import Foundation

/// 複数エンジンの文字起こしを突き合わせて、食い違っている箇所を取り出す。
///
/// 日本語には語境界が無く、エンジンごとにセグメントの切り方も違う（whisper 22本 / Apple 12本）。
/// そのため「セグメント同士を対応付ける」のではなく、
/// 時間窓で本文を集めてから**文字単位のアライメント**で差分スパンを取る。
public enum TranscriptAlignment {

    public struct Candidate: Sendable, Codable, Equatable {
        public var engine: String
        public var text: String
        public init(engine: String, text: String) { self.engine = engine; self.text = text }
    }

    /// 食い違いの種類。
    ///
    /// `.substantive` 以外は既定で人に見せないが、**どれも捨てはしない**。
    /// 分類はすべて機械的な近似で、外すことがある——たとえば表記をそろえると
    /// 「十分」と「10分」のように意味の違いまで消える組み合わせが存在する。
    /// なので件数は常に画面に出し、チェックひとつで全件たどれる状態を保つ。
    /// 「見せない」であって「無かったことにする」ではない。
    ///
    /// 実データ（11分・4エンジン）で人に残っていた282件の内訳がこの分類の出発点:
    /// 片側が空 54% / ひらがなだけの短い差 34% / 実際に見る価値があったもの 約5%。
    public enum Kind: String, Sendable, Codable, Equatable {
        /// 中身が違う。人が見るべきもの。
        case substantive
        /// 表記だけの違い。「三月」と「3月」、「いただ」と「頂」。
        case notation
        /// 片方の窓に寄っただけで、本文は両方のエンジンにある。
        /// 認識の違いではなく置き場所の違い。
        case alignment
        /// 語尾・助詞のゆれ。「と」と「って」、「を」と「は」。
        /// ひらがなと約物だけで構成され、かつ収録全体でくり返し出るもの。
        case inflection

        /// 人に見せる対象か。
        public var needsHumanReview: Bool { self == .substantive }
    }

    public struct Disagreement: Sendable, Codable, Equatable, Identifiable {
        public var id: UUID
        public var start: Double
        public var end: Double
        /// 食い違っている部分の各エンジンの表記。順序は入力の順序を保つ。
        public var candidates: [Candidate]
        /// 全候補の読みが一致するか。
        /// true なら音響では区別できない同音異義語の選択なので、文脈から判断するのが正しい。
        /// false なら音響に情報が残っているので、テキストだけで判定するのは筋が悪い。
        public var readingsMatch: Bool
        /// 前後の文脈（判定材料。書き換え対象ではない）
        public var context: String
        /// 表記だけの違いか、中身の違いか。
        public var kind: Kind

        public init(id: UUID = UUID(), start: Double, end: Double,
                    candidates: [Candidate], readingsMatch: Bool, context: String,
                    kind: Kind = .substantive) {
            self.id = id; self.start = start; self.end = end
            self.candidates = candidates; self.readingsMatch = readingsMatch; self.context = context
            self.kind = kind
        }

        /// 古い JSON（`kind` が無いもの）を読めるようにしておく。
        /// 既存の書き出しを壊さないため。
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            start = try c.decode(Double.self, forKey: .start)
            end = try c.decode(Double.self, forKey: .end)
            candidates = try c.decode([Candidate].self, forKey: .candidates)
            readingsMatch = try c.decode(Bool.self, forKey: .readingsMatch)
            context = try c.decode(String.self, forKey: .context)
            kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .substantive
        }
    }

    public struct Run: Sendable {
        public var engine: String
        public var segments: [Segment]
        public init(engine: String, segments: [Segment]) {
            self.engine = engine; self.segments = segments
        }
    }

    /// 比較を行う。先頭の Run を基準（reference）として扱う。
    public static func compare(_ runs: [Run],
                               windowSeconds: Double = 10,
                               minSpanCharacters: Int = 1) -> [Disagreement] {
        guard runs.count >= 2 else { return [] }
        let duration = runs.flatMap { $0.segments }.map(\.end).max() ?? 0
        guard duration > 0 else { return [] }

        var out: [Disagreement] = []
        var windowStart = 0.0
        while windowStart < duration {
            let windowEnd = min(windowStart + windowSeconds, duration)
            let texts = runs.map { text(of: $0, from: windowStart, to: windowEnd) }
            defer { windowStart = windowEnd }

            // 全部空、または全部同じなら何もしない
            let normalized = texts.map(normalize)
            guard normalized.contains(where: { !$0.isEmpty }) else { continue }
            guard Set(normalized).count > 1 else { continue }

            // 窓を1つ分ずつ広げた本文。片側が空のスパンが「認識できていない」のか
            // 「隣の窓に寄っただけ」なのかを、この範囲に本文があるかで区別する。
            let widened = runs.map {
                normalize(text(of: $0, from: windowStart - windowSeconds, to: windowEnd + windowSeconds))
            }

            let reference = texts[0]
            let referenceChars = Array(reference)
            for i in 1..<runs.count {
                let otherChars = Array(texts[i])
                let spans = differingSpans(referenceChars, otherChars)
                for span in spans {
                    let a = String(referenceChars[span.a])
                    let b = String(otherChars[span.b])
                    // 窓の切り口に接しているスパンか。
                    let touchesEdge = span.a.lowerBound == 0 || span.b.lowerBound == 0
                        || span.a.upperBound == referenceChars.count
                        || span.b.upperBound == otherChars.count
                    let ta = a.trimmingCharacters(in: .whitespacesAndNewlines)
                    let tb = b.trimmingCharacters(in: .whitespacesAndNewlines)
                    if ta.isEmpty && tb.isEmpty { continue }
                    if max(ta.count, tb.count) < minSpanCharacters { continue }
                    if normalize(ta) == normalize(tb) { continue }  // 句読点だけの差は無視

                    let cands = [Candidate(engine: runs[0].engine, text: ta),
                                 Candidate(engine: runs[i].engine, text: tb)]
                    let keys = Set(cands.map { Reading.key($0.text) })
                    let readingsMatch = keys.count == 1 && !(keys.first?.isEmpty ?? true)

                    out.append(Disagreement(
                        start: windowStart, end: windowEnd,
                        candidates: cands,
                        readingsMatch: readingsMatch,
                        context: contextAround(reference, span: span.a),
                        kind: classify(ta, tb,
                                       readingsMatch: readingsMatch,
                                       widenedA: widened[0], widenedB: widened[i],
                                       touchesWindowEdge: touchesEdge)))
                }
            }
        }
        return markRecurringInflections(merge(out))
    }

    // MARK: - 分類

    /// 1件のスパンを、窓の中の情報だけで分類する。
    /// 収録全体を見ないと決まらない `.inflection` は
    /// `markRecurringInflections` で後から上書きする。
    static func classify(_ a: String, _ b: String,
                         readingsMatch: Bool,
                         widenedA: String, widenedB: String,
                         touchesWindowEdge: Bool = false) -> Kind {
        // 片側が空。相手の本文が自分の隣接窓にあるなら、認識できていないのではなく
        // 置き場所が違うだけ。実データではこれが人に残る件数の54%を占めていた。
        //
        // 逆に隣接窓にも無ければ、そのエンジンは本当にその区間を落としている。
        // それは見るべき食い違いなので `.substantive` のまま残す。
        //
        // 窓の端に接しているかを条件に入れているのは、10秒で機械的に切る以上、
        // **どのエンジンも同じ文字位置では切れない**ため。境界では必ず語が割れ、
        // 片方に1文字だけ残る（「行」「ン」）。これは認識の違いではなく切り口の違い。
        // 端に接していない1文字は偶然の一致が起きうるので、2文字以上を要求する。
        if a.isEmpty || b.isEmpty {
            let present = a.isEmpty ? normalize(b) : normalize(a)
            let elsewhere = a.isEmpty ? widenedA : widenedB
            if !present.isEmpty,
               present.count >= 2 || touchesWindowEdge,
               elsewhere.contains(present) { return .alignment }
        }

        // 数値表記・全角半角
        if Notation.comparisonKey(a) == Notation.comparisonKey(b) { return .notation }

        // 送り仮名・交ぜ書き。「いただ」と「頂」。
        // 読みが一致し、かつ**片方だけが漢字を含む**ものに限る。
        // 両方が漢字なら同音異義語（機構／気候）なので、これは人が見るべきもの。
        if readingsMatch, hasKanji(a) != hasKanji(b) { return .notation }

        return .substantive
    }

    /// 収録全体で同じ組み合わせがくり返し出るものを `.inflection` に落とす。
    ///
    /// 1本の収録で「と」と「って」が6回出るのは、その6箇所で認識が割れているのではなく、
    /// 片方のエンジンが常にそう書くということ。個別に人へ出す意味がない。
    ///
    /// ひらがなと約物だけに絞ってあるのは、固有名詞の誤りを巻き込まないため。
    /// 誤認識された社名・人名はくり返し出るので、回数だけを条件にすると
    /// **一番拾いたいものを一番確実に隠す**ことになる。日本語の内容語は
    /// 漢字・カタカナ・英数字を含むので、そこで線を引く。
    static func markRecurringInflections(_ items: [Disagreement],
                                         minimumOccurrences: Int = 3) -> [Disagreement] {
        var counts: [String: Int] = [:]
        for d in items where d.kind == .substantive && isParticleLike(d) {
            counts[pairKey(d), default: 0] += 1
        }
        guard counts.values.contains(where: { $0 >= minimumOccurrences }) else { return items }

        return items.map { d in
            guard d.kind == .substantive, isParticleLike(d),
                  (counts[pairKey(d)] ?? 0) >= minimumOccurrences else { return d }
            var copy = d
            copy.kind = .inflection
            return copy
        }
    }

    private static func pairKey(_ d: Disagreement) -> String {
        d.candidates.map { "\($0.engine)\u{1}\($0.text)" }.joined(separator: "\u{2}")
    }

    /// 全候補が「ひらがな・約物・空白」だけでできているか。
    /// 内容語は漢字・カタカナ・英数字を含むので、ここに入らない。
    static func isParticleLike(_ d: Disagreement) -> Bool {
        d.candidates.allSatisfy { c in
            c.text.unicodeScalars.allSatisfy {
                (0x3040...0x309F).contains($0.value)                    // ひらがな
                    || CharacterSet.whitespacesAndNewlines.contains($0)
                    || CharacterSet.punctuationCharacters.contains($0)
                    || CharacterSet.symbols.contains($0)
            }
        }
    }

    static func hasKanji(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value)
                || (0x3400...0x4DBF).contains($0.value)
                || (0xF900...0xFAFF).contains($0.value)
        }
    }

    // MARK: -

    static func text(of run: Run, from: Double, to: Double) -> String {
        run.segments
            .filter { $0.end > from && $0.start < to && !$0.isSuppressed }
            .sorted { $0.start < $1.start }
            .map { textSlice(of: $0, from: from, to: to) }
            .joined()
    }

    /// 時間窓と重なるセグメント本文だけを取り出す。
    ///
    /// ASR のセグメントは20秒を超えることがあり、全文を各10秒窓へ入れると
    /// 同じ不一致を2〜3回数えてしまう。単語タイムスタンプを持たないエンジンも
    /// 比較対象なので、文字がセグメント内に一様に並ぶと仮定して時間比で分割する。
    /// 同じ丸めを両端に使うことで、隣接する窓を連結すると元の本文へ必ず戻る。
    static func textSlice(of segment: Segment, from: Double, to: Double) -> String {
        let text = Array(segment.text)
        guard !text.isEmpty else { return "" }
        let duration = segment.end - segment.start

        // 長さ0のセグメントは時間比で分けられない。捨てると本文が照合から静かに消えるので、
        // その時刻を含む窓へ丸ごと入れる。
        // `SpeechAnalyzerEngine` は `Segment(start:end: max(end, start))` と書いていて、
        // end == start を許す作りになっている。ここを "" で返すと、Apple エンジンを
        // 基準にしたときだけ特定のセグメントが照合対象から外れ、しかも何も表示されない。
        guard duration > 0 else {
            return (segment.start >= from && segment.start < to) ? segment.text : ""
        }

        let lowerFraction = min(1, max(0, (from - segment.start) / duration))
        let upperFraction = min(1, max(0, (to - segment.start) / duration))
        let lower = min(text.count, Int((Double(text.count) * lowerFraction).rounded(.down)))
        let upper = min(text.count, Int((Double(text.count) * upperFraction).rounded(.down)))
        guard lower < upper else { return "" }
        return String(text[lower..<upper])
    }

    /// 比較用の正規化。句読点・空白・記号を落とす。
    static func normalize(_ s: String) -> String {
        String(s.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
        })
    }

    static func contextAround(_ text: String, span: Range<Int>, radius: Int = 40) -> String {
        let chars = Array(text)
        let lo = max(0, span.lowerBound - radius)
        let hi = min(chars.count, span.upperBound + radius)
        guard lo < hi else { return "" }
        return String(chars[lo..<hi])
    }

    struct SpanPair: Equatable { var a: Range<Int>; var b: Range<Int> }

    /// 文字単位のアライメントを取り、連続する不一致をスパンにまとめる。
    static func differingSpans(_ a: [Character], _ b: [Character]) -> [SpanPair] {
        guard !a.isEmpty || !b.isEmpty else { return [] }
        // あまりに長いと DP が重いので上限を設ける（窓単位なので通常は数百文字）
        let limit = 2000
        if a.count > limit || b.count > limit {
            return a == b ? [] : [SpanPair(a: 0..<a.count, b: 0..<b.count)]
        }

        // 距離行列
        var d = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        if a.count > 0 && b.count > 0 {
            for i in 1...a.count {
                for j in 1...b.count {
                    let cost = a[i-1] == b[j-1] ? 0 : 1
                    d[i][j] = min(d[i-1][j] + 1, d[i][j-1] + 1, d[i-1][j-1] + cost)
                }
            }
        }

        // 逆向きに辿って一致/不一致の列を作る
        var ops: [(ai: Int?, bi: Int?)] = []
        var i = a.count, j = b.count
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && d[i][j] == d[i-1][j-1] + (a[i-1] == b[j-1] ? 0 : 1) {
                ops.append((i-1, j-1)); i -= 1; j -= 1
            } else if i > 0 && d[i][j] == d[i-1][j] + 1 {
                ops.append((i-1, nil)); i -= 1
            } else if j > 0 {
                ops.append((nil, j-1)); j -= 1
            } else { break }
        }
        ops.reverse()

        var spans: [SpanPair] = []
        var runA: Range<Int>? = nil
        var runB: Range<Int>? = nil
        func closeRun() {
            if runA != nil || runB != nil {
                spans.append(SpanPair(a: runA ?? 0..<0, b: runB ?? 0..<0))
            }
            runA = nil; runB = nil
        }
        for op in ops {
            let matched: Bool
            if let ai = op.ai, let bi = op.bi { matched = a[ai] == b[bi] } else { matched = false }
            if matched {
                closeRun()
            } else {
                if let ai = op.ai {
                    runA = (runA.map { $0.lowerBound..<max($0.upperBound, ai + 1) }) ?? (ai..<(ai + 1))
                }
                if let bi = op.bi {
                    runB = (runB.map { $0.lowerBound..<max($0.upperBound, bi + 1) }) ?? (bi..<(bi + 1))
                }
            }
        }
        closeRun()
        return spans
    }

    /// 同じ窓・同じ候補の重複を畳む
    static func merge(_ items: [Disagreement]) -> [Disagreement] {
        var seen = Set<String>()
        var out: [Disagreement] = []
        for d in items.sorted(by: { $0.start < $1.start }) {
            let key = "\(Int(d.start))|" + d.candidates.map { "\($0.engine):\($0.text)" }.joined(separator: "|")
            if seen.insert(key).inserted { out.append(d) }
        }
        return out
    }
}
