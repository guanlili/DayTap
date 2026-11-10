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
    /// 录音来源(#3):nil=手表(旧数据天然如此),"phone"=手机直接录。
    /// 可选字段,默认 nil 向后兼容;不参与手表传输协议(手机录的永远不出本机)。
    var origin: String? = nil

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

enum TransferKeys {
    static let kind = "daytap.kind"
    static let kindRecording = "recording"
    static let kindAck = "ack"
    static let id = "id"
    static let createdAt = "createdAt"
    static let durationSeconds = "durationSeconds"
    static let byteCount = "byteCount"

    static func recordingMetadata(for record: RecordingRecord) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        return [
            kind: kindRecording,
            id: record.id,
            createdAt: formatter.string(from: record.createdAt),
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
