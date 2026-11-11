//
//  Inf6CorePaperStore.swift
//  inf6
//
//  E資格 Core Paper — ストア
//  Core Paper は metadata file store を正本として読み書きする。
//

import Foundation
import Observation

// MARK: - Store

@Observable
final class Inf6CorePaperStore {

    // MARK: State
    private(set) var papers: [Inf6CorePaper] = []
    var progress: [String: Inf6CorePaperProgress] = [:]   // paperId → progress
    var schedule: [String: Inf6CorePaperScheduleEntry] = [:] // paperId → entry
    private var _lastPapersLoadTime: CFAbsoluteTime = 0
    private let _loadSemaphore = DispatchSemaphore(value: 0)
    private(set) var isLoaded = false

    // MARK: Derived
    var sortedByRecommendedOrder: [Inf6CorePaper] {
        papers.sorted {
            let c0 = Inf6CorePaperCategory.infer(from: $0.tags)
            let c1 = Inf6CorePaperCategory.infer(from: $1.tags)
            if c0.recommendedOrder != c1.recommendedOrder {
                return c0.recommendedOrder < c1.recommendedOrder
            }
            return $0.title < $1.title
        }
    }

    // MARK: Init
    init() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            _loadAllSync()
        }
    }

    private func _loadAllSync() {
        loadPapers()
        loadProgress()
        loadSchedule()
        isLoaded = true
        _loadSemaphore.signal()
    }

    func waitUntilLoaded() {
        guard !isLoaded else { return }
        _loadSemaphore.wait()
        _loadSemaphore.signal()
    }

    // MARK: - metadata file store loading

    private func loadPapers() {
        let dbPapers = Inf6MetadataStore.listAllCodable(Inf6CorePaper.self, domain: .papers)
        papers = dbPapers
            .map(\.value)
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        _lastPapersLoadTime = CFAbsoluteTimeGetCurrent()
        NSLog("[Inf6CorePaperStore] Loaded %d papers from metadata file store", papers.count)
    }

    func reloadPapersFromMetadataStore(force: Bool = false) {
        waitUntilLoaded()
        let elapsed = CFAbsoluteTimeGetCurrent() - _lastPapersLoadTime
        if !force && elapsed < 10 && !papers.isEmpty {
            NSLog("[Inf6CorePaperStore] Skipping reload, last load was %.1fs ago", elapsed)
            return
        }
        loadPapers()
    }

    // MARK: - Progress persistence

    private func loadProgress() {
        let dbItems = Inf6MetadataStore.listAllCodable(Inf6CorePaperProgress.self, domain: .paperProgress)
        if !dbItems.isEmpty {
            progress = Dictionary(uniqueKeysWithValues: dbItems.map { ($0.key, $0.value) })
        }
    }

    func saveProgress() {
        for (k, v) in progress { Inf6MetadataStore.putCodable(v, domain: .paperProgress, key: k) }
    }

    func updateProgress(paperId: String, update: (inout Inf6CorePaperProgress) -> Void) {
        var p = progress[paperId] ?? Inf6CorePaperProgress(paperId: paperId)
        update(&p)
        p.lastStudiedAt = Date()
        progress[paperId] = p
        saveProgress()
    }

    // MARK: - Schedule persistence

    private func loadSchedule() {
        let dbItems = Inf6MetadataStore.listAllCodable(Inf6CorePaperScheduleEntry.self, domain: .examSchedule)
        if !dbItems.isEmpty {
            schedule = Dictionary(uniqueKeysWithValues: dbItems.map { ($0.key, $0.value) })
        }
    }

    func saveSchedule() {
        for (k, v) in schedule { Inf6MetadataStore.putCodable(v, domain: .examSchedule, key: k) }
    }

    func updateSchedule(paperId: String, update: (inout Inf6CorePaperScheduleEntry) -> Void) {
        var e = schedule[paperId] ?? Inf6CorePaperScheduleEntry(paperId: paperId)
        update(&e)
        schedule[paperId] = e
        saveSchedule()
    }

    // MARK: - Statistics

    var totalCount: Int { papers.count }

    var doneCount: Int {
        papers.filter { progress[$0.id]?.status == .done }.count
    }

    var readingCount: Int {
        papers.filter { progress[$0.id]?.status == .reading }.count
    }

    var notStartedCount: Int {
        papers.filter { (progress[$0.id]?.status ?? .notStarted) == .notStarted }.count
    }

    var achievementByPaperID: [String: Inf6KnowledgeAchievementState] {
        var result = progress.mapValues { $0.achievementState }
        for paper in papers {
            let pdfURL = paper.resolvedPDFURL
            let assetsAchievement = Self._achievement(fromAssetsPipeline: Self._assetsPipelineState(pdfURL: pdfURL))
            let artifactAchievement = pdfURL.map(Self._achievement(fromLearningArtifactsFor:)) ?? .notStarted
            result[paper.id] = Self._maxAchievement(
                Self._maxAchievement(result[paper.id] ?? .notStarted, assetsAchievement),
                artifactAchievement
            )
        }
        return result
    }

    /// Fast variant of `achievementByPaperID` that reuses pre-computed bulk caches
    /// instead of re-scanning iCloud files. Use this when the caller already has
    /// the assets-pipeline states and learning-artifact states in hand.
    func achievementByPaperID(
        assetsPipelineStates: [String: Inf6AssetsPipelineRunState],
        learningArtifactStates: [String: Inf6CorePaperLearningArtifactState]
    ) -> [String: Inf6KnowledgeAchievementState] {
        var result = progress.mapValues { $0.achievementState }
        for paper in papers {
            let assetsState = assetsPipelineStates[paper.id] ?? .none
            let assetsAchievement = Self._achievement(fromAssetsPipeline: assetsState)

            let artifactState = learningArtifactStates[paper.id] ?? Inf6CorePaperLearningArtifactState()
            var artifactAchievement: Inf6KnowledgeAchievementState = .notStarted
            if artifactState.hasQuiz {
                artifactAchievement = Self._maxAchievement(artifactAchievement, .questioned)
            }
            if artifactState.hasFormulaExplanation || artifactState.hasOverview || artifactState.hasAddedExplanation {
                artifactAchievement = Self._maxAchievement(artifactAchievement, .explained)
            } else if artifactState.hasFormulaCard {
                artifactAchievement = Self._maxAchievement(artifactAchievement, .annotating)
            }

            result[paper.id] = Self._maxAchievement(
                Self._maxAchievement(result[paper.id] ?? .notStarted, assetsAchievement),
                artifactAchievement
            )
        }
        return result
    }

    func assetsPipelineStateByPaperID() -> [String: Inf6AssetsPipelineRunState] {
        return papers.reduce(into: [:]) { result, paper in
            result[paper.id] = Self._assetsPipelineState(pdfURL: paper.resolvedPDFURL)
        }
    }

    func learningArtifactStateByPaperID() -> [String: Inf6CorePaperLearningArtifactState] {
        papers.reduce(into: [:]) { result, paper in
            guard let pdfURL = paper.resolvedPDFURL else { return }
            result[paper.id] = Self._learningArtifactState(for: pdfURL)
        }
    }

    private static func _achievement(fromAssetsPipeline state: Inf6AssetsPipelineRunState) -> Inf6KnowledgeAchievementState {
        switch state {
        case .none, .failed:
            return .notStarted
        case .running:
            return .collecting
        case .finished:
            return .explained
        }
    }

    private static func _achievement(fromLearningArtifactsFor pdfURL: URL) -> Inf6KnowledgeAchievementState {
        let state = _learningArtifactState(for: pdfURL)
        var result: Inf6KnowledgeAchievementState = .notStarted
        if state.hasQuiz {
            result = _maxAchievement(result, .questioned)
        }
        if state.hasFormulaExplanation || state.hasOverview || state.hasAddedExplanation {
            result = _maxAchievement(result, .explained)
        } else if state.hasFormulaCard {
            result = _maxAchievement(result, .annotating)
        }
        return result
    }

    private static func _assetsPipelineState(pdfURL: URL?) -> Inf6AssetsPipelineRunState {
        if let pdfURL {
            if let structured = inf6LoadStructuredAssetsPipelineRunState(pdfURL: pdfURL) {
                return structured
            }
            let current = inf6LoadAssetsPipelineRunState(pdfURL: pdfURL)
            if current != .none {
                return current
            }
        }
        return .none
    }

    private static func _learningArtifactState(for pdfURL: URL) -> Inf6CorePaperLearningArtifactState {
        guard let baseDir = _knowledgeCardBaseDir(for: pdfURL) else {
            return Inf6CorePaperLearningArtifactState()
        }

        let overviewURL = baseDir.appendingPathComponent("\(_paperBaseName(from: pdfURL)).abstract.txt")
        let hasOverview = _nonEmptyTextFileExists(overviewURL)

        let miniDir = baseDir.appendingPathComponent("mini", isDirectory: true)
        let notesDir = baseDir.appendingPathComponent("notes", isDirectory: true)
        let mini = _scanMiniCardArtifacts(in: miniDir)
        let hasAddedExplanation = _scanAddedExplanationArtifacts(in: miniDir) || _scanAddedExplanationArtifacts(in: notesDir)
        let hasQuiz = _hasGeneratedQuiz(in: baseDir)

        return Inf6CorePaperLearningArtifactState(
            hasOverview: hasOverview,
            hasFormulaCard: mini.hasFormulaCard,
            hasFormulaExplanation: mini.hasFormulaExplanation,
            hasQuiz: hasQuiz,
            hasAddedExplanation: hasAddedExplanation
        )
    }

    private static func _knowledgeCardBaseDir(for pdfURL: URL) -> URL? {
        let folderKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: _paperBaseName(from: pdfURL))
        guard !folderKey.isEmpty else { return nil }
        guard let sharedRoot = try? Inf6LibraryView._sharedRootDir() else { return nil }
        let root = sharedRoot
            .appendingPathComponent(Inf6KnowledgeCardsPaths.rootFolderName, isDirectory: true)
        let canonical = root.appendingPathComponent(folderKey, isDirectory: true)
        return canonical
    }

    private static func _paperBaseName(from pdfURL: URL) -> String {
        let raw = pdfURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.lowercased().hasSuffix(".pdf") {
            return String(raw.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return pdfURL.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func _scanMiniCardArtifacts(in miniDir: URL) -> (hasFormulaCard: Bool, hasFormulaExplanation: Bool) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: miniDir.path, isDirectory: &isDir), isDir.boolValue else {
            return (false, false)
        }

        do {
            let files = try fm.contentsOfDirectory(at: miniDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            var hasCard = false
            var hasExplanation = false

            for file in files {
                let name = file.lastPathComponent
                if name.hasSuffix(".mini.pdf") || name.hasSuffix(".mini.meta.json") || name.hasSuffix(".cards.json") {
                    if _nonEmptyFileExists(file) {
                        hasCard = true
                    }
                }
                if name.hasSuffix(".mini.txt") || name.hasSuffix(".mini.rtf") {
                    if _nonEmptyFileExists(file) {
                        hasCard = true
                        hasExplanation = true
                    }
                }
            }

            return (hasCard, hasExplanation)
        } catch {
            print("[Inf6CorePaperStore] mini artifact scan failed: \(miniDir.path) error=\(error)")
            return (false, false)
        }
    }

    private static func _scanAddedExplanationArtifacts(in miniDir: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: miniDir.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }

        do {
            let files = try fm.contentsOfDirectory(at: miniDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            for file in files {
                let name = file.lastPathComponent
                guard name.hasPrefix("p"), name.hasSuffix(".notes.json") else { continue }
                guard let data = try? Data(contentsOf: file), !data.isEmpty else { continue }
                if let notes = try? JSONDecoder().decode([Inf6ExtraNote].self, from: data) {
                    let hasText = notes.contains {
                        !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        !($0.rtf?.isEmpty ?? true)
                    }
                    if hasText { return true }
                } else {
                    print("[Inf6CorePaperStore] notes artifact decode failed: \(file.path)")
                }
            }
        } catch {
            print("[Inf6CorePaperStore] notes artifact scan failed: \(miniDir.path) error=\(error)")
        }
        return false
    }

    private static func _hasGeneratedQuiz(in baseDir: URL) -> Bool {
        let url = baseDir.appendingPathComponent("paper.quiz.json")
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return false }
        do {
            let quiz = try JSONDecoder().decode(Inf6PaperQuiz.self, from: data)
            return !quiz.questions.isEmpty
        } catch {
            print("[Inf6CorePaperStore] quiz artifact decode failed: \(url.path) error=\(error)")
            return false
        }
    }

    private static func _nonEmptyTextFileExists(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return false }
        guard let text = String(data: data, encoding: .utf8) else { return true }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func _nonEmptyFileExists(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber
        else { return false }
        return size.intValue > 0
    }

    private static func _maxAchievement(
        _ lhs: Inf6KnowledgeAchievementState,
        _ rhs: Inf6KnowledgeAchievementState
    ) -> Inf6KnowledgeAchievementState {
        _achievementRank(lhs) >= _achievementRank(rhs) ? lhs : rhs
    }

    private static func _achievementRank(_ state: Inf6KnowledgeAchievementState) -> Int {
        switch state {
        case .notStarted: return 0
        case .collecting: return 1
        case .reading: return 2
        case .annotating: return 3
        case .explained: return 4
        case .questioned: return 5
        case .measured: return 6
        }
    }

    var overallProgress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(doneCount) / Double(totalCount)
    }

    // MARK: - Coverage

    /// シラバス大項目 → カバーしている論文一覧
    func papersForSection(_ def: Inf6SyllabusCoverageDefinition) -> [Inf6CorePaper] {
        let tagSet = Set(def.coveringTags.map { $0.lowercased() })
        return papers.filter { paper in
            paper.tags.contains { tagSet.contains($0.lowercased()) }
        }
    }

    /// 各シラバス大項目の Coverage（該当論文数）
    func coverageSummary() throws -> [(definition: Inf6SyllabusCoverageDefinition, papers: [Inf6CorePaper])] {
        try Inf6SyllabusCoverageDefinition.loadDefinitions().map { def in
            (definition: def, papers: papersForSection(def))
        }
    }

    // MARK: - Related Papers

    /// 指定論文と同じカテゴリの他の論文（関連性）
    func relatedPapers(to paper: Inf6CorePaper) -> [Inf6CorePaper] {
        let cat = Inf6CorePaperCategory.infer(from: paper.tags)
        return papers.filter { $0.id != paper.id && Inf6CorePaperCategory.infer(from: $0.tags) == cat }
    }

    // MARK: - Learning Guide

    /// 次に学ぶべき論文トップN（優先度高セクションで蓄積が低い未着手論文から）
    func nextRecommendedPapers(count: Int = 5) -> [Inf6CorePaper] {
        let nodes = Inf6SyllabusCoverageNode.buildAll(store: self)
            .sorted { lhs, rhs in
                if lhs.isHighPriority != rhs.isHighPriority {
                    return lhs.isHighPriority
                }
                return lhs.accumulationLevel < rhs.accumulationLevel
            }

        var seen = Set<String>()
        var result: [Inf6CorePaper] = []

        for node in nodes {
            for paper in node.coveringPapers {
                guard !seen.contains(paper.id) else { continue }
                let status = progress[paper.id]?.status ?? .notStarted
                guard status == .notStarted else { continue }
                seen.insert(paper.id)
                result.append(paper)
                if result.count >= count { return result }
            }
        }
        return result
    }

    /// 推奨理由を返す（Watch表示用）
    func recommendationReason(for paper: Inf6CorePaper) -> String {
        let nodes = Inf6SyllabusCoverageNode.buildAll(store: self)
        // Find the first high-priority node that covers this paper
        if let node = nodes.first(where: { $0.isHighPriority && $0.coveringPapers.contains(where: { $0.id == paper.id }) }) {
            return "E資格 高優先「\(node.sectionName)」の未着手論文"
        }
        // Fallback: any node
        if let node = nodes.first(where: { $0.coveringPapers.contains(where: { $0.id == paper.id }) }) {
            return "「\(node.sectionName)」の未着手論文"
        }
        return "未着手論文"
    }

    /// 優先度高かつ蓄積度30%未満のアラームノード
    func topAlarmNodes() -> [Inf6SyllabusCoverageNode] {
        Inf6SyllabusCoverageNode.buildAll(store: self)
            .filter { $0.isHighPriority && $0.accumulationLevel < 0.3 }
            .sorted { $0.accumulationLevel < $1.accumulationLevel }
    }
}

// MARK: - Shared singleton

extension Inf6CorePaperStore {
    static let shared = Inf6CorePaperStore()
}

struct Inf6CorePaperLearningArtifactState: Codable, Hashable {
    var hasOverview: Bool = false
    var hasFormulaCard: Bool = false
    var hasFormulaExplanation: Bool = false
    var hasQuiz: Bool = false
    var hasAddedExplanation: Bool = false

    var overviewState: String {
        hasOverview ? "generated" : "none"
    }

    var formulaState: String {
        if hasFormulaExplanation { return "explained" }
        if hasFormulaCard { return "created" }
        return "none"
    }

    var quizState: String {
        hasQuiz ? "generated" : "none"
    }

    var addedExplanationState: String {
        hasAddedExplanation ? "generated" : "none"
    }
}
