import SwiftUI

struct TranscriptView: View {
    @EnvironmentObject var model: AppModel
    let transcript: Transcript
    @State private var tab: Tab = .text
    @State private var showOnlyCorrected = false

    enum Tab: String, CaseIterable, Identifiable {
        case text = "本文"
        case summary = "要約"
        case corrections = "校正差分"
        case crossCheck = "照合"
        case audit = "検証記録"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch tab {
            case .text: textList
            case .summary: SummaryPanel(summary: transcript.summary)
            case .corrections: correctionList
            case .crossCheck: CrossCheckPanel(report: transcript.crossCheck)
            case .audit: AuditPanel(transcript: transcript)
            }
        }
    }

    private var textList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(transcript.visibleSegments) { seg in
                    HStack(alignment: .top, spacing: 10) {
                        Text(Exporter.hms(seg.start))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 68, alignment: .leading)
                        Text(seg.text).textSelection(.enabled)
                        Spacer(minLength: 0)
                        if seg.flags.contains(.lowConfidence) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange).help("尤度が低い区間")
                        }
                        if seg.flags.contains(.repaired) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundStyle(.blue).help("再認識で差し替えた区間")
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }
            .padding(.vertical, 10)
        }
    }

    private var correctionList: some View {
        let corrected = transcript.segments.filter { $0.correction != nil }
        return Group {
            if corrected.isEmpty {
                ContentUnavailableView("校正による変更はありません", systemImage: "checkmark.seal",
                                       description: Text("すべてのセグメントが原文のままです。"))
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("\(corrected.count) 件の変更").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("すべて原文に戻す") { model.revertAllCorrections() }
                            .font(.caption)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    Divider()
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(corrected) { seg in
                                CorrectionRow(segment: seg)
                            }
                        }
                        .padding(12)
                    }
                }
            }
        }
    }
}

struct CorrectionRow: View {
    @EnvironmentObject var model: AppModel
    let segment: Segment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(Exporter.hms(segment.start))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Text(ruleLabel).font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                Spacer()
                if segment.correction?.accepted == true {
                    Button("原文に戻す") { model.revert(segment) }.font(.caption)
                } else {
                    Button("校正を適用") { model.reapply(segment) }.font(.caption)
                }
            }
            Text(segment.original)
                .foregroundStyle(.secondary).strikethrough(segment.correction?.accepted == true)
                .textSelection(.enabled)
            Text(segment.correction?.after ?? "")
                .foregroundStyle(segment.correction?.accepted == true ? .primary : .secondary)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var ruleLabel: String {
        switch segment.correction?.rule {
        case .dictionary: return "辞書"
        case .fillerRemoval: return "フィラー除去"
        case .notation: return "表記統一"
        case .languageModel: return "LLM（ゲート通過）"
        case .none: return "-"
        }
    }
}
