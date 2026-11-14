import Foundation

/// #75 待办回链:在分段转写里找待办条目最可能的原声出处。
/// AI 把口语压成短句,逐字匹配必失败——用共有二字组打分:
/// 待办文本的二元组有多少落进同一段(覆盖待办的比重),取覆盖最高且过阈值的分段。
/// 找不到返回 nil,调用方按「匹配不上不显示入口」原则隐藏跳转。
enum ActionItemAnchor {
    /// 覆盖阈值:待办短语的二元组有约三分之一落在同一段才认作出处。
    /// 偏低会乱跳,偏高会常无锚点;钉 1/3,边界由单测样例把住。
    static let coverageThreshold = 0.34

    /// 最佳匹配分段的起点秒数;无分段/待办太短/不过阈值 → nil。
    static func offset(for itemText: String, segments: [TranscriptSegment]) -> Double? {
        bestSegment(for: itemText, segments: segments)?.start
    }

    /// 最佳匹配分段本体;同分取先出现的(改写自上而下读,靠前的段先命中)。
    static func bestSegment(for itemText: String, segments: [TranscriptSegment]) -> TranscriptSegment? {
        let needle = bigrams(itemText)
        // 二字组不足两个(≈待办不到三个字)没有区分度,不给锚点。
        guard needle.count >= 2 else { return nil }
        var best: (segment: TranscriptSegment, coverage: Double)?
        for segment in segments where !segment.text.isEmpty {
            let coverage = Double(needle.intersection(bigrams(segment.text)).count) / Double(needle.count)
            if coverage >= coverageThreshold, coverage > (best?.coverage ?? 0) {
                best = (segment, coverage)
            }
        }
        return best?.segment
    }

    /// 中英混排二元组:小写化取相邻字符对,跳过空白对(空白不承担语义)。
    static func bigrams(_ text: String) -> Set<String> {
        let chars = text.lowercased().map { $0.isWhitespace ? nil : $0 }
        let compact = chars.compactMap { $0 }
        guard compact.count >= 2 else { return [] }
        return Set((0..<(compact.count - 1)).map { String(compact[$0]) + String(compact[$0 + 1]) })
    }
}
