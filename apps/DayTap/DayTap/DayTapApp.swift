import SwiftUI

/// 启动时就挂上 WatchConnectivity，避免系统在后台送来文件时还没有委托。
final class DayTapAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PhoneLink.shared.activate()
        // iCloud 备份(#56):启动即查账号拉一轮,之后库变更去抖推+回前台触发。
        CloudSync.shared.start()
        // TEMP(截图):-demoAddReminder 写一条系统提醒事项,截完删
        if ProcessInfo.processInfo.arguments.contains("-demoAddReminder") {
            Task {
                try? await SystemInterop.addToReminders(
                    text: "补拍系统提醒事项结果页，并加入演示视频",
                    due: Calendar.current.date(
                        from: DateComponents(year: 2026, month: 11, day: 15, hour: 12, minute: 0)
                    )
                )
            }
        }
        DayTapLog.link.info("iPhone application launched")
        return true
    }
}

@main
struct DayTapApp: App {
    @UIApplicationDelegateAdaptor(DayTapAppDelegate.self) private var appDelegate
    // #80 双 tab:播放器与转写中心提到 App 级共享——Day 页跳播/排程与录音页
    // 看到的是同一个实例,播放态与转写队列不因切 tab 分叉。
    @StateObject private var player = PlaybackCenter()
    @StateObject private var transcriber = TranscriptionCenter(library: PhoneLink.shared.library)

    var body: some Scene {
        WindowGroup {
            MainTabView(player: player, transcriber: transcriber)
        }
    }
}
