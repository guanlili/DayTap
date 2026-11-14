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
            HKObjectType.quantityType(forIdentifier: .restingHeartRate),
            HKObjectType.workoutType(),
        ]
        return Set(types.compactMap { $0 })
    }()

    /// 弹一次系统授权(首次),然后拉今天的聚合量。任何一步失败都只返回 nil 字段,不抛错——
    /// 「今天」的验收标准是无授权整块降级,不是报错。
    static func requestAndSummarize() async -> Summary? {
        guard isAvailable else { return nil }
        await requestAuthorization()
        return await summarize()
    }

    /// 弹一次系统授权(首次)——「今天」「成长」的连接按钮共用;读授权结果不可见,后续静默查询见真章。
    static func requestAuthorization() async {
        let store = HKHealthStore()
        await withCheckedContinuation { continuation in
            store.requestAuthorization(toShare: [], read: readTypes) { _, _ in
                continuation.resume()
            }
        }
    }

    /// 静默读取(#80-P1):不弹授权——已授权就有数,没授权返回 nil 字段。
    /// 排程等后台消费方用它,别替用户决定弹窗时机。
    static func summarize() async -> Summary? {
        guard isAvailable else { return nil }
        let store = HKHealthStore()
        let windowStart = Calendar.current.date(byAdding: .hour, value: -9, to: Calendar.current.startOfDay(for: Date()))
            ?? Calendar.current.startOfDay(for: Date())
        async let sleep = asleepTotal(store, from: windowStart)
        async let steps = quantitySum(store, .stepCount, unit: .count(), from: Calendar.current.startOfDay(for: Date()))
        async let kcal = quantitySum(store, .activeEnergyBurned, unit: .kilocalorie(), from: Calendar.current.startOfDay(for: Date()))
        return await Summary(
            sleepHours: sleep?.hours,
            sleepStart: sleep?.start,
            steps: steps.map { Int($0) },
            activeKcal: kcal
        )
    }

    // MARK: - 周度聚合(#84 成长 tab)

    struct WeekSummary: Equatable {
        var sleepHoursTotal: Double?
        var stepsTotal: Double?
        var kcalTotal: Double?
        var workoutCount: Int?
        var workoutMinutes: Int?
        /// 静息心率·窗口日均(#87);没数据 nil。
        var restingHeartRate: Int?

        var hasAny: Bool {
            sleepHoursTotal != nil || stepsTotal != nil || kcalTotal != nil
                || workoutCount != nil || restingHeartRate != nil
        }
    }

    /// 最近 N 天(含今天)的量:静默查询,没授权就全 nil。锻炼=次数+总分钟。
    static func weekSummary(days: Int = 7) async -> WeekSummary {
        guard isAvailable else { return WeekSummary() }
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let windowStart = calendar.date(byAdding: .day, value: -(days - 1), to: todayStart) ?? todayStart
        let store = HKHealthStore()
        async let sleep = asleepTotal(store, from: windowStart)
        async let steps = quantitySum(store, .stepCount, unit: .count(), from: windowStart)
        async let kcal = quantitySum(store, .activeEnergyBurned, unit: .kilocalorie(), from: windowStart)
        async let workouts = workoutTotals(store, from: windowStart)
        async let resting = restingHeartRateAverage(store, from: windowStart)
        return await WeekSummary(
            sleepHoursTotal: sleep?.hours,
            stepsTotal: steps,
            kcalTotal: kcal,
            workoutCount: workouts?.count,
            workoutMinutes: workouts?.minutes,
            restingHeartRate: resting.map { Int($0.rounded()) }
        )
    }

    /// 静息心率·日均(#87):离散平均,窗口内没样本返回 nil。
    private static func restingHeartRateAverage(_ store: HKHealthStore, from windowStart: Date) async -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: .restingHeartRate) else { return nil }
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: windowStart, end: Date()),
                options: .discreteAverage
            ) { _, statistics, _ in
                continuation.resume(
                    returning: statistics?.averageQuantity()?.doubleValue(for: .count().unitDivided(by: .minute()))
                )
            }
            store.execute(query)
        }
    }

    /// 窗口内锻炼:次数与总分钟。
    private static func workoutTotals(_ store: HKHealthStore, from windowStart: Date) async -> (count: Int, minutes: Int)? {
        await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: HKQuery.predicateForSamples(withStart: windowStart, end: Date()),
                limit: 200,
                sortDescriptors: []
            ) { _, samples, _ in
                let workouts = (samples ?? []) as? [HKWorkout] ?? []
                guard !workouts.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                let minutes = Int(workouts.reduce(0) { $0 + $1.duration } / 60)
                continuation.resume(returning: (workouts.count, minutes))
            }
            store.execute(query)
        }
    }

    /// 睡眠合计:窗口内入睡类阶段的总时长+最早入睡时刻(周度只看时长)。
    private static func asleepTotal(_ store: HKHealthStore, from windowStart: Date) async -> (hours: Double, start: Date)? {
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

    /// 量值总和(步数/活动能量),起点由调用方定(#84 起日/周共用)。
    private static func quantitySum(
        _ store: HKHealthStore,
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from windowStart: Date
    ) async -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: windowStart, end: Date()),
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
