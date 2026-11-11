//
//  Inf6KnowledgeGraphView.swift
//  inf6
//
//  観測済み概念集合の表示。
//  parentNodeID を知識上の親子として扱わず、永続化済み Relation の種別で表示を分ける。
//

import Foundation
import SwiftUI

struct Inf6KnowledgeGraphView: View {
    let domains: [_KnowledgeGraphDomain]
    var showPapers: Bool = false
    var onSelectNode: ((String) -> Void)? = nil
    var onSelectPaper: ((String) -> Void)? = nil
    let onSearchConcept: (Inf6ConceptPaperSearchRequest) -> Void

    struct _KnowledgeGraphDomain {
        let manifest: Inf6LearningFamilyManifest
        let structure: Inf6KnowledgeDomainStructure
        let accentColor: Color
    }

    private struct _ConceptItem: Identifiable, Hashable {
        let id: String
        let titleJa: String
        let titleEn: String
        let parentTitleJa: String
        let parentTitleEn: String
        let domainTitleJa: String
        let domainTitleEn: String
        let kind: Inf6KnowledgeNodeKind
        let paperID: String?
        let linkedPaperIDs: [String]
        let importance: Int
        let relationCount: Int
        let achievement: Inf6KnowledgeAchievementState
        let achievementFraction: Double
        let sourceOrder: Int
        let canonicalID: String?
    }

    private struct _PaperItem: Identifiable, Hashable {
        let id: String
        let title: String
        let titleEn: String?
        let year: Int?
        let provider: String
        let conceptCount: Int
    }

    private struct _PaperColumns {
        let corpus: [_PaperItem]
        let linked: [_PaperItem]
        let corpusTintByPaperID: [String: Color]
        let linkedTintByPaperID: [String: Color]
        let unresolvedIDCount: Int
    }

    private struct _PlacedConcept: Identifiable {
        let id: String
        let item: _ConceptItem
        let componentID: String
        let center: CGPoint
        let size: CGSize
        let tint: Color
    }

    private struct _VisibleRelationGraph {
        let relations: [Inf6KnowledgeRelation]
        let undirected: [String: Set<String>]
        let outgoingPrerequisites: [String: Set<String>]
        let incomingPrerequisites: [String: Set<String>]

        var hasRelations: Bool {
            !relations.isEmpty
        }

        var hasPrerequisites: Bool {
            !outgoingPrerequisites.isEmpty
        }

        func relationCount(for ids: Set<String>) -> Int {
            relations.filter { ids.contains($0.fromConceptID) || ids.contains($0.toConceptID) }.count
        }

        func degree(_ canonicalID: String?) -> Int {
            guard let canonicalID else { return 0 }
            return undirected[canonicalID]?.count ?? 0
        }

        func prerequisiteInDegree(_ canonicalID: String?) -> Int {
            guard let canonicalID else { return 0 }
            return incomingPrerequisites[canonicalID]?.count ?? 0
        }

        func prerequisiteOutDegree(_ canonicalID: String?) -> Int {
            guard let canonicalID else { return 0 }
            return outgoingPrerequisites[canonicalID]?.count ?? 0
        }
    }

    @AppStorage("gen_lang") private var _genLangRaw: String = "ja"
    @AppStorage("inf6_ui_language") private var _uiLanguageRaw: String = "auto"
    @State private var _selectedConceptID: String?

    var body: some View {
        GeometryReader { proxy in
            let availableHeight = max(700, proxy.size.height - 36)
            let paperColumnWidth: CGFloat = 370
            let columnSpacing: CGFloat = 28
            let contentWidth = max(1180, proxy.size.width - 56)
            let conceptColumnWidth = max(
                430,
                contentWidth - paperColumnWidth * 2 - columnSpacing * 2
            )
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 16) {
                    let relationGraph = _relationGraph
                    let conceptItems = _sortedConceptItems(_allConceptItems, graph: relationGraph)
                    let selectedConcept = _selectedConcept(from: conceptItems)
                    let paperColumns = _paperColumns(for: conceptItems, selectedConcept: selectedConcept)

                    if conceptItems.isEmpty {
                        Text(_displayText(
                            ja: "概念データなし",
                            en: "No concept data"
                        ))
                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(15), weight: .semibold))
                        .foregroundStyle(.red)
                        .padding(14)
                        .frame(width: 940, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(uiColor: .systemBackground))
                        )
                    } else {
                        HStack(alignment: .top, spacing: 28) {
                            _paperListColumn(
                                title: _displayText(ja: "論文コーパス", en: "Corpus papers"),
                                papers: paperColumns.corpus,
                                tintByPaperID: paperColumns.corpusTintByPaperID
                            )
                            _conceptSetColumn(
                                items: conceptItems,
                                graph: relationGraph,
                                selectedID: selectedConcept?.id,
                                availableWidth: conceptColumnWidth,
                                availableHeight: availableHeight
                            )
                            _paperListColumn(
                                title: _linkedPaperColumnTitle(selectedConcept),
                                papers: paperColumns.linked,
                                tintByPaperID: paperColumns.linkedTintByPaperID
                            )
                            .id(selectedConcept?.id ?? "linked-papers-none")
                        }
                        .frame(height: availableHeight, alignment: .top)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
                .frame(minWidth: contentWidth, minHeight: proxy.size.height, alignment: .topLeading)
            }
            .background(Color(uiColor: .systemBackground))
        }
    }

    private var _allConceptItems: [_ConceptItem] {
        let corpus = _corpusConceptItems()
        if !corpus.isEmpty { return corpus }
        return _syllabusNodeItems()
    }

    private func _corpusConceptItems() -> [_ConceptItem] {
        let domainIDs = Set(domains.map(\.manifest.sourceFamily).filter { !$0.isEmpty })
        guard !domainIDs.isEmpty else { return [] }

        let metricsByConcept = Dictionary(
            uniqueKeysWithValues: Inf6MetadataStore
                .listAllCodable(Inf6ConceptMetric.self, domain: .conceptMetrics)
                .map { ($0.value.canonicalID, $0.value) }
        )

        let paperAchievements = Inf6CorePaperStore.shared.achievementByPaperID

        var paperIDsByConcept: [String: Set<String>] = [:]
        for mention in Inf6MetadataStore.listAllCodable(Inf6CorpusConceptMention.self, domain: .corpusConceptMentions).map(\.value) {
            guard mention.sourceID.hasPrefix("paper/") else { continue }
            let paperID = String(mention.sourceID.dropFirst("paper/".count))
            if paperID.isEmpty { continue }
            paperIDsByConcept[mention.canonicalID, default: []].insert(paperID)
        }

        let domainTitleByID = Dictionary(uniqueKeysWithValues: domains.map {
            ($0.manifest.sourceFamily, (ja: $0.manifest.displayNameJa, en: $0.manifest.displayNameEn))
        })

        var seen = Set<String>()
        var items: [_ConceptItem] = []

        for (index, candidate) in Inf6MetadataStore
            .listAllCodable(Inf6CorpusConceptCandidate.self, domain: .corpusConceptCandidates)
            .map(\.value)
            .sorted(by: { $0.canonicalID < $1.canonicalID })
            .enumerated() {
            let visibleDomains = candidate.sourceDomains.intersection(domainIDs)
            guard !visibleDomains.isEmpty else { continue }
            guard !seen.contains(candidate.canonicalID) else { continue }

            let canonical = Inf6CanonicalConceptRegistry.get(candidate.canonicalID)
            let titleJa = _firstNonEmpty([
                candidate.displayTitleJA,
                canonical?.displayTitleJA,
                _canonicalTail(candidate.canonicalID, preferJapanese: true)
            ])
            let titleEn = _firstNonEmpty([
                candidate.displayTitleEN,
                canonical?.displayTitleEN,
                _canonicalTail(candidate.canonicalID, preferJapanese: false)
            ])
            guard !titleJa.isEmpty || !titleEn.isEmpty else { continue }
            guard !_isAdministrativeConceptLabel(titleJa) && !_isAdministrativeConceptLabel(titleEn) else { continue }
            seen.insert(candidate.canonicalID)

            let domainTitles = visibleDomains.sorted().compactMap { domainTitleByID[$0] }
            let metric = metricsByConcept[candidate.canonicalID]
            let linkedPaperIDs = Array(paperIDsByConcept[candidate.canonicalID] ?? []).sorted()
            let achievement: Inf6KnowledgeAchievementState
            let achievementFrac: Double
            if let metric {
                achievement = _achievement(from: metric)
                achievementFrac = min(1.0, max(0.0, metric.achievementWeight))
            } else {
                let paperStates = linkedPaperIDs.compactMap { paperAchievements[$0] }
                achievement = _aggregateAchievement(paperStates)
                achievementFrac = _achievementFraction(achievement)
            }
            items.append(_ConceptItem(
                id: candidate.canonicalID,
                titleJa: titleJa,
                titleEn: titleEn,
                parentTitleJa: domainTitles.map(\.ja).joined(separator: " / "),
                parentTitleEn: domainTitles.map(\.en).joined(separator: " / "),
                domainTitleJa: domainTitles.map(\.ja).joined(separator: " / "),
                domainTitleEn: domainTitles.map(\.en).joined(separator: " / "),
                kind: .topic,
                paperID: nil,
                linkedPaperIDs: linkedPaperIDs,
                importance: max(linkedPaperIDs.count, metric?.paperMentionCount ?? 0),
                relationCount: metric?.relationCount ?? 0,
                achievement: achievement,
                achievementFraction: achievementFrac,
                sourceOrder: index,
                canonicalID: candidate.canonicalID
            ))
        }

        return items
    }

    private func _syllabusNodeItems() -> [_ConceptItem] {
        let paperAchievements = Inf6CorePaperStore.shared.achievementByPaperID
        var items: [_ConceptItem] = []
        for (index, domain) in domains.enumerated() {
            let sf = domain.manifest.sourceFamily
            for node in domain.structure.nodes {
                guard node.kind == .major || node.kind == .minor || node.kind == .topic else { continue }
                let achievement = _aggregateAchievement(node.linkedPaperIDs.compactMap { paperAchievements[$0] })
                items.append(_ConceptItem(
                    id: "\(sf):\(node.nodeID)",
                    titleJa: node.titleJa,
                    titleEn: node.titleEn,
                    parentTitleJa: domain.manifest.displayNameJa,
                    parentTitleEn: domain.manifest.displayNameEn,
                    domainTitleJa: domain.manifest.displayNameJa,
                    domainTitleEn: domain.manifest.displayNameEn,
                    kind: node.kind,
                    paperID: nil,
                    linkedPaperIDs: node.linkedPaperIDs,
                    importance: node.paperCount,
                    relationCount: 0,
                    achievement: achievement,
                    achievementFraction: _achievementFraction(achievement),
                    sourceOrder: index * 1000 + (items.count % 1000),
                    canonicalID: nil
                ))
            }
        }
        return items
    }

    private var _relationGraph: _VisibleRelationGraph {
        _buildRelationGraph(items: _allConceptItems)
    }

    private func _displayText(ja: String, en: String) -> String {
        let jaText = ja.trimmingCharacters(in: .whitespacesAndNewlines)
        let enText = en.trimmingCharacters(in: .whitespacesAndNewlines)
        return Inf6Lang.text(jaText, enText)
    }

    private func _isAdministrativeConceptLabel(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.range(of: #"[[:alnum:]ぁ-んァ-ヶ一-龥々]"#, options: .regularExpression) == nil {
            return true
        }
        let compact = text.replacingOccurrences(of: " ", with: "")
        if ["キーワード", "keyword", "keywords"].contains(compact) {
            return true
        }
        let fragments = [
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
        return fragments.contains { text.contains($0) }
    }

    private func _buildRelationGraph(items: [_ConceptItem]) -> _VisibleRelationGraph {
        let visibleIDs = Set(items.compactMap(\.canonicalID))
        guard !visibleIDs.isEmpty else {
            return _VisibleRelationGraph(
                relations: [],
                undirected: [:],
                outgoingPrerequisites: [:],
                incomingPrerequisites: [:]
            )
        }

        let relations = Inf6MetadataStore
            .listAllCodable(Inf6KnowledgeRelation.self, domain: .knowledgeRelations)
            .map(\.value)
            .filter { relation in
                visibleIDs.contains(relation.fromConceptID)
                    && visibleIDs.contains(relation.toConceptID)
                    && relation.kind != .sourceOutlineContains
            }

        var undirected: [String: Set<String>] = [:]
        var outgoingPrerequisites: [String: Set<String>] = [:]
        var incomingPrerequisites: [String: Set<String>] = [:]

        for relation in relations {
            undirected[relation.fromConceptID, default: []].insert(relation.toConceptID)
            undirected[relation.toConceptID, default: []].insert(relation.fromConceptID)

            if relation.kind == .prerequisite {
                outgoingPrerequisites[relation.fromConceptID, default: []].insert(relation.toConceptID)
                incomingPrerequisites[relation.toConceptID, default: []].insert(relation.fromConceptID)
            }
        }

        return _VisibleRelationGraph(
            relations: relations,
            undirected: undirected,
            outgoingPrerequisites: outgoingPrerequisites,
            incomingPrerequisites: incomingPrerequisites
        )
    }

    private func _relationComponents(items: [_ConceptItem], graph: _VisibleRelationGraph) -> [[_ConceptItem]] {
        let itemsByConcept = Dictionary(grouping: items, by: { $0.canonicalID ?? $0.id })
        var unvisited = Set(itemsByConcept.keys)
        var components: [[_ConceptItem]] = []

        while let start = unvisited.first {
            var stack = [start]
            var componentIDs = Set<String>()
            unvisited.remove(start)

            while let current = stack.popLast() {
                componentIDs.insert(current)
                for neighbor in graph.undirected[current] ?? [] where unvisited.contains(neighbor) {
                    unvisited.remove(neighbor)
                    stack.append(neighbor)
                }
            }

            let componentItems = componentIDs
                .flatMap { itemsByConcept[$0] ?? [] }
            if !componentItems.isEmpty {
                components.append(componentItems)
            }
        }

        return components
    }

    private func _sortForEvidence(_ items: [_ConceptItem], graph: _VisibleRelationGraph) -> [_ConceptItem] {
        items.sorted { lhs, rhs in
            if lhs.importance != rhs.importance {
                return lhs.importance > rhs.importance
            }

            let leftDegree = graph.degree(lhs.canonicalID)
            let rightDegree = graph.degree(rhs.canonicalID)
            if leftDegree != rightDegree {
                return leftDegree > rightDegree
            }

            let leftAchievement = lhs.achievementFraction
            let rightAchievement = rhs.achievementFraction
            if leftAchievement != rightAchievement {
                return leftAchievement < rightAchievement
            }

            return _displayText(ja: lhs.titleJa, en: lhs.titleEn)
                .localizedStandardCompare(_displayText(ja: rhs.titleJa, en: rhs.titleEn)) == .orderedAscending
        }
    }

    @ViewBuilder
    private func _paperListColumn(title: String, papers: [_PaperItem], tintByPaperID: [String: Color]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(18), weight: .bold))
                .foregroundStyle(Color(uiColor: .label))
                .padding(.horizontal, 2)

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(papers) { paper in
                        _PaperListRow(
                            title: _paperDisplayTitle(paper),
                            tint: tintByPaperID[paper.id] ?? _paperTint(paper)
                        ) {
                            onSelectPaper?(paper.id)
                        }
                        Divider()
                    }
                }
            }
        }
        .frame(width: 370, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func _paperDisplayTitle(_ paper: _PaperItem) -> String {
        let title = _displayText(ja: paper.title, en: paper.titleEn ?? paper.title)
        guard let year = paper.year else { return title }
        return "\(year) \(title)"
    }

    @ViewBuilder
    private func _conceptSetColumn(
        items: [_ConceptItem],
        graph: _VisibleRelationGraph,
        selectedID: String?,
        availableWidth: CGFloat,
        availableHeight: CGFloat
    ) -> some View {
        let columnWidth = max(430, availableWidth)
        VStack(alignment: .leading, spacing: 10) {
            Text(_displayText(ja: "概念集合", en: "Concept set"))
                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(18), weight: .bold))
                .foregroundStyle(Color(uiColor: .label))
                .padding(.horizontal, 2)

            ScrollView(.vertical) {
                let layout = _conceptSetMapLayout(
                    items: items,
                    graph: graph,
                    availableWidth: columnWidth,
                    availableHeight: availableHeight - 34
                )
                ZStack(alignment: .topLeading) {
                    ForEach(layout.placed) { placed in
                        VStack(spacing: 4) {
                            _ConceptSetAtom(
                                title: _displayText(ja: placed.item.titleJa, en: placed.item.titleEn),
                                tint: placed.tint,
                                achievementFraction: placed.item.achievementFraction,
                                isSelected: selectedID == placed.item.id,
                                size: placed.size
                            ) {
                                _selectedConceptID = placed.item.id
                            }

                            if selectedID == placed.item.id {
                                HStack(spacing: 6) {
                                    Button {
                                        onSelectNode?("inf6-explanation:\(placed.item.id)")
                                    } label: {
                                        Label(L("概要解説", "Overview"), systemImage: "doc.text")
                                            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(11), weight: .medium))
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.purple)
                                    .controlSize(.mini)

                                    Button {
                                        _runNodePipeline(itemID: placed.item.id, kind: "figures")
                                    } label: {
                                        Label(L("図表", "Figures"), systemImage: "photo.badge.plus")
                                            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(11), weight: .medium))
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.orange)
                                    .controlSize(.mini)

                                    Button {
                                        _runNodePipeline(itemID: placed.item.id, kind: "equations")
                                    } label: {
                                        Label(L("数式", "Equations"), systemImage: "function")
                                            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(11), weight: .medium))
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.blue)
                                    .controlSize(.mini)
                                }
                                .transition(.opacity.combined(with: .scale(scale: 0.8)))
                            }
                        }
                        .position(placed.center)
                        .animation(.easeInOut(duration: 0.2), value: selectedID)
                    }
                }
                .frame(width: columnWidth, height: layout.height + 40, alignment: .topLeading)
            }
        }
        .frame(width: columnWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func _runNodePipeline(itemID: String, kind: String) {
        // itemID is "sourceFamily:nodeID", pipeline prefix encodes kind
        onSelectNode?("inf6-pipeline:\(kind):\(itemID)")
    }

    private func _conceptSetMapLayout(
        items: [_ConceptItem],
        graph: _VisibleRelationGraph,
        availableWidth: CGFloat,
        availableHeight: CGFloat
    ) -> (placed: [_PlacedConcept], height: CGFloat) {
        let groups = _conceptSetGroups(items: items, graph: graph)
        let canvasWidth = max(430, availableWidth)
        let sidePadding: CGFloat = 26
        let topPadding: CGFloat = 30
        let bottomPadding: CGFloat = 48

        var placed: [_PlacedConcept] = []
        var cursorY = topPadding

        for (groupIndex, group) in groups.enumerated() {
            let componentID = group.id
            let sortedItems = _sortForEvidence(group.items, graph: graph)
            let relationWeight = min(1.0, Double(graph.relationCount(for: Set(sortedItems.compactMap(\.canonicalID)))) / 70.0)
            let preparedItems = sortedItems.map { item -> (item: _ConceptItem, size: CGSize, tint: Color) in
                let degree = graph.degree(item.canonicalID)
                return (
                    item,
                    _conceptAtomSize(
                        for: item,
                        degree: degree,
                        title: _displayText(ja: item.titleJa, en: item.titleEn)
                    ),
                    _conceptTint(item, fallback: _componentTint(groupIndex))
                )
            }
            let clusterWidth = canvasWidth - sidePadding * 2
            let columnCount = _clusterColumnCount(
                itemCount: preparedItems.count,
                clusterWidth: clusterWidth
            )
            let cellWidth = clusterWidth / CGFloat(max(1, columnCount))
            let fittedItems = preparedItems.map { prepared -> (item: _ConceptItem, size: CGSize, tint: Color) in
                let fittedWidth = min(prepared.size.width, max(108, cellWidth - 16))
                return (
                    prepared.item,
                    CGSize(width: fittedWidth, height: prepared.size.height),
                    prepared.tint
                )
            }
            let maxItemHeight = fittedItems.map(\.size.height).max() ?? 52
            let naturalClusterHeight = _clusterHeight(
                itemCount: fittedItems.count,
                relationWeight: relationWeight,
                maxItemHeight: maxItemHeight,
                columnCount: columnCount
            )
            let clusterHeight = groups.count == 1
                ? max(naturalClusterHeight, availableHeight - topPadding - bottomPadding)
                : naturalClusterHeight
            let clusterFrame = CGRect(
                x: sidePadding,
                y: cursorY,
                width: clusterWidth,
                height: clusterHeight
            )
            let rowCount = _clusterRowCount(itemCount: preparedItems.count, columnCount: columnCount)
            let rowStride = _clusterRowStride(
                clusterHeight: clusterHeight,
                maxItemHeight: maxItemHeight,
                rowCount: rowCount
            )
            let firstRowY = clusterFrame.minY + maxItemHeight / 2 + 18

            for (offset, prepared) in fittedItems.enumerated() {
                let row = offset / max(1, columnCount)
                let column = offset % max(1, columnCount)
                let itemsInRow = min(columnCount, fittedItems.count - row * columnCount)
                let rowWidth = CGFloat(itemsInRow) * cellWidth
                let rowStartX = clusterFrame.midX - rowWidth / 2 + cellWidth / 2
                let stagger = _rowStagger(row: row, column: column, columnCount: itemsInRow, cellWidth: cellWidth)
                placed.append(_PlacedConcept(
                    id: prepared.item.id,
                    item: prepared.item,
                    componentID: componentID,
                    center: CGPoint(
                        x: rowStartX + CGFloat(column) * cellWidth + stagger.x,
                        y: firstRowY + CGFloat(row) * rowStride + stagger.y
                    ),
                    size: prepared.size,
                    tint: prepared.tint
                ))
            }

            cursorY += clusterHeight + (sortedItems.count > 1 ? 18 : 12)
        }

        let height = max(availableHeight, (placed.map { $0.center.y + $0.size.height / 2 }.max() ?? 0) + bottomPadding)
        return (placed, height)
    }

    private func _clusterColumnCount(itemCount: Int, clusterWidth: CGFloat) -> Int {
        guard itemCount > 1 else { return 1 }
        let targetCellWidth: CGFloat = 230
        let fittingColumns = max(1, Int(floor(clusterWidth / targetCellWidth)))
        return min(itemCount, min(3, fittingColumns))
    }

    private func _clusterHeight(itemCount: Int, relationWeight: Double, maxItemHeight: CGFloat, columnCount: Int) -> CGFloat {
        let rows = _clusterRowCount(itemCount: itemCount, columnCount: columnCount)
        let rowStride = maxItemHeight + 12
        let base = CGFloat(rows) * rowStride + maxItemHeight + 24
        return max(maxItemHeight + 44, base + CGFloat(relationWeight) * 10)
    }

    private func _clusterRowCount(itemCount: Int, columnCount: Int) -> Int {
        let count = max(1, itemCount)
        return max(1, Int(ceil(Double(count) / Double(max(1, columnCount)))))
    }

    private func _clusterRowStride(clusterHeight: CGFloat, maxItemHeight: CGFloat, rowCount: Int) -> CGFloat {
        guard rowCount > 1 else { return 0 }
        let usableHeight = max(0, clusterHeight - maxItemHeight - 28)
        return max(maxItemHeight + 10, usableHeight / CGFloat(rowCount - 1))
    }

    private func _rowStagger(row: Int, column: Int, columnCount: Int, cellWidth: CGFloat) -> CGPoint {
        guard columnCount > 1 else { return .zero }
        let horizontal = min(10, cellWidth * 0.11)
        let vertical: CGFloat = row.isMultiple(of: 2) ? 0 : 5
        let direction: CGFloat = (column + row).isMultiple(of: 2) ? 1 : -1
        return CGPoint(
            x: direction * horizontal,
            y: vertical
        )
    }

    private func _conceptAtomSize(for item: _ConceptItem, degree: Int, title: String) -> CGSize {
        let paperEvidence = Double(max(0, item.linkedPaperIDs.count))
        let relationEvidence = Double(max(0, degree + item.relationCount))
        let importanceEvidence = Double(max(0, item.importance))
        let evidenceScore = sqrt(paperEvidence * 1.8 + relationEvidence * 1.4 + importanceEvidence * 1.2)
        let achievementScale = 1.0 + item.achievementFraction * 0.36
        let titleLength = CGFloat(max(3, title.count))
        let evidence = CGFloat(evidenceScore * achievementScale)
        let width = min(300, max(182, titleLength * 9.4 + 54 + evidence * 2.6))
        let height = min(104, max(78, 70 + (titleLength > 14 ? 12 : 0) + evidence * 1.4))
        return CGSize(width: width, height: height)
    }

    private func _componentTint(_ index: Int) -> Color {
        let palette: [Color] = [.cyan, .mint, .indigo, .orange, .pink, .teal, .purple, .green]
        return palette[index % palette.count]
    }

    private func _conceptTint(_ item: _ConceptItem, fallback: Color? = nil) -> Color {
        let palette: [Color] = [.blue, .teal, .purple, .orange, .pink, .indigo, .cyan, .green, .red]
        let key = item.canonicalID ?? item.id
        if key.isEmpty {
            return fallback ?? .blue
        }
        let hash = key.unicodeScalars.reduce(0) { partial, scalar in
            (partial &* 31) &+ Int(scalar.value)
        }
        let index = ((hash % palette.count) + palette.count) % palette.count
        return palette[index]
    }

    private func _paperTint(_ paper: _PaperItem) -> Color {
        let palette: [Color] = [.blue, .teal, .purple, .orange, .pink, .indigo, .cyan, .green, .red]
        let key = [paper.provider, paper.id].filter { !$0.isEmpty }.joined(separator: "::")
        let hash = key.unicodeScalars.reduce(0) { partial, scalar in
            (partial &* 31) &+ Int(scalar.value)
        }
        let index = ((hash % palette.count) + palette.count) % palette.count
        return palette[index]
    }

    private func _paperColumns(for items: [_ConceptItem], selectedConcept: _ConceptItem?) -> _PaperColumns {
        let conceptIDsByPaperID = Dictionary(grouping: items.flatMap { item in
            item.linkedPaperIDs.map { paperID in (paperID: paperID, conceptID: item.id) }
        }, by: \.paperID)
            .mapValues { Set($0.map(\.conceptID)) }

        let allPapers = Inf6CorePaperStore.shared.papers
        let paperByID = Dictionary(uniqueKeysWithValues: allPapers.map { ($0.id, $0) })
        let linkedPaperIDs = Set(conceptIDsByPaperID.keys)
        let unresolvedIDCount = linkedPaperIDs.filter { paperByID[$0] == nil }.count

        let papers = allPapers.map { paper in
            return _PaperItem(
                id: paper.id,
                title: paper.title,
                titleEn: paper.titleEn,
                year: paper.year,
                provider: paper.provider,
                conceptCount: conceptIDsByPaperID[paper.id]?.count ?? 0
            )
        }
        .sorted { lhs, rhs in
            if lhs.year != rhs.year {
                return (lhs.year ?? 0) > (rhs.year ?? 0)
            }
            return _displayText(ja: lhs.title, en: lhs.titleEn ?? lhs.title)
                .localizedStandardCompare(_displayText(ja: rhs.title, en: rhs.titleEn ?? rhs.title)) == .orderedAscending
        }

        let selectedPaperIDs = Set(selectedConcept?.linkedPaperIDs ?? [])
        let linkedPapers = papers.filter { selectedPaperIDs.contains($0.id) }
        let tintByConceptID = Dictionary(uniqueKeysWithValues: items.map { item in
            (item.id, _conceptTint(item))
        })
        var corpusTintByPaperID: [String: Color] = [:]
        for item in items.sorted(by: { lhs, rhs in
            if lhs.importance != rhs.importance { return lhs.importance > rhs.importance }
            return lhs.sourceOrder < rhs.sourceOrder
        }) {
            let tint = tintByConceptID[item.id] ?? Color(uiColor: .label)
            for paperID in item.linkedPaperIDs where corpusTintByPaperID[paperID] == nil {
                corpusTintByPaperID[paperID] = tint
            }
        }
        let linkedTintByPaperID = Dictionary(uniqueKeysWithValues: linkedPapers.map {
            ($0.id, selectedConcept.map { _conceptTint($0) } ?? corpusTintByPaperID[$0.id] ?? Color(uiColor: .label))
        })

        return _PaperColumns(
            corpus: papers,
            linked: linkedPapers,
            corpusTintByPaperID: corpusTintByPaperID,
            linkedTintByPaperID: linkedTintByPaperID,
            unresolvedIDCount: unresolvedIDCount
        )
    }

    private func _selectedConcept(from items: [_ConceptItem]) -> _ConceptItem? {
        if let selectedID = _selectedConceptID,
           let item = items.first(where: { $0.id == selectedID }) {
            return item
        }
        return items.first
    }

    private func _linkedPaperColumnTitle(_ concept: _ConceptItem?) -> String {
        guard let concept else {
            return _displayText(ja: "関連論文", en: "Linked papers")
        }
        return _displayText(ja: concept.titleJa, en: concept.titleEn)
    }

    private func _sortedConceptItems(_ items: [_ConceptItem], graph: _VisibleRelationGraph) -> [_ConceptItem] {
        _sortForEvidence(items, graph: graph)
    }

    private struct _ConceptSetComponent: Identifiable {
        let id: String
        let items: [_ConceptItem]
    }

    private func _conceptSetGroups(items: [_ConceptItem], graph: _VisibleRelationGraph) -> [_ConceptSetComponent] {
        let components = _relationComponents(items: items, graph: graph)
        var normalized = components.map { component in
            _sortForEvidence(component, graph: graph)
        }
        .sorted { lhs, rhs in
            let leftRelations = lhs.reduce(0) { $0 + graph.degree($1.canonicalID) }
            let rightRelations = rhs.reduce(0) { $0 + graph.degree($1.canonicalID) }
            if leftRelations != rightRelations {
                return leftRelations > rightRelations
            }
            let leftImportance = lhs.reduce(0) { $0 + $1.importance }
            let rightImportance = rhs.reduce(0) { $0 + $1.importance }
            if leftImportance != rightImportance {
                return leftImportance > rightImportance
            }
            return (lhs.first?.sourceOrder ?? 0) < (rhs.first?.sourceOrder ?? 0)
        }

        let isolated = normalized.flatMap { component -> [_ConceptItem] in
            guard component.count == 1, graph.degree(component[0].canonicalID) == 0 else { return [] }
            return component
        }
        if isolated.count > 1 {
            normalized.removeAll { component in
                component.count == 1 && graph.degree(component[0].canonicalID) == 0
            }
            normalized.append(_sortForEvidence(isolated, graph: graph))
        }

        return normalized.enumerated().map { index, component in
            let groupID = component
                .map(\.id)
                .sorted()
                .joined(separator: "|")
            return _ConceptSetComponent(id: groupID.isEmpty ? "concept-set-\(index)" : groupID, items: component)
        }
    }

    private func _aggregateAchievement(_ states: [Inf6KnowledgeAchievementState]) -> Inf6KnowledgeAchievementState {
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

    private func _achievement(from metric: Inf6ConceptMetric?) -> Inf6KnowledgeAchievementState {
        guard let metric else { return .notStarted }
        if metric.achievementWeight >= 1.0 { return .measured }
        if metric.achievementWeight >= 0.88 { return .questioned }
        if metric.achievementWeight >= 0.72 { return .explained }
        if metric.achievementWeight >= 0.58 { return .annotating }
        if metric.achievementWeight >= 0.42 { return .reading }
        if metric.achievementWeight > 0 { return .collecting }
        return .notStarted
    }

    private func _achievementFraction(_ achievement: Inf6KnowledgeAchievementState) -> Double {
        switch achievement {
        case .notStarted:
            return 0.0
        case .collecting:
            return 0.16
        case .reading:
            return 0.42
        case .annotating:
            return 0.58
        case .explained:
            return 0.72
        case .questioned:
            return 0.88
        case .measured:
            return 1.0
        }
    }

    private func _canonicalKey(ja: String, en: String) -> String {
        let source = !ja.isEmpty ? ja : en
        return source
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func _firstNonEmpty(_ values: [String?]) -> String {
        for value in values {
            let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { return text }
        }
        return ""
    }

    private func _canonicalTail(_ canonicalID: String, preferJapanese: Bool) -> String? {
        let raw = canonicalID.hasPrefix("concept:")
            ? String(canonicalID.dropFirst("concept:".count))
            : canonicalID
        let text = raw
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        let containsJapanese = text.range(of: #"[ぁ-んァ-ヶ一-龥々]"#, options: .regularExpression) != nil
        if preferJapanese {
            return containsJapanese ? text : nil
        }
        return containsJapanese ? nil : text
    }
}

private struct _ConceptSetAtom: View {
    let title: String
    let tint: Color
    let achievementFraction: Double
    let isSelected: Bool
    let size: CGSize
    let action: () -> Void

    private var _clampedAchievement: CGFloat {
        CGFloat(min(1.0, max(0.0, achievementFraction)))
    }

    private var _fontSize: CGFloat {
        max(17, min(22, size.height * 0.27))
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Capsule()
                    .fill(tint.opacity(isSelected ? 0.22 : 0.07 + Double(_clampedAchievement) * 0.12))
                    .overlay(
                        Capsule()
                            .stroke(tint.opacity(isSelected ? 0.95 : 0.58), lineWidth: isSelected ? 2.4 : 1.4)
                    )

                if _clampedAchievement > 0 {
                    _AchievementWedge(fraction: Double(_clampedAchievement))
                        .fill(tint.opacity(0.22))
                        .clipShape(Capsule())
                        .padding(2)
                }

                Text(title)
                    .font(.system(size: _fontSize, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .label))
                    .lineLimit(3)
                    .minimumScaleFactor(0.84)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Capsule())
            .shadow(color: isSelected ? tint.opacity(0.25) : .clear, radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
    }
}

private struct _AchievementWedge: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let clamped = min(1.0, max(0.0, fraction))
        guard clamped > 0 else { return Path() }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = max(rect.width, rect.height)
        let start = Angle.degrees(-90)
        let end = Angle.degrees(-90 + 360 * clamped)

        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        path.closeSubpath()
        return path
    }
}

private struct _PaperListRow: View {
    let title: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tint)
                    .frame(width: 4)

                Text(title)
                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(15), weight: .semibold))
                    .foregroundStyle(tint)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
}
