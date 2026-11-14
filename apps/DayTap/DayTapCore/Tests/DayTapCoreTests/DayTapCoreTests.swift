import XCTest

@testable import DayTapCore

/// #50 首批单测:覆盖数据安全链路(索引编解码/文件名消毒)、回收站状态机、
/// iCloud 裁决(LWW/墓碑)、格式化边界。全部纯逻辑,swift test 直跑不开模拟器。
final class DayTapCoreTests: XCTestCase {
    // MARK: - RecordingRecord 编解码

    /// 旧 index.json 没有新字段(displayName/transcript/category…)——解码必须得 nil 而不是炸。
    /// 这是字段演进零迁移的底线(#29 起每个可选字段都靠它)。
    func testLegacyRecordDecodesWithMissingOptionals() {
        let json = """
        {"id":"abc","createdAt":"2026-11-01T08:00:00Z","durationSeconds":62.4,
         "byteCount":511000,"state":"pending","updatedAt":"2026-11-01T08:01:00Z"}
        """
        let record = CloudSyncLogic.decode(json)
        XCTAssertNotNil(record)
        XCTAssertNil(record?.displayName)
        XCTAssertNil(record?.transcript)
        XCTAssertNil(record?.deletedAt)
        XCTAssertNil(record?.origin)
        XCTAssertEqual(record?.awaitsPhoneAck, true)
    }

    func testRecordJSONRoundTrip() {
        var record = Self.record(id: "rt-1")
        record.displayName = "晨会"
        record.transcript = "今天聊了三件事"
        record.deletedAt = Date()
        let json = CloudSyncLogic.encode(record)
        XCTAssertNotNil(json)
        let decoded = CloudSyncLogic.decode(json!)
        XCTAssertEqual(decoded?.id, "rt-1")
        XCTAssertEqual(decoded?.displayName, "晨会")
        XCTAssertEqual(decoded?.deletedAt?.timeIntervalSince1970 ?? 0,
                       record.deletedAt!.timeIntervalSince1970, accuracy: 1)
    }

    /// 元数据里的 id 可能带路径字符——filename 消毒后不得能越出音频目录(#17 血案防线)。
    func testTransferKeysFilenameSanitization() {
        let evil = TransferKeys.filename(for: "../../etc/passwd")
        XCTAssertFalse(evil.contains("/"), "消毒后不得残留路径分隔符: \(evil)")
        XCTAssertTrue(evil.hasSuffix("etc-passwd.m4a"))
        XCTAssertEqual(TransferKeys.filename(for: ""), "recording.m4a")
        XCTAssertEqual(TransferKeys.filename(for: "ABC-123"), "ABC-123.m4a")
        XCTAssertEqual(TransferKeys.recordID(from: ["id": "  spaced  "]), "spaced")
        // id 缺失/为空时兜底生成 UUID——两次调用各随机,只能断非空。
        XCTAssertFalse(TransferKeys.recordID(from: nil).isEmpty)
        XCTAssertFalse(TransferKeys.recordID(from: ["id": "  "]).isEmpty)
    }

    // MARK: - RecordingLibrary 状态机

    func testLibraryUpsertRemovePersistsAcrossInstances() throws {
        let dir = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory, create: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("a", isDirectory: true)
        let index = dir.appendingPathComponent("index.json")

        let lib = RecordingLibrary(audioDirectory: audio, indexURL: index)
        lib.upsert(Self.record(id: "t1"))
        lib.upsert(Self.record(id: "t2"))
        XCTAssertEqual(lib.snapshot().count, 2)

        // 新实例从磁盘读——index.json 是唯一真相源。
        let reborn = RecordingLibrary(audioDirectory: audio, indexURL: index)
        XCTAssertEqual(reborn.snapshot().map(\.id).sorted(), ["t1", "t2"])

        reborn.softDelete(id: "t1")
        XCTAssertEqual(reborn.snapshot().first { $0.id == "t1" }?.deletedAt == nil, false)
        reborn.restore(id: "t1")
        XCTAssertEqual(reborn.snapshot().first { $0.id == "t1" }?.deletedAt, nil)

        reborn.remove(id: "t2")
        XCTAssertEqual(reborn.snapshot().count, 1)
    }

    /// 回收站到期清扫(#26):过期连条目带走,未过期保留。
    func testPurgeExpiredDeletedHonorsRetention() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lib = RecordingLibrary(
            audioDirectory: dir.appendingPathComponent("a"),
            indexURL: dir.appendingPathComponent("index.json")
        )
        var fresh = Self.record(id: "fresh")
        fresh.deletedAt = Date()
        var stale = Self.record(id: "stale")
        stale.deletedAt = Date().addingTimeInterval(-31 * 24 * 3600)
        lib.upsert(fresh)
        lib.upsert(stale)

        let purged = lib.purgeExpiredDeleted(retention: 30 * 24 * 3600)
        XCTAssertEqual(purged, 1)
        XCTAssertEqual(lib.snapshot().map(\.id), ["fresh"])
    }

    // MARK: - CloudSyncLogic 裁决

    func testShouldAdoptLatestWins() {
        let base = Date()
        var cloud = Self.record(id: "x", updatedAt: base.addingTimeInterval(10))
        let localNewer = Self.record(id: "x", updatedAt: base.addingTimeInterval(20))
        let localOlder = Self.record(id: "x", updatedAt: base.addingTimeInterval(5))
        XCTAssertEqual(CloudSyncLogic.shouldAdopt(cloud: cloud, local: localNewer), false)
        XCTAssertEqual(CloudSyncLogic.shouldAdopt(cloud: cloud, local: localOlder), true)
        // 换机恢复:本地没有,永远采纳云端。
        XCTAssertEqual(CloudSyncLogic.shouldAdopt(cloud: cloud, local: nil), true)
        cloud.updatedAt = base
    }

    func testOrphanTombstoneAction() {
        let now = Date()
        var trash = Self.record(id: "t")
        trash.deletedAt = now.addingTimeInterval(-29 * 24 * 3600)
        var gone = Self.record(id: "g")
        gone.deletedAt = now.addingTimeInterval(-31 * 24 * 3600)
        var alive = Self.record(id: "a")
        XCTAssertEqual(CloudSyncLogic.orphanAction(cloud: trash, now: now), .adopt)
        XCTAssertEqual(CloudSyncLogic.orphanAction(cloud: gone, now: now), .deleteCloud)
        XCTAssertEqual(CloudSyncLogic.orphanAction(cloud: alive, now: now), .adopt)
    }

    func testDirtyIDsByUpdatedAt() {
        let base = Date()
        let a = Self.record(id: "a", updatedAt: base)
        var b = Self.record(id: "b", updatedAt: base)
        // a 的 lastPushed 与 updatedAt 相等=已推过不脏;b 的账本时刻≠当前=脏。
        let dirty = CloudSyncLogic.dirtyIDs([a, b], lastPushed: ["a": base, "b": base.addingTimeInterval(1)])
        XCTAssertEqual(dirty, ["b"])
        // b 更新后仍无推送记录→继续脏;a 从未入账→也脏。
        b.updatedAt = base.addingTimeInterval(99)
        XCTAssertEqual(
            CloudSyncLogic.dirtyIDs([a, b], lastPushed: ["b": base.addingTimeInterval(99)]).sorted(),
            ["a"]
        )
    }

    // MARK: - 格式化边界

    func testDayTapFormat() {
        XCTAssertEqual(DayTapFormat.clock(0), "0:00")
        XCTAssertEqual(DayTapFormat.clock(75), "1:15")
        XCTAssertEqual(DayTapFormat.clock(3723), "1:02:03")
        XCTAssertEqual(DayTapFormat.clock(-5), "0:00")
        XCTAssertEqual(DayTapFormat.bytes(512), "512 B")
        XCTAssertEqual(DayTapFormat.bytes(1024 * 1024 + 100 * 1024), "1.1 MB")
        XCTAssertTrue(DayTapFormat.shareFilename(name: "周一/晨会", createdAt: Date()).hasSuffix(".m4a"))
        XCTAssertFalse(DayTapFormat.shareFilename(name: "a/b", createdAt: Date()).contains("/"))
    }

    // MARK: - LLM 配置

    /// 预设覆盖国内主流厂商(#42 口径):数量与 preset URL 非空(自定义除外)。
    func testLLMProviderPresets() {
        XCTAssertEqual(LLMProviderID.allCases.count, 7)
        for provider in LLMProviderID.allCases where provider != .custom {
            XCTAssertTrue(provider.presetBaseURL.hasPrefix("https://"))
            XCTAssertFalse(provider.modelCandidates.isEmpty, "\(provider) 需有默认模型候选")
        }
        XCTAssertTrue(LLMProviderID.openai.presetBaseURL.contains("openai.com"))
    }

    /// 「关于我」(#71):默认空;存取走 trim,空串语义=未填(注入侧据此跳过)。
    func testAboutMeRoundTrip() {
        let defaults = UserDefaults.standard
        defer { defaults.removeObject(forKey: LLMSettings.aboutMeKey) }
        XCTAssertEqual(LLMSettings.aboutMe, "")
        defaults.set("  同事小周、青云项目  \n", forKey: LLMSettings.aboutMeKey)
        XCTAssertEqual(LLMSettings.aboutMe, "同事小周、青云项目")
    }

    // MARK: - 语义密度(#69)

    /// 降级口径:无分段/空数组/时长非正/全空文本 → nil,调用方走纯色条。
    func testSpeechDensityDegrades() {
        XCTAssertNil(SpeechDensity.buckets(nil, duration: 60))
        XCTAssertNil(SpeechDensity.buckets([], duration: 60))
        XCTAssertNil(SpeechDensity.buckets(nil, duration: 0))
        XCTAssertNil(SpeechDensity.buckets([TranscriptSegment(text: "", start: 0, duration: 5)], duration: 60))
    }

    /// 半密半静:前半每秒一句、后半无话——前半高后半零,峰值归一到 1,平滑只渗一桶。
    func testSpeechDensityHalfHalf() {
        let dense = (0..<10).map { i in
            TranscriptSegment(text: "五个字的话", start: Double(i), duration: 0.9)
        }
        let density = SpeechDensity.buckets(dense, duration: 20, count: 20)!
        XCTAssertEqual(density.count, 20)
        XCTAssertEqual(density.max()!, 1, accuracy: 0.001)
        XCTAssertGreaterThan(density[5], 0.5)
        XCTAssertEqual(density[15], 0, accuracy: 0.0001)
        XCTAssertEqual(density[19], 0, accuracy: 0.0001)
    }

    /// 越界段(start+duration 超总时长)不崩:摊进末尾桶,前面的桶有值。
    func testSpeechDensityClampsBeyondDuration() {
        let rogue = TranscriptSegment(text: "尾巴", start: 59, duration: 30)
        let density = SpeechDensity.buckets([rogue], duration: 60, count: 10)!
        XCTAssertEqual(density.count, 10)
        XCTAssertGreaterThan(density[9], 0)
        XCTAssertGreaterThan(density[8], 0)
    }

    // MARK: - 转写分块(#68)

    /// 降级口径:无分段/空/总量不超限 → nil,调用方走单次 digest 不产章节。
    func testTranscriptChunkingDegrades() {
        XCTAssertNil(TranscriptChunking.blocks(nil))
        XCTAssertNil(TranscriptChunking.blocks([]))
        let short = (0..<5).map { i in
            TranscriptSegment(text: "短句", start: Double(i), duration: 0.5)
        }
        XCTAssertNil(TranscriptChunking.blocks(short))
        // 纯空白文本的分段等于没内容。
        let blank = [TranscriptSegment(text: "  ", start: 0, duration: 3)]
        XCTAssertNil(TranscriptChunking.blocks(blank))
    }

    /// 切分口径:切口落段边界不腰斩句子,块起点=块内首段 start,块内文本按行拼接。
    func testTranscriptChunkingSplits() {
        let segments = (0..<8).map { i in
            TranscriptSegment(text: String(repeating: "字", count: 600), start: Double(i) * 10, duration: 9)
        }
        let blocks = TranscriptChunking.blocks(segments, limit: 1000)!
        XCTAssertGreaterThanOrEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].start, 0)
        XCTAssertEqual(blocks[1].start, 10)  // 第二块从段 1 起(600+600>1000,段 0 独占一块)
        for block in blocks {
            XCTAssertEqual(block.text.count, 600)  // 单段成块,不拆段
        }
    }

    /// 章节(#68)向后兼容:旧索引无 chapters 解码为 nil;新数据往返不丢。
    func testChaptersRoundTripAndLegacy() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacyJSON = """
        {"id":"a","createdAt":"2026-11-14T10:00:00Z","durationSeconds":62,"byteCount":1000,
         "state":"acknowledged","lastError":null,"updatedAt":"2026-11-14T10:01:00Z"}
        """
        let legacy = try decoder.decode(RecordingRecord.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.chapters)

        var fresh = legacy
        fresh.chapters = [Chapter(title: "季度评审", start: 0), Chapter(title: "扩容报价", start: 1830)]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let back = try decoder.decode(RecordingRecord.self, from: try encoder.encode(fresh))
        XCTAssertEqual(back.chapters, fresh.chapters)
    }

    // MARK: - 承诺方向(#70)

    /// 解码口径:旧裸串→nil;新对象带 me/other;未知值→nil(呈现视作 me)。
    func testActionDirectionDecode() throws {
        let legacy = try JSONDecoder().decode([ActionItem].self, from: Data("[\"旧条目\"]".utf8))
        XCTAssertNil(legacy[0].direction)
        let modern = try JSONDecoder().decode(
            [ActionItem].self,
            from: Data(#"[{"text":"报价方案","isDone":false,"direction":"other"},{"text":"我发纪要"}]"#.utf8)
        )
        XCTAssertEqual(modern[0].direction, .other)
        XCTAssertNil(modern[1].direction)
        let unknown = try JSONDecoder().decode(
            [ActionItem].self,
            from: Data(#"[{"text":"未知","direction":"wat"}]"#.utf8)
        )
        XCTAssertNil(unknown[0].direction)
    }

    /// 分组口径:纯行动项单组无头标;混向才分「我答应的/别人答应的」,组内保序。
    func testActionDirectionGroups() {
        let mine1 = ActionItem(text: "我发方案")
        let mine2 = ActionItem(text: "我订会议室", direction: .me)
        let other1 = ActionItem(text: "对方出报价", direction: .other)

        let single = [mine1, mine2].directionGroups
        XCTAssertEqual(single.count, 1)
        XCTAssertNil(single[0].label)
        XCTAssertEqual(single[0].items.count, 2)

        let mixed = [mine1, other1, mine2].directionGroups
        XCTAssertEqual(mixed.count, 2)
        XCTAssertEqual(mixed[0].label, "我答应的")
        XCTAssertEqual(mixed[0].items.map(\.text), ["我发方案", "我订会议室"])
        XCTAssertEqual(mixed[1].label, "别人答应的")
        XCTAssertEqual(mixed[1].items.map(\.text), ["对方出报价"])
    }

    // MARK: - 工具

    private static func record(
        id: String,
        updatedAt: Date = Date(),
        createdAt: Date = Date()
    ) -> RecordingRecord {
        RecordingRecord(
            id: id,
            createdAt: createdAt,
            durationSeconds: 62.4,
            byteCount: 511_000,
            state: .pending,
            lastError: nil,
            updatedAt: updatedAt
        )
    }
}

extension DayTapCoreTests {
// MARK: - #59 防线回归

/// 重复到达(回执丢失→手表重传)不得抹掉手机端已转写/改名/摘要/软删状态。
func testImportAudioDuplicateArrivalPreservesRichFields() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let lib = RecordingLibrary(
        audioDirectory: dir.appendingPathComponent("a", isDirectory: true),
        indexURL: dir.appendingPathComponent("index.json")
    )

    // 第一轮:正常入库 + 手机端转写/改名/摘要/软删全部发生
    let src = dir.appendingPathComponent("src.m4a")
    try Data(repeating: 0x51, count: 2048).write(to: src)
    XCTAssertTrue(lib.importAudio(from: src, record: Self.record(id: "dup-1")))
    var enriched = lib.record(id: "dup-1")!
    enriched.displayName = "季度会"
    enriched.transcript = "聊了三件事"
    enriched.summary = "摘要在此"
    enriched.autoTitle = "季度会要点"
    enriched.category = "会议"
    enriched.transcriptSegments = [TranscriptSegment(text: "聊了三件事", start: 0, duration: 3)]
    enriched.transcribedAt = Date()
    enriched.deletedAt = Date()
    XCTAssertTrue(lib.upsert(enriched))

    // 第二轮:手表重传的裸 record(富字段全 nil)+ 文件已存在跳过复制
    var raw = Self.record(id: "dup-1")
    raw.byteCount = 2048
    XCTAssertTrue(lib.importAudio(from: src, record: raw))

    let after = try XCTUnwrap(lib.record(id: "dup-1"))
    XCTAssertEqual(after.displayName, "季度会")
    XCTAssertEqual(after.transcript, "聊了三件事")
    XCTAssertEqual(after.summary, "摘要在此")
    XCTAssertEqual(after.autoTitle, "季度会要点")
    XCTAssertEqual(after.category, "会议")
    XCTAssertNotNil(after.transcriptSegments)
    XCTAssertNotNil(after.transcribedAt)
    XCTAssertNotNil(after.deletedAt, "软删状态(用户意图)必须保留")
    XCTAssertEqual(after.state, .acknowledged)
}

/// 主索引损坏(半写)时从 .bak 恢复,不再静默从空表起步把元数据清光。
func testIndexBackupRecovery() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("bak-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let indexURL = dir.appendingPathComponent("index.json")

    let lib = RecordingLibrary(
        audioDirectory: dir.appendingPathComponent("a", isDirectory: true),
        indexURL: indexURL
    )
    lib.upsert(Self.record(id: "keep-1"))
    lib.upsert(Self.record(id: "keep-2"))
    lib.upsert(Self.record(id: "keep-3"))
    // 第三次 upsert 把含前两条的完整版轮转进 .bak——恢复语义:最多丢最后一次写入

    // 模拟半写:主索引写坏,.bak 留存
    try Data("not json at all {{{".utf8).write(to: indexURL)

    let reborn = RecordingLibrary(
        audioDirectory: dir.appendingPathComponent("a", isDirectory: true),
        indexURL: indexURL
    )
    XCTAssertEqual(
        reborn.snapshot().map(\.id).sorted(),
        ["keep-1", "keep-2"],
        "损坏后应从 .bak 恢复(最多丢最后一次写入),而不是从零开始"
    )
}
}

extension DayTapCoreTests {
// MARK: - #61 待办 2.0

/// 旧索引的 actionItems 是纯字符串数组——裸串必须解码为「未完成、无截止」。
func testActionItemLegacyStringDecodes() throws {
    let json = #"["给张总发报告","订周五的会议室"]"#
    let items = try JSONDecoder().decode([ActionItem].self, from: Data(json.utf8))
    XCTAssertEqual(items.count, 2)
    XCTAssertEqual(items[0].text, "给张总发报告")
    XCTAssertEqual(items[0].isDone, false)
    XCTAssertNil(items[0].dueAt)
}

func testActionItemRoundTripKeepsState() throws {
    let item = ActionItem(text: "回拨王工", isDone: true, dueAt: Date(timeIntervalSince1970: 1_800_000_000))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let data = try encoder.encode([item])
    let back = try decoder.decode([ActionItem].self, from: data)
    XCTAssertEqual(back, [item])
}

func testParseDueFormats() {
    XCTAssertNotNil(ActionItem.parseDue("2026-11-14 15:30"))
    XCTAssertNotNil(ActionItem.parseDue(" 2026-11-14 "))
    XCTAssertNotNil(ActionItem.parseDue("2026-11-14"))
    XCTAssertNil(ActionItem.parseDue(""))
    XCTAssertNil(ActionItem.parseDue("周五下午"))   // AI 必须换算成具体日期,裸自然语言不吃
    XCTAssertNil(ActionItem.parseDue("not a date"))
}

/// 含截止时间的新格式与裸串混排也各自归位。
func testActionItemMixedArrayDecodes() throws {
    let json = #"[{"text":"发货","dueAt":null,"isDone":false},"旧样式"]"#
    let items = try JSONDecoder().decode([ActionItem].self, from: Data(json.utf8))
    XCTAssertEqual(items.map(\.text), ["发货", "旧样式"])
}
}

extension DayTapCoreTests {
// MARK: - #63 TransferGate

/// 守门语义钉死:精确匹配/壳丢弃/坏件拒收(#58 家族的回归网)。
func testTransferGateArrivalVerdicts() {
    XCTAssertEqual(TransferGate.verdict(expected: 1024, received: 1024, decodable: true), .accept)
    XCTAssertEqual(
        TransferGate.verdict(expected: 100_000, received: 92_000, decodable: true),
        .rejectMismatch(expected: 100_000, received: 92_000)
    )
    // #58 实证:尺寸齐但结构坏(moov 缺失)照样穿尺寸守门——必须拒。
    XCTAssertEqual(TransferGate.verdict(expected: 119_839, received: 119_839, decodable: false), .rejectUndecodable)
    XCTAssertEqual(TransferGate.verdict(expected: 28, received: 28, decodable: false), .dropShell)
    // 多一个字节也不行:等长是唯一完好口径。
    XCTAssertEqual(
        TransferGate.verdict(expected: 50_000, received: 50_001, decodable: true),
        .rejectMismatch(expected: 50_000, received: 50_001)
    )
}

func testTransferGateIntact() {
    XCTAssertTrue(TransferGate.intact(indexed: true, fileExists: true, expected: 9_000, fileSize: 9_000, decodable: true))
    XCTAssertFalse(TransferGate.intact(indexed: true, fileExists: true, expected: 9_000, fileSize: 8_100, decodable: true))
    XCTAssertFalse(TransferGate.intact(indexed: true, fileExists: true, expected: 9_000, fileSize: 9_000, decodable: false))
    XCTAssertFalse(TransferGate.intact(indexed: false, fileExists: true, expected: 9_000, fileSize: 9_000, decodable: true))
}
}

extension DayTapCoreTests {
// MARK: - #75 ActionItemAnchor

private static func segment(_ text: String, _ start: Double) -> TranscriptSegment {
    TranscriptSegment(text: text, start: start, duration: 3)
}

/// 待办是口语的压缩改写,不是原句——覆盖式打分要能跨过改写命中原声段,
/// 且不被只沾了通用词的别段抢走。
func testActionItemAnchorMatchesCondensedRewrite() {
    let segments = [
        Self.segment("上午先对一下青云项目的进度", 0),
        Self.segment("那我周五之前得给小周回个消息说清楚", 30),
        Self.segment("中午吃饭随便聊聊", 60),
    ]
    XCTAssertEqual(ActionItemAnchor.offset(for: "周五前给小周回消息", segments: segments), 30)
}

/// 匹配不上就老实返回 nil——「匹配不上不显示入口」的依据。
func testActionItemAnchorNoMatchReturnsNil() {
    let segments = [
        Self.segment("今天天气不错", 0),
        Self.segment("中午吃什么", 20),
    ]
    XCTAssertNil(ActionItemAnchor.offset(for: "季度汇报整理成表格", segments: segments))
    // 待办太短(不足二字组)或没有分段:同样无锚点。
    XCTAssertNil(ActionItemAnchor.offset(for: "回", segments: segments))
    XCTAssertNil(ActionItemAnchor.offset(for: "随便什么待办", segments: []))
}

/// 同覆盖取先出现的段:读稿顺序在前面的出处优先。
func testActionItemAnchorPrefersEarlierSegmentOnTie() {
    let segments = [
        Self.segment("这件事周五再说", 0),
        Self.segment("还是周五再说吧", 40),
    ]
    XCTAssertEqual(ActionItemAnchor.offset(for: "周五再说", segments: segments), 0)
}
}
