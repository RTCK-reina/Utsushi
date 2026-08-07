import XCTest
import Speech
import FoundationModels

/// エンジン比較と、オンデバイスLLMの実測値。
/// 「実装したが動かしていない」を残さないための計測用。
final class EngineComparisonTests: XCTestCase {

    private static let clipURL: URL = {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent("fixtures/testclip.m4a")
    }()
    private static let silentStart: Double = 101
    private static let silentEnd: Double = 603

    func testFoundationModelsCapabilities() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26+") }
        let model = SystemLanguageModel.default
        guard model.isAvailable else { throw XCTSkip("Apple Intelligence が無効") }
        print("=== Foundation Models ===")
        print("contextSize: \(model.contextSize) tokens")

        // 実際に何文字まで入るかを測る。要約機能の設計に効く。
        let session = LanguageModelSession(instructions: "入力された文章の主題を1文で答える。")
        let unit = "本日はお集まりいただきましてありがとうございます。弊社の事業内容についてご説明します。"
        for repeats in [10, 40, 100, 200, 400] {
            let text = String(repeating: unit, count: repeats)
            do {
                let t0 = Date()
                _ = try await session.respond(to: "次の文章の主題を1文で:\n\(text)",
                                              options: GenerationOptions(samplingMode: .greedy,
                                                                         maximumResponseTokens: 60))
                print("  \(text.count) 文字 → OK (\(String(format: "%.1f", Date().timeIntervalSince(t0)))s)")
            } catch {
                print("  \(text.count) 文字 → 失敗: \(error)")
                break
            }
        }
    }

    func testSpeechTranscriberOnRealRecording() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26+") }
        guard FileManager.default.fileExists(atPath: Self.clipURL.path) else {
            throw XCTSkip("検証用クリップが無い")
        }
        let locale = Locale(identifier: "ja-JP")
        guard await SpeechAnalyzerEngine.isLocaleSupported(locale) else {
            print("=== SpeechTranscriber: ja-JP は非対応 ===")
            let supported = await SpeechTranscriber.supportedLocales
            print("対応ロケール: \(supported.map { $0.identifier(.bcp47) }.sorted().joined(separator: ", "))")
            throw XCTSkip("ja-JP 非対応")
        }

        let engine = SpeechAnalyzerEngine(locale: locale)
        let t0 = Date()
        try await engine.prepare { msg, p in print("  prepare: \(msg) \(Int(p * 100))%") }
        let prepared = Date().timeIntervalSince(t0)

        let audio = try await AudioExtractor().extract(url: Self.clipURL)
        let t1 = Date()
        let segments = try await engine.transcribe(
            ASRRequest(samples: audio.samples, language: "ja"),
            progress: { _ in }, isCancelled: { false })
        let elapsed = Date().timeIntervalSince(t1)

        let chars = segments.reduce(0) { $0 + $1.original.count }
        let inSilence = segments.filter {
            $0.start >= Self.silentStart + 10 && $0.end <= Self.silentEnd - 10 && !$0.original.isEmpty
        }
        print("=== Apple SpeechTranscriber (ja-JP) ===")
        print("準備: \(String(format: "%.1f", prepared))s / 認識: \(String(format: "%.1f", elapsed))s（音声 \(String(format: "%.0f", audio.duration))s）")
        print("セグメント: \(segments.count) / 文字数: \(chars)")
        print("無音区間(101–603s)に出た本文: \(inSilence.count) 件")
        for s in inSilence.prefix(5) {
            print("   \(Exporter.hms(s.start)) 「\(s.original.prefix(40))」")
        }
        print("--- 冒頭 ---")
        for s in segments.prefix(8) {
            print("   \(Exporter.hms(s.start)) \(s.original)")
        }
        print("--- 休憩明け（603s以降） ---")
        for s in segments.filter({ $0.start >= Self.silentEnd }).prefix(5) {
            print("   \(Exporter.hms(s.start)) \(s.original)")
        }

        XCTAssertFalse(segments.isEmpty, "SpeechTranscriber が何も返していない")
    }
}
