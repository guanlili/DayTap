import Foundation
import WatchConnectivity

/// 一次重传的口径结果,给「再传一次」做明确反馈(#4):点了之后到底发生了什么。
struct RetryResult {
    /// 这次实际重新交给系统队列的条数。
    let submitted: Int
    /// 仍未被 iPhone 确认的条数(含系统队列中)。
    let waiting: Int
    /// 标记失败的条数。
    let failed: Int
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

    /// 传输计数(#4 闲时角标):待 iPhone 确认的条数与失败条数。只在主线程改。
    private(set) var waitingCount = 0
    private(set) var failedCount = 0

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
    /// 返回口径结果(#4):调用方据此给触觉与明确文案,不再让点击像没反应。
    @discardableResult
    func retryPending(reason: String) -> RetryResult {
        guard WCSession.isSupported() else {
            return RetryResult(submitted: 0, waiting: waitingCount, failed: failedCount)
        }
        let session = WCSession.default
        guard session.activationState == .activated else {
            setStatus("正在连接 iPhone…")
            return RetryResult(submitted: 0, waiting: waitingCount, failed: failedCount)
        }

        reconcileOrphans()
        purgeSettled()

        let outstanding = Set(session.outstandingFileTransfers.compactMap { transfer -> String? in
            transfer.file.metadata?[TransferKeys.id] as? String
        })

        var submitted = 0
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
            submitted += 1
        }
        refreshSummary(reachable: session.isReachable, reason: reason)
        return RetryResult(submitted: submitted, waiting: waitingCount, failed: failedCount)
    }

    func enqueue(id: String) {
        guard let record = library.record(id: id) else { return }
        enqueue(record)
        if WCSession.isSupported() {
            refreshSummary(reachable: WCSession.default.isReachable, reason: "new-recording")
        }
    }

    /// 丢弃全部待传(#22):录了不想传的,直接在表上清掉——本地文件、索引、
    /// 系统队列里还没送出的 transfer 一并撤。已确认的本就不在表上(确认即删)。
    /// 已知边界:刚送出还在途的(didFinish 已回)无法撤回,极端竞态下 iPhone 仍可能收到。
    @discardableResult
    func discardPending() -> Int {
        guard WCSession.isSupported() else { return 0 }
        let session = WCSession.default
        for transfer in session.outstandingFileTransfers {
            transfer.cancel()
        }
        let pending = library.snapshot().filter(\.awaitsPhoneAck)
        for record in pending {
            clearSubmitted(record.id)
            library.remove(id: record.id)
        }
        DayTapLog.link.info("discarded pending count=\(pending.count, privacy: .public)")
        refreshSummary(reachable: session.isReachable, reason: "discard-pending")
        return pending.count
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

    /// 清理已落定的本地记录(#21 方案A):
    /// ① iPhone 已确认的——原件与索引一并清,手表只当采集器,存储不随时间膨胀
    ///   (旧版本只标记不删,这里顺带清历史积压);
    /// ② 失败且文件已不存在的死条目——永远传不走,留着只会一直挂在角标里。
    /// 底线不动:只要文件还在且未被确认(待传/队列/失败),就保留等待重传。
    private func purgeSettled() {
        let settled = library.snapshot().filter { record in
            if record.state == .acknowledged { return true }
            if record.state == .failed,
               !FileManager.default.fileExists(atPath: library.fileURL(id: record.id).path) {
                return true
            }
            return false
        }
        guard !settled.isEmpty else { return }
        for record in settled {
            library.remove(id: record.id)
        }
        DayTapLog.link.info("purged settled count=\(settled.count, privacy: .public)")
    }

    /// 崩溃或被系统杀掉时，目录里可能有 m4a 但索引没有。补一条待传记录。
    private func reconcileOrphans() {        let folder = library.audioDirectory
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
        let waiting = records.filter(\.awaitsPhoneAck).count
        let failed = records.filter { $0.state == .failed }.count
        waitingCount = waiting
        failedCount = failed
        let line: String
        if failed > 0 {
            line = "有 \(failed) 条没传出。靠近 iPhone 后会重试。"
        } else if waiting > 0 {
            if reachable {
                line = "正在传给 iPhone（\(waiting) 条）"
            } else {
                line = "iPhone 不在身边也没关系，已排队 \(waiting) 条"
            }
        } else if records.isEmpty {
            line = "结束后音频传到配对的 iPhone"
        } else {
            line = "iPhone 已保存最近一条"
        }
        DayTapLog.link.debug("summary \(reason, privacy: .public)")
        setStatus(line)
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self.retryPending(reason: "after-failure")
                }
            } else {
                self.library.update(id: id, state: .delivered, error: nil)
                DayTapLog.link.info("transfer delivered \(id, privacy: .public)")
                self.setStatus("系统已送出，等 iPhone 确认保存")
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
            // 确认即删(#21 方案A):手机已落盘并回执,原件在手表上不再保留。
            self.library.remove(id: id)
            DayTapLog.link.info("phone acked \(id, privacy: .public); purged on watch")
            self.setStatus("iPhone 已保存")
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DayTapLog.link.info("reachability \(session.isReachable)")
        DispatchQueue.main.async {
            self.retryPending(reason: "reachability")
        }
    }
}
