import Foundation

/// 認識精度の計測。CER / WER と、その内訳（置換・脱落・挿入）を出す。
///
/// 目的は「速くなった」「良くなった気がする」を数字に落とすこと。
/// このプロジェクトではこれまで改善を主観で判断してきた場面があり
/// （語彙注入のA/Bだけは実測したが、照合やゲートの効果は未計測）、
/// ここが無いと設定を変えたときの良し悪しが確かめられない。
///
/// 正解データそのものは人が作る。ここは受け皿と算出だけを持つ。
public struct Benchmark: Sendable {

    // MARK: - 正解データ

    /// 正解の書き起こし。時刻を持つ形と、本文だけの形の両方を受ける。
    /// 時刻があれば区間ごとの比較ができるが、無くても全体のCERは出せる。
    public struct Reference: Sendable, Codable, Equatable {
        public struct Line: Sendable, Codable, Equatable {
            public var start: Double?
            public var end: Double?
            public var text: String
            public init(start: Double? = nil, end: Double? = nil, text: String) {
                self.start = start; self.end = end; self.text = text
            }
        }
        public var lines: [Line]
        /// 素材の識別子（ファイル名など）。取り違え防止のためだけに持つ。
        public var source: String?
        public init(lines: [Line], source: String? = nil) {
            self.lines = lines; self.source = source
        }

        public var fullText: String { lines.map(\.text).joined() }
        public var hasTimestamps: Bool { lines.contains { $0.start != nil } }

        /// JSON（`{"source":..., "lines":[{"start":..,"end":..,"text":".."}]}`）
        public static func fromJSON(_ data: Data) throws -> Reference {
            try JSONDecoder().decode(Reference.self, from: data)
        }

        /// プレーンテキスト。1行1発話として読む。
        /// `00:01:23<TAB>本文` の形なら時刻として解釈する。
        /// 下書きを手で作るときに一番書きやすい形なので用意している。
        public static func fromPlainText(_ text: String, source: String? = nil) -> Reference {
            var lines: [Line] = []
            for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let s = raw.trimmingCharacters(in: .whitespaces)
                if s.isEmpty || s.hasPrefix("#") { continue }   // 空行とコメントは無視
                let parts = s.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2, let t = parseTimecode(String(parts[0])) {
                    lines.append(.init(start: t, text: String(parts[1]).trimmingCharacters(in: .whitespaces)))
                } else {
                    lines.append(.init(text: s))
                }
            }
            return Reference(lines: lines, source: source)
        }

        /// `HH:MM:SS(.mmm)` / `MM:SS` / 秒数 を受ける
        static func parseTimecode(_ s: String) -> Double? {
            let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            if let plain = Double(t), !t.contains(":") { return plain }
            let parts = t.split(separator: ":").map(String.init)
            guard parts.count == 2 || parts.count == 3 else { return nil }
            var total: Double = 0
            for p in parts {
                guard let v = Double(p) else { return nil }
                total = total * 60 + v
            }
            return total
        }
    }

    // MARK: - 正規化

    /// 何を「同じ」とみなすかの取り決め。
    ///
    /// ここを揃えないと数字が比較できない。既定は日本語CERの一般的な扱いに寄せて、
    /// 句読点と空白を落とし、全角英数を半角に、カタカナ・ひらがなはそのまま
    /// （かな表記の揺れを吸収したいときは `foldKana` を立てる）。
    /// **どの設定で測ったかを必ず結果に添えること。** 設定が違えば数字は比較できない。
    public struct NormalizationPolicy: Sendable, Codable, Equatable {
        public var stripPunctuation: Bool = true
        public var stripWhitespace: Bool = true
        /// 全角英数 → 半角、半角カナ → 全角
        public var normalizeWidth: Bool = true
        /// 大文字小文字を無視
        public var caseInsensitive: Bool = true
        /// ひらがな↔カタカナの違いを無視する。表記揺れを誤りに数えたくない場合に立てる。
        public var foldKana: Bool = false
        /// 長音・促音・撥音の揺れを無視する（「サーバ/サーバー」）。既定は無効。
        public var ignoreProlongedSoundMark: Bool = false

        public init() {}

        public static let strict: NormalizationPolicy = {
            var p = NormalizationPolicy()
            p.stripPunctuation = false
            p.normalizeWidth = false
            p.caseInsensitive = false
            return p
        }()

        /// 表記揺れを許す緩い設定。内容が合っているかだけを見たいとき用。
        public static let lenient: NormalizationPolicy = {
            var p = NormalizationPolicy()
            p.foldKana = true
            p.ignoreProlongedSoundMark = true
            return p
        }()

        public var describe: String {
            var on: [String] = []
            if stripPunctuation { on.append("句読点除去") }
            if stripWhitespace { on.append("空白除去") }
            if normalizeWidth { on.append("全半角統一") }
            if caseInsensitive { on.append("大小無視") }
            if foldKana { on.append("かな統一") }
            if ignoreProlongedSoundMark { on.append("長音無視") }
            return on.isEmpty ? "正規化なし" : on.joined(separator: "・")
        }
    }

    public static func normalize(_ s: String, policy: NormalizationPolicy) -> String {
        var t = s
        if policy.normalizeWidth {
            t = t.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? t
        }
        if policy.caseInsensitive { t = t.lowercased() }
        if policy.foldKana {
            t = t.applyingTransform(.hiraganaToKatakana, reverse: false) ?? t
        }
        var out = String.UnicodeScalarView()
        for u in t.unicodeScalars {
            let ch = Character(u)
            if policy.stripWhitespace, ch.isWhitespace { continue }
            if policy.ignoreProlongedSoundMark, u.value == 0x30FC { continue }   // 「ー」
            if policy.stripPunctuation, isPunctuation(u) { continue }
            out.append(u)
        }
        return String(out)
    }

    static func isPunctuation(_ u: Unicode.Scalar) -> Bool {
        let ch = Character(u)
        if ch.isPunctuation || ch.isSymbol { return true }
        // 和文の記号は Character.isPunctuation で拾えないものがあるので明示する
        return "、。・「」『』（）［］〈〉《》〔〕…‥ー－―〜！？".unicodeScalars.contains(u)
            && u.value != 0x30FC   // 長音は ignoreProlongedSoundMark 側で扱う
    }

    // MARK: - 結果

    public struct Result: Sendable, Codable, Equatable {
        /// 単位（"文字" / "語"）
        public var unit: String
        public var referenceCount: Int
        public var hypothesisCount: Int
        public var substitutions: Int
        public var deletions: Int
        public var insertions: Int
        public var policyDescription: String

        public var errors: Int { substitutions + deletions + insertions }
        /// 誤り率。参照が空なら、仮説が空のとき0、そうでなければ1。
        public var rate: Double {
            guard referenceCount > 0 else { return hypothesisCount == 0 ? 0 : 1 }
            return Double(errors) / Double(referenceCount)
        }
        public var accuracy: Double { max(0, 1 - rate) }

        public var summary: String {
            String(format: "%@誤り率 %.2f%%（置換 %d・脱落 %d・挿入 %d / 参照 %d）[%@]",
                   unit, rate * 100, substitutions, deletions, insertions,
                   referenceCount, policyDescription)
        }
    }

    /// 参照と仮説の食い違いを1件ずつ並べたもの。数字だけ見ても直せないので必ず添える。
    public struct Difference: Sendable, Codable, Equatable, Identifiable {
        public enum Kind: String, Sendable, Codable { case substitution, deletion, insertion }
        public var id: Int
        public var kind: Kind
        /// 参照側の位置（挿入の場合は挿入位置）
        public var referenceIndex: Int
        public var reference: String
        public var hypothesis: String
    }

    public struct Report: Sendable, Codable, Equatable {
        public var cer: Result
        public var wer: Result?
        public var differences: [Difference]
        /// 誤りが多い順の上位。まず何を直すべきかを見るため。
        public var topConfusions: [Confusion]

        public struct Confusion: Sendable, Codable, Equatable {
            public var reference: String
            public var hypothesis: String
            public var count: Int
        }
    }

    // MARK: - 算出

    public var policy: NormalizationPolicy
    /// 日本語のWERは分かち書きの仕方に強く依存し、他ツールの数字と比較できない。
    /// 既定で切ってあるのはそのため。立てる場合は同じトークナイザ同士でしか比べないこと。
    public var computeWER: Bool
    public var maxDifferences: Int

    public init(policy: NormalizationPolicy = .init(),
                computeWER: Bool = false,
                maxDifferences: Int = 200) {
        self.policy = policy
        self.computeWER = computeWER
        self.maxDifferences = maxDifferences
    }

    public func evaluate(reference: Reference, hypothesis: Transcript) -> Report {
        evaluate(referenceText: reference.fullText,
                 hypothesisText: hypothesis.visibleSegments.map(\.text).joined())
    }

    public func evaluate(referenceText: String, hypothesisText: String) -> Report {
        let r = Array(Self.normalize(referenceText, policy: policy))
        let h = Array(Self.normalize(hypothesisText, policy: policy))
        let (ops, counts) = Self.align(r.map(String.init), h.map(String.init))

        let cer = Result(unit: "文字",
                         referenceCount: r.count, hypothesisCount: h.count,
                         substitutions: counts.s, deletions: counts.d, insertions: counts.i,
                         policyDescription: policy.describe)

        var wer: Result? = nil
        if computeWER {
            let rw = Self.words(referenceText, policy: policy)
            let hw = Self.words(hypothesisText, policy: policy)
            let (_, wc) = Self.align(rw, hw)
            wer = Result(unit: "語",
                         referenceCount: rw.count, hypothesisCount: hw.count,
                         substitutions: wc.s, deletions: wc.d, insertions: wc.i,
                         policyDescription: policy.describe + "・語単位")
        }

        let diffs = Array(ops.prefix(maxDifferences))
        var tally: [String: Int] = [:]
        for d in ops where d.kind == .substitution {
            tally["\(d.reference)\u{0001}\(d.hypothesis)", default: 0] += 1
        }
        let top = tally.sorted { $0.value > $1.value }.prefix(20).map { kv -> Report.Confusion in
            let parts = kv.key.split(separator: "\u{0001}", maxSplits: 1, omittingEmptySubsequences: false)
            return .init(reference: String(parts.first ?? ""),
                         hypothesis: parts.count > 1 ? String(parts[1]) : "",
                         count: kv.value)
        }
        return Report(cer: cer, wer: wer, differences: diffs, topConfusions: Array(top))
    }

    /// 語分割。`CFStringTokenizer` の語単位を使う。
    /// 日本語では分割の仕方が実装依存なので、これで出した WER は
    /// **同じこのコードで測った値同士でしか比較してはいけない。**
    static func words(_ s: String, policy: NormalizationPolicy) -> [String] {
        let t = normalize(s, policy: policy)
        guard !t.isEmpty else { return [] }
        let cf = t as CFString
        let range = CFRangeMake(0, CFStringGetLength(cf))
        guard let tk = CFStringTokenizerCreate(kCFAllocatorDefault, cf, range,
                                               kCFStringTokenizerUnitWord,
                                               CFLocaleCopyCurrent()) as CFStringTokenizer? else {
            return t.map(String.init)
        }
        var out: [String] = []
        while CFStringTokenizerAdvanceToNextToken(tk) != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tk)
            if let sub = CFStringCreateWithSubstring(kCFAllocatorDefault, cf, r) as String? {
                if !sub.isEmpty { out.append(sub) }
            }
        }
        return out.isEmpty ? t.map(String.init) : out
    }

    struct Counts { var s = 0; var d = 0; var i = 0 }

    /// レーベンシュタイン距離を後戻り付きで取り、置換・脱落・挿入を1件ずつ復元する。
    /// 数字だけでは直せないので、どこがどう違ったかを必ず出せるようにしている。
    static func align(_ r: [String], _ h: [String]) -> ([Difference], Counts) {
        let n = r.count, m = h.count
        if n == 0 && m == 0 { return ([], Counts()) }

        // 0=一致, 1=置換, 2=脱落(参照にあって仮説に無い), 3=挿入
        var dist = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        var back = [[UInt8]](repeating: [UInt8](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { dist[i][0] = i; back[i][0] = 2 }
        for j in 0...m { dist[0][j] = j; back[0][j] = 3 }
        back[0][0] = 0

        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let same = r[i-1] == h[j-1]
                    let sub = dist[i-1][j-1] + (same ? 0 : 1)
                    let del = dist[i-1][j] + 1
                    let ins = dist[i][j-1] + 1
                    let best = min(sub, del, ins)
                    dist[i][j] = best
                    // 一致を最優先にする。同点のときに置換を選ぶと差分が読みにくくなる。
                    if best == sub { back[i][j] = same ? 0 : 1 }
                    else if best == del { back[i][j] = 2 }
                    else { back[i][j] = 3 }
                }
            }
        }

        var out: [Difference] = []
        var counts = Counts()
        var i = n, j = m, id = 0
        while i > 0 || j > 0 {
            let op = back[i][j]
            switch op {
            case 0:
                i -= 1; j -= 1
            case 1:
                counts.s += 1
                out.append(.init(id: id, kind: .substitution, referenceIndex: i - 1,
                                 reference: r[i-1], hypothesis: h[j-1]))
                id += 1; i -= 1; j -= 1
            case 2:
                counts.d += 1
                out.append(.init(id: id, kind: .deletion, referenceIndex: i - 1,
                                 reference: r[i-1], hypothesis: ""))
                id += 1; i -= 1
            default:
                counts.i += 1
                out.append(.init(id: id, kind: .insertion, referenceIndex: i,
                                 reference: "", hypothesis: h[j-1]))
                id += 1; j -= 1
            }
        }
        // 後ろから復元したので時系列に直す
        out.reverse()
        for k in out.indices { out[k].id = k }
        return (out, counts)
    }
}

// MARK: - 出力

extension Benchmark.Report {
    /// 人が読む形。設定を必ず併記する（設定が違う数字は比較できないため）。
    public func markdown(title: String) -> String {
        var out: [String] = ["# 精度計測 — \(title)\n"]
        out.append("| 指標 | 値 |")
        out.append("|---|---|")
        out.append("| 文字誤り率 (CER) | \(String(format: "%.2f%%", cer.rate * 100)) |")
        out.append("| 　置換 | \(cer.substitutions) |")
        out.append("| 　脱落 | \(cer.deletions) |")
        out.append("| 　挿入 | \(cer.insertions) |")
        out.append("| 参照の文字数 | \(cer.referenceCount) |")
        out.append("| 認識結果の文字数 | \(cer.hypothesisCount) |")
        if let w = wer {
            out.append("| 語誤り率 (WER) | \(String(format: "%.2f%%", w.rate * 100)) |")
        }
        out.append("| 正規化 | \(cer.policyDescription) |")
        out.append("")
        if wer != nil {
            out.append("> 日本語のWERは分かち書きの実装に依存する。**このコードで測った値同士でしか比較できない。**\n")
        }
        if !topConfusions.isEmpty {
            out.append("## 多い誤り\n")
            out.append("| 正解 | 認識 | 回数 |")
            out.append("|---|---|---|")
            for c in topConfusions {
                out.append("| \(c.reference) | \(c.hypothesis) | \(c.count) |")
            }
            out.append("")
        }
        if !differences.isEmpty {
            out.append("## 差分（先頭\(differences.count)件）\n")
            for d in differences.prefix(100) {
                switch d.kind {
                case .substitution: out.append("- `\(d.referenceIndex)` 置換 \(d.reference) → \(d.hypothesis)")
                case .deletion:     out.append("- `\(d.referenceIndex)` 脱落 \(d.reference)")
                case .insertion:    out.append("- `\(d.referenceIndex)` 挿入 \(d.hypothesis)")
                }
            }
        }
        return out.joined(separator: "\n") + "\n"
    }
}
