import Foundation

/// LLMが出した書き換え案を機械的に検証する。
///
/// 設計の前提: **LLMには文章を書かせない。書き換え案を出させ、ここで落とす。**
/// 通過条件を満たさない案は理由付きで棄却され、原文がそのまま残る。
/// つまりゲートの緩さがそのままハルシネーション混入率になるので、
/// 緩める場合は必ずここのコードを変えることになる（プロンプトでは緩められない）。
public struct EditGate: Sendable {

    public struct Policy: Sendable {
        /// 読みが完全一致することを要求する。これが主防壁。
        public var requireReadingMatch: Bool = true
        /// 文字数の変化許容比（句読点挿入ぶんの余裕）
        public var maxLengthRatio: Double = 1.35
        public var minLengthRatio: Double = 0.75
        /// 1セグメントあたりの最大編集距離
        public var maxEditDistance: Int = 40
        /// 読みが変わる編集を許すのは、辞書に登録された語に置換する場合だけ
        public var allowDictionaryReadingChange: Bool = true
        public init() {}
    }

    public enum Rejection: String, Sendable, Codable, Equatable {
        case readingChanged        // 読みが変わった＝別の語に書き換えられた
        case lengthOutOfRange      // 長さが許容外
        case editDistanceTooLarge  // 変更量が大きすぎる
        case readingUnavailable    // 読みが取得できず検証不能
        case emptyResult           // 空文字にされた
        case newLatinToken         // 原文になかった英数字トークンが増えた
    }

    public enum Verdict: Sendable, Equatable {
        case accept
        case reject(Rejection)
        public var isAccepted: Bool { if case .accept = self { return true }; return false }
    }

    public var policy: Policy
    public var dictionary: UserDictionary

    public init(policy: Policy = Policy(), dictionary: UserDictionary = .empty) {
        self.policy = policy
        self.dictionary = dictionary
    }

    public func evaluate(original: String, proposed: String) -> Verdict {
        let o = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = proposed.trimmingCharacters(in: .whitespacesAndNewlines)

        if p.isEmpty && !o.isEmpty { return .reject(.emptyResult) }
        if o == p { return .accept }

        // 意味的な違反を先に見る。長さで先に弾くと、実際は固有名詞の創作なのに
        // 「長さが許容外」と報告されて監査記録が実態とずれる。
        //
        // 1. 英数字トークンの新規出現。モデルが固有名詞を創作するのを止める独立した防壁。
        let newLatin = latinTokens(p).subtracting(latinTokens(o))
        if !newLatin.isEmpty {
            let allowed = Set(dictionary.entries.map { $0.surface.lowercased() })
            if !newLatin.allSatisfy({ allowed.contains($0.lowercased()) }) {
                return .reject(.newLatinToken)
            }
        }

        // 2. 読み一致（主防壁）
        if policy.requireReadingMatch {
            guard Reading.isUsable(o), Reading.isUsable(p) else {
                return .reject(.readingUnavailable)
            }
            if Reading.key(o) != Reading.key(p) {
                let excused = policy.allowDictionaryReadingChange
                    && dictionary.explains(original: o, proposed: p)
                if !excused { return .reject(.readingChanged) }
            }
        }

        // 3. 量的な制約
        if !o.isEmpty {
            let ratio = Double(p.count) / Double(o.count)
            if ratio > policy.maxLengthRatio || ratio < policy.minLengthRatio {
                return .reject(.lengthOutOfRange)
            }
        }
        if TextDistance.levenshtein(Array(o), Array(p)) > policy.maxEditDistance {
            return .reject(.editDistanceTooLarge)
        }
        return .accept
    }

    private func latinTokens(_ s: String) -> Set<String> {
        let parts = s.split(whereSeparator: { !($0.isLetter && $0.isASCII) && !($0.isNumber && $0.isASCII) })
        return Set(parts.map(String.init).filter { $0.count >= 2 })
    }
}
