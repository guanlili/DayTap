import SwiftUI

/// 成长 tab(#43→#82):一周的量与分布——概览 + 类别分布,纯本地聚合。
/// 滚动「最近 7 天」而非卡历周,避免周一重置割裂周末;仅统计未删除条目。
/// 待办已归「计划」tab(今日+逾期聚合),这里不再重复展示(2026-11-14 甲方定);
/// 录音页 ⋯ 菜单的 sheet 入口随 #82 移除,records 由 library 实时推导。
struct ReviewSheet: View {
    @ObservedObject var library: RecordingLibrary

    private var records: [RecordingRecord] { library.records }

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
                }
            }
            .navigationTitle("成长")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private static func durationText(_ records: [RecordingRecord]) -> String {
        DayTapFormat.clock(records.reduce(0) { $0 + $1.durationSeconds })
    }
}
