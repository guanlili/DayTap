import Foundation

/// 转写分块(#68):长录音 digest 的分段理解——把时间戳分段序列切成「不超字数上限」的
/// 连续块,切口永远落在段边界(不腰斩句子),块起点=块内首段 start(章节跳播锚点)。
/// 修的是 digest 只发转写前 4000 字的截断:#64 后台长录落地后,几十分钟录音的
/// 摘要/待办实际只覆盖开头一段。纯函数,单测钉住边界口径。
enum TranscriptChunking {
    /// 单块字数上限:略低于 digest 的 4000 字发送口径,给上下文行留余量。
    static let chunkCharLimit = 3200

    struct Block: Equatable {
        /// 块首段 start(秒)——章节锚点。
        var start: Double
        /// 块内段落拼的纯文本。
        var text: String
    }

    /// 无分段(旧数据/未转写)、总字数不超限(单块)、或单段超限无法再切 → nil:
    /// 调用方走旧的单次 digest,不产章节——短录音本来就不需要章节。
    static func blocks(_ segments: [TranscriptSegment]?, limit: Int = chunkCharLimit) -> [Block]? {
        guard let segments, !segments.isEmpty, limit > 0 else { return nil }
        var blocks: [Block] = []
        var current: [String] = []
        var currentChars = 0
        var currentStart = segments[0].start
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if currentChars + text.count > limit, !current.isEmpty {
                blocks.append(Block(start: currentStart, text: current.joined(separator: "\n")))
                current = []
                currentChars = 0
                currentStart = segment.start
            }
            current.append(text)
            currentChars += text.count
        }
        if !current.isEmpty {
            blocks.append(Block(start: currentStart, text: current.joined(separator: "\n")))
        }
        // 单块=不超限(或单段巨长没法切):没有「章节」可言。
        guard blocks.count > 1 else { return nil }
        return blocks
    }
}
