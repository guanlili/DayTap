import SwiftUI

/// 底栏五 tab(#82 定稿):计划 / 今天 / 记录 / 成长 / 我的。
/// 计划=今日待办与安排(原 Day 页),记录=原有录音动线原样,今天/成长为内容落位
/// (#84/#85/#87 健康与回顾逐步填),我的=设置。深链 daytap://recordings 仍落记录(#15 口径)。
struct MainTabView: View {
    enum Tab: Hashable {
        case plan
        case today
        case records
        case growth
        case mine
    }

    @ObservedObject var player: PlaybackCenter
    @ObservedObject var transcriber: TranscriptionCenter
    @State private var tab: Tab = .plan

    var body: some View {
        TabView(selection: $tab) {
            DayView(player: player, transcriber: transcriber)
                .tabItem { Label("计划", systemImage: "checklist") }
                .tag(Tab.plan)
            TodayView()
                .tabItem { Label("今天", systemImage: "sun.max") }
                .tag(Tab.today)
            RecordingListView(player: player, transcriber: transcriber)
                .tabItem { Label("记录", systemImage: "waveform") }
                .tag(Tab.records)
            ReviewSheet(library: PhoneLink.shared.library)
                .tabItem { Label("成长", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(Tab.growth)
            SettingsSheet(transcriber: transcriber)
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
                .tag(Tab.mine)
        }
        .onOpenURL { url in
            // 「已打开录音列表」对看屏幕的人没有信息量(#15),落 tab 即可,只留日志。
            DayTapLog.link.info("open url \(url.absoluteString, privacy: .public)")
            if url.host == "recordings" {
                tab = .records
            }
        }
    }
}
