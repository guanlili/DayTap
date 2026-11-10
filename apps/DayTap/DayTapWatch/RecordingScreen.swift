import SwiftUI

/// 手表录音页(#5→#24 极简化):一块红按钮,出问题才说话。
/// 启停:红按钮 / 握拳快捷指令 / 敲桌两下(#11);录音中按表冠回表盘继续录(audio 后台模式)。
/// 时间不再自绘——右上角系统状态栏已有;触发方式的说明收进手机端「使用指南」(#24 甲方定调)。
struct RecordingScreen: View {
    @ObservedObject var model: WatchModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmDiscard = false

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 10)

            if model.phase == .recording {
                HStack(spacing: 6) {
                    statusDot
                    Text(DayTapFormat.clock(model.elapsed))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                levelBar
            } else if model.permissionDenied {
                Text("请在手表设置里允许 DayTap 使用麦克风")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                idleCluster
            }

            Spacer(minLength: 8)

            recordButton
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("丢弃待传录音?", isPresented: $confirmDiscard) {
            Button("丢弃", role: .destructive) { model.discardPending() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(model.transferWaiting) 条不会传给 iPhone，手表上直接删除。")
        }
        .onAppear {
            model.onAppear()
            model.setKnockListening(true)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.onActive()
                model.setKnockListening(true)
            case .background:
                // audio 后台模式:录音继续,不在这里停(#5);敲桌监听只在前台开。
                model.setKnockListening(false)
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onChange(of: model.phase) { _, phase in
            // 录音中不听敲桌(开始即目的达成);停录回闲时重新武装(#11)。
            model.setKnockListening(phase == .idle)
        }
    }

    /// 闲时聚落(#24 出问题才说话):瞬态结果最多一行;有待传/失败才出角标、
    /// 状态句与「再传一次」;有待传才出「丢弃待传」。全清时整块消失,只剩红按钮。
    @ViewBuilder
    private var idleCluster: some View {
        if !model.status.isEmpty {
            Text(model.status)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        transferBadge
        if model.transferWaiting > 0 || model.transferFailed > 0 {
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

    /// 传输角标(#4/#22):待确认(条数+占用)/失败一眼可读;有失败时补一行短原因。
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

    /// 显式录音大按钮(#23):像语音备忘录那样一眼可见、可按。
    /// 闲时=红色实心麦克风开录;录音中=白色方块停止。
    private var recordButton: some View {
        Button {
            model.toggle()
        } label: {
            Image(systemName: model.phase == .recording ? "stop.fill" : "mic.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.red))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.phase == .recording ? "停止并保存" : "开始录音")
        .accessibilityIdentifier("daytap.record.toggle")
    }

    /// 状态一枚小点:灰=闲,红=正在录。
    private var statusDot: some View {
        Circle()
            .fill(model.phase == .recording ? Color.red : Color.gray)
            .frame(width: 8, height: 8)
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
