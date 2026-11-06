import Foundation
import Security

public enum AIProvider: String, CaseIterable, Codable, Sendable {
    case openAI = "OpenAI"
    case claude = "Claude"
    case gemini = "Gemini"
    case apple = "Apple"

    public var defaultModel: String {
        switch self {
        case .openAI: return "gpt-5-mini"
        case .claude: return "claude-sonnet-4-5"
        case .gemini: return "gemini-2.5-flash"
        case .apple: return "Apple Foundation Models"
        }
    }

    public var needsAPIKey: Bool { self != .apple }
}

public struct AIProviderConfiguration: Codable, Equatable, Sendable {
    public var provider: AIProvider
    public var model: String
    public init(provider: AIProvider, model: String? = nil) {
        self.provider = provider
        self.model = model ?? provider.defaultModel
    }
}

public struct AIProviderConfigurationStore {
    private let root: WorkspaceStore

    public init(root: WorkspaceStore) {
        self.root = root
    }

    public func load() throws -> AIProviderConfiguration? {
        try root.load(AIProviderConfiguration.self, named: "provider.json", in: "ai")
    }

    public func save(_ configuration: AIProviderConfiguration) throws {
        try root.save(configuration, named: "provider.json", in: "ai")
    }
}

public enum AIProviderError: LocalizedError {
    case emptyPrompt
    case emptyResponse
    case missingAPIKey
    case invalidResponse
    case server(String)
    case unavailable
    public var errorDescription: String? {
        switch self {
        case .emptyPrompt: return "AIへ送る内容が空です。"
        case .emptyResponse: return "Providerから空の応答が返されました。"
        case .missingAPIKey: return "APIキーを入力してください。"
        case .invalidResponse: return "Providerの応答を解釈できません。"
        case .server(let message): return message
        case .unavailable: return "この端末ではAppleのローカルモデルを利用できません。"
        }
    }
}

public enum APIKeychain {
    private static let service = "com.inf6.arcane-derivation.provider-key"

    public static func save(_ key: String, for provider: AIProvider) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: provider.rawValue]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AIProviderError.server("APIキーをKeychainへ保存できません。") }
    }

    public static func load(for provider: AIProvider) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: provider.rawValue, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public struct AIProviderClient {
    public let configuration: AIProviderConfiguration
    public let apiKey: String?
    public init(configuration: AIProviderConfiguration, apiKey: String? = nil) { self.configuration = configuration; self.apiKey = apiKey }

    public func generate(prompt: String) async throws -> String {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIProviderError.emptyPrompt }
        switch configuration.provider {
        case .openAI: return try await requestOpenAI(prompt: prompt)
        case .claude: return try await requestClaude(prompt: prompt)
        case .gemini: return try await requestGemini(prompt: prompt)
        case .apple:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) { return try await AppleFoundationModelsClient.generate(prompt: prompt) }
            #endif
            throw AIProviderError.unavailable
        }
    }

    private func requestOpenAI(prompt: String) async throws -> String {
        let data: [String: Any] = ["model": configuration.model, "input": prompt]
        let response = try await post(URL(string: "https://api.openai.com/v1/responses")!, headers: ["Authorization": "Bearer \(try key())"], body: data)
        return try requiredText(response["output_text"])
    }

    private func requestClaude(prompt: String) async throws -> String {
        let data: [String: Any] = ["model": configuration.model, "max_tokens": 2048, "messages": [["role": "user", "content": prompt]]]
        let response = try await post(URL(string: "https://api.anthropic.com/v1/messages")!, headers: ["x-api-key": try key(), "anthropic-version": "2023-06-01"], body: data)
        guard let content = response["content"] as? [[String: Any]], let value = content.first?["text"] else { throw AIProviderError.invalidResponse }
        return try requiredText(value)
    }

    private func requestGemini(prompt: String) async throws -> String {
        let key = try key()
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(configuration.model):generateContent")!
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        let data: [String: Any] = ["contents": [["parts": [["text": prompt]]]]]
        let response = try await post(components.url!, headers: [:], body: data)
        guard let candidates = response["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let value = parts.first?["text"] else { throw AIProviderError.invalidResponse }
        return try requiredText(value)
    }

    private func key() throws -> String {
        guard let apiKey else { throw AIProviderError.missingAPIKey }
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw AIProviderError.missingAPIKey }
        return value
    }

    private func requiredText(_ value: Any?) throws -> String {
        guard let text = value as? String else { throw AIProviderError.invalidResponse }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIProviderError.emptyResponse }
        return text
    }

    private func post(_ url: URL, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AIProviderError.server(String(data: data, encoding: .utf8) ?? "Provider接続に失敗しました。") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIProviderError.invalidResponse }
        return object
    }
}
