import XCTest

// MARK: - 見出しゲート

/// 要約の見出しは言い換えなので、校正で使っている「読み一致」は使えない。
/// 代わりに「原文に無い情報が現れていないか」だけを見る。
/// ここで固定するのは、その検出が実際に効くことと、
/// まともな言い換えを巻き込んで落とさないこと。
final class SummaryGateTests: XCTestCase {

    private let gate = SummaryGate()

    func testPlainParaphraseIsAccepted() {
        let v = gate.evaluate(headline: "面接の日程について",
                              source: "面接の日程は来週の月曜日に決まりました")
        XCTAssertTrue(v.isAccepted)
    }

    func testInventedNumberIsRejected() {
        let v = gate.evaluate(headline: "参加者は120名",
                              source: "参加者はかなり多くて会場がいっぱいでした")
        XCTAssertEqual(v, .reject(.newNumber))
    }

    func testNumberPresentInSourceIsAccepted() {
        let v = gate.evaluate(headline: "参加者は120名",
                              source: "参加者は120名でした")
        XCTAssertTrue(v.isAccepted)
    }

    /// 「三件」と「3件」を別物として落とすと、まともな見出しがほとんど通らなくなる
    func testKanjiAndArabicDigitsAreTreatedAsSame() {
        let v = gate.evaluate(headline: "3件の指摘", source: "三件の指摘がありました")
        XCTAssertTrue(v.isAccepted)
    }

    func testFullWidthDigitsAreTreatedAsSame() {
        let v = gate.evaluate(headline: "５件", source: "5件ありました")
        XCTAssertTrue(v.isAccepted)
    }

    /// 位取りのある漢数字も同じ値として扱う。
    /// ここが効かないと「二十名」を「20名」と書いた見出しが全部落ちる。
    func testKanjiNumberWithUnitsMatchesArabic() {
        XCTAssertTrue(gate.evaluate(headline: "20名が参加", source: "二十名が参加しました").isAccepted)
        XCTAssertTrue(gate.evaluate(headline: "120名", source: "百二十名でした").isAccepted)
        XCTAssertTrue(gate.evaluate(headline: "1500円", source: "千五百円です").isAccepted)
    }

    func testKanjiNumberParsing() {
        XCTAssertEqual(SummaryGate.parseKanjiNumber("十五"), 15)
        XCTAssertEqual(SummaryGate.parseKanjiNumber("二十"), 20)
        XCTAssertEqual(SummaryGate.parseKanjiNumber("百二十"), 120)
        XCTAssertEqual(SummaryGate.parseKanjiNumber("千五百"), 1500)
        XCTAssertEqual(SummaryGate.parseKanjiNumber("三万五千"), 35000)
        XCTAssertEqual(SummaryGate.parseKanjiNumber("一億"), 100_000_000)
        // 位取りが無い並びは桁の連結として読む（〇八〇＝080）
        XCTAssertEqual(SummaryGate.parseKanjiNumber("〇八〇"), 80)
        XCTAssertEqual(SummaryGate.parseKanjiNumber("三"), 3)
    }

    /// 数値の創作は「英数字トークンの創作」ではなく数値として報告されるべき。
    /// 報告の種別がずれると、あとで原因を追うときに嘘の手掛かりになる。
    func testDigitOnlyTokenIsReportedAsNumberNotLatin() {
        let v = gate.evaluate(headline: "120名が参加", source: "たくさんの方が参加しました")
        XCTAssertEqual(v, .reject(.newNumber))
    }

    func testInventedLatinTokenIsRejected() {
        let v = gate.evaluate(headline: "Slackで連絡する",
                              source: "あとで連絡しますのでお待ちください")
        XCTAssertEqual(v, .reject(.newLatinToken))
    }

    func testLatinTokenPresentInSourceIsAccepted() {
        let v = gate.evaluate(headline: "Teamsで連絡",
                              source: "連絡はTeamsで行いますのでご確認ください")
        XCTAssertTrue(v.isAccepted)
    }

    func testInventedKatakanaTermIsRejected() {
        let v = gate.evaluate(headline: "コンピテンシー評価の話",
                              source: "評価の仕組みについて説明します")
        XCTAssertEqual(v, .reject(.newKatakanaTerm))
    }

    func testShortKatakanaIsNotTreatedAsTerm() {
        // 2文字以下は語として扱わない。助詞的な短語で誤検出すると使い物にならない。
        let v = gate.evaluate(headline: "メモを取る", source: "書き留めておいてください")
        XCTAssertTrue(v.isAccepted)
    }

    func testTooLongIsRejected() {
        let long = String(repeating: "あ", count: 41)
        XCTAssertEqual(gate.evaluate(headline: long, source: long), .reject(.tooLong))
    }

    func testTooShortIsRejected() {
        XCTAssertEqual(gate.evaluate(headline: "あ", source: "あああ"), .reject(.tooShort))
    }

    func testExtractHeadlineStopsAtPunctuation() {
        let h = SummaryGate.extractHeadline(from: "本日はお集まりいただきありがとうございます。まずは自己紹介から。")
        XCTAssertFalse(h.contains("。"))
        XCTAssertTrue(h.hasPrefix("本日は"))
        XCTAssertLessThanOrEqual(h.count, 30)
    }

    func testExtractHeadlineSkipsVeryEarlyPunctuation() {
        // 「はい、」で切ると2文字の見出しになる。短すぎる場合は次まで読む。
        let h = SummaryGate.extractHeadline(from: "はい、では次の議題に移ります。")
        XCTAssertGreaterThanOrEqual(h.count, 6)
    }
}

// MARK: - 要約の組み立て

/// 「行番号を返させて本文は引用する」構造が、モデルが暴れても壊れないことを見る。
private struct StubSummaryEngine: SummaryEngine {
    let displayName = "stub"
    let selections: [SummarySelection]
    func isAvailable() async -> CorrectionAvailability { .available }
    func select(from chunk: SummaryChunk, maxPoints: Int) async throws -> [SummarySelection] {
        selections
    }
}

private struct FailingSummaryEngine: SummaryEngine {
    let displayName = "failing"
    struct Boom: Error {}
    func isAvailable() async -> CorrectionAvailability { .available }
    func select(from chunk: SummaryChunk, maxPoints: Int) async throws -> [SummarySelection] {
        throw Boom()
    }
}

final class SummarizerTests: XCTestCase {

    private func seg(_ start: Double, _ text: String) -> Segment {
        var s = Segment(start: start, end: start + 5, original: text)
        s.corrected = text
        return s
    }

    private var sample: [Segment] {
        [seg(0, "本日は会社説明会にお越しいただきありがとうございます"),
         seg(5, "選考は書類選考のあと一次面接と最終面接があります"),
         seg(10, "エントリーシートの締め切りは今月末です"),
         seg(15, "質問がある方は最後にまとめてお願いします")]
    }

    func testQuotesAreVerbatimFromSegments() async {
        let engine = StubSummaryEngine(selections: [
            .init(lineNumbers: [2], headline: "選考の流れ", kind: .topic)
        ])
        let s = await Summarizer(engine: engine).run(on: sample)
        XCTAssertEqual(s.points.count, 1)
        XCTAssertEqual(s.points[0].quotes, ["選考は書類選考のあと一次面接と最終面接があります"],
                       "本文はセグメントからそのまま取られていない")
    }

    /// モデルが存在しない行番号を返しても、その要点ごと捨てる。
    /// 通してしまうと「引用のない要点」＝実質モデルの創作になる。
    func testInvalidLineNumberDropsThePoint() async {
        let engine = StubSummaryEngine(selections: [
            .init(lineNumbers: [99], headline: "ありえない参照", kind: .topic)
        ])
        let s = await Summarizer(engine: engine).run(on: sample)
        XCTAssertTrue(s.points.isEmpty)
        XCTAssertEqual(s.stats.invalidReferenceCount, 1)
    }

    func testPartiallyInvalidReferenceKeepsValidLinesAndIsCounted() async {
        let engine = StubSummaryEngine(selections: [
            .init(lineNumbers: [1, 99], headline: "冒頭の挨拶", kind: .topic)
        ])
        let s = await Summarizer(engine: engine).run(on: sample)
        XCTAssertEqual(s.points.count, 1)
        XCTAssertEqual(s.points[0].quotes.count, 1)
        XCTAssertEqual(s.stats.invalidReferenceCount, 1)
    }

    /// 原文に無い数値を含む見出しはゲートで落ち、原文抜粋に差し替わる。
    /// 要点そのものは残す（引用は本物なので情報としては正しい）。
    func testHallucinatedHeadlineFallsBackToExtraction() async {
        let engine = StubSummaryEngine(selections: [
            .init(lineNumbers: [3], headline: "締め切りは12月31日", kind: .number)
        ])
        let s = await Summarizer(engine: engine).run(on: sample)
        XCTAssertEqual(s.points.count, 1)
        XCTAssertEqual(s.points[0].headlineSource, .extracted)
        XCTAssertEqual(s.stats.rejectedHeadlineCount, 1)
        XCTAssertFalse(s.points[0].headline.contains("12月31日"))
    }

    func testCleanHeadlineIsKept() async {
        let engine = StubSummaryEngine(selections: [
            .init(lineNumbers: [3], headline: "締め切りは今月末", kind: .number)
        ])
        let s = await Summarizer(engine: engine).run(on: sample)
        XCTAssertEqual(s.points[0].headlineSource, .model)
        XCTAssertEqual(s.points[0].headline, "締め切りは今月末")
    }

    /// 幻聴として破棄したセグメントを要約が拾い直したら、除去した意味が無くなる
    func testSuppressedSegmentsAreNotSummarized() async {
        var segs = sample
        segs[1].flags.insert(.silenceSuppressed)
        let chunks = Summarizer(engine: nil).chunks(from: segs)
        let all = chunks.flatMap { $0.lines.map(\.text) }
        XCTAssertFalse(all.contains(where: { $0.contains("書類選考") }))
    }

    func testChunkingRespectsCharacterBudget() {
        var config = Summarizer.Configuration()
        config.maxCharactersPerChunk = 30
        let chunks = Summarizer(engine: nil, config: config).chunks(from: sample)
        XCTAssertGreaterThan(chunks.count, 1)
        for c in chunks {
            // 1セグメントが予算を超える場合は単独で1塊になるため、
            // 「2件以上入っている塊は予算内」を条件にする
            if c.lines.count > 1 {
                XCTAssertLessThanOrEqual(c.plainText.count, 30 + c.lines.last!.text.count)
            }
        }
        // 行番号は塊ごとに1始まり
        for c in chunks { XCTAssertEqual(c.lines.first?.index, 1) }
    }

    func testNumberedTextCarriesLineNumbers() {
        let chunks = Summarizer(engine: nil).chunks(from: sample)
        let text = chunks[0].numberedText
        XCTAssertTrue(text.hasPrefix("1: "))
        XCTAssertTrue(text.contains("\n2: "))
    }

    func testNoEngineProducesEmptySummary() async {
        let s = await Summarizer(engine: nil).run(on: sample)
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.stats.selectedCount, 0)
    }

    /// 要約が失敗しても文字起こし本体は成立する。例外を握りつぶさず件数に残す。
    func testEngineFailureIsRecordedNotSwallowed() async {
        let s = await Summarizer(engine: FailingSummaryEngine()).run(on: sample)
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.stats.failedChunkCount, s.stats.chunkCount)
        XCTAssertGreaterThan(s.stats.chunkCount, 0)
    }

    func testPointsAreSortedByTime() async {
        let engine = StubSummaryEngine(selections: [
            .init(lineNumbers: [4], headline: "質疑は最後", kind: .question),
            .init(lineNumbers: [1], headline: "冒頭の挨拶", kind: .topic)
        ])
        let s = await Summarizer(engine: engine).run(on: sample)
        XCTAssertEqual(s.points.map(\.start), [0, 15])
    }

    func testQuoteCountIsCapped() async {
        var config = Summarizer.Configuration()
        config.maxLinesPerPoint = 2
        let engine = StubSummaryEngine(selections: [
            .init(lineNumbers: [1, 2, 3, 4], headline: "全体の流れ", kind: .topic)
        ])
        let s = await Summarizer(engine: engine, config: config).run(on: sample)
        XCTAssertEqual(s.points[0].quotes.count, 2)
    }

    func testSummaryIsIncludedInMarkdownExport() async throws {
        let engine = StubSummaryEngine(selections: [
            .init(lineNumbers: [3], headline: "締め切りは今月末", kind: .number)
        ])
        let summary = await Summarizer(engine: engine).run(on: sample)
        let meta = TranscriptMeta(sourceURL: URL(fileURLWithPath: "/tmp/a.mp4"),
                                  sourceDuration: 20, engine: "test", modelName: "test", language: "ja")
        let t = Transcript(meta: meta, segments: sample, summary: summary)
        let md = Exporter().markdown(t)
        XCTAssertTrue(md.contains("## 要約"))
        XCTAssertTrue(md.contains("締め切りは今月末"))
        XCTAssertTrue(md.contains("エントリーシートの締め切りは今月末です"), "引用が出力に入っていない")
    }

    func testNoSummarySectionWhenEmpty() {
        let meta = TranscriptMeta(sourceURL: nil, sourceDuration: 20,
                                  engine: "test", modelName: "test", language: "ja")
        let md = Exporter().markdown(Transcript(meta: meta, segments: sample))
        XCTAssertFalse(md.contains("## 要約"))
    }
}
