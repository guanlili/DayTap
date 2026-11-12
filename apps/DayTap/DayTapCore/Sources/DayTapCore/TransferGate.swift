import Foundation

/// 收件守门的裁决口径(#48→#59→#63 纯函数化):把「精确匹配/壳丢弃/坏件拒收」语义
/// 钉进包里防回归——#58 实证尺寸相等也可能结构坏,可解码性由调用方实测传入。
enum TransferGate {
    enum ArrivalVerdict: Equatable {
        /// 收下。
        case accept
        /// 尺寸不符:不保存不回执,手表自动重试。
        case rejectMismatch(expected: Int, received: Int)
        /// <1KB 空壳:回执但不落库,别给重试留死循环。
        case dropShell
        /// 尺寸齐但打不开(#58 家族):拒收不回执。
        case rejectUndecodable
    }

    static func verdict(expected: Int, received: Int, decodable: Bool) -> ArrivalVerdict {
        if expected < 1024 { return .dropShell }
        if received != expected { return .rejectMismatch(expected: expected, received: received) }
        if !decodable { return .rejectUndecodable }
        return .accept
    }

    /// 对账「已有」裁决同口径:索引在+文件在+尺寸齐+打得开才算完好,差一样都要重传。
    static func intact(indexed: Bool, fileExists: Bool, expected: Double, fileSize: Double, decodable: Bool) -> Bool {
        indexed && fileExists && fileSize == expected && decodable
    }
}
