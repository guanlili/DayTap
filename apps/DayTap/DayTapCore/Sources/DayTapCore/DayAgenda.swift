import Foundation

/// Day 页(#80 P0)的纯聚合层:跨录音回答「今天该做什么」。
/// 只读不写——勾选落库仍走宿主回调,与单条录音/本周回顾同一套数据与肌肉记忆。
enum DayAgenda {
    /// 聚合口径里的一条待办。ActionItem.id=text(#62),跨录音同文会撞,
    /// 这里用「录音 id#待办 id」做复合键。
    struct TodoEntry: Identifiable, Equatable {
        enum Bucket: Equatable {
            /// 截止在今天之前且未完成——每天滚进来,直到办掉。
            case overdue
            /// 截止落在今天。
            case today
        }

        let recordID: String
        /// 来源录音标题(手动名>时间,模型 title 口径),跳回去看上下文用。
        let recordTitle: String
        let item: ActionItem
        let bucket: Bucket

        var id: String { "\(recordID)#\(item.id)" }
    }

    /// 今日待办(#80):跨录音聚合「截止今天」+「全部逾期」的未完成项。
    /// 已完成即退场(驾驶舱只看剩余动作);无截止的待办不进——它们活在录音与本周回顾里。
    /// 排序:逾期在前(拖得最久的最先),今天的按截止时刻;同刻按来源录音时间。
    static func todayTodos(
        _ records: [RecordingRecord],
        now: Date,
        calendar: Calendar = .current
    ) -> [TodoEntry] {
        let todayStart = calendar.startOfDay(for: now)
        guard let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) else {
            return []
        }
        var overdue: [TodoEntry] = []
        var today: [TodoEntry] = []
        for record in records where record.deletedAt == nil {
            guard let items = record.actionItems else { continue }
            for item in items where !item.isDone {
                guard let due = item.dueAt else { continue }
                let entry = TodoEntry(
                    recordID: record.id,
                    recordTitle: record.title,
                    item: item,
                    bucket: due < todayStart ? .overdue : .today
                )
                if entry.bucket == .overdue {
                    overdue.append(entry)
                } else if due < tomorrowStart {
                    today.append(entry)
                }
                // 明天及以后:不进今天的驾驶舱。
            }
        }
        let byDue: (TodoEntry, TodoEntry) -> Bool = { $0.item.dueAt! < $1.item.dueAt! }
        return overdue.sorted(by: byDue) + today.sorted(by: byDue)
    }

    /// 今日时间线里的「今天录的」(#80):按创建时间正序,只列未删除的。
    static func todaysRecordings(
        _ records: [RecordingRecord],
        now: Date,
        calendar: Calendar = .current
    ) -> [RecordingRecord] {
        let todayStart = calendar.startOfDay(for: now)
        return records
            .filter { $0.deletedAt == nil && $0.createdAt >= todayStart }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// 今天的声音里提到的人(#85 v1):跨今天录音聚合,按提及条数降序;
    /// sources 带来源录音,点了能听。只统计今天的,不看回收站。
    struct PersonMention: Identifiable, Equatable {
        var id: String { name }
        var name: String
        var count: Int
        /// 提到这个人的今天录音(时间正序)。
        var sources: [RecordingRecord]
    }

    static func peopleMentions(
        _ records: [RecordingRecord],
        now: Date,
        calendar: Calendar = .current
    ) -> [PersonMention] {
        var byName: [String: PersonMention] = [:]
        for record in todaysRecordings(records, now: now, calendar: calendar) {
            // 抽取侧已去重,这里再兜一道:Set 保证「N 条录音」语义不被单条内的重复名虚增。
            for raw in Set(record.people ?? []) {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                if var mention = byName[name] {
                    mention.count += 1
                    mention.sources.append(record)
                    byName[name] = mention
                } else {
                    byName[name] = PersonMention(name: name, count: 1, sources: [record])
                }
            }
        }
        return byName.values.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.name < rhs.name
        }
    }

    /// 人物反向提醒(#85 最小版):观察窗 windowDays 天内出现过、但已 silentDays 天没提到的人。
    /// 只在打开时算一行字,不做推送;没提过的人不进(避免报一堆陌生名字)。
    static func peopleQuietFor(
        _ records: [RecordingRecord],
        now: Date,
        silentDays: Int = 3,
        windowDays: Int = 14,
        calendar: Calendar = .current
    ) -> [String] {
        let windowStart = calendar.date(byAdding: .day, value: -windowDays, to: now) ?? now
        let quietCutoff = calendar.date(byAdding: .day, value: -silentDays, to: now) ?? now
        var lastMention: [String: Date] = [:]
        for record in records where record.deletedAt == nil {
            guard record.createdAt > windowStart else { continue }
            for raw in Set(record.people ?? []) {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                if lastMention[name] == nil || record.createdAt > lastMention[name]! {
                    lastMention[name] = record.createdAt
                }
            }
        }
        return lastMention
            .filter { _, last in last <= quietCutoff }
            .keys.sorted()
    }

    // MARK: - 今日安排建议(#80 P0)

    /// AI 排程建议的一条:标题+理由+建议时段。kind 只作图标语义,不参与逻辑。
    struct Suggestion: Identifiable, Equatable {
        enum Kind: String, CaseIterable {
            case workout = "运动"
            case focus = "专注"
            case rest = "休息"
            case review = "复盘"
            case other = "安排"

            var symbol: String {
                switch self {
                case .workout: "figure.run"
                case .focus: "brain.head.profile"
                case .rest: "cup.and.saucer.fill"
                case .review: "checklist"
                case .other: "calendar"
                }
            }
        }

        var id: String { "\(start)#\(title)" }
        var title: String
        var reason: String
        /// 24 小时制「HH:mm」;引擎口径如此,展示原样。
        var start: String
        /// 建议时长(分钟)。
        var minutes: Int
        var kind: Kind
    }

    /// 两引擎输出的统一规整(#80):配对元组按索引(空标题先丢,#62 左移挂错人教训)、
    /// 截到 4 条、时长钳到 15…240、类型认不出的归 other。
    static func normalizedSuggestions(
        titles: [String],
        reasons: [String],
        starts: [String],
        minutes: [Int],
        kinds: [String]
    ) -> [Suggestion] {
        var out: [Suggestion] = []
        for index in titles.indices {
            let title = titles[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            out.append(Suggestion(
                title: String(title.prefix(16)),
                reason: index < reasons.count
                    ? String(reasons[index].trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
                    : "",
                start: index < starts.count
                    ? starts[index].trimmingCharacters(in: .whitespacesAndNewlines)
                    : "",
                minutes: index < minutes.count ? min(max(minutes[index], 15), 240) : 30,
                kind: index < kinds.count ? (Suggestion.Kind(rawValue: kinds[index]) ?? .other) : .other
            ))
            if out.count == 4 { break }
        }
        return out
    }
}
