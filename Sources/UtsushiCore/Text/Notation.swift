import Foundation

/// 表記の揺れを比較用にそろえる。
///
/// 出力を書き換えるためのものではない。**比較のときだけ**同じ土俵に載せる。
/// エンジンごとに「三月」と「3月」、「１０」と「10」のように書き方が違うだけで、
/// 音として同じものが「食い違い」として数えられてしまうため。
///
/// ここは要約の見張り（`SummaryGate`）と照合（`TranscriptAlignment`）の
/// 両方から使う。以前は `SummaryGate` の中にだけ漢数字の解釈があり、
/// 照合側には無かった。同じ規則が2箇所で食い違っているのは事故のもとなので
/// 1箇所にまとめてある。
public enum Notation {

    // MARK: - 漢数字

    static let kanjiDigits: [Character: Int] = [
        "〇": 0, "零": 0, "一": 1, "二": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
    ]
    static let kanjiSmallUnits: [Character: Int] = ["十": 10, "百": 100, "千": 1000]
    static let kanjiBigUnits: [Character: Int] = ["万": 10_000, "億": 100_000_000]
    static let kanjiNumeral: Set<Character> =
        Set(kanjiDigits.keys).union(kanjiSmallUnits.keys).union(kanjiBigUnits.keys)

    /// 半角・全角の算用数字を1桁の文字列にする。数字でなければ nil。
    static func arabicDigit(_ ch: Character) -> String? {
        if ch.isASCII, ch.isNumber { return String(ch) }
        if let a = ch.unicodeScalars.first, a.value >= 0xFF10, a.value <= 0xFF19 {
            return String(a.value - 0xFF10)   // 全角数字
        }
        return nil
    }

    /// 漢数字を整数に直す。
    /// 位取りが無い並び（〇八〇 のような読み上げ）は桁の連結として扱う。
    /// 解釈できない並びは nil を返す。ここで無理に数値化すると
    /// 「解釈に失敗した」ことが「別の数値だった」に化けてしまう。
    public static func parseKanjiNumber(_ s: String) -> Int? {
        let chars = Array(s)
        guard !chars.isEmpty else { return nil }

        let hasUnit = chars.contains { kanjiSmallUnits[$0] != nil || kanjiBigUnits[$0] != nil }
        if !hasUnit {
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

    /// 数値の並びを走査して、算用数字の塊と漢数字の塊を切り出す。
    /// `canonicalNumbers` と `numberTokens` で同じ切り出し方を使うための共通部分。
    private static func scanNumerals(_ s: String,
                                     onArabic: (String) -> Void,
                                     onKanji: (String) -> Void,
                                     onOther: (Character) -> Void) {
        var arabic = ""
        var kanji = ""
        func flushArabic() {
            guard !arabic.isEmpty else { return }
            // 先頭の 0 を落として「07」と「7」をそろえる。全部 0 なら "0"。
            let trimmed = String(arabic.drop(while: { $0 == "0" }))
            onArabic(trimmed.isEmpty ? "0" : trimmed)
            arabic = ""
        }
        func flushKanji() {
            guard !kanji.isEmpty else { return }
            onKanji(kanji)
            kanji = ""
        }
        for ch in s {
            if let d = arabicDigit(ch) {
                flushKanji(); arabic += d
            } else if kanjiNumeral.contains(ch) {
                flushArabic(); kanji.append(ch)
            } else {
                flushArabic(); flushKanji(); onOther(ch)
            }
        }
        flushArabic(); flushKanji()
    }

    /// 文中の数値表記を算用数字にそろえた文字列を返す。
    ///
    /// 解釈できなかった漢数字はそのまま残す。落とすと文字が消えて
    /// 別の食い違いに見えてしまう。
    public static func canonicalNumbers(_ s: String) -> String {
        var out = ""
        scanNumerals(s,
                     onArabic: { out += $0 },
                     onKanji: { out += parseKanjiNumber($0).map(String.init) ?? $0 },
                     onOther: { out.append($0) })
        return out
    }

    /// 文中に出てくる数値を、表記を問わない形で集める。
    /// 「3件」と「三件」は同じ集合を返す。
    /// 解釈できなかった漢数字は**数えない**——数えると解釈の失敗が
    /// 「原文に無い数値が出た」に化けてしまう。
    public static func numberTokens(_ s: String) -> Set<String> {
        var out: Set<String> = []
        scanNumerals(s,
                     onArabic: { out.insert($0) },
                     onKanji: { if let v = parseKanjiNumber($0) { out.insert(String(v)) } },
                     onOther: { _ in })
        return out
    }

    // MARK: - 全角・半角

    /// 全角の英数字・記号を半角にそろえる。
    /// エンジンによって「ＡＩ」と「AI」が混ざるため。
    public static func foldWidth(_ s: String) -> String {
        s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
    }

    // MARK: - 比較用キー

    /// 照合で「同じことを言っている」と見なすためのキー。
    /// 数値表記・全角半角・大小文字・空白・約物を落とす。
    ///
    /// 落とせるのは**表記**だけで、語の選択の違いは残る。
    /// ただし「十分」と「10分」のように、表記をそろえると意味の違いまで
    /// 消えてしまう組み合わせは存在する。だからこのキーで一致した食い違いは
    /// **捨てずに `.notation` として記録に残す**（`TranscriptAlignment` 側で扱う）。
    public static func comparisonKey(_ s: String) -> String {
        let folded = foldWidth(canonicalNumbers(s)).lowercased()
        return String(folded.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
        })
    }
}
