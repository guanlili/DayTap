import AVFoundation
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

    /// 已删除录音的 id 名单(#20)。手表可能还握着「传输未完成」的尾巴,
    /// 重传到这里时直接回执丢弃,不让删掉的条目复活。UserDefaults 重装即清,
    /// 但那时手表侧早已确认,本就不会再传。
    private static let deletedIDsKey = "daytap.deletedIDs"
    private static let deletedIDsCap = 200

    private override init() {
        library = RecordingLibrary(
            audioDirectory: DayTapFolders.documents,
            indexURL: DayTapFolders.appSupport.appendingPathComponent("index.json")
        )
        super.init()
        // 回收站到期清扫(#26):30 天前的软删条目连文件一起真正清掉。
        library.purgeExpiredDeleted(retention: 30 * 24 * 3600)
        // #44:存量空时长异常(手表传过 33KB/0s 案)——按音频文件实测时长修复,只修有真实音频的。
        repairZeroDurations()
    }

    /// #44:durations <1s 但音频文件在且可读的,用 AVAudioPlayer 实测时长回填。
    /// 与 importAudio 的入口兜底同口径,这里管的是已经进过库的存量。
    private func repairZeroDurations() {
        for record in library.snapshot() where record.durationSeconds < 1 {
            let url = library.fileURL(id: record.id)
            guard record.byteCount >= 1024,
                  FileManager.default.fileExists(atPath: url.path),
                  let player = try? AVAudioPlayer(contentsOf: url),
                  player.duration > 1,
                  var fresh = library.record(id: record.id)
            else { continue }
            fresh.durationSeconds = player.duration
            fresh.updatedAt = Date()
            library.upsert(fresh)
            DayTapLog.library.info("repaired duration \(record.id, privacy: .public) -> \(Int(player.duration), privacy: .public)s")
        }
    }

    /// 手机端删除入口(#20→#26):先记防复活名单,再软删进「最近删除」(30 天可恢复)。
    func forget(id: String) {
        var ids = UserDefaults.standard.stringArray(forKey: Self.deletedIDsKey) ?? []
        if !ids.contains(id) {
            ids.append(id)
            if ids.count > Self.deletedIDsCap {
                ids.removeFirst(ids.count - Self.deletedIDsCap)
            }
            UserDefaults.standard.set(ids, forKey: Self.deletedIDsKey)
        }
        library.softDelete(id: id)
    }

    /// 彻底删除(#26):回收站里手动清掉,索引+文件一并删(防复活名单在 forget 时已记)。
    func purgeNow(id: String) {
        library.remove(id: id)
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
        // 删过的条目不复活(#20):回执让手表停止重传,收到的这份系统自己清掉。
        if let deleted = UserDefaults.standard.stringArray(forKey: Self.deletedIDsKey),
           deleted.contains(id) {
            session.transferUserInfo(TransferKeys.ackMetadata(id: id))
            DayTapLog.link.info("dropped deleted recording \(id, privacy: .public); acked")
            return
        }
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
        // 传输完整性守门(#48):手表元数据里的 byteCount 是保存时实测的真实大小;
        // 实收明显偏小=过河被截断(实测 28B 空壳与 470KB/18MB 半截两类)。
        // 不保存也不回执——之前收到就回执,手表按回执删原件,截断即数据真丢。
        let receivedSize = (try? FileManager.default.attributesOfItem(atPath: file.fileURL.path)[.size] as? Int) ?? 0
        if bytes >= 1024, receivedSize < bytes * 9 / 10 {
            DayTapLog.library.error("truncated arrival \(id, privacy: .public) expected=\(bytes, privacy: .public) got=\(receivedSize, privacy: .public); not acked")
            // 之前落下的坏副本要清位:importAudio 见目标存在会跳过复制,坏文件会永远挡住重传。
            let destination = library.fileURL(id: id)
            if let existing = try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int,
               existing < bytes * 9 / 10 {
                try? FileManager.default.removeItem(at: destination)
            }
            publish(status: "收到一条不完整的录音（应 \(bytes) 实收 \(receivedSize)），已拒收等手表重传", ready: true)
            return
        }
        let saved = library.importAudio(from: file.fileURL, record: record)
        if saved {
            session.transferUserInfo(TransferKeys.ackMetadata(id: id))
            DayTapLog.link.info("acked \(id, privacy: .public)")
            publish(status: "刚收到一条手表录音", ready: true)
            // 通知转写中心试清自动队列(#29)。
            NotificationCenter.default.post(name: .daytapRecordImported, object: nil)
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
