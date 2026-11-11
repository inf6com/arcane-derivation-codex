import Foundation

extension Notification.Name {
    static let inf6SyllabusPaperLinksDidChange = Notification.Name("Inf6SyllabusPaperLinksDidChange")
}

struct Inf6SyllabusPaperLink: Codable, Hashable {
    let sourceFamily: String
    let syllabusNodeID: String
    let paperID: String
    let providerID: String
    let query: String
    let score: Double
    let searchedAt: Date
    let origin: String?
    let originHistory: String?
    let sourceRole: String?
    let originPeriod: String?
    let originChronology: [String]?
    let verificationStatus: String?
    let verificationEvidence: String?
    let originRecordVersion: Int?

    enum CodingKeys: String, CodingKey {
        case sourceFamily, syllabusNodeID, paperID, providerID, query, score, searchedAt
        case origin
        case originEvidence = "origin_evidence"
        case originHistory = "origin_history"
        case sourceRole = "source_role"
        case originPeriod = "origin_period"
        case originChronology = "origin_chronology"
        case verificationStatus = "verification_status"
        case verificationEvidence = "verification_evidence"
        case originRecordVersion = "origin_record_version"
    }

    init(
        sourceFamily: String,
        syllabusNodeID: String,
        paperID: String,
        providerID: String,
        query: String,
        score: Double,
        searchedAt: Date,
        origin: String? = nil,
        originHistory: String? = nil,
        sourceRole: String? = nil,
        originPeriod: String? = nil,
        originChronology: [String]? = nil,
        verificationStatus: String? = nil,
        verificationEvidence: String? = nil,
        originRecordVersion: Int? = nil
    ) {
        self.sourceFamily = sourceFamily
        self.syllabusNodeID = syllabusNodeID
        self.paperID = paperID
        self.providerID = providerID
        self.query = query
        self.score = score
        self.searchedAt = searchedAt
        self.origin = origin?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.originHistory = originHistory?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceRole = sourceRole?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.originPeriod = originPeriod?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.originChronology = originChronology?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.verificationStatus = verificationStatus?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.verificationEvidence = verificationEvidence?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.originRecordVersion = originRecordVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceFamily = try c.decode(String.self, forKey: .sourceFamily)
        syllabusNodeID = try c.decode(String.self, forKey: .syllabusNodeID)
        paperID = try c.decode(String.self, forKey: .paperID)
        providerID = try c.decode(String.self, forKey: .providerID)
        query = try c.decode(String.self, forKey: .query)
        score = try c.decode(Double.self, forKey: .score)
        searchedAt = try Self._decodeStoredDate(from: c)
        let explicitOrigin = try c.decodeIfPresent(String.self, forKey: .origin)
        let legacyOrigin = try c.decodeIfPresent(String.self, forKey: .originEvidence)
        origin = (explicitOrigin ?? legacyOrigin)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        originHistory = try c.decodeIfPresent(String.self, forKey: .originHistory)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        sourceRole = try c.decodeIfPresent(String.self, forKey: .sourceRole)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        originPeriod = try c.decodeIfPresent(String.self, forKey: .originPeriod)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        originChronology = try c.decodeIfPresent([String].self, forKey: .originChronology)?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        verificationStatus = try c.decodeIfPresent(String.self, forKey: .verificationStatus)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        verificationEvidence = try c.decodeIfPresent(String.self, forKey: .verificationEvidence)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        originRecordVersion = try c.decodeIfPresent(Int.self, forKey: .originRecordVersion)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sourceFamily, forKey: .sourceFamily)
        try c.encode(syllabusNodeID, forKey: .syllabusNodeID)
        try c.encode(paperID, forKey: .paperID)
        try c.encode(providerID, forKey: .providerID)
        try c.encode(query, forKey: .query)
        try c.encode(score, forKey: .score)
        try c.encode(searchedAt, forKey: .searchedAt)
        try c.encodeIfPresent(origin, forKey: .origin)
        try c.encodeIfPresent(originHistory, forKey: .originHistory)
        try c.encodeIfPresent(sourceRole, forKey: .sourceRole)
        try c.encodeIfPresent(originPeriod, forKey: .originPeriod)
        try c.encodeIfPresent(originChronology, forKey: .originChronology)
        try c.encodeIfPresent(verificationStatus, forKey: .verificationStatus)
        try c.encodeIfPresent(verificationEvidence, forKey: .verificationEvidence)
        try c.encodeIfPresent(originRecordVersion, forKey: .originRecordVersion)
    }

    private static func _decodeStoredDate(
        from c: KeyedDecodingContainer<CodingKeys>
    ) throws -> Date {
        if let numeric = try? c.decode(Double.self, forKey: .searchedAt) {
            return Date(timeIntervalSinceReferenceDate: numeric)
        }
        let text = try c.decode(String.self, forKey: .searchedAt)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: trimmed) {
            return date
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        if let date = formatter.date(from: trimmed) {
            return date
        }
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let date = formatter.date(from: trimmed) {
            return date
        }

        throw DecodingError.dataCorruptedError(
            forKey: .searchedAt,
            in: c,
            debugDescription: "Unsupported searchedAt value: \(trimmed)"
        )
    }
}

struct Inf6SyllabusPaperAutoSearchReport {
    let sourceFamily: String
    let searchedNodeCount: Int
    let storedPaperCount: Int
    let storedLinkCount: Int
}

enum Inf6SyllabusPaperAutoSearch {
    private static let _maxResultsPerNode = 10
    private static let _maxLinksPerNode = 5
    private static let _minimumScore = 2.0

    static func linkRevision(sourceFamily: String) -> String? {
        Inf6MetadataStore.get(
            domain: .settings,
            key: "syllabus_paper_links_revision:\(sourceFamily)"
        )
    }

    private static func _recordLinkRevision(sourceFamily: String) {
        Inf6MetadataStore.put(
            domain: .settings,
            key: "syllabus_paper_links_revision:\(sourceFamily)",
            json: UUID().uuidString
        )
    }

    static func linkedPaperIDs(sourceFamily: String, syllabusNodeID: String) -> [String] {
        let prefix = _linkKeyPrefix(sourceFamily: sourceFamily, syllabusNodeID: syllabusNodeID)
        return Inf6MetadataStore.listByPrefix(domain: .syllabusPaperLinks, prefix: prefix)
            .compactMap { pair -> Inf6SyllabusPaperLink? in
                guard let data = pair.json.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(Inf6SyllabusPaperLink.self, from: data)
            }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.paperID.localizedStandardCompare($1.paperID) == .orderedAscending
            }
            .map(\.paperID)
    }

    static func linkedPaperIDSet(sourceFamily: String) -> Set<String> {
        Set(
            Inf6MetadataStore.listByPrefix(domain: .syllabusPaperLinks, prefix: "\(sourceFamily)|")
                .compactMap { pair -> Inf6SyllabusPaperLink? in
                    guard let data = pair.json.data(using: .utf8) else { return nil }
                    return try? JSONDecoder().decode(Inf6SyllabusPaperLink.self, from: data)
                }
                .map(\.paperID)
        )
    }

    static func linkCount(sourceFamily: String) -> Int {
        Inf6MetadataStore.listByPrefix(domain: .syllabusPaperLinks, prefix: "\(sourceFamily)|").count
    }

    static func refreshJDLAEshikakuFromCurrentOutline() async throws -> Inf6SyllabusPaperAutoSearchReport {
        let sourceFamily = "jdla_eshikaku"
        let outlineItems = try _currentEshikakuOutlineItems()
        return try await refresh(sourceFamily: sourceFamily, outlineItems: outlineItems)
    }

    static func refresh(
        sourceFamily: String,
        outlineItems: [Inf6SyllabusOutlineItem]
    ) async throws -> Inf6SyllabusPaperAutoSearchReport {
        let targets = _leafItems(outlineItems)
        guard !targets.isEmpty else {
            throw NSError(
                domain: "Inf6SyllabusPaperAutoSearch",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Syllabus outline leaf items are empty: \(sourceFamily)"]
            )
        }

        var storedPapers = Set<String>()
        var storedLinks = 0

        for item in targets {
            let query = _searchQuery(for: item, outlineItems: outlineItems)
            guard !query.isEmpty else { continue }
            _deleteExistingLinks(sourceFamily: sourceFamily, syllabusNodeID: item.key)
            let candidates = try await Inf6ArxivClient.search(
                query: _arxivSearchQuery(for: query),
                maxResults: _maxResultsPerNode
            )
            let ranked = _rank(candidates: candidates, query: query)
            for hit in ranked.prefix(_maxLinksPerNode) where hit.score >= _minimumScore {
                let paper = _corePaper(from: hit.result, sourceFamily: sourceFamily, nodeID: item.key)
                Inf6MetadataStore.putCodable(paper, domain: .papers, key: paper.id)
                storedPapers.insert(paper.id)

                let link = Inf6SyllabusPaperLink(
                    sourceFamily: sourceFamily,
                    syllabusNodeID: item.key,
                    paperID: paper.id,
                    providerID: paper.provider,
                    query: query,
                    score: hit.score,
                    searchedAt: Date()
                )
                Inf6MetadataStore.putCodable(
                    link,
                    domain: .syllabusPaperLinks,
                    key: _linkKey(sourceFamily: sourceFamily, syllabusNodeID: item.key, paperID: paper.id)
                )
                storedLinks += 1
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        _structureTitleEnCache = nil
        Inf6CorePaperStore.shared.reloadPapersFromMetadataStore()
        Inf6KnowledgeDomainStructureStore.invalidateCache()
        _recordLinkRevision(sourceFamily: sourceFamily)
        Inf6MetadataStore.put(domain: .settings, key: "syllabus_paper_auto_search_status", json: "ok")
        Inf6MetadataStore.put(domain: .settings, key: "syllabus_paper_auto_search_at", json: String(Date().timeIntervalSince1970))
        NotificationCenter.default.post(name: .inf6SyllabusPaperLinksDidChange, object: nil)
        return Inf6SyllabusPaperAutoSearchReport(
            sourceFamily: sourceFamily,
            searchedNodeCount: targets.count,
            storedPaperCount: storedPapers.count,
            storedLinkCount: storedLinks
        )
    }

    /// Discovers additional origin candidates during an explicit origin-resolution
    /// operation. Existing links are preserved; discovery never marks a result as
    /// an origin and never replaces the syllabus structure.
    static func discoverOriginCandidates(
        sourceFamily: String,
        syllabusNodeID: String,
        queries: [String]
    ) async throws -> [String] {
        let normalizedQueries = queries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, query in
                if !result.contains(query) { result.append(query) }
            }
        guard !normalizedQueries.isEmpty else {
            throw NSError(
                domain: "Inf6SyllabusPaperAutoSearch",
                code: 41,
                userInfo: [NSLocalizedDescriptionKey: "起源探索クエリがありません。LLMに概念史から検索クエリを生成させてください。"]
            )
        }

        let existingLinks = Inf6MetadataStore
            .listByPrefix(domain: .syllabusPaperLinks, prefix: _linkKeyPrefix(sourceFamily: sourceFamily, syllabusNodeID: syllabusNodeID))
            .compactMap { pair -> Inf6SyllabusPaperLink? in
                guard let data = pair.json.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(Inf6SyllabusPaperLink.self, from: data)
        }
        var knownPaperIDs = Set(existingLinks.map(\.paperID))
        var knownLinkIDs = Set(existingLinks.map(\.paperID))
        var discoveredIDs: [String] = []
        var wroteLink = false

        for query in normalizedQueries.prefix(3) {
            try Task.checkCancellation()
            let arxivResults = try await Inf6ArxivClient.search(
                query: _arxivSearchQuery(for: query),
                maxResults: _maxResultsPerNode,
                sortBy: "relevance",
                sortOrder: "descending"
            )
            let rankedArxiv = _rank(candidates: arxivResults, query: query)
            for hit in rankedArxiv.prefix(_maxLinksPerNode) where hit.score >= _minimumScore {
                let paper = _corePaper(from: hit.result, sourceFamily: sourceFamily, nodeID: syllabusNodeID)
                if !knownPaperIDs.contains(paper.id) {
                    Inf6MetadataStore.putCodable(paper, domain: .papers, key: paper.id)
                    knownPaperIDs.insert(paper.id)
                    discoveredIDs.append(paper.id)
                }
                if knownLinkIDs.insert(paper.id).inserted {
                    let link = Inf6SyllabusPaperLink(
                        sourceFamily: sourceFamily,
                        syllabusNodeID: syllabusNodeID,
                        paperID: paper.id,
                        providerID: paper.provider,
                        query: query,
                        score: hit.score,
                        searchedAt: Date()
                    )
                    Inf6MetadataStore.putCodable(
                        link,
                        domain: .syllabusPaperLinks,
                        key: _linkKey(sourceFamily: sourceFamily, syllabusNodeID: syllabusNodeID, paperID: paper.id)
                    )
                    wroteLink = true
                }
            }

            try Task.checkCancellation()
            let openAlexResults = try await Inf6OpenAlexClient.search(query: query, maxResults: _maxResultsPerNode)
            let rankedOpenAlex = _rank(candidates: openAlexResults, query: query)
            for hit in rankedOpenAlex.prefix(_maxLinksPerNode) where hit.score >= _minimumScore {
                let paper = _corePaper(from: hit.result, sourceFamily: sourceFamily, nodeID: syllabusNodeID, provider: "openalex")
                if !knownPaperIDs.contains(paper.id) {
                    Inf6MetadataStore.putCodable(paper, domain: .papers, key: paper.id)
                    knownPaperIDs.insert(paper.id)
                    discoveredIDs.append(paper.id)
                }
                if knownLinkIDs.insert(paper.id).inserted {
                    let link = Inf6SyllabusPaperLink(
                        sourceFamily: sourceFamily,
                        syllabusNodeID: syllabusNodeID,
                        paperID: paper.id,
                        providerID: paper.provider,
                        query: query,
                        score: hit.score,
                        searchedAt: Date()
                    )
                    Inf6MetadataStore.putCodable(
                        link,
                        domain: .syllabusPaperLinks,
                        key: _linkKey(sourceFamily: sourceFamily, syllabusNodeID: syllabusNodeID, paperID: paper.id)
                    )
                    wroteLink = true
                }
            }
        }

        if wroteLink {
            _recordLinkRevision(sourceFamily: sourceFamily)
            Inf6CorePaperStore.shared.reloadPapersFromMetadataStore()
            Inf6KnowledgeDomainStructureStore.invalidateCache()
            NotificationCenter.default.post(name: .inf6SyllabusPaperLinksDidChange, object: nil)
        }
        return discoveredIDs
    }

    private static func _currentEshikakuOutlineItems() throws -> [Inf6SyllabusOutlineItem] {
        let cacheURL = try Inf6Storage.syllabusOutlineCacheURL()
        guard let cache = Inf6DiskJSON.load([String: [Inf6SyllabusOutlineItem]].self, from: cacheURL) else {
            throw NSError(
                domain: "Inf6SyllabusPaperAutoSearch",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Syllabus outline cache is missing or unreadable: \(cacheURL.path)"]
            )
        }
        let candidates = cache.compactMap { key, items -> (rank: Int, count: Int, items: [Inf6SyllabusOutlineItem])? in
            let lower = key.lowercased()
            guard lower.contains("eshikaku_outline") || lower.contains("e-syllabus") || lower.contains("e%e8%b3%87%e6%a0%bc") else {
                return nil
            }
            let rank = lower.contains("2026") || lower.contains("e-syllabus") ? 1 : 0
            return (rank, items.count, items)
        }
        guard let selected = candidates.max(by: {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return $0.count < $1.count
        }) else {
            throw NSError(
                domain: "Inf6SyllabusPaperAutoSearch",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "E資格 outline cache entry is not present."]
            )
        }
        return selected.items
    }

    private static func _leafItems(_ items: [Inf6SyllabusOutlineItem]) -> [Inf6SyllabusOutlineItem] {
        var leaves: [Inf6SyllabusOutlineItem] = []
        for index in items.indices {
            let depth = items[index].effectiveDepth
            let nextIsChild = items.indices.contains(index + 1) && items[index + 1].effectiveDepth > depth
            if !nextIsChild {
                leaves.append(items[index])
            }
        }
        return leaves
    }

    private static func _searchQuery(for item: Inf6SyllabusOutlineItem, outlineItems: [Inf6SyllabusOutlineItem]) -> String {
        let titleEn = (item.titleEn ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !titleEn.isEmpty { return titleEn }
        let mapped = (Inf6KnowledgeDomainStructureStore
            .englishSyllabusTitle(item.titleJa ?? item.title) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !mapped.isEmpty { return mapped }
        let dbEN = _titleEnFromStructureDB(nodeID: item.key)
        if !dbEN.isEmpty { return dbEN }
        return (item.titleJa ?? item.title).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var _structureTitleEnCache: [String: String]?

    private static func _titleEnFromStructureDB(nodeID: String) -> String {
        if _structureTitleEnCache == nil {
            var cache: [String: String] = [:]
            for item in Inf6MetadataStore.listByPrefix(domain: .syllabus, prefix: "structure:") {
                guard let data = item.json.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let nodes = root["nodes"] as? [[String: Any]] else { continue }
                for node in nodes {
                    guard let nid = node["node_id"] as? String,
                          let en = node["title_en"] as? String else { continue }
                    let trimmed = en.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { cache[nid] = trimmed }
                }
            }
            _structureTitleEnCache = cache
        }
        return _structureTitleEnCache?[nodeID] ?? ""
    }

    private static func _ancestorItems(for item: Inf6SyllabusOutlineItem, in items: [Inf6SyllabusOutlineItem]) -> [Inf6SyllabusOutlineItem] {
        guard let index = items.firstIndex(where: { $0.key == item.key }) else { return [] }
        let depth = item.effectiveDepth
        guard depth > 0 else { return [] }
        var ancestors: [Inf6SyllabusOutlineItem] = []
        var wantedDepth = depth - 1
        var cursor = index
        while cursor > items.startIndex {
            cursor -= 1
            let candidate = items[cursor]
            if candidate.effectiveDepth == wantedDepth {
                ancestors.insert(candidate, at: 0)
                if wantedDepth == 0 { break }
                wantedDepth -= 1
            }
        }
        return ancestors
    }

    private static func _rank(candidates: [Inf6PaperSearchResult], query: String) -> [(result: Inf6PaperSearchResult, score: Double)] {
        let orderedQueryTokens = _tokens(query)
        let queryTokens = Set(orderedQueryTokens)
        let requiredTokens = _requiredTokens(queryTokens)
        let phraseTokens = orderedQueryTokens.filter { $0.count >= 5 }
        let phrase = phraseTokens.count >= 2 ? phraseTokens.joined(separator: " ") : ""
        return candidates.map { result in
            let haystack = [
                result.title,
                result.subtitle,
                result.abstractText
            ].joined(separator: " ").lowercased()
            if !phrase.isEmpty && !haystack.contains(phrase) {
                return (result, 0.0)
            }
            let tokens = Set(_tokens(haystack))
            let overlap = queryTokens.intersection(tokens).count
            let requiredOverlap = requiredTokens.intersection(tokens).count
            let phraseScore = phrase.isEmpty ? 0.0 : 3.0
            let titleScore = Set(_tokens(result.title)).intersection(queryTokens).isEmpty ? 0.0 : 1.0
            let recencyScore: Double = {
                guard let pub = result.publishedAt else { return 0.0 }
                let year = Calendar.current.component(.year, from: pub)
                let currentYear = Calendar.current.component(.year, from: Date())
                let age = max(0, currentYear - year)
                if age <= 2 { return 2.0 }
                if age <= 5 { return 1.0 }
                return 0.0
            }()
            let score = requiredTokens.isEmpty || requiredOverlap >= min(2, requiredTokens.count)
                ? Double(overlap) + phraseScore + titleScore + recencyScore
                : 0.0
            return (result, score)
        }
        .filter { $0.score > 0 }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.result.title.localizedStandardCompare($1.result.title) == .orderedAscending
            }
    }

    private static func _arxivSearchQuery(for query: String) -> String {
        let tokens = _tokens(query)
        guard !tokens.isEmpty else { return query }
        let longTokens = tokens.filter { $0.count >= 5 }
        let phrase = longTokens.count >= 2 ? longTokens.joined(separator: " ") : tokens.joined(separator: " ")
        if tokens.count == 1 { return "all:\(tokens[0])" }
        return #"ti:"\#(phrase)" OR abs:"\#(phrase)""#
    }

    private static func _tokens(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 3 && !_stopWords.contains($0) }
    }

    private static let _stopWords: Set<String> = [
        "and", "for", "the", "with", "from", "into", "using", "used", "use", "based", "model", "models",
        "learning", "deep", "machine", "neural", "network", "networks", "method", "methods"
    ]

    private static func _requiredTokens(_ tokens: Set<String>) -> Set<String> {
        tokens.subtracting([
            "classification", "evaluation", "selection", "foundations", "overview",
            "calculation", "metrics", "performance", "methods", "techniques"
        ])
    }

    private static func _corePaper(
        from result: Inf6PaperSearchResult,
        sourceFamily: String,
        nodeID: String,
        provider: String = "arxiv"
    ) -> Inf6CorePaper {
        let arxivID = provider == "arxiv" ? _arxivID(from: result) : nil
        let year = result.publishedAt.map { Calendar(identifier: .gregorian).component(.year, from: $0) }
            ?? _year(from: result.subtitle)
        return Inf6CorePaper(
            id: result.id,
            title: result.title,
            titleEn: result.title,
            provider: provider,
            arxivId: arxivID,
            pdfURL: result.pdfURL?.absoluteString,
            year: year,
            tags: ["auto_search", sourceFamily, "syllabus_node:\(nodeID)"]
        )
    }

    private static func _year(from text: String) -> Int? {
        guard let match = text.range(of: #"\b(?:19|20)\d{2}\b"#, options: .regularExpression) else { return nil }
        return Int(text[match])
    }

    private static func _arxivID(from result: Inf6PaperSearchResult) -> String? {
        if result.id.lowercased().hasPrefix("arxiv:") {
            return String(result.id.dropFirst("arxiv:".count))
        }
        if let url = result.landingURL ?? result.pdfURL {
            let last = url.lastPathComponent
            if !last.isEmpty { return last.replacingOccurrences(of: ".pdf", with: "") }
        }
        return nil
    }

    private static func _linkKeyPrefix(sourceFamily: String, syllabusNodeID: String) -> String {
        "\(sourceFamily)|\(syllabusNodeID)|"
    }

    private static func _linkKey(sourceFamily: String, syllabusNodeID: String, paperID: String) -> String {
        _linkKeyPrefix(sourceFamily: sourceFamily, syllabusNodeID: syllabusNodeID) + paperID
    }

    private static func _deleteExistingLinks(sourceFamily: String, syllabusNodeID: String) {
        for pair in Inf6MetadataStore.listByPrefix(
            domain: .syllabusPaperLinks,
            prefix: _linkKeyPrefix(sourceFamily: sourceFamily, syllabusNodeID: syllabusNodeID)
        ) {
            Inf6MetadataStore.delete(domain: .syllabusPaperLinks, key: pair.key)
        }
    }
}
