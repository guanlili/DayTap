import Foundation
import Security

// MARK: - LLM 配置中心(#42:摘要只是第一个消费者,后续 AI 功能共用)

/// 国内主流厂商预设(#42,base_url 2026-11 核实):能默认内置的不让用户输入,能选的不让填;
/// 模型候选只是起点(各家上新快,以控制台为准),自定义输入永远兜底。
enum LLMProviderID: String, CaseIterable, Identifiable {
    case zhipu, ark, deepseek, moonshot, qwen, openai, custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zhipu: return "智谱 GLM"
        case .ark: return "火山方舟（豆包）"
        case .deepseek: return "DeepSeek"
        case .moonshot: return "Kimi（月之暗面）"
        case .qwen: return "通义千问（阿里）"
        case .openai: return "OpenAI"
        case .custom: return "自定义（OpenAI 兼容）"
        }
    }

    var presetBaseURL: String {
        switch self {
        case .zhipu: return "https://open.bigmodel.cn/api/paas/v4"
        case .ark: return "https://ark.cn-beijing.volces.com/api/v3"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .moonshot: return "https://api.moonshot.cn/v1"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .openai: return "https://api.openai.com/v1"
        case .custom: return ""
        }
    }

    var modelCandidates: [String] {
        switch self {
        case .zhipu: return ["glm-4-flash", "glm-4.7-flash", "glm-4.7"]
        case .ark: return ["doubao-seed-1.6", "doubao-1.5-pro-32k"]
        case .deepseek: return ["deepseek-chat", "deepseek-reasoner"]
        case .moonshot: return ["kimi-latest", "kimi-k3.1-pro"]
        case .qwen: return ["qwen-plus", "qwen-turbo", "qwen-max"]
        case .openai: return ["gpt-4o-mini", "gpt-4.1-mini"]
        case .custom: return []
        }
    }

    var defaultModel: String { modelCandidates.first ?? "" }
}

/// LLM 统一存取(#42):provider/model/customBaseURL/enabled;#39 的 cloudDigest.* 启动时自动迁移。
enum LLMSettings {
    static let enabledKey = "llm.enabled"
    static let providerKey = "llm.provider"
    static let customBaseURLKey = "llm.customBaseURL"
    static let modelKey = "llm.model"
    private static let migratedKey = "llm.migrated"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// 「关于我」(#71):常提到的人名/项目/术语,两条 digest 路径拼进 prompt 纠专名。
    /// 属 prompt 输入而非接口配置,随 LLM 设置一起存取;可选,空=行为不变。
    static let aboutMeKey = "llm.aboutMe"

    static var aboutMe: String {
        (UserDefaults.standard.string(forKey: aboutMeKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var provider: LLMProviderID {
        LLMProviderID(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .zhipu
    }

    static var customBaseURL: String { UserDefaults.standard.string(forKey: customBaseURLKey) ?? "" }

    /// 生效模型:选过的(含自定义)> 预设默认。
    static var model: String {
        let saved = UserDefaults.standard.string(forKey: modelKey) ?? ""
        return saved.isEmpty ? provider.defaultModel : saved
    }

    static var baseURL: String {
        provider == .custom ? customBaseURL : provider.presetBaseURL
    }

    /// 开关开着且 URL/模型/key 三样齐才算配全。
    static var isConfigured: Bool {
        enabled && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(LLMSecrets.loadKey() ?? "").isEmpty
    }

    /// #39→#42 迁移:旧 cloudDigest.* 按 baseURL 归入对应预设,只搬一次;
    /// Keychain 服务名不动,已配的 key 原地继承(不迁移=丢用户配置)。
    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey) else { return }
        defer { defaults.set(true, forKey: migratedKey) }
        let oldBase = (defaults.string(forKey: "cloudDigest.baseURL") ?? "").lowercased()
        let wasEnabled = defaults.bool(forKey: "cloudDigest.enabled")
        guard wasEnabled || !oldBase.isEmpty else { return }
        defaults.set(true, forKey: enabledKey)
        let mapped: LLMProviderID
        if oldBase.contains("bigmodel") { mapped = .zhipu }
        else if oldBase.contains("volces") { mapped = .ark }
        else if oldBase.contains("deepseek") { mapped = .deepseek }
        else if oldBase.contains("moonshot") { mapped = .moonshot }
        else if oldBase.contains("dashscope") { mapped = .qwen }
        else if oldBase.contains("openai.com") { mapped = .openai }
        else { mapped = .custom }
        defaults.set(mapped.rawValue, forKey: providerKey)
        if let oldModel = defaults.string(forKey: "cloudDigest.model"), !oldModel.isEmpty {
            defaults.set(oldModel, forKey: modelKey)
        }
        if mapped == .custom, !oldBase.isEmpty {
            defaults.set(oldBase, forKey: customBaseURLKey)
        }
    }
}

/// API key 存 Keychain 不进 UserDefaults——明文会随设备备份走。最小 kSecClassGenericPassword 封装。
/// 服务名沿用 #39 的 cloudDigest 值:升级不断已配的 key。
enum LLMSecrets {
    private static let service = "com.guanhongli.daytap.cloudDigest"
    private static let account = "apiKey"

    static func saveKey(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var attrs = query
        attrs[kSecValueData as String] = Data(trimmed.utf8)
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func loadKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// 统一的 OpenAI 兼容对话调用(#42):摘要/标题/类别是第一个消费者,后续 AI 功能直接复用。
struct LLMClient {
    struct CallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let requestURL: URL
    let model: String
    private let key: String

    /// 读 LLMSettings 现配;配置不全返回 nil。
    init?() {
        self.init(baseURL: LLMSettings.baseURL, model: LLMSettings.model, apiKey: LLMSecrets.loadKey() ?? "")
    }

    /// #77 同题对照:一次性临时配置,不落库、不进 Keychain,关页即弃。
    init?(baseURL: String, model: String, apiKey: String) {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "\(base)/chat/completions"),
              !model.isEmpty,
              !apiKey.isEmpty
        else { return nil }
        self.requestURL = url
        self.model = model
        self.key = apiKey
    }

    /// 单轮对话,返回 assistant 文本;失败抛带面向用户文案的 CallError(含 HTTP 码)。
    func chat(system: String, user: String, temperature: Double = 0.2) async throws -> String {
        var request = URLRequest(url: requestURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CallError(message: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CallError(message: "无效响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            DayTapLog.transcribe.info("llm HTTP \(http.statusCode, privacy: .public)")
            throw CallError(message: "HTTP \(http.statusCode)")
        }
        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { var content: String? }
                var message: Message
            }
            var choices: [Choice]
        }
        guard let chat = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let text = chat.choices.first?.message.content
        else {
            throw CallError(message: "回复格式无效")
        }
        return text
    }
}
