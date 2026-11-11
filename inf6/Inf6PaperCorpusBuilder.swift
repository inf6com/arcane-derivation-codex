//
//  Inf6PaperCorpusBuilder.swift
//  inf6
//
//  arXiv + PubMed + ACL + ISCA corpus fetch and vector-space bootstrap.
//

import Foundation

struct Inf6PaperCorpusBuildPlan {
    var arxivQueries: [String]
    var pubmedTerms: [String]
    var aclQueries: [String]
    var iscaQueries: [String]
    var perQueryMaxResults: Int
    var arxivPDFEnrichBudget: Int
    var pubmedPDFEnrichBudget: Int
    var aclPDFEnrichBudget: Int
    var iscaPDFEnrichBudget: Int

    static func defaultPlan() -> Inf6PaperCorpusBuildPlan {
        Inf6PaperCorpusBuildPlan(
            arxivQueries: [
                "cat:cs.AI OR cat:cs.LG OR cat:stat.ML",
                "cat:cs.CL OR cat:cs.CV OR cat:cs.IR",
                "cat:q-bio.BM OR cat:q-bio.QM OR cat:q-bio.NC",
                "cat:eess.SP OR cat:eess.SY OR cat:physics.app-ph"
            ],
            pubmedTerms: [
                "(machine learning[Title/Abstract] OR artificial intelligence[Title/Abstract])",
                "(deep learning[Title/Abstract] OR foundation model[Title/Abstract])",
                "(biomedical[Title/Abstract] OR clinical[Title/Abstract]) AND (machine learning[Title/Abstract] OR deep learning[Title/Abstract])",
                "(information retrieval[Title/Abstract] OR vector search[Title/Abstract])"
            ],
            aclQueries: [
                "large language models",
                "retrieval augmented generation",
                "dialogue state tracking",
                "speech recognition dialect"
            ],
            iscaQueries: [
                "speech recognition",
                "dialogue system",
                "dialect adaptation",
                "acoustic model"
            ],
            perQueryMaxResults: 20,
            // Corpus bootstrap should be metadata-first. PDF assets are too expensive for bulk precompute.
            arxivPDFEnrichBudget: 0,
            pubmedPDFEnrichBudget: 0,
            aclPDFEnrichBudget: 0,
            iscaPDFEnrichBudget: 0
        )
    }
}

struct Inf6PaperCorpusBuildReport {
    let startedAt: Date
    let completedAt: Date

    let arxivFetchedCount: Int
    let pubmedFetchedCount: Int
    let aclFetchedCount: Int
    let iscaFetchedCount: Int
    let arxivUniqueCount: Int
    let pubmedUniqueCount: Int
    let aclUniqueCount: Int
    let iscaUniqueCount: Int

    let arxivIngest: Inf6PaperVectorIngestResult
    let pubmedIngest: Inf6PaperVectorIngestResult
    let aclIngest: Inf6PaperVectorIngestResult
    let iscaIngest: Inf6PaperVectorIngestResult

    let indexSnapshot: Inf6PaperVectorIndexSnapshot
    let warnings: [String]

    var summaryText: String {
        let arxivIndexed = indexSnapshot.sourceCounts["arxiv"] ?? 0
        let pubmedIndexed = indexSnapshot.sourceCounts["pubmed"] ?? 0
        let aclIndexed = indexSnapshot.sourceCounts["acl"] ?? 0
        let iscaIndexed = indexSnapshot.sourceCounts["isca"] ?? 0
        return "Corpus build completed: arXiv unique=\(arxivUniqueCount), PubMed unique=\(pubmedUniqueCount), ACL unique=\(aclUniqueCount), ISCA unique=\(iscaUniqueCount), index total=\(indexSnapshot.totalPapers), arXiv indexed=\(arxivIndexed), PubMed indexed=\(pubmedIndexed), ACL indexed=\(aclIndexed), ISCA indexed=\(iscaIndexed), warnings=\(warnings.count)"
    }
}

enum Inf6PaperCorpusBuilder {

    private struct _FetchedBatch {
        let fetchedCount: Int
        let uniqueCandidates: [Inf6PaperSearchResult]
        let warnings: [String]
    }

    private struct _PersistedBuildSnapshot: Codable {
        let completedAt: Date
        let indexTotalPapers: Int
        let arxivCount: Int
        let pubmedCount: Int
        let aclCount: Int?
        let iscaCount: Int?
        let warningCount: Int
    }

    private struct _PersistedCandidate: Codable {
        let id: String
        let title: String
        let subtitle: String
        let landingURLString: String
        let pdfURLString: String
        let abstractText: String?
    }

    private static let _persistedBuildSnapshotKey = "inf6_paperchat_corpus_build_snapshot_v1"
    static let minimumPerSourceForReadyCorpus = 20

    static func latestPersistedSnapshotOrNil() -> (completedAt: Date, arxivCount: Int, pubmedCount: Int, indexTotalPapers: Int)? {
        guard let data = UserDefaults.standard.data(forKey: _persistedBuildSnapshotKey) else { return nil }
        guard let snap = try? JSONDecoder().decode(_PersistedBuildSnapshot.self, from: data) else { return nil }
        return (
            completedAt: snap.completedAt,
            arxivCount: snap.arxivCount,
            pubmedCount: snap.pubmedCount,
            indexTotalPapers: snap.indexTotalPapers
        )
    }

    static func isCorpusReady(minimumPerSource: Int = minimumPerSourceForReadyCorpus) throws -> Bool {
        let minRequired = max(1, minimumPerSource)
        let snapshot = try Inf6PaperVectorSearchEngine.indexSnapshot()
        let arxiv = snapshot.sourceCounts["arxiv"] ?? 0
        let pubmed = snapshot.sourceCounts["pubmed"] ?? 0
        let acl = snapshot.sourceCounts["acl"] ?? 0
        let isca = snapshot.sourceCounts["isca"] ?? 0
        return arxiv >= minRequired
            && pubmed >= minRequired
            && acl >= minRequired
            && isca >= minRequired
    }

    static func buildDefaultCorpus() async throws -> Inf6PaperCorpusBuildReport {
        try await build(plan: .defaultPlan())
    }

    static func rebuildVectorSpaceFromPersistedCandidates(
        arxivPDFEnrichBudget: Int = 0,
        pubmedPDFEnrichBudget: Int = 0,
        aclPDFEnrichBudget: Int = 0,
        iscaPDFEnrichBudget: Int = 0
    ) async throws -> Inf6PaperCorpusBuildReport {
        let startedAt = Date()
        let arxivCandidates = try loadPersistedCandidates(sourceRaw: "arxiv")
        let pubmedCandidates = try loadPersistedCandidates(sourceRaw: "pubmed")
        let aclCandidates = try loadPersistedCandidates(sourceRaw: "acl")
        let iscaCandidates = try loadPersistedCandidates(sourceRaw: "isca")

        if arxivCandidates.isEmpty {
            throw NSError(
                domain: "inf6.paper.corpus",
                code: -111,
                userInfo: [NSLocalizedDescriptionKey: "Persisted arXiv candidates are empty."]
            )
        }
        if pubmedCandidates.isEmpty {
            throw NSError(
                domain: "inf6.paper.corpus",
                code: -112,
                userInfo: [NSLocalizedDescriptionKey: "Persisted PubMed candidates are empty."]
            )
        }
        if aclCandidates.isEmpty {
            throw NSError(
                domain: "inf6.paper.corpus",
                code: -113,
                userInfo: [NSLocalizedDescriptionKey: "Persisted ACL candidates are empty."]
            )
        }
        if iscaCandidates.isEmpty {
            throw NSError(
                domain: "inf6.paper.corpus",
                code: -114,
                userInfo: [NSLocalizedDescriptionKey: "Persisted ISCA candidates are empty."]
            )
        }

        let arxivIngest = try await Inf6PaperVectorSearchEngine.ingest(
            sourceRaw: "arxiv",
            candidates: arxivCandidates,
            enrichBudget: max(0, arxivPDFEnrichBudget)
        )
        let pubmedIngest = try await Inf6PaperVectorSearchEngine.ingest(
            sourceRaw: "pubmed",
            candidates: pubmedCandidates,
            enrichBudget: max(0, pubmedPDFEnrichBudget)
        )
        let aclIngest = try await Inf6PaperVectorSearchEngine.ingest(
            sourceRaw: "acl",
            candidates: aclCandidates,
            enrichBudget: max(0, aclPDFEnrichBudget)
        )
        let iscaIngest = try await Inf6PaperVectorSearchEngine.ingest(
            sourceRaw: "isca",
            candidates: iscaCandidates,
            enrichBudget: max(0, iscaPDFEnrichBudget)
        )

        let snapshot = try Inf6PaperVectorSearchEngine.indexSnapshot()
        let report = Inf6PaperCorpusBuildReport(
            startedAt: startedAt,
            completedAt: Date(),
            arxivFetchedCount: arxivCandidates.count,
            pubmedFetchedCount: pubmedCandidates.count,
            aclFetchedCount: aclCandidates.count,
            iscaFetchedCount: iscaCandidates.count,
            arxivUniqueCount: arxivCandidates.count,
            pubmedUniqueCount: pubmedCandidates.count,
            aclUniqueCount: aclCandidates.count,
            iscaUniqueCount: iscaCandidates.count,
            arxivIngest: arxivIngest,
            pubmedIngest: pubmedIngest,
            aclIngest: aclIngest,
            iscaIngest: iscaIngest,
            indexSnapshot: snapshot,
            warnings: []
        )
        _persistBuildSnapshot(report)
        return report
    }

    static func loadPersistedCandidates(sourceRaw: String) throws -> [Inf6PaperSearchResult] {
        let file = try _corpusCandidatesFileURL(sourceRaw: sourceRaw)
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return [] }

        let data = try Data(contentsOf: file)
        let decoded = try JSONDecoder().decode([_PersistedCandidate].self, from: data)
        return decoded.map { item in
            Inf6PaperSearchResult(
                id: item.id,
                title: item.title,
                subtitle: item.subtitle,
                landingURL: URL(string: item.landingURLString),
                pdfURL: URL(string: item.pdfURLString),
                abstractText: item.abstractText ?? ""
            )
        }
    }

    static func build(plan rawPlan: Inf6PaperCorpusBuildPlan) async throws -> Inf6PaperCorpusBuildReport {
        let startedAt = Date()
        let plan = _normalizedPlan(rawPlan)

        async let arxivBatchTask = _fetchArxivBatch(
            queries: plan.arxivQueries,
            maxResultsPerQuery: plan.perQueryMaxResults
        )
        async let pubmedBatchTask = _fetchPubMedBatch(
            terms: plan.pubmedTerms,
            maxResultsPerQuery: plan.perQueryMaxResults
        )
        async let aclBatchTask = _fetchACLBatch(
            queries: plan.aclQueries,
            maxResultsPerQuery: plan.perQueryMaxResults
        )
        async let iscaBatchTask = _fetchISCABatch(
            queries: plan.iscaQueries,
            maxResultsPerQuery: plan.perQueryMaxResults
        )

        let arxivBatch = await arxivBatchTask
        let pubmedBatch = await pubmedBatchTask
        let aclBatch = await aclBatchTask
        let iscaBatch = await iscaBatchTask

        if arxivBatch.uniqueCandidates.isEmpty {
            throw NSError(
                domain: "inf6.paper.corpus",
                code: -101,
                userInfo: [NSLocalizedDescriptionKey: "ArXiv fetch returned zero candidates."]
            )
        }
        if pubmedBatch.uniqueCandidates.isEmpty {
            throw NSError(
                domain: "inf6.paper.corpus",
                code: -102,
                userInfo: [NSLocalizedDescriptionKey: "PubMed fetch returned zero candidates."]
            )
        }
        if aclBatch.uniqueCandidates.isEmpty {
            throw NSError(
                domain: "inf6.paper.corpus",
                code: -103,
                userInfo: [NSLocalizedDescriptionKey: "ACL fetch returned zero candidates."]
            )
        }
        if iscaBatch.uniqueCandidates.isEmpty {
            throw NSError(
                domain: "inf6.paper.corpus",
                code: -104,
                userInfo: [NSLocalizedDescriptionKey: "ISCA fetch returned zero candidates."]
            )
        }

        try _persistCandidates(sourceRaw: "arxiv", candidates: arxivBatch.uniqueCandidates)
        try _persistCandidates(sourceRaw: "pubmed", candidates: pubmedBatch.uniqueCandidates)
        try _persistCandidates(sourceRaw: "acl", candidates: aclBatch.uniqueCandidates)
        try _persistCandidates(sourceRaw: "isca", candidates: iscaBatch.uniqueCandidates)

        let arxivIngest = try await Inf6PaperVectorSearchEngine.ingest(
            sourceRaw: "arxiv",
            candidates: arxivBatch.uniqueCandidates,
            enrichBudget: plan.arxivPDFEnrichBudget
        )
        let pubmedIngest = try await Inf6PaperVectorSearchEngine.ingest(
            sourceRaw: "pubmed",
            candidates: pubmedBatch.uniqueCandidates,
            enrichBudget: plan.pubmedPDFEnrichBudget
        )
        let aclIngest = try await Inf6PaperVectorSearchEngine.ingest(
            sourceRaw: "acl",
            candidates: aclBatch.uniqueCandidates,
            enrichBudget: plan.aclPDFEnrichBudget
        )
        let iscaIngest = try await Inf6PaperVectorSearchEngine.ingest(
            sourceRaw: "isca",
            candidates: iscaBatch.uniqueCandidates,
            enrichBudget: plan.iscaPDFEnrichBudget
        )

        let snapshot = try Inf6PaperVectorSearchEngine.indexSnapshot()
        let completedAt = Date()

        let report = Inf6PaperCorpusBuildReport(
            startedAt: startedAt,
            completedAt: completedAt,
            arxivFetchedCount: arxivBatch.fetchedCount,
            pubmedFetchedCount: pubmedBatch.fetchedCount,
            aclFetchedCount: aclBatch.fetchedCount,
            iscaFetchedCount: iscaBatch.fetchedCount,
            arxivUniqueCount: arxivBatch.uniqueCandidates.count,
            pubmedUniqueCount: pubmedBatch.uniqueCandidates.count,
            aclUniqueCount: aclBatch.uniqueCandidates.count,
            iscaUniqueCount: iscaBatch.uniqueCandidates.count,
            arxivIngest: arxivIngest,
            pubmedIngest: pubmedIngest,
            aclIngest: aclIngest,
            iscaIngest: iscaIngest,
            indexSnapshot: snapshot,
            warnings: arxivBatch.warnings + pubmedBatch.warnings + aclBatch.warnings + iscaBatch.warnings
        )

        _persistBuildSnapshot(report)
        return report
    }

    // MARK: - Fetch

    private static func _fetchArxivBatch(
        queries: [String],
        maxResultsPerQuery: Int
    ) async -> _FetchedBatch {
        let maxResults = max(1, min(50, maxResultsPerQuery))
        var fetchedCount = 0
        var warnings: [String] = []
        var out: [Inf6PaperSearchResult] = []
        out.reserveCapacity(queries.count * maxResults)
        var seen = Set<String>()

        for q0 in queries {
            let q = q0.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty { continue }
            do {
                let results = try await Inf6ArxivClient.search(query: q, maxResults: maxResults)
                fetchedCount += results.count
                for r in results {
                    let k = _dedupKey(r)
                    if k.isEmpty { continue }
                    if seen.insert(k).inserted {
                        out.append(r)
                    }
                }
            } catch {
                warnings.append("arXiv query failed: \(q) (\(error.localizedDescription))")
            }
        }

        return _FetchedBatch(
            fetchedCount: fetchedCount,
            uniqueCandidates: out,
            warnings: warnings
        )
    }

    private static func _fetchPubMedBatch(
        terms: [String],
        maxResultsPerQuery: Int
    ) async -> _FetchedBatch {
        let maxResults = max(1, min(20, maxResultsPerQuery))
        var fetchedCount = 0
        var warnings: [String] = []
        var out: [Inf6PaperSearchResult] = []
        out.reserveCapacity(terms.count * maxResults)
        var seen = Set<String>()

        for t0 in terms {
            let term = t0.trimmingCharacters(in: .whitespacesAndNewlines)
            if term.isEmpty { continue }
            do {
                let results = try await Inf6PubMedClient.search(term: term, maxResults: maxResults)
                fetchedCount += results.count
                for r in results {
                    let k = _dedupKey(r)
                    if k.isEmpty { continue }
                    if seen.insert(k).inserted {
                        out.append(r)
                    }
                }
            } catch {
                warnings.append("PubMed term failed: \(term) (\(error.localizedDescription))")
            }
        }

        return _FetchedBatch(
            fetchedCount: fetchedCount,
            uniqueCandidates: out,
            warnings: warnings
        )
    }

    private static func _fetchACLBatch(
        queries: [String],
        maxResultsPerQuery: Int
    ) async -> _FetchedBatch {
        let maxResults = max(1, min(50, maxResultsPerQuery))
        var fetchedCount = 0
        var warnings: [String] = []
        var out: [Inf6PaperSearchResult] = []
        out.reserveCapacity(queries.count * maxResults)
        var seen = Set<String>()

        for q0 in queries {
            let q = q0.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty { continue }
            do {
                let results = try await Inf6ACLAnthologyClient.search(query: q, maxResults: maxResults)
                fetchedCount += results.count
                for r in results {
                    let k = _dedupKey(r)
                    if k.isEmpty { continue }
                    if seen.insert(k).inserted {
                        out.append(r)
                    }
                }
            } catch {
                warnings.append("ACL query failed: \(q) (\(error.localizedDescription))")
            }
        }

        return _FetchedBatch(
            fetchedCount: fetchedCount,
            uniqueCandidates: out,
            warnings: warnings
        )
    }

    private static func _fetchISCABatch(
        queries: [String],
        maxResultsPerQuery: Int
    ) async -> _FetchedBatch {
        let maxResults = max(1, min(50, maxResultsPerQuery))
        var fetchedCount = 0
        var warnings: [String] = []
        var out: [Inf6PaperSearchResult] = []
        out.reserveCapacity(queries.count * maxResults)
        var seen = Set<String>()

        for q0 in queries {
            let q = q0.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty { continue }
            do {
                let results = try await Inf6ISCAArchiveClient.search(query: q, maxResults: maxResults)
                fetchedCount += results.count
                for r in results {
                    let k = _dedupKey(r)
                    if k.isEmpty { continue }
                    if seen.insert(k).inserted {
                        out.append(r)
                    }
                }
            } catch {
                warnings.append("ISCA query failed: \(q) (\(error.localizedDescription))")
            }
        }

        return _FetchedBatch(
            fetchedCount: fetchedCount,
            uniqueCandidates: out,
            warnings: warnings
        )
    }

    // MARK: - Helpers

    private static func _normalizedPlan(_ plan: Inf6PaperCorpusBuildPlan) -> Inf6PaperCorpusBuildPlan {
        var p = plan
        p.arxivQueries = _dedupNonEmpty(plan.arxivQueries)
        p.pubmedTerms = _dedupNonEmpty(plan.pubmedTerms)
        p.aclQueries = _dedupNonEmpty(plan.aclQueries)
        p.iscaQueries = _dedupNonEmpty(plan.iscaQueries)
        p.perQueryMaxResults = max(1, min(50, plan.perQueryMaxResults))
        p.arxivPDFEnrichBudget = max(0, plan.arxivPDFEnrichBudget)
        p.pubmedPDFEnrichBudget = max(0, plan.pubmedPDFEnrichBudget)
        p.aclPDFEnrichBudget = max(0, plan.aclPDFEnrichBudget)
        p.iscaPDFEnrichBudget = max(0, plan.iscaPDFEnrichBudget)
        return p
    }

    private static func _dedupNonEmpty(_ values: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        out.reserveCapacity(values.count)

        for raw in values {
            let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty { continue }
            let key = v.lowercased()
            if seen.insert(key).inserted {
                out.append(v)
            }
        }
        return out
    }

    private static func _dedupKey(_ result: Inf6PaperSearchResult) -> String {
        let id = result.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty { return "" }
        return id.lowercased()
    }

    private static func _persistBuildSnapshot(_ report: Inf6PaperCorpusBuildReport) {
        let arxiv = report.indexSnapshot.sourceCounts["arxiv"] ?? 0
        let pubmed = report.indexSnapshot.sourceCounts["pubmed"] ?? 0
        let acl = report.indexSnapshot.sourceCounts["acl"] ?? 0
        let isca = report.indexSnapshot.sourceCounts["isca"] ?? 0
        let snap = _PersistedBuildSnapshot(
            completedAt: report.completedAt,
            indexTotalPapers: report.indexSnapshot.totalPapers,
            arxivCount: arxiv,
            pubmedCount: pubmed,
            aclCount: acl,
            iscaCount: isca,
            warningCount: report.warnings.count
        )

        guard let data = try? JSONEncoder().encode(snap) else { return }
        UserDefaults.standard.set(data, forKey: _persistedBuildSnapshotKey)
    }

    private static func _persistCandidates(sourceRaw: String, candidates: [Inf6PaperSearchResult]) throws {
        let file = try _corpusCandidatesFileURL(sourceRaw: sourceRaw)
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)

        let payload: [_PersistedCandidate] = candidates.map { c in
            _PersistedCandidate(
                id: c.id,
                title: c.title,
                subtitle: c.subtitle,
                landingURLString: c.landingURL?.absoluteString ?? "",
                pdfURLString: c.pdfURL?.absoluteString ?? "",
                abstractText: c.abstractText
            )
        }

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(payload)
        try data.write(to: file, options: [.atomic])
    }

    private static func _corpusCandidatesFileURL(sourceRaw: String) throws -> URL {
        let base = try Inf6PaperVectorSearchEngine.vectorBaseDir()
        let cleaned = sourceRaw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let source = cleaned.isEmpty ? "unknown" : cleaned

        return base
            .appendingPathComponent("paper.corpus.raw", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("\(source).candidates.json", isDirectory: false)
    }
}
