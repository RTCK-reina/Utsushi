import Foundation

/// NeMo-Speech.cpp の C ABI を静的リンクで呼ぶ話者分離エンジン。
///
/// Nemotron 3 Diarization（sortformer系）で音声を「誰がいつ話したか」に切る。
/// 本文は生成しない。Segment に貼る話者番号を出すだけで、文字起こしの
/// 中身には一切触れない。whisper / sherpa と同じく静的リンク済み。
///
/// 制約: Metal（GPU）は day-0 リリースの上流バグで確実に落ちるため CPU 固定。
/// 実測で実時間の約60倍速なので、バッチ処理には十分。
public actor DiarizationEngine {

    /// 分離結果の1区間。`speaker` は到着順の1始まり番号。
    public struct SpeakerSpan: Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var speaker: Int
        public init(start: Double, end: Double, speaker: Int) {
            self.start = start; self.end = end; self.speaker = speaker
        }
    }

    private let model: ModelCatalog.Model
    private nonisolated let holder = DiarModelBox()

    public init(model: ModelCatalog.Model = ModelCatalog.diarModel) {
        self.model = model
    }

    public nonisolated func shutdown() { holder.free() }
    public nonisolated var isLoaded: Bool { holder.pointer != nil }

    /// モデルが区別できる話者数（V3 は 8）
    public var maxSpeakers: Int {
        guard let p = holder.pointer else { return 0 }
        return Int(nemo_speech_diar_num_speakers(p))
    }

    public func prepare(progress: @escaping @Sendable (String, Double) -> Void) async throws {
        let needsDownload = !ModelCatalog.isInstalled(model)
        let label = needsDownload
            ? "\(model.displayName) をダウンロード中（\(ModelCatalog.sizeText(model.approximateBytes))・初回のみ）"
            : "話者分離モデルを確認中"
        if needsDownload { progress(label, 0.01) }
        _ = try await ModelCatalog.install(model) { p in progress(label, max(0.01, p * 0.95)) }

        guard holder.pointer == nil else { progress("準備完了", 1.0); return }
        progress("話者分離モデルを読み込み中", 0.96)

        guard let path = ModelCatalog.localURL(for: model, role: "model")?.path else {
            throw ASRError.modelUnavailable("話者分離モデルが無い")
        }
        // バッチ処理なので広い窓の "v3-offline" を使う（streaming ジオメトリの
        // バリエーションで、長尺の音声もそのまま流せる）。
        let created: OpaquePointer? = path.withCString { mp in
            "v3-offline".withCString { preset in
                var config = nemo_speech_diar_model_config()
                config.size = MemoryLayout<nemo_speech_diar_model_config>.size
                config.model_path = mp
                config.gpu = -1  // Metal バックエンドは上流で壊れているので CPU 固定
                config.preset = preset
                var out: OpaquePointer?
                let rc = withUnsafeMutablePointer(to: &out) { outPtr in
                    nemo_speech_diar_create(&config, outPtr)
                }
                return rc == NEMO_SPEECH_ASR_OK ? out : nil
            }
        }
        guard let created else {
            throw ASRError.engineFailed("話者分離の初期化に失敗: \(Self.lastError())")
        }
        holder.set(created)
        progress("準備完了", 1.0)
    }

    /// 16kHz mono の波形を流して話者区間を得る。
    ///
    /// offline_f32（全アテンション一発）はエンコーダの位置埋め込み上限に
    /// 縛られるので、長尺には使わない。ストリーミング経路は長さに制限が無い。
    public func diarize(samples: [Float],
                        progress: @escaping @Sendable (Double) -> Void = { _ in },
                        isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> [SpeakerSpan] {
        guard let model = holder.pointer else {
            throw ASRError.engineFailed("DiarizationEngine.prepare() が呼ばれていない")
        }
        guard !samples.isEmpty else { return [] }

        var streamBox: OpaquePointer?
        let openRC = withUnsafeMutablePointer(to: &streamBox) { ptr in
            nemo_speech_diar_stream_open(model, ptr)
        }
        guard openRC == NEMO_SPEECH_ASR_OK, let stream = streamBox else {
            throw ASRError.engineFailed("話者分離ストリームの作成に失敗: \(Self.lastError())")
        }
        defer { nemo_speech_diar_stream_close(stream) }

        // 10秒分ずつ押して進捗を出す。押し込み自体が推論なので分割は進捗用で、
        // 結果には影響しない（内部でチャンク単位にまとめ直される）。
        let chunk = 160_000  // 16000 * 10
        var pos = 0
        while pos < samples.count {
            if isCancelled() { throw ASRError.cancelled }
            let end = min(pos + chunk, samples.count)
            let rc = samples[pos..<end].withUnsafeBufferPointer { buf in
                nemo_speech_diar_stream_push_f32(stream, buf.baseAddress,
                                               buf.count, Int32(AudioExtractor.sampleRate))
            }
            guard rc == NEMO_SPEECH_ASR_OK else {
                throw ASRError.engineFailed("話者分離の推論に失敗: \(Self.lastError())")
            }
            pos = end
            progress(Double(pos) / Double(samples.count) * 0.9)
        }

        guard nemo_speech_diar_stream_finish(stream) == NEMO_SPEECH_ASR_OK else {
            throw ASRError.engineFailed("話者分離の完了処理に失敗: \(Self.lastError())")
        }
        progress(0.95)

        // セグメント取得は2回呼び: 1回目で件数を受け取り、2回目で書き込む。
        var count = 0
        let countRC = nemo_speech_diar_segments(stream, nil, nil, 0, &count)
        guard countRC == NEMO_SPEECH_ASR_OK else {
            throw ASRError.engineFailed("話者区間の取得に失敗: \(Self.lastError())")
        }
        guard count > 0 else { progress(1.0); return [] }
        var raw = [nemo_speech_diar_segment](repeating: .init(), count: count)
        var filled = 0
        let segRC = raw.withUnsafeMutableBufferPointer { buf in
            nemo_speech_diar_segments(stream, nil, buf.baseAddress, buf.count, &filled)
        }
        guard segRC == NEMO_SPEECH_ASR_OK else {
            throw ASRError.engineFailed("話者区間の書き出しに失敗: \(Self.lastError())")
        }
        progress(1.0)
        return raw.prefix(filled).map {
            SpeakerSpan(start: $0.start_time, end: $0.end_time, speaker: Int($0.speaker))
        }
    }

    private static func lastError() -> String {
        guard let p = nemo_speech_asr_last_error() else { return "（詳細なし）" }
        return String(cString: p)
    }

    // MARK: - セグメントへの割り当て

    /// 文字起こしセグメントに話者番号を貼る。区間が最も重なる話者を採用する。
    ///
    /// オーバーラップ（同時発話）は分離側が別行の区間として返してくるので、
    /// ここでは単純に最大重なりを取るだけで支配的な話者が決まる。
    /// 重なりが一切無い区間（分離が拾わなかった whisper の幻聴気味区間など）は
    /// speaker を nil のまま残し、不明であることを画面にも残す。
    public static func assignSpeakers(to segments: inout [Segment],
                                      spans: [SpeakerSpan]) {
        guard !spans.isEmpty else { return }
        for i in segments.indices {
            segments[i].speaker = dominantSpeaker(for: segments[i], spans: spans)
        }
    }

    private static func dominantSpeaker(for segment: Segment,
                                        spans: [SpeakerSpan]) -> Int? {
        var best: (speaker: Int, overlap: Double)? = nil
        for span in spans {
            let overlap = min(segment.end, span.end) - max(segment.start, span.start)
            if overlap > 0, overlap > (best?.overlap ?? 0) {
                best = (span.speaker, overlap)
            }
        }
        if best != nil { return best?.speaker }
        // 分離区間が無い（完全な無音や、分離側が捨てた短い区間）ときは
        // 直近の話者を拾って穴を埋める。離れすぎた区間は不明のままにする。
        let nearest = spans.min(by: {
            min(abs($0.end - segment.start), abs($0.start - segment.end))
                < min(abs($1.end - segment.start), abs($1.start - segment.end))
        })
        guard let nearest else { return nil }
        let gap = max(0, max(nearest.start - segment.end, segment.start - nearest.end))
        return gap <= 1.0 ? nearest.speaker : nil
    }
}

/// diar モデルの所有者。actor の外からも解放できるようロックで持つ。
private final class DiarModelBox: @unchecked Sendable {
    private var ptr: OpaquePointer?
    private let lock = NSLock()
    var pointer: OpaquePointer? { lock.lock(); defer { lock.unlock() }; return ptr }
    func set(_ p: OpaquePointer) {
        lock.lock()
        if let old = ptr { nemo_speech_diar_destroy(old) }
        ptr = p
        lock.unlock()
    }
    func free() {
        lock.lock()
        if let p = ptr { nemo_speech_diar_destroy(p); ptr = nil }
        lock.unlock()
    }
    deinit { free() }
}
