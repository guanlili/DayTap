import EventKit
import Foundation

/// #88 会议自动优先:录音创建时刻落在日历占用区间 → 自动转写队列插队 + 类别兜底归「会议」。
/// 只读;已授权(与「计划」时间线同一条授权)才生效——拒绝/未授权时零变化。
/// 只在主线程用(drainAutoQueue 主线程消费),静态缓存无并发顾虑。
enum CalendarBusy {
    private static let store = EKEventStore()
    private static var cachedDay: Date?
    private static var cachedIntervals: [DateInterval] = []

    static var isReadable: Bool {
        // iOS 17+ 事件授权三态:fullAccess(读写)/writeOnly(仅写)/denied;
        // 时间线授权的是 fullAccess——writeOnly 读不到事件,不算可读。
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    static func contains(_ date: Date) -> Bool {
        intervals(around: date).contains { $0.contains(date) }
    }

    /// 该自然日的事件区间,按日缓存——一轮 drain 挑候选不会连查事件库。
    private static func intervals(around date: Date) -> [DateInterval] {
        guard isReadable else { return [] }
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        if cachedDay == day { return cachedIntervals }
        guard let end = calendar.date(byAdding: .day, value: 1, to: day) else { return [] }
        let predicate = store.predicateForEvents(withStart: day, end: end, calendars: nil)
        cachedIntervals = store.events(matching: predicate)
            .map { DateInterval(start: $0.startDate, end: $0.endDate) }
        cachedDay = day
        return cachedIntervals
    }
}
