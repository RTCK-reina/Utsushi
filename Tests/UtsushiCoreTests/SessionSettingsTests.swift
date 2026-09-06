import XCTest

/// 設定がパイプラインまで届くことを確認する。
///
/// 実際に「照合エンジンと判定器を UI では選べるのに Configuration へ渡していない」
/// という不具合を出したので、渡し漏れをここで機械的に落とす。
final class SessionSettingsTests: XCTestCase {

    func testCrossCheckSelectionReachesConfiguration() {
        var s = SessionSettings()
        let target = ModelCatalog.sherpaModels[0]
        s.crossCheckModelIDs = [target.id]
        let c = s.makeConfiguration(dictionary: .empty, hasCorrector: true, hasJudge: true)
        XCTAssertEqual(c.crossCheckEngines.map(\.id), [target.id],
                       "照合に選んだモデルが Configuration に入っていない")
    }

    func testEmptySelectionMeansNoCrossCheck() {
        let s = SessionSettings()
        let c = s.makeConfiguration(dictionary: .empty, hasCorrector: true, hasJudge: true)
        XCTAssertTrue(c.crossCheckEngines.isEmpty)
    }

    /// 判定器が用意できていないのに adjudicate が true のままだと、
    /// 「LLMが判定した」という記録だけが残って中身が無い状態になる
    func testAdjudicationIsOffWhenNoJudge() {
        var s = SessionSettings()
        s.adjudicateDisagreements = true
        let c = s.makeConfiguration(dictionary: .empty, hasCorrector: true, hasJudge: false)
        XCTAssertFalse(c.adjudicateDisagreements)
    }

    /// 用意できていない LLM を「有効」として渡さない。
    /// ただし**校正の段そのものは止めない**。決定論ルールと辞書は LLM 無しでも効く。
    func testLanguageModelIsOffWhenNoCorrector() {
        var s = SessionSettings()
        s.enableCorrection = true
        let c = s.makeConfiguration(dictionary: .empty, hasCorrector: false, hasJudge: true)
        XCTAssertFalse(c.useLanguageModel)
        XCTAssertTrue(c.enableCorrection, "LLMが無いだけで決定論ルールと辞書まで止めてはいけない")
    }

    /// 全フィールドを既定値から変えた設定を作り、Configuration 側に反映されているか総当たりで見る。
    /// 新しい設定を足したときに makeConfiguration へ書き忘れると、ここが落ちる。
    func testEveryNonDefaultSettingIsReflected() {
        var s = SessionSettings()
        s.language = "en"
        s.enableCorrection = false
        s.requireAgreement = false
        s.autoRepair = false
        s.silenceDBFS = -60
        s.crossCheckModelIDs = Set(ModelCatalog.sherpaModels.map(\.id))
        s.adjudicateDisagreements = false
        s.judgeDifferentReadings = false

        var dict = UserDictionary.empty
        dict.entries = [.init(surface: "上長評価", reading: "じょうちょうひょうか", misspellings: [])]

        let c = s.makeConfiguration(dictionary: dict, hasCorrector: true, hasJudge: true)
        XCTAssertEqual(c.language, "en")
        XCTAssertFalse(c.useLanguageModel)
        XCTAssertFalse(c.requireAgreement)
        XCTAssertFalse(c.autoRepair)
        XCTAssertEqual(c.auditPolicy.silenceDBFS, -60)
        XCTAssertEqual(c.crossCheckEngines.count, ModelCatalog.sherpaModels.count)
        XCTAssertFalse(c.adjudicateDisagreements)
        XCTAssertFalse(c.judgeDifferentReadings)
        XCTAssertEqual(c.dictionary.entries.count, 1)
    }

    func testRoundTripsThroughJSON() throws {
        var s = SessionSettings()
        s.engineChoice = .apple
        s.silenceDBFS = -52
        s.crossCheckModelIDs = [ModelCatalog.sherpaModels[0].id]
        s.judgeDifferentReadings = false
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(SessionSettings.self, from: data)
        XCTAssertEqual(s, back)
    }

    /// カタログから消えたモデルIDを持ったまま復元すると、
    /// 「照合するつもりなのに何も起きない」状態になる
    func testUnknownModelIDsAreDropped() {
        var s = SessionSettings()
        s.whisperModelID = "存在しないモデル"
        s.crossCheckModelIDs = ["消えたモデル", ModelCatalog.sherpaModels[0].id]
        s.dropUnknownModels()
        XCTAssertEqual(s.whisperModelID, ModelCatalog.whisperModels[0].id)
        XCTAssertEqual(s.crossCheckModelIDs, [ModelCatalog.sherpaModels[0].id])
    }

    /// 見出しの厳しさは Summarizer.Configuration.gatePolicy の奥にあり、
    /// 設定から届いていなかった。届かないと実測を見ても切り替えられない。
    func testStrictHeadlineSettingReachesTheGate() {
        var s = SessionSettings()
        s.summaryStrictHeadlines = false
        let off = s.makeConfiguration(dictionary: .empty, hasCorrector: true,
                                      hasJudge: true, hasSummarizer: true)
        XCTAssertFalse(off.summaryConfig.gatePolicy.rejectNewKanjiTerms)

        s.summaryStrictHeadlines = true
        let on = s.makeConfiguration(dictionary: .empty, hasCorrector: true,
                                     hasJudge: true, hasSummarizer: true)
        XCTAssertTrue(on.summaryConfig.gatePolicy.rejectNewKanjiTerms)
    }

    /// 標本3件で既定を動かす根拠には足りないので、安全側のまま
    func testStrictHeadlinesAreOnByDefault() {
        XCTAssertTrue(SessionSettings().summaryStrictHeadlines)
    }

    func testDefaultWhisperModelIDExists() {
        let s = SessionSettings()
        XCTAssertEqual(s.whisperModel.id, s.whisperModelID)
    }
}
