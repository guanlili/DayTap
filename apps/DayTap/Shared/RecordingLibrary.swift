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

    func upsert(_ record: RecordingRecord) {
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
            stored.byteCount = fileSize(at: destination) ?? record.byteCount
            stored.state = .acknowledged
            stored.lastError = nil
            stored.updatedAt = Date()
            upsert(stored)
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

    func snapshot() -> [RecordingRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    private func fileSize(at url: URL) -> Int? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize
    }

    private func mutate(_ body: (inout [RecordingRecord]) -> Void) {
        lock.lock()
        body(&storage)
        storage.sort { $0.createdAt > $1.createdAt }
        let snapshot = storage
        do {
            try Self.write(snapshot, to: indexURL)
        } catch {
            DayTapLog.library.error("write index failed \(error.localizedDescription, privacy: .public)")
        }
        lock.unlock()
        publish(snapshot)
    }

    private func publish(_ snapshot: [RecordingRecord]) {
        if Thread.isMainThread {
            records = snapshot
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.records = snapshot
            }
        }
    }

    private static func read(indexURL: URL) -> [RecordingRecord] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let decoded = try decoder.decode([RecordingRecord].self, from: data)
            return decoded.sorted { $0.createdAt > $1.createdAt }
        } catch {
            DayTapLog.library.error("read index failed \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private static func write(_ records: [RecordingRecord], to indexURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
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
