import SwiftUI

/// 今天 tab(#82 骨架):每日回顾的落位页——健康、人物、情绪的每日一段(#84/#85/#87 逐步填)。
/// 骨架期只放两样真东西:今天的录音统计(纯本地)+ 各回顾块的诚实空态;
/// 绝不放「敬请期待」式的占位假内容,空态都说明数据从哪来、何时会有。
struct TodayView: View {
    @ObservedObject private var library = PhoneLink.shared.library
    /// 人物块点名字听原声(#85 v1):与各页共用同一个 PlaybackCenter。
    @ObservedObject var player: PlaybackCenter
    // 健康回顾(#80-P1):连过/读数两态分开记——「连过但空」要说清是授权还是没记录。
    @State private var health: HealthReader.Summary?
    @State private var healthLinked = false
    @State private var healthLoading = false

    private var todaysRecords: [RecordingRecord] {
        DayAgenda.todaysRecordings(library.records, now: Date())
    }

    private var totalMinutes: Int {
        Int(todaysRecords.reduce(0) { $0 + $1.durationSeconds } / 60)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("今日概览")
                            .font(.headline)
                        Text(todaysRecords.isEmpty
                            ? "今天还没有录音。需要记一笔,去「计划」安排,或去「记录」开录。"
                            : "今天录了 \(todaysRecords.count) 条,共 \(totalMinutes) 分钟。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)

                    healthBlock
                    peopleBlock
                    reviewBlock(
                        title: "情绪",
                        icon: "face.smiling",
                        text: "一天里的紧张与放松时刻,随场景回顾能力上线后在这里呈现。"
                    )
                }
                .padding(.vertical, 8)
            }
            .navigationTitle("今天")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if let playingID = player.playingID,
                   let record = library.records.first(where: { $0.id == playingID }) {
                    PlaybackBarView(player: player, record: record)
                }
            }
        }
    }

    // MARK: - 人物(#85 v1)

    /// 今天的声音里提到的人:digest 顺手抽取(名字按「关于我」词表的写法对齐),
    /// 点人名播最近一条提到 TA 的录音。没提到=诚实空态。
    private var peopleBlock: some View {
        let mentions = DayAgenda.peopleMentions(library.records, now: Date())
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "person.2")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("人物")
                        .font(.subheadline.weight(.medium))
                    if mentions.isEmpty {
                        Text("今天的声音里还没提到具体的人。转写整理时会把提到的人记到这里;常用称呼可在「我的 → 关于我」里定规范写法。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(mentions) { mention in
                            Button {
                                if let first = mention.sources.first {
                                    player.toggle(first, fileURL: library.fileURL(id: first.id))
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Text(mention.name)
                                        .font(.subheadline)
                                    Text(mention.count == 1
                                        ? "来自「\(mention.sources[0].title)」"
                                        : "\(mention.count) 条录音")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("播放今天提到\(mention.name)的录音")
                        }
                        // 人物反向提醒(#85 最小版):最近提过、但三天没见的人,打开时提一嘴;不推送。
                        let quiet = DayAgenda.peopleQuietFor(library.records, now: Date())
                        if !quiet.isEmpty {
                            Text("三天没提到了:\(quiet.joined(separator: "、"))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 健康回顾(#80-P1 探针即首版)

    /// 三态:有数据=真展示;连过但空=诚实说明(未授权或没记录);没连过=引导按钮。
    /// 无授权整块降级不报错(#80 验收口径);聚合数字只在本机展示,不进 AI 输入。
    @ViewBuilder
    private var healthBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "heart.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("健康回顾")
                        .font(.subheadline.weight(.medium))
                    if healthLoading {
                        Text("正在读取…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let headline = health?.headline {
                        Text(headline)
                            .font(.subheadline)
                        Text("来自这台 iPhone 的健康数据(手表自动汇入);只在本机展示,不上传。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if healthLinked {
                        Text("已连接,但没读到数据——可能没授权,或手表还没有昨晚的睡眠与今天的步数。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("重试") { loadHealth() }
                            .font(.caption)
                    } else if HealthReader.isAvailable {
                        Text("读睡眠、步数与活动量,展示在这块;只读不写,也不上传。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            loadHealth()
                        } label: {
                            Label("连接健康数据", systemImage: "heart.text.square")
                                .font(.subheadline)
                        }
                        .accessibilityIdentifier("daytap.today.linkHealth")
                    } else {
                        Text("此设备不支持健康数据。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
    }

    private func loadHealth() {
        healthLoading = true
        Task {
            let summary = await HealthReader.requestAndSummarize()
            await MainActor.run {
                health = summary
                healthLinked = true
                healthLoading = false
            }
        }
    }

    private func reviewBlock(title: String, icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
    }
}
