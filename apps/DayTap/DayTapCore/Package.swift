// swift-tools-version: 6.2
import PackageDescription

/// #50 核心逻辑本地包(PaseoKit 模式):Shared 纯逻辑 + LLM 配置中心 + CloudSync 裁决,
/// `swift test` 不开模拟器直跑。App/Watch 两 target 依赖;语言模式跟工程走 v5,
/// 包内代码以后升 v6 需先过并发检查。
let package = Package(
    name: "DayTapCore",
    platforms: [
        .iOS(.v26),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "DayTapCore", targets: ["DayTapCore"]),
    ],
    targets: [
        .target(name: "DayTapCore"),
        .testTarget(name: "DayTapCoreTests", dependencies: ["DayTapCore"]),
    ],
    swiftLanguageModes: [.v5]
)
