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
        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.drainAutoQueue() }
        }
        NotificationCenter.default.addObserver(
            forName: .daytapRecordImported,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.drainAutoQueue() }
        }
    }

    /// 手动「转文字」:空闲立即转,忙着就把这条插到自动队列最前(手动优先,#29)。
    func transcribe(_ record: RecordingRecord) {
        if activeID == nil {
            start(record)
            return
        }
        // 正在转别的:不打断,插队下一轮。
        pendingManualID = record.id
        statusText = "已排队,当前这条转完就轮到它"
    }

    private var pendingManualID: String?

    private func start(_ record: RecordingRecord) {
        let fileURL = library.fileURL(id: record.id)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            statusText = "找不到这条音频文件"
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
        if let next = pendingManualID, let record = library.record(id: next) {
            pendingManualID = nil
            start(record)
            return
        }
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
            let result = await digest(transcript: trimmed)
            if fresh.category == nil {
                fresh.category = result?.category
            }
            fresh.autoTitle = result?.title
            fresh.summary = result?.summary
            fresh.actionItems = result?.actions
        }
        fresh.updatedAt = Date()
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
    }

    /// 「今天」上下文(#61 修正):转写正文里通常没有日期,模型只能瞎猜基准日——
    /// 「周五」换算错全因于此。两个引擎的输入第一行都注入今天日期+星期。
    static var todayContext: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        return "今天是\(formatter.string(from: Date()))。"
    }

    /// 三级瀑布(#39):本机 Foundation Models(可用必优先)→ 云端(已配置)→ 留空+状态卡说明。
    /// 国行 iPhone 无 Apple 智能,云端是主力用户实际吃到摘要卡的路径。
    private func digest(transcript: String) async -> DigestResult? {
        guard !transcript.isEmpty else { return nil }
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

    private func onDeviceDigest(transcript: String, model: SystemLanguageModel) async -> DigestResult? {
        let session = LanguageModelSession(
            model: model,
            instructions: "你整理中文语音录音的转写全文。只依据全文内容作答,用简体中文,不要发明全文里没有的信息。"
        )
        do {
            let response = try await session.respond(
                to: Self.todayContext + "转写全文如下:\n\(String(transcript.prefix(4000)))",
                generating: RecordingDigest.self
            )
            let raw = response.content
            let category = RecordingCategory.presets.first { raw.category.contains($0) }
            let title = raw.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = raw.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let texts = raw.actionItems
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            // #61:截止时间与待办 zip 对齐(短了补 nil),AI 没给或格式不对就是无时间。
            let deadlines = raw.actionDeadlines
            let actions = texts.enumerated().map { index, text in
                ActionItem(
                    text: text,
                    dueAt: index < deadlines.count ? ActionItem.parseDue(deadlines[index]) : nil
                )
            }
            if category == nil {
                DayTapLog.transcribe.info("digest unmatched category \(raw.category.prefix(10), privacy: .public)")
            }
            return DigestResult(
                category: category,
                title: title.isEmpty ? nil : String(title.prefix(12)),
                summary: summary.isEmpty ? nil : summary,
                actions: actions.isEmpty ? nil : actions
            )
        } catch {
            DayTapLog.transcribe.info("digest failed \(error.localizedDescription, privacy: .public)")
            // 摘要失败不拖垮转写,但要让人看见——静默降级曾让问题长期隐形。
            statusText = "摘要生成失败：\(error.localizedDescription)（转写不受影响）"
            return nil
        }
    }

    /// 云端出摘要(#39→#42 走 LLMClient):转写前 4000 字发送到所配服务,隐私在设置页明示。
    private func cloudDigest(transcript: String) async -> DigestResult? {
        guard let client = LLMClient() else {
            statusText = "AI 模型配置无效（服务商 / 模型 / API Key），转写不受影响"
            return nil
        }
        struct Payload: Decodable {
            var category: String?
            var title: String?
            var summary: String?
            // #61:actionItems 兼容两种形态——新 [{text,due}] 与旧裸字符串数组。
            var actionItems: [CloudAction]?
        }

        struct CloudAction: Decodable {
            var text: String?
            var due: String?

            init(from decoder: Decoder) throws {
                if let plain = try? decoder.singleValueContainer().decode(String.self) {
                    text = plain
                    due = nil
                    return
                }
                let container = try decoder.container(keyedBy: CodingKeys.self)
                text = try container.decodeIfPresent(String.self, forKey: .text)
                due = try container.decodeIfPresent(String.self, forKey: .due)
            }

            enum CodingKeys: String, CodingKey { case text, due }
        }
        do {
            let reply = try await client.chat(
                system: "你整理中文语音录音的转写全文,只依据全文作答,用简体中文,不发明全文里没有的信息。只输出一个 JSON 对象(不要 markdown 代码块),字段:category(必须是 会议/活动/灵感/日常/其他 之一),title(不超过12字,无结尾标点),summary(不超过三句话),actionItems(对象数组,每项 {text:待办一句话, due:截止时间 yyyy-MM-dd HH:mm,把「周五下午」「下月1号」这类相对表述按输入第一行给出的今天换算成具体日期,没有明确时间给空字符串},没有待办给空数组)。",
                user: Self.todayContext + "\n" + String(transcript.prefix(4000))
            )
            let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            // 宽容解析:截第一个 { 到最后一个 },容忍模型带代码围栏或前后废话。
            guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
                DayTapLog.transcribe.info("cloud digest no json in reply")
                statusText = "AI 整理失败：回复不是有效 JSON（转写不受影响）"
                return nil
            }
            let payload = try JSONDecoder().decode(Payload.self, from: Data(text[start...end].utf8))
            let category = RecordingCategory.presets.first { (payload.category ?? "").contains($0) }
            let actions = (payload.actionItems ?? [])
                .compactMap { raw -> ActionItem? in
                    guard let text = raw.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !text.isEmpty
                    else { return nil }
                    return ActionItem(text: text, dueAt: raw.due.flatMap(ActionItem.parseDue))
                }
            return DigestResult(
                category: category,
                title: payload.title.flatMap { $0.isEmpty ? nil : String($0.prefix(12)) },
                summary: payload.summary.flatMap { $0.isEmpty ? nil : $0 },
                actions: actions.isEmpty ? nil : actions
            )
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
                if let result = await digest(transcript: transcript) {
                    if fresh.category == nil { fresh.category = result.category }
                    if fresh.autoTitle == nil { fresh.autoTitle = result.title }
                    if fresh.summary == nil { fresh.summary = result.summary }
                    if fresh.actionItems == nil { fresh.actionItems = result.actions }
                    fresh.updatedAt = Date()
                    library.upsert(fresh)
                }
                backfillDone += 1
                statusText = "补生成摘要 \(backfillDone)/\(backfillTotal)…"
            }
            statusText = "补生成完成：\(backfillDone) 条"
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
