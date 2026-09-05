import Foundation

/// 文字列同士の距離。**ここが唯一の実装**。
///
/// 以前は `EditGate` の中にだけあり、`PlausibilityGate` でも読みの近さを測る必要が
/// 出たときに複製されかけた。同じ計算が2箇所にあると、片方だけ直したときに
/// 「校正では通るが指摘では落ちる」のような、エラーにならないずれが生まれる。
public enum TextDistance {

    /// 文字単位のレーベンシュタイン距離
    public static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i-1] == b[j-1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j-1] + 1, prev[j-1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// 長い方の文字数で割った距離。0 が同一、1 が完全に別物。
    /// 長さの違う語同士を同じ尺度で比べるために使う。
    public static func normalized(_ a: String, _ b: String) -> Double {
        if a.isEmpty && b.isEmpty { return 0 }
        let d = levenshtein(Array(a), Array(b))
        return Double(d) / Double(max(a.count, b.count))
    }
}
