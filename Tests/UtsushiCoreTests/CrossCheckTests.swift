import XCTest

final class TranscriptAlignmentTests: XCTestCase {

    private func run(_ engine: String, _ items: [(Double, Double, String)]) -> TranscriptAlignment.Run {
        TranscriptAlignment.Run(engine: engine,
                                segments: items.map { Segment(start: $0.0, end: $0.1, original: $0.2) })
    }

    func testIdenticalTranscriptsProduceNoDisagreement() {
        let a = run("whisper", [(0, 5, "本日はお集まりいただきありがとうございます")])
        let b = run("apple",   [(0, 2, "本日はお集まり"), (2, 5, "いただきありがとうございます")])
        XCTAssertTrue(TranscriptAlignment.compare([a, b]).isEmpty,
                      "セグメントの切り方が違うだけで不一致にしてはいけない")
    }

    func testPunctuationOnlyDifferenceIsIgnored() {
        let a = run("whisper", [(0, 5, "本日は、お集まりいただきありがとうございます。")])
        let b = run("apple",   [(0, 5, "本日はお集まりいただきありがとうございます")])
        XCTAssertTrue(TranscriptAlignment.compare([a, b]).isEmpty,
                      "句読点だけの差を不一致として扱ってはいけない")
    }

    func testDetectsHomophoneDisagreement() {
        let a = run("whisper", [(0, 5, "機構変動への対応が事業の軸です")])
        let b = run("apple",   [(0, 5, "気候変動への対応が事業の軸です")])
        let d = TranscriptAlignment.compare([a, b])
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(Set(d[0].candidates.map(\.text)), ["機構", "気候"])
        XCTAssertTrue(d[0].readingsMatch, "同音異義語なので読みは一致するはず")
    }

    func testDetectsNonHomophoneDisagreement() {
        let a = run("whisper", [(0, 5, "自己評価と冗長評価を提出します")])
        let b = run("apple",   [(0, 5, "自己評価と情緒評価を提出します")])
        let d = TranscriptAlignment.compare([a, b])
        XCTAssertEqual(d.count, 1)
        XCTAssertFalse(d[0].readingsMatch, "じょうちょう と じょうちょ は読みが違う")
    }

    func testContextIsAttached() {
        let a = run("whisper", [(0, 8, "評価制度の話をします。機構変動については後ほど触れます。")])
        let b = run("apple",   [(0, 8, "評価制度の話をします。気候変動については後ほど触れます。")])
        let d = TranscriptAlignment.compare([a, b])
        XCTAssertEqual(d.count, 1)
        XCTAssertTrue(d[0].context.contains("評価制度"), "判定材料として前後の文脈が要る")
    }

    func testSuppressedSegmentsAreExcluded() {
        var hallucinated = Segment(start: 10, end: 40, original: "ご視聴ありがとうございました")
        hallucinated.flags.insert(.silenceSuppressed)
        hallucinated.corrected = ""
        let a = TranscriptAlignment.Run(engine: "whisper", segments: [
            Segment(start: 0, end: 5, original: "本編です"), hallucinated,
        ])
        let b = run("apple", [(0, 5, "本編です")])
        XCTAssertTrue(TranscriptAlignment.compare([a, b]).isEmpty,
                      "破棄済みセグメントを比較対象にしてはいけない")
    }

    func testDifferingSpansFindsMinimalSpan() {
        let spans = TranscriptAlignment.differingSpans(Array("あいうえお"), Array("あいXえお"))
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(String(Array("あいうえお")[spans[0].a]), "う")
        XCTAssertEqual(String(Array("あいXえお")[spans[0].b]), "X")
    }

    func testDifferingSpansHandlesInsertion() {
        let spans = TranscriptAlignment.differingSpans(Array("あいえお"), Array("あいうえお"))
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(String(Array("あいうえお")[spans[0].b]), "う")
    }
}

/// 判定を返すだけのダミー。ゲート側の挙動だけを見る。
private struct StubJudge: DisagreementJudge {
    let displayName = "stub"
    let reply: @Sendable (TranscriptAlignment.Disagreement, Int) -> Int?
    let counter = Counter()
    func isAvailable() async -> CorrectionAvailability { .available }
    func judge(_ d: TranscriptAlignment.Disagreement) async throws -> Int? {
        reply(d, counter.increment())
    }
}

private final class Counter: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()
    @discardableResult func increment() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

final class AdjudicatorTests: XCTestCase {

    private func sample(readingsMatch: Bool = true) -> TranscriptAlignment.Disagreement {
        TranscriptAlignment.Disagreement(
            start: 0, end: 5,
            candidates: [.init(engine: "whisper", text: "機構"), .init(engine: "apple", text: "気候")],
            readingsMatch: readingsMatch, context: "変動への対応")
    }

    func testChoosesCandidateWhenBothSamplesAgree() async {
        let a = Adjudicator(judge: StubJudge { _, _ in 1 }, requireAgreement: true)
        let (results, stat) = await a.run(on: [sample()])
        XCTAssertEqual(results.first?.chosenText, "気候")
        XCTAssertEqual(stat.decided, 1)
        XCTAssertEqual(stat.decidedWithMatchingReadings, 1)
    }

    func testDisagreementBetweenSamplesBlocksDecision() async {
        let a = Adjudicator(judge: StubJudge { _, n in n % 2 == 1 ? 0 : 1 }, requireAgreement: true)
        let (results, stat) = await a.run(on: [sample()])
        XCTAssertNil(results.first?.chosenText)
        XCTAssertEqual(stat.decided, 0)
        XCTAssertEqual(stat.disagreedBetweenSamples, 1)
    }

    func testOutOfRangeIndexIsRejected() async {
        let a = Adjudicator(judge: StubJudge { _, _ in 7 }, requireAgreement: false)
        let (results, stat) = await a.run(on: [sample()])
        XCTAssertNil(results.first?.chosenText, "候補数を超える番号を採ってはいけない")
        XCTAssertEqual(stat.undecided, 1)
    }

    func testChosenTextIsAlwaysOneOfCandidates() async {
        let a = Adjudicator(judge: StubJudge { _, _ in 0 }, requireAgreement: false)
        let d = sample()
        let (results, _) = await a.run(on: [d])
        guard let chosen = results.first?.chosenText else { return XCTFail("採用されていない") }
        XCTAssertTrue(d.candidates.map(\.text).contains(chosen),
                      "候補に無い文字列が出てはいけない（番号でしか選べない設計）")
    }

    func testSkipsDifferentReadingsWhenConfigured() async {
        let a = Adjudicator(judge: StubJudge { _, _ in 0 },
                            requireAgreement: false, judgeDifferentReadings: false)
        let (results, stat) = await a.run(on: [sample(readingsMatch: false)])
        XCTAssertNil(results.first?.chosenText)
        XCTAssertEqual(stat.undecided, 1)
    }

    func testRecordsReadingCategorySeparately() async {
        let a = Adjudicator(judge: StubJudge { _, _ in 0 }, requireAgreement: false)
        let (_, stat) = await a.run(on: [sample(readingsMatch: true), sample(readingsMatch: false)])
        XCTAssertEqual(stat.decidedWithMatchingReadings, 1)
        XCTAssertEqual(stat.decidedWithDifferentReadings, 1)
    }

    func testJudgeErrorsDoNotDecide() async {
        struct Failing: DisagreementJudge {
            let displayName = "failing"
            func isAvailable() async -> CorrectionAvailability { .available }
            func judge(_ d: TranscriptAlignment.Disagreement) async throws -> Int? {
                throw NSError(domain: "t", code: 1)
            }
        }
        let a = Adjudicator(judge: Failing(), requireAgreement: false)
        let (results, stat) = await a.run(on: [sample()])
        XCTAssertNil(results.first?.chosenText)
        XCTAssertEqual(stat.errors, 1)
    }
}

final class SherpaChunkTests: XCTestCase {
    func testShortAudioIsSingleChunk() {
        let s = [Float](repeating: 0.1, count: 16000 * 5)
        let c = SherpaEngine.chunk(s, sampleRate: 16000, maxSeconds: 20, silenceRatio: 0.02)
        XCTAssertEqual(c, [SherpaEngine.Chunk(start: 0, end: s.count)])
    }

    func testLongAudioIsSplit() {
        let s = [Float](repeating: 0.1, count: 16000 * 65)
        let c = SherpaEngine.chunk(s, sampleRate: 16000, maxSeconds: 20, silenceRatio: 0.02)
        XCTAssertGreaterThan(c.count, 3)
        XCTAssertEqual(c.first?.start, 0)
        XCTAssertEqual(c.last?.end, s.count)
        for i in 1..<c.count { XCTAssertEqual(c[i-1].end, c[i].start, "チャンクに隙間や重なりがあってはいけない") }
    }

    func testPrefersSilentBoundary() {
        // 18秒目に無音の谷を置く。20秒上限なら、そこで切れてほしい。
        var s = [Float](repeating: 0.5, count: 16000 * 40)
        for i in (16000 * 18)..<(16000 * 19) { s[i] = 0 }
        let c = SherpaEngine.chunk(s, sampleRate: 16000, maxSeconds: 20, silenceRatio: 0.05)
        let firstEnd = Double(c[0].end) / 16000
        XCTAssertTrue((18.0...19.2).contains(firstEnd), "無音の谷で切れていない: \(firstEnd)")
    }

    func testGroupTokensSplitsOnGap() {
        let tokens: [(text: String, start: Double)] = [
            ("こん", 0.0), ("にちは", 0.2), ("。", 0.5),
            ("次", 3.0), ("の話", 3.2),
        ]
        let segs = SherpaEngine.groupTokens(tokens, fallbackEnd: 4.0)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].original, "こんにちは。")
        XCTAssertEqual(segs[1].original, "次の話")
    }

    func testGroupTokensStripsSentencePieceMarker() {
        let segs = SherpaEngine.groupTokens([("▁こん", 0.0), ("にちは", 0.1)], fallbackEnd: 1.0)
        XCTAssertEqual(segs.first?.original, "こんにちは")
    }
}


final class CrossCheckExportTests: XCTestCase {
    private func transcript(withCrossCheck: Bool) -> Transcript {
        var cc = CrossCheckReport()
        if withCrossCheck {
            let d = TranscriptAlignment.Disagreement(
                start: 12, end: 20,
                candidates: [.init(engine: "whisper.cpp", text: "機構"),
                             .init(engine: "sherpa-parakeet-ja", text: "気候")],
                readingsMatch: true, context: "変動への対応")
            cc.engines = ["whisper.cpp", "sherpa-parakeet-ja"]
            cc.disagreements = [d]
            cc.adjudications = [Adjudication(disagreementID: d.id, start: 12, end: 20,
                                             chosenEngine: nil, chosenText: nil,
                                             candidates: d.candidates,
                                             readingsMatched: true, agreed: false)]
            cc.outcome.total = 1
            cc.outcome.undecided = 1
        }
        return Transcript(meta: .init(sourceURL: URL(fileURLWithPath: "/tmp/a.mov"),
                                      sourceDuration: 60, engine: "test",
                                      modelName: "test", language: "ja"),
                          segments: [Segment(start: 0, end: 3, original: "本文")],
                          crossCheck: cc)
    }

    func testMarkdownIncludesCrossCheck() throws {
        let s = String(data: try Exporter().render(transcript(withCrossCheck: true), as: .markdown),
                       encoding: .utf8)!
        XCTAssertTrue(s.contains("別エンジンとの照合"))
        XCTAssertTrue(s.contains("判定できなかった食い違い"))
        XCTAssertTrue(s.contains("機構"))
    }

    func testAttributionIsEmittedWhenModelUsed() throws {
        let s = String(data: try Exporter().render(transcript(withCrossCheck: true), as: .markdown),
                       encoding: .utf8)!
        XCTAssertTrue(s.contains("CC BY 4.0"),
                      "CC-BY のモデルを使ったら成果物に帰属表示が要る")
    }

    func testNoCrossCheckSectionWhenSingleEngine() throws {
        let s = String(data: try Exporter().render(transcript(withCrossCheck: false), as: .markdown),
                       encoding: .utf8)!
        XCTAssertFalse(s.contains("別エンジンとの照合"))
    }
}


final class ModelCatalogLayoutTests: XCTestCase {
    /// 旧フラット配置のモデルを再ダウンロードさせないこと。
    /// ディレクトリ構成に変えたときに実際にスキップが発生した。
    func testLegacyFlatLayoutIsAccepted() throws {
        let model = ModelCatalog.whisperModels[0]
        let item = model.items[0]
        let legacy = ModelCatalog.legacyURL(for: item)
        let current = ModelCatalog.directory(for: model).appendingPathComponent(item.fileName)

        // 実機に導入済みなら、新旧どちらかで見つかること
        let installed = ModelCatalog.isInstalled(model)
        let anyExists = FileManager.default.fileExists(atPath: legacy.path)
            || FileManager.default.fileExists(atPath: current.path)
        if anyExists {
            XCTAssertTrue(installed, "ファイルがあるのに未導入と判定された（旧配置の取りこぼし）")
            XCTAssertNotNil(ModelCatalog.localURL(for: model, role: "model"))
        } else {
            XCTAssertFalse(installed)
        }
    }

    func testSizeMismatchIsRejected() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("utsushi-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("x.bin")
        try Data(repeating: 0, count: 10).write(to: f)
        XCTAssertTrue(ModelCatalog.isValid(f, expected: 10))
        XCTAssertFalse(ModelCatalog.isValid(f, expected: 999), "サイズ不一致を通してはいけない")
        XCTAssertTrue(ModelCatalog.isValid(f, expected: 0), "期待サイズ未指定なら存在だけで可")
    }

    func testEveryModelHasItems() {
        for m in ModelCatalog.allModels {
            XCTAssertFalse(m.items.isEmpty, "\(m.id) にファイルが定義されていない")
            if m.archiveURL == nil {
                XCTAssertTrue(m.items.allSatisfy { $0.url != nil },
                              "\(m.id) は単体配布なのにURLが無い項目がある")
            } else {
                XCTAssertTrue(m.items.allSatisfy { $0.pathInArchive != nil },
                              "\(m.id) はアーカイブ配布なのに pathInArchive が無い項目がある")
            }
        }
    }
}
