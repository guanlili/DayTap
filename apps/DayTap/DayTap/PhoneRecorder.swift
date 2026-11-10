import AVFoundation
import Combine
import Foundation

/// 手机端直接录音(#3):复用手表的 AudioCapture 出 m4a,
/// 停止走 importAudio 入口,与手表传来的录音同库同列表混排(origin="phone" 标来源)。
/// 仅前台:手机 App 不开 UIBackgroundModes,退后台由界面层停录保存(与手表同口径)。
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
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("daytap-phone-\(id).m4a")
            do {
                try capture.start(fileURL: url)
            } catch {
                statusText = error.localizedDescription
                DayTapLog.recorder.error("phone start failed \(error.localizedDescription, privacy: .public)")
                return
            }
            recordingID = id
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
    private func finish() {
        let duration = capture.stop() ?? elapsed
        stopTimer()
        let id = recordingID
        let beganAt = startedAt
        isRecording = false
        recordingID = nil
        startedAt = nil
        guard let id, let beganAt else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("daytap-phone-\(id).m4a")
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
        // 录进文稿目录、按真实落盘大小覆盖 byteCount、状态置已确认——手表收件走的是同一扇门。
        library.importAudio(from: url, record: record)
        try? FileManager.default.removeItem(at: url)
        statusText = nil
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
                self.level = self.capture.currentLevel()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
