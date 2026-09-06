import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let t = model.transcript {
                TranscriptView(transcript: t)
            } else {
                dropZone
            }
            Divider()
            footer
        }
        .alert("エラー", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })) {
            Button("閉じる", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.sourceURL?.lastPathComponent ?? "ファイル未選択")
                    .font(.headline).lineLimit(1).truncationMode(.middle)
                Text(model.statusMessage).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRunning {
                ProgressView(value: model.progress).frame(width: 180)
                Button("キャンセル") { model.cancel() }
            } else if model.sourceURL == nil {
                // ファイルが無いときに「開始」を押せない形で置くと、
                // 押しても何も起きないボタンが画面に残る。
                // 押せるボタンは常に1つだけにして、次にやることを迷わせない。
                SettingsLink { Image(systemName: "gearshape") }
                    .help("設定（⌘,）")
                Button("ファイルを選ぶ…") { model.presentOpenPanel() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            } else {
                SettingsLink { Image(systemName: "gearshape") }
                    .help("設定（⌘,）")
                Button("別のファイル…") { model.presentOpenPanel() }
                // 押しかたで構成が決まる。**設定を開かずに速さと確からしさを選べる**ようにした。
                // 設定に埋めると「今どちらで走っているか」が画面から消える。
                Button("高速") { model.start(mode: .fast) }
                    .help("OS内蔵エンジンで下書き。照合も校正もしない。57分の録音で30秒ほど。"
                          + "固有名詞は崩れやすい")
                Button("標準") { model.start(mode: .quality) }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .help("whisper で認識し、設定した照合を掛ける。57分の録音で5〜10分")
            }
        }
        .padding(12)
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 46)).foregroundStyle(.secondary)
            Text("動画・音声ファイルをここにドロップ").font(.title3)
            Text("mov / mp4 / m4a / mp3 / wav など、AVFoundation が読める形式")
                .font(.caption).foregroundStyle(.secondary)
            // ドロップだけだと「ドロップ以外の道が無い」ように見える。
            Button("ファイルを選ぶ…") { model.presentOpenPanel() }
                .controlSize(.large)
            Text("音声はこの Mac の中だけで処理される。外部への送信は無い。")
                .font(.caption2).foregroundStyle(.secondary)
            capabilityBadges
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35))
                .padding(20)
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.accept(url: url) }
            }
            return true
        }
    }

    /// いまの設定で、まだ手元に無いモデル。
    /// 「開始」を押してから10分待たされて初めてダウンロードだと気づく、
    /// という状態にしないために先に出す。
    private var pendingDownload: (count: Int, bytes: Int64) {
        var wanted: [ModelCatalog.Model] = []
        // 「標準」で使う whisper は取得が要る。「高速」の OS内蔵エンジンは要らない。
        if let m = ModelCatalog.whisperModels.first(where: { $0.id == model.settings.whisperModelID }) {
            wanted.append(m)
        }
        wanted += ModelCatalog.sherpaModels.filter { model.settings.crossCheckModelIDs.contains($0.id) }
        let missing = wanted.filter { !ModelCatalog.isInstalled($0) }
        return (missing.count, missing.reduce(0) { $0 + $1.approximateBytes })
    }

    private var capabilityBadges: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                badge("押しかた", model.runMode.displayName, model.runMode == .fast ? .orange : .blue)
                if model.settings.crossCheckModelIDs.isEmpty {
                    badge("照合", "なし", .secondary)
                } else {
                    badge("照合", "\(model.settings.crossCheckModelIDs.count) エンジン", .blue)
                }
                switch model.correctionAvailability {
                case .available:
                    badge("校正LLM", "利用可能", .green)
                case .unavailable(let reason):
                    badge("校正LLM", reason, .orange)
                }
            }
            let pending = pendingDownload
            if pending.bytes > 0 {
                Label("初回だけ \(ModelCatalog.sizeText(pending.bytes)) のダウンロードが入る"
                      + "（モデル \(pending.count) 件）",
                      systemImage: "arrow.down.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.top, 6)
    }

    private func badge(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let t = model.transcript {
                Text("\(t.visibleSegments.count) セグメント / \(t.totalCharacters) 文字 / カバー率 \(String(format: "%.1f%%", t.audit.stats.coverageRatio * 100))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.transcript != nil {
                Menu("書き出し") {
                    ForEach(ExportFormat.allCases) { f in
                        Button(f.displayName) { model.export(f) }
                    }
                    Divider()
                    Button("全形式をフォルダに書き出す") { model.exportAll() }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}
