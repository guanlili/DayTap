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
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due
            )
        }
        reminder.calendar = store.defaultCalendarForNewReminders()
        try store.save(reminder, commit: true)
    }

    /// 预填好的日历事件编辑面板:标题/来源备注/截止时间就位,用户过目改时间后自己点添加。
    static func makeEventEditor(title: String, source: String, due: Date?) -> EventEditor {
        EventEditor(title: title, source: source, due: due)
    }

    enum InteropError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let text) = self { return text }
            return nil
        }
    }

    /// EKEventEditViewController 的 SwiftUI 包装:present 由根控制器承担。
    struct EventEditor: UIViewControllerRepresentable {
        let title: String
        let source: String
        let due: Date?

        func makeUIViewController(context: Context) -> EKEventEditViewController {
            let editor = EKEventEditViewController()
            let store = EKEventStore()
            let event = EKEvent(eventStore: store)
            event.title = title
            event.notes = "来自 DayTap 录音「\(source)」"
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

        func makeCoordinator() -> Coordinator { Coordinator() }

        final class Coordinator: NSObject, EKEventEditViewDelegate {
            func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
                controller.dismiss(animated: true)
            }
        }
    }
}

/// 待办行(#61):轻点=完成态勾选划线;尾部菜单=添加到提醒事项(默认)/日历/复制。
/// 摘要卡与本周回顾共用。完成态写回索引(手动操作永远赢过 AI 重识别)。
struct ActionItemRow: View {
    let recordID: String
    @Binding var item: ActionItem
    /// 完成态落库回调(由宿主视图改库后触发刷新)。
    let onToggleDone: (ActionItem) -> Void
    /// 行内结果反馈(添加成功/失败的一行小字)。
    @Binding var feedback: String

    @State private var confirmReminders = false
    @State private var showEventEditor = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Button {
                item.isDone.toggle()
                onToggleDone(item)
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
                Text(due.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(Color.orange)
            }

            Spacer(minLength: 4)

            Menu {
                Button {
                    confirmReminders = true
                } label: {
                    Label("添加到提醒事项", systemImage: "checklist")
                }
                Button {
                    showEventEditor = true
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
            Text(dueMessage)
        }
        .sheet(isPresented: $showEventEditor) {
            SystemInterop.makeEventEditor(title: item.text, source: recordID, due: item.dueAt)
                .ignoresSafeArea()
        }
    }

    private var dueMessage: String {
        if let due = item.dueAt {
            return "「\(item.text)」" + (due > Date() ? "（截止 \(due.formatted(date: .abbreviated, time: .shortened))）" : "")
        }
        return "「\(item.text)」"
    }
}
