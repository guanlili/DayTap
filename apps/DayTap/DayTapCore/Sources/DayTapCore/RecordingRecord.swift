import Foundation

/// 一条录音在索引里的传输状态。
/// 音频文件一直留在录制它的那台设备上，直到对方明确确认已经落盘。
enum TransferState: String, Codable {
    /// 文件已在手表本地，还没交给系统传输队列。
    case pending
    /// 已调用 `WCSession.transferFile`，或系统队列里还能看见它。
    case queued
    /// 系统报告这一次传输结束且没有错误。还要等 iPhone 回执，避免「送出但没写入」。
    case delivered
    /// iPhone 已把文件放进自己的文稿目录，并回了执。
    case acknowledged
    /// 这一次失败了。下次激活会话或手机回到身边时再排队。
    case failed
}

/// 待办 2.0(#61):AI 从转写全文识别的行动项,带完成态与可选截止时间。
/// 自定义解码兼容旧索引——旧版 actionItems 是纯字符串数组,裸串解码为「未完成、无时间」。
struct ActionItem: Codable, Equatable, Identifiable {
    var text: String
    var isDone: Bool = false
    /// AI 识别的截止时间(「周五下午」类表述归一化而来);没有则 nil。
    var dueAt: Date? = nil

    var id: String { text }

    init(text: String, isDone: Bool = false, dueAt: Date? = nil) {
        self.text = text
        self.isDone = isDone
        self.dueAt = dueAt
    }

    init(from decoder: Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode(String.self) {
            text = legacy
            isDone = false
            dueAt = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        isDone = try container.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
        dueAt = try container.decodeIfPresent(Date.self, forKey: .dueAt)
    }

    /// 解析 AI 输出的截止时间(#61):yyyy-MM-dd HH:mm 优先,退 yyyy-MM-dd;
    /// 空/格式不对一律 nil——识别失败不添乱。
    static func parseDue(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // 只吃两种规范长度(#62):yyyy-MM-dd(10) 与 yyyy-MM-dd HH:mm(16)——
        // 带秒/五位年份等畸形输入静默拒绝,不猜。
        guard trimmed.count == 10 || trimmed.count == 16 else { return nil }
        let minuteFormatter = DateFormatter()
        minuteFormatter.locale = Locale(identifier: "en_US_POSIX")
        minuteFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        if let date = minuteFormatter.date(from: trimmed) { return date }
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        return dayFormatter.date(from: trimmed)
    }
}

/// 转写的时间戳分段(#29):一段文字 + 它在音频里的位置。
/// 搜索仍走 transcript 纯文本(快);分段只用于「命中跳播/点句跳播」的定位与渲染。
struct TranscriptSegment: Codable, Equatable {
    var text: String
    /// 距录音开始的秒数。
    var start: Double
    var duration: Double
}

/// 手表和 iPhone 共用的一条录音索引。文件名永远由 `id` 推导，不采用对方传来的路径。
struct RecordingRecord: Codable, Identifiable, Equatable {
    var id: String
    var createdAt: Date
    var durationSeconds: Double
    var byteCount: Int
    var state: TransferState
    var lastError: String?
    var updatedAt: Date
    /// 手机端重命名的显示名(#2)。nil=还没起过名,列表和分享名退回时间戳。
    /// 可选字段,旧 index.json 解码为 nil,天然向后兼容;不参与手表传输协议。
    var displayName: String?
    /// 手机端转写出的全文。nil=还没转过。
    /// 可选字段,旧 index.json 解码为 nil,天然向后兼容;不参与手表传输协议。
    var transcript: String?
    /// 带时间戳的转写分段(#29)。nil=旧转写或没转过——可搜索、不可跳播,UI 自动降级。
    var transcriptSegments: [TranscriptSegment]? = nil
    /// 录音来源(#3):nil=手表(旧数据天然如此),"phone"=手机直接录。
    /// 可选字段,默认 nil 向后兼容;不参与手表传输协议(手机录的永远不出本机)。
    var origin: String? = nil
    /// 手机端软删时间(#26):nil=正常;非 nil=在「最近删除」里,30 天后自动彻底清除。
    /// 可选字段,默认 nil 向后兼容;不参与手表传输协议。
    var deletedAt: Date? = nil
    /// 主体类别(#29):nil=未分类(还没转写/判不出/被手动清除)。
    /// 可选字段,默认 nil 向后兼容;不参与手表传输协议(手机端本地判定,预设见 RecordingCategory)。
    var category: String? = nil
    /// 转写摘要(#35):本机 Foundation Models 出的 ≤3 句摘要。派生内容,重新转写会重生成。
    /// 可选字段,旧 index 解码 nil 兼容;不进手表协议。
    var summary: String? = nil
    /// 最近一次转写完成时间(#44):nil=还没转过;非 nil 且 transcript 为 nil=转了但没内容
    /// (比如误触发录了段环境音)——UI 标「无语音内容」,自动队列也不再反复重试。
    /// 可选字段,旧 index 解码 nil 兼容;不进手表协议。
    var transcribedAt: Date? = nil
    /// 摘要卡待办清单(#35):每条一行短句。派生内容,同 summary 口径。
    var actionItems: [ActionItem]? = nil
    /// 自动内容短标题(#36):≤12 字,转写完由摘要链路顺手生成;展示优先级 手动名>autoTitle>时刻。
    /// 可选字段,兼容同上;不进手表协议(手表自己的索引永远没有它)。
    var autoTitle: String? = nil

    /// 列表标题:起了名用名字,没起名用时间。
    var title: String {
        if let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    /// 尚未被 iPhone 确认落盘，就还要负责把文件送出去。
    var awaitsPhoneAck: Bool {
        state != .acknowledged
    }
}

/// 主体类别(#29):预设固定小集合,零维护——转写完自动归(见 Transcriber),长按可纠偏。
/// 不做自定义类别/多标签(less is more,v2 再说);顺序即菜单与筛选 chips 的顺序。
enum RecordingCategory {
    static let presets = ["会议", "活动", "灵感", "日常", "其他"]
}

enum TransferKeys {
    static let kind = "daytap.kind"
    static let kindRecording = "recording"
    static let kindAck = "ack"
    /// 对账(#49):手表连上手机时报未确认清单,手机逐条答「已有/重传」——回执丢失不再让角标虚高。
    static let kindReconcile = "reconcile"
    static let items = "items"
    static let acked = "acked"
    static let resend = "resend"
    static let id = "id"
    static let createdAt = "createdAt"
    static let durationSeconds = "durationSeconds"
    static let byteCount = "byteCount"

    private static let metadataDateFormatter = ISO8601DateFormatter()

    static func recordingMetadata(for record: RecordingRecord) -> [String: Any] {
        return [
            kind: kindRecording,
            id: record.id,
            createdAt: metadataDateFormatter.string(from: record.createdAt),
            durationSeconds: record.durationSeconds,
            byteCount: record.byteCount
        ]
    }

    static func ackMetadata(id: String) -> [String: Any] {
        [
            kind: kindAck,
            id: id
        ]
    }

    /// 只接受我们自己生成的 id 字符，避免元数据里的字符串被当成路径。
    static func filename(for id: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        let cleaned = String(id.map { allowed.contains($0) ? $0 : "-" })
        let stem = cleaned.isEmpty ? "recording" : cleaned
        return stem + ".m4a"
    }

    static func recordID(from metadata: [String: Any]?) -> String {
        if let raw = metadata?[id] as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return UUID().uuidString
    }

    static func doubleValue(_ value: Any?) -> Double {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let double = value as? Double {
            return double
        }
        if let int = value as? Int {
            return Double(int)
        }
        return 0
    }

    static func dateValue(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }
}
