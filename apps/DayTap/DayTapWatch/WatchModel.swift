import AVFoundation
import Combine
import Foundation
import WatchKit

/// 无感模式的判定参数(#5):阈值从宽、宁早勿晚,误触发只是多录几秒环境音,漏触发才是事故。
enum StealthTuning {
    /// 人声判定阈值(0...1,来自 AudioCapture.currentLevel)。
    static let voiceLevel: Float = 0.32
    /// 高于阈值持续多久判定「有人说话了」。
    static let voiceHold: TimeInterval = 0.8
    /// 迟滞下限:低于它才重置持续时间,防止在阈值附近抖动。
    static let voiceDrop: Float = 0.22
    /// 武装多久没等到人声就自动解除(省电,也避免忘了关麦)。
    static let armedTimeout: TimeInterval = 600
}

/// 表盘上那一个界面背后的状态。界面只跟它说话。
/// 所有方法都从主线程调用(按钮、计时器、场景变化、AppIntent)。
final class WatchModel: ObservableObject {
    /// AppIntent 与界面共用同一个实例,握拳和点屏幕操作的是同一台状态机。
    static let shared = WatchModel()

    enum Phase: Equatable {
        case idle
        case armed
        case recording
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published var status = "抬腕即武装,有人说话自动录"
    /// 传输通道的一句话状态(待传/送出/已确认),无感界面在闲时小字展示。
    @Published private(set) var linkStatus = ""
    @Published private(set) var permissionDenied = false

    var isRecording: Bool { phase == .recording }

    private let capture = AudioCapture()
    private let link = WatchLink.shared
    private var timer: Timer?
    /// 武装时刻:缓冲文件的起点,也是最终录音的 createdAt。
    private var armedAt: Date?
    private var recordingID: String?
    private var voiceSince: Date?
    private var interruptionObserver: NSObjectProtocol?

    private init() {
        link.onChange = { [weak self] in
            self?.linkStatus = self?.link.statusText ?? ""
        }
        linkStatus = link.statusText
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    func onAppear() {
        switch capture.permissionState() {
        case .denied:
            permissionDenied = true
            status = "需要麦克风权限"
        case .granted:
            permissionDenied = false
            armIfIdle()
        case .undetermined:
            permissionDenied = false
        @unknown default:
            permissionDenied = false
        }
        link.activate()
    }

    /// 回到前台:补传没送完的文件;状态对不上的收尾;闲着就重新武装。
    func onActive() {
        link.retryPending(reason: "foreground")
        if phase == .recording, !capture.isRecording {
            // 系统把录音停掉了,但状态还停在录。把已有内容送出去。
            finish(reason: "录音被系统停下,已保存并排队")
        } else if phase == .idle, capture.permissionState() == .granted {
            armIfIdle()
        }
    }

    /// 全屏点按 / 握拳快捷指令共用的一条龙切换:
    /// 闲 → 武装;武装 → 立刻开录(不等 VAD);录 → 停止保存并传出。
    func toggle() {
        switch phase {
        case .idle:
            armIfIdle()
        case .armed:
            commit()
        case .recording:
            finish(reason: nil)
        }
    }

    /// 再交一次还没被 iPhone 确认的文件。不重新开麦。
    func retry() {
        link.activate()
        link.retryPending(reason: "manual")
    }

    /// AppIntent 专用:想安静退出时,录音中的照常保存,武装中的直接解除不保存。
    func disarmFromIntent() {
        switch phase {
        case .recording:
            finish(reason: nil)
        case .armed:
            disarm(reason: "已解除无感模式")
        case .idle:
            break
        }
    }

    // MARK: - 武装

    private func armIfIdle() {
        guard phase == .idle else { return }
        let arm = { [weak self] in
            guard let self else { return }
            do {
                try self.capture.startBuffer()
            } catch {
                self.status = error.localizedDescription
                DayTapLog.recorder.error("arm failed \(error.localizedDescription, privacy: .public)")
                return
            }
            self.armedAt = Date()
            self.voiceSince = nil
            self.phase = .armed
            self.status = "已武装·听到说话自动录"
            self.startTimer()
        }

        switch capture.permissionState() {
        case .granted:
            arm()
        case .denied:
            permissionDenied = true
            status = "请在手表设置里允许 DayTap 使用麦克风"
        case .undetermined:
            capture.requestPermission { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.permissionDenied = false
                    arm()
                } else {
                    self.permissionDenied = true
                    self.status = "没有麦克风权限,没法录"
                }
            }
        @unknown default:
            break
        }
    }

    /// 武装解除:缓冲从未被晋级,整个丢弃,不留痕迹。
    private func disarm(reason: String) {
        _ = capture.stop()
        stopTimer()
        phase = .idle
        armedAt = nil
        voiceSince = nil
        status = reason
        DayTapLog.recorder.info("disarmed: \(reason, privacy: .public)")
    }

    /// VAD 命中或手动确认:把带着缓冲头的临时文件改名进曲库,录音无缝继续。
    private func commit() {
        let id = UUID().uuidString
        do {
            try capture.promote(to: link.library.fileURL(id: id))
        } catch {
            DayTapLog.recorder.error("promote failed \(error.localizedDescription, privacy: .public)")
            disarm(reason: "开录失败,已重新武装")
            armIfIdle()
            return
        }
        recordingID = id
        voiceSince = nil
        phase = .recording
        WKInterfaceDevice.current().play(.start)
        status = "正在录·点按或握拳停止"
        DayTapLog.recorder.info("stealth commit \(id, privacy: .public)")
    }

    /// 停止、入库、排队传 iPhone。收尾后立刻重新武装,支持一场会里连续多段录音。
    private func finish(reason: String?) {
        let duration = capture.stop() ?? elapsed
        stopTimer()
        let id = recordingID
        let startedAt = armedAt
        phase = .idle
        recordingID = nil
        armedAt = nil
        voiceSince = nil
        WKInterfaceDevice.current().play(.stop)

        guard let id, let startedAt else {
            status = "没有可发送的录音"
            armIfIdle()
            return
        }
        let url = link.library.fileURL(id: id)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else {
            try? FileManager.default.removeItem(at: url)
            status = "录音是空的,没有发送"
            DayTapLog.recorder.error("empty recording \(id, privacy: .public)")
            armIfIdle()
            return
        }
        let record = RecordingRecord(
            id: id,
            createdAt: startedAt,
            durationSeconds: duration,
            byteCount: size,
            state: .pending,
            lastError: nil,
            updatedAt: Date()
        )
        link.library.upsert(record)
        link.enqueue(id: id)
        status = reason ?? "已保存,正在传给 iPhone"
        armIfIdle()
    }

    // MARK: - 心跳

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        level = capture.currentLevel()
        guard phase != .idle, let armedAt else { return }
        elapsed = Date().timeIntervalSince(armedAt)

        guard phase == .armed else { return }
        // VAD:高于阈值并保持住才算人声;边界抖动用迟滞吸收。
        if level >= StealthTuning.voiceLevel {
            if voiceSince == nil {
                voiceSince = Date()
            } else if Date().timeIntervalSince(voiceSince ?? Date()) >= StealthTuning.voiceHold {
                commit()
                return
            }
        } else if level < StealthTuning.voiceDrop {
            voiceSince = nil
        }
        if elapsed > StealthTuning.armedTimeout {
            disarm(reason: "久候无人声,已静默解除")
        }
    }

    /// 来电、Siri、闹钟会抢麦克风。录着就结束保存,武装着就解除,不偷偷续录。
    private func handleInterruption(_ note: Notification) {
        let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
        let began = raw == nil || raw == AVAudioSession.InterruptionType.began.rawValue
        guard began else { return }
        switch phase {
        case .recording:
            DayTapLog.recorder.info("interrupted, saving take")
            finish(reason: "录音被打断,已保存并排队传到 iPhone")
        case .armed:
            disarm(reason: "麦克风被占用,武装已解除")
        case .idle:
            break
        }
    }
}
