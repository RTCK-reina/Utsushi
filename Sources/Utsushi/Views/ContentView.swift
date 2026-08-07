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
            } else {
                Button("ファイルを開く…") { model.presentOpenPanel() }
                Button("文字起こし開始") { model.start() }
                    .keyboardShortcut(.return)
                    .disabled(model.sourceURL == nil)
                    .buttonStyle(.borderedProminent)
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

    private var capabilityBadges: some View {
        HStack(spacing: 8) {
            badge("エンジン", model.settings.engineChoice == .whisper ? "whisper.cpp" : "Apple", .blue)
            switch model.correctionAvailability {
            case .available:
                badge("校正LLM", "利用可能", .green)
            case .unavailable(let reason):
                badge("校正LLM", reason, .orange)
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
