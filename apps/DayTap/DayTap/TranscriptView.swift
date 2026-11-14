import SwiftUI

/// 全文页(#30/#32):时间戳分段渲染、点句跳播、跟读滚动;无分段旧转写降级纯文本。
/// 全文 sheet(#16 → #32 时间戳模式):点句子=跳到那一刻播放;播放时当前句高亮+跟读滚动;
/// 底部内嵌迷你播放条,拖它高亮跟着走(双向锚定)。无分段的老转写退回纯文本。
/// 顶栏保留 重新转写/分享文字,底栏 复制全文 与播放条并存。
struct TranscriptView: View {
    /// 待办行操作反馈(添加到提醒事项/日历/复制的就地一行)。
    @State private var actionFeedback = ""

    let recordID: String
    @ObservedObject var library: RecordingLibrary
    @ObservedObject var transcriber: TranscriptionCenter
    @ObservedObject var player: PlaybackCenter
    /// 高频走钟(#63):跟读滚动与迷你条观察 clock,不牵动观察 player 的整屏。
    @ObservedObject var clock: PlaybackCenter.Clock

    /// 完成态落库(#61/#62):手动勾选写回索引;重新转写会整体重算待办(勾选重置),类别纠偏保留。
    private func toggleDone(_ updated: ActionItem) {
        guard var fresh = library.record(id: recordID),
              var items = fresh.actionItems,
              let index = items.firstIndex(where: { $0.id == updated.id })
        else { return }
        items[index] = updated
        fresh.actionItems = items
        fresh.updatedAt = Date()  // 勾选也是变更(#62):CloudSync 增量按 updatedAt 判脏
        library.upsert(fresh)
    }

    private var record: RecordingRecord? {
        library.record(id: recordID)
    }

    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: library.fileURL(id: recordID).path)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let segments = record?.transcriptSegments, !segments.isEmpty {
                    VStack(spacing: 0) {
                        digestCard
                        segmentList(segments)
                    }
                } else if let text = record?.transcript {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            digestCard
                            Text(text)
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                    }
                } else if transcriber.activeID == recordID {
                    ProgressView("正在转写…")
                } else {
                    Text("还没有转写文字")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(record?.title ?? "全文")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if let record {
                            transcriber.retranscribe(record)
                        }
                    } label: {
                        Label("重新转写", systemImage: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let text = record?.transcript {
                        ShareLink(item: text) {
                            Label("分享文字", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    HStack {
                        if digestCardText != nil {
                            Button {
                                UIPasteboard.general.string = digestCardText
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                            } label: {
                                Label("复制卡片", systemImage: "checklist")
                            }
                            .accessibilityIdentifier("daytap.digest.copy")
                        }

                        Button {
                            UIPasteboard.general.string = record?.transcript
                        } label: {
                            Label("复制全文", systemImage: "doc.on.doc")
                        }
                        .disabled(record?.transcript == nil)

                        if fileExists, let record {
                            miniPlayer(record)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 摘要卡(#35)

    /// 全文页顶部的「决策卡」:摘要+待办,转写完本机自动出;没有就整卡不占位。
    @ViewBuilder
    private var digestCard: some View {
        if record?.summary != nil || record?.actionItems != nil {
            VStack(alignment: .leading, spacing: 10) {
                if let summary = record?.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                }
                if let actions = record?.actionItems, !actions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(actions) { item in
                            ActionItemRow(
                                item: item,
                                sourceTitle: record?.title ?? recordID,
                                onToggleDone: { toggleDone($0) },
                                feedback: $actionFeedback
                            )
                        }
                        if !actionFeedback.isEmpty {
                            Text(actionFeedback)
                                .font(.caption2)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .accessibilityIdentifier("daytap.digest.card")
        }
    }

    /// 「复制卡片」的文本(#35):【摘要】+【待办】清单;两样都没有则按钮不出现。
    private var digestCardText: String? {
        guard let record else { return nil }
        var parts: [String] = []
        if let summary = record.summary, !summary.isEmpty {
            parts.append("【摘要】\(summary)")
        }
        if let actions = record.actionItems, !actions.isEmpty {
            parts.append("【待办】\n" + actions.map { item in
                var line = "· \(item.text)"
                if let due = item.dueAt {
                    line += "（截止 \(due.formatted(date: .abbreviated, time: .shortened))）"
                }
                if item.isDone { line += " ✓" }
                return line
            }.joined(separator: "\n"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    // MARK: - 时间戳分段(#32)

    /// 正在播这条时,当前时刻落在哪个分段(最后一个 start ≤ 时刻 的段)。
    private var currentSegmentIndex: Int? {
        guard player.playingID == recordID,
              let segments = record?.transcriptSegments, !segments.isEmpty
        else { return nil }
        var found: Int?
        for (index, segment) in segments.enumerated() where segment.start <= clock.elapsed + 0.01 {
            found = index
        }
        return found
    }

    private func segmentList(_ segments: [TranscriptSegment]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        segmentRow(segment, isCurrent: index == currentSegmentIndex)
                            .id(index)
                    }
                }
                .padding()
            }
            .onChange(of: currentSegmentIndex) { _, newIndex in
                guard let newIndex, player.isPlaying else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    private func segmentRow(_ segment: TranscriptSegment, isCurrent: Bool) -> some View {
        Button {
            guard fileExists, let record else { return }
            player.toggle(record, fileURL: library.fileURL(id: recordID), at: segment.start)
        } label: {
            Text(segment.text)
                .font(.body)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCurrent ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .accessibilityLabel("第 \(Int(segment.start)) 秒起：\(segment.text)")
    }

    /// 内嵌迷你播放条(#32):播放中显示 进度+拖动+倍速;闲时一枚播放钮。
    @ViewBuilder
    private func miniPlayer(_ record: RecordingRecord) -> some View {
        if player.playingID == recordID {
            HStack(spacing: 8) {
                Button {
                    player.toggle(record, fileURL: library.fileURL(id: recordID))
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.footnote)
                        .frame(width: 26, height: 26)
                }
                Text(DayTapFormat.clock(clock.elapsed))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                DensityScrubber(
                    segments: record.transcriptSegments,
                    duration: max(record.durationSeconds, 0.1),
                    progress: clock.progress,
                    onScrub: { player.scrub(to: $0) }
                )
                Text(DayTapFormat.clock(player.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 260)
        } else {
            Button {
                player.toggle(record, fileURL: library.fileURL(id: recordID))
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
            }
            .accessibilityLabel("播放")
        }
    }
}

/// 最近删除(#26):删除先进这里,30 天保留期内可恢复;到期 PhoneLink 启动时自动彻底清除。
