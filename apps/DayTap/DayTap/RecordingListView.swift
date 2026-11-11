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
        .onReceive(NotificationCenter.default.publisher(for: .daytapTransferRejected)) { note in
            banner = note.object as? String ?? "一条录音传输不完整，已拒收等手表重传"
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                link.activate()
                // 回前台顺一把自动转写队列(#29)。
                transcriber.drainAutoQueue()
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
                transcriber: transcriber,
                player: player
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
            ReviewSheet(records: activeRecords)
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
                .disabled(!fileExists)
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
        VStack(spacing: 6) {
            HStack {
                Text(DayTapFormat.clock(player.elapsed))
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

                // 跳静音(#37):有分段才显示;开着=落在句间空隙自动跳下一句。
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

            Slider(value: Binding(
                get: { player.progress },
                set: { player.scrub(to: $0) }
            ), in: 0...1)
            .tint(.red)
        }
        .accessibilityIdentifier("daytap.playback.\(record.id)")
    }

    private var speedLabel: String {
        player.rate == 1.5 ? "1.5x" : (player.rate == 2.0 ? "2x" : "1x")
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

/// 全文 sheet(#16 → #32 时间戳模式):点句子=跳到那一刻播放;播放时当前句高亮+跟读滚动;
/// 底部内嵌迷你播放条,拖它高亮跟着走(双向锚定)。无分段的老转写退回纯文本。
/// 顶栏保留 重新转写/分享文字,底栏 复制全文 与播放条并存。
private struct TranscriptView: View {
    let recordID: String
    @ObservedObject var library: RecordingLibrary
    @ObservedObject var transcriber: TranscriptionCenter
    @ObservedObject var player: PlaybackCenter

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
                            transcriber.transcribe(record)
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
                        ForEach(actions, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Image(systemName: "circle")
                                    .font(.caption2)
                                    .foregroundStyle(Color.accentColor)
                                Text(item)
                                    .font(.subheadline)
                            }
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
            parts.append("【待办】\n" + actions.map { "· \($0)" }.joined(separator: "\n"))
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
        for (index, segment) in segments.enumerated() where segment.start <= player.elapsed + 0.01 {
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
                Text(DayTapFormat.clock(player.elapsed))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { player.progress },
                    set: { player.scrub(to: $0) }
                ), in: 0...1)
                .tint(.red)
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
private struct TrashView: View {
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

/// 使用指南(#15):原首屏文字墙收纳于此,内容一字不丢,只换排版。
private struct GuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // #40 瘦身:3 节 7 行,只留「界面答不了的事」——隐藏手势/护栏真相/外部链路。
                // 操作细节(轻扫/长按/批量/分组/筛选)界面自明,不再写;配置在设置;开发版说明在设置「关于」。
                Section("录音") {
                    guideRow(
                        icon: "applewatch",
                        title: "手表",
                        detail: "红色大按钮开始/停止；指节敲桌面两下也能启停（DayTap 在前台时），录音中按表冠回表盘不停。录错点「丢弃待传」整条弃掉。传到 iPhone 确认后手表原件自动清除。"
                    )
                    guideRow(
                        icon: "iphone",
                        title: "iPhone",
                        detail: "列表下方红钮直接录，录完和手表录音一起出现在这里；手机录的只存在本机。"
                    )
                }

                Section("转写与整理") {
                    guideRow(
                        icon: "text.bubble",
                        title: "自动转写",
                        detail: "录音到位自动转全文（接电源或电量充足时；首次需下载中文语音模型，之后离线；超长的可长按手动转）。转写完自动出短标题、摘要、待办和类别——长按可改名改类别，行内文字点开全文。摘要需要 Apple 智能，国行手机可在设置的 AI 模型里配置（智谱 / DeepSeek / Kimi / 通义 / 方舟等）。"
                    )
                    guideRow(
                        icon: "waveform",
                        title: "回听",
                        detail: "进度条可拖动、点「1x」换倍速；「跳静音」自动跳过句间无声段。搜索能搜标题与全文，点命中处直达说那句话的那一刻；删除的录音进「最近删除」保留 30 天。"
                    )
                }

                Section("出口") {
                    guideRow(
                        icon: "brain",
                        title: "Track 2 · 得到大脑",
                        detail: "点「分享」选得到大脑，或得到里「导入音视频」选这个 m4a。得到只在这台 iPhone 上。"
                    )
                    guideRow(
                        icon: "text.quote",
                        title: "Track 1 · 转写交给 Bot",
                        detail: "「分享」或「存到文件」后用飞书妙记、快捷指令转写，或送到 Mac 做系统转写，文字贴给 Bot 出决策卡。不要把这条音频送进得到。"
                    )
                    guideRow(
                        icon: "folder",
                        title: "文件与导出",
                        detail: "音频在「文件」App → 我的 iPhone → DayTap；⋯ 菜单「导出」把当前列表（可按类别先筛）拼成一个文件——Markdown 进语料库、纯文本直接粘贴、JSON 喂脚本，内容可选完整或仅摘要卡。"
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
}

/// 导出格式(#41):三种下游三种壳——Markdown 给语料库、纯文本给聊天粘贴、JSON 给脚本管道。
enum ExportFormat: String, CaseIterable, Identifiable {
    case markdown = "Markdown"
    case plainText = "纯文本"
    case json = "JSON"

    var id: String { rawValue }
    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .plainText: return "txt"
        case .json: return "json"
        }
    }
}

/// 导出内容(#41):完整=摘要+待办+全文;仅摘要卡=标题+类别+摘要+待办,不含全文(决策卡直投)。
enum ExportContent: String, CaseIterable, Identifiable {
    case full = "完整"
    case digestOnly = "仅摘要卡"

    var id: String { rawValue }
}

/// 导出构建(#41):格式×内容 → 单文件。Markdown 沿用 #38 结构,纯文本同源去标记,JSON 给机器。
private enum ExportBuilder {
    /// 标题口径与列表一致:手动名 > 自动短标题 > 时刻。
    static func title(_ record: RecordingRecord) -> String {
        if let name = record.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let auto = record.autoTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !auto.isEmpty {
            return auto
        }
        return record.createdAt.formatted(date: .omitted, time: .shortened)
    }

    /// 按天归组(records 已按 createdAt 倒序,同列表分组口径)。
    private static func grouped(_ records: [RecordingRecord]) -> [(day: Date, records: [RecordingRecord])] {
        let calendar = Calendar.current
        var groups: [(day: Date, records: [RecordingRecord])] = []
        for record in records {
            let day = calendar.startOfDay(for: record.createdAt)
            if groups.last?.day == day {
                groups[groups.count - 1].records.append(record)
            } else {
                groups.append((day, [record]))
            }
        }
        return groups
    }

    /// 生成并写临时文件,失败返回 nil。
    static func makeFile(records: [RecordingRecord], format: ExportFormat, content: ExportContent, category: String?) -> URL? {
        let dateText = Date().formatted(.iso8601.year().month().day())
        let suffix = category.map { "-\($0)" } ?? ""
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DayTap-转写-\(dateText)\(suffix).\(format.fileExtension)")
        let data: Data
        switch format {
        case .json:
            // 仅摘要卡时剥掉全文与分段,JSON 与文本格式同口径。
            let out: [RecordingRecord] = content == .full ? records : records.map { record in
                var trimmed = record
                trimmed.transcript = nil
                trimmed.transcriptSegments = nil
                return trimmed
            }
            data = (try? JSONEncoder.exportData(records: out)) ?? Data("[]".utf8)
        default:
            data = Data(text(records: records, format: format, content: content, category: category).utf8)
        }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Markdown/纯文本 共用拼装:同源不同壳(#38 结构,纯文本只换标记)。
    static func text(records: [RecordingRecord], format: ExportFormat, content: ExportContent, category: String?) -> String {
        let markdown = format == .markdown
        let today = Date().formatted(date: .abbreviated, time: .omitted)
        var lines: [String] = [markdown ? "# DayTap 转写 · \(today)" : "DayTap 转写 · \(today)"]
        if let category {
            lines.append("")
            lines.append(markdown ? "筛选类别：**\(category)**" : "筛选类别：\(category)")
        }
        let calendar = Calendar.current
        for group in grouped(records) {
            let header: String
            if calendar.isDateInToday(group.day) {
                header = "今天"
            } else if calendar.isDateInYesterday(group.day) {
                header = "昨天"
            } else {
                header = group.day.formatted(date: .abbreviated, time: .omitted)
            }
            lines.append("")
            lines.append(markdown ? "## \(header)" : "【\(header)】")
            for record in group.records {
                lines.append("")
                let time = record.createdAt.formatted(date: .omitted, time: .shortened)
                let cat = record.category.map { " · \($0)" } ?? ""
                lines.append(markdown ? "### \(time) \(title(record))\(cat)" : "\(time) \(title(record))\(cat)")
                if record.transcript == nil {
                    lines.append("（未转写 · \(DayTapFormat.clock(record.durationSeconds))）")
                    continue
                }
                if let summary = record.summary, !summary.isEmpty {
                    lines.append(markdown ? "**摘要** \(summary)" : "摘要：\(summary)")
                }
                if let actions = record.actionItems, !actions.isEmpty {
                    lines.append(markdown ? "**待办**" : "待办：")
                    for item in actions {
                        lines.append(markdown ? "- \(item)" : "· \(item)")
                    }
                }
                if content == .full, let transcript = record.transcript {
                    lines.append("")
                    lines.append(transcript)
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

private extension JSONEncoder {
    /// JSON 导出(#41):结构化给 pipeline/脚本;完整模式带分段供跳播数据复用。
    static func exportData(records: [RecordingRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(records)
    }
}

/// 导出选项页(#41):格式×内容两排分段选择,自本页弹系统分享面板(不与外层 sheet 打架)。
private struct ExportSheet: View {
    let records: [RecordingRecord]
    let category: String?
    @Environment(\.dismiss) private var dismiss

    @State private var format: ExportFormat = .markdown
    @State private var content: ExportContent = .full
    @State private var shareURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("格式", selection: $format) {
                        ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Picker("内容", selection: $content) {
                        ForEach(ExportContent.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("导出 \(records.count) 条")
                } footer: {
                    Text("Markdown 进语料库；纯文本直接粘贴；JSON 喂脚本。仅摘要卡不含全文，适合把决策卡直投聊天。")
                }

                Section {
                    Button {
                        shareURL = ExportBuilder.makeFile(records: records, format: format, content: content, category: category)
                    } label: {
                        Label("分享 / 存到文件", systemImage: "square.and.arrow.up")
                    }
                    .disabled(records.isEmpty)
                }
            }
            .navigationTitle("导出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: Binding(
                get: { shareURL != nil },
                set: { if !$0 { shareURL = nil } }
            )) {
                if let shareURL {
                    ActivityShareSheet(url: shareURL)
                        .ignoresSafeArea()
                }
            }
        }
    }
}

/// 本周回顾(#43):把攒了一周的录音看见——概览/类别分布/待办汇总,数据全现成,纯本地聚合。
/// 滚动「最近 7 天」而非卡历周,避免周一重置割裂周末;仅统计未删除条目。
private struct ReviewSheet: View {
    let records: [RecordingRecord]
    @Environment(\.dismiss) private var dismiss

    private var weekRecords: [RecordingRecord] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else { return [] }
        return records.filter { $0.createdAt > cutoff }
    }

    private var todayRecords: [RecordingRecord] {
        records.filter { Calendar.current.isDateInToday($0.createdAt) }
    }

    /// 类别分布(最近 7 天):在册预设类别+未分类,按条数降序。
    private var categoryCounts: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for record in weekRecords {
            let key = record.category ?? "未分类"
            counts[key, default: 0] += 1
        }
        return counts.map { ($0.key, $0.value) }.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            // 平局时未分类垫底(Unicode 序会让它抢在真类别前,观感不对)。
            if lhs.name == "未分类" { return false }
            if rhs.name == "未分类" { return true }
            return lhs.name < rhs.name
        }
    }

    /// 待办汇总(最近 7 天):按录音归组,带来源标题。
    private var todoGroups: [(title: String, items: [String])] {
        weekRecords.compactMap { record in
            guard let items = record.actionItems, !items.isEmpty else { return nil }
            return (title: ReviewSheet.rowTitle(record), items: items)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if weekRecords.isEmpty {
                    ContentUnavailableView(
                        "最近 7 天还没有录音",
                        systemImage: "waveform",
                        description: Text("手表或手机录一条，这里就能看见一周的积累。")
                    )
                } else {
                    Section("概览") {
                        LabeledContent("今天", value: "\(todayRecords.count) 条 · \(Self.durationText(todayRecords))")
                        LabeledContent("最近 7 天", value: "\(weekRecords.count) 条 · \(Self.durationText(weekRecords))")
                    }

                    Section("类别分布 · 最近 7 天") {
                        let maxCount = categoryCounts.first?.count ?? 1
                        ForEach(categoryCounts, id: \.name) { item in
                            HStack(spacing: 10) {
                                Text(item.name)
                                    .font(.subheadline)
                                    .frame(width: 52, alignment: .leading)
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.75))
                                    .frame(width: max(10, CGFloat(item.count) / CGFloat(max(maxCount, 1)) * 150), height: 8)
                                Spacer(minLength: 0)
                                Text("\(item.count) 条")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section("待办 · 最近 7 天") {
                        if todoGroups.isEmpty {
                            Text("这一周的录音里没有提到待办")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(todoGroups, id: \.title) { group in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(group.title)
                                        .font(.subheadline.weight(.semibold))
                                    ForEach(group.items, id: \.self) { item in
                                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                                            Image(systemName: "circle")
                                                .font(.caption2)
                                                .foregroundStyle(Color.accentColor)
                                            Text(item)
                                                .font(.subheadline)
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
            .navigationTitle("本周回顾")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    if !todoGroups.isEmpty {
                        Button {
                            UIPasteboard.general.string = todoText
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        } label: {
                            Label("复制全部待办", systemImage: "checklist")
                        }
                        .accessibilityIdentifier("daytap.review.copyTodos")
                    }
                }
            }
        }
    }

    /// 「复制全部待办」的文本:按来源分组,与摘要卡同符号体系。
    private var todoText: String {
        "【待办 · 最近 7 天】\n" + todoGroups.map { group in
            "■ \(group.title)\n" + group.items.map { "· \($0)" }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private static func durationText(_ records: [RecordingRecord]) -> String {
        DayTapFormat.clock(records.reduce(0) { $0 + $1.durationSeconds })
    }

    /// 来源标题与列表同口径:手动名 > 自动短标题 > 日期+时刻(跨天场景日期更有辨识度)。
    private static func rowTitle(_ record: RecordingRecord) -> String {
        if let name = record.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let auto = record.autoTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !auto.isEmpty {
            return auto
        }
        return record.createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}

/// 设置(#40→#42):配置归设置。AI 模型节=LLM 配置中心——预设厂商可选不填、
/// 模型候选可选+自定义兜底、key 唯一必填,配完一键连通性测试;摘要只是第一个消费者。
private struct SettingsSheet: View {
    @ObservedObject var transcriber: TranscriptionCenter
    @Environment(\.dismiss) private var dismiss

    @State private var llmEnabled: Bool
    @State private var provider: LLMProviderID
    @State private var customBaseURL: String
    @State private var modelSelection: String
    @State private var customModel: String
    @State private var apiKey: String
    @State private var testResult: (ok: Bool, message: String)?
    @State private var testing = false

    /// 模型 Picker 里「自定义…」的哨兵值。
    private static let customModelTag = "__custom__"

    init(transcriber: TranscriptionCenter) {
        self.transcriber = transcriber
        _llmEnabled = State(initialValue: LLMSettings.enabled)
        let savedProvider = LLMSettings.provider
        let savedModel = LLMSettings.model
        _provider = State(initialValue: savedProvider)
        _customBaseURL = State(initialValue: LLMSettings.customBaseURL)
        if savedProvider.modelCandidates.contains(savedModel) {
            _modelSelection = State(initialValue: savedModel)
            _customModel = State(initialValue: "")
        } else {
            _modelSelection = State(initialValue: Self.customModelTag)
            _customModel = State(initialValue: savedModel)
        }
        _apiKey = State(initialValue: LLMSecrets.loadKey() ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("启用 AI 整理", isOn: $llmEnabled)
                } header: {
                    Text("AI 模型")
                } footer: {
                    Text("配置一次，摘要、标题、类别与后续 AI 功能共用。本机 Apple 智能可用时始终优先本机；启用后转写文字将发送到所选服务。")
                }

                // 接口细节开关开着才出现(#40 渐进披露)。
                if llmEnabled {
                    Section {
                        Picker("服务商", selection: $provider) {
                            ForEach(LLMProviderID.allCases) { Text($0.displayName).tag($0) }
                        }

                        if provider == .custom {
                            TextField("Base URL（OpenAI 兼容）", text: $customBaseURL, prompt: Text("https://…/v1"))
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }

                        Picker("模型", selection: $modelSelection) {
                            ForEach(provider.modelCandidates, id: \.self) { Text($0).tag($0) }
                            Text("自定义…").tag(Self.customModelTag)
                        }
                        if modelSelection == Self.customModelTag {
                            TextField("模型名（以控制台为准）", text: $customModel)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }

                        SecureField("API Key", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Button {
                            // 测的是当前表单值:先保存再测,所见即所测。
                            persist()
                            testing = true
                            testResult = nil
                            Task {
                                testResult = await TranscriptionCenter.testLLMConnection()
                                testing = false
                            }
                        } label: {
                            HStack {
                                Label("测试连通性", systemImage: "bolt.horizontal")
                                if testing {
                                    Spacer()
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .disabled(testing)
                        // 结果语义化着色(#42 甲方反馈):成功=绿色对勾,失败=警示色三角+原因,不再一行死灰。
                        if let testResult {
                            HStack(spacing: 6) {
                                Image(systemName: testResult.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(testResult.ok ? Color.green : Color.orange)
                                Text(testResult.message)
                                    .foregroundStyle(testResult.ok ? Color.green : Color.secondary)
                            }
                            .font(.caption)
                            .accessibilityLabel(testResult.ok ? "连接正常" : testResult.message)
                            .accessibilityIdentifier("daytap.llm.testResult")
                        }
                    } footer: {
                        Text("模型候选只是起点，各家上新快，以控制台为准，选「自定义…」可填任意型号。")
                    }

                    Section {
                        Button {
                            transcriber.backfillDigests()
                        } label: {
                            if transcriber.backfillRunning {
                                Text("补生成中 \(transcriber.backfillDone)/\(transcriber.backfillTotal)…")
                            } else {
                                let count = transcriber.backfillCandidateCount
                                Text(count > 0 ? "为现有转写补生成摘要（\(count) 条）" : "没有需要补的录音")
                            }
                        }
                        .disabled(transcriber.backfillRunning)
                    } footer: {
                        Text("为已转写但还没有摘要/类别的录音串行补生成。")
                    }
                }

                Section {
                    LabeledContent("版本", value: "开发版")
                } header: {
                    Text("关于")
                } footer: {
                    Text("还不能从 App Store 安装，用 Xcode 侧载；表上没装好时用手机自带录音替代。链接 daytap://recordings 会回到录音列表。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        persist()
                        dismiss()
                    }
                }
            }
            .onChange(of: provider) { _, newProvider in
                // 换厂商,模型候选跟随重置;自定义模型名清空待填。
                modelSelection = newProvider.defaultModel.isEmpty ? Self.customModelTag : newProvider.defaultModel
                customModel = ""
            }
        }
    }

    private func persist() {
        let defaults = UserDefaults.standard
        let model = modelSelection == Self.customModelTag ? customModel : modelSelection
        defaults.set(llmEnabled, forKey: LLMSettings.enabledKey)
        defaults.set(provider.rawValue, forKey: LLMSettings.providerKey)
        defaults.set(customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: LLMSettings.customBaseURLKey)
        defaults.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: LLMSettings.modelKey)
        LLMSecrets.saveKey(apiKey)
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
