import Foundation

/// 文脈に合わない語の指摘。**本文は書き換えない。表示するだけ。**
///
/// 照合（`TranscriptAlignment`）はエンジン間の不一致しか見ないので、
/// **全エンジンが同じ間違え方をした箇所には無力**だった。
/// 実データでは「期初」が4エンジンすべてで「気象」になっており、
/// 「大体気象の目標を3月から4月ぐらいに立てまして」がそのまま出ていた。
/// 音響からの多数決では原理的に拾えない。残っている手掛かりは文脈だけになる。
///
/// そこで言語モデルに「日本語として意味が通らない語」を指摘させる。
/// ただし**モデルに本文を書かせない**という原則は変えない。
/// モデルが返せるのは「行番号」と「その行にある語」と「ありうる語」の3つだけで、
/// 返した語が本文に無ければ機械的に捨てる。採用されても本文は元のままで、
/// 候補が横に並ぶだけ。誤指摘の代償は読み手が一瞬迷うことで、本文の破壊ではない。
public struct PlausibilityFlag: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    /// 指摘された語を含むセグメントの開始時刻
    public var start: Double
    /// 本文にあるその語。**本文に実在することを検証済み。**
    public var surface: String
    /// ありうる語。表示だけで、本文には反映しない。
    public var alternative: String

    public init(id: UUID = UUID(), start: Double, surface: String, alternative: String) {
        self.id = id; self.start = start
        self.surface = surface; self.alternative = alternative
    }
}

/// モデルからの生の指摘。ゲートを通る前のもの。
public struct PlausibilityDraft: Sendable, Equatable {
    public var lineNumber: Int
    public var surface: String
    public var alternative: String
    public init(lineNumber: Int, surface: String, alternative: String) {
        self.lineNumber = lineNumber; self.surface = surface; self.alternative = alternative
    }
}

public protocol PlausibilityChecker: Sendable {
    var displayName: String { get }
    func isAvailable() async -> CorrectionAvailability
    /// 番号付きの本文を渡し、文脈に合わない語を指摘させる。
    func check(numberedText: String, lineCount: Int) async throws -> [PlausibilityDraft]
}

/// モデルの指摘を機械的に検証する。
///
/// `EditGate` ほど厳しくしていないのは、**ここでは本文を書き換えないから**。
/// 書き換えるなら「読みが変わる案は棄却」まで要るが、横に候補を並べるだけなら
/// 誤指摘の代償は読み手が一瞬迷うことで済む。むしろ厳しくしすぎると、
/// 「気象」→「期初」のような**読みが少し違うから拾いたい誤り**を落としてしまう
/// （きしょう / きしょ。`EditGate` の読み一致ではこれは通らない）。
///
/// ただし「モデルが本文に無い語を指摘する」ことだけは許さない。
/// そこを許すと、存在しない語についての注意書きが本文の横に並ぶ。
public struct PlausibilityGate: Sendable {

    public enum Rejection: String, Sendable, Equatable {
        /// 存在しない行を指した
        case lineOutOfRange
        /// 指摘した語がその行に無い（モデルの創作）
        case surfaceNotInLine
        /// 元の語と同じ
        case unchanged
        /// 長すぎる・短すぎる・釣り合わない
        case badLength
        /// ひらがな・約物だけ。助詞のゆれを指摘されても読み手にできることが無い
        case notAContentWord
        /// 元に無い英字を持ち込んだ
        case inventedLatin
    }

    public var maxLength: Int
    public init(maxLength: Int = 8) { self.maxLength = maxLength }

    public func evaluate(_ d: PlausibilityDraft, lines: [String]) -> Rejection? {
        guard d.lineNumber >= 1, d.lineNumber <= lines.count else { return .lineOutOfRange }
        let line = lines[d.lineNumber - 1]

        let surface = d.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let alternative = d.alternative.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !surface.isEmpty, !alternative.isEmpty else { return .badLength }
        guard surface != alternative else { return .unchanged }
        guard line.contains(surface) else { return .surfaceNotInLine }

        let shortest = min(surface.count, alternative.count)
        let longest = max(surface.count, alternative.count)
        guard longest <= maxLength, longest <= shortest * 2 else { return .badLength }

        guard Self.hasContentCharacter(surface) else { return .notAContentWord }

        // 元に英字が無いのに英字を持ち込む指摘は、文脈の指摘ではなく創作。
        if Self.hasLatin(alternative) && !Self.hasLatin(surface) { return .inventedLatin }

        return nil
    }

    static func hasContentCharacter(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value)         // 漢字
                || (0x3400...0x4DBF).contains($0.value)
                || (0x30A0...0x30FF).contains($0.value)  // カタカナ
                || Self.isLatinScalar($0)
        }
    }

    static func hasLatin(_ s: String) -> Bool { s.unicodeScalars.contains(where: isLatinScalar) }

    private static func isLatinScalar(_ v: Unicode.Scalar) -> Bool {
        (0x0041...0x005A).contains(v.value) || (0x0061...0x007A).contains(v.value)
    }
}

/// 指摘を集めてゲートに通す司令塔。
public struct PlausibilityAuditor: Sendable {
    public var checker: (any PlausibilityChecker)?
    /// 同じ指摘が2回出た場合のみ採る。
    /// 1回だけの指摘はモデルの気まぐれで、そのまま出すと本文の横が騒がしくなる。
    public var requireAgreement: Bool
    public var gate: PlausibilityGate

    public init(checker: (any PlausibilityChecker)?,
                requireAgreement: Bool = true,
                gate: PlausibilityGate = PlausibilityGate()) {
        self.checker = checker
        self.requireAgreement = requireAgreement
        self.gate = gate
    }

    public struct Outcome: Sendable, Codable, Equatable {
        public var proposed: Int = 0
        public var accepted: Int = 0
        public var rejectedByGate: Int = 0
        public var droppedForDisagreement: Int = 0
        public var errors: Int = 0
        /// 失敗した理由。0件と失敗を取り違えないために残す。
        public var lastError: String?
        public init() {}
    }

    /// `segments` の並びがそのまま行番号（1始まり）になる。
    public func run(on segments: [Segment]) async -> ([PlausibilityFlag], Outcome) {
        var stat = Outcome()
        guard let checker, !segments.isEmpty else { return ([], stat) }

        let lines = segments.map(\.text)
        let numbered = lines.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        var rounds: [[PlausibilityDraft]] = []
        let times = requireAgreement ? 2 : 1
        for _ in 0..<times {
            do {
                rounds.append(try await checker.check(numberedText: numbered, lineCount: lines.count))
            } catch {
                // 「モデルが0件返した」と「呼び出しが失敗した」は結果が同じ形になる。
                // 区別できないと、動いていないものを「指摘が無い」と読んでしまう。
                stat.errors += 1
                stat.lastError = String(describing: error)
                return ([], stat)
            }
        }

        let first = rounds[0]
        stat.proposed = first.count

        var kept: [PlausibilityDraft] = []
        for d in first {
            if requireAgreement, !rounds[1].contains(d) {
                stat.droppedForDisagreement += 1
                continue
            }
            kept.append(d)
        }

        var out: [PlausibilityFlag] = []
        var seen = Set<String>()
        for d in kept {
            if gate.evaluate(d, lines: lines) != nil { stat.rejectedByGate += 1; continue }
            let key = "\(d.lineNumber)|\(d.surface)|\(d.alternative)"
            guard seen.insert(key).inserted else { continue }
            out.append(PlausibilityFlag(start: segments[d.lineNumber - 1].start,
                                        surface: d.surface.trimmingCharacters(in: .whitespaces),
                                        alternative: d.alternative.trimmingCharacters(in: .whitespaces)))
        }
        stat.accepted = out.count
        return (out, stat)
    }
}
