//
//  Inf6MeridianMasteryAuthoring.swift
//  inf6
//
//  正本仕様: SPEC.md
//
//  経脈マスタリー作問 (MeridianMasteryAuthoring, MMA) の 5 共通データ契約を、
//  Swift 正本アプリ側の型として定義する。
//
//  - `Inf6KnowledgeAtom`      : 1 主張 = 1 原子。
//  - `Inf6KnowledgeEdge`      : 原子間の経脈（8 種）。
//  - `Inf6CoverageTarget`     : 問題が確認する原子 ID / 経脈 ID の参照（正本型）。
//  - `Inf6GeneratedQuestion`  : `coverageTargets` 必須の問題レコード。
//                               既存 `Inf6PaperQuizQuestion` は将来この契約へ収束させる。
//  - `Inf6MasteryState`       : 原子 / 経脈ごとの習得状態。回答ログから逆算される。
//  - `Inf6TrendSignal`        : 最新差分を機械可読化した予想適中 sidecar 契約。
//  - `Inf6ForecastQuestionBlueprint`
//                             : `TrendSignal × QuestionPatternLibrary` の作問指示契約。
//
//  既存 `Inf6PaperQuizCoverageTarget` / `Inf6PaperQuiz(Question)` の JSON 互換は崩さない。
//  本ファイルの型は純粋な追加であり、既存 Codable 契約を変更しない。
//

import Foundation

// MARK: - Context mode

/// ノードの情報取得モード。LLM が知識領域ごとに設計する。
public enum Inf6KnowledgeContextMode: String, Codable, Hashable, CaseIterable {
    /// 固定コンテンツのみ表示。LLM サーチ不要。
    case `static` = "static"
    /// リアルタイム LLM サーチ結果を表示する。
    case live = "live"
    /// 固定コンテンツ + LLM サーチ結果を両方表示する。
    case hybrid = "hybrid"
}

// MARK: - 8 経脈種別

/// 知の経脈 (KnowledgeEdge) の種別。仕様書の 8 種をそのまま列挙する。
public enum Inf6KnowledgeEdgeKind: String, Codable, Hashable, CaseIterable {
    /// 前提関係: `from` を理解した後でなければ `to` は理解できない。
    case prereq      = "prereq"
    /// 差分関係: `from` と `to` の違いを問うべき近縁概念。
    case diff        = "diff"
    /// 手順順序: 操作や計算の順序関係。
    case order       = "order"
    /// 境界関係: ある条件の適用境界（使える / 使えない）。
    case boundary    = "boundary"
    /// 失敗条件: ある原子がエラーや不成立となる条件。
    case failure     = "failure"
    /// 旧称-現行名: `from` が旧称、`to` が現行名称。
    case renaming    = "renaming"
    /// 混同しやすい: 典型的な誤解・混同対象。
    case confusable  = "confusable"
    /// 実務適用判断: どの場面で採用すべきかの判断。
    case practical   = "practical"
}

// MARK: - Knowledge Node Edge (ノード間依存)

/// ノード間の依存関係エッジ（ツリー構造化用）。
/// 原子間の `Inf6KnowledgeEdge` とは別物。こちらはシラバスノード間の依存を表す。
public struct Inf6KnowledgeNodeEdge: Codable, Hashable, Identifiable {
    public var id: String { "\(fromNodeID)->\(toNodeID):\(kind.rawValue)" }
    /// 前提側ノード ID
    public var fromNodeID: String
    /// 依存側ノード ID（from を理解しないと to は理解できない）
    public var toNodeID: String
    /// 経脈種別
    public var kind: Inf6KnowledgeEdgeKind
    /// LLM が付与した根拠（日本語）
    public var reasonJa: String?
    /// LLM が付与した根拠（英語）
    public var reasonEn: String?

    enum CodingKeys: String, CodingKey {
        case fromNodeID = "from_node_id"
        case toNodeID = "to_node_id"
        case kind
        case reasonJa = "reason_ja"
        case reasonEn = "reason_en"
    }
}

// MARK: - 8 問題型

/// 作問する問題の型。仕様書の 8 型をそのまま列挙する。
public enum Inf6QuestionType: String, Codable, Hashable, CaseIterable, Sendable {
    case definition  = "definition"     // 定義問題
    case comparison  = "comparison"     // 比較問題
    case prerequisite = "prerequisite"  // 前提条件問題
    case order       = "order"          // 手順順序問題
    case setting     = "setting"        // 設定値問題
    case errorCause  = "error_cause"    // エラー原因問題
    case renaming    = "renaming"       // 更新名称問題
    case decision    = "decision"       // 実装判断問題
}

// MARK: - 習得レベル

/// 原子 / 経脈ごとの習得状態。
public enum Inf6MasteryLevel: String, Codable, Hashable, CaseIterable {
    case unverified = "unverified"   // 未確認
    case inProgress = "in_progress"  // 確認中（部分的に観測済）
    case verified   = "verified"     // 確認済
    case wrong      = "wrong"        // 誤答観測
}

// MARK: - 試験締切

/// 資格・試験単位で urgencyMultiplier に与える締切。
///
/// 未設定は「空文字」ではなく、レコード不在で表現する。
public struct Inf6ExamDeadline: Codable, Hashable, Identifiable {
    public var id: String { examID }
    public var examID: String
    public var scheduledAt: String

    enum CodingKeys: String, CodingKey {
        case examID = "exam_id"
        case scheduledAt = "scheduled_at"
    }

    public init(examID: String, scheduledAt: String) {
        self.examID = examID
        self.scheduledAt = scheduledAt
    }
}

// MARK: - ExamDeadline 共有ストア

/// sharedRoot/inf6_settings/exam_deadlines.json の読み書き。
/// Desktop と同一契約: { "exam_id": "ISO8601" } の flat JSON object。
/// sharedRoot 未設定時は読み込み空・書き込み無操作。
public enum Inf6ExamDeadlineStore {

    private static let fileName = "exam_deadlines.json"

    private static func _fileURL() throws -> URL {
        let root = try Inf6LibraryView._sharedRootDir()
        let dir = root.appendingPathComponent("inf6_settings", isDirectory: true)
        return dir.appendingPathComponent(fileName)
    }

    /// sharedRoot/inf6_settings/exam_deadlines.json から読む。
    /// 空値エントリは除外する。読み込み失敗時は空配列を返す。
    public static func load() -> [Inf6ExamDeadline] {
        guard let url = try? _fileURL(),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return []
        }
        return dict
            .filter { !$0.key.isEmpty && !$0.value.isEmpty }
            .map { Inf6ExamDeadline(examID: $0.key, scheduledAt: $0.value) }
    }

    /// sharedRoot/inf6_settings/exam_deadlines.json へ書く。
    public static func save(_ deadlines: [Inf6ExamDeadline]) {
        guard let url = try? _fileURL() else { return }
        let dict = Dictionary(uniqueKeysWithValues: deadlines.map { ($0.examID, $0.scheduledAt) })
        guard let data = try? JSONEncoder().encode(dict) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - SelectedExams 共有ストア

/// sharedRoot/inf6_settings/selected_exams.json の読み書き。
/// Desktop と同一契約: ["exam_id", ...] の flat JSON array。
/// sharedRoot 未設定時は読み込み nil・書き込み無操作。
public enum Inf6SelectedExamsStore {

    private static let fileName = "selected_exams.json"

    private static func _fileURL() throws -> URL {
        let root = try Inf6LibraryView._sharedRootDir()
        let dir = root.appendingPathComponent("inf6_settings", isDirectory: true)
        return dir.appendingPathComponent(fileName)
    }

    /// sharedRoot/inf6_settings/selected_exams.json から読む。
    /// 空エントリは除外する。読み込み失敗時は nil を返す。
    public static func load() -> [String]? {
        guard let url = try? _fileURL(),
              let data = try? Data(contentsOf: url),
              let arr = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        let filtered = arr.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return filtered.isEmpty ? nil : filtered
    }

    /// sharedRoot/inf6_settings/selected_exams.json へ書く。
    public static func save(_ examIds: [String]) {
        guard let url = try? _fileURL() else { return }
        guard let data = try? JSONEncoder().encode(examIds) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - LearningFamily manifest

public enum Inf6LearningFamilyActionPhase: String, Codable, Hashable, Sendable {
    case collect = "collect"
    case organize = "organize"
    case compose = "compose"
    case measure = "measure"
}

public enum Inf6LearningGoalKind: String, Codable, Hashable, Sendable {
    case certification = "certification"
    case paperReading = "paper_reading"
    case generalMastery = "general_mastery"
}

// MARK: - Knowledge structure tree

/// UI では「知識構造木」として扱う正本ノード種別。
/// 旧 `LearningFamily` の上に、対象 → シラバス版 → 論点 → 論文 の木を作る。
public enum Inf6KnowledgeNodeKind: String, Codable, Hashable, CaseIterable {
    case domain = "domain"
    case syllabusVersion = "syllabus_version"
    case major = "major"
    case minor = "minor"
    case topic = "topic"
    case paper = "paper"
}

/// 選択状態ではなく、知識処理の到達段階を表す。
public enum Inf6KnowledgeAchievementState: String, Codable, Hashable, CaseIterable {
    case notStarted = "not_started"
    case collecting = "collecting"
    case reading = "reading"
    case annotating = "annotating"
    case explained = "explained"
    case questioned = "questioned"
    case measured = "measured"
}

public struct Inf6KnowledgePaperLink: Codable, Hashable, Identifiable {
    public var id: String { paperID }
    public var paperID: String
    public var paperTitle: String
    public var providerID: String
    public var syllabusNodeIDs: [String]
    public var achievement: Inf6KnowledgeAchievementState
    public var knowledgeCount: Int

    enum CodingKeys: String, CodingKey {
        case paperID = "paper_id"
        case paperTitle = "paper_title"
        case providerID = "provider_id"
        case syllabusNodeIDs = "syllabus_node_ids"
        case achievement
        case knowledgeCount = "knowledge_count"
    }
}

public struct Inf6KnowledgeLiveContextSpec: Codable, Hashable {
    public var queryJa: String
    public var queryEn: String
    public var focusJa: String
    public var focusEn: String

    enum CodingKeys: String, CodingKey {
        case queryJa = "query_ja"
        case queryEn = "query_en"
        case focusJa = "focus_ja"
        case focusEn = "focus_en"
    }

    public init(
        queryJa: String,
        queryEn: String,
        focusJa: String,
        focusEn: String
    ) {
        self.queryJa = queryJa
        self.queryEn = queryEn
        self.focusJa = focusJa
        self.focusEn = focusEn
    }
}

public struct Inf6KnowledgeNode: Codable, Hashable, Identifiable {
    public var id: String { nodeID }
    public var nodeID: String
    public var parentNodeID: String?
    public var kind: Inf6KnowledgeNodeKind
    public var depth: Int
    public var titleJa: String
    public var titleEn: String
    public var summaryJa: String
    public var summaryEn: String
    public var paperCount: Int
    public var achievement: Inf6KnowledgeAchievementState
    public var importance: String
    public var nextAction: Inf6LearningFamilyActionPhase
    public var linkedPaperIDs: [String]
    public var liveContext: Inf6KnowledgeLiveContextSpec?
    public var contextMode: Inf6KnowledgeContextMode

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case parentNodeID = "parent_node_id"
        case kind
        case depth
        case titleJa = "title_ja"
        case titleEn = "title_en"
        case summaryJa = "summary_ja"
        case summaryEn = "summary_en"
        case paperCount = "paper_count"
        case achievement
        case importance
        case nextAction = "next_action"
        case linkedPaperIDs = "linked_paper_ids"
        case liveContext = "live_context"
        case contextMode = "context_mode"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try c.decode(String.self, forKey: .nodeID)
        parentNodeID = try c.decodeIfPresent(String.self, forKey: .parentNodeID)
        kind = try c.decode(Inf6KnowledgeNodeKind.self, forKey: .kind)
        depth = try c.decode(Int.self, forKey: .depth)
        titleJa = try c.decode(String.self, forKey: .titleJa)
        titleEn = try c.decode(String.self, forKey: .titleEn)
        summaryJa = try c.decode(String.self, forKey: .summaryJa)
        summaryEn = try c.decode(String.self, forKey: .summaryEn)
        paperCount = try c.decode(Int.self, forKey: .paperCount)
        achievement = try c.decode(Inf6KnowledgeAchievementState.self, forKey: .achievement)
        importance = try c.decode(String.self, forKey: .importance)
        nextAction = try c.decode(Inf6LearningFamilyActionPhase.self, forKey: .nextAction)
        linkedPaperIDs = try c.decode([String].self, forKey: .linkedPaperIDs)
        liveContext = try c.decodeIfPresent(Inf6KnowledgeLiveContextSpec.self, forKey: .liveContext)
        // 旧 JSON には context_mode がないので static をデフォルトにする
        contextMode = (try? c.decode(Inf6KnowledgeContextMode.self, forKey: .contextMode)) ?? .static
    }

    public init(
        nodeID: String,
        parentNodeID: String?,
        kind: Inf6KnowledgeNodeKind,
        depth: Int,
        titleJa: String,
        titleEn: String,
        summaryJa: String,
        summaryEn: String,
        paperCount: Int,
        achievement: Inf6KnowledgeAchievementState,
        importance: String,
        nextAction: Inf6LearningFamilyActionPhase,
        linkedPaperIDs: [String],
        liveContext: Inf6KnowledgeLiveContextSpec? = nil,
        contextMode: Inf6KnowledgeContextMode = .static
    ) {
        self.nodeID = nodeID
        self.parentNodeID = parentNodeID
        self.kind = kind
        self.depth = depth
        self.titleJa = titleJa
        self.titleEn = titleEn
        self.summaryJa = summaryJa
        self.summaryEn = summaryEn
        self.paperCount = paperCount
        self.achievement = achievement
        self.importance = importance
        self.nextAction = nextAction
        self.linkedPaperIDs = linkedPaperIDs
        self.liveContext = liveContext
        self.contextMode = contextMode
    }
}

public struct Inf6KnowledgeDomainStructure: Codable, Hashable {
    public var domainID: String
    public var syllabusVersionID: String
    public var nodes: [Inf6KnowledgeNode]
    public var papers: [Inf6KnowledgePaperLink]
    public var edges: [Inf6KnowledgeNodeEdge]

    enum CodingKeys: String, CodingKey {
        case domainID = "domain_id"
        case syllabusVersionID = "syllabus_version_id"
        case nodes
        case papers
        case edges
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        domainID = try c.decode(String.self, forKey: .domainID)
        syllabusVersionID = try c.decode(String.self, forKey: .syllabusVersionID)
        nodes = try c.decode([Inf6KnowledgeNode].self, forKey: .nodes)
        papers = try c.decode([Inf6KnowledgePaperLink].self, forKey: .papers)
        // 旧 JSON には edges がない
        edges = (try? c.decode([Inf6KnowledgeNodeEdge].self, forKey: .edges)) ?? []
    }

    public init(
        domainID: String,
        syllabusVersionID: String,
        nodes: [Inf6KnowledgeNode],
        papers: [Inf6KnowledgePaperLink],
        edges: [Inf6KnowledgeNodeEdge] = []
    ) {
        self.domainID = domainID
        self.syllabusVersionID = syllabusVersionID
        self.nodes = nodes
        self.papers = papers
        self.edges = edges
    }
}

public enum Inf6KnowledgeDomainStructureStore {

    // MARK: - In-memory cache
    //
    // The home page (CircuitBoardView) calls loadOrSeed for every manifest on each
    // appearance. The knowledge-structure JSON is the syllabus-node authority;
    // runtime outline caches may enrich an explicit rebuild, but must not redefine
    // the node set during ordinary reads. Cache the canonical structure and
    // invalidate when the on-disk file's mtime changes.
    private struct _CacheEntry {
        let structure: Inf6KnowledgeDomainStructure
        let mtime: TimeInterval
        let paperStoreFingerprint: String
        let seedFingerprint: _SeedFingerprint
    }
    private static var _cache: [String: _CacheEntry] = [:]
    private static let _cacheLock = NSLock()

    private static func _cacheKey(_ manifest: Inf6LearningFamilyManifest, _ syllabusVersionID: String) -> String {
        return manifest.sourceFamily + "#" + syllabusVersionID
    }

    private static func _fileMTime(_ url: URL) -> TimeInterval {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }

    private static func _readSidecarStructure(
        from url: URL
    ) throws -> Inf6KnowledgeDomainStructure {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(
                domain: "Inf6MeridianMasteryAuthoring",
                code: 17,
                userInfo: [NSLocalizedDescriptionKey: "knowledge structure sidecar is missing: \(url.path)"]
            )
        }

        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(Inf6KnowledgeDomainStructure.self, from: data)
        } catch {
            throw NSError(
                domain: "Inf6MeridianMasteryAuthoring",
                code: 19,
                userInfo: [
                    NSLocalizedDescriptionKey: "knowledge structure sidecar decode failed: \(url.path): \(error.localizedDescription)",
                    NSUnderlyingErrorKey: error,
                ]
            )
        }
    }

    private static func _paperStoreFingerprint(_ paperStore: Inf6CorePaperStore?) -> String {
        guard let s = paperStore else { return "nopaperstore" }
        // count + last-updated-ish indicator; cheap fingerprint
        return "ps:\(s.papers.count)"
    }

    /// Clear the in-memory cache. Call this when the underlying data is known to have
    /// changed in a way the mtime check can't see (e.g., bulk file-store writes).
    public static func invalidateCache() {
        _cacheLock.lock()
        _cache.removeAll(keepingCapacity: true)
        _cacheLock.unlock()
    }

    /// Invalidate only the cached structure(s) for one source family, leaving other domains untouched.
    /// Use this instead of invalidateCache() when only one domain's data changed.
    public static func invalidateCache(sourceFamily: String) {
        _cacheLock.lock()
        let prefix = sourceFamily + "#"
        _cache = _cache.filter { !$0.key.hasPrefix(prefix) }
        _cacheLock.unlock()
    }

    private static func _englishTextOrEmpty(_ text: String?) -> String {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"[ぁ-んァ-ン一-龥]"#, options: .regularExpression) != nil {
            return ""
        }
        return trimmed
    }

    /// Persistent fingerprint of the inputs that produced a previously-built structure.
    /// Stored in metadata file store so it survives process restarts (the in-memory cache does not).
    /// If the current inputs match the stored fingerprint, the entire rebuild +
    /// merge step is skipped and the on-disk JSON is returned as-is.
    private struct _SeedFingerprint: Codable, Equatable {
        let seedSchemaVersion: Int
        let paperCount: Int
        let syllabusPaperLinkCount: Int
        let syllabusPaperLinkRevision: String?
        let outlineCount: Int
        let outlineSignature: String
        let supportsPapers: Bool
        let domainTitleJa: String
    }

    private static func _currentSeedFingerprint(
        manifest: Inf6LearningFamilyManifest,
        outlineItems: [Inf6SyllabusOutlineItem],
        paperStore: Inf6CorePaperStore?,
        domainTitleJa: String
    ) -> _SeedFingerprint {
        return _SeedFingerprint(
            seedSchemaVersion: 7,
            paperCount: paperStore?.papers.count ?? 0,
            syllabusPaperLinkCount: 0,
            syllabusPaperLinkRevision: paperStore != nil
                ? Inf6SyllabusPaperAutoSearch.linkRevision(sourceFamily: manifest.sourceFamily)
                : nil,
            outlineCount: outlineItems.count,
            outlineSignature: outlineItems.map {
                [
                    $0.key,
                    $0.titleJa ?? "",
                    $0.titleEn ?? "",
                    String($0.effectiveDepth)
                ].joined(separator: "\u{1f}")
            }.joined(separator: "\u{1e}"),
            supportsPapers: paperStore != nil,
            domainTitleJa: domainTitleJa
        )
    }

    private static func _seedFingerprintsMatch(_ lhs: _SeedFingerprint, _ rhs: _SeedFingerprint) -> Bool {
        lhs.seedSchemaVersion == rhs.seedSchemaVersion
            && lhs.paperCount == rhs.paperCount
            && lhs.syllabusPaperLinkRevision == rhs.syllabusPaperLinkRevision
            && lhs.outlineCount == rhs.outlineCount
            && lhs.outlineSignature == rhs.outlineSignature
            && lhs.supportsPapers == rhs.supportsPapers
            && lhs.domainTitleJa == rhs.domainTitleJa
    }

    private static func _seedFingerprintDBKey(_ manifest: Inf6LearningFamilyManifest, _ syllabusVersionID: String) -> String {
        return "seed_fp:" + manifest.sourceFamily + "#" + syllabusVersionID
    }

    /// metadata file store key for the structure body itself (separate from the seed fingerprint).
    private static func _structureDBKey(_ manifest: Inf6LearningFamilyManifest, _ syllabusVersionID: String) -> String {
        return "structure:" + manifest.sourceFamily + "#" + syllabusVersionID
    }

    static func loadOrSeed(
        manifest: Inf6LearningFamilyManifest,
        syllabusVersionID: String,
        domainTitleJa: String,
        outlineItems: [Inf6SyllabusOutlineItem],
        paperStore: Inf6CorePaperStore? = nil,
        rebuildSyllabusNodes: Bool = false
    ) throws -> Inf6KnowledgeDomainStructure {
        let loadT0 = CFAbsoluteTimeGetCurrent()
        NSLog("[inf6-structure] loadOrSeed: start %@, paperStore=%@", manifest.sourceFamily, paperStore != nil ? "yes" : "nil")
        try _migrateLegacyStructureIfNeeded(
            manifest: manifest,
            syllabusVersionID: syllabusVersionID,
            domainTitleJa: domainTitleJa
        )
        let url = try _fileURL(manifest: manifest, syllabusVersionID: syllabusVersionID)
        NSLog("[inf6-structure] loadOrSeed: fileURL resolved, %.1fms", (CFAbsoluteTimeGetCurrent() - loadT0) * 1000)
        let cacheKey = _cacheKey(manifest, syllabusVersionID)
        let mtime = _fileMTime(url)
        NSLog("[inf6-structure] loadOrSeed: mtime done, %.1fms", (CFAbsoluteTimeGetCurrent() - loadT0) * 1000)
        if let paperStore {
            paperStore.reloadPapersFromMetadataStore()
            NSLog("[inf6-structure] loadOrSeed: reloadPapers done, %.1fms", (CFAbsoluteTimeGetCurrent() - loadT0) * 1000)
        }
        let fingerprint = _paperStoreFingerprint(paperStore)
        let shouldPersistStructure = paperStore != nil
        let currentSeedFP = _currentSeedFingerprint(
            manifest: manifest,
            outlineItems: outlineItems,
            paperStore: paperStore,
            domainTitleJa: domainTitleJa
        )

        NSLog("[inf6-structure] loadOrSeed: fingerprint computed, %.1fms", (CFAbsoluteTimeGetCurrent() - loadT0) * 1000)
        // Memory cache hit
        _cacheLock.lock()
        if let entry = _cache[cacheKey],
           entry.mtime == mtime,
           entry.paperStoreFingerprint == fingerprint,
           _seedFingerprintsMatch(entry.seedFingerprint, currentSeedFP) {
            _cacheLock.unlock()
            return entry.structure
        } else {
            _cacheLock.unlock()
        }

        // Persistent seed-fingerprint check: if the stored fingerprint matches the
        // current inputs, skip the expensive rebuild+merge. The metadata file store
        // is the only structure source here.
        let fpDBKey = _seedFingerprintDBKey(manifest, syllabusVersionID)
        let structDBKey = _structureDBKey(manifest, syllabusVersionID)
        if shouldPersistStructure && !rebuildSyllabusNodes {
            NSLog("[inf6-structure] loadOrSeed: reading storedFP, %.1fms", (CFAbsoluteTimeGetCurrent() - loadT0) * 1000)
            let storedFP: _SeedFingerprint? = Inf6MetadataStore.getCodable(_SeedFingerprint.self, domain: .syllabus, key: fpDBKey)
            NSLog("[inf6-structure] loadOrSeed: storedFP read done, found=%d, %.1fms", storedFP != nil ? 1 : 0, (CFAbsoluteTimeGetCurrent() - loadT0) * 1000)

            if let stored = storedFP, _seedFingerprintsMatch(stored, currentSeedFP) {
                if let cached = Inf6MetadataStore.getCodable(Inf6KnowledgeDomainStructure.self, domain: .syllabus, key: structDBKey) {
                    _cacheLock.lock()
                    _cache[cacheKey] = _CacheEntry(
                        structure: cached,
                        mtime: mtime,
                        paperStoreFingerprint: fingerprint,
                        seedFingerprint: currentSeedFP
                    )
                    _cacheLock.unlock()
                    return cached
                }
            }
        }

        NSLog("[inf6-structure] loadOrSeed: reading structure from MetadataStore, %.1fms", (CFAbsoluteTimeGetCurrent() - loadT0) * 1000)
        let existingFromStore: Inf6KnowledgeDomainStructure? = Inf6MetadataStore.getCodable(
            Inf6KnowledgeDomainStructure.self,
            domain: .syllabus,
            key: structDBKey
        )
        let existingFromAnywhere: Inf6KnowledgeDomainStructure?
        if let existingFromStore {
            existingFromAnywhere = existingFromStore
        } else if FileManager.default.fileExists(atPath: url.path) {
            do {
                existingFromAnywhere = try _readSidecarStructure(from: url)
            } catch {
                NSLog("[inf6-structure] sidecar unavailable for %@: %@", manifest.sourceFamily, error.localizedDescription)
                existingFromAnywhere = nil
            }
        } else {
            existingFromAnywhere = nil
        }
        NSLog("[inf6-structure] loadOrSeed: structure read done, found=%d, %.1fms", existingFromAnywhere != nil ? 1 : 0, (CFAbsoluteTimeGetCurrent() - loadT0) * 1000)
        let storedPaperLinks: [Inf6SyllabusPaperLink]
        if paperStore != nil {
            storedPaperLinks = try _decodeStoredSyllabusPaperLinks(
                Inf6MetadataStore.listByPrefix(
                    domain: .syllabusPaperLinks,
                    prefix: "\(manifest.sourceFamily)|"
                )
            )
        } else {
            storedPaperLinks = []
        }

        // An existing knowledge structure is the fixed syllabus tree. Ordinary
        // reads may reconcile paper links and progress, but the current outline
        // cache is not allowed to add, remove, or re-parent syllabus nodes.
        if let existing = existingFromAnywhere, !rebuildSyllabusNodes {
            var canonical = existing
            if let paperStore {
                canonical = try _structureByReconcilingStoredPaperLinks(
                    canonical,
                    manifest: manifest,
                    versionID: syllabusVersionID,
                    paperStore: paperStore,
                    sourceLinks: storedPaperLinks
                )
                let missingLinks = _missingStoredPaperLinks(
                    in: canonical,
                    sourceLinks: storedPaperLinks,
                    paperStore: paperStore
                )
                guard missingLinks.isEmpty else {
                    throw _incompletePaperLinkedStructureError(
                        sourceFamily: manifest.sourceFamily,
                        syllabusVersionID: syllabusVersionID,
                        missingLinks: missingLinks
                    )
                }
            }
            if shouldPersistStructure, canonical != existing {
                try save(canonical, manifest: manifest, syllabusVersionID: syllabusVersionID)
            }
            _cacheLock.lock()
            _cache[cacheKey] = _CacheEntry(
                structure: canonical,
                mtime: _fileMTime(url),
                paperStoreFingerprint: fingerprint,
                seedFingerprint: currentSeedFP
            )
            _cacheLock.unlock()
            NSLog("[inf6-structure] loadOrSeed: canonical %@, nodes=%d, %.1fms", manifest.sourceFamily, canonical.nodes.count, (CFAbsoluteTimeGetCurrent() - loadT0) * 1000)
            return canonical
        }

        if let existing = existingFromAnywhere, rebuildSyllabusNodes {
            let missingLinksBeforeMerge: [(nodeID: String, paperIDs: [String])]
            if let paperStore {
                missingLinksBeforeMerge = _missingStoredPaperLinks(
                    in: existing,
                    sourceLinks: storedPaperLinks,
                    paperStore: paperStore
                )
            } else {
                missingLinksBeforeMerge = []
            }
            let seeded: Inf6KnowledgeDomainStructure
            if let paperStore {
                seeded = try _buildPaperLinkedStructure(
                    manifest: manifest,
                    syllabusVersionID: syllabusVersionID,
                    domainTitleJa: domainTitleJa,
                    outlineItems: outlineItems,
                    sourceLinks: storedPaperLinks,
                    paperStore: paperStore
                )
            } else {
                seeded = try _buildOutlineStructure(
                    manifest: manifest,
                    syllabusVersionID: syllabusVersionID,
                    domainTitleJa: domainTitleJa,
                    outlineItems: outlineItems
                )
            }
            var merged = try _mergeSeededBilingualFieldsAndLiveContext(existing, seeded: seeded)
            if let paperStore {
                merged = try _structureByReconcilingStoredPaperLinks(
                    merged,
                    manifest: manifest,
                    versionID: syllabusVersionID,
                    paperStore: paperStore,
                    sourceLinks: storedPaperLinks
                )
            }
            if let paperStore {
                let missingLinks = _missingStoredPaperLinks(
                    in: merged,
                    sourceLinks: storedPaperLinks,
                    paperStore: paperStore
                )
                guard missingLinks.isEmpty else {
                    throw _incompletePaperLinkedStructureError(
                        sourceFamily: manifest.sourceFamily,
                        syllabusVersionID: syllabusVersionID,
                        missingLinks: missingLinks
                    )
                }
            }
            if shouldPersistStructure, merged != existing || !missingLinksBeforeMerge.isEmpty {
                try save(merged, manifest: manifest, syllabusVersionID: syllabusVersionID)
            }
            // Persist the build fingerprint so the next cold start can skip the rebuild.
            if shouldPersistStructure {
                Inf6MetadataStore.putCodable(currentSeedFP, domain: .syllabus, key: fpDBKey)
            }
            _cacheLock.lock()
            _cache[cacheKey] = _CacheEntry(
                structure: merged,
                mtime: _fileMTime(url),  // re-read after potential save
                paperStoreFingerprint: fingerprint,
                seedFingerprint: currentSeedFP
            )
            _cacheLock.unlock()
            NSLog("[inf6-structure] loadOrSeed: done %@, nodes=%d, %.1fms", manifest.sourceFamily, merged.nodes.count, (CFAbsoluteTimeGetCurrent() - loadT0) * 1000)
            return merged
        }

        let canReconstructFromVerifiedOutline = !outlineItems.isEmpty
        guard rebuildSyllabusNodes || canReconstructFromVerifiedOutline else {
            throw NSError(
                domain: "Inf6MeridianMasteryAuthoring",
                code: 9,
                userInfo: [
                    NSLocalizedDescriptionKey: "canonical knowledge structure is missing and the verified syllabus outline is empty: \(manifest.sourceFamily)#\(syllabusVersionID)"
                ]
            )
        }

        var structure: Inf6KnowledgeDomainStructure
        if let paperStore {
            structure = try _buildPaperLinkedStructure(
                manifest: manifest,
                syllabusVersionID: syllabusVersionID,
                domainTitleJa: domainTitleJa,
                outlineItems: outlineItems,
                sourceLinks: storedPaperLinks,
                paperStore: paperStore
            )
        } else {
            structure = try _buildOutlineStructure(
                manifest: manifest,
                syllabusVersionID: syllabusVersionID,
                domainTitleJa: domainTitleJa,
                outlineItems: outlineItems
            )
        }
        if let paperStore {
            structure = try _structureByReconcilingStoredPaperLinks(
                structure,
                manifest: manifest,
                versionID: syllabusVersionID,
                paperStore: paperStore,
                sourceLinks: storedPaperLinks
            )
        }

        if shouldPersistStructure {
            if let paperStore {
                let missingLinks = _missingStoredPaperLinks(
                    in: structure,
                    sourceLinks: storedPaperLinks,
                    paperStore: paperStore
                )
                guard missingLinks.isEmpty else {
                    throw _incompletePaperLinkedStructureError(
                        sourceFamily: manifest.sourceFamily,
                        syllabusVersionID: syllabusVersionID,
                        missingLinks: missingLinks
                    )
                }
            }
            try save(structure, manifest: manifest, syllabusVersionID: syllabusVersionID)
            Inf6MetadataStore.putCodable(currentSeedFP, domain: .syllabus, key: fpDBKey)
        }
        _cacheLock.lock()
        _cache[cacheKey] = _CacheEntry(
            structure: structure,
            mtime: _fileMTime(url),
            paperStoreFingerprint: fingerprint,
            seedFingerprint: currentSeedFP
        )
        _cacheLock.unlock()
        NSLog("[inf6-structure] loadOrSeed: done %@ (built), nodes=%d, %.1fms", manifest.sourceFamily, structure.nodes.count, (CFAbsoluteTimeGetCurrent() - loadT0) * 1000)
        return structure
    }

    private static func _migrateLegacyStructureIfNeeded(
        manifest: Inf6LearningFamilyManifest,
        syllabusVersionID: String,
        domainTitleJa: String
    ) throws {
        let canonicalVersionID = syllabusVersionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonicalVersionID.isEmpty else { return }
        let legacyVersionIDs = _legacyKnowledgeStructureVersionIDs(
            for: manifest,
            canonicalVersionID: canonicalVersionID
        )
        guard !legacyVersionIDs.isEmpty else { return }

        let canonicalURL = try _fileURL(manifest: manifest, syllabusVersionID: canonicalVersionID)
        let canonicalStoreKey = _structureDBKey(manifest, canonicalVersionID)
        var hasCanonicalStructure =
            Inf6MetadataStore.getCodable(
                Inf6KnowledgeDomainStructure.self,
                domain: .syllabus,
                key: canonicalStoreKey
            ) != nil
        if !hasCanonicalStructure {
            hasCanonicalStructure = FileManager.default.fileExists(atPath: canonicalURL.path)
        }

        for legacyVersionID in legacyVersionIDs {
            if !hasCanonicalStructure,
               let legacyStructure = try _readStoredStructureIfPresent(
                    manifest: manifest,
                    syllabusVersionID: legacyVersionID
               ) {
                let migrated = _structureByReplacingSyllabusVersionID(
                    legacyStructure,
                    manifest: manifest,
                    domainTitleJa: domainTitleJa,
                    from: legacyVersionID,
                    to: canonicalVersionID
                )
                try save(migrated, manifest: manifest, syllabusVersionID: canonicalVersionID)
                if let seedFingerprint = Inf6MetadataStore.getCodable(
                    _SeedFingerprint.self,
                    domain: .syllabus,
                    key: _seedFingerprintDBKey(manifest, legacyVersionID)
                ) {
                    Inf6MetadataStore.putCodable(
                        seedFingerprint,
                        domain: .syllabus,
                        key: _seedFingerprintDBKey(manifest, canonicalVersionID)
                    )
                }
                hasCanonicalStructure = true
            }
            try _deleteStructureArtifacts(manifest: manifest, syllabusVersionID: legacyVersionID)
        }
    }

    @discardableResult
    static func reconcileStoredPaperLinks(
        manifest: Inf6LearningFamilyManifest,
        paperStore: Inf6CorePaperStore
    ) throws -> Int {
        paperStore.reloadPapersFromMetadataStore()
        let papersByID = Dictionary(uniqueKeysWithValues: paperStore.papers.map { ($0.id, $0) })
        guard !papersByID.isEmpty else {
            throw NSError(
                domain: "Inf6MeridianMasteryAuthoring",
                code: 14,
                userInfo: [NSLocalizedDescriptionKey: "paper store is empty during paper-linked structure reconciliation: \(manifest.sourceFamily)"]
            )
        }
        let sourceLinkRows = Inf6MetadataStore.listByPrefix(domain: .syllabusPaperLinks, prefix: "\(manifest.sourceFamily)|")
        let sourceLinks = try _decodeStoredSyllabusPaperLinks(sourceLinkRows)
        guard !sourceLinks.isEmpty else { return 0 }

        var changedCount = 0
        let structurePrefix = "structure:\(manifest.sourceFamily)#"
        for row in Inf6MetadataStore.listByPrefix(domain: .syllabus, prefix: structurePrefix) {
            guard let data = row.json.data(using: .utf8) else {
                throw NSError(
                    domain: "Inf6MeridianMasteryAuthoring",
                    code: 12,
                    userInfo: [NSLocalizedDescriptionKey: "knowledge structure JSON is not UTF-8: \(row.key)"]
                )
            }
            let structure: Inf6KnowledgeDomainStructure
            do {
                structure = try JSONDecoder().decode(Inf6KnowledgeDomainStructure.self, from: data)
            } catch {
                throw NSError(
                    domain: "Inf6MeridianMasteryAuthoring",
                    code: 13,
                    userInfo: [NSLocalizedDescriptionKey: "knowledge structure decode failed: \(row.key): \(error.localizedDescription)"]
                )
            }

            let versionID = String(row.key.dropFirst(structurePrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !versionID.isEmpty else { continue }

            let missingLinksBeforeRepair = _missingStoredPaperLinks(
                in: structure,
                sourceLinks: sourceLinks,
                paperStore: paperStore
            )
            let repaired = try _structureByReconcilingStoredPaperLinks(
                structure,
                manifest: manifest,
                versionID: versionID,
                paperStore: paperStore,
                papersByID: papersByID,
                sourceLinks: sourceLinks
            )
            let missingLinksAfterRepair = _missingStoredPaperLinks(
                in: repaired,
                sourceLinks: sourceLinks,
                paperStore: paperStore
            )
            guard missingLinksAfterRepair.isEmpty else {
                throw _incompletePaperLinkedStructureError(
                    sourceFamily: manifest.sourceFamily,
                    syllabusVersionID: versionID,
                    missingLinks: missingLinksAfterRepair
                )
            }
            guard repaired != structure || !missingLinksBeforeRepair.isEmpty else { continue }
            try save(repaired, manifest: manifest, syllabusVersionID: versionID)
            changedCount += 1
        }
        return changedCount
    }

    static func assertStoredPaperLinkCoverage(
        manifest: Inf6LearningFamilyManifest,
        syllabusVersionID: String,
        paperStore: Inf6CorePaperStore
    ) throws {
        paperStore.reloadPapersFromMetadataStore()
        guard !paperStore.papers.isEmpty else {
            throw NSError(
                domain: "Inf6MeridianMasteryAuthoring",
                code: 15,
                userInfo: [NSLocalizedDescriptionKey: "paper store is empty during paper-link coverage validation: \(manifest.sourceFamily)#\(syllabusVersionID)"]
            )
        }
        let structDBKey = _structureDBKey(manifest, syllabusVersionID)
        guard let structure = Inf6MetadataStore.getCodable(
            Inf6KnowledgeDomainStructure.self,
            domain: .syllabus,
            key: structDBKey
        ) else {
            throw NSError(
                domain: "Inf6MeridianMasteryAuthoring",
                code: 16,
                userInfo: [NSLocalizedDescriptionKey: "paper-linked structure is missing: \(manifest.sourceFamily)#\(syllabusVersionID)"]
            )
        }
        let sourceLinks = try _decodeStoredSyllabusPaperLinks(
            Inf6MetadataStore.listByPrefix(
                domain: .syllabusPaperLinks,
                prefix: "\(manifest.sourceFamily)|"
            )
        )
        let missingLinks = _missingStoredPaperLinks(
            in: structure,
            sourceLinks: sourceLinks,
            paperStore: paperStore
        )
        guard missingLinks.isEmpty else {
            throw _incompletePaperLinkedStructureError(
                sourceFamily: manifest.sourceFamily,
                syllabusVersionID: syllabusVersionID,
                missingLinks: missingLinks
            )
        }
    }

    private static func _decodeStoredSyllabusPaperLinks(
        _ rows: [(key: String, json: String)]
    ) throws -> [Inf6SyllabusPaperLink] {
        var sourceLinks: [Inf6SyllabusPaperLink] = []
        for row in rows {
            guard let data = row.json.data(using: .utf8) else {
                throw NSError(
                    domain: "Inf6MeridianMasteryAuthoring",
                    code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "syllabus paper link JSON is not UTF-8: \(row.key)"]
                )
            }
            do {
                sourceLinks.append(try JSONDecoder().decode(Inf6SyllabusPaperLink.self, from: data))
            } catch {
                throw NSError(
                    domain: "Inf6MeridianMasteryAuthoring",
                    code: 11,
                    userInfo: [NSLocalizedDescriptionKey: "syllabus paper link decode failed: \(row.key): \(error.localizedDescription)"]
                )
            }
        }
        return sourceLinks
    }

    private static func _structureByReconcilingStoredPaperLinks(
        _ structure: Inf6KnowledgeDomainStructure,
        manifest: Inf6LearningFamilyManifest,
        versionID: String,
        paperStore: Inf6CorePaperStore,
        sourceLinks: [Inf6SyllabusPaperLink]
    ) throws -> Inf6KnowledgeDomainStructure {
        paperStore.reloadPapersFromMetadataStore()
        let papersByID = Dictionary(uniqueKeysWithValues: paperStore.papers.map { ($0.id, $0) })
        guard !sourceLinks.isEmpty else { return structure }
        return try _structureByReconcilingStoredPaperLinks(
            structure,
            manifest: manifest,
            versionID: versionID,
            paperStore: paperStore,
            papersByID: papersByID,
            sourceLinks: sourceLinks
        )
    }

    private static func _structureByReconcilingStoredPaperLinks(
        _ structure: Inf6KnowledgeDomainStructure,
        manifest: Inf6LearningFamilyManifest,
        versionID: String,
        paperStore: Inf6CorePaperStore,
        papersByID: [String: Inf6CorePaper],
        sourceLinks: [Inf6SyllabusPaperLink]
    ) throws -> Inf6KnowledgeDomainStructure {
        var nodes = structure.nodes
        let sourceLinkedPaperIDs = Set(sourceLinks.map(\.paperID))
        let domainNodeID = "domain:\(manifest.familyID)"
        let versionNodeID = "syllabus:\(versionID)"
        let defaultAction = manifest.entryActions.first?.phase ?? .collect

        let originalNodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.nodeID, $0) })
        let nodeIDs = Set(nodes.map(\.nodeID))
        var expectedByNodeID: [String: [String]] = [:]
        for link in sourceLinks where nodeIDs.contains(link.syllabusNodeID) {
            guard papersByID[link.paperID] != nil else { continue }
            if expectedByNodeID[link.syllabusNodeID] == nil {
                expectedByNodeID[link.syllabusNodeID] = []
            }
            if !(expectedByNodeID[link.syllabusNodeID] ?? []).contains(link.paperID) {
                expectedByNodeID[link.syllabusNodeID]?.append(link.paperID)
            }
        }

        guard !expectedByNodeID.isEmpty else {
            return structure
        }

        let allPaperIDs = Set(expectedByNodeID.values.flatMap { $0 })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let achievementsByPaperID = _achievementByPaperID(store: paperStore)
        let allAchievement = _aggregateAchievement(forPaperIDs: allPaperIDs, achievementsByPaperID: achievementsByPaperID)

        for index in nodes.indices where nodes[index].nodeID == domainNodeID || nodes[index].nodeID == versionNodeID {
            nodes[index].paperCount = allPaperIDs.count
            nodes[index].achievement = allAchievement
            nodes[index].nextAction = defaultAction
            nodes[index].linkedPaperIDs = allPaperIDs
        }

        for (nodeID, paperIDs) in expectedByNodeID {
            guard let nodeIndex = nodes.firstIndex(where: { $0.nodeID == nodeID }) else { continue }
            nodes[nodeIndex].paperCount = paperIDs.count
            nodes[nodeIndex].achievement = _aggregateAchievement(forPaperIDs: paperIDs, achievementsByPaperID: achievementsByPaperID)
            nodes[nodeIndex].nextAction = defaultAction
            nodes[nodeIndex].linkedPaperIDs = paperIDs
        }

        var aggregatePaperIDsByAncestorID: [String: Set<String>] = [:]
        for (nodeID, paperIDs) in expectedByNodeID {
            var currentParentID = originalNodesByID[nodeID]?.parentNodeID
            while let parentID = currentParentID {
                aggregatePaperIDsByAncestorID[parentID, default: []].formUnion(paperIDs)
                currentParentID = originalNodesByID[parentID]?.parentNodeID
            }
        }
        for (nodeID, paperIDs) in aggregatePaperIDsByAncestorID {
            guard let nodeIndex = nodes.firstIndex(where: { $0.nodeID == nodeID }) else { continue }
            // 中間ノードは、子孫の集約だけでなく自身の直接リンクも持ちうる。
            // 集約で置き換えると直接リンクが消え、保存後の検証で
            // paper-linked structure is incomplete として弾かれ続ける。
            let ownPaperIDs = expectedByNodeID[nodeID] ?? []
            let sortedPaperIDs = paperIDs.union(ownPaperIDs)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            nodes[nodeIndex].paperCount = sortedPaperIDs.count
            nodes[nodeIndex].achievement = _aggregateAchievement(forPaperIDs: sortedPaperIDs, achievementsByPaperID: achievementsByPaperID)
            nodes[nodeIndex].nextAction = defaultAction
            nodes[nodeIndex].linkedPaperIDs = sortedPaperIDs
        }

        nodes.removeAll { node in
            guard node.kind == .paper,
                  let parentNodeID = node.parentNodeID else { return false }
            return expectedByNodeID[parentNodeID] != nil
        }

        var paperNodeIDsByPaperID: [String: [String]] = [:]
        let parentByNodeID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.nodeID, $0) })
        for nodeID in expectedByNodeID.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            guard let parent = parentByNodeID[nodeID],
                  let paperIDs = expectedByNodeID[nodeID] else { continue }
            for paperID in paperIDs {
                guard let paper = papersByID[paperID] else { continue }
                guard let paperTitleEn = paper.titleEn,
                      !paperTitleEn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw NSError(
                        domain: "Inf6MeridianMasteryAuthoring",
                        code: 9,
                        userInfo: [NSLocalizedDescriptionKey: "paper title_en is missing: \(paperID)"]
                    )
                }
                paperNodeIDsByPaperID[paperID, default: []].append(nodeID)
                nodes.append(
                    Inf6KnowledgeNode(
                        nodeID: "paper:\(nodeID):\(paperID)",
                        parentNodeID: nodeID,
                        kind: .paper,
                        depth: parent.depth + 1,
                        titleJa: paper.title,
                        titleEn: paperTitleEn,
                        summaryJa: paper.tags.joined(separator: " / "),
                        summaryEn: paper.tags.joined(separator: " / "),
                        paperCount: 1,
                        achievement: achievementsByPaperID[paperID] ?? .notStarted,
                        importance: "medium",
                        nextAction: .organize,
                        linkedPaperIDs: [paperID],
                        liveContext: nil,
                        contextMode: .static
                    )
                )
            }
        }

        let paperIDsInStructure = Set(allPaperIDs)
        let papers = paperStore.papers
            .filter { paperIDsInStructure.contains($0.id) }
            .map { paper in
                Inf6KnowledgePaperLink(
                    paperID: paper.id,
                    paperTitle: paper.title,
                    providerID: paper.provider,
                    syllabusNodeIDs: paperNodeIDsByPaperID[paper.id] ?? [],
                    achievement: _achievement(from: paperStore.progress[paper.id]?.status ?? .notStarted),
                    knowledgeCount: paperStore.progress[paper.id]?.masteryScore ?? 0
                )
            }

        return Inf6KnowledgeDomainStructure(
            domainID: structure.domainID,
            syllabusVersionID: structure.syllabusVersionID,
            nodes: nodes,
            papers: papers,
            edges: structure.edges
        )
    }

    private static func _missingStoredPaperLinks(
        in structure: Inf6KnowledgeDomainStructure,
        sourceLinks: [Inf6SyllabusPaperLink],
        paperStore: Inf6CorePaperStore
    ) -> [(nodeID: String, paperIDs: [String])] {
        let validPaperIDs = Set(paperStore.papers.map(\.id))
        let nodesByID = Dictionary(uniqueKeysWithValues: structure.nodes.map { ($0.nodeID, $0) })
        var expectedByNodeID: [String: Set<String>] = [:]
        for link in sourceLinks {
            guard nodesByID[link.syllabusNodeID] != nil,
                  validPaperIDs.contains(link.paperID) else {
                continue
            }
            expectedByNodeID[link.syllabusNodeID, default: []].insert(link.paperID)
        }
        return expectedByNodeID.compactMap { pair in
            let nodeID = pair.key
            let expectedIDs = pair.value
            guard let node = nodesByID[nodeID] else { return nil }
            let missing = expectedIDs.subtracting(Set(node.linkedPaperIDs))
            guard !missing.isEmpty else { return nil }
            return (nodeID: nodeID, paperIDs: missing.sorted())
        }.sorted {
            $0.nodeID.localizedStandardCompare($1.nodeID) == .orderedAscending
        }
    }

    private static func _incompletePaperLinkedStructureError(
        sourceFamily: String,
        syllabusVersionID: String,
        missingLinks: [(nodeID: String, paperIDs: [String])]
    ) -> NSError {
        let sample = missingLinks.prefix(8).map { "\($0.nodeID):\($0.paperIDs.count)" }.joined(separator: ",")
        return NSError(
            domain: "Inf6MeridianMasteryAuthoring",
            code: 8,
            userInfo: [
                NSLocalizedDescriptionKey: "paper-linked structure is incomplete: \(sourceFamily)#\(syllabusVersionID) missing=\(sample)"
            ]
        )
    }

    public static func save(
        _ structure: Inf6KnowledgeDomainStructure,
        manifest: Inf6LearningFamilyManifest,
        syllabusVersionID: String
    ) throws {
        // Write to metadata file store first (canonical store).
        Inf6MetadataStore.putCodable(
            structure,
            domain: .syllabus,
            key: _structureDBKey(manifest, syllabusVersionID)
        )
        // Also keep a JSON sidecar for backward-compat / external inspection.
        let url = try _fileURL(manifest: manifest, syllabusVersionID: syllabusVersionID)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(structure)
        try data.write(to: url, options: .atomic)
        // Invalidate cache for this key; next loadOrSeed will repopulate with the
        // correct paper-store fingerprint.
        _cacheLock.lock()
        _cache.removeValue(forKey: _cacheKey(manifest, syllabusVersionID))
        _cacheLock.unlock()
    }

    public static func fileURL(
        manifest: Inf6LearningFamilyManifest,
        syllabusVersionID: String
    ) throws -> URL {
        try _fileURL(manifest: manifest, syllabusVersionID: syllabusVersionID)
    }

    public static func deleteStructure(
        manifest: Inf6LearningFamilyManifest,
        syllabusVersionID: String
    ) throws {
        try _deleteStructureArtifacts(manifest: manifest, syllabusVersionID: syllabusVersionID)
    }

    private static func _fileURL(
        manifest: Inf6LearningFamilyManifest,
        syllabusVersionID: String
    ) throws -> URL {
        let root = try Inf6LibraryView._sharedRootDir()
        let versionKey = _sanitizeFileKey(syllabusVersionID)
        return root
            .appendingPathComponent("mma", isDirectory: true)
            .appendingPathComponent(manifest.sourceFamily, isDirectory: true)
            .appendingPathComponent("knowledge_structures", isDirectory: true)
            .appendingPathComponent(versionKey)
            .appendingPathExtension("json")
    }

    private static func _sanitizeFileKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "default" }
        let illegal = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let mapped = trimmed.unicodeScalars.map { illegal.contains($0) ? "_" : String($0) }.joined()
        let squashed = mapped.replacingOccurrences(of: " ", with: "_")
        return squashed.isEmpty ? "default" : squashed
    }

    private static func _deleteStructureArtifacts(
        manifest: Inf6LearningFamilyManifest,
        syllabusVersionID: String
    ) throws {
        Inf6MetadataStore.delete(
            domain: .syllabus,
            key: _structureDBKey(manifest, syllabusVersionID)
        )
        Inf6MetadataStore.delete(
            domain: .syllabus,
            key: _seedFingerprintDBKey(manifest, syllabusVersionID)
        )
        let url = try _fileURL(manifest: manifest, syllabusVersionID: syllabusVersionID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        _cacheLock.lock()
        _cache.removeValue(forKey: _cacheKey(manifest, syllabusVersionID))
        _cacheLock.unlock()
    }

    private static func _readStoredStructureIfPresent(
        manifest: Inf6LearningFamilyManifest,
        syllabusVersionID: String
    ) throws -> Inf6KnowledgeDomainStructure? {
        if let stored = Inf6MetadataStore.getCodable(
            Inf6KnowledgeDomainStructure.self,
            domain: .syllabus,
            key: _structureDBKey(manifest, syllabusVersionID)
        ) {
            return stored
        }
        let url = try _fileURL(manifest: manifest, syllabusVersionID: syllabusVersionID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try _readSidecarStructure(from: url)
    }

    private static func _legacyKnowledgeStructureVersionIDs(
        for manifest: Inf6LearningFamilyManifest,
        canonicalVersionID: String
    ) -> [String] {
        guard let examName = _examScheduleName(for: manifest),
              let info = Inf6SyllabusUpdateChecker.shared.examScheduleInfo(for: examName) else {
            return []
        }
        return info.legacyKnowledgeStructureVersionIDs.filter { $0 != canonicalVersionID }
    }

    private static func _examScheduleName(for manifest: Inf6LearningFamilyManifest) -> String? {
        switch manifest.familyID {
        case "e-shikaku":
            return "E資格"
        case "g-kentei":
            return "G検定"
        case "ai-102":
            return "AI-102"
        case "ai-103":
            return "AI-103"
        default:
            return nil
        }
    }

    private static func _structureByReplacingSyllabusVersionID(
        _ structure: Inf6KnowledgeDomainStructure,
        manifest: Inf6LearningFamilyManifest,
        domainTitleJa: String,
        from oldVersionID: String,
        to newVersionID: String
    ) -> Inf6KnowledgeDomainStructure {
        let canonicalVersionID = newVersionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldVersionNodeID = "syllabus:\(oldVersionID)"
        let newVersionNodeID = "syllabus:\(canonicalVersionID)"
        let versionTitleEn = _englishTextOrEmpty(canonicalVersionID).isEmpty
            ? manifest.displayNameEn
            : canonicalVersionID

        var nodes = structure.nodes
        for index in nodes.indices {
            if nodes[index].kind == .syllabusVersion || nodes[index].nodeID == oldVersionNodeID {
                nodes[index].nodeID = newVersionNodeID
                nodes[index].titleJa = canonicalVersionID
                nodes[index].titleEn = versionTitleEn
                nodes[index].liveContext = _defaultLiveContext(
                    manifest: manifest,
                    syllabusVersionID: canonicalVersionID,
                    domainTitleJa: domainTitleJa,
                    kind: .syllabusVersion,
                    titleJa: canonicalVersionID,
                    titleEn: versionTitleEn,
                    summaryJa: nodes[index].summaryJa
                )
            }
            if nodes[index].parentNodeID == oldVersionNodeID {
                nodes[index].parentNodeID = newVersionNodeID
            }
        }

        var papers = structure.papers
        for index in papers.indices {
            papers[index].syllabusNodeIDs = papers[index].syllabusNodeIDs.map {
                $0 == oldVersionNodeID ? newVersionNodeID : $0
            }
        }

        var edges = structure.edges
        for index in edges.indices {
            if edges[index].fromNodeID == oldVersionNodeID {
                edges[index].fromNodeID = newVersionNodeID
            }
            if edges[index].toNodeID == oldVersionNodeID {
                edges[index].toNodeID = newVersionNodeID
            }
        }

        return Inf6KnowledgeDomainStructure(
            domainID: structure.domainID,
            syllabusVersionID: canonicalVersionID,
            nodes: nodes,
            papers: papers,
            edges: edges
        )
    }

    private static func _buildOutlineStructure(
        manifest: Inf6LearningFamilyManifest,
        syllabusVersionID: String,
        domainTitleJa: String,
        outlineItems: [Inf6SyllabusOutlineItem]
    ) throws -> Inf6KnowledgeDomainStructure {
        let outlineItems = try _outlineItemsWithRequiredBilingualData(outlineItems, familyID: manifest.familyID)
        let domainNodeID = "domain:\(manifest.familyID)"
        let versionNodeID = "syllabus:\(syllabusVersionID)"
        let defaultAction = manifest.entryActions.first?.phase ?? .organize

        var nodes: [Inf6KnowledgeNode] = [
            Inf6KnowledgeNode(
                nodeID: domainNodeID,
                parentNodeID: nil,
                kind: .domain,
                depth: 0,
                titleJa: domainTitleJa,
                titleEn: manifest.displayNameEn,
                summaryJa: "\(domainTitleJa) の知識構造です。",
                summaryEn: "Knowledge structure for \(manifest.displayNameEn).",
                paperCount: 0,
                achievement: .notStarted,
                importance: "high",
                nextAction: defaultAction,
                linkedPaperIDs: [],
                liveContext: _defaultLiveContext(
                    manifest: manifest,
                    syllabusVersionID: syllabusVersionID,
                    domainTitleJa: domainTitleJa,
                    kind: .domain,
                    titleJa: domainTitleJa,
                    titleEn: manifest.displayNameEn,
                    summaryJa: "\(domainTitleJa) の知識構造です。"
                )
            ),
            Inf6KnowledgeNode(
                nodeID: versionNodeID,
                parentNodeID: domainNodeID,
                kind: .syllabusVersion,
                depth: 1,
                titleJa: syllabusVersionID,
                titleEn: _englishTextOrEmpty(syllabusVersionID).isEmpty ? manifest.displayNameEn : syllabusVersionID,
                summaryJa: "現在選択中のシラバス版です。",
                summaryEn: "Currently selected syllabus version.",
                paperCount: 0,
                achievement: .notStarted,
                importance: "high",
                nextAction: defaultAction,
                linkedPaperIDs: [],
                liveContext: _defaultLiveContext(
                    manifest: manifest,
                    syllabusVersionID: syllabusVersionID,
                    domainTitleJa: domainTitleJa,
                    kind: .syllabusVersion,
                    titleJa: syllabusVersionID,
                    titleEn: _englishTextOrEmpty(syllabusVersionID).isEmpty ? manifest.displayNameEn : syllabusVersionID,
                    summaryJa: "現在選択中のシラバス版です。"
                )
            )
        ]

        var parentNodeIDs: [Int: String] = [0: versionNodeID]

        for item in outlineItems {
            let depth = max(0, item.effectiveDepth)
            let parentID = depth == 0 ? versionNodeID : (parentNodeIDs[depth - 1] ?? versionNodeID)
            let kind: Inf6KnowledgeNodeKind = {
                switch depth {
                case 0: return .major
                case 1: return .minor
                default: return .topic
                }
            }()
            let importance: String = {
                switch depth {
                case 0: return "high"
                case 1: return "medium"
                default: return "normal"
                }
            }()
            let node = Inf6KnowledgeNode(
                nodeID: item.key,
                parentNodeID: parentID,
                kind: kind,
                depth: depth + 2,
                titleJa: item.titleJa ?? item.title,
                titleEn: _englishTextOrEmpty(item.titleEn),
                summaryJa: item.summaryJa ?? item.summary ?? "",
                summaryEn: _englishTextOrEmpty(item.summaryEn),
                paperCount: 0,
                achievement: .notStarted,
                importance: importance,
                nextAction: defaultAction,
                linkedPaperIDs: [],
                liveContext: _defaultLiveContext(
                    manifest: manifest,
                    syllabusVersionID: syllabusVersionID,
                    domainTitleJa: domainTitleJa,
                    kind: kind,
                    titleJa: item.titleJa ?? item.title,
                    titleEn: _englishTextOrEmpty(item.titleEn),
                    summaryJa: item.summaryJa ?? item.summary ?? ""
                )
            )
            nodes.append(node)
            parentNodeIDs[depth] = node.nodeID
            let deeperKeys = parentNodeIDs.keys.filter { $0 > depth }
            for key in deeperKeys {
                parentNodeIDs.removeValue(forKey: key)
            }
        }

        return Inf6KnowledgeDomainStructure(
            domainID: manifest.familyID,
            syllabusVersionID: syllabusVersionID,
            nodes: nodes,
            papers: []
        )
    }

    private static func _outlineItemsWithRequiredBilingualData(
        _ outlineItems: [Inf6SyllabusOutlineItem],
        familyID: String
    ) throws -> [Inf6SyllabusOutlineItem] {
        let bundled = _bundledCircuitBoardNodeEnglishTitles(familyID: familyID)
        var missing: [String] = []
        let conceptItems = outlineItems.filter { item in
            !_isNonConceptSyllabusTitle(item.titleJa ?? item.title)
        }
        let items = conceptItems.map { item in
            let existingTitleEn = _englishTextOrEmpty(item.titleEn)
            let titleJa = item.titleJa ?? item.title
            let titleEn = existingTitleEn.isEmpty
                ? (
                    bundled.byNodeID[item.key]
                    ?? bundled.byTitleJa[titleJa]
                    ?? _syllabusGlossaryTitleEN(titleJa)
                    ?? ""
                )
                : existingTitleEn
            if titleJa.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || titleEn.isEmpty {
                missing.append("\(item.key): \(titleJa)")
            }
            return Inf6SyllabusOutlineItem(
                key: item.key,
                title: item.title,
                summary: item.summary,
                titleJa: item.titleJa,
                titleEn: titleEn.isEmpty ? item.titleEn : titleEn,
                summaryJa: item.summaryJa,
                summaryEn: item.summaryEn,
                depth: item.depth
            )
        }
        guard missing.isEmpty else {
            throw NSError(
                domain: "Inf6MeridianMasteryAuthoring",
                code: 6,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "syllabus bilingual title is missing:\n\(missing.prefix(24).joined(separator: "\n"))"
                ]
            )
        }
        return items
    }

    private static func _syllabusGlossaryTitleEN(_ titleJa: String) -> String? {
        let key = _normalizedSyllabusTitleKey(titleJa)
        guard !key.isEmpty else { return nil }
        for candidate in _syllabusTitleKeyCandidates(key) {
            if let exact = _syllabusTitleGlossaryEN[candidate] {
                return exact
            }
        }
        if key.range(of: #"^\([A-Za-z0-9 ._+/#:-]+\)$"#, options: .regularExpression) != nil {
            let unwrapped = String(key.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            if let exact = _syllabusTitleGlossaryEN[unwrapped] {
                return exact
            }
            if !unwrapped.isEmpty {
                return unwrapped
            }
        }
        if key.range(of: #"^[A-Za-z0-9][A-Za-z0-9 ._+/#():-]*$"#, options: .regularExpression) != nil {
            return key
        }
        return nil
    }

    private static func _syllabusTitleKeyCandidates(_ key: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ raw: String) {
            let normalized = _normalizedSyllabusTitleKey(raw)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return }
            out.append(normalized)
        }

        add(key)
        add(key.replacingOccurrences(of: #"^\([0-9]+\)\s*"#, with: "", options: .regularExpression))
        add(key.replacingOccurrences(of: #"^[0-9]+[.)]\s*"#, with: "", options: .regularExpression))
        add(key.replacingOccurrences(of: #"[①②③④⑤⑥⑦⑧⑨⑩]$"#, with: "", options: .regularExpression))
        add(key.replacingOccurrences(of: #"(?<=\p{Han}|[ぁ-んァ-ン])\s+(?=\p{Han}|[ぁ-んァ-ン])"#, with: "", options: .regularExpression))
        add(key.replacingOccurrences(of: #"(?<=AI)\s+(?=[^\s])"#, with: "", options: .regularExpression))
        add(key.replacingOccurrences(of: #"(?<=Azure)\s+(?=[^\s])"#, with: "", options: .regularExpression))
        return out
    }

    private static func _normalizedSyllabusTitleKey(_ title: String) -> String {
        return title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
            .replacingOccurrences(of: "　", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*,\s*$"#, with: "", options: .regularExpression)
    }

    private static func _isNonConceptSyllabusTitle(_ title: String) -> Bool {
        let key = _normalizedSyllabusTitleKey(title)
        let withoutNumberPrefix = key.replacingOccurrences(
            of: #"^[0-9]+[.)]?\s*"#,
            with: "",
            options: .regularExpression
        )
        return key.hasPrefix("※")
            || key.contains("出題対象外")
            || key.contains("シラバス") && key.contains("新規作成")
            || withoutNumberPrefix.hasPrefix("以下のキーワード")
    }

    private static let _syllabusTitleGlossaryEN: [String: String] = [
        "人工知能とは": "Artificial intelligence",
        "人工知能の定義": "Definition of artificial intelligence",
        "人工知能分野で議論される問題": "Issues discussed in artificial intelligence",
        "人工知能をめぐる動向": "Trends in artificial intelligence",
        "探索・推論": "Search and reasoning",
        "知識表現とエキスパートシステム": "Knowledge representation and expert systems",
        "機械学習": "Machine learning",
        "機械学習の概要": "Machine learning overview",
        "機械学習の基礎": "Machine learning foundations",
        "教師あり学習": "Supervised learning",
        "教師なし学習": "Unsupervised learning",
        "半教師あり学習": "Semi-supervised learning",
        "強化学習": "Reinforcement learning",
        "モデルの選択・評価": "Model selection and evaluation",
        "深層学習": "Deep learning",
        "ディープラーニング": "Deep learning",
        "ディープラーニングの概要": "Deep learning overview",
        "ニューラルネットワークとディープラーニング": "Neural networks and deep learning",
        "ニューラルネットワーク": "Neural networks",
        "活性化関数": "Activation functions",
        "誤差関数": "Loss functions",
        "損失関数": "Loss functions",
        "正則化": "Regularization",
        "正規化": "Normalization",
        "正規化・正則化": "Normalization and regularization",
        "誤差逆伝播法": "Backpropagation",
        "最適化手法": "Optimization methods",
        "最適化": "Optimization",
        "ディープラーニングの要素技術": "Deep learning components",
        "全結合層": "Fully connected layers",
        "畳み込み層": "Convolutional layers",
        "畳み込みニューラルネットワーク": "Convolutional neural networks",
        "正規化層": "Normalization layers",
        "プーリング層": "Pooling layers",
        "スキップ結合": "Skip connections",
        "回帰結合層": "Recurrent layers",
        "回帰結合": "Recurrent connections",
        "Attention": "Attention",
        "アテンション": "Attention",
        "注意機構": "Attention mechanism",
        "オートエンコーダ": "Autoencoders",
        "データ拡張": "Data augmentation",
        "ディープラーニングの応用例": "Deep learning applications",
        "画像認識": "Image recognition",
        "自然言語処理": "Natural language processing",
        "音声処理": "Speech processing",
        "深層強化学習": "Deep reinforcement learning",
        "データ生成": "Data generation",
        "転移学習": "Transfer learning",
        "ファインチューニング": "Fine-tuning",
        "マルチモーダル": "Multimodal learning",
        "モデルの解釈性": "Model interpretability",
        "モデルの軽量化": "Model compression",
        "人工知能の社会実装": "Social implementation of AI",
        "AI プロジェクトの進め方": "Managing AI projects",
        "データの収集・加工・分析・学習": "Data collection, processing, analysis, and training",
        "数理・統計": "Mathematics and statistics",
        "AI に関する法律と契約": "Laws and contracts related to AI",
        "個人情報保護法": "Personal Information Protection Act",
        "著作権法": "Copyright Act",
        "特許法": "Patent Act",
        "不正競争防止法": "Unfair Competition Prevention Act",
        "独占禁止法": "Antimonopoly Act",
        "AI 開発委託契約": "AI development contracts",
        "AI サービス提供契約": "AI service contracts",
        "AI 倫理・AI ガバナンス": "AI ethics and AI governance",
        "国内外のガイドライン": "Domestic and international guidelines",
        "プライバシー": "Privacy",
        "公平性": "Fairness",
        "安全性とセキュリティ": "Safety and security",
        "悪用": "Misuse",
        "透明性": "Transparency",
        "民主主義": "Democracy",
        "環境保護": "Environmental protection",
        "労働政策": "Labor policy",
        "その他の重要な価値": "Other important values",
        "AI ガバナンス": "AI governance",
        "数学的基礎": "Mathematical foundations",
        "応用数学": "Applied mathematics",
        "線形代数": "Linear algebra",
        "行列演算": "Matrix operations",
        "行列・テンソルの積": "Matrix and tensor products",
        "内積": "Inner product",
        "テンソルの積": "Tensor product",
        "勾配・統計": "Gradients and statistics",
        "固有値分解・特異値分解": "Eigenvalue decomposition and singular value decomposition",
        "微分積分学": "Calculus",
        "確率・統計": "Probability and statistics",
        "確率の基礎": "Fundamentals of probability",
        "ベルヌーイ分布・多項分布": "Bernoulli distribution and multinomial distribution",
        "ガウス分布": "Gaussian distribution",
        "確率モデルにおけるパラメータ推定": "Parameter estimation in probabilistic models",
        "情報理論": "Information theory",
        "パターン認識": "Pattern recognition",
        "k近傍法・近傍法": "k-nearest neighbors and nearest neighbor methods",
        "距離計算": "Distance calculation",
        "深層学習の基礎": "Deep learning foundations",
        "深層学習の基礎(順伝播型ネットワーク)": "Deep learning foundations (feedforward networks)",
        "順伝播型ネットワーク": "Feedforward networks",
        "深層モデルのための最適化": "Optimization for deep models",
        "機械学習の分類": "Classification of machine learning methods",
        "線形回帰": "Linear regression",
        "Lasso 回帰・Ridge 回帰": "Lasso regression and Ridge regression",
        "畳み込みネットワーク": "Convolutional networks",
        "系列モデル": "Sequence models",
        "Transformer": "Transformer",
        "生成モデル": "Generative models",
        "深層学習の適応方法": "Deep learning adaptation methods",
        "深層学習の説明性": "Explainability of deep learning",
        "深層学習の応用": "Deep learning applications",
        "画像認識タスク": "Image recognition tasks",
        "物体検出": "Object detection",
        "セグメンテーション": "Segmentation",
        "自然言語処理タスク": "Natural language processing tasks",
        "音声認識": "Speech recognition",
        "推薦システム": "Recommendation systems",
        "強化学習の応用": "Applications of reinforcement learning",
        "開発・運用環境": "Development and operations environment",
        "深層学習フレームワーク": "Deep learning frameworks",
        "アクセラレータ": "Accelerators",
        "分散処理": "Distributed processing",
        "エッジコンピューティング": "Edge computing",
        "大規模言語モデル": "Large language models",
        "生成 AI": "Generative AI",
        "検索拡張生成": "Retrieval-augmented generation",
        "自己回帰モデル": "Autoregressive models",
        "汎化性能向上のためのテクニック": "Techniques for improving generalization performance",
        "データ集合の拡張": "Dataset augmentation",
        "画像のデータ拡張": "Image data augmentation",
        "音声のデータ拡張": "Audio data augmentation",
        "ILM": "ILM",
        "AI開発委託契約": "AI development contracts",
        "AIサービス提供契約": "AI service contracts",
        "AIガバナンス": "AI governance",
        "AI に必要な数理・統計知識": "Mathematics and statistics required for AI",
        "転移学習・ファインチューニング": "Transfer learning and fine-tuning",
        "行列演習": "Matrix exercises",
        "勾配": "Gradient",
        "一般的な確率分布": "Common probability distributions",
        "ガウス分布・t分布": "Gaussian distribution and t-distribution",
        "深層モデルのための正則化": "Regularization for deep models",
        "機械学習の課題": "Machine learning challenges",
        "回帰": "Regression",
        "Lasso回帰・Ridge回帰": "Lasso regression and Ridge regression",
        "ロジスティック回帰": "Logistic regression",
        "サポートベクターマシン": "Support vector machines",
        "決定木 Random Forest": "Decision trees and Random Forest",
        "勾配ブースティング": "Gradient boosting",
        "次元圧縮": "Dimensionality reduction",
        "クラスタリング": "Clustering",
        "過剰適合・過少適合": "Overfitting and underfitting",
        "検証集合": "Validation set",
        "訓練データ・検証データ・テストデータ": "Training, validation, and test data",
        "交差検証": "Cross-validation",
        "性能指標": "Performance metrics",
        "多層パーセプトロン": "Multilayer perceptron",
        "出力層と損失関数": "Output layers and loss functions",
        "2値分類": "Binary classification",
        "多クラス分類": "Multiclass classification",
        "マルチラベル分類": "Multilabel classification",
        "シグモイド関数 ReLU": "Sigmoid function and ReLU",
        "Leaky ReLU tanh (2)深層モデルのための最適化": "Leaky ReLU and tanh; optimization for deep models",
        "基本的なアルゴリズム": "Basic algorithms",
        "確率的勾配降下法(SGD)": "Stochastic gradient descent (SGD)",
        "モメンタム": "Momentum",
        "自動微分": "Automatic differentiation",
        "適応的な学習率を持つアルゴリズム": "Algorithms with adaptive learning rates",
        "パラメータの初期化戦略": "Parameter initialization strategies",
        "パラメータノルムペナルティー": "Parameter norm penalties",
        "確率的削除": "Dropout",
        "陰的正則化": "Implicit regularization",
        "基本的な畳み込み演算": "Basic convolution operations",
        "リカレントニューラルネットワーク": "Recurrent neural networks",
        "ゲート機構": "Gating mechanisms",
        "系列変換": "Sequence transduction",
        "アンサンブル手法": "Ensemble methods",
        "ハイパーパラメータの選択": "Hyperparameter selection",
        "基本的なハイパーパラメータ調整": "Basic hyperparameter tuning",
        "ハイパーパラメータの最適化": "Hyperparameter optimization",
        "セマンティックセグメンテーション": "Semantic segmentation",
        "サンプリング、短時間フーリエ変換、メル尺度": "Sampling, short-time Fourier transform, and mel scale",
        "識別モデルと生成モデル": "Discriminative models and generative models",
        "基本的なGAN": "Basic GAN",
        "条件付きGAN": "Conditional GAN",
        "深層強化学習のモデル": "Deep reinforcement learning models",
        "様々な学習方法": "Various learning methods",
        "ドメイン適応 (domain adaptation)": "Domain adaptation",
        "半教師あり学習と自己教師あり学習": "Semi-supervised learning and self-supervised learning",
        "能動学習(Active": "Active learning",
        "距離学習(Metric": "Metric learning",
        "Learning) 2サンプルによる比較 表現学習": "Learning from sample pairs and representation learning",
        "メタ学習(Meta": "Meta-learning",
        "Learning) 初期値の獲得 MAML": "Learning initial parameters and MAML",
        "メタ目的関数(meta-objective)": "Meta-objective",
        "判断根拠の可視化": "Visualization of decision rationale",
        "モデルの近似": "Model approximation",
        "局所的な解釈": "Local interpretation",
        "大域的な解釈": "Global interpretation",
        "IoTデバイス": "IoT devices",
        "プルーニング(枝刈り)": "Pruning",
        "並列分散処理": "Parallel and distributed processing",
        "分散深層学習": "Distributed deep learning",
        "モデル並列化": "Model parallelism",
        "データ並列化": "Data parallelism",
        "連合学習(Federated": "Federated learning",
        "learning) クロスデバイス学習": "Cross-device federated learning",
        "クロスサイロ学習": "Cross-silo learning",
        "デバイスによる高速化": "Device acceleration",
        "環境構築": "Environment setup",
        "コンテナ型仮想化": "Container-based virtualization",
        "仮想化環境": "Virtualized environments",
        "ホスト型": "Hosted virtualization",
        "ハイパーバイザー型": "Hypervisor-based virtualization",
        "コンテナ型": "Container-based virtualization",
        "キーワード": "Keywords"
    ]

    static func englishSyllabusTitle(_ title: String) -> String? {
        _syllabusTitleGlossaryEN[_normalizedSyllabusTitleKey(title)]
    }

    private static func _bundledCircuitBoardNodeEnglishTitles(
        familyID: String
    ) -> (byNodeID: [String: String], byTitleJa: [String: String]) {
        guard let url = Bundle.main.url(forResource: "cb_slim", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return ([:], [:])
        }

        var byNodeID: [String: String] = [:]
        var byTitleJa: [String: String] = [:]
        for domain in root {
            guard (domain["domain_id"] as? String) == familyID,
                  let nodes = domain["nodes"] as? [[String: Any]] else { continue }
            for node in nodes {
                guard let nodeID = node["node_id"] as? String,
                      let titleJa = node["title_ja"] as? String,
                      let titleEn = node["title_en"] as? String else { continue }
                let trimmedEn = _englishTextOrEmpty(titleEn)
                guard !trimmedEn.isEmpty else { continue }
                byNodeID[nodeID] = trimmedEn
                byTitleJa[titleJa] = trimmedEn
            }
        }
        return (byNodeID, byTitleJa)
    }

    private static func _buildPaperLinkedStructure(
        manifest: Inf6LearningFamilyManifest,
        syllabusVersionID: String,
        domainTitleJa: String,
        outlineItems: [Inf6SyllabusOutlineItem],
        sourceLinks: [Inf6SyllabusPaperLink],
        paperStore: Inf6CorePaperStore
    ) throws -> Inf6KnowledgeDomainStructure {
        let domainNodeID = "domain:\(manifest.familyID)"
        let versionNodeID = "syllabus:\(syllabusVersionID)"
        let defaultAction = manifest.entryActions.first?.phase ?? .collect
        var structure = try _buildOutlineStructure(
            manifest: manifest,
            syllabusVersionID: syllabusVersionID,
            domainTitleJa: domainTitleJa,
            outlineItems: outlineItems
        )
        var nodes = structure.nodes
        var linkedPaperIDsByNodeID: [String: [String]] = [:]
        for link in sourceLinks {
            if !(linkedPaperIDsByNodeID[link.syllabusNodeID] ?? []).contains(link.paperID) {
                linkedPaperIDsByNodeID[link.syllabusNodeID, default: []].append(link.paperID)
            }
        }
        let sourceLinkedPaperIDs = Set(sourceLinks.map(\.paperID))
        let allPaperIDs = paperStore.papers.map(\.id).filter { sourceLinkedPaperIDs.contains($0) }
        let achievementsByPaperID = _achievementByPaperID(store: paperStore)
        let allAchievement = _aggregateAchievement(forPaperIDs: allPaperIDs, achievementsByPaperID: achievementsByPaperID)
        for index in nodes.indices where nodes[index].nodeID == domainNodeID || nodes[index].nodeID == versionNodeID {
            nodes[index].paperCount = allPaperIDs.count
            nodes[index].achievement = allAchievement
            nodes[index].nextAction = defaultAction
            nodes[index].linkedPaperIDs = allPaperIDs
        }
        var paperNodeIDsByPaperID: [String: [String]] = [:]

        let papersByID = Dictionary(uniqueKeysWithValues: paperStore.papers.map { ($0.id, $0) })
        for item in outlineItems {
            let searchedPaperIDs = (linkedPaperIDsByNodeID[item.key] ?? [])
                .filter { papersByID[$0] != nil }
            guard !searchedPaperIDs.isEmpty else { continue }
            guard let nodeIndex = nodes.firstIndex(where: { $0.nodeID == item.key }) else {
                throw NSError(
                    domain: "Inf6MeridianMasteryAuthoring",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "searched paper target is missing from structure: \(item.key)"]
                )
            }

            let existingIDs = Set(nodes[nodeIndex].linkedPaperIDs)
            let mergedPaperIDs = nodes[nodeIndex].linkedPaperIDs + searchedPaperIDs.filter { !existingIDs.contains($0) }
            nodes[nodeIndex].paperCount = mergedPaperIDs.count
            nodes[nodeIndex].achievement = _aggregateAchievement(forPaperIDs: mergedPaperIDs, achievementsByPaperID: achievementsByPaperID)
            nodes[nodeIndex].nextAction = defaultAction
            nodes[nodeIndex].linkedPaperIDs = mergedPaperIDs

            for paperID in searchedPaperIDs {
                guard let paper = papersByID[paperID] else { continue }
                let nodeID = "paper:\(item.key):\(paper.id)"
                guard !nodes.contains(where: { $0.nodeID == nodeID }) else { continue }
                if !(paperNodeIDsByPaperID[paper.id] ?? []).contains(item.key) {
                    paperNodeIDsByPaperID[paper.id, default: []].append(item.key)
                }
                let paperAchievement = achievementsByPaperID[paper.id] ?? .notStarted
                guard let paperTitleEn = paper.titleEn, !paperTitleEn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw NSError(
                        domain: "Inf6MeridianMasteryAuthoring",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "paper title_en is missing: \(paper.id)"]
                    )
                }
                nodes.append(
                    Inf6KnowledgeNode(
                        nodeID: nodeID,
                        parentNodeID: item.key,
                        kind: .paper,
                        depth: 3,
                        titleJa: paper.title,
                        titleEn: paperTitleEn,
                        summaryJa: paper.tags.joined(separator: " / "),
                        summaryEn: paper.tags.joined(separator: " / "),
                        paperCount: 1,
                        achievement: paperAchievement,
                        importance: "medium",
                        nextAction: .organize,
                        linkedPaperIDs: [paper.id],
                        liveContext: nil,
                        contextMode: .static
                    )
                )
            }
        }

        let papers: [Inf6KnowledgePaperLink] = paperStore.papers
            .filter { sourceLinkedPaperIDs.contains($0.id) }
            .map { paper in
            Inf6KnowledgePaperLink(
                paperID: paper.id,
                paperTitle: paper.title,
                providerID: paper.provider,
                syllabusNodeIDs: paperNodeIDsByPaperID[paper.id] ?? [],
                achievement: achievementsByPaperID[paper.id] ?? .notStarted,
                knowledgeCount: paperStore.progress[paper.id]?.masteryScore ?? 0
            )
        }

        return Inf6KnowledgeDomainStructure(
            domainID: manifest.familyID,
            syllabusVersionID: syllabusVersionID,
            nodes: nodes,
            papers: papers
        )
    }

    private static func _mergeSeededBilingualFieldsAndLiveContext(
        _ existing: Inf6KnowledgeDomainStructure,
        seeded: Inf6KnowledgeDomainStructure
    ) throws -> Inf6KnowledgeDomainStructure {
        let existingByNodeID = Dictionary(uniqueKeysWithValues: existing.nodes.map { ($0.nodeID, $0) })
        var mergedNodes = try seeded.nodes.map { seededNode -> Inf6KnowledgeNode in
            guard let existingNode = existingByNodeID[seededNode.nodeID] else {
                return seededNode
            }
            var copy = seededNode
            if copy.titleEn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let existingTitleEn = existingNode.titleEn.trimmingCharacters(in: .whitespacesAndNewlines)
                if existingTitleEn.isEmpty {
                    throw NSError(
                        domain: "Inf6MeridianMasteryAuthoring",
                        code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "seeded title_en is missing: \(copy.nodeID)"]
                    )
                }
                copy.titleEn = existingTitleEn
            }
            copy.achievement = existingNode.achievement
            if let liveContext = existingNode.liveContext {
                copy.liveContext = liveContext
            }
            copy.contextMode = existingNode.contextMode
            let existingPaperIDs = Set(existingNode.linkedPaperIDs)
            if !existingPaperIDs.isSubset(of: Set(copy.linkedPaperIDs)) {
                copy.linkedPaperIDs += existingNode.linkedPaperIDs.filter { !copy.linkedPaperIDs.contains($0) }
                copy.paperCount = copy.linkedPaperIDs.count
            }
            return copy
        }
        let mergedNodeIDs = Set(mergedNodes.map(\.nodeID))
        let preservedNodes = existing.nodes.filter { !mergedNodeIDs.contains($0.nodeID) }
        mergedNodes += preservedNodes
        if !preservedNodes.isEmpty {
            NSLog(
                "[Inf6KnowledgeDomainStructureStore] preserved %d existing nodes missing from seeded structure",
                preservedNodes.count
            )
        }
        var papersByID = Dictionary(uniqueKeysWithValues: seeded.papers.map { ($0.paperID, $0) })
        for existingPaper in existing.papers {
            if var paper = papersByID[existingPaper.paperID] {
                paper.syllabusNodeIDs += existingPaper.syllabusNodeIDs.filter { !paper.syllabusNodeIDs.contains($0) }
                paper.knowledgeCount = max(paper.knowledgeCount, existingPaper.knowledgeCount)
                papersByID[paper.paperID] = paper
            } else {
                papersByID[existingPaper.paperID] = existingPaper
            }
        }
        let mergedPapers = papersByID.values.sorted {
            $0.paperID.localizedStandardCompare($1.paperID) == .orderedAscending
        }
        var edgesByID = Dictionary(uniqueKeysWithValues: seeded.edges.map { ($0.id, $0) })
        for existingEdge in existing.edges where edgesByID[existingEdge.id] == nil {
            edgesByID[existingEdge.id] = existingEdge
        }
        let mergedEdges = edgesByID.values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        return Inf6KnowledgeDomainStructure(
            domainID: seeded.domainID,
            syllabusVersionID: seeded.syllabusVersionID,
            nodes: mergedNodes,
            papers: mergedPapers,
            edges: mergedEdges
        )
    }

    /// `context_mode` のデフォルト値を返す。paper は `.static`、それ以外は `.live`。
    /// LLM による ContextModeDesign フェーズで上書きされる。
    static func defaultContextMode(for kind: Inf6KnowledgeNodeKind) -> Inf6KnowledgeContextMode {
        kind == .paper ? .static : .live
    }

    private static func _defaultLiveContext(
        manifest: Inf6LearningFamilyManifest,
        syllabusVersionID: String,
        domainTitleJa: String,
        kind: Inf6KnowledgeNodeKind,
        titleJa: String,
        titleEn: String,
        summaryJa: String
    ) -> Inf6KnowledgeLiveContextSpec? {
        guard kind != .paper else { return nil }

        let trimmedTitleJa = titleJa.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitleEn = titleEn.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummaryJa = summaryJa.trimmingCharacters(in: .whitespacesAndNewlines)

        let queryJa: String
        let queryEn: String
        let focusJa: String
        let focusEn: String

        switch kind {
        case .domain:
            queryJa = "\(domainTitleJa) 最新動向 重要論点 公式情報"
            queryEn = "\(trimmedTitleEn) latest trends key topics official sources"
            focusJa = "\(domainTitleJa) 全体について、最新の事実、最近の動き、いま優先して見るべき判断を自由文で整理してください。"
            focusEn = "Summarize the latest facts, recent changes, and what matters now for the overall domain."
        case .syllabusVersion:
            queryJa = "\(domainTitleJa) \(syllabusVersionID) シラバス 改定 出題範囲 変更点"
            queryEn = "\(trimmedTitleEn) syllabus revision scope changes latest"
            focusJa = "\(syllabusVersionID) の適用範囲、改定点、いま注意すべき変更点を自由文で整理してください。"
            focusEn = "Summarize the applicable scope, revisions, and changes that matter now for this syllabus version."
        case .major, .minor, .topic:
            queryJa = "\(domainTitleJa) \(trimmedTitleJa) 最新動向 重要論点 公式情報"
            queryEn = "\(trimmedTitleEn) latest trends key points official sources"
            focusJa = trimmedSummaryJa.isEmpty
                ? "\(trimmedTitleJa) について、最新の事実、最近の動き、いまどう判断すべきかを自由文で整理してください。"
                : "\(trimmedTitleJa)（\(trimmedSummaryJa)）について、最新の事実、最近の動き、いまどう判断すべきかを自由文で整理してください。"
            focusEn = "Summarize the latest facts, recent changes, and what should be judged now for \(trimmedTitleEn)."
        case .paper:
            return nil
        }

        return Inf6KnowledgeLiveContextSpec(
            queryJa: queryJa,
            queryEn: queryEn,
            focusJa: focusJa,
            focusEn: focusEn
        )
    }

    private static func _aggregateAchievement(
        forPaperIDs paperIDs: [String],
        achievementsByPaperID: [String: Inf6KnowledgeAchievementState]
    ) -> Inf6KnowledgeAchievementState {
        guard !paperIDs.isEmpty else { return .notStarted }
        let states = paperIDs.map { paperID in
            achievementsByPaperID[paperID] ?? .notStarted
        }
        return _aggregateAchievement(states)
    }

    private static func _achievementByPaperID(
        store: Inf6CorePaperStore
    ) -> [String: Inf6KnowledgeAchievementState] {
        store.achievementByPaperID(
            assetsPipelineStates: store.assetsPipelineStateByPaperID(),
            learningArtifactStates: store.learningArtifactStateByPaperID()
        )
    }

    private static func _achievement(from status: Inf6CorePaperStatus) -> Inf6KnowledgeAchievementState {
        switch status {
        case .notStarted:
            return .notStarted
        case .reading:
            return .reading
        case .done:
            return .measured
        }
    }

    private static func _aggregateAchievement(_ states: [Inf6KnowledgeAchievementState]) -> Inf6KnowledgeAchievementState {
        guard !states.isEmpty else { return .notStarted }
        let avg = states.map(_achievementFraction).reduce(0, +) / Double(states.count)
        if avg >= 0.95 { return .measured }
        if avg >= 0.74 { return .questioned }
        if avg >= 0.58 { return .explained }
        if avg >= 0.42 { return .annotating }
        if avg >= 0.24 { return .reading }
        if avg > 0 { return .collecting }
        return .notStarted
    }

    private static func _achievementFraction(_ state: Inf6KnowledgeAchievementState) -> Double {
        switch state {
        case .notStarted: return 0
        case .collecting: return 0.16
        case .reading: return 0.34
        case .annotating: return 0.50
        case .explained: return 0.66
        case .questioned: return 0.82
        case .measured: return 1.0
        }
    }
}

public enum Inf6SourceProviderID: String, Codable, Hashable, CaseIterable {
    case microsoftLearn = "microsoft_learn"
    case microsoftTechCommunity = "microsoft_techcommunity"
    case jdlaHTML = "jdla_html"
    case arxiv = "arxiv"
    case pubmed = "pubmed"
    case pdfImport = "pdf_import"
}

public enum Inf6MicrosoftLearnSourceRole: String, Codable, Hashable, Sendable {
    case wrapper = "wrapper"
    case current = "current"
    case lifecycle = "lifecycle"
    case legacyDetail = "legacy_detail"
    case discontinued = "discontinued"
    case unknown = "unknown"

    public var labelJa: String {
        switch self {
        case .wrapper:
            return "新ページラッパー"
        case .current:
            return "現行"
        case .lifecycle:
            return "資格ライフサイクル"
        case .legacyDetail:
            return "旧ページだが現行詳細を保持"
        case .discontinued:
            return "本当にディスコン"
        case .unknown:
            return "不明"
        }
    }
}

public struct Inf6MicrosoftLearnSourceDefinition: Codable, Hashable, Sendable {
    public var id: String
    public var topic: String
    public var title: String
    public var urlString: String
    public var roleHint: Inf6MicrosoftLearnSourceRole
    public var provider: String?

    public init(
        id: String,
        topic: String,
        title: String,
        urlString: String,
        roleHint: Inf6MicrosoftLearnSourceRole,
        provider: String? = nil
    ) {
        self.id = id
        self.topic = topic
        self.title = title
        self.urlString = urlString
        self.roleHint = roleHint
        self.provider = provider
    }
}

public struct Inf6LearningFamilyAction: Codable, Hashable, Sendable {
    public var phase: Inf6LearningFamilyActionPhase
    public var labelJa: String
    public var descriptionJa: String

    enum CodingKeys: String, CodingKey {
        case phase
        case labelJa = "label_ja"
        case descriptionJa = "description_ja"
    }

    public init(
        phase: Inf6LearningFamilyActionPhase,
        labelJa: String,
        descriptionJa: String
    ) {
        self.phase = phase
        self.labelJa = labelJa
        self.descriptionJa = descriptionJa
    }
}

public enum Inf6LearningFamilyLifecycleState: String, Codable, Hashable, Sendable {
    case active
    case retiring
    case retired
    case superseded
}

public struct Inf6LearningFamilyManifest: Codable, Hashable, Identifiable, Sendable {
    public var id: String { familyID }
    public var familyID: String
    public var displayNameJa: String
    public var displayNameEn: String
    public var providerDisplayNameJa: String
    public var providerDisplayNameEn: String
    public var accentColorHex: String
    public var sourceFamily: String
    public var lifecycleState: Inf6LearningFamilyLifecycleState
    public var retirementDate: String?
    public var successorFamilyID: String?
    public var goalKind: Inf6LearningGoalKind
    public var providers: [String]
    public var syllabusProviders: [String]
    public var contentProviders: [String]
    public var officialSources: [String]
    public var trendSources: [String]
    public var currentSources: [Inf6MicrosoftLearnSourceDefinition]?
    public var routeTokens: [String]?
    public var patternLibraryPath: String?
    public var forecastAuthoringPath: String?
    public var uiActions: [String]
    public var entryActions: [Inf6LearningFamilyAction]

    enum CodingKeys: String, CodingKey {
        case familyID = "family_id"
        case displayNameJa = "display_name_ja"
        case displayNameEn = "display_name_en"
        case providerDisplayNameJa = "provider_display_name_ja"
        case providerDisplayNameEn = "provider_display_name_en"
        case accentColorHex = "accent_color_hex"
        case sourceFamily = "source_family"
        case lifecycleState = "lifecycle_state"
        case retirementDate = "retirement_date"
        case successorFamilyID = "successor_family_id"
        case goalKind = "goal_kind"
        case providers
        case syllabusProviders = "syllabus_providers"
        case contentProviders = "content_providers"
        case officialSources = "official_sources"
        case trendSources = "trend_sources"
        case currentSources = "current_sources"
        case routeTokens = "route_tokens"
        case patternLibraryPath = "pattern_library_path"
        case forecastAuthoringPath = "forecast_authoring_path"
        case uiActions = "ui_actions"
        case entryActions = "entry_actions"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        familyID = try c.decode(String.self, forKey: .familyID)
        displayNameJa = try c.decode(String.self, forKey: .displayNameJa)
        displayNameEn = try c.decode(String.self, forKey: .displayNameEn)
        providerDisplayNameJa = try c.decode(String.self, forKey: .providerDisplayNameJa)
        providerDisplayNameEn = try c.decode(String.self, forKey: .providerDisplayNameEn)
        accentColorHex = try c.decode(String.self, forKey: .accentColorHex)
        sourceFamily = try c.decode(String.self, forKey: .sourceFamily)
        lifecycleState = (try? c.decode(Inf6LearningFamilyLifecycleState.self, forKey: .lifecycleState)) ?? .active
        retirementDate = try? c.decode(String.self, forKey: .retirementDate)
        successorFamilyID = try? c.decode(String.self, forKey: .successorFamilyID)
        goalKind = try c.decode(Inf6LearningGoalKind.self, forKey: .goalKind)
        providers = try c.decode([String].self, forKey: .providers)
        syllabusProviders = (try? c.decode([String].self, forKey: .syllabusProviders)) ?? []
        contentProviders = (try? c.decode([String].self, forKey: .contentProviders)) ?? []
        officialSources = try c.decode([String].self, forKey: .officialSources)
        trendSources = try c.decode([String].self, forKey: .trendSources)
        currentSources = try? c.decode([Inf6MicrosoftLearnSourceDefinition].self, forKey: .currentSources)
        routeTokens = try? c.decode([String].self, forKey: .routeTokens)
        patternLibraryPath = try? c.decode(String.self, forKey: .patternLibraryPath)
        forecastAuthoringPath = try? c.decode(String.self, forKey: .forecastAuthoringPath)
        uiActions = try c.decode([String].self, forKey: .uiActions)
        entryActions = try c.decode([Inf6LearningFamilyAction].self, forKey: .entryActions)
    }

    public init(
        familyID: String,
        displayNameJa: String,
        displayNameEn: String,
        providerDisplayNameJa: String,
        providerDisplayNameEn: String,
        accentColorHex: String,
        sourceFamily: String,
        lifecycleState: Inf6LearningFamilyLifecycleState = .active,
        retirementDate: String? = nil,
        successorFamilyID: String? = nil,
        goalKind: Inf6LearningGoalKind,
        providers: [String],
        syllabusProviders: [String] = [],
        contentProviders: [String] = [],
        officialSources: [String],
        trendSources: [String],
        currentSources: [Inf6MicrosoftLearnSourceDefinition]? = nil,
        routeTokens: [String]? = nil,
        patternLibraryPath: String? = nil,
        forecastAuthoringPath: String? = nil,
        uiActions: [String],
        entryActions: [Inf6LearningFamilyAction]
    ) {
        self.familyID = familyID
        self.displayNameJa = displayNameJa
        self.displayNameEn = displayNameEn
        self.providerDisplayNameJa = providerDisplayNameJa
        self.providerDisplayNameEn = providerDisplayNameEn
        self.accentColorHex = accentColorHex
        self.sourceFamily = sourceFamily
        self.lifecycleState = lifecycleState
        self.retirementDate = retirementDate
        self.successorFamilyID = successorFamilyID
        self.goalKind = goalKind
        self.providers = providers
        self.syllabusProviders = syllabusProviders
        self.contentProviders = contentProviders
        self.officialSources = officialSources
        self.trendSources = trendSources
        self.currentSources = currentSources
        self.routeTokens = routeTokens
        self.patternLibraryPath = patternLibraryPath
        self.forecastAuthoringPath = forecastAuthoringPath
        self.uiActions = uiActions
        self.entryActions = entryActions
    }

    public func hasProvider(_ providerID: String) -> Bool {
        providers.contains(providerID)
    }

    public func hasSyllabusProvider(_ providerID: String) -> Bool {
        syllabusProviders.contains(providerID)
    }

    public func hasContentSource(_ sourceID: String) -> Bool {
        contentProviders.contains(sourceID)
    }

    public var usesMicrosoftLearnProvider: Bool {
        hasProvider("microsoft_learn") || hasSyllabusProvider("microsoft_learn") || hasContentSource("microsoft_learn")
    }

    public func effectiveLifecycleState(on date: Date = Date()) -> Inf6LearningFamilyLifecycleState {
        switch lifecycleState {
        case .retired, .superseded:
            return lifecycleState
        case .active, .retiring:
            guard let retirementDate,
                  !retirementDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return lifecycleState
            }
            return Self._calendarDayString(date) > retirementDate ? .retired : lifecycleState
        }
    }

    public var isCurrentSyllabusSyncTarget: Bool {
        let state = effectiveLifecycleState()
        return state == .active || state == .retiring
    }

    private static func _calendarDayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public var usesJDLAHTMLProvider: Bool {
        hasSyllabusProvider("jdla_html")
    }

    public var usesArxivProvider: Bool {
        hasProvider("arxiv")
    }

    public var usesPubMedProvider: Bool {
        hasProvider("pubmed")
    }

    public var allowsPDFImportProvider: Bool {
        hasContentSource("pdf_import")
    }

    var resolvedContentProviders: [any Inf6ContentProvider] {
        Inf6ContentProviderRegistry.providers(for: contentProviders)
    }

    public var supportsPaperSearchProviders: Bool {
        usesArxivProvider || usesPubMedProvider
    }

    public var isJDLAOutlineFamily: Bool {
        usesJDLAHTMLProvider && !supportsPaperSearchProviders && !usesMicrosoftLearnProvider
    }

    public var officialSourceRequests: [Inf6OfficialSourceRequest] {
        var requests: [Inf6OfficialSourceRequest] = []

        for (idx, rawURL) in officialSources.enumerated() {
            requests.append(
                Inf6OfficialSourceRequest(
                    id: "official-\(idx + 1)",
                    listKind: "official",
                    topic: "official",
                    title: "\(displayNameJa) 公式情報 \(idx + 1)",
                    urlString: rawURL,
                    roleHint: "official"
                )
            )
        }

        for (idx, rawURL) in trendSources.enumerated() {
            requests.append(
                Inf6OfficialSourceRequest(
                    id: "trend-\(idx + 1)",
                    listKind: "trend",
                    topic: "trend",
                    title: "\(displayNameJa) 改定・動向 \(idx + 1)",
                    urlString: rawURL,
                    roleHint: "trend"
                )
            )
        }

        for source in currentSources ?? [] {
            requests.append(
                Inf6OfficialSourceRequest(
                    id: source.id,
                    listKind: "current",
                    topic: source.topic,
                    title: source.title,
                    urlString: source.urlString,
                    roleHint: source.roleHint.rawValue
                )
            )
        }

        var seen = Set<String>()
        return requests.filter { request in
            let key = request.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }
}

public struct Inf6OfficialSourceRequest: Codable, Hashable, Identifiable {
    public var id: String
    public var listKind: String
    public var topic: String
    public var title: String
    public var urlString: String
    public var roleHint: String

    enum CodingKeys: String, CodingKey {
        case id
        case listKind = "list_kind"
        case topic
        case title
        case urlString = "url"
        case roleHint = "role_hint"
    }
}

public struct Inf6OfficialSourceSnapshot: Codable, Hashable {
    public var schemaID: String
    public var familyID: String
    public var sourceFamily: String
    public var providerIDs: [String]
    public var collectedAt: String
    public var sources: [Inf6OfficialSourceSnapshotItem]

    enum CodingKeys: String, CodingKey {
        case schemaID = "schema_id"
        case familyID = "family_id"
        case sourceFamily = "source_family"
        case providerIDs = "provider_ids"
        case collectedAt = "collected_at"
        case sources
    }
}

public struct Inf6OfficialSourceSnapshotItem: Codable, Hashable, Identifiable {
    public var id: String
    public var listKind: String
    public var topic: String
    public var title: String
    public var urlString: String
    public var roleHint: String
    public var httpStatus: Int
    public var contentType: String
    public var sourceYears: [Int]
    public var textExcerpt: String
    public var fetchedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case listKind = "list_kind"
        case topic
        case title
        case urlString = "url"
        case roleHint = "role_hint"
        case httpStatus = "http_status"
        case contentType = "content_type"
        case sourceYears = "source_years"
        case textExcerpt = "text_excerpt"
        case fetchedAt = "fetched_at"
    }
}

public enum Inf6OfficialSourceCollector {
    public static func collectAndSave(manifest: Inf6LearningFamilyManifest) async throws -> Inf6OfficialSourceSnapshot {
        let requests = manifest.officialSourceRequests
        guard !requests.isEmpty else {
            throw NSError(domain: "Inf6OfficialSourceCollector", code: -1201, userInfo: [
                NSLocalizedDescriptionKey: "公式ソースが未定義です: \(manifest.familyID)"
            ])
        }

        let collectedAt = _iso8601(Date())
        var items: [Inf6OfficialSourceSnapshotItem] = []
        for request in requests {
            items.append(try await _fetch(request: request, collectedAt: collectedAt))
        }

        let snapshot = Inf6OfficialSourceSnapshot(
            schemaID: "inf6.official-source-snapshot.v1",
            familyID: manifest.familyID,
            sourceFamily: manifest.sourceFamily,
            providerIDs: manifest.providers,
            collectedAt: collectedAt,
            sources: items
        )

        let url = try latestSnapshotURL(manifest: manifest)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
        return snapshot
    }

    public static func latestSnapshotURL(manifest: Inf6LearningFamilyManifest) throws -> URL {
        let root = try Inf6LibraryView._sharedRootDir()
        return root
            .appendingPathComponent("mma", isDirectory: true)
            .appendingPathComponent(manifest.sourceFamily, isDirectory: true)
            .appendingPathComponent("source_snapshots", isDirectory: true)
            .appendingPathComponent("latest.json")
    }

    private static func _fetch(
        request source: Inf6OfficialSourceRequest,
        collectedAt: String
    ) async throws -> Inf6OfficialSourceSnapshotItem {
        let rawURL = source.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawURL), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw NSError(domain: "Inf6OfficialSourceCollector", code: -1202, userInfo: [
                NSLocalizedDescriptionKey: "公式ソース URL が不正です: \(source.id) \(source.urlString)"
            ])
        }

        var request = URLRequest(url: url)
        request.setValue("inf6/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Inf6OfficialSourceCollector", code: -1203, userInfo: [
                NSLocalizedDescriptionKey: "HTTP 応答ではありません: \(source.urlString)"
            ])
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "Inf6OfficialSourceCollector", code: -1204, userInfo: [
                NSLocalizedDescriptionKey: "公式ソース取得失敗: HTTP \(http.statusCode) \(source.urlString)"
            ])
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "Inf6OfficialSourceCollector", code: -1205, userInfo: [
                NSLocalizedDescriptionKey: "公式ソースが UTF-8 として読めません: \(source.urlString)"
            ])
        }

        let normalized = _normalizeText(_stripHTML(text))
        guard !normalized.isEmpty else {
            throw NSError(domain: "Inf6OfficialSourceCollector", code: -1206, userInfo: [
                NSLocalizedDescriptionKey: "公式ソース本文が空です: \(source.urlString)"
            ])
        }

        let years = _extractYears(from: [
            source.title,
            source.topic,
            source.urlString,
            normalized
        ].joined(separator: " "))

        return Inf6OfficialSourceSnapshotItem(
            id: source.id,
            listKind: source.listKind,
            topic: source.topic,
            title: source.title,
            urlString: source.urlString,
            roleHint: source.roleHint,
            httpStatus: http.statusCode,
            contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "",
            sourceYears: years,
            textExcerpt: String(normalized.prefix(4000)),
            fetchedAt: collectedAt
        )
    }

    private static func _extractYears(from text: String) -> [Int] {
        let pattern = #"(?:19|20)\d{2}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let years = regex.matches(in: text, range: range).compactMap { match -> Int? in
            guard let range = Range(match.range, in: text) else { return nil }
            let year = Int(text[range])
            guard let year, (1990...2100).contains(year) else { return nil }
            return year
        }
        return Array(Set(years)).sorted()
    }

    private static func _stripHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }

    private static func _normalizeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func _iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

public struct Inf6LearningFamilyManifestLoadFailure: Identifiable, Sendable {
    public let familyID: String
    public let displayName: String
    public let message: String

    public var id: String { familyID }
}

public struct Inf6LearningFamilyManifestLoadResult: Sendable {
    public let manifests: [Inf6LearningFamilyManifest]
    public let failures: [Inf6LearningFamilyManifestLoadFailure]

    public init(
        manifests: [Inf6LearningFamilyManifest],
        failures: [Inf6LearningFamilyManifestLoadFailure]
    ) {
        self.manifests = manifests
        self.failures = failures
    }
}

public enum Inf6LearningFamilyManifestStore {

    /// storageRoot/mma/<sourceFamily>/family_manifest.json を正本とする。
    /// 未配置時は seed manifest を storageRoot へ書き出し、その後 storageRoot 側を読み直す。
    public static func loadAll() -> [Inf6LearningFamilyManifest] {
        let root: URL
        do { root = try Inf6LibraryView._sharedRootDir() } catch { return _seedManifests() }
        var manifests: [Inf6LearningFamilyManifest] = []
        for seed in _seedManifests() {
            let sharedURL = _sharedFileURL(root: root, sourceFamily: seed.sourceFamily)
            let dir = sharedURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: sharedURL.path) {
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try _validateManifest(seed)
                    let data = try JSONEncoder().encode(seed)
                    try data.write(to: sharedURL, options: .atomic)
                } catch {
                    _recordManifestLoadFailure(
                        operation: "family_manifest_write",
                        url: sharedURL,
                        error: error
                    )
                    manifests.append(seed)
                    continue
                }
            }
            do {
                let data = try Data(contentsOf: sharedURL)
                let rawText = String(decoding: data, as: UTF8.self)
                let decoded = try JSONDecoder().decode(Inf6LearningFamilyManifest.self, from: data)
                let merged = _mergedManifest(seed: seed, existing: decoded)
                try _validateManifest(merged)
                let hasLegacyExecutorFields = rawText.contains("\"executor_kind\"") || rawText.contains("\"executor_arg\"")
                if hasLegacyExecutorFields || merged != decoded {
                    let mergedData = try JSONEncoder().encode(merged)
                    try mergedData.write(to: sharedURL, options: .atomic)
                }
                try _ensureForecastAuthoringSharedFile(root: root, manifest: merged)
                manifests.append(merged)
            } catch {
                _recordManifestLoadFailure(
                    operation: "family_manifest_read",
                    url: sharedURL,
                    error: error
                )
                // ローカル manifest が壊れている場合でもドメイン欠落を黙って成功扱いしない。
                manifests.append(seed)
            }
        }
        return manifests
    }

    public static func load(familyID: String) -> Inf6LearningFamilyManifest? {
        loadAll().first { $0.familyID == familyID }
    }

    public static func loadCurrentSyllabusDomains() -> [Inf6LearningFamilyManifest] {
        _currentSyllabusDomains(from: loadAll())
    }

    public static func loadCurrentSyllabusDomainsEnsuringDownloaded() async throws -> Inf6LearningFamilyManifestLoadResult {
        let result = try await loadAllEnsuringDownloaded()
        return Inf6LearningFamilyManifestLoadResult(
            manifests: _currentSyllabusDomains(from: result.manifests),
            failures: result.failures
        )
    }

    private static func loadAllEnsuringDownloaded() async throws -> Inf6LearningFamilyManifestLoadResult {
        let root = try await MainActor.run {
            try Inf6LibraryView._sharedRootDir()
        }
        let seeds = _seedManifests()
        var manifestURLs: [URL] = []

        for seed in seeds {
            let sharedURL = _sharedFileURL(root: root, sourceFamily: seed.sourceFamily)
            let dir = sharedURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: sharedURL.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try _validateManifest(seed)
                let data = try JSONEncoder().encode(seed)
                try data.write(to: sharedURL, options: .atomic)
            }
            manifestURLs.append(sharedURL)
        }

        var failures: [Inf6LearningFamilyManifestLoadFailure] = []
        var undownloadedFamilyIDs: Set<String> = []
        for (seed, url) in zip(seeds, manifestURLs) {
            do {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw NSError(domain: "Inf6LearningFamilyManifestStore", code: -1120, userInfo: [
                        NSLocalizedDescriptionKey: "family_manifest is missing locally: \(url.path)"
                    ])
                }
                _ = try Data(contentsOf: url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // ここでの失敗は記録し、利用可能な seed が同じ family を提供するか後段で確認する。
                NSLog("[Inf6LearningFamilyManifestStore] family_manifest not local, using seed: %@", url.path)
                failures.append(Inf6LearningFamilyManifestLoadFailure(
                    familyID: seed.familyID,
                    displayName: seed.displayNameJa,
                    message: error.localizedDescription
                ))
                undownloadedFamilyIDs.insert(seed.familyID)
            }
        }

        var manifests = loadAll()
        // ローカル manifest が利用不能だったドメインは、同一バンドル seed で正当性を確認して補う。
        let loadedFamilyIDs = Set(manifests.map(\.familyID))
        for seed in seeds where undownloadedFamilyIDs.contains(seed.familyID) && !loadedFamilyIDs.contains(seed.familyID) {
            manifests.append(seed)
        }
        // フォールバックまで含めて使えているドメインは失敗ではない。
        // 利用者に見せる意味が無いうえ、毎回の起動で赤い帯が出続けることになる。
        let availableFamilyIDs = Set(manifests.map(\.familyID))
        let unresolvedFailures = failures.filter { !availableFamilyIDs.contains($0.familyID) }
        guard !manifests.isEmpty || unresolvedFailures.isEmpty else {
            throw NSError(domain: "Inf6LearningFamilyManifestStore", code: -1121, userInfo: [
                NSLocalizedDescriptionKey: "family manifests could not be loaded: \(unresolvedFailures.map(\.displayName).joined(separator: ", "))"
            ])
        }
        return Inf6LearningFamilyManifestLoadResult(manifests: manifests, failures: unresolvedFailures)
    }

    private static func _currentSyllabusDomains(
        from manifests: [Inf6LearningFamilyManifest]
    ) -> [Inf6LearningFamilyManifest] {
        let currentByFamilyID = Dictionary(
            uniqueKeysWithValues: manifests
                .filter(\.isCurrentSyllabusSyncTarget)
                .map { ($0.familyID, $0) }
        )
        return manifests.filter { manifest in
            guard manifest.isCurrentSyllabusSyncTarget else { return false }
            guard let successorID = manifest.successorFamilyID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !successorID.isEmpty,
                  let successor = currentByFamilyID[successorID] else {
                return true
            }
            return successor.effectiveLifecycleState() != .active
        }
    }

    private static func _sharedFileURL(root: URL, sourceFamily: String) -> URL {
        root
            .appendingPathComponent("mma", isDirectory: true)
            .appendingPathComponent(sourceFamily, isDirectory: true)
            .appendingPathComponent("family_manifest.json")
    }


    private static func _recordManifestLoadFailure(operation: String, url: URL, error: Error) {
        let message = "\(operation) failed: \(url.path) / \(error.localizedDescription)"
        NSLog("[Inf6LearningFamilyManifestStore] %@", message)
        Inf6ErrorIntelligence.recordRuntimeEvent(
            operation: operation,
            context: url.path,
            error: error
        )
    }

    private static func _ensureForecastAuthoringSharedFile(root: URL, manifest: Inf6LearningFamilyManifest) throws {
        guard manifest.forecastAuthoringPath != nil else { return }
        let dir = root
            .appendingPathComponent("mma", isDirectory: true)
            .appendingPathComponent(manifest.sourceFamily, isDirectory: true)
        let sharedURL = dir.appendingPathComponent("forecast_authoring.json")
        if FileManager.default.fileExists(atPath: sharedURL.path) {
            return
        }
        guard let bundleURL = Bundle.main.url(
            forResource: "\(manifest.sourceFamily)_forecast_authoring_v1",
            withExtension: "json"
        ) else {
            throw NSError(domain: "Inf6Manifest", code: 9, userInfo: [
                NSLocalizedDescriptionKey: "forecast_authoring seed missing: \(manifest.sourceFamily)"
            ])
        }
        let data = try Data(contentsOf: bundleURL)
        let decoded = try JSONDecoder().decode(Inf6ForecastAuthoringLoader.ForecastAuthoring.self, from: data)
        guard decoded.schemaID == "inf6.forecast-authoring.v1" else {
            throw NSError(domain: "Inf6Manifest", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "forecast_authoring schema mismatch: \(bundleURL.path)"
            ])
        }
        guard decoded.sourceFamily == manifest.sourceFamily else {
            throw NSError(domain: "Inf6Manifest", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "forecast_authoring sourceFamily mismatch: \(bundleURL.path)"
            ])
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: sharedURL, options: .atomic)
    }

    private static func _validateManifest(_ manifest: Inf6LearningFamilyManifest) throws {
        let providerSet = Set(manifest.providers)
        let unknownProviders = providerSet.filter { raw in
            Inf6SourceProviderID(rawValue: raw) == nil
        }
        guard unknownProviders.isEmpty else {
            let joined = unknownProviders.sorted().joined(separator: ", ")
            throw NSError(domain: "Inf6LearningFamilyManifestStore", code: -1102, userInfo: [
                NSLocalizedDescriptionKey: "unknown providers in \(manifest.familyID): \(joined)"
            ])
        }
        let knownSourceIDs = Set(Inf6SourceProviderID.allCases.map(\.rawValue) + ["ai_generated"])
        let unknownSyllabusProviders = Set(manifest.syllabusProviders).subtracting(knownSourceIDs)
        guard unknownSyllabusProviders.isEmpty else {
            let joined = unknownSyllabusProviders.sorted().joined(separator: ", ")
            throw NSError(domain: "Inf6LearningFamilyManifestStore", code: -1109, userInfo: [
                NSLocalizedDescriptionKey: "unknown syllabus_providers in \(manifest.familyID): \(joined)"
            ])
        }
        let unknownContentProviders = Set(manifest.contentProviders).subtracting(knownSourceIDs)
        guard unknownContentProviders.isEmpty else {
            let joined = unknownContentProviders.sorted().joined(separator: ", ")
            throw NSError(domain: "Inf6LearningFamilyManifestStore", code: -1110, userInfo: [
                NSLocalizedDescriptionKey: "unknown content_providers in \(manifest.familyID): \(joined)"
            ])
        }
        guard !manifest.entryActions.isEmpty else {
            throw NSError(domain: "Inf6LearningFamilyManifestStore", code: -1103, userInfo: [
                NSLocalizedDescriptionKey: "entry_actions is empty: \(manifest.familyID)"
            ])
        }
        guard !manifest.uiActions.isEmpty else {
            throw NSError(domain: "Inf6LearningFamilyManifestStore", code: -1104, userInfo: [
                NSLocalizedDescriptionKey: "ui_actions is empty: \(manifest.familyID)"
            ])
        }

        if let retirementDate = manifest.retirementDate {
            guard retirementDate.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
                throw NSError(domain: "Inf6LearningFamilyManifestStore", code: -1113, userInfo: [
                    NSLocalizedDescriptionKey: "retirement_date must be yyyy-MM-dd: \(manifest.familyID)"
                ])
            }
        }
        if manifest.lifecycleState == .retiring {
            guard manifest.retirementDate?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw NSError(domain: "Inf6LearningFamilyManifestStore", code: -1114, userInfo: [
                    NSLocalizedDescriptionKey: "retiring domain requires retirement_date: \(manifest.familyID)"
                ])
            }
        }
        if manifest.lifecycleState == .superseded {
            guard manifest.successorFamilyID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw NSError(domain: "Inf6LearningFamilyManifestStore", code: -1115, userInfo: [
                    NSLocalizedDescriptionKey: "superseded domain requires successor_family_id: \(manifest.familyID)"
                ])
            }
        }

        if manifest.usesMicrosoftLearnProvider {
            guard let currentSources = manifest.currentSources, !currentSources.isEmpty else {
                throw NSError(domain: "Inf6LearningFamilyManifestStore", code: -1105, userInfo: [
                    NSLocalizedDescriptionKey: "microsoft_learn requires current_sources: \(manifest.familyID)"
                ])
            }
            let allLearnURLs = manifest.officialSources + currentSources
                .filter { ($0.provider ?? "microsoft_learn") == "microsoft_learn" }
                .map(\.urlString)
            guard allLearnURLs.allSatisfy({ _host($0) == "learn.microsoft.com" }) else {
                throw NSError(domain: "Inf6LearningFamilyManifestStore", code: -1106, userInfo: [
                    NSLocalizedDescriptionKey: "microsoft_learn requires learn.microsoft.com URLs only: \(manifest.familyID)"
                ])
            }
        }

        if manifest.hasProvider("microsoft_techcommunity") {
            let techCommunityTrendURLs = manifest.trendSources.filter { _host($0) == "techcommunity.microsoft.com" }
            let explicitTechCommunityURLs = (manifest.currentSources ?? [])
                .filter { ($0.provider ?? "microsoft_learn") == "microsoft_techcommunity" }
                .map(\.urlString)
            guard !techCommunityTrendURLs.isEmpty || !explicitTechCommunityURLs.isEmpty else {
                throw NSError(domain: "Inf6LearningFamilyManifestStore", code: -1111, userInfo: [
                    NSLocalizedDescriptionKey: "microsoft_techcommunity requires trend_sources or current_sources: \(manifest.familyID)"
                ])
            }
            guard explicitTechCommunityURLs.allSatisfy({ _host($0) == "techcommunity.microsoft.com" }) else {
                throw NSError(domain: "Inf6LearningFamilyManifestStore", code: -1112, userInfo: [
                    NSLocalizedDescriptionKey: "microsoft_techcommunity requires techcommunity.microsoft.com URLs only: \(manifest.familyID)"
                ])
            }
        }

        if manifest.usesJDLAHTMLProvider {
            guard !manifest.officialSources.isEmpty else {
                throw NSError(domain: "Inf6LearningFamilyManifestStore", code: -1107, userInfo: [
                    NSLocalizedDescriptionKey: "jdla_html requires official_sources: \(manifest.familyID)"
                ])
            }
            let jdlaURLs = manifest.officialSources + manifest.trendSources
            guard jdlaURLs.contains(where: { _host($0)?.contains("jdla.org") == true }) else {
                throw NSError(domain: "Inf6LearningFamilyManifestStore", code: -1108, userInfo: [
                    NSLocalizedDescriptionKey: "jdla_html requires jdla.org sources: \(manifest.familyID)"
                ])
            }
        }
    }

    private static func _host(_ raw: String) -> String? {
        URL(string: raw)?.host?.lowercased()
    }

    private static func _mergedManifest(
        seed: Inf6LearningFamilyManifest,
        existing: Inf6LearningFamilyManifest
    ) -> Inf6LearningFamilyManifest {
        _ = existing
        return seed
    }

    private static func _seedManifests() -> [Inf6LearningFamilyManifest] {
        return [
            Inf6LearningFamilyManifest(
                familyID: "ai-102",
                displayNameJa: "AI-102",
                displayNameEn: "AI-102",
                providerDisplayNameJa: "Microsoft",
                providerDisplayNameEn: "Microsoft",
                accentColorHex: "#0078d4",
                sourceFamily: "microsoft_ai_102",
                lifecycleState: .retiring,
                retirementDate: "2026-06-30",
                successorFamilyID: "ai-103",
                goalKind: Inf6LearningGoalKind.certification,
                providers: ["microsoft_learn", "microsoft_techcommunity"],
                syllabusProviders: ["microsoft_learn"],
                contentProviders: ["microsoft_learn", "pdf_import"],
                officialSources: [
                    "https://learn.microsoft.com/en-us/credentials/certifications/exams/ai-102",
                    "https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/ai-102",
                    "https://learn.microsoft.com/en-us/training/courses/ai-102t00"
                ],
                trendSources: [
                    "https://learn.microsoft.com/en-us/azure/ai-services/openai/whats-new",
                    "https://learn.microsoft.com/en-us/azure/ai-services/language-service/whats-new",
                    "https://learn.microsoft.com/en-us/azure/ai-foundry/whats-new-foundry",
                    "https://techcommunity.microsoft.com/blog/skills-hub-blog/the-ai-job-boom-is-here-are-you-ready-to-showcase-your-skills/4494128"
                ],
                currentSources: [
                    Inf6MicrosoftLearnSourceDefinition(id: "ai102-study-guide", topic: "exam_scope", title: "AI-102 Study Guide", urlString: "https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/ai-102", roleHint: Inf6MicrosoftLearnSourceRole.wrapper),
                    Inf6MicrosoftLearnSourceDefinition(id: "ai102-certification", topic: "exam_scope", title: "Azure AI Engineer Associate", urlString: "https://learn.microsoft.com/en-us/credentials/certifications/azure-ai-engineer/", roleHint: Inf6MicrosoftLearnSourceRole.wrapper),
                    Inf6MicrosoftLearnSourceDefinition(id: "ai102-course", topic: "exam_scope", title: "AI-102T00 Course", urlString: "https://learn.microsoft.com/en-us/training/courses/ai-102t00", roleHint: Inf6MicrosoftLearnSourceRole.wrapper),
                    Inf6MicrosoftLearnSourceDefinition(id: "foundry-overview", topic: "foundry", title: "Microsoft Foundry documentation", urlString: "https://learn.microsoft.com/en-us/ai/ai-studio-experiences-overview", roleHint: Inf6MicrosoftLearnSourceRole.wrapper),
                    Inf6MicrosoftLearnSourceDefinition(id: "search-hybrid", topic: "search", title: "Azure AI Search hybrid search overview", urlString: "https://learn.microsoft.com/en-us/azure/search/hybrid-search-overview", roleHint: Inf6MicrosoftLearnSourceRole.current),
                    Inf6MicrosoftLearnSourceDefinition(id: "search-semantic", topic: "search", title: "Azure AI Search semantic search overview", urlString: "https://learn.microsoft.com/en-us/azure/search/semantic-search-overview", roleHint: Inf6MicrosoftLearnSourceRole.current),
                    Inf6MicrosoftLearnSourceDefinition(id: "language-overview", topic: "language", title: "Azure AI Language overview", urlString: "https://learn.microsoft.com/en-us/azure/ai-services/language-service/overview", roleHint: Inf6MicrosoftLearnSourceRole.current),
                    Inf6MicrosoftLearnSourceDefinition(id: "speech-overview", topic: "speech", title: "Azure AI Speech overview", urlString: "https://learn.microsoft.com/en-us/azure/ai-services/speech-service/overview", roleHint: Inf6MicrosoftLearnSourceRole.current),
                    Inf6MicrosoftLearnSourceDefinition(id: "vision-overview", topic: "vision", title: "Azure AI Vision overview", urlString: "https://learn.microsoft.com/en-us/azure/ai-services/computer-vision/overview", roleHint: Inf6MicrosoftLearnSourceRole.current),
                    Inf6MicrosoftLearnSourceDefinition(id: "docintel-overview", topic: "document_intelligence", title: "Azure AI Document Intelligence overview", urlString: "https://learn.microsoft.com/en-us/azure/ai-services/document-intelligence/overview?view=doc-intel-4.0.0", roleHint: Inf6MicrosoftLearnSourceRole.current),
                    Inf6MicrosoftLearnSourceDefinition(id: "docintel-whats-new", topic: "document_intelligence", title: "Azure AI Document Intelligence what's new", urlString: "https://learn.microsoft.com/en-us/azure/ai-services/document-intelligence/whats-new?view=doc-intel-4.0.0", roleHint: Inf6MicrosoftLearnSourceRole.current),
                    Inf6MicrosoftLearnSourceDefinition(id: "docintel-documentanalysisclient", topic: "document_intelligence", title: "DocumentAnalysisClient reference", urlString: "https://learn.microsoft.com/en-us/python/api/azure-ai-formrecognizer/azure.ai.formrecognizer.documentanalysisclient?view=azure-python", roleHint: Inf6MicrosoftLearnSourceRole.current),
                    Inf6MicrosoftLearnSourceDefinition(id: "docintel-formrecognizerclient", topic: "document_intelligence", title: "FormRecognizerClient reference", urlString: "https://learn.microsoft.com/en-us/python/api/azure-ai-formrecognizer/azure.ai.formrecognizer.formrecognizerclient?view=azure-python", roleHint: Inf6MicrosoftLearnSourceRole.legacyDetail),
                    Inf6MicrosoftLearnSourceDefinition(id: "content-safety-overview", topic: "responsible_ai", title: "Azure AI Content Safety overview", urlString: "https://learn.microsoft.com/en-us/azure/ai-services/content-safety/overview", roleHint: Inf6MicrosoftLearnSourceRole.current),
                    Inf6MicrosoftLearnSourceDefinition(id: "skills-hub-ai-job-boom", topic: "certification_lifecycle", title: "The AI job boom is here: Are you ready to showcase your skills?", urlString: "https://techcommunity.microsoft.com/blog/skills-hub-blog/the-ai-job-boom-is-here-are-you-ready-to-showcase-your-skills/4494128", roleHint: Inf6MicrosoftLearnSourceRole.lifecycle, provider: "microsoft_techcommunity")
                ],
                routeTokens: ["AI-102", "Azure AI Engineer", "Azure AI Engineer Associate", "Microsoft Learn"],
                patternLibraryPath: "knowledge/microsoft_ai_102/question_patterns.json",
                forecastAuthoringPath: "knowledge/microsoft_ai_102/forecast.json",
                uiActions: ["organize", "compose", "measure"],
                entryActions: [
                    Inf6LearningFamilyAction(
                        phase: .organize,
                        labelJa: "公式知識を整理する",
                        descriptionJa: "Microsoft Learn の一次情報を公式知識として再構成します。"
                    ),
                    Inf6LearningFamilyAction(
                        phase: .compose,
                        labelJa: "問題集を確認する",
                        descriptionJa: "生成済みの MMA 問題集があるかを確認し、測定へ進める状態かを判定します。"
                    )
                ]
            ),
            Inf6LearningFamilyManifest(
                familyID: "ai-103",
                displayNameJa: "AI-103",
                displayNameEn: "AI-103",
                providerDisplayNameJa: "Microsoft",
                providerDisplayNameEn: "Microsoft",
                accentColorHex: "#0078d4",
                sourceFamily: "microsoft_ai_103",
                lifecycleState: .active,
                goalKind: Inf6LearningGoalKind.certification,
                providers: ["microsoft_learn", "microsoft_techcommunity"],
                syllabusProviders: ["microsoft_learn"],
                contentProviders: ["microsoft_learn", "pdf_import"],
                officialSources: [
                    "https://learn.microsoft.com/en-us/credentials/certifications/azure-ai-apps-and-agents-developer-associate/",
                    "https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/ai-103",
                    "https://learn.microsoft.com/en-us/training/courses/ai-103t00"
                ],
                trendSources: [
                    "https://learn.microsoft.com/en-us/azure/ai-foundry/whats-new-foundry",
                    "https://learn.microsoft.com/en-us/azure/ai-services/openai/whats-new",
                    "https://techcommunity.microsoft.com/blog/skills-hub-blog/new-microsoft-certified-azure-ai-apps-and-agents-developer-associate/4494126"
                ],
                currentSources: [
                    Inf6MicrosoftLearnSourceDefinition(id: "ai103-certification", topic: "exam_scope", title: "Azure AI Apps and Agents Developer Associate", urlString: "https://learn.microsoft.com/en-us/credentials/certifications/azure-ai-apps-and-agents-developer-associate/", roleHint: Inf6MicrosoftLearnSourceRole.wrapper),
                    Inf6MicrosoftLearnSourceDefinition(id: "ai103-study-guide", topic: "exam_scope", title: "AI-103 Study Guide", urlString: "https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/ai-103", roleHint: Inf6MicrosoftLearnSourceRole.wrapper),
                    Inf6MicrosoftLearnSourceDefinition(id: "ai103-course", topic: "exam_scope", title: "AI-103T00 Course", urlString: "https://learn.microsoft.com/en-us/training/courses/ai-103t00", roleHint: Inf6MicrosoftLearnSourceRole.wrapper),
                    Inf6MicrosoftLearnSourceDefinition(id: "foundry-overview", topic: "foundry", title: "Microsoft Foundry documentation", urlString: "https://learn.microsoft.com/en-us/ai/ai-studio-experiences-overview", roleHint: Inf6MicrosoftLearnSourceRole.wrapper),
                    Inf6MicrosoftLearnSourceDefinition(id: "foundry-whats-new", topic: "foundry", title: "What's new in Microsoft Foundry", urlString: "https://learn.microsoft.com/en-us/azure/ai-foundry/whats-new-foundry", roleHint: Inf6MicrosoftLearnSourceRole.current),
                    Inf6MicrosoftLearnSourceDefinition(id: "azure-openai-whats-new", topic: "azure_openai", title: "Azure OpenAI what's new", urlString: "https://learn.microsoft.com/en-us/azure/ai-services/openai/whats-new", roleHint: Inf6MicrosoftLearnSourceRole.current),
                    Inf6MicrosoftLearnSourceDefinition(id: "skills-hub-ai103", topic: "certification_lifecycle", title: "New Microsoft Certified: Azure AI Apps and Agents Developer Associate", urlString: "https://techcommunity.microsoft.com/blog/skills-hub-blog/new-microsoft-certified-azure-ai-apps-and-agents-developer-associate/4494126", roleHint: Inf6MicrosoftLearnSourceRole.lifecycle, provider: "microsoft_techcommunity")
                ],
                routeTokens: ["AI-103", "Azure AI Apps and Agents Developer Associate", "Develop AI apps and agents on Azure", "Microsoft Foundry", "agentic", "generative AI", "Microsoft Learn"],
                patternLibraryPath: nil,
                forecastAuthoringPath: nil,
                uiActions: ["organize", "compose", "measure"],
                entryActions: [
                    Inf6LearningFamilyAction(
                        phase: .organize,
                        labelJa: "公式知識を整理する",
                        descriptionJa: "Microsoft Learn の AI-103 一次情報を公式知識として再構成します。"
                    ),
                    Inf6LearningFamilyAction(
                        phase: .compose,
                        labelJa: "問題集を確認する",
                        descriptionJa: "生成済みの MMA 問題集があるかを確認し、測定へ進める状態かを判定します。"
                    )
                ]
            ),
            Inf6LearningFamilyManifest(
                familyID: "g-kentei",
                displayNameJa: "G検定",
                displayNameEn: "G-Kentei",
                providerDisplayNameJa: "JDLA",
                providerDisplayNameEn: "JDLA",
                accentColorHex: "#d97706",
                sourceFamily: "jdla_gkentei",
                goalKind: Inf6LearningGoalKind.certification,
                providers: [],
                syllabusProviders: ["jdla_html"],
                contentProviders: ["pdf_import", "ai_generated"],
                officialSources: [
                    "https://www.jdla.org/certificate/general/",
                    "https://www.jdla.org/certificate/general/issues/"
                ],
                trendSources: [
                    "https://www.jdla.org/download/g%E6%A4%9C%E5%AE%9A%E3%81%AE%E8%A9%A6%E9%A8%93%E5%87%BA%E9%A1%8C%E7%AF%84%E5%9B%B2-%EF%BC%88%E3%82%B7%E3%83%A9%E3%83%90%E3%82%B9%EF%BC%89g20246%EF%BD%9Ev1-4/",
                    "https://www.jdla.org/download/g-syllabus_2021/"
                ],
                currentSources: Optional<[Inf6MicrosoftLearnSourceDefinition]>.none,
                routeTokens: ["G検定", "GKentei", "G Kentei"],
                patternLibraryPath: "knowledge/jdla_gkentei/question_patterns.json",
                forecastAuthoringPath: "knowledge/jdla_gkentei/forecast.json",
                uiActions: ["compose", "measure"],
                entryActions: [
                    Inf6LearningFamilyAction(
                        phase: .compose,
                        labelJa: "問題集を確認する",
                        descriptionJa: "生成済みの G検定 MMA 問題集があるかを確認します。"
                    )
                ]
            ),
            Inf6LearningFamilyManifest(
                familyID: "e-shikaku",
                displayNameJa: "E資格",
                displayNameEn: "E-Qualification",
                providerDisplayNameJa: "JDLA",
                providerDisplayNameEn: "JDLA",
                accentColorHex: "#059669",
                sourceFamily: "jdla_eshikaku",
                goalKind: Inf6LearningGoalKind.certification,
                providers: ["arxiv", "pubmed"],
                syllabusProviders: ["jdla_html"],
                contentProviders: ["arxiv", "pubmed", "pdf_import"],
                officialSources: [
                    "https://www.jdla.org/certificate/engineer/",
                    "https://www.jdla.org/download/e%e8%b3%87%e6%a0%bc%e3%81%ae%e8%a9%a6%e9%a8%93%e5%87%ba%e9%a1%8c%e7%af%84%e5%9b%b2%ef%bc%88%e3%82%b7%e3%83%a9%e3%83%90%e3%82%b9%ef%bc%89e20262%ef%bd%9e/?wpdmdl=113072"
                ],
                trendSources: [
                    "https://www.jdla.org/certificate/engineer/"
                ],
                currentSources: Optional<[Inf6MicrosoftLearnSourceDefinition]>.none,
                routeTokens: ["E資格", "E Qualification", "EKentei", "E Kentei"],
                patternLibraryPath: nil,
                forecastAuthoringPath: nil,
                uiActions: ["collect", "organize", "compose", "measure"],
                entryActions: [
                    Inf6LearningFamilyAction(
                        phase: .collect,
                        labelJa: "論文・資料を収集する",
                        descriptionJa: "E資格に関連する論文と資料を集めます。"
                    ),
                    Inf6LearningFamilyAction(
                        phase: .organize,
                        labelJa: "収集済み PDF を開く",
                        descriptionJa: "収集済み PDF を開き、PDF ごとに解説・知識カード・演習を蓄積します。"
                    ),
                    Inf6LearningFamilyAction(
                        phase: .compose,
                        labelJa: "問題集を確認する",
                        descriptionJa: "生成済みの E資格 MMA 問題集があるかを確認します。"
                    )
                ]
            )
        ]
    }
}

// MARK: - 知識源種別

/// 原子や経脈の出典種別。アダプタ差し替えのみで拡張する。
/// 知識原子の素材ソース。試験ごとに異なる入力アダプターが対応する。
///
/// E資格  → arxivPaper（代表論文の abstract / 図表から原子化）
/// G検定  → jdlaGKenteiSyllabus（シラバス + 一般的 AI 知識から原子化）
/// Microsoft 資格 → microsoftLearn（製品仕様ドキュメントから原子化）
///
/// 入力アダプターが異なるだけで、原子化 → 経脈化 → 作問 の構造は三者共通。
public enum Inf6KnowledgeSourceKind: String, Codable, Hashable, Sendable {
    // Microsoft 資格（AI-102 ほか）
    case microsoftLearn       = "microsoft_learn"

    // E資格：JDLA 指定代表論文（ArXiv / PDF）が題材
    case arxivPaper           = "arxiv_paper"

    // G検定：JDLA シラバス + 一般 AI 知識が題材
    case jdlaGKenteiSyllabus  = "jdla_gkentei_syllabus"

    // 後方互換（旧 jdla_syllabus / paper_pdf を受け入れる）
    case jdlaSyllabus         = "jdla_syllabus"
    case paperPDF             = "paper_pdf"

    case other                = "other"

    /// 表示名
    public var displayName: String {
        switch self {
        case .microsoftLearn:      return "Microsoft Learn"
        case .arxivPaper:          return "ArXiv 論文（E資格）"
        case .jdlaGKenteiSyllabus: return "JDLA シラバス（G検定）"
        case .jdlaSyllabus:        return "JDLA シラバス"
        case .paperPDF:            return "論文 PDF"
        case .other:               return "その他"
        }
    }

    /// この素材ソースが属する資格グループ
    public var certificationGroup: String {
        switch self {
        case .microsoftLearn:                  return "microsoft"
        case .arxivPaper:                      return "jdla_eshikaku"
        case .jdlaGKenteiSyllabus, .jdlaSyllabus: return "jdla_gkentei"
        case .paperPDF, .other:                return "other"
        }
    }
}

// MARK: - 1. KnowledgeAtom

/// 1 主張 = 1 知識原子。仕様書 07_MeridianMasteryAuthoring.md に従う。
public struct Inf6KnowledgeAtom: Codable, Hashable, Identifiable {
    /// 原子 ID（UUID 文字列または決定論的ハッシュ）。
    public var id: String

    /// 1 文で書かれた主張本体。
    public var content: String

    /// 出典種別。
    public var sourceType: Inf6KnowledgeSourceKind

    /// 根拠 URL（Microsoft Learn の場合）または shared-root 相対パス（JDLA PDF の場合）。
    public var sourceURLOrPath: String

    /// 前提知識として依存する原子 ID の配列。
    public var prerequisites: [String]

    /// 旧称 / 別称（現行名称が `content` に入る前提）。
    public var aliases: [String]

    /// 典型的な誤解や混同注意（作問時の ヒント / distractor 生成根拠）。
    public var misconceptionNotes: String?

    /// ドメインタグ（例: "azure-ai-search", "jdla-g-exam", "機械学習"）。
    public var domainTags: [String]

    /// 実務頻度（0.0 〜 1.0、任意）。適応型出題の優先度ヒント。
    public var practicalFrequency: Double?

    /// 誤答しやすさ（0.0 〜 1.0、任意）。
    public var errorProneness: Double?

    public init(
        id: String,
        content: String,
        sourceType: Inf6KnowledgeSourceKind,
        sourceURLOrPath: String,
        prerequisites: [String] = [],
        aliases: [String] = [],
        misconceptionNotes: String? = nil,
        domainTags: [String] = [],
        practicalFrequency: Double? = nil,
        errorProneness: Double? = nil
    ) {
        self.id = id
        self.content = content
        self.sourceType = sourceType
        self.sourceURLOrPath = sourceURLOrPath
        self.prerequisites = prerequisites
        self.aliases = aliases
        self.misconceptionNotes = misconceptionNotes
        self.domainTags = domainTags
        self.practicalFrequency = practicalFrequency
        self.errorProneness = errorProneness
    }
}

// MARK: - 2. KnowledgeEdge

/// 原子間の経脈。8 種のうちいずれかを `kind` に取る。
public struct Inf6KnowledgeEdge: Codable, Hashable, Identifiable {
    public var id: String
    public var fromAtomID: String
    public var toAtomID: String
    public var kind: Inf6KnowledgeEdgeKind
    /// この経脈を裏付ける公式根拠 URL（Learn / シラバス PDF）。
    public var evidenceURL: String?
    /// 人間可読の注釈（例: "index と skillset は別リソース"）。
    public var note: String?

    public init(
        id: String,
        fromAtomID: String,
        toAtomID: String,
        kind: Inf6KnowledgeEdgeKind,
        evidenceURL: String? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.fromAtomID = fromAtomID
        self.toAtomID = toAtomID
        self.kind = kind
        self.evidenceURL = evidenceURL
        self.note = note
    }
}

// MARK: - 3. CoverageTarget (正本)

/// 問題 1 問が確認する被覆対象。`atomID` または `edgeID` のどちらかを必ず 1 つ以上持つ。
///
/// 既存 `Inf6PaperQuizCoverageTarget` は PDF 由来の evidence 単位（page_note / math_card / abstract）を
/// 扱う下位契約であり、本型と別物として共存する。
/// 既存型は MMA 契約上、対応する原子 ID が立ち上がるまでは "proto-atom" と見なす。
public struct Inf6CoverageTarget: Codable, Hashable, Identifiable {
    public enum RefKind: String, Codable, Hashable {
        case atom  = "atom"
        case edge  = "edge"
    }

    public var id: String
    public var kind: RefKind
    /// `kind == .atom` のとき原子 ID、`.edge` のとき経脈 ID。
    public var refID: String
    /// UI 表示用の短い説明（任意）。
    public var label: String?

    public init(id: String, kind: RefKind, refID: String, label: String? = nil) {
        self.id = id
        self.kind = kind
        self.refID = refID
        self.label = label
    }

    public static func atom(id: String = UUID().uuidString, atomID: String, label: String? = nil) -> Inf6CoverageTarget {
        Inf6CoverageTarget(id: id, kind: .atom, refID: atomID, label: label)
    }
    public static func edge(id: String = UUID().uuidString, edgeID: String, label: String? = nil) -> Inf6CoverageTarget {
        Inf6CoverageTarget(id: id, kind: .edge, refID: edgeID, label: label)
    }
}

// MARK: - 4. GeneratedQuestion

/// MMA 正本の問題レコード。
///
/// 既存 `Inf6PaperQuizQuestion` は論文 PDF 用に最適化されているため、本型はそれを包含する汎用形として定義する。
/// 既存クイズの JSON との相互変換は `Inf6MMAQuestionAdapter`（別途）で行う。
public struct Inf6GeneratedQuestion: Codable, Hashable, Identifiable {
    public var id: String
    public var createdAt: Double

    /// 問題文。
    public var prompt: String
    /// 選択肢（n ≥ 2）。
    public var choices: [String]
    /// 正解インデックス（`choices` 内）。
    public var correctIndex: Int
    /// 解説（正解理由＋誤答理由）。
    public var explanation: String

    /// 問題型（8 型）。
    public var questionType: Inf6QuestionType

    /// 被覆対象の ID 配列。**MMA では必ず 1 件以上必須**。
    public var coverageTargetIDs: [String]

    /// 根拠 URL 群（Learn URL / シラバス PDF 位置など）。
    public var sourceURLs: [String]

    /// 紐付く原子 ID（便宜フィールド。coverageTargets から導出可能）。
    public var knowledgeAtomIDs: [String]
    /// 紐付く経脈 ID（便宜フィールド）。
    public var knowledgeEdgeIDs: [String]

    public init(
        id: String,
        createdAt: Double,
        prompt: String,
        choices: [String],
        correctIndex: Int,
        explanation: String,
        questionType: Inf6QuestionType,
        coverageTargetIDs: [String],
        sourceURLs: [String] = [],
        knowledgeAtomIDs: [String] = [],
        knowledgeEdgeIDs: [String] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.prompt = prompt
        self.choices = choices
        self.correctIndex = correctIndex
        self.explanation = explanation
        self.questionType = questionType
        self.coverageTargetIDs = coverageTargetIDs
        self.sourceURLs = sourceURLs
        self.knowledgeAtomIDs = knowledgeAtomIDs
        self.knowledgeEdgeIDs = knowledgeEdgeIDs
    }
}

// MARK: - 5. MasteryState

/// 原子 / 経脈ごとの習得状態。回答ログから逆算されて更新される。
public struct Inf6MasteryState: Codable, Hashable {
    /// atomID -> レベル
    public var atomStates: [String: Inf6MasteryLevel]
    /// edgeID -> レベル
    public var edgeStates: [String: Inf6MasteryLevel]
    /// 最終更新 UNIX 秒。
    public var lastUpdatedAt: Double

    public init(
        atomStates: [String: Inf6MasteryLevel] = [:],
        edgeStates: [String: Inf6MasteryLevel] = [:],
        lastUpdatedAt: Double = Date().timeIntervalSince1970
    ) {
        self.atomStates = atomStates
        self.edgeStates = edgeStates
        self.lastUpdatedAt = lastUpdatedAt
    }

    public func atomLevel(_ atomID: String) -> Inf6MasteryLevel {
        atomStates[atomID] ?? .unverified
    }
    public func edgeLevel(_ edgeID: String) -> Inf6MasteryLevel {
        edgeStates[edgeID] ?? .unverified
    }
}

// MARK: - 予想適中 sidecar 契約

public enum Inf6TrendSignalCategory: String, Codable, Hashable {
    case emergingTopic = "emerging_topic"
    case expandedTopic = "expanded_topic"
    case deemphasizedTopic = "deemphasized_topic"
}

public enum Inf6TrendSignalImportance: String, Codable, Hashable {
    case high
    case medium
    case low
}

public struct Inf6TrendPatternRecommendation: Codable, Hashable {
    public var patternID: String
    public var observedSupportingQuestionCount: Int

    enum CodingKeys: String, CodingKey {
        case patternID = "pattern_id"
        case observedSupportingQuestionCount = "observed_supporting_question_count"
    }

    public init(patternID: String, observedSupportingQuestionCount: Int) {
        self.patternID = patternID
        self.observedSupportingQuestionCount = observedSupportingQuestionCount
    }
}

public struct Inf6TrendSignalEvidence: Codable, Hashable {
    public var version: String
    public var effectiveDate: String?
    public var domain: String
    public var topicNumber: Int?
    public var topicTitle: String
    public var changeType: String
    public var summary: String
    public var keywords: [String]
    public var beforeValue: String?
    public var sourceURL: String

    enum CodingKeys: String, CodingKey {
        case version
        case effectiveDate = "effective_date"
        case domain
        case topicNumber = "topic_number"
        case topicTitle = "topic_title"
        case changeType = "change_type"
        case summary
        case keywords
        case beforeValue = "before_value"
        case sourceURL = "source_url"
    }
}

public struct Inf6TrendSignal: Codable, Hashable, Identifiable {
    public var id: String { signalID }
    public var signalID: String
    public var titleJa: String
    public var category: Inf6TrendSignalCategory
    public var importance: Inf6TrendSignalImportance
    public var priorityRank: Int
    public var summaryJa: String
    public var matchedKeywords: [String]
    public var changeBreakdown: [String: Int]
    public var recommendedPatterns: [Inf6TrendPatternRecommendation]
    public var stemAxes: [String]
    public var distractorDirectives: [String]
    public var evidence: [Inf6TrendSignalEvidence]

    enum CodingKeys: String, CodingKey {
        case signalID = "signal_id"
        case titleJa = "title_ja"
        case category
        case importance
        case priorityRank = "priority_rank"
        case summaryJa = "summary_ja"
        case matchedKeywords = "matched_keywords"
        case changeBreakdown = "change_breakdown"
        case recommendedPatterns = "recommended_patterns"
        case stemAxes = "stem_axes"
        case distractorDirectives = "distractor_directives"
        case evidence
    }
}

public struct Inf6ForecastGroundingPolicy: Codable, Hashable {
    public var allowedSources: [String]
    public var mustTraceToSignal: Bool
    public var mustExplainWhyCurrent: Bool

    enum CodingKeys: String, CodingKey {
        case allowedSources = "allowed_sources"
        case mustTraceToSignal = "must_trace_to_signal"
        case mustExplainWhyCurrent = "must_explain_why_current"
    }
}

public struct Inf6ForecastQuestionBlueprint: Codable, Hashable, Identifiable {
    public var id: String { blueprintID }
    public var blueprintID: String
    public var titleJa: String
    public var priorityRank: Int
    public var trendSignalIDs: [String]
    public var objectiveJa: String
    public var requiredKeywordFocus: [String]
    public var recommendedPatternIDs: [String]
    public var stemAxes: [String]
    public var distractorDirectives: [String]
    public var groundingPolicy: Inf6ForecastGroundingPolicy
    public var deemphasizedKeywords: [String]

    enum CodingKeys: String, CodingKey {
        case blueprintID = "blueprint_id"
        case titleJa = "title_ja"
        case priorityRank = "priority_rank"
        case trendSignalIDs = "trend_signal_ids"
        case objectiveJa = "objective_ja"
        case requiredKeywordFocus = "required_keyword_focus"
        case recommendedPatternIDs = "recommended_pattern_ids"
        case stemAxes = "stem_axes"
        case distractorDirectives = "distractor_directives"
        case groundingPolicy = "grounding_policy"
        case deemphasizedKeywords = "deemphasized_keywords"
    }
}

// MARK: - MasteryState 逆算

/// 回答ログ 1 件。
public struct Inf6MMAAnswerLog: Codable, Hashable {
    public var questionID: String
    public var answeredAt: Double
    public var isCorrect: Bool
    /// その問題の `coverageTargetIDs`（問題側と一致）。
    public var coverageTargetIDs: [String]

    public init(questionID: String, answeredAt: Double, isCorrect: Bool, coverageTargetIDs: [String]) {
        self.questionID = questionID
        self.answeredAt = answeredAt
        self.isCorrect = isCorrect
        self.coverageTargetIDs = coverageTargetIDs
    }
}

/// CoverageTarget 解決用の軽量インデクス。
/// id -> (kind, refID) を引ける。
public struct Inf6MMACoverageIndex {
    /// coverageTargetID -> (kind, refID)
    public let byID: [String: (Inf6CoverageTarget.RefKind, String)]

    public init(targets: [Inf6CoverageTarget]) {
        var m: [String: (Inf6CoverageTarget.RefKind, String)] = [:]
        m.reserveCapacity(targets.count)
        for t in targets {
            m[t.id] = (t.kind, t.refID)
        }
        self.byID = m
    }
}

public enum Inf6MasteryInference {
    /// 回答ログ列から MasteryState を逆算する。
    ///
    /// ルール:
    /// - 同一原子 / 経脈に対して最新の観測を優先する（`answeredAt` 降順）。
    /// - 最新観測が `isCorrect == true` の場合、`.verified` を割り当てる。
    /// - 最新観測が `isCorrect == false` の場合、`.wrong` を割り当てる。
    /// - 一度以上観測があるが結果が混在している場合、直近が正答でも過去誤答があれば `.inProgress` に格下げする。
    /// - 未観測は `.unverified`。
    public static func infer(
        logs: [Inf6MMAAnswerLog],
        coverageIndex: Inf6MMACoverageIndex,
        now: Double = Date().timeIntervalSince1970
    ) -> Inf6MasteryState {
        // refID ごとに観測を集約する。
        // keyType: ("atom" or "edge", refID)
        struct Obs { let at: Double; let isCorrect: Bool }
        var atomObs: [String: [Obs]] = [:]
        var edgeObs: [String: [Obs]] = [:]

        for log in logs {
            for ctID in log.coverageTargetIDs {
                guard let (kind, refID) = coverageIndex.byID[ctID] else { continue }
                let o = Obs(at: log.answeredAt, isCorrect: log.isCorrect)
                switch kind {
                case .atom: atomObs[refID, default: []].append(o)
                case .edge: edgeObs[refID, default: []].append(o)
                }
            }
        }

        func reduce(_ obs: [Obs]) -> Inf6MasteryLevel {
            guard !obs.isEmpty else { return .unverified }
            let sorted = obs.sorted { $0.at > $1.at }
            let latest = sorted[0]
            let hasPastWrong = sorted.dropFirst().contains(where: { !$0.isCorrect })
            if latest.isCorrect {
                return hasPastWrong ? .inProgress : .verified
            } else {
                return .wrong
            }
        }

        var atomStates: [String: Inf6MasteryLevel] = [:]
        for (k, v) in atomObs { atomStates[k] = reduce(v) }
        var edgeStates: [String: Inf6MasteryLevel] = [:]
        for (k, v) in edgeObs { edgeStates[k] = reduce(v) }

        return Inf6MasteryState(
            atomStates: atomStates,
            edgeStates: edgeStates,
            lastUpdatedAt: now
        )
    }
}

// MARK: - 適応型問題選択

public enum Inf6AdaptiveQuestionSelector {

    /// 3 層スコア = Current(習得状態) × Trend(出題圧) × Urgency(受験日圧)
    ///
    /// 習得スコア規則:
    /// - `.wrong`      : 3.0
    /// - `.unverified` : 2.0
    /// - `.inProgress` : 1.0
    /// - `.verified`   : 0.1
    ///
    /// Trend 乗数（TrendSignal のキーワードが問題文にマッチした場合）:
    /// - emerging  × high   : ×2.5  （新出・高確率）
    /// - emerging  × medium : ×2.0
    /// - expanded  × high   : ×1.5  （比重上昇）
    /// - expanded  × medium : ×1.2
    /// - any       × low    : ×1.1
    /// - deemphasized       : ×0.4  （出題圧低下）
    /// - マッチなし          : ×1.0
    ///
    /// Urgency 乗数（ExamDeadline の残日数）:
    /// - 30日以内 : ×2.0
    /// - 60日以内 : ×1.5
    /// - 90日以内 : ×1.2
    /// - それ以外 / 未設定 / 解析失敗 : ×1.0
    ///
    /// 最終スコア = 習得スコア合計 × Trend 乗数 × Urgency 乗数。同点は `createdAt` 新しい順。
    public static func prioritize(
        questions: [Inf6GeneratedQuestion],
        coverageIndex: Inf6MMACoverageIndex,
        masteryState: Inf6MasteryState,
        trendSignals: [Inf6TrendSignal] = [],
        examDeadline: Inf6ExamDeadline? = nil,
        limit: Int = 10
    ) -> [Inf6GeneratedQuestion] {

        func levelScore(_ lvl: Inf6MasteryLevel) -> Double {
            switch lvl {
            case .wrong:      return 3.0
            case .unverified: return 2.0
            case .inProgress: return 1.0
            case .verified:   return 0.1
            }
        }

        func masteryScore(_ q: Inf6GeneratedQuestion) -> Double {
            guard !q.coverageTargetIDs.isEmpty else { return 0 }
            var s = 0.0
            for ctID in q.coverageTargetIDs {
                guard let (kind, refID) = coverageIndex.byID[ctID] else {
                    s += 2.0
                    continue
                }
                switch kind {
                case .atom: s += levelScore(masteryState.atomLevel(refID))
                case .edge: s += levelScore(masteryState.edgeLevel(refID))
                }
            }
            return s
        }

        func trendMultiplier(_ q: Inf6GeneratedQuestion) -> Double {
            guard !trendSignals.isEmpty else { return 1.0 }
            let haystack = (q.prompt + " " + q.explanation).lowercased()
            var best = 1.0
            for signal in trendSignals {
                let matched = signal.matchedKeywords.contains {
                    haystack.contains($0.lowercased())
                }
                guard matched else { continue }
                if signal.category == .deemphasizedTopic { return 0.4 }
                let boost: Double
                switch signal.importance {
                case .high:
                    boost = signal.category == .emergingTopic ? 2.5 : 1.5
                case .medium:
                    boost = signal.category == .emergingTopic ? 2.0 : 1.2
                case .low:
                    boost = 1.1
                }
                best = max(best, boost)
            }
            return best
        }

        func parseISO8601(_ raw: String) -> Date? {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: raw)
        }

        func urgencyMultiplier(_ deadline: Inf6ExamDeadline?) -> Double {
            guard let deadline,
                  let scheduledAt = parseISO8601(deadline.scheduledAt) else { return 1.0 }
            let daysRemaining = Int(ceil(scheduledAt.timeIntervalSinceNow / 86_400))
            if daysRemaining <= 30 { return 2.0 }
            if daysRemaining <= 60 { return 1.5 }
            if daysRemaining <= 90 { return 1.2 }
            return 1.0
        }

        let urgency = urgencyMultiplier(examDeadline)

        let scored = questions.map { q in
            (q: q, s: masteryScore(q) * trendMultiplier(q) * urgency)
        }
        let sorted = scored.sorted { a, b in
            if a.s != b.s { return a.s > b.s }
            return a.q.createdAt > b.q.createdAt
        }
        return Array(sorted.prefix(max(0, limit))).map { $0.q }
    }

    /// 問題が今の出題圧が高い論点に該当するか。UI バッジ用。
    public static func isNowOnExam(
        _ q: Inf6GeneratedQuestion,
        trendSignals: [Inf6TrendSignal]
    ) -> Bool {
        guard !trendSignals.isEmpty else { return false }
        let haystack = (q.prompt + " " + q.explanation).lowercased()
        return trendSignals.contains { signal in
            guard signal.category != .deemphasizedTopic else { return false }
            guard signal.importance == .high || signal.importance == .medium else { return false }
            return signal.matchedKeywords.contains { haystack.contains($0.lowercased()) }
        }
    }
}

// MARK: - Forecast Authoring ローダー

/// 試験別の TrendSignal / ForecastBlueprint を読み込む。
///
/// 検索順:
/// 1. sharedRoot/mma/<sourceFamily>/forecast_authoring.json（生成済み / ユーザー配置）
/// 2. Bundle.main（Xcode Resources に追加済みの場合）
///
/// ファイルが無い場合は空配列を返す（Trend 乗数は ×1.0 になりスコアに影響しない）。
public enum Inf6ForecastAuthoringLoader {

    public struct ForecastAuthoring: Codable {
        public var schemaID: String
        public var sourceFamily: String
        public var trendSignals: [Inf6TrendSignal]
        public var forecastBlueprints: [Inf6ForecastQuestionBlueprint]

        enum CodingKeys: String, CodingKey {
            case schemaID = "schema_id"
            case sourceFamily = "source_family"
            case trendSignals = "trend_signals"
            case forecastBlueprints = "forecast_blueprints"
        }
    }

    public static func loadSignals(sourceFamily: String) -> [Inf6TrendSignal] {
        load(sourceFamily: sourceFamily)?.trendSignals ?? []
    }

    public static func loadBlueprints(sourceFamily: String) -> [Inf6ForecastQuestionBlueprint] {
        load(sourceFamily: sourceFamily)?.forecastBlueprints ?? []
    }

    /// sharedRoot/mma/<sourceFamily>/forecast_authoring.json に TrendSignal を保存する。
    /// MMA パイプラインが GPT で生成した信号を永続化するために使う。
    public static func save(signals: [Inf6TrendSignal], blueprints: [Inf6ForecastQuestionBlueprint], sourceFamily: String) throws {
        guard let dir = _dir(sourceFamily: sourceFamily) else { return }
        let authoring = ForecastAuthoring(
            schemaID: "inf6.forecast-authoring.v1",
            sourceFamily: sourceFamily,
            trendSignals: signals,
            forecastBlueprints: blueprints
        )
        let data = try JSONEncoder().encode(authoring)
        Inf6MetadataStore.putCodable(authoring, domain: .forecast, key: sourceFamily)
        try data.write(to: dir.appendingPathComponent("forecast_authoring.json"), options: .atomic)
    }

    private static func load(sourceFamily: String) -> ForecastAuthoring? {
        // 1. metadata file store
        if let fa = Inf6MetadataStore.getCodable(ForecastAuthoring.self, domain: .forecast, key: sourceFamily) {
            return fa
        }
        // 2. sharedRoot
        if let dir = _dir(sourceFamily: sourceFamily) {
            let url = dir.appendingPathComponent("forecast_authoring.json")
            if let data = try? Data(contentsOf: url),
               let authoring = try? JSONDecoder().decode(ForecastAuthoring.self, from: data) {
                Inf6MetadataStore.putCodable(authoring, domain: .forecast, key: sourceFamily)
                return authoring
            }
        }
        // 3. KnowledgeDataStore (iCloud)
        let kdURL = Inf6KnowledgeDataStore.forecastURL(for: sourceFamily)
        if let data = Inf6KnowledgeDataStore.loadData(at: kdURL),
           let authoring = try? JSONDecoder().decode(ForecastAuthoring.self, from: data) {
            Inf6MetadataStore.putCodable(authoring, domain: .forecast, key: sourceFamily)
            return authoring
        }
        // 4. Bundle fallback
        let name = "\(sourceFamily)_forecast_authoring_v1"
        if let url = Bundle.main.url(forResource: name, withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let authoring = try? JSONDecoder().decode(ForecastAuthoring.self, from: data) {
            Inf6MetadataStore.putCodable(authoring, domain: .forecast, key: sourceFamily)
            return authoring
        }
        return nil
    }

    private static func _dir(sourceFamily: String) -> URL? {
        let root = Inf6DataRoot.url()
        let dir = root.appendingPathComponent("mma/\(sourceFamily)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - 監査

public struct Inf6MMACoverageAuditReport {
    /// coverageTargets を持たない問題 ID。
    public var questionsWithoutCoverage: [String]
    /// 出典 URL を持たない問題 ID。
    public var questionsWithoutSource: [String]
    /// 出題対象がまだ存在しない原子 ID。
    public var uncoveredAtomIDs: [String]
    /// 出題対象がまだ存在しない経脈 ID。
    public var uncoveredEdgeIDs: [String]

    public var isPass: Bool {
        questionsWithoutCoverage.isEmpty
            && questionsWithoutSource.isEmpty
            && uncoveredAtomIDs.isEmpty
            && uncoveredEdgeIDs.isEmpty
    }
}

public enum Inf6MMAAudit {
    /// 仕様書の成功条件に従って、与えられた問題集合が MMA 契約を満たすか監査する。
    public static func audit(
        atoms: [Inf6KnowledgeAtom],
        edges: [Inf6KnowledgeEdge],
        targets: [Inf6CoverageTarget],
        questions: [Inf6GeneratedQuestion]
    ) -> Inf6MMACoverageAuditReport {
        let index = Inf6MMACoverageIndex(targets: targets)

        var questionsWithoutCoverage: [String] = []
        var questionsWithoutSource: [String] = []
        for q in questions {
            if q.coverageTargetIDs.isEmpty {
                questionsWithoutCoverage.append(q.id)
            }
            if q.sourceURLs.isEmpty {
                questionsWithoutSource.append(q.id)
            }
        }

        // 問題側が被覆する原子 / 経脈の集合
        var coveredAtoms: Set<String> = []
        var coveredEdges: Set<String> = []
        for q in questions {
            for ctID in q.coverageTargetIDs {
                guard let (kind, refID) = index.byID[ctID] else { continue }
                switch kind {
                case .atom: coveredAtoms.insert(refID)
                case .edge: coveredEdges.insert(refID)
                }
            }
        }

        let uncoveredAtomIDs = atoms.map(\.id).filter { !coveredAtoms.contains($0) }
        // 重要経脈のみを必須とするが、本実装では v1 として全経脈を対象に置く（仕様書の保守的解釈）。
        let uncoveredEdgeIDs = edges.map(\.id).filter { !coveredEdges.contains($0) }

        return Inf6MMACoverageAuditReport(
            questionsWithoutCoverage: questionsWithoutCoverage,
            questionsWithoutSource: questionsWithoutSource,
            uncoveredAtomIDs: uncoveredAtomIDs,
            uncoveredEdgeIDs: uncoveredEdgeIDs
        )
    }
}

// MARK: - MasteryState 永続化

/// shared root 配下の JSON として保存される MasteryState ストア。
/// 保存先パスは呼び出し側で指定する（共通保存契約に従う）。
public enum Inf6MasteryStateStore {
    public enum IOError: LocalizedError {
        case encodeFailed(Error)
        case decodeFailed(Error)
        case readFailed(Error)
        case writeFailed(Error)

        public var errorDescription: String? {
            switch self {
            case .encodeFailed(let e): return "MasteryState エンコード失敗: \(e.localizedDescription)"
            case .decodeFailed(let e): return "MasteryState デコード失敗: \(e.localizedDescription)"
            case .readFailed(let e):   return "MasteryState 読込失敗: \(e.localizedDescription)"
            case .writeFailed(let e):  return "MasteryState 書込失敗: \(e.localizedDescription)"
            }
        }
    }

    public static func load(from url: URL) throws -> Inf6MasteryState {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw IOError.readFailed(error)
        }
        do {
            return try JSONDecoder().decode(Inf6MasteryState.self, from: data)
        } catch {
            throw IOError.decodeFailed(error)
        }
    }

    public static func save(_ state: Inf6MasteryState, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try enc.encode(state)
        } catch {
            throw IOError.encodeFailed(error)
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
        } catch {
            throw IOError.writeFailed(error)
        }
    }
}
