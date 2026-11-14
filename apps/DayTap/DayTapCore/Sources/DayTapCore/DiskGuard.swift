import Foundation

/// #58 空间护栏:手表开录前的最低可用空间。写坏事件的假说之一是存储临界
/// (moov 尾写不进、~119.8KB 天花板),宁可拒录说人话,不产坏件。
/// 200MB ≈ 两小时录音的体量,再给系统留余量;探针读不出容量时不拦——
/// 别因护栏失灵把正常录音也挡了。
enum DiskGuard {
    static let minimumFreeBytes: Int64 = 200 * 1024 * 1024

    static func tooLow(freeBytes: Int64?) -> Bool {
        guard let freeBytes else { return false }
        return freeBytes < minimumFreeBytes
    }
}
