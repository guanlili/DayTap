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
