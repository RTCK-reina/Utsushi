import XCTest
import FoundationModels

/// 実モデルで「全エンジンが同じ誤り方をした語」を拾えるか。
///
/// 単体テストはゲートの振る舞いしか見ていない。
/// **モデルが実際に「気象」を怪しいと言えるか**はここでしか分からない。
///
///     script/build_and_run.sh test
///     # または
///     xcodebuild ... -only-testing:UtsushiTests/PlausibilityRealModelTests test
///
/// Apple Intelligence が使えない環境（メモリ逼迫を含む）では skip する。
/// 実際、この機能を書いた時点では別プロセスが13GB保持していて
/// `CriticalMemoryPressure` でモデルが起動せず、**実データでの確認ができていない。**
@available(macOS 26.0, *)
final class PlausibilityRealModelTests: XCTestCase {

    /// 実データの本文そのまま。「気象」は「期初」、「一気通関」は「一気通貫」。
    /// どちらも4エンジンすべてが同じ誤り方をしていて、照合では拾えなかった。
    private let lines = [
        "コンピテンシーに則って評価を行っていきますというところです。",
        "大体気象の目標を3月から4月ぐらいに立てまして、中期の振り返りを行いつつ、2月が期末の振り返りというところになっていて、",
        "自己評価と上長評価をそれぞれ人事の方に提出いただきます。",
        "当社は結構一気通関で横のつながりも実際にあったりはするので、",
        "はい、では一旦休憩挟みます。",
    ]

    private func requireModel() throws {
        guard case .available = SystemLanguageModel.default.availability else {
            throw XCTSkip("Apple Intelligence が利用できない（メモリ逼迫でも起きる）")
        }
    }

    func testCatchesTheErrorEveryEngineAgreedOn() async throws {
        try requireModel()
        let segments = lines.enumerated().map {
            Segment(start: Double($0.offset * 10), end: Double($0.offset * 10 + 10),
                    original: $0.element)
        }
        let (flags, stat) = await PlausibilityAuditor(
            checker: FoundationModelsPlausibility()).run(on: segments)

        print("[plausibility] 提案\(stat.proposed) / 採用\(stat.accepted) / "
              + "ゲート棄却\(stat.rejectedByGate) / 候補だけ棄却\(stat.alternativesDropped) / "
              + "2回目に出ず\(stat.droppedForDisagreement) / **エラー\(stat.errors)**")
        // **「モデルが動かなかった」と「動いて外した」は分ける。**
        // 両方とも結果は0件で同じ形になるので、区別しないと
        // 環境の問題を製品の問題として読んでしまう（実際に一度読み違えた）。
        if stat.errors > 0 {
            throw XCTSkip("モデルが起動しなかったので判定できない: " + (stat.lastError ?? "理由不明"))
        }
        for f in flags {
            print("  「\(f.surface)」→" + (f.alternative.map { "「\($0)」" } ?? "（候補なし）"))
        }

        // ゲートを通ったものは必ず本文に実在する。ここが崩れると
        // 存在しない語についての注意書きが本文の横に並ぶ。
        for f in flags {
            XCTAssertTrue(lines.contains { $0.contains(f.surface) },
                          "本文に無い語が通った: 「\(f.surface)」")
        }

        // **本命は「語を拾えるか」であって「正しい語を言えるか」ではない。**
        //
        // 実測でモデルの能力は非対称だと分かっている:
        // 「気象」は3回とも安定して指摘できるのに、代わりの語は
        // 「境界」「気温」「目標」と毎回外し、読みを与えても正解に届かない。
        // 候補まで要求すると、**このモデルでは原理的に通らないテスト**になる。
        // 通らないテストを置いておくと、いつか期待値の方を緩めることになる。
        let caught = flags.contains { $0.surface.contains("気象") || $0.surface.contains("通関") }
        XCTAssertTrue(caught,
                      "全エンジン共通の誤りを1件も拾えていない。"
                      + "拾えた指摘: " + flags.map { "「\($0.surface)」" }.joined())
    }

    /// **出た候補は必ず音が近い。** ゲートが実モデル相手に効いているかを見る。
    /// 単体テストは作り物の入力しか通していないので、
    /// 実際に返ってくる「目標」「気温」のような候補を止められるかはここでしか分からない。
    func testSurvivingAlternativesAreAlwaysPhoneticallyClose() async throws {
        try requireModel()
        let segments = lines.enumerated().map {
            Segment(start: Double($0.offset * 10), end: Double($0.offset * 10 + 10),
                    original: $0.element)
        }
        let (flags, stat) = await PlausibilityAuditor(
            checker: FoundationModelsPlausibility()).run(on: segments)
        if stat.errors > 0 {
            throw XCTSkip("モデルが起動しなかったので判定できない: " + (stat.lastError ?? "理由不明"))
        }
        let gate = PlausibilityGate()
        for f in flags {
            guard let alt = f.alternative else { continue }
            XCTAssertEqual(gate.readingProximity(f.surface, alt), .close,
                           "音の遠い候補が読み手に届いている: 「\(f.surface)」→「\(alt)」")
        }
    }

    /// 誤りの無い本文でも指摘は出る。**それを消せるふりをしない。**
    ///
    /// 2段目は候補から必ず1つ選ぶ。「どれも問題ない」という逃げ道を与えても
    /// 実測では使わず、誤りの無い本文でも別の語を選んだ。
    /// つまりこの仕組みがやっているのは**有無の判定ではなく順位付け**である。
    ///
    /// ここで固定するのは「騒がしくならないこと」——塊あたり1件までに収まること。
    /// 0件を期待値にすると、モデルの性質と食い違うので、いつか期待値の方を緩めることになる。
    func testStaysQuietEnoughOnCleanText() async throws {
        try requireModel()
        let clean = ["本日はお集まりいただきありがとうございます。",
                     "議題は来年度の採用計画についてです。",
                     "資料は事前に共有したとおりです。"]
        let segments = clean.enumerated().map {
            Segment(start: Double($0.offset * 10), end: Double($0.offset * 10 + 10),
                    original: $0.element)
        }
        let (flags, stat) = await PlausibilityAuditor(
            checker: FoundationModelsPlausibility()).run(on: segments)
        if stat.errors > 0 {
            throw XCTSkip("モデルが起動しなかったので判定できない: " + (stat.lastError ?? "理由不明"))
        }
        print("[plausibility clean] " + flags.map {
            "「\($0.surface)」→" + ($0.alternative.map { a in "「\(a)」" } ?? "（候補なし）")
        }.joined(separator: " / "))
        XCTAssertLessThanOrEqual(flags.count, 1,
                                 "誤りの無い本文に指摘を作りすぎている: "
                                 + flags.map { "「\($0.surface)」" }.joined())
    }
}
