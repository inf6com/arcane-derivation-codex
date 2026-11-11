//
//  OpenAI.swift
//  inf6
//
//  Unified OpenAI client (Responses API) with strict error surfacing.
//  - No silent fallback
//  - No swallowed errors
//  - Always throws on non-2xx with full context
//

import Foundation

// MARK: - OpenAI Error

public enum OpenAIError: LocalizedError, Equatable {
    case invalidBaseURL(String)
    case invalidRequestBody(String)
    case transport(String)                  // URLSession / networking
    case nonHTTPResponse
    case httpError(statusCode: Int, apiError: OpenAIAPIError?, bodyText: String?, rateLimit: OpenAIRateLimitInfo?)
    case decoding(String)
    case missingOutputText
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let s):
            return "OpenAI: Base URL is invalid: \(s)"
        case .invalidRequestBody(let s):
            return "OpenAI: Request body is invalid: \(s)"
        case .transport(let s):
            return "OpenAI: Network error: \(s)"
        case .nonHTTPResponse:
            return "OpenAI: Response is not HTTPURLResponse."
        case .httpError(let status, let apiError, let bodyText, let rateLimit):
            var parts: [String] = []
            parts.append("OpenAI: HTTP \(status)")

            if let apiError = apiError {
                parts.append("type=\(apiError.type ?? "nil")")
                parts.append("code=\(apiError.code ?? "nil")")
                if let msg = apiError.message, !msg.isEmpty {
                    parts.append("message=\(msg)")
                }
            } else if let bodyText = bodyText, !bodyText.isEmpty {
                parts.append("body=\(bodyText)")
            }

            if let rateLimit = rateLimit {
                if let retryAfterSeconds = rateLimit.retryAfterSeconds {
                    parts.append("retry_after=\(retryAfterSeconds)s")
                }
                if let remReq = rateLimit.remainingRequests, let limReq = rateLimit.limitRequests {
                    parts.append("requests=\(remReq)/\(limReq)")
                }
                if let remTok = rateLimit.remainingTokens, let limTok = rateLimit.limitTokens {
                    parts.append("tokens=\(remTok)/\(limTok)")
                }
                if let resetReq = rateLimit.resetRequests {
                    parts.append("reset_requests=\(resetReq)")
                }
                if let resetTok = rateLimit.resetTokens {
                    parts.append("reset_tokens=\(resetTok)")
                }
            }

            return parts.joined(separator: " | ")

        case .decoding(let s):
            return "OpenAI: Decode error: \(s)"
        case .missingOutputText:
            return "OpenAI: Response contained no output text."
        case .cancelled:
            return "OpenAI: Request cancelled."
        }
    }
}

// MARK: - OpenAI API error payload

public struct OpenAIAPIErrorEnvelope: Decodable, Equatable {
    public let error: OpenAIAPIError?
}

public struct OpenAIAPIError: Decodable, Equatable {
    public let message: String?
    public let type: String?
    public let param: String?
    public let code: String?
}

// MARK: - Rate limit info (headers)

public struct OpenAIRateLimitInfo: Equatable {
    public let retryAfterSeconds: Int?

    public let limitRequests: Int?
    public let remainingRequests: Int?
    public let resetRequests: String?

    public let limitTokens: Int?
    public let remainingTokens: Int?
    public let resetTokens: String?

    public init(
        retryAfterSeconds: Int?,
        limitRequests: Int?,
        remainingRequests: Int?,
        resetRequests: String?,
        limitTokens: Int?,
        remainingTokens: Int?,
        resetTokens: String?
    ) {
        self.retryAfterSeconds = retryAfterSeconds
        self.limitRequests = limitRequests
        self.remainingRequests = remainingRequests
        self.resetRequests = resetRequests
        self.limitTokens = limitTokens
        self.remainingTokens = remainingTokens
        self.resetTokens = resetTokens
    }

    static func fromHTTPHeaders(_ headers: [AnyHashable: Any]) -> OpenAIRateLimitInfo? {
        func str(_ key: String) -> String? {
            for (k, v) in headers {
                if let ks = k as? String, ks.lowercased() == key.lowercased() {
                    return String(describing: v)
                }
            }
            return nil
        }
        func int(_ key: String) -> Int? {
            guard let s = str(key) else { return nil }
            return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Rate-limit headers are documented in OpenAI rate limit guide.  [oai_citation:3‡OpenAI Platform](https://platform.openai.com/docs/guides/rate-limits)
        let retryAfter = int("retry-after")

        let limitReq = int("x-ratelimit-limit-requests")
        let remReq = int("x-ratelimit-remaining-requests")
        let resetReq = str("x-ratelimit-reset-requests")

        let limitTok = int("x-ratelimit-limit-tokens")
        let remTok = int("x-ratelimit-remaining-tokens")
        let resetTok = str("x-ratelimit-reset-tokens")

        if retryAfter == nil,
           limitReq == nil, remReq == nil, resetReq == nil,
           limitTok == nil, remTok == nil, resetTok == nil {
            return nil
        }

        return OpenAIRateLimitInfo(
            retryAfterSeconds: retryAfter,
            limitRequests: limitReq,
            remainingRequests: remReq,
            resetRequests: resetReq,
            limitTokens: limitTok,
            remainingTokens: remTok,
            resetTokens: resetTok
        )
    }
}

// MARK: - Client

public final class OpenAIClient {
    public struct Config: Equatable {
        public enum ServiceTier: String, Equatable {
            case standard
            case flex
            case priority
        }

        public let baseURL: URL
        public let model: String
        public let timeoutSeconds: TimeInterval
        public let serviceTier: ServiceTier?

        public init(baseURL: URL, model: String, timeoutSeconds: TimeInterval = 90, serviceTier: ServiceTier? = nil) {
            self.baseURL = baseURL
            self.model = model
            self.timeoutSeconds = timeoutSeconds
            self.serviceTier = serviceTier
        }

        public static func `default`(model: String) throws -> Config {
            guard let url = URL(string: "https://api.openai.com") else {
                throw OpenAIError.invalidBaseURL("https://api.openai.com")
            }
            return Config(baseURL: url, model: model, timeoutSeconds: 90, serviceTier: nil)
        }
    }

    private let apiKey: String
    private let config: Config
    private let session: URLSession

    // MARK: - Request options

    public struct GenerateOptions: Equatable {
        public let maxOutputTokens: Int?
        public let modelOverride: String?
        public let requiresJSONObject: Bool

        public init(
            maxOutputTokens: Int? = nil,
            modelOverride: String? = nil,
            requiresJSONObject: Bool = false
        ) {
            self.maxOutputTokens = maxOutputTokens
            self.modelOverride = modelOverride
            self.requiresJSONObject = requiresJSONObject
        }
    }

    public struct InputMessage: Equatable {
        public let role: Role
        public let text: String

        public init(role: Role, text: String) {
            self.role = role
            self.text = text
        }
    }

    public enum Role: String {
        case system
        case user
        case assistant
    }

    public init(apiKey: String, config: Config, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.config = config
        self.session = session
    }

    // MARK: - Public API (prompt -> text)

    /// Sends a single text prompt using the Responses API and returns the output text.
    /// Request format follows the Responses create API.  [oai_citation:4‡OpenAI Platform](https://platform.openai.com/docs/api-reference/responses/create?api-mode=responses)
    public func generateText(prompt: String) async throws -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenAIError.invalidRequestBody("prompt is empty")
        }

        // Delegate to the unified message-based API.
        return try await generateText(
            messages: [InputMessage(role: .user, text: trimmed)],
            options: .init()
        )
    }

    /// Sends messages using the Responses API and returns the output text.
    /// This is the unified entry-point for all call-sites.
    public func generateText(messages: [InputMessage], options: GenerateOptions) async throws -> String {
        if Task.isCancelled { throw OpenAIError.cancelled }

        if !OpenAIHealthGate.isHealthy() {
            throw OpenAIError.httpError(
                statusCode: 429,
                apiError: OpenAIAPIError(message: "API blocked: \(OpenAIHealthGate.blockReason ?? "unknown")", type: "health_gate", param: nil, code: OpenAIHealthGate.blockReason),
                bodyText: nil,
                rateLimit: nil
            )
        }

        guard !messages.isEmpty else {
            throw OpenAIError.invalidRequestBody("messages is empty")
        }

        // Validate message texts strictly (no silent drop).
        for (i, m) in messages.enumerated() {
            let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty {
                throw OpenAIError.invalidRequestBody("message[\(i)] text is empty")
            }
        }

        if let maxTok = options.maxOutputTokens {
            if maxTok <= 0 {
                throw OpenAIError.invalidRequestBody("maxOutputTokens must be > 0")
            }
        }

        let url = config.baseURL.appendingPathComponent("v1/chat/completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = config.timeoutSeconds
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let chosenModel = (options.modelOverride ?? config.model).trimmingCharacters(in: .whitespacesAndNewlines)
        if chosenModel.isEmpty {
            throw OpenAIError.invalidRequestBody("model is empty")
        }

        var effectiveMessages = messages
        let globalInstruction = Inf6PromptGovernance.globalAdditionalInstruction()
        if !globalInstruction.isEmpty,
           let lastUserIndex = effectiveMessages.lastIndex(where: { $0.role == .user }) {
            let original = effectiveMessages[lastUserIndex]
            effectiveMessages[lastUserIndex] = InputMessage(
                role: original.role,
                text: original.text + "\n\n【全Prompt共通のユーザー指示】\n\(globalInstruction)"
            )
        }
        let chatMessages = effectiveMessages.map { m in
            ChatCompletionMessage(role: m.role.rawValue, content: m.text)
        }
        let body = ChatCompletionRequest(
            model: chosenModel,
            messages: chatMessages,
            max_completion_tokens: options.maxOutputTokens,
            response_format: options.requiresJSONObject ? ChatCompletionResponseFormat(type: "json_object") : nil
        )

        do {
            let enc = JSONEncoder()
            req.httpBody = try enc.encode(body)
        } catch {
            throw OpenAIError.invalidRequestBody(error.localizedDescription)
        }

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch is CancellationError {
            throw OpenAIError.cancelled
        } catch {
            throw OpenAIError.transport(error.localizedDescription)
        }

        guard let http = resp as? HTTPURLResponse else {
            throw OpenAIError.nonHTTPResponse
        }

        let rate = OpenAIRateLimitInfo.fromHTTPHeaders(http.allHeaderFields)

        if !(200...299).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8)
            let apiErr = Self.decodeAPIErrorIfPossible(data)
            let err = OpenAIError.httpError(
                statusCode: http.statusCode,
                apiError: apiErr,
                bodyText: bodyText,
                rateLimit: rate
            )
            OpenAIHealthGate.checkAndBlock(err)
            throw err
        }

        let decoded: ChatCompletionResponse
        do {
            let dec = JSONDecoder()
            decoded = try dec.decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw OpenAIError.decoding(error.localizedDescription)
        }

        if let text = decoded.extractText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        throw OpenAIError.missingOutputText
    }

    /// Sends a prompt with OpenAI's web_search tool enabled (Responses API) and returns the output text.
    /// Used when a claim needs to be checked/refined against live web content, not just the model's memory.
    public func generateTextWithWebSearch(prompt: String, options: GenerateOptions = .init()) async throws -> String {
        if Task.isCancelled { throw OpenAIError.cancelled }

        if !OpenAIHealthGate.isHealthy() {
            throw OpenAIError.httpError(
                statusCode: 429,
                apiError: OpenAIAPIError(message: "API blocked: \(OpenAIHealthGate.blockReason ?? "unknown")", type: "health_gate", param: nil, code: OpenAIHealthGate.blockReason),
                bodyText: nil,
                rateLimit: nil
            )
        }

        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenAIError.invalidRequestBody("prompt is empty")
        }

        let chosenModel = (options.modelOverride ?? config.model).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chosenModel.isEmpty else {
            throw OpenAIError.invalidRequestBody("model is empty")
        }

        let url = config.baseURL.appendingPathComponent("v1/responses")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = config.timeoutSeconds
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body = ResponsesAPIRequest(
            model: chosenModel,
            input: trimmed,
            tools: [ResponsesAPITool(type: "web_search_preview")]
        )
        do {
            req.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw OpenAIError.invalidRequestBody(error.localizedDescription)
        }

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch is CancellationError {
            throw OpenAIError.cancelled
        } catch {
            throw OpenAIError.transport(error.localizedDescription)
        }

        guard let http = resp as? HTTPURLResponse else {
            throw OpenAIError.nonHTTPResponse
        }

        let rate = OpenAIRateLimitInfo.fromHTTPHeaders(http.allHeaderFields)

        if !(200...299).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8)
            let apiErr = Self.decodeAPIErrorIfPossible(data)
            let err = OpenAIError.httpError(
                statusCode: http.statusCode,
                apiError: apiErr,
                bodyText: bodyText,
                rateLimit: rate
            )
            OpenAIHealthGate.checkAndBlock(err)
            throw err
        }

        let decoded: ResponsesAPIResponse
        do {
            decoded = try JSONDecoder().decode(ResponsesAPIResponse.self, from: data)
        } catch {
            throw OpenAIError.decoding(error.localizedDescription)
        }

        if let text = decoded.extractText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        throw OpenAIError.missingOutputText
    }

    /// Vision-capable: send text + images to GPT-4o
    public func generateTextWithVision(systemPrompt: String, userText: String, imageDataList: [(data: Data, mimeType: String)], options: GenerateOptions = .init()) async throws -> String {
        if Task.isCancelled { throw OpenAIError.cancelled }
        if !OpenAIHealthGate.isHealthy() {
            throw OpenAIError.httpError(statusCode: 429, apiError: OpenAIAPIError(message: "API blocked", type: "health_gate", param: nil, code: nil), bodyText: nil, rateLimit: nil)
        }

        var parts: [ChatCompletionContentPart] = []
        parts.append(.text(userText))
        for img in imageDataList {
            parts.append(.imageBase64(data: img.data, mimeType: img.mimeType, detail: Inf6VisionDetailSetting.resolved()))
        }

        let url = config.baseURL.appendingPathComponent("v1/chat/completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = config.timeoutSeconds
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let chosenModel = (options.modelOverride ?? config.model).trimmingCharacters(in: .whitespacesAndNewlines)
        let chatMessages: [ChatCompletionMessage] = [
            .init(role: "system", content: systemPrompt),
            .init(role: "user", parts: parts)
        ]
        let body = ChatCompletionRequest(
            model: chosenModel,
            messages: chatMessages,
            max_completion_tokens: options.maxOutputTokens ?? 4096,
            response_format: nil
        )
        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw OpenAIError.nonHTTPResponse }
        if !(200...299).contains(http.statusCode) {
            let apiErr = Self.decodeAPIErrorIfPossible(data)
            let err = OpenAIError.httpError(statusCode: http.statusCode, apiError: apiErr, bodyText: String(data: data, encoding: .utf8), rateLimit: OpenAIRateLimitInfo.fromHTTPHeaders(http.allHeaderFields))
            OpenAIHealthGate.checkAndBlock(err)
            throw err
        }
        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        if let text = decoded.extractText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        throw OpenAIError.missingOutputText
    }

    private static func decodeAPIErrorIfPossible(_ data: Data) -> OpenAIAPIError? {
        // Typical OpenAI REST error envelope: { "error": { "message":..., "type":..., "param":..., "code":... } }
        // If it doesn't match, we return nil and keep raw bodyText in the thrown error.
        do {
            let env = try JSONDecoder().decode(OpenAIAPIErrorEnvelope.self, from: data)
            return env.error
        } catch {
            return nil
        }
    }
}

// MARK: - Global API Health Gate

public enum OpenAIHealthGate {
    private static let _lock = NSLock()
    private static var _blockedUntil: Date?
    private static var _reason: String?

    public static func markUnhealthy(reason: String, cooldownSeconds: TimeInterval = 300) {
        _lock.lock()
        _blockedUntil = Date().addingTimeInterval(cooldownSeconds)
        _reason = reason
        _lock.unlock()
        NSLog("[inf6-api-health] blocked for %.0fs: %@", cooldownSeconds, reason)
    }

    public static func isHealthy() -> Bool {
        _lock.lock()
        defer { _lock.unlock() }
        guard let until = _blockedUntil else { return true }
        if Date() >= until {
            _blockedUntil = nil
            _reason = nil
            return true
        }
        return false
    }

    public static var blockReason: String? {
        _lock.lock()
        defer { _lock.unlock() }
        return _reason
    }

    public static func reset() {
        _lock.lock()
        _blockedUntil = nil
        _reason = nil
        _lock.unlock()
    }

    static func checkAndBlock(_ error: Error) {
        guard let oaiErr = error as? OpenAIError else { return }
        switch oaiErr {
        case .httpError(let status, let apiError, _, _):
            if status == 401 {
                markUnhealthy(reason: "invalid_api_key", cooldownSeconds: 3600)
            } else if status == 429 {
                markUnhealthy(reason: apiError?.code ?? "rate_limited", cooldownSeconds: 60)
            }
        default:
            break
        }
    }
}

// MARK: - Responses API request/response (minimal subset)

// Based on Responses create request schema: model + input messages with content list.  [oai_citation:6‡OpenAI Platform](https://platform.openai.com/docs/api-reference/responses/create?api-mode=responses)
private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatCompletionMessage]
    let max_completion_tokens: Int?
    let response_format: ChatCompletionResponseFormat?
}

private struct ChatCompletionResponseFormat: Encodable {
    let type: String
}

private struct ChatCompletionMessage: Encodable {
    let role: String
    let content: ChatCompletionContent

    init(role: String, content: String) {
        self.role = role
        self.content = .text(content)
    }

    init(role: String, parts: [ChatCompletionContentPart]) {
        self.role = role
        self.content = .parts(parts)
    }
}

private enum ChatCompletionContent: Encodable {
    case text(String)
    case parts([ChatCompletionContentPart])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let s): try container.encode(s)
        case .parts(let p): try container.encode(p)
        }
    }
}

private struct ChatCompletionContentPart: Encodable {
    let type: String
    let text: String?
    let image_url: ImageURL?

    struct ImageURL: Encodable {
        let url: String
        let detail: String?
    }

    static func text(_ t: String) -> Self {
        .init(type: "text", text: t, image_url: nil)
    }

    static func imageBase64(data: Data, mimeType: String = "image/png", detail: String = "high") -> Self {
        let b64 = data.base64EncodedString()
        return .init(type: "image_url", text: nil, image_url: .init(url: "data:\(mimeType);base64,\(b64)", detail: detail))
    }
}

private struct ResponsesAPIRequest: Encodable {
    let model: String
    let input: String
    let tools: [ResponsesAPITool]
}

private struct ResponsesAPITool: Encodable {
    let type: String
}

private struct ResponsesAPIResponse: Decodable {
    let output: [ResponsesAPIOutputItem]?

    func extractText() -> String? {
        guard let output else { return nil }
        for item in output where item.type == "message" {
            guard let content = item.content else { continue }
            let texts = content.compactMap { part -> String? in
                guard part.type == "output_text" else { return nil }
                return part.text
            }
            if !texts.isEmpty {
                return texts.joined(separator: "\n")
            }
        }
        return nil
    }
}

private struct ResponsesAPIOutputItem: Decodable {
    let type: String
    let content: [ResponsesAPIContentPart]?
}

private struct ResponsesAPIContentPart: Decodable {
    let type: String
    let text: String?
}

private struct ChatCompletionResponse: Decodable {
    let choices: [ChatCompletionChoice]?

    func extractText() -> String? {
        choices?.first?.message?.content
    }
}

private struct ChatCompletionChoice: Decodable {
    let message: ChatCompletionChoiceMessage?
}

private struct ChatCompletionChoiceMessage: Decodable {
    let content: String?
}

// MARK: - Vision Detail Setting

enum Inf6VisionDetailSetting {
    static let userDefaultsKey = "inf6.openai.vision_detail"
    static let defaultValue = "low"

    static func resolved() -> String {
        let v = UserDefaults.standard.string(forKey: userDefaultsKey) ?? defaultValue
        return (v == "high") ? "high" : "low"
    }
}
