import AVFoundation
import Combine
import Foundation
import FoundationModels
import Security
import Speech
import UIKit

/// 手机端转文字：iOS 26 的 SpeechAnalyzer/SpeechTranscriber，识别在本机完成，音频不出设备。
/// 一次只转一条；全文+时间戳分段写回索引（index.json），杀 App 不丢。仿 PlaybackCenter 的「一机一件」形态。
/// #29 自动转全文:新录音入册即排入隐式队列(=库里还没转写的正常条目,派生而来不落盘),
/// 接电源或电量≥50% 时前台串行消费;手动转写保留并优先。
@MainActor
final class TranscriptionCenter: ObservableObject {
    private var batteryToken: NSObjectProtocol?
    private var importedToken: NSObjectProtocol?

    deinit {
        // #63:token 式 addObserver 的标准坑——不存不移除,重构多实例即漏。
        if let batteryToken { NotificationCenter.default.removeObserver(batteryToken) }
        if let importedToken { NotificationCenter.default.removeObserver(importedToken) }
    }
    /// 正在转写的录音 id。nil=空闲。转写中按钮变进度圈并禁用。
    @Published private(set) var activeID: String?
    /// 列表页展示的一行状态（下载模型/转写中/失败原因）。成功后清空，失败保留到下一次操作。
    @Published var statusText: String?

    private let library: RecordingLibrary
    /// 本次会话自动转写失败的 id:不再自动重试(退回手动),防失败死循环刷屏。
    /// 会话级记忆——重启 App 后可再试一轮;@Published 让失败行自己亮出来(#44)。
    @Published private(set) var autoFailedIDs: Set<String> = []

    init(library: RecordingLibrary) {
        self.library = library
        // #39→#42 配置迁移:App 一启动就搬,设置页与摘要链路看到的都是新口径。
        LLMSettings.migrateIfNeeded()
        // 电量监控默认关,打开才能读 batteryState/Level(#29 护栏)。
        UIDevice.current.isBatteryMonitoringEnabled = true
        // 插上电源那一刻,是清自动队列最自然的时机;收到新录音也立刻试一把(#29)。
        batteryToken = NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.drainAutoQueue() }
        }
        importedToken = NotificationCenter.default.addObserver(
            forName: .daytapRecordImported,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.drainAutoQueue() }
        }
    }

    /// 手动「转文字」:空闲立即转,忙着就把这条插到自动队列最前(手动优先,#29)。
    /// 重新转写(#61 修正):先清派生字段(摘要/短题/待办)再走常规转写——
    /// digest 只在三字段有 nil 时跑,不清的话「重新转写」对已出全摘要的旧件是空操作,
    /// 0b1f78a 承诺的「错截止自愈」就没有出口。类别是用户纠偏过的,保留。
    func retranscribe(_ record: RecordingRecord) {
        var stale = record
        stale.summary = nil
        stale.autoTitle = nil
        stale.actionItems = nil
        stale.chapters = nil
        stale.people = nil
        library.upsert(stale)
        // #67:预清先留底——转写失败时派生字段(含用户勾选态)可回滚,
        // 不停在「旧全文+无摘要+无待办」的裸态。
        retranscribeBackup[record.id] = (record.summary, record.autoTitle, record.actionItems, record.chapters, record.people)
        transcribe(record)
    }

    /// 重转预清前的派生字段快照(#67 失败回滚用;#68 起 chapters、#85 起 people 一并留底)。
    private var retranscribeBackup:
        [String: (summary: String?, autoTitle: String?, actions: [ActionItem]?, chapters: [Chapter]?, people: [String]?)] = [:]

    private func rollbackRetranscribe(id: String) {
        guard let backup = retranscribeBackup.removeValue(forKey: id),
              var fresh = library.record(id: id)
        else { return }
        fresh.summary = backup.summary
        fresh.autoTitle = backup.autoTitle
        fresh.actionItems = backup.actions
        fresh.chapters = backup.chapters
        fresh.people = backup.people
        library.upsert(fresh)
        DayTapLog.transcribe.info("retranscribe rollback \(id, privacy: .public)")
    }

    func transcribe(_ record: RecordingRecord) {
        if activeID == nil {
            start(record)
            return
        }
        // 正在转别的:不打断,排队(#63 队列化;#67 去重——同一条连点不重复全量转写)。
        guard !pendingManualIDs.contains(record.id) else { return }
        pendingManualIDs.append(record.id)
        statusText = "已排队(第 \(pendingManualIDs.count) 位),前一条转完就轮到它"
    }

    private var pendingManualIDs: [String] = []

    /// 手动队列泵(#67):跳过文件已不存在的,取到可转的下一条即启;队列空则回自动队列。
    private func drainManualQueue() {
        while !pendingManualIDs.isEmpty {
            let nextID = pendingManualIDs.removeFirst()
            if let record = library.record(id: nextID),
               FileManager.default.fileExists(atPath: library.fileURL(id: nextID).path) {
                start(record)
                return
            }
        }
    }

    private func start(_ record: RecordingRecord) {
        let fileURL = library.fileURL(id: record.id)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            statusText = "找不到这条音频文件"
            // #67:手动队列在这里断链(原 return 后续排队永久滞留)——继续排空下一条。
            drainManualQueue()
            return
        }
        activeID = record.id
        Task {
            defer {
                activeID = nil
                afterCompletion(id: record.id)
            }
            do {
                // run 内部在「转写成功、digest 未说话」时自行清状态;这里不再兜底清空——
                // 否则 digest 写下的可见性提示(本机不可用/云端失败/AI 未配全)会被当场抹掉(#59)
                try await run(record: record, fileURL: fileURL)
            } catch {
                DayTapLog.transcribe.error("transcribe \(record.id, privacy: .public) failed \(error.localizedDescription, privacy: .public)")
                statusText = "转文字失败：\(error.localizedDescription)"
                // #67:重转预清过的条目,失败时把派生字段滚回来(含用户勾选态)。
                rollbackRetranscribe(id: record.id)
            }
        }
    }

    /// 一条转完:有手动插队先转它;真失败(transcript 没出且 transcribedAt 也没盖——
    /// 盖了=转完了只是没内容,那是「无语音内容」不是失败)记入会话级失败名单防自动死循环;
    /// 然后继续清队列。
    private func afterCompletion(id: String) {
        if let record = library.record(id: id),
           record.transcript == nil, record.transcribedAt == nil
        {
            autoFailedIDs.insert(id)
        }
        drainManualQueue()
        drainAutoQueue()
    }

    // MARK: - 自动转全文(#29)

    /// 自动队列条件:在列(未软删)、没转过(转了没内容的也不重试,#44)、本次会话没失败过、
    /// 音频在、时长 ≤2h(超长留给手动,内存/耗时护栏)。
    private func autoCandidates() -> [RecordingRecord] {
        library.snapshot().filter { record in
            record.deletedAt == nil
                && record.transcript == nil
                && record.transcribedAt == nil
                && !autoFailedIDs.contains(record.id)
                && record.byteCount >= 1024
                && record.durationSeconds <= 7200
                && FileManager.default.fileExists(atPath: library.fileURL(id: record.id).path)
        }
    }

    /// 电量护栏:接电源(充电中/已充满)或电量≥50% 才自动转。
    private var powerOK: Bool {
        let device = UIDevice.current
        switch device.batteryState {
        case .charging, .full:
            return true
        case .unplugged:
            return device.batteryLevel >= 0.5 || device.batteryLevel < 0  // <0=模拟器读不到,放行
        case .unknown:
            return true
        @unknown default:
            return true
        }
    }

    /// 消费自动队列:前台串行(activeID 保证一机一件,转完在 afterCompletion 续下一条);
    /// 不满足电量就静默等待(插电/新录音/回前台事件都会再触发)。
    func drainAutoQueue() {
        guard activeID == nil, powerOK else { return }
        guard let next = autoCandidates().first else { return }
        start(next)
    }

    private func run(record: RecordingRecord, fileURL: URL) async throws {
        // 转写语言跟着内容走：中文录音。zh-CN 不在支持列表时退到系统等价方言（如 zh-Hans-CN）。
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN"))
            ?? Locale(identifier: "zh-CN")
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

        // 语言模型是按需下载的本机资产。装好之前先引导下载，之后离线可用。
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            break
        case .supported, .downloading:
            statusText = "正在下载中文语音模型（首次转写需要，之后离线可用）…"
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        case .unsupported:
            throw TranscriptionError.unsupportedLocale
        @unknown default:
            throw TranscriptionError.unsupportedLocale
        }

        // 结果流和分析并行：results 只有消费端在等，analyzeSequence 走完流才会 finish。
        // 每个结果自带 audioTimeRange(#29)——分段时间戳在这里采,以前只拼文本扔掉了时间。
        statusText = "正在转写…"
        let audioFile = try AVAudioFile(forReading: fileURL)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task<([String], [TranscriptSegment]), Error> {
            var parts: [String] = []
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                parts.append(text)
                segments.append(
                    TranscriptSegment(
                        text: text,
                        start: result.range.start.seconds,
                        duration: result.range.duration.seconds
                    )
                )
            }
            return (parts, segments)
        }
        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        }
        let (parts, segments) = try await collector.value

        // 写回取库内最新那条，不覆盖传输状态的并发更新（同重命名 commitRename 的做法）。
        guard var fresh = library.record(id: record.id) else { return }
        let trimmed = parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        fresh.transcript = trimmed.isEmpty ? nil : trimmed
        fresh.transcriptSegments = trimmed.isEmpty || segments.isEmpty ? nil : segments
        // #44:转写跑完就盖时间戳——空结果从此可区分「没转过」与「无语音内容」,
        // 自动队列不再把空内容当失败反复重试。
        fresh.transcribedAt = Date()
        // 转写完顺手出摘要卡(#35)+短标题(#36)+类别(#29):一次调用三件事;
        // 类别被用户纠偏过的不覆盖;摘要/标题是派生内容,重新转写就重生成;
        // 模型不可用→全留 nil(未分类/时刻名),不影响转写落库。
        if fresh.transcript != nil,
           fresh.category == nil || fresh.summary == nil || fresh.autoTitle == nil {
            // 转写本体已成功:此刻清掉「正在转写…」;digest 若有话说(不可用/失败)会再设——
            // #59:start() 不再兜底清,清场职责移到这里。
            statusText = nil
            let result = await digest(transcript: trimmed, segments: segments)
            if fresh.category == nil {
                fresh.category = result?.category
            }
            fresh.autoTitle = result?.title
            fresh.summary = result?.summary
            // #62:双引擎失败(result=nil)不清已有待办——原实现会把用户勾选态连条目一起蒸发。
            if let actions = result?.actions {
                fresh.actionItems = actions
            }
            // 章节(#68)同摘要/标题口径:成功即覆盖,失败(含降级短路径)清空——章节锚的是旧全文会误导跳播。
            fresh.chapters = result?.chapters
            // 提到的人(#85 v1)同口径:失败清空,今天页人物块随之降级为空态。
            fresh.people = result?.people
        }
        fresh.updatedAt = Date()
        retranscribeBackup.removeValue(forKey: record.id)
        library.upsert(fresh)
        DayTapLog.transcribe.info("transcribed \(record.id, privacy: .public) chars=\(trimmed.count) segments=\(segments.count, privacy: .public) category=\(fresh.category ?? "-", privacy: .public) autoTitle=\(fresh.autoTitle ?? "-", privacy: .public) hasSummary=\(fresh.summary != nil)")
    }

    // MARK: - 摘要卡与自动归类(#35/#36/#29) + 云端兜底(#39)

    /// digest() 的规整结果:字段级可空——模型某件没办好不连坐其它件。
    private struct DigestResult {
        var category: String?
        var title: String?
        var summary: String?
        var actions: [ActionItem]?
        /// 长录音章节(#68):只有分块路径产出;短录音/降级路径 nil。
        var chapters: [Chapter]? = nil
        /// 提到的人(#85 v1):digest 同一次调用顺手抽取;失败/降级路径 nil。
        var people: [String]? = nil
    }

    /// 块级摘要(#68)的规整结果:章节标题+要点+该块待办。
    private struct ChunkResult {
        var sectionTitle: String
        var keyPoints: String
        var actions: [ActionItem]
    }

    /// 「今天」上下文(#61 修正):转写正文里通常没有日期,模型只能瞎猜基准日——
    /// 「周五」换算错全因于此。两个引擎的输入第一行都注入今天日期+星期。
    static var todayContext: String {
        "今天是\(todayFormatter.string(from: Date()))。"
    }

    /// 日期行只缓存一枚(#80 起排程/预览/digest 高频走 todayContext,不再每次新建)。
    private static let todayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        return formatter
    }()

    /// digest 输入的公共前缀(#71):今天日期仍居第一行——云端 prompt 明说「按输入第一行的今天换算」;
    /// 「关于我」可选跟在其后,给模型人名/术语的写法线索(不是待整理内容)。留空行为不变,
    /// 注入侧限长 400 字,防一句背景把本就紧张的摘要输入挤得更短。
    static var digestContext: String { digestContext(about: LLMSettings.aboutMe) }

    /// #76:预览与实发共用同一拼接点——设置页传草稿值实时预览,发送路径读已存值;
    /// trim 与 400 字截断都在这,两条路永不漂移。
    static func digestContext(about raw: String) -> String {
        let about = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !about.isEmpty else { return todayContext }
        return todayContext + "\n关于我的背景(只用于理解转写内容与专有名词写法):\n" + String(about.prefix(400))
    }

    /// 三级瀑布(#39):本机 Foundation Models(可用必优先)→ 云端(已配置)→ 留空+状态卡说明。
    /// 国行 iPhone 无 Apple 智能,云端是主力用户实际吃到摘要卡的路径。
    /// 长录音(#68):分段超单块口径→先走分块理解+合并;任何一块失败整条退回本短路径
    /// (首 4000 字)——降级永远不比旧版差。合并复用本函数(压縮文本不再超限,天然短路径)。
    private func digest(transcript: String, segments: [TranscriptSegment]? = nil) async -> DigestResult? {
        guard !transcript.isEmpty else { return nil }
        if let blocks = TranscriptChunking.blocks(segments), let long = await longDigest(blocks: blocks) {
            return long
        }
        let model = SystemLanguageModel.default
        if model.isAvailable, let result = await onDeviceDigest(transcript: transcript, model: model) {
            return result
        }
        if LLMSettings.isConfigured, let result = await cloudDigest(transcript: transcript) {
            return result
        }
        if !model.isAvailable, !LLMSettings.isConfigured {
            // 不可用不是错误但也不能永远无声(实测曾 35 条静默跳过无人察觉),状态卡说一句;
            // 云端已配置且已报过具体错误的,不在这里用泛化提示覆盖。
            if case .unavailable(let reason) = model.availability {
                DayTapLog.transcribe.info("digest unavailable: \(String(describing: reason), privacy: .public)")
            }
            statusText = LLMSettings.enabled
                ? "转写完成；AI 模型未配全（服务商 / 模型 / API Key），未生成摘要/标题/类别"
                : "转写完成；本机 Apple 智能不可用，未生成摘要/标题/类别（可在设置的 AI 模型里配置）"
            return nil
        }
        // 本机可用但失败且云端未配:错误已在 onDeviceDigest 的 catch 里报过,不重复。
        return nil
    }

    // MARK: - 长录音分块摘要(#68)

    /// 分块理解→合并(#68):块级 digest 出「章节标题+要点+待办」,拼成小文本再走
    /// 短路径出全局 类别/标题/摘要/去重待办——全局摘要仍然三句话,但背后看过了全文。
    /// 章节条=块标题+块起点,合并调用免费带出。引擎选择与短路径同口径:本机可用必优先。
    private func longDigest(blocks: [TranscriptChunking.Block]) async -> DigestResult? {
        let model = SystemLanguageModel.default
        var chunks: [ChunkResult] = []
        if model.isAvailable {
            for block in blocks {
                guard let chunk = await onDeviceChunkDigest(block: block, model: model) else {
                    DayTapLog.transcribe.info("long digest on-device chunk failed, fall back to short path")
                    return nil
                }
                chunks.append(chunk)
            }
        } else if LLMSettings.isConfigured {
            for block in blocks {
                guard let chunk = await cloudChunkDigest(block: block) else {
                    DayTapLog.transcribe.info("long digest cloud chunk failed, fall back to short path")
                    return nil
                }
                chunks.append(chunk)
            }
        } else {
            // 两引擎都不在:交给外层短路径去给「不可用」状态卡,这里不重复说话。
            return nil
        }
        var parts: [String] = []
        var actionLines: [String] = []
        for (index, chunk) in chunks.enumerated() {
            parts.append("【第\(index + 1)章 \(chunk.sectionTitle)】\(chunk.keyPoints)")
            for action in chunk.actions {
                var line = "· \(action.text)"
                if let due = action.dueAt {
                    line += "（截止 \(Self.dueLineFormatter.string(from: due))）"
                }
                if action.direction == .other { line += "（别人答应的）" }
                actionLines.append(line)
            }
        }
        if !actionLines.isEmpty {
            parts.append("以上各片段提到的待办候选:\n" + actionLines.joined(separator: "\n"))
        }
        guard var merged = await digest(transcript: parts.joined(separator: "\n")) else { return nil }
        // #75 摘要回链(A):块级 keyPoints 随章节落库,要点=回链锚点(本机/云端两引擎共用此合并点)。
        merged.chapters = zip(blocks, chunks).map {
            let trimmed = $1.keyPoints.trimmingCharacters(in: .whitespacesAndNewlines)
            return Chapter(
                title: String($1.sectionTitle.prefix(8)),
                start: $0.start,
                keyPoints: trimmed.isEmpty ? nil : trimmed
            )
        }
        return merged
    }

    /// 块摘要的日期行口径(#68):与 ActionItem.parseDue 吃的 16 位格式一致,合并层原样过。
    private static let dueLineFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// 两引擎块输出的统一规整(#68):去空串、同文去重(#62 口径)、方向未知视作 me(#70)。
    private static func chunkResult(
        sectionTitle: String,
        keyPoints: String,
        actionTuples: [(text: String, due: String, direction: String)]
    ) -> ChunkResult {
        var seen = Set<String>()
        let actions = actionTuples.compactMap { tuple -> ActionItem? in
            let text = tuple.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text).inserted else { return nil }
            return ActionItem(
                text: text,
                dueAt: ActionItem.parseDue(tuple.due),
                direction: ActionDirection(rawValue: tuple.direction)
            )
        }
        return ChunkResult(
            sectionTitle: sectionTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPoints: keyPoints.trimmingCharacters(in: .whitespacesAndNewlines),
            actions: actions
        )
    }

    /// 本机块摘要(#68):ChunkDigest 一次出 章节标题+要点+待办(带截止与方向)。
    private func onDeviceChunkDigest(block: TranscriptChunking.Block, model: SystemLanguageModel) async -> ChunkResult? {
        let session = LanguageModelSession(
            model: model,
            instructions: "你整理中文语音录音转写的一个片段。只依据片段内容作答,用简体中文,不要发明片段里没有的信息。"
        )
        do {
            let response = try await session.respond(
                to: Self.digestContext + "\n片段如下:\n\(block.text)",
                generating: ChunkDigest.self
            )
            let raw = response.content
            let deadlines = raw.actionDeadlines
            let directions = raw.actionDirections
            let tuples = raw.actionItems.enumerated().map { index, text in
                (text: text,
                 due: index < deadlines.count ? deadlines[index] : "",
                 direction: index < directions.count ? directions[index] : "me")
            }
            return Self.chunkResult(sectionTitle: raw.sectionTitle, keyPoints: raw.keyPoints, actionTuples: tuples)
        } catch {
            DayTapLog.transcribe.info("chunk digest failed \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 云端块摘要(#68):与 cloudDigest 同一套宽容 JSON 解析,只是字段换成章节三件套。
    private func cloudChunkDigest(block: TranscriptChunking.Block) async -> ChunkResult? {
        guard let client = LLMClient() else { return nil }
        struct ChunkPayload: Decodable {
            var sectionTitle: String?
            var keyPoints: String?
            var actionItems: [CloudAction]?
        }
        do {
            let reply = try await client.chat(
                system: "你整理中文语音录音转写的一个片段,只依据片段内容作答,用简体中文,不发明片段里没有的信息。只输出一个 JSON 对象(不要 markdown 代码块),字段:sectionTitle(该片段的主题短标题,不超过8个字,无结尾标点),keyPoints(该片段要点,不超过两句话),actionItems(对象数组,每项 {text:待办一句话, direction:\"me\"或\"other\"(我答应别人的=me,别人答应我的=other,拿不准给 me), due:截止时间 yyyy-MM-dd HH:mm,把相对表述按输入第一行的今天换算成具体日期,没有明确时间给空字符串},没有待办给空数组),people(人名数组,只列转写里明确提到的人,优先用背景段里给过的规范写法,没有给空数组)。",
                user: Self.digestContext + "\n片段如下:\n" + block.text
            )
            let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
                DayTapLog.transcribe.info("cloud chunk no json in reply")
                return nil
            }
            guard let payload = try? JSONDecoder().decode(ChunkPayload.self, from: Data(text[start...end].utf8)) else {
                DayTapLog.transcribe.info("cloud chunk bad json head=\(text[start...].prefix(200), privacy: .public)")
                return nil
            }
            let tuples = (payload.actionItems ?? []).map { action in
                (text: action.text ?? "", due: action.due ?? "", direction: action.direction ?? "me")
            }
            return Self.chunkResult(
                sectionTitle: payload.sectionTitle ?? "片段",
                keyPoints: payload.keyPoints ?? "",
                actionTuples: tuples
            )
        } catch {
            DayTapLog.transcribe.info("cloud chunk failed \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func onDeviceDigest(transcript: String, model: SystemLanguageModel) async -> DigestResult? {
        let session = LanguageModelSession(
            model: model,
            instructions: "你整理中文语音录音的转写全文。只依据全文内容作答,用简体中文,不要发明全文里没有的信息。"
        )
        do {
            let response = try await session.respond(
                to: Self.digestContext + "\n转写全文如下:\n\(String(transcript.prefix(4000)))",
                generating: RecordingDigest.self
            )
            let raw = response.content
            let category = RecordingCategory.presets.first { raw.category.contains($0) }
            let title = raw.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = raw.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            // #62:先按下标配对再过滤空串——原实现过滤 text 不过滤 deadline,
            // 模型输出中间空串时其后所有截止时间整体左移挂错人。
            let deadlines = raw.actionDeadlines
            let directions = raw.actionDirections
            let paired = raw.actionItems.enumerated().compactMap { index, rawText -> ActionItem? in
                let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let due = index < deadlines.count ? ActionItem.parseDue(deadlines[index]) : nil
                let direction = index < directions.count ? ActionDirection(rawValue: directions[index]) : nil
                return ActionItem(text: text, dueAt: due, direction: direction)
            }
            // 同文去重(#62):转写重复口述会让 AI 出两条一样的待办,text 即 id,撞则行为未定义。
            var seen = Set<String>()
            let actions = paired.filter { seen.insert($0.text).inserted }
            if category == nil {
                DayTapLog.transcribe.info("digest unmatched category \(raw.category.prefix(10), privacy: .public)")
            }
            let people = Array(Set(raw.people.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.map { String($0.prefix(12)) })).sorted()
            return DigestResult(
                category: category,
                title: title.isEmpty ? nil : String(title.prefix(12)),
                summary: summary.isEmpty ? nil : summary,
                actions: actions.isEmpty ? nil : actions,
                people: people.isEmpty ? nil : people
            )
        } catch {
            DayTapLog.transcribe.info("digest failed \(error.localizedDescription, privacy: .public)")
            // 摘要失败不拖垮转写,但要让人看见——静默降级曾让问题长期隐形。
            statusText = "摘要生成失败：\(error.localizedDescription)（转写不受影响）"
            return nil
        }
    }

    /// 云端出摘要(#39→#42 走 LLMClient):转写前 4000 字(+#71「关于我」若填)发送到所配服务,隐私在设置页明示。
    private func cloudDigest(transcript: String) async -> DigestResult? {
        guard let client = LLMClient() else {
            statusText = "AI 模型配置无效（服务商 / 模型 / API Key），转写不受影响"
            return nil
        }
        do {
            return try await cloudStyleDigest(transcript: transcript, client: client)
        } catch let error as LLMClient.CallError {
            DayTapLog.transcribe.info("cloud digest failed \(error.message, privacy: .public)")
            statusText = "AI 整理失败：\(error.message)（转写不受影响）"
            return nil
        } catch {
            DayTapLog.transcribe.info("cloud digest failed \(error.localizedDescription, privacy: .public)")
            statusText = "AI 整理失败：\(error.localizedDescription)（转写不受影响）"
            return nil
        }
    }

    // MARK: - #78 事的聚合

    /// 跨录音进展摘要:把相关各条(时间正序)的 日期/标题/摘要/章节要点/未完成待办 拼输入,
    /// 引擎同摘要瀑布;不落库、不动 statusText——按需一次性,结果由聚合页自己呈现。
    func affairSummary(records: [RecordingRecord]) async -> AffairResult? {
        let lines = records.sorted { $0.createdAt < $1.createdAt }.map { record -> String in
            var line = "【\(record.createdAt.formatted(date: .abbreviated, time: .omitted)) · \(record.title)】"
            if let summary = record.summary { line += summary }
            for chapter in record.chapters ?? [] {
                if let points = chapter.keyPoints { line += ";要点:\(points)" }
            }
            for todo in record.actionItems ?? [] where !todo.isDone {
                line += ";未办:\(todo.text)"
            }
            return line
        }
        let user = Self.digestContext
            + "\n以下是同一件事的多条录音(按时间正序):\n" + String(lines.joined(separator: "\n").prefix(6000))
            + "\n请汇总这件事的进展。"
        let model = SystemLanguageModel.default
        if model.isAvailable, let result = await onDeviceAffair(user: user, model: model) {
            return result
        }
        if LLMSettings.isConfigured, let result = await cloudAffair(user: user) {
            return result
        }
        DayTapLog.transcribe.info("affair summary unavailable: on-device=\(model.isAvailable), cloud=\(LLMSettings.isConfigured)")
        return nil
    }

    private func onDeviceAffair(user: String, model: SystemLanguageModel) async -> AffairResult? {
        let session = LanguageModelSession(
            model: model,
            instructions: "你汇总同一件事的多条录音进展,只依据给出的内容,用简体中文,不发明没提过的信息。"
        )
        do {
            let response = try await session.respond(to: user, generating: AffairDigest.self)
            let raw = response.content
            return Self.normalizedAffair(status: raw.status, highlights: raw.highlights, todos: raw.openTodos)
        } catch {
            DayTapLog.transcribe.info("affair on-device failed \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func cloudAffair(user: String) async -> AffairResult? {
        guard let client = LLMClient() else { return nil }
        struct AffairPayload: Decodable {
            var status: String?
            var highlights: [String]?
            var openTodos: [String]?
        }
        do {
            let reply = try await client.chat(
                system: "你汇总同一件事的多条录音进展,只依据给出的内容,用简体中文,不发明没提过的信息。只输出一个 JSON 对象(不要 markdown 代码块),字段:status(现状,不超过三句话),highlights(数组,按时间列关键进展,每条一句话,可带日期),openTodos(数组,还没办完的事,每条一句话;没有给空数组)。",
                user: user
            )
            let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
                DayTapLog.transcribe.info("affair cloud no json")
                return nil
            }
            guard let payload = try? JSONDecoder().decode(AffairPayload.self, from: Data(text[start...end].utf8)) else {
                DayTapLog.transcribe.info("affair cloud bad json head=\(text[start...].prefix(200), privacy: .public)")
                return nil
            }
            return Self.normalizedAffair(
                status: payload.status ?? "",
                highlights: payload.highlights ?? [],
                todos: payload.openTodos ?? []
            )
        } catch {
            DayTapLog.transcribe.info("affair cloud failed \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 两引擎输出的统一规整:去空串、截长、上限(highlights 8 条/todos 10 条)。
    static func normalizedAffair(status: String, highlights: [String], todos: [String]) -> AffairResult {
        AffairResult(
            status: String(status.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)),
            highlights: highlights.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)) }
                .filter { !$0.isEmpty }
                .prefix(8).map { $0 },
            openTodos: todos.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)) }
                .filter { !$0.isEmpty }
                .prefix(10).map { $0 }
        )
    }

    /// #77 同题对照:用**临时配置**(不落库,关页即弃)对同一段转写出一份摘要。
    /// 不写库、不动 statusText——错误原样抛给对照页自己说。
    func compareDigest(transcript: String, baseURL: String, model: String, apiKey: String) async throws -> CompareResult {
        guard let client = LLMClient(baseURL: baseURL, model: model, apiKey: apiKey) else {
            throw LLMClient.CallError(message: "临时配置不全（Base URL / 模型 / API Key）")
        }
        let result = try await cloudStyleDigest(transcript: transcript, client: client)
        return CompareResult(title: result.title, summary: result.summary, actions: result.actions)
    }

    /// 同题对照的只读结果(#77):类别/人物不入对照卡,聚焦标题·摘要·待办三样肉眼可比。
    struct CompareResult: Equatable {
        var title: String?
        var summary: String?
        var actions: [ActionItem]?
    }

    /// 云端口径的摘要核(#77 从 cloudDigest 抽出共用):同一 prompt(#71 关于我 + 前 4000 字)、
    /// 同一套宽容 JSON 解析——所配配置与临时配置跑的是一模一样的输入,对照才公平。
    private func cloudStyleDigest(transcript: String, client: LLMClient) async throws -> DigestResult {
        struct Payload: Decodable {
            var category: String?
            var title: String?
            var summary: String?
            // #61:actionItems 兼容两种形态——新 [{text,due,direction}] 与旧裸字符串数组。
            var actionItems: [CloudAction]?
            // #85 v1:提到的人;没抽到给 nil。
            var people: [String]?
        }
        let reply = try await client.chat(
            system: "你整理中文语音录音的转写全文,只依据全文内容作答,用简体中文,不发明全文里没有的信息。只输出一个 JSON 对象(不要 markdown 代码块),字段:category(必须是 会议/活动/灵感/日常/其他 之一),title(不超过12字,无结尾标点),summary(不超过三句话),actionItems(对象数组,每项 {text:待办一句话, direction:\"me\"或\"other\"(我答应别人的=me,别人答应我的=other,拿不准给 me), due:截止时间 yyyy-MM-dd HH:mm,把「周五下午」「下月1号」这类相对表述按输入第一行给出的今天换算成具体日期,没有明确时间给空字符串},没有待办给空数组),people(人名数组,只列转写里明确提到的人,优先用背景段里给过的规范写法,没有给空数组)。",
            user: Self.digestContext + "\n" + String(transcript.prefix(4000))
        )
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        // 宽容解析:截第一个 { 到最后一个 },容忍模型带代码围栏或前后废话。
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            DayTapLog.transcribe.info("cloud digest no json in reply")
            throw LLMClient.CallError(message: "回复不是有效 JSON")
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: Data(text[start...end].utf8))
        } catch {
            // #67:小模型常见尾逗号/裸键等非严格 JSON——统一文案+留原始回复前 200 字做诊断。
            DayTapLog.transcribe.info("cloud digest bad json head=\(text[start...].prefix(200), privacy: .public)")
            throw LLMClient.CallError(message: "回复不是有效 JSON")
        }
        let category = RecordingCategory.presets.first { (payload.category ?? "").contains($0) }
        var seen = Set<String>()
        let actions = (payload.actionItems ?? [])
            .compactMap { raw -> ActionItem? in
                guard let text = raw.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty,
                      seen.insert(text).inserted  // 同文去重(#62)
                else { return nil }
                return ActionItem(
                    text: text,
                    dueAt: raw.due.flatMap(ActionItem.parseDue),
                    direction: raw.direction.flatMap(ActionDirection.init)
                )
            }
        let people = Array(Set((payload.people ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.map { String($0.prefix(12)) })).sorted()
        return DigestResult(
            category: category,
            title: payload.title.flatMap { $0.isEmpty ? nil : String($0.prefix(12)) },
            summary: payload.summary.flatMap { $0.isEmpty ? nil : $0 },
            actions: actions.isEmpty ? nil : actions,
            people: people.isEmpty ? nil : people
        )
    }

    /// 连通性测试(#42):设置页一键验配——别等第一条录音失败才发现配错。
    /// 返回 (成败, 面向用户文案);界面按成败着色(绿=通,警示色=不通)。
    static func testLLMConnection() async -> (ok: Bool, message: String) {
        guard let client = LLMClient() else { return (false, "配置不全（服务商 / 模型 / API Key）") }
        do {
            let reply = try await client.chat(
                system: "你是连通性测试助手。",
                user: "请只回复两个字：正常",
                temperature: 0
            )
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? (false, "服务有响应，但返回为空")
                : (true, "连接正常 · \(LLMSettings.provider.displayName) \(LLMSettings.model)")
        } catch let error as LLMClient.CallError {
            return (false, "失败：\(error.message)")
        } catch {
            return (false, "失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 存量补跑(#39)

    /// 补跑候选:在列、已转写、既无摘要卡也无类别(新录音走转写链路,不进这里)。
    var backfillCandidateCount: Int {
        library.snapshot().filter { record in
            record.deletedAt == nil && record.transcript != nil
                && record.summary == nil && record.category == nil
        }.count
    }

    @Published private(set) var backfillRunning = false
    @Published private(set) var backfillDone = 0
    @Published private(set) var backfillTotal = 0

    /// 设置页一键补跑:串行过候选,digest 瀑布本机优先;失败条目跳过不中断。
    func backfillDigests() {
        guard activeID == nil, !backfillRunning else {
            statusText = "正在转写，稍后再补"
            return
        }
        let candidates = library.snapshot().filter { record in
            record.deletedAt == nil && record.transcript != nil
                && record.summary == nil && record.category == nil
        }
        guard !candidates.isEmpty else {
            statusText = "没有需要补的录音"
            return
        }
        backfillRunning = true
        backfillTotal = candidates.count
        backfillDone = 0
        Task {
            defer { backfillRunning = false }
            for record in candidates {
                guard var fresh = library.record(id: record.id), let transcript = fresh.transcript else { continue }
                if let result = await digest(transcript: transcript, segments: fresh.transcriptSegments) {
                    if fresh.category == nil { fresh.category = result.category }
                    if fresh.autoTitle == nil { fresh.autoTitle = result.title }
                    if fresh.summary == nil { fresh.summary = result.summary }
                    if fresh.actionItems == nil { fresh.actionItems = result.actions }
                    if fresh.chapters == nil { fresh.chapters = result.chapters }
                    if fresh.people == nil { fresh.people = result.people }
                    fresh.updatedAt = Date()
                    library.upsert(fresh)
                }
                backfillDone += 1
                statusText = "补生成摘要 \(backfillDone)/\(backfillTotal)…"
            }
            statusText = "补生成完成：\(backfillDone) 条"
        }
    }

    // MARK: - Day 页今日安排(#80 P0)

    /// 排程入口(#80):输入=今天的待办、日历忙段与健康概况(#80-P1:睡眠/步数等聚合量,静默读取,无授权即无此段);
    /// 引擎同摘要三级瀑布(本机优先→云端兜底→nil)。失败不置 statusText——排程是用户主动按的,
    /// 结果空由 Day 页自己说话,不混进转写状态流。
    func daySuggestions(todos: [String], busy: [String], health: String? = nil) async -> [DayAgenda.Suggestion]? {
        let todoBlock = todos.isEmpty ? "（无）" : todos.joined(separator: "\n")
        let busyBlock = busy.isEmpty ? "（无）" : busy.joined(separator: "\n")
        let user = Self.digestContext
            + "\n今天的待办:\n" + todoBlock
            + "\n今天日历已占用的时段:\n" + busyBlock
            + (health.map { "\n健康概况(安排强度时参考):\n\($0)" } ?? "")
            + "\n现在是" + nowLine() + "。请给今天剩余时间 2–4 条安排建议。"
        let model = SystemLanguageModel.default
        if model.isAvailable, let list = await onDeviceDayPlan(user: user, model: model) {
            return list
        }
        if LLMSettings.isConfigured, let list = await cloudDayPlan(user: user) {
            return list
        }
        DayTapLog.transcribe.info("day plan unavailable: on-device=\(model.isAvailable), cloud=\(LLMSettings.isConfigured)")
        return nil
    }

    /// 「现在是 HH:mm」——排程要知道还剩多少白天;时区跟设备。
    private static let nowTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private func nowLine() -> String {
        Self.nowTimeFormatter.string(from: Date())
    }

    private func onDeviceDayPlan(user: String, model: SystemLanguageModel) async -> [DayAgenda.Suggestion]? {
        let session = LanguageModelSession(
            model: model,
            instructions: "你帮人安排今天剩余的时间,只依据给出的待办与占用时段,用简体中文,不发明没给过的信息。"
        )
        do {
            let response = try await session.respond(to: user, generating: DayPlan.self)
            let raw = response.content
            return DayAgenda.normalizedSuggestions(
                titles: raw.titles, reasons: raw.reasons, starts: raw.starts,
                minutes: raw.minutes, kinds: raw.kinds
            )
        } catch {
            DayTapLog.transcribe.info("day plan on-device failed \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 云端排程(#80):与 cloudDigest 同一套宽容 JSON 解析。
    private func cloudDayPlan(user: String) async -> [DayAgenda.Suggestion]? {
        guard let client = LLMClient() else { return nil }
        struct PlanPayload: Decodable {
            struct Item: Decodable {
                var title: String?
                var reason: String?
                var start: String?
                var minutes: Int?
                var kind: String?
            }
            var suggestions: [Item]?
        }
        do {
            let reply = try await client.chat(
                system: "你帮人安排今天剩余的时间,只依据给出的待办与占用时段,用简体中文,不发明没给过的信息。只输出一个 JSON 对象(不要 markdown 代码块),字段:suggestions(对象数组,每项 {title:安排标题,不超过12字,无结尾标点, reason:一句话理由, start:建议开始时刻 24小时制 HH:mm, minutes:建议时长分钟数, kind:运动/专注/休息/复盘 之一}),给 2 到 4 条。",
                user: user
            )
            let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
                DayTapLog.transcribe.info("day plan cloud no json in reply")
                return nil
            }
            guard let payload = try? JSONDecoder().decode(PlanPayload.self, from: Data(text[start...end].utf8)) else {
                DayTapLog.transcribe.info("day plan cloud bad json head=\(text[start...].prefix(200), privacy: .public)")
                return nil
            }
            let items = payload.suggestions ?? []
            return DayAgenda.normalizedSuggestions(
                titles: items.map { $0.title ?? "" },
                reasons: items.map { $0.reason ?? "" },
                starts: items.map { $0.start ?? "" },
                minutes: items.map { $0.minutes ?? 30 },
                kinds: items.map { $0.kind ?? "" }
            )
        } catch {
            DayTapLog.transcribe.info("day plan cloud failed \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// @Generable 的结构化输出(#35/#36/#29):一次模型调用产出 类别+短标题+摘要+待办。
/// 宏生成的 init 扩展要求类型非 private,故置于文件级。
@Generable
struct RecordingDigest {
    @Guide(description: "最贴切的类别,必须恰好是:会议、活动、灵感、日常、其他 五个词之一")
    var category: String
    @Guide(description: "内容短标题,不超过12个字,不要句号等结尾标点")
    var title: String
    @Guide(description: "内容摘要,不超过三句话")
    var summary: String
    @Guide(description: "录音里提到的待办事项,每条一句话;没有待办就给空列表")
    var actionItems: [String]
    @Guide(description: "与 actionItems 一一对应的截止时间数组,格式 yyyy-MM-dd HH:mm;把「周五下午」「下月1号」这类相对表述换算成具体日期,今天的日期在输入第一行给出,以它为基准;该条没有明确时间就给空字符串")
    var actionDeadlines: [String]
    @Guide(description: "与 actionItems 一一对应的方向数组:\"me\"=我答应别人的,\"other\"=别人答应我的;拿不准给 \"me\"")
    var actionDirections: [String]
    @Guide(description: "转写里明确提到的人名数组,只列真名或常用称呼,优先用背景段给过的规范写法;没提到给空列表")
    var people: [String]
}

/// @Generable 的块级结构化输出(#68):长录音分块摘要用,一次产出 章节标题+要点+待办。
@Generable
struct ChunkDigest {
    @Guide(description: "该片段的主题短标题,不超过8个字,不要句号等结尾标点")
    var sectionTitle: String
    @Guide(description: "该片段的要点,不超过两句话")
    var keyPoints: String
    @Guide(description: "片段里提到的待办事项,每条一句话;没有待办就给空列表")
    var actionItems: [String]
    @Guide(description: "与 actionItems 一一对应的截止时间数组,格式 yyyy-MM-dd HH:mm;把相对表述按输入第一行的今天换算成具体日期;没有明确时间就给空字符串")
    var actionDeadlines: [String]
    @Guide(description: "与 actionItems 一一对应的方向数组:\"me\"=我答应别人的,\"other\"=别人答应我的;拿不准给 \"me\"")
    var actionDirections: [String]
}

/// @Generable 的排程结构化输出(#80):平行数组口径与 #35 同款(嵌套结构体不赌宏的边角),
/// 配对与钳制在 DayAgenda.normalizedSuggestions,空标题先丢防左移(#62)。
@Generable
struct DayPlan {
    @Guide(description: "每条安排的标题,不超过12个字,无结尾标点")
    var titles: [String]
    @Guide(description: "与 titles 一一对应的理由,每条一句话")
    var reasons: [String]
    @Guide(description: "与 titles 一一对应的建议开始时刻,24小时制 HH:mm")
    var starts: [String]
    @Guide(description: "与 titles 一一对应的建议时长,分钟数")
    var minutes: [Int]
    @Guide(description: "与 titles 一一对应的类型:运动、专注、休息、复盘 之一")
    var kinds: [String]
}

/// 事的聚合结果(#78):现状+按时间的关键进展+未决待办;零实体,不落库。
struct AffairResult: Equatable {
    var status: String
    var highlights: [String]
    var openTodos: [String]
}

/// @Generable 的聚合结构化输出(#78)。
@Generable
struct AffairDigest {
    @Guide(description: "这件事的现状,不超过三句话")
    var status: String
    @Guide(description: "按时间排列的关键进展,每条一句话,可带日期;给 2 到 8 条")
    var highlights: [String]
    @Guide(description: "还没办完的事,每条一句话;没有给空列表")
    var openTodos: [String]
}

/// 云端 actionItems 的宽容解码(#61→#70):兼容旧裸串、新 {text,due,direction};
/// direction 只认 me/other,未知值解码后仍是 nil(呈现上视作 me)。
private struct CloudAction: Decodable {
    var text: String?
    var due: String?
    var direction: String?

    init(from decoder: Decoder) throws {
        if let plain = try? decoder.singleValueContainer().decode(String.self) {
            text = plain
            due = nil
            direction = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        due = try container.decodeIfPresent(String.self, forKey: .due)
        direction = try? container.decodeIfPresent(String.self, forKey: .direction)
    }

    enum CodingKeys: String, CodingKey { case text, due, direction }
}

enum TranscriptionError: LocalizedError {
    case unsupportedLocale

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale:
            return "这台设备不支持中文语音转写"
        }
    }
}

extension Notification.Name {
    /// 新录音入库(手表收到/手机录完,#29):转写中心听到就试清自动队列。
    static let daytapRecordImported = Notification.Name("daytap.recordImported")
}
