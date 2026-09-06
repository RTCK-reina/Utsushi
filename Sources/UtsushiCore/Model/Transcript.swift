import Foundation

/// 1発話区間。ASRの生出力と、監査・校正の結果を同一の型で持ち回る。
public struct Segment: Sendable, Codable, Identifiable, Equatable {
    public var id: UUID
    /// 動画先頭からの秒
    public var start: Double
    public var end: Double
    /// ASRが出した原文。校正しても**絶対に破壊しない**。
    public var original: String
    /// 校正後の本文。未校正なら original と同一。
    public var corrected: String
    /// ASRの平均対数尤度（whisper系のみ。無い場合は nil）
    public var avgLogprob: Double?
    /// 無音確率（whisper系のみ）
    public var noSpeechProb: Double?
    /// 区間の音圧 dBFS。監査層が埋める。
    public var rmsDBFS: Double?
    /// 監査で付いた印
    public var flags: Set<SegmentFlag>
    /// 校正の適用記録（nilなら未校正）
    public var correction: AppliedCorrection?

    public var duration: Double { max(0, end - start) }
    /// 表示に使うべき本文
    public var text: String { corrected }
    public var isSuppressed: Bool { flags.contains(.silenceSuppressed) || flags.contains(.repetitionLoop) }

    public init(id: UUID = UUID(), start: Double, end: Double, original: String,
                avgLogprob: Double? = nil, noSpeechProb: Double? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.original = original
        self.corrected = original
        self.avgLogprob = avgLogprob
        self.noSpeechProb = noSpeechProb
        self.rmsDBFS = nil
        self.flags = []
        self.correction = nil
    }
}

public enum SegmentFlag: String, Sendable, Codable, Hashable {
    /// 区間が無音だったため本文を破棄した（幻聴の決定論的除去）
    case silenceSuppressed
    /// 同一文の反復ループとして破棄した
    case repetitionLoop
    /// 尤度が閾値を下回る
    case lowConfidence
    /// 尺に対して文字数が異常に少ない＝取りこぼしの疑い
    case densityAnomaly
    /// 取りこぼし疑いを再認識して差し替えた
    case repaired
}

public struct AppliedCorrection: Sendable, Codable, Equatable {
    public var before: String
    public var after: String
    public var rule: CorrectionRule
    public var accepted: Bool
    public init(before: String, after: String, rule: CorrectionRule, accepted: Bool) {
        self.before = before; self.after = after; self.rule = rule; self.accepted = accepted
    }
}

public enum CorrectionRule: String, Sendable, Codable {
    case dictionary      // ユーザー辞書による決定論的置換
    case fillerRemoval   // フィラー除去（決定論的）
    case notation        // 表記ゆれ正規化（決定論的）
    case languageModel   // LLM提案 + ゲート通過
}

/// どちらの押しかたで作ったか。
///
/// 設定でエンジンを切り替えるのをやめ、**開始ボタンそのものを2つにした**。
/// 速さと確からしさは実行のたびに選びたいもので、設定に埋めると
/// 「今どちらで走っているか」が画面から消える。
public enum RunMode: String, Sendable, Codable, CaseIterable {
    /// OS内蔵エンジンで一気に通す。57分の実データで30秒。
    /// 照合も言語モデルも使わない。固有名詞は崩れる前提で読む。
    case fast
    /// whisper に設定どおりの照合を掛ける。実データで5〜10分。
    case quality

    public var displayName: String {
        switch self {
        case .fast:    return "高速"
        case .quality: return "標準"
        }
    }

    /// 書き出しに載せる注記。**出力だけを読む人が前提を知らないと危険**なので、
    /// 速い方は弱点をそのまま書く。
    public var note: String {
        switch self {
        case .fast:
            return "OS内蔵エンジンで下書きした。照合も校正もしていない。"
                + "固有名詞と数字は崩れやすく、辞書による認識の誘導も効いていない"
        case .quality:
            return "whisper で認識し、設定した照合を掛けた"
        }
    }
}

public struct TranscriptMeta: Sendable, Codable, Equatable {
    public var sourceURL: URL?
    public var sourceDuration: Double
    public var engine: String
    public var modelName: String
    public var language: String
    public var createdAt: Date
    /// どちらの押しかたで作ったか。古い書き出しには無いので Optional。
    public var mode: RunMode?
    public init(sourceURL: URL?, sourceDuration: Double, engine: String,
                modelName: String, language: String, createdAt: Date = Date(),
                mode: RunMode? = nil) {
        self.sourceURL = sourceURL; self.sourceDuration = sourceDuration
        self.engine = engine; self.modelName = modelName
        self.language = language; self.createdAt = createdAt
        self.mode = mode
    }
}

/// 複数エンジンの照合結果。エンジンを1つしか使わなかった場合は空。
public struct CrossCheckReport: Sendable, Codable, Equatable {
    public var engines: [String] = []
    public var disagreements: [TranscriptAlignment.Disagreement] = []
    public var adjudications: [Adjudication] = []
    public var outcome: AdjudicationOutcome = .init()
    public static let empty = CrossCheckReport()
    public init() {}
}

public struct Transcript: Sendable, Codable, Equatable {
    public var meta: TranscriptMeta
    public var segments: [Segment]
    public var audit: AuditReport
    public var crossCheck: CrossCheckReport
    /// 要約。作らなかった場合は空。
    public var summary: Summary
    /// 文脈に合わない語の指摘。**本文には反映していない。**
    /// 照合が拾えない「全エンジンが同じ誤り方をした箇所」を埋めるためのもの。
    public var plausibility: [PlausibilityFlag]

    public init(meta: TranscriptMeta, segments: [Segment], audit: AuditReport = .empty,
                crossCheck: CrossCheckReport = .empty, summary: Summary = .empty,
                plausibility: [PlausibilityFlag] = []) {
        self.meta = meta; self.segments = segments; self.audit = audit
        self.crossCheck = crossCheck; self.summary = summary
        self.plausibility = plausibility
    }

    /// 古い JSON（`plausibility` が無いもの）を読めるようにしておく。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meta = try c.decode(TranscriptMeta.self, forKey: .meta)
        segments = try c.decode([Segment].self, forKey: .segments)
        audit = try c.decode(AuditReport.self, forKey: .audit)
        crossCheck = try c.decode(CrossCheckReport.self, forKey: .crossCheck)
        summary = try c.decode(Summary.self, forKey: .summary)
        plausibility = try c.decodeIfPresent([PlausibilityFlag].self, forKey: .plausibility) ?? []
    }

    /// 出力に載せるべきセグメント（破棄されたものを除く）
    public var visibleSegments: [Segment] {
        segments.filter { !$0.isSuppressed && !$0.text.isEmpty }
    }
    /// 監査で破棄した区間。人が誤爆を確認できるよう原文のまま持つ。
    public var suppressedSegments: [Segment] {
        segments.filter { $0.isSuppressed && !$0.original.isEmpty }
    }

    /// 発話が無い区間（休憩など）。**音声から出した記録**を返す。
    ///
    /// 当初はセグメントの隙間から推測していたが、無音をまたぐセグメントが
    /// 1つあるだけで隙間が消え、8分の休憩がまるごと見えなくなった。
    /// セグメントの並びは無音の一次情報ではない。
    public func gaps(minimumSeconds: Double = 30) -> [ClosedRange<Double>] {
        audit.stats.silentRanges
            .filter { $0.duration >= minimumSeconds }
            .map { $0.start...$0.end }
    }

    public var totalCharacters: Int { visibleSegments.reduce(0) { $0 + $1.text.count } }
    /// 発話としてカバーされた秒数
    public var coveredSeconds: Double { visibleSegments.reduce(0) { $0 + $1.duration } }
}
