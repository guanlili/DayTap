import SwiftUI

/// 同题对照·最小版(#77 已拍板):同一段转写,当前已存摘要 vs 临时填入配置现跑一份,
/// 两张只读卡并排看。临时配置不落库、不进 Keychain,关页即弃;只跑云端(OpenAI 兼容)口径。
struct CompareSheet: View {
    /// 对照对象:转写全文与已存摘要三件套来自这条录音。
    let record: RecordingRecord
    /// compareDigest 挂在转写中心上(与正常 digest 同一 prompt 拼装)。
    let transcriber: TranscriptionCenter

    @Environment(\.dismiss) private var dismiss

    @State private var provider: LLMProviderID = .zhipu
    @State private var modelSelection: String = ""
    @State private var customModel = ""
    @State private var customBaseURL = ""
    @State private var apiKey = ""
    @State private var running = false
    @State private var note = ""
    @State private var result: TranscriptionCenter.CompareResult?

    /// 模型 Picker 里「自定义…」的哨兵值(与设置页同款口径)。
    private static let customModelTag = "__custom__"

    private var effectiveBaseURL: String {
        provider == .custom ? customBaseURL : provider.presetBaseURL
    }

    private var effectiveModel: String {
        modelSelection == Self.customModelTag ? customModel : modelSelection
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    digestCard(
                        title: "当前已存(\(LLMSettings.provider.displayName) · \(LLMSettings.model))",
                        titleText: record.autoTitle,
                        summary: record.summary,
                        actions: record.actionItems ?? []
                    )
                } header: {
                    Text("当前配置")
                } footer: {
                    Text("转写完成时按当前配置生成;重新转写会覆盖。")
                }

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
                        runComparison()
                    } label: {
                        HStack {
                            Label("生成对照", systemImage: "square.split.2x1")
                            if running {
                                Spacer()
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .disabled(running || (record.transcript?.isEmpty ?? true))
                    if let result {
                        digestCard(
                            title: "本次临时(\(provider.displayName) · \(effectiveModel))",
                            titleText: result.title,
                            summary: result.summary,
                            actions: result.actions ?? []
                        )
                    }
                    if !note.isEmpty {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("临时配置")
                } footer: {
                    Text("不保存,关页即弃;点一次按该服务商实际计费一次。与当前配置跑同一份输入(含「关于我」),对照才公平。")
                }
            }
            .navigationTitle("同题对照")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                if modelSelection.isEmpty {
                    modelSelection = provider.defaultModel.isEmpty ? Self.customModelTag : provider.defaultModel
                }
            }
            .onChange(of: provider) { _, newProvider in
                modelSelection = newProvider.defaultModel.isEmpty ? Self.customModelTag : newProvider.defaultModel
                customModel = ""
            }
        }
    }

    private func runComparison() {
        guard let transcript = record.transcript, !transcript.isEmpty else { return }
        running = true
        note = ""
        Task {
            do {
                let output = try await transcriber.compareDigest(
                    transcript: transcript,
                    baseURL: effectiveBaseURL,
                    model: effectiveModel,
                    apiKey: apiKey
                )
                await MainActor.run {
                    result = output
                    running = false
                }
            } catch {
                await MainActor.run {
                    note = "生成失败:\(error.localizedDescription)"
                    running = false
                }
            }
        }
    }

    /// 只读对照卡:标题/摘要/待办三样,肉眼可比的最小集。
    @ViewBuilder
    private func digestCard(
        title: String,
        titleText: String?,
        summary: String?,
        actions: [ActionItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if let titleText, !titleText.isEmpty {
                Text(titleText)
                    .font(.subheadline.weight(.medium))
            }
            if let summary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
            }
            ForEach(actions) { item in
                Text("· \(item.text)\(item.isDone ? " ✓" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if (titleText ?? "").isEmpty && (summary ?? "").isEmpty && actions.isEmpty {
                Text("（这份没有摘要三件套）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
