import Foundation

/// 見出しの検証。
///
/// 校正の `EditGate` は「読みが変わらないこと」を主防壁にできるが、
/// 見出しは要約＝言い換えなので読み一致は使えない。
/// そこで**原文に存在しない情報が現れていないか**だけを見る。
/// 検出できるのは数値・英数字・カタカナ語の創作で、
/// 助詞や語順の言い換えは通る。これは仕様であり、限界でもある。
public struct SummaryGate: Sendable {

    public struct Policy: Sendable {
        public var maxCharacters: Int = 40
        public var minCharacters: Int = 2
        /// 原文に無い数字（半角・全角・漢数字）を含む見出しを落とす
        public var rejectNewNumbers: Bool = true
        /// 原文に無い英数字トークンを含む見出しを落とす
        public var rejectNewLatinTokens: Bool = true
        /// 原文に無いカタカナ語（3文字以上）を含む見出しを落とす
        public var rejectNewKatakanaTerms: Bool = true
        /// 原文に無い漢語（漢字2文字以上の連続）を含む見出しを落とす。
        ///
        /// これが無いと「予算を承認」→「予算を却下」が通る。数値の創作より悪い。
        /// 代償として言い換えの自由度が下がり、モデルの見出しが棄却されて
        /// 原文抜粋に落ちる割合が増える。その割合は `Summary.modelHeadlineRatio`
        /// と種別ごとの棄却件数で観測できるようにしてある。
        public var rejectNewKanjiTerms: Bool = true
        public init() {}
    }

    public enum Rejection: String, Sendable, Codable, Equatable {
        case tooLong
        case tooShort
        case newNumber
        case newLatinToken
        case newKatakanaTerm
        case newKanjiTerm
        /// 引用そのものを見出しに使おうとした（要約になっていない）
        case notASummary
    }

    public enum Verdict: Sendable, Equatable {
        case accept
        case reject(Rejection)
        public var isAccepted: Bool { if case .accept = self { return true }; return false }
    }

    public var policy: Policy
    public init(policy: Policy = Policy()) { self.policy = policy }

    public func evaluate(headline: String, source: String) -> Verdict {
        let h = headline.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.count < policy.minCharacters { return .reject(.tooShort) }
        if h.count > policy.maxCharacters { return .reject(.tooLong) }

        if policy.rejectNewLatinTokens {
            let new = Self.latinTokens(h).subtracting(Self.latinTokens(source))
            if !new.isEmpty { return .reject(.newLatinToken) }
        }
        if policy.rejectNewNumbers {
            let new = Self.numberTokens(h).subtracting(Self.numberTokens(source))
            if !new.isEmpty { return .reject(.newNumber) }
        }
        if policy.rejectNewKatakanaTerms {
            let new = Self.katakanaTerms(h).subtracting(Self.katakanaTerms(source))
            if !new.isEmpty { return .reject(.newKatakanaTerm) }
        }
        if policy.rejectNewKanjiTerms {
            let new = Self.kanjiTerms(h).subtracting(Self.kanjiTerms(source))
            if !new.isEmpty { return .reject(.newKanjiTerm) }
        }
        return .accept
    }

    // MARK: - トークン抽出

    /// 数字だけのトークンはここでは扱わない。
    /// 数字は `numberTokens` が漢数字・全角と同じ土俵に載せてから比較するので、
    /// こちらで先に拾うと「120」と「百二十」が別物として落ちてしまう
    /// （実際にテストで露見した）。
    static func latinTokens(_ s: String) -> Set<String> {
        let parts = s.split(whereSeparator: { !($0.isLetter && $0.isASCII) && !($0.isNumber && $0.isASCII) })
        return Set(parts.map { $0.lowercased() }
            .filter { $0.count >= 2 && !$0.allSatisfy(\.isNumber) })
    }

    /// 半角数字・全角数字・漢数字を同じ土俵に載せてから比較する。
    /// 「3件」を「三件」と書き換えただけで落とすと、まともな見出しが全部落ちる。
    static func numberTokens(_ s: String) -> Set<String> {
        var out: Set<String> = []
        var arabic = ""
        var kanji = ""

        func flushArabic() {
            if !arabic.isEmpty { out.insert(arabic); arabic = "" }
        }
        func flushKanji() {
            if !kanji.isEmpty {
                if let v = parseKanjiNumber(kanji) { out.insert(String(v)) }
                kanji = ""
            }
        }

        for ch in s {
            if let d = Self.arabicDigit(ch) {
                flushKanji(); arabic += d
            } else if Self.kanjiNumeral.contains(ch) {
                flushArabic(); kanji.append(ch)
            } else {
                flushArabic(); flushKanji()
            }
        }
        flushArabic(); flushKanji()
        return out
    }

    private static let kanjiDigits: [Character: Int] = [
        "〇": 0, "零": 0, "一": 1, "二": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
    ]
    private static let kanjiSmallUnits: [Character: Int] = ["十": 10, "百": 100, "千": 1000]
    private static let kanjiBigUnits: [Character: Int] = ["万": 10_000, "億": 100_000_000]
    private static let kanjiNumeral: Set<Character> =
        Set(kanjiDigits.keys).union(kanjiSmallUnits.keys).union(kanjiBigUnits.keys)

    private static func arabicDigit(_ ch: Character) -> String? {
        if ch.isASCII, ch.isNumber { return String(ch) }
        if let a = ch.unicodeScalars.first, a.value >= 0xFF10, a.value <= 0xFF19 {
            return String(a.value - 0xFF10)   // 全角数字
        }
        return nil
    }

    /// 漢数字を整数に直す。
    /// 位取りが無い並び（〇八〇 のような読み上げ）は桁の連結として扱う。
    /// 解釈できない並びは nil を返し、その場合は数値トークンとして数えない
    /// （数えると「解釈に失敗した」ことが「新しい数値が出た」に化けてしまう）。
    static func parseKanjiNumber(_ s: String) -> Int? {
        let chars = Array(s)
        guard !chars.isEmpty else { return nil }

        let hasUnit = chars.contains { kanjiSmallUnits[$0] != nil || kanjiBigUnits[$0] != nil }
        if !hasUnit {
            // 位取りが無いので桁の並びとして読む
            var digits = ""
            for c in chars {
                guard let d = kanjiDigits[c] else { return nil }
                digits += String(d)
            }
            return Int(digits)
        }

        var total = 0        // 万・億で確定した分
        var section = 0      // 現在の万未満の塊
        var current = 0      // 直前の数字
        var sawAnything = false

        for c in chars {
            if let d = kanjiDigits[c] {
                current = current * 10 + d
                sawAnything = true
            } else if let u = kanjiSmallUnits[c] {
                // 「十」は前に数字が無ければ 1（十五＝15）
                section += (current == 0 ? 1 : current) * u
                current = 0
                sawAnything = true
            } else if let b = kanjiBigUnits[c] {
                section += current
                current = 0
                if section == 0 { return nil }   // 「万」単独などは解釈しない
                total += section * b
                section = 0
                sawAnything = true
            } else {
                return nil
            }
        }
        guard sawAnything else { return nil }
        return total + section + current
    }

    /// 3文字以上のカタカナ連続。長音・中黒は語の一部として扱う。
    static func katakanaTerms(_ s: String) -> Set<String> {
        var out: Set<String> = []
        var current = ""
        for ch in s {
            if Self.isKatakana(ch) {
                current.append(ch)
            } else {
                if current.count >= 3 { out.insert(current) }
                current = ""
            }
        }
        if current.count >= 3 { out.insert(current) }
        return out
    }

    /// 2文字以上の漢字の連続。日本語の内容語はここに集中する。
    /// 数字として使われる漢数字（十・百・千・万）は `numberTokens` の担当なので外す
    /// ——「三段階」を漢語として弾くと、まともな言い換えまで落ちる。
    static func kanjiTerms(_ s: String) -> Set<String> {
        var out: Set<String> = []
        var current = ""
        for ch in s {
            if Self.isKanji(ch), !Self.kanjiNumeral.contains(ch) {
                current.append(ch)
            } else {
                if current.count >= 2 { out.insert(current) }
                current = ""
            }
        }
        if current.count >= 2 { out.insert(current) }
        return out
    }

    private static func isKanji(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v)      // CJK統合漢字
            || (0x3400...0x4DBF).contains(v)      // 拡張A
            || (0xF900...0xFAFF).contains(v)      // 互換漢字
    }

    private static func isKatakana(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        // カタカナ (30A0–30FF) と半角カタカナ (FF66–FF9F)
        return (0x30A0...0x30FF).contains(v) || (0xFF66...0xFF9F).contains(v)
    }

    /// 見出しが作れなかったときの代替。引用の先頭を句読点で切って使う。
    /// モデルを通さないので創作は起きないが、要約にはなっていない。
    public static func extractHeadline(from text: String, limit: Int = 30) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        let stops: Set<Character> = ["。", "、", "？", "！", "\n"]
        var out = ""
        for ch in t {
            if stops.contains(ch) {
                if out.count >= 6 { break }
                continue
            }
            out.append(ch)
            if out.count >= limit { break }
        }
        return out.isEmpty ? String(t.prefix(limit)) : out
    }
}
