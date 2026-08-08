import FoundationModels

/// 指摘の受け皿。**本文を返すフィールドが無い。**
/// 返せるのは行番号と、その行にある語と、ありうる語の3つだけ。
@available(macOS 26.0, *)
@Generable
struct PlausibilityList {
    @Guide(description: "文脈に合わない語。無ければ空。多くても6件。", .count(0...6))
    var items: [PlausibilityItem]
}

@available(macOS 26.0, *)
@Generable
struct PlausibilityItem {
    @Guide(description: "その語がある行の番号。本文に付いている番号をそのまま使う。")
    var line: Int

    @Guide(description: "本文にそのまま書かれている、意味の通らない語。1〜8文字。本文から一字一句そのまま写す。")
    var surface: String

    @Guide(description: "音が近く、文脈に合う語。1〜8文字。思いつかない場合はその語を挙げない。")
    var alternative: String
}

/// Apple Foundation Models に「日本語として意味が通らない語」を指摘させる。
///
/// 照合が拾えるのはエンジン間の不一致だけで、全エンジンが同じ誤り方をした箇所は
/// 素通りする。そこに残っている手掛かりは文脈しかない。
///
/// **モデルは本文を書き換えない。** 指摘した語が本文に無ければ `PlausibilityGate` が捨て、
/// 通っても本文はそのままで候補が横に並ぶだけ。
@available(macOS 26.0, *)
public final class FoundationModelsPlausibility: PlausibilityChecker, @unchecked Sendable {
    public let displayName = "Apple Foundation Models (on-device)"

    private let instructions = """
    あなたは日本語の音声認識結果を校閲する。**同音・類音の取り違えを探すのが仕事。**

    音声認識は音を文字にするだけなので、音は合っていても語の選択を外す。
    前後の文脈と照らして意味が通らない語は、ほぼ確実にこの取り違えである。

    手順: 1行ずつ「この語はこの話の流れで意味が通るか」と問う。通らなければ挙げる。

    実例:

    入力
    2. 大体気象の目標を3月から4月ぐらいに立てまして、中期の振り返りを行いつつ、
    4. 当社は結構一気通関で横のつながりも実際にあったりはするので、

    出力
    line 2, surface「気象」, alternative「期初」
      → 目標を立てる話に天気の語は無関係。「きしょ（期初）」の取り違え
    line 4, surface「一気通関」, alternative「一気通貫」
      → 社内のつながりの話に通関業務は無関係。同音の取り違え

    挙げるもの:
    - 話の流れと無関係な語（業務の話に出てくる天気・通関・気候など）
    - 音は近いが意味が通らない熟語

    挙げないもの:
    - 言い淀み・言い直し・助詞の抜け。話し言葉として正常
    - 語尾や助詞のゆれ（「と」「って」）
    - 表記の違い（「三月」「3月」）
    - 意味が通っている語。**通っているなら挙げない**

    厳守:
    - surface は**本文から一字一句そのまま写す**。本文に無い語を書いてはならない
    - surface も alternative も1〜8文字の語にする。文を書いてはならない
    - alternative が思いつかない語は挙げない
    """

    private let options: GenerationOptions

    public init(temperature: Double = 0.0) {
        self.options = GenerationOptions(samplingMode: .greedy,
                                         temperature: temperature,
                                         maximumResponseTokens: 500)
    }

    public func isAvailable() async -> CorrectionAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(let reason): return .unavailable(Self.describe(reason))
        @unknown default: return .unavailable("未知の理由でモデルが利用できない")
        }
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: return "このMacはApple Intelligenceに対応していない"
        case .appleIntelligenceNotEnabled: return "システム設定でApple Intelligenceが有効になっていない"
        case .modelNotReady: return "モデルのダウンロード/準備が完了していない"
        @unknown default: return "モデルが利用できない"
        }
    }

    public func check(numberedText: String, lineCount: Int) async throws -> [PlausibilityDraft] {
        guard lineCount > 0 else { return [] }
        let prompt = """
        次は音声認識の結果である。音が近い別の語に取り違えられている箇所を挙げよ。
        無ければ空で返してよい。

        \(numberedText)
        """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt,
                                                 generating: PlausibilityList.self,
                                                 options: options)
        return response.content.items.map {
            PlausibilityDraft(lineNumber: $0.line, surface: $0.surface, alternative: $0.alternative)
        }
    }
}
