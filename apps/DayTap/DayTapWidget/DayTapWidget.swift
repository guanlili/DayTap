import SwiftUI
import WidgetKit

/// #12 的落地形态:Apple 没有第三方表盘 API,「表盘入口」用 WidgetKit 配件小组件实现。
/// 静态磁贴:Smart Stack / 原生表盘角标,点一下打开 DayTap,App 打开即武装。
/// 状态联动(武装中/待传 N)是 v2,需要 App Group 共享数据,先不做。
@main
struct DayTapWidgetBundle: WidgetBundle {
    var body: some Widget {
        DayTapStealthWidget()
    }
}

struct StealthEntry: TimelineEntry {
    let date: Date
}

/// 静态内容不需要刷新时间线。
struct StealthProvider: TimelineProvider {
    func placeholder(in context: Context) -> StealthEntry {
        StealthEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (StealthEntry) -> Void) {
        completion(StealthEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StealthEntry>) -> Void) {
        completion(Timeline(entries: [StealthEntry(date: .now)], policy: .never))
    }
}

struct DayTapStealthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DayTapStealthEntry", provider: StealthProvider()) { _ in
            StealthEntryView()
        }
        .configurationDisplayName("无感录音")
        .description("点一下打开 DayTap：抬腕即武装，听到说话自动录。")
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

    var body: some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("DayTap", systemImage: "waveform")
                    .font(.headline)
                Text("点开即武装 · 说话自动录")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .accessoryInline:
            Label("DayTap 无感录音", systemImage: "waveform")
        case .accessoryCorner:
            Image(systemName: "waveform")
        default:
            ZStack {
                Circle().fill(Color.red.opacity(0.18))
                Image(systemName: "waveform")
                    .font(.title3.weight(.semibold))
            }
        }
    }
}
