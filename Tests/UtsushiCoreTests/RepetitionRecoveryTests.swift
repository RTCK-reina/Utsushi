import XCTest

/// 反復ループに落ちた区間を、パイプラインが読み直して取り戻すこと。
///
/// 実データ（57分・large-v3）で、13:27 から最後まで「437の上りと言うんですけど」が
/// 2191 回連続し、44分ぶんの本文が丸ごと消えた。監査はループを検出して破棄したが、
/// **破棄しただけで読み直していなかった**ので、利用者には「14分以降が無い」と見えた。
///
/// whisper.cpp v1.9.1 は `no_context` を立てても直前の窓の出力を次の窓の prompt に
/// 持ち越す（`prompt_past1` は毎回組み直され、`no_context` は開始時に消すだけ）。
/// だから一度ループに入ると音声の終わりまで抜けない。読み直すときは持ち越しを切る。
final class RepetitionRecoveryTests: XCTestCase {

    private static let clipURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/testclip.m4a")
    }()

    func testLongRepetitionLoopIsReRecognizedWithoutContextCarry() async throws {
        guard FileManager.default.fileExists(atPath: Self.clipURL.path) else {
            throw XCTSkip("検証用クリップが無い")
        }
        let engine = LoopingEngine()
        var config = TranscriptionPipeline.Configuration()
        config.enableCorrection = false
        config.enablePlausibilityCheck = false
        config.autoRepair = true
        let pipeline = TranscriptionPipeline(engine: engine, corrector: nil, config: config)
        let t = try await pipeline.run(url: Self.clipURL) { _ in }

        // ループ区間（60〜400秒）に、読み直しで得た本文が残っていること。
        let recovered = t.segments.filter {
            $0.start >= 60 && $0.end <= 400 && !$0.isSuppressed && $0.text.hasPrefix("読み直し")
        }
        XCTAssertFalse(recovered.isEmpty,
                       "ループ区間が読み直されていない。破棄されたまま本文が消えている")
        // ループの本文は一切残らないこと。
        XCTAssertFalse(t.segments.contains { !$0.isSuppressed && $0.text == LoopingEngine.loopText },
                       "ループの本文が本文として残っている")
        // 読み直しは文脈の持ち越しを切って呼ばれること（切らないとループが再発する）。
        XCTAssertTrue(engine.sawRepairWithoutContextCarry,
                      "読み直しの呼び出しで文脈の持ち越しが切られていない")
        // 監査記録に「読み直した」ことが残ること。黙って直さない。
        XCTAssertGreaterThan(t.audit.stats.repairedCount, 0)
        XCTAssertTrue(t.audit.findings.contains { $0.kind == .repetitionLoop && $0.action == .repaired },
                      "反復ループの記録が『読み直した』に更新されていない")
        // カバー率は読み直し後の本文で出し直されていること。
        // 監査時の値が残ると、44分ぶん取り戻しても「58%」と表示され続ける（実際にそうなった）。
        // 読み直し前に見えている本文は 0–60秒 と 400–600秒 の 260秒（素材は 660秒）なので、
        // 古い値なら 0.4 前後。読み直し後の実測は 0.70（末尾60秒は偽エンジンが覆っていない）。
        XCTAssertGreaterThan(t.audit.stats.coverageRatio, 0.6,
                             "読み直し後もカバー率が監査時の値のまま: \(t.audit.stats.coverageRatio)")
    }
}

/// 全体を頼むと 60 秒以降でループし、区間を頼むとまともな本文を返す偽エンジン。
private final class LoopingEngine: ASREngine, @unchecked Sendable {
    static let loopText = "437の上りと言うんですけど"
    let identifier = "looping"
    let displayName = "looping"
    let supportsVAD = true
    let exposesConfidence = false
    let supportsVocabularyHint = false

    private let lock = NSLock()
    private var _sawRepairWithoutContextCarry = false
    var sawRepairWithoutContextCarry: Bool { lock.withLock { _sawRepairWithoutContextCarry } }

    func prepare(progress: @escaping @Sendable (String, Double) -> Void) async throws { progress("準備完了", 1) }

    func transcribe(_ request: ASRRequest,
                    progress: @escaping @Sendable (Double) -> Void,
                    isCancelled: @escaping @Sendable () -> Bool) async throws -> [Segment] {
        if let range = request.timeRange {
            // 読み直し。文脈を切って呼ばれたかを記録する。
            if !request.carryContext { lock.withLock { _sawRepairWithoutContextCarry = true } }
            var out: [Segment] = []
            var t = range.lowerBound
            var i = 0
            while t + 5 <= range.upperBound {
                out.append(Segment(start: t, end: t + 5, original: "読み直し\(i)"))
                t += 5; i += 1
            }
            return out
        }
        // 全体。最初の60秒はまとも、そこから400秒までループ、その後もまとも。
        var out: [Segment] = []
        var t = 0.0
        var i = 0
        while t < 60 { out.append(Segment(start: t, end: t + 5, original: "冒頭\(i)")); t += 5; i += 1 }
        while t < 400 { out.append(Segment(start: t, end: t + 1, original: Self.loopText)); t += 1 }
        while t < 600 { out.append(Segment(start: t, end: t + 5, original: "末尾\(i)")); t += 5; i += 1 }
        return out
    }
}
