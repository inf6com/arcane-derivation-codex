import Foundation
import SwiftUI

enum Inf6PromptGovernanceError: LocalizedError {
    case registryNotFound
    case registryDecodeFailed(String)
    case promptNotFound(id: String, version: Int)
    case invalidFormat(id: String, version: Int, expected: String, actual: String)
    case templateMissing(id: String, version: Int)
    case unresolvedPlaceholder(id: String, version: Int, name: String)

    var errorDescription: String? {
        switch self {
        case .registryNotFound:
            return "Prompt registry JSON が見つかりません。"
        case .registryDecodeFailed(let detail):
            return "Prompt registry JSON の読み込みに失敗しました: \(detail)"
        case .promptNotFound(let id, let version):
            return "Prompt が未登録です: id=\(id), version=\(version)"
        case .invalidFormat(let id, let version, let expected, let actual):
            return "Prompt format が不一致です: id=\(id), version=\(version), expected=\(expected), actual=\(actual)"
        case .templateMissing(let id, let version):
            return "Prompt template が不足しています: id=\(id), version=\(version)"
        case .unresolvedPlaceholder(let id, let version, let name):
            return "Prompt 変数が不足しています: id=\(id), version=\(version), variable=\(name)"
        }
    }
}

enum Inf6PromptFormat: String, Codable {
    case singlePrompt = "single_prompt"
    case systemUser = "system_user"
}

struct Inf6ResolvedSystemUserPrompt {
    let systemInstruction: String
    let userPrompt: String
}

struct Inf6PromptRef {
    let id: String
    let version: Int
}

struct Inf6PromptSummary: Identifiable, Hashable {
    let id: String
    let version: Int
    let format: Inf6PromptFormat
}

struct Inf6PromptFeedback: Codable, Identifiable, Hashable {
    let id: UUID
    let promptID: String
    let promptVersion: Int
    let rating: Int
    let comment: String
    let createdAt: TimeInterval
}

enum Inf6PromptCatalog {
    // Commented explain (selection + comment panel)
    static let commentedExplainJaLocal = Inf6PromptRef(id: "inline.commented_explain.ja.local", version: 5)
    static let commentedExplainJaWeb = Inf6PromptRef(id: "inline.commented_explain.ja.web", version: 9)
    static let commentedExplainEnLocal = Inf6PromptRef(id: "inline.commented_explain.en.local", version: 5)
    static let commentedExplainEnWeb = Inf6PromptRef(id: "inline.commented_explain.en.web", version: 9)

    // Selection explain
    static let selectionExplainJa = Inf6PromptRef(id: "inline.selection_explain.ja", version: 3)
    static let selectionExplainEn = Inf6PromptRef(id: "inline.selection_explain.en", version: 3)

    // Page explain
    static let pageExplainJa = Inf6PromptRef(id: "inline.page_explain.ja", version: 3)
    static let pageExplainEn = Inf6PromptRef(id: "inline.page_explain.en", version: 3)

    // Term explain
    static let termExplainJaLocal = Inf6PromptRef(id: "inline.term_explain.ja.local", version: 1)
    static let termExplainJaWeb = Inf6PromptRef(id: "inline.term_explain.ja.web", version: 3)
    static let termExplainEnLocal = Inf6PromptRef(id: "inline.term_explain.en.local", version: 1)
    static let termExplainEnWeb = Inf6PromptRef(id: "inline.term_explain.en.web", version: 3)

    // Ask card / note / quiz
    static let askCardExplainJa = Inf6PromptRef(id: "inline.ask_card_explain.ja", version: 2)
    static let askCardExplainEn = Inf6PromptRef(id: "inline.ask_card_explain.en", version: 2)
    static let askNoteSheetJa = Inf6PromptRef(id: "inline.ask_note_sheet.ja", version: 1)
    static let askNoteSheetEn = Inf6PromptRef(id: "inline.ask_note_sheet.en", version: 1)
    static let quizPromptBridgeJa = Inf6PromptRef(id: "inline.quiz_prompt_bridge.ja", version: 1)
    static let quizPromptBridgeEn = Inf6PromptRef(id: "inline.quiz_prompt_bridge.en", version: 1)

    // Assets / abstract / quoted evidence bridge
    static let assetsPromptBridgeJa = Inf6PromptRef(id: "inline.assets_prompt_bridge.ja", version: 1)
    static let assetsPromptBridgeEn = Inf6PromptRef(id: "inline.assets_prompt_bridge.en", version: 1)
    static let quotedEvidenceBridgeJa = Inf6PromptRef(id: "library.quoted_evidence_bridge.ja", version: 1)
    static let quotedEvidenceBridgeEn = Inf6PromptRef(id: "library.quoted_evidence_bridge.en", version: 1)

    // Math mini card
    static let mathMiniExplainJa = Inf6PromptRef(id: "inline.math_mini_explain.ja", version: 1)
    static let mathMiniExplainEn = Inf6PromptRef(id: "inline.math_mini_explain.en", version: 1)

    // Syllabus / paper creation
    static let paperCreatePDFTitle = Inf6PromptRef(id: "papercreate.pdf_title_from_cover", version: 1)
    static let paperCreateOutlineGenerate = Inf6PromptRef(id: "papercreate.generate_outline", version: 1)

    // Taxonomy
    static let taxonomyGeneratePapersYAML = Inf6PromptRef(id: "taxonomy.generate_papers_yaml", version: 1)

    // Auto papers clustering
    static let autoPapersClusterLabel = Inf6PromptRef(id: "autopapers.cluster_label", version: 1)
    static let autoPapersFeatureKeywords = Inf6PromptRef(id: "autopapers.feature_keywords", version: 1)
    static let autoPapersCompactClusterLabel = Inf6PromptRef(id: "autopapers.compact_cluster_label", version: 1)

    // Paper chat
    static let paperChatProfileKey = Inf6PromptRef(id: "paperchat.profile_key", version: 1)
    static let paperChatSurveyClusterLabel = Inf6PromptRef(id: "paperchat.survey_cluster_label", version: 1)
    static let paperChatSurveyFeatureKeywords = Inf6PromptRef(id: "paperchat.survey_feature_keywords", version: 1)

    // Syllabus detail
    static let syllabusDetailGKenteiJa = Inf6PromptRef(id: "syllabusdetail.gkentei_item_html.ja", version: 1)
    static let syllabusDetailGKenteiEn = Inf6PromptRef(id: "syllabusdetail.gkentei_item_html.en", version: 1)
    static let syllabusDetailMicrosoftLearnQualification = Inf6PromptRef(id: "syllabusdetail.microsoftlearn_qualification_html", version: 1)
}

private struct _Inf6PromptRegistryFile: Codable {
    let schemaVersion: Int
    let prompts: [_Inf6PromptRecord]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case prompts
    }
}

private struct _Inf6PromptRecord: Codable {
    let id: String
    let version: Int
    let format: Inf6PromptFormat
    let promptTemplate: String?
    let systemTemplate: String?
    let userTemplate: String?

    enum CodingKeys: String, CodingKey {
        case id
        case version
        case format
        case promptTemplate = "prompt_template"
        case systemTemplate = "system_template"
        case userTemplate = "user_template"
    }
}

enum Inf6PromptGovernance {
    private static let _registryFileName = "prompt_registry"
    private static let _registryFileExtension = "json"

    private static let _placeholderRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\\{\\{([a-zA-Z0-9_]+)\\}\\}",
        options: []
    )

    private static var _cachedRegistryByKey: [String: _Inf6PromptRecord]?

    private static let _customizationKey = "_customizations"
    private static let _feedbackKey = "_feedback"

    private struct _Customization: Codable, Hashable {
        var promptID: String
        var version: Int
        var additionalInstruction: String
        var enabled: Bool
        var updatedAt: TimeInterval
    }

    static func promptSummaries() throws -> [Inf6PromptSummary] {
        try _registry().values
            .map { Inf6PromptSummary(id: $0.id, version: $0.version, format: $0.format) }
            .sorted { ($0.id, $0.version) < ($1.id, $1.version) }
    }

    static func customization(id: String, version: Int) -> String {
        guard let json = Inf6MetadataStore.get(domain: .promptRegistry, key: _customizationKey),
              let values = try? JSONDecoder().decode([_Customization].self, from: Data(json.utf8)) else { return "" }
        return values.first { $0.promptID == id && $0.version == version && $0.enabled }?.additionalInstruction ?? ""
    }

    static func globalAdditionalInstruction() -> String {
        customization(id: "*", version: 1)
    }

    static func saveCustomization(id: String, version: Int, additionalInstruction: String, enabled: Bool) {
        let trimmed = additionalInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingJSON = Inf6MetadataStore.get(domain: .promptRegistry, key: _customizationKey)
        var values = (existingJSON.flatMap { try? JSONDecoder().decode([_Customization].self, from: Data($0.utf8)) }) ?? []
        values.removeAll { $0.promptID == id && $0.version == version }
        if !trimmed.isEmpty || enabled {
            values.append(_Customization(promptID: id, version: version, additionalInstruction: trimmed, enabled: enabled, updatedAt: Date().timeIntervalSince1970))
        }
        guard let data = try? JSONEncoder().encode(values), let json = String(data: data, encoding: .utf8) else { return }
        Inf6MetadataStore.put(domain: .promptRegistry, key: _customizationKey, json: json)
    }

    static func saveFeedback(promptID: String, version: Int, rating: Int, comment: String) {
        let existingJSON = Inf6MetadataStore.get(domain: .promptFeedback, key: _feedbackKey)
        var values = (existingJSON.flatMap { try? JSONDecoder().decode([Inf6PromptFeedback].self, from: Data($0.utf8)) }) ?? []
        values.append(Inf6PromptFeedback(id: UUID(), promptID: promptID, promptVersion: version, rating: min(max(rating, 1), 5), comment: comment.trimmingCharacters(in: .whitespacesAndNewlines), createdAt: Date().timeIntervalSince1970))
        guard let data = try? JSONEncoder().encode(values), let json = String(data: data, encoding: .utf8) else { return }
        Inf6MetadataStore.put(domain: .promptFeedback, key: _feedbackKey, json: json)
    }

    private static func _registry() throws -> [String: _Inf6PromptRecord] {
        if let cached = _cachedRegistryByKey {
            return cached
        }

        // 1. metadata file store
        if let json = Inf6MetadataStore.get(domain: .promptRegistry, key: "_registry"),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(_Inf6PromptRegistryFile.self, from: data) {
            let byKey = _buildRegistryIndex(decoded)
            _cachedRegistryByKey = byKey
            return byKey
        }

        guard let url = Bundle.main.url(forResource: _registryFileName, withExtension: _registryFileExtension) else {
            throw Inf6PromptGovernanceError.registryNotFound
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Inf6PromptGovernanceError.registryDecodeFailed(error.localizedDescription)
        }

        let decoded: _Inf6PromptRegistryFile
        do {
            decoded = try JSONDecoder().decode(_Inf6PromptRegistryFile.self, from: data)
        } catch {
            throw Inf6PromptGovernanceError.registryDecodeFailed(error.localizedDescription)
        }

        // Migrate to metadata file store
        if let jsonStr = String(data: data, encoding: .utf8) {
            Inf6MetadataStore.put(domain: .promptRegistry, key: "_registry", json: jsonStr)
        }

        let byKey = _buildRegistryIndex(decoded)
        _cachedRegistryByKey = byKey
        return byKey
    }

    private static func _buildRegistryIndex(_ decoded: _Inf6PromptRegistryFile) -> [String: _Inf6PromptRecord] {
        var byKey: [String: _Inf6PromptRecord] = [:]
        byKey.reserveCapacity(decoded.prompts.count)
        for p in decoded.prompts {
            let key = _registryKey(id: p.id, version: p.version)
            byKey[key] = p
        }
        return byKey
    }

    private static func _registryKey(id: String, version: Int) -> String {
        "\(id)#\(version)"
    }

    private static func _findPrompt(id: String, version: Int) throws -> _Inf6PromptRecord {
        let all = try _registry()
        let key = _registryKey(id: id, version: version)
        guard let rec = all[key] else {
            throw Inf6PromptGovernanceError.promptNotFound(id: id, version: version)
        }
        return rec
    }

    private static func _renderTemplate(
        _ template: String,
        variables: [String: String],
        id: String,
        version: Int
    ) throws -> String {
        guard let re = _placeholderRegex else {
            return template
        }

        let fullRange = NSRange(template.startIndex..<template.endIndex, in: template)
        let matches = re.matches(in: template, options: [], range: fullRange)
        if matches.isEmpty {
            return template
        }

        var rendered = template
        for m in matches.reversed() {
            guard m.numberOfRanges >= 2,
                  let keyRange = Range(m.range(at: 1), in: template) else { continue }
            let name = String(template[keyRange])
            guard let value = variables[name] else {
                throw Inf6PromptGovernanceError.unresolvedPlaceholder(id: id, version: version, name: name)
            }
            guard let fullRange = Range(m.range(at: 0), in: rendered) else { continue }
            rendered.replaceSubrange(fullRange, with: value)
        }

        return rendered
    }

    static func renderSinglePrompt(
        ref: Inf6PromptRef,
        variables: [String: String]
    ) throws -> String {
        try renderSinglePrompt(id: ref.id, version: ref.version, variables: variables)
    }

    static func renderSystemUserPrompt(
        ref: Inf6PromptRef,
        variables: [String: String]
    ) throws -> Inf6ResolvedSystemUserPrompt {
        try renderSystemUserPrompt(id: ref.id, version: ref.version, variables: variables)
    }

    static func renderSinglePrompt(
        id: String,
        version: Int,
        variables: [String: String]
    ) throws -> String {
        let rec = try _findPrompt(id: id, version: version)
        guard rec.format == .singlePrompt else {
            throw Inf6PromptGovernanceError.invalidFormat(
                id: id,
                version: version,
                expected: Inf6PromptFormat.singlePrompt.rawValue,
                actual: rec.format.rawValue
            )
        }
        guard let template = rec.promptTemplate else {
            throw Inf6PromptGovernanceError.templateMissing(id: id, version: version)
        }
        var rendered = try _renderTemplate(template, variables: variables, id: id, version: version)
        let instruction = customization(id: id, version: version)
        if !instruction.isEmpty {
            rendered += "\n\n【ユーザー追加指示】\n\(instruction)"
        }
        return rendered
    }

    static func renderSystemUserPrompt(
        id: String,
        version: Int,
        variables: [String: String]
    ) throws -> Inf6ResolvedSystemUserPrompt {
        let rec = try _findPrompt(id: id, version: version)
        guard rec.format == .systemUser else {
            throw Inf6PromptGovernanceError.invalidFormat(
                id: id,
                version: version,
                expected: Inf6PromptFormat.systemUser.rawValue,
                actual: rec.format.rawValue
            )
        }
        guard let sysT = rec.systemTemplate, let userT = rec.userTemplate else {
            throw Inf6PromptGovernanceError.templateMissing(id: id, version: version)
        }
        let system = try _renderTemplate(sysT, variables: variables, id: id, version: version)
        var user = try _renderTemplate(userT, variables: variables, id: id, version: version)
        let instruction = customization(id: id, version: version)
        if !instruction.isEmpty {
            user += "\n\n【ユーザー追加指示】\n\(instruction)"
        }
        return Inf6ResolvedSystemUserPrompt(systemInstruction: system, userPrompt: user)
    }
}

struct Inf6PromptSettingsView: View {
    @State private var summaries: [Inf6PromptSummary] = []
    @State private var selected: Inf6PromptSummary?
    @State private var globalInstruction = ""
    @State private var instruction = ""
    @State private var feedback = ""
    @State private var rating = 3

    var body: some View {
        NavigationStack {
            List {
                Section("全Prompt共通のユーザー指示") {
                    TextEditor(text: $globalInstruction).frame(minHeight: 120)
                    Button("共通指示を保存") {
                        Inf6PromptGovernance.saveCustomization(id: "*", version: 1, additionalInstruction: globalInstruction, enabled: !globalInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section("集中管理Prompt") {
                    ForEach(summaries) { summary in
                        Button {
                            selected = summary
                            instruction = Inf6PromptGovernance.customization(id: summary.id, version: summary.version)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(summary.id).font(.body)
                                Text("v\(summary.version) / \(summary.format.rawValue)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let selected {
                    Section("ユーザーカスタマイズ") {
                        TextEditor(text: $instruction).frame(minHeight: 120)
                        Button("保存") {
                            Inf6PromptGovernance.saveCustomization(id: selected.id, version: selected.version, additionalInstruction: instruction, enabled: !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    Section("フィードバック") {
                        Picker("評価", selection: $rating) { ForEach(1...5, id: \.self) { Text("\($0)").tag($0) } }
                        TextField("生成結果へのコメント", text: $feedback, axis: .vertical)
                        Button("フィードバックを保存") {
                            Inf6PromptGovernance.saveFeedback(promptID: selected.id, version: selected.version, rating: rating, comment: feedback)
                            feedback = ""
                        }
                    }
                }
            }
            .navigationTitle("Prompt管理")
            .task {
                summaries = (try? Inf6PromptGovernance.promptSummaries()) ?? []
                globalInstruction = Inf6PromptGovernance.globalAdditionalInstruction()
            }
        }
    }
}
