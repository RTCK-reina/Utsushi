import XCTest

/// 書き出しを**LLMに渡す**ことを前提にした検査。
///
/// 人が読むなら、後ろの検証記録と本文を目で突き合わせられる。
/// LLM は本文を確定した事実として読み、時刻で突き合わせてくれる保証がない。
/// だから「どこが怪しいか」は本文と同じ場所に無いといけない。
///
/// このテストが見ているのは体裁ではなく、**読み手が誤解しない条件**:
/// - 怪しい語が、その語のすぐ下に出ている
/// - 無音が「話していない」と分かる（話が省略されたと読まれない）
/// - 検証記録が本文と区別できる
/// - 打ち切りを黙ってやらない
final class ExportForLLMTests: XCTestCase {

    /// 本文に添えられた注記の行頭。
    /// 冒頭の「読み方」にも同じ語が凡例として出るので、
    /// 単語で探すと必ず見つかってしまい、テストが常に通る（実際に通った）。
    static let bodyNoteMarker = "> ↳ 別エンジンの候補:"

    private func seg(_ start: Double, _ end: Double, _ text: String) -> Segment {
        Segment(start: start, end: end, original: text)
    }

    /// `render` は Data を返すので、読める形にしてから見る。
    private func markdown(_ t: Transcript) throws -> String {
        let data = try Exporter().render(t, as: .markdown)
        return try XCTUnwrap(String(data: data, encoding: .utf8), "UTF-8 として読めない")
    }

    private func transcript(disagreements: [TranscriptAlignment.Disagreement] = [],
                            segments: [Segment]? = nil,
                            duration: Double = 60) -> Transcript {
        var t = Transcript(
            meta: TranscriptMeta(sourceURL: URL(fileURLWithPath: "/tmp/test.m4a"),
                                 sourceDuration: duration,
                                 engine: "whisper.cpp", modelName: "large-v3-turbo",
                                 language: "ja"),
            segments: segments ?? [
                seg(0, 10, "大体気象の目標を3月から4月ぐらいに立てまして、"),
                seg(10, 20, "自己評価と上長評価をそれぞれ人事の方に提出いただきます。"),
            ])
        if !disagreements.isEmpty {
            t.crossCheck.engines = ["whisper.cpp", "sherpa-zipformer-ja-reazonspeech"]
            t.crossCheck.disagreements = disagreements
        }
        return t
    }

    private func disagreement(_ a: String, _ b: String,
                              at start: Double = 0,
                              kind: TranscriptAlignment.Kind = .substantive)
    -> TranscriptAlignment.Disagreement {
        TranscriptAlignment.Disagreement(
            start: start, end: start + 10,
            candidates: [.init(engine: "whisper.cpp", text: a),
                         .init(engine: "sherpa-zipformer-ja-reazonspeech", text: b)],
            readingsMatch: false, context: "", kind: kind)
    }

    // MARK: - 怪しい箇所が本文と同じ場所にあること

    /// エンジンが割れた語は、その語を含む行のすぐ下に出る。
    /// 文書の後ろの節にしか無いと、突き合わせが起きずに確定した事実として読まれる。
    func testUncertainWordAppearsRightBelowTheLineItIsIn() throws {
        let t = transcript(disagreements: [disagreement("気象", "期初", at: 2)])
        let md = try markdown(t)
        let lines = md.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard let bodyIndex = lines.firstIndex(where: { $0.contains("大体気象の目標") }) else {
            return XCTFail("本文が書き出されていない")
        }
        let following = lines[bodyIndex...].prefix(3).joined(separator: "\n")
        XCTAssertTrue(following.contains("期初"),
                      "割れた語が本文のすぐ下に出ていない。後ろの節だけでは読み手が突き合わせない:\n"
                      + following)
    }

    /// 整列のずれ・語尾のゆれ・表記差は本文に出さない。
    /// 読み手の判断を変えないものを並べると、変えるものが埋もれる。
    func testFoldedKindsDoNotClutterTheBody() throws {
        for kind in [TranscriptAlignment.Kind.alignment, .inflection, .notation] {
            let t = transcript(disagreements: [disagreement("三月", "3月", at: 2, kind: kind)])
            let md = try markdown(t)
            XCTAssertFalse(md.contains(Self.bodyNoteMarker),
                           "\(kind.rawValue) を本文に出している")
        }
    }

    /// 片側が空の食い違いは本文に出さない。代わりの語を示せないので、
    /// 読み手にできることが無い。取りこぼしの疑いは検証記録の担当。
    func testOneSidedDropoutIsNotShownInBody() throws {
        let t = transcript(disagreements: [disagreement("評価を行っていきます", "", at: 2)])
        let md = try markdown(t)
        XCTAssertFalse(md.contains(Self.bodyNoteMarker),
                       "代わりの語が無いものを本文に出している")
    }

    /// **その語を含まない行に注記を付けない。**
    /// 食い違いの時刻は10秒の窓なので、重なりだけで拾うと隣の行にも同じ注記が出る。
    /// 実際に出ていた——「コンピ」の注記が「コンピ」を含まない行に付いていた。
    func testNoteIsAttachedOnlyToTheLineContainingTheWord() throws {
        let t = transcript(disagreements: [disagreement("陣", "人", at: 2)],
                           segments: [seg(0, 10, "各部署の部長陣が集まって、"),
                                      seg(4, 14, "社員一人一人を評価していきます。")])
        let md = try markdown(t)
        let lines = md.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let notes = lines.enumerated().filter { $0.element.contains(Self.bodyNoteMarker) }
        XCTAssertEqual(notes.count, 1,
                       "同じ注記が複数の行に付いている:\n" + notes.map(\.element).joined(separator: "\n"))

        // 付いた先が「陣」を含む行の直下であること
        let index = try XCTUnwrap(notes.first?.offset)
        XCTAssertTrue(lines[index - 1].contains("部長陣"),
                      "「陣」を含まない行に注記が付いている: " + lines[index - 1])
    }

    /// 長さが釣り合わない組は出さない。
    /// 「、自己評価と上長評価をそれぞれ人事の方」→「まずで実際」のような組を候補として
    /// 見せると、節まるごとが別物かのように読める。実際に出ていた。
    func testWildlyUnbalancedPairIsNotShown() throws {
        let t = transcript(
            disagreements: [disagreement("自己評価と上長評価をそれぞれ人事の方", "まずで実際", at: 2)],
            segments: [seg(0, 10, "自己評価と上長評価をそれぞれ人事の方に提出いただきます。")])
        let md = try markdown(t)
        XCTAssertFalse(md.contains(Self.bodyNoteMarker),
                       "整列のずれの残りを語の候補として見せている")
    }

    /// ひらがなだけの差も本文に出さない。語尾のゆれの取りこぼし。
    func testHiraganaOnlyDifferenceIsNotShownInBody() throws {
        let t = transcript(disagreements: [disagreement("ぐ", "く", at: 2)])
        let md = try markdown(t)
        XCTAssertFalse(md.contains(Self.bodyNoteMarker), "ひらがなだけの差を本文に出している")
    }

    /// 黙って打ち切らない。「これで全部」と読まれると、残りが無いことになる。
    func testTruncationIsStated() throws {
        // 注記は「その語が行にあること」を条件にするので、本文にも並べておく。
        let words = (0..<12).map { "語\($0)甲" }
        let many = words.enumerated().map { i, w in disagreement(w, "語\(i)乙", at: 1) }
        let t = transcript(disagreements: many,
                           segments: [seg(0, 10, words.joined(separator: "、") + "。")])
        let md = try markdown(t)
        XCTAssertTrue(md.contains(Self.bodyNoteMarker), "注記が出ていない")
        XCTAssertTrue(md.contains("ほか"), "打ち切ったことが書かれていない")
    }

    // MARK: - 読み手が前提を取り違えないこと

    /// 冒頭に「読み方」がある。LLM は文書の性質を推測するので、
    /// 何が確定で何が推測かを最初に書いておく必要がある。
    func testDocumentStatesHowToReadItUpFront() throws {
        let md = try markdown(transcript())
        let head = String(md.prefix(2200))
        for phrase in ["読み方", "誤りが残っている前提", "話者の区別をしていない", "同音異義語"] {
            XCTAssertTrue(head.contains(phrase),
                          "冒頭に「\(phrase)」の断りが無い。読み手が前提を取り違える")
        }
    }

    /// 検証記録が本文と区別できる。区別できないと、監査の記述が発言として引用される。
    func testAuditSectionIsMarkedAsNotSpeech() throws {
        let md = try markdown(transcript())
        XCTAssertTrue(md.contains("話された内容ではない"),
                      "検証記録が本文と区別できない。監査の記述が発言として読まれる")
    }

    /// 無音は「話していない」と分かる形で出る。
    /// 何も書かないと、休憩をはさんだ発話が地続きに見え、
    /// 「その間の話が省略された」と読まれる。
    func testSilenceIsExplicitSoItIsNotReadAsOmission() throws {
        var t = transcript(segments: [seg(0, 10, "では一旦休憩を挟みます。"),
                                      seg(500, 510, "はい、再開します。")],
                           duration: 520)
        t.audit.stats.silentRanges = [.init(start: 10, end: 500)]
        let md = try markdown(t)
        XCTAssertTrue(md.contains("発話なし"), "無音が本文に出ていない")
        XCTAssertTrue(md.contains("話が省略されているのではない"),
                      "無音の意味が読み手に伝わらない")
    }

    /// 全エンジンが同じ誤り方をした語も本文の直下に出る。
    /// 照合では拾えないので、ここが無いと LLM は「気象の目標」を事実として読む。
    func testContextFlagAppearsBelowTheLine() throws {
        var t = transcript()
        t.plausibility = [PlausibilityFlag(start: 0, surface: "気象", alternative: "期初")]
        let md = try markdown(t)
        let lines = md.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let i = lines.firstIndex(where: { $0.contains("大体気象の目標") }) else {
            return XCTFail("本文が書き出されていない")
        }
        XCTAssertTrue(lines[(i + 1)...].prefix(2).joined().contains("期初"),
                      "文脈の指摘が本文のすぐ下に出ていない")
        XCTAssertTrue(md.contains("本文は書き換えていない"),
                      "本文が直っていると読まれる")
    }

    /// 本文は書き換えない。この不変条件は LLM 向けでも変わらない
    /// ——「読みやすく直した文」を渡すと、直した箇所が事実として固定される。
    func testBodyTextIsStillVerbatim() throws {
        let original = "大体気象の目標を3月から4月ぐらいに立てまして、"
        let t = transcript(disagreements: [disagreement("気象", "期初", at: 2)])
        let md = try markdown(t)
        XCTAssertTrue(md.contains(original),
                      "本文が書き換えられている。候補を添えるだけで、本文には触らない")
    }
}
