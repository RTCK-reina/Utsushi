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

    func testAppleJoinsCrossCheckWhenPrimaryIsWhisper() {
        var s = SessionSettings()
        s.engineChoice = .whisper
        s.crossCheckModelIDs = [ModelCatalog.appleModel.id, ModelCatalog.sherpaModels[0].id]
        let ids = s.crossCheckModels.map(\.id)
        XCTAssertTrue(ids.contains(ModelCatalog.appleModel.id))
        XCTAssertEqual(ids.count, 2)
    }

    /// 一次認識と同じエンジンを照合に使っても、同じ誤りが返るだけで食い違いが出ない。
    /// 選ばれたままでも外す。**時間だけ倍かかって収穫が無い**のを防ぐ。
    func testAppleIsDroppedFromCrossCheckWhenItIsAlsoThePrimaryEngine() {
        var s = SessionSettings()
        s.engineChoice = .apple
        s.crossCheckModelIDs = [ModelCatalog.appleModel.id, ModelCatalog.sherpaModels[0].id]
        let ids = s.crossCheckModels.map(\.id)
        XCTAssertFalse(ids.contains(ModelCatalog.appleModel.id),
                       "一次認識と同じエンジンが照合にも入っている")
        XCTAssertEqual(ids, [ModelCatalog.sherpaModels[0].id])
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
