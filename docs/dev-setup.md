# 开发环境速览(远程执行者先读)

## 工程

- 主工程:`apps/DayTap/DayTap.xcodeproj`,Xcode 27 打开
- Target:**DayTap**(iPhone)/ **DayTap Watch App**(手表)/ **DayTapWidget**(表盘磁贴);共享纯逻辑在 `apps/DayTap/DayTapCore`(SPM 包,App 双 target 以同步组直编同源),跨端源码在 `Shared/`
- 签名:免费个人团队(BR3SB4Q4BV)自动签名,开发版,不上架;真机需该账号设备在列

## 构建冒烟

首选脚本(前置 DayTapCore swift test 门,再双 target 免签构建 + pbxproj lint):

```bash
./scripts/build-smoke.sh
```

单测(纯逻辑秒级,不开模拟器):`cd apps/DayTap/DayTapCore && swift test`

pbxproj 已是 **Xcode 16 文件系统同步组形态**(#49):**往 target 目录加源文件不碰 pbxproj**,丢进去直接编。例外集只有三枚 Info.plist、entitlements 与跨 target 的 `Shared/AudioCapture.swift`;真要动 pbxproj,改完必跑 `plutil -lint`。

内嵌 appex(小组件扩展)的 CopyFiles phase:`dstSubfolderSpec = 13` 且 **`dstPath` 必须留空**——写成 `$(PLUGINS_FOLDER_PATH)` 会解析成相对构建目录的完整路径,叠出 `PlugIns/DayTap Watch App.app/PlugIns/appex` 双层嵌套(实测踩过)。

## 纪律与文档

- **记账纪律见仓库根 CLAUDE.md / AGENTS.md(devledger)**:完成可交付单元的会话,结束前建 issue → 关闭 → 入 Project #18 → 设字段;commit 末尾带 `(#issue号)` 自动关联
- 需求看板:GitHub Project #18(仓库同名);issue 正文即规格,自带验收要点
- 手表无感录音设计/验证清单:`docs/stealth-mode.md`;代码入口 `WatchModel` 三态状态机 + `StealthTuning` 参数表
