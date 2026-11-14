import SwiftUI
import WidgetKit

/// #12 的落地形态:Apple 没有第三方表盘 API,「表盘入口」用 WidgetKit 配件小组件实现。
/// #80-P2 起「计划磁贴」:手机算好今日待办数(今天到期+逾期未完成)经 WatchConnectivity
/// 推到手表 App,表侧写 App Group 共享容器,这里读出来显示——抬腕一眼今天还剩几件事。
@main
struct DayTapWidgetBundle: WidgetBundle {
    var body: some Widget {
        DayTapStealthWidget()
    }
}

struct StealthEntry: TimelineEntry {
    let date: Date
    /// 今日待办数;nil=没数据(未同步/隔夜自清/件数为 0),磁贴退回静态武装形态。
    let todoCount: Int?
}

/// 静态内容不需要刷新时间线。
struct StealthProvider: TimelineProvider {
    func placeholder(in context: Context) -> StealthEntry {
        StealthEntry(date: .now, todoCount: currentTodoCount())
    }

    func getSnapshot(in context: Context, completion: @escaping (StealthEntry) -> Void) {
        completion(StealthEntry(date: .now, todoCount: currentTodoCount()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StealthEntry>) -> Void) {
        // 主要靠手表 App 收到推送后 reloadAllTimelines;时间线兜底 2 小时一刷,防漏。
        completion(Timeline(
            entries: [StealthEntry(date: .now, todoCount: currentTodoCount())],
            policy: .after(.now.addingTimeInterval(2 * 3600))
        ))
    }

    /// 共享容器里的今日件数;「天」不是今天一律当没数据(隔夜自清,不显示昨天的旧数)。
    private func currentTodoCount() -> Int? {
        guard let shared = UserDefaults(suiteName: "group.com.guanhongli.daytap"),
              shared.string(forKey: "plan.day") == Self.dayFormatter.string(from: .now)
        else { return nil }
        let count = shared.integer(forKey: "plan.todoCount")
        return count > 0 ? count : nil
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

struct DayTapStealthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DayTapStealthEntry", provider: StealthProvider()) { entry in
            StealthEntryView(todoCount: entry.todoCount)
        }
        .configurationDisplayName("DayTab 计划")
        .description("今日待办件数,点开看计划;没同步到件数时是录音入口。")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

struct StealthEntryView: View {
    @Environment(\.widgetFamily) private var family
    let todoCount: Int?

    var body: some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("DayTab", systemImage: todoCount != nil ? "checklist" : "waveform")
                    .font(.headline)
                Text(todoCount.map { "今天还有 \($0) 件待办" } ?? "点开即武装 · 说话自动录")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .accessoryInline:
            if let count = todoCount {
                Label("DayTab 今天 \(count) 件待办", systemImage: "checklist")
            } else {
                Label("DayTab 无感录音", systemImage: "waveform")
            }
        case .accessoryCorner:
            if let count = todoCount {
                Text("\(count)")
                    .font(.title3.weight(.bold))
                    .widgetLabel("今天 \(count) 件待办")
            } else {
                Image(systemName: "waveform")
            }
        default:
            ZStack {
                Circle().fill(Color.red.opacity(0.18))
                if let count = todoCount {
                    Text("\(count)")
                        .font(.title2.weight(.bold))
                } else {
                    Image(systemName: "waveform")
                        .font(.title3.weight(.semibold))
                }
            }
        }
    }
}
