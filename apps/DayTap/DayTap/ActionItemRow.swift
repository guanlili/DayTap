import EventKitUI
import SwiftUI

/// 待办 2.0(#61)的系统打通:提醒事项(默认,轻量确认)/ 日历(系统编辑面板,过目自存)。
/// EventKit 走隐私权限弹窗(iOS 17+ 日历有「仅写入」档),免费签名可用;
/// **绝不静默写入**——AI 可能幻觉条目,确认层就是防呆。
enum SystemInterop {
    /// 添加到系统「提醒事项」默认清单。轻量路径:调用方先给确认弹窗,这里只管落地。
    static func addToReminders(text: String, due: Date?) async throws {
        let store = EKEventStore()
        let granted = await withCheckedContinuation { continuation in
            store.requestFullAccessToReminders { ok, _ in continuation.resume(returning: ok) }
        }
        guard granted else {
            throw InteropError.message("没有提醒事项权限——设置里允许后可用")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = text
        reminder.notes = "来自 DayTap 录音"
        if let due {
            // #62:组件要带上 calendar——无日历的 DateComponents 历史上按 GMT 解释,+8 区会偏 8 小时。
            var components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due
            )
            components.calendar = .current
            reminder.dueDateComponents = components
        }
        reminder.calendar = store.defaultCalendarForNewReminders()
        try store.save(reminder, commit: true)
    }

    /// 日历写入权限前置(#62):面板自己不定权限——被拒过的设备上直接弹面板=空白怪象,
    /// 先把「仅写入」请求做了,拒绝走 feedback 通道。
    static func requestCalendarWriteAccess() async -> Bool {
        let store = EKEventStore()
        return await withCheckedContinuation { continuation in
            store.requestWriteOnlyAccessToEvents { ok, _ in continuation.resume(returning: ok) }
        }
    }

    /// 预填好的日历事件编辑面板:标题/来源备注/截止时间就位,用户过目改时间后自己点添加。
    static func makeEventEditor(
        title: String,
        sourceTitle: String,
        due: Date?,
        onDismiss: (() -> Void)? = nil
    ) -> EventEditor {
        EventEditor(title: title, sourceTitle: sourceTitle, due: due, onDismiss: onDismiss)
    }

    enum InteropError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let text) = self { return text }
            return nil
        }
    }

    /// EKEventEditViewController 的 SwiftUI 包装:嵌在 SwiftUI sheet 里呈现。
    struct EventEditor: UIViewControllerRepresentable {
        let title: String
        let sourceTitle: String
        let due: Date?
        var onDismiss: (() -> Void)?

        func makeUIViewController(context: Context) -> EKEventEditViewController {
            let editor = EKEventEditViewController()
            let store = EKEventStore()
            let event = EKEvent(eventStore: store)
            event.title = title
            // 备注用显示名(#62):原来写 UUID,用户日历里看到无意义串。
            event.notes = "来自 DayTap 录音「\(sourceTitle)」"
            // 没识别出截止就默认下个整点+1 小时,面板里用户随手改。
            let start = due ?? Calendar.current.nextDate(
                after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime
            ).map { $0.addingTimeInterval(3600) } ?? Date().addingTimeInterval(3600)
            event.startDate = start
            event.endDate = start.addingTimeInterval(3600)
            editor.eventStore = store
            editor.event = event
            editor.editViewDelegate = context.coordinator
            return editor
        }

        func updateUIViewController(_ uiViewController: EKEventEditViewController, context: Context) {}

        func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }

        /// #62:面板关闭不能只靠 UIKit dismiss——SwiftUI 的 $showEventEditor 可能不复位,
        /// 二次打开(true→true)就失灵。Coordinator 回调先把绑定复位。
        final class Coordinator: NSObject, EKEventEditViewDelegate {
            let onDismiss: (() -> Void)?

            init(onDismiss: (() -> Void)?) {
                self.onDismiss = onDismiss
            }

            func eventEditViewController(
                _ controller: EKEventEditViewController,
                didCompleteWith action: EKEventEditViewAction
            ) {
                onDismiss?()
                controller.dismiss(animated: true)
            }
        }
    }
}

/// 待办行(#61/#62):轻点=完成态勾选划线;尾部菜单=添加到提醒事项(默认)/日历/复制。
/// item 只读——勾选经 onToggleDone 落库,刷新由宿主的库观察驱动(不再依赖绑定可写)。
struct ActionItemRow: View {
    let item: ActionItem
    /// 日历事件备注里的来源显示名(录音标题)。
    let sourceTitle: String
    let onToggleDone: (ActionItem) -> Void
    /// 行内结果反馈(添加成功/失败的一行小字)。
    @Binding var feedback: String

    @State private var confirmReminders = false
    @State private var showEventEditor = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Button {
                // .constant 绑定写不进去(#62 教训):本地翻转后交给落库回调,UI 由库刷新。
                var updated = item
                updated.isDone.toggle()
                onToggleDone(updated)
            } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(item.isDone ? "标记未完成" : "标记完成")

            Text(item.text)
                .font(.subheadline)
                .strikethrough(item.isDone)
                .foregroundStyle(item.isDone ? Color.secondary : Color.primary)

            if let due = item.dueAt {
                Text(dueLabel(due))
                    .font(.caption2)
                    .foregroundStyle(due > Date() ? Color.orange : Color.secondary)
            }

            Spacer(minLength: 4)

            Menu {
                Button {
                    confirmReminders = true
                } label: {
                    Label("添加到提醒事项", systemImage: "checklist")
                }
                Button {
                    Task {
                        guard await SystemInterop.requestCalendarWriteAccess() else {
                            feedback = "没有日历权限——设置里允许后可用"
                            return
                        }
                        showEventEditor = true
                    }
                } label: {
                    Label("添加到日历", systemImage: "calendar")
                }
                Button {
                    UIPasteboard.general.string = item.text
                    feedback = "已复制"
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
            } label: {
                Image(systemName: "calendar.badge.plus")
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
            .accessibilityLabel("系统打通菜单")
        }
        .confirmationDialog(
            "添加到提醒事项?",
            isPresented: $confirmReminders,
            titleVisibility: .visible
        ) {
            Button("添加") {
                Task {
                    do {
                        try await SystemInterop.addToReminders(text: item.text, due: item.dueAt)
                        feedback = "已添加到提醒事项"
                    } catch {
                        feedback = error.localizedDescription
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .sheet(isPresented: $showEventEditor) {
            SystemInterop.makeEventEditor(
                title: item.text,
                sourceTitle: sourceTitle,
                due: item.dueAt,
                onDismiss: { showEventEditor = false }
            )
            .ignoresSafeArea()
        }
    }

    /// 过期口径统一(#62):行尾与弹窗都说「已过期 M月d日」,不再一处照常橙显一处隐去。
    private func dueLabel(_ due: Date) -> String {
        due > Date()
            ? due.formatted(date: .abbreviated, time: .shortened)
            : "已过期 " + due.formatted(date: .abbreviated, time: .omitted)
    }

    private var confirmMessage: String {
        if let due = item.dueAt, due > Date() {
            return "「\(item.text)」（截止 \(due.formatted(date: .abbreviated, time: .shortened))）"
        }
        return "「\(item.text)」"
    }
}
