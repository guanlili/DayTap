import SwiftUI

/// 无感录音界面(#5):看起来就是一块报时表盘。
/// 点一下开始/停止,握拳(AssistiveTouch 绑快捷指令)同样启停;
/// 录着的时候按表冠回表盘继续录(audio 后台模式),不亮屏不出声。
/// 手动触发:VAD 自动开录经甲方真机体验后撤下(环境音误触),2026-11-10。
struct RecordingScreen: View {
    @ObservedObject var model: WatchModel
    @Environment(\.scenePhase) private var scenePhase

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
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { model.toggle() }
            .accessibilityIdentifier("daytap.record.toggle")
            .accessibilityLabel(model.phase == .recording ? "正在录音,点按停止并保存" : "录音,点按开始")
            .accessibilityAddTraits(.isButton)
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
