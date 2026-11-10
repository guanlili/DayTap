import SwiftUI
import WatchKit

/// 尽早激活 `WCSession`，这样上次没传完的文件不用等用户先点开界面。
final class DayTapWatchDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        WatchLink.shared.activate()
        DayTapLog.link.info("watch application launched")
    }

    func applicationDidBecomeActive() {
        WatchLink.shared.retryPending(reason: "did-become-active")
    }
}

@main
struct DayTapWatchApp: App {
    @WKApplicationDelegateAdaptor(DayTapWatchDelegate.self) private var delegate
    /// 单例:AppIntent(握拳)与界面必须驱动同一个 WatchModel。
    @StateObject private var model = WatchModel.shared

    var body: some Scene {
        WindowGroup {
            RecordingScreen(model: model)
        }
    }
}
