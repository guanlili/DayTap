import CoreMotion
import Foundation

/// 敲桌两下检测(#11):App 在前台的闲时,指节敲桌面两下=开始录音,等同点按。
/// 武装态随 VAD 一起撤了(#5),重定口径为「闲时前台监听」:回表盘即停,零后台开销。
/// CMMotionManager 加速度计 ~100Hz,合加速度(含静止 ~1g)做双冲击峰检测。
final class KnockDetector: ObservableObject {
    /// 真机调参区(#11 原型参数,依据 DayTapLog 采集的峰幅/间隔分布再定):
    /// 木桌传导强、玻璃桌弱,先取保守窗;误触优先保低。
    enum Tuning {
        /// 单峰进入阈值(g)。低于它不算敲击。
        static let peakG: Double = 2.2
        /// 峰间回落阈值(g)。上个峰之后必须落回这里以下,下一个峰才算独立敲击
        /// (避免一记重击的余震被数成两下)。
        static let quietG: Double = 1.6
        /// 峰幅上限(g):超过按甩腕/磕碰丢弃。
        static let maxG: Double = 9.0
        /// 两峰间隔窗口(秒):指节连敲两下约 150-400ms。
        static let intervalMin: TimeInterval = 0.15
        static let intervalMax: TimeInterval = 0.40
        /// 触发后冷却(秒):三连敲不该触发第二次。
        static let cooldown: TimeInterval = 1.2
    }

    /// 命中回调。加速度计队列触发,已派发主线程。
    var onTrigger: (() -> Void)?

    private let manager = CMMotionManager()
    private var lastPeakAt: CFTimeInterval?
    private var belowQuiet = true
    private var cooldownUntil = Date.distantPast
    private(set) var isRunning = false

    func start() {
        guard !isRunning, manager.isAccelerometerAvailable else { return }
        isRunning = true
        belowQuiet = true
        lastPeakAt = nil
        manager.accelerometerUpdateInterval = 1.0 / 100.0
        manager.startAccelerometerUpdates(to: OperationQueue()) { [weak self] data, _ in
            guard let self, let data else { return }
            self.sample(magnitude: magnitude(of: data.acceleration), at: data.timestamp)
        }
        DayTapLog.motion.info("knock detector started")
    }

    func stop() {
        guard isRunning else { return }
        manager.stopAccelerometerUpdates()
        isRunning = false
        DayTapLog.motion.info("knock detector stopped")
    }

    /// 双冲击检测:上穿 peakG 记峰(需先回落到 quietG 以下),两峰间隔落在窗口内即命中。
    private func sample(magnitude: Double, at timestamp: CFTimeInterval) {
        guard magnitude < Tuning.maxG else {
            // 甩腕/磕碰级别的量级,整段作废,要求重新回落。
            belowQuiet = false
            return
        }
        if magnitude < Tuning.quietG {
            belowQuiet = true
            return
        }
        guard belowQuiet, magnitude >= Tuning.peakG else { return }
        belowQuiet = false

        if let last = lastPeakAt {
            let interval = timestamp - last
            // 调参日志:每个峰的幅值与间隔都落盘,真机采几轮就能定参。
            DayTapLog.motion.info("knock peak g=\(Int(magnitude * 10), privacy: .public) interval=\(Int(interval * 1000))ms")
            if interval >= Tuning.intervalMin, interval <= Tuning.intervalMax,
               Date() > cooldownUntil {
                cooldownUntil = Date().addingTimeInterval(Tuning.cooldown)
                lastPeakAt = nil
                DayTapLog.motion.info("knock TRIGGER")
                DispatchQueue.main.async { [weak self] in
                    self?.onTrigger?()
                }
                return
            }
        } else {
            DayTapLog.motion.info("knock peak g=\(Int(magnitude * 10), privacy: .public) (first)")
        }
        lastPeakAt = timestamp
    }

    private func magnitude(of a: CMAcceleration) -> Double {
        sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
    }
}
