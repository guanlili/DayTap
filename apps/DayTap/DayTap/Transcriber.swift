import AVFoundation
import Combine
import Foundation
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
        fresh.updatedAt = Date()
        library.upsert(fresh)
        DayTapLog.transcribe.info("transcribed \(record.id, privacy: .public) chars=\(trimmed.count) segments=\(segments.count, privacy: .public)")
    }
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
