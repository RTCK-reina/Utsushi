import XCTest

/// SenseVoice を実物で確かめる。
///
/// 狙いは Qwen3-ASR の代わりになるかどうか。非自己回帰なので
/// 「文脈から補って書く」ことがなく、プロセス間で揺れる理由も構造上無いはず。
/// **その「はず」を実際に確かめる**のがこのテストの目的。
///
/// 経緯: 最初は 2025-09-09 版を入れていて、11分の素材から287文字しか出ず、
/// しかも「目标」「上长」のような簡体字混じりだった。トークンの束ね方か
/// 言語指定を疑ったが、どちらも外れ。onnx のメタデータを読んだら
/// `comment=ASLP-lab/WSYue-ASR` で、**広東語向けの別モデル**だった。
/// リリース名が sense-voice-zh-en-ja-ko-yue と続いていたので気づけなかった。
/// 2024-07-17 版（本家 FunASR の SenseVoice-Small）に替えたら 1,104文字・89.8倍速。
///
/// 教訓は2つ:
/// - 出力が「日本語に見える」ことを合格条件にしない（漢字比率では中国語と区別できない）
/// - リリース名の連続性をモデルの同一性の根拠にしない
final class SenseVoiceTests: XCTestCase {

    private static let clipURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/testclip.m4a")
    }()

    private func model() throws -> ModelCatalog.Model {
        guard let m = ModelCatalog.sherpaModels.first(where: { $0.engine == .sherpaSenseVoice }) else {
            throw XCTSkip("sense-voice がカタログに無い")
        }
        return m
    }

    func testTranscribesJapanese() async throws {
        guard FileManager.default.fileExists(atPath: Self.clipURL.path) else {
            throw XCTSkip("検証用クリップが無い")
        }
        let m = try model()
        let audio = try await AudioExtractor().extract(url: Self.clipURL,
                                                       progress: { _ in }, isCancelled: { false })
        let engine = SherpaEngine(model: m)
        let t0 = Date()
        try await engine.prepare { msg, p in if p == 0 || p >= 1 { print("[sense-voice] " + msg) } }
        let prepared = Date().timeIntervalSince(t0)

        let t1 = Date()
        let segs = try await engine.transcribe(
            ASRRequest(samples: audio.samples, language: "ja", useVAD: false),
            progress: { _ in }, isCancelled: { false })
        let elapsed = Date().timeIntervalSince(t1)
        engine.shutdown()

        let text = segs.map(\.text).joined()
        print("[sense-voice] 準備 " + String(format: "%.1f", prepared) + "秒 / 認識 "
              + String(format: "%.1f", elapsed) + "秒（"
              + String(format: "%.1f", audio.duration / max(elapsed, 0.001)) + "倍速） / "
              + String(segs.count) + "セグメント " + String(text.count) + "文字")
        print("[sense-voice] 冒頭: " + String(text.prefix(160)))

        XCTAssertFalse(segs.isEmpty, "セグメントが1件も返っていない")

        // 文字数は他エンジンと比べる。この素材では whisper 1,064 / zipformer 952 /
        // parakeet 1,006 文字なので、半分を切っていたら取りこぼしている。
        // 「200文字超」のような緩い下限だと、287文字の壊れた出力が素通りした（実際にした）。
        XCTAssertGreaterThan(text.count, 600,
                             "他エンジンの半分以下しか取れていない（" + String(text.count) + "文字）")

        // かなの比率で見る。**CJK統合漢字の比率では日本語と中国語を区別できない**。
        // 実際、中国語寄りの出力（「目标」「振行」）が漢字比率のチェックを素通りした。
        // 判定は `JapaneseTextCheck` に寄せてある（EndToEndTests と条件がずれないように）。
        XCTAssertGreaterThan(JapaneseTextCheck.kanaRatio(text),
                             JapaneseTextCheck.minimumKanaRatio,
                             "かなが少なすぎる。日本語ではなく中国語として認識している疑い: "
                             + String(text.prefix(80)))

        // セグメントあたりの文字数。細切れすぎるなら出力の組み立てが壊れている。
        let perSegment = Double(text.count) / Double(max(segs.count, 1))
        XCTAssertGreaterThan(perSegment, 8,
                             "1セグメントあたり " + String(format: "%.1f", perSegment)
                             + "文字しかない。トークンの束ね方が合っていない")
        XCTAssertGreaterThan(segs.last?.end ?? 0, 60, "後半が認識されていない")
        // 言語タグ等のメタ文字列が本文に混ざっていないこと（SenseVoice は
        // <|ja|><|NEUTRAL|> のようなタグを吐くことがある）
        XCTAssertFalse(text.contains("<|"), "メタタグが本文に混ざっている: " + String(text.prefix(80)))
    }

    /// Qwen3 が落ちたのはここ。非自己回帰なら通るはず。
    /// このテストは**プロセス内**しか見ていないので、プロセス間は
    /// 実行を2回に分けて比べる必要がある（Qwen3 で痛い目を見た）。
    func testDeterministicAcrossInstances() async throws {
        guard FileManager.default.fileExists(atPath: Self.clipURL.path) else {
            throw XCTSkip("検証用クリップが無い")
        }
        let m = try model()
        guard ModelCatalog.isInstalled(m) else { throw XCTSkip("sense-voice が未導入") }

        let full = try await AudioExtractor().extract(url: Self.clipURL,
                                                      progress: { _ in }, isCancelled: { false })
        let take = min(full.samples.count, Int(AudioExtractor.sampleRate) * 120)
        let samples = Array(full.samples[0..<take])

        var outs: [String] = []
        for i in 0..<2 {
            let e = SherpaEngine(model: m)
            try await e.prepare { _, _ in }
            let s = try await e.transcribe(
                ASRRequest(samples: samples, language: "ja", useVAD: false),
                progress: { _ in }, isCancelled: { false })
            e.shutdown()
            let t = s.map(\.text).joined()
            outs.append(t)
            print("[sense-voice inst\(i + 1)] \(t.count)文字 / 冒頭: \(t.prefix(60))")
        }
        XCTAssertEqual(outs[0], outs[1], "インスタンスをまたいで出力が変わった")
    }
}
