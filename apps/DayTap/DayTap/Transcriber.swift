import AVFoundation
import Combine
import Foundation
import FoundationModels
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
    /// 会话级记忆——重启 App 后可再试一轮。
    private var autoFailedIDs: Set<String> = []

    init(library: RecordingLibrary) {
        self.library = library
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
                try await run(record: record, fileURL: fileURL)
                statusText = nil
            } catch {
                DayTapLog.transcribe.error("transcribe \(record.id, privacy: .public) failed \(error.localizedDescription, privacy: .public)")
                statusText = "转文字失败：\(error.localizedDescription)"
            }
        }
    }

    /// 一条转完:有手动插队先转它;刚这条没出全文=失败,记入会话级失败名单防自动死循环;
    /// 然后继续清队列。
    private func afterCompletion(id: String) {
        if library.record(id: id)?.transcript == nil {
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

    /// 自动队列条件:在列(未软删)、没转过、本次会话没失败过、音频在、
    /// 时长 ≤2h(超长留给手动,内存/耗时护栏)。
    private func autoCandidates() -> [RecordingRecord] {
        library.snapshot().filter { record in
            record.deletedAt == nil
                && record.transcript == nil
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
        // 转写完顺手出摘要卡(#35)+短标题(#36)+类别(#29):一次调用三件事;
        // 类别被用户纠偏过的不覆盖;摘要/标题是派生内容,重新转写就重生成;
        // 模型不可用→全留 nil(未分类/时刻名),不影响转写落库。
        if fresh.transcript != nil,
           fresh.category == nil || fresh.summary == nil || fresh.autoTitle == nil {
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

    // MARK: - 摘要卡与自动归类(#35/#36/#29)

    /// digest() 的规整结果:字段级可空——模型某件没办好不连坐其它件。
    private struct DigestResult {
        var category: String?
        var title: String?
        var summary: String?
        var actions: [String]?
    }

    private func digest(transcript: String) async -> DigestResult? {
        guard !transcript.isEmpty else { return nil }
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            DayTapLog.transcribe.info("digest skipped: foundation models unavailable")
            return nil
        }
        let session = LanguageModelSession(
            model: model,
            instructions: "你整理中文语音录音的转写全文。只依据全文内容作答,用简体中文,不要发明全文里没有的信息。"
        )
        do {
            let response = try await session.respond(
                to: "转写全文如下:\n\(String(transcript.prefix(4000)))",
                generating: RecordingDigest.self
            )
            let raw = response.content
            let category = RecordingCategory.presets.first { raw.category.contains($0) }
            let title = raw.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = raw.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let actions = raw.actionItems
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
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
