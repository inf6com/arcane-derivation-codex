import Foundation
import CryptoKit
import PDFKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Vision) && canImport(UIKit)
import Vision
#endif

enum Inf6EshikakuDrillPipeline {
    static let visionOCRLock = NSLock()
    private static let _generatedExplanationProviderID = "generated_explanation"
    private static let _generatedExplanationRoleID = "explanation_item"
    private static let _generatedExplanationStatusID = "explanation_generated"

    private static func _canonicalExplanationPaperID(sourceFamily: String, nodeID: String) -> String {
        "explanation:\(sourceFamily):\(nodeID)"
    }

    static func isGeneratedExplanationProvider(_ provider: String) -> Bool {
        provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == _generatedExplanationProviderID
    }

    struct EntityCropExpansion: Codable, Equatable {
        var top: CGFloat = 0
        var bottom: CGFloat = 0
        var left: CGFloat = 0
        var right: CGFloat = 0
        static let zero = EntityCropExpansion()
        /// PDF初回取り込みの標準値。図表数式タイトルの上下欠落を防ぐ。
        static let standard = EntityCropExpansion(top: 0.08, bottom: 0.08)
    }

    enum FailureKind: String, Codable {
        case missingStorage
        case paperURLResolution
        case pdfHTTP
        case pdfMIME
        case pdfMagic
        case pdfPersistence
        case pdfRead
        case pdfIdentity
        case pdfTextExtraction
        case entityExtraction
        case entityImageExtraction
        case openAI
        case openAIRateLimit
        case arxivRateLimit
        case modelStructuredOutput
        case emptySource
        case originUnverified
        case cancelled
        case unknown
    }

    struct ResolutionAttempt: Codable, Hashable {
        let stage: String
        let target: String
        let result: String
    }

    struct FailureReport: Codable, Hashable {
        let operation: String
        let paperID: String
        let paperTitle: String
        let kind: FailureKind
        let cause: String
        let plan: [String]
        let attempts: [ResolutionAttempt]
    }

    struct DrillPipelineError: LocalizedError {
        let report: FailureReport
        let underlying: Error?

        var errorDescription: String? {
            diagnosticMessage(for: report)
        }
    }

    struct DrillEntry: Identifiable {
        let id: String
        let paper: Inf6CorePaper
        let folderKey: String
        let domainPrefix: String
        let domainLabelJa: String
        let domainLabelEn: String
        var quiz: Inf6PaperQuiz?
        var pdfURL: URL?
        var downloadURL: URL?
        var kcExists: Bool
        var syllabusTitle: String?
        var syllabusNodeID: String?
        var syllabusContext: String
    }

    struct OriginUnverifiedItem: Identifiable, Hashable {
        let id: String
        let nodeID: String
        let titleJa: String
        let titleEn: String
        let domainPrefix: String
        let domainLabelJa: String
        let domainLabelEn: String
        let candidates: [String]
        let reason: String
        let plan: [String]
    }

    struct OriginExplorationOutcome: Codable, Hashable {
        let kind: String
        let selectedPaperID: String?
    }

    struct DrillGroup: Identifiable {
        let id: String
        let labelJa: String
        let labelEn: String
        var entries: [DrillEntry]
        var unverifiedOrigins: [OriginUnverifiedItem] = []
    }

    private struct _SelectedCorePaper {
        let paper: Inf6CorePaper
        let link: Inf6SyllabusPaperLink
        let localPDF: (url: URL, normalizedName: String)?
        let downloadURL: URL?
        let plannedFileName: String
        let originScore: Double
    }

    private enum _OriginPaperSelection {
        case selected(_SelectedCorePaper)
        case unverified(OriginUnverifiedItem)
    }

    private struct _PDFDownloadResult {
        let url: URL
        let data: Data
        let attempts: [ResolutionAttempt]
    }

    private struct _PDFCandidateFailure: Error {
        let kind: FailureKind
        let message: String
    }

    private struct _ResolvedPDF {
        let url: URL
        let sourceWasReplaced: Bool
    }

    private struct _EntityExtractionFailure: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    private struct _LLMInvocationRecord: Codable {
        let id: String
        let targetID: String
        let inputHash: String
        let modelID: String
        let featureName: String
        let startedAt: Double
        var finishedAt: Double?
        var status: String
        var inputBytes: Int
        var outputBytes: Int?
        var errorMessage: String?
    }

    struct ExecutionRecord: Codable {
        let id: String
        let targetID: String
        let featureName: String
        let startedAt: Double
        var finishedAt: Double?
        var status: String
        var inputBytes: Int
        var outputBytes: Int?
        var errorMessage: String?
    }

    private struct _OriginExplorationRecord: Codable {
        let id: String
        let sourceFamily: String
        let nodeID: String
        let title: String
        let startedAt: Double
        var finishedAt: Double?
        var status: String
        var errorMessage: String?
    }

    private actor _AsyncPermitGate {
        private let limit: Int
        private var active = 0

        init(limit: Int) {
            self.limit = max(1, limit)
        }

        func tryAcquire() -> Bool {
            if active < limit {
                active += 1
                return true
            }
            return false
        }

        func release() {
            active = max(0, active - 1)
        }

        func acquire() async throws {
            while true {
                try Task.checkCancellation()
                if tryAcquire() {
                    return
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private actor _LLMInvocationGate {
        private var inFlight: Set<String> = []
        private let permitGate = _AsyncPermitGate(limit: 1)

        func enter(_ key: String, featureName: String, targetID: String, inputHash: String) async throws {
            if inFlight.contains(key) {
                throw NSError(
                    domain: "Inf6EshikakuDrillPipeline",
                    code: 60,
                    userInfo: [NSLocalizedDescriptionKey: "同一LLM工程が実行中です: \(featureName) target=\(targetID) input_hash=\(inputHash)"]
                )
            }
            inFlight.insert(key)
            do {
                try await permitGate.acquire()
            } catch {
                inFlight.remove(key)
                throw error
            }
        }

        func leave(_ key: String) async {
            inFlight.remove(key)
            await permitGate.release()
        }
    }

    private static let _llmInvocationGate = _LLMInvocationGate()
    private static let _metadataWriteGate = _AsyncPermitGate(limit: 1)

    private static let _domainDefs: [(prefix: String, ja: String, en: String)] = [
        ("e_01", "数学的基礎", "Mathematical Foundations"),
        ("e_02", "機械学習", "Machine Learning"),
        ("e_03", "深層学習の基礎", "Deep Learning Foundations"),
        ("e_04", "深層学習の応用", "Deep Learning Applications"),
        ("e_05", "開発・運用環境", "Development & Operations"),
    ]

    // MARK: - Step 1

    static func selectOriginPapers(sourceFamily: String, forcePapersReload: Bool = false) throws -> [DrillGroup] {
        let _t0 = CFAbsoluteTimeGetCurrent()
        func _ms(_ since: CFAbsoluteTime) -> String { String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - since) * 1000) }

        // 統合や引き取りをここで行わない。
        //
        // 画面を出すための経路であり、ファイルを触る処理を挟むと、その分だけ
        // 表示が遅れる。iCloud に追い出されたものが混ざれば取得待ちで止まる。
        // 片付けはユーザーが明示的に始めるものとし、読み込みは読むだけにする。

        let store = Inf6CorePaperStore.shared
        // force: 起源探索/削除の直後の再読込時のみ true にする。通常ロードでは
        // ストア側の10秒スロットルに従い、無条件フル再読込による遅延を避ける。
        store.reloadPapersFromMetadataStore(force: forcePapersReload)
        var storedPaperIDs = Set(store.papers.map(\.id))
        NSLog("[DrillPipeline] selectOriginPapers(%@): papers reloaded, %d papers, %@ms", sourceFamily, store.papers.count, _ms(_t0))

        let structure = try _loadKnowledgeStructureOrThrow(sourceFamily: sourceFamily)
        NSLog("[DrillPipeline] selectOriginPapers(%@): structure loaded, %d nodes, %@ms", sourceFamily, structure.nodes.count, _ms(_t0))
        let leafNodes = _leafSyllabusNodes(in: structure)
        let structurePaperIDsByNodeID = _structurePaperIDsByNodeID(structure)
        let linksByNode = _loadSyllabusPaperLinks(sourceFamily: sourceFamily)
        NSLog("[DrillPipeline] selectOriginPapers(%@): links loaded, %d nodes-with-links, %@ms", sourceFamily, linksByNode.count, _ms(_t0))
        let storedQuizzes = Inf6MetadataStore.listAllCodable(Inf6PaperQuiz.self, domain: .quiz)
        let storedEntityIndexes = Inf6MetadataStore.listAllCodable(Inf6DocEntityIndex.self, domain: .docEntities)
        NSLog("[DrillPipeline] selectOriginPapers(%@): quizzes=%d entityIndexes=%d loaded, %@ms", sourceFamily, storedQuizzes.count, storedEntityIndexes.count, _ms(_t0))

        let fm = FileManager.default
        let kcRoot = Inf6KnowledgeCardsPaths.rootDirectoryURL()
        let kcFolders: Set<String> = {
            guard let root = kcRoot,
                  let items = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
            return Set(items)
        }()
        NSLog("[DrillPipeline] selectOriginPapers(%@): kcFolders=%d listed, %@ms", sourceFamily, kcFolders.count, _ms(_t0))

        let papersByID = Dictionary(uniqueKeysWithValues: store.papers.map { ($0.id, $0) })
        let nodesByID = Dictionary(uniqueKeysWithValues: structure.nodes.map { ($0.nodeID, $0) })

        var groups: [DrillGroup] = []

        for (prefix, ja, en) in _domainDefs {
            let _tDomain = CFAbsoluteTimeGetCurrent()
            var entries: [DrillEntry] = []
            var unverifiedOrigins: [OriginUnverifiedItem] = []

            let domainNodes = leafNodes.filter { $0.nodeID.hasPrefix(prefix) }
            for node in domainNodes {
                let selections = try _selectCorePaperForNode(
                    node: node,
                    domainPrefix: prefix,
                    domainLabelJa: ja,
                    domainLabelEn: en,
                    sourceFamily: sourceFamily,
                    structurePaperIDs: structurePaperIDsByNodeID[node.nodeID] ?? [],
                    searchLinks: linksByNode[node.nodeID] ?? [],
                    papersByID: papersByID,
                    storedPaperIDs: storedPaperIDs
                )
                for selection in selections {
                guard case .selected(let selected) = selection else {
                    if case .unverified(let item) = selection {
                        unverifiedOrigins.append(item)
                    }
                    continue
                }

                let folderKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(
                    from: selected.plannedFileName)
                guard !folderKey.isEmpty else { continue }

                let paper = selected.paper
                let titleKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paper.title)
                let titleEnKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paper.titleEn ?? "")
                let actualFolder = _findKCFolder(titleKey: folderKey, titleEnKey: titleEnKey, in: kcFolders)
                    ?? _findKCFolder(titleKey: titleKey, titleEnKey: titleEnKey, in: kcFolders)
                let usedKey = actualFolder ?? folderKey
                let kcExists = actualFolder != nil
                let artifactAliases = _artifactLookupAliases(
                    folderKey: usedKey,
                    titleKey: titleKey,
                    titleEnKey: titleEnKey,
                    paperID: paper.id
                )
                let storedQuiz = _findStoredArtifact(
                    in: storedQuizzes,
                    aliases: artifactAliases,
                    stablePaperIDKey: Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paper.id),
                    artifactKey: { $0.paperKey },
                    artifactTitle: { $0.paperTitle }
                )
                let entityIndex = _findStoredArtifact(
                    in: storedEntityIndexes,
                    aliases: artifactAliases,
                    stablePaperIDKey: Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paper.id),
                    artifactKey: { $0.pdfKey },
                    artifactTitle: { $0.pdfKey }
                )
                let quiz: Inf6PaperQuiz? = {
                    guard let storedQuiz, !storedQuiz.questions.isEmpty else { return nil }
                    if isGeneratedExplanationProvider(paper.provider) {
                        return storedQuiz
                    }
                    guard let entityIndex,
                          entityIndex.version >= Inf6DocEntityIndex.currentVersion
                    else { return nil }
                    let entitiesByID = Dictionary(uniqueKeysWithValues: entityIndex.entities.map { ($0.id, $0) })
                    let allBound = storedQuiz.questions.allSatisfy { question in
                        let isVisual = ["figure", "table", "equation"].contains(question.kind.lowercased())
                        if question.normalizedExerciseType == "py" {
                            let targetsByID = Dictionary(uniqueKeysWithValues: (storedQuiz.coverageTargets ?? []).map { ($0.id, $0) })
                            let codeIDs = (question.coverageTargetIDs ?? []).filter { $0.hasPrefix("code-practice-") }
                            return codeIDs.count == 1
                                && targetsByID[codeIDs[0]]?.kind == .code
                                && question.docEntityID == nil
                                && question.entityImagePath == nil
                        }
                        guard isVisual, let entityID = question.docEntityID else { return false }
                        let targetIDs = question.coverageTargetIDs ?? []
                        guard targetIDs.filter({ $0.hasPrefix("understanding-point-") }).count == 1,
                              targetIDs.filter({ $0.hasPrefix("doc-entity:") }).count == 1 else { return false }
                        guard let entity = entitiesByID[entityID],
                              question.entityImagePath == entity.imagePath,
                              question.pageIndex == entity.pageIndex,
                              _imageFileExists(entity.imagePath)
                        else { return false }
                        return question.kind.lowercased() == entity.kind.rawValue
                    }
                    if !allBound {
                        NSLog("[DrillPipeline] quiz loaded with unresolved visual binding: %@", storedQuiz.paperKey)
                    }
                    // 保存済み演習を、図表数式1件の結合不備だけで一覧から消さない。
                    // 不備は設問の画像表示側で表面化し、通常の設問と生成済み件数は保持する。
                    return storedQuiz
                }()

                entries.append(DrillEntry(
                    id: "\(node.nodeID)|\(paper.id)", paper: paper, folderKey: usedKey,
                    domainPrefix: prefix, domainLabelJa: ja, domainLabelEn: en,
                    quiz: quiz,
                    pdfURL: selected.localPDF?.url, downloadURL: selected.downloadURL, kcExists: kcExists,
                    syllabusTitle: node.titleJa.isEmpty ? node.titleEn : node.titleJa,
                    syllabusNodeID: node.nodeID,
                    syllabusContext: _syllabusContext(for: node, nodesByID: nodesByID)
                ))
                }
            }

            entries.sort { a, b in
                let an = a.syllabusNodeID ?? ""
                let bn = b.syllabusNodeID ?? ""
                if an != bn { return an.localizedStandardCompare(bn) == .orderedAscending }
                let aGenerated = isGeneratedExplanationProvider(a.paper.provider)
                let bGenerated = isGeneratedExplanationProvider(b.paper.provider)
                if aGenerated != bGenerated { return aGenerated && !bGenerated }

                let aYear = a.paper.year ?? Int.max
                let bYear = b.paper.year ?? Int.max
                if aYear != bYear { return aYear < bYear }

                let titleOrder = a.paper.title.localizedStandardCompare(b.paper.title)
                if titleOrder != .orderedSame { return titleOrder == .orderedAscending }

                return a.paper.id.localizedStandardCompare(b.paper.id) == .orderedAscending
            }

            unverifiedOrigins.sort {
                if $0.nodeID != $1.nodeID { return $0.nodeID.localizedStandardCompare($1.nodeID) == .orderedAscending }
                return $0.titleJa.localizedStandardCompare($1.titleJa) == .orderedAscending
            }

            let representedNodeIDs = Set(entries.compactMap(\.syllabusNodeID))
                .union(unverifiedOrigins.map(\.nodeID))
            let missingNodeIDs = domainNodes
                .map(\.nodeID)
                .filter { !representedNodeIDs.contains($0) }
            guard missingNodeIDs.isEmpty else {
                throw NSError(
                    domain: "Inf6EshikakuDrillPipeline",
                    code: 103,
                    userInfo: [
                        NSLocalizedDescriptionKey: "シラバス正本ノードが画面表示集合から欠落しています: domain=\(prefix) missing=\(missingNodeIDs.joined(separator: ","))"
                    ]
                )
            }

            if !entries.isEmpty || !unverifiedOrigins.isEmpty {
                groups.append(DrillGroup(
                    id: prefix,
                    labelJa: ja,
                    labelEn: en,
                    entries: entries,
                    unverifiedOrigins: unverifiedOrigins
                ))
            }
            NSLog("[DrillPipeline] selectOriginPapers(%@): domain=%@ %d nodes done, %@ms (domain-local)",
                  sourceFamily, prefix, domainNodes.count, _ms(_tDomain))
        }

        let totalPapers = groups.flatMap(\.entries).count
        let totalUnverifiedOrigins = groups.flatMap(\.unverifiedOrigins).count
        let missingRequiredDomains = _domainDefs
            .map(\.prefix)
            .filter { prefix in !groups.contains(where: { $0.id == prefix }) }
        guard missingRequiredDomains.isEmpty else {
            let missingJoined = missingRequiredDomains.joined(separator: ",")
            throw NSError(
                domain: "Inf6EshikakuDrillPipeline",
                code: 102,
                userInfo: [
                    NSLocalizedDescriptionKey: "E資格集中特訓の起源対応が欠落しています: missing_domains=\(missingJoined) entries=\(totalPapers)"
                ]
            )
        }
        NSLog("[DrillPipeline] Step1: %d groups, %d leaf-origin entries, %d origin-unverified nodes, total=%@ms", groups.count, totalPapers, totalUnverifiedOrigins, _ms(_t0))
        return groups
    }

    /// 起源探索の結果(syllabus_paper_link)を削除し、そのノードを未解決状態へ戻す。
    /// 論文本体(Inf6CorePaper)は他ノードから参照され得るため削除しない。
    /// 生成済みの演習だけを削除する。起源論文のリンクと論文レコード、
    /// および抽出済みの図表数式は残すため、再生成では論文の再取得も
    /// 図表の切り出しもやり直さずに済む。
    static func deleteGeneratedQuiz(folderKey: String, paperTitle: String, paperID: String) {
        let titleKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paperTitle)
        let aliases = _artifactLookupAliases(
            folderKey: folderKey, titleKey: titleKey, titleEnKey: "", paperID: paperID
        )
        func matches(_ storedRawKeys: [String]) -> Bool {
            let stored = Set(storedRawKeys.filter { !$0.isEmpty })
            if !aliases.isDisjoint(with: stored) { return true }
            let normalized = storedRawKeys
                .map { Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: $0) }
                .filter { !$0.isEmpty }
            return aliases.contains { alias in
                normalized.contains { $0 == alias || $0.hasSuffix("_\(alias)") }
            }
        }
        for record in Inf6MetadataStore.listAllCodable(Inf6PaperQuiz.self, domain: .quiz) {
            guard matches([record.key, record.value.paperKey, record.value.paperTitle]) else { continue }
            Inf6MetadataStore.delete(domain: .quiz, key: record.key)
            // 設問が消える以上、その設問に紐づく Ask 記録も残さない。
            Inf6DrillAskNoteStore.deleteAll(paperKey: record.key)
        }
        Inf6DrillAskNoteStore.deleteAll(paperKey: folderKey)

        // 概要解説も消す。_generateOverviewIfRequired は既存の概要が契約を満たす限り
        // 何もせず返るため、残したままだと再生成しても古い解説が使われ続ける。
        // 理解点は概要側にあるので、演習を作り直す以上こちらも作り直す必要がある。
        if let kcRoot = Inf6KnowledgeCardsPaths.rootDirectoryURL() {
            let dir = kcRoot.appendingPathComponent(folderKey)
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(folderKey).abstract.txt"))
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(folderKey).original_explanation.txt"))
        }

        // 解説項目の図表数式も消す。これはこの端末が作ったもので、
        // 残っていると作り直しても古いものが使われ続ける。実際、図を
        // 描けるようにした後で作り直しても、式のままだった。
        //
        // 論文から切り出したものは消さない。PDF から抽出した根拠であり、
        // 作り直すには PDF の再取得と再抽出が要る。
        _deleteTextbookGeneratedEntityEvidence(folderKey: folderKey)
    }

    static func deleteGeneratedQuizQuestions(
        folderKey: String,
        paperTitle: String,
        paperID: String,
        deletingCodeQuestions: Bool
    ) {
        let titleKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paperTitle)
        let aliases = _artifactLookupAliases(
            folderKey: folderKey, titleKey: titleKey, titleEnKey: "", paperID: paperID
        )
        func matches(_ storedRawKeys: [String]) -> Bool {
            let stored = Set(storedRawKeys.filter { !$0.isEmpty })
            if !aliases.isDisjoint(with: stored) { return true }
            let normalized = storedRawKeys
                .map { Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: $0) }
                .filter { !$0.isEmpty }
            return aliases.contains { alias in
                normalized.contains { $0 == alias || $0.hasSuffix("_\(alias)") }
            }
        }

        for record in Inf6MetadataStore.listAllCodable(Inf6PaperQuiz.self, domain: .quiz) {
            guard matches([record.key, record.value.paperKey, record.value.paperTitle]) else { continue }
            var quiz = record.value
            let removedQuestionIDs = Set(quiz.questions.filter { question in
                (question.normalizedExerciseType == "py") == deletingCodeQuestions
            }.map(\.id))
            guard !removedQuestionIDs.isEmpty else { continue }
            quiz.questions.removeAll { removedQuestionIDs.contains($0.id) }
            if quiz.questions.isEmpty {
                Inf6MetadataStore.delete(domain: .quiz, key: record.key)
                Inf6DrillAskNoteStore.deleteAll(paperKey: record.key)
            } else {
                Inf6MetadataStore.putCodable(quiz, domain: .quiz, key: record.key)
                Inf6DrillAskNoteStore.delete(paperKey: record.key, questionIDs: removedQuestionIDs)
            }
        }
        if !deletingCodeQuestions {
            _deleteTextbookGeneratedEntityEvidence(folderKey: folderKey)
        }
    }

    /// 解説項目かどうかを、置き場の名前から判定する。
    ///
    private static func _isTextbookFieldKey(_ folderKey: String) -> Bool {
        folderKey.contains("textbook")
    }

    private static func _deleteTextbookGeneratedEntityEvidence(folderKey: String) {
        guard _isTextbookFieldKey(folderKey) else { return }
        Inf6MetadataStore.delete(domain: .docEntities, key: folderKey)
        let imagesBase = Inf6LibraryView._entityImagesBaseURL()
        let entityDir = imagesBase.appendingPathComponent(String(folderKey.prefix(80)), isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(atPath: entityDir.path) {
            for file in files where file.hasPrefix("textbook_") {
                try? FileManager.default.removeItem(at: entityDir.appendingPathComponent(file))
            }
        }
    }

    private static func _plannedArtifactFileName(for paper: Inf6CorePaper) throws -> String {
        if isGeneratedExplanationProvider(paper.provider) {
            let stable = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paper.id)
            guard !stable.isEmpty else {
                throw NSError(
                    domain: "Inf6EshikakuDrillPipeline",
                    code: 230,
                    userInfo: [NSLocalizedDescriptionKey: "解説項目の保存キーを生成できません: \(paper.id)"]
                )
            }
            return "paper_\(stable).pdf"
        }
        return try Inf6PaperSaveShared.safeFileName(
            title: paper.title,
            fallbackID: paper.arxivId ?? paper.id
        )
    }

    static func deleteOriginRecord(sourceFamily: String, nodeID: String, paperID: String) {
        Inf6MetadataStore.delete(
            domain: .syllabusPaperLinks,
            key: "\(sourceFamily)|\(nodeID)|\(paperID)"
        )
        defer { Inf6KnowledgeDomainStructureStore.invalidateCache(sourceFamily: sourceFamily) }

        // paper メタデータが読めない(iCloud未ダウンロード等)場合でも、paperID 由来の
        // stablePaperIDKey だけは常に計算できるため、削除処理自体は必ず実行する。
        // 以前はここで paper が nil だと即 return し、クイズ/docEntities/KCフォルダが
        // 一切削除されないまま syllabus_paper_link だけ消える不具合があった。
        let paper = Inf6MetadataStore.getCodable(Inf6CorePaper.self, domain: .papers, key: paperID)
        let plannedFileName = paper.flatMap { try? _plannedArtifactFileName(for: $0) }
        let folderKey = plannedFileName.map { Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: $0) } ?? ""
        let titleKey = paper.map { Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: $0.title) } ?? ""
        let titleEnKey = paper.flatMap { $0.titleEn }.map { Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: $0) } ?? ""
        let aliases = _artifactLookupAliases(
            folderKey: folderKey, titleKey: titleKey, titleEnKey: titleEnKey, paperID: paperID
        )

        // 読み込み時(_findStoredArtifact)と同じエイリアス判定で該当レコードを"全て"削除する。
        // 単一の再計算キーだけを消すと、実際の保存キー(KCフォルダの実名やpaperKey/pdfKey由来の
        // 別名)と食い違って削除が黙って失敗し、再探索後に古いクイズが復活する不具合があった。
        var deletedFolderKeys = Set<String>()
        if !folderKey.isEmpty { deletedFolderKeys.insert(folderKey) }

        // _findStoredArtifact (読み込み時) は正規化キーの末尾一致(hasSuffix("_\(stablePaperIDKey)"))
        // も許容している。削除側が完全一致/包含のみだと、読み込み時には見つかるのに
        // 削除時には見つからないという非対称が再発するため、同じ判定を使う。
        func matchesAliases(_ storedRawKeys: [String]) -> Bool {
            let storedAliases = Set(storedRawKeys.filter { !$0.isEmpty })
            if !aliases.isDisjoint(with: storedAliases) { return true }
            let normalizedStored = storedRawKeys
                .map { Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: $0) }
                .filter { !$0.isEmpty }
            return aliases.contains { alias in
                normalizedStored.contains { $0 == alias || $0.hasSuffix("_\(alias)") }
            }
        }

        for record in Inf6MetadataStore.listAllCodable(Inf6PaperQuiz.self, domain: .quiz) {
            if matchesAliases([record.key, record.value.paperKey, record.value.paperTitle]) {
                Inf6MetadataStore.delete(domain: .quiz, key: record.key)
                // 設問が消える以上、その設問に紐づく Ask 記録も残さない。
                Inf6DrillAskNoteStore.deleteAll(paperKey: record.key)
            }
        }

        for record in Inf6MetadataStore.listAllCodable(Inf6DocEntityIndex.self, domain: .docEntities) {
            if matchesAliases([record.key, record.value.pdfKey]) {
                Inf6MetadataStore.delete(domain: .docEntities, key: record.key)
                deletedFolderKeys.insert(record.key)
            }
        }

        if let kcRoot = Inf6KnowledgeCardsPaths.rootDirectoryURL(),
           let actualFolders = try? FileManager.default.contentsOfDirectory(atPath: kcRoot.path) {
            for folder in actualFolders {
                let normalized = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: folder)
                guard deletedFolderKeys.contains(folder)
                    || aliases.contains(folder)
                    || aliases.contains(normalized)
                    || deletedFolderKeys.contains(normalized)
                else { continue }
                try? FileManager.default.removeItem(at: kcRoot.appendingPathComponent(folder))
            }
        }
    }

    static func resetOriginResolution(sourceFamily: String, nodeIDs: Set<String>) {
        let family = sourceFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        let targets = nodeIDs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !family.isEmpty, !targets.isEmpty else { return }

        for nodeID in targets {
            let prefix = "\(family)|\(nodeID)|"
            let links = Inf6MetadataStore.listByPrefix(
                domain: .syllabusPaperLinks,
                prefix: prefix
            ).compactMap { row -> Inf6SyllabusPaperLink? in
                guard let data = row.json.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(Inf6SyllabusPaperLink.self, from: data)
            }
            for link in links {
                deleteOriginRecord(sourceFamily: family, nodeID: nodeID, paperID: link.paperID)
            }
        }

        Inf6CorePaperStore.shared.reloadPapersFromMetadataStore()
        Inf6KnowledgeDomainStructureStore.invalidateCache(sourceFamily: family)
        NotificationCenter.default.post(name: .inf6SyllabusPaperLinksDidChange, object: nil)
    }

    static func exploreOriginHistory(
        item: OriginUnverifiedItem,
        sourceFamily: String,
        extraInstruction: String? = nil,
        askModel: @escaping (String) async throws -> String
    ) async throws -> OriginExplorationOutcome {
        let recordID = UUID().uuidString
        var record = _OriginExplorationRecord(
            id: recordID,
            sourceFamily: sourceFamily,
            nodeID: item.nodeID,
            title: item.titleJa.isEmpty ? item.titleEn : item.titleJa,
            startedAt: Date().timeIntervalSince1970,
            finishedAt: nil,
            status: "started",
            errorMessage: nil
        )
        try await _storeOriginExplorationRecord(record)
        NSLog("[DrillPipeline] origin exploration started id=%@ family=%@ node=%@", recordID, sourceFamily, item.nodeID)

        do {
            let outcome = try await _exploreOriginHistory(
                item: item,
                sourceFamily: sourceFamily,
                extraInstruction: extraInstruction,
                askModel: askModel
            )
            record.finishedAt = Date().timeIntervalSince1970
            record.status = "succeeded"
            try await _storeOriginExplorationRecord(record)
            NSLog("[DrillPipeline] origin exploration succeeded id=%@ family=%@ node=%@", recordID, sourceFamily, item.nodeID)
            return outcome
        } catch {
            record.finishedAt = Date().timeIntervalSince1970
            record.status = Task.isCancelled || error is CancellationError ? "cancelled" : "failed"
            record.errorMessage = error.localizedDescription
            try? await _storeOriginExplorationRecord(record)
            NSLog("[DrillPipeline] origin exploration failed id=%@ family=%@ node=%@ error=%@", recordID, sourceFamily, item.nodeID, error.localizedDescription)
            throw error
        }
    }

    private static func _exploreOriginHistory(
        item: OriginUnverifiedItem,
        sourceFamily: String,
        extraInstruction: String? = nil,
        askModel: @escaping (String) async throws -> String
    ) async throws -> OriginExplorationOutcome {
        let structure = try _loadKnowledgeStructureOrThrow(sourceFamily: sourceFamily)
        guard let node = structure.nodes.first(where: { $0.nodeID == item.nodeID }) else {
            throw _originResolutionError(
                item: item,
                cause: "正本 syllabus metadata に対象ノードが存在しません: node=\(item.nodeID)",
                plan: ["syllabus metadata を再取得する", "対象ノードIDを検証する", "同じ操作を再実行する"]
            )
        }

        // Step 1: LLM自身の知識でこの概念の起源論文を名指しさせる。検索ではなく主張。
        let claim = try await _claimOriginPaper(node: node, extraInstruction: extraInstruction, askModel: askModel)

        var verifiedPaperIDs: [String] = []
        let hasPersistableHistory = !claim.originHistory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !claim.originPeriod.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && claim.chronology.count >= 2
        let discovered = hasPersistableHistory
            ? try await _discoverOriginPapers(node: node, claim: claim)
            : []
        for verified in discovered {
            guard _verifiedPaperMatchesClaimedPeriod(verified, originPeriod: claim.originPeriod) else {
                NSLog("[DrillPipeline] origin candidate rejected by claimed period node=%@ paper=%@ year=%@ period=%@",
                      item.nodeID, verified.id, verified.year.map(String.init) ?? "nil", claim.originPeriod)
                continue
            }
            guard _verifiedPaperMatchesNodeConcept(verified, node: node) else {
                NSLog("[DrillPipeline] origin candidate rejected by node concept node=%@ paper=%@ title=%@", item.nodeID, verified.id, verified.title)
                continue
            }
            let paperID = try await _persistVerifiedOriginPaper(
                verified: verified,
                item: item,
                sourceFamily: sourceFamily,
                node: node,
                claim: claim
            )
            verifiedPaperIDs.append(paperID)
        }

        switch claim.fieldKind {
        case .paperOrigin:
            let claimedPapers = claim.selectedPapers.filter {
                !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard !claimedPapers.isEmpty else {
                throw _originResolutionError(
                    item: item,
                    cause: "paper_origin と判定されましたが論文タイトルが空です。",
                    plan: ["起源論文名を再提示させる"]
                )
            }
            guard !claim.originHistory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw _originResolutionError(
                    item: item,
                    cause: "origin_history が空です。",
                    plan: ["概念史を再生成する"]
                )
            }

            // Step 2: 主張された個々の論文が実在するかを決定論的に検証する(検索ではなく確認)。単一である必要はない。
            for claimedPaper in claimedPapers {
                let title = claimedPaper.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let verified = try await _verifyClaimedPaper(title: title, titleEn: claimedPaper.titleEn) else {
                    NSLog("[DrillPipeline] _verifyClaimedPaper node=%@ title=\"%@\" -> NOT FOUND", item.nodeID, title)
                    continue
                }
                NSLog("[DrillPipeline] _verifyClaimedPaper node=%@ title=\"%@\" -> FOUND id=%@ verified_title=\"%@\"",
                      item.nodeID, title, verified.id, verified.title)
                guard _verifiedPaperMatchesClaimedPeriod(verified, originPeriod: claim.originPeriod) else {
                    NSLog("[DrillPipeline] claimed origin rejected by claimed period node=%@ paper=%@ year=%@ period=%@",
                          item.nodeID, verified.id, verified.year.map(String.init) ?? "nil", claim.originPeriod)
                    continue
                }
                guard _verifiedPaperMatchesNodeConcept(verified, node: node) else {
                    NSLog("[DrillPipeline] claimed origin rejected by node concept node=%@ paper=%@ title=%@", item.nodeID, verified.id, verified.title)
                    continue
                }
                let citationAncestors = try await _traceCitationAncestors(node: node, paper: verified)
                guard !citationAncestors.isEmpty else {
                    NSLog("[DrillPipeline] claimed origin rejected without citation ancestor node=%@ paper=%@", item.nodeID, verified.id)
                    continue
                }
                NSLog("[DrillPipeline] claimed origin citation trail node=%@ paper=%@ ancestors=%d", item.nodeID, verified.id, citationAncestors.count)
                let paperID = try await _persistVerifiedOriginPaper(
                    verified: verified,
                    item: item,
                    sourceFamily: sourceFamily,
                    node: node,
                    claim: claim
                )
                if !verifiedPaperIDs.contains(paperID) { verifiedPaperIDs.append(paperID) }
            }
            guard !verifiedPaperIDs.isEmpty else {
                let reason = "許可Provider内で起源論文を検証できなかったため、起源論文なしとしてオリジナル解説を生成します。"
                NSLog("[DrillPipeline] paper origin unresolved; generating original explanation node=%@", item.nodeID)
                return try await _persistTextbookField(
                    item: item,
                    sourceFamily: sourceFamily,
                    node: node,
                    claim: claim,
                    reasonOverride: reason
                )
            }
            Inf6KnowledgeDomainStructureStore.invalidateCache(sourceFamily: sourceFamily)
            return OriginExplorationOutcome(kind: "paper_origin", selectedPaperID: verifiedPaperIDs.first)

        case .textbookField:
            if !verifiedPaperIDs.isEmpty {
                Inf6KnowledgeDomainStructureStore.invalidateCache(sourceFamily: sourceFamily)
                return OriginExplorationOutcome(kind: "paper_origin", selectedPaperID: verifiedPaperIDs.first)
            }
            return try await _persistTextbookField(
                item: item,
                sourceFamily: sourceFamily,
                node: node,
                claim: claim,
                reasonOverride: nil
            )
        }
    }

    private static func _persistTextbookField(
        item: OriginUnverifiedItem,
        sourceFamily: String,
        node: Inf6KnowledgeNode,
        claim: _OriginClaim,
        reasonOverride: String?
    ) async throws -> OriginExplorationOutcome {
        let reason = (reasonOverride ?? claim.unableReason)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let history = !claim.originHistory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? claim.originHistory.trimmingCharacters(in: .whitespacesAndNewlines)
            : (reason ?? "")
        let verificationEvidence = reason ?? history
        guard !history.isEmpty else {
            throw _originResolutionError(
                item: item,
                cause: "textbook_field と判定されましたが、理由(origin_history/unable_reason)が空です。",
                plan: ["単一論文を提示できない理由を明示させる"]
            )
        }
        let syntheticPaperID = _canonicalExplanationPaperID(sourceFamily: sourceFamily, nodeID: item.nodeID)
        let legacyTextbookPaperID = "textbook:\(sourceFamily):\(item.nodeID)"
        var tags = ["explanation_item", sourceFamily]
        if claim.requiresPythonCode { tags.append("requires_python_code") }
        let syntheticPaper = Inf6CorePaper(
            id: syntheticPaperID,
            title: node.titleJa.isEmpty ? node.titleEn : node.titleJa,
            titleEn: node.titleEn,
            provider: "generated_explanation",
            arxivId: nil,
            pdfURL: nil,
            year: nil,
            tags: tags
        )
        try await _withMetadataWrite {
            // 旧分類の合成レコードは、オリジナル解説リーフと同一ノードに
            // 二重表示されるため、正規IDへ保存する前に削除する。
            Inf6MetadataStore.delete(
                domain: .syllabusPaperLinks,
                key: "\(sourceFamily)|\(item.nodeID)|\(legacyTextbookPaperID)"
            )
            Inf6MetadataStore.delete(domain: .papers, key: legacyTextbookPaperID)
            guard Inf6MetadataStore.putCodable(syntheticPaper, domain: .papers, key: syntheticPaperID) else {
                throw NSError(domain: "Inf6OriginResolution", code: 34, userInfo: [
                    NSLocalizedDescriptionKey: "合成説明論文metadataを保存できませんでした: \(syntheticPaperID)"
                ])
            }
        }
        let link = Inf6SyllabusPaperLink(
            sourceFamily: sourceFamily,
            syllabusNodeID: item.nodeID,
            paperID: syntheticPaperID,
            providerID: "generated_explanation",
            query: "\(node.titleJa) \(node.titleEn)",
            score: 0,
            searchedAt: Date(),
            origin: "explanation_item",
            originHistory: history,
            sourceRole: "explanation_item",
            originPeriod: claim.originPeriod,
            originChronology: claim.chronology,
            verificationStatus: "explanation_generated",
            verificationEvidence: verificationEvidence,
            originRecordVersion: 1
        )
        try await _withMetadataWrite {
            guard Inf6MetadataStore.putCodable(
                link,
                domain: .syllabusPaperLinks,
                key: "\(sourceFamily)|\(item.nodeID)|\(syntheticPaperID)"
            ) else {
                throw NSError(domain: "Inf6OriginResolution", code: 35, userInfo: [
                    NSLocalizedDescriptionKey: "合成説明論文リンクを保存できませんでした: \(item.nodeID)"
                ])
            }
        }
        Inf6KnowledgeDomainStructureStore.invalidateCache(sourceFamily: sourceFamily)
        return OriginExplorationOutcome(kind: "textbook_field", selectedPaperID: syntheticPaperID)
    }

    private enum _OriginFieldKind: String, Decodable {
        case paperOrigin = "paper_origin"
        case textbookField = "textbook_field"
    }

    private struct _ClaimedPaperRef: Decodable {
        let title: String
        let titleEn: String?

        enum CodingKeys: String, CodingKey {
            case title
            case titleEn = "title_en"
        }
    }

    private struct _OriginClaim: Decodable {
        let fieldKind: _OriginFieldKind
        let requiresPythonCode: Bool
        let selectedPapers: [_ClaimedPaperRef]
        let searchQueries: [String]
        let citationAnchors: [String]
        let originHistory: String
        let originPeriod: String
        let chronology: [String]
        let unableReason: String?

        enum CodingKeys: String, CodingKey {
            case fieldKind = "field_kind"
            case requiresPythonCode = "requires_python_code"
            case selectedPapers = "selected_papers"
            case searchQueries = "search_queries"
            case citationAnchors = "citation_anchors"
            case originHistory = "origin_history"
            case originPeriod = "origin_period"
            case chronology
            case unableReason = "unable_reason"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fieldKind = try c.decode(_OriginFieldKind.self, forKey: .fieldKind)
            requiresPythonCode = try c.decodeIfPresent(Bool.self, forKey: .requiresPythonCode) ?? false
            selectedPapers = try c.decodeIfPresent([_ClaimedPaperRef].self, forKey: .selectedPapers) ?? []
            searchQueries = try c.decodeIfPresent([String].self, forKey: .searchQueries) ?? []
            citationAnchors = try c.decodeIfPresent([String].self, forKey: .citationAnchors) ?? []
            originHistory = try c.decodeIfPresent(String.self, forKey: .originHistory) ?? ""
            originPeriod = try c.decodeIfPresent(String.self, forKey: .originPeriod) ?? ""
            chronology = try c.decodeIfPresent([String].self, forKey: .chronology) ?? []
            unableReason = try c.decodeIfPresent(String.self, forKey: .unableReason)
        }
    }

    private static func _claimOriginPaper(
        node: Inf6KnowledgeNode,
        extraInstruction: String?,
        askModel: @escaping (String) async throws -> String
    ) async throws -> _OriginClaim {
        let trimmedExtra = (extraInstruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let extraBlock = trimmedExtra.isEmpty ? "" : """


        追加指示(ユーザーからの補足。最優先で従うこと):
        \(trimmedExtra)
        """
        let prompt = """
        あなたはE資格(JDLA主催、ディープラーニングエンジニア資格試験)の演習問題を作成するために、シラバス概念の起源を特定する専門家です。E資格は、ディープラーニングの理論を理解し適切な手法を選択・実装する能力を認定する知識試験(多肢選択式)で、これから出す演習問題の根拠として使います。

        以下の概念について、まず field_kind を仮判定してください。これは保存判定ではありません。保存判定は、この後の決定論的な provider 検索と引用アンカー検証だけで行います。

        - textbook_field: 講義で体系化された確立知識として問われる概念。ただし、この場合でも search_queries と citation_anchors は必ず出してください。後続の決定論探索を止めてはいけません。
        - paper_origin: 特定の論文が手法そのものを定義しており、E資格がその論文の提案内容(アーキテクチャ、アルゴリズム、実験結果)を問う概念。深層学習の個別手法(Transformer, ResNet, Adam, Dropout, BatchNorm など)が該当します。

        paper_origin と判定した場合は、その起点となる論文を、Web search で論文名候補として確認してから名指ししてください。単一である必要はありません。複数の論文が共同で、あるいは並行して起源を形成している場合は、それらすべてを selected_papers に列挙してください。

        textbook_field と判定した場合は selected_papers を空配列にしてよいですが、search_queries には概念名、別名、歴史的な先行名、代表的な引用元を探すための語を3〜8件入れてください。citation_anchors には引用を遡る手掛かりになる著者名・先行概念名・代表用語を入れてください。

        制約:
        - 実在しない論文・URL・DOIを創作してはいけません。
        - Web search で見つけた URL は採用 URL ではありません。URL、DOI、arXiv ID、PMID は出力しないでください。後段の決定論工程だけが family manifest の Provider / Content Provider で実測します。
        - 後年の応用論文・レビュー論文だけで終えてはいけません。そこから引用を遡るための search_queries / citation_anchors を必ず出してください。
        - 年代・時代を必ず示してください。
        - requires_python_code は、この概念の演習問題にPython/PyTorch/TensorFlowの実装コードを含めるのが自然かどうかを判定してください。
        - JSON オブジェクトだけを返してください。
        \(extraBlock)

        JSON schema:
        {
          "field_kind": "paper_origin | textbook_field",
          "requires_python_code": true または false,
          "selected_papers": [{"title": "実在する論文の正式タイトル", "title_en": "英語タイトル"}],
          "search_queries": ["provider 検索に使う論文名または概念史の検索語"],
          "citation_anchors": ["引用を遡るための著者名・先行概念名・代表用語"],
          "origin_history": "概念史の理解。URLは書かない。",
          "origin_period": "概念の成立時代または代表的起点年代。例: ancient_greece, 17th_century, 1950s, 2017",
          "chronology": ["年代または時代: 何が成立したか", "後続年代: どう体系化されたか"],
          "unable_reason": "textbook_field の場合だけ、単一論文を提示できない理由"
        }

        node_id: \(node.nodeID)
        title_ja: \(node.titleJa)
        title_en: \(node.titleEn)
        """
        let raw = try await _askModelWithLedger(
            prompt: prompt,
            targetID: node.nodeID,
            featureName: "eshikaku_origin_claim_web_search",
            askModel: askModel
        )
        NSLog("[DrillPipeline] _claimOriginPaper node=%@ raw_response=%@", node.nodeID, raw)
        guard let json = _extractJSONObject(from: raw) else {
            throw NSError(domain: "Inf6EshikakuDrillPipeline", code: 210, userInfo: [
                NSLocalizedDescriptionKey: "起源主張の出力がJSONオブジェクトではありません。"
            ])
        }
        let claim = try JSONDecoder().decode(_OriginClaim.self, from: Data(json.utf8))
        let titleList = claim.selectedPapers.map { $0.title }.joined(separator: " / ")
        NSLog("[DrillPipeline] _claimOriginPaper node=%@ field_kind=%@ papers=[%@] requires_python=%d unable_reason=%@",
              node.nodeID, claim.fieldKind.rawValue, titleList,
              claim.requiresPythonCode ? 1 : 0, claim.unableReason ?? "-")
        return claim
    }

    private struct _VerifiedPaper {
        let id: String
        let title: String
        let titleEn: String?
        let provider: String
        let arxivId: String?
        let pdfURL: String?
        let year: Int?
        let evidence: String
        /// 照会先から返された原文の Abstract。論文概要としてそのまま使う。
        let abstract: String
    }

    private static func _verifiedPaperMatchesClaimedPeriod(
        _ paper: _VerifiedPaper,
        originPeriod: String
    ) -> Bool {
        let period = originPeriod.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let year = paper.year else { return false }
        let centuryPattern = #"\b([0-9]{1,2})(st|nd|rd|th)[ _-]?century\b"#
        if let match = period.range(of: centuryPattern, options: .regularExpression) {
            let centuryText = period[match]
                .replacingOccurrences(of: #"[^0-9]"#, with: "", options: .regularExpression)
            if let century = Int(centuryText) {
                return year <= century * 100
            }
        }
        let decadePattern = #"\b([0-9]{4})s\b"#
        if let match = period.range(of: decadePattern, options: .regularExpression) {
            let decadeText = period[match].dropLast()
            if let decade = Int(decadeText) {
                return year <= decade + 9
            }
        }
        if let exactYear = Int(period), (1000...2999).contains(exactYear) {
            return year <= exactYear
        }
        return true
    }

    /// 書誌の存在確認だけでは、同名・無関係な論文を概念の起源として保存できてしまう。
    /// 正本ノードの英語タイトルまたは日本語タイトルに含まれる意味のある語が、
    /// 論文タイトルまたはAbstractに存在することを、保存前の必要条件とする。
    private static func _verifiedPaperMatchesNodeConcept(
        _ paper: _VerifiedPaper,
        node: Inf6KnowledgeNode
    ) -> Bool {
        let titleEn = paper.titleEn ?? ""
        let haystack = _normalizedTitleForMatching("\(paper.title) \(titleEn) \(paper.abstract)")
        guard !haystack.isEmpty else { return false }

        let stopWords: Set<String> = [
            "and", "or", "the", "for", "with", "from", "into", "using",
            "method", "methods", "model", "models", "learning", "network", "networks",
            "algorithm", "algorithms", "basic", "fundamental", "fundamentals",
            "deep", "neural", "based", "approach", "approaches"
        ]
        let sources = [node.titleEn, node.titleJa]
        for source in sources {
            let normalized = _normalizedTitleForMatching(source)
            guard !normalized.isEmpty else { continue }
            if normalized.count >= 5, haystack.contains(normalized) {
                return true
            }
            let tokens = normalized.split(separator: " ").map(String.init)
            if tokens.contains(where: { token in
                token.count >= 5 && !stopWords.contains(token) && haystack.contains(token)
            }) {
                return true
            }
        }
        return false
    }

    /// Webで関連論文を見つけ、その参考文献を2段階たどる。
    /// 直接タイトルが一致しただけの論文は、引用元を確認できるまで起源として保存しない。
    private static func _traceCitationAncestors(
        node: Inf6KnowledgeNode,
        paper: _VerifiedPaper
    ) async throws -> [_VerifiedPaper] {
        let related = try await Inf6OpenAlexClient.search(
            query: node.titleEn.isEmpty ? node.titleJa : node.titleEn,
            maxResults: 5
        )
        let relatedIDs = Set(related.map(\.id))
        var frontier = related
        var visited = relatedIDs
        var ancestors: [Inf6PaperSearchResult] = []

        for depth in 1...2 {
            var next: [Inf6PaperSearchResult] = []
            for work in frontier {
                let references = try await Inf6OpenAlexClient.references(workID: work.id, maxResults: 50)
                ancestors.append(contentsOf: references)
                for reference in references where visited.insert(reference.id).inserted {
                    next.append(reference)
                }
            }
            NSLog("[DrillPipeline] citation traversal paper=%@ depth=%d works=%d", paper.id, depth, next.count)
            frontier = next
            if frontier.isEmpty { break }
        }

        let currentYear = paper.year ?? Int.max
        return ancestors
            .filter { result in
                let candidate = _VerifiedPaper(
                    id: result.id,
                    title: result.title,
                    titleEn: result.title,
                    provider: "openalex",
                    arxivId: nil,
                    pdfURL: result.pdfURL?.absoluteString,
                    year: result.publishedAt.map { Calendar(identifier: .gregorian).component(.year, from: $0) },
                    evidence: "OpenAlex citation traversal",
                    abstract: result.abstractText
                )
                let year = candidate.year ?? Int.max
                return year <= currentYear && _verifiedPaperMatchesNodeConcept(candidate, node: node)
            }
            .sorted {
                ($0.publishedAt ?? .distantFuture) < ($1.publishedAt ?? .distantFuture)
            }
            .map { result in
                _VerifiedPaper(
                    id: result.id,
                    title: result.title,
                    titleEn: result.title,
                    provider: "openalex",
                    arxivId: nil,
                    pdfURL: result.pdfURL?.absoluteString,
                    year: result.publishedAt.map { Calendar(identifier: .gregorian).component(.year, from: $0) },
                    evidence: "OpenAlex citation traversal: related work and two-level references",
                    abstract: result.abstractText
                )
            }
    }

    private static func _persistVerifiedOriginPaper(
        verified: _VerifiedPaper,
        item: OriginUnverifiedItem,
        sourceFamily: String,
        node: Inf6KnowledgeNode,
        claim: _OriginClaim
    ) async throws -> String {
        var tags = ["origin_verified", sourceFamily]
        if claim.requiresPythonCode { tags.append("requires_python_code") }
        let paper = Inf6CorePaper(
            id: verified.id,
            title: verified.title,
            titleEn: verified.titleEn,
            provider: verified.provider,
            arxivId: verified.arxivId,
            pdfURL: verified.pdfURL,
            year: verified.year,
            tags: tags,
            abstract: verified.abstract.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        // 書誌情報だけでは本文根拠を確認できない。起源として保存する前に
        // 許可ソースからPDFを取得し、PDFKitと書誌同一性まで検証する。
        let localPDF = try await _persistVerifiedOriginPDF(
            paper: paper,
            downloadURL: verified.pdfURL.flatMap(URL.init(string:)),
            sourceFamily: sourceFamily,
            node: node
        )
        let pdfEvidence = "; PDF saved and verified: \(localPDF.lastPathComponent)"
        try await _withMetadataWrite {
            guard Inf6MetadataStore.putCodable(paper, domain: .papers, key: paper.id) else {
                throw _originResolutionError(
                    item: item,
                    cause: "検証済み起源論文のmetadata保存に失敗しました: paper=\(paper.id)",
                    plan: ["User Setting Rootの書込権限を確認する", "論文metadataを再保存する"]
                )
            }
        }
        let link = Inf6SyllabusPaperLink(
            sourceFamily: sourceFamily,
            syllabusNodeID: item.nodeID,
            paperID: paper.id,
            providerID: paper.provider,
            query: "\(node.titleJa) \(node.titleEn)",
            score: 0,
            searchedAt: Date(),
            origin: "paper_origin",
            originHistory: claim.originHistory,
            sourceRole: "origin",
            originPeriod: claim.originPeriod,
            originChronology: claim.chronology,
            verificationStatus: "source_verified",
            verificationEvidence: "\(verified.evidence)\(pdfEvidence)",
            originRecordVersion: 1
        )
        try await _withMetadataWrite {
            guard Inf6MetadataStore.putCodable(
                link,
                domain: .syllabusPaperLinks,
                key: "\(sourceFamily)|\(item.nodeID)|\(paper.id)"
            ) else {
                throw _originResolutionError(
                    item: item,
                    cause: "検証済み起源論文の検証リンク保存に失敗しました: paper=\(paper.id)",
                    plan: ["User Setting Rootの書込権限を確認する", "検証リンクを再保存する"]
                )
            }
        }
        try await _persistSupplementaryExplanationItem(
            item: item,
            sourceFamily: sourceFamily,
            node: node,
            claim: claim
        )
        return paper.id
    }

    private static func _persistSupplementaryExplanationItem(
        item: OriginUnverifiedItem,
        sourceFamily: String,
        node: Inf6KnowledgeNode,
        claim: _OriginClaim
    ) async throws {
        let paperID = _canonicalExplanationPaperID(sourceFamily: sourceFamily, nodeID: item.nodeID)
        let paper = Inf6CorePaper(
            id: paperID,
            title: node.titleJa.isEmpty ? node.titleEn : node.titleJa,
            titleEn: node.titleEn,
            provider: "generated_explanation",
            arxivId: nil,
            pdfURL: nil,
            year: nil,
            tags: ["explanation_item", sourceFamily]
        )
        let link = Inf6SyllabusPaperLink(
            sourceFamily: sourceFamily,
            syllabusNodeID: item.nodeID,
            paperID: paperID,
            providerID: "generated_explanation",
            query: "\(node.titleJa) \(node.titleEn)",
            score: 0,
            searchedAt: Date(),
            origin: "explanation_item",
            originHistory: claim.originHistory,
            sourceRole: "explanation_item",
            originPeriod: claim.originPeriod,
            originChronology: claim.chronology,
            verificationStatus: "explanation_generated",
            verificationEvidence: "概念ノードとPDF検証済み起源論文を基に生成する解説・演習項目。",
            originRecordVersion: 1
        )
        try await _withMetadataWrite {
            guard Inf6MetadataStore.putCodable(paper, domain: .papers, key: paperID) else {
                throw NSError(domain: "Inf6OriginResolution", code: 31, userInfo: [
                    NSLocalizedDescriptionKey: "補足説明論文metadataを保存できませんでした: \(paperID)"
                ])
            }
            guard Inf6MetadataStore.putCodable(
                link,
                domain: .syllabusPaperLinks,
                key: "\(sourceFamily)|\(item.nodeID)|\(paperID)"
            ) else {
                throw NSError(domain: "Inf6OriginResolution", code: 32, userInfo: [
                    NSLocalizedDescriptionKey: "補足説明の検証リンクを保存できませんでした: \(paperID)"
                ])
            }
        }
    }

    /// 論文名で直接照会する。採用先は source 設定内の arXiv に限定する。
    /// Web検索は arXiv ID の特定だけに使い、Web検索結果URLは採用しない。
    /// 照合用にタイトルを正規化する。大小文字、約物、空白の違いは同一視する。
    private static func _normalizedTitleForMatching(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let kept = lowered.map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : " "
        }
        return String(kept)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// 照会結果が、主張された論文そのものかを判定する。
    ///
    /// arXiv の ti:"..." は曖昧一致であり、
    /// 「Random Forests」で「Neural Random Forests」が先頭ヒットする。
    /// 前に語が付くものは別論文なので、前方一致だけを採用する。
    /// 後ろに付く「(With discussion...)」や末尾の句点は同一論文の表記揺れなので許す。
    private static func _verifiedTitleMatchesClaim(claimed: String, verified: String) -> Bool {
        let c = _normalizedTitleForMatching(claimed)
        let v = _normalizedTitleForMatching(verified)
        guard !c.isEmpty, !v.isEmpty else { return false }
        if v == c { return true }
        return v.hasPrefix(c + " ")
    }

    private static func _originSearchTerms(node: Inf6KnowledgeNode, claim: _OriginClaim) -> [String] {
        var terms: [String] = []
        func add(_ raw: String) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            if !terms.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
                terms.append(value)
            }
        }
        add(node.titleEn)
        add(node.titleJa)
        for query in claim.searchQueries { add(query) }
        let tokenStop: Set<String> = [
            "and", "or", "the", "for", "with", "from", "into", "using",
            "method", "methods", "model", "models", "learning", "network", "networks",
            "algorithm", "algorithms", "basic", "fundamental", "fundamentals"
        ]
        for source in [node.titleEn, node.titleJa] + claim.searchQueries {
            let normalized = _normalizedTitleForMatching(source)
            for token in normalized.split(separator: " ") {
                let t = String(token)
                guard t.count >= 5, !tokenStop.contains(t) else { continue }
                add(t)
            }
        }
        return terms
    }

    private static func _originCitationAnchors(claim: _OriginClaim) -> [String] {
        var anchors: [String] = []
        func add(_ raw: String) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count >= 3 else { return }
            if !anchors.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
                anchors.append(value)
            }
        }
        for anchor in claim.citationAnchors { add(anchor) }
        for source in [claim.originHistory] + claim.chronology {
            let ns = source as NSString
            guard let regex = try? NSRegularExpression(pattern: #"[A-Z][A-Za-z][A-Za-z\-']{2,}"#) else {
                continue
            }
            let range = NSRange(location: 0, length: ns.length)
            for match in regex.matches(in: source, range: range) {
                add(ns.substring(with: match.range))
            }
        }
        return anchors
    }

    private static func _candidateScore(
        result: Inf6PaperSearchResult,
        provider: String,
        terms: [String],
        anchors: [String]
    ) -> Int {
        let haystack = _normalizedTitleForMatching("\(result.title) \(result.subtitle)")
        var score = 0
        for term in terms {
            let t = _normalizedTitleForMatching(term)
            if !t.isEmpty, haystack.contains(t) { score += 8 }
        }
        for anchor in anchors {
            let a = _normalizedTitleForMatching(anchor)
            if !a.isEmpty, haystack.contains(a) { score += 15 }
        }
        if provider == "pubmed" { score += 2 }
        if let year = result.publishedAt.map({ Calendar(identifier: .gregorian).component(.year, from: $0) }) {
            if year < 1970 { score += 10 }
            else if year < 1990 { score += 6 }
            else if year < 2010 { score += 2 }
        }
        return score
    }

    private static func _discoverOriginPapers(
        node: Inf6KnowledgeNode,
        claim: _OriginClaim
    ) async throws -> [_VerifiedPaper] {
        let terms = _originSearchTerms(node: node, claim: claim)
        let anchors = _originCitationAnchors(claim: claim)
        guard !terms.isEmpty else { return [] }

        let pubmedQueries = terms.prefix(3).map { "\"\($0)\"[Title]" }

        var candidateSeeds: [(Inf6PaperSearchResult, String, Int)] = []
        var providerFailures: [String] = []
        var providerSuccesses = 0
        for query in pubmedQueries {
            do {
                let hits = try await Inf6PubMedClient.search(term: query, maxResults: 10)
                providerSuccesses += 1
                NSLog("[DrillPipeline] origin PubMed search query=%@ hits=%d", query, hits.count)
                for hit in hits {
                    let score = _candidateScore(result: hit, provider: "pubmed", terms: terms, anchors: anchors)
                    guard score >= 10 else { continue }
                    candidateSeeds.append((hit, "pubmed", score))
                }
            } catch {
                let failure = "PubMed検索 query=\(query): \(error.localizedDescription)"
                providerFailures.append(failure)
                NSLog("[DrillPipeline] origin %@", failure)
            }
        }
        guard providerSuccesses > 0 else {
            throw NSError(
                domain: "Inf6EshikakuDrillPipeline",
                code: 218,
                userInfo: [NSLocalizedDescriptionKey: "許可Providerの検索がすべて失敗しました。\(providerFailures.joined(separator: " / "))"]
            )
        }

        var candidates: [(Inf6PaperSearchResult, String, Int, String)] = []
        for seed in candidateSeeds.sorted(by: { $0.2 > $1.2 }).prefix(3) where seed.1 == "pubmed" {
            let seedPMID = seed.0.id
            let refPMIDs: [String]
            let citedByPMIDs: [String]
            do {
                refPMIDs = try await Inf6PubMedClient.referencePMIDs(pmid: seedPMID)
                citedByPMIDs = try await Inf6PubMedClient.citedByPMIDs(pmid: seedPMID)
                NSLog("[DrillPipeline] origin PubMed relations seed=%@ references=%d cited_by=%d", seedPMID, refPMIDs.count, citedByPMIDs.count)
            } catch {
                let failure = "PubMed引用照会 seed=\(seedPMID): \(error.localizedDescription)"
                providerFailures.append(failure)
                NSLog("[DrillPipeline] origin %@", failure)
                continue
            }
            let linkedPMIDs = Array((refPMIDs + citedByPMIDs).prefix(40))
            guard !linkedPMIDs.isEmpty else { continue }
            let linkedPapers: [Inf6PaperSearchResult]
            do {
                linkedPapers = try await Inf6PubMedClient.fetch(pmids: linkedPMIDs)
            } catch {
                let failure = "PubMed引用本文照会 seed=\(seedPMID): \(error.localizedDescription)"
                providerFailures.append(failure)
                NSLog("[DrillPipeline] origin %@", failure)
                continue
            }
            for linked in linkedPapers {
                let score = _candidateScore(result: linked, provider: "pubmed", terms: terms, anchors: anchors)
                guard score >= 10 else { continue }
                let relation = refPMIDs.contains(linked.id) ? "references" : "cited_by"
                candidates.append((linked, "pubmed", score + 20, "PubMed \(relation) traversal: seed=\(seedPMID) linked=\(linked.id)"))
            }
        }

        let unique = candidates.reduce(into: [(Inf6PaperSearchResult, String, Int, String)]()) { result, item in
            let id = item.1 == "pubmed" ? "pubmed:\(item.0.id)" : item.0.id
            if !result.contains(where: { ($0.1 == "pubmed" ? "pubmed:\($0.0.id)" : $0.0.id) == id }) {
                result.append(item)
            }
        }
        let sorted = unique.sorted {
            if $0.2 != $1.2 { return $0.2 > $1.2 }
            let y0 = $0.0.publishedAt.map { Calendar(identifier: .gregorian).component(.year, from: $0) } ?? Int.max
            let y1 = $1.0.publishedAt.map { Calendar(identifier: .gregorian).component(.year, from: $0) } ?? Int.max
            return y0 < y1
        }

        return sorted.prefix(3).map { hit, provider, _, traversalEvidence in
            let year = hit.publishedAt.map { Calendar(identifier: .gregorian).component(.year, from: $0) }
            if provider == "pubmed" {
                return _VerifiedPaper(
                    id: "pubmed:\(hit.id)",
                    title: hit.title,
                    titleEn: hit.title,
                    provider: "pubmed",
                    arxivId: nil,
                    pdfURL: nil,
                    year: year,
                    evidence: "\(traversalEvidence); pmid=\(hit.id) title=\(hit.title)",
                    abstract: hit.abstractText
                )
            }
            return _VerifiedPaper(
                id: hit.id,
                title: hit.title,
                titleEn: hit.title,
                provider: "arxiv",
                arxivId: hit.id,
                pdfURL: hit.pdfURL?.absoluteString,
                year: year,
                evidence: "arXiv provider record verified after Web title discovery: id=\(hit.id) title=\(hit.title)",
                abstract: hit.abstractText
            )
        }
    }

    private static func _verifyClaimedPaper(title: String, titleEn: String?) async throws -> _VerifiedPaper? {
        let queryTitle = (titleEn?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? title
        let claimedTitles = [queryTitle, title]
        let matchesClaim: (String) -> Bool = { candidate in
            claimedTitles.contains { _verifiedTitleMatchesClaim(claimed: $0, verified: candidate) }
        }

        if let arxivID = try? await _findArxivIDByWebSearch(title: title, titleEn: titleEn),
           let hits = try? await Inf6ArxivClient.searchByID(arxivID: arxivID),
           let match = hits.first, matchesClaim(match.title) {
            NSLog("[DrillPipeline] _verifyClaimedPaper web_search found arxiv_id=%@ for title=\"%@\"", arxivID, title)
            return _VerifiedPaper(
                id: match.id,
                title: match.title,
                titleEn: match.title,
                provider: "arxiv",
                arxivId: match.id,
                pdfURL: match.pdfURL?.absoluteString,
                year: match.publishedAt.map { Calendar(identifier: .gregorian).component(.year, from: $0) },
                evidence: "Web検索で特定したarXiv ID(\(arxivID))を直接照会して実在確認: id=\(match.id) title=\(match.title)",
                abstract: match.abstractText
            )
        }
        let arxivQuery = "ti:\"\(queryTitle)\""
        if let hits = try? await Inf6ArxivClient.search(query: arxivQuery, maxResults: 5),
           let match = hits.first(where: { matchesClaim($0.title) }) {
            return _VerifiedPaper(
                id: match.id,
                title: match.title,
                titleEn: match.title,
                provider: "arxiv",
                arxivId: match.id,
                pdfURL: match.pdfURL?.absoluteString,
                year: match.publishedAt.map { Calendar(identifier: .gregorian).component(.year, from: $0) },
                evidence: "Web検索で論文名候補を確認後、arXivを直接照会して実在確認: id=\(match.id) title=\(match.title)",
                abstract: match.abstractText
            )
        }
        return nil
    }

    static func ensureLocalPDFForOpening(entry: DrillEntry) async throws -> URL {
        try await _localPDFURL(for: entry).url
    }

    private static func _persistVerifiedOriginPDF(
        paper: Inf6CorePaper,
        downloadURL: URL?,
        sourceFamily: String,
        node: Inf6KnowledgeNode
    ) async throws -> URL {
        let title = node.titleJa.isEmpty ? node.titleEn : node.titleJa
        let entry = DrillEntry(
            id: "\(node.nodeID)|\(paper.id)",
            paper: paper,
            folderKey: Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(
                from: try Inf6PaperSaveShared.safeFileName(
                    title: paper.title,
                    fallbackID: paper.arxivId ?? paper.id
                )
            ),
            domainPrefix: sourceFamily,
            domainLabelJa: sourceFamily,
            domainLabelEn: sourceFamily,
            quiz: nil,
            pdfURL: nil,
            downloadURL: downloadURL,
            kcExists: false,
            syllabusTitle: title,
            syllabusNodeID: node.nodeID,
            syllabusContext: _syllabusContext(for: node, nodesByID: [node.nodeID: node])
        )
        return try await _localPDFURL(for: entry).url
    }

    private static func _findArxivIDByWebSearch(title: String, titleEn: String?) async throws -> String? {
        let prompt = """
        次の論文の正確なarXiv IDをWeb検索で確認してください。

        論文名: \(title)
        英語名: \(titleEn ?? "-")

        存在が確認できた場合は、arXiv IDだけを返してください(例: 1706.03762)。バージョン番号(vN)は付けないでください。
        確認できない場合は NOT_FOUND とだけ返してください。他の文章・説明を含めないでください。
        """
        let raw = try await Inf6LibraryView.askOpenAIText(prompt, lang: "ja", allowWebSearch: true)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = trimmed.range(of: #"\d{4}\.\d{4,5}"#, options: .regularExpression) else {
            return nil
        }
        return String(trimmed[match])
    }

    // MARK: - Step 2+3+4

    /// 生成の進み具合を画面へ知らせる。何をしているか分からない待ち時間を作らない。
    typealias ProgressReporter = @Sendable (String) async -> Void

    static func ensureKCAndQuiz(
        entry: DrillEntry,
        askModel: @escaping (String) async throws -> String,
        progress: ProgressReporter? = nil,
        generateBaseQuiz: Bool = true,
        generateCodePractice: Bool = true,
        forceCodePracticeRegeneration: Bool = false
    ) async throws -> Inf6PaperQuiz? {
        guard let kcRoot = Inf6KnowledgeCardsPaths.rootDirectoryURL() else {
            throw _failure(
                entry: entry,
                operation: "prepare_knowledge_card_directory",
                kind: .missingStorage,
                cause: "保存先rootを解決できないためナレッジカード保存先を決定できません。",
                plan: ["保存先rootを解決する", "保存先ディレクトリを作成する", "同じ生成工程を継続する"],
                attempts: []
            )
        }
        let kcDir = kcRoot.appendingPathComponent(entry.folderKey)

        if isGeneratedExplanationProvider(entry.paper.provider) {
            try await _ensureTextbookFieldEvidence(
                entry: entry,
                kcDir: kcDir,
                askModel: askModel,
                progress: progress
            )
            let needsBaseQuizRegeneration = generateBaseQuiz && _requiresBaseQuizRegeneration(entry: entry)
            let needsCodePracticeRegeneration = generateCodePractice
                && (forceCodePracticeRegeneration || _requiresCodePracticeRegeneration(entry: entry))
            if needsBaseQuizRegeneration || needsCodePracticeRegeneration {
                NSLog("[DrillPipeline] Step4(textbook): generating quiz from original explanation for %@", entry.paper.title)
                await progress?("演習を生成しています")
                return try await _generateQuizFromKC(
                    entry: entry,
                    kcDir: kcDir,
                    includeBaseQuiz: needsBaseQuizRegeneration,
                    includeCodePractice: needsCodePracticeRegeneration,
                    preserveExistingCodeQuestions: needsBaseQuizRegeneration && !needsCodePracticeRegeneration,
                    askModel: askModel
                )
            }
            return entry.quiz
        }

        await progress?("論文PDFを用意しています")

        let resolvedPDF: _ResolvedPDF
        do {
            resolvedPDF = try await _localPDFURL(for: entry)
        } catch {
            if isCancellation(error) { throw error }
            throw _failure(
                entry: entry,
                operation: "resolve_paper_pdf",
                kind: _failureKind(from: error),
                cause: "論文PDFまたは本文を取得できないため、論文根拠の演習を生成できません: \(error.localizedDescription)",
                plan: [
                    "許可ソース内のPDF URLまたは本文URLを確認する",
                    "ユーザー取り込みPDFがある場合はpdf_import参照を登録する",
                    "本文/PDFの実測確認が完了するまで演習生成を停止する",
                ],
                attempts: [],
                underlying: error
            )
        }
        let pdfURL = resolvedPDF.url
        let needsEntityEvidence = !_hasGeneratedEntityEvidence(
            paperKey: entry.folderKey,
            kcDir: kcDir
        )
        if needsEntityEvidence {
            NSLog("[DrillPipeline] Step3: generating KC overview from PDF for %@", entry.paper.title)
            await progress?("PDF から解説を作成しています")
            do {
                try await _generateKCFolder(
                    pdfURL: pdfURL,
                    kcDir: kcDir,
                    paperKey: entry.folderKey,
                    paperTitle: entry.paper.title,
                    paperID: entry.paper.id,
                    syllabusContext: [entry.syllabusContext, entry.paper.title, entry.paper.titleEn]
                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n"),
                    forceOverviewRegeneration: resolvedPDF.sourceWasReplaced,
                    askModel: askModel
                )
            } catch let failure as DrillPipelineError {
                throw failure
            } catch {
                if isCancellation(error) { throw error }
                throw _failure(
                    entry: entry,
                    operation: "generate_knowledge_card",
                    kind: _failureKind(from: error),
                    cause: error.localizedDescription,
                    plan: ["PDFを開く", "本文を抽出する", "中核図表数式を決定論的に抽出する", "画像切り出しとKCノート生成を検証する"],
                    attempts: [],
                    underlying: error
                )
            }
        } else if resolvedPDF.sourceWasReplaced || !_hasCurrentOverview(paperKey: entry.folderKey, kcDir: kcDir) {
            NSLog("[DrillPipeline] Step3: regenerating structured overview for %@", entry.paper.title)
            await progress?("解説を作り直しています")
            do {
                let existingEntities = Inf6MetadataStore.getCodable(
                    Inf6DocEntityIndex.self, domain: .docEntities, key: entry.folderKey
                )?.entities ?? []
                try await _generateOverviewIfRequired(
                    pdfURL: pdfURL,
                    kcDir: kcDir,
                    paperKey: entry.folderKey,
                    paperTitle: entry.paper.title,
                    paperID: entry.paper.id,
                    entityEvidence: _entityEvidenceBlock(existingEntities),
                    forceRegeneration: resolvedPDF.sourceWasReplaced
                )
            } catch {
                if isCancellation(error) { throw error }
                throw _failure(
                    entry: entry,
                    operation: "generate_knowledge_card_overview",
                    kind: _failureKind(from: error),
                    cause: error.localizedDescription,
                    plan: ["既存概要の構造を検証する", "PDF根拠から理解点付き概要を生成する", "検証成功後に概要を置換する"],
                    attempts: [],
                    underlying: error
                )
            }
        }
        let needsBaseQuizRegeneration = generateBaseQuiz && _requiresBaseQuizRegeneration(entry: entry)
        let needsCodePracticeRegeneration = generateCodePractice
            && (forceCodePracticeRegeneration || _requiresCodePracticeRegeneration(entry: entry))
        if needsBaseQuizRegeneration || needsCodePracticeRegeneration {
            NSLog("[DrillPipeline] Step4: generating quiz from KC overview for %@", entry.paper.title)
            await progress?("演習を生成しています")
            return try await _generateQuizFromKC(
                entry: entry,
                kcDir: kcDir,
                includeBaseQuiz: needsBaseQuizRegeneration,
                includeCodePractice: needsCodePracticeRegeneration,
                preserveExistingCodeQuestions: needsBaseQuizRegeneration && !needsCodePracticeRegeneration,
                askModel: askModel
            )
        }
        return entry.quiz
    }

    // MARK: - 解説項目: PDFなしで概要・エンティティを直接生成

    private static func _ensureTextbookFieldEvidence(
        entry: DrillEntry,
        kcDir: URL,
        askModel: @escaping (String) async throws -> String,
        progress: ProgressReporter? = nil
    ) async throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: kcDir, withIntermediateDirectories: true)
        } catch {
            throw _failure(
                entry: entry,
                operation: "prepare_textbook_kc_directory",
                kind: .pdfPersistence,
                cause: error.localizedDescription,
                plan: ["KCフォルダを作成する", "解説の生成を継続する"],
                attempts: [],
                underlying: error
            )
        }

        if !_hasCurrentTextbookOriginalExplanation(paperKey: entry.folderKey, kcDir: kcDir) {
            NSLog("[DrillPipeline] Step3(textbook): generating syllabus explanation overview for %@", entry.paper.title)
            await progress?("解説を作成しています")
            let overview: String
            do {
                overview = try await _generateTextbookOverview(entry: entry, askModel: askModel)
            } catch {
                if isCancellation(error) { throw error }
                throw _failure(
                    entry: entry,
                    operation: "generate_textbook_overview",
                    kind: _failureKind(from: error),
                    cause: error.localizedDescription,
                    plan: ["解説文を再生成する", "契約書式(解説/数学的導出/実装/実務上の検証)を検証する"],
                    attempts: [],
                    underlying: error
                )
            }
            let abstractURL = _textbookOriginalExplanationURL(paperKey: entry.folderKey, kcDir: kcDir)
            do {
                try await _withMetadataWrite {
                    try overview.write(to: abstractURL, atomically: true, encoding: .utf8)
                }
            } catch {
                throw _failure(
                    entry: entry,
                    operation: "persist_textbook_overview",
                    kind: .pdfPersistence,
                    cause: error.localizedDescription,
                    plan: ["概要文をatomic保存する"],
                    attempts: [],
                    underlying: error
                )
            }
        }

        if !_hasGeneratedEntityEvidence(paperKey: entry.folderKey, kcDir: kcDir) {
            NSLog("[DrillPipeline] Step3(textbook): generating docEntity index for %@", entry.paper.title)
            await progress?("演習の根拠を作成しています")
            do {
                var generated = try await _generateTextbookEntities(
                    entry: entry,
                    askModel: askModel
                )
                guard !generated.entities.isEmpty else {
                    throw NSError(
                        domain: "Inf6EshikakuDrillPipeline",
                        code: 203,
                        userInfo: [NSLocalizedDescriptionKey: "解説項目から演習の根拠となる数式・表を抽出できませんでした。"]
                    )
                }
                try _renderTextbookEntityImages(
                    paperKey: entry.folderKey,
                    entities: &generated.entities,
                    plots: generated.plots
                )
                guard generated.entities.allSatisfy({ _imageFileExists($0.imagePath) }) else {
                    throw NSError(
                        domain: "Inf6EshikakuDrillPipeline",
                        code: 204,
                        userInfo: [NSLocalizedDescriptionKey: "演習の根拠画像を保存できませんでした。"]
                    )
                }
                try await _withMetadataWrite {
                    guard Inf6MetadataStore.putCodable(
                        Inf6DocEntityIndex(pdfKey: entry.folderKey, entities: generated.entities),
                        domain: .docEntities,
                        key: entry.folderKey
                    ) else {
                        throw NSError(domain: "Inf6EshikakuDrillPipeline", code: 205, userInfo: [
                            NSLocalizedDescriptionKey: "docEntity indexを保存できませんでした: \(entry.folderKey)"
                        ])
                    }
                }
            } catch {
                if isCancellation(error) { throw error }
                throw _failure(
                    entry: entry,
                    operation: "generate_textbook_doc_entities",
                    kind: _failureKind(from: error),
                    cause: error.localizedDescription,
                    plan: ["解説本文から数式・表の根拠を抽出する", "根拠画像を保存する", "docEntity indexを保存してから問題生成を継続する"],
                    attempts: [],
                    underlying: error
                )
            }
        }

    }

    private static func _generateTextbookOverview(
        entry: DrillEntry,
        askModel: @escaping (String) async throws -> String
    ) async throws -> String {
        let title = entry.paper.title
        let context = entry.syllabusContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = """
        E資格シラバス項目「\(title)」について、解説をプレーンテキストで生成してください。

        以下の4見出しをこの順序で必ず出力してください。見出しは行頭に単独で置き、日本語のままにしてください。
        解説
        数学的導出
        実装
        実務上の検証

        出力条件:
        - 日本語で書く。Markdown記号やコードブロックは使わない
        - 「解説」: この概念の位置づけ、何のための知識か、機械学習・深層学習のどの処理で実際に使うかを説明する
        - 「数学的導出」: 記号の定義から機械学習・深層学習で使う式までを省略せず、途中式を示す。箇条書きのポイント集は禁止する
        - 「実装」: PyTorchまたはTensorFlowの実例、入力shape、出力、学習更新との関係を説明する
        - 「実務上の検証」: 使い分け、確認すべきshape、損失、評価指標、失敗条件と適用限界を具体的に書く
          例: 多層パーセプトロンでは、単純パーセプトロンの線形境界だけで終えてはならない。
          隠れ層、非線形活性化、特徴変換、非線形決定境界のいずれかを中核として扱う
        - 用語の羅列、理解点、ポイント、コア理論という見出しは出力してはいけない
        - 誤解や誤りの例、定型的な試験対策文を書いてはならない
          役割の違い、対になる要素の相違点、成立条件、パラメータを変えたときの帰結、なぜその方法なのかで書き分ける
        - 実在しない論文・URL・DOIを創作してはいけない。単一の起源を主張してもいけない
        - E資格の出題範囲に沿い、受験者が絶対に知っておくべき内容に絞る

        シラバス文脈:
        \(context)
        """
        let raw = try await askModel(prompt)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Inf6AssetsAbstractPipeline.overviewMeetsCurrentContract(trimmed) else {
            throw NSError(domain: "Inf6EshikakuDrillPipeline", code: 201, userInfo: [
                NSLocalizedDescriptionKey: "生成された概要が契約書式(解説/数学的導出/実装/実務上の検証)を満たしていません。"
            ])
        }
        return trimmed
    }

    private struct _TextbookEntityBatch: Decodable {
        let entities: [_TextbookRawEntity]
    }
    private struct _TextbookRawEntity: Decodable {
        let kind: String
        let title: String
        let snippet: String
        let explanation: String?
        /// figure のときだけ入る。関数の形を描くための式。
        let plot: Inf6TextbookPlot.Spec?

        /// plot が読めなくても、その項目ごと捨てない。
        ///
        /// 図の指定を足した際、plot の形が少しでも違うと生成全体が
        /// 「正しい形式ではありません」で落ちるようにしてしまった。図が
        /// 描けないことと、解説が一つも作れないことは別である。
        enum CodingKeys: String, CodingKey { case kind, title, snippet, explanation, plot }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = (try? c.decode(String.self, forKey: .kind)) ?? "equation"
            title = try c.decode(String.self, forKey: .title)
            snippet = try c.decode(String.self, forKey: .snippet)
            explanation = try? c.decode(String.self, forKey: .explanation)
            plot = try? c.decode(Inf6TextbookPlot.Spec.self, forKey: .plot)
        }
    }


    /// 解説項目の数式・表を画像として描画する。
    ///
    /// 解説項目には原論文もPDFも無いため切り出す対象が存在しない。
    /// しかし演習は図表数式を根拠に問う設計なので、生成した数式・表の本文を
    /// そのまま組版して画像化し、論文の切り出し図と同じ土俵に載せる。
    private static func _renderTextbookEntityImages(
        paperKey: String,
        entities: inout [Inf6DocEntity],
        plots: [Int: Inf6TextbookPlot.Spec] = [:]
    ) throws {
        #if canImport(UIKit)
        let fm = FileManager.default
        let paperDirName = String(paperKey.prefix(80))
        let imagesBase = Inf6LibraryView._entityImagesBaseURL()
        let entityDir = imagesBase.appendingPathComponent(paperDirName, isDirectory: true)
        try fm.createDirectory(at: entityDir, withIntermediateDirectories: true)

        // 論文の切り出しは PDF 1pt あたり 2px。表示側が同じ前提で寸法を決めるため揃える。
        let scale: CGFloat = 2.0
        let contentWidthPt: CGFloat = 460
        let paddingPt: CGFloat = 18

        for index in entities.indices {
            let entity = entities[index]
            let requiresTypesetRefresh = entity.kind == .equation
                && !(entity.imagePath?.contains("textbook_equation_typeset_v2_") ?? false)
            guard requiresTypesetRefresh || !_imageFileExists(entity.imagePath) else { continue }

            // 関数の形が本体である概念は、式を並べても理解に届かない。
            // 式からこちらで点を計算し、実際のグラフを描く。
            if entity.kind == .figure,
               let spec = plots[index],
               let plotted = Inf6TextbookPlot.render(spec),
               let data = plotted.jpegData(compressionQuality: 0.92) {
                let name = "textbook_figure_\(index).jpg"
                let relPath = "\(paperDirName)/\(name)"
                try Inf6EntityImageStore.write(data, relativePath: relPath)
                entities[index].imagePath = relPath
                continue
            }
            if entity.kind == .figure,
               let diagram = _renderTextbookFlowGraphDiagram(entity),
               let data = diagram.jpegData(compressionQuality: 0.92) {
                let name = "textbook_figure_\(index).jpg"
                let relPath = "\(paperDirName)/\(name)"
                try Inf6EntityImageStore.write(data, relativePath: relPath)
                entities[index].imagePath = relPath
                continue
            }
            if entity.kind == .figure,
               let diagram = _renderTextbookLayerFlowDiagram(entity),
               let data = diagram.jpegData(compressionQuality: 0.92) {
                let name = "textbook_figure_\(index).jpg"
                let relPath = "\(paperDirName)/\(name)"
                try Inf6EntityImageStore.write(data, relativePath: relPath)
                entities[index].imagePath = relPath
                continue
            }
            let titleFont = UIFont.systemFont(ofSize: 12, weight: .semibold)
            let bodyFont = entity.kind == .equation
                ? UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                : UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineSpacing = 3

            let titleText = NSAttributedString(
                string: entity.title,
                attributes: [.font: titleFont, .foregroundColor: UIColor.label, .paragraphStyle: paragraph]
            )
            let bodyText = _displaySnippet(
                for: entity,
                font: bodyFont,
                paragraph: paragraph
            )

            let bounds = CGSize(width: contentWidthPt, height: .greatestFiniteMagnitude)
            let titleRect = titleText.boundingRect(with: bounds, options: [.usesLineFragmentOrigin], context: nil)
            let bodyRect = bodyText.boundingRect(with: bounds, options: [.usesLineFragmentOrigin], context: nil)
            let totalHeight = paddingPt * 2 + ceil(titleRect.height) + 10 + ceil(bodyRect.height)
            let sizePt = CGSize(width: contentWidthPt + paddingPt * 2, height: totalHeight)

            let format = UIGraphicsImageRendererFormat.default()
            format.scale = scale
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: sizePt, format: format)
            let image = renderer.image { ctx in
                UIColor.systemBackground.setFill()
                ctx.fill(CGRect(origin: .zero, size: sizePt))
                titleText.draw(
                    with: CGRect(x: paddingPt, y: paddingPt, width: contentWidthPt, height: ceil(titleRect.height)),
                    options: [.usesLineFragmentOrigin],
                    context: nil
                )
                bodyText.draw(
                    with: CGRect(
                        x: paddingPt,
                        y: paddingPt + ceil(titleRect.height) + 10,
                        width: contentWidthPt,
                        height: ceil(bodyRect.height)
                    ),
                    options: [.usesLineFragmentOrigin],
                    context: nil
                )
            }
            guard let data = image.jpegData(compressionQuality: 0.92) else { continue }
            let imgName = entity.kind == .equation
                ? "textbook_equation_typeset_v2_\(index).jpg"
                : "textbook_\(entity.kind.rawValue)_\(index).jpg"
            // 生成した端末はローカルと iCloud の両方へ置く。
            // ローカルは表示用で追い出されない。iCloud は他の端末への配布元。
            try Inf6EntityImageStore.write(data, relativePath: "\(paperDirName)/\(imgName)")
            entities[index].imagePath = "\(paperDirName)/\(imgName)"
        }
        #endif
    }

    #if canImport(UIKit)
    private struct _TextbookFlowNode {
        let id: String
        let label: String
        let role: String
    }

    private struct _TextbookFlowEdge {
        let from: String
        let to: String
        let label: String?
    }

    private static func _renderTextbookLayerFlowDiagram(_ entity: Inf6DocEntity) -> UIImage? {
        let fields = _diagramFields(entity.snippet)
        guard fields["diagram"]?.lowercased() == "layer_flow" else { return nil }
        let layers = _splitDiagramList(fields["layers"])
        guard layers.count >= 2 else { return nil }
        let nodeCounts = _splitDiagramList(fields["nodes"]).map { Int($0) ?? 3 }
        let annotation = fields["annotation"] ?? entity.explanation ?? ""
        let contrast = fields["contrast"] ?? ""

        let scale: CGFloat = 2
        let size = CGSize(width: 760, height: 430)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 27, weight: .bold),
                .foregroundColor: UIColor.black
            ]
            let subtitleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: UIColor.darkText
            ]
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14, weight: .bold),
                .foregroundColor: UIColor.black
            ]
            let noteAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14, weight: .regular),
                .foregroundColor: UIColor.black
            ]

            (entity.title as NSString).draw(
                in: CGRect(x: 20, y: 18, width: size.width - 40, height: 36),
                withAttributes: titleAttrs
            )
            if !annotation.isEmpty {
                _drawCenteredText(
                    annotation,
                    rect: CGRect(x: 36, y: 63, width: size.width - 72, height: 34),
                    attributes: subtitleAttrs,
                    fill: UIColor(red: 1.00, green: 0.93, blue: 0.87, alpha: 1)
                )
            }

            let diagramTop: CGFloat = 120
            let diagramBottom: CGFloat = 330
            let left: CGFloat = 80
            let right: CGFloat = size.width - 80
            let step = (right - left) / CGFloat(max(layers.count - 1, 1))
            var nodePositionsByLayer: [[CGPoint]] = []

            for layerIndex in layers.indices {
                let x = left + CGFloat(layerIndex) * step
                let count = max(1, min(nodeCounts.indices.contains(layerIndex) ? nodeCounts[layerIndex] : 3, 6))
                let box = CGRect(x: x - 58, y: diagramTop - 18, width: 116, height: diagramBottom - diagramTop + 36)
                let path = UIBezierPath(roundedRect: box, cornerRadius: 18)
                UIColor.gray.setStroke()
                path.lineWidth = 2
                path.setLineDash([4, 4], count: 2, phase: 0)
                path.stroke()

                _drawCenteredText(layers[layerIndex], rect: CGRect(x: x - 62, y: diagramTop - 52, width: 124, height: 28), attributes: labelAttrs, fill: UIColor(red: 0.95, green: 1.0, blue: 0.92, alpha: 1))

                let nodeStep = (diagramBottom - diagramTop) / CGFloat(max(count - 1, 1))
                let points = (0..<count).map { nodeIndex -> CGPoint in
                    let y = count == 1 ? (diagramTop + diagramBottom) / 2 : diagramTop + CGFloat(nodeIndex) * nodeStep
                    return CGPoint(x: x, y: y)
                }
                nodePositionsByLayer.append(points)
                for point in points {
                    let node = UIBezierPath(ovalIn: CGRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36))
                    UIColor(red: 0.58, green: 0.76, blue: 0.92, alpha: 1).setFill()
                    node.fill()
                }
            }

            let arrowColor = UIColor(red: 0.86, green: 0.45, blue: 0.16, alpha: 1)
            for layerIndex in 0..<(nodePositionsByLayer.count - 1) {
                for start in nodePositionsByLayer[layerIndex] {
                    for end in nodePositionsByLayer[layerIndex + 1] {
                        _drawArrow(from: CGPoint(x: start.x + 18, y: start.y), to: CGPoint(x: end.x - 18, y: end.y), color: arrowColor)
                    }
                }
            }

            if !contrast.isEmpty {
                _drawCenteredText(
                    contrast,
                    rect: CGRect(x: 48, y: 360, width: size.width - 96, height: 44),
                    attributes: noteAttrs,
                    fill: UIColor.white
                )
            }
        }
    }

    private static func _renderTextbookFlowGraphDiagram(_ entity: Inf6DocEntity) -> UIImage? {
        let fields = _diagramFields(entity.snippet)
        guard fields["diagram"]?.lowercased() == "flow_graph" else { return nil }

        let nodes = _parseTextbookFlowNodes(fields["nodes"])
        let edges = _parseTextbookFlowEdges(fields["edges"])
        guard nodes.count >= 2, !edges.isEmpty else { return nil }

        let nodeIDs = Set(nodes.map(\.id))
        guard edges.allSatisfy({ nodeIDs.contains($0.from) && nodeIDs.contains($0.to) }) else { return nil }

        let depths = _flowDepths(nodes: nodes, edges: edges)
        let grouped = Dictionary(grouping: nodes, by: { depths[$0.id] ?? 0 })
        let orderedDepths = grouped.keys.sorted()
        guard orderedDepths.count >= 2 else { return nil }

        let annotation = fields["annotation"] ?? entity.explanation ?? ""
        let contrast = fields["contrast"] ?? ""
        let scale: CGFloat = 2
        let size = CGSize(width: 900, height: 480)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            UIColor.white.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 27, weight: .bold),
                .foregroundColor: UIColor.black
            ]
            let subtitleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: UIColor.darkText
            ]
            let nodeAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 15, weight: .bold),
                .foregroundColor: UIColor.black
            ]
            let edgeAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: UIColor.darkGray
            ]
            let noteAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14, weight: .regular),
                .foregroundColor: UIColor.black
            ]

            (entity.title as NSString).draw(
                in: CGRect(x: 20, y: 18, width: size.width - 40, height: 36),
                withAttributes: titleAttrs
            )
            if !annotation.isEmpty {
                _drawCenteredText(
                    annotation,
                    rect: CGRect(x: 36, y: 63, width: size.width - 72, height: 34),
                    attributes: subtitleAttrs,
                    fill: UIColor(red: 1.00, green: 0.93, blue: 0.87, alpha: 1)
                )
            }

            let top: CGFloat = 135
            let bottom: CGFloat = contrast.isEmpty ? 415 : 360
            let left: CGFloat = 80
            let right: CGFloat = size.width - 80
            let columnStep = (right - left) / CGFloat(max(orderedDepths.count - 1, 1))
            var rectsByID: [String: CGRect] = [:]

            for (columnIndex, depth) in orderedDepths.enumerated() {
                let columnNodes = nodes.filter { (depths[$0.id] ?? 0) == depth }
                let rowStep = (bottom - top) / CGFloat(max(columnNodes.count - 1, 1))
                let x = left + CGFloat(columnIndex) * columnStep

                for (rowIndex, node) in columnNodes.enumerated() {
                    let y = columnNodes.count == 1 ? (top + bottom) / 2 : top + CGFloat(rowIndex) * rowStep
                    let rect = CGRect(x: x - 68, y: y - 24, width: 136, height: 48)
                    rectsByID[node.id] = rect
                }
            }

            let arrowColor = UIColor(red: 0.86, green: 0.45, blue: 0.16, alpha: 1)
            for edge in edges {
                guard let fromRect = rectsByID[edge.from], let toRect = rectsByID[edge.to] else { continue }
                let start = CGPoint(x: fromRect.maxX, y: fromRect.midY)
                let end = CGPoint(x: toRect.minX, y: toRect.midY)
                _drawArrow(from: start, to: end, color: arrowColor)
                if let label = edge.label, !label.isEmpty {
                    _drawCenteredText(
                        label,
                        rect: CGRect(x: (start.x + end.x) / 2 - 28, y: (start.y + end.y) / 2 - 15, width: 56, height: 24),
                        attributes: edgeAttrs,
                        fill: UIColor.white
                    )
                }
            }

            for node in nodes {
                guard let rect = rectsByID[node.id] else { continue }
                let path = UIBezierPath(roundedRect: rect, cornerRadius: 12)
                _flowNodeFill(role: node.role).setFill()
                UIColor(red: 0.52, green: 0.70, blue: 0.86, alpha: 1).setStroke()
                path.lineWidth = 1.2
                path.fill()
                path.stroke()
                _drawCenteredText(node.label, rect: rect, attributes: nodeAttrs, fill: .clear)
            }

            if !contrast.isEmpty {
                _drawCenteredText(
                    contrast,
                    rect: CGRect(x: 48, y: 390, width: size.width - 96, height: 44),
                    attributes: noteAttrs,
                    fill: UIColor.white
                )
            }
        }
    }

    private static func _diagramFields(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !value.isEmpty { result[key] = value }
        }
        return result
    }

    private static func _splitDiagramList(_ raw: String?) -> [String] {
        raw?
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
    }

    private static func _parseTextbookFlowNodes(_ raw: String?) -> [_TextbookFlowNode] {
        _splitDiagramList(raw).compactMap { item in
            let fields = _inlineDiagramFields(item)
            guard let id = fields["id"], let label = fields["label"], !id.isEmpty, !label.isEmpty else { return nil }
            return _TextbookFlowNode(id: id, label: label, role: fields["role"] ?? "step")
        }
    }

    private static func _parseTextbookFlowEdges(_ raw: String?) -> [_TextbookFlowEdge] {
        _splitDiagramList(raw).compactMap { item in
            let parts = item.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let arrow = parts.first, arrow.contains("->") else { return nil }
            let endpoints = arrow.components(separatedBy: "->").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard endpoints.count == 2, !endpoints[0].isEmpty, !endpoints[1].isEmpty else { return nil }
            let fields = _inlineDiagramFields(parts.dropFirst().joined(separator: ";"))
            return _TextbookFlowEdge(from: endpoints[0], to: endpoints[1], label: fields["label"])
        }
    }

    private static func _inlineDiagramFields(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in text.components(separatedBy: ";") {
            guard let separator = part.firstIndex(of: "=") else { continue }
            let key = part[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = part[part.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !value.isEmpty { result[key] = value }
        }
        return result
    }

    private static func _flowDepths(nodes: [_TextbookFlowNode], edges: [_TextbookFlowEdge]) -> [String: Int] {
        var depths = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, 0) })
        for _ in 0..<nodes.count {
            var changed = false
            for edge in edges {
                let nextDepth = (depths[edge.from] ?? 0) + 1
                if nextDepth > (depths[edge.to] ?? 0) {
                    depths[edge.to] = nextDepth
                    changed = true
                }
            }
            if !changed { break }
        }
        return depths
    }

    private static func _flowNodeFill(role: String) -> UIColor {
        switch role.lowercased() {
        case "input":
            return UIColor(red: 0.94, green: 1.00, blue: 0.90, alpha: 1)
        case "decision":
            return UIColor(red: 1.00, green: 0.95, blue: 0.78, alpha: 1)
        case "output":
            return UIColor(red: 0.93, green: 0.98, blue: 0.91, alpha: 1)
        case "score":
            return UIColor(red: 0.94, green: 0.92, blue: 1.00, alpha: 1)
        default:
            return UIColor(red: 0.91, green: 0.97, blue: 1.00, alpha: 1)
        }
    }

    private static func _drawCenteredText(
        _ text: String,
        rect: CGRect,
        attributes: [NSAttributedString.Key: Any],
        fill: UIColor
    ) {
        let box = UIBezierPath(roundedRect: rect, cornerRadius: 8)
        fill.setFill()
        box.fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        var attrs = attributes
        attrs[.paragraphStyle] = paragraph
        (text as NSString).draw(in: rect.insetBy(dx: 8, dy: 6), withAttributes: attrs)
    }

    private static func _drawArrow(from start: CGPoint, to end: CGPoint, color: UIColor) {
        let path = UIBezierPath()
        path.move(to: start)
        path.addLine(to: end)
        color.setStroke()
        path.lineWidth = 1.2
        path.stroke()

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength: CGFloat = 7
        let headAngle: CGFloat = .pi / 7
        let arrowHead = UIBezierPath()
        arrowHead.move(to: end)
        arrowHead.addLine(to: CGPoint(
            x: end.x - headLength * cos(angle - headAngle),
            y: end.y - headLength * sin(angle - headAngle)
        ))
        arrowHead.move(to: end)
        arrowHead.addLine(to: CGPoint(
            x: end.x - headLength * cos(angle + headAngle),
            y: end.y - headLength * sin(angle + headAngle)
        ))
        color.setStroke()
        arrowHead.lineWidth = 1.2
        arrowHead.stroke()
    }
    #endif

    private static func _displaySnippet(
        for entity: Inf6DocEntity,
        font: UIFont,
        paragraph: NSParagraphStyle
    ) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph
        ]
        guard entity.kind == .equation else {
            return NSAttributedString(string: entity.snippet, attributes: attributes)
        }

        let result = NSMutableAttributedString()
        for (lineIndex, line) in _formatEquationSnippet(entity.snippet).components(separatedBy: .newlines).enumerated() {
            if lineIndex > 0 { result.append(NSAttributedString(string: "\n", attributes: attributes)) }
            result.append(_typesetEquationLine(line, font: font, paragraph: paragraph))
        }
        return result
    }

    /// 生成済みデータに残る旧式の `^` / `_` 表記も、画面へ記号を露出させずに
    /// 上付き・下付きの組版へ変換する。対応できない数式を別の意味へ置換しない。
    private static func _typesetEquationLine(
        _ line: String,
        font: UIFont,
        paragraph: NSParagraphStyle
    ) -> NSAttributedString {
        let normal: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label, .paragraphStyle: paragraph]
        let raised: [NSAttributedString.Key: Any] = [.font: font.withSize(font.pointSize * 0.72), .foregroundColor: UIColor.label, .baselineOffset: font.pointSize * 0.32, .paragraphStyle: paragraph]
        let lowered: [NSAttributedString.Key: Any] = [.font: font.withSize(font.pointSize * 0.72), .foregroundColor: UIColor.label, .baselineOffset: -font.pointSize * 0.18, .paragraphStyle: paragraph]
        let output = NSMutableAttributedString()
        let chars = Array(line)
        var index = 0
        while index < chars.count {
            let marker = chars[index]
            guard marker == "^" || marker == "_" else {
                output.append(NSAttributedString(string: String(marker), attributes: normal))
                index += 1
                continue
            }
            let start = index + 1
            guard start < chars.count else {
                output.append(NSAttributedString(string: String(marker), attributes: normal))
                index += 1
                continue
            }
            var end = start + 1
            if chars[start] == "{" {
                end = start + 1
                while end < chars.count, chars[end] != "}" { end += 1 }
                guard end < chars.count else {
                    output.append(NSAttributedString(string: String(marker), attributes: normal))
                    index += 1
                    continue
                }
                let value = String(chars[(start + 1)..<end])
                output.append(NSAttributedString(string: value, attributes: marker == "^" ? raised : lowered))
                index = end + 1
            } else if chars[start] == "(" {
                end = start + 1
                var depth = 1
                while end < chars.count, depth > 0 {
                    if chars[end] == "(" { depth += 1 }
                    if chars[end] == ")" { depth -= 1 }
                    end += 1
                }
                guard depth == 0 else {
                    output.append(NSAttributedString(string: String(marker), attributes: normal))
                    index += 1
                    continue
                }
                let value = String(chars[start..<end])
                output.append(NSAttributedString(string: value, attributes: marker == "^" ? raised : lowered))
                index = end
            } else {
                output.append(NSAttributedString(string: String(chars[start]), attributes: marker == "^" ? raised : lowered))
                index = end
            }
        }
        return output
    }

    private static func _formatEquationSnippet(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .flatMap { _splitEquationClauses($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func _splitEquationClauses(_ text: String) -> [String] {
        var clauses: [String] = []
        var current = ""
        var parenDepth = 0
        var braceDepth = 0
        let chars = Array(text)

        for (offset, ch) in chars.enumerated() {
            switch ch {
            case "(":
                parenDepth += 1
                current.append(ch)
            case ")":
                parenDepth = max(0, parenDepth - 1)
                current.append(ch)
            case "{":
                braceDepth += 1
                current.append(ch)
            case "}":
                braceDepth = max(0, braceDepth - 1)
                current.append(ch)
            case ",", ";":
                let next = String(chars.dropFirst(offset + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if parenDepth == 0, braceDepth == 0, _looksLikeEquationAssignment(next) {
                    let clause = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clause.isEmpty { clauses.append(clause) }
                    current = ""
                } else {
                    current.append(ch)
                }
            default:
                current.append(ch)
            }
        }

        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { clauses.append(tail) }
        return clauses.isEmpty ? [text] : clauses
    }

    private static func _looksLikeEquationAssignment(_ text: String) -> Bool {
        let head = String(text.prefix(48))
        guard let equals = head.firstIndex(of: "=") else { return false }
        let lhs = head[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lhs.isEmpty, lhs.count <= 24 else { return false }
        return lhs.range(of: #"^[A-Za-zα-ωΑ-Ω\\_{}\^\+\-\s0-9]+$"#, options: .regularExpression) != nil
    }

    private static func _generateTextbookEntities(
        entry: DrillEntry,
        askModel: @escaping (String) async throws -> String
    ) async throws -> (entities: [Inf6DocEntity], plots: [Int: Inf6TextbookPlot.Spec]) {
        let title = entry.paper.title
        let prompt = """
        E資格シラバス項目「\(title)」について、演習問題の根拠となる核心の視覚・構造根拠を、次のJSONオブジェクトだけで出力してください。
        根拠の型は概念に応じて選びます。AIが作る図・グラフは生成してはいけません。

        {
          "entities": [
            {"kind": "equation または table", "title": "短い見出し", "snippet": "数式は組版済みUnicode数学記号、表は構造化テキスト", "explanation": "これが何を意味し、何を問うべきかの解説"}
          ]
        }

        kind の選び方:
        - equation: 数式の変数・写像・目的関数・更新式の関係を読むことが理解の中心のとき
        - table: 複数概念、条件、長所短所、単純版との差分を並べて比べることが理解の中心のとき

        内容の選び方:
        - 項目名に対して本質的な構造図・フロー図・比較表・数式・グラフを選ぶ。周辺概念だけを出してはいけない
        - まず「構造で理解する概念」「式で理解する概念」「比較で理解する概念」「曲線で理解する概念」のどれかを判断し、それに合う kind を選ぶ
        - snippet は、数式または表を単独で意味が分かる内容にする。数式はUnicodeの数学記号と上付き・下付き文字で組版して出し、LaTeX、^、_、R^(...)、C_ij等の未組版表記は禁止。単語だけは禁止
        - equation/tableの内容は、機械学習・深層学習で実際に使う変数、導出、比較条件に限定する

        entities は最低3件、最大8件生成してください。figure、plot、FLOW_GRAPH、LAYER_FLOWは出力してはいけません。
        実在しない論文の引用や出典URLを創作してはいけません。
        JSONオブジェクトだけを出力し、他のテキストを含めないでください。
        """
        let raw = try await askModel(prompt)
        guard let jsonText = _extractJSONObject(from: raw) else {
            throw NSError(domain: "Inf6EshikakuDrillPipeline", code: 202, userInfo: [
                NSLocalizedDescriptionKey: "解説項目のエンティティ出力がJSONオブジェクトではありません。"
            ])
        }
        let decoded = try JSONDecoder().decode(_TextbookEntityBatch.self, from: Data(jsonText.utf8))
        var result: [Inf6DocEntity] = []
        var plots: [Int: Inf6TextbookPlot.Spec] = [:]
        for (index, raw) in decoded.entities.enumerated() {
            let kind: Inf6DocEntityKind
            switch raw.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "table": kind = .table
            case "figure": kind = .figure
            default: kind = .equation
            }
            let entityTitle = raw.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = raw.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entityTitle.isEmpty, !snippet.isEmpty else { continue }
            guard kind != .figure else { continue }
            result.append(Inf6DocEntity(
                kind: kind,
                pageIndex: index,
                title: entityTitle,
                snippet: snippet,
                explanation: raw.explanation?.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        return (entities: result, plots: plots)
    }

    private static func _hasGeneratedEntityEvidence(paperKey: String, kcDir: URL) -> Bool {
        if let index = Inf6MetadataStore.getCodable(Inf6DocEntityIndex.self, domain: .docEntities, key: paperKey),
           index.version >= Inf6DocEntityIndex.currentVersion,
           !index.entities.isEmpty,
           index.entities.allSatisfy({ _imageFileExists($0.imagePath) }) {
            return true
        }
        return false
    }

    private static func _textbookOriginalExplanationFileName(paperKey: String) -> String {
        "\(paperKey).original_explanation.txt"
    }

    private static func _textbookOriginalExplanationURL(paperKey: String, kcDir: URL) -> URL {
        kcDir.appendingPathComponent(_textbookOriginalExplanationFileName(paperKey: paperKey))
    }

    private static func _hasCurrentOverview(paperKey: String, kcDir: URL) -> Bool {
        let url = kcDir.appendingPathComponent("\(paperKey).abstract.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return Inf6AssetsAbstractPipeline.overviewMeetsCurrentContract(text)
    }

    private static func _hasCurrentTextbookOriginalExplanation(paperKey: String, kcDir: URL) -> Bool {
        let url = _textbookOriginalExplanationURL(paperKey: paperKey, kcDir: kcDir)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return Inf6AssetsAbstractPipeline.overviewMeetsCurrentContract(text)
    }

    private static func _localPDFURL(for entry: DrillEntry) async throws -> _ResolvedPDF {
        if let local = entry.pdfURL, _pdfMatchesPaper(at: local, paper: entry.paper) {
            return _ResolvedPDF(url: local, sourceWasReplaced: false)
        }
        // 取り込みと同じ場所を使う。別々にすると同じ論文を二重に持つ。
        let root = try Inf6PaperSaveShared.defaultToolsPapersDirectoryURL()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileName = try Inf6PaperSaveShared.safeFileName(
            title: entry.paper.title,
            fallbackID: entry.paper.arxivId ?? entry.paper.id
        )
        let dest = root.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: dest.path),
           _pdfMatchesPaper(at: dest, paper: entry.paper) {
            return _ResolvedPDF(url: dest, sourceWasReplaced: false)
        }

        // ローカルに無ければ、取得済みPDFは存在しない。
        let candidates = try await _candidateRemotePDFURLs(for: entry)
        guard !candidates.isEmpty else {
            throw _failure(
                entry: entry,
                operation: "resolve_remote_pdf",
                kind: .paperURLResolution,
                cause: "決定論的なPDF候補URLを特定できませんでした。",
                plan: ["代表論文URLを確認する", "論文メタデータの pdf_url/arxiv_id を確認する", "source manifest が許可する取得先だけを確認する"],
                attempts: []
            )
        }
        let downloaded: _PDFDownloadResult
        do {
            downloaded = try await _downloadFirstValidPDF(from: candidates, entry: entry)
        } catch let failure as DrillPipelineError {
            throw failure
        } catch {
            throw _failure(
                entry: entry,
                operation: "download_pdf",
                kind: _failureKind(from: error),
                cause: error.localizedDescription,
                plan: ["候補URLを順にHTTP取得する", "HTTP status / MIME / %PDF magic header を検証する", "検証済みPDFだけを保存する"],
                attempts: []
            )
        }
        do {
            try await _withMetadataWrite {
                try downloaded.data.write(to: dest, options: [.atomic])
            }
        } catch {
            throw _failure(
                entry: entry,
                operation: "persist_pdf",
                kind: .pdfPersistence,
                cause: error.localizedDescription,
                plan: ["検証済みPDFデータを一時ファイルへatomic保存する", "保存完了後にPDF登録通知を送る"],
                attempts: downloaded.attempts,
                underlying: error
            )
        }
        NotificationCenter.default.post(name: .inf6PaperPDFDidSave, object: nil, userInfo: ["pdfURL": dest])
        return _ResolvedPDF(url: dest, sourceWasReplaced: true)
    }

    private static func _candidateRemotePDFURLs(for entry: DrillEntry) async throws -> [URL] {
        // 取得元は既存の「ソース設定」に従う。ここに別の設定を作らない。
        let enabledSourceIDs = Set(Inf6PaperSourceSelection.enabledSources())

        var candidates: [URL] = []
        if let remote = entry.downloadURL {
            candidates.append(remote)
        }
        if let direct = _remotePDFURL(for: entry.paper) {
            candidates.append(direct)
        }
        if enabledSourceIDs.contains(.arxiv) {
            do {
                if let arxiv = try await _resolveArxivPDFURL(for: entry.paper) {
                    candidates.append(arxiv)
                }
            } catch {
                NSLog("[DrillPipeline] arXiv candidate lookup failed for %@: %@; continuing with other sources",
                      entry.paper.title, error.localizedDescription)
            }
        }
        return _uniqueURLs(candidates)
    }

    private static func _resolveArxivPDFURL(for paper: Inf6CorePaper) async throws -> URL? {
        // arXiv 由来の手がかりが何も無い論文を、タイトルで探しても見つからない。
        // Springer などの論文まで毎回照会すると、無駄に負荷をかけて 429 を招く。
        let ids = _arxivIDCandidates(for: paper)
        if ids.isEmpty && (paper.arxivId?.isEmpty ?? true) {
            let provider = paper.provider.lowercased()
            if !provider.contains("arxiv") {
                NSLog("[DrillPipeline] no arXiv hint for %@ (provider=%@); skipping arXiv lookup",
                      paper.title, paper.provider)
                return nil
            }
        }
        for arxivID in ids {
            let results = try await Inf6ArxivClient.searchByID(arxivID: arxivID)
            if let pdf = results.first?.pdfURL {
                return _normalizedPDFDownloadURL(pdf) ?? pdf
            }
        }

        let titles = [paper.title, paper.titleEn ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !titles.isEmpty else { return nil }

        var results: [Inf6PaperSearchResult] = []
        for title in titles {
            let quotedTitle = title.replacingOccurrences(of: "\"", with: "")
            results += try await Inf6ArxivClient.search(
                query: "ti:\"\(quotedTitle)\"",
                maxResults: 5,
                sortBy: "relevance",
                sortOrder: "descending"
            )
        }
        if results.isEmpty {
            for title in titles {
                let quotedTitle = title.replacingOccurrences(of: "\"", with: "")
                results += try await Inf6ArxivClient.search(
                    query: "all:\"\(quotedTitle)\"",
                    maxResults: 5,
                    sortBy: "relevance",
                    sortOrder: "descending"
                )
            }
        }

        let targets = Set(titles.map(_normalizedTitle))
        let selected = results.first { result in
            targets.contains(_normalizedTitle(result.title))
        }
        guard let pdf = selected?.pdfURL else { return nil }
        return _normalizedPDFDownloadURL(pdf) ?? pdf
    }

    private static func _doiCandidate(for paper: Inf6CorePaper) -> String? {
        let values = [paper.id, paper.pdfURL, paper.titleEn]
        for value in values.compactMap({ $0 }) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("doi:") {
                return String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let range = trimmed.range(of: #"10\.\d{4,9}/[^\s]+"#, options: .regularExpression) {
                return String(trimmed[range]).trimmingCharacters(in: CharacterSet(charactersIn: " .。),]"))
            }
        }
        return nil
    }

    private static func _downloadFirstValidPDF(from candidates: [URL], entry: DrillEntry) async throws -> _PDFDownloadResult {
        var attempts: [ResolutionAttempt] = []
        var lastKind: FailureKind = .paperURLResolution
        var lastMessage = "PDF候補URLがありません。"

        for url in candidates {
            do {
                let data = try await _downloadValidatedPDFData(from: url)
                guard _pdfDataMatchesPaper(data, paper: entry.paper) else {
                    let mismatch = _pdfIdentityMismatchMessage(data: data, paper: entry.paper)
                    lastKind = .pdfIdentity
                    lastMessage = mismatch
                    attempts.append(ResolutionAttempt(stage: "pdf_identity", target: url.absoluteString, result: mismatch))
                    continue
                }
                attempts.append(ResolutionAttempt(stage: "pdf_probe", target: url.absoluteString, result: "ok application/pdf %PDF bytes=\(data.count)"))
                return _PDFDownloadResult(url: url, data: data, attempts: attempts)
            } catch let failure as _PDFCandidateFailure {
                lastKind = failure.kind
                lastMessage = failure.message
                attempts.append(ResolutionAttempt(stage: "pdf_probe", target: url.absoluteString, result: failure.message))
            } catch {
                lastKind = _failureKind(from: error)
                lastMessage = error.localizedDescription
                attempts.append(ResolutionAttempt(stage: "pdf_probe", target: url.absoluteString, result: error.localizedDescription))
            }
        }

        throw _failure(
            entry: entry,
            operation: "download_pdf",
            kind: lastKind,
            cause: lastMessage,
            plan: ["候補URLを順にHTTP取得する", "HTTP status / MIME / %PDF magic header を検証する", "PDFの書誌同一性を検証する", "検証済みPDFだけを保存する"],
            attempts: attempts
        )
    }

    private static func _pdfMatchesPaper(at url: URL, paper: Inf6CorePaper) -> Bool {
        guard let data = Inf6SafeFileRead.dataIfReadable(at: url) else { return false }
        return _pdfDataMatchesPaper(data, paper: paper)
    }

    private static func _pdfDataMatchesPaper(_ data: Data, paper: Inf6CorePaper) -> Bool {
        guard data.count >= 5,
              String(data: data.prefix(5), encoding: .ascii) == "%PDF-",
              let document = PDFDocument(data: data)
        else { return false }

        let metadataTitle = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? ""
        let firstPages = (0..<min(document.pageCount, 2))
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
        let observed = "\(metadataTitle)\n\(firstPages)"
        let observedTokens = Set(_identityTokens(observed))
        let expectedTitles = [paper.titleEn, paper.title]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return expectedTitles.contains { title in
            let expectedTokens = _identityTokens(title)
            guard !expectedTokens.isEmpty else { return false }
            return expectedTokens.allSatisfy { observedTokens.contains($0) }
        }
    }

    private static func _pdfIdentityMismatchMessage(data: Data, paper: Inf6CorePaper) -> String {
        let observedTitle: String
        if let document = PDFDocument(data: data) {
            observedTitle = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            observedTitle = "unreadable"
        }
        let expectedTitle = [paper.titleEn, paper.title]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? paper.id
        return "PDFの書誌同一性検証に失敗しました: expected=\"\(expectedTitle)\" metadata_title=\"\(observedTitle.isEmpty ? "nil" : observedTitle)\" bytes=\(data.count)"
    }

    private static func _identityTokens(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 2 && !["and", "for", "the", "with", "from", "into", "using", "used", "use", "a", "an"].contains($0) }
    }

    private static func _downloadValidatedPDFData(from url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 45
        // User-Agent は既定のままにする。ブラウザを装うと、出版社サイトは
        // 同意ページのHTMLを返す。実測では Springer が同じURLに対し、
        // Safari の体裁には 3KB のHTMLを、既定の体裁には 1.5MB のPDFを返した。
        req.setValue("application/pdf,application/octet-stream;q=0.9,*/*;q=0.1", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw _PDFCandidateFailure(kind: .pdfHTTP, message: "通信失敗: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw _PDFCandidateFailure(kind: .pdfHTTP, message: "HTTP応答ではありません。")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw _PDFCandidateFailure(kind: .pdfHTTP, message: "HTTP \(http.statusCode)")
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? response.mimeType ?? "")
            .lowercased()
        let magic = data.count >= 5 ? String(data: data.prefix(5), encoding: .ascii) ?? "" : ""
        guard magic == "%PDF-" else {
            let kind: FailureKind = contentType.contains("pdf") ? .pdfMagic : .pdfMIME
            let prefix = String(data: data.prefix(80), encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw _PDFCandidateFailure(
                kind: kind,
                message: "PDF不一致 status=\(http.statusCode) mime=\(contentType.isEmpty ? "nil" : contentType) magic=\(magic.isEmpty ? "nil" : magic) bytes=\(data.count) prefix=\(prefix)"
            )
        }
        if !contentType.isEmpty,
           !contentType.contains("pdf"),
           !contentType.contains("octet-stream") {
            throw _PDFCandidateFailure(
                kind: .pdfMIME,
                message: "MIME不一致 status=\(http.statusCode) mime=\(contentType) magic=%PDF bytes=\(data.count)"
            )
        }
        return data
    }

    private static func _uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for url in urls {
            let key = url.absoluteString
            guard seen.insert(key).inserted else { continue }
            out.append(url)
        }
        return out
    }

    private static func _arxivIDCandidates(for paper: Inf6CorePaper) -> [String] {
        var out: [String] = []
        func add(_ raw: String?) {
            guard let raw, let id = _extractArxivID(raw) else { return }
            if !out.contains(id) { out.append(id) }
        }
        add(paper.arxivId)
        add(paper.id)
        add(paper.pdfURL)
        return out
    }

    private static func _extractArxivID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.host?.lowercased().contains("arxiv.org") == true {
            // 旧形式のIDは archive/YYMMNNN の形で、接頭辞まで含めて一つのIDである。
            // 末尾要素だけを取ると cond-mat/9811421v2 が 9811421v2 になり、
            // 存在しないIDとして毎回照会に失敗する。abs/ または pdf/ の後ろを
            // すべて残す。
            let parts = url.path.split(separator: "/").map(String.init)
            let markers: Set<String> = ["abs", "pdf"]
            let tail: [String]
            if let markerIndex = parts.firstIndex(where: { markers.contains($0.lowercased()) }) {
                tail = Array(parts[(markerIndex + 1)...])
            } else if let last = parts.last {
                tail = [last]
            } else {
                tail = []
            }
            guard !tail.isEmpty else { return nil }
            let id = tail.joined(separator: "/").replacingOccurrences(of: ".pdf", with: "")
            return id.isEmpty ? nil : id
        }
        let cleaned = trimmed
            .replacingOccurrences(of: "arxiv:", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: ".pdf", with: "")
        let allowed = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-_/")
        guard cleaned.rangeOfCharacter(from: allowed.inverted) == nil else { return nil }
        return cleaned.contains("/") || cleaned.contains(".") ? cleaned : nil
    }

    private static func _normalizedTitle(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func diagnosticMessage(for report: FailureReport) -> String {
        var lines: [String] = []
        lines.append("\(report.paperTitle)")
        lines.append("工程: \(report.operation)")
        lines.append("原因分類: \(report.kind.rawValue)")
        lines.append("原因: \(report.cause)")
        if !report.plan.isEmpty {
            lines.append("解決計画: \(report.plan.joined(separator: " -> "))")
        }
        if !report.attempts.isEmpty {
            lines.append("検証:")
            for attempt in report.attempts {
                lines.append("- \(attempt.stage) \(attempt.target): \(attempt.result)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func _failure(
        entry: DrillEntry,
        operation: String,
        kind: FailureKind,
        cause: String,
        plan: [String],
        attempts: [ResolutionAttempt],
        underlying: Error? = nil
    ) -> DrillPipelineError {
        DrillPipelineError(
            report: FailureReport(
                operation: operation,
                paperID: entry.paper.id,
                paperTitle: entry.paper.title,
                kind: kind,
                cause: cause,
                plan: plan,
                attempts: attempts
            ),
            underlying: underlying
        )
    }

    private static func _failureKind(from error: Error) -> FailureKind {
        if isCancellation(error) { return .cancelled }
        if let candidate = error as? _PDFCandidateFailure { return candidate.kind }
        if error is _EntityExtractionFailure { return .entityExtraction }
        if let drill = error as? DrillPipelineError { return drill.report.kind }
        if _isOpenAIRateLimit(error) { return .openAIRateLimit }
        if _isArxivRateLimit(error) { return .arxivRateLimit }
        if error is OpenAIError { return .openAI }
        let message = error.localizedDescription.lowercased()
        if message.contains("origin") || message.contains("起源") { return .originUnverified }
        if message.contains("json") { return .modelStructuredOutput }
        if message.contains("pdf") && message.contains("open") { return .pdfRead }
        if message.contains("pdf") { return .pdfMagic }
        return .unknown
    }

    static func shouldStopBatchAfterFailure(_ error: Error) -> Bool {
        _isOpenAIRateLimit(error) || _isArxivRateLimit(error)
    }

    static func diagnosticMessage(entry: DrillEntry, operation: String, error: Error) -> String {
        if let drillError = error as? DrillPipelineError {
            return diagnosticMessage(for: drillError.report)
        }
        let kind = _failureKind(from: error)
        let plan: [String]
        switch kind {
        case .openAIRateLimit:
            plan = ["OpenAI provider の 429 を記録する", "この対象の生成を停止する", "ユーザーの明示操作があるまで再実行しない"]
        case .arxivRateLimit:
            plan = ["arXiv の 429 を記録する", "この対象の生成を停止する", "送信間隔を空けてから再実行する"]
        case .openAI:
            plan = ["OpenAI provider の code/type/message を記録する", "対象工程を停止する", "原因解消後にユーザー操作で再実行する"]
        default:
            plan = []
        }
        return diagnosticMessage(for: FailureReport(
            operation: operation,
            paperID: entry.paper.id,
            paperTitle: entry.paper.title,
            kind: kind,
            cause: error.localizedDescription,
            plan: plan,
            attempts: []
        ))
    }

    static func displayMessage(entry: DrillEntry, error: Error) -> String {
        guard let drillError = error as? DrillPipelineError else {
            return error.localizedDescription
        }
        switch drillError.report.kind {
        case .paperURLResolution, .pdfHTTP, .pdfMIME, .pdfMagic, .pdfPersistence, .pdfRead, .pdfIdentity, .pdfTextExtraction:
            return "\(entry.paper.title): 論文PDFを取得・検証できません。"
        default:
            return drillError.report.cause
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let openAI = error as? OpenAIError,
           case .cancelled = openAI {
            return true
        }
        if let drill = error as? DrillPipelineError {
            return drill.report.kind == .cancelled || drill.underlying.map(isCancellation) == true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private static func _isOpenAIRateLimit(_ error: Error) -> Bool {
        if let drill = error as? DrillPipelineError {
            return drill.report.kind == .openAIRateLimit || drill.underlying.map(_isOpenAIRateLimit) == true
        }
        if let openAI = error as? OpenAIError,
           case .httpError(let statusCode, _, _, _) = openAI,
           statusCode == 429 {
            return true
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("openai: http 429") || message.contains("openai provider") && message.contains("429")
    }

    private static func _isArxivRateLimit(_ error: Error) -> Bool {
        if let drill = error as? DrillPipelineError {
            return drill.report.kind == .arxivRateLimit || drill.underlying.map(_isArxivRateLimit) == true
        }
        if let arxiv = error as? Inf6ArxivClientError,
           case .badStatus(let code, _) = arxiv,
           code == 429 {
            return true
        }
        // 文言からも拾う。arXiv の 429 は "HTTP error 429: ..." として上がってくる。
        return error.localizedDescription.lowercased().contains("http error 429")
    }

    private static func _askModelWithLedger(
        prompt: String,
        targetID: String,
        featureName: String,
        askModel: @escaping (String) async throws -> String
    ) async throws -> String {
        let inputData = Data(prompt.utf8)
        let inputHash = SHA256.hash(data: inputData).map { String(format: "%02x", $0) }.joined()
        let modelID = "openai_configured"
        let inFlightKey = "\(targetID)|\(featureName)|\(inputHash)|\(modelID)"
        try await _llmInvocationGate.enter(inFlightKey, featureName: featureName, targetID: targetID, inputHash: inputHash)
        if Task.isCancelled {
            await _llmInvocationGate.leave(inFlightKey)
            throw CancellationError()
        }

        var record = _LLMInvocationRecord(
            id: UUID().uuidString,
            targetID: targetID,
            inputHash: inputHash,
            modelID: modelID,
            featureName: featureName,
            startedAt: Date().timeIntervalSince1970,
            finishedAt: nil,
            status: "started",
            inputBytes: inputData.count,
            outputBytes: nil,
            errorMessage: nil
        )
        try await _storeLLMLedger(record)
        do {
            let output = try await askModel(prompt)
            record.finishedAt = Date().timeIntervalSince1970
            record.status = "succeeded"
            record.outputBytes = Data(output.utf8).count
            try await _storeLLMLedger(record)
            await _llmInvocationGate.leave(inFlightKey)
            return output
        } catch {
            record.finishedAt = Date().timeIntervalSince1970
            record.status = _isOpenAIRateLimit(error) ? "rate_limited" : "failed"
            record.errorMessage = error.localizedDescription
            try? await _storeLLMLedger(record)
            await _llmInvocationGate.leave(inFlightKey)
            throw error
        }
    }

    static func startExecutionLedger(entry: DrillEntry) async throws -> String {
        let id = UUID().uuidString
        let input = [
            entry.id,
            entry.paper.id,
            entry.paper.title,
            entry.folderKey,
            entry.syllabusNodeID ?? ""
        ].joined(separator: "\n")
        let record = ExecutionRecord(
            id: id,
            targetID: entry.folderKey,
            featureName: "eshikaku_intensive_drill_entry",
            startedAt: Date().timeIntervalSince1970,
            finishedAt: nil,
            status: "started",
            inputBytes: Data(input.utf8).count,
            outputBytes: nil,
            errorMessage: nil
        )
        try await _storeExecutionLedger(record)
        return id
    }

    static func finishExecutionLedger(id: String, entry: DrillEntry, quiz: Inf6PaperQuiz?) async {
        let outputBytes: Int? = quiz.flatMap { quiz in
            (try? JSONEncoder().encode(quiz)).map(\.count)
        }
        let record = ExecutionRecord(
            id: id,
            targetID: entry.folderKey,
            featureName: "eshikaku_intensive_drill_entry",
            startedAt: Date().timeIntervalSince1970,
            finishedAt: Date().timeIntervalSince1970,
            status: "succeeded",
            inputBytes: Data(entry.id.utf8).count,
            outputBytes: outputBytes,
            errorMessage: nil
        )
        try? await _storeExecutionLedger(record)
    }

    static func failExecutionLedger(id: String, entry: DrillEntry, status: String, error: Error) async {
        let record = ExecutionRecord(
            id: id,
            targetID: entry.folderKey,
            featureName: "eshikaku_intensive_drill_entry",
            startedAt: Date().timeIntervalSince1970,
            finishedAt: Date().timeIntervalSince1970,
            status: status,
            inputBytes: Data(entry.id.utf8).count,
            outputBytes: nil,
            errorMessage: error.localizedDescription
        )
        try? await _storeExecutionLedger(record)
    }

    private static func _storeLLMLedger(_ record: _LLMInvocationRecord) async throws {
        try await _withMetadataWrite {
            guard Inf6MetadataStore.putCodable(
                record,
                domain: .settings,
                key: "drill_llm_invocation:\(record.id)"
            ) else {
                throw NSError(domain: "Inf6DrillLedger", code: 41, userInfo: [
                    NSLocalizedDescriptionKey: "LLM実行台帳を保存できませんでした: \(record.id)"
                ])
            }
        }
    }

    private static func _storeExecutionLedger(_ record: ExecutionRecord) async throws {
        try await _withMetadataWrite {
            guard Inf6MetadataStore.putCodable(
                record,
                domain: .settings,
                key: "drill_execution:\(record.id):\(record.status)"
            ) else {
                throw NSError(domain: "Inf6DrillLedger", code: 42, userInfo: [
                    NSLocalizedDescriptionKey: "実行台帳を保存できませんでした: \(record.id)"
                ])
            }
        }
    }

    private static func _storeOriginExplorationRecord(_ record: _OriginExplorationRecord) async throws {
        try await _withMetadataWrite {
            guard Inf6MetadataStore.putCodable(
                record,
                domain: .settings,
                key: "origin_exploration:\(record.id):\(record.status)"
            ) else {
                throw NSError(domain: "Inf6OriginResolution", code: 43, userInfo: [
                    NSLocalizedDescriptionKey: "起源監査記録を保存できませんでした: \(record.id)"
                ])
            }
        }
    }

    private static func _withMetadataWrite<T>(_ body: () throws -> T) async throws -> T {
        try await _metadataWriteGate.acquire()
        do {
            let value = try body()
            await _metadataWriteGate.release()
            return value
        } catch {
            await _metadataWriteGate.release()
            throw error
        }
    }

    private static func _loadSyllabusPaperLinks(sourceFamily: String) -> [String: [Inf6SyllabusPaperLink]] {
        var grouped: [String: [Inf6SyllabusPaperLink]] = [:]
        for row in Inf6MetadataStore.listByPrefix(domain: .syllabusPaperLinks, prefix: "\(sourceFamily)|") {
            guard let data = row.json.data(using: .utf8),
                  let link = try? JSONDecoder().decode(Inf6SyllabusPaperLink.self, from: data)
            else { continue }
            grouped[link.syllabusNodeID, default: []].append(link)
        }
        for key in grouped.keys {
            grouped[key]?.sort {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.paperID.localizedStandardCompare($1.paperID) == .orderedAscending
            }
        }
        return grouped
    }

    private static func _artifactLookupAliases(
        folderKey: String,
        titleKey: String,
        titleEnKey: String,
        paperID: String
    ) -> Set<String> {
        var aliases = Set([folderKey, titleKey, titleEnKey].filter { !$0.isEmpty })
        let stablePaperIDKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paperID)
        if !stablePaperIDKey.isEmpty {
            aliases.insert(stablePaperIDKey)
        }
        return aliases
    }

    private static func _findStoredArtifact<T>(
        in records: [(key: String, value: T)],
        aliases: Set<String>,
        stablePaperIDKey: String,
        artifactKey: (T) -> String,
        artifactTitle: (T) -> String
    ) -> T? {
        if !stablePaperIDKey.isEmpty,
           let stable = records.first(where: { record in
               let rawKey = artifactKey(record.value)
               let normalizedKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: rawKey)
               return record.key == stablePaperIDKey
                   || rawKey == stablePaperIDKey
                   || normalizedKey == stablePaperIDKey
                   || normalizedKey.hasSuffix("_\(stablePaperIDKey)")
           }) {
            return stable.value
        }

        if let exact = records.first(where: { record in
            let storedAliases = Set([
                record.key,
                artifactKey(record.value),
                Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: artifactKey(record.value)),
                Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: artifactTitle(record.value))
            ].filter { !$0.isEmpty })
            return !aliases.isDisjoint(with: storedAliases)
        }) {
            return exact.value
        }

        return nil
    }

    static func storedPaperArtifactKey(for paper: Inf6CorePaper) -> String? {
        let aliases = Set([
            paper.id,
            paper.title,
            paper.titleEn ?? "",
            paper.resolvedPDFURL?.lastPathComponent ?? ""
        ].map { Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: $0) }
            .filter { !$0.isEmpty })
        guard !aliases.isEmpty else { return nil }

        return Inf6MetadataStore.listAllCodable(Inf6PaperQuiz.self, domain: .quiz)
            .first { record in
                let stored = Set([
                    record.key,
                    record.value.paperKey,
                    record.value.paperTitle
                ].map { Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: $0) }
                    .filter { !$0.isEmpty })
                return aliases.contains { alias in
                    stored.contains { value in
                        value == alias || value.hasSuffix("_\(alias)")
                    }
                }
            }?.key
    }

    private static func _selectCorePaperForNode(
        node: Inf6KnowledgeNode,
        domainPrefix: String,
        domainLabelJa: String,
        domainLabelEn: String,
        sourceFamily: String,
        structurePaperIDs: [String],
        searchLinks: [Inf6SyllabusPaperLink],
        papersByID: [String: Inf6CorePaper],
        storedPaperIDs: Set<String>
    ) throws -> [_OriginPaperSelection] {
        func providerIsAllowed(_ paper: Inf6CorePaper) -> Bool {
            let provider = paper.provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if sourceFamily == "jdla_eshikaku" {
                return ["arxiv", "pubmed", "pdf_import"].contains(provider)
                    || isGeneratedExplanationProvider(provider)
            }
            return !provider.isEmpty && !isGeneratedExplanationProvider(provider) && provider != "openalex"
        }
        func linkIsVerifiedOrigin(_ link: Inf6SyllabusPaperLink, paper: Inf6CorePaper) -> Bool {
            let provider = paper.provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let role = link.sourceRole?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let status = link.verificationStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let historyOK = !(link.originHistory ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let evidenceOK = !(link.verificationEvidence ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard historyOK, evidenceOK, link.originRecordVersion == 1 else { return false }
            if isGeneratedExplanationProvider(provider) {
                return role == _generatedExplanationRoleID
                    && status == _generatedExplanationStatusID
            }
            return role == "origin"
                && status == "source_verified"
                && paper.year != nil
        }

        let candidatePaperIDs = node.linkedPaperIDs + structurePaperIDs.filter { !node.linkedPaperIDs.contains($0) }
        let candidateIDs = (candidatePaperIDs + searchLinks.map(\.paperID)).reduce(into: [String]()) { result, paperID in
            guard !paperID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !result.contains(paperID)
            else { return }
            result.append(paperID)
        }
        // 表示用プレビューは常に最新の searchLinks(syllabus_paper_links を直接読んだ値)だけを使う。
        // structurePaperIDs/node.linkedPaperIDs はキャッシュされた構造データに由来し、
        // 起源レコードを削除しても即座に反映されないため、削除後に古い論文名が残る原因になる。
        let candidates = searchLinks.map(\.paperID).reduce(into: [String]()) { result, paperID in
            guard !result.contains(paperID) else { return }
            result.append(paperID)
        }.compactMap { paperID -> String? in
            guard storedPaperIDs.contains(paperID),
                  let paper = papersByID[paperID],
                  providerIsAllowed(paper),
                  let year = paper.year
            else { return nil }
            let title = paper.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return "\(title) (\(year))"
        }.prefix(3).map { $0 }

        if !searchLinks.isEmpty {
            NSLog("[DrillPipeline] _selectCore node=%@ searchLinks=%d", node.nodeID, searchLinks.count)
            for sl in searchLinks {
                let roleRaw = sl.sourceRole?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let roleOK = roleRaw == "origin" || roleRaw == _generatedExplanationRoleID
                let histOK = !(sl.originHistory ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let statusRaw = sl.verificationStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let statusOK = ["source_verified", "metadata_verified"].contains(statusRaw)
                    || statusRaw == _generatedExplanationStatusID
                let evidOK = !(sl.verificationEvidence ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let verOK = sl.originRecordVersion == 1
                let inStore = storedPaperIDs.contains(sl.paperID)
                let inMap = papersByID[sl.paperID] != nil
                let paper = papersByID[sl.paperID]
                let providerOK = paper.map(providerIsAllowed) ?? false
                let yearOK = paper?.year != nil
                NSLog("[DrillPipeline]   link paperID=%@ role=%d hist=%d status=%d evid=%d ver=%d inStore=%d inMap=%d provider=%d year=%d",
                      sl.paperID, roleOK ? 1 : 0, histOK ? 1 : 0, statusOK ? 1 : 0, evidOK ? 1 : 0, verOK ? 1 : 0,
                      inStore ? 1 : 0, inMap ? 1 : 0, providerOK ? 1 : 0, yearOK ? 1 : 0)
            }
        }
        var selections: [_OriginPaperSelection] = []
        for link in searchLinks {
            guard storedPaperIDs.contains(link.paperID),
                  let paper = papersByID[link.paperID],
                  providerIsAllowed(paper),
                  linkIsVerifiedOrigin(link, paper: paper)
            else { continue }
            let downloadURL = _remotePDFURL(for: paper)
            let plannedFileName = try _plannedArtifactFileName(for: paper)
            selections.append(.selected(_SelectedCorePaper(
                paper: paper, link: link, localPDF: nil,
                downloadURL: downloadURL, plannedFileName: plannedFileName, originScore: link.score
            )))
        }
        if !selections.isEmpty {
            selections.sort { lhs, rhs in
                guard case .selected(let left) = lhs, case .selected(let right) = rhs else { return false }
                let leftGenerated = isGeneratedExplanationProvider(left.paper.provider)
                let rightGenerated = isGeneratedExplanationProvider(right.paper.provider)
                if leftGenerated != rightGenerated { return !leftGenerated && rightGenerated }

                let leftYear = left.paper.year ?? Int.max
                let rightYear = right.paper.year ?? Int.max
                if leftYear != rightYear { return leftYear < rightYear }

                let leftTitle = left.paper.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let rightTitle = right.paper.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let titleOrder = leftTitle.localizedStandardCompare(rightTitle)
                if titleOrder != .orderedSame { return titleOrder == .orderedAscending }

                return left.paper.id.localizedStandardCompare(right.paper.id) == .orderedAscending
            }
        }
        guard selections.isEmpty else { return selections }

        let reason: String
        if candidateIDs.isEmpty {
            reason = "起源理解が未解決です。"
        } else {
            reason = "候補論文の役割と起源履歴が未解決です。"
        }

        return [.unverified(_knowledgeFormationIssue(
            node: node,
            domainPrefix: domainPrefix,
            domainLabelJa: domainLabelJa,
            domainLabelEn: domainLabelEn,
            candidates: Array(candidates),
            reason: reason,
            plan: [
                "explore_origin_history: LLMで概念史と候補論文の役割を構造化する",
                "deterministic_source_verify: source manifest が許可する Provider / Content Provider だけを実測検証する",
                "persist_origin_record: 検証済み origin_history と source role を正本 metadata に保存する",
                "continue_same_generation: 検証済み根拠で同じ生成工程を継続する",
            ]
        ))]
    }

    private static func _knowledgeFormationIssue(
        node: Inf6KnowledgeNode,
        domainPrefix: String,
        domainLabelJa: String,
        domainLabelEn: String,
        candidates: [String],
        reason: String,
        plan: [String]
    ) -> OriginUnverifiedItem {
        OriginUnverifiedItem(
            id: node.nodeID,
            nodeID: node.nodeID,
            titleJa: node.titleJa,
            titleEn: node.titleEn,
            domainPrefix: domainPrefix,
            domainLabelJa: domainLabelJa,
            domainLabelEn: domainLabelEn,
            candidates: candidates,
            reason: reason,
            plan: plan
        )
    }

    private static func _extractJSONObject(from raw: String) -> String? {
        var start: String.Index?
        var depth = 0
        var inString = false
        var escaped = false
        for index in raw.indices {
            let ch = raw[index]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
                continue
            }
            if ch == "\"" {
                inString = true
            } else if ch == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if ch == "}" {
                guard depth > 0 else { return nil }
                depth -= 1
                if depth == 0, let start {
                    return String(raw[start...index])
                }
            }
        }
        return nil
    }

    private static func _jsonDecodingFailureDescription(_ error: Error) -> String {
        switch error {
        case let DecodingError.keyNotFound(key, context):
            return "必須キー \(key.stringValue) がありません（\(context.codingPath.map(\.stringValue).joined(separator: "."))）"
        case let DecodingError.typeMismatch(_, context):
            return "値の型が不正です（\(context.codingPath.map(\.stringValue).joined(separator: "."))）"
        case let DecodingError.valueNotFound(_, context):
            return "必須値がありません（\(context.codingPath.map(\.stringValue).joined(separator: "."))）"
        case let DecodingError.dataCorrupted(context):
            return "JSONが壊れています（\(context.codingPath.map(\.stringValue).joined(separator: "."))）"
        default:
            return error.localizedDescription
        }
    }

    private static func _originResolutionError(
        item: OriginUnverifiedItem,
        cause: String,
        plan: [String],
        underlying: Error? = nil
    ) -> DrillPipelineError {
        DrillPipelineError(
            report: FailureReport(
                operation: "explore_origin_history",
                paperID: item.nodeID,
                paperTitle: item.titleJa.isEmpty ? item.titleEn : item.titleJa,
                kind: .originUnverified,
                cause: cause,
                plan: plan,
                attempts: []
            ),
            underlying: underlying
        )
    }

    private static func _structurePaperIDsByNodeID(_ structure: Inf6KnowledgeDomainStructure) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for paper in structure.papers {
            let paperID = paper.paperID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paperID.isEmpty else { continue }
            for nodeID in paper.syllabusNodeIDs {
                let trimmedNodeID = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedNodeID.isEmpty else { continue }
                if !(result[trimmedNodeID] ?? []).contains(paperID) {
                    result[trimmedNodeID, default: []].append(paperID)
                }
            }
        }
        return result
    }

    private static func _remotePDFURL(for paper: Inf6CorePaper) -> URL? {
        if let raw = paper.pdfURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let url = URL(string: raw),
           url.scheme?.lowercased().hasPrefix("http") == true {
            return _normalizedPDFDownloadURL(url)
        }
        if let arxivID = paper.arxivId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !arxivID.isEmpty {
            return URL(string: "https://arxiv.org/pdf/\(arxivID).pdf")
        }
        return nil
    }

    private static func _normalizedPDFDownloadURL(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased() else { return url }
        if host.hasSuffix("arxiv.org") {
            let parts = url.path.split(separator: "/").map(String.init)
            if let last = parts.last, !last.isEmpty {
                let id = last.replacingOccurrences(of: ".pdf", with: "")
                return URL(string: "https://arxiv.org/pdf/\(id).pdf")
            }
        }
        return url
    }

    // MARK: - Private: シラバスリーフノード取得

    private static func _loadKnowledgeStructureOrThrow(sourceFamily: String) throws -> Inf6KnowledgeDomainStructure {
        guard let manifest = Inf6LearningFamilyManifestStore.loadCurrentSyllabusDomains()
            .first(where: { $0.sourceFamily == sourceFamily })
        else {
            throw NSError(domain: "Inf6EshikakuDrillPipeline", code: 101, userInfo: [
                NSLocalizedDescriptionKey: "E資格集中特訓に必要な current family_manifest が見つかりません: \(sourceFamily)"
            ])
        }

        let outlineItems = try Inf6SyllabusConceptSetSynchronizer.currentOutlineItemsForPaperSearch(for: manifest)
        guard !outlineItems.isEmpty else {
            throw NSError(domain: "Inf6EshikakuDrillPipeline", code: 102, userInfo: [
                NSLocalizedDescriptionKey: "E資格集中特訓に必要な検証済みシラバス outline cache が空です: \(sourceFamily)"
            ])
        }

        let syllabusVersionID = try Inf6KnowledgeDataStore
            .resolvedKnowledgeStructureVersionID(for: manifest)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !syllabusVersionID.isEmpty else {
            throw NSError(domain: "Inf6EshikakuDrillPipeline", code: 103, userInfo: [
                NSLocalizedDescriptionKey: "E資格集中特訓に必要な syllabus version が解決できません: \(sourceFamily)"
            ])
        }

        return try Inf6KnowledgeDomainStructureStore.loadOrSeed(
            manifest: manifest,
            syllabusVersionID: syllabusVersionID,
            domainTitleJa: manifest.displayNameJa,
            outlineItems: outlineItems,
            paperStore: Inf6CorePaperStore.shared
        )
    }

    private static func _leafSyllabusNodes(in structure: Inf6KnowledgeDomainStructure) -> [Inf6KnowledgeNode] {
        let parentIDs = Set(structure.nodes.compactMap { node -> String? in
            guard node.kind != .paper else { return nil }
            return node.parentNodeID
        })
        return structure.nodes
            .filter { node in
                node.kind != .domain &&
                node.kind != .syllabusVersion &&
                node.kind != .paper &&
                !parentIDs.contains(node.nodeID)
            }
            .sorted { $0.nodeID.localizedStandardCompare($1.nodeID) == .orderedAscending }
    }

    private static func _syllabusContext(
        for node: Inf6KnowledgeNode,
        nodesByID: [String: Inf6KnowledgeNode]
    ) -> String {
        var chain: [Inf6KnowledgeNode] = []
        var cursor: Inf6KnowledgeNode? = node
        while let current = cursor {
            chain.append(current)
            guard let parentID = current.parentNodeID else { break }
            cursor = nodesByID[parentID]
        }
        return chain.reversed().flatMap { item in
            [
                item.titleJa,
                item.titleEn,
                item.summaryJa,
                item.summaryEn
            ]
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    // MARK: - Private: タイトル抽出

    private static func _extractDisplayTitle(from filename: String) -> String {
        var name = filename
        if name.lowercased().hasSuffix(".pdf") { name = String(name.dropLast(4)) }
        if let range = name.range(of: "__") {
            name = String(name[name.startIndex..<range.lowerBound])
        }
        name = name.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return filename }
        if let r = name.range(of: #" \(\d+\)$"#, options: .regularExpression) {
            name = String(name[name.startIndex..<r.lowerBound])
        }
        return name
    }

    // MARK: - Private: 論文ストアマッチング

    private static func _buildPaperLookup(papers: [Inf6CorePaper]) -> [String: Inf6CorePaper] {
        var lookup: [String: Inf6CorePaper] = [:]
        for p in papers {
            let tk = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: p.title).lowercased()
            if !tk.isEmpty { lookup[tk] = p }
            if let en = p.titleEn {
                let ek = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: en).lowercased()
                if !ek.isEmpty { lookup[ek] = p }
            }
        }
        return lookup
    }

    private static func _findMatchingPaper(
        pdfFilename: String, displayTitle: String, lookup: [String: Inf6CorePaper]
    ) -> Inf6CorePaper? {
        let pdfKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: pdfFilename).lowercased()
        let titleKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: displayTitle).lowercased()
        if let p = lookup[titleKey] { return p }
        if let p = lookup[pdfKey] { return p }
        for (key, paper) in lookup {
            if key.count >= 10 && pdfKey.contains(key) { return paper }
            if key.count >= 10 && titleKey.contains(key) { return paper }
        }
        return nil
    }

    // MARK: - Private: KCフォルダ検索

    private static func _findKCFolder(titleKey: String, titleEnKey: String, in folders: Set<String>) -> String? {
        if titleKey.isEmpty && titleEnKey.isEmpty { return nil }
        for f in folders {
            if !titleKey.isEmpty && (f == titleKey || f.hasPrefix(titleKey + "_")) { return f }
            if !titleEnKey.isEmpty && (f == titleEnKey || f.hasPrefix(titleEnKey + "_")) { return f }
        }
        return nil
    }

    // MARK: - Entity Image Re-crop

    static func recutEntityImages(
        entry: DrillEntry,
        expansion: EntityCropExpansion,
        entityFilter: Set<Inf6DocEntityKind>? = nil
    ) async throws {
        #if canImport(UIKit)
        guard let pdfURL = _existingPDFURL(entry.pdfURL) ?? _findPDF(paperKey: entry.folderKey) else {
            throw NSError(
                domain: "Inf6EshikakuDrillPipeline",
                code: 43,
                userInfo: [NSLocalizedDescriptionKey: "再クロップ対象PDFが見つかりません: \(entry.folderKey)"]
            )
        }
        guard let doc = PDFDocument(url: pdfURL) else {
            throw NSError(
                domain: "Inf6EshikakuDrillPipeline",
                code: 44,
                userInfo: [NSLocalizedDescriptionKey: "再クロップ対象PDFを開けません: \(pdfURL.lastPathComponent)"]
            )
        }
        NSLog(
            "[LiveBP][CROP] start paper=%@ pdf=%@ pages=%d",
            entry.folderKey,
            pdfURL.lastPathComponent,
            doc.pageCount
        )
        let existingIndex = Inf6MetadataStore.getCodable(
            Inf6DocEntityIndex.self,
            domain: .docEntities,
            key: entry.folderKey
        )
        let existingEntities = existingIndex?.entities ?? []

        // 一括クロップは既存JSONの件数に依存せず、PDFを画像解析で再走査する。
        // 再クロップ後に同一エンティティのID・解説・設問参照を保持しつつ、
        // 部位と論文本文のLLM関連付けを検証して保存する。
        let scannedEntities = Inf6DocEntityScanner.scan(doc: doc)
            .filter { entityFilter?.contains($0.kind) ?? true }
        NSLog(
            "[LiveBP][CROP] scanned paper=%@ entities=%d figures=%d tables=%d equations=%d",
            entry.folderKey,
            scannedEntities.count,
            scannedEntities.filter { $0.kind == .figure }.count,
            scannedEntities.filter { $0.kind == .table }.count,
            scannedEntities.filter { $0.kind == .equation }.count
        )
        guard !scannedEntities.isEmpty else {
            throw NSError(
                domain: "Inf6EshikakuDrillPipeline",
                code: 49,
                userInfo: [NSLocalizedDescriptionKey: "PDFから図表・表・数式を検出できませんでした: \(entry.folderKey)"]
            )
        }
        var mutableEntities = scannedEntities
        NSLog("[LiveBP][CROP] image_analysis_started paper=%@ entities=%d", entry.folderKey, mutableEntities.count)
        try cropEntitiesFromPDF(
            pdfURL: pdfURL,
            doc: doc,
            paperKey: entry.folderKey,
            entities: &mutableEntities,
            expansion: expansion,
            reuseExistingImages: false,
            forceRecut: true
        )
        NSLog("[LiveBP][CROP] image_analysis_succeeded paper=%@ entities=%d parts=%d", entry.folderKey, mutableEntities.count, mutableEntities.reduce(0) { $0 + $1.parts.count })
        var paperAssociationSucceeded = false
        do {
            NSLog("[LiveBP][CROP] paper_text_association_started paper=%@ parts=%d", entry.folderKey, mutableEntities.reduce(0) { $0 + $1.parts.count })
            try await associatePartsWithPaperText(
                entities: &mutableEntities,
                pageTexts: _paperPageTexts(from: doc),
                paperKey: entry.folderKey,
                paperTitle: entry.paper.title,
                askModel: _partAssociationModel
            )
            paperAssociationSucceeded = true
            NSLog("[LiveBP][CROP] paper_text_association_succeeded paper=%@ parts=%d", entry.folderKey, mutableEntities.reduce(0) { $0 + $1.parts.count })
        } catch {
            if Self.isCancellation(error) {
                NSLog("[LiveBP][CROP] cancelled paper=%@", entry.folderKey)
                throw error
            }
            if (error as NSError).domain == "Inf6PaperTextTranslation" {
                NSLog("[LiveBP][CROP] translation_failed paper=%@ reason=%@", entry.folderKey, error.localizedDescription)
                throw error
            }
            NSLog("[LiveBP][CROP] paper_text_association_failed paper=%@ reason=%@", entry.folderKey, error.localizedDescription)
            // 画像クロップと本文関連付けは別成果物。画像は保存し、関連付けは未完了のまま保持する。
            NSLog("[LiveBP][CROP] paper-text association incomplete; image crop remains valid paper=%@ reason=%@", entry.folderKey, error.localizedDescription)
        }
        let replacedEntities = _replaceRecutEntities(
            existing: existingEntities,
            rescanned: mutableEntities
        )
        let entityIndex = Inf6DocEntityIndex(
            pdfKey: entry.folderKey,
            entities: replacedEntities
        )
        try _persistRecutResult(paperKey: entry.folderKey, entityIndex: entityIndex)
        let savedEntities = replacedEntities.filter { _imageFileExists($0.imagePath) }
        NSLog(
            "[LiveBP][CROP] saved paper=%@ generated=%d/%d replacedEntities=%d paperAssociation=%@",
            entry.folderKey,
            savedEntities.count,
            mutableEntities.count,
            replacedEntities.count,
            paperAssociationSucceeded ? "success" : "incomplete"
        )
        #endif
    }

    private static func _recropIdentityKey(_ entity: Inf6DocEntity) -> String {
        let title = entity.title
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
        return "\(entity.kind.rawValue)|\(entity.pageIndex)|\(title)"
    }

    private static func _replaceRecutEntities(
        existing: [Inf6DocEntity],
        rescanned: [Inf6DocEntity]
    ) -> [Inf6DocEntity] {
        var candidatesByKey: [String: [Inf6DocEntity]] = [:]
        for entity in existing {
            candidatesByKey[_recropIdentityKey(entity), default: []].append(entity)
        }
        var usedIDs = Set<UUID>()
        return rescanned.map { scanned in
            let key = _recropIdentityKey(scanned)
            guard let candidate = candidatesByKey[key]?.first(where: { candidate in
                !usedIDs.contains(candidate.id)
            }) else {
                return scanned
            }
            usedIDs.insert(candidate.id)
            var replaced = scanned
            replaced.id = candidate.id
            replaced.explanation = candidate.explanation
            replaced.references = candidate.references
            replaced.isCore = candidate.isCore
            replaced.coreImportanceScore = candidate.coreImportanceScore
            return replaced
        }
    }

    static func recutSingleEntityImage(
        entry: DrillEntry,
        docEntityID: String,
        expansion: EntityCropExpansion
    ) async throws -> String {
        #if canImport(UIKit)
        NSLog("[DrillPipeline][CROP] started paper=%@ entity=%@", entry.folderKey, docEntityID)
        guard var entityIndex = Inf6MetadataStore.getCodable(
            Inf6DocEntityIndex.self,
            domain: .docEntities,
            key: entry.folderKey
        ) else {
            throw NSError(
                domain: "Inf6EshikakuDrillPipeline",
                code: 44,
                userInfo: [NSLocalizedDescriptionKey: "再クロップ対象のdoc_entities metadataがありません: \(entry.folderKey)"]
            )
        }
        var entities = entityIndex.entities.filter { $0.id.uuidString == docEntityID }
        guard !entities.isEmpty else {
            throw NSError(
                domain: "Inf6EshikakuDrillPipeline",
                code: 45,
                userInfo: [NSLocalizedDescriptionKey: "再クロップ対象のdocEntity IDがありません: \(docEntityID)"]
            )
        }
        guard let pdfURL = _existingPDFURL(entry.pdfURL) ?? _findPDF(paperKey: entry.folderKey),
              let doc = PDFDocument(url: pdfURL) else {
            NSLog("[DrillPipeline] recutSingleEntityImage: PDF not found for %@", entry.folderKey)
            throw NSError(
                domain: "Inf6EshikakuDrillPipeline",
                code: 46,
                userInfo: [NSLocalizedDescriptionKey: "再クロップ対象PDFを開けません: \(entry.folderKey)"]
            )
        }
        try cropEntitiesFromPDF(
            pdfURL: pdfURL,
            doc: doc,
            paperKey: entry.folderKey,
            entities: &entities,
            expansion: expansion,
            reuseExistingImages: false,
            forceRecut: true
        )
        NSLog("[DrillPipeline][CROP] image_analysis_succeeded paper=%@ entity=%@ image=%@ parts=%d", entry.folderKey, docEntityID, entities.first?.imagePath ?? "", entities.reduce(0) { $0 + $1.parts.count })
        var paperAssociationSucceeded = false
        do {
            NSLog("[DrillPipeline][CROP] paper_text_association_started paper=%@ entity=%@ parts=%d", entry.folderKey, docEntityID, entities.reduce(0) { $0 + $1.parts.count })
            try await associatePartsWithPaperText(
                entities: &entities,
                pageTexts: _paperPageTexts(from: doc),
                paperKey: entry.folderKey,
                paperTitle: entry.paper.title,
                askModel: _partAssociationModel
            )
            paperAssociationSucceeded = true
            NSLog("[DrillPipeline][CROP] paper_text_association_succeeded paper=%@ entity=%@ parts=%d", entry.folderKey, docEntityID, entities.reduce(0) { $0 + $1.parts.count })
        } catch {
            if Self.isCancellation(error) {
                NSLog("[DrillPipeline][CROP] cancelled paper=%@ entity=%@", entry.folderKey, docEntityID)
                throw error
            }
            if (error as NSError).domain == "Inf6PaperTextTranslation" {
                NSLog("[DrillPipeline][CROP] translation_failed paper=%@ entity=%@ reason=%@", entry.folderKey, docEntityID, error.localizedDescription)
                throw error
            }
            NSLog("[DrillPipeline][CROP] llm_formula_processing_failed paper=%@ entity=%@ reason=%@", entry.folderKey, docEntityID, error.localizedDescription)
            throw error
        }
        guard let recut = entities.first,
              let imagePath = recut.imagePath,
              let index = entityIndex.entities.firstIndex(where: { $0.id == recut.id }) else {
            throw NSError(
                domain: "Inf6EshikakuDrillPipeline",
                code: 47,
                userInfo: [NSLocalizedDescriptionKey: "再クロップ結果に画像参照がありません: \(docEntityID)"]
            )
        }
        // Persist the complete LLM-enriched entity. Saving only imagePath and
        // parts silently discarded the entity-level formula and code returned
        // by _acquireLLMFormulaAndCode.
        entityIndex.entities[index] = recut
        entityIndex.entities[index].updatedAt = Date().timeIntervalSince1970
        try _persistRecutResult(paperKey: entry.folderKey, entityIndex: entityIndex)
        NSLog("[DrillPipeline][CROP] saved paper=%@ entity=%@ image=%@ parts=%d paperAssociation=%@", entry.folderKey, docEntityID, imagePath, recut.parts.count, paperAssociationSucceeded ? "success" : "incomplete")
        return imagePath
        #else
        throw NSError(
            domain: "Inf6EshikakuDrillPipeline",
            code: 48,
            userInfo: [NSLocalizedDescriptionKey: "UIKitが利用できないため再クロップできません。"]
        )
        #endif
    }

    private static func _persistRecutResult(
        paperKey: String,
        entityIndex: Inf6DocEntityIndex
    ) throws {
        guard var quiz = Inf6MetadataStore.getCodable(
            Inf6PaperQuiz.self,
            domain: .quiz,
            key: paperKey
        ) else {
            throw NSError(
                domain: "Inf6EshikakuDrillPipeline",
                code: 43,
                userInfo: [NSLocalizedDescriptionKey: "再クロップ対象のquiz metadataがありません: \(paperKey)"]
            )
        }
        let imagePathByID = Dictionary(uniqueKeysWithValues: entityIndex.entities.compactMap { entity in
            entity.imagePath.map { (entity.id, $0) }
        })
        for index in quiz.questions.indices {
            guard let entityID = quiz.questions[index].docEntityID,
                  let imagePath = imagePathByID[entityID] else { continue }
            quiz.questions[index].entityImagePath = imagePath
        }
        Inf6MetadataStore.putCodable(entityIndex, domain: .docEntities, key: paperKey)
        Inf6MetadataStore.putCodable(quiz, domain: .quiz, key: paperKey)
    }

    private static func _findPDF(paperKey: String) -> URL? {
        let fm = FileManager.default
        let papersDirectory = Inf6LocalStore.url(.papers)
        let targetKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paperKey)
        guard !targetKey.isEmpty,
              let contents = try? fm.contentsOfDirectory(
                at: papersDirectory,
                includingPropertiesForKeys: [.isRegularFileKey]
              ) else { return nil }
        return contents.first { url in
            guard url.pathExtension.lowercased() == "pdf",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { return false }
            return Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: url) == targetKey
        }
    }

    private static func _existingPDFURL(_ url: URL?) -> URL? {
        guard let url,
              url.pathExtension.lowercased() == "pdf",
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private static func _loadCoverageEntities(
        paperKey: String,
        entityFilter: Set<Inf6DocEntityKind>? = nil
    ) -> [Inf6DocEntity]? {
        guard let quiz = Inf6MetadataStore.getCodable(Inf6PaperQuiz.self, domain: .quiz, key: paperKey),
              let targets = quiz.coverageTargets, !targets.isEmpty else {
            NSLog("[DrillPipeline] _loadCoverageEntities: no quiz or no coverageTargets for %@", paperKey)
            return nil
        }
        let kindMap: [Inf6PaperQuizCoverageTargetKind: Inf6DocEntityKind] = [
            .figure: .figure, .table: .table, .equation: .equation
        ]
        let entities: [Inf6DocEntity] = targets.compactMap { target in
            guard let kind = kindMap[target.kind],
                  let pageIndex = target.pageIndex else { return nil }
            if let filter = entityFilter, !filter.contains(kind) { return nil }
            let rawID = target.id
            let uuidStr = rawID.hasPrefix("doc-entity:") ? String(rawID.dropFirst("doc-entity:".count)) : rawID
            guard let uuid = UUID(uuidString: uuidStr) else { return nil }
            return Inf6DocEntity(id: uuid, kind: kind, pageIndex: pageIndex, title: target.title, snippet: "")
        }
        return entities
    }

    /// 図表数式を「まず全て切り出し」、そのうえで論文の中核理論による重みづけを行う。
    ///
    /// 以前はシラバス概念名との文字列一致(relevance > 0)を必須条件にし、要旨語彙との
    /// 一致度(abstractHit)を最大の重みにしていた。これは
    ///   - 日本語トークンが正規表現で全て落ちる
    ///   - neural/network/deep/learning 等がストップワードで消える
    ///   - 中核であっても要旨で言及されない図(アーキテクチャ図など)が不利になる
    /// という理由で、中核図表を取りこぼしていた。文字列スコアリングは全廃し、
    /// 中核理論かどうかの判定は論文本文を読めるLLMに委ねる。
    private static func _markCoreEntities(
        entities: [Inf6DocEntity],
        paperTitle: String,
        syllabusContext: String,
        askModel: (String) async throws -> String
    ) async throws -> [Inf6DocEntity] {
        // 1) 切り出し段階では、実体として成立しているかだけを見る。
        //    図表はキャプション体裁を持つもの、数式はそのまま。中核性による足切りはしない。
        let extracted = entities
            .sorted {
                if $0.pageIndex != $1.pageIndex { return $0.pageIndex < $1.pageIndex }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        guard !extracted.isEmpty else { return [] }

        // 2) 切り出した全エンティティを提示し、論文の中核理論を担うものを重みづけさせる。
        let catalog = extracted.enumerated().map { index, entity in
            """
            [\(index)] 種別=\(entity.kind.labelJa) ページ=\(entity.pageIndex + 1) タイトル=\(entity.title)
            根拠抜粋: \(String(entity.snippet.prefix(400)).replacingOccurrences(of: "\n", with: " "))
            """
        }.joined(separator: "\n\n")

        let prompt = """
        あなたはE資格(JDLA主催)の演習問題を作成する専門家です。
        以下は論文「\(paperTitle)」から機械的に切り出した図・表・数式の全 \(extracted.count) 件です。

        各エンティティについて、その論文の中核理論を担っているかを1件ずつ判定してください。
        判定基準は「E資格の受験者が絶対に知っておかなければならない理解点か」です。

        判定の指針:
        - 論文の要旨で言及されているかどうかは基準にしない。中核理論は要旨ではなく図・表・数式に宿る。
        - アーキテクチャ図、定義式、手法の構成要素を示す図、比較表は、原則として中核である。
        - 手法の一部だけを示す図や、同じ手法の別の側面を示す表も、それぞれ独立した理解点になるため中核に含める。
        - 除外してよいのは、実験の細部、付録、参考図、体裁上の断片、本文と対応しない断片だけである。
        - 絞り込みすぎてはならない。中核に該当するものを落とすことは、余分に含めることより悪い。
          迷った場合は含めること。

        全 \(extracted.count) 件それぞれについて0〜100の重要度スコアを付け、重要度の高い順に全件を返してください。
        70以上を中核とし、スコアは必ず全件に付けてください。中核でないものも含め、全件を保存します。

        対象シラバス概念:
        \(syllabusContext)

        エンティティ一覧:
        \(catalog)

        JSON オブジェクトだけを返してください。
        {"entities": [{"index": 0, "score": 0}, {"index": 1, "score": 0}]}
        """

        let raw = try await askModel(prompt)
        NSLog("[DrillPipeline] _markCoreEntities paper=\"%@\" extracted=%d raw=%@",
              paperTitle, extracted.count, String(raw.prefix(400)))

        guard let json = _extractJSONObject(from: raw),
              let parsed = try? JSONDecoder().decode(_CoreEntitySelection.self, from: Data(json.utf8)) else {
            throw _EntityExtractionFailure(
                message: "中核図表数式の重みづけ応答を解釈できませんでした: \(paperTitle)"
            )
        }

        var used = Set<Int>()
        var scores: [Int: Int] = [:]
        for item in parsed.entities where extracted.indices.contains(item.index) && used.insert(item.index).inserted {
            scores[item.index] = min(max(item.score, 0), 100)
        }
        guard scores.count == extracted.count else {
            throw _EntityExtractionFailure(message: "図表数式のLLM重要度スコアが全件返されませんでした: \(paperTitle)")
        }
        var marked = extracted
        for index in marked.indices {
            let score = scores[index] ?? 0
            marked[index].coreImportanceScore = score
            marked[index].isCore = score >= 70
        }
        NSLog("[DrillPipeline] _markCoreEntities paper=\"%@\" core=%d retained=%d",
              paperTitle, marked.filter(\.isCore).count, marked.count)
        return marked
    }

    private struct _CoreEntitySelection: Decodable {
        struct EntityScore: Decodable {
            let index: Int
            let score: Int
        }
        let entities: [EntityScore]

        enum CodingKeys: String, CodingKey {
            case entities
        }
    }

    private static func _captionConfidence(_ title: String) -> Double {
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        let colonPattern = #"(?i)^\s*(figure|fig\.?|table|tab\.?)\s*[a-z]?\d+(?:\.\d+)?\s*[:：]"#
        if let regex = try? NSRegularExpression(pattern: colonPattern),
           regex.firstMatch(in: title, range: range) != nil {
            return 1.0
        }
        let periodPattern = #"(?i)^\s*(figure|fig\.?|table|tab\.?)\s*[a-z]?\d+(?:\.\d+)?\s*\."#
        if let regex = try? NSRegularExpression(pattern: periodPattern),
           regex.firstMatch(in: title, range: range) != nil {
            let proseContinuationPattern = #"(?i)^\s*(figure|fig\.?|table|tab\.?)\s*[a-z]?\d+(?:\.\d+)?\s*\.\s*(it|this|that|we|they|the authors?)\b"#
            if let proseRegex = try? NSRegularExpression(pattern: proseContinuationPattern),
               proseRegex.firstMatch(in: title, range: range) != nil {
                return 0.0
            }
            return 0.4
        }
        return 0.0
    }

    private static func _reuseExistingEntityImages(paperKey: String, entities: inout [Inf6DocEntity]) {
        guard let existing = Inf6MetadataStore.getCodable(Inf6DocEntityIndex.self, domain: .docEntities, key: paperKey) else {
            return
        }
        guard existing.version >= Inf6DocEntityIndex.currentVersion else { return }
        var used = Set<UUID>()
        for index in entities.indices where !_imageFileExists(entities[index].imagePath) {
            let normalizedTitle = entities[index].title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let match = existing.entities.first(where: { candidate in
                guard !used.contains(candidate.id), candidate.kind == entities[index].kind,
                      candidate.pageIndex == entities[index].pageIndex,
                      candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedTitle,
                      _imageFileExists(candidate.imagePath)
                else { return false }
                return true
            }) else { continue }
            entities[index].imagePath = match.imagePath
            used.insert(match.id)
        }
    }

    /// 初回生成と一括・単体再クロップで共有する、PDF図表数式画像化の入口。
    ///
    /// エンティティの検出・中核判定・設問生成とは責務を分離する。この処理は
    /// 渡された全エンティティを対象に、既存画像の再利用可否を同じ条件で判定し、
    /// Edge/Core ML検出を経由して画像を保存する。
    static func cropEntitiesFromPDF(
        pdfURL: URL,
        doc: PDFDocument,
        paperKey: String,
        entities: inout [Inf6DocEntity],
        expansion: EntityCropExpansion,
        reuseExistingImages: Bool,
        forceRecut: Bool
    ) throws {
        if reuseExistingImages {
            _reuseExistingEntityImages(paperKey: paperKey, entities: &entities)
        }
        try _cutMissingEntityImages(
            pdfURL: pdfURL,
            doc: doc,
            paperKey: paperKey,
            entities: &entities,
            expansion: expansion,
            forceRecut: forceRecut
        )
        #if canImport(UIKit)
        for index in entities.indices {
            guard let imagePath = entities[index].imagePath,
                  let page = doc.page(at: entities[index].pageIndex) else { continue }
            let imageURL = Inf6LibraryView._entityImagesBaseURL().appendingPathComponent(imagePath)
            guard let imageData = try? Data(contentsOf: imageURL) else {
                throw NSError(
                    domain: "Inf6EshikakuDrillPipeline",
                    code: 51,
                    userInfo: [NSLocalizedDescriptionKey: "図表数式クロップ画像を読み込めません: (imagePath)"]
                )
            }
            var parts = _extractCropParts(
                imageData: imageData,
                pageText: page.string ?? "",
                pageIndex: entities[index].pageIndex,
                entityID: entities[index].id
            )
            try _recognizePaperFormulas(imageData: imageData, parts: &parts, entity: &entities[index])
            entities[index].parts = parts
        }
        #endif
    }

    /// クロップ時に、各部位の画像を数式認識し、MathML検証を通った結果だけを保存する。
    /// 論文本文との意味的な対応付けはここでは行わず、後段のLLM関連付けに分離する。
    private static func _recognizePaperFormulas(
        imageData: Data,
        parts: inout [Inf6DocEntityPart],
        entity: inout Inf6DocEntity
    ) throws {
        #if canImport(UIKit)
        guard let image = UIImage(data: imageData), let cgImage = image.cgImage else {
            throw NSError(domain: "Inf6PaperFormulaRecognition", code: 1, userInfo: [NSLocalizedDescriptionKey: "クロップ画像を数式認識できません: \(entity.title)"])
        }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width > 1, height > 1 else {
            throw NSError(domain: "Inf6PaperFormulaRecognition", code: 1, userInfo: [NSLocalizedDescriptionKey: "クロップ画像のサイズが不正です: \(entity.title)"])
        }
        for index in parts.indices {
            try Task.checkCancellation()
            let rect = parts[index].normalizedRect
            let cropRect = CGRect(
                x: max(0, rect.minX * width),
                y: max(0, (1 - rect.maxY) * height),
                width: min(rect.width * width, width - max(0, rect.minX * width)),
                height: min(rect.height * height, height - max(0, (1 - rect.maxY) * height))
            ).integral
            guard cropRect.width > 2, cropRect.height > 2,
                  let partImage = cgImage.cropping(to: cropRect),
                  let partData = UIImage(cgImage: partImage).pngData()
            else {
                throw NSError(domain: "Inf6PaperFormulaRecognition", code: 2, userInfo: [NSLocalizedDescriptionKey: "部位画像を切り出せません: \(parts[index].stableID)"])
            }
            NSLog("[Inf6][CROP] formula_recognition_started entity=%@ part=%@", entity.id.uuidString, parts[index].stableID)
            do {
                let result = try TexTellerFormulaRecognition.recognize(imageData: partData)
                guard !result.mathML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !result.decodedExpression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw NSError(domain: "Inf6PaperFormulaRecognition", code: 3, userInfo: [NSLocalizedDescriptionKey: "数式認識結果が空です: \(parts[index].stableID)"])
                }
                parts[index].paperFormulaMathML = result.mathML
                parts[index].paperFormulaExpression = result.decodedExpression
                NSLog("[Inf6][CROP] formula_recognition_finished entity=%@ part=%@", entity.id.uuidString, parts[index].stableID)
            } catch {
                NSLog("[Inf6][CROP] formula_recognition_failed entity=%@ part=%@ reason=%@", entity.id.uuidString, parts[index].stableID, error.localizedDescription)
                throw NSError(domain: "Inf6PaperFormulaRecognition", code: 4, userInfo: [NSLocalizedDescriptionKey: "論文クロップ部位を数式表現へ変換できません: \(parts[index].stableID)。\(error.localizedDescription)"])
            }
        }
        NSLog("[Inf6][CROP] entity_formula_recognition_started entity=%@", entity.id.uuidString)
        let entityResult = try TexTellerFormulaRecognition.recognize(imageData: imageData)
        guard !entityResult.mathML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !entityResult.decodedExpression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "Inf6PaperFormulaRecognition", code: 6, userInfo: [NSLocalizedDescriptionKey: "エンティティ全体の数式認識結果が空です: \(entity.title)"])
        }
        entity.paperFormulaMathML = entityResult.mathML
        entity.paperFormulaExpression = entityResult.decodedExpression
        NSLog("[Inf6][CROP] entity_formula_recognition_finished entity=%@", entity.id.uuidString)
        #else
        throw NSError(domain: "Inf6PaperFormulaRecognition", code: 5, userInfo: [NSLocalizedDescriptionKey: "この実行環境では論文クロップの数式認識を実行できません。"])
        #endif
    }

    private static func _imageFileExists(_ imagePath: String?) -> Bool {
        guard let imagePath, !imagePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return FileManager.default.fileExists(atPath: Inf6LibraryView._entityImagesBaseURL().appendingPathComponent(imagePath).path)
    }

    private static func _cutMissingEntityImages(
        pdfURL: URL,
        doc: PDFDocument,
        paperKey: String,
        entities: inout [Inf6DocEntity],
        expansion: EntityCropExpansion = .zero,
        forceRecut: Bool = false
    ) throws {
        #if canImport(UIKit)
        let originalImageSizes = Dictionary(uniqueKeysWithValues: entities.compactMap { entity -> (UUID, CGSize)? in
            guard let imagePath = entity.imagePath,
                  let image = UIImage(contentsOfFile: Inf6LibraryView._entityImagesBaseURL().appendingPathComponent(imagePath).path)
            else { return nil }
            return (entity.id, image.size)
        })
        if forceRecut {
            for i in entities.indices { entities[i].imagePath = nil }
        }
        let missingBefore = entities.filter { !_imageFileExists($0.imagePath) }
        guard !missingBefore.isEmpty else { return }

        let fm = FileManager.default
        let paperDirName = String(paperKey.prefix(80))
        let imagesBase = Inf6LibraryView._entityImagesBaseURL()
        let entityDir = imagesBase.appendingPathComponent(paperDirName, isDirectory: true)
        try fm.createDirectory(at: entityDir, withIntermediateDirectories: true)

        let pages = Set(missingBefore.map(\.pageIndex)).sorted()
        for pageIndex in pages {
            guard let page = doc.page(at: pageIndex) else {
                throw NSError(
                    domain: "Inf6EshikakuDrillPipeline",
                    code: 30,
                    userInfo: [NSLocalizedDescriptionKey: "画像切り出し対象ページを開けません: \(pdfURL.lastPathComponent) page=\(pageIndex + 1)"]
                )
            }
            let thumbResult = try _renderPageImage(page)
            let neededClasses = _neededLayoutClasses(for: entities, pageIndex: pageIndex)
            let detections: [Inf6DocLayoutDetection]
            if !neededClasses.isEmpty {
                detections = try Inf6DocLayoutDetector.shared.detect(image: thumbResult.cgImage, classes: neededClasses)
            } else {
                detections = []
            }
            var nextDetectionIndexByClass: [Inf6DocLayoutClass: Int] = [:]

            for entityIndex in entities.indices where entities[entityIndex].pageIndex == pageIndex && !_imageFileExists(entities[entityIndex].imagePath) {
                let entity = entities[entityIndex]
                let layoutClass = _layoutClass(for: entity.kind)
                let matched = detections
                    .filter { $0.classID == layoutClass }
                    .sorted { lhs, rhs in
                        if lhs.y != rhs.y { return lhs.y < rhs.y }
                        return lhs.x < rhs.x
                    }
                let detectionIndex = nextDetectionIndexByClass[layoutClass, default: 0]
                nextDetectionIndexByClass[layoutClass] = detectionIndex + 1

                let originalSize = originalImageSizes[entity.id]
                let requiredWidth = originalSize.map { $0.width * (1 + expansion.left + expansion.right) }
                let requiredHeight = originalSize.map { $0.height * (1 + expansion.top + expansion.bottom) }
                let minimumOutputSize = CGSize(
                    width: requiredWidth ?? 0,
                    height: requiredHeight ?? 0
                )
                func acceptedCrop(_ data: Data) -> Data? {
                    guard let image = UIImage(data: data) else { return nil }
                    if let requiredWidth, expansion.left + expansion.right > 0,
                       image.size.width + 1 < requiredWidth { return nil }
                    if let requiredHeight, expansion.top + expansion.bottom > 0,
                       image.size.height + 1 < requiredHeight { return nil }
                    return data
                }

                var finalData: Data?
                if matched.indices.contains(detectionIndex) {
                    let best = matched[detectionIndex]
                    if let data = try? _cropDetectionJPEG(
                        best,
                        thumbResult: thumbResult,
                        padding: 0.03,
                        expansion: expansion,
                        minimumOutputSize: minimumOutputSize
                    ) {
                        finalData = acceptedCrop(data)
                    }
                }
                if finalData == nil {
                    finalData = _cropEntityJPEGFromTextLayout(
                        entity: entity,
                        page: page,
                        thumbResult: thumbResult,
                        expansion: expansion
                    )
                }
                guard let finalData else {
                    NSLog("[DrillPipeline] entity image crop failed (Edge/Core ML layout detection): %@ p%d", entity.kind.rawValue, pageIndex + 1)
                    continue
                }
                let imgName = "page_\(pageIndex)_\(entity.kind.rawValue)_\(entityIndex).jpg"
                let relPath = "\(paperDirName)/\(imgName)"
                try Inf6EntityImageStore.write(finalData, relativePath: "\(paperDirName)/\(imgName)")
                entities[entityIndex].imagePath = relPath
                entities[entityIndex].parts = _extractCropParts(
                    imageData: finalData,
                    pageText: page.string ?? "",
                    pageIndex: pageIndex,
                    entityID: entities[entityIndex].id
                )
            }
        }

        let stillMissing = entities.filter { !_imageFileExists($0.imagePath) }
        if !stillMissing.isEmpty {
            let labels = stillMissing
                .map { "\($0.kind.rawValue) p\($0.pageIndex + 1) \($0.title)" }
                .joined(separator: ", ")
            NSLog("[DrillPipeline] YOLO検出で画像取得できなかったエンティティ: %@", labels)
            if forceRecut {
                throw _EntityExtractionFailure(
                    message: "再クロップ対象の図表数式画像を生成できませんでした: \(labels)"
                )
            }
            throw _EntityExtractionFailure(
                message: "図表数式画像を生成できないエンティティがあります: \(labels)"
            )
        }
        #else
        throw NSError(
            domain: "Inf6EshikakuDrillPipeline",
            code: 32,
            userInfo: [NSLocalizedDescriptionKey: "UIKitが利用できないため中核エンティティ画像を切り出せません。"]
        )
        #endif
    }

    #if canImport(UIKit)
    private static func _extractCropParts(
        imageData: Data,
        pageText: String,
        pageIndex: Int,
        entityID: UUID
    ) -> [Inf6DocEntityPart] {
        #if canImport(Vision)
        guard let image = UIImage(data: imageData), let cgImage = image.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.usesCPUOnly = true
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        Self.visionOCRLock.lock()
        defer { Self.visionOCRLock.unlock() }
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else { return [] }

        struct OCRWord {
            let text: String
            let rect: CGRect
        }
        var words: [OCRWord] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let recognized = candidate.string
            let fullRange = NSRange(location: 0, length: (recognized as NSString).length)
            guard !recognized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let range = Range(fullRange, in: recognized),
                  let box = try? candidate.boundingBox(for: range) else { continue }
            let minX = min(box.topLeft.x, box.bottomLeft.x, box.topRight.x, box.bottomRight.x)
            let maxX = max(box.topLeft.x, box.bottomLeft.x, box.topRight.x, box.bottomRight.x)
            let minY = min(box.topLeft.y, box.bottomLeft.y, box.topRight.y, box.bottomRight.y)
            let maxY = max(box.topLeft.y, box.bottomLeft.y, box.topRight.y, box.bottomRight.y)
            words.append(OCRWord(
                text: recognized,
                rect: CGRect(
                    x: minX,
                    y: 1 - maxY,
                    width: maxX - minX,
                    height: maxY - minY
                )
            ))
        }
        // 黒枠と矢印も同じ画像から検出し、色矩形を図の構造として扱うための
        // 境界情報にする。OCR文字だけを部位にしない。
        let regions = _detectFilledColorRegions(cgImage: cgImage)
        var parts: [Inf6DocEntityPart] = []
        for region in regions {
            let contained = words.filter { region.insetBy(dx: -0.012, dy: -0.012).contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
                .sorted {
                    if abs($0.rect.midY - $1.rect.midY) > 0.015 { return $0.rect.midY < $1.rect.midY }
                    return $0.rect.minX < $1.rect.minX
                }
            let label = contained.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            let canonical = label.replacingOccurrences(of: "  ", with: " ")
            let rectKey = String(format: "%.5f,%.5f,%.5f,%.5f", region.minX, region.minY, region.width, region.height)
            let stableKey = "\(entityID.uuidString.lowercased())|p\(pageIndex)|\(canonical.lowercased())|\(rectKey)"
            let digest = SHA256.hash(data: Data(stableKey.utf8)).map { String(format: "%02x", $0) }.joined()
            parts.append(Inf6DocEntityPart(
                stableID: "part-\(digest)",
                text: canonical,
                normalizedRect: region,
                pageIndex: pageIndex,
                paperText: ""
            ))
        }
        // 色付き矩形の外にある黒文字ラベルも部位として保持する。
        // 例: Transformer図の「Output Probabilities」は矩形で囲まれていない。
        let uncoveredWords = words.filter { word in
            !regions.contains { region in
                region.insetBy(dx: -0.012, dy: -0.012)
                    .contains(CGPoint(x: word.rect.midX, y: word.rect.midY))
            }
        }
        for word in uncoveredWords {
            guard word.rect.width >= 0.012, word.rect.height >= 0.008 else { continue }
            let stableKey = "\(entityID.uuidString.lowercased())|p\(pageIndex)|ocr|\(word.text)|\(word.rect.minX),\(word.rect.minY),\(word.rect.width),\(word.rect.height)"
            let digest = SHA256.hash(data: Data(stableKey.utf8)).map { String(format: "%02x", $0) }.joined()
            parts.append(Inf6DocEntityPart(
                stableID: "part-\(digest)",
                text: word.text,
                normalizedRect: word.rect,
                pageIndex: pageIndex,
                paperText: ""
            ))
        }
        return parts
        #else
        return []
        #endif
    }

    private struct _BlackGeometry {
        let frameCount: Int
        let arrowCount: Int
    }

    /// 黒い水平・垂直線を枠、短い斜線の交点を矢印候補として数える。
    /// 図の構造検出はローカルで完結し、ここでは文字列を生成しない。
    private static func _detectBlackFramesAndArrows(cgImage: CGImage) -> _BlackGeometry {
        let width = cgImage.width, height = cgImage.height
        guard width > 0, height > 0, let provider = cgImage.dataProvider,
              let data = provider.data, let bytes = CFDataGetBytePtr(data) else { return _BlackGeometry(frameCount: 0, arrowCount: 0) }
        let bpp = cgImage.bitsPerPixel / 8
        guard bpp >= 3 else { return _BlackGeometry(frameCount: 0, arrowCount: 0) }
        let alpha = CGImageAlphaInfo(rawValue: cgImage.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
        let colorOffset = alpha == .first || alpha == .premultipliedFirst ? 1 : 0
        let step = max(1, min(4, width / 700))
        var horizontal = 0, vertical = 0, diagonal = 0
        for y in stride(from: step, to: height - step, by: step) {
            var run = 0
            for x in stride(from: step, to: width - step, by: step) {
                let i = y * cgImage.bytesPerRow + x * bpp + colorOffset
                let a = bytes[i], b = bytes[i + 1], c = bytes[i + 2]
                let dark = max(a, max(b, c)) < 80 && Int(max(a, max(b, c))) - Int(min(a, min(b, c))) < 35
                run = dark ? run + 1 : 0
                if run == 10 { horizontal += 1 }
            }
        }
        for x in stride(from: step, to: width - step, by: step) {
            var run = 0
            for y in stride(from: step, to: height - step, by: step) {
                let i = y * cgImage.bytesPerRow + x * bpp + colorOffset
                let a = bytes[i], b = bytes[i + 1], c = bytes[i + 2]
                let dark = max(a, max(b, c)) < 80 && Int(max(a, max(b, c))) - Int(min(a, min(b, c))) < 35
                run = dark ? run + 1 : 0
                if run == 10 { vertical += 1 }
            }
        }
        for y in stride(from: step, to: height - step, by: step) {
            for x in stride(from: step, to: width - step, by: step) {
                let i = y * cgImage.bytesPerRow + x * bpp + colorOffset
                let a = bytes[i], b = bytes[i + 1], c = bytes[i + 2]
                if max(a, max(b, c)) < 80 {
                    let ni = min(height - 1, y + step) * cgImage.bytesPerRow + min(width - 1, x + step) * bpp + colorOffset
                    if max(bytes[ni], max(bytes[ni + 1], bytes[ni + 2])) < 80 { diagonal += 1 }
                }
            }
        }
        return _BlackGeometry(frameCount: (horizontal + vertical) / 2, arrowCount: diagonal / 20)
    }

    /// 図の色付き矩形を画像画素から抽出する。OCRの単語枠をそのまま部位にせず、
    /// まず視覚的な部品境界を作り、その内部のOCRを一つの意味単位へ統合する。
    private static func _detectFilledColorRegions(cgImage: CGImage) -> [CGRect] {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0, let provider = cgImage.dataProvider,
              let data = provider.data, let bytes = CFDataGetBytePtr(data) else { return [] }
        let bpp = cgImage.bitsPerPixel / 8
        guard bpp >= 3 else { return [] }
        let alpha = CGImageAlphaInfo(rawValue: cgImage.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
        let colorOffset = alpha == .first || alpha == .premultipliedFirst ? 1 : 0
        let step = max(1, min(4, width / 700))
        let gridW = max(1, width / step)
        let gridH = max(1, height / step)
        var mask = Array(repeating: false, count: gridW * gridH)
        for gy in 0..<gridH {
            for gx in 0..<gridW {
                let x = min(width - 1, gx * step)
                let y = min(height - 1, gy * step)
                let base = y * cgImage.bytesPerRow + x * bpp + colorOffset
                let p = bytes[base]
                let q = bytes[base + 1]
                let r = bytes[base + 2]
                let maxC = max(p, max(q, r)), minC = min(p, min(q, r))
                let brightness = CGFloat(maxC) / 255
                let saturation = CGFloat(Int(maxC) - Int(minC)) / 255.0
                mask[gy * gridW + gx] = brightness > 0.18 && brightness < 0.995 && saturation > 0.035
            }
        }
        var visited = Array(repeating: false, count: mask.count)
        var regions: [CGRect] = []
        for start in mask.indices where mask[start] && !visited[start] {
            var queue = [start]; visited[start] = true; var cursor = 0
            var minX = gridW, minY = gridH, maxX = 0, maxY = 0, count = 0
            while cursor < queue.count {
                let i = queue[cursor]; cursor += 1; let x = i % gridW; let y = i / gridW
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y); count += 1
                for n in [i - 1, i + 1, i - gridW, i + gridW] where n >= 0 && n < mask.count {
                    let nx = n % gridW
                    guard abs(nx - x) <= 1, mask[n], !visited[n] else { continue }
                    visited[n] = true; queue.append(n)
                }
            }
            let rect = CGRect(x: CGFloat(minX * step) / CGFloat(width), y: CGFloat(minY * step) / CGFloat(height), width: CGFloat((maxX - minX + 1) * step) / CGFloat(width), height: CGFloat((maxY - minY + 1) * step) / CGFloat(height))
            let area = rect.width * rect.height
            guard count >= 12, rect.width > 0.04, rect.height > 0.015, rect.width < 0.8, rect.height < 0.35, area < 0.20 else { continue }
            if !regions.contains(where: { $0.insetBy(dx: -0.01, dy: -0.01).contains(CGPoint(x: rect.midX, y: rect.midY)) }) { regions.append(rect) }
        }
        return _mergeSameColorRegions(
            cgImage: cgImage,
            regions: regions.sorted { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
        )
    }

    /// 黒文字で塗り領域が分断された場合に、同色で連続する矩形だけを結合する。
    /// 異なる部品色は結合しないため、隣接する別部品を一つにしない。
    private static func _mergeSameColorRegions(cgImage: CGImage, regions: [CGRect]) -> [CGRect] {
        guard regions.count > 1 else { return regions }
        var merged = regions
        var changed = true
        while changed {
            changed = false
            outer: for i in merged.indices {
                for j in merged.indices where j > i {
                    let first = merged[i]
                    let second = merged[j]
                    let horizontalOverlap = max(0, min(first.maxX, second.maxX) - max(first.minX, second.minX))
                    let overlapRatio = horizontalOverlap / max(0.0001, min(first.width, second.width))
                    let verticalGap = max(0, max(first.minY, second.minY) - min(first.maxY, second.maxY))
                    guard overlapRatio >= 0.55, verticalGap <= 0.025,
                          let a = _sampleRegionColor(cgImage: cgImage, rect: first),
                          let b = _sampleRegionColor(cgImage: cgImage, rect: second) else { continue }
                    let colorDistance = sqrt(pow(a.0 - b.0, 2) + pow(a.1 - b.1, 2) + pow(a.2 - b.2, 2))
                    guard colorDistance <= 0.16 else { continue }
                    merged[i] = first.union(second)
                    merged.remove(at: j)
                    changed = true
                    break outer
                }
            }
        }
        return merged.sorted { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
    }

    private static func _sampleRegionColor(cgImage: CGImage, rect: CGRect) -> (CGFloat, CGFloat, CGFloat)? {
        guard let provider = cgImage.dataProvider,
              let data = provider.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let bpp = cgImage.bitsPerPixel / 8
        guard bpp >= 3 else { return nil }
        let alpha = CGImageAlphaInfo(rawValue: cgImage.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
        let colorOffset = alpha == .first || alpha == .premultipliedFirst ? 1 : 0
        let points: [(CGFloat, CGFloat)] = [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)]
        var total = (CGFloat.zero, CGFloat.zero, CGFloat.zero)
        for (px, py) in points {
            let x = min(cgImage.width - 1, max(0, Int((rect.minX + rect.width * px) * CGFloat(cgImage.width))))
            let y = min(cgImage.height - 1, max(0, Int((rect.minY + rect.height * py) * CGFloat(cgImage.height))))
            let base = y * cgImage.bytesPerRow + x * bpp + colorOffset
            total.0 += CGFloat(bytes[base]) / 255
            total.1 += CGFloat(bytes[base + 1]) / 255
            total.2 += CGFloat(bytes[base + 2]) / 255
        }
        return (total.0 / 4, total.1 / 4, total.2 / 4)
    }

    private struct _PartPaperTextAssociation: Decodable {
        let partIndex: Int
        let found: Bool
        let pageIndex: Int?
        let segmentIDs: [String]?
        let utf16Location: Int?
        let utf16Length: Int?
        let quote: String?
    }

    private struct _PaperTextSegment {
        let id: String
        let pageIndex: Int
        let utf16Location: Int
        let utf16Length: Int
        let text: String
    }

    private struct _PartPaperTextAssociationResponse: Decodable {
        let associations: [_PartPaperTextAssociation]
    }

    private struct _EntityFormulaCodeResponse: Decodable {
        let mathML: String
        let decodedExpression: String
        let pytorchCode: String
        let tensorflowCode: String
    }

    private static let _partAssociationModel: (String) async throws -> String = { prompt in
        try await Inf6LibraryView.askOpenAIJSONObject(
            systemInstruction: "あなたは論文原典の図表数式部位と本文範囲を対応付ける検証担当です。本文にない説明を生成してはいけません。JSON以外を返してはいけません。",
            userPrompt: prompt
        )
    }

    private static let _formulaCodeModel: (String) async throws -> String = { prompt in
        try await Inf6LibraryView.askOpenAIJSONObject(
            systemInstruction: "あなたは論文の図表数式を実装へ対応付ける担当です。原典にない内容を断定せず、JSON以外を返してはいけません。",
            userPrompt: prompt
        )
    }

    private static func _paperPageTexts(from doc: PDFDocument) -> [String] {
        (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
    }

    static func associatePartsWithPaperText(
        entities: inout [Inf6DocEntity],
        pageTexts: [String],
        paperKey: String,
        paperTitle: String,
        askModel: @escaping (String) async throws -> String
    ) async throws {
        let partLocations = entities.indices.flatMap { entityIndex in
            entities[entityIndex].parts.indices.map { (entityIndex, $0) }
        }
        guard !partLocations.isEmpty else {
            throw NSError(
                domain: "Inf6EshikakuDrillPipeline",
                code: 52,
                userInfo: [NSLocalizedDescriptionKey: "画像解析で図表数式の部位を検出できませんでした: \(paperTitle)"]
            )
        }
        NSLog("[Inf6][CROP] association_started paper=%@ parts=%d", paperKey, partLocations.count)
        let paperSegments = pageTexts.enumerated().flatMap { pageIndex, pageText -> [_PaperTextSegment] in
            let pageNSString = pageText as NSString
            var location = 0
            var lineIndex = 0
            var segments: [_PaperTextSegment] = []
            while location < pageNSString.length {
                var lineStart = 0
                var lineEnd = 0
                var contentsEnd = 0
                pageNSString.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
                let line = pageNSString.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(_PaperTextSegment(
                        id: "p\(pageIndex + 1)-l\(lineIndex + 1)",
                        pageIndex: pageIndex,
                        utf16Location: lineStart,
                        utf16Length: contentsEnd - lineStart,
                        text: line
                    ))
                }
                location = max(lineEnd, location + 1)
                lineIndex += 1
            }
            return segments
        }
        let fullText = paperSegments.map { segment in
            "[sourceSegmentID=\(segment.id) page=\(segment.pageIndex + 1)] \(segment.text)"
        }.joined(separator: "\n")
        var workingEntities = entities
        var failedChunks: [String] = []
        // LLMのJSON出力を安定して検証できる上限。全件を1応答に詰め込まない。
        let chunkSize = 3
        for chunkStart in stride(from: 0, to: partLocations.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, partLocations.count)
            let chunk = Array(partLocations[chunkStart..<chunkEnd])
            NSLog("[Inf6][CROP] association_chunk_started paper=%@ part=%d-%d", paperKey, chunkStart, chunkEnd - 1)
            let partCatalog = chunk.enumerated().map { localIndex, location in
                let entity = workingEntities[location.0]
                let part = entity.parts[location.1]
                return "[partIndex=\(localIndex)] entity=\(entity.kind.rawValue) title=\(entity.title) page=\(part.pageIndex + 1) label=\(part.text) rect=\(part.normalizedRect.minX),\(part.normalizedRect.minY),\(part.normalizedRect.width),\(part.normalizedRect.height)"
            }.joined(separator: "\n")
            let prompt = """
            論文「\(paperTitle)」の図表数式クロップについて、各部位を論文本文の正確な範囲に対応付けてください。
            これは関連付けだけを行う処理です。解説、要約、一般知識、本文にない文章を作成してはいけません。

            今回の部位一覧だけを処理してください。各 partIndex に対し、論文本文がその部位を定義・説明している最小限の連続範囲を1つ返してください。可能なら単語だけでなく、関連する完全な1文以上を引用してください。
            対応する本文がない場合だけ found=false とし、pageIndex/segmentIDs/utf16Location/utf16Length/quote は null にしてください。
            found=true の場合、本文一覧から関連する連続した sourceSegmentID を1つ以上選び、segmentIDs に入れてください。
            sourceSegmentID は作り変えず、本文一覧に存在するIDだけを返してください。quoteと文字位置は返さずnullにしてください。
            今回の全\(chunk.count)部位を重複なく必ず返してください。

            部位一覧:
            \(partCatalog)

            論文全文:
            \(fullText)

            JSONのみ:
            {"associations":[{"partIndex":0,"found":true,"pageIndex":0,"segmentIDs":["p1-l12","p1-l13"],"utf16Location":null,"utf16Length":null,"quote":null}]}
            """
            do {
            NSLog("[Inf6][CROP] association_request_started paper=%@ part=%d-%d", paperKey, chunkStart, chunkEnd - 1)
            let raw = try await askModel(prompt)
            NSLog("[Inf6][CROP] association_request_finished paper=%@ part=%d-%d", paperKey, chunkStart, chunkEnd - 1)
            guard let json = _extractJSONObject(from: raw) else {
                NSLog("[Inf6][CROP] association response has no JSON object paper=%@ part=%d rawPrefix=%@", paperKey, chunkStart, String(raw.prefix(600)))
                throw NSError(
                    domain: "Inf6EshikakuDrillPipeline",
                    code: 53,
                    userInfo: [NSLocalizedDescriptionKey: "部位と論文本文のLLM関連付けに失敗しました。LLMがJSONオブジェクトを返しませんでした（部位\(chunkStart + 1)〜\(chunkEnd)）。"]
                )
            }
            let response: _PartPaperTextAssociationResponse
            do {
                response = try JSONDecoder().decode(_PartPaperTextAssociationResponse.self, from: Data(json.utf8))
            } catch {
                NSLog("[Inf6][CROP] association JSON decode failed paper=%@ part=%d reason=%@ raw=%@", paperKey, chunkStart, _jsonDecodingFailureDescription(error), String(json.prefix(1200)))
                throw NSError(
                    domain: "Inf6EshikakuDrillPipeline",
                    code: 53,
                    userInfo: [NSLocalizedDescriptionKey: "部位と論文本文の関連付けJSONを検証できませんでした（部位\(chunkStart + 1)〜\(chunkEnd)：\(_jsonDecodingFailureDescription(error) )。"]
                )
            }
            guard response.associations.count == chunk.count else {
                throw NSError(
                    domain: "Inf6EshikakuDrillPipeline",
                    code: 54,
                    userInfo: [NSLocalizedDescriptionKey: "部位と論文本文の関連付けが全件返されませんでした: \(paperKey) (\(response.associations.count)/\(chunk.count))"]
                )
            }
            var seen = Set<Int>()
            for association in response.associations {
                guard chunk.indices.contains(association.partIndex),
                      seen.insert(association.partIndex).inserted else {
                    throw NSError(domain: "Inf6EshikakuDrillPipeline", code: 55, userInfo: [NSLocalizedDescriptionKey: "LLMの部位番号が重複または範囲外です: \(paperKey) part=\(chunkStart)"])
                }
                let (entityIndex, partIndex) = chunk[association.partIndex]
                if association.found {
                guard association.pageIndex != nil,
                      let segmentIDs = association.segmentIDs,
                      !segmentIDs.isEmpty else {
                    throw NSError(domain: "Inf6EshikakuDrillPipeline", code: 57, userInfo: [NSLocalizedDescriptionKey: "LLMが返した関連本文を原文と照合できません: \(paperKey) part=\(chunkStart + association.partIndex)"])
                }
                let selectedSegments = segmentIDs.compactMap { id in
                    paperSegments.first { $0.id == id }
                }
                guard selectedSegments.count == segmentIDs.count,
                      !selectedSegments.isEmpty else {
                    throw NSError(domain: "Inf6EshikakuDrillPipeline", code: 57, userInfo: [NSLocalizedDescriptionKey: "LLMが返した関連本文を原文と照合できません: \(paperKey) part=\(chunkStart + association.partIndex)"])
                }
                if selectedSegments.count == 1 {
                    let segment = selectedSegments[0]
                    let validatedPage = pageTexts[segment.pageIndex] as NSString
                    let validatedRange = NSRange(location: segment.utf16Location, length: segment.utf16Length)
                    workingEntities[entityIndex].parts[partIndex].paperText = validatedPage.substring(with: validatedRange)
                    workingEntities[entityIndex].parts[partIndex].paperTextUTF16Location = validatedRange.location
                    workingEntities[entityIndex].parts[partIndex].paperTextUTF16Length = validatedRange.length
                } else {
                    workingEntities[entityIndex].parts[partIndex].paperText = selectedSegments.map(\.text).joined(separator: "\n\n")
                    workingEntities[entityIndex].parts[partIndex].paperTextUTF16Location = nil
                    workingEntities[entityIndex].parts[partIndex].paperTextUTF16Length = nil
                }
                workingEntities[entityIndex].parts[partIndex].paperTextSourceSegmentIDs = segmentIDs
                } else {
                    workingEntities[entityIndex].parts[partIndex].paperText = "論文本文との対応箇所を確立できませんでした。"
                    workingEntities[entityIndex].parts[partIndex].paperTextUTF16Location = nil
                    workingEntities[entityIndex].parts[partIndex].paperTextUTF16Length = nil
                    workingEntities[entityIndex].parts[partIndex].paperTextSourceSegmentIDs = []
                }
            }
            } catch {
                let reason = error.localizedDescription
                NSLog("[Inf6][CROP] association chunk failed; continuing paper=%@ part=%d-%d reason=%@", paperKey, chunkStart, chunkEnd - 1, reason)
                failedChunks.append("部位\(chunkStart + 1)〜\(chunkEnd): \(reason)")
            }
        }
        if !failedChunks.isEmpty {
            // A failed association belongs to the affected part only. Keep its
            // explicit failure text in workingEntities and let valid parts and
            // the paper navigation continue.
            NSLog("[Inf6][CROP] association incomplete; continuing paper=%@ failures=%@", paperKey, failedChunks.joined(separator: " / "))
        }
        try await _acquireLLMFormulaAndCode(entities: &workingEntities, paperTitle: paperTitle, paperText: fullText)
        NSLog("[Inf6][CROP] association_finished paper=%@ parts=%d", paperKey, partLocations.count)
        entities = workingEntities
    }

    static func translateEntityPartsToJapanese(paperKey: String, entityID: UUID) async throws {
        try await Inf6SystemTranslationCoordinator.shared.verifyReadyForTranslation()
        guard var index = Inf6MetadataStore.getCodable(Inf6DocEntityIndex.self, domain: .docEntities, key: paperKey),
              let entityIndex = index.entities.firstIndex(where: { $0.id == entityID }) else {
            throw NSError(domain: "Inf6PaperTextTranslation", code: 2, userInfo: [NSLocalizedDescriptionKey: "日本語訳対象のEntityがありません: \(entityID.uuidString)"])
        }
        var entity = index.entities[entityIndex]
        var translatedEntities = [entity]
        translatedEntities = try await prefetchJapanesePaperTranslations(entities: translatedEntities)
        entity = translatedEntities[0]
        index.entities[entityIndex] = entity
        let hasJapaneseContent = !entity.titleJapanese.isEmpty
            || !entity.snippetJapanese.isEmpty
            || !(entity.explanationJapanese?.isEmpty ?? true)
            || entity.parts.contains(where: { !$0.paperTextJapanese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        guard hasJapaneseContent else {
            throw NSError(domain: "Inf6PaperTextTranslation", code: 3, userInfo: [NSLocalizedDescriptionKey: "Entity内に翻訳対象の論文本文がありません: \(entity.title)"])
        }
        entity.updatedAt = Date().timeIntervalSince1970
        index.entities[entityIndex] = entity
        Inf6MetadataStore.putCodable(index, domain: .docEntities, key: paperKey)
    }

    private static func _acquireLLMFormulaAndCode(
        entities: inout [Inf6DocEntity],
        paperTitle: String,
        paperText: String
    ) async throws {
        for index in entities.indices {
            try Task.checkCancellation()
            let entity = entities[index]
            let labels = entity.parts.map(\.text).joined(separator: ", ")
            let prompt = """
            論文「\(paperTitle)」のEntityを、論文本文と図表の実際の内容だけに基づいて処理してください。
            Entity全体を表す数式をMathMLで返し、その数式に対応する実行可能なPyTorchコードとTensorFlowコードを返してください。
            コードは推測で機能を省略せず、数式の処理と一致させてください。未検証のコードを検証済みとは書かないでください。
            Entity: \(entity.kind.rawValue) \(entity.title)
            既存の画像認識式: \(entity.paperFormulaExpression ?? "なし")
            部位ラベル: \(labels)
            論文本文:
            \(paperText)
            JSONのみで返してください:
            {"decodedExpression":"\\mathrm{...}","mathML":"<math>...</math>","pytorchCode":"...","tensorflowCode":"..."}
            """
            NSLog("[Inf6][CROP] llm_formula_code_started entity=%@", entity.id.uuidString)
            let raw = try await _formulaCodeModel(prompt)
            guard let json = _extractJSONObject(from: raw),
                  let result = try? JSONDecoder().decode(_EntityFormulaCodeResponse.self, from: Data(json.utf8)),
                  !result.decodedExpression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !result.mathML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !result.pytorchCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !result.tensorflowCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(domain: "Inf6LLMFormulaCode", code: 1, userInfo: [NSLocalizedDescriptionKey: "LLMがEntityの数式または対応コードを返しませんでした: \(entity.title)"])
            }
            do {
                try MathMLValidator().validate(result.mathML)
            } catch {
                throw NSError(domain: "Inf6LLMFormulaCode", code: 2, userInfo: [NSLocalizedDescriptionKey: "LLMが返したMathMLを検証できませんでした: \(entity.title)。\(error.localizedDescription)"])
            }
            entities[index].paperFormulaMathML = result.mathML
            entities[index].paperFormulaExpression = result.decodedExpression
            entities[index].llmPyTorchCode = result.pytorchCode
            entities[index].llmTensorFlowCode = result.tensorflowCode
            entities[index].llmCodeVerification = "未実行検証"
            NSLog("[Inf6][CROP] llm_formula_code_finished entity=%@", entity.id.uuidString)
        }
    }

    private static func prefetchJapanesePaperTranslations(entities: [Inf6DocEntity]) async throws -> [Inf6DocEntity] {
        var translatedEntities = entities
        for entityIndex in translatedEntities.indices {
            let title = translatedEntities[entityIndex].title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty && translatedEntities[entityIndex].titleJapanese.isEmpty {
                translatedEntities[entityIndex].titleJapanese = try await Inf6SystemTranslationCoordinator.shared.translate(
                    title, source: "en", target: "ja"
                ).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let snippet = translatedEntities[entityIndex].snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            if !snippet.isEmpty && translatedEntities[entityIndex].snippetJapanese.isEmpty {
                translatedEntities[entityIndex].snippetJapanese = try await Inf6SystemTranslationCoordinator.shared.translate(
                    snippet, source: "en", target: "ja"
                ).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let explanation = translatedEntities[entityIndex].explanation?.trimmingCharacters(in: .whitespacesAndNewlines),
               !explanation.isEmpty,
               translatedEntities[entityIndex].explanationJapanese == nil {
                translatedEntities[entityIndex].explanationJapanese = try await Inf6SystemTranslationCoordinator.shared.translate(
                    explanation, source: "en", target: "ja"
                ).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            for partIndex in translatedEntities[entityIndex].parts.indices {
                try Task.checkCancellation()
                let source = translatedEntities[entityIndex].parts[partIndex].paperText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !source.isEmpty,
                      source != "論文本文との対応箇所を確立できませんでした。" else { continue }
                NSLog("[Inf6][CROP] translation_started part=%@", translatedEntities[entityIndex].parts[partIndex].stableID)
                let translated = try await Inf6SystemTranslationCoordinator.shared.translate(
                    source,
                    source: "en",
                    target: "ja"
                )
                try Task.checkCancellation()
                let value = translated.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else {
                    throw NSError(
                        domain: "Inf6PaperTextTranslation",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "OS標準翻訳の結果が空でした。"]
                    )
                }
                translatedEntities[entityIndex].parts[partIndex].paperTextJapanese = value
                NSLog("[Inf6][CROP] translation_finished part=%@", translatedEntities[entityIndex].parts[partIndex].stableID)
            }
        }
        return translatedEntities
    }

    private static func _neededLayoutClasses(for entities: [Inf6DocEntity], pageIndex: Int) -> Set<Inf6DocLayoutClass> {
        Set(entities
            .filter { $0.pageIndex == pageIndex && !_imageFileExists($0.imagePath) }
            .map { _layoutClass(for: $0.kind) })
    }

    private static func _layoutClass(for kind: Inf6DocEntityKind) -> Inf6DocLayoutClass {
        switch kind {
        case .figure: return .picture
        case .table: return .table
        case .equation: return .formula
        }
    }

    private static func _renderPageImage(_ page: PDFPage) throws -> (cgImage: CGImage, actualW: CGFloat, actualH: CGFloat) {
        let mediaBox = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.0
        let thumbSize = CGSize(width: mediaBox.width * scale, height: mediaBox.height * scale)
        guard let cgImage = page.thumbnail(of: thumbSize, for: .mediaBox).cgImage else {
            throw NSError(
                domain: "Inf6EshikakuDrillPipeline",
                code: 33,
                userInfo: [NSLocalizedDescriptionKey: "PDFページ画像を生成できません。"]
            )
        }
        return (cgImage: cgImage, actualW: CGFloat(cgImage.width), actualH: CGFloat(cgImage.height))
    }

    private static func _cropDetectionJPEG(
        _ det: Inf6DocLayoutDetection,
        thumbResult: (cgImage: CGImage, actualW: CGFloat, actualH: CGFloat),
        padding: CGFloat,
        expansion: EntityCropExpansion = .zero,
        minimumOutputSize: CGSize = .zero
    ) throws -> Data {
        let bx = CGFloat(det.x) * thumbResult.actualW
        let by = CGFloat(det.y) * thumbResult.actualH
        let bw = CGFloat(det.width) * thumbResult.actualW
        let bh = CGFloat(det.height) * thumbResult.actualH
        let padX = max(10, thumbResult.actualW * padding)
        let padY = max(10, thumbResult.actualH * padding)
        let expL = bw * expansion.left
        let expR = bw * expansion.right
        let expT = bh * expansion.top
        let expB = bh * expansion.bottom
        var x = max(0, bx - padX - expL)
        var y = max(0, by - padY - expT)
        var width = min(bw + padX * 2 + expL + expR, thumbResult.actualW - x)
        var height = min(bh + padY * 2 + expT + expB, thumbResult.actualH - y)
        if minimumOutputSize.width > width {
            let desired = min(minimumOutputSize.width, thumbResult.actualW)
            let horizontalTotal = expansion.left + expansion.right
            let leftShare = horizontalTotal > 0 ? expansion.left / horizontalTotal : 0.5
            x = min(max(0, x - (desired - width) * leftShare), thumbResult.actualW - desired)
            width = desired
        }
        if minimumOutputSize.height > height {
            let desired = min(minimumOutputSize.height, thumbResult.actualH)
            let verticalTotal = expansion.top + expansion.bottom
            let topShare = verticalTotal > 0 ? expansion.top / verticalTotal : 0.5
            y = min(max(0, y - (desired - height) * topShare), thumbResult.actualH - desired)
            height = desired
        }
        let rect = CGRect(x: x, y: y, width: width, height: height)
        guard rect.width > 1, rect.height > 1,
              let cropped = thumbResult.cgImage.cropping(to: rect),
              let data = UIImage(cgImage: cropped).jpegData(compressionQuality: 0.85)
        else {
            throw NSError(
                domain: "Inf6EshikakuDrillPipeline",
                code: 34,
                userInfo: [NSLocalizedDescriptionKey: "検出領域のJPEG切り出しに失敗しました。"]
            )
        }
        return data
    }

    private static func _cropEntityJPEGFromTextLayout(
        entity: Inf6DocEntity,
        page: PDFPage,
        thumbResult: (cgImage: CGImage, actualW: CGFloat, actualH: CGFloat),
        expansion: EntityCropExpansion = .zero
    ) -> Data? {
        guard let captionBounds = _anchorBounds(for: entity, page: page) else { return nil }
        let pageBounds = page.bounds(for: .mediaBox)
        guard pageBounds.width > 0, pageBounds.height > 0 else { return nil }

        let scaleY = thumbResult.actualH / pageBounds.height
        let margin = thumbResult.actualW * 0.04
        let fullWidth = thumbResult.actualW - margin * 2
        let pageTopImg = thumbResult.actualH * 0.03
        let pageBottomImg = thumbResult.actualH * 0.97

        let cropRect: CGRect
        switch entity.kind {
        case .figure:
            // 図: キャプション（"Figure X"）が下。上方テキスト〜キャプション下端
            let captionBottomImg = (pageBounds.maxY - captionBounds.minY) * scaleY
            let upperBoundImg: CGFloat
            if let upperText = _findNearestText(relativeTo: captionBounds, direction: .above, page: page, pageBounds: pageBounds) {
                upperBoundImg = (pageBounds.maxY - upperText.minY) * scaleY
            } else {
                upperBoundImg = pageTopImg
            }
            cropRect = CGRect(x: margin, y: max(0, upperBoundImg), width: fullWidth, height: max(20, captionBottomImg - upperBoundImg))

        case .table:
            // 表: キャプション（"Table X"）が上。キャプション上端〜下方テキスト
            let captionTopImg = (pageBounds.maxY - captionBounds.maxY) * scaleY
            let lowerBoundImg: CGFloat
            if let lowerText = _findNearestText(relativeTo: captionBounds, direction: .below, page: page, pageBounds: pageBounds) {
                lowerBoundImg = (pageBounds.maxY - lowerText.maxY) * scaleY
            } else {
                lowerBoundImg = pageBottomImg
            }
            cropRect = CGRect(x: margin, y: max(0, captionTopImg), width: fullWidth, height: max(20, lowerBoundImg - captionTopImg))

        case .equation:
            // 数式: 前後テキスト間の狭い帯
            let eqTopImg = (pageBounds.maxY - captionBounds.maxY) * scaleY
            let eqBottomImg = (pageBounds.maxY - captionBounds.minY) * scaleY
            let padY = captionBounds.height * scaleY * 0.5
            let upperBoundImg: CGFloat
            if let upperText = _findNearestText(relativeTo: captionBounds, direction: .above, page: page, pageBounds: pageBounds) {
                upperBoundImg = (pageBounds.maxY - upperText.minY) * scaleY
            } else {
                upperBoundImg = max(0, eqTopImg - padY)
            }
            let lowerBoundImg: CGFloat
            if let lowerText = _findNearestText(relativeTo: captionBounds, direction: .below, page: page, pageBounds: pageBounds) {
                lowerBoundImg = (pageBounds.maxY - lowerText.maxY) * scaleY
            } else {
                lowerBoundImg = min(thumbResult.actualH, eqBottomImg + padY)
            }
            cropRect = CGRect(x: margin, y: max(0, upperBoundImg), width: fullWidth, height: max(20, lowerBoundImg - upperBoundImg))
        }

        let expandedRect = CGRect(
            x: cropRect.minX - cropRect.width * expansion.left,
            y: cropRect.minY - cropRect.height * expansion.top,
            width: cropRect.width * (1 + expansion.left + expansion.right),
            height: cropRect.height * (1 + expansion.top + expansion.bottom)
        )
        let clipped = expandedRect.intersection(CGRect(x: 0, y: 0, width: thumbResult.actualW, height: thumbResult.actualH))
        guard clipped.width > 8, clipped.height > 8,
              let cropped = thumbResult.cgImage.cropping(to: clipped),
              let data = UIImage(cgImage: cropped).jpegData(compressionQuality: 0.85)
        else { return nil }
        return data
    }

    private enum _TextDirection { case above, below }

    private static func _findNearestText(relativeTo anchor: CGRect, direction: _TextDirection, page: PDFPage, pageBounds: CGRect) -> CGRect? {
        guard let pageText = page.string, !pageText.isEmpty else { return nil }
        let lines = pageText.components(separatedBy: .newlines)
        var bestBounds: CGRect?
        var bestDistance: CGFloat = .greatestFiniteMagnitude
        let nsText = pageText as NSString
        var searchStart = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 3 else { continue }
            let range = nsText.range(of: trimmed, options: [], range: NSRange(location: searchStart, length: nsText.length - searchStart))
            guard range.location != NSNotFound,
                  let selection = page.selection(for: range) else { continue }
            searchStart = range.location + range.length
            let bounds = selection.bounds(for: page)
            guard bounds.width > 0, bounds.height > 0 else { continue }

            let distance: CGFloat
            switch direction {
            case .above:
                // PDF座標: 上方 = minY > anchor.maxY
                guard bounds.minY >= anchor.maxY + 2 else { continue }
                distance = bounds.minY - anchor.maxY
            case .below:
                // PDF座標: 下方 = maxY < anchor.minY
                guard bounds.maxY <= anchor.minY - 2 else { continue }
                distance = anchor.minY - bounds.maxY
            }
            if distance < bestDistance {
                bestDistance = distance
                bestBounds = bounds
            }
        }
        return bestBounds
    }

    private static func _anchorBounds(for entity: Inf6DocEntity, page: PDFPage) -> CGRect? {
        guard let pageText = page.string, !pageText.isEmpty else { return nil }
        let nsText = pageText as NSString
        for candidate in _anchorCandidates(for: entity) {
            let range = nsText.range(of: candidate, options: [.caseInsensitive, .diacriticInsensitive])
            guard range.location != NSNotFound, range.length > 0,
                  let selection = page.selection(for: range) else {
                continue
            }
            let bounds = selection.bounds(for: page)
            if bounds.width > 0, bounds.height > 0 { return bounds }
        }
        return nil
    }

    private static func _anchorCandidates(for entity: Inf6DocEntity) -> [String] {
        var values: [String] = []
        let title = entity.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, !title.lowercased().hasPrefix("equation candidate") {
            values.append(title)
        }
        for line in entity.snippet
            .components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            guard line.count >= 8 else { continue }
            values.append(String(line.prefix(90)))
        }

        var seen = Set<String>()
        return values.filter { value in
            let normalized = value.lowercased()
            guard !seen.contains(normalized) else { return false }
            seen.insert(normalized)
            return true
        }
    }
    #endif

    // MARK: - Private: Step 3 KC 自動生成 (PDF)

    private static func _entityEvidenceBlock(_ entities: [Inf6DocEntity]) -> String {
        entities.map { entity in
            let explanation = (entity.explanation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return """
            - 種別: \(entity.kind.labelJa) / タイトル: \(entity.title)
              根拠: \(String(entity.snippet.prefix(300)))
              解説: \(explanation.isEmpty ? "(未生成)" : explanation)
            """
        }.joined(separator: "\n")
    }

    private static func _generateOverviewIfRequired(
        pdfURL: URL,
        kcDir: URL,
        paperKey: String,
        paperTitle: String,
        paperID: String = "",
        entityEvidence: String = "",
        forceRegeneration: Bool = false
    ) async throws {
        guard forceRegeneration || !_hasCurrentOverview(paperKey: paperKey, kcDir: kcDir) else { return }
        let abstractText = try await Inf6AssetsAbstractPipeline.generatePaperAbstract(
            pdfURL: pdfURL,
            paperTitle: paperTitle,
            genLang: "ja",
            entityEvidence: entityEvidence,
            askModel: { prompt in
                let rendered = try Inf6PromptGovernance.renderSystemUserPrompt(
                    ref: Inf6PromptCatalog.assetsPromptBridgeJa,
                    variables: ["task_prompt": prompt]
                )
                let ledgerPrompt = [
                    rendered.systemInstruction,
                    rendered.userPrompt
                ].joined(separator: "\n\n")
                return try await _askModelWithLedger(
                    prompt: ledgerPrompt,
                    targetID: paperKey,
                    featureName: "drill_kc_overview"
                ) { _ in
                    try await Inf6LibraryView.askOpenAIText(
                        systemInstruction: rendered.systemInstruction,
                        userPrompt: rendered.userPrompt,
                        lang: "ja"
                    )
                }
            }
        )
        let generated = abstractText.trimmingCharacters(in: .whitespacesAndNewlines)
        // 「論文概要」は LLM の要約ではなく、許可された論文 source から取得した原文の
        // Abstract を用いる。日本語モードではその和訳を用いる。
        // 取得できていない場合は生成文をそのまま残す。
        let sourceAbstract = await _localizedSourceAbstract(paperID: paperID, genLang: "ja", paperKey: paperKey)
        let trimmed = _overviewWithSourceAbstract(generated, abstract: sourceAbstract)
        let abstractURL = kcDir.appendingPathComponent("\(paperKey).abstract.txt")
        try await _withMetadataWrite {
            try trimmed.write(to: abstractURL, atomically: true, encoding: .utf8)
        }
    }


    /// 「論文概要」節の本文を、保存済みの原文 Abstract に差し替える。
    /// 見出しは行単独で置かれる契約なので行単位で処理する。
    /// 原文 Abstract を取得し、日本語モードでは和訳して返す。
    /// 要約や補足はさせず、原文の内容をそのまま訳させる。
    private static func _localizedSourceAbstract(
        paperID: String,
        genLang: String,
        paperKey: String
    ) async -> String {
        guard !paperID.isEmpty,
              let paper = Inf6MetadataStore.getCodable(Inf6CorePaper.self, domain: .papers, key: paperID)
        else { return "" }

        // 演習生成では外部へ取りに行かない。
        //
        // abstract は起源探索で論文を実在確認したときに取得して保存済みである。
        // ここで取り直すと、一括生成のたびに件数ぶん arXiv を叩くことになり、
        // 429 やタイムアウトで生成そのものが失敗する。保存が無い論文は
        // 「要旨」への差し替えを諦め、LLM が書いた「論文概要」をそのまま使う。
        // 穴埋めが要る場合は、その論文の起源探索をやり直せば保存される。
        let abstract = paper.abstract?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !abstract.isEmpty else {
            NSLog("[DrillPipeline] abstract not stored for %@; keeping generated overview", paperKey)
            return ""
        }
        guard genLang == "ja" else { return abstract }

        do {
            let translated = try await Inf6SystemTranslationCoordinator.shared.translate(
                abstract,
                source: "en",
                target: "ja"
            )
            let cleaned = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? abstract : cleaned
        } catch {
            NSLog("[DrillPipeline] abstract translation failed for %@: %@", paperKey, error.localizedDescription)
            return abstract
        }
    }



    /// 原文 Abstract を載せるときの見出し。取得できない場合は LLM の「論文概要」を残す。
    private static let _sourceAbstractHeading = "要旨"

    private static func _overviewWithSourceAbstract(_ text: String, abstract rawAbstract: String) -> String {
        let abstract = rawAbstract.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !abstract.isEmpty else { return text }

        let lines = text.components(separatedBy: .newlines)
        let startHeadings = ["要旨", "論文要旨（abstract）", "論文概要", "Paper overview"]
        let nextHeadings = ["数学的導出", "実装", "実務上の検証", "Mathematical derivation", "Implementation", "Practical validation"]
        guard let start = lines.firstIndex(where: {
            startHeadings.contains($0.trimmingCharacters(in: .whitespaces))
        }) else { return text }
        let end = lines[(start + 1)...].firstIndex(where: {
            nextHeadings.contains($0.trimmingCharacters(in: .whitespaces))
        }) ?? lines.count

        // 原文 Abstract を取得できたときだけ、見出しごと「論文要旨（abstract）」へ
        // 差し替える。取得できない論文は LLM が書いた「論文概要」のまま残す。
        var rebuilt = Array(lines[..<start])
        rebuilt.append(_sourceAbstractHeading)
        rebuilt.append(abstract)
        rebuilt.append("")
        rebuilt.append(contentsOf: lines[end...])
        return rebuilt.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func _generateKCFolder(
        pdfURL: URL, kcDir: URL, paperKey: String,
        paperTitle: String,
        paperID: String = "",
        syllabusContext: String,
        forceOverviewRegeneration: Bool = false,
        askModel: @escaping (String) async throws -> String
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: kcDir, withIntermediateDirectories: true)

        guard let doc = PDFDocument(url: pdfURL) else {
            throw NSError(
                domain: "Inf6EshikakuDrillPipeline",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "PDFを開けませんでした: \(pdfURL.path)"]
            )
        }

        let pageTexts: [String] = (0..<doc.pageCount).map { index in
            doc.page(at: index)?.string ?? ""
        }
        let extractedText = pageTexts.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !extractedText.isEmpty else {
            throw NSError(
                domain: "Inf6EshikakuDrillPipeline",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "PDF本文を抽出できませんでした: \(pdfURL.lastPathComponent)"]
            )
        }
        Inf6MetadataStore.putCodable(
            Inf6PaperTextIndex(
                pdfKey: paperKey,
                pages: pageTexts.enumerated().map { Inf6PaperTextPage(pageIndex: $0.offset, text: $0.element) }
            ),
            domain: .docEntities,
            key: "\(paperKey).paper-text"
        )

        let miniDir = kcDir.appendingPathComponent("mini")
        try fm.createDirectory(at: miniDir, withIntermediateDirectories: true)

        // 中核理論は要旨ではなく図表数式に宿るという前提のもと、
        // 先にエンティティ(図・表・数式)を抽出・解説してから、その内容を根拠に概要/理解点を生成する。
        let entities = Inf6DocEntityScanner.scan(doc: doc)

        var coreEntities = try await _markCoreEntities(
            entities: entities,
            paperTitle: paperTitle,
            syllabusContext: syllabusContext,
            askModel: askModel
        )
        guard !coreEntities.isEmpty else {
            throw _EntityExtractionFailure(
                message: "中核図表数式を抽出できませんでした: \(pdfURL.lastPathComponent)"
            )
        }
        try cropEntitiesFromPDF(
            pdfURL: pdfURL,
            doc: doc,
            paperKey: paperKey,
            entities: &coreEntities,
            expansion: .standard,
            reuseExistingImages: true,
            forceRecut: false
        )
        try await associatePartsWithPaperText(
            entities: &coreEntities,
            pageTexts: pageTexts,
            paperKey: paperKey,
            paperTitle: paperTitle,
            askModel: askModel
        )
        guard !coreEntities.isEmpty else {
            throw _EntityExtractionFailure(
                message: "YOLOとPDFテキスト配置で実体を確認できる中核図表数式がありません: \(pdfURL.lastPathComponent)"
            )
        }

        var notesByPage: [Int: [[String: Any]]] = [:]
        for entityIndex in coreEntities.indices {
            let entity = coreEntities[entityIndex]
            let pageText = pageTexts.indices.contains(entity.pageIndex) ? pageTexts[entity.pageIndex] : ""
            let notePrompt =
                """
                以下はE資格シラバス対応の原論文から抽出したエンティティです。
                この図・表・数式について、試験演習に使える解説を日本語で180字以内で作成してください。
                何を表すか、どの理論を支えるか、読み取るべき変数・指標・比較を具体化してください。
                さらに、E資格の受験者が絶対に知っておくべき内容かどうかを踏まえて記述してください。

                種別: \(entity.kind.labelJa)
                タイトル: \(entity.title)
                根拠抜粋:
                \(String(entity.snippet.prefix(1200)))

                ページ本文:
                \(String(pageText.prefix(2400)))
                """
            let noteText = try await _askModelWithLedger(
                prompt: notePrompt,
                targetID: "\(paperKey):\(entity.id.uuidString)",
                featureName: "drill_kc_entity_note",
                askModel: askModel
            )
            coreEntities[entityIndex].explanation = noteText
            let focusedNote = """
            \(entity.kind.labelJa)
            1. \(entity.title)
            \(noteText)
            """
            notesByPage[entity.pageIndex, default: []].append([
                "id": UUID().uuidString,
                "text": focusedNote,
                "createdAt": Date().timeIntervalSince1970
            ])
        }

        for (pageIndex, noteData) in notesByPage {
            let data = try JSONSerialization.data(withJSONObject: noteData)
            try await _withMetadataWrite {
                try data.write(to: miniDir.appendingPathComponent("p\(pageIndex + 1).notes.json"), options: [.atomic])
            }
        }

        try await _withMetadataWrite {
            guard Inf6MetadataStore.putCodable(
                Inf6DocEntityIndex(pdfKey: paperKey, entities: coreEntities),
                domain: .docEntities,
                key: paperKey
            ) else {
                throw NSError(domain: "Inf6EshikakuDrillPipeline", code: 206, userInfo: [
                    NSLocalizedDescriptionKey: "docEntity indexを保存できませんでした: \(paperKey)"
                ])
            }
        }

        try await _generateOverviewIfRequired(
            pdfURL: pdfURL,
            kcDir: kcDir,
            paperKey: paperKey,
            paperTitle: paperTitle,
            paperID: paperID,
            entityEvidence: _entityEvidenceBlock(coreEntities),
            forceRegeneration: forceOverviewRegeneration
        )
    }

    // MARK: - Private: Step 4a クイズ生成 (KC ベース)

    private static func _codePracticeOptions(for entry: DrillEntry) -> Inf6PaperQuizCodePracticeOptions? {
        let tags = entry.paper.tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard tags.contains("requires_python_code") else { return nil }
        let syllabusTitle = (entry.syllabusTitle ?? entry.domainLabelJa)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Inf6PaperQuizCodePracticeOptions(
            frameworks: ["PyTorch", "TensorFlow"],
            syllabusTitle: syllabusTitle.isEmpty ? entry.paper.title : syllabusTitle,
            questionCount: 5
        )
    }

    private static func _storedQuizSatisfiesPythonPracticeContract(_ quiz: Inf6PaperQuiz, paper: Inf6CorePaper) -> Bool {
        let tags = paper.tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard tags.contains("requires_python_code") else { return true }
        let codeQuestions = quiz.questions.filter { $0.normalizedExerciseType == "py" }
        guard !codeQuestions.isEmpty else { return false }
        let codeTargetIDs = codeQuestions
            .flatMap { $0.coverageTargetIDs ?? [] }
            .map { $0.lowercased() }
        return ["PyTorch", "TensorFlow"].allSatisfy { framework in
            let prefix = "code-practice-\(Inf6PaperQuizGenerator.codePracticeFrameworkSlug(framework))-"
            return codeTargetIDs.contains { $0.hasPrefix(prefix) }
        }
    }

    private static func _requiresCodePracticeRegeneration(entry: DrillEntry) -> Bool {
        guard let options = _codePracticeOptions(for: entry) else { return false }
        guard let quiz = entry.quiz, !quiz.questions.isEmpty else { return true }
        let codeQuestions = quiz.questions.filter { $0.normalizedExerciseType == "py" }
        let codeTargetIDs = codeQuestions.flatMap { $0.coverageTargetIDs ?? [] }.map { $0.lowercased() }
        return options.frameworks.contains { framework in
            let prefix = "code-practice-\(Inf6PaperQuizGenerator.codePracticeFrameworkSlug(framework))-"
            return !codeTargetIDs.contains { $0.hasPrefix(prefix) }
        }
    }

    private static func _requiresBaseQuizRegeneration(entry: DrillEntry) -> Bool {
        guard let quiz = entry.quiz, !quiz.questions.isEmpty else { return true }
        return !quiz.questions.contains { $0.normalizedExerciseType == "regular" }
    }

    private static func _generateQuizFromKC(
        entry: DrillEntry, kcDir: URL,
        includeBaseQuiz: Bool = true,
        includeCodePractice: Bool = true,
        preserveExistingCodeQuestions: Bool = false,
        askModel: @escaping (String) async throws -> String
    ) async throws -> Inf6PaperQuiz? {
        let disk = try Inf6PaperQuizSourceBundle.loadFromDisk(
            baseDir: kcDir,
            paperKey: entry.folderKey,
            overviewFileName: isGeneratedExplanationProvider(entry.paper.provider)
                ? _textbookOriginalExplanationFileName(paperKey: entry.folderKey)
                : nil
        )
        guard let entityIndex = Inf6MetadataStore.getCodable(
            Inf6DocEntityIndex.self,
            domain: .docEntities,
            key: entry.folderKey
        ), entityIndex.version >= Inf6DocEntityIndex.currentVersion else {
            throw _failure(
                entry: entry,
                operation: "load_doc_entities",
                kind: .entityExtraction,
                cause: "再生成済み docEntity index がありません。",
                plan: ["PDFからdocEntityを再抽出する", "docEntity ID付き解説を保存する", "docEntity IDを問題生成へ渡す"],
                attempts: []
            )
        }
        let entityTargets = entityIndex.entities.map { entity in
            Inf6PaperQuizCoverageTarget(
                id: "doc-entity:\(entity.id.uuidString.lowercased())",
                kind: {
                    switch entity.kind {
                    case .figure: return .figure
                    case .table: return .table
                    case .equation: return .equation
                    }
                }(),
                pageIndex: entity.pageIndex,
                title: entity.title,
                evidenceText: [
                    entity.title,
                    entity.snippet,
                    entity.explanation ?? "",
                    (entity.references ?? []).map { reference in
                        "[reference_id=\(reference.id.uuidString.lowercased()) kind=\(reference.kind.rawValue) page=\(reference.pageIndex + 1)]\n\(reference.surroundingText)"
                    }.joined(separator: "\n\n")
                ]
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .joined(separator: "\n")
            )
        }
        let entityPageIndexes = Set(entityIndex.entities.map(\.pageIndex))
        let currentEntityNotes = disk.pageNotes.filter { entityPageIndexes.contains($0.key) }
        let sources = Inf6PaperQuizSourceBundle(
            abstractText: disk.abstractText,
            pageNotes: currentEntityNotes,
            mathCards: [:],
            entityCoverageTargets: entityTargets
        )
        guard sources.hasAnyContent else {
            throw _failure(
                entry: entry,
                operation: "load_quiz_sources",
                kind: .emptySource,
                cause: "KC概要・ページノート・数式カードが空のため演習問題の根拠がありません。",
                plan: ["PDF本文を抽出する", "中核図表数式を抽出する", "KCノートを生成する", "KC根拠から演習問題を生成する"],
                attempts: []
            )
        }

        NSLog("[DrillPipeline] Step4 sources: entities=%d pageNotes=%d abstract=%d chars",
              entityTargets.count, currentEntityNotes.count, disk.abstractText.count)
        let promptRef = Inf6PromptCatalog.quizPromptBridgeJa
        let wrappedAsk: (String) async throws -> String = { prompt in
            let rendered = try Inf6PromptGovernance.renderSystemUserPrompt(ref: promptRef, variables: ["task_prompt": prompt])
            let ledgerPrompt = [
                rendered.systemInstruction,
                rendered.userPrompt
            ].joined(separator: "\n\n")
            return try await _askModelWithLedger(
                prompt: ledgerPrompt,
                targetID: entry.folderKey,
                featureName: "drill_quiz_structured_json"
            ) { _ in
                try await Inf6LibraryView.askOpenAIJSONObject(
                    systemInstruction: rendered.systemInstruction,
                    userPrompt: rendered.userPrompt
                )
            }
        }

        let titleKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: entry.paper.title)
        let titleEnKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: entry.paper.titleEn ?? "")
        let aliases = _artifactLookupAliases(
            folderKey: entry.folderKey, titleKey: titleKey, titleEnKey: titleEnKey, paperID: entry.paper.id
        )
        let storedQuiz = entry.quiz ?? _findStoredArtifact(
            in: Inf6MetadataStore.listAllCodable(Inf6PaperQuiz.self, domain: .quiz),
            aliases: aliases,
            stablePaperIDKey: Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: entry.paper.id),
            artifactKey: { $0.paperKey },
            artifactTitle: { $0.paperTitle }
        )
        var quiz: Inf6PaperQuiz
        let existingQuizForPreservation = storedQuiz
        if includeBaseQuiz {
            do {
                quiz = try await Inf6PaperQuizGenerator.generate(
                    paperKey: entry.folderKey,
                    paperTitle: entry.paper.title,
                    lang: "ja",
                    sources: sources,
                    codePractice: nil,
                    askModel: wrappedAsk
                )
            } catch {
                if isCancellation(error) { throw error }
                throw _failure(
                    entry: entry,
                    operation: "generate_quiz_from_kc",
                    kind: _failureKind(from: error),
                    cause: error.localizedDescription,
                    plan: ["KC根拠を読み込む", "通常演習JSON生成を台帳付きで実行する", "JSON schema と coverageTargetIDs を検証する", "検証済み通常演習だけを保存する"],
                    attempts: [],
                    underlying: error
                )
            }
        } else {
            if let storedQuiz {
                quiz = storedQuiz
            } else {
                quiz = Inf6PaperQuiz(
                    paperKey: entry.folderKey,
                    paperTitle: entry.paper.title,
                    lang: "ja",
                    questions: [],
                    coverageTargets: []
                )
            }
            quiz.questions.removeAll { $0.normalizedExerciseType == "py" }
            quiz.coverageTargets = (quiz.coverageTargets ?? []).filter { $0.kind != .code }
        }
        let preservedCodeQuestions = preserveExistingCodeQuestions
            ? ((existingQuizForPreservation ?? entry.quiz)?.questions.filter { $0.normalizedExerciseType == "py" } ?? [])
            : []
        let preservedCodeTargets = preserveExistingCodeQuestions
            ? (((existingQuizForPreservation ?? entry.quiz)?.coverageTargets ?? []).filter { $0.kind == .code })
            : []
        if includeCodePractice, let codePractice = _codePracticeOptions(for: entry) {
            let codeQuiz: Inf6PaperQuiz
            do {
                codeQuiz = try await Inf6PaperQuizGenerator.generateCodePracticeOnly(
                    paperKey: entry.folderKey,
                    paperTitle: entry.paper.title,
                    lang: "ja",
                    sources: sources,
                    options: codePractice,
                    askModel: wrappedAsk
                )
            } catch {
                if isCancellation(error) { throw error }
                throw _failure(
                    entry: entry,
                    operation: "generate_code_practice_from_kc",
                    kind: _failureKind(from: error),
                    cause: error.localizedDescription,
                    plan: ["KC根拠を読み込む", "py演習JSON生成を台帳付きで実行する", "codeTargetID と実装解説を検証する", "検証済みpy演習だけを保存する"],
                    attempts: [],
                    underlying: error
                )
            }
            let existingTargetIDs = Set(quiz.coverageTargets?.map(\.id) ?? [])
            quiz.questions.append(contentsOf: codeQuiz.questions)
            quiz.coverageTargets = (quiz.coverageTargets ?? []) + (codeQuiz.coverageTargets ?? []).filter { !existingTargetIDs.contains($0.id) }
        }
        if let index = Inf6MetadataStore.getCodable(Inf6DocEntityIndex.self, domain: .docEntities, key: entry.folderKey) {
            let entitiesByID = Dictionary(uniqueKeysWithValues: index.entities.map { ($0.id, $0) })
            for i in quiz.questions.indices {
                let q = quiz.questions[i]
                let referencedEntityIDs = Set((q.coverageTargetIDs ?? []).compactMap { targetID -> UUID? in
                    guard targetID.hasPrefix("doc-entity:") else { return nil }
                    return UUID(uuidString: String(targetID.dropFirst("doc-entity:".count)))
                })
                let matches = referencedEntityIDs.compactMap { entitiesByID[$0] }
                guard matches.count == 1, let entity = matches.first,
                      let imagePath = entity.imagePath, _imageFileExists(imagePath) else {
                    continue
                }
                quiz.questions[i].kind = entity.kind.rawValue
                quiz.questions[i].docEntityID = entity.id
                quiz.questions[i].entityImagePath = imagePath
                quiz.questions[i].entityReferenceIDs = (entity.references ?? []).map(\.id)
                quiz.questions[i].pageIndex = entity.pageIndex
                if let canonicalReference = _entityReference(in: entity.title) {
                    quiz.questions[i].question = _replacingEntityReference(
                        in: q.question,
                        with: canonicalReference
                    )
                }
            }
        }

        let visualKinds = Set(["figure", "table", "equation"])
        let invalidVisualQuestions = quiz.questions.enumerated().compactMap { index, question -> String? in
            guard visualKinds.contains(question.kind.lowercased()) else { return nil }
            guard question.docEntityID != nil,
                  let imagePath = question.entityImagePath,
                  _imageFileExists(imagePath) else { return "Q\(index + 1) \(question.kind)" }
            return nil
        }
        guard invalidVisualQuestions.isEmpty else {
            throw _failure(
                entry: entry,
                operation: "validate_quiz_entity_binding",
                kind: .entityImageExtraction,
                cause: "図表数式問題を画像へ一意に結合できません: \(invalidVisualQuestions.joined(separator: ", "))",
                plan: ["coverageTargetIDを検証する", "docEntityを一意に解決する", "画像パスの存在を検証する", "検証済みquizだけを保存する"],
                attempts: []
            )
        }
        try quiz.validateVisualEvidenceContract()
        if includeBaseQuiz,
           _requiresBaseQuizRegeneration(entry: entry),
           !quiz.questions.contains(where: { $0.normalizedExerciseType == "regular" }) {
            throw Inf6PaperQuizError.modelJSONDecodeFailed(
                "[Quiz] regular drill regeneration produced no regular questions for \(entry.folderKey)"
            )
        }
        if !preservedCodeQuestions.isEmpty || !preservedCodeTargets.isEmpty {
            let existingTargetIDs = Set(quiz.coverageTargets?.map(\.id) ?? [])
            quiz.questions.append(contentsOf: preservedCodeQuestions)
            quiz.coverageTargets = (quiz.coverageTargets ?? []) + preservedCodeTargets.filter { !existingTargetIDs.contains($0.id) }
        }

        try await _withMetadataWrite {
            guard Inf6MetadataStore.putCodable(quiz, domain: .quiz, key: entry.folderKey) else {
                throw NSError(
                    domain: "Inf6EshikakuDrillPipeline",
                    code: 44,
                    userInfo: [NSLocalizedDescriptionKey: "演習JSONを保存できませんでした: \(entry.folderKey)"]
                )
            }
        }
        NSLog("[DrillPipeline] quiz from KC: %@ (%d questions)", entry.folderKey, quiz.questions.count)
        return quiz
    }

    private static func _entityReference(in text: String) -> String? {
        let pattern = #"(?i)\b(figure|fig\.?|table|tab\.?|equation|eq\.?)\s*\(?([a-z]?\d+(?:\.\d+)?)\)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let kindRange = Range(match.range(at: 1), in: text),
              let numberRange = Range(match.range(at: 2), in: text)
        else { return nil }
        let rawKind = String(text[kindRange]).lowercased()
        let kind: String
        if rawKind.hasPrefix("fig") { kind = "figure" }
        else if rawKind.hasPrefix("tab") { kind = "table" }
        else { kind = "equation" }
        return "\(kind):\(text[numberRange].lowercased())"
    }

    private static func _replacingEntityReference(in text: String, with canonicalReference: String) -> String {
        let components = canonicalReference.split(separator: ":", maxSplits: 1).map(String.init)
        guard components.count == 2 else { return text }
        let label: String
        switch components[0] {
        case "figure": label = "Figure \(components[1])"
        case "table": label = "Table \(components[1])"
        case "equation": label = "Equation \(components[1])"
        default: return text
        }
        let pattern = #"(?i)\b(figure|fig\.?|table|tab\.?|equation|eq\.?)\s*\(?[a-z]?\d+(?:\.\d+)?\)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: label)
    }

}
