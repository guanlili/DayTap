import SwiftUI
import UniformTypeIdentifiers

/// iPhone 上的收件箱。不做录音。
/// 分享:Track 2 交给得到大脑,或 Track 1 交给飞书妙记 / 文件 / 隔空投送到 Mac。
/// 试听与重命名(#2):行内播放/暂停带进度;长按重命名,分享导出文件名跟随。
struct RecordingListView: View {
    @ObservedObject private var link = PhoneLink.shared
    @ObservedObject private var library = PhoneLink.shared.library
    @StateObject private var player = PlaybackCenter()
    @Environment(\.scenePhase) private var scenePhase

    @State private var exportURL: URL?
    @State private var exportName = "DayTap.m4a"
    @State private var showExporter = false
    @State private var banner: String?
    @State private var renamingRecord: RecordingRecord?
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            Group {
                if library.records.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("DayTap")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text(link.sessionReady ? "通道就绪" : "未连接")
                        .font(.caption)
                        .foregroundStyle(link.sessionReady ? .green : .secondary)
                }
            }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportURL.map { M4AFile(url: $0) },
            contentType: .mpeg4Audio,
            defaultFilename: exportName
        ) { result in
            if case .failure(let error) = result {
                banner = error.localizedDescription
                DayTapLog.library.error("file export failed \(error.localizedDescription, privacy: .public)")
            }
        }
        .onOpenURL { url in
            banner = "已打开 DayTap 录音列表"
            DayTapLog.link.info("open url \(url.absoluteString, privacy: .public)")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                link.activate()
            } else if phase != .inactive {
                player.reset()
            }
        }
        .alert("重命名", isPresented: renameBinding) {
            TextField("录音名称", text: $newName)
            Button("保存") { commitRename() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("列表标题与分享、导出的文件名都会跟随新名字。留空则恢复默认时间戳名。")
        }
    }

    /// 只在选中的那条还在时弹 alert,避免多条同时弹。
    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renamingRecord != nil },
            set: { if !$0 { renamingRecord = nil } }
        )
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("还没有手表录音")
                .font(.title2.bold())
            Text("在 Apple Watch 上打开 DayTap，点一次「开始」，再点「停止」。音频会出现在这里。")
            Text(link.status)
                .font(.footnote)
                .foregroundStyle(.secondary)
            trackNote
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var list: some View {
        List {
            Section {
                Text(link.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let banner {
                    Text(banner)
                        .font(.footnote)
                }
                trackNote
            }
            Section("最近录音") {
                ForEach(library.records) { record in
                    row(record)
                }
            }
        }
    }

    private func row(_ record: RecordingRecord) -> some View {
        let fileExists = FileManager.default.fileExists(atPath: library.fileURL(id: record.id).path)

        return VStack(alignment: .leading, spacing: 8) {
            Text(record.title)
                .font(.body.weight(.semibold))
            Text(subtitle(for: record))
                .font(.caption)
                .foregroundStyle(.secondary)

            if player.playingID == record.id {
                playbackBar(record)
            }

            HStack(spacing: 16) {
                Button {
                    guard fileExists else {
                        banner = "找不到这条音频文件"
                        return
                    }
                    player.toggle(record, fileURL: library.fileURL(id: record.id))
                } label: {
                    Label(
                        player.playingID == record.id && player.isPlaying ? "暂停" : "试听",
                        systemImage: player.playingID == record.id && player.isPlaying
                            ? "pause.fill" : "play.fill"
                    )
                }
                .disabled(!fileExists)
                .accessibilityIdentifier("daytap.play.\(record.id)")

                if fileExists, let shareURL = link.shareFileURL(for: record) {
                    ShareLink(
                        item: DayTapAudioFile(url: shareURL),
                        preview: SharePreview(
                            record.title,
                            image: Image(systemName: "waveform")
                        )
                    ) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("daytap.share.\(record.id)")
                }

                Button {
                    prepareExport(record)
                } label: {
                    Label("存到文件", systemImage: "folder")
                }
                .disabled(!fileExists)
            }
            .font(.callout)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button {
                newName = record.displayName ?? ""
                renamingRecord = record
            } label: {
                Label("重命名", systemImage: "pencil")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("daytap.recording.\(record.id)")
    }

    /// 试听进度:一行时间 + 细进度条。只占播放中那一行。
    private func playbackBar(_ record: RecordingRecord) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(DayTapFormat.clock(player.elapsed))
                Spacer()
                Text(DayTapFormat.clock(max(player.duration, record.durationSeconds)))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)

            ProgressView(value: player.progress)
                .tint(.accentColor)
        }
        .accessibilityIdentifier("daytap.playback.\(record.id)")
    }

    private func subtitle(for record: RecordingRecord) -> String {
        let date = record.createdAt.formatted(date: .abbreviated, time: .shortened)
        let size = "\(DayTapFormat.clock(record.durationSeconds)) · \(DayTapFormat.bytes(record.byteCount)) · m4a"
        // 起了名的条目,标题已经是名字,这里补回时间;没起名的避免时间出现两遍。
        if let name = record.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return "\(date) · \(size)"
        }
        return size
    }

    private var trackNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("手表只负责录音，不连接得到。")
            Text("Track 1：分享或「存到文件」后，用飞书妙记、快捷指令转写，或把文件送到 Mac 做系统转写。文字再贴给 Bot。不要把这条音频送进得到。")
            Text("Track 2：点「分享」，选得到大脑；或在得到里用「导入音视频」选这个 m4a。得到只在这台 iPhone 上。")
            Text("在「文件」App 里打开：我的 iPhone → DayTap。链接 daytap://recordings 会回到这个列表。")
            Text("这是开发版，还不能从 App Store 安装。表上没装好时，用手机上的得到、语音备忘录或飞书妙记录（Track 0）。")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func prepareExport(_ record: RecordingRecord) {
        guard let url = link.shareFileURL(for: record) else {
            banner = "找不到这条音频文件"
            return
        }
        exportURL = url
        exportName = url.lastPathComponent
        showExporter = true
    }

    /// 落名:取库里最新那条改,不覆盖传输状态的并发更新。空名=清掉,恢复时间戳名。
    private func commitRename() {
        guard let target = renamingRecord else { return }
        renamingRecord = nil
        guard var fresh = library.record(id: target.id) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        fresh.displayName = trimmed.isEmpty ? nil : trimmed
        library.upsert(fresh)
        DayTapLog.library.info("renamed \(target.id, privacy: .public)")
    }
}
