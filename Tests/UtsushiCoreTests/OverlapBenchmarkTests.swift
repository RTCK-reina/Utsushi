import XCTest

/// 一次認識（whisper / Metal）と照合エンジン（sherpa / CPU）を**重ねて**走らせたときの
/// 壁時計時間と、認識内容が変わらないことを実測する。
///
/// パイプラインは照合を一次認識の後に直列で回している。whisper は GPU、sherpa は CPU なので
/// 重ねれば照合の時間がほぼ消えるはずだが、CLAUDE.md にある通り whisper のタイムスタンプは
/// 実行時の負荷で揺れる。**本文が同じで時刻だけが動く**ことをここで確かめてから、
/// パイプラインの構造を変える。数字なしに機構を足さない（§6）。
///
/// 実測（2026-09-04, M5 Pro, 11分クリップ, 照合3本）:
///
/// | | whisper | 照合 | 合計 |
/// |---|---|---|---|
/// | 直列 | 6.5秒 | 26.1秒 | 32.7秒 |
/// | 重ね | — | — | 26.2秒（20%短縮）|
///
/// 照合3本の本文は完全一致。**whisper は読点1文字だけ変わった**（「1コマ、90分」→「1コマ90分」。
/// 1083字 vs 1082字）。CLAUDE.md の「本文は揺れない」は句読点レベルでは成り立たない。
/// 短縮できるのは whisper の尺（照合より短い方）に限られ、2時間でも1分程度なので、
/// 一次認識を非決定にしてまで重ねる価値は無いと判断してパイプラインは直列のまま。
///
/// 実モデルが要るので、既定では走らない。xcodebuild は環境変数を TEST_RUNNER_ 接頭辞で渡す:
///   TEST_RUNNER_UTSUSHI_BENCH_OVERLAP=1 xcodebuild ... -only-testing:UtsushiTests/OverlapBenchmarkTests
final class OverlapBenchmarkTests: XCTestCase {

    private static let clipURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/testclip.m4a")
    }()

    func testOverlappingCrossCheckWithPrimaryKeepsTextAndSavesTime() async throws {
        guard ProcessInfo.processInfo.environment["UTSUSHI_BENCH_OVERLAP"] == "1" else {
            throw XCTSkip("UTSUSHI_BENCH_OVERLAP=1 のときだけ走る（実モデルで数分かかる）")
        }
        let url = Self.clipURL
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("検証用クリップが無い") }
        guard ModelCatalog.isInstalled(ModelCatalog.whisperModels[0]) else { throw XCTSkip("whisperモデルが未導入") }
        let sherpaModels = ModelCatalog.sherpaModels.filter { ModelCatalog.isInstalled($0) }
        guard !sherpaModels.isEmpty else { throw XCTSkip("照合エンジンが未導入") }

        let audio = try await AudioExtractor().extract(url: url, progress: { _ in }, isCancelled: { false })
        let request = ASRRequest(samples: audio.samples, language: "ja", useVAD: true)
        let sherpaRequest = ASRRequest(samples: audio.samples, language: "ja", useVAD: false)

        // 準備（モデル読み込み）は計測に入れない。
        let whisper = WhisperEngine()
        try await whisper.prepare { _, _ in }
        let sherpas = sherpaModels.map { SherpaEngine(model: $0) }
        for e in sherpas { try await e.prepare { _, _ in } }
        defer { whisper.shutdown(); sherpas.forEach { $0.shutdown() } }

        @Sendable func runSherpas() async throws -> [[Segment]] {
            var out: [[Segment]] = []
            for e in sherpas {
                out.append(try await e.transcribe(sherpaRequest, progress: { _ in }, isCancelled: { false }))
            }
            return out
        }

        // 直列
        let t0 = Date()
        let seqWhisper = try await whisper.transcribe(request, progress: { _ in }, isCancelled: { false })
        let tWhisper = Date().timeIntervalSince(t0)
        let seqSherpa = try await runSherpas()
        let tSequential = Date().timeIntervalSince(t0)

        // 重ねる
        let t1 = Date()
        async let ovlWhisperTask = whisper.transcribe(request, progress: { _ in }, isCancelled: { false })
        async let ovlSherpaTask = runSherpas()
        let (ovlWhisper, ovlSherpa) = try await (ovlWhisperTask, ovlSherpaTask)
        let tOverlapped = Date().timeIntervalSince(t1)

        let seqText = seqWhisper.map(\.text).joined()
        let ovlText = ovlWhisper.map(\.text).joined()
        print("""
              === 重ね合わせ計測（音声 \(String(format: "%.0f", audio.duration))秒・照合 \(sherpaModels.count)本）===
              直列:  whisper \(String(format: "%.1f", tWhisper))秒 + 照合 \(String(format: "%.1f", tSequential - tWhisper))秒 = \(String(format: "%.1f", tSequential))秒
              重ね:  \(String(format: "%.1f", tOverlapped))秒（\(String(format: "%.0f", (1 - tOverlapped / tSequential) * 100))% 短縮）
              whisper 本文: 直列 \(seqText.count)文字 / 重ね \(ovlText.count)文字 / セグメント \(seqWhisper.count) vs \(ovlWhisper.count)
              """)
        for (i, m) in sherpaModels.enumerated() {
            let a = seqSherpa[i].map(\.text).joined(), b = ovlSherpa[i].map(\.text).joined()
            print("[\(m.id)] 本文一致: \(a == b)（\(a.count) / \(b.count) 文字）")
            XCTAssertEqual(a, b, "[\(m.id)] 重ねると照合本文が変わった")
        }
        // whisper は負荷で時刻が揺れ、句読点も1文字程度動く（上の実測）。
        // 語の内容まで動いたらそれは別の問題なので、句読点を落として比べる。
        let strip = { (t: String) in String(t.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }) }
        if seqText != ovlText { print("whisper 本文の差分あり（句読点レベルかを下で判定）") }
        XCTAssertEqual(strip(seqText), strip(ovlText), "重ねると whisper の語が変わった。句読点ではなく内容が動いている")
        XCTAssertLessThan(tOverlapped, tSequential, "重ねても速くなっていない")
    }
}
