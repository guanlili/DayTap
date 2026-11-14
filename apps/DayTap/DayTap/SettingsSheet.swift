import SwiftUI

/// 设置(#40):AI 模型(#42 LLM 配置中心+#71 关于我)+iCloud 备份(#56 泊车态)+数据去向(#72)+关于。
/// 设置(#40→#42):配置归设置。AI 模型节=LLM 配置中心——预设厂商可选不填、
/// 模型候选可选+自定义兜底、key 唯一必填,配完一键连通性测试;摘要只是第一个消费者。
struct SettingsSheet: View {
    @ObservedObject var transcriber: TranscriptionCenter
    @ObservedObject private var cloudSync = CloudSync.shared
    @Environment(\.dismiss) private var dismiss

    @State private var llmEnabled: Bool
    @State private var cloudEnabled = CloudSyncSettings.enabled
    @State private var cloudAudio = CloudSyncSettings.includeAudio
    @State private var provider: LLMProviderID
    @State private var customBaseURL: String
    @State private var modelSelection: String
    @State private var customModel: String
    @State private var apiKey: String
    @State private var aboutMe: String
    @State private var testResult: (ok: Bool, message: String)?
    @State private var testing = false

    /// 模型 Picker 里「自定义…」的哨兵值。
    private static let customModelTag = "__custom__"

    init(transcriber: TranscriptionCenter) {
        self.transcriber = transcriber
        _llmEnabled = State(initialValue: LLMSettings.enabled)
        let savedProvider = LLMSettings.provider
        let savedModel = LLMSettings.model
        _provider = State(initialValue: savedProvider)
        _customBaseURL = State(initialValue: LLMSettings.customBaseURL)
        if savedProvider.modelCandidates.contains(savedModel) {
            _modelSelection = State(initialValue: savedModel)
            _customModel = State(initialValue: "")
        } else {
            _modelSelection = State(initialValue: Self.customModelTag)
            _customModel = State(initialValue: savedModel)
        }
        _apiKey = State(initialValue: LLMSecrets.loadKey() ?? "")
        _aboutMe = State(initialValue: LLMSettings.aboutMe)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("启用 AI 整理", isOn: $llmEnabled)
                } header: {
                    Text("AI 模型")
                } footer: {
                    Text("配置一次，摘要、标题、类别与后续 AI 功能共用。本机 Apple 智能可用时始终优先本机；启用后转写文字将发送到所选服务。")
                }

                // 接口细节开关开着才出现(#40 渐进披露)。
                if llmEnabled {
                    Section {
                        Picker("服务商", selection: $provider) {
                            ForEach(LLMProviderID.allCases) { Text($0.displayName).tag($0) }
                        }

                        if provider == .custom {
                            TextField("Base URL（OpenAI 兼容）", text: $customBaseURL, prompt: Text("https://…/v1"))
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }

                        Picker("模型", selection: $modelSelection) {
                            ForEach(provider.modelCandidates, id: \.self) { Text($0).tag($0) }
                            Text("自定义…").tag(Self.customModelTag)
                        }
                        if modelSelection == Self.customModelTag {
                            TextField("模型名（以控制台为准）", text: $customModel)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }

                        SecureField("API Key", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Button {
                            // 测的是当前表单值:先保存再测,所见即所测。
                            persist()
                            testing = true
                            testResult = nil
                            Task {
                                testResult = await TranscriptionCenter.testLLMConnection()
                                testing = false
                            }
                        } label: {
                            HStack {
                                Label("测试连通性", systemImage: "bolt.horizontal")
                                if testing {
                                    Spacer()
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .disabled(testing)
                        // 结果语义化着色(#42 甲方反馈):成功=绿色对勾,失败=警示色三角+原因,不再一行死灰。
                        if let testResult {
                            HStack(spacing: 6) {
                                Image(systemName: testResult.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(testResult.ok ? Color.green : Color.orange)
                                Text(testResult.message)
                                    .foregroundStyle(testResult.ok ? Color.green : Color.secondary)
                            }
                            .font(.caption)
                            .accessibilityLabel(testResult.ok ? "连接正常" : testResult.message)
                            .accessibilityIdentifier("daytap.llm.testResult")
                        }
                    } footer: {
                        Text("模型候选只是起点，各家上新快，以控制台为准，选「自定义…」可填任意型号。")
                    }

                    // 「关于我」(#71):可选背景段,拼进 digest prompt 纠人名/术语——
                    // 占位示例即格式说明,能选不填,留空行为不变。
                    Section {
                        TextField("例：同事小周、青云项目、行业词「私域复购」…", text: $aboutMe, axis: .vertical)
                            .lineLimit(1...4)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("daytap.llm.aboutMe")
                    } header: {
                        Text("关于我")
                    } footer: {
                        Text("常提到的人名、项目名与术语的规范写法。整理摘要时会随转写文字一并发给所配服务，帮模型写对专有名词；留空不发送。")
                    }

                    Section {
                        Button {
                            transcriber.backfillDigests()
                        } label: {
                            if transcriber.backfillRunning {
                                Text("补生成中 \(transcriber.backfillDone)/\(transcriber.backfillTotal)…")
                            } else {
                                let count = transcriber.backfillCandidateCount
                                Text(count > 0 ? "为现有转写补生成摘要（\(count) 条）" : "没有需要补的录音")
                            }
                        }
                        .disabled(transcriber.backfillRunning)
                    } footer: {
                        Text("为已转写但还没有摘要/类别的录音串行补生成。")
                    }
                }

                // iCloud 备份(#56):全量默认(音频+文字),仅文字开关留给配额紧张;
                // 状态可见不静默——未登录/空间不足/离线都在这里说话。
                // 免费签名团队开不了 iCloud 能力(2026-11-12 定):整节收起只留状态说明。
                Section {
                    if CloudSync.capabilityAvailable {
                        Toggle("iCloud 备份", isOn: $cloudEnabled)
                        if cloudEnabled {
                            Toggle("包含音频", isOn: $cloudAudio)
                            LabeledContent("状态", value: cloudSync.status.text)
                            if cloudSync.cloudCount > 0 {
                                LabeledContent(
                                    "已备份",
                                    value: "\(cloudSync.cloudCount) 条 · \(DayTapFormat.bytes(cloudSync.cloudBytes))"
                                )
                            }
                            Button("立即同步") {
                                cloudSync.syncNow()
                            }
                        }
                    } else {
                        LabeledContent("状态", value: cloudSync.status.text)
                    }
                } header: {
                    Text("iCloud 备份")
                } footer: {
                    Text(
                        CloudSync.capabilityAvailable
                            ? "录音与转写备份到你的 iCloud 私有空间，换机或重装可恢复。音频仅在 WiFi 且充电时上传；关闭「包含音频」只备文字，几 KB 一条。"
                            : "备份能力已就绪，但当前签名账号是免费个人团队，无法开通 iCloud 权限；升级付费开发者账号后即可启用。"
                    )
                }

                // 数据去向(#72):一屏总览「什么存在哪、什么会出网、怎么关」。
                // 各节 footer 讲细节,这里只做清单;不写死字数/条数这类会漂移的数字。
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("· 录音与转写只存在这台 iPhone 的 App 私有空间；转写在本机完成，手表录音传回手机后原件即从手表删除。DayTap 没有自己的服务器，也不需要账号。")
                        Text("· AI 整理优先在本机 Apple 智能完成；配置云端服务商后，生成摘要会把转写文字——填了「关于我」则连同它——发送到所选服务，音频文件永不外发。关掉「启用 AI 整理」即完全不出设备。")
                        Text("· iCloud 备份把录音与转写备份到你自己的 iCloud 私有空间；可以关闭，也可以只备文字。")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("数据去向")
                }

                Section {
                    LabeledContent("版本", value: "开发版")
                } header: {
                    Text("关于")
                } footer: {
                    Text("还不能从 App Store 安装，用 Xcode 侧载；表上没装好时用手机自带录音替代。链接 daytap://recordings 会回到录音列表。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: cloudEnabled) { _, on in
                CloudSyncSettings.enabled = on
                cloudSync.settingsChanged()
            }
            .onChange(of: cloudAudio) { _, on in
                CloudSyncSettings.includeAudio = on
                cloudSync.settingsChanged()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        persist()
                        dismiss()
                    }
                }
            }
            .onChange(of: provider) { _, newProvider in
                // 换厂商,模型候选跟随重置;自定义模型名清空待填。
                modelSelection = newProvider.defaultModel.isEmpty ? Self.customModelTag : newProvider.defaultModel
                customModel = ""
            }
        }
    }

    private func persist() {
        let defaults = UserDefaults.standard
        let model = modelSelection == Self.customModelTag ? customModel : modelSelection
        defaults.set(llmEnabled, forKey: LLMSettings.enabledKey)
        defaults.set(provider.rawValue, forKey: LLMSettings.providerKey)
        defaults.set(customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: LLMSettings.customBaseURLKey)
        defaults.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: LLMSettings.modelKey)
        defaults.set(aboutMe.trimmingCharacters(in: .whitespacesAndNewlines), forKey: LLMSettings.aboutMeKey)
        LLMSecrets.saveKey(apiKey)
    }
}

