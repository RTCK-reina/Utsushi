import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    /// dBFS は音の分野の外では通じない。数値は残しつつ、意味の分かる語を添える。
    private var silenceLabel: String {
        switch model.settings.silenceDBFS {
        case ..<(-55): return "かなり静かでも拾う"
        case ..<(-40): return "標準"
        case ..<(-32): return "やや厳しい"
        default:       return "はっきりした声だけ"
        }
    }

    /// 選択済みでまだ手元に無いモデルの合計。押す前に総量が見えるようにする。
    private var pendingCrossCheckBytes: Int64 {
        ModelCatalog.crossCheckCandidates
            .filter { model.settings.crossCheckModelIDs.contains($0.id) && !ModelCatalog.isInstalled($0) }
            .reduce(0) { $0 + $1.approximateBytes }
    }

    var body: some View {
        TabView {
            engineTab.tabItem { Label("エンジン", systemImage: "waveform") }
            crossCheckTab.tabItem { Label("照合", systemImage: "arrow.triangle.branch") }
            correctionTab.tabItem { Label("校正", systemImage: "text.badge.checkmark") }
            DictionaryEditor().tabItem { Label("辞書", systemImage: "character.book.closed") }
        }
        // 高さを固定していたせいで、校正タブの「要約」節がまるごと画面外に落ちていた。
        // 設定ウインドウはスクロールしないので、切れた分は一切たどり着けない
        // （設定を足したのに使えない、という状態を実際に作ってしまった）。
        // 最も背の高いタブに合わせ、それでも溢れる場合はスクロールできるようにする。
        .frame(width: 620, height: 620)
    }

    private var engineTab: some View {
        Form {
            Picker("認識エンジン", selection: $model.settings.engineChoice) {
                ForEach(AppModel.EngineChoice.allCases) { Text($0.displayName).tag($0) }
            }
            Text(model.settings.engineChoice.note).font(.caption).foregroundStyle(.secondary)

            if model.settings.engineChoice == .whisper {
                Picker("モデル", selection: $model.settings.whisperModelID) {
                    ForEach(ModelCatalog.whisperModels) { m in
                        Text("\(m.displayName)（\(ModelCatalog.sizeText(m.approximateBytes))）")
                            .tag(m.id)
                    }
                }
                if let m = ModelCatalog.whisperModels.first(where: { $0.id == model.settings.whisperModelID }) {
                    HStack {
                        Text(m.note).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(ModelCatalog.isInstalled(m) ? "導入済み" : "初回実行時にダウンロード")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background((ModelCatalog.isInstalled(m) ? Color.green : Color.orange).opacity(0.15),
                                        in: Capsule())
                    }
                }
            }

            // 以前は自由入力だった。打ち間違えても保存でき、
            // 認識が始まってから初めておかしいと気づく形になっていた。
            Picker("音声の言語", selection: $model.settings.language) {
                Text("日本語").tag("ja")
                Text("英語").tag("en")
                Text("自動判定").tag("auto")
            }
            Text("自動判定は、話者が言語を切り替える収録で外しやすい。分かっているなら指定する方が安定する。")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("取りこぼし疑い区間を自動で再認識する", isOn: $model.settings.autoRepair)

            VStack(alignment: .leading) {
                HStack {
                    Text("無音とみなす音の小ささ")
                    Spacer()
                    Text(silenceLabel).font(.caption)
                    Text("(\(Int(model.settings.silenceDBFS)) dBFS)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.settings.silenceDBFS, in: -70...(-25), step: 1) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("静かでも拾う").font(.caption2).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("はっきりした声だけ").font(.caption2).foregroundStyle(.secondary)
                }
                Text("""
                     これより小さい音しか無い区間は、認識結果が出ていても本文を捨てる。\
                     無音に対して文章を出してしまう「幻聴」を止めるための主な仕組み。\
                     右に寄せるほど幻聴は減るが、小声のやりとりを落としやすくなる。\
                     既定（-45 dBFS 付近）から動かす必要はふつう無い。
                     """)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding()
    }

    private var crossCheckTab: some View {
        Form {
            Section("別エンジンで読み直して食い違いを探す") {
                Text("""
                     whisper と系統の違うエンジンで同じ音声を認識し、\
                     出力が食い違う箇所を取り出す。両者が一致していれば信用でき、\
                     食い違っていれば怪しい、という判断材料になる。\
                     同系統のモデルを足しても誤りが相関するだけなので、\
                     ここに並ぶのはアーキテクチャの異なるものだけ。
                     """)
                    .font(.caption).foregroundStyle(.secondary)

                ForEach(ModelCatalog.crossCheckCandidates) { m in
                    Toggle(isOn: Binding(
                        get: { model.settings.crossCheckModelIDs.contains(m.id) },
                        set: { on in
                            if on { model.settings.crossCheckModelIDs.insert(m.id) }
                            else { model.settings.crossCheckModelIDs.remove(m.id) }
                        })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.displayName)
                            Text(m.note).font(.caption).foregroundStyle(.secondary)
                            if ModelCatalog.isInstalled(m) {
                                Label("導入済み", systemImage: "checkmark.circle.fill")
                                    .font(.caption2).foregroundStyle(.green)
                            } else {
                                Label("入れると初回に \(ModelCatalog.sizeText(m.approximateBytes)) "
                                      + "のダウンロードが走る",
                                      systemImage: "arrow.down.circle")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                            // 実測で分かった欠点は、選ぶ前に見えていないと意味がない。
                            if let c = m.caveat {
                                Label(c, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                            if let a = m.attribution {
                                Text(a).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                if pendingCrossCheckBytes > 0 {
                    Label("選択中で未導入の合計: \(ModelCatalog.sizeText(pendingCrossCheckBytes))",
                          systemImage: "arrow.down.circle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("""
                     いずれも CPU 実行（静的 onnxruntime では CoreML が使えない）。\
                     照合を1つ足すと、収録時間ぶんの認識がもう一周走る。
                     """)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("食い違いの判定") {
                Toggle("LLMに文脈から判定させる", isOn: $model.settings.adjudicateDisagreements)
                Toggle("読みが違う食い違いも判定させる（非推奨）", isOn: $model.settings.judgeDifferentReadings)
                    .disabled(!model.settings.adjudicateDisagreements)
                Text("""
                     実測（whisper × parakeet・11分）では判定145件のうち138件が読み不一致だった。\
                     読みが違う箇所は音響に情報が残っているので、テキストだけの判断は確度が落ちる。\
                     既定で切ってあり、その分は判定せず人に残す。
                     """)
                    .font(.caption).foregroundStyle(.secondary)
                Text("""
                     LLMは候補の**番号**しか返せない形にしてあるので、候補に無い文字列が出ることはない。\
                     読みが一致する食い違い（機構／気候）は音響で区別できないため文脈判断が正しい道具だが、\
                     読みが違う食い違いは音響に情報が残っているので、\
                     テキストだけで判断させると見えない誤りが増える。\
                     後者を切ると、その分は判定せず人に残す。
                     """)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding()
    }

    private var correctionTab: some View {
        Form {
            HStack {
                Text("Foundation Models")
                Spacer()
                switch model.correctionAvailability {
                case .available:
                    Label("利用可能", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .unavailable(let r):
                    Label(r, systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                }
            }
            Button("状態を再確認") { Task { await model.refreshCorrectionAvailability() } }

            Toggle("LLMによる校正を行う", isOn: $model.settings.enableCorrection)
            Toggle("同じ提案が2回出た場合のみ採用する", isOn: $model.settings.requireAgreement)
                .disabled(!model.settings.enableCorrection)

            Section("ゲートの内容（変更不可）") {
                Label("読み（発音）が変わる書き換えは棄却", systemImage: "lock.fill")
                Label("原文に無い英数字トークンの出現は棄却", systemImage: "lock.fill")
                Label("長さ比 0.75〜1.35 の外は棄却", systemImage: "lock.fill")
                Label("編集距離 40 超は棄却", systemImage: "lock.fill")
                Text("これらはプロンプトではなくコードで強制されている。緩めるにはソースを変更する必要がある。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("文脈に合わない語の指摘") {
                Toggle("意味が通らない語をモデルに指摘させる", isOn: $model.settings.enablePlausibilityCheck)
                Text("""
                     照合は**エンジン間の食い違い**しか見られないので、\
                     全エンジンが同じ間違え方をした箇所は素通りする。\
                     実測でも「期初」が4エンジンすべてで「気象」になり、\
                     「大体気象の目標を…」がそのまま出ていた。音響の多数決では原理的に拾えない。
                     """)
                    .font(.caption).foregroundStyle(.secondary)
                Text("""
                     ここだけは文脈を手掛かりにする。ただし**本文は書き換えない**。\
                     モデルが返せるのは「行番号」「その行にある語」「ありうる語」の3つだけで、\
                     返した語が本文に無ければ機械的に捨てる。\
                     通っても本文はそのままで、候補が横に並ぶだけ。\
                     同じ指摘が2回出た場合のみ採る。
                     """)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("要約") {
                Toggle("要約を作る", isOn: $model.settings.enableSummary)
                Text("""
                     モデルには「どの行が重要か」の**行番号**と短い見出しだけを返させ、\
                     本文は文字起こしからそのまま引用する。要約文をモデルに書かせる経路は無い。\
                     見出しは、引用に無い数値・英数字・カタカナ語を含む場合に棄却され、\
                     代わりに原文の先頭が機械的に切り出される。
                     """)
                    .font(.caption).foregroundStyle(.secondary)

                Stepper("1塊の文字数: \(model.settings.summaryChunkCharacters)",
                        value: $model.settings.summaryChunkCharacters,
                        in: 1_000...6_000, step: 500)
                    .disabled(!model.settings.enableSummary)
                Text("""
                     Foundation Models の文脈長は 8,192 トークン（日本語で約1万文字）。\
                     長い収録はこの単位に割って順に処理する。大きくすると文脈は広がるが、\
                     上限を超えると失敗する。
                     """)
                    .font(.caption).foregroundStyle(.secondary)

                Stepper("1塊あたりの要点数: \(model.settings.summaryPointsPerChunk)",
                        value: $model.settings.summaryPointsPerChunk, in: 1...4)
                    .disabled(!model.settings.enableSummary)

                Toggle("見出しの検証を厳しくする", isOn: $model.settings.summaryStrictHeadlines)
                    .disabled(!model.settings.enableSummary)
                Text("""
                     原文に無い漢語を含む見出しを棄却する。\
                     「予算を承認」→「予算を却下」のような意味の反転を止められるが、\
                     実測（11分の素材）では見出し3件が3件とも棄却され、\
                     モデル由来の見出しは0%になった。棄却されると原文の先頭を切り出した\
                     見出しに替わるので、引用のすぐ上に同じ文が並ぶことになる。\
                     切ると言い換えの自由度が戻るが、反転を止める防壁は数値・英数字・\
                     カタカナ語だけになる。要約タブの「モデル見出しが通った割合」で効果を見て決める。
                     """)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding()
    }
}

struct DictionaryEditor: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("固有名詞辞書")
                .font(.headline)
            Text("""
                 ここに登録した語は2か所で使われる。\
                 ひとつは認識時の語彙ヒント（whisper の initial_prompt）で、\
                 「モデルがその語を知らない」ことが原因の誤認識を減らす。\
                 もうひとつは認識後の決定論的な置換。\
                 読み一致ゲートは読みが変わる書き換えを必ず棄却するので、\
                 社名・人名のような誤認識を直せる経路はここだけになる。
                 """)
                .font(.caption).foregroundStyle(.secondary)

            Table(of: Binding<UserDictionary.Entry>.self) {
                TableColumn("正しい表記") { $e in TextField("", text: $e.surface) }
                TableColumn("読み") { $e in TextField("", text: $e.reading) }
                TableColumn("誤認識されがちな表記（カンマ区切り）") { $e in
                    TextField("", text: Binding(
                        get: { e.misspellings.joined(separator: ",") },
                        set: { e.misspellings = $0.split(separator: ",").map {
                            $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                }
            } rows: {
                ForEach($model.dictionary.entries) { $entry in
                    TableRow($entry)
                }
            }

            HStack {
                Button("追加") { model.addDictionaryEntry() }
                Button("削除") {
                    if !model.dictionary.entries.isEmpty { model.dictionary.entries.removeLast() }
                }
                Spacer()
                Button("保存") { model.saveDictionary() }.buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}
