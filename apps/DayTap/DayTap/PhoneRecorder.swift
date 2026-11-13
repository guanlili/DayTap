import AVFoundation
import Combine
import Foundation

/// 手机端直接录音(#3):复用手表的 AudioCapture 出 m4a,
/// 停止走 importAudio 入口,与手表传来的录音同库同列表混排(origin="phone" 标来源)。
/// #64 起 audio 后台模式已开:退后台/锁屏续录(与手表、语音备忘录同口径),停录只由用户触发。
@MainActor
final class PhoneRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var permissionDenied = false
    @Published var statusText: String?

    private let capture = AudioCapture()
    private let library = PhoneLink.shared.library
    private var timer: Timer?
    private var startedAt: Date?
    private var recordingID: String?
    private var interruptionObserver: NSObjectProtocol?

    init() {
        // 来电/闹钟抢麦克风时,系统会停掉录音器——主动收尾入库,
        // 不让计时器空转误导(#28,同手表 handleInterruption 口径)。
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                guard raw == nil || raw == AVAudioSession.InterruptionType.began.rawValue else { return }
                self.finish(reason: "录音被打断，已保存")
            }
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    /// 底栏红钮:闲→开录,录→停存。与手表 toggle() 同语义。
    func toggle() {
        if isRecording {
            finish()
        } else {
            begin()
        }
    }

    private func begin() {
        let start = { [weak self] in
            guard let self else { return }
            let id = UUID().uuidString
            // #67:直写库目录(原写 tmp,App 被杀=moov 未写+内存态全丢,整条蒸发无兜底)。
            // 库内文件崩溃后走孤儿回收口径;在录期间由 PhoneLink.activePhoneRecordingID
            // 挡住领养(#66 同款闸)。
            let url = library.fileURL(id: id)
            do {
                try capture.start(fileURL: url)
            } catch {
                statusText = error.localizedDescription
                DayTapLog.recorder.error("phone start failed \(error.localizedDescription, privacy: .public)")
                return
            }
            recordingID = id
            PhoneLink.shared.activePhoneRecordingID = id
            startedAt = Date()
            elapsed = 0
            level = 0
            isRecording = true
            permissionDenied = false
            startTimer()
        }

        switch capture.permissionState() {
        case .granted:
            start()
        case .denied:
            permissionDenied = true
            statusText = "请在 iPhone 设置里允许 DayTap 使用麦克风"
        case .undetermined:
            capture.requestPermission { [weak self] granted in
                guard let self else { return }
                if granted {
                    permissionDenied = false
                    start()
                } else {
                    permissionDenied = true
                    statusText = "没有麦克风权限,没法录"
                }
            }
        @unknown default:
            break
        }
    }

    /// 停录入库;空壳(<1KB 容器头)直接丢弃,口径同手表(#17)。
    /// reason 非空=被打断等异常收尾,界面留一句说明(#28)。
    private func finish(reason: String? = nil) {
        let duration = capture.stop() ?? elapsed
        stopTimer()
        let id = recordingID
        let beganAt = startedAt
        isRecording = false
        recordingID = nil
        PhoneLink.shared.activePhoneRecordingID = nil
        startedAt = nil
        statusText = reason
        guard let id, let beganAt else { return }

        let url = library.fileURL(id: id)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size >= 1024 else {
            try? FileManager.default.removeItem(at: url)
            statusText = "录音是空的,没有保存"
            DayTapLog.recorder.error("phone empty recording \(id, privacy: .public) size=\(size)")
            return
        }

        var record = RecordingRecord(
            id: id,
            createdAt: beganAt,
            durationSeconds: duration,
            byteCount: size,
            state: .acknowledged,
            lastError: nil,
            updatedAt: Date()
        )
        record.origin = "phone"
        // 文件已在库位:importAudio 走「目标存在跳过复制」分支,只做时长兜底+入库+索引落盘校验。
        library.importAudio(from: url, record: record)
        statusText = reason
        // 通知转写中心试清自动队列(#29)。
        NotificationCenter.default.post(name: .daytapRecordImported, object: nil)
    }

    private func startTimer() {
        timer?.invalidate()
        // #67:.common mode——录音中滚动列表时(default mode 暂停)计时/音量不停走。
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording, let startedAt = self.startedAt else { return }
                // #67 心跳兜底:任何外因把录音器掐死(类别被切/系统抢麦,不触发中断通知),
                // 主动收尾保存——对齐手表 onActive 口径,计时器不再空转骗人。
                if !self.capture.isRecording {
                    self.finish(reason: "录音被系统停下，已保存")
                    return
                }
                self.elapsed = Date().timeIntervalSince(startedAt)
                self.level = self.capture.currentLevel()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
