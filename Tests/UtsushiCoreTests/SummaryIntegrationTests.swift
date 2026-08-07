import XCTest
import FoundationModels

/// 要約を実際の Foundation Models で回し、構造上の保証が本当に成り立つかを見る。
///
/// スタブでは「引用は原文からしか作れない」ことを設計で示せるが、
/// 実モデルが行番号を無視して自由に喋り出す挙動をしないかは実物でしか確かめられない。
final class SummaryRealModelTests: XCTestCase {

    /// 実際の説明会録画の文字起こしから取った断片。
    /// 数値・カタカナ語・英単語が混ざっており、見出しゲートが働く余地がある。
    private static let lines = [
        "本日はお忙しい中、当社の会社説明会にお越しいただきありがとうございます",
        "まず簡単に会社の概要からご説明します",
        "設立は1998年で、従業員数はグループ全体で約1200名になります",
        "事業は大きく分けて三つあり、システム開発、インフラ運用、コンサルティングです",
        "選考の流れですが、まずエントリーシートをご提出いただきます",
        "その後、一次面接、二次面接、最終面接という三段階になります",
        "エントリーシートの締め切りは今月末までとなっていますのでご注意ください",
        "面接は基本的にオンラインで、Teamsを使って実施します",
        "評価の観点はコンピテンシーを重視しており、上長評価も参考にしています",
        "質問がある方は、最後にまとめてお受けしますので控えておいてください"
    ]

    private var segments: [Segment] {
        Self.lines.enumerated().map { i, text in
            var s = Segment(start: Double(i) * 8, end: Double(i) * 8 + 8, original: text)
            s.corrected = text
            return s
        }
    }

    private func requireModel() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26 未満") }
        guard case .available = SystemLanguageModel.default.availability else {
            throw XCTSkip("Foundation Models が利用できない")
        }
    }

    /// このアプリの要約が守るべき唯一絶対の約束。
    /// 引用が1件でも原文に無ければ、要約はモデルの作文になっている。
    func testEveryQuoteExistsVerbatimInTheTranscript() async throws {
        try requireModel()
        guard #available(macOS 26.0, *) else { return }

        let segs = segments
        let summary = await Summarizer(engine: FoundationModelsSummarizer()).run(on: segs)

        let known = Set(segs.map(\.text))
        let byID = Dictionary(uniqueKeysWithValues: segs.map { ($0.id, $0.text) })

        print("要約: \(summary.points.count)件 / 見出しがモデル由来 \(Int(summary.modelHeadlineRatio * 100))% / "
              + "見出し棄却 \(summary.stats.rejectedHeadlineCount) / 不正参照 \(summary.stats.invalidReferenceCount) / "
              + "失敗した塊 \(summary.stats.failedChunkCount)")
        for p in summary.points {
            print("  [\(p.kind.rawValue)] \(p.headline) (\(p.headlineSource.rawValue))")
            for q in p.quotes { print("     > \(q)") }
        }

        XCTAssertFalse(summary.points.isEmpty, "実データから要点が1件も取れていない")
        for p in summary.points {
            XCTAssertFalse(p.quotes.isEmpty, "引用の無い要点が存在する")
            for q in p.quotes {
                XCTAssertTrue(known.contains(q), "原文に存在しない引用が出た: \(q)")
            }
            XCTAssertEqual(p.segmentIDs.count, p.quotes.count)
            for (id, q) in zip(p.segmentIDs, p.quotes) {
                XCTAssertEqual(byID[id], q, "セグメントIDと引用の対応が壊れている")
            }
        }
    }

    /// 見出しは言い換えなので、原文と一字一句同じである必要はない。
    /// ただし「原文に無い数値・英数字・カタカナ語」は入っていてはならない。
    /// ゲートを通ったものだけを見て、その不変条件を確認する。
    func testAcceptedHeadlinesIntroduceNoNewFacts() async throws {
        try requireModel()
        guard #available(macOS 26.0, *) else { return }

        let summary = await Summarizer(engine: FoundationModelsSummarizer()).run(on: segments)
        let gate = SummaryGate()
        for p in summary.points where p.headlineSource == .model {
            let source = p.quotes.joined(separator: "")
            XCTAssertTrue(gate.evaluate(headline: p.headline, source: source).isAccepted,
                          "ゲートを通ったはずの見出しが再評価で落ちた: \(p.headline)")
        }
    }

    /// 塊が文脈長を超えないこと。超えると respond が失敗して要約が丸ごと落ちる。
    func testLongTranscriptIsSplitAndAllChunksSucceed() async throws {
        try requireModel()
        guard #available(macOS 26.0, *) else { return }

        // 実運用に近い長さを作る。素材は1行あたり平均約31文字なので、
        // 300行で約9,400文字＝既定の3,000文字予算では4塊になる。
        // （90行で書いていたが約2,800文字にしかならず1塊のままだった）
        var segs: [Segment] = []
        for i in 0..<300 {
            let text = Self.lines[i % Self.lines.count]
            var s = Segment(start: Double(i) * 8, end: Double(i) * 8 + 8, original: text)
            s.corrected = text
            segs.append(s)
        }
        let total = segs.reduce(0) { $0 + $1.text.count }
        let summary = await Summarizer(engine: FoundationModelsSummarizer()).run(on: segs)
        print("長文要約: \(total)文字 / 塊 \(summary.stats.chunkCount) / 失敗 \(summary.stats.failedChunkCount) / 要点 \(summary.points.count)")
        XCTAssertGreaterThan(total, 8_000, "テスト素材が短すぎて分割の検証にならない")
        XCTAssertGreaterThan(summary.stats.chunkCount, 1, "分割されていない")
        XCTAssertEqual(summary.stats.failedChunkCount, 0,
                       "文脈長を超えて失敗した塊がある。maxCharactersPerChunk を下げる必要がある")
    }
}
