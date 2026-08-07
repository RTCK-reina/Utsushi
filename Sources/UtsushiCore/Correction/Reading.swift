import Foundation

/// 日本語テキストの読みを取り出す。校正ゲートの土台。
///
/// CFStringTokenizer の LatinTranscription を使う。漢字かな交じり文から
/// ローマ字読みが得られるので、それを正規化して比較キーにする。
/// 「機構」と「気候」は同じキーになり、「新小物」と「BeeX」は別キーになる。
public enum Reading {

    /// 比較に使う正規化済みの読み。ローマ字・小文字・英数以外を全部落とす。
    /// 句読点や記号は読みに寄与しないので、句読点の挿入は読みを変えない＝ゲートを通る。
    public static func key(_ text: String) -> String {
        let romaji = latinTranscription(text)
        var out = String.UnicodeScalarView()
        for u in romaji.lowercased().unicodeScalars {
            if (u.value >= 97 && u.value <= 122) || (u.value >= 48 && u.value <= 57) {
                out.append(u)
            }
        }
        return String(out)
    }

    /// 表示用のひらがな読み。
    public static func hiragana(_ text: String) -> String {
        let m = NSMutableString(string: latinTranscription(text))
        CFStringTransform(m, nil, kCFStringTransformLatinHiragana, false)
        return (m as String).replacingOccurrences(of: " ", with: "")
    }

    /// トークンごとのローマ字読みを空白区切りで返す。
    /// 読みが取れないトークン（英数字・記号など）は原文をそのまま入れる。
    public static func latinTranscription(_ text: String) -> String {
        let cf = text as CFString
        let full = CFRangeMake(0, CFStringGetLength(cf))
        guard full.length > 0,
              let tok = CFStringTokenizerCreate(kCFAllocatorDefault, cf, full,
                            kCFStringTokenizerUnitWordBoundary,
                            Locale(identifier: "ja_JP") as CFLocale)
        else { return text }

        let ns = text as NSString
        var parts: [String] = []
        while !CFStringTokenizerAdvanceToNextToken(tok).isEmpty {
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(
                    tok, kCFStringTokenizerAttributeLatinTranscription) as? String,
               !latin.isEmpty {
                parts.append(latin)
            } else {
                let r = CFStringTokenizerGetCurrentTokenRange(tok)
                if r.location != kCFNotFound, r.length > 0,
                   r.location + r.length <= ns.length {
                    parts.append(ns.substring(with: NSRange(location: r.location, length: r.length)))
                }
            }
        }
        return parts.joined(separator: " ")
    }

    /// 読みが取れているか（漢字を含むのにキーが空、等の異常検出用）
    public static func isUsable(_ text: String) -> Bool {
        let stripped = text.unicodeScalars.filter { CharacterSet.whitespacesAndNewlines.inverted.contains($0) }
        if stripped.isEmpty { return true }
        return !key(text).isEmpty
    }
}
