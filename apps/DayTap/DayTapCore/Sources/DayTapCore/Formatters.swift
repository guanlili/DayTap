import Foundation

enum DayTapFormat {
    /// 录音计时，例如 `12:05`；满一小时升为 `1:02:03`（#28，长会议回读）。
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func bytes(_ count: Int) -> String {
        let value = Double(max(0, count))
        if value < 1024 {
            return "\(count) B"
        }
        if value < 1024 * 1024 {
            return String(format: "%.0f KB", value / 1024)
        }
        return String(format: "%.1f MB", value / 1024 / 1024)
    }

    /// 分享出去时用的文件名，方便在得到或文件 App 里辨认。不参与传输协议。
    /// formatter 静态缓存(iOS 7+ NSDateFormatter 线程安全):原每次调用新建。
    private static let shareFilenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    static func shareFilename(createdAt: Date) -> String {
        "DayTap-\(shareFilenameFormatter.string(from: createdAt)).m4a"
    }

    /// 分享文件名(#2):重命名过的跟名字走,没起名退回时间戳。斜杠换掉,避免被当成路径。
    static func shareFilename(name: String?, createdAt: Date) -> String {
        if let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            let sanitized = trimmed.replacingOccurrences(of: "/", with: "-")
            return "\(sanitized).m4a"
        }
        return shareFilename(createdAt: createdAt)
    }
}
