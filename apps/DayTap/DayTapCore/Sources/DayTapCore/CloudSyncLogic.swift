import Foundation

// MARK: - 纯逻辑(#50 SPM 化时本段整体随迁,可单测)

/// 同步裁决与序列化的全部决策逻辑,不碰 CloudKit、不碰文件——
/// 裁决口径:单写者是常态(一台手机配一只表),updatedAt 最新赢(LWW)。
enum CloudSyncLogic {
    /// 回收站保留期,与 PhoneLink 的清扫口径一致(#26)。
    static let trashRetention: TimeInterval = 30 * 24 * 3600

    /// 云端 vs 本地:云端更新则采纳(true)。
    /// local 为 nil(换机恢复/新装机)时永远采纳云端。
    static func shouldAdopt(cloud: RecordingRecord, local: RecordingRecord?) -> Bool {
        guard let local else { return true }
        return cloud.updatedAt > local.updatedAt
    }

    /// 云端有、本地整条没有(可能被 30 天清扫真删了):墓碑过期→连云端一起删;
    /// 未过期→接回本地回收站,换机恢复时回收站内容也不丢。
    static func orphanAction(cloud: RecordingRecord, now: Date = Date()) -> OrphanAction {
        guard let deletedAt = cloud.deletedAt else { return .adopt }
        return now.timeIntervalSince(deletedAt) > trashRetention ? .deleteCloud : .adopt
    }

    enum OrphanAction {
        case adopt
        case deleteCloud
    }

    /// 本地待推的脏条目:updatedAt 与上次成功推送时不一致。
    static func dirtyIDs(_ records: [RecordingRecord], lastPushed: [String: Date]) -> [String] {
        records.filter { lastPushed[$0.id] != $0.updatedAt }.map(\.id)
    }

    /// 整条录音序列化成 JSON 存 CDMeta——字段演进免费,加字段零迁移。
    static func encode(_ record: RecordingRecord) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String) -> RecordingRecord? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(RecordingRecord.self, from: data)
    }
}

