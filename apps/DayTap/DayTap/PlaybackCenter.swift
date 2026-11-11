import AVFoundation
import Combine
import Foundation

/// 手机端试听(#2):一台 AVAudioPlayer,同一时刻只播一条。
/// 不做后台续播、不做锁屏控制——试听是「确认这条是不是我要的」,几秒钟的事。
final class PlaybackCenter: ObservableObject {
    @Published private(set) var playingID: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    /// 倍速(#26):点击循环 1x→1.5x→2x,同一播放会话内跨条保留。
    @Published private(set) var rate: Float = 1.0
    /// 跳静音(#37):开着时落在分段间隙就跳到下一句起点。会话内跨条保留,同倍速口径;
    /// 当前条无分段=无从判断,开关在播放条上直接不显示。
    @Published private(set) var skipsSilence = false
    /// 最近一次「点试听却打不开」的原因,给列表页提示。成功播放或 reset 时清空。
    @Published private(set) var loadError: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?
    /// 正在播这条的时间戳分段(#37 跳静音用);start 时随 record 带入。
    private var activeSegments: [TranscriptSegment]?

    private static let rateOrder: [Float] = [1.0, 1.5, 2.0]

    /// 同一条:播着就暂停,暂停了就续播;换一条:从头播。
    func toggle(_ record: RecordingRecord, fileURL: URL) {
        toggle(record, fileURL: fileURL, at: 0)
    }

    /// 带定位的启停(#32):搜索命中/点句跳播用——从指定秒数起播,
    /// 已在播的同一条则直接定位过去并确保在播。
    func toggle(_ record: RecordingRecord, fileURL: URL, at offset: TimeInterval) {
        if playingID == record.id, let player {
            if offset > 0 {
                scrub(to: offset / max(duration, 0.1))
            }
            if !isPlaying {
                player.play()
                isPlaying = true
            }
            return
        }
        start(record: record, fileURL: fileURL, at: offset)
    }

    private func start(record: RecordingRecord, fileURL: URL, at offset: TimeInterval = 0) {
        reset()
        let session = AVAudioSession.sharedInstance()
        // 激活失败重试一次(#28):曾出现「界面在播但无声」的一次性抖动,
        // 会话没激活成功时 play() 只是空转;失败两次才放弃并落日志。
        var activated = false
        for _ in 0..<2 where !activated {
            do {
                try session.setCategory(.playback, mode: .default, options: [])
                try session.setActive(true)
                activated = true
            } catch {
                DayTapLog.library.error("playback session failed \(error.localizedDescription, privacy: .public)")
            }
        }
        guard let newPlayer = try? AVAudioPlayer(contentsOf: fileURL) else {
            DayTapLog.library.error("playback load failed \(record.id, privacy: .public)")
            // 空壳/损坏文件加载失败不再静默:手表端曾经发出过只有容器头的录音,点试听毫无反应(#17)。
            loadError = "这条音频打不开（文件是空的或已损坏）。新版手表不再发送这类录音，这条可以从列表忽略。"
            return
        }
        loadError = nil
        newPlayer.enableRate = true
        newPlayer.rate = rate
        guard activated, newPlayer.play() else {
            DayTapLog.library.error("playback failed to start \(record.id, privacy: .public)")
            loadError = "没法开始播放（音频会话没就绪）。再点一次试试。"
            return
        }
        player = newPlayer
        playingID = record.id
        isPlaying = true
        duration = max(newPlayer.duration, 0.1)
        activeSegments = record.transcriptSegments
        if offset > 0 {
            newPlayer.currentTime = min(offset, duration - 0.1)
            elapsed = newPlayer.currentTime
            progress = min(1, elapsed / duration)
        } else {
            elapsed = 0
            progress = 0
        }
        startTimer()
    }

    /// 倍速循环(#26):1x→1.5x→2x→1x,正在播的条目即时生效。
    func cycleRate() {
        guard let index = Self.rateOrder.firstIndex(of: rate) else {
            rate = 1.0
            return
        }
        rate = Self.rateOrder[(index + 1) % Self.rateOrder.count]
        player?.rate = rate
    }

    /// 跳静音开关(#37):下一个 tick 起生效。
    func toggleSkipSilence() {
        skipsSilence.toggle()
    }

    /// 拖动定位(#26):进度比例 0...1 落到播放器,拖动中 currentTime 实时跟手;
    /// 顶到末端留 0.1s 余量,避免拖到头触发「播完自动复位」。
    func scrub(to fraction: Double) {
        guard let player, playingID != nil, duration > 0 else { return }
        let clamped = min(max(fraction, 0), 0.995)
        player.currentTime = clamped * duration
        elapsed = player.currentTime
        progress = clamped
    }

    /// 停止并复位。播完自动调用;列表刷新、切条、离开页面也由外部调用。
    func reset() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        playingID = nil
        isPlaying = false
        progress = 0
        elapsed = 0
        duration = 0
        loadError = nil
        activeSegments = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let player, playingID != nil else { return }
        elapsed = player.currentTime
        progress = min(1, elapsed / duration)
        // 跳静音(#37):落在分段间隙就跳到下一句起点,0.25s 一查,跳跃即时反馈。
        if skipsSilence, let next = Self.nextSpeechStart(after: elapsed, in: activeSegments) {
            player.currentTime = next
            elapsed = next
            progress = min(1, elapsed / duration)
        }
        // 播完:player 自己停了且不是我们按的暂停,静默复位。
        if !player.isPlaying, isPlaying {
            reset()
        }
    }

    /// 当前时刻落在分段间隙(容差内不算,防切掉词间自然停顿)→返回下一分段起点;
    /// 在语音上或尾部间隙→nil 不跳(尾部放行,自然播完触发复位)。
    /// 分段假定按 start 升序(转写结果流天然如此);边界用例见 #37 的 11 例单验。
    private static func nextSpeechStart(after time: TimeInterval, in segments: [TranscriptSegment]?) -> TimeInterval? {
        guard let segments, !segments.isEmpty else { return nil }
        let tolerance: TimeInterval = 0.15
        for segment in segments {
            let speechEnd = segment.start + segment.duration
            if time < segment.start - tolerance {
                return max(segment.start, 0)
            }
            if time <= speechEnd + tolerance {
                return nil
            }
        }
        return nil
    }
}
