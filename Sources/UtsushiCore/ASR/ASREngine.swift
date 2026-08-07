import Foundation

public struct ASRRequest: Sendable {
    public var samples: [Float]
    public var language: String
    /// 部分再認識用。nil なら全体。
    public var timeRange: ClosedRange<Double>?
    /// VADを使うか。取りこぼし検証のために意図的に切ることがある。
    public var useVAD: Bool
    /// 認識を語彙側から誘導するためのヒント（whisper系の initial_prompt）。
    /// 固有名詞・専門語の誤認識は「モデルがその語を知らない」ことが原因なので、
    /// エンジンを増やすより先にここで効かせる。
    public var vocabularyHint: String?

    public init(samples: [Float], language: String = "ja",
                timeRange: ClosedRange<Double>? = nil, useVAD: Bool = true,
                vocabularyHint: String? = nil) {
        self.samples = samples; self.language = language
        self.timeRange = timeRange; self.useVAD = useVAD
        self.vocabularyHint = vocabularyHint
    }
}

public protocol ASREngine: Sendable {
    var identifier: String { get }
    var displayName: String { get }
    var supportsVAD: Bool { get }
    var exposesConfidence: Bool { get }
    /// 語彙ヒント（initial_prompt 相当）を受け付けるか
    var supportsVocabularyHint: Bool { get }
    func prepare(progress: @escaping @Sendable (String, Double) -> Void) async throws
    func transcribe(_ request: ASRRequest,
                    progress: @escaping @Sendable (Double) -> Void,
                    isCancelled: @escaping @Sendable () -> Bool) async throws -> [Segment]
}

public enum ASRError: LocalizedError {
    case modelUnavailable(String)
    case engineFailed(String)
    case cancelled
    case localeUnsupported(String)
    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let m): return "モデルを用意できない: \(m)"
        case .engineFailed(let m): return "認識に失敗: \(m)"
        case .cancelled: return "キャンセルされた"
        case .localeUnsupported(let l): return "この言語には対応していない: \(l)"
        }
    }
}
