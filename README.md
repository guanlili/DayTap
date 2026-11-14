# DayTab

> 腕上日录:按一下录音,回到手机时,它已经是文字、摘要和待办。
>
> 产品名 **DayTab**(#81 定案);仓库名与工程名沿用 DayTap,签名/安装/数据不受影响。

录音像语音备忘录一样简单;录完之后,替你把收尾做完——转全文、出摘要、待办进提醒事项和日历。AI 整理是可选的:不配也能用,配上各家大模型任选。

**[功能介绍 →](docs/product-intro.md)** 用户视角完整版:一条动线、隐私边界、它不是什么。

**[组员先读 →](docs/onboarding-teammates.md)** · [装机步骤](docs/dev-setup.md) · [只装手表](docs/teammate-watch-sideload.md)

English blurb: **DayTab** — wrist-first capture → transcription, summaries & action items on iPhone. No TestFlight; sideload with Xcode.

---

## 装机

没有 TestFlight,也没有可点的安装包,只能 **Mac + Xcode 侧载**(无 `.xcworkspace`):

```bash
git clone --depth 1 https://github.com/guanlili/DayTap.git
open DayTap/apps/DayTap/DayTap.xcodeproj
```

两个 target 选自己的 Apple ID 签名,选设备,运行。详细步骤与环境要求见 [装机文档](docs/dev-setup.md)。

## 开发

- 环境:Xcode 27(本机 27.2 验证)/ 部署目标 iOS 26.0、watchOS 10.0;个人免费 Apple ID 即可(EventKit 可用,CloudKit 需付费团队)
- 单测:`cd apps/DayTap/DayTapCore && swift test`(纯逻辑 22 例,秒级)
- 冒烟:`scripts/build-smoke.sh`(前置 swift test 门)
- 工程为 Xcode 16 文件系统同步组:加文件不碰 pbxproj
- 协作:先开 issue 对齐再动手,commit 末尾带 `(#N)`;UI 批次交付前过 apple-design + swiftui-pro 双审查;真实隐私数据不进仓库

## 仓库结构

```
apps/DayTap/
├── DayTap.xcodeproj    # 双击打开;无 .xcworkspace
├── DayTap/             # iPhone App
├── DayTapWatch/        # Watch App
├── DayTapWidget/       # 表盘小组件
├── DayTapCore/         # 共享纯逻辑 SPM 包(swift test 直跑)
├── Shared/             # 跨端共享源码
└── Config/             # Info.plist ×3 + entitlements
docs/                   # 全部文档(功能介绍/装机/工程/口径)
scripts/                # build-smoke / env-check
pipeline/               # 早期语料→Agent 流水线 stub
corpus/examples/        # 示例转写
blog/                   # 开发记录
```

## 现状(2026-11-14)

真机闭环长期在用:Watch 录 → 传输守门对账 → iPhone 自动转写 → 摘要与待办进提醒事项、日历(iPhone 17 + Watch S11)。App 为底栏五 tab:**计划 / 今天 / 记录 / 成长 / 我的**(#82 定稿)。

还欠的:

- iCloud 备份——引擎就绪,等付费开发者账号启用(#56)
- TestFlight 上线链路——当前安装只能侧载
- 长录音摘要分段(#68)、待办承诺方向(#70)——待需求评审
- App Store 未提交审核,不要说已经能上架

下一步候选:降噪、自定义类别与多标签、日历视图、Action Button 一键录音、每功能各配模型等。

## 红线(诚实版)

- 不做全天候无感录音:手表录音是前台行为;手机录退后台续录仅限进行中的那条
- **音频永不外发**:出设备的只有转写文字与可选「关于我」段;iCloud 备份可关或只备文字
- 国行 iPhone 暂无 Apple 智能(官方口径:随 iOS 27.3 推送),深度整理依赖可选云端 LLM,key 存 Keychain
- 手表不连接得到;App 不集成、也不依赖得到
- 本仓库不含任何 API Key;勿提交 `.env`
- 模拟器传文件不可靠,验收以真机为准

## 文档

[功能介绍](docs/product-intro.md) · [装机](docs/dev-setup.md) · [手表工程](docs/daytap-watch-app.md) · [架构(早期版)](docs/architecture.md) · [MVP 路线档案](docs/tech-path.md)

## License

[MIT](LICENSE) © 2026 Chris Cui (崔莹) and contributors
