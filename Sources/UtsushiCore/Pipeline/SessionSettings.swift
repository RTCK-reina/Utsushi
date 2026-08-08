import Foundation

/// 画面で選べる設定の全体。
///
/// UI 側に散らしていたときに「設定は用意したがパイプラインに渡し忘れる」という
/// 不具合を実際に出した（照合エンジンと判定器がまるごと配線されていなかった）。
/// 設定から Configuration への変換をここ1か所に閉じることで、
/// 渡し忘れが「この構造体にフィールドが無い」場合にしか起きないようにする。
public struct SessionSettings: Sendable, Codable, Equatable {

    public enum EngineChoice: String, Sendable, Codable, CaseIterable, Identifiable {
        case whisper, apple
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .whisper: return "whisper.cpp（推奨・検証機能フル）"
            case .apple:   return "Apple SpeechTranscriber（OS内蔵）"
            }
        }
        public var note: String {
            switch self {
            case .whisper: return "モデルを初回にダウンロードする。尤度と無音確率が取れるので検証層が全機能で動く。"
            case .apple:   return "モデル管理不要。ただし尤度が取れないため低信頼検出が無効になる。"
            }
        }
    }

    public var engineChoice: EngineChoice = .whisper
    public var whisperModelID: String = ModelCatalog.whisperModels[0].id
    public var language: String = "ja"
    public var enableCorrection: Bool = true
    public var requireAgreement: Bool = true
    public var autoRepair: Bool = true
    public var silenceDBFS: Double = -45
    /// 照合に使う別エンジン（モデルID）。空なら照合しない。
    public var crossCheckModelIDs: Set<String> = []
    public var adjudicateDisagreements: Bool = true
    /// 読みが違う食い違いもLLMに判定させるか。
    ///
    /// 既定は false。実測（whisper × parakeet, 11分）では判定145件のうち138件が
    /// 読み不一致で、LLMが本来得意な同音異義語は7件しかなかった。
    /// 読みが違う＝音響に情報が残っている箇所なので、テキストだけの判断は確度が落ちる。
    /// 切っておけば、その分は判定せず人に残る。
    public var judgeDifferentReadings: Bool = false
    /// 文脈に合わない語をモデルに指摘させるか。
    /// 照合が拾えない「全エンジンが同じ誤り方をした箇所」を埋める。
    /// 本文は書き換えず、候補を横に並べるだけなので既定で有効。
    public var enablePlausibilityCheck: Bool = true
    /// 要約を作る
    public var enableSummary: Bool = true
    /// 1塊の最大文字数（Foundation Models の文脈長に収める）
    public var summaryChunkCharacters: Int = 3_000
    /// 1塊あたりの要点の上限
    public var summaryPointsPerChunk: Int = 4
    /// 見出しの検証を厳しくする（原文に無い漢語を棄却する）。
    ///
    /// 既定は true（安全側）。ただし実測では、11分の実素材で出た見出し3件が
    /// 3件とも漢語チェックで棄却され、モデル由来の見出しは0%になった。
    /// 言い換えは原文に無い漢語を使うのが普通なので当然ではある。
    /// 棄却されても要点と引用は残る（見出しが原文抜粋に替わるだけ）ので
    /// 誤りにはならないが、見出しの意味は薄くなる。
    /// 標本が3件しかなく既定を動かす根拠には足りないため、切り替えを設定に出してある。
    public var summaryStrictHeadlines: Bool = true

    public init() {}

    /// 保存後にカタログが変わっていることがあるので、実在するものだけ残す。
    /// 消えたモデルIDをそのまま持っていると、照合が黙って走らない状態になる。
    public mutating func dropUnknownModels() {
        if !ModelCatalog.whisperModels.contains(where: { $0.id == whisperModelID }) {
            whisperModelID = ModelCatalog.whisperModels[0].id
        }
        crossCheckModelIDs.formIntersection(Set(ModelCatalog.sherpaModels.map(\.id)))
    }

    public var crossCheckModels: [ModelCatalog.Model] {
        ModelCatalog.sherpaModels.filter { crossCheckModelIDs.contains($0.id) }
    }

    public var whisperModel: ModelCatalog.Model {
        ModelCatalog.whisperModels.first { $0.id == whisperModelID } ?? ModelCatalog.whisperModels[0]
    }

    /// - Parameters:
    ///   - hasCorrector: 校正エンジンが実際に用意できたか
    ///   - hasJudge: 判定器が実際に用意できたか
    ///   - hasSummarizer: 要約エンジンが実際に用意できたか
    ///
    /// 用意できていない機能を「有効」として渡すと、動いていないのに動いた扱いになる。
    /// ここで落としておく。
    public func makeConfiguration(dictionary: UserDictionary,
                                  hasCorrector: Bool,
                                  hasJudge: Bool,
                                  hasSummarizer: Bool = false,
                                  hasPlausibilityChecker: Bool = false)
-> TranscriptionPipeline.Configuration {
        var c = TranscriptionPipeline.Configuration()
        c.language = language
        c.dictionary = dictionary
        c.enableCorrection = enableCorrection && hasCorrector
        c.requireAgreement = requireAgreement
        c.autoRepair = autoRepair
        c.auditPolicy.silenceDBFS = Float(silenceDBFS)
        c.crossCheckEngines = crossCheckModels
        c.adjudicateDisagreements = adjudicateDisagreements && hasJudge
        c.judgeDifferentReadings = judgeDifferentReadings
        c.enableSummary = enableSummary && hasSummarizer
        c.enablePlausibilityCheck = enablePlausibilityCheck && hasPlausibilityChecker
        c.summaryConfig.maxCharactersPerChunk = summaryChunkCharacters
        c.summaryConfig.maxPointsPerChunk = summaryPointsPerChunk
        c.summaryConfig.gatePolicy.rejectNewKanjiTerms = summaryStrictHeadlines
        return c
    }
}
