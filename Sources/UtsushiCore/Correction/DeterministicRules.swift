import Foundation

/// LLMを使わずに機械的に直せるものは、機械で直す。
/// LLMに回す仕事を減らすほどハルシネーションの入口が狭くなる、という方針の実装。
public struct DeterministicRules: Sendable {

    /// 除去してよいフィラー。
    ///
    /// **単語境界を持たない日本語で部分文字列マッチによる除去は危険**なので、
    /// 「他の語の一部になり得ない形」だけを載せている。
    /// 実際に「こう」を載せていたときは
    ///   「こういうところ」→「いうところ」 /「こういった制度」→「いった制度」
    /// と本文を壊した。同じ理由で以下は意図的に載せていない:
    ///   こう（こういう・こうして・こういった）
    ///   あの（あの人・あのように）
    ///   なんか（なんかあったら＝何かあったら）
    ///   まあ / ですね（そうですね → そう）
    /// これらを本気で扱うには形態素解析が要る。今は精度より無改変を優先する。
    public static let defaultFillers: [String] = [
        "えーと", "えっと", "ええと", "えーっと", "えっとー",
        "あのー", "あのう", "そのー", "そのう",
        "えー", "あー", "うー", "んー", "んーと"
    ]

    /// 表記ゆれの正規化。読みが変わるもの（そうゆう→そういう）もここに置く。
    /// 一覧が明示的にコードにあることが重要で、モデルの気分で増えない。
    public static let defaultNotation: [(String, String)] = [
        ("そうゆう", "そういう"), ("こうゆう", "こういう"), ("どうゆう", "どういう"),
        ("わたくし達", "私たち"), ("出来る", "できる"), ("下さい", "ください"),
        ("有難う", "ありがとう"), ("宜しく", "よろしく"), ("頂く", "いただく"),
        ("１", "1"), ("２", "2"), ("３", "3"), ("４", "4"), ("５", "5"),
        ("６", "6"), ("７", "7"), ("８", "8"), ("９", "9"), ("０", "0"),
    ]

    public var fillers: [String]
    public var notation: [(String, String)]
    public var removeFillers: Bool
    public var normalizeNotation: Bool

    public init(fillers: [String] = DeterministicRules.defaultFillers,
                notation: [(String, String)] = DeterministicRules.defaultNotation,
                removeFillers: Bool = true,
                normalizeNotation: Bool = true) {
        self.fillers = fillers
        self.notation = notation
        self.removeFillers = removeFillers
        self.normalizeNotation = normalizeNotation
    }

    /// 発話がフィラーだけで構成されているか。相槌をまるごと消さないための判定。
    static func isOnlyFillers(_ text: String, fillers: [String]) -> Bool {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return true }
        for f in fillers.sorted(by: { $0.count > $1.count }) {
            t = t.replacingOccurrences(of: f, with: "")
        }
        let residue = t.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "、。 　,.")))
        return residue.isEmpty
    }

    /// 語の途中を食わないよう、**左側が境界のときだけ**フィラーを除去する。
    /// 右側は見ない（「えーとですね」→「ですね」は正しい除去なので）。
    static func removeAtBoundaries(_ filler: String, from text: String) -> String {
        guard !filler.isEmpty else { return text }
        let boundary: Set<Character> = ["、", "。", "，", "．", ",", ".", " ", "　",
                                        "「", "」", "（", "）", "？", "！", "?", "!", "\n"]
        var result = ""
        var rest = Substring(text)
        while let range = rest.range(of: filler) {
            let leftIsBoundary: Bool
            if range.lowerBound == rest.startIndex {
                // 直前が結果側の末尾（=元テキストの手前）なら、そこで判定する
                leftIsBoundary = result.isEmpty || boundary.contains(result.last!)
            } else {
                leftIsBoundary = boundary.contains(rest[rest.index(before: range.lowerBound)])
            }
            result += rest[rest.startIndex..<range.lowerBound]
            if !leftIsBoundary {
                result += filler          // 語の途中なので消さない
            }
            rest = rest[range.upperBound...]
        }
        result += rest
        return result
    }

    public func apply(_ text: String) -> (result: String, rule: CorrectionRule?) {
        var out = text
        var usedFiller = false, usedNotation = false

        if normalizeNotation {
            for (from, to) in notation where out.contains(from) {
                out = out.replacingOccurrences(of: from, with: to)
                usedNotation = true
            }
        }
        if removeFillers, !Self.isOnlyFillers(out, fillers: fillers) {
            // 長いフィラーから先に消す。短い方を先に消すと「えーと」から「えー」だけが
            // 抜けて「と」という無意味な断片が残る（実際に起きた）。
            for f in fillers.sorted(by: { $0.count > $1.count }) {
                let candidate = Self.removeAtBoundaries(f, from: out)
                if candidate == out { continue }
                if candidate.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                out = candidate
                usedFiller = true
            }
        }
        out = out.replacingOccurrences(of: "  ", with: " ")
                 .trimmingCharacters(in: .whitespacesAndNewlines)
        if out == text { return (text, nil) }
        return (out, usedFiller ? .fillerRemoval : (usedNotation ? .notation : nil))
    }
}
