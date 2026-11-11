import Foundation

// MARK: - Error Intelligence
// エラーをAIに投入し、アプリ自体が構造を自動改変する。
// 機械的な3回リトライではなく、エラーの意味を理解して適応する。

enum Inf6ErrorIntelligence {

    // MARK: - Error Event Collection

    struct ErrorEvent: Codable {
        let timestamp: Double
        let operation: String
        let context: String
        let errorType: String
        let errorMessage: String
        let httpStatus: Int?
        let apiErrorCode: String?
    }

    private static let _lock = NSLock()
    private static var _recentErrors: [ErrorEvent] = []
    private static var _lastAnalysisAt: Date?
    private static var _didLoadPersistedErrors = false
    private static let _persistedErrorsKey = "runtime_error_events_v1"

    @discardableResult
    private static func _persist(_ events: [ErrorEvent]) -> Bool {
        let persisted = Inf6MetadataStore.putCodable(
            events,
            domain: .settings,
            key: _persistedErrorsKey
        )
        if !persisted {
            NSLog("[Inf6ErrorIntelligence] runtime error event persistence failed; keeping the event in memory")
        }
        return persisted
    }

    static func record(operation: String, context: String, error: Error) {
        let event = _classify(operation: operation, context: context, error: error)
        _lock.lock()
        if !_didLoadPersistedErrors {
            _recentErrors = Inf6MetadataStore.getCodable(
                [ErrorEvent].self,
                domain: .settings,
                key: _persistedErrorsKey
            ) ?? []
            _didLoadPersistedErrors = true
        }
        _recentErrors.append(event)
        if _recentErrors.count > 500 { _recentErrors.removeFirst(_recentErrors.count - 500) }
        let persistedErrors = _recentErrors
        let count = _recentErrors.count
        let lastAnalysis = _lastAnalysisAt
        _lock.unlock()
        let didPersist = _persist(persistedErrors)

        let needsAnalysis = didPersist
            && count >= 5
            && (lastAnalysis == nil || Date().timeIntervalSince(lastAnalysis!) > 120)
        if needsAnalysis {
            Task.detached(priority: .utility) {
                await analyzeAndAdapt()
            }
        }
    }

    static func recordRuntimeEvent(operation: String, context: String, error: Error) {
        let event = _classify(operation: operation, context: context, error: error)
        _lock.lock()
        if !_didLoadPersistedErrors {
            _recentErrors = Inf6MetadataStore.getCodable(
                [ErrorEvent].self,
                domain: .settings,
                key: _persistedErrorsKey
            ) ?? []
            _didLoadPersistedErrors = true
        }
        _recentErrors.append(event)
        if _recentErrors.count > 500 { _recentErrors.removeFirst(_recentErrors.count - 500) }
        let persistedErrors = _recentErrors
        _lock.unlock()
        _ = _persist(persistedErrors)
    }

    static func recordedEvents() -> [ErrorEvent] {
        Inf6MetadataStore.getCodable(
            [ErrorEvent].self,
            domain: .settings,
            key: _persistedErrorsKey
        ) ?? []
    }

    // MARK: - Adaptive Rules (AI-generated, stored in DB)

    struct AdaptiveRule: Codable {
        let id: String
        let createdAt: Double
        let operation: String
        let condition: Condition
        let action: Action

        enum Condition: Codable {
            case skipPaper(paperIDPrefix: String)
            case skipOperation(operationName: String)
            case reduceLoad(maxConcurrent: Int)
            case cooldown(seconds: Int)
            case switchStrategy(from: String, to: String)
        }

        enum Action: Codable {
            case skip(reason: String)
            case delay(seconds: Int)
            case fallback(strategy: String)
            case disable(until: Double)
        }
    }

    static func loadRules() -> [AdaptiveRule] {
        guard let json = Inf6MetadataStore.get(domain: .settings, key: "error_intelligence_rules"),
              let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([AdaptiveRule].self, from: data)) ?? []
    }

    static func shouldSkip(operation: String, context: String) -> String? {
        let rules = loadRules()
        let now = Date().timeIntervalSince1970
        for rule in rules {
            switch rule.action {
            case .disable(let until) where until > now:
                if rule.operation == operation || rule.operation == "*" {
                    return "disabled until \(_formatDate(until))"
                }
            case .skip(let reason):
                if rule.operation == operation {
                    if case .skipOperation(let op) = rule.condition, op == operation {
                        return reason
                    }
                    if case .skipPaper(let prefix) = rule.condition, context.hasPrefix(prefix) {
                        return reason
                    }
                }
            default:
                continue
            }
        }
        return nil
    }

    static func adaptiveDelay(operation: String) -> TimeInterval {
        let rules = loadRules()
        for rule in rules where rule.operation == operation {
            if case .delay(let seconds) = rule.action {
                return TimeInterval(seconds)
            }
        }
        return 0
    }

    // MARK: - AI Analysis

    static func analyzeAndAdapt() async {
        let analysisDate = Date()
        let errors: [ErrorEvent] = _lock.withLock {
            _lastAnalysisAt = analysisDate
            return _recentErrors
        }

        guard !errors.isEmpty else { return }
        guard OpenAIHealthGate.isHealthy() else {
            NSLog("[inf6-error-intelligence] AI analysis skipped because the health gate is closed; no fallback rule was applied")
            return
        }

        let errorSummary = _buildErrorSummary(errors)

        let prompt = """
        あなたはモバイルアプリの自己修復エンジンです。以下のエラーログを分析し、アプリの動作を適応させるルールをJSON配列で返してください。

        エラーログ:
        \(errorSummary)

        返すべきJSON形式:
        [
          {
            "operation": "操作名 or *",
            "action": "skip|delay|disable",
            "target": "対象の説明",
            "reason": "判断理由",
            "duration_seconds": 秒数(disableの場合),
            "delay_seconds": 秒数(delayの場合)
          }
        ]

        ルール:
        - quota超過: 該当APIを長時間disable
        - 同一論文の繰り返し失敗: その論文をskip
        - rate_limit: delay増加
        - ネットワークエラー: 全操作をcooldown
        - パース失敗が特定フォーマットに集中: そのフォーマットをskip

        JSONのみ返してください。説明不要。
        """

        do {
            let apiKey = Inf6MetadataStore.get(domain: .settings, key: "openai_api_key") ?? ""
            guard !apiKey.isEmpty else { return }
            let config = try OpenAIClient.Config.default(model: "gpt-4o-mini")
            let client = OpenAIClient(apiKey: apiKey, config: config)
            let response = try await client.generateText(prompt: prompt)
            _parseAndStoreRules(response)
        } catch {
            NSLog("[inf6-error-intelligence] AI analysis failed; no fallback rule was applied: %@", error.localizedDescription)
        }
    }

    // MARK: - Parse AI Response

    private static func _parseAndStoreRules(_ response: String) {
        guard let jsonStart = response.firstIndex(of: "["),
              let jsonEnd = response.lastIndex(of: "]") else {
            NSLog("[inf6-error-intelligence] AI response contained no JSON rule array; no fallback rule was applied")
            return
        }

        let jsonStr = String(response[jsonStart...jsonEnd])
        guard let data = jsonStr.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            NSLog("[inf6-error-intelligence] AI response JSON rule array was invalid; no fallback rule was applied")
            return
        }

        let now = Date().timeIntervalSince1970
        var rules: [AdaptiveRule] = []

        for (i, item) in items.enumerated() {
            let operation = item["operation"] as? String ?? "*"
            let action = item["action"] as? String ?? ""
            let reason = item["reason"] as? String ?? ""
            let target = item["target"] as? String ?? ""

            let rule: AdaptiveRule
            switch action {
            case "skip":
                rule = AdaptiveRule(
                    id: "ai-\(i)-\(Int(now))",
                    createdAt: now,
                    operation: operation,
                    condition: .skipOperation(operationName: target),
                    action: .skip(reason: reason)
                )
            case "disable":
                let duration = item["duration_seconds"] as? Int ?? 3600
                rule = AdaptiveRule(
                    id: "ai-\(i)-\(Int(now))",
                    createdAt: now,
                    operation: operation,
                    condition: .skipOperation(operationName: operation),
                    action: .disable(until: now + Double(duration))
                )
            case "delay":
                let seconds = item["delay_seconds"] as? Int ?? 5
                rule = AdaptiveRule(
                    id: "ai-\(i)-\(Int(now))",
                    createdAt: now,
                    operation: operation,
                    condition: .cooldown(seconds: seconds),
                    action: .delay(seconds: seconds)
                )
            default:
                continue
            }
            rules.append(rule)
        }

        if !rules.isEmpty {
            _storeRules(rules)
            NSLog("[inf6-error-intelligence] AI generated %d adaptive rules", rules.count)
        }
    }

    private static func _storeRules(_ newRules: [AdaptiveRule]) {
        var existing = loadRules()
        let now = Date().timeIntervalSince1970
        existing.removeAll { $0.createdAt < now - 86400 }
        existing.append(contentsOf: newRules)
        if let data = try? JSONEncoder().encode(existing),
           let json = String(data: data, encoding: .utf8) {
            Inf6MetadataStore.put(domain: .settings, key: "error_intelligence_rules", json: json)
        }
    }

    // MARK: - Private

    private static func _classify(operation: String, context: String, error: Error) -> ErrorEvent {
        var httpStatus: Int?
        var apiCode: String?
        var errorType = "unknown"

        if let oaiErr = error as? OpenAIError {
            switch oaiErr {
            case .httpError(let status, let apiError, _, _):
                httpStatus = status
                apiCode = apiError?.code
                errorType = apiError?.type ?? "http_\(status)"
            case .transport:
                errorType = "network"
            case .cancelled:
                errorType = "cancelled"
            case .missingOutputText:
                errorType = "empty_response"
            default:
                errorType = "openai_other"
            }
        } else if let drillError = error as? Inf6EshikakuDrillPipeline.DrillPipelineError {
            errorType = drillError.report.kind.rawValue
            apiCode = drillError.report.operation
        }

        return ErrorEvent(
            timestamp: Date().timeIntervalSince1970,
            operation: operation,
            context: context,
            errorType: errorType,
            errorMessage: String(error.localizedDescription.prefix(200)),
            httpStatus: httpStatus,
            apiErrorCode: apiCode
        )
    }

    private static func _buildErrorSummary(_ errors: [ErrorEvent]) -> String {
        var groups: [String: (count: Int, sample: ErrorEvent)] = [:]
        for e in errors {
            let key = "\(e.operation)|\(e.errorType)|\(e.apiErrorCode ?? "")"
            if let existing = groups[key] {
                groups[key] = (existing.count + 1, e)
            } else {
                groups[key] = (1, e)
            }
        }

        return groups.map { (_, value) in
            let e = value.sample
            return "[\(value.count)回] op=\(e.operation) type=\(e.errorType) code=\(e.apiErrorCode ?? "nil") status=\(e.httpStatus.map(String.init) ?? "nil") ctx=\(e.context.prefix(50))"
        }.joined(separator: "\n")
    }

    private static func _formatDate(_ ts: Double) -> String {
        let date = Date(timeIntervalSince1970: ts)
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }

    // MARK: - Cleanup

    static func clearExpiredRules() {
        var rules = loadRules()
        let now = Date().timeIntervalSince1970
        let before = rules.count
        rules.removeAll { rule in
            if case .disable(let until) = rule.action, until < now { return true }
            return rule.createdAt < now - 86400
        }
        if rules.count != before {
            if let data = try? JSONEncoder().encode(rules),
               let json = String(data: data, encoding: .utf8) {
                Inf6MetadataStore.put(domain: .settings, key: "error_intelligence_rules", json: json)
            }
        }
    }
}
