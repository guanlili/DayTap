# 开发环境速览(远程执行者先读)

## 工程

- 主工程:`apps/DayTap/DayTap.xcodeproj`,Xcode 27 打开
- Target:**DayTap**(iPhone)/ **DayTap Watch App**(手表),共享代码在 `Shared/` 组(RecordingRecord、RecordingLibrary、Formatters、DayTapLog)
- 签名:免费个人团队(BR3SB4Q4BV)自动签名,开发版,不上架;真机需该账号设备在列

## 构建冒烟(免签名,模拟器)

```bash
xcodebuild -project apps/DayTap/DayTap.xcodeproj -scheme "DayTap Watch App" \
  -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project apps/DayTap/DayTap.xcodeproj -scheme "DayTap" \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
plutil -lint apps/DayTap/DayTap.xcodeproj/project.pbxproj
```

pbxproj 是 objectVersion 56 显式文件引用(非同步文件夹),**新增源文件要四处登记**(PBXBuildFile / PBXFileReference / 组 children / Sources phase),ID 照既有规律递增。这个文件坏过一次,改完必跑 `plutil -lint`。

## 纪律与文档

- **记账纪律见仓库根 CLAUDE.md / AGENTS.md(devledger)**:完成可交付单元的会话,结束前建 issue → 关闭 → 入 Project #18 → 设字段;commit 末尾带 `(#issue号)` 自动关联
- 需求看板:GitHub Project #18(仓库同名);issue 正文即规格,自带验收要点
- 手表无感录音设计/验证清单:`docs/stealth-mode.md`;代码入口 `WatchModel` 三态状态机 + `StealthTuning` 参数表
