import XCTest

/// 話者分離（Nemotron 3 Diarization）の区間割り当ての検証。
///
/// モデルを引く実機テストは重いので、ここでは割り当てロジックだけを見る。
/// assignSpeakers は「最も重なる区間の話者」を貼る。割り当てられない区間は
/// speaker が nil のまま残り、画面にも「不明」と残る約束。
final class DiarizationTests: XCTestCase {

    private func seg(_ start: Double, _ end: Double, _ text: String = "x") -> Segment {
        Segment(start: start, end: end, original: text)
    }
    private func span(_ start: Double, _ end: Double, _ speaker: Int) -> DiarizationEngine.SpeakerSpan {
        .init(start: start, end: end, speaker: speaker)
    }

    func testAssignsDominantSpeaker() {
        var segments = [seg(0, 5), seg(5, 10)]
        DiarizationEngine.assignSpeakers(to: &segments, spans: [
            span(0, 4, 1), span(4, 10, 2)
        ])
        XCTAssertEqual(segments[0].speaker, 1)
        XCTAssertEqual(segments[1].speaker, 2)
    }

    /// 同時発話で区間が重なっていても、大きく重なる方が選ばれる
    func testOverlapPicksLargestOverlap() {
        var segments = [seg(2, 6)]
        DiarizationEngine.assignSpeakers(to: &segments, spans: [
            span(2.0, 3.0, 1),   // 1秒だけ重なる
            span(2.5, 7.0, 2),   // 3.5秒重なる → これが採用される
        ])
        XCTAssertEqual(segments[0].speaker, 2)
    }

    /// 分離区間が無いところは直近の話者を拾う（穴埋め）
    func testGapFilledFromNearest() {
        var segments = [seg(0, 2), seg(2.5, 4), seg(20, 22)]
        DiarizationEngine.assignSpeakers(to: &segments, spans: [span(0, 2.4, 1)])
        XCTAssertEqual(segments[0].speaker, 1)
        XCTAssertEqual(segments[1].speaker, 1)   // 0.1秒先の区間から拾う
        XCTAssertNil(segments[2].speaker)        // 離れすぎ → 不明のまま
    }

    func testEmptySpansLeavesSpeakersNil() {
        var segments = [seg(0, 2)]
        DiarizationEngine.assignSpeakers(to: &segments, spans: [])
        XCTAssertNil(segments[0].speaker)
    }

    /// 実モデルを通す回帰確認。モデルが導入済みのときだけ走る。
    /// TTS 音声ではなく実音声が要るので、合成音声では走らせない。
    func testRealModelSmoke() async throws {
        guard ProcessInfo.processInfo.environment["UTSUSHI_DIAR_TEST"] == "1" else {
            throw XCTSkip("UTSUSHI_DIAR_TEST=1 のときだけ走る")
        }
        let model = ModelCatalog.diarModel
        guard ModelCatalog.isInstalled(model) else { throw XCTSkip("話者分離モデルが未導入") }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/testclip.m4a")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("検証用クリップが無い") }
        let audio = try await AudioExtractor().extract(url: url)
        let engine = DiarizationEngine()
        try await engine.prepare { _, _ in }
        let spans = try await engine.diarize(samples: audio.samples)
        XCTAssertFalse(spans.isEmpty, "実音声なら区間が返る")
        for s in spans {
            XCTAssertGreaterThan(s.end, s.start)
            XCTAssertGreaterThanOrEqual(s.speaker, 1)
        }
    }
}
