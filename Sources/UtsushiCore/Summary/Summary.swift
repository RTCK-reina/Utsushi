import Foundation

/// 要約の結果。
///
/// このアプリの中核は「モデルに作文させない」ことなので、要約も同じ原則で作る。
/// 本文（`quotes`）は必ず文字起こしからの**引用そのまま**で、モデルは
/// 「どの区間が重要か」を選ぶだけ。見出しだけはモデルが書くが、
/// `SummaryGate` を通り、原文に無い数値・英数字を含むものは捨てる。
public struct Summary: Sendable, Codable, Equatable {

    public struct Point: Sendable, Codable, Equatable, Identifiable {
        public var id: UUID
        /// モデルが書いた短い見出し。ゲートを通らなかった場合は引用の先頭を切り出したものが入る。
        public var headline: String
        /// 見出しがモデル由来か、機械的に切り出したものか
        public var headlineSource: HeadlineSource
        public var kind: PointKind
        /// 引用元セグメントのID（本文は必ずこの区間から取る）
        public var segmentIDs: [UUID]
        /// 引用そのまま。書き換えは一切していない。
        public var quotes: [String]
        public var start: Double
        public var end: Double

        public init(id: UUID = UUID(), headline: String, headlineSource: HeadlineSource,
                    kind: PointKind, segmentIDs: [UUID], quotes: [String],
                    start: Double, end: Double) {
            self.id = id
            self.headline = headline
            self.headlineSource = headlineSource
            self.kind = kind
            self.segmentIDs = segmentIDs
            self.quotes = quotes
            self.start = start
            self.end = end
        }
    }

    public enum HeadlineSource: String, Sendable, Codable {
        /// モデルが書き、ゲートを通った
        case model
        /// モデルの見出しがゲートで落ちたので、引用の先頭を機械的に切り出した
        case extracted
    }

    public enum PointKind: String, Sendable, Codable, CaseIterable {
        case topic       // 話題・説明
        case decision    // 決定事項
        case action      // やること・宿題
        case number      // 数値・日付・条件
        case question    // 質疑

        public var displayName: String {
            switch self {
            case .topic: return "話題"
            case .decision: return "決定"
            case .action: return "やること"
            case .number: return "数値・日程"
            case .question: return "質疑"
            }
        }
    }

    public var points: [Point] = []
    public var stats: Stats = .init()

    public struct Stats: Sendable, Codable, Equatable {
        /// 要約にかけた塊の数
        public var chunkCount: Int = 0
        /// モデルが選んだ区間の総数
        public var selectedCount: Int = 0
        /// 実在しない区間を指してきたので捨てた数
        public var invalidReferenceCount: Int = 0
        /// 見出しがゲートで落ちた数
        public var rejectedHeadlineCount: Int = 0
        /// 棄却理由ごとの内訳。どの条件が厳しすぎるかを判断するために残す。
        public var headlineRejections: [String: Int] = [:]
        /// 要約に失敗した塊の数
        public var failedChunkCount: Int = 0
        public init() {}
    }

    public var isEmpty: Bool { points.isEmpty }
    public static let empty = Summary()
    public init() {}

    /// 見出しの何割がモデル由来か。低いほど「モデルが妥当な見出しを書けていない」。
    public var modelHeadlineRatio: Double {
        guard !points.isEmpty else { return 0 }
        return Double(points.filter { $0.headlineSource == .model }.count) / Double(points.count)
    }
}
