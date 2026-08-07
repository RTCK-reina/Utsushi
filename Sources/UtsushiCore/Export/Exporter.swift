import Foundation

public enum ExportFormat: String, Sendable, CaseIterable, Identifiable {
    case markdown, srt, vtt, plainText, json
    public var id: String { rawValue }
    public var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .srt: return "srt"
        case .vtt: return "vtt"
        case .plainText: return "txt"
        case .json: return "json"
        }
    }
    public var displayName: String {
        switch self {
        case .markdown: return "Markdown（タイムスタンプ付き）"
        case .srt: return "SRT 字幕"
        case .vtt: return "WebVTT"
        case .plainText: return "プレーンテキスト"
        case .json: return "JSON（監査記録込み）"
        }
    }
}

public struct Exporter: Sendable {
    public init() {}

    public func render(_ t: Transcript, as format: ExportFormat) throws -> Data {
        let s: String
        switch format {
        case .markdown:  s = markdown(t)
        case .srt:       s = srt(t)
        case .vtt:       s = vtt(t)
        case .plainText: s = plain(t)
        case .json:      return try jsonData(t)
        }
        guard let d = s.data(using: .utf8) else {
            throw NSError(domain: "Utsushi", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "UTF-8への変換に失敗"])
        }
        return d
    }

    // MARK: -

    public func markdown(_ t: Transcript) -> String {
        var out: [String] = []
        let name = t.meta.sourceURL?.lastPathComponent ?? "(不明)"
        out.append("# 文字起こし — \(name)\n")
        out.append("| 項目 | 内容 |")
        out.append("|---|---|")
        out.append("| 元ファイル | `\(name)` |")
        out.append("| 収録長 | \(Self.hms(t.meta.sourceDuration)) |")
        out.append("| エンジン | \(t.meta.engine) |")
        out.append("| 言語 | \(t.meta.language) |")
        out.append("| セグメント数 | \(t.visibleSegments.count) |")
        out.append("| 総文字数 | \(t.totalCharacters) |")
        out.append("| 発話カバー率 | \(String(format: "%.1f%%", t.audit.stats.coverageRatio * 100))"
                   + "（発話 \(Self.hms(t.audit.stats.voicedSeconds))"
                   + " / 無音 \(Self.hms(t.audit.stats.silentSeconds))）|")
        out.append("| 作成 | \(Self.stamp(t.meta.createdAt)) |")
        out.append("")

        if !t.summary.isEmpty {
            out.append("## 要約\n")
            out.append("> 見出しはモデルが書き、本文は文字起こしからの引用そのまま。")
            out.append("> 引用に無い数値・英数字・カタカナ語を含む見出しは機械的に落としてある。\n")
            for p in t.summary.points {
                let tag = p.headlineSource == .extracted ? "（見出しはモデル案が棄却されたため原文から抜粋）" : ""
                out.append("- **[\(p.kind.displayName)]** `\(Self.hms(p.start))` \(p.headline)\(tag)")
                for q in p.quotes { out.append("  > \(q)") }
            }
            out.append("")
        }

        // 無音区間はセグメントとして持たないので、ここで並びから割り出して明示する。
        // 何も書かないと、休憩をはさんだ発話が地続きに見えてしまう。
        let gaps = t.gaps()
        var chunk = -1
        var emittedGaps = 0
        var previousEnd: Double? = nil
        for seg in t.visibleSegments {
            // 無音区間は音声から出しているので、セグメント境界には一致しない。
            // 「まだ出していない無音のうち、このセグメントより前に始まるもの」を出す。
            while emittedGaps < gaps.count, gaps[emittedGaps].lowerBound < seg.start {
                let g = gaps[emittedGaps]
                let minutes = Int((g.upperBound - g.lowerBound) / 60)
                let span = minutes >= 1 ? "約\(minutes)分" : "\(Int(g.upperBound - g.lowerBound))秒"
                out.append("\n> —— 発話なし \(Self.hms(g.lowerBound)) – \(Self.hms(g.upperBound))"
                           + "（\(span)）——\n")
                emittedGaps += 1
            }
            _ = previousEnd
            let c = Int(seg.start / 600)
            if c != chunk {
                chunk = c
                out.append("\n## \(Self.hms(Double(c * 600))) – \(Self.hms(min(Double((c + 1) * 600), t.meta.sourceDuration)))\n")
            }
            let mark = seg.flags.contains(.lowConfidence) ? " ⚠︎" : ""
            out.append("`[\(Self.hms(seg.start))]`\(mark) \(seg.text)\n")
            previousEnd = seg.end
        }
        // 末尾の無音（収録の最後が無音で終わる場合）も出す
        while emittedGaps < gaps.count {
            let g = gaps[emittedGaps]
            let minutes = Int((g.upperBound - g.lowerBound) / 60)
            let span = minutes >= 1 ? "約\(minutes)分" : "\(Int(g.upperBound - g.lowerBound))秒"
            out.append("\n> —— 発話なし \(Self.hms(g.lowerBound)) – \(Self.hms(g.upperBound))"
                       + "（\(span)）——\n")
            emittedGaps += 1
        }

        out.append("\n---\n")
        out.append("## 検証記録\n")
        out.append("| 種別 | 件数 |")
        out.append("|---|---|")
        let byKind = Dictionary(grouping: t.audit.findings, by: \.kind)
        for kind in [AuditReport.Finding.Kind.silentHallucination, .repetitionLoop,
                     .densityAnomaly, .coverageGap, .lowConfidence, .segmentOverrun] {
            out.append("| \(Self.label(kind)) | \(byKind[kind]?.count ?? 0) |")
        }
        out.append("| 本文を破棄した区間 | \(t.audit.stats.suppressedCount) |")
        out.append("| 再認識で差し替えた区間 | \(t.audit.stats.repairedCount) |")
        out.append("")

        // 破棄した本文そのものはここに出さない。
        // 幻聴が成果物に混ざらないことを ExporterTests が固定しており、
        // 中身の確認は JSON 書き出し（監査記録込み）と検証記録タブが担う。
        // stats は監査段が埋めるので、監査を通していない Transcript では 0 のままになる。
        // 案内の有無が「破棄があったか」とずれるので、データ側から判定する。
        if !t.suppressedSegments.isEmpty {
            out.append("> 破棄した本文そのものは、混入を避けるためここには載せない。"
                       + "中身はアプリの検証記録タブか JSON 書き出しで確認する。\n")
        }

        let unresolved = t.audit.findings.filter { $0.action == .unresolved }
        if !unresolved.isEmpty {
            out.append("### 未解決（人の目で確認すべき箇所）\n")
            for f in unresolved.prefix(50) {
                out.append("- `\(Self.hms(f.start))–\(Self.hms(f.end))` \(Self.label(f.kind))：\(f.detail)")
            }
            out.append("")
        }
        if t.crossCheck.engines.count >= 2 {
            out.append("### 別エンジンとの照合\n")
            out.append("照合エンジン: \(t.crossCheck.engines.joined(separator: " / "))\n")
            let o = t.crossCheck.outcome
            out.append("| 項目 | 件数 |")
            out.append("|---|---|")
            out.append("| 食い違い | \(t.crossCheck.disagreements.count) |")
            out.append("| 判定できた | \(o.decided) |")
            out.append("| 　うち読みが一致（同音異義語）| \(o.decidedWithMatchingReadings) |")
            out.append("| 　うち読みが不一致（音響情報を無視した推定）| \(o.decidedWithDifferentReadings) |")
            out.append("| 判定できず | \(o.undecided) |")
            out.append("| 2回の判定が割れた | \(o.disagreedBetweenSamples) |")
            out.append("")
            let unresolved = t.crossCheck.adjudications.filter { $0.chosenText == nil }
            if !unresolved.isEmpty {
                out.append("#### 判定できなかった食い違い（人の目で確認）\n")
                for a in unresolved.prefix(50) {
                    let cands = a.candidates.map { "\($0.engine)「\($0.text)」" }.joined(separator: " / ")
                    out.append("- `\(Self.hms(a.start))` \(cands)")
                }
                out.append("")
            }
            // 使用したモデルのライセンス表示義務を成果物にも載せる
            let attributions = ModelCatalog.sherpaModels
                .filter { t.crossCheck.engines.contains($0.id) }
                .compactMap { $0.attribution }
            if !attributions.isEmpty {
                out.append("#### ライセンス表記\n")
                for a in attributions { out.append("- \(a)") }
                out.append("")
            }
        }

        let corrected = t.segments.filter { $0.correction != nil }
        if !corrected.isEmpty {
            out.append("### 校正で変更した箇所（\(corrected.count)件）\n")
            for seg in corrected.prefix(200) {
                guard let c = seg.correction else { continue }
                out.append("- `\(Self.hms(seg.start))` [\(c.rule.rawValue)] ~~\(c.before)~~ → \(c.after)")
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    public func srt(_ t: Transcript) -> String {
        var out: [String] = []
        for (i, seg) in t.visibleSegments.enumerated() {
            out.append("\(i + 1)")
            out.append("\(Self.timecode(seg.start, sep: ",")) --> \(Self.timecode(max(seg.end, seg.start + 0.2), sep: ","))")
            out.append(seg.text)
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    public func vtt(_ t: Transcript) -> String {
        var out = ["WEBVTT", ""]
        for seg in t.visibleSegments {
            out.append("\(Self.timecode(seg.start, sep: ".")) --> \(Self.timecode(max(seg.end, seg.start + 0.2), sep: "."))")
            out.append(seg.text)
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    public func plain(_ t: Transcript) -> String {
        var paragraphs: [String] = []
        var current = ""
        var prevEnd: Double? = nil
        for seg in t.visibleSegments {
            if let p = prevEnd, seg.start - p > 1.2, !current.isEmpty {
                paragraphs.append(current); current = ""
            }
            current += seg.text
            if current.count >= 90 { paragraphs.append(current); current = "" }
            prevEnd = seg.end
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.joined(separator: "\n\n")
    }

    public func jsonData(_ t: Transcript) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(t)
    }

    // MARK: -

    static func label(_ k: AuditReport.Finding.Kind) -> String {
        switch k {
        case .silentHallucination: return "無音区間の幻聴"
        case .repetitionLoop: return "反復ループ"
        case .densityAnomaly: return "取りこぼし疑い"
        case .lowConfidence: return "低信頼"
        case .coverageGap: return "カバレッジの穴"
        case .segmentOverrun: return "尺が発話より長い"
        }
    }
    public static func hms(_ x: Double) -> String {
        let v = max(0, x)
        return String(format: "%02d:%02d:%02d", Int(v) / 3600, (Int(v) % 3600) / 60, Int(v) % 60)
    }
    public static func timecode(_ x: Double, sep: String) -> String {
        let v = max(0, x)
        let h = Int(v) / 3600, m = (Int(v) % 3600) / 60
        let s = v - Double(h * 3600 + m * 60)
        return String(format: "%02d:%02d:%06.3f", h, m, s).replacingOccurrences(of: ".", with: sep)
    }
    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }
}
