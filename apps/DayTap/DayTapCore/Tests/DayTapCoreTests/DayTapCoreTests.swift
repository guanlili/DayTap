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

extension DayTapCoreTests {
// MARK: - #75 Chapter.keyPoints 落库

/// 老索引的 chapters 没有 keyPoints 字段——解码必须得 nil(可选字段零迁移的既定底线)。
func testChapterDecodesLegacyWithoutKeyPoints() {
    let json = """
    {"id":"ch-legacy","createdAt":"2026-11-13T08:00:00Z","durationSeconds":1900,
     "byteCount":9000000,"state":"pending","updatedAt":"2026-11-13T08:31:00Z",
     "chapters":[{"title":"青云项目","start":0},{"title":"待办收尾","start":960}]}
    """
    let record = CloudSyncLogic.decode(json)
    XCTAssertEqual(record?.chapters?.count, 2)
    XCTAssertNil(record?.chapters?.first?.keyPoints)
}

/// 带要点的章节编解码往返——回链锚点链路要保真。
func testChapterKeyPointsRoundTrip() {
    var record = Self.record(id: "ch-rt")
    record.chapters = [
        Chapter(title: "青云项目", start: 120, keyPoints: "对齐了二期排期,风险在小周那边"),
        Chapter(title: "散会", start: 900, keyPoints: nil),
    ]
    let decoded = CloudSyncLogic.decode(CloudSyncLogic.encode(record)!)
    XCTAssertEqual(decoded?.chapters?.first?.keyPoints, "对齐了二期排期,风险在小周那边")
    XCTAssertNil(decoded?.chapters?.last?.keyPoints)
}
}

extension DayTapCoreTests {
// MARK: - #80 DayAgenda

private static func todoRecord(
    id: String,
    created: Date,
    items: [ActionItem],
    deleted: Bool = false
) -> RecordingRecord {
    var record = Self.record(id: id)
    record.createdAt = created
    record.actionItems = items
    if deleted { record.deletedAt = created }
    return record
}

/// 今日待办聚合口径:今天到期+全部逾期的未完成;已完成/无截止/明天以后/回收站都不进;
/// 排序逾期在前、同桶按截止时刻。
func testDayAgendaTodayTodosBucketsAndOrder() {
    let calendar = Calendar.current
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 12))!
    let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
    let earlier = calendar.date(byAdding: .hour, value: -12, to: now)!
    let records = [
        Self.todoRecord(
            id: "r1", created: yesterday,
            items: [
                ActionItem(text: "今天上午回消息", dueAt: calendar.date(byAdding: .hour, value: -2, to: now)),
                ActionItem(text: "昨晚就该发的周报", dueAt: yesterday),
                ActionItem(text: "已办掉的逾期项", isDone: true, dueAt: yesterday),
                ActionItem(text: "没截止的念想", dueAt: nil),
                ActionItem(text: "明天的会", dueAt: tomorrow),
            ]
        ),
        Self.todoRecord(
            id: "r2", created: earlier,
            items: [ActionItem(text: "拖了三天的预算", dueAt: calendar.date(byAdding: .day, value: -3, to: now))]
        ),
        Self.todoRecord(id: "r3", created: earlier, items: [ActionItem(text: "回收站里的", dueAt: now)], deleted: true),
    ]
    let todos = DayAgenda.todayTodos(records, now: now)
    // 逾期在前且最久的排最前,今天的殿后;完成/无截止/明天/删除全排除。
    XCTAssertEqual(todos.map { $0.item.text }, ["拖了三天的预算", "昨晚就该发的周报", "今天上午回消息"])
    let expectedBuckets: [DayAgenda.TodoEntry.Bucket] = [.overdue, .overdue, .today]
    XCTAssertEqual(todos.map { $0.bucket }, expectedBuckets)
    // 复合键防跨录音同文撞 id。
    XCTAssertEqual(Set(todos.map { $0.id }).count, todos.count)
}

/// 跨录音同文待办不互吞:两条「回消息」各自成行。
func testDayAgendaDuplicateTextAcrossRecordsKept() {
    let calendar = Calendar.current
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 9))!
    let records = [
        Self.todoRecord(id: "a", created: now, items: [ActionItem(text: "回消息", dueAt: now)]),
        Self.todoRecord(id: "b", created: now, items: [ActionItem(text: "回消息", dueAt: now)]),
    ]
    XCTAssertEqual(DayAgenda.todayTodos(records, now: now).count, 2)
}

/// 今天录的:未删除、今天创建、按时间正序;昨天的与回收站的不进。
func testDayAgendaTodaysRecordings() {
    let calendar = Calendar.current
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 15))!
    let morning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 8))!
    let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
    let records = [
        Self.todoRecord(id: "r2", created: now, items: []),
        Self.todoRecord(id: "r1", created: morning, items: []),
        Self.todoRecord(id: "old", created: yesterday, items: []),
        Self.todoRecord(id: "gone", created: morning, items: [], deleted: true),
    ]
    XCTAssertEqual(DayAgenda.todaysRecordings(records, now: now).map { $0.id }, ["r1", "r2"])
}

/// 建议规整:空标题先丢再配对(防左移)、截 4 条、时长钳制、未知类型归 other。
func testDayAgendaNormalizedSuggestions() {
    let out = DayAgenda.normalizedSuggestions(
        titles: ["慢跑", "", "深度工作", "午休", "复盘", "第五条"],
        reasons: ["提高心肺", "理由2", "理由3", "理由4", "理由5", "理由6"],
        starts: ["07:30", "09:00", "13:00", "18:00", "21:00", "23:00"],
        minutes: [30, 60, 600, -5, 45, 60],
        kinds: ["运动", "专注", "休息", "复盘", "不认识的", "运动"]
    )
    // 空标题丢弃,其余按原索引配对(不左移);最多 4 条。
    XCTAssertEqual(out.map { $0.title }, ["慢跑", "深度工作", "午休", "复盘"])
    // #62 教训:丢空后配对不左移——「深度工作」的理由是 reasons[2] 而非「理由2」。
    XCTAssertEqual(out[1].reason, "理由3")
    // 时长钳到 15…240。
    XCTAssertEqual(out.map { $0.minutes }, [30, 240, 15, 45])
    let expectedKinds: [DayAgenda.Suggestion.Kind] = [.workout, .rest, .review, .other]
    XCTAssertEqual(out.map { $0.kind }, expectedKinds)
}
}

extension DayTapCoreTests {
// MARK: - #85 people

/// 今天提到的人:跨录音聚合、单条内重名不虚增、空名丢弃、只看今天未删除、按条数降序同数按名序。
func testDayAgendaPeopleMentions() {
    let calendar = Calendar.current
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 16))!
    let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
    var a = Self.record(id: "a")
    a.createdAt = now
    a.people = ["小周", "王总", "小周", "  "]  // 单条内重复+纯空白
    var b = Self.record(id: "b")
    b.createdAt = now
    b.people = ["小周"]
    var old = Self.record(id: "old")
    old.createdAt = yesterday
    old.people = ["王总"]
    var gone = Self.record(id: "gone")
    gone.createdAt = now
    gone.deletedAt = now
    gone.people = ["小周"]
    let mentions = DayAgenda.peopleMentions([a, b, old, gone], now: now)
    XCTAssertEqual(mentions.map { $0.name }, ["小周", "王总"])
    XCTAssertEqual(mentions[0].count, 2)
    XCTAssertEqual(mentions[0].sources.map { $0.id }, ["a", "b"])
    XCTAssertEqual(mentions[1].count, 1)
}

/// 老索引没有 people 字段——解码得 nil(可选字段零迁移底线)。
func testRecordDecodesLegacyWithoutPeople() {
    let json = """
    {"id":"p-legacy","createdAt":"2026-11-13T08:00:00Z","durationSeconds":60,
     "byteCount":500000,"state":"pending","updatedAt":"2026-11-13T08:01:00Z",
     "transcript":"聊到小周","summary":"聊了排期"}
    """
    XCTAssertNil(CloudSyncLogic.decode(json)?.people)
}

}

extension DayTapCoreTests {
// MARK: - #78 AffairCluster

private static func affairRecord(
    id: String,
    daysAgo: Int,
    title: String,
    summary: String = "",
    people: [String] = [],
    todos: [String] = [],
    deleted: Bool = false
) -> RecordingRecord {
    var record = Self.record(id: id)
    record.createdAt = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
    record.displayName = title
    record.summary = summary.isEmpty ? nil : summary
    record.people = people.isEmpty ? nil : people
    record.actionItems = todos.map { ActionItem(text: $0) }
    if deleted { record.deletedAt = record.createdAt }
    return record
}

/// 相关判定:同人物+沾边、纯文本高重叠各自命中;不相关的、出窗的、回收站的、没内容的不进。
func testAffairClusterRelatedRules() {
    let now = Date()
    let seed = Self.affairRecord(
        id: "seed", daysAgo: 0,
        title: "青云项目周会",
        summary: "聊了青云项目二期排期和小周负责的接口",
        people: ["小周"], todos: ["周五前回小周消息"]
    )
    let samePerson = Self.affairRecord(
        id: "same-person", daysAgo: 2,
        title: "和小周对接口", summary: "小周说接口这周能好",
        people: ["小周"]
    )
    let textOverlap = Self.affairRecord(
        id: "text-overlap", daysAgo: 5,
        title: "青云项目二期排期又聊了一次",
        summary: "青云项目二期排期没定,小周接口还在等",
        people: []
    )
    let unrelated = Self.affairRecord(
        id: "unrelated", daysAgo: 1,
        title: "周末爬山计划", summary: "走哪条路线带什么吃的", people: ["老李"]
    )
    let outOfWindow = Self.affairRecord(
        id: "old", daysAgo: 40,
        title: "青云项目立项", summary: "青云项目二期排期和小周接口", people: ["小周"]
    )
    let deleted = Self.affairRecord(
        id: "gone", daysAgo: 1,
        title: "青云项目杂谈", summary: "青云项目二期排期", deleted: true
    )
    let related = AffairCluster.relatedRecords(
        seed: seed,
        in: [seed, samePerson, textOverlap, unrelated, outOfWindow, deleted],
        now: now
    )
    XCTAssertEqual(Set(related.map { $0.id }), ["same-person", "text-overlap"])
}

/// 结果按时间正序(早的先——进展叙事要时间线),上限 8 条。
func testAffairClusterOrderAndCap() {
    let now = Date()
    let seed = Self.affairRecord(id: "seed", daysAgo: 0, title: "青云项目", summary: "青云二期", people: ["小周"])
    let many = (1...10).map { index in
        Self.affairRecord(id: "r\(index)", daysAgo: index, title: "青云项目第\(index)次", summary: "青云二期推进", people: ["小周"])
    }
    let related = AffairCluster.relatedRecords(seed: seed, in: [seed] + many, now: now)
    XCTAssertEqual(related.count, AffairCluster.maxRelated)
    XCTAssertEqual(related.map { $0.id }, ["r10", "r9", "r8", "r7", "r6", "r5", "r4", "r3"])
}

}

extension DayTapCoreTests {
// MARK: - #58 空间护栏 / #80 勾选收敛

func testDiskGuardThreshold() {
    XCTAssertFalse(DiskGuard.tooLow(freeBytes: DiskGuard.minimumFreeBytes))
    XCTAssertTrue(DiskGuard.tooLow(freeBytes: DiskGuard.minimumFreeBytes - 1))
    // 探针读不出容量:不拦——护栏失灵不能挡正常录音。
    XCTAssertFalse(DiskGuard.tooLow(freeBytes: nil))
}

/// 勾选落库收敛版(#61→#80):落盘可见、触脏,找不到的静默不动。
func testToggleActionItemPersists() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let library = RecordingLibrary(
        audioDirectory: dir.appendingPathComponent("audio"),
        indexURL: dir.appendingPathComponent("index.json")
    )
    var record = Self.record(id: "toggle-1")
    record.actionItems = [ActionItem(text: "回消息")]
    library.upsert(record)
    library.toggleActionItem(recordID: "toggle-1", updated: ActionItem(text: "回消息", isDone: true))
    let after = library.record(id: "toggle-1")
    XCTAssertEqual(after?.actionItems?.first?.isDone, true)
    XCTAssertNotNil(after?.updatedAt)
    // 不存在的录音:静默不崩。
    library.toggleActionItem(recordID: "nope", updated: ActionItem(text: "x"))
}
}
