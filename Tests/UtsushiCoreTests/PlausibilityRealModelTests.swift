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
              + "ゲート棄却\(stat.rejectedByGate) / 2回目に出ず\(stat.droppedForDisagreement) "
              + "/ **エラー\(stat.errors)**")
        // **「モデルが動かなかった」と「動いて外した」は分ける。**
        // 両方とも結果は0件で同じ形になるので、区別しないと
        // 環境の問題を製品の問題として読んでしまう（実際に一度読み違えた）。
        //
        // `availability` が .available でも、実際の呼び出しは
        // SensitiveContentAnalysisML の安全ガードレールが
        // CriticalMemoryPressure で拒否することがある。事前チェックでは分からない。
        if stat.errors > 0 {
            throw XCTSkip("モデルが起動しなかったので判定できない: " + (stat.lastError ?? "理由不明"))
        }
        for f in flags { print("  「\(f.surface)」→「\(f.alternative)」") }

        // ゲートを通ったものは必ず本文に実在する。ここが崩れると
        // 存在しない語についての注意書きが本文の横に並ぶ。
        for f in flags {
            XCTAssertTrue(lines.contains { $0.contains(f.surface) },
                          "本文に無い語が通った: 「\(f.surface)」")
        }

        // 本命。どちらか一方でも拾えれば、照合では届かなかった領域に手が届いている。
        let caught = flags.contains { $0.surface.contains("気象") || $0.surface.contains("通関") }
        XCTAssertTrue(caught,
                      "全エンジン共通の誤りを1件も拾えていない。"
                      + "拾えた指摘: " + flags.map { "「\($0.surface)」" }.joined())
    }

    /// 誤りの無い本文に対して指摘を作らないこと。
    /// でっち上げるモデルなら、本文の横が常に騒がしくなって誰も読まなくなる。
    func testDoesNotInventProblemsInCleanText() async throws {
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
        print("[plausibility clean] " + flags.map { "「\($0.surface)」→「\($0.alternative)」" }
            .joined(separator: " / "))
        XCTAssertLessThanOrEqual(flags.count, 1,
                                 "誤りの無い本文に指摘を作りすぎている: "
                                 + flags.map { "「\($0.surface)」" }.joined())
    }
}
