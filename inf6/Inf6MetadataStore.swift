import CryptoKit
import Foundation

// MARK: - Unified Metadata File Store

/// Stores app metadata as one JSON file per logical record under the selected storage root.
/// `domain` maps to a directory and `key` maps to a percent-encoded file name.
enum Inf6MetadataStore {

    // MARK: - Domains

    enum Domain: String {
        case papers            = "papers"
        case paperProgress     = "paper_progress"
        case pdfRefs           = "pdf_refs"
        case notes             = "notes"
        case miniCards         = "mini_cards"
        case docEntities       = "doc_entities"
        case quiz              = "quiz"
        case mmaAtoms          = "mma_atoms"
        case mmaEdges          = "mma_edges"
        case mmaMastery        = "mma_mastery"
        case mmaAnswerLogs     = "mma_answer_logs"
        case mmaQuestions      = "mma_questions"
        case forecast          = "forecast"
        case questionPatterns  = "question_patterns"
        case trendSignals      = "trend_signals"
        case syllabus          = "syllabus"
        case knowledgeDomains  = "knowledge_domains"
        case promptRegistry    = "prompt_registry"
        case promptFeedback   = "prompt_feedback"
        case vectorIndex       = "vector_index"
        case chatHistory       = "chat_history"
        case assetsPipeline    = "assets_pipeline"
        case examSchedule      = "exam_schedule"
        case schools           = "schools"
        case generatedExplanations = "generated_explanations"
        case generatedQuizzes      = "generated_quizzes"
        case quizAttempts          = "quiz_attempts"
        case settings          = "settings"
        case canonicalConcepts = "canonical_concepts"
        case canonicalAliases  = "canonical_aliases"
        case knowledgeEvidence    = "knowledge_evidence"
        case knowledgeRelations   = "knowledge_relations"
        case knowledgeMemberships = "knowledge_memberships"
        case corpusSources     = "corpus_sources"
        case corpusConceptCandidates = "corpus_concept_candidates"
        case corpusConceptMentions   = "corpus_concept_mentions"
        case corpusConceptRelations  = "corpus_concept_relations"
        case conceptMetrics          = "concept_metrics"
        case syllabusPaperLinks      = "syllabus_paper_links"
        case drillAskNotes           = "drill_ask_notes"
        case drillSlideshowProgress  = "drill_slideshow_progress"
        case liveBPReactions         = "live_bp_reactions"
        case liveBPGeneratedExercises = "live_bp_generated_exercises"
        case syllabusImportanceScores = "syllabus_importance_scores"
    }

    private struct _Record: Codable {
        var key: String
        var json: String
        var updatedAt: TimeInterval
    }

    private static let _lock = NSRecursiveLock()
    private static let _encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private static let _decoder = JSONDecoder()

    private static var _allowedFileNameCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private struct _ListAllCache {
        let records: [(key: String, json: String)]
        let time: CFAbsoluteTime
    }
    private static var _listAllCache: [String: _ListAllCache] = [:]
    private static let _listAllCacheTTL: CFAbsoluteTime = 30

    private struct _ListByPrefixCache {
        let records: [(key: String, json: String)]
        let time: CFAbsoluteTime
    }
    private static var _listByPrefixCache: [String: _ListByPrefixCache] = [:]

    private static func _invalidateListCaches(domain: Domain) {
        _listAllCache.removeValue(forKey: domain.rawValue)
        _listByPrefixCache = _listByPrefixCache.filter { !$0.key.hasPrefix("\(domain.rawValue)|") }
    }

    static func invalidateCachesForRootChange() {
        _lock.lock()
        defer { _lock.unlock() }
        _listAllCache.removeAll()
        _listByPrefixCache.removeAll()
    }

    private struct _DiskSnapshot: Codable {
        var records: [_Record]
        var fileCount: Int
        var fileSignatures: [String: String]
    }

    private static func _snapshotURL(_ domain: Domain) -> URL {
        _domainURL(domain).appendingPathComponent(".inf6-index.json")
    }

    private static func _recordURLs(_ domain: Domain) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: _domainURL(domain),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls.filter {
            $0.pathExtension == "json" && $0.lastPathComponent != ".inf6-index.json"
        }
    }

    private static func _fileSignatures(for urls: [URL]) -> [String: String]? {
        var signatures: [String: String] = [:]
        signatures.reserveCapacity(urls.count)
        for url in urls {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let fileSize = attributes[.size] as? NSNumber,
                  let modificationDate = attributes[.modificationDate] as? Date else {
                return nil
            }
            signatures[url.lastPathComponent] = "\(fileSize.int64Value):\(modificationDate.timeIntervalSince1970)"
        }
        return signatures
    }

    private static func _saveSnapshot(
        _ domain: Domain,
        records: [_Record],
        fileSignatures: [String: String]
    ) {
        let snap = _DiskSnapshot(
            records: records,
            fileCount: fileSignatures.count,
            fileSignatures: fileSignatures
        )
        if let data = try? _encoder.encode(snap) {
            try? FileManager.default.createDirectory(
                at: _domainURL(domain),
                withIntermediateDirectories: true
            )
            try? data.write(to: _snapshotURL(domain), options: .atomic)
        }
    }

    private static func _loadSnapshot(_ domain: Domain, recordURLs: [URL]) -> [_Record]? {
        let url = _snapshotURL(domain)
        guard let data = try? Data(contentsOf: url),
              let snap = try? _decoder.decode(_DiskSnapshot.self, from: data),
              let signatures = _fileSignatures(for: recordURLs),
              snap.fileCount == recordURLs.count,
              snap.fileSignatures == signatures else { return nil }
        return snap.records
    }

    private static func _updateSnapshotAfterPut(_ domain: Domain, record: _Record) {
        let url = _snapshotURL(domain)
        guard let data = try? Data(contentsOf: url),
              var snapshot = try? _decoder.decode(_DiskSnapshot.self, from: data)
        else { return }
        if let index = snapshot.records.firstIndex(where: { $0.key == record.key }) {
            snapshot.records[index] = record
        } else {
            snapshot.records.append(record)
        }
        guard let fileSignatures = _fileSignatures(for: _recordURLs(domain)) else { return }
        _saveSnapshot(domain, records: snapshot.records, fileSignatures: fileSignatures)
    }

    private static func _updateSnapshotAfterDelete(_ domain: Domain, key: String) {
        let url = _snapshotURL(domain)
        guard let data = try? Data(contentsOf: url),
              var snapshot = try? _decoder.decode(_DiskSnapshot.self, from: data)
        else { return }
        snapshot.records.removeAll { $0.key == key }
        guard let fileSignatures = _fileSignatures(for: _recordURLs(domain)) else { return }
        _saveSnapshot(domain, records: snapshot.records, fileSignatures: fileSignatures)
    }

    // MARK: - Lifecycle

    static func close() {}

    // MARK: - CRUD

    @discardableResult
    static func put(domain: Domain, key: String, json: String) -> Bool {
        _lock.lock()
        defer { _lock.unlock() }

        _invalidateListCaches(domain: domain)
        let record = _Record(key: key, json: json, updatedAt: Date().timeIntervalSince1970)
        do {
            let url = _recordURL(domain: domain, key: key)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try _encoder.encode(record)
            try data.write(to: url, options: [.atomic])
            _updateSnapshotAfterPut(domain, record: record)
            return true
        } catch {
            NSLog("[Inf6MetadataStore] write failed for %@/%@: %@", domain.rawValue, key, error.localizedDescription)
            return false
        }
    }

    static func get(domain: Domain, key: String) -> String? {
        _lock.lock()
        defer { _lock.unlock() }

        let url = _recordURL(domain: domain, key: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let record = try _decoder.decode(_Record.self, from: Data(contentsOf: url))
            guard record.key == key else {
                NSLog("[Inf6MetadataStore] key mismatch at %@, returning nil", url.path)
                return nil
            }
            return record.json
        } catch {
            NSLog("[Inf6MetadataStore] read failed for %@/%@: %@", domain.rawValue, key, error.localizedDescription)
            return nil
        }
    }

    static func delete(domain: Domain, key: String) {
        _lock.lock()
        defer { _lock.unlock() }

        _invalidateListCaches(domain: domain)
        let url = _recordURL(domain: domain, key: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
            _updateSnapshotAfterDelete(domain, key: key)
        } catch {
            preconditionFailure("[Inf6MetadataStore] delete failed for \(domain.rawValue)/\(key): \(error.localizedDescription)")
        }
    }

    static func listKeys(domain: Domain) -> [String] {
        listAll(domain: domain).map(\.key).sorted()
    }

    static func listAll(domain: Domain) -> [(key: String, json: String)] {
        _lock.lock()
        let cacheKey = domain.rawValue
        if let cached = _listAllCache[cacheKey],
           CFAbsoluteTimeGetCurrent() - cached.time < _listAllCacheTTL {
            _lock.unlock()
            return cached.records
        }
        _lock.unlock()

        let jsonURLs = _recordURLs(domain)

        if let cached = _loadSnapshot(domain, recordURLs: jsonURLs) {
            let result = cached
                .sorted { $0.updatedAt > $1.updatedAt }
                .map { ($0.key, $0.json) }
            _lock.lock()
            _listAllCache[cacheKey] = _ListAllCache(records: result, time: CFAbsoluteTimeGetCurrent())
            _lock.unlock()
            NSLog("[Inf6MetadataStore] listAll %@ from disk snapshot (%d records)", domain.rawValue, result.count)
            return result
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        let count = jsonURLs.count
        guard count > 0 else { return [] }
        let box = UnsafeMutablePointer<_Record?>.allocate(capacity: count)
        box.initialize(repeating: nil, count: count)

        DispatchQueue.concurrentPerform(iterations: count) { i in
            let url = jsonURLs[i]
            do {
                box[i] = try JSONDecoder().decode(_Record.self, from: Data(contentsOf: url))
            } catch {
                NSLog("[Inf6MetadataStore] skipping corrupt file at %@: %@", url.path, error.localizedDescription)
            }
        }

        var records: [_Record] = []
        records.reserveCapacity(count)
        for i in 0..<count {
            if let r = box[i] { records.append(r) }
        }
        box.deinitialize(count: count)
        box.deallocate()

        let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        NSLog("[Inf6MetadataStore] listAll %@ read %d files in %.1fms", domain.rawValue, count, elapsed)
        let result = records
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { ($0.key, $0.json) }
        _lock.lock()
        _listAllCache[cacheKey] = _ListAllCache(records: result, time: CFAbsoluteTimeGetCurrent())
        _lock.unlock()
        if let fileSignatures = _fileSignatures(for: jsonURLs) {
            _saveSnapshot(domain, records: records, fileSignatures: fileSignatures)
        }
        return result
    }

    static func listAllStrict(domain: Domain) throws -> [(key: String, json: String)] {
        let directory = _domainURL(domain)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" && $0.lastPathComponent != ".inf6-index.json" }
        } catch {
            throw NSError(domain: "Inf6MetadataStore", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "保存一覧を読み込めません (\(domain.rawValue)): \(error.localizedDescription)"
            ])
        }
        return try urls.map { url in
            let record: _Record
            do {
                record = try _decoder.decode(_Record.self, from: Data(contentsOf: url))
            } catch {
                throw NSError(domain: "Inf6MetadataStore", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "保存レコードを読み込めません (\(url.lastPathComponent)): \(error.localizedDescription)"
                ])
            }
            guard _recordURL(domain: domain, key: record.key).standardizedFileURL == url.standardizedFileURL else {
                throw NSError(domain: "Inf6MetadataStore", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "保存レコードのキーとファイル名が一致しません (\(url.lastPathComponent))"
                ])
            }
            return (record.key, record.json)
        }
    }

    static func count(domain: Domain) -> Int {
        listAll(domain: domain).count
    }

    // MARK: - Codable helpers

    @discardableResult
    static func putCodable<T: Encodable>(_ value: T, domain: Domain, key: String) -> Bool {
        do {
            let data = try JSONEncoder().encode(value)
            guard let json = String(data: data, encoding: .utf8) else {
                NSLog("[Inf6MetadataStore] UTF-8 conversion failed for %@/%@", domain.rawValue, key)
                return false
            }
            return put(domain: domain, key: key, json: json)
        } catch {
            NSLog("[Inf6MetadataStore] encode failed for %@/%@: %@", domain.rawValue, key, error.localizedDescription)
            return false
        }
    }

    static func getCodable<T: Decodable>(_ type: T.Type, domain: Domain, key: String) -> T? {
        guard let json = get(domain: domain, key: key),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func listAllCodable<T: Decodable>(_ type: T.Type, domain: Domain) -> [(key: String, value: T)] {
        let records = listAll(domain: domain)
        guard !records.isEmpty else { return [] }

        let values = UnsafeMutablePointer<T?>.allocate(capacity: records.count)
        values.initialize(repeating: nil, count: records.count)
        DispatchQueue.concurrentPerform(iterations: records.count) { index in
            let pair = records[index]
            guard let data = pair.json.data(using: .utf8) else { return }
            values[index] = try? JSONDecoder().decode(type, from: data)
        }

        var result: [(key: String, value: T)] = []
        result.reserveCapacity(records.count)
        for index in records.indices {
            if let value = values[index] {
                result.append((records[index].key, value))
            }
        }
        values.deinitialize(count: records.count)
        values.deallocate()
        return result
    }

    // MARK: - Prefix query

    static func listByPrefix(domain: Domain, prefix: String) -> [(key: String, json: String)] {
        _lock.lock()
        let cacheKey = "\(domain.rawValue)|\(prefix)"
        if let cached = _listByPrefixCache[cacheKey],
           CFAbsoluteTimeGetCurrent() - cached.time < _listAllCacheTTL {
            _lock.unlock()
            return cached.records
        }
        _lock.unlock()

        guard !prefix.isEmpty else {
            preconditionFailure("[Inf6MetadataStore] invalid prefix")
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        let result = listAll(domain: domain)
            .filter { $0.key.hasPrefix(prefix) }
            .sorted { $0.key < $1.key }

        _lock.lock()
        _listByPrefixCache[cacheKey] = _ListByPrefixCache(records: result, time: CFAbsoluteTimeGetCurrent())
        _lock.unlock()

        let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        NSLog("[Inf6MetadataStore] listByPrefix %@/%@ filtered %d records in %.1fms", domain.rawValue, prefix, result.count, elapsed)
        return result
    }

    // MARK: - Batch operations

    static func putBatch(domain: Domain, items: [(key: String, json: String)]) {
        guard !items.isEmpty else { return }
        _lock.lock()
        defer { _lock.unlock() }
        for item in items {
            put(domain: domain, key: item.key, json: item.json)
        }
    }

    static func deleteByPrefix(domain: Domain, prefix: String) {
        for item in listByPrefix(domain: domain, prefix: prefix) {
            delete(domain: domain, key: item.key)
        }
    }

    // MARK: - Migration from JSON files

    static func migrateJSONFile<T: Codable>(
        _ type: T.Type,
        from url: URL,
        domain: Domain,
        key: String,
        deleteAfter: Bool = false
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(type, from: data) else {
            return false
        }
        putCodable(value, domain: domain, key: key)
        if deleteAfter {
            try? FileManager.default.removeItem(at: url)
        }
        return true
    }

    // MARK: - Bootstrap migration

    private static let _migrationDoneKey = "inf6_metadata_file_store_migrated_v1"

    static func migrateIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: _migrationDoneKey) else { return }
        let t0 = CFAbsoluteTimeGetCurrent()

        _migrateNotes()
        _migrateDocEntities()
        _migratePromptRegistry()
        _migrateForecastAndPatterns()
        _migrateQuizAndMastery()

        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        print("[Inf6MetadataStore] Migration complete in \(String(format: "%.2f", elapsed))s")
        UserDefaults.standard.set(true, forKey: _migrationDoneKey)
    }

    private static func _migrateNotes() {
        guard count(domain: .notes) == 0 else { return }
        let root = Inf6DataRoot.url()
        let cardsDir = (Inf6KnowledgeCardsPaths.rootDirectoryURL() ?? root.appendingPathComponent("inf6_knowledge_cards", isDirectory: true))
        guard let pdfDirs = try? FileManager.default.contentsOfDirectory(at: cardsDir, includingPropertiesForKeys: nil) else { return }
        for pdfDir in pdfDirs where pdfDir.hasDirectoryPath {
            let pdfKey = pdfDir.lastPathComponent
            guard let files = try? FileManager.default.contentsOfDirectory(at: pdfDir, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.lastPathComponent.hasPrefix("p") && file.lastPathComponent.hasSuffix(".notes.json") {
                let pageStr = file.lastPathComponent
                    .replacingOccurrences(of: ".notes.json", with: "")
                    .replacingOccurrences(of: "p", with: "")
                let compositeKey = "\(pdfKey):\(pageStr)"
                if let data = try? Data(contentsOf: file), let json = String(data: data, encoding: .utf8) {
                    put(domain: .notes, key: compositeKey, json: json)
                }
            }
        }
    }

    private static func _migrateDocEntities() {
        guard count(domain: .docEntities) == 0 else { return }
        let root = Inf6DataRoot.url()
        let cardsDir = (Inf6KnowledgeCardsPaths.rootDirectoryURL() ?? root.appendingPathComponent("inf6_knowledge_cards", isDirectory: true))
        guard let pdfDirs = try? FileManager.default.contentsOfDirectory(at: cardsDir, includingPropertiesForKeys: nil) else { return }
        for pdfDir in pdfDirs where pdfDir.hasDirectoryPath {
            let pdfKey = pdfDir.lastPathComponent
            let entFile = pdfDir.appendingPathComponent("\(pdfKey).entities.json")
            if let data = try? Data(contentsOf: entFile), let json = String(data: data, encoding: .utf8) {
                put(domain: .docEntities, key: pdfKey, json: json)
            }
        }
    }

    private static func _migratePromptRegistry() {
        guard count(domain: .promptRegistry) == 0 else { return }
        guard let url = Bundle.main.url(forResource: "prompt_registry", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = String(data: data, encoding: .utf8) else { return }
        put(domain: .promptRegistry, key: "_registry", json: json)
    }

    private static func _migrateForecastAndPatterns() {
        let manifests = Inf6LearningFamilyManifestStore.loadAll()
        for manifest in manifests {
            let sf = manifest.sourceFamily
            if count(domain: .forecast) == 0 || get(domain: .forecast, key: sf) == nil {
                let kdURL = Inf6KnowledgeDataStore.forecastURL(for: sf)
                if let data = try? Data(contentsOf: kdURL), let json = String(data: data, encoding: .utf8) {
                    put(domain: .forecast, key: sf, json: json)
                }
            }
            if count(domain: .questionPatterns) == 0 || get(domain: .questionPatterns, key: sf) == nil {
                let kdURL = Inf6KnowledgeDataStore.questionPatternsURL(for: sf)
                if let data = try? Data(contentsOf: kdURL), let json = String(data: data, encoding: .utf8) {
                    put(domain: .questionPatterns, key: sf, json: json)
                }
            }
        }
    }

    private static func _migrateQuizAndMastery() {
        let root = Inf6DataRoot.url()
        let mmaDir = root.appendingPathComponent("mma", isDirectory: true)
        guard let families = try? FileManager.default.contentsOfDirectory(at: mmaDir, includingPropertiesForKeys: nil) else { return }
        for familyDir in families where familyDir.hasDirectoryPath {
            let sf = familyDir.lastPathComponent
            let masteryFile = familyDir.appendingPathComponent("mastery_state.json")
            if let data = try? Data(contentsOf: masteryFile), let json = String(data: data, encoding: .utf8) {
                put(domain: .mmaMastery, key: sf, json: json)
            }
            let logsFile = familyDir.appendingPathComponent("answer_logs.json")
            if let data = try? Data(contentsOf: logsFile), let json = String(data: data, encoding: .utf8) {
                put(domain: .mmaAnswerLogs, key: sf, json: json)
            }
            if let files = try? FileManager.default.contentsOfDirectory(at: familyDir, includingPropertiesForKeys: nil) {
                for file in files where file.lastPathComponent.hasPrefix("questions_") && file.pathExtension == "json" {
                    let qKey = "\(sf):\(file.deletingPathExtension().lastPathComponent)"
                    if let data = try? Data(contentsOf: file), let json = String(data: data, encoding: .utf8) {
                        put(domain: .mmaQuestions, key: qKey, json: json)
                    }
                }
            }
        }
    }

    // MARK: - Paths

    private static func _rootURL() -> URL {
        let dir = Inf6Storage.homeDirectory().appendingPathComponent("metadata", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            preconditionFailure("[Inf6MetadataStore] root creation failed: \(error.localizedDescription)")
        }
        return dir
    }

    private static func _domainURL(_ domain: Domain) -> URL {
        _rootURL().appendingPathComponent(domain.rawValue, isDirectory: true)
    }

    private static func _recordURL(domain: Domain, key: String) -> URL {
        _domainURL(domain).appendingPathComponent(_fileName(for: key), isDirectory: false)
    }

    private static func _fileName(for key: String) -> String {
        let encoded = key.addingPercentEncoding(withAllowedCharacters: _allowedFileNameCharacters)
        guard let encoded, !encoded.isEmpty else {
            preconditionFailure("[Inf6MetadataStore] invalid key")
        }
        guard encoded.utf8.count > 180 else {
            return "\(encoded).json"
        }
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256-\(hex).json"
    }
}
