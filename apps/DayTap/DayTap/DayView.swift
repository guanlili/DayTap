import EventKit
import SwiftUI

/// Day 页(#80 P0):今天的三块——今日待办(跨录音聚合)/今日时间线(录音+待办+日历混排)/
/// 今日安排(AI 建议,写回提醒事项·日历前先确认)。
/// 只读聚合+确认写回;健康数据是 P1,本页零接入。
struct DayView: View {
    @ObservedObject private var library = PhoneLink.shared.library
    @ObservedObject var player: PlaybackCenter
    @ObservedObject var transcriber: TranscriptionCenter

    @State private var calendarEvents: [EKEvent] = []
    @State private var eventsLoaded = false
    @State private var suggestions: [DayAgenda.Suggestion]?
    @State private var plannedOnce = false
    @State private var planning = false
    @State private var planNote = ""
    @State private var todoFeedback = ""
    @State private var confirmReminder: DayAgenda.Suggestion?
    @State private var editorSuggestion: DayAgenda.Suggestion?

    private var todos: [DayAgenda.TodoEntry] {
        DayAgenda.todayTodos(library.records, now: Date())
    }

    private var todaysRecords: [RecordingRecord] {
        DayAgenda.todaysRecordings(library.records, now: Date())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    todoBlock
                    timelineBlock
                    planBlock
                }
                .padding(.vertical, 8)
            }
            .navigationTitle("计划")
            .navigationBarTitleDisplayMode(.inline)
            // 跳到出处/点录音行的播放在本页可见(#80):与录音页同一个 PlaybackCenter。
            .safeAreaInset(edge: .bottom) {
                if let playingID = player.playingID,
                   let record = library.records.first(where: { $0.id == playingID }) {
                    PlaybackBarView(player: player, record: record)
                }
            }
        }
        .task { await loadCalendarEvents() }
        .confirmationDialog(
            "添加到提醒事项?",
            isPresented: Binding(
                get: { confirmReminder != nil },
                set: { if !$0 { confirmReminder = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("添加") {
                if let suggestion = confirmReminder {
                    Task {
                        do {
                            try await SystemInterop.addToReminders(
                                text: suggestion.title, due: suggestionDate(suggestion)
                            )
                            planNote = "已添加到提醒事项:\(suggestion.title)"
                        } catch {
                            planNote = error.localizedDescription
                        }
                    }
                }
                confirmReminder = nil
            }
            Button("取消", role: .cancel) { confirmReminder = nil }
        } message: {
            Text(confirmReminder.map { "「\($0.title)」\($0.start) · \($0.minutes) 分钟" } ?? "")
        }
        .sheet(isPresented: Binding(
            get: { editorSuggestion != nil },
            set: { if !$0 { editorSuggestion = nil } }
        )) {
            if let suggestion = editorSuggestion {
                SystemInterop.makeEventEditor(
                    title: suggestion.title,
                    sourceTitle: "Day 今日安排",
                    due: suggestionDate(suggestion),
                    onDismiss: { editorSuggestion = nil }
                )
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - 今日待办

    private var todoBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("今日待办")
            if todos.isEmpty {
                Text("今天没有到期或逾期的待办。录音里识别出的待办带上截止时间后会出现在这里。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                // 勾选与单条录音/本周回顾同一套数据与肌肉记忆(#61/#80 验收口径)。
                ForEach(todos) { entry in
                    ActionItemRow(
                        item: entry.item,
                        sourceTitle: entry.recordTitle,
                        onToggleDone: { toggleDone(entry.recordID, $0) },
                        onJumpToSource: jumpToSource(entry),
                        feedback: $todoFeedback
                    )
                }
                if !todoFeedback.isEmpty {
                    Text(todoFeedback)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal)
    }

    /// 完成态落库:与 TranscriptView/ReviewSheet 同一写法,勾完三处同步。
    private func toggleDone(_ recordID: String, _ updated: ActionItem) {
        guard var fresh = library.record(id: recordID),
              var items = fresh.actionItems,
              let index = items.firstIndex(where: { $0.id == updated.id })
        else { return }
        items[index] = updated
        fresh.actionItems = items
        fresh.updatedAt = Date()
        library.upsert(fresh)
    }

    /// 待办回链(#75 基建复用):锚点找到才给入口,跳播走共享播放器。
    private func jumpToSource(_ entry: DayAgenda.TodoEntry) -> (() -> Void)? {
        guard let record = library.record(id: entry.recordID),
              let anchor = ActionItemAnchor.offset(for: entry.item.text, segments: record.transcriptSegments ?? [])
        else { return nil }
        return { player.toggle(record, fileURL: library.fileURL(id: record.id), at: anchor) }
    }

    // MARK: - 今日时间线

    private struct TimelineRow: Identifiable {
        enum Kind {
            case recording
            case todo
            case calendar
        }

        let id: String
        let time: Date
        let title: String
        let detail: String
        let kind: Kind
        let action: (() -> Void)?
    }

    private var timelineRows: [TimelineRow] {
        var rows: [TimelineRow] = []
        for record in todaysRecords {
            rows.append(TimelineRow(
                id: "rec-\(record.id)",
                time: record.createdAt,
                title: record.title,
                detail: "录音",
                kind: .recording,
                action: { player.toggle(record, fileURL: library.fileURL(id: record.id)) }
            ))
        }
        for entry in todos where entry.bucket == .today {
            rows.append(TimelineRow(
                id: "todo-\(entry.id)",
                time: entry.item.dueAt ?? Date(),
                title: entry.item.text,
                detail: "待办 · 来自「\(entry.recordTitle)」",
                kind: .todo,
                action: jumpToSource(entry)
            ))
        }
        for event in calendarEvents {
            rows.append(TimelineRow(
                // eventIdentifier 兜底用稳定串,不用随机 UUID(ForEach id 每帧变会闪)。
                id: "cal-\(event.eventIdentifier ?? "\(Self.clock(event.startDate))-\(event.title ?? "")")",
                time: event.startDate,
                title: event.title ?? "日程",
                detail: "\(Self.clock(event.startDate))–\(Self.clock(event.endDate)) · 日历",
                kind: .calendar,
                action: nil
            ))
        }
        return rows.sorted { $0.time < $1.time }
    }

    private var timelineBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("今日时间线")
            if timelineRows.isEmpty {
                Text("今天还没有录音、到期待办或日历日程。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(timelineRows) { row in
                    timelineRow(row)
                }
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func timelineRow(_ row: TimelineRow) -> some View {
        if let action = row.action {
            Button(action: action) { timelineLabel(row) }
                .buttonStyle(.borderless)
        } else {
            timelineLabel(row)
        }
    }

    private func timelineLabel(_ row: TimelineRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Self.clock(row.time))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Image(systemName: row.kind == .recording ? "waveform" : row.kind == .todo ? "circle" : "calendar")
                .font(.caption2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
                Text(row.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityLabel("\(row.title),\(row.detail)")
    }

    // MARK: - 今日安排

    private var planBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("今日安排")
            if let suggestions, !suggestions.isEmpty {
                ForEach(suggestions) { suggestion in
                    suggestionRow(suggestion)
                }
                regenerateButton
            } else if planning {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在生成建议…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("让 AI 看今天的待办与日程占用,给 2–4 条安排建议。写进提醒事项或日历前都会先经你确认。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                generateButton(plannedOnce ? "重新生成建议" : "生成今日安排")
            }
            if !planNote.isEmpty {
                Text(planNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
    }

    private var regenerateButton: some View {
        generateButton("重新生成")
    }

    private func generateButton(_ title: String) -> some View {
        Button {
            generatePlan()
        } label: {
            Label(title, systemImage: "sparkles")
                .font(.subheadline)
        }
        .disabled(planning)
    }

    private func suggestionRow(_ suggestion: DayAgenda.Suggestion) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: suggestion.kind.symbol)
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(suggestion.title)
                        .font(.subheadline)
                    Text("\(suggestion.start) · \(suggestion.minutes) 分钟")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !suggestion.reason.isEmpty {
                    Text(suggestion.reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Menu {
                Button {
                    confirmReminder = suggestion
                } label: {
                    Label("添加到提醒事项", systemImage: "checklist")
                }
                Button {
                    Task {
                        guard await SystemInterop.requestCalendarWriteAccess() else {
                            planNote = "没有日历权限——设置里允许后可用"
                            return
                        }
                        editorSuggestion = suggestion
                    }
                } label: {
                    Label("添加到日历", systemImage: "calendar")
                }
            } label: {
                Image(systemName: "calendar.badge.plus")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("写回菜单:\(suggestion.title)")
        }
    }

    private func generatePlan() {
        planning = true
        planNote = ""
        Task {
            let todoLines = todos.map { entry -> String in
                let due = entry.item.dueAt.map { Self.dateTime($0) } ?? "无时间"
                return "· \(entry.item.text)（\(entry.bucket == .overdue ? "已逾期" : "截止 \(due)")）"
            }
            let busyLines = calendarEvents.map { "\(Self.clock($0.startDate))–\(Self.clock($0.endDate)) \($0.title ?? "日程")" }
            // #80-P1:健康聚合量静默进排程——不弹授权,已授权才有这行;没睡够就少排硬仗。
            let health = await HealthReader.summarize()?.headline
            let result = await transcriber.daySuggestions(todos: todoLines, busy: busyLines, health: health)
            await MainActor.run {
                planning = false
                plannedOnce = true
                if let result, !result.isEmpty {
                    suggestions = result
                } else {
                    suggestions = nil
                    planNote = "没能生成建议——本机 Apple 智能与云端模型都不可用时出不来,可在设置的 AI 模型里配置。"
                }
            }
        }
    }

    /// 建议的「HH:mm」+今天 → Date;解析不了给 nil(写提醒事项当无时间)。
    private func suggestionDate(_ suggestion: DayAgenda.Suggestion) -> Date? {
        guard let time = Self.timeFormatter.date(from: suggestion.start) else { return nil }
        let calendar = Calendar.current
        var parts = calendar.dateComponents([.year, .month, .day], from: Date())
        let timeParts = calendar.dateComponents([.hour, .minute], from: time)
        parts.hour = timeParts.hour
        parts.minute = timeParts.minute
        return calendar.date(from: parts)
    }

    // MARK: - 日历只读(#80):无授权整块降级,不报错。

    private func loadCalendarEvents() async {
        guard !eventsLoaded else { return }
        eventsLoaded = true
        let store = EKEventStore()
        let granted = await withCheckedContinuation { continuation in
            store.requestFullAccessToEvents { ok, _ in continuation.resume(returning: ok) }
        }
        guard granted else {
            DayTapLog.link.info("day calendar access denied, timeline degrades")
            return
        }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        calendarEvents = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    // MARK: - 格式

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func clock(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    private static func dateTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
