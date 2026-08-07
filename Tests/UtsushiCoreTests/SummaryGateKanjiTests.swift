import XCTest

/// 見出しゲートは数値・英数字・カタカナ語しか見ておらず、漢語の内容語が素通りしていた。
/// 「予算を承認」→「予算を却下」が通る状態で、数値の創作より影響が大きい。
final class SummaryGateKanjiTests: XCTestCase {

    private let gate = SummaryGate()

    func testInvertedMeaningIsRejected() {
        let v = gate.evaluate(headline: "予算を却下", source: "来期の予算を承認しました")
        XCTAssertEqual(v, .reject(.newKanjiTerm))
    }

    func testInventedKanjiTermIsRejected() {
        let v = gate.evaluate(headline: "退職金の説明", source: "福利厚生についてご説明します")
        XCTAssertEqual(v, .reject(.newKanjiTerm))
    }

    func testKanjiTermPresentInSourceIsAccepted() {
        let v = gate.evaluate(headline: "予算を承認", source: "来期の予算を承認しました")
        XCTAssertTrue(v.isAccepted)
    }

    /// 1文字の漢字は語として扱わない。助数詞・活用語尾で誤検出すると使い物にならない。
    func testSingleKanjiIsNotATerm() {
        XCTAssertTrue(gate.evaluate(headline: "3件の話", source: "三件ありました").isAccepted)
    }

    /// 漢数字は数値側の担当。ここで漢語として弾くとまともな言い換えが落ちる。
    func testKanjiNumeralsAreNotTreatedAsTerms() {
        XCTAssertTrue(gate.evaluate(headline: "三段階の選考",
                                    source: "選考は三段階で行います").isAccepted)
        XCTAssertTrue(gate.evaluate(headline: "二十名が参加",
                                    source: "二十名の方が参加されました").isAccepted)
    }

    func testKanjiTermExtraction() {
        XCTAssertEqual(SummaryGate.kanjiTerms("予算を承認しました"), ["予算", "承認"])
        XCTAssertEqual(SummaryGate.kanjiTerms("三段階"), ["段階"], "漢数字を語に含めてはいけない")
        XCTAssertTrue(SummaryGate.kanjiTerms("ひらがなだけ").isEmpty)
    }

    /// 厳しくすると言い換えの自由度が下がる。切れることを明示的に固定しておく。
    func testCanBeDisabledWhenParaphraseFreedomMatters() {
        var p = SummaryGate.Policy()
        p.rejectNewKanjiTerms = false
        let loose = SummaryGate(policy: p)
        XCTAssertTrue(loose.evaluate(headline: "予算を却下", source: "来期の予算を承認しました").isAccepted)
    }

    /// より重い違反が先に報告されること（報告の種別がずれると原因追跡が嘘になる）
    func testNumberViolationIsReportedBeforeKanji() {
        let v = gate.evaluate(headline: "退職金は120万円", source: "福利厚生の説明です")
        XCTAssertEqual(v, .reject(.newNumber))
    }
}

/// 棄却理由の内訳が記録されること。理由が分からないと何を締めすぎているか判断できない。
private struct FixedEngine: SummaryEngine {
    let displayName = "fixed"
    let selections: [SummarySelection]
    func isAvailable() async -> CorrectionAvailability { .available }
    func select(from chunk: SummaryChunk, maxPoints: Int) async throws -> [SummarySelection] { selections }
}

final class SummaryRejectionBreakdownTests: XCTestCase {

    private var segments: [Segment] {
        ["来期の予算を承認しました", "参加者はたくさんいました"].enumerated().map { i, text in
            var s = Segment(start: Double(i) * 5, end: Double(i) * 5 + 5, original: text)
            s.corrected = text
            return s
        }
    }

    func testRejectionReasonIsRecorded() async {
        let engine = FixedEngine(selections: [
            .init(lineNumbers: [1], headline: "予算を却下", kind: .decision)
        ])
        let s = await Summarizer(engine: engine).run(on: segments)
        XCTAssertEqual(s.stats.rejectedHeadlineCount, 1)
        XCTAssertEqual(s.stats.headlineRejections["newKanjiTerm"], 1)
        XCTAssertEqual(s.points.first?.headlineSource, .extracted)
    }

    func testAcceptedHeadlineRecordsNoRejection() async {
        let engine = FixedEngine(selections: [
            .init(lineNumbers: [1], headline: "予算を承認", kind: .decision)
        ])
        let s = await Summarizer(engine: engine).run(on: segments)
        XCTAssertTrue(s.stats.headlineRejections.isEmpty)
        XCTAssertEqual(s.points.first?.headlineSource, .model)
        XCTAssertEqual(s.modelHeadlineRatio, 1.0)
    }
}
