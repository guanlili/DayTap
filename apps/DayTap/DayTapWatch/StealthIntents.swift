import AppIntents
import Foundation

/// 握拳/快捷指令入口(#5)。
/// 绑定路径:手表 设置 → 辅助功能 → AssistiveTouch → 手势 → 握拳 → 运行快捷指令 → 「DayTap 无感录音启停」。
/// 界面与意图共用 `WatchModel.shared`,握拳和点屏操作的是同一台状态机。
struct StealthToggleIntent: AppIntent {
    static var title: LocalizedStringResource = "无感录音启停"
    static var description = IntentDescription(
        "一条龙切换:闲置→武装,武装→立刻开录,录音中→停止保存并传 iPhone。适合绑到 AssistiveTouch 手势。"
    )

    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        WatchModel.shared.toggle()
        return .result()
    }
}

/// 手动停止专用(误入武装想安静退出时用,和启停分开更稳)。
struct StealthDisarmIntent: AppIntent {
    static var title: LocalizedStringResource = "解除无感模式"
    static var description = IntentDescription("静默退出武装/录音状态,未触发的内容不保存。")

    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        WatchModel.shared.disarmFromIntent()
        return .result()
    }
}
