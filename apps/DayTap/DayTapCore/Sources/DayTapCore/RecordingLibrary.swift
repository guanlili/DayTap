import AVFoundation
import Combine
import Foundation

/// 录音文件和 `index.json` 的读写。
/// 手表用它记住「哪些还没被手机确认」；iPhone 用它列出最近收到的文件。
/// `didReceive file` 发生在后台线程，所以写入用锁，刷新界面再回到主线程。
final class RecordingLibrary: ObservableObject {
    @Published private(set) var records: [RecordingRecord] = []

    let audioDirectory: URL
    private let indexURL: URL
    private let lock = NSLock()
    private var storage: [RecordingRecord] = []

    init(audioDirectory: URL, indexURL: URL) {
        self.audioDirectory = audioDirectory
        self.indexURL = indexURL
        do {
            try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: indexURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            DayTapLog.library.error("create folders failed \(error.localizedDescription, privacy: .public)")
        }
        storage = Self.read(indexURL: indexURL)
        records = storage
    }

    func fileURL(id: String) -> URL {
        audioDirectory.appendingPathComponent(TransferKeys.filename(for: id))
    }

    /// 批量入册(#67):一次落盘一次刷新——孤儿收编等 N 条场景,原逐条 upsert
    /// = N 次全量写 index.json + N 次列表跳变。
    @discardableResult
    func upsertBatch(_ records: [RecordingRecord]) -> Bool {
        guard !records.isEmpty else { return true }
        return mutate { storage in
            for record in records {
                if let index = storage.firstIndex(where: { $0.id == record.id }) {
                    storage[index] = record
                } else {
                    storage.append(record)
                }
            }
        }
    }

    /// 返回 false=索引落盘失败(磁盘满等),调用方据此不回执(#59:手表保留原件而非删)。
    @discardableResult
    /// 勾选落库(#61/#62/#80 收敛):按 id 在该条录音的待办里替换并触脏。
    /// 计划页/全文页共用这一份,不再各留拷贝;找不到(已删/待办没了)静默不动。
    func toggleActionItem(recordID: String, updated: ActionItem) {
        guard var fresh = record(id: recordID),
              var items = fresh.actionItems,
              let index = items.firstIndex(where: { $0.id == updated.id })
        else { return }
        items[index] = updated
        fresh.actionItems = items
        fresh.updatedAt = Date()  // 勾选也是变更(#62):CloudSync 增量按 updatedAt 判脏
        upsert(fresh)
    }

    func upsert(_ record: RecordingRecord) -> Bool {
        mutate { records in
            if let index = records.firstIndex(where: { $0.id == record.id }) {
                records[index] = record
            } else {
                records.append(record)
            }
        }
    }

    /// iPhone 收到文件时调用。同一个 id 已存在就不再覆盖音频，只更新索引并让调用方回执。
    /// 返回 true 表示可以给手表发「已保存」回执。
    @discardableResult
    func importAudio(from source: URL, record: RecordingRecord) -> Bool {
        let destination = fileURL(id: record.id)
        do {
            try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: source, to: destination)
            }
            var stored = record
            // 重复到达保富字段(#59):回执丢失→重传的裸 record 不再把手机端已转写/改名/
            // 摘要/软删状态整条抹掉——索引里非空的派生字段与用户输入永远赢过传输元数据。
            if let existing = self.record(id: record.id) {
                stored.displayName = existing.displayName ?? stored.displayName
                stored.transcript = existing.transcript ?? stored.transcript
                stored.transcriptSegments = existing.transcriptSegments ?? stored.transcriptSegments
                if let stamped = existing.transcribedAt { stored.transcribedAt = stamped }
                stored.summary = existing.summary ?? stored.summary
                stored.actionItems = existing.actionItems ?? stored.actionItems
                stored.autoTitle = existing.autoTitle ?? stored.autoTitle
                stored.category = existing.category ?? stored.category
                if let deletedAt = existing.deletedAt { stored.deletedAt = deletedAt }
                if let origin = existing.origin { stored.origin = origin }
            }
            stored.byteCount = fileSize(at: destination) ?? record.byteCount
            // #44:手表偶发传来 duration=0 但音频真实存在(33KB/0s 案)——按落盘文件实测时长兜底。
            if stored.durationSeconds < 1,
               let player = try? AVAudioPlayer(contentsOf: destination),
               player.duration > 1
            {
                stored.durationSeconds = player.duration
            }
            stored.state = .acknowledged
            stored.lastError = nil
            stored.updatedAt = Date()
            guard upsert(stored) else {
                DayTapLog.library.error("import \(record.id, privacy: .public): index write failed, NOT acking")
                return false
            }
            DayTapLog.library.info("saved \(stored.id, privacy: .public) bytes=\(stored.byteCount)")
            return true
        } catch {
            DayTapLog.library.error("import \(record.id, privacy: .public) failed \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func update(id: String, state: TransferState, error: String?) {
        mutate { records in
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }
            if records[index].state == .acknowledged && state != .acknowledged {
                return
            }
            records[index].state = state
            records[index].lastError = error
            records[index].updatedAt = Date()
        }
    }

    func record(id: String) -> RecordingRecord? {
        lock.lock()
        defer { lock.unlock() }
        return storage.first { $0.id == id }
    }

    /// 手机端删除(#20):索引条目与音频文件一并清掉。
    /// 只动手机这一侧;手表的传输状态与原件不受影响(已确认的不会重传)。
    func remove(id: String) {
        mutate { records in
            records.removeAll { $0.id == id }
        }
        try? FileManager.default.removeItem(at: fileURL(id: id))
        DayTapLog.library.info("removed \(id, privacy: .public)")
    }

    /// 软删进回收站(#26):只打 deletedAt 标记,文件留在原地,列表按非 nil 过滤。
    func softDelete(id: String) {
        mutate { records in
            if let index = records.firstIndex(where: { $0.id == id }) {
                records[index].deletedAt = Date()
            }
        }
        DayTapLog.library.info("soft deleted \(id, privacy: .public)")
    }

    /// 从回收站恢复(#26):清掉 deletedAt,条目回到列表。
    func restore(id: String) {
        mutate { records in
            if let index = records.firstIndex(where: { $0.id == id }) {
                records[index].deletedAt = nil
            }
        }
    }

    /// 回收站到期清扫(#26):软删超过保留期的连文件一起真正删掉。返回清除条数。
    @discardableResult
    func purgeExpiredDeleted(retention: TimeInterval) -> Int {
        let cutoff = Date().addingTimeInterval(-retention)
        let expired = snapshot().filter { record in
            guard let deletedAt = record.deletedAt else { return false }
            return deletedAt < cutoff
        }
        for record in expired {
            remove(id: record.id)
        }
        if !expired.isEmpty {
            DayTapLog.library.info("purged expired trashed count=\(expired.count, privacy: .public)")
        }
        return expired.count
    }

    func snapshot() -> [RecordingRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    private func fileSize(at url: URL) -> Int? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize
    }

    /// 返回是否成功落盘(#59:importAudio 据此决定回不回执)。
    @discardableResult
    private func mutate(_ body: (inout [RecordingRecord]) -> Void) -> Bool {
        lock.lock()
        body(&storage)
        storage.sort { $0.createdAt > $1.createdAt }
        let snapshot = storage
        var persisted = true
        do {
            try Self.write(snapshot, to: indexURL)
        } catch {
            persisted = false
            DayTapLog.library.error("write index failed \(error.localizedDescription, privacy: .public)")
        }
        lock.unlock()
        publish(snapshot)
        return persisted
    }

    private func publish(_ snapshot: [RecordingRecord]) {
        if Thread.isMainThread {
            records = snapshot
        } else {
            DispatchQueue.main.async { [weak self] in
                // 回锁重读最新值(#59):后台 mutate 的旧快照晚到时,不再把主线程刚发布的新状态拉回去
                guard let self else { return }
                self.records = self.snapshot()
            }
        }
    }

    private static func read(indexURL: URL) -> [RecordingRecord] {
        func decode(_ url: URL) -> [RecordingRecord]? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode([RecordingRecord].self, from: data)
        }

        if let records = decode(indexURL) {
            return records.sorted { $0.createdAt > $1.createdAt }
        }
        // 主索引坏(半写/损坏):先吃 .bak 备份,不再静默从空表起步——否则下一次 mutate
        // 会把只含新内容的快照覆盖写回,旧元数据(转写/摘要/名字)无备份蒸发(#59)。
        let bakURL = indexURL.appendingPathExtension("bak")
        if let records = decode(bakURL) {
            DayTapLog.library.error("index unreadable, recovered \(records.count) records from .bak")
            return records.sorted { $0.createdAt > $1.createdAt }
        }
        if FileManager.default.fileExists(atPath: indexURL.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            let evidence = indexURL.deletingLastPathComponent()
                .appendingPathComponent("index.corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: indexURL, to: evidence)
            DayTapLog.library.error("index unreadable and no .bak; corrupt copy preserved as \(evidence.lastPathComponent)")
        }
        return []
    }

    private static func write(_ records: [RecordingRecord], to indexURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        // .bak 轮转(#59):写新之前把当前版留底,读侧解码失败时从备份恢复。
        let bakURL = indexURL.appendingPathExtension("bak")
        if FileManager.default.fileExists(atPath: indexURL.path) {
            try? FileManager.default.removeItem(at: bakURL)
            try? FileManager.default.copyItem(at: indexURL, to: bakURL)
        }
        try data.write(to: indexURL, options: [.atomic])
    }
}

enum DayTapFolders {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var appSupport: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DayTap", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
