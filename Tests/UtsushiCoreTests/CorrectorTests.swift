import XCTest

/// ゲートを通らない提案しか出さない「敵対的な」ダミーLLM。
private struct AdversarialEngine: CorrectionEngine {
    let displayName = "adversarial"
    let reply: @Sendable (String) -> String?
    func isAvailable() async -> CorrectionAvailability { .available }
    func propose(segment: String, context: CorrectionContext) async throws -> String? { reply(segment) }
}

final class CorrectorTests: XCTestCase {

    func testHallucinatedRewriteIsRejected() async {
        let engine = AdversarialEngine { _ in
            "本日は株式会社BeeXの会社説明会にお越しいただき誠にありがとうございます"
        }
        let c = Corrector(engine: engine, requireAgreement: false)
        let segs = [Segment(start: 0, end: 3, original: "本日はありがとうございます")]
        let (out, stat) = await c.run(on: segs)
        XCTAssertEqual(out[0].text, "本日はありがとうございます", "ゲートを通っていない案が採用された")
        XCTAssertEqual(stat.accepted, 0)
        XCTAssertGreaterThan(stat.rejected.values.reduce(0, +), 0)
    }

    func testHomophoneFixIsAccepted() async {
        let engine = AdversarialEngine { s in s.replacingOccurrences(of: "機構変動", with: "気候変動") }
        let c = Corrector(engine: engine, requireAgreement: false)
        let segs = [Segment(start: 0, end: 3, original: "機構変動の話をします")]
        let (out, stat) = await c.run(on: segs)
        XCTAssertEqual(out[0].text, "気候変動の話をします")
        XCTAssertEqual(stat.accepted, 1)
        XCTAssertEqual(out[0].correction?.rule, .languageModel)
        XCTAssertEqual(out[0].original, "機構変動の話をします", "原文は保持されていなければならない")
    }

    func testDisagreementBlocksAcceptance() async {
        // 呼ぶたび違う答えを返すエンジン。2回一致要求が効いているかを見る。
        let counter = Counter()
        let engine = AdversarialEngine { s in
            counter.increment() % 2 == 0 ? s.replacingOccurrences(of: "機構", with: "気候") : s
        }
        let c = Corrector(engine: engine, requireAgreement: true)
        let segs = [Segment(start: 0, end: 3, original: "機構変動の話をします")]
        let (out, stat) = await c.run(on: segs)
        XCTAssertEqual(out[0].text, "機構変動の話をします")
        XCTAssertEqual(stat.accepted, 0)
        XCTAssertEqual(stat.rejected["disagreement"], 1)
    }

    func testSuppressedSegmentsAreNotSentToLLM() async {
        let called = Counter()
        let engine = AdversarialEngine { _ in called.increment(); return nil }
        let c = Corrector(engine: engine, requireAgreement: false)
        var seg = Segment(start: 0, end: 30, original: "ご視聴ありがとうございました")
        seg.flags.insert(.silenceSuppressed)
        _ = await c.run(on: [seg])
        XCTAssertEqual(called.value, 0, "破棄済みセグメントをLLMに渡してはいけない")
    }

    func testDictionaryAppliesDeterministically() async {
        let dict = UserDictionary(entries: [
            .init(surface: "BeeX", reading: "びーえっくす", misspellings: ["新小物"])
        ])
        let c = Corrector(engine: nil, gate: EditGate(policy: .init(), dictionary: dict), dictionary: dict)
        let segs = [Segment(start: 0, end: 3, original: "株式会社新小物と申します")]
        let (out, stat) = await c.run(on: segs)
        XCTAssertEqual(out[0].text, "株式会社BeeXと申します")
        XCTAssertEqual(stat.dictionary, 1)
        XCTAssertEqual(out[0].correction?.rule, .dictionary)
    }

    func testEngineErrorsDoNotCorruptText() async {
        struct Failing: CorrectionEngine {
            let displayName = "failing"
            func isAvailable() async -> CorrectionAvailability { .available }
            func propose(segment: String, context: CorrectionContext) async throws -> String? {
                throw NSError(domain: "test", code: 1)
            }
        }
        let c = Corrector(engine: Failing(), requireAgreement: false)
        let segs = [Segment(start: 0, end: 3, original: "原文のままであるべき")]
        let (out, stat) = await c.run(on: segs)
        XCTAssertEqual(out[0].text, "原文のままであるべき")
        XCTAssertEqual(stat.engineErrors, 1)
    }
}

private final class Counter: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    @discardableResult func increment() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

final class DeterministicRulesTests: XCTestCase {
    func testRemovesFillers() {
        let r = DeterministicRules()
        let (out, rule) = r.apply("えーとですね、これはテストです")
        XCTAssertFalse(out.contains("えーと"))
        XCTAssertNotNil(rule)
    }
    func testKeepsFillerOnlyUtterance() {
        let r = DeterministicRules()
        let (out, _) = r.apply("えーと")
        XCTAssertEqual(out, "えーと", "フィラーだけの発話を空にしてはいけない")
    }
    /// 実機で本文を壊した実例をそのまま回帰テストにする。
    /// 「こう」を部分文字列として消すと「こういう」「こういった」が壊れる。
    func testDoesNotEatWordsContainingFillerSubstring() {
        let r = DeterministicRules()
        let cases = [
            "他の部署からみたいにこういうところがいいところだよみたいなところで、",
            "こういった評価制度があるというところをご認識いただいて、",
            "あの人がおっしゃっていた件です",
            "なんかあったら連絡してください",
            "そうですね、まあまあの出来でした",
            "こうして振り返ると",
        ]
        for c in cases {
            let (out, _) = r.apply(c)
            XCTAssertEqual(out, c, "本文を壊している: 「\(c)」→「\(out)」")
        }
    }

    func testBoundaryRuleKeepsMidWordOccurrences() {
        // 左が境界でない位置のフィラーは消さない
        XCTAssertEqual(DeterministicRules.removeAtBoundaries("えー", from: "すごーいえーと"), "すごーいえーと")
        // 文頭・読点の直後は消す
        XCTAssertEqual(DeterministicRules.removeAtBoundaries("えーと", from: "えーとですね"), "ですね")
        XCTAssertEqual(DeterministicRules.removeAtBoundaries("あのー", from: "はい、あのー本題です"), "はい、本題です")
    }

    func testNormalizesNotation() {
        let r = DeterministicRules()
        let (out, _) = r.apply("そうゆう風に出来る")
        XCTAssertEqual(out, "そういう風にできる")
    }
}

final class ExporterTests: XCTestCase {
    private func sample() -> Transcript {
        var s1 = Segment(start: 0, end: 2.5, original: "最初の発話")
        var s2 = Segment(start: 10, end: 40, original: "ご視聴ありがとうございました")
        s2.flags.insert(.silenceSuppressed); s2.corrected = ""
        s1.corrected = "最初の発話。"
        s1.correction = AppliedCorrection(before: "最初の発話", after: "最初の発話。",
                                          rule: .languageModel, accepted: true)
        return Transcript(meta: .init(sourceURL: URL(fileURLWithPath: "/tmp/a.mov"),
                                      sourceDuration: 60, engine: "test",
                                      modelName: "test", language: "ja"),
                          segments: [s1, s2])
    }

    func testSuppressedSegmentsNeverReachOutput() throws {
        let t = sample()
        for f in ExportFormat.allCases {
            let data = try Exporter().render(t, as: f)
            let s = String(data: data, encoding: .utf8) ?? ""
            if f == .json {
                XCTAssertTrue(s.contains("silenceSuppressed"), "JSONには記録として残す")
            } else {
                XCTAssertFalse(s.contains("ご視聴ありがとうございました"),
                               "\(f.rawValue) に破棄済み本文が出ている")
            }
        }
    }

    func testSRTIsWellFormed() throws {
        let s = String(data: try Exporter().render(sample(), as: .srt), encoding: .utf8)!
        XCTAssertTrue(s.hasPrefix("1\n00:00:00,000 --> "))
        XCTAssertTrue(s.contains("最初の発話。"))
    }

    func testMarkdownRecordsCorrections() throws {
        let s = String(data: try Exporter().render(sample(), as: .markdown), encoding: .utf8)!
        XCTAssertTrue(s.contains("校正で変更した箇所"))
        XCTAssertTrue(s.contains("検証記録"))
    }

    func testTimecodeFormat() {
        XCTAssertEqual(Exporter.timecode(3661.5, sep: ","), "01:01:01,500")
        XCTAssertEqual(Exporter.hms(3661.5), "01:01:01")
    }
}


@available(macOS 26.0, *)
final class SpeechAnalyzerCoalesceTests: XCTestCase {
    /// SpeechTranscriber の細切れ確定結果をまとめ直せること。
    /// 実測で「自」「己評価と」「情」「緒評価を」のような断片が並んだのが動機。
    func testMergesFragments() {
        let frags = [
            Segment(start: 0.0, end: 0.4, original: "自"),
            Segment(start: 0.4, end: 1.2, original: "己評価と"),
            Segment(start: 1.2, end: 2.0, original: "上長評価を提出します。"),
            Segment(start: 5.0, end: 6.0, original: "次の話題です。"),
        ]
        let out = SpeechAnalyzerEngine.coalesce(frags)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].original, "自己評価と上長評価を提出します。")
        XCTAssertEqual(out[0].start, 0.0)
        XCTAssertEqual(out[0].end, 2.0)
        XCTAssertEqual(out[1].original, "次の話題です。")
    }

    func testSplitsOnLongGap() {
        let frags = [
            Segment(start: 0, end: 1, original: "前半"),
            Segment(start: 30, end: 31, original: "後半"),
        ]
        let out = SpeechAnalyzerEngine.coalesce(frags)
        XCTAssertEqual(out.count, 2, "無音を跨いで結合してはいけない")
    }

    func testCapsSegmentLength() {
        let frags = (0..<40).map { i in
            Segment(start: Double(i) * 0.3, end: Double(i) * 0.3 + 0.3, original: "あいうえお")
        }
        let out = SpeechAnalyzerEngine.coalesce(frags)
        XCTAssertGreaterThan(out.count, 1, "上限を超えても1本にまとめてはいけない")
        XCTAssertTrue(out.allSatisfy { $0.original.count <= 145 })
    }
}


final class PromptHintTests: XCTestCase {
    func testEmptyDictionaryProducesNoHint() {
        XCTAssertNil(UserDictionary.empty.promptHint())
    }

    func testBuildsHintFromSurfaces() {
        let d = UserDictionary(entries: [
            .init(surface: "BeeX", reading: "びーえっくす"),
            .init(surface: "上長評価", reading: "じょうちょうひょうか"),
            .init(surface: "コンピテンシー", reading: "こんぴてんしー"),
        ])
        let hint = d.promptHint()
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint!.contains("BeeX"))
        XCTAssertTrue(hint!.contains("上長評価"))
        XCTAssertTrue(hint!.contains("コンピテンシー"))
    }

    func testTruncatesToBudget() {
        // initial_prompt は 224トークンで黙って切られるので、こちら側で必ず収める
        let d = UserDictionary(entries: (0..<200).map {
            .init(surface: "専門用語\($0)", reading: "せんもんようご")
        })
        let hint = d.promptHint(maxCharacters: 200)
        XCTAssertNotNil(hint)
        XCTAssertLessThanOrEqual(hint!.count, 200)
    }

    func testIgnoresBlankSurfaces() {
        let d = UserDictionary(entries: [
            .init(surface: "  ", reading: ""),
            .init(surface: "有効な語", reading: "ゆうこうなご"),
        ])
        let hint = d.promptHint()
        XCTAssertEqual(hint, "固有名詞: 有効な語。")
    }
}
