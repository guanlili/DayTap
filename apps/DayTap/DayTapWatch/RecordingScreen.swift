import SwiftUI

/// 无感录音界面(#5):看起来就是一块报时表盘。
/// 抬腕看时间 = 武装;有人说话自动开录;全屏点按或握拳 = 立刻开录/停止。
/// 界面上没有大按钮——这个场景里,显眼的动作本身就是缺陷。
struct RecordingScreen: View {
    @ObservedObject var model: WatchModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            VStack(spacing: 6) {
                clock(timeline.date)

                statusDot
                    .padding(.vertical, 2)

                if model.phase != .idle {
                    levelBar
                } else if model.permissionDenied {
                    Text("请在手表设置里允许 DayTap 使用麦克风")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("点一下进入无感模式")
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
            .accessibilityLabel(accessibilitySummary)
            .accessibilityAddTraits(.isButton)
        }
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

    private var accessibilitySummary: String {
        switch model.phase {
        case .idle: return "无感录音,闲置,点按进入武装"
        case .armed: return "无感录音,已武装,听到说话自动开录,点按立刻开录"
        case .recording: return "无感录音,正在录音,点按停止并保存"
        }
    }
}
