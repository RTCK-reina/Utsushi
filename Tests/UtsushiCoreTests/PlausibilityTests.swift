import XCTest

/// 文脈による誤り検出のゲート。
///
/// 照合はエンジン間の不一致しか見ないので、全エンジンが同じ誤り方をした箇所
/// （実データの「期初」→「気象」）を素通りする。そこを埋めるための仕組みで、
/// **モデルに本文を書かせない**という原則は変えていない。
///
/// 判定は2段になっている。実モデルの能力が非対称だったため:
/// **どの語が浮いているかは当てられるが、その語が本来何かは当てられない。**
/// 両方を同じ扱いにすると、当てられる方まで一緒に捨てることになる。
final class PlausibilityGateTests: XCTestCase {

    private let lines = [
        "大体気象の目標を3月から4月ぐらいに立てまして、",
        "当社は結構一気通関で横のつながりもあったりはするので、",
        "はい、では一旦休憩挟みます。",
    ]

    private func draft(_ line: Int, _ surface: String, _ alt: String = "") -> PlausibilityDraft {
        PlausibilityDraft(lineNumber: line, surface: surface, alternative: alt)
    }

    // MARK: - 1段目: 指摘そのものの採否

    /// 拾いたい本命。実データで全4エンジンが取り違えていた箇所。
    /// 候補まで正しく出せた場合は、候補も一緒に通す。
    func testAcceptsHomophoneErrorEveryEngineGotWrong() {
        let a = PlausibilityGate().judge(draft(1, "気象", "期初"), lines: lines)
        XCTAssertTrue(a.isAccepted)
        XCTAssertTrue(a.keepsAlternative, "きしょう/きしょ は音が近い。候補として通すべき")

        let b = PlausibilityGate().judge(draft(2, "一気通関", "一気通貫"), lines: lines)
        XCTAssertTrue(b.isAccepted)
        XCTAssertTrue(b.keepsAlternative, "同音。候補として通すべき")
    }

    /// **本文に無い語を指摘できない。** ここを許すと、存在しない語についての
    /// 注意書きが本文の横に並ぶ。
    func testRejectsWordThatIsNotInTheLine() {
        XCTAssertEqual(PlausibilityGate().judge(draft(1, "決算", "決済"), lines: lines).rejection,
                       .surfaceNotInLine)
    }

    /// 行番号の捏造も落とす。
    func testRejectsNonexistentLine() {
        XCTAssertEqual(PlausibilityGate().judge(draft(99, "気象", "期初"), lines: lines).rejection,
                       .lineOutOfRange)
        XCTAssertEqual(PlausibilityGate().judge(draft(0, "気象", "期初"), lines: lines).rejection,
                       .lineOutOfRange)
    }

    /// 文まるごとの指摘は落とす。語の指摘だけを受け付ける。
    func testRejectsWholeClauseFlag() {
        XCTAssertEqual(
            PlausibilityGate().judge(
                draft(1, "大体気象の目標を3月から4月ぐらいに立てまして", "期初の目標を立てます"),
                lines: lines).rejection,
            .badLength)
    }

    /// 助詞・語尾の指摘は受け付けない。読み手にできることが無い。
    func testRejectsParticleOnlyFlag() {
        XCTAssertEqual(PlausibilityGate().judge(draft(3, "では", "でわ"), lines: lines).rejection,
                       .notAContentWord)
    }

    // MARK: - 2段目: 候補だけを落とす

    /// **ここが今回の中核。** 候補が使えなくても、指摘そのものは残す。
    /// 実モデルは「気象」を安定して指摘できるのに、候補は「目標」「気温」「境界」と
    /// 毎回外す。候補を理由に指摘ごと捨てると、当てられている情報まで消える。
    func testKeepsTheFlagWhenOnlyTheAlternativeIsBad() {
        let cases: [(String, PlausibilityGate.Rejection)] = [
            ("目標", .readingTooFar),      // もくひょう。音が近くない
            ("気温", .readingTooFar),      // きおん
            ("KPI",  .inventedLatin),      // 元に無い英字の創作
            ("気象", .unchanged),          // 同じ語
            ("",     .badLength),          // 候補を出さなかった
        ]
        for (alt, expected) in cases {
            let v = PlausibilityGate().judge(draft(1, "気象", alt), lines: lines)
            XCTAssertTrue(v.isAccepted, "「\(alt)」で指摘ごと落ちている")
            XCTAssertFalse(v.keepsAlternative, "「\(alt)」が候補として通っている")
            XCTAssertEqual(v.alternativeRejection, expected)
        }
    }

    /// 読みの近さの境界。**一致ではなく近さ**を見ている。
    /// 一致を要求すると「気象（きしょう）→期初（きしょ）」という一番拾いたい形が落ちる。
    func testReadingProximity() {
        let g = PlausibilityGate()
        XCTAssertEqual(g.readingProximity("気象", "期初"), .close)
        XCTAssertEqual(g.readingProximity("一気通関", "一気通貫"), .close)
        XCTAssertEqual(g.readingProximity("機構", "気候"), .close, "同音")
        XCTAssertEqual(g.readingProximity("気象", "目標"), .far)
        XCTAssertEqual(g.readingProximity("気象", "気温"), .far)
        XCTAssertEqual(g.readingProximity("気象", "境界"), .far)
    }
}

/// 指摘を集める司令塔の振る舞い。
final class PlausibilityAuditorTests: XCTestCase {

    private func seg(_ start: Double, _ text: String) -> Segment {
        Segment(start: start, end: start + 10, original: text)
    }

    private var segments: [Segment] {
        [seg(0, "大体気象の目標を3月から4月ぐらいに立てまして、"),
         seg(10, "当社は結構一気通関で横のつながりもあったりはするので、")]
    }

    func testAcceptedFlagPointsAtTheRightSegment() async {
        let checker = ScriptedChecker(rounds: [
            [PlausibilityDraft(lineNumber: 2, surface: "一気通関", alternative: "一気通貫")],
            [PlausibilityDraft(lineNumber: 2, surface: "一気通関", alternative: "一気通貫")],
        ])
        let (flags, stat) = await PlausibilityAuditor(checker: checker).run(on: segments)
        XCTAssertEqual(flags.count, 1)
        XCTAssertEqual(flags.first?.start, 10, "指摘が別のセグメントに付いている")
        XCTAssertEqual(flags.first?.alternative, "一気通貫")
        XCTAssertEqual(stat.accepted, 1)
    }

    /// **候補が外れていても指摘は残る。** 実モデルで起きるのはこの形。
    func testFlagSurvivesWithoutUsableAlternative() async {
        let bad = PlausibilityDraft(lineNumber: 1, surface: "気象", alternative: "目標")
        let checker = ScriptedChecker(rounds: [[bad], [bad]])
        let (flags, stat) = await PlausibilityAuditor(checker: checker).run(on: segments)
        XCTAssertEqual(flags.count, 1, "候補が使えないだけで指摘まで消えている")
        XCTAssertEqual(flags.first?.surface, "気象")
        XCTAssertNil(flags.first?.alternative, "音の遠い候補が読み手に見えている")
        XCTAssertEqual(stat.alternativesDropped, 1, "候補を落としたことが記録されていない")
        XCTAssertEqual(stat.rejectedByGate, 0)
    }

    /// 2回の一致は**語だけ**で見る。候補は毎回違うものが返るので、
    /// 候補まで一致を求めると安定している指摘まで巻き添えで消える。
    func testAgreementIgnoresTheAlternative() async {
        let checker = ScriptedChecker(rounds: [
            [PlausibilityDraft(lineNumber: 1, surface: "気象", alternative: "目標")],
            [PlausibilityDraft(lineNumber: 1, surface: "気象", alternative: "気温")],
        ])
        let (flags, stat) = await PlausibilityAuditor(checker: checker).run(on: segments)
        XCTAssertEqual(flags.count, 1, "候補が違うだけで指摘が消えている")
        XCTAssertEqual(stat.droppedForDisagreement, 0)
    }

    /// 2回目に語ごと出なかった指摘は捨てる。
    func testDropsFlagsThatDoNotRecur() async {
        let checker = ScriptedChecker(rounds: [
            [PlausibilityDraft(lineNumber: 1, surface: "気象", alternative: "期初")],
            [],
        ])
        let (flags, stat) = await PlausibilityAuditor(checker: checker).run(on: segments)
        XCTAssertTrue(flags.isEmpty)
        XCTAssertEqual(stat.droppedForDisagreement, 1)
    }

    /// ゲートに落ちたものは件数として残る。黙って消えない。
    func testGateRejectionIsCounted() async {
        let fabricated = PlausibilityDraft(lineNumber: 1, surface: "決算", alternative: "決済")
        let checker = ScriptedChecker(rounds: [[fabricated], [fabricated]])
        let (flags, stat) = await PlausibilityAuditor(checker: checker).run(on: segments)
        XCTAssertTrue(flags.isEmpty, "本文に無い語が通っている")
        XCTAssertEqual(stat.rejectedByGate, 1)
    }

    /// 本文は窓に分けて渡す。**全文を1回で渡すと収録全体で指摘が最大1件になる**
    /// （2段目が1件に絞るため）し、2時間分は文脈長を超えて呼び出しごと失敗する。
    /// 窓の中の行番号は窓内で振り、戻すときに元の並びへ足す。
    func testSplitsIntoWindowsAndRemapsLineNumbers() async {
        let segs = [seg(0, "一行目の本文です。"),
                    seg(10, "二行目の本文です。"),
                    seg(20, "大体気象の目標を3月から4月ぐらいに立てまして、"),
                    seg(30, "四行目の本文です。")]
        // 各窓で「1行目」を指摘する。窓2の1行目は元の3行目（気象）。
        let checker = RecordingChecker { text, _ in
            [PlausibilityDraft(lineNumber: 1, surface: text.contains("気象") ? "気象" : "一行目")]
        }
        // 1・2行目で18字、3・4行目で32字。40字の窓なら 2行ずつに割れる。
        let auditor = PlausibilityAuditor(checker: checker, requireAgreement: false,
                                          windowCharacters: 40)
        XCTAssertEqual(auditor.windows(for: segs).map(\.offset), [0, 2])
        let (flags, stat) = await auditor.run(on: segs)
        XCTAssertEqual(stat.windows, 2)
        XCTAssertEqual(checker.calls.count, 2, "窓ごとに1回ずつ呼ばれるはず")
        XCTAssertEqual(checker.calls.map(\.lineCount), [2, 2])
        XCTAssertTrue(checker.calls[1].text.hasPrefix("1. 大体気象"), "窓内の番号は1から振り直す")
        XCTAssertEqual(flags.map(\.start), [0, 20], "窓2の1行目は元の3行目（start=20）に付くべき")
        XCTAssertEqual(flags.map(\.surface), ["一行目", "気象"])
        XCTAssertEqual(stat.rejectedByGate, 0)
    }

    /// 1つの窓が失敗しても他の窓は続ける。失敗は errors に残る。
    func testOneFailingWindowDoesNotAbortTheRest() async {
        let segs = [seg(0, "一行目の本文です。"),
                    seg(10, "大体気象の目標を3月から4月ぐらいに立てまして、")]
        let checker = RecordingChecker { text, _ in
            if text.hasPrefix("1. 一行目") { throw NSError(domain: "test", code: 1) }
            return [PlausibilityDraft(lineNumber: 1, surface: "気象")]
        }
        let auditor = PlausibilityAuditor(checker: checker, requireAgreement: false,
                                          windowCharacters: 10)
        let (flags, stat) = await auditor.run(on: segs)
        XCTAssertEqual(stat.errors, 1)
        XCTAssertEqual(flags.map(\.surface), ["気象"], "失敗した窓のせいで残りの窓の指摘が消えている")
    }

    /// 候補が空のものは「候補だけ落とした」に数えない。数えると、
    /// モデルが候補を出せなかっただけなのにゲートが落としたように見える。
    func testEmptyAlternativeIsNotCountedAsDropped() async {
        let d = PlausibilityDraft(lineNumber: 1, surface: "気象", alternative: "")
        let checker = ScriptedChecker(rounds: [[d], [d]])
        let (flags, stat) = await PlausibilityAuditor(checker: checker).run(on: segments)
        XCTAssertEqual(flags.count, 1)
        XCTAssertNil(flags.first?.alternative)
        XCTAssertEqual(stat.alternativesDropped, 0)
    }

    /// 改行付きで返ってきた語も、ゲートと同じ集合で trim して本文に実在する形で残す。
    /// ここがずれると書き出し側の `segment.text.contains(surface)` が外れて指摘が消える。
    func testSurfaceIsTrimmedWithTheSameRuleAsTheGate() async {
        let a = PlausibilityDraft(lineNumber: 1, surface: "気象\n", alternative: "")
        let b = PlausibilityDraft(lineNumber: 1, surface: "気象", alternative: "")
        let checker = ScriptedChecker(rounds: [[a], [b]])
        let (flags, stat) = await PlausibilityAuditor(checker: checker).run(on: segments)
        XCTAssertEqual(stat.droppedForDisagreement, 0, "改行の有無で別の語と数えている")
        XCTAssertEqual(flags.first?.surface, "気象")
    }

    /// チェッカーが無ければ何もしない。Apple Intelligence が無効な環境で落ちない。
    func testNoCheckerIsNotAnError() async {
        let (flags, stat) = await PlausibilityAuditor(checker: nil).run(on: segments)
        XCTAssertTrue(flags.isEmpty)
        XCTAssertEqual(stat.errors, 0)
    }
}

/// 決まった答えを返すだけのチェッカー。
private final class ScriptedChecker: PlausibilityChecker, @unchecked Sendable {
    var displayName: String { "scripted" }
    private var rounds: [[PlausibilityDraft]]
    private var index = 0
    init(rounds: [[PlausibilityDraft]]) { self.rounds = rounds }
    func isAvailable() async -> CorrectionAvailability { .available }
    func check(numberedText: String, lineCount: Int) async throws -> [PlausibilityDraft] {
        defer { index += 1 }
        return index < rounds.count ? rounds[index] : []
    }
}

/// 呼ばれ方を記録し、渡された関数で答えるチェッカー。
private final class RecordingChecker: PlausibilityChecker, @unchecked Sendable {
    var displayName: String { "recording" }
    private(set) var calls: [(text: String, lineCount: Int)] = []
    private let answer: (String, Int) throws -> [PlausibilityDraft]
    init(_ answer: @escaping (String, Int) throws -> [PlausibilityDraft]) { self.answer = answer }
    func isAvailable() async -> CorrectionAvailability { .available }
    func check(numberedText: String, lineCount: Int) async throws -> [PlausibilityDraft] {
        calls.append((numberedText, lineCount))
        return try answer(numberedText, lineCount)
    }
}
