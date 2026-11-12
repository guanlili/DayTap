import SwiftUI
import UniformTypeIdentifiers

/// 本周回顾(#43):条数/时长/类别分布/待办汇总,纯本地聚合。
struct ReviewSheet: View {
    let records: [RecordingRecord]
    @Environment(\.dismiss) private var dismiss

    private var weekRecords: [RecordingRecord] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else { return [] }
        return records.filter { $0.createdAt > cutoff }
    }

    private var todayRecords: [RecordingRecord] {
        records.filter { Calendar.current.isDateInToday($0.createdAt) }
    }

    /// 类别分布(最近 7 天):在册预设类别+未分类,按条数降序。
    private var categoryCounts: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for record in weekRecords {
            let key = record.category ?? "未分类"
            counts[key, default: 0] += 1
        }
        return counts.map { ($0.key, $0.value) }.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            // 平局时未分类垫底(Unicode 序会让它抢在真类别前,观感不对)。
            if lhs.name == "未分类" { return false }
            if rhs.name == "未分类" { return true }
            return lhs.name < rhs.name
        }
    }

    /// 待办汇总(最近 7 天):按录音归组,带来源标题。
    private var todoGroups: [(title: String, items: [String])] {
        weekRecords.compactMap { record in
            guard let items = record.actionItems, !items.isEmpty else { return nil }
            return (title: ReviewSheet.rowTitle(record), items: items)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if weekRecords.isEmpty {
                    ContentUnavailableView(
                        "最近 7 天还没有录音",
                        systemImage: "waveform",
                        description: Text("手表或手机录一条，这里就能看见一周的积累。")
                    )
                } else {
                    Section("概览") {
                        LabeledContent("今天", value: "\(todayRecords.count) 条 · \(Self.durationText(todayRecords))")
                        LabeledContent("最近 7 天", value: "\(weekRecords.count) 条 · \(Self.durationText(weekRecords))")
                    }

                    Section("类别分布 · 最近 7 天") {
                        let maxCount = categoryCounts.first?.count ?? 1
                        ForEach(categoryCounts, id: \.name) { item in
                            HStack(spacing: 10) {
                                Text(item.name)
                                    .font(.subheadline)
                                    .frame(width: 52, alignment: .leading)
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.75))
                                    .frame(width: max(10, CGFloat(item.count) / CGFloat(max(maxCount, 1)) * 150), height: 8)
                                Spacer(minLength: 0)
                                Text("\(item.count) 条")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section("待办 · 最近 7 天") {
                        if todoGroups.isEmpty {
                            Text("这一周的录音里没有提到待办")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(todoGroups, id: \.title) { group in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(group.title)
                                        .font(.subheadline.weight(.semibold))
                                    ForEach(group.items, id: \.self) { item in
                                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                                            Image(systemName: "circle")
                                                .font(.caption2)
                                                .foregroundStyle(Color.accentColor)
                                            Text(item)
                                                .font(.subheadline)
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
            .navigationTitle("本周回顾")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    if !todoGroups.isEmpty {
                        Button {
                            UIPasteboard.general.string = todoText
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        } label: {
                            Label("复制全部待办", systemImage: "checklist")
                        }
                        .accessibilityIdentifier("daytap.review.copyTodos")
                    }
                }
            }
        }
    }

    /// 「复制全部待办」的文本:按来源分组,与摘要卡同符号体系。
    private var todoText: String {
        "【待办 · 最近 7 天】\n" + todoGroups.map { group in
            "■ \(group.title)\n" + group.items.map { "· \($0)" }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private static func durationText(_ records: [RecordingRecord]) -> String {
        DayTapFormat.clock(records.reduce(0) { $0 + $1.durationSeconds })
    }

    /// 来源标题与列表同口径:手动名 > 自动短标题 > 日期+时刻(跨天场景日期更有辨识度)。
    private static func rowTitle(_ record: RecordingRecord) -> String {
        if let name = record.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let auto = record.autoTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !auto.isEmpty {
            return auto
        }
        return record.createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}

/// 设置(#40→#42):配置归设置。AI 模型节=LLM 配置中心——预设厂商可选不填、
/// 模型候选可选+自定义兜底、key 唯一必填,配完一键连通性测试;摘要只是第一个消费者。
