import CloudKit
import Combine
import Foundation
import Network
import UIKit

// MARK: - 设置存储(与 LLMSettings 同风格:UserDefaults 静态存取)

/// #56 iCloud 备份设置。粒度默认全量(音频+文字);仅文字是留给配额紧张用户的开关。
enum CloudSyncSettings {
    private static let enabledKey = "daytap.cloudsync.enabled"
    private static let audioKey = "daytap.cloudsync.audio"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// 含音频(默认开)。关掉后新录音只备文字,云端已有音频不回收。
    static var includeAudio: Bool {
        get { UserDefaults.standard.object(forKey: audioKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: audioKey) }
    }
}

// MARK: - 纯逻辑(#50 SPM 化时本段整体随迁,可单测)

/// 同步裁决与序列化的全部决策逻辑,不碰 CloudKit、不碰文件——
/// 裁决口径:单写者是常态(一台手机配一只表),updatedAt 最新赢(LWW)。
enum CloudSyncLogic {
    /// 回收站保留期,与 PhoneLink 的清扫口径一致(#26)。
    static let trashRetention: TimeInterval = 30 * 24 * 3600

    /// 云端 vs 本地:云端更新则采纳(true)。
    /// local 为 nil(换机恢复/新装机)时永远采纳云端。
    static func shouldAdopt(cloud: RecordingRecord, local: RecordingRecord?) -> Bool {
        guard let local else { return true }
        return cloud.updatedAt > local.updatedAt
    }

    /// 云端有、本地整条没有(可能被 30 天清扫真删了):墓碑过期→连云端一起删;
    /// 未过期→接回本地回收站,换机恢复时回收站内容也不丢。
    static func orphanAction(cloud: RecordingRecord, now: Date = Date()) -> OrphanAction {
        guard let deletedAt = cloud.deletedAt else { return .adopt }
        return now.timeIntervalSince(deletedAt) > trashRetention ? .deleteCloud : .adopt
    }

    enum OrphanAction {
        case adopt
        case deleteCloud
    }

    /// 本地待推的脏条目:updatedAt 与上次成功推送时不一致。
    static func dirtyIDs(_ records: [RecordingRecord], lastPushed: [String: Date]) -> [String] {
        records.filter { lastPushed[$0.id] != $0.updatedAt }.map(\.id)
    }

    /// 整条录音序列化成 JSON 存 CDMeta——字段演进免费,加字段零迁移。
    static func encode(_ record: RecordingRecord) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ json: String) -> RecordingRecord? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(RecordingRecord.self, from: data)
    }
}

// MARK: - 同步引擎

/// iPhone ↔ iCloud 私有库的备份通道(#56)。手表不参与——它靠传输协议汇到本机,
/// 本机是唯一汇合点;云端恢复也只落本地库,绝不发回手表(防复活名单零接触)。
/// 数据模型两张表,避开「改元数据还要碰音频资产」的引用陷阱:
/// - CDMeta(recordName=id):整条 RecordingRecord 的 JSON + updatedAt(裁决)
/// - CDAudio(recordName=id):CKAsset 写一次(音频导入后永不改)+ bytes(配额统计)
/// 可见性纪律(#39 教训):未登录/配额不足/离线都进状态,不静默。
final class CloudSync: ObservableObject {
    static let shared = CloudSync()

    /// 能力总闸(#56 泊车,2026-11-12 定):签名团队是免费个人账号,开不了 iCloud 能力,
    /// entitlements 已从构建摘除。**付费开发者计划落地后:翻 true + 接回
    /// CODE_SIGN_ENTITLEMENTS(见 issue #56 批审评论)即恢复**,代码零改动。
    /// 关键:CKContainer(identifier:) 在无 entitlements 时抛 ObjC 异常且 Swift 捕不住,
    /// 本闸(配合 container 的 lazy)保证它永远不会被构造。
    static let capabilityAvailable = false

    enum Status: Equatable {
        case idle
        case noAccount
        case syncing
        case synced(Date)
        case disabled
        case unavailable
        case failed(String)

        var text: String {
            switch self {
            case .idle: "待同步"
            case .noAccount: "未登录 iCloud"
            case .syncing: "同步中…"
            case .synced(let date): "已同步 " + date.formatted(date: .omitted, time: .shortened)
            case .disabled: "未开启"
            case .unavailable: "暂不可用（需付费开发者账号）"
            case .failed(let reason): "失败:" + reason
            }
        }
    }

    @Published private(set) var status: Status = .idle
    /// 云端实况(设置页展示):条数与音频占用。
    @Published private(set) var cloudCount = 0
    @Published private(set) var cloudBytes = 0

    private static let containerID = "iCloud.com.guanhongli.daytap"

    /// recordName 命名空间:CloudKit 的 record ID 唯一,元数据与音频同 id 会互覆,
    /// 用 m./a. 前缀分表(同一条录音的两张卡)。
    private static func metaID(_ id: String, zone: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: "m." + id, zoneID: zone)
    }

    private static func audioID(_ id: String, zone: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: "a." + id, zoneID: zone)
    }
    private static let metaType = "CDMeta"
    private static let audioType = "CDAudio"

    /// lazy:只在能力闸放行后才可能被构造(见 capabilityAvailable 注释)。
    private lazy var container: CKContainer = CKContainer(identifier: Self.containerID)
    private var database: CKDatabase { container.privateCloudDatabase }
    private let zoneID = CKRecordZone.default().zoneID

    /// 上次成功推送的 (id → updatedAt),增量推的依据。
    private var lastPushed: [String: Date] {
        didSet { persistCodable(lastPushed, forKey: Self.lastPushedKey) }
    }
    /// 音频已上传账本(CDAudio 写一次的依据),UserDefaults 持久。
    private var uploadedAudio: Set<String> {
        didSet { persistCodable(Array(uploadedAudio).sorted(), forKey: Self.uploadedKey) }
    }
    /// 增量拉取游标。nil=全量。
    private var changeToken: CKServerChangeToken? {
        didSet {
            if let data = changeToken.flatMap({ try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }) {
                UserDefaults.standard.set(data, forKey: Self.tokenKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.tokenKey)
            }
        }
    }

    private static let lastPushedKey = "daytap.cloudsync.lastPushed"
    private static let uploadedKey = "daytap.cloudsync.uploadedAudio"
    private static let tokenKey = "daytap.cloudsync.changeToken"

    private var libraryCancellable: AnyCancellable?
    private var pathMonitor: NWPathMonitor?
    private var onWiFi = false
    private var syncing = false
    private var started = false

    private init() {
        lastPushed = Self.loadCodable([String: Date].self, forKey: Self.lastPushedKey) ?? [:]
        uploadedAudio = Set(Self.loadCodable([String].self, forKey: Self.uploadedKey) ?? [])
        if let data = UserDefaults.standard.data(forKey: Self.tokenKey),
           let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data) {
            changeToken = token
        }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            self?.onWiFi = path.usesInterfaceType(.wifi)
        }
        monitor.start(queue: DispatchQueue(label: "daytap.cloudsync.path"))
    }

    /// App 启动调用:查账号 → 订阅库变更(去抖) → 前台触发。
    func start() {
        guard !started else { return }
        started = true
        guard Self.capabilityAvailable else {
            setStatus(.unavailable)
            return
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sync()
        }
        libraryCancellable = PhoneLink.shared.library.$records
            .dropFirst()
            .debounce(for: .seconds(3), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }
        Task { await refreshAccountThenSync() }
    }

    /// 设置页「立即同步」。
    func syncNow() {
        guard Self.capabilityAvailable else {
            setStatus(.unavailable)
            return
        }
        Task { await refreshAccountThenSync() }
    }

    /// 设置变更:开关切换后立刻对齐(新开→补一波,关闭→停状态)。
    func settingsChanged() {
        guard Self.capabilityAvailable else {
            setStatus(.unavailable)
            return
        }
        if CloudSyncSettings.enabled {
            syncNow()
        } else {
            setStatus(.disabled)
        }
    }

    private func refreshAccountThenSync() async {
        guard CloudSyncSettings.enabled else {
            setStatus(.disabled)
            return
        }
        setStatus(.syncing)
        do {
            let account = try await container.accountStatus()
            guard account == .available else {
                // 未登录/受限都是「用户需要知道」的状态,可见不静默(#39)。
                setStatus(account == .noAccount ? .noAccount : .failed("iCloud 账号不可用(\(account.rawValue))"))
                return
            }
            try await syncOnce()
            setStatus(.synced(Date()))
        } catch {
            setStatus(.failed(cleanError(error)))
        }
    }

    private func sync() {
        Task { await refreshAccountThenSync() }
    }

    private func setStatus(_ new: Status) {
        DispatchQueue.main.async { self.status = new }
    }

    /// 一轮完整同步:先拉(收远端变更+换机恢复)再推(本地脏条目+音频队列)。
    private func syncOnce() async throws {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        try await pull()
        try await push()
    }

    // MARK: 下行

    private func pull() async throws {
        var metas: [CKRecord] = []
        var fetchError: Error?
        // 区变更增量拉(recordName 驱动,不依赖任何字段索引)。
        let fetch = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zoneID],
            configurationsByRecordZoneID: [zoneID: .init(previousServerChangeToken: changeToken)]
        )
        fetch.qualityOfService = .utility
        fetch.recordWasChangedBlock = { _, result in
            if case .success(let record) = result, record.recordType == Self.metaType {
                metas.append(record)
            }
        }
        fetch.recordZoneChangeTokensUpdatedBlock = { _, token, _ in
            self.changeToken = token
        }
        fetch.recordZoneFetchResultBlock = { _, result in
            switch result {
            case .success(let info): self.changeToken = info.serverChangeToken
            case .failure(let error): fetchError = error
            }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            fetch.fetchRecordZoneChangesResultBlock = { _ in cont.resume() }
            database.add(fetch)
        }
        if let fetchError { throw fetchError }

        let library = PhoneLink.shared.library
        let localByID = Dictionary(uniqueKeysWithValues: library.snapshot().map { ($0.id, $0) })
        var adopted = 0
        for meta in metas {
            guard let json = meta["json"] as? String,
                  let cloud = CloudSyncLogic.decode(json) else { continue }
            let local = localByID[cloud.id]
            if local == nil {
                // 本地整条没有:墓碑过期→云端连音频一起清;否则接回(换机恢复)。
                if CloudSyncLogic.orphanAction(cloud: cloud) == .deleteCloud {
                    try? await deleteCloud(id: cloud.id)
                    continue
                }
                library.upsert(cloud)
                await downloadAudioIfMissing(cloud)
                adopted += 1
            } else if CloudSyncLogic.shouldAdopt(cloud: cloud, local: local) {
                library.upsert(cloud)
                await downloadAudioIfMissing(cloud)
                adopted += 1
            }
        }
        if adopted > 0 {
            DayTapLog.library.info("cloudsync adopted \(adopted, privacy: .public)")
        }
        refreshCloudSummary()
    }

    /// 本地缺音频文件而云端可能有:拉 CDAudio 落盘(换机恢复的主体路径)。
    private func downloadAudioIfMissing(_ record: RecordingRecord) async {
        let library = PhoneLink.shared.library
        let url = library.fileURL(id: record.id)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let id = Self.audioID(record.id, zone: zoneID)
        guard let audio = try? await database.record(for: id),
              let asset = audio["asset"] as? CKAsset, let fileURL = asset.fileURL else { return }
        try? FileManager.default.createDirectory(at: library.audioDirectory, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: fileURL, to: url)
    }

    // MARK: 上行

    private func push() async throws {
        let library = PhoneLink.shared.library
        let records = library.snapshot()
        let dirty = CloudSyncLogic.dirtyIDs(records, lastPushed: lastPushed)
        var pushed = 0

        // 元数据按 200 一批推(CKModifyRecords 上限内留余量)。
        for chunk in stride(from: 0, to: dirty.count, by: 200).map({ Array(dirty[$0..<min($0 + 200, dirty.count)]) }) {
            var saving: [CKRecord] = []
            var stamped: [(id: String, updatedAt: Date)] = []
            for id in chunk {
                guard let record = records.first(where: { $0.id == id }),
                      let json = CloudSyncLogic.encode(record) else { continue }
                let meta = CKRecord(recordType: Self.metaType, recordID: Self.metaID(id, zone: zoneID))
                meta["json"] = json
                meta["updatedAt"] = record.updatedAt as CKRecordValue
                saving.append(meta)
                stamped.append((id, record.updatedAt))
            }
            guard !saving.isEmpty else { continue }
            _ = try await database.modifyRecords(saving: saving, deleting: [], savePolicy: .changedKeys, atomically: false)
            for entry in stamped {
                lastPushed[entry.id] = entry.updatedAt
            }
            pushed += saving.count
        }

        // 音频写一次:仅在 含音频 且 WiFi+充电 时出队;不满足就留在队列等下一轮。
        if CloudSyncSettings.includeAudio, audioUploadAllowed() {
            for record in records where !uploadedAudio.contains(record.id) {
                let url = library.fileURL(id: record.id)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let audio = CKRecord(recordType: Self.audioType, recordID: Self.audioID(record.id, zone: zoneID))
                audio["asset"] = CKAsset(fileURL: url)
                audio["bytes"] = record.byteCount as CKRecordValue
                _ = try? await database.modifyRecords(saving: [audio], deleting: [], savePolicy: .changedKeys, atomically: false)
                uploadedAudio.insert(record.id)
            }
        }
        if pushed > 0 {
            DayTapLog.library.info("cloudsync pushed \(pushed, privacy: .public) metas")
        }
    }

    /// 音频上传策略(设计决策):WiFi + 充电才传,电量/蜂窝友好;文字不受此限。
    private func audioUploadAllowed() -> Bool {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        return onWiFi && charging
    }

    private func deleteCloud(id: String) async throws {
        _ = try await database.modifyRecords(
            saving: [],
            deleting: [Self.metaID(id, zone: zoneID), Self.audioID(id, zone: zoneID)],
            savePolicy: .changedKeys,
            atomically: false
        )
        uploadedAudio.remove(id)
    }

    /// 云端实况从本地账本推导(增量拉的返回集不全,不能当统计源):
    /// 元数据每条都推→云端条数=本地条数;音频占用=已上传账本内的条目字节和。
    private func refreshCloudSummary() {
        let records = PhoneLink.shared.library.snapshot()
        let count = records.count
        let bytes = records.filter { uploadedAudio.contains($0.id) }.reduce(0) { $0 + $1.byteCount }
        DispatchQueue.main.async {
            self.cloudCount = count
            self.cloudBytes = bytes
        }
    }

    // MARK: 持久化小工具

    private func persistCodable<T: Codable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func loadCodable<T: Codable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func cleanError(_ error: Error) -> String {
        if let ck = error as? CKError {
            if ck.code == .quotaExceeded { return "iCloud 空间不足" }
            if ck.code == .notAuthenticated { return "未登录 iCloud" }
            if ck.code == .networkUnavailable || ck.code == .networkFailure { return "网络不可用" }
        }
        return error.localizedDescription
    }
}
