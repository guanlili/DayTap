import Combine
import Foundation
import WatchConnectivity

/// iPhone 侧接收手表文件。
/// 系统可能在后台把 App 唤醒后立刻调用 `didReceive`。委托必须在启动时就挂上。
/// 回调返回前要把文件拷走：系统随后会删掉收件箱里的那份临时文件。
final class PhoneLink: NSObject, ObservableObject {
    static let shared = PhoneLink()

    /// 音频直接放在「文稿」目录，打开「文件 → 我的 iPhone → DayTap」就能看见。
    /// 索引放在 Application Support，不出现在文件 App 里。
    let library: RecordingLibrary

    @Published private(set) var status = "等手表把录音传过来"
    @Published private(set) var sessionReady = false

    private override init() {
        library = RecordingLibrary(
            audioDirectory: DayTapFolders.documents,
            indexURL: DayTapFolders.appSupport.appendingPathComponent("index.json")
        )
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else {
            publish(status: "这台 iPhone 不支持与手表连接", ready: false)
            DayTapLog.link.error("WCSession not supported on iPhone")
            return
        }
        let session = WCSession.default
        session.delegate = self
        if session.activationState != .activated {
            session.activate()
        } else {
            publish(status: readyStatus(session), ready: true)
        }
        DayTapLog.link.info("iPhone WCSession activate requested")
    }

    /// 分享时复制一份带名字的文件名，避免得到里只看到一长串 UUID。起了名跟名字走(#2)。
    func shareFileURL(for record: RecordingRecord) -> URL? {
        let source = library.fileURL(id: record.id)
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                DayTapFormat.shareFilename(name: record.displayName, createdAt: record.createdAt)
            )
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            DayTapLog.library.error("share copy failed \(error.localizedDescription, privacy: .public)")
            return source
        }
    }

    private func publish(status: String, ready: Bool) {
        let apply = {
            self.status = status
            self.sessionReady = ready
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    private func readyStatus(_ session: WCSession) -> String {
        if session.isPaired == false {
            return "没有配对的 Apple Watch"
        }
        if session.isWatchAppInstalled == false {
            return "手表上还没有 DayTap。用 Xcode 装到配对的手表后再录。"
        }
        return "手表通道已就绪。录音结束且表在身边时，文件会出现在下面。"
    }
}

extension PhoneLink: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        if let error {
            DayTapLog.link.error("iPhone activation failed \(error.localizedDescription, privacy: .public)")
            publish(status: "连接手表失败：\(error.localizedDescription)", ready: false)
            return
        }
        DayTapLog.link.info("iPhone activation state=\(activationState.rawValue)")
        publish(status: readyStatus(session), ready: activationState == .activated)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        DayTapLog.link.info("session inactive")
    }

    func sessionDidDeactivate(_ session: WCSession) {
        // 换了一只配对手表时，系统要求重新激活。
        session.activate()
        DayTapLog.link.info("session deactivated; activating again")
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadata = file.metadata ?? [:]
        let id = TransferKeys.recordID(from: metadata)
        let createdAt = TransferKeys.dateValue(metadata[TransferKeys.createdAt]) ?? Date()
        let duration = TransferKeys.doubleValue(metadata[TransferKeys.durationSeconds])
        let bytes = Int(TransferKeys.doubleValue(metadata[TransferKeys.byteCount]))
        let record = RecordingRecord(
            id: id,
            createdAt: createdAt,
            durationSeconds: duration,
            byteCount: bytes,
            state: .delivered,
            lastError: nil,
            updatedAt: Date()
        )
        let saved = library.importAudio(from: file.fileURL, record: record)
        if saved {
            session.transferUserInfo(TransferKeys.ackMetadata(id: id))
            DayTapLog.link.info("acked \(id, privacy: .public)")
            publish(status: "刚收到一条手表录音", ready: true)
        } else {
            // 不回执。手表仍保留原文件，下次会再传。临时收件箱里的这份系统会自己删。
            DayTapLog.link.error("did not ack \(id, privacy: .public); watch will retry")
            publish(status: "收到文件但没能保存，手表会再传一次", ready: true)
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DayTapLog.link.info("iPhone saw reachability \(session.isReachable)")
    }
}
