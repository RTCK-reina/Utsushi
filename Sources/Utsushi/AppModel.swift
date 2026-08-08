import SwiftUI
import UniformTypeIdentifiers
import AVFoundation


@MainActor
final class AppModel: ObservableObject {

    typealias EngineChoice = SessionSettings.EngineChoice

    // 入力
    @Published var sourceURL: URL?
    @Published var isRunning = false
    @Published var progress: Double = 0
    @Published var statusMessage = "動画または音声ファイルをドロップ"
    @Published var errorMessage: String?

    // 結果
    @Published var transcript: Transcript?
    @Published var correctionOutcome: CorrectionOutcome?

    /// 設定はまとめて1つの値にしてある。UI側にばらして持つと
    /// 「画面には出ているがパイプラインに渡し忘れる」が起きるため（実際に起きた）。
    /// 変更のたびに保存し、次回起動で選び直さずに済むようにする。
    @Published var settings = SessionSettings() { didSet { scheduleSettingsSave() } }
    @Published var dictionary = UserDictionary.empty
    @Published var correctionAvailability: CorrectionAvailability = .unavailable("未確認")

    private var pipeline: TranscriptionPipeline?
    private var task: Task<Void, Never>?
    /// 実行をまたいで使い回す。モデルの再読み込み（10秒前後）を避けるためと、
    /// 終了時に確実に解放するために参照を持ち続ける。
    private var whisperEngine: WhisperEngine?
    /// 通知の解除は行わない。AppModel はアプリと同じ寿命なので、
    /// 解除するタイミングが存在しない（deinit は actor 隔離の外なので触れない）。
    private var terminationObserver: NSObjectProtocol?

    private static let dictURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Utsushi/dictionary.json")
    }()

    private static let settingsURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Utsushi/settings.json")
    }()

    /// 起動直後の代入で保存が走るのを防ぐ
    private var settingsLoaded = false
    private var settingsSaveTask: Task<Void, Never>?

    init() {
        loadDictionary()
        loadSettings()
        settingsLoaded = true
        Task { await refreshCorrectionAvailability() }
        // ggml の静的デストラクタが Metal デバイスを片付ける前に whisper_context を解放する。
        // これをしないと、一度でも認識を走らせたあとの終了で ggml_abort により
        // SIGABRT で落ち、毎回クラッシュダイアログが出る（実際に出た）。
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // 遅延保存が残っていると終了で消えるので、ここで確定させる
                self?.settingsSaveTask?.cancel()
                self?.saveSettings()
                self?.whisperEngine?.shutdown()
            }
        }
    }

    func refreshCorrectionAvailability() async {
        if #available(macOS 26.0, *) {
            correctionAvailability = await FoundationModelsCorrector().isAvailable()
        } else {
            correctionAvailability = .unavailable("macOS 26 以降が必要")
        }
    }

    // MARK: - 入力

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .audio, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .mpeg4Audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { accept(url: url) }
    }

    func accept(url: URL) {
        sourceURL = url
        transcript = nil
        errorMessage = nil
        // ヘッダのタイトルが既にファイル名なので、ここは別の情報を出す。
        // 尺と音声トラックの有無を先に見せておくと、開始前に「読めるファイルか」が分かる。
        statusMessage = "読み込み中…"
        Task { [weak self] in
            let info = await Self.describe(url)
            self?.statusMessage = info
        }
    }

    /// ファイルの尺・サイズ・音声トラックの有無を1行にまとめる
    private static func describe(_ url: URL) async -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) }
        let sizeText = size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "-"
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration).seconds
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard !tracks.isEmpty else {
                return "音声トラックが無い（\(sizeText)）"
            }
            return "\(Exporter.hms(duration))・\(sizeText)・音声トラック \(tracks.count)"
        } catch {
            return "読み込めない: \(error.localizedDescription)"
        }
    }

    // MARK: - 実行

    func start() {
        guard let url = sourceURL, !isRunning else { return }
        errorMessage = nil
        isRunning = true
        progress = 0
        statusMessage = "準備中"

        let engine: any ASREngine
        switch settings.engineChoice {
        case .whisper:
            let model = settings.whisperModel
            // モデルが同じなら読み込み済みのエンジンを使い回す
            if let existing = whisperEngine, existing.modelIdentifier == model.id {
                engine = existing
            } else {
                whisperEngine?.shutdown()
                let fresh = WhisperEngine(model: model)
                whisperEngine = fresh
                engine = fresh
            }
        case .apple:
            if #available(macOS 26.0, *) {
                let loc = settings.language == "ja" ? "ja-JP" : settings.language
                engine = SpeechAnalyzerEngine(locale: Locale(identifier: loc))
            } else {
                engine = WhisperEngine()
            }
        }

        var corrector: (any CorrectionEngine)? = nil
        var judge: (any DisagreementJudge)? = nil
        var summarizer: (any SummaryEngine)? = nil
        var plausibility: (any PlausibilityChecker)? = nil
        if #available(macOS 26.0, *), correctionAvailability.isAvailable {
            if settings.enableCorrection { corrector = FoundationModelsCorrector() }
            if settings.adjudicateDisagreements { judge = FoundationModelsJudge() }
            if settings.enableSummary { summarizer = FoundationModelsSummarizer() }
            if settings.enablePlausibilityCheck { plausibility = FoundationModelsPlausibility() }
        }

        let config = settings.makeConfiguration(dictionary: dictionary,
                                                hasCorrector: corrector != nil,
                                                hasJudge: judge != nil,
                                                hasSummarizer: summarizer != nil,
                                                hasPlausibilityChecker: plausibility != nil)
        let p = TranscriptionPipeline(engine: engine, corrector: corrector, judge: judge,
                                      summaryEngine: summarizer,
                                      plausibilityChecker: plausibility, config: config)
        pipeline = p

        // AppModel は @MainActor なので、ここで作る Task は MainActor 隔離を引き継ぐ。
        // 進捗コールバックだけがバックグラウンドから来るので、そこだけ MainActor に戻す。
        task = Task { [weak self] in
            do {
                let result = try await p.run(url: url) { [weak self] prog in
                    Task { @MainActor in
                        self?.progress = prog.fraction
                        self?.statusMessage = prog.message
                    }
                }
                let outcome = await p.lastCorrectionOutcome
                guard let self else { return }
                self.transcript = result
                self.correctionOutcome = outcome
                self.isRunning = false
                self.progress = 1
                self.statusMessage = "完了"
            } catch {
                guard let self else { return }
                self.isRunning = false
                if let asr = error as? ASRError, case .cancelled = asr {
                    self.errorMessage = nil
                    self.statusMessage = "キャンセルした"
                } else {
                    self.statusMessage = "中断"
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancel() {
        guard let pipeline else { return }
        Task { await pipeline.cancel() }
        statusMessage = "キャンセル中"
    }

    // MARK: - 校正の採否

    func revert(_ segment: Segment) {
        guard var t = transcript, let idx = t.segments.firstIndex(where: { $0.id == segment.id }) else { return }
        t.segments[idx].corrected = t.segments[idx].original
        t.segments[idx].correction?.accepted = false
        transcript = t
    }

    func reapply(_ segment: Segment) {
        guard var t = transcript, let idx = t.segments.firstIndex(where: { $0.id == segment.id }),
              let c = t.segments[idx].correction else { return }
        t.segments[idx].corrected = c.after
        t.segments[idx].correction?.accepted = true
        transcript = t
    }

    func revertAllCorrections() {
        guard var t = transcript else { return }
        for i in t.segments.indices where t.segments[i].correction != nil {
            t.segments[i].corrected = t.segments[i].original
            t.segments[i].correction?.accepted = false
        }
        transcript = t
    }

    // MARK: - 書き出し

    func export(_ format: ExportFormat) {
        guard let t = transcript else { return }
        let panel = NSSavePanel()
        let base = sourceURL?.deletingPathExtension().lastPathComponent ?? "transcript"
        panel.nameFieldStringValue = "\(base)_文字起こし.\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Exporter().render(t, as: format)
            try data.write(to: url)
        } catch {
            errorMessage = "書き出しに失敗: \(error.localizedDescription)"
        }
    }

    func exportAll() {
        guard let t = transcript else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "このフォルダに書き出す"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let base = sourceURL?.deletingPathExtension().lastPathComponent ?? "transcript"
        do {
            for f in ExportFormat.allCases {
                let data = try Exporter().render(t, as: f)
                try data.write(to: dir.appendingPathComponent("\(base)_文字起こし.\(f.fileExtension)"))
            }
        } catch {
            errorMessage = "書き出しに失敗: \(error.localizedDescription)"
        }
    }

    // MARK: - 辞書

    func loadDictionary() {
        guard let data = try? Data(contentsOf: Self.dictURL),
              let d = try? JSONDecoder().decode(UserDictionary.self, from: data) else { return }
        dictionary = d
    }

    func saveDictionary() {
        do {
            try FileManager.default.createDirectory(at: Self.dictURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(dictionary)
            try data.write(to: Self.dictURL)
        } catch {
            errorMessage = "辞書の保存に失敗: \(error.localizedDescription)"
        }
    }

    func addDictionaryEntry() {
        dictionary.entries.append(.init(surface: "", reading: "", misspellings: []))
    }

    // MARK: - 設定の保存

    /// スライダーの操作中は毎フレーム didSet が走るので、最後の値だけ書く。
    private func scheduleSettingsSave() {
        guard settingsLoaded else { return }
        settingsSaveTask?.cancel()
        settingsSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveSettings()
        }
    }

    func saveSettings() {
        do {
            try FileManager.default.createDirectory(at: Self.settingsURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(settings).write(to: Self.settingsURL)
        } catch {
            // 設定が保存できなくても認識は行える。作業を止めるほどではないので本文の邪魔をしない。
            NSLog("Utsushi: 設定の保存に失敗 %@", error.localizedDescription)
        }
    }

    func loadSettings() {
        guard let data = try? Data(contentsOf: Self.settingsURL),
              var s = try? JSONDecoder().decode(SessionSettings.self, from: data) else { return }
        s.dropUnknownModels()
        settings = s
    }
}
