import Foundation

/// 「事」的聚合·形态 A(#78):零实体——不建「项目/事」对象、不动主列表,
/// 按需找出「与这条录音谈同一件事」的其他录音。相关=两规则任一命中:
/// ①共享至少一个 people 名,且词元重叠>0.05(同一个人+沾边);
/// ②词元包含度≥0.25(文本高度重叠,#75 bigram 同款口径)。
/// 候选窗=最近 30 天、未删除、有可比内容;结果按时间正序,最多 8 条防 prompt 失控。
enum AffairCluster {
    static let maxRelated = 8

    static func relatedRecords(
        seed: RecordingRecord,
        in records: [RecordingRecord],
        now: Date,
        calendar: Calendar = .current,
        windowDays: Int = 30
    ) -> [RecordingRecord] {
        guard let cutoff = calendar.date(byAdding: .day, value: -windowDays, to: now) else { return [] }
        let seedPool = textPool(seed)
        guard seedPool.count >= 2 else { return [] }
        let seedPeople = Set(seed.people ?? [])
        let hits = records.filter { candidate in
            guard candidate.id != seed.id,
                  candidate.deletedAt == nil,
                  candidate.createdAt > cutoff
            else { return false }
            let pool = textPool(candidate)
            guard pool.count >= 2 else { return false }
            let overlap = containment(seedPool, pool)
            let sharedPerson = !seedPeople.isDisjoint(with: candidate.people ?? [])
            return (sharedPerson && overlap > 0.05) || overlap >= 0.25
        }
        .sorted { $0.createdAt < $1.createdAt }
        return Array(hits.prefix(maxRelated))
    }

    /// 一条录音的可比词元池:标题(手动名/自动题)+摘要+章节要点+待办文字+人物名。
    /// 只用整理后的蒸馏字段——全文转写太长太噪,稀释重叠信号。
    static func textPool(_ record: RecordingRecord) -> Set<String> {
        var parts: [String] = []
        if let name = record.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            parts.append(name)
        }
        if let auto = record.autoTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !auto.isEmpty {
            parts.append(auto)
        }
        parts.append(record.summary ?? "")
        parts.append(contentsOf: (record.chapters ?? []).compactMap(\.keyPoints))
        parts.append(contentsOf: (record.actionItems ?? []).map(\.text))
        parts.append(contentsOf: record.people ?? [])
        var pool = Set<String>()
        for part in parts where !part.isEmpty {
            pool.formUnion(ActionItemAnchor.bigrams(part))
        }
        return pool
    }

    /// 包含度=交集/min(两池):短文谈的都在长文里出现也算高度相关,不受长度偏置。
    static func containment(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        let smaller = min(lhs.count, rhs.count)
        guard smaller > 0 else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(smaller)
    }
}
