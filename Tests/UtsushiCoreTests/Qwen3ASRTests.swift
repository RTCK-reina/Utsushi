import XCTest

/// Qwen3-ASR（LLMデコーダ型）を実物で確かめる。
///
/// 他の2つの照合エンジンと性質が違う。zipformer / nemo-ctc は音響から素直に写すが、
/// これは文脈から補って**書く**。だから「動くか」だけでは足りず、
/// **同じ音声から同じ本文が出るか**を必ず見る。
/// 温度が効いていると、照合の食い違いも CER の数字も実行のたびに変わって意味を失う。
final class Qwen3ASRTests: XCTestCase {

    private static let clipURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/testclip.m4a")
    }()

    func testTranscribesJapaneseAndIsDeterministic() async throws {
        guard FileManager.default.fileExists(atPath: Self.clipURL.path) else {
            throw XCTSkip("検証用クリップが無い")
        }
        guard let model = ModelCatalog.sherpaModels.first(where: { $0.engine == .sherpaQwen3ASR }) else {
            throw XCTSkip("qwen3-asr がカタログに無い")
        }
        let audio = try await AudioExtractor().extract(url: Self.clipURL,
                                                       progress: { _ in }, isCancelled: { false })

        let engine = SherpaEngine(model: model)
        let t0 = Date()
        try await engine.prepare { msg, p in if p == 0 || p >= 1 { print("[qwen3] " + msg) } }
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
        print("[qwen3] 準備 " + String(format: "%.1f", prepared) + "秒 / 認識 "
              + String(format: "%.1f", elapsed) + "秒（音声 "
              + String(format: "%.0f", audio.duration) + "秒・"
              + String(format: "%.1f", speed) + "倍速） / "
              + String(first.count) + "セグメント " + String(a.count) + "文字")
        print("[qwen3] 冒頭: " + String(a.prefix(140)))

        XCTAssertFalse(first.isEmpty, "セグメントが1件も返っていない")
        XCTAssertGreaterThan(a.count, 200, "文字数が少なすぎる。実質認識できていない疑い")

        let japanese = a.unicodeScalars.filter {
            (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
        }.count
        XCTAssertGreaterThan(Double(japanese) / Double(max(a.count, 1)), 0.5,
                             "日本語になっていない: " + String(a.prefix(80)))
        XCTAssertGreaterThan(first.last?.end ?? 0, 60, "後半が認識されていない")

        // ここが本題。生成型を照合や計測に使う前提が成り立つかどうか。
        XCTAssertEqual(a, b,
                       "同じ音声から違う本文が出た。生成が決定的でない＝照合にも計測にも使えない")
    }
}
