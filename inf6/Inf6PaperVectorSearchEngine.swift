//
//  Inf6PaperVectorSearchEngine.swift
//  inf6
//
//  Profile-vector driven paper re-ranking for PaperChat.
//  - Profile vector: derived from user profile text
//  - Corpus paper vector: metadata (title/abstract)
//  - Search-time refinement: optional PDF assets vector (late fusion)
//  - Storage/search: iCloud vector index (Inf6PaperVectorIndex)
//

import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

struct Inf6PaperVectorIngestResult {
    let sourceRaw: String
    let requestedCount: Int
    let uniqueCount: Int
    let existingSkippedCount: Int
    let upsertedCount: Int
    let enrichedCount: Int
    let failedCount: Int
}

struct Inf6PaperVectorIndexSnapshot {
    let dimension: Int?
    let totalPapers: Int
    let sourceCounts: [String: Int]
}

struct Inf6PaperVectorRerankResult {
    let ranked: [Inf6PaperSearchResult]
    let scoresByID: [String: Float]
    let profileID: String
    let profileBackend: Inf6EmbeddingBackend
    let vectorizedPaperCount: Int
    let enrichedPaperCount: Int
    let failedPaperCount: Int
}

struct Inf6PaperVectorSearchHit {
    let result: Inf6PaperSearchResult
    let score: Float
}

enum Inf6PaperVectorSearchEngine {

    static func indexSnapshot() throws -> Inf6PaperVectorIndexSnapshot {
        let baseDir = try vectorBaseDir()
        let index = Inf6PaperVectorIndex(baseDir: baseDir)
        try index.loadOrCreate()

        let papers = try index.allPapers()
        var sourceCounts: [String: Int] = [:]
        sourceCounts.reserveCapacity(8)
        for p in papers {
            let key = p.sourceRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            sourceCounts[key, default: 0] += 1
        }

        return Inf6PaperVectorIndexSnapshot(
            dimension: index.currentDimension(),
            totalPapers: papers.count,
            sourceCounts: sourceCounts
        )
    }

    static func ingest(
        sourceRaw: String,
        candidates: [Inf6PaperSearchResult],
        enrichBudget: Int
    ) async throws -> Inf6PaperVectorIngestResult {
        // Contract: corpus bootstrap is metadata-first.
        // Assets enrichment is handled at search time, not precompute.
        _ = enrichBudget
        let normalizedSource = sourceRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedSource.isEmpty else {
            throw NSError(
                domain: "inf6.paper.vector",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "sourceRaw is empty."]
            )
        }

        if candidates.isEmpty {
            return Inf6PaperVectorIngestResult(
                sourceRaw: normalizedSource,
                requestedCount: 0,
                uniqueCount: 0,
                existingSkippedCount: 0,
                upsertedCount: 0,
                enrichedCount: 0,
                failedCount: 0
            )
        }

        let baseDir = try vectorBaseDir()
        let index = Inf6PaperVectorIndex(baseDir: baseDir)
        try index.loadOrCreate()

        let existing = try index.allPapers()
        var existingIDs = Set(existing.map { $0.paperID })

        var seenIDs = Set<String>()
        seenIDs.reserveCapacity(candidates.count)
        var unique: [Inf6PaperSearchResult] = []
        unique.reserveCapacity(candidates.count)

        for c in candidates {
            let id = c.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty { continue }
            if seenIDs.insert(id).inserted {
                unique.append(c)
            }
        }
        var existingSkippedCount = 0
        var upsertedCount = 0
        var failedCount = 0

        for c in unique {
            if existingIDs.contains(c.id) {
                existingSkippedCount += 1
                continue
            }

            do {
                let metadataText = _paperMetadataFeatureText(candidate: c, sourceRaw: normalizedSource)
                let emb = try await Inf6EmbeddingService.embedPassage(metadataText)
                try index.upsertPaperVector(
                    paperID: c.id,
                    title: c.title,
                    sourceRaw: normalizedSource,
                    vector: emb.vector
                )
                existingIDs.insert(c.id)
                upsertedCount += 1
            } catch {
                failedCount += 1
            }
        }

        return Inf6PaperVectorIngestResult(
            sourceRaw: normalizedSource,
            requestedCount: candidates.count,
            uniqueCount: unique.count,
            existingSkippedCount: existingSkippedCount,
            upsertedCount: upsertedCount,
            enrichedCount: 0,
            failedCount: failedCount
        )
    }

    static func rerank(
        profileText: String,
        profileLabel: String,
        sourceRaw: String,
        candidates: [Inf6PaperSearchResult]
    ) async throws -> Inf6PaperVectorRerankResult {
        let trimmedProfile = profileText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProfile.isEmpty else {
            throw NSError(
                domain: "inf6.paper.vector",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "Profile text is empty."]
            )
        }

        guard !candidates.isEmpty else {
            return Inf6PaperVectorRerankResult(
                ranked: [],
                scoresByID: [:],
                profileID: _stableID("profile|\(trimmedProfile)"),
                profileBackend: .coreML,
                vectorizedPaperCount: 0,
                enrichedPaperCount: 0,
                failedPaperCount: 0
            )
        }

        let baseDir = try vectorBaseDir()
        let index = Inf6PaperVectorIndex(baseDir: baseDir)
        try index.loadOrCreate()

        let profileEmbedding = try await Inf6EmbeddingService.embedQuery(trimmedProfile)
        let profileVector = profileEmbedding.vector
        let profileID = _stableID("profile|\(trimmedProfile)")
        try index.upsertProfileVector(profileID: profileID, label: profileLabel, vector: profileVector)

        let normalizedSource = sourceRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let existing = try index.allPapers()
        var metadataVectorsByID: [String: [Float]] = [:]
        metadataVectorsByID.reserveCapacity(existing.count)
        for e in existing {
            metadataVectorsByID[e.paperID] = e.vector
        }

        var vectorizedPaperCount = 0
        var enrichedPaperCount = 0
        var failedPaperCount = 0

        // 1) Ensure corpus vectors (metadata-only) for candidates.
        for c in candidates {
            if metadataVectorsByID[c.id] != nil { continue }

            do {
                let metadataText = _paperMetadataFeatureText(candidate: c, sourceRaw: normalizedSource)
                let emb = try await Inf6EmbeddingService.embedPassage(metadataText)
                try index.upsertPaperVector(
                    paperID: c.id,
                    title: c.title,
                    sourceRaw: normalizedSource,
                    vector: emb.vector
                )
                metadataVectorsByID[c.id] = emb.vector
                vectorizedPaperCount += 1
            } catch {
                failedPaperCount += 1
            }
        }

        // 2) Base scores from corpus space (metadata vectors).
        var baseScoresByID: [String: Float] = [:]
        baseScoresByID.reserveCapacity(candidates.count)
        for c in candidates {
            if let v = metadataVectorsByID[c.id] {
                baseScoresByID[c.id] = Inf6VectorMath.cosine(profileVector, v)
            }
        }

        // 3) Search-time assets vectors (optional) + late fusion.
        // Keep bounded to avoid excessive latency.
        let assetsBudget = 6
        let metadataWeight: Float = 0.80
        let assetsWeight: Float = 0.20

        var originalOrder: [String: Int] = [:]
        originalOrder.reserveCapacity(candidates.count)
        for (idx, c) in candidates.enumerated() {
            originalOrder[c.id] = idx
        }

        let assetsTargets = candidates.sorted { a, b in
            let sa = baseScoresByID[a.id] ?? -Float.greatestFiniteMagnitude
            let sb = baseScoresByID[b.id] ?? -Float.greatestFiniteMagnitude
            if sa != sb { return sa > sb }
            return (originalOrder[a.id] ?? 0) < (originalOrder[b.id] ?? 0)
        }

        var assetsScoresByID: [String: Float] = [:]
        assetsScoresByID.reserveCapacity(min(assetsBudget, candidates.count))

        for c in assetsTargets where enrichedPaperCount < assetsBudget {
            do {
                guard let assetText = try await _assetFeatureText(candidate: c, sourceRaw: normalizedSource), !assetText.isEmpty else {
                    continue
                }
                let emb = try await Inf6EmbeddingService.embedPassage(assetText)
                let assetScore = Inf6VectorMath.cosine(profileVector, emb.vector)
                assetsScoresByID[c.id] = assetScore
                enrichedPaperCount += 1
            } catch {
                failedPaperCount += 1
            }
        }

        var scoresByID: [String: Float] = [:]
        scoresByID.reserveCapacity(candidates.count)

        for c in candidates {
            let base = baseScoresByID[c.id]
            let asset = assetsScoresByID[c.id]

            switch (base, asset) {
            case let (b?, a?):
                scoresByID[c.id] = (metadataWeight * b) + (assetsWeight * a)
            case let (b?, nil):
                scoresByID[c.id] = b
            case let (nil, a?):
                scoresByID[c.id] = a
            case (nil, nil):
                break
            }
        }

        let ranked = candidates.sorted { a, b in
            let sa = scoresByID[a.id] ?? -Float.greatestFiniteMagnitude
            let sb = scoresByID[b.id] ?? -Float.greatestFiniteMagnitude
            if sa != sb { return sa > sb }
            return (originalOrder[a.id] ?? 0) < (originalOrder[b.id] ?? 0)
        }

        return Inf6PaperVectorRerankResult(
            ranked: ranked,
            scoresByID: scoresByID,
            profileID: profileID,
            profileBackend: profileEmbedding.backend,
            vectorizedPaperCount: vectorizedPaperCount,
            enrichedPaperCount: enrichedPaperCount,
            failedPaperCount: failedPaperCount
        )
    }

    static func searchLocalByVector(
        queryText: String,
        sourceRaw: String?,
        topK: Int
    ) async throws -> [Inf6PaperVectorSearchHit] {
        let trimmedQuery = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw NSError(
                domain: "inf6.paper.vector",
                code: -20,
                userInfo: [NSLocalizedDescriptionKey: "Query text is empty for local vector search."]
            )
        }

        let baseDir = try vectorBaseDir()
        let index = Inf6PaperVectorIndex(baseDir: baseDir)
        try index.loadOrCreate()

        let queryEmbedding = try await Inf6EmbeddingService.embedQuery(trimmedQuery)
        let rawK = max(1, min(topK, 200))
        let bufferedK = min(max(rawK * 4, rawK), 800)
        let scored = try index.searchPapers(queryVector: queryEmbedding.vector, topK: bufferedK)

        let normalizedSource = (sourceRaw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let isPinned = !normalizedSource.isEmpty && normalizedSource != "auto"

        let filtered: [(paper: Inf6PaperVectorIndexEntry, score: Float)]
        if isPinned {
            filtered = scored.filter { $0.paper.sourceRaw.lowercased() == normalizedSource }
            if filtered.isEmpty {
                throw NSError(
                    domain: "inf6.paper.vector",
                    code: -21,
                    userInfo: [NSLocalizedDescriptionKey: "No local vector hits for source=\(normalizedSource)."]
                )
            }
        } else {
            filtered = scored
        }

        let metadataByID = try _loadPersistedMetadataByPaperID()
        var hits: [Inf6PaperVectorSearchHit] = []
        hits.reserveCapacity(min(rawK, filtered.count))

        for item in filtered.prefix(rawK) {
            let id = item.paper.paperID.trimmingCharacters(in: .whitespacesAndNewlines)
            let meta = metadataByID[id]
            let result: Inf6PaperSearchResult
            if let meta {
                result = meta
            } else {
                result = Inf6PaperSearchResult(
                    id: item.paper.paperID,
                    title: item.paper.title,
                    subtitle: item.paper.sourceRaw.uppercased(),
                    landingURL: nil,
                    pdfURL: nil,
                    abstractText: ""
                )
            }
            hits.append(Inf6PaperVectorSearchHit(result: result, score: item.score))
        }
        return hits
    }

    // MARK: - Vector base dir

    static func vectorBaseDir() throws -> URL {
        let fm = FileManager.default
        let dir = Inf6DataRoot.url()
            .appendingPathComponent("inf6.paperchat", isDirectory: true)
            .appendingPathComponent("vector", isDirectory: true)

        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Feature text

    private static func _paperMetadataFeatureText(
        candidate: Inf6PaperSearchResult,
        sourceRaw: String
    ) -> String {
        var lines: [String] = []
        lines.reserveCapacity(12)

        let t = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = candidate.abstractText.trimmingCharacters(in: .whitespacesAndNewlines)

        lines.append("source: \(sourceRaw)")
        if !t.isEmpty { lines.append("title: \(t)") }
        if !s.isEmpty { lines.append("abstract: \(s)") }

        let keywordHints = _keywordHints(from: t + "\n" + s)
        if !keywordHints.isEmpty {
            lines.append("hints: \(keywordHints.joined(separator: ", "))")
        }

        return lines.joined(separator: "\n")
    }

    private static func _keywordHints(from text: String) -> [String] {
        let lower = text.lowercased()
        let hints = [
            "transformer", "diffusion", "reinforcement learning", "rag", "retrieval",
            "benchmark", "ablation", "reproducibility", "optimization", "bayesian",
            "clinical", "vision", "language", "graph", "causal", "simulation"
        ]
        return hints.filter { lower.contains($0) }
    }

    // MARK: - PDF enrichment (figure/equation evidence)

    private static func _assetFeatureText(candidate: Inf6PaperSearchResult, sourceRaw: String) async throws -> String? {
        let resolvedPDF: URL?
        if let u = candidate.pdfURL {
            resolvedPDF = u
        } else if sourceRaw == "pubmed" {
            // PubMed results often have no direct PDF URL; try PMC resolution best-effort.
            resolvedPDF = try await Inf6EshikakuPaperSearch.resolvePubMedPDFURLIfPossible(pmid: candidate.id)
        } else {
            resolvedPDF = nil
        }

        guard let pdfURL = resolvedPDF else { return nil }

        let localURL = try await _downloadPDFToTemporary(url: pdfURL)
        defer { try? FileManager.default.removeItem(at: localURL) }
        return try assetFeatureTextFromLocalPDF(localURL)
    }

    static func assetFeatureTextFromLocalPDF(_ localPDFURL: URL) throws -> String? {
        #if canImport(PDFKit)
        guard let doc = PDFDocument(url: localPDFURL), doc.pageCount > 0 else { return nil }

        let totalPages = doc.pageCount
        var figures: [String] = []
        var tables: [String] = []
        var equations: [String] = []
        figures.reserveCapacity(10)
        tables.reserveCapacity(10)
        equations.reserveCapacity(12)

        for i in 0..<totalPages {
            guard let page = doc.page(at: i), let pageTextRaw = page.string else { continue }
            let pageText = Inf6AssetsAbstractPipeline.normalizeSpaces(pageTextRaw)
            if pageText.isEmpty { continue }

            let pageItems = Inf6AssetsAbstractPipeline.detectItemsForPage(pageIndex: i, pageText: pageText)
            let pageFigures = pageItems
                .filter { $0.kind == .figure }
                .prefix(4)
                .map { $0.titleLine }
            let pageTables = pageItems
                .filter { $0.kind == .table }
                .prefix(4)
                .map { $0.titleLine }
            let pageEquations = _extractEquationLikeLines(from: pageText, limit: 4)

            figures.append(contentsOf: pageFigures)
            tables.append(contentsOf: pageTables)
            equations.append(contentsOf: pageEquations)

            if figures.count >= 10, tables.count >= 10, equations.count >= 12 {
                break
            }
        }

        figures = Array(_stableDedup(figures).prefix(10))
        tables = Array(_stableDedup(tables).prefix(10))
        equations = Array(_stableDedup(equations).prefix(12))

        if figures.isEmpty, tables.isEmpty, equations.isEmpty { return nil }

        var lines: [String] = []
        if !figures.isEmpty {
            lines.append("figures: " + figures.joined(separator: " | "))
        }
        if !tables.isEmpty {
            lines.append("tables: " + tables.joined(separator: " | "))
        }
        if !equations.isEmpty {
            lines.append("equations: " + equations.joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
        #else
        return nil
        #endif
    }

    private static func _downloadPDFToTemporary(url: URL) async throws -> URL {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("application/pdf,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let (tmp, resp) = try await URLSession.shared.download(for: req)

        if let http = resp as? HTTPURLResponse {
            guard (200..<300).contains(http.statusCode) else {
                throw NSError(
                    domain: "inf6.paper.vector",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "PDF download failed: HTTP \(http.statusCode)"]
                )
            }
        }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("inf6-paperchat-\(UUID().uuidString)")
            .appendingPathExtension("pdf")

        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: tmp, to: dest)
        return dest
    }

    private static func _extractEquationLikeLines(from pageText: String, limit: Int) -> [String] {
        let lines = Inf6AssetsAbstractPipeline.splitToLines(pageText)
        if lines.isEmpty { return [] }

        var out: [String] = []
        out.reserveCapacity(limit)

        for line in lines where out.count < max(1, limit) {
            let l = line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if l.isEmpty { continue }

            let hasEqual = l.contains("=") || l.contains("≈") || l.contains("∝")
            let hasMathToken = l.contains("argmin") || l.contains("argmax") || l.contains("\\") || l.contains("∑") || l.contains("∫") || l.contains("λ") || l.contains("∇")
            let digitCount = l.reduce(into: 0) { partial, ch in
                if ch.isNumber { partial += 1 }
            }

            if (hasEqual || hasMathToken) && digitCount >= 1 {
                let clipped = String(l.prefix(180))
                out.append(clipped)
            }
        }

        return out
    }

    private static func _stableDedup(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        out.reserveCapacity(values.count)
        for v in values {
            let key = v.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty { continue }
            if seen.insert(key).inserted {
                out.append(v)
            }
        }
        return out
    }

    private static func _stableID(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for b in s.utf8 {
            hash ^= UInt64(b)
            hash = hash &* prime
        }
        return String(format: "pc_%016llx", hash)
    }

    private static func _loadPersistedMetadataByPaperID() throws -> [String: Inf6PaperSearchResult] {
        let sources = ["arxiv", "pubmed", "acl", "isca"]
        var out: [String: Inf6PaperSearchResult] = [:]
        out.reserveCapacity(4096)

        for source in sources {
            let candidates = try Inf6PaperCorpusBuilder.loadPersistedCandidates(sourceRaw: source)
            for c in candidates {
                let id = c.id.trimmingCharacters(in: .whitespacesAndNewlines)
                if id.isEmpty { continue }
                if out[id] == nil {
                    out[id] = c
                }
            }
        }
        return out
    }
}
