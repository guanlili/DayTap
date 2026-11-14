import SwiftUI
import WatchKit

/// 手表主屏(#44 重排):一枚 68pt 红钮绝对居中,不与任何元素纵向堆叠。
/// 传输状态收敛成左上角标(#46:失败=橙三角,待传=橙点+↑),报告与「再传一次/丢弃待传」
/// 全部移入传输 sheet(#45)——点角标或长按主按钮 0.6s 打开,主屏不再说话。
/// 启停:红按钮 / 握拳快捷指令 / 敲桌两下(#11);录音中按表冠回表盘继续录(audio 后台模式)。
/// 麦克风被拒(#46):按钮 35% 不透明+斜线,点按只给失败触觉,底部两行出路,不弹 alert。
struct RecordingScreen: View {
    @ObservedObject var model: WatchModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showTransferSheet = false
    @State private var ringPulse = false
    @State private var savedFlash = false
    /// 长按成功的 suppress 窗口(#59):onTap/onLongPress 并挂时,部分系统长按松手还会补一发
    /// tap——把正在录的误停。窗口内 tap 一律吞掉。
    @State private var suppressTapUntil = Date.distantPast
    /// savedFlash 序号(#59):0.35s 内二次停录时,旧闭包不掐灭新一闪。
    @State private var flashToken = 0


    var body: some View {
        ZStack {
            recordButton
            if model.phase == .recording {
                VStack {
                    // 计时挂顶部、不参与堆叠——按钮在闲/录两态的位置逐像素一致(#44)。
                    Text(DayTapFormat.clock(model.elapsed))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.top, 18)
                    Spacer(minLength: 0)
                }
            } else if model.permissionDenied {
                VStack {
                    Spacer(minLength: 0)
                    Text("麦克风未授权\n在设置里允许后可用")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 14)
                }
            } else if savedFlash {
                // #44 决策点3:停录「已保存」0.35s 一闪——主屏唯一的瞬态字,常规保存的唯一回执;
                // 被打断这类异常不在这说,完整状态在传输 sheet 里。
                VStack {
                    Spacer(minLength: 0)
                    Text("已保存")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) { transferBadge }
        .sheet(isPresented: $showTransferSheet) {
            TransferSheet(model: model)
        }
        .onChange(of: showTransferSheet) { _, shown in
            // #59:sheet 打开期间撤敲桌监听,关闭恢复闲时监听——不在遮罩后面开录。
            model.setKnockListening(!shown)
        }
        .onAppear {
            model.onAppear()
            model.setKnockListening(true)
            // TEMP(截图):-demoRecording 自动开录,截完删
            if ProcessInfo.processInfo.arguments.contains("-demoRecording"), model.phase == .idle {
                model.toggle()
            }
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
                // #59:下拉通知中心等半失活态也不听敲桌——否则在看不见的地方静默开录。
                model.setKnockListening(false)
            @unknown default:
                break
            }
        }
        .onChange(of: model.phase) { old, phase in
            // 录音中不听敲桌(开始即目的达成);停录回闲时重新武装(#11)。
            model.setKnockListening(phase == .idle)
            ringPulse = false
            if old == .recording, phase == .idle, model.status.isEmpty {
                flashToken += 1
                let token = flashToken
                savedFlash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard token == flashToken else { return }
                    savedFlash = false
                }
            }
        }
    }

    /// 主操作(#44):68pt 绝对居中;闲=红 mic 开录,录=stop 停止。
    /// 短按启停;长按 0.6s 打开传输 sheet(#45 隐藏入口,不占屏)。
    /// 被拒=35% 不透明+斜线,点按只给失败触觉,不进录音流程(#46)。
    private var recordButton: some View {
        Image(
            systemName: model.permissionDenied
                ? "mic.slash.fill" : (model.phase == .recording ? "stop.fill" : "mic.fill")
        )
        .font(.system(size: 28, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 68, height: 68)
        .background(Circle().fill(Color.red))
        .overlay { breathingRing }
        .opacity(model.permissionDenied ? 0.35 : 1)
        .onTapGesture {
            guard Date() >= suppressTapUntil else { return }
            guard !model.permissionDenied else {
                WKInterfaceDevice.current().play(.failure)
                return
            }
            model.toggle()
        }
        .onLongPressGesture(minimumDuration: 0.6) {
            suppressTapUntil = Date().addingTimeInterval(0.8)
            showTransferSheet = true
        }
        // VO 可达(#59):长按是隐藏手势,给 VoiceOver 显式动作。
        .accessibilityAction(named: Text("传输详情")) {
            showTransferSheet = true
        }
        .accessibilityLabel(
            model.permissionDenied
                ? "麦克风未授权" : (model.phase == .recording ? "停止并保存" : "开始录音")
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("daytap.record.toggle")
    }

    /// 录音中的音量环(#46):透明度跟音量,1.2s 呼吸放大;减少动态时只剩颜色变化。
    @ViewBuilder
    private var breathingRing: some View {
        if model.phase == .recording {
            let intensity = Double(max(min(model.level, 1), 0)) * 0.75 + 0.25
            Circle()
                .stroke(Color.red.opacity(intensity), lineWidth: 3)
                .padding(6)
                .scaleEffect(reduceMotion ? 1 : (ringPulse ? 1.08 : 1))
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                        ringPulse = true
                    }
                }
                .accessibilityHidden(true)
        }
    }

    /// 左上角传输角标(#44/#46):内缩 14pt,无待传无失败时完全不出现。
    /// 待传=橙点+↑(≥2 条才出数字);失败优先,换成橙三角+条数——失败要处理,待传只是等待。
    /// 点按打开传输 sheet(#45)。
    @ViewBuilder
    private var transferBadge: some View {
        if model.transferFailed > 0 || model.transferWaiting > 0 {
            let failed = model.transferFailed > 0
            Button {
                showTransferSheet = true
            } label: {
                HStack(spacing: 3) {
                    if failed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("\(model.transferFailed)")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                    } else {
                        Circle()
                            .fill(Color.daytapBadgeOrange)
                            .frame(width: 6, height: 6)
                        Image(systemName: "arrow.up")
                            .font(.system(size: 9, weight: .bold))
                        if model.transferWaiting >= 2 {
                            Text("\(model.transferWaiting)")
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                        }
                    }
                }
                .foregroundStyle(Color.daytapBadgeOrange)
                // #59:热区扩到 44×44(watchOS HIG 最小可点目标);内衬 8+外衬 6=视觉仍钉 14pt 内缩。
                .padding(8)
                .frame(minWidth: 44, minHeight: 44, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            .padding(.leading, 6)
            .accessibilityLabel(
                failed ? "\(model.transferFailed) 条传输失败" : "\(model.transferWaiting) 条待传"
            )
            .accessibilityIdentifier("daytap.transfer.badge")
        }
    }
}
