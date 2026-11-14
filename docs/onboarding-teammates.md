# DayTap 组员接入文档（Onboarding）

> 给黑客松 / 协作组员｜2026-11-14 更新｜**先读本文件，再动手装机。**  
> 电脑空间紧：**不必先整仓 clone**——在网页打开本页即可对齐口径；真机侧载时再浅克隆。

---

## 0. 30 秒：我们在做什么

**DayTap**＝腕上/指尖按一下录音,iPhone 接住后**自动转全文、出摘要和待办**——回到手机时,它已经不是一堆音频。  
不是系统 Voice Memos,也不是「在得到里录」。

**当前形态**  
- iPhone 端是完整 App:底栏五 tab——**计划**(今日待办/AI 安排)/ **今天**(每日回顾落位)/ **记录**(录音列表全套)/ **成长**(本周回顾)/ **我的**(设置)  
- Watch App:三种启停(按钮/敲桌/握拳),录完自动传回手机,确认即删表上原件  
- 装机仍必须 **Mac + Xcode 侧载**(没有 TestFlight / App Store 包)

**30 秒路演口径**  
「腕上最短路径的想法捕获:手表录 → 手机接住 → 自动变文字、摘要和可勾选的待办,待办一键进提醒事项/日历。本场看侧载可用版。」

> 口头可能听到「DayTab」——产品更名与品牌更新评审中,仓库/工程/文档目前仍叫 DayTap。

---

## 1. 仓库与分支

| 项 | 值 |
|----|-----|
| 主仓(PUBLIC,克隆这个) | https://github.com/guanlili/DayTap |
| Clone URL | `https://github.com/guanlili/DayTap.git` |
| 分支 | `main`(全部开发在这,无需换分支) |
| 工程路径 | `apps/DayTap/DayTap.xcodeproj` |
| 功能介绍 | [`docs/product-intro.md`](product-intro.md) |
| 开发环境速览 | [`docs/dev-setup.md`](dev-setup.md) |
| 只装手表短步骤 | [`docs/teammate-watch-sideload.md`](teammate-watch-sideload.md) |

历史仓(flicy/DayTap)与 `cursor/daytap-watch-app-60a0` 分支是 MVP 时期存档,**别从那里装**——代码落后当前 main 两周。

**空间不够时(浅克隆)**  

```bash
git clone --depth 1 https://github.com/guanlili/DayTap.git
```

不要装无关依赖;Xcode 只开 `apps/DayTap/DayTap.xcodeproj`(没有单独的 `.xcworkspace`)。

---

## 2. 能力与边界（别夸大）

### 现在能讲
1. **腕上/指尖录音**:手表三种启停 + 表盘磁贴;手机也能直接录(退后台不停)
2. **收到即转全文**(本机转写,带时间戳分段;国行可配云端大模型兜底,七家厂商任选)
3. **摘要卡**:标题/类别/摘要/待办自动生成;待办可勾选、一键进提醒事项/日历;待办和要点都能「跳到出处」回听原声那一刻
4. **检索回听**:搜索标题与全文,点句跳播、跟读滚动、密度着色进度条

### 工程现状（务必说清）
- **没有**可点安装的 `.ipa` / TestFlight / App Store
- Linux 云端 **编不了**真机包;以 **Mac 签装**为准
- 想进得到/飞书工作流:音频到 iPhone 后走系统分享面板(App 不集成也不依赖)

### 不要当主卖点
- 全天候无中断录音(手表录音是前台行为)
- 健康数据/心率情绪(评审中,未落地)

---

## 3. 怎么装（Mac + Xcode 侧载）

只想看装机、不看产品背景:[`teammate-watch-sideload.md`](teammate-watch-sideload.md)。  
签名、传输和限制的更细说明:[`daytap-watch-app.md`](daytap-watch-app.md)。

### 准备
- Mac + **Xcode 26 以上**(部署目标 iOS 26 / watchOS 10)
- Apple ID(免费可侧载,约 **7 天**过期,再 Run 续签)
- 装手表需已配对的 iPhone + Apple Watch;线连 Mac,手表解锁靠近

### 步骤
1. 浅克隆(命令见 §1)
2. 打开 `apps/DayTap/DayTap.xcodeproj`
3. Target **DayTap** 与 **DayTap Watch App**:Automatically manage signing → Team 选你的 Apple ID
4. Bundle id 默认 `com.guanhongli.daytap`;冲突则改唯一 id,Watch 必须为 `<iphone-id>.watchkitapp`
5. Scheme **DayTap** → 目标 **真机 iPhone** → Run
6. 未信任开发者:iPhone 设置 → 通用 → VPN 与设备管理 → 信任 → 再 Run
7. 手表无图标:Scheme **DayTap Watch App** → 目标 Watch → Run,再对 iPhone Run 一次
8. 冒烟:手表开始/停止录音 → iPhone「记录」tab 出现该条并自动转文字;空列表则靠近、双端打开、手表「再传一次」

模拟器测不了 WatchConnectivity 传文件,传输入证以真机为准。

飞书备份:[组员装机指南](https://my.feishu.cn/docx/KFrWd5boro20TWx6MUpctJgenXf)

---

## 4. 协作怎么进仓

- 主仓 **public**,克隆即用;PR 直接对 `main`,写清改了什么、是否真机测过
- commit message 末尾带 issue 号(`#N`)自动关联需求看板
- **每人自己的 Mac + Apple ID** 签装到自己的设备
- 黑客松优先:录稳 + 传输/转写通 + 待办能勾

---

## 5. 黑客松时间盒（手册摘要）

| 日 | 事 |
|----|------|
| 11/13 | 签到及开幕式 · 清华自强科技楼 5414 及中庭 |
| 11/14 | 集中开发 |
| 11/15 | 成果展示 / 路演 |

赛事手册(需登录):https://kc8ig8gvnh.feishu.cn/wiki/BfluwhA60iDaU1kdIKVcq9InnOb  
组队表:https://kc8ig8gvnh.feishu.cn/base/SuYpbutZQaNd3KsL8FscFP5Jntc  
校外入校:https://kc8ig8gvnh.feishu.cn/share/base/form/shrcnUMVmUej102dDR1P2JQJ1Ec

---

## 6. 相关材料索引

| 材料 | 位置 |
|------|------|
| 功能介绍(用户视角) | [`docs/product-intro.md`](product-intro.md) |
| 开发环境速览 | [`docs/dev-setup.md`](dev-setup.md) |
| 组员装机短步骤 | [`docs/teammate-watch-sideload.md`](teammate-watch-sideload.md) |
| 手表工程细节 | [`docs/daytap-watch-app.md`](daytap-watch-app.md) |
| 早期 MVP 档案(双轨/得到/演示脚本) | `docs/tech-path.md`、`docs/watch-two-tracks.md` 等,口径以本文件与 product-intro 为准 |
| 品牌 Figma | https://www.figma.com/design/My46193WfgQKdoDG1QncHo |

---

## 7. 组员检查清单

- [ ] 读完本文 §0–§2,能用自己的话讲清「是什么 / 不是什么」  
- [ ] 浅克隆 + Xcode 侧载通一次录音到转写  
- [ ] 卡点时贴:**卡在第几步 + Xcode 报错原文**

有问题先队内同步,再找仓库主理人 / DayTap Bot。
