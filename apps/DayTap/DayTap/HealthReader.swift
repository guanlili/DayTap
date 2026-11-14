import HealthKit
import SwiftUI

/// 健康数据读取(#80-P1/#84):只读、只取聚合量——睡眠时长+入睡时刻、今日步数、活动能量。
/// Watch 采集的数据自动汇入 iPhone 健康库,手机侧读即可,手表 App 零改动。
/// 隐私口径(#80 拍板):聚合数字留在本机展示;原始样本不出设备、不进任何 AI 输入。
enum HealthReader {
    /// 「今天」要展示的聚合量;读不到的字段为 nil(未授权/无记录都长这样——
    /// HealthKit 的读授权状态按设计不可查询,空值即诚实呈现)。
    struct Summary: Equatable {
        /// 昨晚(昨日午后至今)的睡眠小时数。
        var sleepHours: Double?
        /// 入睡时刻。
        var sleepStart: Date?
        /// 今日步数。
        var steps: Int?
        /// 今日活动能量(千卡)。
        var activeKcal: Double?
    }

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private static let readTypes: Set<HKObjectType> = {
        let types: [HKObjectType?] = [
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
            HKObjectType.quantityType(forIdentifier: .stepCount),
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned),
        ]
        return Set(types.compactMap { $0 })
    }()

    /// 弹一次系统授权(首次),然后拉今天的聚合量。任何一步失败都只返回 nil 字段,不抛错——
    /// 「今天」的验收标准是无授权整块降级,不是报错。
    static func requestAndSummarize() async -> Summary? {
        guard isAvailable else { return nil }
        let store = HKHealthStore()
        let granted = await withCheckedContinuation { continuation in
            store.requestAuthorization(toShare: [], read: readTypes) { _, _ in
                continuation.resume()
            }
        }
        _ = granted  // 读授权的系统选择对 App 不可见,授权与否都继续查,空值如实展示。
        async let sleep = sleepSummary(store)
        async let steps = quantitySum(store, .stepCount, unit: .count())
        async let kcal = quantitySum(store, .activeEnergyBurned, unit: .kilocalorie())
        return await Summary(
            sleepHours: sleep?.hours,
            sleepStart: sleep?.start,
            steps: steps.map { Int($0) },
            activeKcal: kcal
        )
    }

    /// 昨晚睡眠:昨日 15:00 起的睡眠分析样本,只统计入睡类阶段。
    private static func sleepSummary(_ store: HKHealthStore) async -> (hours: Double, start: Date)? {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        guard let windowStart = calendar.date(byAdding: .hour, value: -9, to: todayStart) else { return nil }
        let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        guard let sleepType = type else { return nil }
        return await withCheckedContinuation { continuation in
            // 睡眠阶段白名单(iOS 16+ 分段睡眠):入睡类全算,醒着(awake)/在床(inBed)不算。
            let asleepValues: Set<Int> = [
                HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            ]
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: HKQuery.predicateForSamples(withStart: windowStart, end: Date()),
                limit: 200,
                sortDescriptors: []
            ) { _, samples, _ in
                var total: TimeInterval = 0
                var start: Date?
                for sample in samples ?? [] {
                    guard let category = sample as? HKCategorySample,
                          asleepValues.contains(category.value)
                    else { continue }
                    total += category.endDate.timeIntervalSince(category.startDate)
                    if start == nil || category.startDate < start! { start = category.startDate }
                }
                continuation.resume(returning: total > 0 ? (total / 3600, start!) : nil)
            }
            store.execute(query)
        }
    }

    /// 今日的量值总和(步数/活动能量)。
    private static func quantitySum(
        _ store: HKHealthStore,
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit
    ) async -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
        let todayStart = Calendar.current.startOfDay(for: Date())
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: todayStart, end: Date()),
                options: .cumulativeSum
            ) { _, statistics, _ in
                continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }
}

extension HealthReader.Summary {
    /// 「今天」健康块的一行式呈现;空字段跳过,全空返回 nil(块整体降级)。
    var headline: String? {
        var parts: [String] = []
        if let sleepHours {
            let sleepLine = "昨晚睡了 \(String(format: "%.1f", sleepHours)) 小时"
            if let sleepStart {
                parts.append(sleepLine + "(\(sleepStart.formatted(date: .omitted, time: .shortened)) 入睡)")
            } else {
                parts.append(sleepLine)
            }
        }
        if let steps {
            parts.append("今日 \(Int(steps)) 步")
        }
        if let activeKcal {
            parts.append("活动 \(Int(activeKcal)) 千卡")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
