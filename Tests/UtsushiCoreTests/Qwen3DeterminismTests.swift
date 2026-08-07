import XCTest

/// Qwen3-ASR がなぜ実行ごとに違う本文を出すのかを切り分ける。
///
/// 分かっていること:
/// - 同一 recognizer に2回投げると **一致する**
/// - プロセスを分けると **一致しない**（1,855文字/1,865文字、冒頭が毎回別物）
///
/// ということは「認識のたび」ではなく「recognizer を作るたび」か、
/// もしくはプロセス環境に依存する何かが効いている。
/// スレッド数を変えて、ONNX の並列リダクション順が原因かを見る。
final class Qwen3DeterminismTests: XCTestCase {

    private static let clipURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/testclip.m4a")
    }()

    private func transcribe(model: ModelCatalog.Model, threads: Int32,
                            samples: [Float]) async throws -> String {
        var o = SherpaEngine.Options()
        o.threads = threads
        let engine = SherpaEngine(model: model, options: o)
        try await engine.prepare { _, _ in }
        let segs = try await engine.transcribe(
            ASRRequest(samples: samples, language: "ja", useVAD: false),
            progress: { _ in }, isCancelled: { false })
        engine.shutdown()
        return segs.map(\.text).joined()
    }

    func testDeterminismAcrossRecognizerInstances() async throws {
        guard FileManager.default.fileExists(atPath: Self.clipURL.path) else {
            throw XCTSkip("検証用クリップが無い")
        }
        // 手元にある 0.6B で切り分ける（1.7B は取得に時間がかかるため）
        guard let model = ModelCatalog.sherpaModels.first(where: {
            $0.engine == .sherpaQwen3ASR && ModelCatalog.isInstalled($0)
        }) else { throw XCTSkip("導入済みの qwen3-asr が無い") }

        // 素材を短くする。ここで見たいのは精度ではなく再現性なので、
        // 冒頭2分あれば揺れる箇所（曖昧な語）は十分含まれる。
        let full = try await AudioExtractor().extract(url: Self.clipURL,
                                                      progress: { _ in }, isCancelled: { false })
        let take = min(full.samples.count, Int(AudioExtractor.sampleRate) * 120)
        let samples = Array(full.samples[0..<take])

        var results: [Int32: [String]] = [:]
        for threads: Int32 in [6, 1] {
            var runs: [String] = []
            for i in 0..<2 {
                let t = try await transcribe(model: model, threads: threads, samples: samples)
                runs.append(t)
                print("[threads=\(threads) run\(i + 1)] \(t.count)文字 / 冒頭: \(t.prefix(60))")
            }
            results[threads] = runs
        }

        let six = results[6] ?? []
        let one = results[1] ?? []
        print("=== 切り分け結果 ===")
        print("threads=6: インスタンスをまたいで " + (six[0] == six[1] ? "一致" : "不一致"))
        print("threads=1: インスタンスをまたいで " + (one[0] == one[1] ? "一致" : "不一致"))

        // スレッド数1で揺れが止まるなら、原因は並列リダクション順。
        // それでも揺れるなら、この用途（照合・CER計測）には使えない。
        XCTAssertEqual(one[0], one[1],
                       "threads=1 でもインスタンスごとに出力が変わる。"
                       + "並列化が原因ではないので、生成型ASRを計測・照合に使う前提が成り立たない")
    }
}
