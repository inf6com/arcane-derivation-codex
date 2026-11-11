//
//  Inf6UniversalConceptSet.swift
//  inf6
//
//  工学的契約（集合構造）:
//    - K は知の可能空間。未観測・未命名・未抽出の知を含む。
//    - O は観測済み知識集合。現在保有している全ドメイン D_i から得た canonical 概念の和集合。
//    - D_i は domain_id -> Set<canonical_id> として管理する。
//    - outline 行は O の要素ではない。outline -> atomize -> canonical 解決の順で O に登録する。
//

import Foundation

struct Inf6UniversalConceptSet {
    struct Concept: Hashable {
        let canonicalID: String
        var displayTitleJA: String?
        var displayTitleEN: String?
        var aliases: Set<String>
        var classificationID: String?
        var sourceDomains: Set<String>
        var achievementsByDomain: [String: String]
        var scoresByDomain: [String: ConceptScore]

        func displayTitle(isJapanese: Bool) -> String {
            if isJapanese {
                if let ja = displayTitleJA, !ja.isEmpty { return ja }
                if let en = displayTitleEN, !en.isEmpty { return en }
            } else {
                if let en = displayTitleEN, !en.isEmpty { return en }
                if let ja = displayTitleJA, !ja.isEmpty { return ja }
            }
            return canonicalID.split(separator: ":").last.map(String.init) ?? canonicalID
        }

        func achievement(domainID: String) -> String {
            achievementsByDomain[domainID] ?? "not_started"
        }

        func score(domainID: String?) -> ConceptScore {
            if let domainID, let score = scoresByDomain[domainID] {
                return score
            }
            return scoresByDomain.values.reduce(ConceptScore()) { acc, score in
                ConceptScore(
                    hotScore: max(acc.hotScore, score.hotScore),
                    basicScore: max(acc.basicScore, score.basicScore),
                    evidenceIDs: acc.evidenceIDs.union(score.evidenceIDs)
                )
            }
        }
    }

    struct ConceptScore: Hashable {
        var hotScore: Double = 0
        var basicScore: Double = 0
        var evidenceIDs: Set<String> = []
    }

    struct DomainSubset: Hashable {
        let domainID: String
        let sourceFamily: String
        var displayTitleJA: String
        var displayTitleEN: String
        var canonicalIDs: Set<String>
        var topCanonicalIDs: [String]
        var childrenByParentCanonicalID: [String: [String]]

        func displayTitle(isJapanese: Bool) -> String {
            if isJapanese {
                return displayTitleJA.isEmpty ? displayTitleEN : displayTitleJA
            }
            return displayTitleEN.isEmpty ? displayTitleJA : displayTitleEN
        }
    }

    var conceptsByID: [String: Concept]
    var domainSubsets: [DomainSubset]
    var evidenceByID: [String: Inf6KnowledgeEvidence]
    var memberships: [Inf6KnowledgeMembership]
    var relations: [Inf6KnowledgeRelation]

    static func build(fromDomainDictionaries domains: [[String: Any]]) -> Inf6UniversalConceptSet {
        var concepts: [String: Concept] = [:]
        var subsets: [DomainSubset] = []
        var evidenceByID: [String: Inf6KnowledgeEvidence] = [:]
        var memberships: [Inf6KnowledgeMembership] = []
        var relations: [Inf6KnowledgeRelation] = []

        for domain in domains {
            let definition = _defineDomain(from: domain)
            let domainID = definition.domainID
            let sourceFamily = definition.sourceFamily
            let sourceKind = definition.sourceKind
            let trendSignals = Inf6ForecastAuthoringLoader.loadSignals(sourceFamily: sourceFamily)

            let nodes = (domain["nodes"] as? [[String: Any]]) ?? []

            var subset = DomainSubset(
                domainID: domainID,
                sourceFamily: sourceFamily,
                displayTitleJA: definition.displayTitleJA,
                displayTitleEN: definition.displayTitleEN,
                canonicalIDs: [],
                topCanonicalIDs: [],
                childrenByParentCanonicalID: [:]
            )
            var firstCanonicalIDByRawNodeID: [String: String] = [:]

            for node in nodes {
                let kind = _trimmedString(node["kind"]) ?? "node"
                guard kind != "paper", kind != "domain", kind != "syllabus_version" else { continue }

                let titleJA = _trimmedString(node["title_ja"]) ?? ""
                let titleEN = _trimmedString(node["title_en"]) ?? ""
                let canonicalSeedTitle = titleJA.isEmpty ? titleEN : titleJA
                guard !canonicalSeedTitle.isEmpty else { continue }

                // Reject qualification meta-labels per AGENTS.md 概念モデル契約.
                if _isQualificationMetaTitle(titleJA: titleJA, titleEN: titleEN) { continue }
                if _isSyllabusMaintenanceTitle(titleJA: titleJA, titleEN: titleEN) { continue }

                let classificationID = _trimmedString(node["classification_id"])
                let achievement = _trimmedString(node["achievement"]) ?? "not_started"
                let depth = (node["depth"] as? Int) ?? ((node["depth"] as? Double).map(Int.init) ?? 0)
                let isTopNode = kind == "major" && depth <= 2
                let rawNodeID = _trimmedString(node["node_id"]) ?? ""
                let parentRawNodeID = _trimmedString(node["parent_node_id"])

                let atomsJA = Inf6AtomicConceptExtractor.extract(from: canonicalSeedTitle)
                let atomsEN = titleEN.isEmpty ? [] : Inf6AtomicConceptExtractor.extract(from: titleEN)
                for (index, atomJA) in atomsJA.enumerated() {
                    let atomEN = index < atomsEN.count ? atomsEN[index] : nil
                    let canonicalID = Inf6CanonicalConceptRegistry.register(
                        title: atomJA,
                        titleEN: atomEN,
                        classificationID: classificationID,
                        domain: domainID
                    )

                    var concept = concepts[canonicalID]
                        ?? Concept(
                            canonicalID: canonicalID,
                            displayTitleJA: nil,
                            displayTitleEN: nil,
                            aliases: [],
                            classificationID: nil,
                            sourceDomains: [],
                            achievementsByDomain: [:],
                            scoresByDomain: [:]
                        )

                    if concept.displayTitleJA?.isEmpty ?? true {
                        concept.displayTitleJA = atomJA
                    }
                    if concept.displayTitleEN?.isEmpty ?? true, let atomEN, !atomEN.isEmpty {
                        concept.displayTitleEN = atomEN
                    }
                    concept.aliases.insert(_normalizeAlias(atomJA))
                    if let atomEN, !atomEN.isEmpty {
                        concept.aliases.insert(_normalizeAlias(atomEN))
                    }
                    if concept.classificationID == nil, let classificationID, !classificationID.isEmpty {
                        concept.classificationID = classificationID
                    }
                    if !domainID.isEmpty {
                        let evidenceID = "evidence:\(domainID):node:\(rawNodeID.isEmpty ? canonicalID : rawNodeID):atom:\(index)"
                        do {
                            let evidence = try Inf6KnowledgeEvidence(
                                evidenceID: evidenceID,
                                sourceKind: sourceKind,
                                sourceID: domainID,
                                locator: rawNodeID.isEmpty ? "canonical:\(canonicalID)" : "node_id:\(rawNodeID)"
                            )
                            evidenceByID[evidence.evidenceID] = evidence
                            let membership = try Inf6KnowledgeMembership(
                                setID: domainID,
                                conceptID: canonicalID,
                                evidenceIDs: [evidence.evidenceID]
                            )
                            if !memberships.contains(membership) {
                                memberships.append(membership)
                            }
                        } catch {
                            preconditionFailure("[Inf6UniversalConceptSet] invalid membership evidence: \(error)")
                        }
                        concept.sourceDomains.insert(domainID)
                        concept.achievementsByDomain[domainID] = _maxAchievement(
                            concept.achievementsByDomain[domainID],
                            achievement
                        )
                        let nextScore = _scoreConcept(
                            titleJA: atomJA,
                            titleEN: atomEN,
                            classificationID: classificationID,
                            depth: depth,
                            isTopNode: isTopNode,
                            sourceFamily: sourceFamily,
                            trendSignals: trendSignals
                        )
                        concept.scoresByDomain[domainID] = _joinScore(
                            concept.scoresByDomain[domainID],
                            nextScore
                        )
                        subset.canonicalIDs.insert(canonicalID)
                        if isTopNode && !subset.topCanonicalIDs.contains(canonicalID) {
                            subset.topCanonicalIDs.append(canonicalID)
                        }
                        if index == 0, !rawNodeID.isEmpty {
                            firstCanonicalIDByRawNodeID[rawNodeID] = canonicalID
                        }
                        if let parentRawNodeID,
                           let parentCanonicalID = firstCanonicalIDByRawNodeID[parentRawNodeID],
                           parentCanonicalID != canonicalID {
                            var children = subset.childrenByParentCanonicalID[parentCanonicalID] ?? []
                            if !children.contains(canonicalID) {
                                children.append(canonicalID)
                                subset.childrenByParentCanonicalID[parentCanonicalID] = children
                            }
                            do {
                                let relationID = "relation:\(domainID):\(parentCanonicalID):sourceOutlineContains:\(canonicalID)"
                                let relation = try Inf6KnowledgeRelation(
                                    relationID: relationID,
                                    fromConceptID: parentCanonicalID,
                                    toConceptID: canonicalID,
                                    kind: .sourceOutlineContains,
                                    evidenceIDs: ["evidence:\(domainID):node:\(rawNodeID.isEmpty ? canonicalID : rawNodeID):atom:\(index)"]
                                )
                                if !relations.contains(relation) {
                                    relations.append(relation)
                                }
                            } catch {
                                preconditionFailure("[Inf6UniversalConceptSet] invalid source outline relation: \(error)")
                            }
                        }
                    }
                    concepts[canonicalID] = concept
                }
            }

            subsets.append(subset)
        }

        return Inf6UniversalConceptSet(
            conceptsByID: concepts,
            domainSubsets: subsets,
            evidenceByID: evidenceByID,
            memberships: memberships,
            relations: relations
        )
    }

    /// Pattern-detect titles that are qualification meta-labels (NOT concepts).
    /// Examples:
    ///   - "AI-102 認定試験" (the certification exam itself)
    ///   - "Fundamentals カテゴリ" (a section header)
    ///   - "Azure AI Engineer Associate" (a certification name)
    ///   - "関連 AI 基礎認定" (a reference to related certifications)
    private static func _isQualificationMetaTitle(titleJA: String, titleEN: String) -> Bool {
        let candidates = [titleJA, titleEN].filter { !$0.isEmpty }
        // Japanese patterns
        let jaSuffixes = ["認定試験", "認定", "資格", "カテゴリ", "カテゴリー"]
        let jaContains = ["関連 ", "関連　", "に関する出題範囲"]
        // English patterns
        let enContainsCI = [
            "associate", "certification", "credential", "exam",
            "study guide", "fundamentals category", "related certifications",
        ]
        for raw in candidates {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { continue }
            for suffix in jaSuffixes where s.hasSuffix(suffix) { return true }
            for needle in jaContains where s.contains(needle) { return true }
            let lower = s.lowercased()
            for needle in enContainsCI where lower.contains(needle) { return true }
        }
        return false
    }

    /// Syllabus revision rows define the source document maintenance state, not AI concepts.
    private static func _isSyllabusMaintenanceTitle(titleJA: String, titleEN: String) -> Bool {
        let candidates = [titleJA, titleEN].filter { !$0.isEmpty }
        let patterns = [
            "シラバス",
            "キーワード内容を見直し",
            "キーワードの一部見直し",
            "表記内容",
            "表現の統一",
            "新規作成",
            "syllabus",
            "review the following keyword",
            "review some of the following keyword",
            "revise wording",
            "newly created"
        ]
        for raw in candidates {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if s.isEmpty { continue }
            for p in patterns where s.contains(p.lowercased()) { return true }
        }
        return false
    }

    private static func _trimmedString(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func _normalizeAlias(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func _defineDomain(from domain: [String: Any]) -> Inf6KnowledgeDomainDefinition {
        let nodes = (domain["nodes"] as? [[String: Any]]) ?? []
        let root = nodes.first { (_trimmedString($0["kind"]) ?? "") == "domain" }
        let domainID = _trimmedString(domain["domain_id"]) ?? _trimmedString(domain["source_family"]) ?? ""
        let sourceFamily = _trimmedString(domain["source_family"]) ?? domainID
        let titleJA = _trimmedString(root?["title_ja"]) ?? ""
        let titleEN = _trimmedString(root?["title_en"]) ?? ""
        do {
            return try Inf6KnowledgeDomainDefinition(
                domainID: domainID,
                sourceFamily: sourceFamily,
                sourceKind: _sourceKind(sourceFamily: sourceFamily),
                displayTitleJA: titleJA,
                displayTitleEN: titleEN
            )
        } catch {
            preconditionFailure("[Inf6UniversalConceptSet] invalid domain definition: \(error)")
        }
    }

    private static func _sourceKind(sourceFamily: String) -> Inf6KnowledgeSourceKind {
        switch sourceFamily {
        case "jdla_gkentei", "jdla_eshikaku":
            return .jdlaSyllabus
        case "microsoft_ai_102", "microsoft_ai_103":
            return .microsoftLearn
        default:
            preconditionFailure("[Inf6UniversalConceptSet] unknown source family for knowledge evidence: \(sourceFamily)")
        }
    }

    private static func _maxAchievement(_ lhs: String?, _ rhs: String) -> String {
        let rank = [
            "not_started": 0,
            "collecting": 1,
            "reading": 2,
            "annotating": 3,
            "explained": 4,
            "questioned": 5,
            "measured": 6,
        ]
        let left = lhs ?? "not_started"
        return (rank[rhs, default: 0] > rank[left, default: 0]) ? rhs : left
    }

    private static func _joinScore(_ lhs: ConceptScore?, _ rhs: ConceptScore) -> ConceptScore {
        guard let lhs else { return rhs }
        return ConceptScore(
            hotScore: max(lhs.hotScore, rhs.hotScore),
            basicScore: max(lhs.basicScore, rhs.basicScore),
            evidenceIDs: lhs.evidenceIDs.union(rhs.evidenceIDs)
        )
    }

    private static func _scoreConcept(
        titleJA: String,
        titleEN: String?,
        classificationID: String?,
        depth: Int,
        isTopNode: Bool,
        sourceFamily: String,
        trendSignals: [Inf6TrendSignal]
    ) -> ConceptScore {
        var score = ConceptScore()

        // Basic は公式アウトライン上の上位性と基礎分類から定義する。
        if isTopNode { score.basicScore += 40 }
        score.basicScore += max(0, 24 - Double(max(depth, 0)) * 4)
        switch (classificationID ?? "").lowercased() {
        case "mathematics-statistics", "ai-foundations", "machine-learning":
            score.basicScore += 24
        case "deep-learning":
            score.basicScore += 12
        default:
            break
        }
        score.evidenceIDs.insert("outline:\(sourceFamily):depth:\(depth)")

        // Hot は forecast authoring の TrendSignal に一致した場合だけ上げる。
        let haystack = _normalizeForMatch([titleJA, titleEN ?? ""].joined(separator: " "))
        for signal in trendSignals {
            guard signal.category != .deemphasizedTopic else { continue }
            let matched = signal.matchedKeywords.contains { keyword in
                let key = _normalizeForMatch(keyword)
                return !key.isEmpty && (haystack.contains(key) || key.contains(haystack))
            }
            guard matched else { continue }
            let importanceWeight: Double
            switch signal.importance {
            case .high: importanceWeight = 80
            case .medium: importanceWeight = 50
            case .low: importanceWeight = 25
            }
            let rankBoost = max(0, 24 - Double(max(signal.priorityRank - 1, 0)) * 4)
            score.hotScore = max(score.hotScore, importanceWeight + rankBoost)
            score.evidenceIDs.insert("trend:\(sourceFamily):\(signal.signalID)")
        }

        return score
    }

    private static func _normalizeForMatch(_ raw: String) -> String {
        raw
            .lowercased()
            .replacingOccurrences(of: "・", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: "／", with: " ")
            .replacingOccurrences(of: "（", with: " ")
            .replacingOccurrences(of: "）", with: " ")
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
