import SwiftUI

/// 事的聚合·形态 A(#78):长按一条录音 → 自动找出谈同一件事的其他录音(可勾除)→
/// 生成跨录音进展摘要(现状/关键进展/未决待办)。零实体、不落库,关页即弃。
struct AffairSheet: View {
    let seed: RecordingRecord
    let transcriber: TranscriptionCenter
    /// 候选池(快照即可——按需一次性,聚合期间列表变化不追)。
    let allRecords: [RecordingRecord]

    @Environment(\.dismiss) private var dismiss
    @State private var includedIDs: Set<String> = []
    @State private var running = false
    @State private var result: AffairResult?
    @State private var note = ""

    private var related: [RecordingRecord] {
        AffairCluster.relatedRecords(seed: seed, in: allRecords, now: Date())
    }

    private var selectedRecords: [RecordingRecord] {
        ([seed] + related.filter { includedIDs.contains($0.id) }).sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    row(seed, subtitle: "发起聚合的这条")
                    if related.isEmpty {
                        Text("最近 30 天没找到与它谈同一件事的其他录音(同人物或内容高度重叠才算)。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(related) { record in
                            Button {
                                if includedIDs.contains(record.id) {
                                    includedIDs.remove(record.id)
                                } else {
                                    includedIDs.insert(record.id)
                                }
                            } label: {
                                row(record, subtitle: nil)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("相关录音(自动判定)")
                } footer: {
                    Text("按「提到同一人物」或「内容高度重叠」自动判定;轻点可勾除不参与的。")
                }

                if !selectedRecords.isEmpty || !related.isEmpty {
                    Section {
                        Button {
                            generate()
                        } label: {
                            HStack {
                                Label("生成进展摘要", systemImage: "sparkles")
                                if running {
                                    Spacer()
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .disabled(running || includedIDs.isEmpty && related.isEmpty)
                        if let result {
                            VStack(alignment: .leading, spacing: 8) {
                                if !result.status.isEmpty {
                                    Text(result.status)
                                        .font(.subheadline)
                                }
                                if !result.highlights.isEmpty {
                                    Text("关键进展")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    ForEach(result.highlights, id: \.self) { item in
                                        Text("· \(item)")
                                            .font(.caption)
                                    }
                                }
                                if !result.openTodos.isEmpty {
                                    Text("未决待办")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    ForEach(result.openTodos, id: \.self) { item in
                                        Text("· \(item)")
                                            .font(.caption)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        if !note.isEmpty {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("进展摘要")
                    } footer: {
                        Text("按需一次性,不保存;发起条目始终参与。")
                    }
                }
            }
            .navigationTitle("事的聚合")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                if includedIDs.isEmpty {
                    includedIDs = Set(related.map(\.id))
                }
            }
        }
    }

    private func row(_ record: RecordingRecord, subtitle: String?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(record.title)
                    .font(.subheadline)
                Text(subtitle ?? record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if subtitle == nil {
                Image(systemName: includedIDs.contains(record.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }

    private func generate() {
        running = true
        note = ""
        let records = selectedRecords
        Task {
            let output = await transcriber.affairSummary(records: records)
            await MainActor.run {
                running = false
                if let output, !(output.status.isEmpty && output.highlights.isEmpty && output.openTodos.isEmpty) {
                    result = output
                } else {
                    note = "没能生成——本机 Apple 智能与云端模型都不可用时出不来,可在「我的 → AI 模型」里配置。"
                }
            }
        }
    }
}
