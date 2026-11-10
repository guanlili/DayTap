import SwiftUI
import UniformTypeIdentifiers

/// iPhone 上的收件箱。不做录音。
/// 转文字：点「转文字」用系统语音识别在本机出全文，全文进 sheet 查看、复制、分享。
/// 分享:Track 2 交给得到大脑,或 Track 1 交给飞书妙记 / 文件 / 隔空投送到 Mac。
/// 试听与重命名(#2):行内播放/暂停带进度;长按重命名,分享导出文件名跟随。
/// #15 重设计:首屏只留录音本身——指南收进工具栏 ⓘ sheet,状态「出问题才说话」。
/// #19 二稿(less is more):行内只留标题+副标题+一个播放键(整行轻点=试听),
/// 分享/存到文件/转文字/重命名收进长按菜单,左右轻扫给快捷;去掉波形图标与行内胶囊。
struct RecordingListView: View {
    @ObservedObject private var link = PhoneLink.shared
    @ObservedObject private var library = PhoneLink.shared.library
    @StateObject private var player = PlaybackCenter()
    @StateObject private var transcriber = TranscriptionCenter(library: PhoneLink.shared.library)
    @StateObject private var recorder = PhoneRecorder()
    @Environment(\.scenePhase) private var scenePhase

    @State private var exportURL: URL?
    @State private var exportName = "DayTap.m4a"
    @State private var showExporter = false
    @State private var banner: String?
    @State private var renamingRecord: RecordingRecord?
    @State private var newName = ""
    @State private var deletingRecord: RecordingRecord?
    @State private var transcriptRecord: RecordingRecord?
    @State private var shareRecord: RecordingRecord?
    @State private var showGuide = false

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
                    Button {
                        showGuide = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("使用指南")
                    .accessibilityIdentifier("daytap.guide")
                }
                ToolbarItem(placement: .bottomBar) {
                    recordControl
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
            // #15:「已打开录音列表」对正在看屏幕的人没有信息量,只留日志。
            DayTapLog.link.info("open url \(url.absoluteString, privacy: .public)")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                link.activate()
            } else if phase != .inactive {
                player.reset()
                // 手机不开后台模式:退后台即停录保存(#3),与手表同口径。
                if recorder.isRecording {
                    recorder.toggle()
                }
            }
        }
        .alert("重命名", isPresented: renameBinding) {
            TextField("录音名称", text: $newName)
            Button("保存") { commitRename() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("列表标题与分享、导出的文件名都会跟随新名字。留空则恢复默认时间戳名。")
        }
        .confirmationDialog(
            "删除「\(deletingRecord?.title ?? "")」？",
            isPresented: deleteBinding,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { commitDelete() }
            Button("取消", role: .cancel) { deletingRecord = nil }
        } message: {
            Text("手机上的音频与索引会一并删除，不可恢复。")
        }
        .sheet(item: $transcriptRecord) { record in
            TranscriptView(
                recordID: record.id,
                library: PhoneLink.shared.library,
                transcriber: transcriber
            )
        }
        .sheet(item: $shareRecord) { record in
            ActivityShareSheet(url: library.fileURL(id: record.id))
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showGuide) {
            GuideSheet()
        }
    }

    /// 只在选中的那条还在时弹 alert,避免多条同时弹。
    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renamingRecord != nil },
            set: { if !$0 { renamingRecord = nil } }
        )
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { deletingRecord != nil },
            set: { if !$0 { deletingRecord = nil } }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 104, height: 104)
                Image(systemName: "waveform")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 8) {
                Text("还没有录音")
                    .font(.title3.bold())
                Text("手表点一下「开始」，或点下方红钮用 iPhone 直接录。\n录完都会出现在这里。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if !link.sessionReady {
                HStack(spacing: 6) {
                    Image(systemName: "applewatch")
                    Text(link.status)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }

            Button {
                showGuide = true
            } label: {
                Label("使用指南", systemImage: "book")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 首屏 = 录音本身。手表未连接 / 报错 / 转写进度才在顶部多出小卡,平时完全安静。
    private var list: some View {
        List {
            if !link.sessionReady || banner != nil || player.loadError != nil
                || transcriber.statusText != nil || recorder.statusText != nil {
                Section {
                    if !link.sessionReady {
                        statusCard
                    }
                    if let banner {
                        errorCard(banner)
                    }
                    if let playError = player.loadError {
                        errorCard(playError)
                            .accessibilityIdentifier("daytap.play.error")
                    }
                    if let status = transcriber.statusText {
                        HStack(spacing: 8) {
                            if transcriber.activeID != nil {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(status)
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("daytap.transcribe.status")
                    }
                    if let status = recorder.statusText {
                        HStack(spacing: 8) {
                            Text(status)
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("daytap.phone.status")
                    }
                }
            }

            Section {
                ForEach(library.records) { record in
                    row(record)
                }
            }
        }
    }

    /// 底栏录音钮(#3):闲时红色大麦克风;录时红点+计时+音量条+停止键。语音备忘录的语言。
    @ViewBuilder
    private var recordControl: some View {
        if recorder.isRecording {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                Text(DayTapFormat.clock(recorder.elapsed))
                    .font(.callout.monospacedDigit())
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 64, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.red)
                            .frame(width: 64 * CGFloat(max(recorder.level, 0.08)), height: 4)
                    }
                    .accessibilityHidden(true)
                Spacer()
                Button {
                    recorder.toggle()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.red))
                }
                .accessibilityLabel("停止并保存")
                .accessibilityIdentifier("daytap.phone.stop")
            }
        } else {
            Button {
                recorder.toggle()
            } label: {
                Image(systemName: "mic.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.red))
            }
            .accessibilityLabel("用 iPhone 录音")
            .accessibilityIdentifier("daytap.phone.record")
        }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "applewatch")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("等待手表")
                    .font(.subheadline.weight(.semibold))
                Text(link.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("daytap.link.status")
    }

    private func errorCard(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
        }
        .listRowBackground(Color.orange.opacity(0.12))
        .accessibilityIdentifier("daytap.banner")
    }

    /// #19 极简行:标题+副标题+一个播放键,整行轻点=试听;
    /// 其余动作全在长按菜单,轻扫给快捷(左滑转文字/全文,右滑分享)。
    private func row(_ record: RecordingRecord) -> some View {
        let fileExists = FileManager.default.fileExists(atPath: library.fileURL(id: record.id).path)
        let active = player.playingID == record.id
        let playing = active && player.isPlaying

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Text(subtitle(for: record))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if active {
                    playbackBar(record)
                }
            }

            Spacer(minLength: 8)

            Button {
                togglePlay(record, fileExists: fileExists)
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(active ? Color.white : Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle().fill(active ? Color.red : Color.accentColor.opacity(0.12))
                    )
            }
            .disabled(!fileExists)
            .buttonStyle(.borderless)
            .accessibilityLabel(playing ? "暂停" : "试听")
            .accessibilityIdentifier("daytap.play.\(record.id)")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { togglePlay(record, fileExists: fileExists) }
        .contextMenu {
            if record.transcript != nil {
                Button {
                    transcriptRecord = record
                } label: {
                    Label("查看全文", systemImage: "text.quote")
                }
                .accessibilityIdentifier("daytap.transcript.\(record.id)")
            } else if fileExists {
                Button {
                    transcriber.transcribe(record)
                } label: {
                    Label("转文字", systemImage: "text.bubble")
                }
                .disabled(transcriber.activeID != nil)
                .accessibilityIdentifier("daytap.transcribe.\(record.id)")
            }

            Button {
                shareRecord = record
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
            }
            .disabled(!fileExists)
            .accessibilityIdentifier("daytap.share.\(record.id)")

            Button {
                prepareExport(record)
            } label: {
                Label("存到文件", systemImage: "folder")
            }
            .disabled(!fileExists)

            Button {
                newName = record.displayName ?? ""
                renamingRecord = record
            } label: {
                Label("重命名", systemImage: "pencil")
            }

            Button(role: .destructive) {
                deletingRecord = record
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                shareRecord = record
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
            }
            .tint(.accentColor)
            .disabled(!fileExists)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deletingRecord = record
            } label: {
                Label("删除", systemImage: "trash")
            }

            if record.transcript != nil {
                Button {
                    transcriptRecord = record
                } label: {
                    Label("全文", systemImage: "text.quote")
                }
                .tint(.accentColor)
            } else if fileExists {
                Button {
                    transcriber.transcribe(record)
                } label: {
                    Label("转文字", systemImage: "text.bubble")
                }
                .tint(.accentColor)
                .disabled(transcriber.activeID != nil)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("daytap.recording.\(record.id)")
    }

    /// 整行与播放键共用一份启停逻辑,文件不在就提示。
    private func togglePlay(_ record: RecordingRecord, fileExists: Bool) {
        guard fileExists else {
            banner = "找不到这条音频文件"
            return
        }
        player.toggle(record, fileURL: library.fileURL(id: record.id))
    }

    /// 落删(#20):删的是正在播的先停播,再清索引+文件并记入防复活名单。
    private func commitDelete() {
        guard let target = deletingRecord else { return }
        deletingRecord = nil
        if player.playingID == target.id {
            player.reset()
        }
        link.forget(id: target.id)
    }

    /// 试听进度:一行时间 + 细进度条。只占播放中那一行,红进度与行首同色。
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
                .tint(.red)
        }
        .accessibilityIdentifier("daytap.playback.\(record.id)")
    }

    private func subtitle(for record: RecordingRecord) -> String {
        // 数字日期比「2026年11月10日」短一截,转写过的行才不至于折成两行(#19)。
        let date = record.createdAt.formatted(date: .numeric, time: .shortened)
        // 空壳文件(只有容器头)直接标出来,别让用户点开才发现播不了;
        // 正常条目带「已转文字」标记;手机录的标来源(#3)。byteCount 已按真实落盘大小;
        // 不写 m4a——条条都是,语音备忘录也不标格式,格式知识在指南里(#19)。
        var mark = record.origin == "phone" ? "手机录 · " : ""
        if record.byteCount < 1024 {
            mark += "空录音 · "
        } else if record.transcript != nil {
            mark += "已转文字 · "
        }
        let size = "\(DayTapFormat.clock(record.durationSeconds)) · \(DayTapFormat.bytes(record.byteCount))"
        // 起了名的条目,标题已经是名字,这里补回时间;没起名的避免时间出现两遍。
        if let name = record.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return "\(date) · \(mark)\(size)"
        }
        return mark + size
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

/// 全文 sheet:转写结果的可选中文本,配复制 / 分享文字 / 重新转写。
/// 内容按 id 从库内实时取,重转完成后文字自动刷新。
private struct TranscriptView: View {
    let recordID: String
    @ObservedObject var library: RecordingLibrary
    @ObservedObject var transcriber: TranscriptionCenter

    private var record: RecordingRecord? {
        library.record(id: recordID)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let text = record?.transcript {
                    ScrollView {
                        Text(text)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
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
                            transcriber.transcribe(record)
                        }
                    } label: {
                        Label("重新转写", systemImage: "arrow.clockwise")
                    }
                    .disabled(transcriber.activeID != nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let text = record?.transcript {
                        ShareLink(item: text) {
                            Label("分享文字", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        UIPasteboard.general.string = record?.transcript
                    } label: {
                        Label("复制全文", systemImage: "doc.on.doc")
                    }
                    .disabled(record?.transcript == nil)
                }
            }
        }
    }
}

/// 使用指南(#15):原首屏文字墙收纳于此,内容一字不丢,只换排版。
private struct GuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("分工") {
                    guideRow(
                        icon: "applewatch",
                        title: "手表和 iPhone 都能录音，不连接得到。",
                        detail: "手表录音传到 iPhone 确认保存后，手表原件自动清除；iPhone 点列表下方红钮也能直接录（手机录的只存在本机）。"
                    )
                }

                Section("操作") {
                    guideRow(
                        icon: "hand.tap",
                        title: "轻点 · 长按 · 轻扫",
                        detail: "轻点录音行=试听；长按=分享 / 存到文件 / 转文字 / 重命名 / 删除；左滑出「转文字」「全文」或「删除」，右滑出「分享」。"
                    )
                }

                Section("转写路线") {
                    guideRow(
                        icon: "text.bubble",
                        title: "转文字 · 本机出全文",
                        detail: "点录音下方的「转文字」，用 iPhone 自带的语音识别在本机完成（首次需要下载中文语音模型，之后离线可用）。"
                    )
                    guideRow(
                        icon: "text.quote",
                        title: "Track 1 · 转写后贴给 Bot",
                        detail: "分享或「存到文件」后，用飞书妙记、快捷指令转写，或把文件送到 Mac 做系统转写。文字再贴给 Bot。不要把这条音频送进得到。"
                    )
                    guideRow(
                        icon: "brain",
                        title: "Track 2 · 得到大脑",
                        detail: "点「分享」，选得到大脑；或在得到里用「导入音视频」选这个 m4a。得到只在这台 iPhone 上。"
                    )
                }

                Section("文件在哪里") {
                    guideRow(
                        icon: "folder",
                        title: "我的 iPhone → DayTap",
                        detail: "在「文件」App 里打开。链接 daytap://recordings 会回到这个列表。"
                    )
                }

                Section {
                    guideRow(
                        icon: "wrench.and.screwdriver",
                        title: "这是开发版",
                        detail: "还不能从 App Store 安装。表上没装好时，用手机上的得到、语音备忘录或飞书妙记录（Track 0）。"
                    )
                }
            }
            .navigationTitle("使用指南")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func guideRow(icon: String, title: String, detail: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
