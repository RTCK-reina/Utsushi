import Foundation

/// 認識結果が「日本語として成立しているか」を測るための共通部品。
///
/// **CJK統合漢字の比率で日本語かどうかを判定してはいけない。**
/// 中国語も同じ範囲の文字を使うので、日本語と中国語を区別できない。
/// 実際、広東語向けモデルの出力（「目标」「上长」「企业」）が
/// 漢字比率のチェックを素通りし、壊れていることに気づけなかった。
///
/// 見るべきはかなの有無。日本語なら助詞・活用語尾がかなで書かれるので、
/// 文字（かな＋漢字）に対するかなの比率が必ず一定以上になる。
///
/// 実測値（同じ11分の素材）:
///
/// | | かな / (かな+漢字) |
/// |---|---|
/// | 広東語モデルの壊れた出力 | 0.00 |
/// | Qwen3-ASR 0.6B | 0.61 |
/// | whisper / SenseVoice / zipformer / parakeet | 0.6〜0.7 |
///
/// 0 と 0.6 の間は十分に開いているので、閾値は 0.35 に置く。
/// 句読点や算用数字を分母に入れると、表記の癖（「3月」と書くか「三月」と書くか）で
/// 比率が動いてしまうので、分母は文字だけにする。
enum JapaneseTextCheck {

    static func kanaCount(_ s: String) -> Int {
        s.unicodeScalars.filter {
            (0x3040...0x309F).contains($0.value)     // ひらがな
                || (0x30A0...0x30FF).contains($0.value)  // カタカナ
        }.count
    }

    static func kanjiCount(_ s: String) -> Int {
        s.unicodeScalars.filter {
            (0x4E00...0x9FFF).contains($0.value)
                || (0x3400...0x4DBF).contains($0.value)
                || (0xF900...0xFAFF).contains($0.value)
        }.count
    }

    /// かな＋漢字に対するかなの比率。句読点・数字・空白は分母に入れない。
    static func kanaRatio(_ s: String) -> Double {
        let kana = kanaCount(s)
        let script = kana + kanjiCount(s)
        return script > 0 ? Double(kana) / Double(script) : 0
    }

    /// この値を下回ったら日本語として認識できていない。
    static let minimumKanaRatio = 0.35
}
