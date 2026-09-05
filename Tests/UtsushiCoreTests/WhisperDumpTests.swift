import XCTest

/// 調査用。指定した素材を whisper 単体で認識し、全セグメントを TSV に吐く。
/// パイプラインの監査を通さないので、whisper が実際に何を返したかがそのまま見える。
///
///   TEST_RUNNER_UTSUSHI_DUMP_MEDIA=/path/to.m4a \
///   TEST_RUNNER_UTSUSHI_DUMP_MODEL=ggml-large-v3 \
///   TEST_RUNNER_UTSUSHI_DUMP_VAD=1 \
///   TEST_RUNNER_UTSUSHI_DUMP_OUT=/tmp/out.tsv \
///   xcodebuild ... -only-testing:UtsushiTests/WhisperDumpTests
final class WhisperDumpTests: XCTestCase {
    func testDumpWhisperSegments() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let media = env["UTSUSHI_DUMP_MEDIA"], let out = env["UTSUSHI_DUMP_OUT"] else {
            throw XCTSkip("UTSUSHI_DUMP_MEDIA / UTSUSHI_DUMP_OUT が無いので走らない（調査用）")
        }
        let modelID = env["UTSUSHI_DUMP_MODEL"] ?? ModelCatalog.whisperModels[0].id
        guard let model = ModelCatalog.whisperModels.first(where: { $0.id == modelID }) else {
            XCTFail("モデル \(modelID) がカタログに無い"); return
        }
        guard ModelCatalog.isInstalled(model) else {
            XCTFail("モデル \(modelID) が未導入。ダウンロードは調査では走らせない"); return
        }
        let useVAD = env["UTSUSHI_DUMP_VAD"] != "0"
        var range: ClosedRange<Double>? = nil
        if let r = env["UTSUSHI_DUMP_RANGE"] {
            let p = r.split(separator: "-").compactMap { Double($0) }
            if p.count == 2 { range = p[0]...p[1] }
        }

        let audio = try await AudioExtractor().extract(url: URL(fileURLWithPath: media),
                                                       progress: { _ in }, isCancelled: { false })
        var options = WhisperEngine.Options()
        if let c = env["UTSUSHI_DUMP_CTX"].flatMap({ Int32($0) }) { options.maxTextContext = c }
        let engine = WhisperEngine(model: model, options: options)
        try await engine.prepare { _, _ in }
        defer { engine.shutdown() }

        let t0 = Date()
        let segs = try await engine.transcribe(
            ASRRequest(samples: audio.samples, language: "ja", timeRange: range, useVAD: useVAD),
            progress: { _ in }, isCancelled: { false })
        let elapsed = Date().timeIntervalSince(t0)

        var tsv = "start\tend\tnoSpeech\tavgLogprob\ttext\n"
        for s in segs {
            tsv += String(format: "%.2f\t%.2f\t%.3f\t%.3f\t", s.start, s.end, s.noSpeechProb ?? -1, s.avgLogprob ?? 0)
            tsv += s.original.replacingOccurrences(of: "\t", with: " ") + "\n"
        }
        try tsv.write(toFile: out, atomically: true, encoding: .utf8)
        print("""
              [dump] model=\(modelID) vad=\(useVAD) ctx=\(options.maxTextContext.map { "\($0)" } ?? "既定") range=\(range.map { "\($0)" } ?? "全体") \
              音声 \(String(format: "%.0f", audio.duration))秒 / \(String(format: "%.0f", elapsed))秒で認識 / \
              \(segs.count)セグメント / 最後の end=\(String(format: "%.1f", segs.last?.end ?? 0))秒 → \(out)
              """)
    }
}

/// 調査用。アプリと同じパイプライン（監査・自動修復込み、LLM と照合は切る）で走らせ、
/// 破棄されたセグメントと監査記録を吐く。whisper 単体では再現しない現象が
/// パイプラインの段で起きているかを切り分ける。
final class PipelineDumpTests: XCTestCase {
    func testDumpPipelineAudit() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let media = env["UTSUSHI_PIPE_MEDIA"], let out = env["UTSUSHI_PIPE_OUT"] else {
            throw XCTSkip("UTSUSHI_PIPE_MEDIA / UTSUSHI_PIPE_OUT が無いので走らない（調査用）")
        }
        let modelID = env["UTSUSHI_PIPE_MODEL"] ?? ModelCatalog.whisperModels[0].id
        guard let model = ModelCatalog.whisperModels.first(where: { $0.id == modelID }),
              ModelCatalog.isInstalled(model) else { XCTFail("モデル \(modelID) が使えない"); return }

        var config = TranscriptionPipeline.Configuration()
        config.enableCorrection = false
        config.enableSummary = false
        config.enablePlausibilityCheck = false
        config.crossCheckEngines = []
        config.autoRepair = env["UTSUSHI_PIPE_REPAIR"] != "0"

        // UTSUSHI_PIPE_FRESH=1 なら実行ごとにエンジンを作り直す（アプリは使い回す）。
        let fresh = env["UTSUSHI_PIPE_FRESH"] == "1"
        var options = WhisperEngine.Options()
        if let c = env["UTSUSHI_PIPE_CTX"].flatMap({ Int32($0) }) { options.maxTextContext = c }
        var engine = WhisperEngine(model: model, options: options)
        var pipeline = TranscriptionPipeline(engine: engine, corrector: nil, config: config)
        let runs = Int(env["UTSUSHI_PIPE_RUNS"] ?? "1") ?? 1
        var report = "fresh=\(fresh) ctx=\(options.maxTextContext.map { "\($0)" } ?? "既定")\n"
        for r in 1...runs {
            if fresh && r > 1 {
                engine.shutdown()
                engine = WhisperEngine(model: model, options: options)
                pipeline = TranscriptionPipeline(engine: engine, corrector: nil, config: config)
            }
            let t0 = Date()
            let t = try await pipeline.run(url: URL(fileURLWithPath: media)) { _ in }
            let elapsed = Date().timeIntervalSince(t0)
            let suppressed = t.segments.filter { $0.isSuppressed }
            var perTen: [Int: Int] = [:]
            for s in t.segments where !s.isSuppressed { perTen[Int(s.start / 600), default: 0] += s.text.count }
            let visibleChars = perTen.values.reduce(0, +)
            let buckets = perTen.keys.sorted().map { "\($0 * 10)m:\(perTen[$0]!)" }.joined(separator: " ")
            report += "可視文字 \(visibleChars) / 10分ごと: \(buckets)\n"
            report += """
            ==== run \(r): \(String(format: "%.0f", elapsed))秒 / セグメント \(t.segments.count) / 破棄 \(suppressed.count) \
            / カバー率 \(String(format: "%.1f", t.audit.stats.coverageRatio * 100))% \
            / 最後の end \(String(format: "%.1f", t.segments.last?.end ?? 0))
            findings: \(Dictionary(grouping: t.audit.findings, by: { "\($0.kind)" }).mapValues(\.count))

            """
            for f in t.audit.findings where f.kind == .repetitionLoop || f.kind == .coverageGap || f.kind == .densityAnomaly {
                report += String(format: "  [%@] %.1f-%.1f %@\n", "\(f.kind)", f.start, f.end, f.detail)
            }
            for s in suppressed.prefix(20) {
                report += String(format: "  破棄 %.1f-%.1f %@ | %@\n", s.start, s.end, "\(s.flags)", String(s.original.prefix(40)))
            }
        }
        engine.shutdown()
        try report.write(toFile: out, atomically: true, encoding: .utf8)
        print(report)
    }
}
