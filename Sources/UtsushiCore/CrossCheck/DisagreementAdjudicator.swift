import Foundation
import FoundationModels

/// 不一致の判定結果。**候補の番号しか返せない形**にしてある。
/// 本文を書かせないので、モデルが第3の文字列を創作する余地が構造的に無い。
@available(macOS 26.0, *)
@Generable
struct DisagreementChoice {
    @Guide(description: "文脈に照らして正しいと判断した候補。判断できないときは unknown。")
    var pick: PickedCandidate
}

@available(macOS 26.0, *)
@Generable
enum PickedCandidate {
    case first
    case second
    case third
    case fourth
    case unknown
}

public struct Adjudication: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var disagreementID: UUID
    public var start: Double
    public var end: Double
    /// 採用した候補のエンジン名。nil なら判定不能。
    public var chosenEngine: String?
    public var chosenText: String?
    public var candidates: [TranscriptAlignment.Candidate]
    /// 候補の読みが一致していたか。効果を後から分離して測るために必ず残す。
    public var readingsMatched: Bool
    /// 2回の判定が一致したか
    public var agreed: Bool

    public init(id: UUID = UUID(), disagreementID: UUID, start: Double, end: Double,
                chosenEngine: String?, chosenText: String?,
                candidates: [TranscriptAlignment.Candidate],
                readingsMatched: Bool, agreed: Bool) {
        self.id = id; self.disagreementID = disagreementID
        self.start = start; self.end = end
        self.chosenEngine = chosenEngine; self.chosenText = chosenText
        self.candidates = candidates; self.readingsMatched = readingsMatched; self.agreed = agreed
    }
}

public struct AdjudicationOutcome: Sendable, Codable, Equatable {
    public var total: Int = 0
    public var decided: Int = 0
    public var undecided: Int = 0
    public var disagreedBetweenSamples: Int = 0
    public var errors: Int = 0
    /// 読みが一致していた不一致のうち決着した数（LLMが本来得意な領域）
    public var decidedWithMatchingReadings: Int = 0
    /// 読みが違う不一致のうち決着した数（音響情報を無視した推定）
    public var decidedWithDifferentReadings: Int = 0
    /// 表記だけの違い（「三月」と「3月」など）。判定にかけていない。
    /// `total` には含まれる。人に残す件数は `undecided - notationOnly` で見る。
    public var notationOnly: Int = 0
    public init() {}
}

/// 不一致を LLM に判定させる。
public protocol DisagreementJudge: Sendable {
    var displayName: String { get }
    func isAvailable() async -> CorrectionAvailability
    /// 候補の**添字**を返す。nil は判定不能。範囲外を返してはいけない。
    func judge(_ d: TranscriptAlignment.Disagreement) async throws -> Int?
}

@available(macOS 26.0, *)
public final class FoundationModelsJudge: DisagreementJudge, @unchecked Sendable {
    public let displayName = "Apple Foundation Models (on-device)"

    private let instructions = """
    複数の音声認識エンジンが同じ音声に対して異なる文字を出した。
    文脈に照らしてどれが正しいかを選ぶ。

    - 候補の中から選ぶだけで、新しい語を書いてはならない
    - どれも正しくない、または判断材料が足りない場合は unknown を選ぶ
    - 迷ったら unknown を選ぶこと。誤った断定より未判定の方が良い
    """
    private let options: GenerationOptions

    public init(temperature: Double = 0.0) {
        self.options = GenerationOptions(samplingMode: .greedy,
                                         temperature: temperature,
                                         maximumResponseTokens: 60)
    }

    public func isAvailable() async -> CorrectionAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(let reason): return .unavailable(Self.describe(reason))
        @unknown default: return .unavailable("未知の理由でモデルが利用できない")
        }
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: return "このMacはApple Intelligenceに対応していない"
        case .appleIntelligenceNotEnabled: return "システム設定でApple Intelligenceが有効になっていない"
        case .modelNotReady: return "モデルのダウンロード/準備が完了していない"
        @unknown default: return "モデルが利用できない"
        }
    }

    public func judge(_ d: TranscriptAlignment.Disagreement) async throws -> Int? {
        guard d.candidates.count >= 2, d.candidates.count <= 4 else { return nil }
        var prompt = ""
        if !d.context.isEmpty {
            prompt += "文脈（この前後の書き起こし）:\n\(d.context)\n\n"
        }
        prompt += "この箇所で各エンジンの出力が食い違っている:\n"
        for (i, c) in d.candidates.enumerated() {
            prompt += "\(i + 1). 「\(c.text)」\n"
        }
        prompt += "\n文脈に合うのはどれか。判断できなければ unknown。"

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt,
                                                 generating: DisagreementChoice.self,
                                                 options: options)
        let index: Int
        switch response.content.pick {
        case .first: index = 0
        case .second: index = 1
        case .third: index = 2
        case .fourth: index = 3
        case .unknown: return nil
        }
        // 候補数を超える番号は採らない。モデルの出力を範囲で必ず縛る。
        guard index < d.candidates.count else { return nil }
        return index
    }
}

/// 判定の司令塔。読みの一致/不一致を記録し、2回一致した場合のみ採る。
public struct Adjudicator: Sendable {
    public var judge: (any DisagreementJudge)?
    /// 同じ判定が2回出た場合のみ採用する
    public var requireAgreement: Bool
    /// 読みが違う不一致もLLMに判定させるか。
    /// false にすると、音響に情報が残っているケースを人に残す（安全側）。
    public var judgeDifferentReadings: Bool

    public init(judge: (any DisagreementJudge)?,
                requireAgreement: Bool = true,
                judgeDifferentReadings: Bool = true) {
        self.judge = judge
        self.requireAgreement = requireAgreement
        self.judgeDifferentReadings = judgeDifferentReadings
    }

    public func run(on disagreements: [TranscriptAlignment.Disagreement],
                    progress: (@Sendable (Int, Int) -> Void)? = nil)
    async -> ([Adjudication], AdjudicationOutcome) {
        var out: [Adjudication] = []
        var stat = AdjudicationOutcome()
        stat.total = disagreements.count

        for (i, d) in disagreements.enumerated() {
            progress?(i, disagreements.count)
            // 表記だけの違いはモデルに投げない。
            // 「三月」と「3月」のどちらが正しいかはモデルに聞く問題ではないし、
            // 実データではこれが件数の大半を占めるので、投げると時間だけ食う。
            if d.kind == .notation {
                out.append(undecided(d)); stat.undecided += 1; stat.notationOnly += 1; continue
            }
            guard let judge else {
                out.append(undecided(d)); stat.undecided += 1; continue
            }
            if !d.readingsMatch && !judgeDifferentReadings {
                out.append(undecided(d)); stat.undecided += 1; continue
            }
            do {
                let first = try await judge.judge(d)
                var picked = first
                if requireAgreement {
                    let second = try await judge.judge(d)
                    if second != first {
                        picked = nil
                        stat.disagreedBetweenSamples += 1
                    }
                }
                if let picked, picked < d.candidates.count {
                    let c = d.candidates[picked]
                    out.append(Adjudication(disagreementID: d.id, start: d.start, end: d.end,
                                            chosenEngine: c.engine, chosenText: c.text,
                                            candidates: d.candidates,
                                            readingsMatched: d.readingsMatch,
                                            agreed: true))
                    stat.decided += 1
                    if d.readingsMatch { stat.decidedWithMatchingReadings += 1 }
                    else { stat.decidedWithDifferentReadings += 1 }
                } else {
                    out.append(undecided(d)); stat.undecided += 1
                }
            } catch {
                stat.errors += 1
                out.append(undecided(d))
            }
        }
        progress?(disagreements.count, disagreements.count)
        return (out, stat)
    }

    private func undecided(_ d: TranscriptAlignment.Disagreement) -> Adjudication {
        Adjudication(disagreementID: d.id, start: d.start, end: d.end,
                     chosenEngine: nil, chosenText: nil,
                     candidates: d.candidates, readingsMatched: d.readingsMatch, agreed: false)
    }
}
