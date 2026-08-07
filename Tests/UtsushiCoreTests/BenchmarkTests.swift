import XCTest

/// 計測コード自体が間違っていると、そこから先の判断が全部ずれる。
/// 手計算で答えが決まる小さな例で固定する。
final class BenchmarkTests: XCTestCase {

    private let bench = Benchmark()

    // MARK: - 基本

    func testIdenticalTextHasZeroError() {
        let r = bench.evaluate(referenceText: "本日はお集まりいただきありがとうございます",
                               hypothesisText: "本日はお集まりいただきありがとうございます")
        XCTAssertEqual(r.cer.errors, 0)
        XCTAssertEqual(r.cer.rate, 0)
        XCTAssertEqual(r.cer.accuracy, 1)
        XCTAssertTrue(r.differences.isEmpty)
    }

    func testSingleSubstitution() {
        // 「機構」→「気候」で2文字置換
        let r = bench.evaluate(referenceText: "機構について", hypothesisText: "気候について")
        XCTAssertEqual(r.cer.substitutions, 2)
        XCTAssertEqual(r.cer.deletions, 0)
        XCTAssertEqual(r.cer.insertions, 0)
        XCTAssertEqual(r.cer.referenceCount, 6)
        XCTAssertEqual(r.cer.rate, 2.0 / 6.0, accuracy: 1e-9)
    }

    func testDeletion() {
        let r = bench.evaluate(referenceText: "あいうえお", hypothesisText: "あいえお")
        XCTAssertEqual(r.cer.deletions, 1)
        XCTAssertEqual(r.cer.substitutions, 0)
        XCTAssertEqual(r.cer.insertions, 0)
        XCTAssertEqual(r.differences.first?.reference, "う")
    }

    func testInsertion() {
        let r = bench.evaluate(referenceText: "あいえお", hypothesisText: "あいうえお")
        XCTAssertEqual(r.cer.insertions, 1)
        XCTAssertEqual(r.cer.substitutions, 0)
        XCTAssertEqual(r.cer.deletions, 0)
        XCTAssertEqual(r.differences.first?.hypothesis, "う")
    }

    /// 幻聴は「参照に無い文字列が丸ごと入る」なので挿入として出るべき
    func testHallucinationShowsAsInsertions() {
        let ghost = "ご視聴ありがとうございました"
        let r = bench.evaluate(referenceText: "以上です",
                               hypothesisText: "以上です" + ghost)
        XCTAssertEqual(r.cer.insertions, ghost.count)
        XCTAssertEqual(r.cer.substitutions, 0)
        XCTAssertEqual(r.cer.deletions, 0)
        // 参照が短いので誤り率は1を超えうる。頭打ちにしない（実態を隠すため）。
        XCTAssertGreaterThan(r.cer.rate, 1.0)
        XCTAssertEqual(r.cer.accuracy, 0, "accuracy は0で下げ止まる")
    }

    func testEmptyHypothesisIsAllDeletions() {
        let r = bench.evaluate(referenceText: "あいう", hypothesisText: "")
        XCTAssertEqual(r.cer.deletions, 3)
        XCTAssertEqual(r.cer.rate, 1.0)
    }

    func testEmptyReferenceWithOutput() {
        let r = bench.evaluate(referenceText: "", hypothesisText: "何か")
        XCTAssertEqual(r.cer.rate, 1.0, "参照が空なのに出力があるのを0%扱いにしてはいけない")
    }

    func testBothEmpty() {
        let r = bench.evaluate(referenceText: "", hypothesisText: "")
        XCTAssertEqual(r.cer.rate, 0)
        XCTAssertEqual(r.cer.errors, 0)
    }

    // MARK: - 正規化

    func testPunctuationIsIgnoredByDefault() {
        let r = bench.evaluate(referenceText: "はい、そうです。", hypothesisText: "はいそうです")
        XCTAssertEqual(r.cer.errors, 0, "句読点の有無だけで誤りに数えている")
    }

    func testStrictPolicyCountsPunctuation() {
        let strict = Benchmark(policy: .strict)
        let r = strict.evaluate(referenceText: "はい、そうです。", hypothesisText: "はいそうです")
        XCTAssertEqual(r.cer.deletions, 2)
    }

    func testCaseIsFoldedByDefault() {
        XCTAssertEqual(bench.evaluate(referenceText: "Teams", hypothesisText: "teams").cer.errors, 0)
        let strict = Benchmark(policy: .strict)
        XCTAssertGreaterThan(strict.evaluate(referenceText: "Teams", hypothesisText: "teams").cer.errors, 0)
    }

    func testWidthNormalization() {
        let r = bench.evaluate(referenceText: "ＡＢＣ123", hypothesisText: "ABC123")
        XCTAssertEqual(r.cer.errors, 0)
    }

    func testKanaFoldingIsOffByDefault() {
        let r = bench.evaluate(referenceText: "サーバ", hypothesisText: "さーば")
        XCTAssertGreaterThan(r.cer.errors, 0, "既定でかなの違いを無視してはいけない")
    }

    func testLenientPolicyFoldsKanaAndProlongedMark() {
        let lenient = Benchmark(policy: .lenient)
        XCTAssertEqual(lenient.evaluate(referenceText: "サーバ", hypothesisText: "さーば").cer.errors, 0)
        XCTAssertEqual(lenient.evaluate(referenceText: "サーバー", hypothesisText: "サーバ").cer.errors, 0)
    }

    func testPolicyIsRecordedInResult() {
        // どの設定で測ったか分からない数字は比較できない
        XCTAssertFalse(bench.evaluate(referenceText: "あ", hypothesisText: "あ").cer.policyDescription.isEmpty)
        XCTAssertNotEqual(Benchmark(policy: .strict).evaluate(referenceText: "あ", hypothesisText: "あ").cer.policyDescription,
                          Benchmark(policy: .lenient).evaluate(referenceText: "あ", hypothesisText: "あ").cer.policyDescription)
    }

    // MARK: - 差分の復元

    func testDifferencesAreInTimeOrder() {
        let r = bench.evaluate(referenceText: "あいうえお", hypothesisText: "あXうYお")
        XCTAssertEqual(r.cer.substitutions, 2)
        let idx = r.differences.map(\.referenceIndex)
        XCTAssertEqual(idx, idx.sorted(), "差分が時系列に並んでいない")
        // 既定ポリシーは大小を無視するので、正規化後は小文字で出る
        XCTAssertEqual(r.differences.map(\.hypothesis), ["x", "y"])
    }

    func testTopConfusionsCountRepeats() {
        let r = bench.evaluate(referenceText: "機構機構機構", hypothesisText: "気候気候気候")
        let top = r.topConfusions.first
        XCTAssertNotNil(top)
        XCTAssertEqual(top?.count, 3, "同じ誤りが集計されていない")
    }

    func testDifferenceCountIsCapped() {
        let capped = Benchmark(maxDifferences: 5)
        let r = capped.evaluate(referenceText: String(repeating: "あ", count: 50),
                                hypothesisText: String(repeating: "い", count: 50))
        XCTAssertEqual(r.differences.count, 5)
        XCTAssertEqual(r.cer.substitutions, 50, "打ち切りが集計まで削ってはいけない")
    }

    // MARK: - 正解データの読み込み

    func testPlainTextReferenceWithTimecodes() {
        let ref = Benchmark.Reference.fromPlainText("""
        # これはコメント
        00:00:05\t本日はお集まりいただきありがとうございます
        00:01:30\t選考の流れをご説明します

        02:00\t以上です
        """)
        XCTAssertEqual(ref.lines.count, 3)
        XCTAssertEqual(ref.lines[0].start, 5)
        XCTAssertEqual(ref.lines[1].start, 90)
        XCTAssertEqual(ref.lines[2].start, 120)
        XCTAssertTrue(ref.hasTimestamps)
        XCTAssertTrue(ref.fullText.contains("選考の流れ"))
    }

    func testPlainTextWithoutTimecodes() {
        let ref = Benchmark.Reference.fromPlainText("あいうえお\nかきくけこ")
        XCTAssertEqual(ref.lines.count, 2)
        XCTAssertFalse(ref.hasTimestamps)
        XCTAssertNil(ref.lines[0].start)
    }

    func testTimecodeParsing() {
        XCTAssertEqual(Benchmark.Reference.parseTimecode("01:02:03"), 3723)
        XCTAssertEqual(Benchmark.Reference.parseTimecode("02:03"), 123)
        XCTAssertEqual(Benchmark.Reference.parseTimecode("12.5"), 12.5)
        XCTAssertEqual(Benchmark.Reference.parseTimecode("00:00:01,500"), 1.5)
        XCTAssertNil(Benchmark.Reference.parseTimecode("あ"))
    }

    func testReferenceRoundTripsThroughJSON() throws {
        let ref = Benchmark.Reference(lines: [.init(start: 1, end: 2, text: "あ")], source: "x.m4a")
        let back = try Benchmark.Reference.fromJSON(JSONEncoder().encode(ref))
        XCTAssertEqual(ref, back)
    }

    // MARK: - Transcript との接続

    func testEvaluateAgainstTranscriptUsesVisibleSegmentsOnly() {
        var a = Segment(start: 0, end: 3, original: "本日はよろしくお願いします")
        a.corrected = a.original
        var ghost = Segment(start: 3, end: 6, original: "ご視聴ありがとうございました")
        ghost.corrected = ghost.original
        ghost.flags.insert(.silenceSuppressed)   // 幻聴として破棄済み

        let meta = TranscriptMeta(sourceURL: nil, sourceDuration: 6,
                                  engine: "t", modelName: "t", language: "ja")
        let t = Transcript(meta: meta, segments: [a, ghost])
        let ref = Benchmark.Reference(lines: [.init(text: "本日はよろしくお願いします")])

        let r = bench.evaluate(reference: ref, hypothesis: t)
        XCTAssertEqual(r.cer.errors, 0, "破棄済みの幻聴が計測に混入している")
    }

    func testMarkdownContainsPolicyAndNumbers() {
        let r = bench.evaluate(referenceText: "機構について", hypothesisText: "気候について")
        let md = r.markdown(title: "テスト")
        XCTAssertTrue(md.contains("文字誤り率"))
        XCTAssertTrue(md.contains(r.cer.policyDescription), "どの設定で測ったかが出力に無い")
        XCTAssertTrue(md.contains("多い誤り"))
    }

    // MARK: - WER

    func testWERIsOffByDefault() {
        XCTAssertNil(bench.evaluate(referenceText: "あ", hypothesisText: "あ").wer)
    }

    func testWERIsComputedWhenEnabled() {
        let b = Benchmark(computeWER: true)
        let r = b.evaluate(referenceText: "本日は会社説明会にお越しいただきありがとうございます",
                           hypothesisText: "本日は会社説明会にお越しいただきありがとうございます")
        XCTAssertNotNil(r.wer)
        XCTAssertEqual(r.wer?.errors, 0)
        XCTAssertGreaterThan(r.wer?.referenceCount ?? 0, 0, "語に分割できていない")
    }

    func testWERDetectsAWordError() {
        let b = Benchmark(computeWER: true)
        let r = b.evaluate(referenceText: "選考の流れを説明します",
                           hypothesisText: "選考の流れを説明しません")
        XCTAssertGreaterThan(r.wer?.errors ?? 0, 0)
    }
}
