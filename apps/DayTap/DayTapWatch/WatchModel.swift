import AVFoundation
import Combine
import Foundation
import WatchKit

/// 表上那块「表盘」背后的状态。界面只跟它说话。
/// 所有方法都从主线程调用(按钮、计时器、场景变化、AppIntent)。
///
/// 演进记录:#5 首版做过「进入即武装 + VAD 人声自动开录」(含 3-5 分钟滚动缓冲)。
/// 2026-11-10 甲方真机体验后定夺撤下:环境音误触太容易(模拟器验证时已见端倪),
/// 改回**手动触发**(点按/握拳),但保留 #5 的核心收益——audio 后台模式,录着回表盘继续。
/// VAD 与滚动缓冲的实现(见 AudioCapture.startBuffer/promote)留在代码里备 v2 调参后回归。
final class WatchModel: ObservableObject {
    /// AppIntent 与界面共用同一个实例,握拳和点屏幕操作的是同一台状态机。
    static let shared = WatchModel()

    enum Phase: Equatable {
        case idle
        case recording
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published var status = ""
    /// 传输通道的一句话状态(待传/送出/已确认),闲时小字展示。
    @Published private(set) var linkStatus = ""
    /// 传输计数(#4):待 iPhone 确认 / 失败条数,闲时角标。
    @Published private(set) var transferWaiting = 0
    @Published private(set) var transferFailed = 0
    /// 待传占用(#22):还没传出去的录音在手表上共占多少,角标顺带显示。
    @Published private(set) var transferBytes = 0
    /// 最近一条失败的短原因(有失败才非 nil),角标下小字。
    @Published private(set) var transferError: String?
    @Published private(set) var permissionDenied = false

    var isRecording: Bool { phase == .recording }

    private let capture = AudioCapture()
    private let link = WatchLink.shared
    /// 敲桌两下检测(#11):只在闲时前台开,回表盘/录音中即停。
    private let knock = KnockDetector()
    private var timer: Timer?
    private var startedAt: Date?
    private var recordingID: String?
    private var interruptionObserver: NSObjectProtocol?

    private init() {
        link.onChange = { [weak self] in
            self?.syncTransferState()
        }
        // 敲桌命中=点按:闲时开录。onTrigger 已派发主线程。
        knock.onTrigger = { [weak self] in
            guard let self, phase == .idle else { return }
            DayTapLog.motion.info("knock → begin")
            toggle()
        }
        linkStatus = link.statusText
        syncTransferState()
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
        case .undetermined:
            permissionDenied = false
        @unknown default:
            permissionDenied = false
        }
        link.activate()
    }

    /// 回到前台:补传没送完的文件;录音状态与采集层对不上时收尾。
    func onActive() {
        link.retryPending(reason: "foreground")
        if phase == .recording, !capture.isRecording {
            finish(reason: "录音被系统停下,已保存并排队")
        }
    }

    /// 全屏点按 / 握拳快捷指令共用:闲→开录,录→停存传出。
    func toggle() {
        if phase == .recording {
            finish(reason: nil)
        } else {
            begin()
        }
    }

    /// 敲桌监听开关(#11):界面按「闲时且在前台」驱动;录音中与回表盘都不听。
    func setKnockListening(_ active: Bool) {
        if active {
            guard phase == .idle, !knock.isRunning else { return }
            knock.start()
        } else {
            knock.stop()
        }
    }

    /// 再交一次还没被 iPhone 确认的文件。不开麦。
    /// #4:点击必给触觉 + 结果文案,不再让点了像没反应。
    func retry() {
        link.activate()
        let result = link.retryPending(reason: "manual")
        syncTransferState()
        WKInterfaceDevice.current().play(.click)
        if result.failed > 0 {
            status = "有 \(result.failed) 条没传出,靠近 iPhone 会自动重试"
        } else if result.waiting > 0 {
            status = result.submitted > 0
                ? "已交 \(result.submitted) 条,共 \(result.waiting) 条等 iPhone 确认"
                : "没有新的要交,\(result.waiting) 条仍在队列里"
        } else {
            status = "没有要重传的,iPhone 都已确认"
        }
    }

    /// 从链路层同步一行状态与计数到发布属性。
    private func syncTransferState() {
        linkStatus = link.statusText
        transferWaiting = link.waitingCount
        transferFailed = link.failedCount
        transferError = link.library.snapshot()
            .first { $0.state == .failed && $0.lastError != nil }?
            .lastError
        transferBytes = link.library.snapshot()
            .filter(\.awaitsPhoneAck)
            .reduce(0) { $0 + $1.byteCount }
    }

    /// 丢弃全部待传(#22):录了不想传的,表上直接清掉。触觉+文案给明确反馈。
    func discardPending() {
        let count = link.discardPending()
        WKInterfaceDevice.current().play(count > 0 ? .success : .click)
        status = count > 0 ? "已丢弃 \(count) 条,不传 iPhone" : "没有待传的录音"
        syncTransferState()
    }

    /// AppIntent 专用:录错了直接丢弃这一条(不保存不传出),静默回闲。
    func discardFromIntent() {
        guard phase == .recording else { return }
        let id = recordingID
        _ = capture.stop()
        stopTimer()
        if let id {
            try? FileManager.default.removeItem(at: link.library.fileURL(id: id))
        }
        phase = .idle
        recordingID = nil
        startedAt = nil
        WKInterfaceDevice.current().play(.stop)
        status = "已丢弃,点一下重新开始"
        DayTapLog.recorder.info("discarded \(id ?? "-", privacy: .public)")
    }

    // MARK: - 手动录音

    private func begin() {
        let start = { [weak self] in
            guard let self else { return }
            let id = UUID().uuidString
            let url = self.link.library.fileURL(id: id)
            do {
                try self.capture.start(fileURL: url)
            } catch {
                self.status = error.localizedDescription
                DayTapLog.recorder.error("start failed \(error.localizedDescription, privacy: .public)")
                try? FileManager.default.removeItem(at: url)
                return
            }
            self.recordingID = id
            self.startedAt = Date()
            self.elapsed = 0
            self.level = 0
            self.phase = .recording
            self.permissionDenied = false
            // #24:录音态界面(红点/计时/音量条/停止键)自解释,不再配说明文案。
            WKInterfaceDevice.current().play(.start)
            self.startTimer()
        }

        switch capture.permissionState() {
        case .granted:
            start()
        case .denied:
            permissionDenied = true
            status = "请在手表设置里允许 DayTap 使用麦克风"
        case .undetermined:
            capture.requestPermission { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.permissionDenied = false
                    start()
                } else {
                    self.permissionDenied = true
                    self.status = "没有麦克风权限,没法录"
                }
            }
        @unknown default:
            break
        }
    }

    /// 停止、入库、排队传 iPhone。录完回闲,等待下一次手动开始。
    private func finish(reason: String?) {
        let duration = capture.stop() ?? elapsed
        stopTimer()
        let id = recordingID
        let startedAt = startedAt
        phase = .idle
        recordingID = nil
        self.startedAt = nil
        WKInterfaceDevice.current().play(.stop)

        guard let id, let startedAt else {
            status = "没有可发送的录音"
            return
        }
        let url = link.library.fileURL(id: id)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // 48kbps AAC 下一秒音频就有约 6KB;不到 1KB 的必然是只有容器头的空壳
        // (prepareToRecord 先写好 28 字节头,帧没落盘时 size>0 检查放过了它,
        // 真机上出现过录了 16 秒只有 28 字节的空文件,传到 iPhone 后试听打不开)。
        guard size >= 1024 else {
            try? FileManager.default.removeItem(at: url)
            status = "录音是空的,没有发送"
            DayTapLog.recorder.error("empty recording \(id, privacy: .public) size=\(size)")
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
        // 常规保存不留文案——排队状态由角标/状态句说;只有被打断这类异常才说一句(#24)。
        status = reason ?? ""
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
        guard phase == .recording, let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
    }

    /// 来电、Siri、闹钟会抢麦克风。录着就结束保存,不偷偷续录。
    private func handleInterruption(_ note: Notification) {
        let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
        let began = raw == nil || raw == AVAudioSession.InterruptionType.began.rawValue
        guard began else { return }
        if phase == .recording {
            DayTapLog.recorder.info("interrupted, saving take")
            finish(reason: "录音被打断,已保存并排队传到 iPhone")
        }
    }
}
