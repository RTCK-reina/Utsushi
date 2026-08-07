import SwiftUI

struct AuditPanel: View {
    @EnvironmentObject var model: AppModel
    let transcript: Transcript

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summary
                if let o = model.correctionOutcome { correctionStats(o) }
                findings
                discarded
            }
            .padding(14)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ASR検証").font(.headline)
            grid([
                ("セグメント数", "\(transcript.audit.stats.segmentCount)"),
                ("本文を破棄した区間", "\(transcript.audit.stats.suppressedCount)"),
                ("再認識で差し替え", "\(transcript.audit.stats.repairedCount)"),
                ("発話カバー率", String(format: "%.1f%%", transcript.audit.stats.coverageRatio * 100)),
                ("　発話のある時間", Exporter.hms(transcript.audit.stats.voicedSeconds)),
                ("　無音の時間", Exporter.hms(transcript.audit.stats.silentSeconds)),
                ("最大反復連続数", "\(transcript.audit.stats.maxRepetitionRun)"),
            ])
        }
    }

    /// 破棄した本文をそのまま見せる。
    /// 件数だけ出しても、ゲートが正しく効いたのか誤爆したのか区別が付かない。
    @ViewBuilder
    private var discarded: some View {
        let items = transcript.suppressedSegments
        let gaps = transcript.gaps()
        if !items.isEmpty || !gaps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("破棄した本文（\(items.count)件）").font(.headline)
                if items.isEmpty {
                    Text("なし").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("無音・反復として本文を捨てた区間。誤って捨てていないかはここで確認する。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(items) { seg in
                        HStack(alignment: .top, spacing: 8) {
                            Text(Exporter.hms(seg.start))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 68, alignment: .leading)
                            Text(seg.original)
                                .font(.caption).foregroundStyle(.secondary)
                                .strikethrough()
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                            Text(seg.flags.contains(.repetitionLoop) ? "反復" : "無音")
                                .font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.red.opacity(0.15), in: Capsule())
                        }
                    }
                }
                if !gaps.isEmpty {
                    Text("発話の無い区間（\(gaps.count)件）").font(.subheadline).padding(.top, 6)
                    ForEach(Array(gaps.enumerated()), id: \.offset) { _, g in
                        Text("\(Exporter.hms(g.lowerBound)) – \(Exporter.hms(g.upperBound))"
                             + "（\(Int((g.upperBound - g.lowerBound) / 60))分）")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func correctionStats(_ o: CorrectionOutcome) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("校正ゲート").font(.headline)
            grid([
                ("辞書による置換", "\(o.dictionary)"),
                ("決定論ルール適用", "\(o.deterministic)"),
                ("LLM提案", "\(o.proposed)"),
                ("ゲート通過して採用", "\(o.accepted)"),
                ("エンジンエラー", "\(o.engineErrors)"),
            ])
            if !o.rejected.isEmpty {
                Text("棄却された提案").font(.subheadline).padding(.top, 4)
                grid(o.rejected.sorted { $0.value > $1.value }.map { (Self.rejectionLabel($0.key), "\($0.value)") })
            }
        }
    }

    private var findings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("検出項目（\(transcript.audit.findings.count)件）").font(.headline)
            if transcript.audit.findings.isEmpty {
                Text("検出なし").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(transcript.audit.findings) { f in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon(f.action)).foregroundStyle(color(f.action))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Exporter.hms(f.start)) – \(Exporter.hms(f.end))　\(Exporter.label(f.kind))")
                            .font(.system(.caption, design: .monospaced))
                        Text(f.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text(actionLabel(f.action)).font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(color(f.action).opacity(0.14), in: Capsule())
                }
                .padding(8)
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func grid(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(rows, id: \.0) { r in
                HStack {
                    Text(r.0).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(r.1).font(.system(.caption, design: .monospaced))
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func icon(_ a: AuditReport.Finding.Action) -> String {
        switch a {
        case .suppressed: return "trash"
        case .repaired: return "arrow.triangle.2.circlepath"
        case .marked: return "flag"
        case .unresolved: return "exclamationmark.triangle"
        }
    }
    private func color(_ a: AuditReport.Finding.Action) -> Color {
        switch a {
        case .suppressed: return .red
        case .repaired: return .blue
        case .marked: return .orange
        case .unresolved: return .yellow
        }
    }
    private func actionLabel(_ a: AuditReport.Finding.Action) -> String {
        switch a {
        case .suppressed: return "破棄"
        case .repaired: return "再認識で修復"
        case .marked: return "印付け"
        case .unresolved: return "未解決"
        }
    }
    static func rejectionLabel(_ raw: String) -> String {
        switch raw {
        case "readingChanged": return "読みが変わる書き換え"
        case "lengthOutOfRange": return "長さが許容外"
        case "editDistanceTooLarge": return "変更量が大きすぎる"
        case "readingUnavailable": return "読みを取得できず検証不能"
        case "emptyResult": return "空文字にされた"
        case "newLatinToken": return "原文に無い英数字が出現"
        case "disagreement": return "2回の提案が不一致"
        default: return raw
        }
    }
}
