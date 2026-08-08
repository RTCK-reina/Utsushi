import XCTest

/// 文脈による誤り検出のゲート。
///
/// 照合はエンジン間の不一致しか見ないので、全エンジンが同じ誤り方をした箇所
/// （実データの「期初」→「気象」）を素通りする。そこを埋めるための仕組みで、
/// **モデルに本文を書かせない**という原則は変えていない。
/// ここで固定するのは「モデルが本文に無い語を指摘できないこと」。
final class PlausibilityGateTests: XCTestCase {

    private let lines = [
        "大体気象の目標を3月から4月ぐらいに立てまして、",
        "当社は結構一気通関で横のつながりもあったりはするので、",
        "はい、では一旦休憩挟みます。",
    ]

    private func draft(_ line: Int, _ surface: String, _ alt: String) -> PlausibilityDraft {
        PlausibilityDraft(lineNumber: line, surface: surface, alternative: alt)
    }

    /// 拾いたい本命。実データで全4エンジンが取り違えていた箇所。
    func testAcceptsHomophoneErrorEveryEngineGotWrong() {
        XCTAssertNil(PlausibilityGate().evaluate(draft(1, "気象", "期初"), lines: lines))
        XCTAssertNil(PlausibilityGate().evaluate(draft(2, "一気通関", "一気通貫"), lines: lines))
    }

    /// **本文に無い語を指摘できない。** ここを許すと、存在しない語についての
    /// 注意書きが本文の横に並ぶ。
    func testRejectsWordThatIsNotInTheLine() {
        XCTAssertEqual(PlausibilityGate().evaluate(draft(1, "決算", "決済"), lines: lines),
                       .surfaceNotInLine)
    }

    /// 行番号の捏造も落とす。
    func testRejectsNonexistentLine() {
        XCTAssertEqual(PlausibilityGate().evaluate(draft(99, "気象", "期初"), lines: lines),
                       .lineOutOfRange)
        XCTAssertEqual(PlausibilityGate().evaluate(draft(0, "気象", "期初"), lines: lines),
                       .lineOutOfRange)
    }

    /// 文まるごとの書き換え提案は落とす。語の指摘だけを受け付ける。
    func testRejectsWholeClauseRewrite() {
        XCTAssertEqual(
            PlausibilityGate().evaluate(
                draft(1, "大体気象の目標を3月から4月ぐらいに立てまして", "期初の目標を立てます"),
                lines: lines),
            .badLength)
    }

    /// 助詞・語尾の指摘は受け付けない。読み手にできることが無い。
    func testRejectsParticleOnlyFlag() {
        XCTAssertEqual(PlausibilityGate().evaluate(draft(3, "では", "でわ"), lines: lines),
                       .notAContentWord)
    }

    /// 元に英字が無いのに英字を持ち込む指摘は、文脈の指摘ではなく創作。
    func testRejectsInventedLatin() {
        XCTAssertEqual(PlausibilityGate().evaluate(draft(1, "気象", "KPI"), lines: lines),
                       .inventedLatin)
    }

    func testRejectsUnchanged() {
        XCTAssertEqual(PlausibilityGate().evaluate(draft(1, "気象", "気象"), lines: lines),
                       .unchanged)
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
        XCTAssertEqual(stat.accepted, 1)
    }

    /// 2回目に出なかった指摘は捨てる。1回だけの指摘はモデルの気まぐれで、
    /// そのまま出すと本文の横が騒がしくなる。
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
