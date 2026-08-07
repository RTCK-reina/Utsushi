import Foundation

/// whisper.cpp を静的リンクして直接呼ぶ。サブプロセスもPythonも挟まない。
///
/// 静的リンクなので Hardened Runtime 下で未署名 dylib を読み込む問題が起きない
/// （`disable-library-validation` を付けずに済む）。
public actor WhisperEngine: ASREngine {
    public nonisolated let identifier = "whisper.cpp"
    public nonisolated var displayName: String { "whisper.cpp (\(model.displayName))" }
    public nonisolated let supportsVAD = true
    public nonisolated let exposesConfidence = true
    public nonisolated let supportsVocabularyHint = true

    public struct Options: Sendable {
        public var threads: Int32 = 8
        public var beamSize: Int32 = 5
        public var bestOf: Int32 = 5
        public var vadThreshold: Float = 0.5
        public var vadMinSpeechMs: Int32 = 250
        public var vadMinSilenceMs: Int32 = 100
        public var vadMaxSpeechSec: Float = 30
        public var vadSpeechPadMs: Int32 = 100
        public var noSpeechThreshold: Float = 0.6
        public var entropyThreshold: Float = 2.4
        public var logprobThreshold: Float = -1.0
        public init() {}
    }

    private let model: ModelCatalog.Model
    private let options: Options
    /// actor 隔離の外からも解放できるようにロック付きの箱で持つ。
    /// アプリ終了時、ggml の静的デストラクタが Metal デバイスを片付ける前に
    /// whisper_context を解放しておかないと ggml_abort で落ちる（実際に落ちた）。
    private nonisolated let context = WhisperContextBox()
    private var vadPath: String?

    public init(model: ModelCatalog.Model = ModelCatalog.whisperModels[0], options: Options = Options()) {
        self.model = model
        self.options = options
    }

    /// 明示的な解放。アプリ終了時に必ず呼ぶこと。
    /// actor の外（NSApplication の終了通知など）からも呼べるよう nonisolated にしてある。
    public nonisolated func shutdown() { context.free() }

    public nonisolated var isLoaded: Bool { context.pointer != nil }
    public nonisolated var modelIdentifier: String { model.id }

    public func prepare(progress: @escaping @Sendable (String, Double) -> Void) async throws {
        progress("モデルを確認中", 0)
        // 未導入なら実際にはここで数分のダウンロードが走る。
        // 「確認中」のまま止まって見えないよう、開始前にラベルを切り替える。
        let needsDownload = !ModelCatalog.isInstalled(model)
        let label = needsDownload
            ? "音声認識モデルをダウンロード中（\(ModelCatalog.sizeText(model.approximateBytes))・初回のみ）"
            : "モデルを確認中"
        if needsDownload { progress(label, 0.01) }
        _ = try await ModelCatalog.install(model) { p in progress(label, max(0.01, p * 0.95)) }
        _ = try await ModelCatalog.install(ModelCatalog.vadModel) { _ in }

        guard let modelPath = ModelCatalog.localURL(for: model, role: "model")?.path,
              let vad = ModelCatalog.localURL(for: ModelCatalog.vadModel, role: "model")?.path else {
            throw ASRError.modelUnavailable("モデルファイルの場所を解決できない")
        }
        vadPath = vad

        if context.pointer == nil {
            progress("モデルを読み込み中", 0.97)
            var cparams = whisper_context_default_params()
            cparams.use_gpu = true
            cparams.flash_attn = true
            guard let c = whisper_init_from_file_with_params(modelPath, cparams) else {
                throw ASRError.modelUnavailable("whisper_init_from_file_with_params が nil を返した")
            }
            context.set(c)
        }
        progress("準備完了", 1.0)
    }

    public func transcribe(_ request: ASRRequest,
                           progress: @escaping @Sendable (Double) -> Void,
                           isCancelled: @escaping @Sendable () -> Bool) async throws -> [Segment] {
        guard let ctx = context.pointer else { throw ASRError.engineFailed("prepare() が呼ばれていない") }
        guard !request.samples.isEmpty else { return [] }

        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.n_threads = options.threads
        params.beam_search.beam_size = options.beamSize
        params.greedy.best_of = options.bestOf
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_speech_thold = options.noSpeechThreshold
        params.entropy_thold = options.entropyThreshold
        params.logprob_thold = options.logprobThreshold

        if let range = request.timeRange {
            params.offset_ms = Int32(range.lowerBound * 1000)
            params.duration_ms = Int32((range.upperBound - range.lowerBound) * 1000)
        }

        let box = CallbackBox(progress: progress, isCancelled: isCancelled)
        let boxPtr = Unmanaged.passUnretained(box).toOpaque()
        params.progress_callback = { _, _, p, user in
            guard let user else { return }
            Unmanaged<CallbackBox>.fromOpaque(user).takeUnretainedValue().progress(Double(p) / 100.0)
        }
        params.progress_callback_user_data = boxPtr
        params.abort_callback = { user in
            guard let user else { return false }
            return Unmanaged<CallbackBox>.fromOpaque(user).takeUnretainedValue().isCancelled()
        }
        params.abort_callback_user_data = boxPtr

        // C の const char * は呼び出しの間だけ生きていればよいので、
        // withCString をネストして params に載せる（Swift の String をそのまま渡すと解放済みポインタになる）。
        let segments: [Segment] = try request.language.withCString { langPtr in
            params.language = langPtr
            params.detect_language = false

            let run: () throws -> [Segment] = {
                let rc = request.samples.withUnsafeBufferPointer { buf in
                    whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                }
                if isCancelled() { throw ASRError.cancelled }
                guard rc == 0 else { throw ASRError.engineFailed("whisper_full rc=\(rc)") }
                return Self.collect(ctx: ctx)
            }

            let withVAD: () throws -> [Segment] = { [self] in
                if request.useVAD, let vadPath {
                    return try vadPath.withCString { vadPtr -> [Segment] in
                        params.vad = true
                        params.vad_model_path = vadPtr
                        var vp = whisper_vad_default_params()
                        vp.threshold = options.vadThreshold
                        vp.min_speech_duration_ms = options.vadMinSpeechMs
                        vp.min_silence_duration_ms = options.vadMinSilenceMs
                        vp.max_speech_duration_s = options.vadMaxSpeechSec
                        vp.speech_pad_ms = options.vadSpeechPadMs
                        params.vad_params = vp
                        return try run()
                    }
                } else {
                    params.vad = false
                    return try run()
                }
            }

            // 語彙ヒント。carry_initial_prompt を立てないと先頭30秒にしか効かない。
            if let hint = request.vocabularyHint, !hint.isEmpty {
                return try hint.withCString { hintPtr -> [Segment] in
                    params.initial_prompt = hintPtr
                    params.carry_initial_prompt = true
                    return try withVAD()
                }
            }
            return try withVAD()
        }
        progress(1.0)
        return segments
    }

    private static func collect(ctx: OpaquePointer) -> [Segment] {
        let n = whisper_full_n_segments(ctx)
        var out: [Segment] = []
        out.reserveCapacity(Int(n))
        for i in 0..<n {
            guard let cText = whisper_full_get_segment_text(ctx, i) else { continue }
            let text = String(cString: cText).trimmingCharacters(in: .whitespacesAndNewlines)
            let t0 = Double(whisper_full_get_segment_t0(ctx, i)) / 100.0
            let t1 = Double(whisper_full_get_segment_t1(ctx, i)) / 100.0

            // トークン確率の対数平均を尤度の代理指標にする
            let nTok = whisper_full_n_tokens(ctx, i)
            var logSum = 0.0
            var counted = 0
            for j in 0..<nTok {
                let p = Double(whisper_full_get_token_p(ctx, i, j))
                if p > 0 { logSum += log(p); counted += 1 }
            }
            let avgLogprob = counted > 0 ? logSum / Double(counted) : nil
            let noSpeech = Double(whisper_full_get_segment_no_speech_prob(ctx, i))

            out.append(Segment(start: t0, end: t1, original: text,
                               avgLogprob: avgLogprob, noSpeechProb: noSpeech))
        }
        return out
    }
}

/// whisper_context の所有者。
/// actor の deinit からは isolated state に触れられず、かつアプリ終了時には
/// 任意のスレッドから解放したいので、ロック付きのクラスで持つ。
private final class WhisperContextBox: @unchecked Sendable {
    private var ptr: OpaquePointer?
    private let lock = NSLock()

    var pointer: OpaquePointer? {
        lock.lock(); defer { lock.unlock() }
        return ptr
    }
    func set(_ p: OpaquePointer) {
        lock.lock()
        if let old = ptr { whisper_free(old) }
        ptr = p
        lock.unlock()
    }
    func free() {
        lock.lock()
        if let p = ptr { whisper_free(p); ptr = nil }
        lock.unlock()
    }
    deinit { free() }
}

/// C コールバックに渡すための箱。actor をまたぐのでクラスにする。
private final class CallbackBox: @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    let isCancelled: @Sendable () -> Bool
    init(progress: @escaping @Sendable (Double) -> Void, isCancelled: @escaping @Sendable () -> Bool) {
        self.progress = progress; self.isCancelled = isCancelled
    }
}
