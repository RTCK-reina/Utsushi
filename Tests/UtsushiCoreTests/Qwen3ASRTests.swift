import XCTest

/// Qwen3-ASR（LLMデコーダ型）を実物で確かめる。
///
/// zipformer / nemo-ctc は音響から素直に写すが、これは文脈から補って**書く**。
/// だから「動くか」だけでは足りず、**同じ音声から同じ本文が出るか**を必ず見る。
/// 温度が効いていると、照合の食い違いも CER の数字も実行のたびに変わって意味を失う。
final class Qwen3ASRTests: XCTestCase {

    private static let clipURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/testclip.m4a")
    }()

    /// 導入済みの Qwen3-ASR を同じ素材で回して並べる。
    /// サイズを上げた効果があるのかを、憶測ではなく同一条件で見る。
    func testAllQwen3ModelsTranscribeAndAreDeterministic() async throws {
        guard FileManager.default.fileExists(atPath: Self.clipURL.path) else {
            throw XCTSkip("検証用クリップが無い")
        }
        let models = ModelCatalog.sherpaModels.filter { $0.engine == .sherpaQwen3ASR }
        // 導入済みのものだけを回す。
        // Qwen3 はプロセス間で再現しないと分かったのでモデル実体は消してあり、
        // ここで未導入のものまで回すと 940MB の再取得が走ってしまう。
        let installed = models.filter { ModelCatalog.isInstalled($0) }
        guard !installed.isEmpty else {
            throw XCTSkip("導入済みの qwen3-asr が無い（設定で有効にすると取得される）")
        }

        let audio = try await AudioExtractor().extract(url: Self.clipURL,
                                                       progress: { _ in }, isCancelled: { false })
        var summaries: [String] = []

        for model in installed {
            let engine = SherpaEngine(model: model)
            let t0 = Date()
            do {
                try await engine.prepare { msg, p in if p == 0 || p >= 1 { print("[" + model.id + "] " + msg) } }
            } catch {
                XCTFail("[" + model.id + "] 準備に失敗: " + String(describing: error))
                continue
            }
            let prepared = Date().timeIntervalSince(t0)

            let t1 = Date()
            let first = try await engine.transcribe(
                ASRRequest(samples: audio.samples, language: "ja", useVAD: false),
                progress: { _ in }, isCancelled: { false })
            let elapsed = Date().timeIntervalSince(t1)

            let second = try await engine.transcribe(
                ASRRequest(samples: audio.samples, language: "ja", useVAD: false),
                progress: { _ in }, isCancelled: { false })
            engine.shutdown()

            let a = first.map(\.text).joined()
            let b = second.map(\.text).joined()
            let speed = audio.duration / max(elapsed, 0.001)
            let line = "[" + model.id + "] 準備 " + String(format: "%.1f", prepared)
                + "秒 / 認識 " + String(format: "%.1f", elapsed) + "秒（"
                + String(format: "%.1f", speed) + "倍速） / "
                + String(first.count) + "セグメント " + String(a.count) + "文字"
            print(line)
            print("[" + model.id + "] 冒頭: " + String(a.prefix(160)))
            summaries.append(line)

            XCTAssertFalse(first.isEmpty, "[" + model.id + "] セグメントが1件も返っていない")
            XCTAssertGreaterThan(a.count, 200, "[" + model.id + "] 文字数が少なすぎる")
            // 判定は `JapaneseTextCheck`。漢字比率ではなくかな比率で見る
            // （漢字比率では中国語と区別できない、句読点と算用数字で値が動く）。
            XCTAssertGreaterThan(JapaneseTextCheck.kanaRatio(a),
                                 JapaneseTextCheck.minimumKanaRatio,
                                 "[" + model.id + "] 日本語になっていない: " + String(a.prefix(80)))
            XCTAssertGreaterThan(first.last?.end ?? 0, 60, "[" + model.id + "] 後半が認識されていない")
            // 注意: これは**同一プロセス内**の一致しか見ていない。
            // プロセスをまたぐと出力は変わる（Qwen3DeterminismTests 参照）。
            // 通ったからといって「再現性がある」と読んではいけない。
            XCTAssertEqual(a, b, "[" + model.id + "] 同一プロセス内ですら出力が揺れている")
        }

        print("=== Qwen3-ASR まとめ ===")
        for s in summaries { print(s) }
    }
}
