import SwiftUI

/// 无感录音界面(#5):看起来就是一块报时表盘。
/// 点一下开始/停止,握拳(AssistiveTouch 绑快捷指令)同样启停;
/// 录着的时候按表冠回表盘继续录(audio 后台模式),不亮屏不出声。
/// 手动触发:VAD 自动开录经甲方真机体验后撤下(环境音误触),2026-11-10。
struct RecordingScreen: View {
    @ObservedObject var model: WatchModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmDiscard = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            VStack(spacing: 6) {
                clock(timeline.date)

                HStack(spacing: 6) {
                    statusDot
                    if model.phase == .recording {
                        Text(DayTapFormat.clock(model.elapsed))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)

                if model.phase == .recording {
                    levelBar
                } else if model.permissionDenied {
                    Text("请在手表设置里允许 DayTap 使用麦克风")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("点一下录音 · 录着可回表盘")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    transferBadge
                    if !model.linkStatus.isEmpty {
                        Text(model.linkStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    Button("再传一次", action: model.retry)
                        .buttonStyle(.bordered)
                        .font(.caption2)
                        .accessibilityIdentifier("daytap.record.retry")

                    // 待传才出现(#22):录了不想传的,表上直接清,不给 iPhone 知道。
                    if model.transferWaiting > 0 {
                        Button {
                            confirmDiscard = true
                        } label: {
                            Label("丢弃待传 (\(model.transferWaiting))", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .font(.caption2)
                        .accessibilityIdentifier("daytap.record.discard")
                    }
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { model.toggle() }
            .accessibilityIdentifier("daytap.record.toggle")
            .accessibilityLabel(model.phase == .recording ? "正在录音,点按停止并保存" : "录音,点按开始")
            .accessibilityAddTraits(.isButton)
            .alert("丢弃待传录音?", isPresented: $confirmDiscard) {
                Button("丢弃", role: .destructive) { model.discardPending() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("\(model.transferWaiting) 条不会传给 iPhone，手表上直接删除。")
            }
        }
        .onAppear(perform: model.onAppear)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.onActive()
            case .background:
                // audio 后台模式:录音继续,不在这里停(#5)。
                break
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    /// 传输角标(#4):待确认/失败一眼可读;有失败时补一行短原因。
    /// 融进表盘形态:两行 caption2,不亮大屏不弹窗。
    @ViewBuilder
    private var transferBadge: some View {
        if model.transferFailed > 0 || model.transferWaiting > 0 {
            VStack(spacing: 2) {
                HStack(spacing: 8) {
                    if model.transferWaiting > 0 {
                        Label(
                            "\(model.transferWaiting) 条 · \(DayTapFormat.bytes(model.transferBytes))",
                            systemImage: "arrow.uturn.up"
                        )
                    }
                    if model.transferFailed > 0 {
                        Label("\(model.transferFailed)", systemImage: "exclamationmark.triangle")
                    }
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(model.transferFailed > 0 ? Color.orange : Color.secondary)
                if model.transferFailed > 0, let error = model.transferError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityIdentifier("daytap.transfer.badge")
        }
    }

    private func clock(_ date: Date) -> some View {
        Text(date.formatted(date: .omitted, time: .shortened))
            .font(.system(size: 44, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.6)
            .foregroundStyle(.primary)
    }

    /// 状态一枚小点:灰=闲,红=正在录。远看就是表盘上的装饰。
    private var statusDot: some View {
        Circle()
            .fill(model.phase == .recording ? Color.red : Color.gray)
            .frame(width: 8, height: 8)
            .opacity(model.phase == .recording ? 1 : 0.35)
    }

    private var levelBar: some View {
        Capsule()
            .fill(Color.white.opacity(0.15))
            .frame(height: 4)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.red)
                    .scaleEffect(
                        x: CGFloat(max(model.level, 0.08)),
                        y: 1,
                        anchor: .leading
                    )
            }
            .accessibilityHidden(true)
    }
}
