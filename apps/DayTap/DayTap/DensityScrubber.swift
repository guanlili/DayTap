import SwiftUI

/// 密度播放条(#69):拖动定位条的轨道就是「哪段讲得密」——把语音备忘录的物理波形
/// 换成语义版,长录音一眼找到讲得多的段。分段字数聚合成等宽桶着色:深=密,
/// 近零=静音/无语音;已播桶换红,与原 Slider 的 tint(.red) 同脸。
/// 无分段旧数据降级纯色条(同 #29 无分段降级先例),点按/拖动/无障碍调节行为不变。
/// 密度在 body 现算:O(分段数) 微秒级,不与 4Hz 时钟抢任何东西。
struct DensityScrubber: View {
    let segments: [TranscriptSegment]?
    /// 只用于桶化定位;播放进度是 0...1 比例,与播放器实际时长解耦。
    let duration: TimeInterval
    let progress: Double
    let onScrub: (Double) -> Void

    private let barHeight: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if let density = SpeechDensity.buckets(segments, duration: duration) {
                    Canvas { context, size in
                        let n = density.count
                        let width = size.width / CGFloat(n)
                        let playedBucket = Int(min(max(progress, 0), 1) * Double(n))
                        for (i, d) in density.enumerated() {
                            // 相邻桶各加 0.5pt 消缝;Capsule 裁圆两端。
                            let rect = CGRect(x: CGFloat(i) * width, y: 0, width: width + 0.5, height: size.height)
                            context.fill(
                                Path(rect),
                                with: .color(
                                    i < playedBucket
                                        ? Color.red.opacity(0.45 + 0.55 * Double(d))
                                        : Color.secondary.opacity(0.18 + 0.72 * Double(d))
                                )
                            )
                        }
                    }
                    .clipShape(Capsule())
                } else {
                    Capsule().fill(Color.secondary.opacity(0.22))
                    Capsule().fill(Color.red)
                        .frame(width: geo.size.width * min(max(progress, 0), 1))
                }
            }
            .frame(height: barHeight)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                // minimumDistance 0 = 点按即跳,拖动实时跟手,与原 Slider 手感对齐。
                DragGesture(minimumDistance: 0).onChanged { value in
                    guard geo.size.width > 1 else { return }
                    onScrub(min(max(value.location.x / geo.size.width, 0), 0.995))
                }
            )
        }
        .frame(height: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(Int(min(max(progress, 0), 1) * 100))%")
        .accessibilityAdjustableAction { direction in
            let next = progress + (direction == .increment ? 0.05 : -0.05)
            onScrub(min(max(next, 0), 0.995))
        }
    }
}
