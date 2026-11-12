import AVFoundation
import Foundation

/// 手表前台录音。
/// 使用 `AVAudioRecorder` 写成单声道 AAC `.m4a`，方便 iPhone 分享给飞书妙记或得到大脑。
/// 不使用延长运行会话：那些会话类型对不上「上一节课」，滥用有审核风险。屏幕熄灭或回到后台时由界面层停止并保存。
final class AudioCapture {
    private var recorder: AVAudioRecorder?
    private(set) var fileURL: URL?
    /// 武装态：录音器实际写着的临时缓冲文件（不在曲库目录，解除武装即删）。
    private(set) var bufferURL: URL?

    var isRecording: Bool {
        recorder?.isRecording ?? false
    }

    func permissionState() -> AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    func requestPermission(completion: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                DayTapLog.recorder.info("microphone permission granted=\(granted)")
                completion(granted)
            }
        }
    }

    func start(fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let session = AVAudioSession.sharedInstance()
        // 先试只录音。个别系统拒绝 `.record` 时退回 `.playAndRecord`，仍只把文件写到本地。
        do {
            try session.setCategory(.record, mode: .default, options: [])
        } catch {
            DayTapLog.recorder.error("record category failed, falling back: \(error.localizedDescription, privacy: .public)")
            try session.setCategory(.playAndRecord, mode: .default, options: [])
        }
        try session.setActive(true)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 22_050,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        // #59:会话已激活,后续任何失败都要先熄会话再抛——否则表顶麦克风指示常亮,用户以为还在偷录。
        do {
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.prepareToRecord()
            guard recorder.record() else {
                try? session.setActive(false, options: [.notifyOthersOnDeactivation])
                throw CaptureError.failedToStart
            }
            self.recorder = recorder
            self.fileURL = fileURL
        } catch {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            throw error
        }
        DayTapLog.recorder.info("recording started \(fileURL.lastPathComponent, privacy: .public)")
    }

    /// 武装态开麦：录进临时文件，不进曲库（#5 的「缓冲不落盘」）。
    /// 麦克风此时是活跃的——配合 audio 后台模式，降腕/回表盘后 VAD 依然活着。
    func startBuffer() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("daytap-armed-\(UUID().uuidString).m4a")
        try start(fileURL: tmp)
        bufferURL = tmp
        fileURL = nil
        DayTapLog.recorder.info("armed buffer started \(tmp.lastPathComponent, privacy: .public)")
    }

    /// 武装态命中触发：把正被录音器写着的临时文件改名进曲库。
    /// POSIX 语义下 rename 不影响已打开的 fd，录音器无感继续写，
    /// 同一个文件天然带着触发前的缓冲头，无需任何拼接。
    func promote(to target: URL) throws {
        guard let recorder, recorder.isRecording, let source = bufferURL else {
            throw CaptureError.failedToStart
        }
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: source, to: target)
        bufferURL = nil
        fileURL = target
        DayTapLog.recorder.info("armed buffer promoted \(target.lastPathComponent, privacy: .public)")
    }

    /// 停止并返回时长。文件留在 `fileURL`，调用方负责入队传输。
    func stop() -> TimeInterval? {
        guard let recorder, let fileURL else {
            // 武装态解除：缓冲没有命中触发，整个丢弃，不留痕迹。
            if let recorder {
                let duration = recorder.currentTime
                recorder.stop()
                self.recorder = nil
                if let bufferURL {
                    try? FileManager.default.removeItem(at: bufferURL)
                    self.bufferURL = nil
                }
                try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
                DayTapLog.recorder.info("armed buffer discarded duration=\(duration)")
            }
            return nil
        }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.fileURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        DayTapLog.recorder.info("recording stopped \(fileURL.lastPathComponent, privacy: .public) duration=\(duration)")
        return duration
    }

    /// 0...1，给界面上的音量条。没有在录就返回 0。
    func currentLevel() -> Float {
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        let db = recorder.averagePower(forChannel: 0)
        let clamped = max(-50, min(0, db))
        return (clamped + 50) / 50
    }

    enum CaptureError: LocalizedError {
        case failedToStart

        var errorDescription: String? {
            switch self {
            case .failedToStart:
                return "录音没有开始。请允许麦克风，并让 DayTap 留在前台。"
            }
        }
    }
}
