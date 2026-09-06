import XCTest

/// OS内蔵の SpeechTranscriber を照合の相手として使えること。
///
/// 実測（57分・作手小学校）で足す判断をした:
///   - 30秒（115倍速）で完走し、反復ループが 0%。照合3本 137秒に対して +22% で済む
///   - 本文の一致率は whisper 0.655 / sherpa平均 0.622。どちらの系統にも偏らない
///     （参考: SenseVoice と Parakeet は 0.762 で、既存同士の方が似ている）
///   - ただし固有名詞が崩れやすく、語彙ヒントに非対応。一次認識ではなく照合向き
final class AppleCrossCheckTests: XCTestCase {

    func testAppleIsOfferedAsCrossCheckCandidate() {
        XCTAssertTrue(ModelCatalog.crossCheckCandidates.contains { $0.engine == .appleSpeechAnalyzer },
                      "照合の選択肢に OS内蔵エンジンが無い")
        // 系統が違うものだけを並べる場所なので、whisper は入らない。
        XCTAssertFalse(ModelCatalog.crossCheckCandidates.contains { $0.engine == .whisper })
    }

    /// OS内蔵は取得するファイルが無い。**ダウンロード定義の一覧には入れない。**
    /// 入れると「ファイルが定義されていないモデル」として配布定義の検証が落ちる。
    func testAppleIsNotInTheDownloadCatalog() {
        XCTAssertFalse(ModelCatalog.allModels.contains { $0.engine == .appleSpeechAnalyzer },
                       "取得対象の一覧に OS内蔵エンジンが混ざっている")
        XCTAssertTrue(ModelCatalog.appleModel.items.isEmpty)
        XCTAssertEqual(ModelCatalog.appleModel.approximateBytes, 0)
    }

    /// 未取得のまま「使えない」と判定すると、選んでも黙って照合が走らない。
    func testAppleCountsAsInstalledWithoutDownloading() {
        XCTAssertTrue(ModelCatalog.isInstalled(ModelCatalog.appleModel))
    }

    func testAppleJoinsCrossCheckInQualityMode() {
        var s = SessionSettings()
        s.crossCheckModelIDs = [ModelCatalog.appleModel.id, ModelCatalog.sherpaModels[0].id]
        let c = s.makeConfiguration(dictionary: .empty, hasCorrector: false, hasJudge: false,
                                    mode: .quality)
        XCTAssertEqual(Set(c.crossCheckEngines.map(\.id)),
                       [ModelCatalog.appleModel.id, ModelCatalog.sherpaModels[0].id])
    }

    /// 高速は「下書きを一気に見る」ための押しかた。照合も言語モデルも使わない。
    /// **選ばれたままでも走らせない。**速さの意味が無くなるため。
    func testFastModeSkipsCrossCheckAndLanguageModel() {
        var s = SessionSettings()
        s.crossCheckModelIDs = [ModelCatalog.appleModel.id, ModelCatalog.sherpaModels[0].id]
        s.enableCorrection = true
        s.enableSummary = true
        let c = s.makeConfiguration(dictionary: .empty, hasCorrector: true, hasJudge: true,
                                    hasSummarizer: true, mode: .fast)
        XCTAssertTrue(c.crossCheckEngines.isEmpty, "高速なのに照合が走る")
        XCTAssertFalse(c.useLanguageModel, "高速なのに言語モデルを使う")
        XCTAssertFalse(c.enableSummary, "高速なのに要約が走る")
        XCTAssertEqual(c.mode, .fast)
        // 監査と辞書は落とさない。速い代わりに幻聴が残る書き出しは意味が無い。
        XCTAssertTrue(c.enableCorrection, "決定論ルールと辞書まで止めている")
        XCTAssertTrue(c.autoRepair, "取りこぼしの読み直しまで止めている")
    }

    /// 設定に残った ID が消えないこと。OS内蔵は候補に含まれるので落ちてはいけない。
    func testDropUnknownModelsKeepsApple() {
        var s = SessionSettings()
        s.crossCheckModelIDs = [ModelCatalog.appleModel.id, "存在しないモデル"]
        s.dropUnknownModels()
        XCTAssertEqual(s.crossCheckModelIDs, [ModelCatalog.appleModel.id])
    }

    /// 選んでも追加のダウンロードが発生しないこと。
    func testSelectingAppleAddsNoDownloadWeight() {
        var s = SessionSettings()
        s.crossCheckModelIDs = [ModelCatalog.appleModel.id]
        let pending = ModelCatalog.crossCheckCandidates
            .filter { s.crossCheckModelIDs.contains($0.id) && !ModelCatalog.isInstalled($0) }
            .reduce(0) { $0 + $1.approximateBytes }
        XCTAssertEqual(pending, 0)
    }
}
