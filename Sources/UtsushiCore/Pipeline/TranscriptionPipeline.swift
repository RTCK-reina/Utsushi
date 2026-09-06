import Foundation

/// 抽出 → 認識 → 監査 → 自動修復 → 校正 の全体。
/// 各段が何をしたかは AuditReport / CorrectionOutcome に残り、黙って直すことはしない。
public actor TranscriptionPipeline {

    public struct Configuration: Sendable {
        public var language: String = "ja"
        /// どちらの押しかたで走っているか。書き出しに残す。
        public var mode: RunMode = .quality
        public var auditPolicy: HallucinationAuditor.Policy = .init()
        public var gatePolicy: EditGate.Policy = .init()
        public var rules: DeterministicRules = .init()
        public var dictionary: UserDictionary = .empty
        /// 取りこぼし疑い区間をVADなしで自動再認識する
        public var autoRepair: Bool = true
        /// 校正の段を走らせる。**決定論ルールと辞書の適用を含む。**
        public var enableCorrection: Bool = true
        /// 校正の中で LLM を使うか。
        ///
        /// 切っても決定論ルール（フィラー除去など）と辞書は効く。以前はここが
        /// `enableCorrection` と一緒くたで、**LLM を切ると辞書まで止まっていた**。
        /// Apple Intelligence が無効な環境でも同じことが起きていて、
        /// README の「無効でも検証層は全機能動く」と食い違っていた。
        public var useLanguageModel: Bool = true
        /// LLM案は2回一致した場合のみ採用
        public var requireAgreement: Bool = true
        /// 照合に使う別エンジン。空なら照合しない。
        public var crossCheckEngines: [ModelCatalog.Model] = []
        /// 不一致をLLMに判定させる
        public var adjudicateDisagreements: Bool = true
        /// 読みが違う不一致もLLMに判定させるか（既定は切る。SessionSettings の説明を参照）
        public var judgeDifferentReadings: Bool = false
        /// 要約を作る
        public var enableSummary: Bool = false
        public var summaryConfig: Summarizer.Configuration = .init()
        /// 文脈に合わない語をモデルに指摘させるか。
        /// 照合が拾えない「全エンジンが同じ誤り方をした箇所」を埋める。
        /// 本文は書き換えず、候補を横に並べるだけ。
        public var enablePlausibilityCheck: Bool = true
        public init() {}
    }

    public enum Stage: Sendable, Equatable {
        case preparing(String)
        case extractingAudio
        case transcribing
        case auditing
        case repairing(Int, Int)
        case crossChecking(String)
        case adjudicating(Int, Int)
        case correcting
        case summarizing(Int, Int)
        case done
        case failed(String)
        case cancelled
    }

    public struct Progress: Sendable, Equatable {
        public var stage: Stage
        public var fraction: Double
        public var message: String
    }

    private let engine: any ASREngine
    private let corrector: (any CorrectionEngine)?
    private let judge: (any DisagreementJudge)?
    private let summaryEngine: (any SummaryEngine)?
    private let plausibilityChecker: (any PlausibilityChecker)?
    private let config: Configuration
    /// Cコールバックから同期的に読めるキャンセル状態。
    /// ポーリング Task を作ると、その Task がパイプラインとASRエンジンを保持し続け、
    /// 終了時まで whisper_context が解放されないため、共有フラグを直接使う。
    private let cancellation = CancelBox()

    public init(engine: any ASREngine,
                corrector: (any CorrectionEngine)?,
                judge: (any DisagreementJudge)? = nil,
                summaryEngine: (any SummaryEngine)? = nil,
                plausibilityChecker: (any PlausibilityChecker)? = nil,
                config: Configuration = Configuration()) {
        self.engine = engine
        self.corrector = corrector
        self.judge = judge
        self.summaryEngine = summaryEngine
        self.plausibilityChecker = plausibilityChecker
        self.config = config
    }

    public func cancel() { cancellation.set() }
    private func makeCancelCheck() -> @Sendable () -> Bool {
        let cancellation = cancellation
        return { cancellation.value }
    }

    public func run(url: URL, onProgress: @escaping @Sendable (Progress) -> Void) async throws -> Transcript {
        cancellation.reset()
        let isCancelled = makeCancelCheck()

        let emit: @Sendable (Stage, Double, String) -> Void = { s, f, m in
            onProgress(Progress(stage: s, fraction: f, message: m))
        }

        // 1. 準備
        emit(.preparing(String(localized: "開始")), 0, String(localized: "準備中"))
        try await engine.prepare { msg, p in emit(.preparing(msg), p * 0.10, msg) }
        if isCancelled() { throw ASRError.cancelled }

        // 2. 音声抽出
        emit(.extractingAudio, 0.10, String(localized: "音声を抽出中"))
        let audio = try await AudioExtractor().extract(url: url,
            progress: { p in emit(.extractingAudio, 0.10 + p * 0.08, String(localized: "音声を抽出中")) },
            isCancelled: isCancelled)
        let envelope = AudioEnvelope(values: audio.envelope, hop: audio.envelopeHopSeconds)

        // 3. 認識
        emit(.transcribing, 0.18, String(localized: "認識中"))
        let hint = engine.supportsVocabularyHint ? config.dictionary.promptHint() : nil
        var segments = try await engine.transcribe(
            ASRRequest(samples: audio.samples, language: config.language,
                       useVAD: engine.supportsVAD, vocabularyHint: hint),
            progress: { p in emit(.transcribing, 0.18 + p * 0.52, String(localized: "認識中 \(Int(p * 100))%")) },
            isCancelled: isCancelled)
        segments.sort { $0.start < $1.start }

        // 4. 監査
        emit(.auditing, 0.72, String(localized: "検証中"))
        let auditor = HallucinationAuditor(policy: config.auditPolicy)
        var (audited, report) = auditor.audit(segments: segments,
                                              envelope: envelope,
                                              totalDuration: audio.duration,
                                              engineExposesConfidence: engine.exposesConfidence)

        // 5. 自動修復（VADを切って疑わしい区間だけ読み直す）
        if config.autoRepair {
            let plan = auditor.repairPlan(from: report, totalDuration: audio.duration)
            for (i, target) in plan.enumerated() {
                if isCancelled() { throw ASRError.cancelled }
                let range = target.range
                let isLoop = target.kind == .repetitionLoop
                emit(.repairing(i + 1, plan.count), 0.74 + Double(i) / Double(max(plan.count, 1)) * 0.06,
                     (isLoop ? String(localized: "反復ループの区間を読み直し中")
                      : String(localized: "取りこぼし疑い区間を再認識中"))
                     + " (\(i + 1)/\(plan.count))")
                do {
                    // 取りこぼしは VAD を切って拾い直す。反復ループは VAD はそのまま、
                    // **文脈の持ち越しを切る**（持ち越すと同じループに戻る）。
                    // 持ち越しはどちらの読み直しでも要らないので常に切る。
                    let redone = try await engine.transcribe(
                        ASRRequest(samples: audio.samples, language: config.language,
                                   timeRange: range, useVAD: isLoop && engine.supportsVAD,
                                   vocabularyHint: hint, carryContext: false),
                        progress: { _ in }, isCancelled: isCancelled)
                    let (replaced, changed) = Self.splice(into: audited, range: range,
                                                          with: redone, envelope: envelope,
                                                          policy: config.auditPolicy)
                    // 記録の end は音声の尺を超えることがある（whisper のセグメント end が
                    // 尺より先に出る）ので、区間に入っているかは start で見る。
                    for k in report.findings.indices
                    where report.findings[k].start >= range.lowerBound
                        && report.findings[k].start <= range.upperBound {
                        let f = report.findings[k]
                        if f.kind == .repetitionLoop, f.action == .suppressed {
                            if changed {
                                report.findings[k].action = .repaired
                                report.findings[k].detail += "（文脈の持ち越しを切って読み直し、本文を差し替えた）"
                            } else {
                                report.findings[k].detail += "（読み直したが本文は得られなかった）"
                            }
                        } else if f.action == .unresolved {
                            if changed {
                                report.findings[k].action = .repaired
                            } else {
                                // 調べた結果なにも無かった、を「未解決」と同じ扱いにしない。
                                // 未解決のまま残すと、確認済みの区間まで人の目を要求してしまう。
                                report.findings[k].action = .marked
                                report.findings[k].detail += "（VADなしで再認識したが、追加の発話は検出されなかった）"
                            }
                        }
                    }
                    if changed {
                        audited = replaced
                        report.stats.repairedCount += 1
                    }
                } catch is CancellationError {
                    throw ASRError.cancelled
                } catch {
                    // 再認識に失敗しても元の結果は壊さない。未解決のまま報告に残す。
                    continue
                }
            }
            audited.sort { $0.start < $1.start }
            // 読み直しで本文が変わったので、カバー率も今の本文で出し直す。
            if report.stats.repairedCount > 0 {
                auditor.updateCoverage(&report.stats, segments: audited,
                                       envelope: envelope, totalDuration: audio.duration)
            }
        }

        // 6. 照合（別エンジンで読み直し、食い違いを取り出す）
        var crossCheck = CrossCheckReport()
        if !config.crossCheckEngines.isEmpty {
            crossCheck.engines = [engine.identifier]
            var runs = [TranscriptAlignment.Run(engine: engine.identifier, segments: audited)]
            for model in config.crossCheckEngines {
                if isCancelled() { throw ASRError.cancelled }
                emit(.crossChecking(model.displayName), 0.80, String(localized: "\(model.displayName) で照合中"))
                do {
                    // 照合の相手は sherpa 系と OS 内蔵の2種類。
                    // OS 内蔵は取得も解放も要らないので、生成だけ分ける。
                    let secondary: any ASREngine
                    if model.engine == .appleSpeechAnalyzer {
                        guard #available(macOS 26.0, *) else { continue }
                        let loc = config.language == "ja" ? "ja-JP" : config.language
                        secondary = SpeechAnalyzerEngine(locale: Locale(identifier: loc))
                    } else {
                        secondary = SherpaEngine(model: model)
                    }
                    try await secondary.prepare { msg, _ in emit(.crossChecking(model.displayName), 0.80, msg) }
                    let segs = try await secondary.transcribe(
                        ASRRequest(samples: audio.samples, language: config.language, useVAD: false),
                        progress: { _ in }, isCancelled: isCancelled)
                    (secondary as? SherpaEngine)?.shutdown()
                    runs.append(TranscriptAlignment.Run(engine: model.id, segments: segs))
                    crossCheck.engines.append(model.id)
                } catch is CancellationError {
                    throw ASRError.cancelled
                } catch {
                    // 照合は補助機能なので、失敗しても本体の結果は返す
                    continue
                }
            }
            if runs.count >= 2 {
                crossCheck.disagreements = TranscriptAlignment.compare(runs)
                if config.adjudicateDisagreements, !crossCheck.disagreements.isEmpty {
                    let a = Adjudicator(judge: judge,
                                        requireAgreement: config.requireAgreement,
                                        judgeDifferentReadings: config.judgeDifferentReadings)
                    let (adj, stat) = await a.run(on: crossCheck.disagreements) { done, total in
                        emit(.adjudicating(done, total), 0.81, String(localized: "食い違いを判定中 \(done)/\(total)"))
                    }
                    crossCheck.adjudications = adj
                    crossCheck.outcome = stat
                }
            }
        }

        // 7. 校正
        var outcome = CorrectionOutcome()
        let correctionEnd = config.enableSummary ? 0.92 : 0.99
        if config.enableCorrection {
            emit(.correcting, 0.82, String(localized: "校正中"))
            let gate = EditGate(policy: config.gatePolicy, dictionary: config.dictionary)
            let c = Corrector(engine: config.useLanguageModel ? corrector : nil,
                              gate: gate, rules: config.rules,
                              dictionary: config.dictionary, requireAgreement: config.requireAgreement)
            let (corrected, stat) = await c.run(on: audited) { done, total in
                emit(.correcting, 0.82 + Double(done) / Double(max(total, 1)) * (correctionEnd - 0.82),
                     String(localized: "校正中 \(done)/\(total)"))
            }
            audited = corrected
            outcome = stat
        }

        // 8. 要約（校正後の本文から引用する）
        var summary = Summary.empty
        if config.enableSummary, summaryEngine != nil {
            if isCancelled() { throw ASRError.cancelled }
            let s = Summarizer(engine: summaryEngine, config: config.summaryConfig)
            summary = await s.run(on: audited) { done, total in
                emit(.summarizing(done, total),
                     correctionEnd + Double(done) / Double(max(total, 1)) * (0.99 - correctionEnd),
                     String(localized: "要約中 \(done)/\(total)"))
            }
        }

        // 9. 文脈に合わない語の指摘
        //
        // 照合はエンジン間の不一致しか見ないので、**全エンジンが同じ誤り方をした箇所**
        // （「期初」→「気象」）を素通りする。音響からの多数決では原理的に拾えないため、
        // 残っている手掛かりである文脈をモデルに見せる。
        // モデルは本文を書き換えない。指摘した語が本文に無ければ機械的に捨てる。
        var plausibility: [PlausibilityFlag] = []
        if config.enablePlausibilityCheck, plausibilityChecker != nil {
            if isCancelled() { throw ASRError.cancelled }
            emit(.correcting, 0.99, String(localized: "文脈の点検中"))
            let a = PlausibilityAuditor(checker: plausibilityChecker,
                                        requireAgreement: config.requireAgreement)
            let (flags, stat) = await a.run(on: audited.filter { !$0.isSuppressed }) { done, total in
                emit(.correcting, 0.99, String(localized: "文脈の点検中 \(done)/\(total)"))
            }
            plausibility = flags
            self.lastPlausibilityOutcome = stat
        }

        report.stats.segmentCount = audited.count
        let meta = TranscriptMeta(sourceURL: url, sourceDuration: audio.duration,
                                  engine: engine.displayName,
                                  modelName: engine.identifier,
                                  language: config.language,
                                  mode: config.mode)
        emit(.done, 1.0, String(localized: "完了"))
        // カバー率は監査層が音声を見て出す。ここで尺の合計から上書きしない
        // （それをやっていたせいで、休憩を含む素材が 100% と報告されていた）。
        let transcript = Transcript(meta: meta, segments: audited, audit: report,
                                    crossCheck: crossCheck, summary: summary,
                                    plausibility: plausibility)
        self.lastCorrectionOutcome = outcome
        return transcript
    }

    public private(set) var lastCorrectionOutcome = CorrectionOutcome()
    public private(set) var lastPlausibilityOutcome = PlausibilityAuditor.Outcome()

    /// 再認識結果を元の並びに差し込む。
    /// 再認識側にも幻聴が乗るので、無音区間の本文はここでも捨てる。
    static func splice(into segments: [Segment],
                       range: ClosedRange<Double>,
                       with fresh: [Segment],
                       envelope: AudioEnvelope,
                       policy: HallucinationAuditor.Policy) -> ([Segment], Bool) {
        let cleaned = fresh.filter { seg in
            guard !seg.original.isEmpty else { return false }
            let peak = envelope.peakDBFS(from: seg.start, to: seg.end)
            if peak <= policy.silenceDBFS { return false }
            let t = seg.original.trimmingCharacters(in: .whitespaces)
            if HallucinationAuditor.knownHallucinations.contains(t) { return false }
            return true
        }
        // 元より情報が増えないなら差し替えない（改悪防止）
        let originalChars = segments
            .filter { $0.start < range.upperBound && $0.end > range.lowerBound && !$0.isSuppressed }
            .reduce(0) { $0 + $1.original.count }
        let freshChars = cleaned.reduce(0) { $0 + $1.original.count }
        guard freshChars > originalChars else { return (segments, false) }

        var out = segments.filter { $0.end <= range.lowerBound || $0.start >= range.upperBound }
        for var seg in cleaned {
            seg.flags.insert(.repaired)
            out.append(seg)
        }
        out.sort { $0.start < $1.start }
        return (out, true)
    }
}

private final class CancelBox: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
    func reset() { lock.lock(); flag = false; lock.unlock() }
}
