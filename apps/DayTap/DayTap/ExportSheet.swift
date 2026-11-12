import SwiftUI

/// 导出(#38→#41):格式(Markdown/纯文本/JSON)×内容(完整/仅摘要卡)选项页,ExportBuilder 同源拼装。
enum ExportFormat: String, CaseIterable, Identifiable {
    case markdown = "Markdown"
    case plainText = "纯文本"
    case json = "JSON"

    var id: String { rawValue }
    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .plainText: return "txt"
        case .json: return "json"
        }
    }
}

/// 导出内容(#41):完整=摘要+待办+全文;仅摘要卡=标题+类别+摘要+待办,不含全文(决策卡直投)。
enum ExportContent: String, CaseIterable, Identifiable {
    case full = "完整"
    case digestOnly = "仅摘要卡"

    var id: String { rawValue }
}

/// 导出构建(#41):格式×内容 → 单文件。Markdown 沿用 #38 结构,纯文本同源去标记,JSON 给机器。
private enum ExportBuilder {
    /// 标题口径与列表一致:手动名 > 自动短标题 > 时刻。
    static func title(_ record: RecordingRecord) -> String {
        if let name = record.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let auto = record.autoTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !auto.isEmpty {
            return auto
        }
        return record.createdAt.formatted(date: .omitted, time: .shortened)
    }

    /// 按天归组(records 已按 createdAt 倒序,同列表分组口径)。
    private static func grouped(_ records: [RecordingRecord]) -> [(day: Date, records: [RecordingRecord])] {
        let calendar = Calendar.current
        var groups: [(day: Date, records: [RecordingRecord])] = []
        for record in records {
            let day = calendar.startOfDay(for: record.createdAt)
            if groups.last?.day == day {
                groups[groups.count - 1].records.append(record)
            } else {
                groups.append((day, [record]))
            }
        }
        return groups
    }

    /// 生成并写临时文件,失败返回 nil。
    static func makeFile(records: [RecordingRecord], format: ExportFormat, content: ExportContent, category: String?) -> URL? {
        let dateText = Date().formatted(.iso8601.year().month().day())
        let suffix = category.map { "-\($0)" } ?? ""
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DayTap-转写-\(dateText)\(suffix).\(format.fileExtension)")
        let data: Data
        switch format {
        case .json:
            // 仅摘要卡时剥掉全文与分段,JSON 与文本格式同口径。
            let out: [RecordingRecord] = content == .full ? records : records.map { record in
                var trimmed = record
                trimmed.transcript = nil
                trimmed.transcriptSegments = nil
                return trimmed
            }
            data = (try? JSONEncoder.exportData(records: out)) ?? Data("[]".utf8)
        default:
            data = Data(text(records: records, format: format, content: content, category: category).utf8)
        }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Markdown/纯文本 共用拼装:同源不同壳(#38 结构,纯文本只换标记)。
    static func text(records: [RecordingRecord], format: ExportFormat, content: ExportContent, category: String?) -> String {
        let markdown = format == .markdown
        let today = Date().formatted(date: .abbreviated, time: .omitted)
        var lines: [String] = [markdown ? "# DayTap 转写 · \(today)" : "DayTap 转写 · \(today)"]
        if let category {
            lines.append("")
            lines.append(markdown ? "筛选类别：**\(category)**" : "筛选类别：\(category)")
        }
        let calendar = Calendar.current
        for group in grouped(records) {
            let header: String
            if calendar.isDateInToday(group.day) {
                header = "今天"
            } else if calendar.isDateInYesterday(group.day) {
                header = "昨天"
            } else {
                header = group.day.formatted(date: .abbreviated, time: .omitted)
            }
            lines.append("")
            lines.append(markdown ? "## \(header)" : "【\(header)】")
            for record in group.records {
                lines.append("")
                let time = record.createdAt.formatted(date: .omitted, time: .shortened)
                let cat = record.category.map { " · \($0)" } ?? ""
                lines.append(markdown ? "### \(time) \(title(record))\(cat)" : "\(time) \(title(record))\(cat)")
                if record.transcript == nil {
                    lines.append("（未转写 · \(DayTapFormat.clock(record.durationSeconds))）")
                    continue
                }
                if let summary = record.summary, !summary.isEmpty {
                    lines.append(markdown ? "**摘要** \(summary)" : "摘要：\(summary)")
                }
                if let actions = record.actionItems, !actions.isEmpty {
                    lines.append(markdown ? "**待办**" : "待办：")
                    for item in actions {
                        var line = item.text
                        if let due = item.dueAt {
                            line += "（截止 \(due.formatted(date: .abbreviated, time: .shortened))）"
                        }
                        if item.isDone { line += " ✓" }
                        lines.append(markdown ? "- \(line)" : "· \(line)")
                    }
                }
                if content == .full, let transcript = record.transcript {
                    lines.append("")
                    lines.append(transcript)
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

private extension JSONEncoder {
    /// JSON 导出(#41):结构化给 pipeline/脚本;完整模式带分段供跳播数据复用。
    static func exportData(records: [RecordingRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(records)
    }
}

/// 导出选项页(#41):格式×内容两排分段选择,自本页弹系统分享面板(不与外层 sheet 打架)。
struct ExportSheet: View {
    let records: [RecordingRecord]
    let category: String?
    @Environment(\.dismiss) private var dismiss

    @State private var format: ExportFormat = .markdown
    @State private var content: ExportContent = .full
    @State private var shareURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("格式", selection: $format) {
                        ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Picker("内容", selection: $content) {
                        ForEach(ExportContent.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("导出 \(records.count) 条")
                } footer: {
                    Text("Markdown 进语料库；纯文本直接粘贴；JSON 喂脚本。仅摘要卡不含全文，适合把决策卡直投聊天。")
                }

                Section {
                    Button {
                        shareURL = ExportBuilder.makeFile(records: records, format: format, content: content, category: category)
                    } label: {
                        Label("分享 / 存到文件", systemImage: "square.and.arrow.up")
                    }
                    .disabled(records.isEmpty)
                }
            }
            .navigationTitle("导出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: Binding(
                get: { shareURL != nil },
                set: { if !$0 { shareURL = nil } }
            )) {
                if let shareURL {
                    ActivityShareSheet(url: shareURL)
                        .ignoresSafeArea()
                }
            }
        }
    }
}

