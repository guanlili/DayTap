import SwiftUI

/// 播放条支撑(#57→#80 拆文件批次):各 tab 底部共用的行内播放条。

/// 行内播放条(#63 独立观察):整条下沉成子视图,自己观察 clock——
/// 4Hz 只重画这一小条,列表主体不再随 tick 全量重算。
/// #80 起 Day 页跳播也用它,摘 internal。
struct PlaybackBarView: View {
    @ObservedObject var player: PlaybackCenter
    @ObservedObject private var clock: PlaybackCenter.Clock
    let record: RecordingRecord

    init(player: PlaybackCenter, record: RecordingRecord) {
        self.player = player
        self._clock = ObservedObject(wrappedValue: player.clock)
        self.record = record
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(DayTapFormat.clock(clock.elapsed))
                Spacer()
                Button {
                    player.cycleRate()
                } label: {
                    Text(speedLabel)
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("播放速度\(speedLabel)")

                // 跳静音(#37):有分段才显示;开着=落在分段间隙自动跳下一句。
                if record.transcriptSegments != nil {
                    Button {
                        player.toggleSkipSilence()
                    } label: {
                        Text("跳静音")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(player.skipsSilence ? Color.white : Color.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(player.skipsSilence ? Color.accentColor : Color.secondary.opacity(0.15))
                            )
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(player.skipsSilence ? "跳静音,已开" : "跳静音,已关")
                    .accessibilityIdentifier("daytap.skipsilence")
                }
                Spacer()
                Text(DayTapFormat.clock(max(player.duration, record.durationSeconds)))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)

            // 密度播放条(#69):轨道按分段字数着色,长录一眼找「讲得密的段」;拖动/点按与原 Slider 一致。
            DensityScrubber(
                segments: record.transcriptSegments,
                duration: max(record.durationSeconds, 0.1),
                progress: clock.progress,
                onScrub: { player.scrub(to: $0) }
            )
        }
        .accessibilityIdentifier("daytap.playback.\(record.id)")
    }

    private var speedLabel: String {
        player.rate == 1.5 ? "1.5x" : (player.rate == 2.0 ? "2x" : "1x")
    }
}
