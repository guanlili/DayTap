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
    /// 最近一次「点试听却打不开」的原因,给列表页提示。成功播放或 reset 时清空。
    @Published private(set) var loadError: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    /// 同一条:播着就暂停,暂停了就续播;换一条:从头播。
    func toggle(_ record: RecordingRecord, fileURL: URL) {
        if playingID == record.id, let player {
            if isPlaying {
                player.pause()
                isPlaying = false
            } else {
                player.play()
                isPlaying = true
            }
            return
        }
        start(record: record, fileURL: fileURL)
    }

    private func start(record: RecordingRecord, fileURL: URL) {
        reset()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            DayTapLog.library.error("playback session failed \(error.localizedDescription, privacy: .public)")
        }
        guard let newPlayer = try? AVAudioPlayer(contentsOf: fileURL) else {
            DayTapLog.library.error("playback load failed \(record.id, privacy: .public)")
            // 空壳/损坏文件加载失败不再静默:手表端曾经发出过只有容器头的录音,点试听毫无反应(#17)。
            loadError = "这条音频打不开（文件是空的或已损坏）。新版手表不再发送这类录音，这条可以从列表忽略。"
            return
        }
        loadError = nil
        newPlayer.play()
        player = newPlayer
        playingID = record.id
        isPlaying = true
        duration = max(newPlayer.duration, 0.1)
        elapsed = 0
        progress = 0
        startTimer()
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
        // 播完:player 自己停了且不是我们按的暂停,静默复位。
        if !player.isPlaying, isPlaying {
            reset()
        }
    }
}
