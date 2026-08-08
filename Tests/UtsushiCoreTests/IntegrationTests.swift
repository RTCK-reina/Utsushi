import XCTest
import FoundationModels

/// 実データ統合テスト。
///
/// 素材は実際の説明会録画から切り出した 00:57:00–01:08:00 の11分。
/// この区間は「発話 → 約8分の無音（休憩） → 発話再開」という構成で、
/// 今日の手作業の文字起こしで3件の不具合が全部出た区間そのもの。
/// 素材が無い環境ではスキップする（CIを壊さないため）。
final class RealAudioIntegrationTests: XCTestCase {

    /// 検証用素材はリポジトリ内の fixtures/ に置く（gitignore 済み）。
    /// script/make_fixture.sh で元動画から生成できる。
    private static let clipURL: URL = {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UtsushiCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        return repo.appendingPathComponent("fixtures/testclip.m4a")
    }()
    /// クリップ先頭は元動画の 3420 秒地点
    private static let clipOffset: Double = 3420
    /// 元動画で無音だった 3521–4023 秒 → クリップ相対
    private static let silentStart: Double = 3521 - clipOffset   // 101
    private static let silentEnd: Double   = 4023 - clipOffset   // 603

    private func requireClip() throws -> URL {
        let url = Self.clipURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("検証用クリップが無い: \(url.path)（script/make_fixture.sh で生成できる）")
        }
        guard ModelCatalog.isInstalled(ModelCatalog.whisperModels[0]) else {
            throw XCTSkip("whisperモデルが未導入")
        }
        return url
    }

    func testPipelineOnRealRecording() async throws {
        let url = try requireClip()

        var config = TranscriptionPipeline.Configuration()
        config.language = "ja"
        config.enableCorrection = false     // 校正は別テストで見る
        config.autoRepair = true
        let pipeline = TranscriptionPipeline(engine: WhisperEngine(), corrector: nil, config: config)

        let t = try await pipeline.run(url: url) { _ in }

        // 出力を目視できるように残す
        let dump = FileManager.default.temporaryDirectory.appendingPathComponent("utsushi-integration.md")
        try Exporter().render(t, as: .markdown).write(to: dump)
        print("integration output -> \(dump.path)")

        // セグメント数では主張しない。同じ音声でもエンジンや設定で分割粒度が変わり、
        // 「1発話=1セグメント」なのか「1文=1セグメント」なのかで数が倍以上動くため、
        // 数を閾値にすると内容が完全でもテストが落ちる（実際に落ちた）。
        // 発話が取れているかは文字数と発話密度で見る。
        XCTAssertGreaterThan(t.visibleSegments.count, 10, "発話がほとんど取れていない")
        XCTAssertGreaterThan(t.totalCharacters, 800, "11分中およそ3分の発話にしては文字数が少なすぎる")
        let charsPerSpeechSecond = Double(t.totalCharacters) / max(t.coveredSeconds, 1)
        XCTAssertTrue((3.0...12.0).contains(charsPerSpeechSecond),
                      "日本語の発話速度として異常: \(charsPerSpeechSecond) 文字/秒")

        // 1. 無音区間に本文が残っていないこと（今日の 3761–4023 の再現）
        let inSilence = t.visibleSegments.filter {
            $0.start >= Self.silentStart + 10 && $0.end <= Self.silentEnd - 10
        }
        XCTAssertTrue(inSilence.isEmpty,
                      "無音区間に本文が残っている: " +
                      inSilence.map { "\(Exporter.hms($0.start))「\($0.text)」" }.joined(separator: " / "))

        // 2. 幻聴フレーズが出力に一切出ていないこと
        for seg in t.visibleSegments {
            XCTAssertFalse(HallucinationAuditor.knownHallucinations.contains(seg.text.trimmingCharacters(in: .whitespaces)),
                           "既知の幻聴フレーズが出力に残っている: \(Exporter.hms(seg.start))")
        }

        // 3. 無音の前後には発話が残っていること（消しすぎ検出）
        let before = t.visibleSegments.filter { $0.end <= Self.silentStart }
        let after  = t.visibleSegments.filter { $0.start >= Self.silentEnd }
        XCTAssertGreaterThan(before.reduce(0) { $0 + $1.text.count }, 300, "休憩前の発話が消えている")
        XCTAssertGreaterThan(after.reduce(0) { $0 + $1.text.count }, 200, "休憩後の発話が消えている")

        // 内容そのものが取れているかを固定する。数だけ合っていて中身が別物、を防ぐ。
        let beforeText = before.map(\.text).joined()
        let afterText = after.map(\.text).joined()
        XCTAssertTrue(beforeText.contains("休憩"), "休憩の告知が欠落している")
        XCTAssertTrue(afterText.contains("就職活動"), "休憩後の本題が欠落している")

        // 4. 監査が無音区間を見ていること。
        //    「破棄件数>0」は主張しない。VADが効いて無音に何も出さなかった場合、
        //    破棄すべき本文がそもそも存在せず0件が正しい（実際にそうなった）。
        //    主張すべきは「無音区間が検出対象として認識されている」ことの方。
        let silenceAware = t.audit.findings.contains {
            $0.start < Self.silentEnd && $0.end > Self.silentStart
        }
        XCTAssertTrue(silenceAware, "8分の無音区間が監査でまったく認識されていない")

        //    無音区間に落ちたセグメントが仮にあったなら、必ず破棄されていること
        for seg in t.segments where seg.start >= Self.silentStart + 10 && seg.end <= Self.silentEnd - 10 {
            XCTAssertTrue(seg.isSuppressed || seg.original.isEmpty,
                          "無音区間のセグメントが破棄されていない: 「\(seg.original)」")
        }

        //    自動修復が動いたなら、その区間の指摘は未解決のまま放置されていないこと
        if t.audit.stats.repairedCount > 0 {
            XCTAssertFalse(t.audit.findings.contains { $0.action == .unresolved && $0.kind == .densityAnomaly },
                           "修復済みなのに未解決のまま残っている")
        }

        // 5. 原文は破壊されていないこと
        for seg in t.segments where seg.correction == nil && !seg.isSuppressed {
            XCTAssertEqual(seg.text, seg.original)
        }

        print("""
        --- 統合テスト結果 ---
        セグメント(表示) : \(t.visibleSegments.count)
        文字数           : \(t.totalCharacters)
        カバー率         : \(String(format: "%.1f%%", t.audit.stats.coverageRatio * 100))
        破棄             : \(t.audit.stats.suppressedCount)
        再認識で修復     : \(t.audit.stats.repairedCount)
        検出項目         : \(t.audit.findings.count)
        """)
    }

    /// 任意の2時間超素材を使う本番サイズ検証。
    /// 大容量の実録画はリポジトリへ入れないため、明示した環境変数がある時だけ走らせる。
    func testProductionLengthRecordingHasNoTextInsideSilence() async throws {
        guard let path = ProcessInfo.processInfo.environment["UTSUSHI_PRODUCTION_MEDIA"],
              !path.isEmpty else {
            throw XCTSkip("UTSUSHI_PRODUCTION_MEDIA が未指定（2時間超の実素材検証用）")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("本番サイズ素材が存在しない: \(url.path)")
            return
        }
        guard ModelCatalog.isInstalled(ModelCatalog.whisperModels[0]) else {
            throw XCTSkip("whisperモデルが未導入")
        }

        var config = TranscriptionPipeline.Configuration()
        config.language = "ja"
        config.enableCorrection = false
        config.autoRepair = true
        let engine = WhisperEngine()
        defer { engine.shutdown() }
        let pipeline = TranscriptionPipeline(engine: engine, corrector: nil, config: config)

        let t = try await pipeline.run(url: url) { progress in
            if case .transcribing = progress.stage, Int(progress.fraction * 100) % 10 == 0 {
                print("production progress: \(Int(progress.fraction * 100))% \(progress.message)")
            }
        }

        XCTAssertGreaterThan(t.meta.sourceDuration, 2 * 60 * 60,
                             "本番サイズ検証には2時間超の素材が必要")
        XCTAssertGreaterThan(t.totalCharacters, 1_000, "長尺素材を実質的に認識できていない")

        let longSilences = t.audit.stats.silentRanges.filter { $0.duration >= 20 }
        let leaked = t.visibleSegments.filter { segment in
            longSilences.contains { silence in
                segment.start >= silence.start && segment.end <= silence.end
            }
        }
        XCTAssertTrue(leaked.isEmpty,
                      "無音区間に本文が残っている: "
                      + leaked.prefix(10).map { "\(Exporter.hms($0.start))「\($0.text)」" }
                          .joined(separator: " / "))

        let dump = FileManager.default.temporaryDirectory
            .appendingPathComponent("utsushi-production-\(UUID().uuidString).md")
        try Exporter().render(t, as: .markdown).write(to: dump)
        print("production result: \(String(format: "%.0f", t.meta.sourceDuration))秒 / "
              + "\(t.visibleSegments.count)セグメント / \(t.totalCharacters)文字 / "
              + "長無音\(longSilences.count)区間 / 出力 \(dump.path)")
    }

    /// 解放 → 再準備 → 認識 が通ること。
    /// アプリ終了時に context を解放する必要があるため、解放後に壊れないことを固定する。
    func testEngineSurvivesShutdownAndReprepare() async throws {
        let url = try requireClip()
        let engine = WhisperEngine()
        try await engine.prepare { _, _ in }
        XCTAssertTrue(engine.isLoaded)

        engine.shutdown()
        XCTAssertFalse(engine.isLoaded, "shutdown 後に解放されていない")
        engine.shutdown()   // 二重解放しても落ちないこと

        try await engine.prepare { _, _ in }
        XCTAssertTrue(engine.isLoaded, "再準備できていない")

        let audio = try await AudioExtractor().extract(url: url)
        let head = Array(audio.samples.prefix(Int(AudioExtractor.sampleRate * 20)))
        let segs = try await engine.transcribe(ASRRequest(samples: head, language: "ja"),
                                               progress: { _ in }, isCancelled: { false })
        XCTAssertFalse(segs.isEmpty, "解放→再準備のあと認識できていない")
        engine.shutdown()
    }

    /// Foundation Models が実際に呼べて、ゲートが実モデルの出力に対して機能するか。
    func testFoundationModelsCorrectionOnRealSegments() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26 以降が必要") }
        let corrector = FoundationModelsCorrector()
        let availability = await corrector.isAvailable()
        guard availability.isAvailable else {
            throw XCTSkip("Foundation Models が利用不可: \(availability.reason ?? "")")
        }

        // 実際の説明会で出てきた文と、ASRが起こしがちな誤りを混ぜたもの
        let segments = [
            Segment(start: 0, end: 4, original: "本日はお集まりいただきましてありがとうございます"),
            Segment(start: 4, end: 8, original: "機構変動への対応が事業の軸になっています"),
            Segment(start: 8, end: 12, original: "シュウショク活動の講座を担当することになりました"),
            Segment(start: 12, end: 16, original: "株式会社新小物という会社になります"),
        ]
        let dict = UserDictionary(entries: [])
        let c = Corrector(engine: corrector,
                          gate: EditGate(policy: .init(), dictionary: dict),
                          dictionary: dict,
                          requireAgreement: true)
        let (out, stat) = await c.run(on: segments)

        print("""
        --- 実モデル校正 ---
        提案 : \(stat.proposed) / 採用 : \(stat.accepted) / 棄却 : \(stat.rejected)
        """)
        for (i, s) in out.enumerated() where s.text != segments[i].original {
            print("  \(segments[i].original) → \(s.text)")
        }

        XCTAssertGreaterThan(stat.proposed, 0, "実モデルから提案が1件も返っていない")

        // 社名は読みが違うので、辞書が無い限り絶対に書き換わってはいけない
        XCTAssertEqual(out[3].text, "株式会社新小物という会社になります",
                       "辞書に無い固有名詞が書き換えられた")

        // 採用されたものは全てゲートを通っているはず＝読みが保存されている
        for s in out where s.correction?.rule == .languageModel {
            XCTAssertEqual(Reading.key(s.original), Reading.key(s.corrected),
                           "ゲートを通ったのに読みが変わっている: \(s.original) → \(s.corrected)")
        }
    }
}

/// キャンセル監視がパイプラインとネイティブASRコンテキストを保持し続けないこと。
/// 以前は150ms間隔の監視Taskが終了せず、テスト終了時まで whisper_context が残って
/// ggml Metal の静的デストラクタでアサートしていた。
final class PipelineLifetimeTests: XCTestCase {
    func testFailedRunReleasesPipelineWithoutBackgroundPollingTask() async throws {
        let weakBox = WeakPipelineBox()
        do {
            let pipeline = TranscriptionPipeline(engine: LifetimeProbeEngine(), corrector: nil)
            weakBox.value = pipeline
            do {
                let missing = FileManager.default.temporaryDirectory
                    .appendingPathComponent("utsushi-missing-\(UUID().uuidString).m4a")
                _ = try await pipeline.run(
                    url: missing,
                    onProgress: { _ in })
                XCTFail("存在しない入力で成功してはいけない")
            } catch {
                // 入力エラーはこのテストの前提。見たいのは失敗後の所有関係。
            }
        }

        for _ in 0..<10 where weakBox.value != nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(weakBox.value,
                     "終了したキャンセル監視がパイプラインとASRコンテキストを保持している")
    }
}

private final class WeakPipelineBox: @unchecked Sendable {
    weak var value: TranscriptionPipeline?
}

private final class LifetimeProbeEngine: ASREngine, @unchecked Sendable {
    let identifier = "lifetime-probe"
    let displayName = "lifetime-probe"
    let supportsVAD = false
    let exposesConfidence = false
    let supportsVocabularyHint = false

    func prepare(progress: @escaping @Sendable (String, Double) -> Void) async throws {
        progress("準備完了", 1)
    }

    func transcribe(_ request: ASRRequest,
                    progress: @escaping @Sendable (Double) -> Void,
                    isCancelled: @escaping @Sendable () -> Bool) async throws -> [Segment] {
        []
    }
}
