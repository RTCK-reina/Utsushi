import XCTest

/// LLM を切っても、決定論ルールと辞書は効くこと。
///
/// 以前は `enableCorrection` ひとつで校正の段ごと止めていたので、
/// **LLM を切ると辞書まで止まっていた**。Apple Intelligence が使えない環境でも
/// 同じことが起きていて、README の「無効でも検証層は全機能動く」と食い違っていた。
///
/// 実測で LLM 校正の採用が 22件中1件（読点の挿入）と分かり、切る判断が現実的に
/// なったので、切ったときに何が残るかをここで固定する。
final class CorrectionWithoutLLMTests: XCTestCase {

    private static let clipURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/testclip.m4a")
    }()

    private func run(useLanguageModel: Bool) async throws -> Transcript {
        guard FileManager.default.fileExists(atPath: Self.clipURL.path) else {
            throw XCTSkip("検証用クリップが無い")
        }
        var config = TranscriptionPipeline.Configuration()
        config.enableCorrection = true
        config.useLanguageModel = useLanguageModel
        config.autoRepair = false
        config.enablePlausibilityCheck = false
        var dict = UserDictionary.empty
        dict.entries = [.init(surface: "上長評価", reading: "じょうちょうひょうか",
                              misspellings: ["冗長評価"])]
        config.dictionary = dict
        // corrector は渡さない。LLM が無い環境と同じ条件にする。
        let pipeline = TranscriptionPipeline(engine: FixedEngine(), corrector: nil, config: config)
        return try await pipeline.run(url: Self.clipURL) { _ in }
    }

    func testDictionaryStillAppliesWithoutLanguageModel() async throws {
        let t = try await run(useLanguageModel: false)
        let body = t.segments.map(\.text).joined()
        XCTAssertTrue(body.contains("上長評価"),
                      "LLMを切ると辞書まで止まっている: \(body)")
        XCTAssertFalse(body.contains("冗長評価"), "辞書の誤記が残っている")
    }

    func testFillerRemovalStillAppliesWithoutLanguageModel() async throws {
        let t = try await run(useLanguageModel: false)
        let body = t.segments.map(\.text).joined()
        XCTAssertFalse(body.contains("あのー"), "フィラー除去が効いていない: \(body)")
    }

    /// 原文は触らない。破棄でも書き換えでもなく、`corrected` にだけ入る。
    func testOriginalIsPreserved() async throws {
        let t = try await run(useLanguageModel: false)
        XCTAssertTrue(t.segments.contains { $0.original.contains("冗長評価") },
                      "原文が書き換わっている")
    }

    /// LLM の有無は記録に残る。動いていないものを動いた扱いにしない。
    func testOutcomeDistinguishesRuleFromLanguageModel() async throws {
        let t = try await run(useLanguageModel: false)
        let rules = t.segments.compactMap { $0.correction?.rule }
        XCTAssertFalse(rules.contains(.languageModel), "LLMを切ったのに言語モデル由来の修正がある")
        XCTAssertTrue(rules.contains(.dictionary) || rules.contains(.fillerRemoval),
                      "決定論由来の修正が1件も無い: \(rules)")
    }
}

/// 決まった本文を返す偽エンジン。辞書とフィラーの対象を必ず含める。
private final class FixedEngine: ASREngine, @unchecked Sendable {
    let identifier = "fixed"
    let displayName = "fixed"
    let supportsVAD = false
    let exposesConfidence = false
    let supportsVocabularyHint = false

    func prepare(progress: @escaping @Sendable (String, Double) -> Void) async throws {
        progress("準備完了", 1)
    }

    func transcribe(_ request: ASRRequest,
                    progress: @escaping @Sendable (Double) -> Void,
                    isCancelled: @escaping @Sendable () -> Bool) async throws -> [Segment] {
        [Segment(start: 0, end: 6, original: "自己評価と冗長評価をそれぞれ人事の方に提出いただきます"),
         Segment(start: 6, end: 12, original: "あのー ラウンドテーブルということで")]
    }
}
