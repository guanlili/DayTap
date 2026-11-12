import SwiftUI

/// 最近删除(#26):软删条目恢复/彻底删/清空,30 天到期由 PhoneLink 启动清扫。
struct TrashView: View {
    @ObservedObject var library: RecordingLibrary
    @State private var confirmPurgeAll = false

    private var trashed: [RecordingRecord] {
        library.records.filter { $0.deletedAt != nil }
    }

    var body: some View {
        List {
            Section {
                ForEach(trashed) { record in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.title)
                            .font(.body.weight(.semibold))
                            .lineLimit(2)
                        Text("删除于 \(record.deletedAt?.formatted(date: .abbreviated, time: .shortened) ?? "") · 剩 \(daysLeft(record)) 天")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            PhoneLink.shared.restore(id: record.id)
                        } label: {
                            Label("恢复", systemImage: "arrow.uturn.backward")
                        }
                        .tint(.accentColor)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            PhoneLink.shared.purgeNow(id: record.id)
                        } label: {
                            Label("彻底删除", systemImage: "trash")
                        }
                    }
                }
            } footer: {
                Text("删除的录音保留 30 天，到期自动清除；恢复后回到列表。")
            }
        }
        .navigationTitle("最近删除")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !trashed.isEmpty {
                    Button("清空", role: .destructive) {
                        confirmPurgeAll = true
                    }
                }
            }
        }
        .confirmationDialog(
            "清空最近删除？",
            isPresented: $confirmPurgeAll,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                for record in trashed {
                    PhoneLink.shared.purgeNow(id: record.id)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将彻底删除 \(trashed.count) 条，不可恢复。")
        }
    }

    private func daysLeft(_ record: RecordingRecord) -> Int {
        guard let deletedAt = record.deletedAt else { return 30 }
        let days = Int(Date().timeIntervalSince(deletedAt) / 86_400)
        return max(0, 30 - days)
    }
}

