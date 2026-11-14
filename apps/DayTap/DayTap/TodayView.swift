import SwiftUI

/// 今天 tab(#82 骨架):每日回顾的落位页——健康、人物、情绪的每日一段(#84/#85/#87 逐步填)。
/// 骨架期只放两样真东西:今天的录音统计(纯本地)+ 各回顾块的诚实空态;
/// 绝不放「敬请期待」式的占位假内容,空态都说明数据从哪来、何时会有。
struct TodayView: View {
    @ObservedObject private var library = PhoneLink.shared.library

    private var todaysRecords: [RecordingRecord] {
        DayAgenda.todaysRecordings(library.records, now: Date())
    }

    private var totalMinutes: Int {
        Int(todaysRecords.reduce(0) { $0 + $1.durationSeconds } / 60)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("今日概览")
                            .font(.headline)
                        Text(todaysRecords.isEmpty
                            ? "今天还没有录音。需要记一笔,去「计划」安排,或去「记录」开录。"
                            : "今天录了 \(todaysRecords.count) 条,共 \(totalMinutes) 分钟。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)

                    reviewBlock(
                        title: "健康回顾",
                        icon: "heart.circle",
                        text: "睡眠、活动量与锻炼记录的每日一段,接入健康数据后在这里出现。"
                    )
                    reviewBlock(
                        title: "人物",
                        icon: "person.2",
                        text: "今天的声音里常出现谁、聊了什么,会在每日回顾里汇总。"
                    )
                    reviewBlock(
                        title: "情绪",
                        icon: "face.smiling",
                        text: "一天里的紧张与放松时刻,随场景回顾能力上线后在这里呈现。"
                    )
                }
                .padding(.vertical, 8)
            }
            .navigationTitle("今天")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func reviewBlock(title: String, icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
    }
}
