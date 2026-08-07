import XCTest

/// 監査で見つかった「作ったのに繋がっていない」の再発を止める。
///
/// 無音区間は**音声から**出す。当初はセグメントの隙間から推測していたが、
/// 無音をまたぐセグメントが1つあるだけで8分の休憩が見えなくなった。
final class AuditVisibilityTests: XCTestCase {

    private func seg(_ start: Double, _ end: Double, _ text: String) -> Segment {
        var s = Segment(start: start, end: end, original: text)
        s.corrected = text
        return s
    }

    /// hop 0.02秒のエンベロープ。voicedRanges 以外は無音。
    private func envelope(voiced: [(Double, Double)], duration: Double,
                          hop: Double = 0.02) -> AudioEnvelope {
        let n = Int(duration / hop)
        var v = [Float](repeating: -80, count: n)
        for (s, e) in voiced {
            let i0 = max(0, Int(s / hop)), i1 = min(n, Int(e / hop))
            guard i0 < i1 else { continue }
            for i in i0..<i1 { v[i] = -20 }
        }
        return AudioEnvelope(values: v, hop: hop)
    }

    /// 監査を通した Transcript を作る。gaps / カバー率は監査層が埋めるので、
    /// 監査を通していない Transcript で確かめても意味がない。
    private func audited(_ segs: [Segment], voiced: [(Double, Double)],
                         duration: Double) -> Transcript {
        let env = envelope(voiced: voiced, duration: duration)
        let (out, report) = HallucinationAuditor().audit(
            segments: segs, envelope: env, totalDuration: duration, engineExposesConfidence: true)
        let meta = TranscriptMeta(sourceURL: URL(fileURLWithPath: "/tmp/a.m4a"),
                                  sourceDuration: duration,
                                  engine: "test", modelName: "test", language: "ja")
        return Transcript(meta: meta, segments: out, audit: report)
    }

    // MARK: - 破棄した本文が取り出せる

    /// 幻聴を捨てたことは件数で分かっても、何を捨てたかが見えないと誤爆に気づけない
    func testSuppressedSegmentsAreRetrievable() {
        var ghost = seg(300, 310, "ご視聴ありがとうございました")
        ghost.flags.insert(.silenceSuppressed)
        var loop = seg(20, 24, "はいはいはい")
        loop.flags.insert(.repetitionLoop)
        let t = audited([seg(0, 5, "本題です"), loop, ghost],
                        voiced: [(0, 30)], duration: 400)

        XCTAssertEqual(t.suppressedSegments.count, 2)
        XCTAssertFalse(t.visibleSegments.contains { $0.original.contains("ご視聴") })
        XCTAssertEqual(t.suppressedSegments.last?.original, "ご視聴ありがとうございました",
                       "破棄しても原文は壊さない")
    }

    func testSuppressedSegmentsExcludeEmptyOnes() {
        var empty = seg(10, 14, "")
        empty.flags.insert(.silenceSuppressed)
        XCTAssertTrue(audited([empty], voiced: [(0, 5)], duration: 20).suppressedSegments.isEmpty)
    }

    // MARK: - 無音区間

    /// 実素材の形。休憩直前のセグメントの end が「次に喋り出す時刻」に置かれるため、
    /// セグメントの隙間はゼロになる。それでも休憩は見えなければならない。
    func testSilenceIsVisibleEvenWhenASegmentSpansIt() {
        let t = audited([seg(0, 500, "前半のおわり"), seg(500, 540, "再開します")],
                        voiced: [(0, 100), (500, 540)], duration: 560)
        let g = t.gaps()
        XCTAssertEqual(g.count, 1, "セグメントがまたいでいる無音が見えていない")
        XCTAssertEqual(g.first?.lowerBound ?? 0, 100, accuracy: 1.0)
        XCTAssertEqual(g.first?.upperBound ?? 0, 500, accuracy: 1.0)
    }

    func testShortGapIsIgnored() {
        let t = audited([seg(0, 10, "あ"), seg(15, 20, "い")],
                        voiced: [(0, 10), (15, 20)], duration: 20)
        XCTAssertTrue(t.gaps().isEmpty, "5秒の間を休憩として報告してはいけない")
    }

    func testLeadingAndTrailingSilenceAreReported() {
        let t = audited([seg(100, 110, "本編")],
                        voiced: [(100, 110)], duration: 300)
        let g = t.gaps()
        XCTAssertEqual(g.count, 2)
        XCTAssertEqual(g.first?.lowerBound ?? -1, 0, accuracy: 0.1)
        XCTAssertEqual(g.last?.upperBound ?? 0, 300, accuracy: 1.0)
    }

    func testNoSilenceMeansNoGaps() {
        let t = audited([seg(0, 60, "ずっと喋っている")], voiced: [(0, 60)], duration: 60)
        XCTAssertTrue(t.gaps().isEmpty)
    }

    /// 無音区間は音声由来なので、字幕や文字数には一切影響してはいけない
    func testGapsDoNotAffectCountsOrSubtitles() {
        let t = audited([seg(0, 100, "前半"), seg(500, 540, "後半")],
                        voiced: [(0, 100), (500, 540)], duration: 560)
        XCTAssertEqual(t.totalCharacters, 4)
        let srt = Exporter().srt(t)
        XCTAssertFalse(srt.contains("発話なし"), "字幕に無音表示が混ざっている")
        XCTAssertEqual(srt.components(separatedBy: "-->").count - 1, 2)
    }

    // MARK: - カバー率

    /// 以前は「非破棄セグメントの尺の合計 / 総尺」で出しており、
    /// 無音をまたぐセグメントがあると 100% と誤報された。
    func testCoverageIgnoresSilenceInTheDenominator() {
        let t = audited([seg(0, 500, "前半のおわり"), seg(500, 540, "再開します")],
                        voiced: [(0, 100), (500, 540)], duration: 560)
        // 有声は 140秒、うち文字起こしが覆っているのはほぼ全部
        XCTAssertEqual(t.audit.stats.voicedSeconds, 140, accuracy: 3.0)
        XCTAssertEqual(t.audit.stats.silentSeconds, 420, accuracy: 3.0)
        XCTAssertGreaterThan(t.audit.stats.coverageRatio, 0.9, "喋っている箇所は取れているのに低すぎる")
        XCTAssertLessThanOrEqual(t.audit.stats.coverageRatio, 1.0, "100%を超えてはいけない")
    }

    /// 実際に取りこぼしたらカバー率が下がること（下がらないなら指標の意味が無い）
    func testCoverageDropsWhenSpeechIsMissed() {
        let t = audited([seg(0, 50, "前半だけ書き起こした")],
                        voiced: [(0, 50), (200, 250)], duration: 300)
        XCTAssertLessThan(t.audit.stats.coverageRatio, 0.6, "後半50秒の発話を落としているのに高すぎる")
    }

    // MARK: - 出力に残る

    /// 破棄した本文は JSON にだけ残す。共有される成果物に幻聴を混ぜないため。
    func testDiscardedTextStaysOutOfSharedFormats() throws {
        var ghost = seg(300, 310, "ご視聴ありがとうございました")
        ghost.flags.insert(.silenceSuppressed)
        let t = audited([seg(0, 100, "前半"), ghost, seg(500, 540, "後半")],
                        voiced: [(0, 100), (500, 540)], duration: 560)
        XCTAssertFalse(t.suppressedSegments.isEmpty, "前提が崩れている")

        for f in ExportFormat.allCases {
            let s = String(data: try Exporter().render(t, as: f), encoding: .utf8) ?? ""
            if f == .json {
                XCTAssertTrue(s.contains("ご視聴ありがとうございました"), "JSONに記録が残っていない")
            } else {
                XCTAssertFalse(s.contains("ご視聴ありがとうございました"),
                               "\(f.rawValue) に破棄済み本文が漏れている")
            }
        }
        XCTAssertTrue(Exporter().markdown(t).contains("検証記録タブ"))
    }

    func testMarkdownMarksSilentGap() {
        let t = audited([seg(0, 500, "前半のおわり"), seg(500, 540, "再開します")],
                        voiced: [(0, 100), (500, 540)], duration: 560)
        XCTAssertTrue(Exporter().markdown(t).contains("発話なし"), "無音区間が本文に明示されていない")
    }

    func testMarkdownOmitsGapNoticeWhenContinuous() {
        let t = audited([seg(0, 60, "ずっと喋っている")], voiced: [(0, 60)], duration: 60)
        let md = Exporter().markdown(t)
        XCTAssertFalse(md.contains("発話なし"))
        XCTAssertFalse(md.contains("検証記録タブ"), "破棄が無いのに案内が出ている")
    }
}
