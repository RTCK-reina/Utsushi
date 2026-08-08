import XCTest

/// 表記の正規化と、照合での「表記だけの違い」の分類。
///
/// 実データで食い違い380件のうち相当数が「三月 / 3月」だった。
/// 認識の誤りではないものが一覧の大半を占めると、見るべき食い違いが埋もれる。
final class NotationTests: XCTestCase {

    func testKanjiAndArabicBecomeTheSame() {
        XCTAssertEqual(Notation.canonicalNumbers("三月"), Notation.canonicalNumbers("3月"))
        XCTAssertEqual(Notation.canonicalNumbers("十二件"), Notation.canonicalNumbers("12件"))
        XCTAssertEqual(Notation.canonicalNumbers("百二十"), Notation.canonicalNumbers("120"))
        XCTAssertEqual(Notation.canonicalNumbers("一万五千"), Notation.canonicalNumbers("15000"))
        // 全角と半角、先頭の 0
        XCTAssertEqual(Notation.canonicalNumbers("１０時"), Notation.canonicalNumbers("10時"))
        XCTAssertEqual(Notation.canonicalNumbers("07月"), Notation.canonicalNumbers("7月"))
    }

    func testUnparsableKanjiSurvives() {
        // 解釈できない並びを落とすと文字が消え、別の食い違いに化ける。
        XCTAssertEqual(Notation.canonicalNumbers("万々歳"), "万々歳")
        XCTAssertTrue(Notation.canonicalNumbers("十人十色").contains("色"))
    }

    func testDifferentNumbersStayDifferent() {
        XCTAssertNotEqual(Notation.canonicalNumbers("三月"), Notation.canonicalNumbers("4月"))
        XCTAssertNotEqual(Notation.comparisonKey("120件"), Notation.comparisonKey("12件"))
    }

    func testComparisonKeyDropsPunctuationAndWidth() {
        XCTAssertEqual(Notation.comparisonKey("AI、導入"), Notation.comparisonKey("ＡＩ 導入"))
        XCTAssertEqual(Notation.comparisonKey("Utsushi"), Notation.comparisonKey("utsushi"))
    }

    /// 語が違えば、表記をそろえても違いは残る。
    func testWordChoiceIsNotFoldedAway() {
        XCTAssertNotEqual(Notation.comparisonKey("承認"), Notation.comparisonKey("却下"))
        XCTAssertNotEqual(Notation.comparisonKey("機構"), Notation.comparisonKey("気候"))
    }

    // MARK: - 照合での分類

    private func seg(_ start: Double, _ end: Double, _ text: String) -> Segment {
        Segment(start: start, end: end, original: text)
    }

    func testNotationDifferenceIsClassifiedNotDropped() {
        let a = TranscriptAlignment.Run(engine: "zipformer",
                                        segments: [seg(0, 5, "三月から四月ぐらいに評価を行います")])
        let b = TranscriptAlignment.Run(engine: "parakeet",
                                        segments: [seg(0, 5, "3月から4月ぐらいに評価を行います")])
        let out = TranscriptAlignment.compare([a, b])

        // 捨てない。件数は数えられる状態で残す。
        XCTAssertFalse(out.isEmpty, "表記の違いが記録から消えている")
        XCTAssertTrue(out.allSatisfy { $0.kind == .notation },
                      "表記だけの違いが中身の違いとして数えられている: "
                      + out.map { $0.candidates.map(\.text).joined(separator: "|") }.joined(separator: " , "))
    }

    func testRealDifferenceIsStillSubstantive() {
        let a = TranscriptAlignment.Run(engine: "whisper",
                                        segments: [seg(0, 5, "予算を承認しました")])
        let b = TranscriptAlignment.Run(engine: "parakeet",
                                        segments: [seg(0, 5, "予算を却下しました")])
        let out = TranscriptAlignment.compare([a, b])
        XCTAssertTrue(out.contains { $0.kind == .substantive },
                      "語の違いが表記の違いに分類されている")
    }

    /// 表記をそろえると意味の差まで消える組み合わせ。
    /// **見えなくするのは構わないが、記録から消してはいけない**ことを固定する。
    func testAmbiguousNotationCaseIsStillRecorded() {
        let a = TranscriptAlignment.Run(engine: "whisper", segments: [seg(0, 5, "十分に議論した")])
        let b = TranscriptAlignment.Run(engine: "parakeet", segments: [seg(0, 5, "10分に議論した")])
        let out = TranscriptAlignment.compare([a, b])
        XCTAssertFalse(out.isEmpty, "「十分」と「10分」の食い違いが記録ごと消えている")
    }

    /// 判定は表記の違いをモデルに投げない。投げても答えようがなく、時間だけ食う。
    func testAdjudicatorSkipsNotationOnly() async {
        let d = TranscriptAlignment.Disagreement(
            start: 0, end: 5,
            candidates: [.init(engine: "a", text: "三月"), .init(engine: "b", text: "3月")],
            readingsMatch: true, context: "", kind: .notation)
        let judge = CountingJudge()
        let (adj, stat) = await Adjudicator(judge: judge).run(on: [d])
        XCTAssertEqual(judge.calls, 0, "表記だけの違いをモデルに投げている")
        XCTAssertEqual(stat.notationOnly, 1)
        XCTAssertEqual(adj.count, 1, "記録そのものは残す")
    }
}

/// 呼ばれた回数を数えるだけの判定役。
private final class CountingJudge: DisagreementJudge, @unchecked Sendable {
    var displayName: String { "counting" }
    private(set) var calls = 0
    func isAvailable() async -> CorrectionAvailability { .available }
    func judge(_ d: TranscriptAlignment.Disagreement) async throws -> Int? {
        calls += 1
        return 0
    }
}
