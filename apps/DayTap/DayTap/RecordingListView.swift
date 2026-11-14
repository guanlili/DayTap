import SwiftUI
import UniformTypeIdentifiers

/// iPhone 上的收件箱。不做录音。
/// 转文字(#30 零步化)：录音到位自动转全文(电量护栏在 Transcriber)；行内常显首行预览、
/// 点预览开全文 sheet，长按「复制文字」一步复制；手动转写留作兜底。
/// 分类(#29)：列表按天分组(日期上移到分组头,行内只留时刻);转写完自动归入预设类别,
/// 长按「类别」纠偏,顶部 chips 单选筛选;与搜索/编辑态叠加。
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
    // 设置(#40):配置从指南独立出来,⋯ 菜单进。
    @State private var showSettings = false
    // 导出选项页(#41):格式×内容在页里选,不再一击定死 Markdown。
    @State private var showExport = false
    // 本周回顾(#43):⋯ 菜单进,把一周的积累看见。
    @State private var showReview = false
    // 批量管理(#25):编辑态、选中集、批量分享/删除。
    @State private var isEditing = false
    @State private var selectedIDs: Set<String> = []
    @State private var batchShareURLs: [URL]?
    @State private var confirmBatchDelete = false
    // 搜索(#26):标题+全文。
    @State private var query = ""
    // 类别筛选(#29):nil=全部;与搜索叠加作用于分组前的集合。
    @State private var categoryFilter: String?

    /// 正常在列的(不含回收站);搜索时再按 标题/全文 过滤。
    private var activeRecords: [RecordingRecord] {
        library.records.filter { $0.deletedAt == nil }
    }

    private var trashedRecords: [RecordingRecord] {
        library.records.filter { $0.deletedAt != nil }
    }

    private var visibleRecords: [RecordingRecord] {
        var result = activeRecords
        // 类别筛选(#29)与搜索叠加:先筛后搜,两者都作用于分组前的同一集合。
        if let categoryFilter {
            result = result.filter { $0.category == categoryFilter }
        }
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return result }
        return result.filter { record in
            record.title.localizedCaseInsensitiveContains(keyword)
                || (record.transcript?.localizedCaseInsensitiveContains(keyword) ?? false)
        }
    }

    /// 按天分组(#29):库内本就按 createdAt 倒序,顺序扫描相邻归组即为「天」分节。
    private var groupedByDay: [(day: Date, records: [RecordingRecord])] {
        let calendar = Calendar.current
        var groups: [(day: Date, records: [RecordingRecord])] = []
        for record in visibleRecords {
            let day = calendar.startOfDay(for: record.createdAt)
            if groups.last?.day == day {
                groups[groups.count - 1].records.append(record)
            } else {
                groups.append((day, [record]))
            }
        }
        return groups
    }

    /// 分组头(#29):今天/昨天/M月d日,跨年带年份;日期信息全上移到这里。
    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        if calendar.isDate(day, equalTo: Date(), toGranularity: .year) {
            return day.formatted(.dateTime.month().day())
        }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        NavigationStack {
            Group {
                if activeRecords.isEmpty && query.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("DayTap")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !activeRecords.isEmpty, !recorder.isRecording {
                        Button(isEditing ? "完成" : "编辑") {
                            isEditing.toggle()
                            if !isEditing { selectedIDs.removeAll() }
                        }
                        .accessibilityIdentifier("daytap.edit")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // ⋯ 菜单(#40):低频入口收敛——导出(#41 选项页)/指南/设置,一个图标三个动作。
                    Menu {
                        Button {
                            showExport = true
                        } label: {
                            Label("导出…", systemImage: "doc.text")
                        }
                        .disabled(visibleRecords.isEmpty)
                        .accessibilityIdentifier("daytap.export.md")

                        Button {
                            showReview = true
                        } label: {
                            Label("本周回顾", systemImage: "chart.bar.xaxis")
                        }
                        .disabled(activeRecords.isEmpty)
                        .accessibilityIdentifier("daytap.review")

                        Button {
                            showGuide = true
                        } label: {
                            Label("使用指南", systemImage: "book")
                        }
                        .accessibilityIdentifier("daytap.guide")

                        Button {
                            showSettings = true
                        } label: {
                            Label("设置", systemImage: "gearshape")
                        }
                        .accessibilityIdentifier("daytap.settings")
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("更多操作")
                    .accessibilityIdentifier("daytap.more")
                }
                ToolbarItem(placement: .bottomBar) {
                    if isEditing {
                        batchBar
                    } else {
                        recordControl
                    }
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
        // 守门拒收可见化(#48):文件到了但不完整,数字直接亮在列表顶。
        .onReceive(NotificationCenter.default.publisher(for: .daytapTransferRejected).receive(on: DispatchQueue.main)) { note in
            banner = note.object as? String ?? "一条录音传输不完整，已拒收等手表重传"
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                link.activate()
                // 回前台顺一把自动转写队列(#29)。
                transcriber.drainAutoQueue()
            } else if phase != .inactive {
                // #64/#65:录音中绝不能 reset 播放器——reset 会熄掉共享音频会话,
                // 把正在进行的后台录音掐死(实测录几分钟只剩前台十几秒)。
                // 录音中本来也没有播放(#60 已禁),不 reset 无损失。
                if !recorder.isRecording {
                    player.reset()
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
                transcriber: transcriber,
                player: player,
                clock: player.clock
            )
        }
        .sheet(item: $shareRecord) { record in
            // #34:分享走带名副本(名字/时间戳),不再让接收方看到 UUID;「存到文件」同源。
            if let url = link.shareFileURL(for: record) {
                ActivityShareSheet(url: url)
                    .ignoresSafeArea()
            } else {
                Text("找不到这条音频文件")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .sheet(isPresented: Binding(
            get: { !(batchShareURLs ?? []).isEmpty },
            set: { if !$0 { batchShareURLs = nil } }
        )) {
            ActivityShareSheet(urls: batchShareURLs ?? [])
                .ignoresSafeArea()
        }
        .confirmationDialog(
            "删除选中的 \(selectedIDs.count) 条？",
            isPresented: $confirmBatchDelete,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { commitBatchDelete() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("手机上的音频与索引会一并删除，不可恢复。")
        }
        .sheet(isPresented: $showGuide) {
            GuideSheet()
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(transcriber: transcriber)
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(records: visibleRecords, category: categoryFilter)
        }
        .sheet(isPresented: $showReview) {
            ReviewSheet(records: activeRecords, library: library, player: player)
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

            if visibleRecords.isEmpty {
                Section {
                    ContentUnavailableView.search(text: query)
                }
            } else {
                // 按天分组(#29):一天一节,分组头承接日期;搜索/筛选后的结果同样按天归组。
                ForEach(groupedByDay, id: \.day) { group in
                    Section {
                        ForEach(group.records) { record in
                            row(record)
                        }
                    } header: {
                        Text(dayTitle(group.day))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // 回收站有货才出现(#26):与「出问题才说话」同一口径。
            if !trashedRecords.isEmpty {
                Section {
                    NavigationLink {
                        TrashView(library: library)
                    } label: {
                        Label("最近删除 · \(trashedRecords.count) 条", systemImage: "trash")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("daytap.trash")
                }
            }
        }
        .searchable(text: $query, prompt: "搜索录音或全文")
        // 类别筛选 chips(#29):钉在列表上方,编辑态收起;没出现过类别就不占位。
        .safeAreaInset(edge: .top, spacing: 0) {
            if !isEditing {
                categoryChips
            }
        }
    }

    /// 类别筛选 chips(#29):「全部」+ 库里出现过的预设类别,单选。
    /// 与搜索、按天分组三态叠加;Apple 风格轻量,不做侧边栏/层级树。
    @ViewBuilder
    private var categoryChips: some View {
        let present = RecordingCategory.presets.filter { preset in
            activeRecords.contains { $0.category == preset }
        }
        if !present.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    categoryChip(nil, label: "全部")
                    ForEach(present, id: \.self) { preset in
                        categoryChip(preset, label: preset)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }

    private func categoryChip(_ value: String?, label: String) -> some View {
        let selected = categoryFilter == value
        return Button {
            categoryFilter = value
        } label: {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(selected ? Color.accentColor : Color.secondary.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("筛选\(label)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("daytap.chip.\(label)")
    }

    /// 编辑态底栏(#25):全选 / 分享(n) / 删除(n),替代录音钮(录着时禁进编辑)。
    /// 全选作用于当前可见集(搜索结果),同邮件口径。
    private var batchBar: some View {
        let count = selectedIDs.count
        let allSelected = !visibleRecords.isEmpty && count == visibleRecords.count
        return HStack {
            Button(allSelected ? "全不选" : "全选") {
                selectedIDs = allSelected ? [] : Set(visibleRecords.map(\.id))
            }
            Spacer()
            Button {
                shareSelected()
            } label: {
                Label("分享 (\(count))", systemImage: "square.and.arrow.up")
            }
            .disabled(count == 0)
            Spacer()
            Button(role: .destructive) {
                confirmBatchDelete = true
            } label: {
                Label("删除 (\(count))", systemImage: "trash")
            }
            .disabled(count == 0)
        }
    }

    private func toggleSelect(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func shareSelected() {
        // #34 同根因:批量分享也走带名副本;两条同名(如两条「晨会」)加序号防覆盖。
        var urls: [URL] = []
        var usedNames: Set<String> = []
        for id in selectedIDs {
            guard let record = library.record(id: id),
                  let url = link.shareFileURL(for: record)
            else { continue }
            var finalURL = url
            if usedNames.contains(url.lastPathComponent) {
                let stem = url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension
                var index = 2
                while usedNames.contains("\(stem)-\(index).\(ext)") { index += 1 }
                let renamed = url.deletingLastPathComponent().appendingPathComponent("\(stem)-\(index).\(ext)")
                try? FileManager.default.removeItem(at: renamed)
                if (try? FileManager.default.copyItem(at: url, to: renamed)) != nil {
                    finalURL = renamed
                }
            }
            usedNames.insert(finalURL.lastPathComponent)
            urls.append(finalURL)
        }
        guard !urls.isEmpty else {
            banner = "选中的录音找不到音频文件"
            return
        }
        batchShareURLs = urls
    }

    // MARK: - 导出(#38→#41,构建器与选项页在文件级 ExportBuilder/ExportSheet)

    /// 批量落删(#25→#26 软删):正在播的在集内先停播,逐条进回收站。
    private func commitBatchDelete() {
        let ids = selectedIDs
        selectedIDs.removeAll()
        if let playing = player.playingID, ids.contains(playing) {
            player.reset()
        }
        for id in ids {
            link.forget(id: id)
        }
        if activeRecords.allSatisfy({ ids.contains($0.id) }) {
            isEditing = false
        }
    }

    /// 全文命中(#26 上下文 → #32 高亮+跳播):标题没命中但全文命中时,
    /// 返回带高亮关键词的预览与该词所在的音频秒数(有分段才有精确 offset)。
    private func transcriptSnippet(_ record: RecordingRecord) -> (text: AttributedString, offset: TimeInterval)? {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty,
              let transcript = record.transcript,
              !record.title.localizedCaseInsensitiveContains(keyword),
              let range = transcript.range(of: keyword, options: [.caseInsensitive, .diacriticInsensitive])
        else { return nil }
        let window = 12
        let start = transcript.index(range.lowerBound, offsetBy: -window, limitedBy: transcript.startIndex)
            ?? transcript.startIndex
        let end = transcript.index(range.upperBound, offsetBy: window, limitedBy: transcript.endIndex)
            ?? transcript.endIndex
        let head = start > transcript.startIndex ? "…" : ""
        let tail = end < transcript.endIndex ? "…" : ""
        var attr = AttributedString("全文 \(head)\(transcript[start..<end])\(tail)")
        if let hit = attr.range(of: keyword, options: [.caseInsensitive, .diacriticInsensitive]) {
            attr[hit].foregroundColor = .accentColor
            attr[hit].font = .caption2.weight(.semibold)
        }

        // 定位:第一个包含关键词的分段(无分段=旧转写,offset 0=从头播,降级口径)。
        var offset: TimeInterval = 0
        if let segments = record.transcriptSegments {
            offset = segments.first {
                $0.text.localizedCaseInsensitiveContains(keyword)
            }?.start ?? 0
        }
        return (attr, offset)
    }

    /// 点命中预览:跳到那一刻播放(#32)。无分段的老转写退化为从头播。
    private func playFromHit(_ record: RecordingRecord, offset: TimeInterval) {
        guard FileManager.default.fileExists(atPath: library.fileURL(id: record.id).path) else {
            banner = "找不到这条音频文件"
            return
        }
        player.toggle(record, fileURL: library.fileURL(id: record.id), at: offset)
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
                // #67:先播后录——开录前停掉播放器,否则播放 tick 的自动收摊
                // (内含熄会话)会把刚开的录音掐死(#65 同源病灶的另一入口)。
                if player.playingID != nil {
                    player.reset()
                }
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

    /// #19 极简行 / #25 编辑态:平时=标题+副标题+播放键,整行轻点试听;
    /// 编辑态=左端勾选圈,整行轻点切换选中,播放键与轻扫隐藏。
    @ViewBuilder
    private func row(_ record: RecordingRecord) -> some View {
        if isEditing {
            rowBody(record)
                .contentShape(Rectangle())
                .onTapGesture { toggleSelect(record.id) }
        } else {
            rowBody(record)
                .contentShape(Rectangle())
                .onTapGesture { togglePlay(record, fileExists: FileManager.default.fileExists(atPath: library.fileURL(id: record.id).path)) }
                .contextMenu { rowMenu(record) }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        shareRecord = record
                    } label: {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    .tint(.accentColor)
                    .disabled(!FileManager.default.fileExists(atPath: library.fileURL(id: record.id).path))
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
                    } else if FileManager.default.fileExists(atPath: library.fileURL(id: record.id).path) {
                        Button {
                            transcriber.transcribe(record)
                        } label: {
                            Label("转文字", systemImage: "text.bubble")
                        }
                        .tint(.accentColor)
                        // #29:忙碌中不禁用,点按即插队(pendingManualID)
                    }
                }
        }
    }

    private func rowBody(_ record: RecordingRecord) -> some View {
        let fileExists = FileManager.default.fileExists(atPath: library.fileURL(id: record.id).path)
        let active = player.playingID == record.id
        let playing = active && player.isPlaying

        return HStack(alignment: .center, spacing: 12) {
            if isEditing {
                Image(systemName: selectedIDs.contains(record.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectedIDs.contains(record.id) ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle(record))
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Text(subtitle(for: record))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // 预览位(#30):正在转→轻提示;搜索命中→高亮+跳播(#32 不变);
                // 平时→首行常显,点它看全文(看全文从两次手势降为一步)。
                if transcriber.activeID == record.id {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("转写中…")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                } else if let snippet = transcriptSnippet(record) {
                    Button {
                        playFromHit(record, offset: snippet.offset)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Image(systemName: "play.circle")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                            Text(snippet.text)
                        }
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("跳到命中处播放")
                    .accessibilityIdentifier("daytap.search.hit.\(record.id)")
                } else if let text = record.summary ?? record.transcript {
                    // 有摘要先摘要(#35):比转写首句更短更准;没有退转写首行(#30)。
                    Button {
                        transcriptRecord = record
                    } label: {
                        Text(text)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    // iOS 26 borderless 按钮会把 tint 强加给 label,单靠 foregroundStyle 压不住;
                    // 预览是内容不是操作,从 tint 源头改成次要色(实测验证过的写法)。
                    .buttonStyle(.borderless)
                    .tint(Color.secondary)
                    .accessibilityLabel("查看全文")
                    .accessibilityIdentifier("daytap.preview.\(record.id)")
                } else if transcriber.autoFailedIDs.contains(record.id) {
                    // #44:失败行内可见——之前只有顶部一条全局横幅,看不出哪条坏了。
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.orange)
                        Text("转写失败 · 左滑「转文字」重试")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("daytap.failed.\(record.id)")
                } else if record.transcribedAt != nil {
                    // #44:转过但没内容(如敲桌误触发的环境音)——不是坏了,别让用户以为坏了。
                    HStack(spacing: 5) {
                        Image(systemName: "waveform.slash")
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                        Text("无语音内容")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("daytap.silent.\(record.id)")
                }

                if active {
                    playbackBar(record)
                }
            }

            Spacer(minLength: 8)

            if !isEditing {
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
                // #59:手机录音中禁播——播放会切音频会话类别,大概率掐断正在进行的录音
                .disabled(!fileExists || recorder.isRecording)
                .buttonStyle(.borderless)
                .accessibilityLabel(playing ? "暂停" : "试听")
                .accessibilityIdentifier("daytap.play.\(record.id)")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("daytap.recording.\(record.id)")
    }

    /// 长按菜单(#19 系动作 + #25 「选择」进入编辑态)。
    @ViewBuilder
    private func rowMenu(_ record: RecordingRecord) -> some View {
        let fileExists = FileManager.default.fileExists(atPath: library.fileURL(id: record.id).path)

        Button {
            isEditing = true
            selectedIDs.insert(record.id)
        } label: {
            Label("选择", systemImage: "checkmark.circle")
        }

        if record.transcript != nil {
            Button {
                transcriptRecord = record
            } label: {
                Label("查看全文", systemImage: "text.quote")
            }
            .accessibilityIdentifier("daytap.transcript.\(record.id)")

            // #30 一键复制:不进 sheet 直接把全文放进剪贴板。
            Button {
                copyTranscript(record)
            } label: {
                Label("复制文字", systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier("daytap.copyText.\(record.id)")
        } else if fileExists {
            Button {
                transcriber.transcribe(record)
            } label: {
                Label("转文字", systemImage: "text.bubble")
            }
            // #29:忙碌中不禁用,点按即插队
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

        // 类别纠偏(#29):自动归类打底,这里一次点选改掉;当前类别带勾。
        Menu {
            ForEach(RecordingCategory.presets, id: \.self) { preset in
                Button {
                    setCategory(record, to: preset)
                } label: {
                    if record.category == preset {
                        Label(preset, systemImage: "checkmark")
                    } else {
                        Text(preset)
                    }
                }
            }
            if record.category != nil {
                Button {
                    setCategory(record, to: nil)
                } label: {
                    Text("清除类别")
                }
            }
        } label: {
            Label(record.category ?? "类别", systemImage: "tag")
        }

        Button(role: .destructive) {
            deletingRecord = record
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    /// 手动改类别(#29):取库内最新那条改,不覆盖传输状态的并发更新(同 commitRename 口径)。
    /// 设为同一值不动(避免无谓的 updatedAt 刷新)。
    private func setCategory(_ record: RecordingRecord, to category: String?) {
        guard var fresh = library.record(id: record.id), fresh.category != category else { return }
        fresh.category = category
        fresh.updatedAt = Date()
        library.upsert(fresh)
    }

    /// 整行与播放键共用一份启停逻辑,文件不在就提示。
    private func togglePlay(_ record: RecordingRecord, fileExists: Bool) {
        guard fileExists else {
            banner = "找不到这条音频文件"
            return
        }
        player.toggle(record, fileURL: library.fileURL(id: record.id))
    }

    /// 长按「复制文字」(#30):全文直接进剪贴板,触感轻确认,不开 sheet 不占 banner。
    private func copyTranscript(_ record: RecordingRecord) {
        guard let text = record.transcript else { return }
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
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

    /// 试听进度(#26):时间行(中间倍速钮)+可拖动定位的红 slider。
    private func playbackBar(_ record: RecordingRecord) -> some View {
        PlaybackBarView(player: player, record: record)
    }

    /// 行标题(#29→#36):手动名 > 自动短标题 > 时刻;日期已上移到分组头,手动名永远赢。
    private func displayTitle(_ record: RecordingRecord) -> String {
        if let name = record.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let auto = record.autoTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !auto.isEmpty {
            return auto
        }
        return record.createdAt.formatted(date: .omitted, time: .shortened)
    }

    private func subtitle(for record: RecordingRecord) -> String {
        // 日期已上移到分组头(#29),这里只留时刻;空壳文件直接标出来,别让用户点开才发现播不了;
        // 类别(#29)与手机录来源(#3)打头。byteCount 已按真实落盘大小;
        // 不写 m4a——条条都是,语音备忘录也不标格式,格式知识在指南里(#19)。
        // 转没转过不再标「已转文字」——行内预览常显本身就是状态(#30)。
        let time = record.createdAt.formatted(date: .omitted, time: .shortened)
        var mark = ""
        if let category = record.category {
            mark += "\(category) · "
        }
        if record.origin == "phone" {
            mark += "手机录 · "
        }
        if record.byteCount < 1024 {
            mark += "空录音 · "
        }
        let size = "\(DayTapFormat.clock(record.durationSeconds)) · \(DayTapFormat.bytes(record.byteCount))"
        // 标题已是内容的条目(手动名/自动短标题),这里补回时刻;纯时刻标题避免时刻出现两遍(#36)。
        let titled = record.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || record.autoTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if titled {
            return "\(time) · \(mark)\(size)"
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



/// 行内播放条(#63 独立观察):整条下沉成子视图,自己观察 clock——
/// 4Hz 只重画这一小条,列表主体不再随 tick 全量重算。
private struct PlaybackBarView: View {
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
