import Foundation

/// 成就(#86 最小版):五枚纯本地里程碑,达成即亮——不推送、不积分、不惩罚。
/// 原料全是现成数据(录音/勾选/承诺方向),纯函数可单测;落点=成长 tab。
enum Achievements {
    struct Achievement: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
    }

    static func earned(
        _ records: [RecordingRecord],
        now: Date,
        calendar: Calendar = .current
    ) -> [Achievement] {
        let active = records.filter { $0.deletedAt == nil }
        var out: [Achievement] = []

        if !active.isEmpty {
            out.append(Achievement(
                id: "first", title: "第一次记录", detail: "录下第一条的那一刻", symbol: "sparkle"
            ))
        }

        if streakDays(active, now: now, calendar: calendar) >= 7 {
            out.append(Achievement(
                id: "streak7", title: "连续七天", detail: "连续 7 天都有记录", symbol: "flame"
            ))
        }

        if active.count >= 50 {
            out.append(Achievement(
                id: "fifty", title: "累计五十条", detail: "攒下第 50 条录音", symbol: "square.stack"
            ))
        }

        let honored = active.compactMap(\.actionItems).flatMap { $0 }
            .filter { $0.isDone && $0.direction != .other }
            .count
        if honored >= 10 {
            out.append(Achievement(
                id: "honored10", title: "承诺兑现十次", detail: "答应的事办到 10 次", symbol: "checkmark.seal"
            ))
        }

        let weekTodos = active.filter { $0.createdAt > now.addingTimeInterval(-7 * 86400) }
            .compactMap(\.actionItems).flatMap { $0 }
        if weekTodos.count >= 3, weekTodos.allSatisfy(\.isDone) {
            out.append(Achievement(
                id: "cleared", title: "清清爽爽", detail: "一周待办全部办完", symbol: "broom"
            ))
        }

        return out
    }

    /// 连续记录天数:今天没录不打断(从昨天起算),口径宽容。
    private static func streakDays(
        _ records: [RecordingRecord], now: Date, calendar: Calendar
    ) -> Int {
        let days = Set(records.map { calendar.startOfDay(for: $0.createdAt) })
        var cursor = calendar.startOfDay(for: now)
        if !days.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = yesterday
        }
        var streak = 0
        while days.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }
}
