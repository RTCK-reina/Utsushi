import XCTest
import FoundationModels

/// 実エンジン・実モデルで最後まで通す。
///
/// これまで照合エンジンは純粋関数（chunk / groupTokens）しかテストしておらず、
/// sherpa-onnx が実際に波形を認識したことが一度も無かった。
/// 静的リンクが通る＝シンボルが解決するだけで、実行時に動く証明にはならない。
///
/// パイプラインは照合の失敗を握りつぶして本体の結果を返す設計なので、
/// **照合が実際に走ったことを明示的に主張する**。でないと沈黙した失敗を成功と読み違える。
/// 進捗コールバックはバックグラウンドから呼ばれるので、素の var では受けられない。
private final class StageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: Set<String> = []
    func add(_ s: String) { lock.lock(); values.insert(s); lock.unlock() }
    var all: Set<String> { lock.lock(); defer { lock.unlock() }; return values }
}

final class EndToEndTests: XCTestCase {

    private static let clipURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/testclip.m4a")
    }()

    private func requireClip() throws -> URL {
        guard FileManager.default.fileExists(atPath: Self.clipURL.path) else {
            throw XCTSkip("検証用クリップが無い")
        }
        return Self.clipURL
    }

    // MARK: - 1. sherpa が本当に音声を認識するか

    /// モデルの取得から認識まで、実物で通す。落ちるならここで落ちてほしい。
    func testSherpaEnginesActuallyTranscribeAudio() async throws {
        let url = try requireClip()
        let audio = try await AudioExtractor().extract(url: url, progress: { _ in }, isCancelled: { false })
        XCTAssertGreaterThan(audio.samples.count, 0)

        // 導入済みのものを回す。カタログには「選べるが既定では勧めない」モデル
        // （Qwen3）も載っているので、全部回すとテストのたびに数 GB の取得が走る。
        //
        // 何も入っていない環境では、取得と展開の経路自体を通したいので
        // 一番小さいものを1つだけ落とす。
        let installed = ModelCatalog.sherpaModels.filter { ModelCatalog.isInstalled($0) }
        let targets = installed.isEmpty
            ? [ModelCatalog.sherpaModels.min { $0.approximateBytes < $1.approximateBytes }].compactMap { $0 }
            : installed
        XCTAssertFalse(targets.isEmpty, "照合エンジンがカタログに1つも無い")

        for model in targets {
            let t0 = Date()
            let engine = SherpaEngine(model: model)
            do {
                try await engine.prepare { msg, p in
                    if p == 0 || p >= 1 { print("[\(model.id)] \(msg)") }
                }
            } catch {
                XCTFail("[\(model.id)] モデル準備に失敗: \(error)")
                continue
            }
            let prepared = Date().timeIntervalSince(t0)

            let t1 = Date()
            let segs: [Segment]
            do {
                segs = try await engine.transcribe(
                    ASRRequest(samples: audio.samples, language: "ja", useVAD: false),
                    progress: { _ in }, isCancelled: { false })
            } catch {
                XCTFail("[\(model.id)] 認識に失敗: \(error)")
                engine.shutdown()
                continue
            }
            let elapsed = Date().timeIntervalSince(t1)
            engine.shutdown()

            let text = segs.map(\.text).joined()
            print("""
                  [\(model.id)] 準備 \(String(format: "%.1f", prepared))秒 / \
                  認識 \(String(format: "%.1f", elapsed))秒（音声 \(String(format: "%.0f", audio.duration))秒・\
                  \(String(format: "%.1f", audio.duration / max(elapsed, 0.001)))倍速）/ \
                  \(segs.count)セグメント \(text.count)文字
                  """)
            print("[\(model.id)] 冒頭: \(text.prefix(120))")

            XCTAssertFalse(segs.isEmpty, "[\(model.id)] セグメントが1件も返っていない")
            XCTAssertGreaterThan(text.count, 200, "[\(model.id)] 文字数が少なすぎる。実質認識できていない疑い")
            // 日本語が返っていること。
            //
            // 以前はここを「かな＋CJK漢字 / 全文字」で見ていた。これには穴が2つあった:
            //   1. 中国語を検出できない。漢字は中国語も同じ範囲を使う。
            //      実際、広東語モデルの壊れた出力がこの条件を通ってしまった
            //   2. 分母に句読点と算用数字が入るので、表記の癖で比率が動く。
            //      Qwen3 は「3月」と算用数字で書き句読点も打つので 0.471 になり、
            //      正しい日本語なのに 0.5 を割った
            // かな / (かな+漢字) で見れば、壊れた出力 0.00 に対し実エンジンは 0.6 以上で、
            // 間が十分に開く。
            XCTAssertGreaterThan(JapaneseTextCheck.kanaRatio(text),
                                 JapaneseTextCheck.minimumKanaRatio,
                                 "[\(model.id)] 日本語になっていない"
                                 + "（かな比率 \(String(format: "%.2f", JapaneseTextCheck.kanaRatio(text)))）: "
                                 + "\(text.prefix(80))")
            XCTAssertGreaterThan(segs.last?.end ?? 0, 60, "[\(model.id)] 後半が認識されていない")
        }
    }

    // MARK: - 2. 照合と要約を含めてパイプラインを最後まで

    func testFullPipelineWithCrossCheckAndSummary() async throws {
        let url = try requireClip()
        guard ModelCatalog.isInstalled(ModelCatalog.whisperModels[0]) else {
            throw XCTSkip("whisperモデルが未導入")
        }
        guard #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability else {
            throw XCTSkip("Foundation Models が利用できない")
        }

        // 照合は導入済みのエンジンで行う。
        // カタログ全件を指定していたが、そこには「選べるが既定では勧めない」
        // Qwen3 も入るので、テストを回すたびに 940MB の取得が走っていた
        // （実際に走った）。このテストが見たいのはパイプラインが最後まで通ることで、
        // カタログの全件網羅ではない。
        let installedSherpa = ModelCatalog.sherpaModels.filter { ModelCatalog.isInstalled($0) }
        guard installedSherpa.count >= 2 else {
            throw XCTSkip("照合できるエンジンが2つ以上導入されていない")
        }

        var settings = SessionSettings()
        settings.crossCheckModelIDs = Set(installedSherpa.map(\.id))
        settings.enableSummary = true
        settings.enableCorrection = true
        settings.adjudicateDisagreements = true

        var dict = UserDictionary.empty
        dict.entries = [
            .init(surface: "コンピテンシー", reading: "こんぴてんしー", misspellings: []),
            .init(surface: "上長評価", reading: "じょうちょうひょうか", misspellings: []),
        ]
        let config = settings.makeConfiguration(dictionary: dict,
                                                hasCorrector: true, hasJudge: true, hasSummarizer: true)
        XCTAssertEqual(config.crossCheckEngines.count, installedSherpa.count)

        let pipeline = TranscriptionPipeline(
            engine: WhisperEngine(),
            corrector: FoundationModelsCorrector(),
            judge: FoundationModelsJudge(),
            summaryEngine: FoundationModelsSummarizer(),
            config: config)

        let t0 = Date()
        // 進捗はバックグラウンドから来るので、ローカル var を直接触ると
        // Swift 6 の並行チェックに引っかかる（実際に引っかかった）
        let seen = StageRecorder()
        let t = try await pipeline.run(url: url) { prog in
            seen.add("\(prog.stage)".prefix(while: { $0 != "(" }).description)
        }
        let elapsed = Date().timeIntervalSince(t0)
        let stages = seen.all

        print("""
              === 全段通し \(String(format: "%.0f", elapsed))秒 ===
              本文: \(t.visibleSegments.count)セグメント \(t.totalCharacters)文字
              照合エンジン: \(t.crossCheck.engines.joined(separator: " / "))
              食い違い: \(t.crossCheck.disagreements.count)
              判定: 決着\(t.crossCheck.outcome.decided) / 未決\(t.crossCheck.outcome.undecided) \
              / 読み一致\(t.crossCheck.outcome.decidedWithMatchingReadings) \
              / 読み不一致\(t.crossCheck.outcome.decidedWithDifferentReadings) \
              / エラー\(t.crossCheck.outcome.errors)
              要約: \(t.summary.points.count)件 / 塊\(t.summary.stats.chunkCount) \
              / モデル見出し\(Int(t.summary.modelHeadlineRatio * 100))% \
              / 棄却\(t.summary.stats.headlineRejections)
              破棄した本文: \(t.suppressedSegments.count) / 無音区間: \(t.gaps().count)
              到達した段: \(stages.sorted().joined(separator: ", "))
              """)
        for p in t.summary.points.prefix(8) {
            print("  [\(p.kind.rawValue)] \(p.headline) (\(p.headlineSource.rawValue))")
        }

        // 照合が本当に走ったこと。パイプラインは失敗を握りつぶすので必ず主張する。
        XCTAssertGreaterThanOrEqual(t.crossCheck.engines.count, 3,
                                    "照合エンジンが結果に入っていない＝黙って失敗している")
        for m in installedSherpa {
            XCTAssertTrue(t.crossCheck.engines.contains(m.id), "\(m.id) が照合に参加していない")
        }
        XCTAssertFalse(t.crossCheck.disagreements.isEmpty,
                       "系統の違うエンジン3つで食い違いが0件はありえない。整列が機能していない疑い")

        // 表記の分類が**実データで実際に効いている**こと。
        // 単体テストが通るだけの機能を作って画面に繋がっていない、という失敗を
        // この構成で何度もやっているので、実データでの発火を必ず主張する。
        // zipformer は「三月」、parakeet は「3月」と書くので、0件ならどこかで死んでいる。
        let notation = t.crossCheck.disagreements.filter { $0.kind == .notation }
        let substantive = t.crossCheck.disagreements.filter { $0.kind == .substantive }
        print("""
              　うち表記だけ: \(notation.count) / 中身の違い: \(substantive.count) \
              （判定に投げなかった表記差: \(t.crossCheck.outcome.notationOnly)）
              """)
        XCTAssertFalse(notation.isEmpty,
                       "表記だけの違いが1件も分類されていない。Notation が繋がっていない疑い")
        XCTAssertEqual(notation.count, t.crossCheck.outcome.notationOnly,
                       "分類した件数と、判定を飛ばした件数が合っていない")
        for d in notation.prefix(5) {
            print("  表記差: " + d.candidates.map { "\($0.engine.suffix(12))「\($0.text)」" }
                .joined(separator: " / "))
        }
        XCTAssertTrue(stages.contains("crossChecking"), "照合の段に入っていない")
        XCTAssertTrue(stages.contains("summarizing"), "要約の段に入っていない")

        // 要約が出て、引用が原文そのままであること
        XCTAssertFalse(t.summary.points.isEmpty, "要約が1件も出ていない")
        let known = Set(t.visibleSegments.map(\.text))
        for p in t.summary.points {
            for q in p.quotes {
                XCTAssertTrue(known.contains(q), "原文に無い引用が出た: \(q)")
            }
        }
        XCTAssertEqual(t.summary.stats.failedChunkCount, 0, "要約に失敗した塊がある")

        // 本体が壊れていないこと
        XCTAssertGreaterThan(t.totalCharacters, 800)
        for s in t.visibleSegments {
            XCTAssertFalse(s.text.isEmpty)
        }

        // 成果物を目視できるように残す
        let dump = FileManager.default.temporaryDirectory.appendingPathComponent("utsushi-e2e.md")
        try Exporter().render(t, as: .markdown).write(to: dump)
        print("出力 -> \(dump.path)")
    }

    // MARK: - 3. 設定の保存と復元

    /// AppModel はテストターゲットに入っていないので、保存先と往復だけ実ファイルで確かめる。
    /// アプリ側の配線（didSet → 遅延保存 → 終了時フラッシュ）は手動確認が要る。
    func testSettingsSurviveARoundTripOnDisk() throws {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Utsushi")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.e2e-test.json")
        defer { try? FileManager.default.removeItem(at: url) }

        var s = SessionSettings()
        s.engineChoice = .apple
        s.silenceDBFS = -52
        s.crossCheckModelIDs = [ModelCatalog.sherpaModels[0].id]
        s.enableSummary = false
        try JSONEncoder().encode(s).write(to: url)

        var back = try JSONDecoder().decode(SessionSettings.self, from: Data(contentsOf: url))
        back.dropUnknownModels()
        XCTAssertEqual(s, back)
    }
}
