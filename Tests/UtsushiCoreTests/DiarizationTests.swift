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

    // MARK: - 話者操作（rename / merge / 再割り当て）

    private func transcriptWith(_ speakers: [Int?]) -> Transcript {
        Transcript(meta: TranscriptMeta(sourceURL: nil, sourceDuration: 30,
                                      engine: "test", modelName: "m", language: "ja"),
                   segments: speakers.enumerated().map { i, s in
                       var seg = self.seg(Double(i * 5), Double(i * 5 + 5))
                       seg.speaker = s
                       return seg
                   })
    }

    func testRenameSpeakerStoresName() {
        var t = transcriptWith([1, 1, 2])
        t.renameSpeaker(1, to: "田中")
        XCTAssertEqual(t.speakerName(1), "田中")
        XCTAssertEqual(t.speakerName(2), "話者2")
        XCTAssertEqual(t.speakerIDs, [1, 2])
    }

    /// 空名にすると番号表示に戻る
    func testRenameEmptyClears() {
        var t = transcriptWith([1])
        t.renameSpeaker(1, to: "田中")
        t.renameSpeaker(1, to: "  ")
        XCTAssertEqual(t.speakerName(1), "話者1")
        XCTAssertTrue(t.meta.speakerNames.isEmpty)
    }

    /// 誤分離の統合: from の区間が into に移り、未命名なら名前も移る
    func testMergeSpeakersMovesSegmentsAndName() {
        var t = transcriptWith([1, 2, 1, 2])
        t.renameSpeaker(1, to: "田中")
        t.mergeSpeakers(from: 1, into: 2)
        XCTAssertEqual(t.segments.map(\.speaker), [2, 2, 2, 2])
        XCTAssertEqual(t.speakerName(2), "田中")
        XCTAssertEqual(t.speakerIDs, [2])
    }

    /// 移し先に名前があるときは先側を優先する
    func testMergeKeepsExistingTargetName() {
        var t = transcriptWith([1, 2])
        t.renameSpeaker(1, to: "田中")
        t.renameSpeaker(2, to: "佐藤")
        t.mergeSpeakers(from: 1, into: 2)
        XCTAssertEqual(t.speakerName(2), "佐藤")
    }

    func testSetSpeakerOnOneSegment() {
        var t = transcriptWith([1, 1, 2])
        let id = t.segments[1].id
        t.setSpeaker(of: id, to: 2)
        XCTAssertEqual(t.segments[1].speaker, 2)
        t.setSpeaker(of: id, to: nil)
        XCTAssertNil(t.segments[1].speaker)
    }

    /// 話者名の無い古い JSON も読める（後方互換）
    func testOldJSONWithoutSpeakerNamesDecodes() throws {
        var t = transcriptWith([1])
        t.renameSpeaker(1, to: "田中")
        let data = try JSONEncoder().encode(t)
        // 実際のエンコード結果から speakerNames だけ消して「古い形式」を作る。
        // 手書き JSON だと他フィールドの形がズレたとき嘘の合格になる。
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var meta = try XCTUnwrap(obj["meta"] as? [String: Any])
        meta.removeValue(forKey: "speakerNames")
        obj["meta"] = meta
        let oldData = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(Transcript.self, from: oldData)
        XCTAssertTrue(decoded.meta.speakerNames.isEmpty)
        XCTAssertEqual(decoded.speakerName(1), "話者1")
    }

    /// 付けた名前が書き出しに出る
    func testExportUsesSpeakerNames() {
        var t = transcriptWith([1])
        t.renameSpeaker(1, to: "田中")
        XCTAssertTrue(Exporter().srt(t).contains("田中: "))
        XCTAssertTrue(Exporter().plain(t).contains("【田中】"))
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
