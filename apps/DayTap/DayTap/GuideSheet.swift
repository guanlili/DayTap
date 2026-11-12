import SwiftUI
import UniformTypeIdentifiers

/// 使用指南(#24/#40 瘦身后):知识/工作流/配置三分,自解释的不进指南。
struct GuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // #40 瘦身:3 节 7 行,只留「界面答不了的事」——隐藏手势/护栏真相/外部链路。
                // 操作细节(轻扫/长按/批量/分组/筛选)界面自明,不再写;配置在设置;开发版说明在设置「关于」。
                Section("录音") {
                    guideRow(
                        icon: "applewatch",
                        title: "手表",
                        detail: "红色大按钮开始/停止；指节敲桌面两下也能启停（DayTap 在前台时），录音中按表冠回表盘不停。录错点「丢弃待传」整条弃掉。传到 iPhone 确认后手表原件自动清除。"
                    )
                    guideRow(
                        icon: "iphone",
                        title: "iPhone",
                        detail: "列表下方红钮直接录，录完和手表录音一起出现在这里；手机录的只存在本机。"
                    )
                }

                Section("转写与整理") {
                    guideRow(
                        icon: "text.bubble",
                        title: "自动转写",
                        detail: "录音到位自动转全文（接电源或电量充足时；首次需下载中文语音模型，之后离线；超长的可长按手动转）。转写完自动出短标题、摘要、待办和类别——长按可改名改类别，行内文字点开全文。摘要需要 Apple 智能，国行手机可在设置的 AI 模型里配置（智谱 / DeepSeek / Kimi / 通义 / 方舟等）。"
                    )
                    guideRow(
                        icon: "waveform",
                        title: "回听",
                        detail: "进度条可拖动、点「1x」换倍速；「跳静音」自动跳过句间无声段。搜索能搜标题与全文，点命中处直达说那句话的那一刻；删除的录音进「最近删除」保留 30 天。"
                    )
                }

                Section("出口") {
                    guideRow(
                        icon: "brain",
                        title: "Track 2 · 得到大脑",
                        detail: "点「分享」选得到大脑，或得到里「导入音视频」选这个 m4a。得到只在这台 iPhone 上。"
                    )
                    guideRow(
                        icon: "text.quote",
                        title: "Track 1 · 转写交给 Bot",
                        detail: "「分享」或「存到文件」后用飞书妙记、快捷指令转写，或送到 Mac 做系统转写，文字贴给 Bot 出决策卡。不要把这条音频送进得到。"
                    )
                    guideRow(
                        icon: "folder",
                        title: "文件与导出",
                        detail: "音频在「文件」App → 我的 iPhone → DayTap；⋯ 菜单「导出」把当前列表（可按类别先筛）拼成一个文件——Markdown 进语料库、纯文本直接粘贴、JSON 喂脚本，内容可选完整或仅摘要卡。"
                    )
                }
            }
            .navigationTitle("使用指南")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

/// 导出格式(#41):三种下游三种壳——Markdown 给语料库、纯文本给聊天粘贴、JSON 给脚本管道。

private func guideRow(icon: String, title: String, detail: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
