import SwiftUI

/// 底栏双 tab(#80):「Day」=今天的驾驶舱,「录音」=原有动线原样保留。
/// 铁律修订:录音列表仍是录音域唯一主列表,Day 只做「今天」,两域互不抢屏。
/// 深链 daytap://recordings 仍落录音 tab(#15 口径:链接打开的是录音列表)。
struct MainTabView: View {
    enum Tab: Hashable {
        case day
        case recordings
    }

    @ObservedObject var player: PlaybackCenter
    @ObservedObject var transcriber: TranscriptionCenter
    @State private var tab: Tab = .day

    var body: some View {
        TabView(selection: $tab) {
            DayView(player: player, transcriber: transcriber)
                .tabItem { Label("Day", systemImage: "sun.max") }
                .tag(Tab.day)
            RecordingListView(player: player, transcriber: transcriber)
                .tabItem { Label("录音", systemImage: "waveform") }
                .tag(Tab.recordings)
        }
        .onOpenURL { url in
            // 「已打开录音列表」对看屏幕的人没有信息量(#15),落 tab 即可,只留日志。
            DayTapLog.link.info("open url \(url.absoluteString, privacy: .public)")
            if url.host == "recordings" {
                tab = .recordings
            }
        }
    }
}
