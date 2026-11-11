import Foundation

// MARK: - Knowledge Data Store

enum Inf6KnowledgeDataStore {

    // MARK: - Path resolution

    static func familyDirectory(for sourceFamily: String) -> URL {
        let dir = Inf6Storage.homeDirectory()
            .appendingPathComponent("knowledge", isDirectory: true)
            .appendingPathComponent(sourceFamily, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func sharedDirectory() -> URL {
        let dir = Inf6Storage.homeDirectory()
            .appendingPathComponent("knowledge", isDirectory: true)
            .appendingPathComponent("_shared", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Per-family files

    static func syllabusURL(for sourceFamily: String) -> URL {
        familyDirectory(for: sourceFamily).appendingPathComponent("syllabus.yaml")
    }

    static func questionPatternsURL(for sourceFamily: String) -> URL {
        familyDirectory(for: sourceFamily).appendingPathComponent("question_patterns.json")
    }

    static func forecastURL(for sourceFamily: String) -> URL {
        familyDirectory(for: sourceFamily).appendingPathComponent("forecast.json")
    }

    static func schoolsURL(for sourceFamily: String) -> URL {
        familyDirectory(for: sourceFamily).appendingPathComponent("schools.yaml")
    }

    static func promptsURL(for sourceFamily: String) -> URL {
        familyDirectory(for: sourceFamily).appendingPathComponent("prompts.json")
    }

    // MARK: - Shared files

    static func sharedPromptRegistryURL() -> URL {
        sharedDirectory().appendingPathComponent("prompt_registry.json")
    }

    // MARK: - Seed management

    private static let _seedVersionKey = "inf6_knowledge_seed_versions"

    static func ensureSeeded(sourceFamily: String, fileName: String, bundleResource: String, bundleExtension: String) {
        let destURL: URL
        switch fileName {
        case "syllabus.yaml":           destURL = syllabusURL(for: sourceFamily)
        case "question_patterns.json":  destURL = questionPatternsURL(for: sourceFamily)
        case "forecast.json":           destURL = forecastURL(for: sourceFamily)
        case "schools.yaml":            destURL = schoolsURL(for: sourceFamily)
        case "prompts.json":            destURL = promptsURL(for: sourceFamily)
        default:                        destURL = familyDirectory(for: sourceFamily).appendingPathComponent(fileName)
        }
        _seedIfNeeded(destURL: destURL, bundleResource: bundleResource, bundleExtension: bundleExtension)
    }

    static func ensureSharedSeeded(fileName: String, bundleResource: String, bundleExtension: String) {
        let destURL: URL
        switch fileName {
        case "prompt_registry.json":    destURL = sharedPromptRegistryURL()
        default:                        destURL = sharedDirectory().appendingPathComponent(fileName)
        }
        _seedIfNeeded(destURL: destURL, bundleResource: bundleResource, bundleExtension: bundleExtension)
    }

    private static func _seedIfNeeded(destURL: URL, bundleResource: String, bundleExtension: String) {
        guard let bundleURL = Bundle.main.url(forResource: bundleResource, withExtension: bundleExtension) else {
            print("[KnowledgeDataStore] seed not found in bundle: \(bundleResource).\(bundleExtension)")
            return
        }
        if FileManager.default.fileExists(atPath: destURL.path) {
            guard bundleResource == "gkentei_syllabus_seed" else { return }
            guard
                let existing = try? String(contentsOf: destURL, encoding: .utf8),
                let bundled = try? String(contentsOf: bundleURL, encoding: .utf8)
            else { return }
            let existingIsIncomplete = _yamlOutlineHasMissingTitleEN(existing)
            if existingIsIncomplete && existing != bundled {
                do {
                    try FileManager.default.removeItem(at: destURL)
                    try FileManager.default.copyItem(at: bundleURL, to: destURL)
                    print("[KnowledgeDataStore] refreshed seed: \(destURL.lastPathComponent)")
                } catch {
                    print("[KnowledgeDataStore] seed refresh failed: \(error)")
                }
            }
            return
        }
        do {
            try FileManager.default.copyItem(at: bundleURL, to: destURL)
            print("[KnowledgeDataStore] seeded: \(destURL.lastPathComponent)")
        } catch {
            print("[KnowledgeDataStore] seed copy failed: \(error)")
        }
    }

    private static func _yamlOutlineHasMissingTitleEN(_ yaml: String) -> Bool {
        let parts = yaml.components(separatedBy: "\n  - key:")
        guard parts.count > 1 else { return true }
        for part in parts.dropFirst() {
            let block = "key:" + part
            if block.contains("\n    title:") && !block.contains("\n    title_en:") {
                return true
            }
        }
        return false
    }

    // MARK: - Bootstrap

    static func bootstrapAll() {
        let manifests = Inf6LearningFamilyManifestStore.loadAll()
        for manifest in manifests {
            bootstrap(manifest: manifest)
        }
        ensureSharedSeeded(fileName: "prompt_registry.json", bundleResource: "prompt_registry", bundleExtension: "json")
    }

    static func reconcileEshikakuPaperLinkedStructure() throws {
        guard let manifest = Inf6LearningFamilyManifestStore.loadCurrentSyllabusDomains()
            .first(where: { $0.sourceFamily == "jdla_eshikaku" })
        else {
            throw NSError(
                domain: "Inf6KnowledgeDataStore",
                code: 20,
                userInfo: [NSLocalizedDescriptionKey: "Current E資格 manifest is missing."]
            )
        }

        let outlineItems = try Inf6SyllabusConceptSetSynchronizer.currentOutlineItemsForPaperSearch(for: manifest)
        guard !outlineItems.isEmpty else {
            throw NSError(
                domain: "Inf6KnowledgeDataStore",
                code: 21,
                userInfo: [NSLocalizedDescriptionKey: "Current E資格 outline is empty."]
            )
        }

        Inf6KnowledgeDomainStructureStore.invalidateCache()
        let paperStore = Inf6CorePaperStore.shared
        let versionIDs = try _knowledgeStructureVersionIDsToReconcile(for: manifest)
        for versionID in versionIDs {
            _ = try Inf6KnowledgeDomainStructureStore.loadOrSeed(
                manifest: manifest,
                syllabusVersionID: versionID,
                domainTitleJa: manifest.displayNameJa,
                outlineItems: outlineItems,
                paperStore: paperStore,
                rebuildSyllabusNodes: true
            )
        }
        _ = try Inf6KnowledgeDomainStructureStore.reconcileStoredPaperLinks(
            manifest: manifest,
            paperStore: paperStore
        )
        for versionID in versionIDs {
            try Inf6KnowledgeDomainStructureStore.assertStoredPaperLinkCoverage(
                manifest: manifest,
                syllabusVersionID: versionID,
                paperStore: paperStore
            )
        }
        Inf6KnowledgeDomainStructureStore.invalidateCache()
    }

    private static func _knowledgeStructureVersionIDsToReconcile(for manifest: Inf6LearningFamilyManifest) throws -> [String] {
        let resolved = try resolvedKnowledgeStructureVersionID(for: manifest)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty else {
            throw NSError(
                domain: "Inf6KnowledgeDataStore",
                code: 22,
                userInfo: [NSLocalizedDescriptionKey: "Current syllabus version is empty: \(manifest.sourceFamily)"]
            )
        }
        return [resolved]
    }

    static func resolvedKnowledgeStructureVersionID(for manifest: Inf6LearningFamilyManifest) throws -> String {
        if let examName = _examName(for: manifest),
           let info = Inf6SyllabusUpdateChecker.shared.examScheduleInfo(for: examName) {
            let versionID = info.preferredKnowledgeStructureID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !versionID.isEmpty { return versionID }
        }
        throw NSError(
            domain: "Inf6KnowledgeDataStore",
            code: 23,
            userInfo: [NSLocalizedDescriptionKey: "Current syllabus version is not resolved: \(manifest.sourceFamily)"]
        )
    }

    private static func _examName(for manifest: Inf6LearningFamilyManifest) -> String? {
        switch manifest.familyID {
        case "e-shikaku": return "E資格"
        case "g-kentei": return "G検定"
        case "ai-102": return "AI-102"
        case "ai-103": return "AI-103"
        default: return nil
        }
    }

    static func bootstrap(manifest: Inf6LearningFamilyManifest) {
        let sf = manifest.sourceFamily

        _seedSyllabus(manifest: manifest)
        _seedQuestionPatterns(manifest: manifest)
        _seedForecast(manifest: manifest)
        _seedSchools(sf: sf)
    }

    private static func _seedSyllabus(manifest: Inf6LearningFamilyManifest) {
        let sf = manifest.sourceFamily
        let mapping: [(String, String)] = [
            ("jdla_gkentei",    "gkentei_syllabus_seed"),
            ("jdla_eshikaku",   "deeplearningJA"),
        ]
        for (family, resource) in mapping where sf == family {
            ensureSeeded(sourceFamily: sf, fileName: "syllabus.yaml", bundleResource: resource, bundleExtension: "yaml")
        }
    }

    private static func _seedQuestionPatterns(manifest: Inf6LearningFamilyManifest) {
        let sf = manifest.sourceFamily
        let mapping: [(String, String)] = [
            ("microsoft_ai_102", "azure_ai_question_pattern_library_v1"),
            ("jdla_gkentei",     "jdla_gkentei_question_pattern_library_v1"),
        ]
        for (family, resource) in mapping where sf == family {
            ensureSeeded(sourceFamily: sf, fileName: "question_patterns.json", bundleResource: resource, bundleExtension: "json")
        }
    }

    private static func _seedForecast(manifest: Inf6LearningFamilyManifest) {
        let sf = manifest.sourceFamily
        let resource = "\(sf)_forecast_authoring_v1"
        if Bundle.main.url(forResource: resource, withExtension: "json") != nil {
            ensureSeeded(sourceFamily: sf, fileName: "forecast.json", bundleResource: resource, bundleExtension: "json")
        }
    }

    private static func _seedSchools(sf: String) {
        let mapping: [(String, String)] = [
            ("jdla_eshikaku", "schools_jdla.default"),
            ("jdla_gkentei",  "schools_jdla.default"),
        ]
        for (family, resource) in mapping where sf == family {
            ensureSeeded(sourceFamily: sf, fileName: "schools.yaml", bundleResource: resource, bundleExtension: "yaml")
        }
    }

    // MARK: - Load helpers

    static func loadData(at url: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func loadString(at url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
