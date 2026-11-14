import Foundation

/// 语义密度(#69):时间戳分段 → 等宽桶的归一化字数密度,给密度播放条着色——
/// 「哪段讲得密」纯本地可算(TranscriptSegment 自带 text/start/duration),零 LLM 成本;
/// 与跳静音(#37)同一数据源,视觉语义互相呼应。
enum SpeechDensity {
    /// 默认 120 桶:300pt 宽的条每桶约 2.5pt,再密的转写也不值得更多绘制单元。
    static let defaultBucketCount = 120

    /// 分段聚合成 `count` 桶的 0...1 归一化密度(3 点均值平滑后按峰值归一)。
    /// 无分段/时长非正/全空文本 → nil,调用方降级纯色条(同 #29 无分段降级先例)。
    /// 段跨桶按覆盖桶数摊字数:桶里装的是「这段区域信息多不多」的相对值,
    /// 长录音与短录音、长句与短句同口径可比。
    static func buckets(
        _ segments: [TranscriptSegment]?,
        duration: TimeInterval,
        count: Int = defaultBucketCount
    ) -> [Float]? {
        guard let segments, !segments.isEmpty, duration > 0, count > 1 else { return nil }
        var sums = [Float](repeating: 0, count: count)
        var hasContent = false
        for segment in segments {
            let chars = Float(segment.text.count)
            guard chars > 0 else { continue }
            hasContent = true
            let from = max(0, min(Int(floor(segment.start / duration * Double(count))), count - 1))
            let to = max(from + 1, min(Int(ceil((segment.start + segment.duration) / duration * Double(count))), count))
            let perBucket = chars / Float(to - from)
            for bucket in from..<to { sums[bucket] += perBucket }
        }
        guard hasContent else { return nil }
        // 轻度平滑(3 点均值):单桶尖刺不扎眼,段落边界仍清晰。
        var smoothed = sums
        for i in 0..<count {
            let prev = i > 0 ? sums[i - 1] : 0
            let next = i < count - 1 ? sums[i + 1] : 0
            smoothed[i] = (prev + sums[i] + next) / 3
        }
        let peak = smoothed.max() ?? 0
        guard peak > 0 else { return nil }
        return smoothed.map { $0 / peak }
    }
}
