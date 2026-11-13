import AVFoundation
import Combine
import Foundation
import WatchConnectivity

extension Notification.Name {
    /// 手表来件被完整性守门拒收(#48):列表页 banner 可见化,不再静默。
    static let daytapTransferRejected = Notification.Name("daytap.transferRejected")
}

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

    /// 手机端正在录制的 id(#67):领养扫描跳过(在录文件不是孤儿,#66 同款闸)。
    var activePhoneRecordingID: String?

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
        // 手机端孤儿扫描(#63):索引丢失/半写场景下音频还在但条目蒸发——后台补登,
        // 与手表 reconcileOrphans 同口径(<1KB 壳删除)。冷启动不卡首帧。
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.adoptOrphanAudio()
        }
    }

    /// Documents 里索引没有的音频→补登已确认条目。
    /// 口径(#67 收紧):Documents 是 Files App 可写的共享目录,用户自己的文件不能动——
    /// 只碰 id 形如 UUID 的文件(DayTap 的命名),其余一律跳过(不领养、不删除、不上传);
    /// 在录文件(60s 内修改过或 id=在录标记)跳过;UUID 形态但打不开的崩溃残件删除(手表同口径)。
    private func adoptOrphanAudio() {
        func isOurs(_ id: String) -> Bool {
            UUID(uuidString: id)?.uuidString == id
        }
        var adopted: [RecordingRecord] = []
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: library.audioDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey]
        ) else { return }
        for url in urls where url.pathExtension.lowercased() == "m4a" {
            let id = url.deletingPathExtension().lastPathComponent
            guard isOurs(id) else { continue }  // 用户的文件:完全不动
            if library.record(id: id) != nil { continue }  // 重查,绕过陈旧快照(冷启动收件竞态)
            if id == activePhoneRecordingID { continue }
            let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey]
            )
            // 60s 内动过的文件可能在写(收件半拷贝/在录),下轮再看。
            if let modified = values?.contentModificationDate,
               Date().timeIntervalSince(modified) < 60 { continue }
            guard let size = values?.fileSize else { continue }
            guard size >= 1024 else {
                try? FileManager.default.removeItem(at: url)
                DayTapLog.library.info("purged phone shell orphan \(id, privacy: .public)")
                continue
            }
            guard let player = try? AVAudioPlayer(contentsOf: url), player.duration > 0 else {
                // UUID 形态但 moov 没写完的崩溃残件:发不上也播不了,删(手表同口径);
                // 播得了才领养——不给列表进 0 秒哑弹。
                try? FileManager.default.removeItem(at: url)
                DayTapLog.library.info("purged undecodable phone orphan \(id, privacy: .public)")
                continue
            }
            adopted.append(RecordingRecord(
                id: id,
                createdAt: values?.creationDate ?? Date(),
                durationSeconds: max(player.duration, 0),
                byteCount: size,
                state: .acknowledged,
                lastError: nil,
                updatedAt: Date()
            ))
        }
        // #67:批量一次落盘(原逐条 upsert=每条全量写索引+逐条刷列表,冷启动跳变)。
        if !adopted.isEmpty {
            library.upsertBatch(adopted)
            DayTapLog.library.info("adopted phone orphans count=\(adopted.count, privacy: .public)")
        }
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

    /// 从回收站恢复(#54):除了清 deletedAt,还要解防复活名单——否则手表重传的好件
    /// (比如来替换截断空壳的完整版)会被名单拦下+回执,原件反被这个流程删掉。
    func restore(id: String) {
        var ids = UserDefaults.standard.stringArray(forKey: Self.deletedIDsKey) ?? []
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
            UserDefaults.standard.set(ids, forKey: Self.deletedIDsKey)
            DayTapLog.link.info("unblocked deleted id \(id, privacy: .public) on restore")
        }
        library.restore(id: id)
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
        // 传输完整性守门(#48→#59 收紧):byteCount 是手表对同一文件定稿时实测,完好到达
        // 必严格相等;原 90% 阈值会放行 90–100% 截断件——m4a 的 moov 在尾部,丢 8% 同样
        // 不可播,却照样回执→手表删原件→真丢。不等一律不保存不回执,手表自动重试。
        let receivedSize = (try? FileManager.default.attributesOfItem(atPath: file.fileURL.path)[.size] as? Int) ?? 0
        // 可解码校验(#63):#58 实证「尺寸齐但 moov 没了」照样穿尺寸守门——
        // AVAudioPlayer 打不开的件按损坏拒收,手表重传。冷路径,开销无感。
        let decodable = (try? AVAudioPlayer(contentsOf: file.fileURL)) != nil
        switch TransferGate.verdict(expected: bytes, received: receivedSize, decodable: decodable) {
        case .accept:
            break
        case .rejectMismatch(let expected, let received):
            DayTapLog.library.error("truncated arrival \(id, privacy: .public) expected=\(expected, privacy: .public) got=\(received, privacy: .public); not acked")
            // 拒收必须可见(#48 修正):改走通知进列表页 banner,带应/实收数字。
            let message = "一条录音传输不完整（\(DayTapFormat.clock(duration))，应 \(DayTapFormat.bytes(expected)) 实收 \(DayTapFormat.bytes(received))）——已拒收，原件在手表会重试"
            publish(status: message, ready: true)
            NotificationCenter.default.post(name: .daytapTransferRejected, object: message)
            return
        case .dropShell:
            // <1KB 空壳(#17/#59):回执但不落库——手表清掉尾巴,不给重试留死循环。
            DayTapLog.library.error("shell arrival \(id, privacy: .public) bytes=\(bytes, privacy: .public); acked & dropped")
            session.transferUserInfo(TransferKeys.ackMetadata(id: id))
            return
        case .rejectUndecodable:
            DayTapLog.library.error("undecodable arrival \(id, privacy: .public) bytes=\(receivedSize, privacy: .public); not acked")
            let message = "一条录音传到后打不开（文件损坏，\(DayTapFormat.clock(duration))）——已拒收，原件在手表会重试"
            publish(status: message, ready: true)
            NotificationCenter.default.post(name: .daytapTransferRejected, object: message)
            return
        }
        // 让位(#48 收尾→#59 收紧为不等即让):完好的来件若撞上尺寸对不上的既有副本
        // (截断坏壳/陈旧残件),importAudio 的「目标存在即跳过复制」会保壳拒新、照回执——
        // 手表删原件,好数据被空壳吃掉。让位后好件落位,同 id 行原地痊愈。
        let destination = library.fileURL(id: id)
        if let existing = try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int,
           existing != bytes {
            try? FileManager.default.removeItem(at: destination)
            DayTapLog.library.info("cleared mismatched copy \(id, privacy: .public) (\(existing, privacy: .public)B) for good arrival")
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

    /// 对账裁决(#49):手表报来的未确认条目,按实际落盘情况逐条回答。
    /// 裁决口径与收件守门(#48)一致:文件在且 ≥ 手表实测的 90% = 已有,否则要重传
    /// (含「索引有但文件是截断坏副本」——让它重传好件来覆盖)。
    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard (message[TransferKeys.kind] as? String) == TransferKeys.kindReconcile,
              let items = message[TransferKeys.items] as? [[String: Any]]
        else {
            replyHandler([:])
            return
        }
        var acked: [String] = []
        var resend: [String] = []
        for item in items {
            guard let id = item[TransferKeys.id] as? String else { continue }
            let expected = TransferKeys.doubleValue(item[TransferKeys.byteCount])
            let url = library.fileURL(id: id)
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Double) ?? 0
            // #59/#63:尺寸齐还要打得开——本地副本若已损坏,裁成「已有」会让手表删原件。
            // #67:尺寸不符直接短路不解码——原实现对每条 pending 都开一次 AVAudioPlayer,
            // 几十条×18MB 长录会把 WCSession 串行回调队列卡住秒级。
            let sizeMatches = library.record(id: id) != nil
                && FileManager.default.fileExists(atPath: url.path)
                && fileSize == expected
            let decodable = sizeMatches && (try? AVAudioPlayer(contentsOf: url)) != nil
            let intact = TransferGate.intact(
                indexed: library.record(id: id) != nil,
                fileExists: FileManager.default.fileExists(atPath: url.path),
                expected: expected,
                fileSize: fileSize,
                decodable: decodable
            )
            if intact {
                acked.append(id)
            } else {
                resend.append(id)
            }
        }
        DayTapLog.link.info("reconcile verdict acked=\(acked.count, privacy: .public) resend=\(resend.count, privacy: .public)")
        replyHandler([
            TransferKeys.acked: acked,
            TransferKeys.resend: resend
        ])
    }
}
