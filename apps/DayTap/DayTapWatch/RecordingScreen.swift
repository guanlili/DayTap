import SwiftUI
import WatchKit

/// 无感录音界面(#5):看起来就是一块报时表盘。
/// 抬腕看时间 = 武装;有人说话自动开录;全屏点按或握拳 = 立刻开录/停止。
/// 界面上没有大按钮——这个场景里,显眼的动作本身就是缺陷。
///
/// #4 的边界:安静不等于让本人也看不见。传输卡住时,界面只多一行极简计数;
/// 想看细节就长按 0.6 秒打开诊断页(重传/失败原因/解除无感都在那里)。
struct RecordingScreen: View {
    @ObservedObject var model: WatchModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var showDiagnostics = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            VStack(spacing: 6) {
                clock(timeline.date)

                statusDot
                    .padding(.vertical, 2)

                if model.phase != .idle {
                    levelBar
                }

                secondaryLine

                if model.phase == .idle && model.permissionDenied {
                    Text("请在手表设置里允许 DayTap 使用麦克风")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { model.toggle() }
            .onLongPressGesture(minimumDuration: 0.6) {
                WKInterfaceDevice.current().play(.click)
                showDiagnostics = true
            }
            .accessibilityIdentifier("daytap.record.toggle")
            .accessibilityLabel(accessibilitySummary)
            .accessibilityAddTraits(.isButton)
        }
        .sheet(isPresented: $showDiagnostics) { diagnostics }
        .onAppear(perform: model.onAppear)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.onActive()
            case .background:
                // audio 后台模式:录音与武装态都继续,不在这里停(#5)。
                break
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    private func clock(_ date: Date) -> some View {
        Text(date.formatted(date: .omitted, time: .shortened))
            .font(.system(size: 44, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.6)
            .foregroundStyle(.primary)
    }

    /// 状态全靠一枚小点:白=武装待命,红=正在录。远看就是表盘上的装饰。
    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
            .opacity(model.phase == .idle ? 0.25 : 1)
    }

    private var dotColor: Color {
        switch model.phase {
        case .idle: return .gray
        case .armed: return .white
        case .recording: return .red
        }
    }

    /// 第二行只在两种时候出现:传输卡住(用户能自己处理),或闲着需要一句提示。
    /// 正常录制中不占位,保持「就是块表盘」的观感。
    @ViewBuilder private var secondaryLine: some View {
        if model.transfer.failed > 0 {
            Text("\(model.transfer.failed) 条没传出·长按看")
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
        } else if model.transfer.waiting > 0 {
            Text("待传 \(model.transfer.waiting)·长按看")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if model.phase == .idle && !model.permissionDenied {
            Text(model.stealthSuppressed ? "无感模式已关闭·点一下恢复" : "点一下进入无感模式")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
    }

    private var levelBar: some View {
        Capsule()
            .fill(Color.white.opacity(0.15))
            .frame(height: 4)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(model.phase == .recording ? Color.red : Color.white.opacity(0.45))
                    .scaleEffect(
                        x: CGFloat(max(model.level, 0.08)),
                        y: 1,
                        anchor: .leading
                    )
            }
            .accessibilityHidden(true)
    }

    // MARK: - 诊断页

    /// 长按进入。#4 的所有「想知道但不想抬手」的信息都收在这里:
    /// 待传/已确认/失败、最近失败原因、通道一句话状态、重传、解除无感。
    private var diagnostics: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("传输")
                    .font(.headline)

                countRow("待传", model.transfer.waiting)
                countRow("已确认", model.transfer.acknowledged)
                countRow("失败", model.transfer.failed)

                if let error = model.transfer.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(4)
                }

                if let ackedAt = model.transfer.lastAckedAt {
                    Text("最近确认 \(ackedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(model.linkStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(model.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button("再传一次") { model.retry() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("daytap.record.retry")

                Button("解除无感模式") {
                    model.exitStealth()
                    showDiagnostics = false
                }
                .buttonStyle(.bordered)
                .tint(.gray)

                Button("关闭") { showDiagnostics = false }
                    .buttonStyle(.borderless)
                    .font(.caption2)
            }
            .padding(.horizontal, 4)
        }
    }

    private func countRow(_ title: String, _ count: Int) -> some View {
        HStack {
            Text(title)
                .font(.caption)
            Spacer()
            Text("\(count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(count == 0 ? Color.secondary : Color.primary)
        }
    }

    private var accessibilitySummary: String {
        switch model.phase {
        case .idle: return "无感录音,闲置,点按进入武装"
        case .armed: return "无感录音,已武装,听到说话自动开录,点按立刻开录"
        case .recording: return "无感录音,正在录音,点按停止并保存"
        }
    }
}
