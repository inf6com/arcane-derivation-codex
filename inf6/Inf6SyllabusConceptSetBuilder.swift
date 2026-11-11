//
//  Inf6SyllabusConceptSetBuilder.swift
//  inf6
//
//  公式シラバス構造から観測済み概念集合 O と各ドメイン部分集合 D_i を生成する。
//  各 membership は、実際の outline node に出現した原子概念または明示概念句を根拠にする。
//

import Foundation

enum Inf6SyllabusConceptSetBuilder {
    private static let _version = "syllabus-semantic-v20"
    static var currentVersion: String { _version }

    struct Summary: Codable, Hashable {
        let version: String
        let domainCount: Int
        let conceptCount: Int
        let membershipCount: Int
        let relationCount: Int
    }

    static func conceptIDs(for node: Inf6KnowledgeNode, sourceFamily: String) -> Set<String> {
        guard _isConceptNode(node) else { return [] }
        return Set(_terms(from: node, sourceFamily: sourceFamily).map(\.canonicalID))
    }

    @discardableResult
    static func rebuildAndPersist(
        domains: [Inf6KnowledgeGraphView._KnowledgeGraphDomain]
    ) throws -> Summary {
        var conceptsByID: [String: Inf6CanonicalConcept] = [:]
        var evidenceByID: [String: Inf6KnowledgeEvidence] = [:]
        var membershipByKey: [String: Inf6KnowledgeMembership] = [:]
        var relationByID: [String: Inf6KnowledgeRelation] = [:]
        var auditByDomain: [String: _DomainAudit] = [:]
        var unmappedConceptNodes: [String] = []

        for domain in domains {
            let sourceFamily = domain.manifest.sourceFamily.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sourceFamily.isEmpty else { continue }

            let sourceKind = _sourceKind(for: domain.manifest)
            let nodesByID = Dictionary(uniqueKeysWithValues: domain.structure.nodes.map { ($0.nodeID, $0) })
            var firstConceptByNodeID: [String: String] = [:]
            var audit = _DomainAudit(
                sourceFamily: sourceFamily,
                outlineCount: _sourceOutlineCount(for: domain),
                conceptNodeCount: 0,
                emittedAtomCount: 0,
                membershipCount: 0
            )

            for node in domain.structure.nodes {
                guard _isConceptNode(node) else { continue }
                audit.conceptNodeCount += 1
                let terms = _terms(from: node, sourceFamily: sourceFamily)
                audit.emittedAtomCount += terms.count
                if terms.isEmpty {
                    unmappedConceptNodes.append("\(sourceFamily):\(node.nodeID): \(node.titleJa)")
                    continue
                }

                for (index, term) in terms.enumerated() {
                    var concept = conceptsByID[term.canonicalID]
                        ?? Inf6CanonicalConcept(
                            canonicalID: term.canonicalID,
                            displayTitleJA: term.displayTitleJA,
                            displayTitleEN: term.displayTitleEN,
                            aliases: [],
                            classificationID: nil,
                            sourceDomains: []
                        )
                    if concept.displayTitleJA?.isEmpty ?? true {
                        concept.displayTitleJA = term.displayTitleJA
                    }
                    if concept.displayTitleEN?.isEmpty ?? true {
                        concept.displayTitleEN = term.displayTitleEN
                    }
                    concept.aliases.formUnion(term.aliases)
                    concept.sourceDomains.insert(sourceFamily)
                    concept.updatedAt = Date().timeIntervalSince1970
                    conceptsByID[term.canonicalID] = concept

                    let evidenceID = "evidence:syllabus:\(sourceFamily):\(node.nodeID):atom:\(index)"
                    let evidence = try Inf6KnowledgeEvidence(
                        evidenceID: evidenceID,
                        sourceKind: sourceKind,
                        sourceID: sourceFamily,
                        locator: "node_id:\(node.nodeID)"
                    )
                    evidenceByID[evidenceID] = evidence

                    let membershipKey = "\(sourceFamily)|\(term.canonicalID)"
                    let evidenceIDs = (membershipByKey[membershipKey]?.evidenceIDs ?? []).union([evidenceID])
                    membershipByKey[membershipKey] = try Inf6KnowledgeMembership(
                        setID: sourceFamily,
                        conceptID: term.canonicalID,
                        evidenceIDs: evidenceIDs
                    )

                    if index == 0 {
                        firstConceptByNodeID[node.nodeID] = term.canonicalID
                    }
                }
            }

            for node in domain.structure.nodes {
                guard let parentNodeID = node.parentNodeID,
                      let childConceptID = firstConceptByNodeID[node.nodeID],
                      let parentConceptID = _nearestParentConceptID(
                        parentNodeID: parentNodeID,
                        nodesByID: nodesByID,
                        firstConceptByNodeID: firstConceptByNodeID
                      ),
                      parentConceptID != childConceptID
                else { continue }

                let evidenceID = "evidence:syllabus:\(sourceFamily):\(node.nodeID):outline-parent"
                let evidence = try Inf6KnowledgeEvidence(
                    evidenceID: evidenceID,
                    sourceKind: sourceKind,
                    sourceID: sourceFamily,
                    locator: "parent_node_id:\(parentNodeID)"
                )
                evidenceByID[evidenceID] = evidence

                let relationID = "relation:syllabus:\(sourceFamily):\(parentConceptID):contains:\(childConceptID)"
                let relation = try Inf6KnowledgeRelation(
                    relationID: relationID,
                    fromConceptID: parentConceptID,
                    toConceptID: childConceptID,
                    kind: .sourceOutlineContains,
                    evidenceIDs: [evidenceID]
                )
                relationByID[relationID] = relation
            }

            try _applySourceOutlineClosure(
                sourceFamily: sourceFamily,
                sourceKind: sourceKind,
                relationByID: relationByID,
                membershipByKey: &membershipByKey,
                evidenceByID: &evidenceByID
            )
            auditByDomain[sourceFamily] = audit
        }

        guard unmappedConceptNodes.isEmpty else {
            throw NSError(
                domain: "Inf6SyllabusConceptSetBuilder",
                code: 70,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Syllabus concept extraction produced unmapped concept nodes:\n\(unmappedConceptNodes.prefix(24).joined(separator: "\n"))"
                ]
            )
        }

        for sourceFamily in auditByDomain.keys {
            auditByDomain[sourceFamily]?.membershipCount = membershipByKey.values.filter { $0.setID == sourceFamily }.count
        }

        _replacePersistedConceptSet(
            concepts: Array(conceptsByID.values),
            evidence: Array(evidenceByID.values),
            memberships: Array(membershipByKey.values),
            relations: Array(relationByID.values)
        )

        let summary = Summary(
            version: _version,
            domainCount: domains.count,
            conceptCount: conceptsByID.count,
            membershipCount: membershipByKey.count,
            relationCount: relationByID.count
        )
        Inf6MetadataStore.put(domain: .settings, key: "semantic_concept_set_version", json: _version)
        Inf6MetadataStore.put(domain: .settings, key: "semantic_concept_set_quality", json: "source_evidence_observed")
        Inf6MetadataStore.putCodable(summary, domain: .settings, key: "semantic_concept_set_summary")
        for audit in auditByDomain.values {
            Inf6MetadataStore.putCodable(audit, domain: .settings, key: "semantic_concept_set_audit:\(audit.sourceFamily)")
        }
        _ = Inf6SemanticScopeVerifier.verifyCurrentConceptSet(version: _version)
        return summary
    }

    private static func _replacePersistedConceptSet(
        concepts: [Inf6CanonicalConcept],
        evidence: [Inf6KnowledgeEvidence],
        memberships: [Inf6KnowledgeMembership],
        relations: [Inf6KnowledgeRelation]
    ) {
        Inf6MetadataStore.deleteByPrefix(domain: .canonicalConcepts, prefix: "")
        Inf6MetadataStore.deleteByPrefix(domain: .canonicalAliases, prefix: "")
        Inf6MetadataStore.deleteByPrefix(domain: .knowledgeEvidence, prefix: "")
        Inf6MetadataStore.deleteByPrefix(domain: .knowledgeMemberships, prefix: "")
        Inf6MetadataStore.deleteByPrefix(domain: .knowledgeRelations, prefix: "")
        Inf6MetadataStore.delete(domain: .settings, key: "semantic_concept_set_summary")
        Inf6MetadataStore.delete(domain: .settings, key: "semantic_scope_verification_report")
        Inf6MetadataStore.deleteByPrefix(domain: .settings, prefix: "semantic_concept_set_audit:")

        for concept in concepts {
            Inf6MetadataStore.putCodable(concept, domain: .canonicalConcepts, key: concept.canonicalID)
            for alias in concept.aliases where !alias.isEmpty {
                Inf6MetadataStore.put(domain: .canonicalAliases, key: alias, json: concept.canonicalID)
            }
        }
        for item in evidence {
            Inf6MetadataStore.putCodable(item, domain: .knowledgeEvidence, key: item.evidenceID)
        }
        for membership in memberships {
            Inf6MetadataStore.putCodable(
                membership,
                domain: .knowledgeMemberships,
                key: "\(membership.setID)|\(membership.conceptID)"
            )
        }
        for relation in relations {
            Inf6MetadataStore.putCodable(relation, domain: .knowledgeRelations, key: relation.relationID)
        }
    }

    private static func _sourceOutlineCount(for domain: Inf6KnowledgeGraphView._KnowledgeGraphDomain) -> Int {
        if let seed = Inf6MetadataStore.getCodable(
            _StoredSeedFingerprint.self,
            domain: .syllabus,
            key: "seed_fp:\(domain.manifest.sourceFamily)#\(domain.structure.syllabusVersionID)"
        ) {
            return seed.outlineCount
        }
        return domain.structure.nodes.filter {
            switch $0.kind {
            case .major, .minor, .topic:
                return !_isAdministrativeLabel($0.titleJa) && !_isAdministrativeLabel($0.titleEn)
            case .domain, .syllabusVersion, .paper:
                return false
            }
        }.count
    }

    private static func _isConceptNode(_ node: Inf6KnowledgeNode) -> Bool {
        switch node.kind {
        case .major, .minor, .topic:
            return !_isAdministrativeLabel(node.titleJa) && !_isAdministrativeLabel(node.titleEn)
        case .domain, .syllabusVersion, .paper:
            return false
        }
    }

    private static func _terms(from node: Inf6KnowledgeNode, sourceFamily: String) -> [_Term] {
        var out: [_Term] = []
        var seen: Set<String> = []

        let atoms = sourceFamily == "microsoft_ai_102" || sourceFamily == "microsoft_ai_103"
            ? _microsoftLearnSourceAtoms(from: node)
            : _sourceAtoms(from: node)
        for atom in atoms {
            guard let term = _term(atom: atom) else { continue }
            guard !seen.contains(term.canonicalID) else { continue }
            seen.insert(term.canonicalID)
            out.append(term)
        }
        return out
    }

    private static func _sourceAtoms(from node: Inf6KnowledgeNode) -> [_SourceAtom] {
        let jaAtoms = _atomizeJapanese(node.titleJa)
        let enAtoms = _atomizeEnglish(node.titleEn)
        if jaAtoms.count == enAtoms.count {
            return jaAtoms.indices.map { index in
                _SourceAtom(ja: jaAtoms[index], en: enAtoms[index])
            }
        }

        var out = jaAtoms.map { _SourceAtom(ja: $0, en: "") }
        out.append(contentsOf: enAtoms.map { _SourceAtom(ja: "", en: $0) })
        return out
    }

    private static func _microsoftLearnSourceAtoms(from node: Inf6KnowledgeNode) -> [_SourceAtom] {
        let joined = [node.titleJa, node.titleEn, node.summaryJa, node.summaryEn]
            .map(_cleanDisplay)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        let matchedAtoms = _canonicalIDsMentioned(in: joined).map { canonical in
            _SourceAtom(
                ja: _manualDisplayJA[canonical] ?? "",
                en: _manualDisplayEN[canonical] ?? ""
            )
        }
        if !matchedAtoms.isEmpty {
            return matchedAtoms
        }

        return [_SourceAtom(ja: node.titleJa, en: node.titleEn)]
    }

    private static func _canonicalIDsMentioned(in text: String) -> [String] {
        let normalized = _normalizeAlias(text)
        guard !normalized.isEmpty else { return [] }
        return _manualAliases.keys.sorted().filter { canonical in
            (_manualAliases[canonical] ?? []).contains { alias in
                !alias.isEmpty && normalized.contains(alias)
            }
        }
    }

    private static func _atomizeJapanese(_ raw: String) -> [String] {
        Inf6AtomicConceptExtractor.extract(from: raw)
            .flatMap(_splitJapaneseConjunctions)
            .map(_cleanDisplay)
            .filter { !$0.isEmpty }
    }

    private static func _atomizeEnglish(_ raw: String) -> [String] {
        Inf6AtomicConceptExtractor.extract(from: raw)
            .flatMap(_splitShortEnglishConjunctions)
            .map(_cleanDisplay)
            .filter { !$0.isEmpty }
    }

    private static func _splitJapaneseConjunctions(_ raw: String) -> [String] {
        let text = _cleanDisplay(raw)
        guard text.contains("と") else { return [text] }
        let parts = text
            .components(separatedBy: "と")
            .map(_cleanDisplay)
            .filter { !$0.isEmpty }
        guard parts.count >= 2,
              parts.allSatisfy({ $0.count >= 2 && !$0.contains(" ") })
        else { return [text] }
        return parts
    }

    private static func _splitShortEnglishConjunctions(_ raw: String) -> [String] {
        let text = _cleanDisplay(raw)
        let words = text.split(whereSeparator: { $0 == " " || $0 == "," }).count
        guard words <= 6 else { return [text] }
        let normalized = text.replacingOccurrences(of: " and ", with: "\u{1F}")
        let parts = normalized
            .split(separator: "\u{1F}")
            .map { _cleanDisplay(String($0)) }
            .filter { !$0.isEmpty }
        return parts.count >= 2 ? parts : [text]
    }

    private static func _term(atom: _SourceAtom) -> _Term? {
        let rawJA = _cleanDisplay(atom.ja)
        let rawEN = _cleanDisplay(atom.en)
        guard !rawJA.isEmpty || !rawEN.isEmpty else { return nil }

        let meaningfulJA = rawJA.isEmpty || !_isAdministrativeLabel(rawJA)
        let meaningfulEN = rawEN.isEmpty || !_isAdministrativeLabel(rawEN)
        guard meaningfulJA || meaningfulEN else { return nil }

        let cleanedJA = meaningfulJA ? rawJA : ""
        let cleanedEN = meaningfulEN ? rawEN : ""
        var aliases = Set([_normalizeAlias(cleanedJA), _normalizeAlias(cleanedEN)].filter { !$0.isEmpty })
        let lookupKeys = aliases.union(_expandedAliases(cleanedJA)).union(_expandedAliases(cleanedEN))
        if let canonical = _manualCanonicalID(forAny: lookupKeys) {
            aliases.formUnion(_manualAliases[canonical] ?? [])
            return _Term(
                canonicalID: canonical,
                displayTitleJA: _manualDisplayJA[canonical] ?? (cleanedJA.isEmpty ? nil : cleanedJA),
                displayTitleEN: _manualDisplayEN[canonical] ?? (cleanedEN.isEmpty ? nil : cleanedEN),
                aliases: aliases
            )
        }

        let base = _semanticSlug(cleanedJA.isEmpty ? cleanedEN : cleanedJA)
        guard !base.isEmpty else { return nil }
        return _Term(
            canonicalID: "concept:\(base)",
            displayTitleJA: cleanedJA.isEmpty ? nil : cleanedJA,
            displayTitleEN: cleanedEN.isEmpty ? nil : cleanedEN,
            aliases: aliases
        )
    }

    private static func _term(canonicalID: String) -> _Term {
        let aliases = _manualAliases[canonicalID] ?? []
        return _Term(
            canonicalID: canonicalID,
            displayTitleJA: _manualDisplayJA[canonicalID],
            displayTitleEN: _manualDisplayEN[canonicalID],
            aliases: aliases
        )
    }

    private static func _nearestParentConceptID(
        parentNodeID: String,
        nodesByID: [String: Inf6KnowledgeNode],
        firstConceptByNodeID: [String: String]
    ) -> String? {
        var cursor: String? = parentNodeID
        var visited: Set<String> = []
        while let nodeID = cursor, !visited.contains(nodeID) {
            visited.insert(nodeID)
            if let conceptID = firstConceptByNodeID[nodeID] {
                return conceptID
            }
            cursor = nodesByID[nodeID]?.parentNodeID
        }
        return nil
    }

    private static func _applySourceOutlineClosure(
        sourceFamily: String,
        sourceKind: Inf6KnowledgeSourceKind,
        relationByID: [String: Inf6KnowledgeRelation],
        membershipByKey: inout [String: Inf6KnowledgeMembership],
        evidenceByID: inout [String: Inf6KnowledgeEvidence]
    ) throws {
        let relations = relationByID.values.filter {
            $0.kind == .sourceOutlineContains && $0.relationID.hasPrefix("relation:syllabus:\(sourceFamily):")
        }
        guard !relations.isEmpty else { return }

        var parentsByChild: [String: Set<String>] = [:]
        for relation in relations {
            parentsByChild[relation.toConceptID, default: []].insert(relation.fromConceptID)
        }

        var changed = true
        while changed {
            changed = false
            let currentConceptIDs = Set(membershipByKey.values
                .filter { $0.setID == sourceFamily }
                .map(\.conceptID))

            for childConceptID in currentConceptIDs {
                for parentConceptID in _sourceOutlineAncestors(
                    of: childConceptID,
                    parentsByChild: parentsByChild
                ) where parentConceptID != childConceptID {
                    let evidenceID = "evidence:semantic-closure:\(sourceFamily):\(parentConceptID):contains:\(childConceptID)"
                    evidenceByID[evidenceID] = try Inf6KnowledgeEvidence(
                        evidenceID: evidenceID,
                        sourceKind: sourceKind,
                        sourceID: sourceFamily,
                        locator: "semantic_closure:source_outline_contains:\(parentConceptID):\(childConceptID)"
                    )

                    let membershipKey = "\(sourceFamily)|\(parentConceptID)"
                    let evidenceIDs = (membershipByKey[membershipKey]?.evidenceIDs ?? []).union([evidenceID])
                    let next = try Inf6KnowledgeMembership(
                        setID: sourceFamily,
                        conceptID: parentConceptID,
                        evidenceIDs: evidenceIDs
                    )
                    if membershipByKey[membershipKey]?.evidenceIDs != next.evidenceIDs {
                        membershipByKey[membershipKey] = next
                        changed = true
                    }
                }
            }
        }
    }

    private static func _sourceOutlineAncestors(
        of conceptID: String,
        parentsByChild: [String: Set<String>]
    ) -> Set<String> {
        var out: Set<String> = []
        var stack = Array(parentsByChild[conceptID] ?? [])
        while let current = stack.popLast() {
            guard out.insert(current).inserted else { continue }
            stack.append(contentsOf: parentsByChild[current] ?? [])
        }
        return out
    }

    private static func _sourceKind(for manifest: Inf6LearningFamilyManifest) -> Inf6KnowledgeSourceKind {
        if manifest.usesMicrosoftLearnProvider { return .microsoftLearn }
        if manifest.usesJDLAHTMLProvider { return .jdlaSyllabus }
        return .other
    }

    private static func _cleanDisplay(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("-") { text.removeFirst() }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,、。:;"))
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    private static func _normalizeAlias(_ raw: String) -> String {
        let cleaned = _cleanDisplay(raw)
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
            .replacingOccurrences(of: "　", with: " ")
            .folding(options: [.widthInsensitive, .caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let collapsed = cleaned
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;"))
    }

    private static func _semanticSlug(_ raw: String) -> String {
        _normalizeAlias(raw)
            .replacingOccurrences(of: #"[^0-9a-zぁ-んァ-ヶ一-龥々ー]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func _expandedAliases(_ raw: String) -> Set<String> {
        let normalized = _normalizeAlias(raw)
        guard !normalized.isEmpty else { return [] }
        var out: Set<String> = [normalized]
        let withoutParens = normalized
            .replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !withoutParens.isEmpty { out.insert(withoutParens) }
        return out
    }

    private static func _manualCanonicalID(forAny aliases: Set<String>) -> String? {
        for alias in aliases {
            if let canonical = _manualAliasToCanonical[alias] {
                return canonical
            }
        }
        return nil
    }

    private static func _isAdministrativeLabel(_ raw: String) -> Bool {
        let text = _normalizeAlias(raw)
        if text.isEmpty { return true }
        let fragments = [
            "シラバス", "試験", "資格", "認定", "カテゴリ", "カテゴリー",
            "study guide", "exam", "certification", "credential", "associate",
            "キーワード内容を見直し", "表記内容", "表現の統一", "新規作成"
        ]
        if fragments.contains(where: { text.contains($0) }) { return true }
        let broadLabels: Set<String> = [
            "training",
            "parallel",
            "domestic",
            "development",
            "開発",
            "基本的なアルゴリズム",
            "様々な学習方法",
            "深層学習の応用",
            "深層学習の基礎",
            "機械学習の基礎",
            "機械学習の課題"
        ]
        return broadLabels.contains(text)
    }

    private struct _Term {
        let canonicalID: String
        let displayTitleJA: String?
        let displayTitleEN: String?
        let aliases: Set<String>
    }

    private struct _SourceAtom {
        let ja: String
        let en: String
    }

    private struct _DomainAudit: Codable, Hashable {
        let sourceFamily: String
        var outlineCount: Int
        var conceptNodeCount: Int
        var emittedAtomCount: Int
        var membershipCount: Int
    }

    private struct _StoredSeedFingerprint: Codable, Hashable {
        let seedSchemaVersion: Int?
        let paperCount: Int?
        let outlineCount: Int
        let outlineSignature: String?
        let supportsPapers: Bool?
        let domainTitleJa: String?
    }

    private static let _manualDisplayJA: [String: String] = [
        "concept:machine-learning": "機械学習",
        "concept:deep-learning": "深層学習",
        "concept:supervised-learning": "教師あり学習",
        "concept:unsupervised-learning": "教師なし学習",
        "concept:reinforcement-learning": "強化学習",
        "concept:deep-reinforcement-learning": "深層強化学習",
        "concept:neural-network": "ニューラルネットワーク",
        "concept:cnn": "畳み込みニューラルネットワーク",
        "concept:rnn": "再帰型ニューラルネットワーク",
        "concept:transformer": "Transformer",
        "concept:attention": "注意機構",
        "concept:backpropagation": "誤差逆伝播法",
        "concept:activation-function": "活性化関数",
        "concept:autoencoder": "オートエンコーダ",
        "concept:gan": "GAN",
        "concept:transfer-learning": "転移学習",
        "concept:fine-tuning": "ファインチューニング",
        "concept:nlp": "自然言語処理",
        "concept:computer-vision": "コンピュータビジョン",
        "concept:image-recognition": "画像認識",
        "concept:object-detection": "物体検出",
        "concept:generative-ai": "生成AI",
        "concept:large-language-model": "大規模言語モデル",
        "concept:normalization": "正規化",
        "concept:regularization": "正則化",
        "concept:dropout": "ドロップアウト",
        "concept:embedding": "埋め込み",
        "concept:prompt-engineering": "プロンプトエンジニアリング",
        "concept:rag": "検索拡張生成",
        "concept:responsible-ai": "責任あるAI",
        "concept:ai-governance": "AIガバナンス",
        "concept:content-safety": "コンテンツ安全性",
        "concept:image-classification": "画像分類",
        "concept:image-analysis": "画像分析",
        "concept:ocr": "OCR",
        "concept:speech-processing": "音声処理",
        "concept:speech-recognition": "音声認識",
        "concept:speech-synthesis": "音声合成",
        "concept:translation": "翻訳",
        "concept:language-understanding": "言語理解",
        "concept:question-answering": "質問応答",
        "concept:sentiment-analysis": "感情分析",
        "concept:information-extraction": "情報抽出",
        "concept:knowledge-mining": "ナレッジマイニング",
        "concept:model-evaluation": "モデル評価",
        "concept:meta-learning": "メタ学習",
        "concept:active-learning": "能動学習",
        "concept:federated-learning": "連合学習",
        "concept:metric-learning": "距離学習",
        "concept:cross-device-federated-learning": "クロスデバイス連合学習",
        "concept:maml": "MAML",
        "concept:uncertainty-sampling": "不確実性サンプリング",
        "concept:sample-pair-learning": "2サンプル比較学習",
        "concept:training-validation": "訓練と検証",
        "concept:data-collection-processing-analysis": "データの収集・加工・分析",
        "concept:meta-objective": "メタ目的関数",
        "concept:containerization": "コンテナ化",
        "concept:edge-computing": "エッジコンピューティング",
        "concept:multimodal": "マルチモーダル",
        "concept:agent": "エージェント",
        "concept:azure-ai-solution": "Azure AI ソリューション",
        "concept:azure-ai-resource": "Azure AI リソース",
        "concept:microsoft-foundry-service": "Microsoft Foundry Service",
        "concept:ai-model": "AIモデル",
        "concept:ci-cd": "CI/CD",
        "concept:authentication": "認証",
        "concept:cost-management": "コスト管理",
        "concept:model-monitoring": "モデル監視",
        "concept:diagnostics": "診断",
        "concept:deployment-management": "デプロイ管理",
        "concept:custom-vision": "Custom Vision",
        "concept:skillset": "スキルセット",
        "concept:indexer": "インデクサー",
        "concept:knowledge-store": "ナレッジストア",
        "concept:sdk-api": "SDK と API",
        "concept:service-endpoint": "サービスエンドポイント",
        "concept:account-key": "アカウントキー",
        "concept:generative-parameters": "生成パラメーター",
        "concept:image-labeling": "画像ラベル付け",
        "concept:prebuilt-model": "事前構築済みモデル",
        "concept:video-analysis": "動画分析",
        "concept:simulated-conversation": "シミュレート会話",
        "concept:index-query": "インデックスクエリ",
        "concept:tracing-feedback": "トレースとフィードバック",
        "concept:model-reflection": "モデルリフレクション"
    ]

    private static let _manualDisplayEN: [String: String] = [
        "concept:machine-learning": "Machine learning",
        "concept:deep-learning": "Deep learning",
        "concept:supervised-learning": "Supervised learning",
        "concept:unsupervised-learning": "Unsupervised learning",
        "concept:reinforcement-learning": "Reinforcement learning",
        "concept:deep-reinforcement-learning": "Deep reinforcement learning",
        "concept:neural-network": "Neural network",
        "concept:cnn": "Convolutional neural network",
        "concept:rnn": "Recurrent neural network",
        "concept:transformer": "Transformer",
        "concept:attention": "Attention",
        "concept:backpropagation": "Backpropagation",
        "concept:activation-function": "Activation function",
        "concept:autoencoder": "Autoencoder",
        "concept:gan": "Generative adversarial network",
        "concept:transfer-learning": "Transfer learning",
        "concept:fine-tuning": "Fine-tuning",
        "concept:nlp": "Natural language processing",
        "concept:computer-vision": "Computer vision",
        "concept:image-recognition": "Image recognition",
        "concept:object-detection": "Object detection",
        "concept:generative-ai": "Generative AI",
        "concept:large-language-model": "Large language model",
        "concept:normalization": "Normalization",
        "concept:regularization": "Regularization",
        "concept:dropout": "Dropout",
        "concept:embedding": "Embedding",
        "concept:prompt-engineering": "Prompt engineering",
        "concept:rag": "Retrieval-augmented generation",
        "concept:responsible-ai": "Responsible AI",
        "concept:ai-governance": "AI governance",
        "concept:content-safety": "Content safety",
        "concept:image-classification": "Image classification",
        "concept:image-analysis": "Image analysis",
        "concept:ocr": "Optical character recognition",
        "concept:speech-processing": "Speech processing",
        "concept:speech-recognition": "Speech recognition",
        "concept:speech-synthesis": "Speech synthesis",
        "concept:translation": "Translation",
        "concept:language-understanding": "Language understanding",
        "concept:question-answering": "Question answering",
        "concept:sentiment-analysis": "Sentiment analysis",
        "concept:information-extraction": "Information extraction",
        "concept:knowledge-mining": "Knowledge mining",
        "concept:model-evaluation": "Model evaluation",
        "concept:meta-learning": "Meta-learning",
        "concept:active-learning": "Active learning",
        "concept:federated-learning": "Federated learning",
        "concept:metric-learning": "Metric learning",
        "concept:cross-device-federated-learning": "Cross-device federated learning",
        "concept:maml": "MAML",
        "concept:uncertainty-sampling": "Uncertainty sampling",
        "concept:sample-pair-learning": "Sample-pair representation learning",
        "concept:training-validation": "Training and validation",
        "concept:data-collection-processing-analysis": "Data collection, processing, and analysis",
        "concept:meta-objective": "Meta-objective",
        "concept:containerization": "Containerization",
        "concept:edge-computing": "Edge computing",
        "concept:multimodal": "Multimodal learning",
        "concept:agent": "Agent",
        "concept:azure-ai-solution": "Azure AI solution",
        "concept:azure-ai-resource": "Azure AI resource",
        "concept:microsoft-foundry-service": "Microsoft Foundry Service",
        "concept:ai-model": "AI model",
        "concept:ci-cd": "CI/CD",
        "concept:authentication": "Authentication",
        "concept:cost-management": "Cost management",
        "concept:model-monitoring": "Model monitoring",
        "concept:diagnostics": "Diagnostics",
        "concept:deployment-management": "Deployment management",
        "concept:custom-vision": "Custom Vision",
        "concept:skillset": "Skillset",
        "concept:indexer": "Indexer",
        "concept:knowledge-store": "Knowledge Store",
        "concept:sdk-api": "SDKs and APIs",
        "concept:service-endpoint": "Service endpoint",
        "concept:account-key": "Account key",
        "concept:generative-parameters": "Generative parameters",
        "concept:image-labeling": "Image labeling",
        "concept:prebuilt-model": "Prebuilt model",
        "concept:video-analysis": "Video analysis",
        "concept:simulated-conversation": "Simulated conversation",
        "concept:index-query": "Index query",
        "concept:tracing-feedback": "Tracing and feedback",
        "concept:model-reflection": "Model reflection"
    ]

    private static let _manualAliases: [String: Set<String>] = [
        "concept:machine-learning": ["機械学習", "machine learning", "ml"],
        "concept:deep-learning": ["深層学習", "ディープラーニング", "deep learning", "dl"],
        "concept:supervised-learning": ["教師あり学習", "supervised learning"],
        "concept:unsupervised-learning": ["教師なし学習", "unsupervised learning"],
        "concept:reinforcement-learning": ["強化学習", "reinforcement learning", "rl"],
        "concept:deep-reinforcement-learning": ["深層強化学習", "deep reinforcement learning", "deep rl"],
        "concept:neural-network": ["ニューラルネットワーク", "neural network", "neural networks"],
        "concept:cnn": ["cnn", "畳み込みニューラルネットワーク", "畳込みニューラルネットワーク", "畳み込み層", "畳込み層", "畳み込み演算", "基本的な畳み込み演算", "convolutional neural network", "convolutional neural networks", "convolutional layers", "convolution layers", "basic convolution operations"],
        "concept:rnn": ["rnn", "再帰型ニューラルネットワーク", "回帰結合層", "recurrent neural network", "recurrent neural networks", "recurrent layers"],
        "concept:transformer": ["transformer", "transformers", "トランスフォーマー"],
        "concept:attention": ["attention", "注意機構", "アテンション"],
        "concept:backpropagation": ["誤差逆伝播法", "誤差逆伝播", "backpropagation", "back-propagation"],
        "concept:activation-function": ["活性化関数", "activation function", "activation functions"],
        "concept:autoencoder": ["オートエンコーダ", "オートエンコーダー", "autoencoder", "autoencoders"],
        "concept:gan": ["gan", "gans", "敵対的生成ネットワーク", "generative adversarial network", "generative adversarial networks"],
        "concept:transfer-learning": ["転移学習", "transfer learning"],
        "concept:fine-tuning": ["ファインチューニング", "fine tuning", "fine-tuning", "finetuning"],
        "concept:nlp": ["自然言語処理", "nlp", "natural language processing"],
        "concept:computer-vision": ["コンピュータビジョン", "computer vision"],
        "concept:image-recognition": ["画像認識", "image recognition", "image classification"],
        "concept:object-detection": ["物体検出", "object detection"],
        "concept:generative-ai": ["生成ai", "生成 ai", "生成系ai", "生成モデル", "データ生成", "画像を生成", "コンテンツを生成", "generative ai", "generative model", "generative models", "data generation", "generate content", "generate images", "dall-e"],
        "concept:large-language-model": ["大規模言語モデル", "言語モデル", "llm", "llms", "large language model", "large language models", "language model", "language models", "azure openai", "openai model", "foundry models", "natural language responses"],
        "concept:normalization": ["正規化", "正規化層", "normalization", "normalisation", "normalization layer", "normalization layers"],
        "concept:regularization": ["正則化", "深層モデルのための正則化", "regularization", "regularisation", "regularization for deep models"],
        "concept:dropout": ["ドロップアウト", "dropout"],
        "concept:embedding": ["埋め込み", "埋込み", "embedding", "embeddings", "vector store", "vector stores", "semantic store", "semantic stores"],
        "concept:prompt-engineering": ["プロンプトエンジニアリング", "プロンプト", "prompt engineering", "prompt", "prompts"],
        "concept:rag": ["rag", "検索拡張生成", "retrieval augmented generation", "retrieval-augmented generation"],
        "concept:responsible-ai": ["責任あるai", "responsible ai", "responsible ai principles", "公平性", "透明性", "プライバシー", "悪用", "国内外のガイドライン", "モデルの解釈性", "説明性", "explainability", "interpretability", "fairness", "transparency", "privacy", "misuse", "guidelines"],
        "concept:ai-governance": ["aiガバナンス", "ai ガバナンス", "ai governance", "governance framework"],
        "concept:content-safety": ["コンテンツ安全性", "コンテンツの安全性", "安全性とセキュリティ", "安全性", "セキュリティ", "悪用", "content safety", "safety and security", "safety", "security", "content filter", "content filters", "blocklist", "blocklists", "prompt shield", "prompt shields", "harm detection", "content moderation"],
        "concept:image-classification": ["画像分類", "image classification"],
        "concept:image-analysis": ["画像分析", "image analysis", "analyze images", "image processing", "extract insights from a video", "spatial analysis"],
        "concept:ocr": ["ocr", "光学文字認識", "画像からテキスト", "手書きのテキスト", "document intelligence", "extract text from images", "handwritten text"],
        "concept:speech-processing": ["音声処理", "speech processing", "speech solution", "speech solutions"],
        "concept:speech-recognition": ["音声認識", "speech recognition", "speech-to-text", "speech to text"],
        "concept:speech-synthesis": ["音声合成", "speech synthesis", "text-to-speech", "text to speech", "ssml"],
        "concept:translation": ["翻訳", "translation", "translator", "translate text", "translate documents", "custom translation"],
        "concept:language-understanding": ["言語理解", "言語を検出", "language understanding", "language detection", "detect language", "detect the language used in text", "intent recognition", "intents", "utterances"],
        "concept:question-answering": ["質問応答", "質問回答", "質問と回答", "question answering", "question-answering", "question-and-answer", "question-and-answer pairs", "question answer pairs", "knowledge base"],
        "concept:sentiment-analysis": ["感情分析", "sentiment analysis", "sentiment"],
        "concept:information-extraction": ["情報抽出", "キーワード", "information extraction", "key phrase", "key phrases", "entities", "entity extraction", "pii", "extract information", "extract entities", "detect attributes"],
        "concept:knowledge-mining": ["ナレッジマイニング", "ナレッジ マイニング", "知識表現", "エキスパートシステム", "knowledge mining", "knowledge representation", "expert systems", "azure ai search", "ai search", "search solution"],
        "concept:model-evaluation": ["モデル評価", "モデルの選択", "評価指標", "性能指標", "モデルの評価", "evaluation", "model evaluation", "model selection", "evaluate models", "test and publish", "test optimize and deploy", "evaluate custom vision model metrics", "performance metrics"],
        "concept:data-augmentation": ["データ拡張", "データ集合の拡張", "画像のデータ拡張", "音声のデータ拡張", "data augmentation", "dataset augmentation", "image data augmentation", "audio data augmentation"],
        "concept:statistics": ["統計", "統計知識", "ai に必要な数理", "statistics", "statistics for ai", "mathematics"],
        "concept:loss-function": ["誤差関数", "損失関数", "loss function", "loss functions"],
        "concept:pooling": ["プーリング", "プーリング層", "pooling", "pooling layer", "pooling layers"],
        "concept:fully-connected-layer": ["全結合層", "fully connected layer", "fully connected layers"],
        "concept:skip-connection": ["スキップ結合", "skip connection", "skip connections"],
        "concept:meta-learning": ["メタ学習", "メタ学習(meta", "meta learning", "meta-learning"],
        "concept:active-learning": ["能動学習", "能動学習(active", "active learning"],
        "concept:federated-learning": ["連合学習", "連合学習(federated", "federated learning"],
        "concept:metric-learning": ["距離学習", "距離学習(metric", "metric learning"],
        "concept:cross-device-federated-learning": ["クロスデバイス学習", "learning) クロスデバイス学習", "cross-device federated learning"],
        "concept:maml": ["maml", "初期値の獲得", "learning) 初期値の獲得 maml", "learning initial parameters"],
        "concept:uncertainty-sampling": ["uncertainty sampling", "learning) uncertainty sampling"],
        "concept:sample-pair-learning": ["2サンプルによる比較", "表現学習", "learning) 2サンプルによる比較 表現学習", "learning from sample pairs and representation learning"],
        "concept:training-validation": ["訓練と検証", "training validation", "training, validation"],
        "concept:data-collection-processing-analysis": ["データの収集・加工・分析", "data collection processing analysis", "data collection, processing, analysis"],
        "concept:meta-objective": ["メタ目的関数", "メタ目的関数(meta-objective", "meta objective", "meta-objective"],
        "concept:containerization": ["コンテナ化", "コンテナ型", "コンテナー", "コンテナーのデプロイ", "container", "containers", "container deployment"],
        "concept:edge-computing": ["エッジコンピューティング", "edge computing", "edge devices"],
        "concept:multimodal": ["マルチモーダル", "multimodal", "large multimodal model", "large multimodal models"],
        "concept:agent": ["エージェント", "agent", "agents", "agentic solution", "multi-agent", "complex agents"],
        "concept:azure-ai-solution": ["azure ai ソリューション", "azure ai solution", "ai solutions responsibly"],
        "concept:azure-ai-resource": ["azure ai リソース", "azure ai resource", "azure ai resources"],
        "concept:microsoft-foundry-service": ["microsoft foundry service", "microsoft foundry services", "microsoft foundry サービス", "foundry service", "foundry services", "foundry tools", "foundry tools サービス"],
        "concept:ai-model": ["aiモデル", "ai モデル", "ai model", "ai models", "appropriate ai models"],
        "concept:ci-cd": ["ci/cd", "continuous integration", "continuous delivery", "継続的インテグレーション", "継続的デリバリー"],
        "concept:authentication": ["認証", "authentication"],
        "concept:cost-management": ["コスト", "コスト管理", "cost", "costs", "cost management"],
        "concept:model-monitoring": ["モデル監視", "model monitoring", "monitor model", "monitoring"],
        "concept:diagnostics": ["診断", "diagnostic", "diagnostics", "diagnostic settings"],
        "concept:deployment-management": ["デプロイ", "デプロイ管理", "deployment", "deployment management", "manage resources for deployment", "scalability", "backup", "recover"],
        "concept:custom-vision": ["custom vision", "カスタム ビジョン", "カスタムビジョン"],
        "concept:skillset": ["skillset", "skillsets", "スキルセット", "custom skills"],
        "concept:indexer": ["indexer", "indexers", "インデクサー", "インデックス作成"],
        "concept:knowledge-store": ["knowledge store", "knowledge store projections", "ナレッジストア"],
        "concept:sdk-api": ["sdk", "sdks", "api", "apis", "sdk と api", "sdk and api", "sdks and apis"],
        "concept:service-endpoint": ["エンドポイント", "既定のエンドポイント", "endpoint", "endpoints", "default endpoint"],
        "concept:account-key": ["アカウント キー", "アカウントキー", "account key", "account keys"],
        "concept:generative-parameters": ["生成動作", "生成パラメーター", "パラメーター", "generative behavior", "generative parameters", "parameters to control generative behavior"],
        "concept:image-labeling": ["ラベル イメージ", "画像ラベル", "画像ラベル付け", "label images", "image labeling", "image labels", "image tags"],
        "concept:prebuilt-model": ["事前構築済みモデル", "prebuilt model", "prebuilt models"],
        "concept:video-analysis": ["動画分析", "ビデオ", "video analysis", "video indexer", "extract insights from a video", "live stream"],
        "concept:simulated-conversation": ["シミュレート会話", "シミュレートされた会話", "マルチターン会話", "multi-turn conversation", "simulated conversation", "simulated conversations"],
        "concept:index-query": ["インデックスのクエリ", "index query", "query an index", "syntax sorting filtering wildcards"],
        "concept:tracing-feedback": ["トレース", "フィードバック", "tracing", "feedback", "enable tracing", "collect feedback"],
        "concept:model-reflection": ["モデル リフレクション", "モデルリフレクション", "model reflection"]
    ].mapValues { Set($0.map(_normalizeAlias)) }

    private static let _manualAliasToCanonical: [String: String] = {
        var out: [String: String] = [:]
        for (canonical, aliases) in _manualAliases {
            for alias in aliases {
                out[alias] = canonical
            }
        }
        return out
    }()
}
