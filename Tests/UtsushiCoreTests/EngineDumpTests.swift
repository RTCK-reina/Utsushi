import XCTest

/// 調査用。導入済みの全エンジンで同じ音声を認識し、本文と統計を吐く。
///
/// 目的は CER の順位付けではなく、**書き出しを LLM が読んだときに理解できるか**の比較。
/// 文字単位の一致率は句読点もフィラーも固有名詞も同じ重みで数えるので、この用途では
/// 指標として合わない（詳細は会話ログ）。ここでは素の本文を出すところまでをやり、
/// 判断は本文そのものを読んで行う。
///
///   TEST_RUNNER_UTSUSHI_CMP_MEDIA=/path/to.m4a \
///   TEST_RUNNER_UTSUSHI_CMP_MODELS=ggml-large-v3-turbo,sherpa-sense-voice-2024-07-17 \
///   TEST_RUNNER_UTSUSHI_CMP_OUT=/tmp/cmp \
///   xcodebuild ... -only-testing:UtsushiTests/EngineDumpTests
final class EngineDumpTests: XCTestCase {
    func testDumpAllEngines() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let media = env["UTSUSHI_CMP_MEDIA"], let outDir = env["UTSUSHI_CMP_OUT"] else {
            throw XCTSkip("UTSUSHI_CMP_MEDIA / UTSUSHI_CMP_OUT が無いので走らない（調査用）")
        }
        let ids = (env["UTSUSHI_CMP_MODELS"] ?? "").split(separator: ",").map(String.init)
        let models = ModelCatalog.allModels.filter {
            ids.isEmpty ? ModelCatalog.isInstalled($0) && $0.engine != .sileroVAD
                        : ids.contains($0.id)
        }
        XCTAssertFalse(models.isEmpty, "対象モデルが無い")
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let audio = try await AudioExtractor().extract(url: URL(fileURLWithPath: media),
                                                       progress: { _ in }, isCancelled: { false })
        var summary = "音声 \(String(format: "%.0f", audio.duration))秒\n\n"
        summary += "| モデル | 秒 | 倍速 | セグメント | 文字数 | 最後のend |\n|---|---|---|---|---|---|\n"

        /// 出力を書き出して統計を1行返す。
        func record(_ id: String, _ segs: [Segment], _ elapsed: Double) throws -> String {
            let text = segs.map(\.text).joined()
            var tsv = "start\tend\ttext\n"
            for s in segs {
                tsv += String(format: "%.2f\t%.2f\t", s.start, s.end)
                    + s.original.replacingOccurrences(of: "\t", with: " ") + "\n"
            }
            try tsv.write(toFile: "\(outDir)/\(id).tsv", atomically: true, encoding: .utf8)
            var body = ""
            var bucket = -1
            for s in segs {
                let b = Int(s.start / 600)
                if b != bucket { body += "\n\n=== \(b * 10)分 ===\n"; bucket = b }
                body += s.text
            }
            try body.write(toFile: "\(outDir)/\(id).txt", atomically: true, encoding: .utf8)
            print("[cmp] \(id): \(String(format: "%.0f", elapsed))秒 / \(segs.count)セグ / \(text.count)文字")
            return "| \(id) | \(String(format: "%.0f", elapsed)) "
                + "| \(String(format: "%.0f", audio.duration / max(elapsed, 0.001)))x "
                + "| \(segs.count) | \(text.count) | \(String(format: "%.0f", segs.last?.end ?? 0)) |\n"
        }

        // OS内蔵の SpeechTranscriber。カタログのモデルではないので別扱い。
        if ids.contains("apple"), #available(macOS 26.0, *) {
            let engine = SpeechAnalyzerEngine(locale: Locale(identifier: "ja-JP"))
            do {
                try await engine.prepare { m, _ in print("[apple] \(m)") }
                let t0 = Date()
                let segs = try await engine.transcribe(
                    ASRRequest(samples: audio.samples, language: "ja", useVAD: false),
                    progress: { _ in }, isCancelled: { false })
                summary += try record("apple-speechtranscriber", segs, Date().timeIntervalSince(t0))
            } catch {
                print("[skip] apple: \(error)")
            }
        }

        for model in models {
            guard ModelCatalog.isInstalled(model) else {
                print("[skip] \(model.id) 未導入"); continue
            }
            let engine: any ASREngine = model.engine == .whisper
                ? WhisperEngine(model: model)
                : SherpaEngine(model: model)
            do {
                try await engine.prepare { _, _ in }
            } catch {
                print("[skip] \(model.id) prepare 失敗: \(error)"); continue
            }
            let t0 = Date()
            let segs: [Segment]
            do {
                segs = try await engine.transcribe(
                    ASRRequest(samples: audio.samples, language: "ja", useVAD: engine.supportsVAD),
                    progress: { _ in }, isCancelled: { false })
            } catch {
                print("[skip] \(model.id) 認識失敗: \(error)")
                (engine as? WhisperEngine)?.shutdown(); (engine as? SherpaEngine)?.shutdown()
                continue
            }
            let elapsed = Date().timeIntervalSince(t0)
            (engine as? WhisperEngine)?.shutdown()
            (engine as? SherpaEngine)?.shutdown()

            summary += try record(model.id, segs, elapsed)
        }
        try summary.write(toFile: "\(outDir)/summary.md", atomically: true, encoding: .utf8)
        print(summary)
    }
}
