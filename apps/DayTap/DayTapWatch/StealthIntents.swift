import AppIntents
import Foundation

/// 握拳/快捷指令入口(#5)。
/// 绑定路径:手表 设置 → 辅助功能 → AssistiveTouch → 手势 → 握拳 → 运行快捷指令 → 「DayTap 无感录音启停」。
/// 界面与意图共用 `WatchModel.shared`,握拳和点屏操作的是同一台状态机。
struct StealthToggleIntent: AppIntent {
    static var title: LocalizedStringResource = "无感录音启停"
    static var description = IntentDescription(
        "手动触发:闲→开始录音(回表盘继续),录音中→停止保存并传 iPhone。适合绑到 AssistiveTouch 手势。"
    )

    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        WatchModel.shared.toggle()
        return .result()
    }
}

/// 录错了静默丢弃:停止且不保存不传出。
struct StealthDisarmIntent: AppIntent {
    static var title: LocalizedStringResource = "丢弃当前录音"
    static var description = IntentDescription("停止当前录音并直接丢弃,不保存不传 iPhone。")

    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        WatchModel.shared.discardFromIntent()
        return .result()
    }
}
