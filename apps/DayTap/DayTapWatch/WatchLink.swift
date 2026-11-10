import Foundation
import WatchConnectivity

/// 传输账本的结构化视图（#4）。
/// 之前界面只能看到 `statusText` 一行字，于是「点了没反应」「没有待传」都无法区分。
/// 现在把计数摊开：界面能判断要不要提示，也能把失败原因交给用户。
struct TransferSummary: Equatable {
    /// 还没被 iPhone 确认的条数（待传/排队中/已送出）。
    var waiting = 0
    /// 其中已交给系统队列的数量。
    var queued = 0
    /// 其中系统报告送出完成、还在等回执的数量。
    var delivered = 0
    /// 确认失败、等下次重试的数量。
    var failed = 0
    /// iPhone 已确认落盘的数量。
    var acknowledged = 0
    /// 最近一条失败原因。
    var lastError: String?
    /// 最近一次被 iPhone 确认的时间。
    var lastAckedAt: Date?

    var total: Int { waiting + failed + acknowledged }
    /// 只有「有东西卡住」才值得占用无感界面的视线。
    var needsAttention: Bool { failed > 0 || waiting > 0 }
}

/// 手表 → iPhone 的文件桥。
/// `transferFile` 会把文件放进系统队列：当时手机不在身边也会排队，靠近后再送。
/// 这是 Apple 公开的配套 App 传文件方式（见 WWDC21《There and back again》）。模拟器传不成，要真机配对。
final class WatchLink: NSObject {
    static let shared = WatchLink()

    /// 手表文稿目录里的音频。索引放在 Application Support，避免和音频混在一起。
    let library: RecordingLibrary

    /// 界面可读的一行状态。只在主线程改。
    private(set) var statusText = "结束后会传给 iPhone"

    /// 结构化传输计数。界面据此决定「要不要显眼提示」，而不是去解析上面那句话（#4）。
    private(set) var summary = TransferSummary()

    var onChange: (() -> Void)?

    /// 本进程里已经交给 `transferFile`、还没收到结束回调的 id。避免同一次启动重复入队。
    private var submitted: Set<String> = []
    private let submittedLock = NSLock()

    private override init() {
        let audio = DayTapFolders.documents.appendingPathComponent("Recordings", isDirectory: true)
        let index = DayTapFolders.appSupport.appendingPathComponent("index.json")
        library = RecordingLibrary(audioDirectory: audio, indexURL: index)
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else {
            setStatus("这只手表不能连接 iPhone")
            DayTapLog.link.error("WCSession not supported")
            return
        }
        let session = WCSession.default
        session.delegate = self
        if session.activationState == .activated {
            retryPending(reason: "already-active")
            return
        }
        session.activate()
        DayTapLog.link.info("activating WCSession")
    }

    /// 把还没被手机确认的本地文件再交一次。已经在系统队列里的不重复提交。
    func retryPending(reason: String) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else {
            setStatus("正在连接 iPhone…")
            return
        }

        reconcileOrphans()

        let outstanding = Set(session.outstandingFileTransfers.compactMap { transfer -> String? in
            transfer.file.metadata?[TransferKeys.id] as? String
        })

        let now = Date()
        for record in library.snapshot() where record.awaitsPhoneAck {
            if outstanding.contains(record.id) {
                library.update(id: record.id, state: .queued, error: nil)
                continue
            }
            // 刚报告「系统已送出」时先等回执，避免手机还没写完又传第二份。
            if record.state == .delivered, now.timeIntervalSince(record.updatedAt) < 120 {
                continue
            }
            if isSubmitted(record.id) {
                continue
            }
            enqueue(record)
        }
        refreshSummary(reachable: session.isReachable, reason: reason)
    }

    func enqueue(id: String) {
        guard let record = library.record(id: id) else { return }
        enqueue(record)
        if WCSession.isSupported() {
            refreshSummary(reachable: WCSession.default.isReachable, reason: "new-recording")
        }
    }

    private func enqueue(_ record: RecordingRecord) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else {
            library.update(id: record.id, state: .pending, error: "会话还没连上，稍后自动再传")
            setStatus("已保存在手表，连上 iPhone 后自动传")
            return
        }
        let url = library.fileURL(id: record.id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            library.update(id: record.id, state: .failed, error: "手表上找不到音频文件")
            DayTapLog.link.error("missing file for \(record.id, privacy: .public)")
            setStatus("找不到刚才的录音文件")
            return
        }
        markSubmitted(record.id)
        session.transferFile(url, metadata: TransferKeys.recordingMetadata(for: record))
        library.update(id: record.id, state: .queued, error: nil)
        DayTapLog.link.info("transferFile queued \(record.id, privacy: .public) reachable=\(session.isReachable)")
    }

    /// 崩溃或被系统杀掉时，目录里可能有 m4a 但索引没有。补一条待传记录。
    private func reconcileOrphans() {
        let folder = library.audioDirectory
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey]
        ) else { return }
        let known = Set(library.snapshot().map(\.id))
        for url in urls where url.pathExtension.lowercased() == "m4a" {
            let id = url.deletingPathExtension().lastPathComponent
            if known.contains(id) { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
            let record = RecordingRecord(
                id: id,
                createdAt: values?.creationDate ?? Date(),
                durationSeconds: 0,
                byteCount: values?.fileSize ?? 0,
                state: .pending,
                lastError: nil,
                updatedAt: Date()
            )
            library.upsert(record)
            DayTapLog.link.info("recovered orphan \(id, privacy: .public)")
        }
    }

    private func refreshSummary(reachable: Bool, reason: String) {
        let records = library.snapshot()
        var counts = TransferSummary()
        var newestError: (date: Date, text: String)?
        for record in records {
            switch record.state {
            case .pending, .queued:
                counts.waiting += 1
                if record.state == .queued { counts.queued += 1 }
            case .delivered:
                counts.waiting += 1
                counts.delivered += 1
            case .failed:
                counts.failed += 1
            case .acknowledged:
                counts.acknowledged += 1
                if let date = counts.lastAckedAt {
                    counts.lastAckedAt = max(date, record.updatedAt)
                } else {
                    counts.lastAckedAt = record.updatedAt
                }
            }
            if let error = record.lastError, error.isEmpty == false {
                if let current = newestError {
                    if record.updatedAt > current.date {
                        newestError = (record.updatedAt, error)
                    }
                } else {
                    newestError = (record.updatedAt, error)
                }
            }
        }
        counts.lastError = newestError?.text

        let line: String
        if counts.failed > 0 {
            line = "有 \(counts.failed) 条没传出。靠近 iPhone 后会重试。"
        } else if counts.waiting > 0 {
            if reachable {
                line = "正在传给 iPhone（\(counts.waiting) 条）"
            } else {
                line = "iPhone 不在身边也没关系，已排队 \(counts.waiting) 条"
            }
        } else if records.isEmpty {
            line = "结束后音频传到配对的 iPhone"
        } else {
            line = "iPhone 已保存最近一条"
        }
        DayTapLog.link.debug("summary \(reason, privacy: .public) waiting=\(counts.waiting) failed=\(counts.failed)")
        applySummary(counts)
        setStatus(line)
    }

    /// 计数与文案必须同时到界面，否则会出现「数字变了、提示没变」的错位。
    private func applySummary(_ counts: TransferSummary) {
        let apply = {
            self.summary = counts
            self.onChange?()
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    private func setStatus(_ text: String) {
        if Thread.isMainThread {
            statusText = text
            onChange?()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.statusText = text
                self?.onChange?()
            }
        }
    }

    private func markSubmitted(_ id: String) {
        submittedLock.lock()
        submitted.insert(id)
        submittedLock.unlock()
    }

    private func clearSubmitted(_ id: String) {
        submittedLock.lock()
        submitted.remove(id)
        submittedLock.unlock()
    }

    private func isSubmitted(_ id: String) -> Bool {
        submittedLock.lock()
        defer { submittedLock.unlock() }
        return submitted.contains(id)
    }
}

extension WatchLink: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            DayTapLog.link.error("activation failed \(error.localizedDescription, privacy: .public)")
            setStatus("连接 iPhone 失败，录音仍留在手表")
            return
        }
        DayTapLog.link.info("activation state=\(activationState.rawValue)")
        DispatchQueue.main.async {
            self.retryPending(reason: "activated")
        }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let id = fileTransfer.file.metadata?[TransferKeys.id] as? String
        DispatchQueue.main.async {
            guard let id else { return }
            self.clearSubmitted(id)
            if let error {
                self.library.update(id: id, state: .failed, error: error.localizedDescription)
                DayTapLog.link.error("transfer failed \(id, privacy: .public) \(error.localizedDescription, privacy: .public)")
                self.setStatus("传输失败，稍后自动重试")
                self.refreshSummary(reachable: session.isReachable, reason: "transfer-failed")
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self.retryPending(reason: "after-failure")
                }
            } else {
                self.library.update(id: id, state: .delivered, error: nil)
                DayTapLog.link.info("transfer delivered \(id, privacy: .public)")
                self.setStatus("系统已送出，等 iPhone 确认保存")
                self.refreshSummary(reachable: session.isReachable, reason: "transfer-delivered")
            }
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard (userInfo[TransferKeys.kind] as? String) == TransferKeys.kindAck,
              let id = userInfo[TransferKeys.id] as? String else {
            return
        }
        DispatchQueue.main.async {
            self.clearSubmitted(id)
            self.library.update(id: id, state: .acknowledged, error: nil)
            DayTapLog.link.info("phone acked \(id, privacy: .public)")
            self.setStatus("iPhone 已保存")
            self.refreshSummary(reachable: session.isReachable, reason: "acked")
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DayTapLog.link.info("reachability \(session.isReachable)")
        DispatchQueue.main.async {
            self.retryPending(reason: "reachability")
        }
    }
}
