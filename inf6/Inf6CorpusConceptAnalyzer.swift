//
//  Inf6CorpusConceptAnalyzer.swift
//  inf6
//
//  コーパス分析契約:
//    - シラバス見出しは entry point であり、概念 identity はコーパス内の出現根拠で決める。
//    - 候補概念、出現箇所、関係、指標は metadata file store に保存し、表示都合の一時データにしない。
//

import Foundation

struct Inf6CorpusConceptCandidate: Codable, Hashable, Sendable {
    let candidateID: String
    let canonicalID: String
    var displayTitleJA: String?
    var displayTitleEN: String?
    var sourceDomains: Set<String>
    var mentionIDs: Set<String>
    var evidenceIDs: Set<String>
    var firstObservedAt: TimeInterval
    var lastObservedAt: TimeInterval
}

struct Inf6CorpusConceptMention: Codable, Hashable, Sendable {
    let mentionID: String
    let candidateID: String
    let canonicalID: String
    let surface: String
    let sourceKind: Inf6KnowledgeSourceKind
    let sourceID: String
    let domainID: String?
    let field: String
    let rangeStart: Int
    let rangeLength: Int
    let snippet: String
    let observedAt: TimeInterval
}

struct Inf6CorpusConceptRelationObservation: Codable, Hashable, Sendable {
    let relationID: String
    let fromConceptID: String
    let toConceptID: String
    let kind: Inf6KnowledgeRelationKind
    let sourceKind: Inf6KnowledgeSourceKind
    let sourceID: String
    let evidenceIDs: Set<String>
    let supportCount: Int
    let observedAt: TimeInterval
}

struct Inf6ConceptMetric: Codable, Hashable, Sendable {
    let canonicalID: String
    let corpusWeight: Double
    let historicalWeight: Double
    let achievementWeight: Double
    let freshnessWeight: Double
    let unknownBoundaryWeight: Double
    let sourceDomainCount: Int
    let mentionCount: Int
    let paperMentionCount: Int
    let syllabusMentionCount: Int
    let relationCount: Int
    let evidenceIDs: Set<String>
    let updatedAt: TimeInterval
}

struct Inf6CorpusAnalysisSummary: Codable, Hashable, Sendable {
    let analyzedAt: TimeInterval
    let sourceCount: Int
    let candidateCount: Int
    let mentionCount: Int
    let relationCount: Int
    let metricCount: Int
}

enum Inf6CorpusConceptAnalyzer {

    struct DomainCorpus: Hashable {
        let domainID: String
        let sourceFamily: String
        let sourceKind: Inf6KnowledgeSourceKind
        let displayTitleJA: String
        let displayTitleEN: String
        let outlineItems: [Inf6SyllabusOutlineItem]
    }

    private struct _SourceText {
        let sourceKind: Inf6KnowledgeSourceKind
        let sourceID: String
        let domainID: String?
        let field: String
        let text: String
        let seeds: [String]
        let titleENByJA: [String: String]
        let paperYear: Int?
        let paperProgress: Inf6CorePaperProgress?
    }

    private struct _Accumulator {
        var candidates: [String: Inf6CorpusConceptCandidate] = [:]
        var mentions: [String: Inf6CorpusConceptMention] = [:]
        var evidence: [String: Inf6KnowledgeEvidence] = [:]
        var memberships: [String: Inf6KnowledgeMembership] = [:]
        var relationEvidence: [String: (from: String, to: String, kind: Inf6KnowledgeRelationKind, sourceKind: Inf6KnowledgeSourceKind, sourceID: String, evidenceIDs: Set<String>)] = [:]
        var paperMentionCountByConcept: [String: Int] = [:]
        var syllabusMentionCountByConcept: [String: Int] = [:]
        var paperYearByConcept: [String: Set<Int>] = [:]
        var achievementByConcept: [String: Double] = [:]
    }

    static func analyzeAndPersist(
        domains: [DomainCorpus],
        papers: [Inf6CorePaper],
        progress: [String: Inf6CorePaperProgress]
    ) throws -> Inf6CorpusAnalysisSummary {
        let sources = _buildSources(domains: domains, papers: papers, progress: progress)
        guard !sources.isEmpty else {
            throw NSError(
                domain: "Inf6CorpusConceptAnalyzer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "corpus analysis requires at least one source"]
            )
        }

        let now = Date().timeIntervalSince1970
        var acc = _Accumulator()

        for source in sources {
            let conceptIDs = try _analyze(source: source, observedAt: now, accumulator: &acc)
            try _recordCooccurrenceRelations(source: source, conceptIDs: conceptIDs, accumulator: &acc)
        }

        let relations = try _materializeRelations(acc.relationEvidence, observedAt: now)
        let metrics = _materializeMetrics(accumulator: acc, relations: relations, observedAt: now)

        try _persist(
            candidates: Array(acc.candidates.values),
            mentions: Array(acc.mentions.values),
            evidence: Array(acc.evidence.values),
            memberships: Array(acc.memberships.values),
            relations: relations,
            metrics: metrics
        )

        let summary = Inf6CorpusAnalysisSummary(
            analyzedAt: now,
            sourceCount: sources.count,
            candidateCount: acc.candidates.count,
            mentionCount: acc.mentions.count,
            relationCount: relations.count,
            metricCount: metrics.count
        )
        Inf6MetadataStore.putCodable(summary, domain: .settings, key: "corpus_analysis_summary")
        return summary
    }

    private static func _buildSources(
        domains: [DomainCorpus],
        papers: [Inf6CorePaper],
        progress: [String: Inf6CorePaperProgress]
    ) -> [_SourceText] {
        var sources: [_SourceText] = []

        for domain in domains {
            for item in domain.outlineItems {
                let itemID = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
                if itemID.isEmpty { continue }

                let titleJA = _preferredJA(item)
                let titleEN = _preferredEN(item)
                let summaryJA = item.summaryJa?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? item.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? ""
                let summaryEN = item.summaryEn?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                var seeds = Inf6AtomicConceptExtractor.extractAll(from: [titleJA, titleEN])
                seeds.append(contentsOf: _extractPhrases(from: summaryJA))
                seeds.append(contentsOf: _extractPhrases(from: summaryEN))
                seeds = _dedupe(seeds).filter(_isConceptLike)

                let text = [titleJA, titleEN, summaryJA, summaryEN]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }

                sources.append(_SourceText(
                    sourceKind: domain.sourceKind,
                    sourceID: "\(domain.domainID)/outline/\(itemID)",
                    domainID: domain.domainID,
                    field: "outline",
                    text: text,
                    seeds: seeds,
                    titleENByJA: titleEN.isEmpty ? [:] : [titleJA: titleEN],
                    paperYear: nil,
                    paperProgress: nil
                ))
            }
        }

        for paper in papers {
            let title = paper.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let titleEN = paper.titleEn?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let tagText = paper.tags.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: "\n")
            let text = [title, titleEN, tagText].filter { !$0.isEmpty }.joined(separator: "\n")
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }

            var seeds = Inf6AtomicConceptExtractor.extractAll(from: [title, titleEN])
            seeds.append(contentsOf: paper.tags.map { $0.replacingOccurrences(of: "_", with: " ") })
            seeds.append(contentsOf: _extractPhrases(from: title))
            seeds.append(contentsOf: _extractPhrases(from: titleEN))
            seeds = _dedupe(seeds).filter(_isConceptLike)

            let sourceKind: Inf6KnowledgeSourceKind = paper.provider.lowercased() == "arxiv" ? .arxivPaper : .paperPDF
            sources.append(_SourceText(
                sourceKind: sourceKind,
                sourceID: "paper/\(paper.id)",
                domainID: "jdla_eshikaku",
                field: "paper_metadata",
                text: text,
                seeds: seeds,
                titleENByJA: titleEN.isEmpty ? [:] : [title: titleEN],
                paperYear: paper.year,
                paperProgress: progress[paper.id]
            ))
        }

        for row in Inf6MetadataStore.listAllCodable(Inf6CorpusSource.self, domain: .corpusSources) {
            let source = row.value
            let text = _plainText(fromCorpusContent: source.content)
            let seeds = _dedupe(_extractPhrases(from: text)).filter(_isConceptLike)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }

            sources.append(_SourceText(
                sourceKind: _sourceKind(domainID: source.domainID),
                sourceID: source.sourceID,
                domainID: source.domainID,
                field: source.contentType,
                text: text,
                seeds: seeds,
                titleENByJA: [:],
                paperYear: nil,
                paperProgress: nil
            ))
        }

        return sources
    }

    private static func _analyze(
        source: _SourceText,
        observedAt: TimeInterval,
        accumulator: inout _Accumulator
    ) throws -> Set<String> {
        var conceptIDs: Set<String> = []
        let seeds = _dedupe(source.seeds).filter(_isConceptLike)

        for seed in seeds {
            let titleEN = source.titleENByJA[seed]
            let canonicalID = Inf6CanonicalConceptRegistry.register(
                title: seed,
                titleEN: titleEN,
                classificationID: nil,
                domain: source.domainID ?? ""
            )
            let candidateID = "candidate:\(canonicalID)"
            let ranges = _ranges(of: seed, in: source.text)
            let effectiveRanges = ranges.isEmpty ? [source.text.startIndex..<source.text.startIndex] : ranges
            var mentionIDs: Set<String> = []
            var evidenceIDs: Set<String> = []

            for range in effectiveRanges {
                let start = source.text.distance(from: source.text.startIndex, to: range.lowerBound)
                let length = source.text.distance(from: range.lowerBound, to: range.upperBound)
                let mentionID = "mention:\(_stableHex("\(source.sourceID)|\(source.field)|\(seed)|\(start)|\(length)"))"
                let evidenceID = "evidence:corpus:\(_stableHex("\(mentionID)|\(canonicalID)"))"
                let snippet = _snippet(text: source.text, around: range)

                let mention = Inf6CorpusConceptMention(
                    mentionID: mentionID,
                    candidateID: candidateID,
                    canonicalID: canonicalID,
                    surface: seed,
                    sourceKind: source.sourceKind,
                    sourceID: source.sourceID,
                    domainID: source.domainID,
                    field: source.field,
                    rangeStart: start,
                    rangeLength: length,
                    snippet: snippet,
                    observedAt: observedAt
                )
                let evidence = try Inf6KnowledgeEvidence(
                    evidenceID: evidenceID,
                    sourceKind: source.sourceKind,
                    sourceID: source.sourceID,
                    locator: "\(source.field):\(start):\(length)",
                    observedAt: observedAt
                )
                accumulator.mentions[mentionID] = mention
                accumulator.evidence[evidenceID] = evidence
                mentionIDs.insert(mentionID)
                evidenceIDs.insert(evidenceID)
            }

            var candidate = accumulator.candidates[candidateID] ?? Inf6CorpusConceptCandidate(
                candidateID: candidateID,
                canonicalID: canonicalID,
                displayTitleJA: _containsJapanese(seed) ? seed : nil,
                displayTitleEN: _containsJapanese(seed) ? titleEN : seed,
                sourceDomains: [],
                mentionIDs: [],
                evidenceIDs: [],
                firstObservedAt: observedAt,
                lastObservedAt: observedAt
            )
            if let domainID = source.domainID, !domainID.isEmpty {
                candidate.sourceDomains.insert(domainID)
            }
            candidate.mentionIDs.formUnion(mentionIDs)
            candidate.evidenceIDs.formUnion(evidenceIDs)
            candidate.firstObservedAt = min(candidate.firstObservedAt, observedAt)
            candidate.lastObservedAt = max(candidate.lastObservedAt, observedAt)
            accumulator.candidates[candidateID] = candidate

            if let domainID = source.domainID, !evidenceIDs.isEmpty {
                let membership = try Inf6KnowledgeMembership(setID: domainID, conceptID: canonicalID, evidenceIDs: evidenceIDs)
                accumulator.memberships["\(domainID)|\(canonicalID)"] = membership
            }

            if source.sourceKind == .arxivPaper || source.sourceKind == .paperPDF {
                accumulator.paperMentionCountByConcept[canonicalID, default: 0] += mentionIDs.count
                if let year = source.paperYear {
                    accumulator.paperYearByConcept[canonicalID, default: []].insert(year)
                }
                if let p = source.paperProgress {
                    accumulator.achievementByConcept[canonicalID] = max(
                        accumulator.achievementByConcept[canonicalID] ?? 0,
                        Double(p.masteryScore) / 5.0
                    )
                }
            } else {
                accumulator.syllabusMentionCountByConcept[canonicalID, default: 0] += mentionIDs.count
            }
            conceptIDs.insert(canonicalID)
        }

        return conceptIDs
    }

    private static func _recordCooccurrenceRelations(
        source: _SourceText,
        conceptIDs: Set<String>,
        accumulator: inout _Accumulator
    ) throws {
        let ids = conceptIDs.sorted()
        guard ids.count >= 2 else { return }
        let limited = Array(ids.prefix(24))
        for i in 0..<limited.count {
            for j in (i + 1)..<limited.count {
                let from = limited[i]
                let to = limited[j]
                let pairKey = "\(from)|related|\(to)"
                let evidenceIDs = Set(accumulator.mentions.values
                    .filter { $0.sourceID == source.sourceID && ($0.canonicalID == from || $0.canonicalID == to) }
                    .map { "evidence:corpus:\(_stableHex("\($0.mentionID)|\($0.canonicalID)"))" })
                if evidenceIDs.isEmpty { continue }
                var current = accumulator.relationEvidence[pairKey]
                    ?? (from: from, to: to, kind: .related, sourceKind: source.sourceKind, sourceID: source.sourceID, evidenceIDs: [])
                current.evidenceIDs.formUnion(evidenceIDs)
                accumulator.relationEvidence[pairKey] = current
            }
        }
    }

    private static func _materializeRelations(
        _ relations: [String: (from: String, to: String, kind: Inf6KnowledgeRelationKind, sourceKind: Inf6KnowledgeSourceKind, sourceID: String, evidenceIDs: Set<String>)],
        observedAt: TimeInterval
    ) throws -> [Inf6KnowledgeRelation] {
        try relations.map { pair in
            let raw = pair.value
            return try Inf6KnowledgeRelation(
                relationID: "relation:\(_stableHex(pair.key))",
                fromConceptID: raw.from,
                toConceptID: raw.to,
                kind: raw.kind,
                evidenceIDs: raw.evidenceIDs
            )
        }
    }

    private static func _materializeMetrics(
        accumulator: _Accumulator,
        relations: [Inf6KnowledgeRelation],
        observedAt: TimeInterval
    ) -> [Inf6ConceptMetric] {
        let relationCountByConcept = relations.reduce(into: [String: Int]()) { dict, relation in
            dict[relation.fromConceptID, default: 0] += 1
            dict[relation.toConceptID, default: 0] += 1
        }

        return accumulator.candidates.values.map { candidate in
            let mentionCount = candidate.mentionIDs.count
            let paperMentions = accumulator.paperMentionCountByConcept[candidate.canonicalID] ?? 0
            let syllabusMentions = accumulator.syllabusMentionCountByConcept[candidate.canonicalID] ?? 0
            let years = accumulator.paperYearByConcept[candidate.canonicalID] ?? []
            let oldPaperBonus = years.filter { $0 <= 2017 }.count
            let recentPaperBonus = years.filter { $0 >= Calendar.current.component(.year, from: Date()) - 3 }.count
            let domainCount = candidate.sourceDomains.count
            let relationCount = relationCountByConcept[candidate.canonicalID] ?? 0

            return Inf6ConceptMetric(
                canonicalID: candidate.canonicalID,
                corpusWeight: Double(mentionCount) + Double(domainCount * 2) + Double(relationCount) * 0.25,
                historicalWeight: Double(paperMentions) + Double(oldPaperBonus) * 1.5,
                achievementWeight: accumulator.achievementByConcept[candidate.canonicalID] ?? 0,
                freshnessWeight: Double(recentPaperBonus) + (candidate.sourceDomains.contains("microsoft_ai_102") || candidate.sourceDomains.contains("microsoft_ai_103") ? 0.5 : 0),
                unknownBoundaryWeight: domainCount <= 1 && relationCount <= 2 ? 1.0 : 0.0,
                sourceDomainCount: domainCount,
                mentionCount: mentionCount,
                paperMentionCount: paperMentions,
                syllabusMentionCount: syllabusMentions,
                relationCount: relationCount,
                evidenceIDs: candidate.evidenceIDs,
                updatedAt: observedAt
            )
        }
    }

    private static func _persist(
        candidates: [Inf6CorpusConceptCandidate],
        mentions: [Inf6CorpusConceptMention],
        evidence: [Inf6KnowledgeEvidence],
        memberships: [Inf6KnowledgeMembership],
        relations: [Inf6KnowledgeRelation],
        metrics: [Inf6ConceptMetric]
    ) throws {
        Inf6MetadataStore.deleteByPrefix(domain: .corpusConceptCandidates, prefix: "")
        Inf6MetadataStore.deleteByPrefix(domain: .corpusConceptMentions, prefix: "")
        Inf6MetadataStore.deleteByPrefix(domain: .corpusConceptRelations, prefix: "")
        Inf6MetadataStore.deleteByPrefix(domain: .conceptMetrics, prefix: "")

        for candidate in candidates {
            Inf6MetadataStore.putCodable(candidate, domain: .corpusConceptCandidates, key: candidate.candidateID)
        }
        for mention in mentions {
            Inf6MetadataStore.putCodable(mention, domain: .corpusConceptMentions, key: mention.mentionID)
        }
        for relation in relations {
            let observation = Inf6CorpusConceptRelationObservation(
                relationID: relation.relationID,
                fromConceptID: relation.fromConceptID,
                toConceptID: relation.toConceptID,
                kind: relation.kind,
                sourceKind: .other,
                sourceID: "corpus",
                evidenceIDs: relation.evidenceIDs,
                supportCount: relation.evidenceIDs.count,
                observedAt: Date().timeIntervalSince1970
            )
            Inf6MetadataStore.putCodable(observation, domain: .corpusConceptRelations, key: observation.relationID)
        }
        for metric in metrics {
            Inf6MetadataStore.putCodable(metric, domain: .conceptMetrics, key: metric.canonicalID)
        }
    }

    private static func _preferredJA(_ item: Inf6SyllabusOutlineItem) -> String {
        let title = item.titleJa?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty { return title }
        return item.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func _preferredEN(_ item: Inf6SyllabusOutlineItem) -> String {
        let title = item.titleEn?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty { return title }
        if !_containsJapanese(item.title) {
            return item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private static func _sourceKind(domainID: String?) -> Inf6KnowledgeSourceKind {
        let id = domainID?.lowercased() ?? ""
        if id.contains("microsoft") || id.contains("ai_102") { return .microsoftLearn }
        if id.contains("gkentei") || id.contains("g-kentei") { return .jdlaGKenteiSyllabus }
        if id.contains("eshikaku") || id.contains("e-shikaku") { return .arxivPaper }
        return .other
    }

    private static func _extractPhrases(from text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[\r\n\t]"#, with: " ", options: .regularExpression)
        let separators = CharacterSet(charactersIn: "。．.、,;；:：()（）[]【】{}「」『』!?！？\n\r\t")
        return normalized.components(separatedBy: separators)
            .flatMap { Inf6AtomicConceptExtractor.extract(from: $0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(_isConceptLike)
    }

    private static func _plainText(fromCorpusContent content: String) -> String {
        content
            .replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: #"[\r\n\t ]+"#, with: " ", options: .regularExpression)
    }

    private static func _isConceptLike(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count < 2 || s.count > 64 { return false }
        let lower = s.lowercased()
        let compact = lower.replacingOccurrences(of: " ", with: "")
        if s.range(of: #"[[:alnum:]ぁ-んァ-ヶ一-龥々]"#, options: .regularExpression) == nil { return false }
        let blocked: Set<String> = [
            "ai",
            "jdla",
            "g検定",
            "e資格",
            "ai-102",
            "ai-103",
            "microsoftlearn",
            "microsoft learn",
            "キーワード",
            "keyword",
            "keywords",
            "0 gシラバス2024 新規作成",
            "1 以下のキーワード内容を見直し",
            "2 以下のキーワード内容を見直し",
            "3 以下のキーワードの一部見直し",
        ]
        if blocked.contains(lower) { return false }
        if blocked.contains(compact) { return false }
        let administrativeFragments = [
            "キーワード内容を見直し",
            "キーワードの一部見直し",
            "表記内容",
            "表現の統一",
            "シラバス2024",
            "新規作成",
            "review the following keyword",
            "review some of the following keyword",
            "revise wording"
        ]
        if administrativeFragments.contains(where: { lower.contains($0) }) { return false }
        if lower.range(of: #"^\d+$"#, options: .regularExpression) != nil { return false }
        return true
    }

    private static func _ranges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        let needle = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty { return [] }
        var ranges: [Range<String.Index>] = []
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let range = haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<haystack.endIndex) {
            ranges.append(range)
            searchStart = range.upperBound
        }
        return ranges
    }

    private static func _snippet(text: String, around range: Range<String.Index>) -> String {
        let startOffset = max(0, text.distance(from: text.startIndex, to: range.lowerBound) - 48)
        let endOffset = min(text.count, text.distance(from: text.startIndex, to: range.upperBound) + 48)
        let start = text.index(text.startIndex, offsetBy: startOffset)
        let end = text.index(text.startIndex, offsetBy: endOffset)
        return String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func _dedupe(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            if trimmed.isEmpty || seen.contains(key) { continue }
            seen.insert(key)
            out.append(trimmed)
        }
        return out
    }

    private static func _containsJapanese(_ s: String) -> Bool {
        s.range(of: #"[ぁ-んァ-ヶ一-龥々]"#, options: .regularExpression) != nil
    }

    private static func _stableHex(_ raw: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(format: "%016llx", hash)
    }
}
