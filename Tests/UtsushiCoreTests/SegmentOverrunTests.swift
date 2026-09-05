import XCTest

/// 無音をまたいだ end の切り詰め。
///
/// 実機で「はい、では一旦休憩挟みます。」の end が8分先まで伸び、
/// **発話カバー率が100%と誤報された**。カバー率は「取りこぼしていないか」を
/// 判断する一次情報なので、ここが嘘をつくと検証層の意味が半分死ぬ。
final class SegmentOverrunTests: XCTestCase {

    /// hop 0.02秒。voiced=有声とみなす音圧、silent=無音。
    private func envelope(voicedRanges: [(Double, Double)], duration: Double,
                          hop: Double = 0.02) -> AudioEnvelope {
        let n = Int(duration / hop)
        var v = [Float](repeating: -80, count: n)
        for (s, e) in voicedRanges {
            let i0 = max(0, Int(s / hop)), i1 = min(n, Int(e / hop))
            guard i0 < i1 else { continue }
            for i in i0..<i1 { v[i] = -20 }
        }
        return AudioEnvelope(values: v, hop: hop)
    }

    private func seg(_ start: Double, _ end: Double, _ text: String) -> Segment {
        var s = Segment(start: start, end: end, original: text)
        s.corrected = text
        return s
    }

    // MARK: - 本体

    /// 実機で起きた形そのもの: 発話が100秒で終わり、以降8分無音なのに end が600秒
    func testEndSpanningSilenceIsTrimmed() {
        let env = envelope(voicedRanges: [(0, 100), (600, 660)], duration: 660)
        let segs = [seg(0, 600, "はい、では一旦休憩挟みます。"), seg(600, 640, "再開します")]
        let (out, report) = HallucinationAuditor().audit(
            segments: segs, envelope: env, totalDuration: 660, engineExposesConfidence: true)

        XCTAssertLessThan(out[0].end, 105, "無音をまたいだ end が切り詰められていない")
        XCTAssertGreaterThan(out[0].end, 99, "発話の終わりより手前まで削ってはいけない")
        XCTAssertEqual(report.stats.overrunTrimmedCount, 1)
        XCTAssertGreaterThan(report.stats.overrunTrimmedSeconds, 400)
        XCTAssertTrue(report.findings.contains { $0.kind == .segmentOverrun },
                      "黙って直している。記録に残っていない")
    }

    /// **先頭側の無音も切り詰める。**
    ///
    /// 末尾だけ切り詰めていたので、セグメントが「長い無音 + 発話」の形になると
    /// 尺が伸びたまま残った。実機では実行のたびにこの形が出たり出なかったりして、
    /// **認識内容は同じ（1083文字 vs 1084文字）なのにカバー率が 73.5% と 95.1% の間で揺れた。**
    /// タイムスタンプの揺れ自体は whisper/Metal 側の問題で消せないが、
    /// 尺をここで正せば、揺れてもカバー率は正しい値に収束する。
    func testStartInsideSilenceIsTrimmed() {
        let env = envelope(voicedRanges: [(500, 660)], duration: 660)
        let segs = [seg(0, 660, "再開します")]   // 先頭500秒が無音なのに start が0
        let (out, report) = HallucinationAuditor().audit(
            segments: segs, envelope: env, totalDuration: 660, engineExposesConfidence: true)

        XCTAssertGreaterThan(out[0].start, 495, "先頭の無音が切り詰められていない")
        XCTAssertLessThan(out[0].start, 501, "発話の始まりより先まで削ってはいけない")
        XCTAssertTrue(report.findings.contains { $0.kind == .segmentOverrun },
                      "黙って直している。記録に残っていない")
    }

    /// 先頭と末尾の両方に無音があるとき、両方削る。
    func testSilenceOnBothSidesIsTrimmed() {
        let env = envelope(voicedRanges: [(300, 360)], duration: 660)
        let segs = [seg(0, 660, "真ん中だけ喋っている")]
        let (out, report) = HallucinationAuditor().audit(
            segments: segs, envelope: env, totalDuration: 660, engineExposesConfidence: true)
        // 両端を削っても「切り詰めたセグメント数」は1。削った秒数は両端の合計。
        XCTAssertEqual(report.stats.overrunTrimmedCount, 1, "1本のセグメントを2本と数えている")
        XCTAssertEqual(report.findings.filter { $0.kind == .segmentOverrun }.count, 2,
                       "先頭と末尾で記録が2件あるべき")
        XCTAssertGreaterThan(report.stats.overrunTrimmedSeconds, 590)

        XCTAssertGreaterThan(out[0].start, 295, "先頭の無音が残っている")
        XCTAssertLessThan(out[0].end, 365, "末尾の無音が残っている")
    }

    /// 短いセグメントの先頭に少し無音があるのは正常。削らない。
    /// ここを削ると、字幕の頭が発話に食い込む。
    func testShortSegmentIsLeftAlone() {
        let env = envelope(voicedRanges: [(1.0, 5.0)], duration: 660)
        let segs = [seg(0.5, 5.5, "短い発話")]
        let (out, _) = HallucinationAuditor().audit(
            segments: segs, envelope: env, totalDuration: 660, engineExposesConfidence: true)

        XCTAssertEqual(out[0].start, 0.5, accuracy: 0.001, "短いセグメントを削っている")
    }

    /// カバー率は「発話のうち書き起こせた割合」であって「総尺のうち」ではない。
    ///
    /// 以前は非破棄セグメントの尺の合計 ÷ 総尺で出しており、無音をまたぐセグメントが
    /// あると 100% と誤報された。いまは無音を分母から外すので、
    /// 8分の休憩があってもカバー率は「喋っている箇所を取れたか」だけを表す。
    func testCoverageMeasuresSpeechNotWallClock() {
        let env = envelope(voicedRanges: [(0, 100), (600, 660)], duration: 660)
        let segs = [seg(0, 600, "はい、では一旦休憩挟みます。"), seg(600, 640, "再開します")]
        let (_, report) = HallucinationAuditor().audit(
            segments: segs, envelope: env, totalDuration: 660, engineExposesConfidence: true)

        // 発話160秒・無音500秒。休憩が分母に入っていないこと。
        XCTAssertEqual(report.stats.voicedSeconds, 160, accuracy: 3.0)
        XCTAssertEqual(report.stats.silentSeconds, 500, accuracy: 3.0)
        // 覆えているのは 0–100 と 600–640 の計140秒ぶん
        XCTAssertEqual(report.stats.transcribedVoicedSeconds, 140, accuracy: 3.0)
        XCTAssertEqual(report.stats.coverageRatio, 140.0 / 160.0, accuracy: 0.03)
        XCTAssertLessThan(report.stats.coverageRatio, 1.0,
                          "末尾20秒の発話を落としているのに100%になっている")
    }

    /// 切り詰めたあとに無音が「見える」ようになること
    func testGapBecomesVisibleAfterTrim() {
        let env = envelope(voicedRanges: [(0, 100), (600, 660)], duration: 660)
        let segs = [seg(0, 600, "はい、では一旦休憩挟みます。"), seg(600, 640, "再開します")]
        let (out, report) = HallucinationAuditor().audit(
            segments: segs, envelope: env, totalDuration: 660, engineExposesConfidence: true)
        let meta = TranscriptMeta(sourceURL: nil, sourceDuration: 660,
                                  engine: "t", modelName: "t", language: "ja")
        let t = Transcript(meta: meta, segments: out, audit: report)
        XCTAssertEqual(t.gaps().count, 1, "切り詰めても無音区間が見えていない")
        XCTAssertGreaterThan(t.gaps().first.map { $0.upperBound - $0.lowerBound } ?? 0, 400)
    }

    // MARK: - 触ってはいけない場合

    func testNormalSegmentIsUntouched() {
        let env = envelope(voicedRanges: [(0, 30)], duration: 30)
        let segs = [seg(0, 5, "ふつうの発話")]
        let (out, report) = HallucinationAuditor().audit(
            segments: segs, envelope: env, totalDuration: 30, engineExposesConfidence: true)
        XCTAssertEqual(out[0].end, 5)
        XCTAssertEqual(report.stats.overrunTrimmedCount, 0)
    }

    /// 長くても最後まで喋っているなら削ってはいけない
    func testLongButFullyVoicedSegmentIsUntouched() {
        let env = envelope(voicedRanges: [(0, 60)], duration: 60)
        let segs = [seg(0, 55, String(repeating: "あ", count: 200))]
        let (out, report) = HallucinationAuditor().audit(
            segments: segs, envelope: env, totalDuration: 60, engineExposesConfidence: true)
        XCTAssertEqual(out[0].end, 55, "最後まで有声なのに削っている")
        XCTAssertEqual(report.stats.overrunTrimmedCount, 0)
    }

    /// 末尾の短い間は誤差。いちいち削ると記録が無意味に増える
    func testShortTrailingSilenceIsIgnored() {
        let env = envelope(voicedRanges: [(0, 19)], duration: 30)
        let segs = [seg(0, 20, "ふつうの発話")]
        let (out, _) = HallucinationAuditor().audit(
            segments: segs, envelope: env, totalDuration: 30, engineExposesConfidence: true)
        XCTAssertEqual(out[0].end, 20)
    }

    /// 区間全体が無音なら尺は触らない。無音ゲートが本文を捨てる判断に任せる。
    func testFullySilentSegmentKeepsItsRangeForTheSilenceGate() {
        let env = envelope(voicedRanges: [], duration: 60)
        let segs = [seg(0, 30, "ご視聴ありがとうございました")]
        let (out, report) = HallucinationAuditor().audit(
            segments: segs, envelope: env, totalDuration: 60, engineExposesConfidence: true)
        XCTAssertEqual(report.stats.overrunTrimmedCount, 0)
        XCTAssertTrue(out[0].isSuppressed, "無音区間の幻聴が破棄されていない")
    }

    /// 切り詰めは短くするだけ。伸ばしてカバー率を水増しできてはいけない。
    func testTrimNeverExtendsASegment() {
        let env = envelope(voicedRanges: [(0, 100)], duration: 660)
        let segs = [seg(0, 20, "短い"), seg(30, 600, "長い")]
        let (out, _) = HallucinationAuditor().audit(
            segments: segs, envelope: env, totalDuration: 660, engineExposesConfidence: true)
        for (before, after) in zip(segs, out) {
            XCTAssertLessThanOrEqual(after.end, before.end, "end が伸びている")
            XCTAssertGreaterThanOrEqual(after.start, before.start, "start が前に伸びている")
        }
    }

    func testTrimmedSegmentKeepsItsText() {
        let env = envelope(voicedRanges: [(0, 100), (600, 660)], duration: 660)
        let segs = [seg(0, 600, "はい、では一旦休憩挟みます。")]
        let (out, _) = HallucinationAuditor().audit(
            segments: segs, envelope: env, totalDuration: 660, engineExposesConfidence: true)
        XCTAssertEqual(out[0].original, "はい、では一旦休憩挟みます。", "尺を直すついでに本文を壊している")
        XCTAssertFalse(out[0].isSuppressed, "喋っている区間を破棄してはいけない")
    }

    // MARK: - lastVoicedTime

    func testLastVoicedTime() {
        let env = envelope(voicedRanges: [(0, 10)], duration: 60)
        let t = env.lastVoicedTime(from: 0, to: 60, threshold: -45)
        XCTAssertNotNil(t)
        XCTAssertEqual(t ?? 0, 10, accuracy: 0.05)
        XCTAssertNil(env.lastVoicedTime(from: 20, to: 60, threshold: -45),
                     "無音しかない範囲で値を返している")
    }
}

/// 照合の既定値。実測に基づいて切ってある。
final class CrossCheckDefaultsTests: XCTestCase {
    func testDifferentReadingJudgementIsOffByDefault() {
        XCTAssertFalse(SessionSettings().judgeDifferentReadings)
        XCTAssertFalse(TranscriptionPipeline.Configuration().judgeDifferentReadings)
    }

    func testSettingIsStillReachableWhenEnabled() {
        var s = SessionSettings()
        s.judgeDifferentReadings = true
        let c = s.makeConfiguration(dictionary: .empty, hasCorrector: true, hasJudge: true)
        XCTAssertTrue(c.judgeDifferentReadings)
    }

    /// 同音異義語の判定（LLMが本来得意な方）は既定でも生きている
    func testMatchingReadingJudgementStaysOnByDefault() {
        XCTAssertTrue(SessionSettings().adjudicateDisagreements)
    }
}
