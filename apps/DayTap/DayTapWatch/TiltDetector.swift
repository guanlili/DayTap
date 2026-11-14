import CoreMotion
import Foundation

/// 翻腕朝下开录(#89 实验室版):表盘翻向地面保持约 1 秒=开录。**默认关**——
/// 「我的 → 实验室」打开才启用;闲时前台监听(与 #11 敲桌同口径),误触优先保低:
/// 看表扫一眼不会停留保持时长,甩腕类大幅动作后要求重新翻下。
final class TiltDetector: ObservableObject {
    enum Tuning {
        /// 面朝下判定:重力在屏幕法向的分量(平放朝上约 -1g,朝下约 +1g)。
        static let faceDownZ: Double = 0.7
        /// 保持时长(秒):区分「翻下去看一眼」与「有意翻腕」。
        static let holdSeconds: CFTimeInterval = 1.0
        /// 触发后冷却(秒):翻回来再翻才能再触发。
        static let cooldown: TimeInterval = 3.0
    }

    /// 命中回调。动作队列触发,已派发主线程。
    var onTrigger: (() -> Void)?

    private let manager = CMMotionManager()
    /// 串行队列:与 #28 同款,防回调并发改写检测状态。
    private let sampleQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var faceDownSince: CFTimeInterval?
    private var cooldownUntil = Date.distantPast
    private(set) var isRunning = false

    func start() {
        guard !isRunning, manager.isDeviceMotionAvailable else { return }
        isRunning = true
        faceDownSince = nil
        manager.deviceMotionUpdateInterval = 1.0 / 20.0
        manager.startDeviceMotionUpdates(to: sampleQueue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.sample(gravityZ: motion.gravity.z, at: motion.timestamp)
        }
        DayTapLog.motion.info("tilt detector started")
    }

    func stop() {
        guard isRunning else { return }
        manager.stopDeviceMotionUpdates()
        isRunning = false
        DayTapLog.motion.info("tilt detector stopped")
    }

    /// 保持检测:法向分量持续超阈值达 holdSeconds 才命中;中途抬回即重置。
    private func sample(gravityZ: Double, at timestamp: CFTimeInterval) {
        guard gravityZ >= Tuning.faceDownZ else {
            faceDownSince = nil
            return
        }
        if faceDownSince == nil {
            faceDownSince = timestamp
            return
        }
        if timestamp - faceDownSince! >= Tuning.holdSeconds, Date() > cooldownUntil {
            cooldownUntil = Date().addingTimeInterval(Tuning.cooldown)
            faceDownSince = nil
            DayTapLog.motion.info("tilt TRIGGER")
            DispatchQueue.main.async { [weak self] in
                self?.onTrigger?()
            }
        }
    }
}
