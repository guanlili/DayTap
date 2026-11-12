import os

/// 统一日志。真机用 Mac 上的「控制台」按 subsystem `com.guanhongli.daytap` 过滤。
/// 这里只记状态和错误，不记录音内容。
enum DayTapLog {
    static let recorder = Logger(subsystem: "com.guanhongli.daytap", category: "recorder")
    static let link = Logger(subsystem: "com.guanhongli.daytap", category: "link")
    static let library = Logger(subsystem: "com.guanhongli.daytap", category: "library")
    static let transcribe = Logger(subsystem: "com.guanhongli.daytap", category: "transcribe")
    static let motion = Logger(subsystem: "com.guanhongli.daytap", category: "motion")
}
