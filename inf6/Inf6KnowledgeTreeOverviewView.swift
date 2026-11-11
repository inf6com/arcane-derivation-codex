//
//  Inf6KnowledgeTreeOverviewView.swift
//  inf6
//
//  トップ画面: 全知識領域を統合した一本のツリー。
//  ルートは「知」。その下に各ドメインがぶら下がる。
//  ドメインルートノードをタップすると詳細ツリーに遷移。
//

import Foundation
import SwiftUI
import UIKit

// MARK: - Overview

struct Inf6KnowledgeTreeOverviewView: View {

    @State private var _domains: [_DomainData] = []

    fileprivate struct _SubsetOverlap: Identifiable, Hashable {
        let id: String
        let leftDomainID: String
        let rightDomainID: String
        let leftTitle: String
        let rightTitle: String
        let sharedCount: Int
        let sampleTitles: [String]
    }

    fileprivate struct _DomainData: Identifiable {
        let id: String
        let manifest: Inf6LearningFamilyManifest
        var structure: Inf6KnowledgeDomainStructure
        let accentColor: Color
    }

    @State private var _isDesigning: Bool = false

    var body: some View {
        NavigationStack {
            Group {
                if _domains.isEmpty {
                    VStack(spacing: 18) {
                        if _isDesigning {
                            ProgressView().tint(.pink).scaleEffect(1.25)
                                .controlSize(.large)
                        }
                        _emptyState
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if _isDesigning {
                                HStack(spacing: 10) { ProgressView().tint(.pink).scaleEffect(1.25) }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(Color(uiColor: .secondarySystemBackground))
                                )
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                            }

                            _subsetRelationSurface
                                .padding(.horizontal, 16)
                                .padding(.bottom, 18)
                        }
                        .padding(.vertical, 12)
                    }
                    .background(Color(uiColor: .systemGroupedBackground))
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            if _domains.isEmpty {
                await _loadAndDesign()
            }
        }
    }

    private var _subsetRelationSurface: some View {
        return VStack(alignment: .leading, spacing: 20) {
            _Inf6FlowLayout(horizontalSpacing: 18, verticalSpacing: 18) {
                ForEach(_domains) { domain in
                    NavigationLink {
                        _domainDetailView(domain.id)
                    } label: {
                        _domainSurfaceCard(domain)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func _domainSurfaceCard(_ domain: _DomainData) -> some View {
        let progress = _fraction(for: domain)
        let rootNodeID = _domainRootNodeID(for: domain)

        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                _domainCoreGlyph(accent: domain.accentColor, progress: progress)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }

            if let rootNodeID {
                _Inf6SubsetSurfaceTreeView(
                    structure: domain.structure,
                    accentColor: domain.accentColor,
                    rootNodeID: rootNodeID,
                    parentNodeID: rootNodeID,
                    depth: 0,
                    maxDepth: 1
                )
            } else {
                _emptyState
                    .frame(minHeight: 120)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(domain.accentColor.opacity(0.18), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func _nodeTile(_ node: Inf6KnowledgeNode, accent: Color) -> some View {
        _Inf6SubsetGlyph(node: node, accent: accent)
    }

    private func _domainCoreGlyph(accent: Color, progress: Double) -> some View {
        let clamped = min(max(progress, 0), 1)
        return ZStack {
            Circle()
                .stroke(Color(uiColor: .systemGray5), lineWidth: 10)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle()
                .fill(accent.opacity(0.12))
                .padding(10)
            ForEach(0..<4, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(accent.opacity(0.78 - (Double(index) * 0.14)))
                    .frame(width: 8, height: 18)
                    .offset(y: -18)
                    .rotationEffect(.degrees(Double(index) * 90))
            }
        }
        .frame(width: 72, height: 72)
    }

    // MARK: - Empty

    private var _emptyState: some View {
        ZStack {
            Circle()
                .fill(Color(uiColor: .secondarySystemFill))
                .frame(width: 96, height: 96)

            ForEach(0..<6, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(Color.secondary.opacity(0.72 - (Double(index) * 0.08)))
                    .frame(width: 10, height: 28)
                    .offset(y: -20)
                    .rotationEffect(.degrees(Double(index) * 60))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Detail view

    @ViewBuilder
    private func _domainDetailView(_ domainID: String) -> some View {
        if let domain = _domains.first(where: { $0.id == domainID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    _syllabusIdentityHeader(for: domain)
                    _Inf6SubsetSurfaceTreeView(
                        structure: domain.structure,
                        accentColor: domain.accentColor,
                        rootNodeID: _domainRootNodeID(for: domain),
                        parentNodeID: _domainRootNodeID(for: domain),
                        depth: 0,
                        maxDepth: nil
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            EmptyView()
        }
    }

    private func _syllabusIdentityHeader(for domain: _DomainData) -> some View {
        let examName = _examName(for: domain.manifest) ?? domain.manifest.displayNameJa
        let schedule = _examName(for: domain.manifest).flatMap {
            Inf6SyllabusUpdateChecker.shared.examScheduleInfo(for: $0)
        }
        let revision = schedule?.applicableSyllabusVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let syllabusID = schedule?.applicableSyllabusId.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 5) {
            Text(Inf6Lang.text("対象シラバス", "Syllabus"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(examName)
                .font(.title3.weight(.bold))
            if let revision, !revision.isEmpty {
                Text(Inf6Lang.text("適用改訂: \(revision)", "Applicable revision: \(revision)"))
                    .font(.subheadline.weight(.semibold))
            } else {
                Text(Inf6Lang.text("適用改訂: 未取得", "Applicable revision: unavailable"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            if let syllabusID, !syllabusID.isEmpty {
                Text(Inf6Lang.text("シラバスID: \(syllabusID)", "Syllabus ID: \(syllabusID)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    private func _domainRootNodeID(for domain: _DomainData) -> String? {
        if let versionNode = domain.structure.nodes.first(where: { $0.kind == .syllabusVersion }) {
            return versionNode.nodeID
        }
        return domain.structure.nodes.first(where: { $0.kind == .domain })?.nodeID
    }

    private func _fraction(for domain: _DomainData) -> Double {
        let nodes = domain.structure.nodes.filter { $0.kind != .domain && $0.kind != .syllabusVersion }
        guard !nodes.isEmpty else { return 0 }
        let total = nodes.reduce(0.0) { $0 + _achievementScore($1.achievement) }
        return total / Double(nodes.count)
    }

    private func _achievementScore(_ state: Inf6KnowledgeAchievementState) -> Double {
        switch state {
        case .notStarted:
            return 0.0
        case .collecting:
            return 0.15
        case .reading:
            return 0.35
        case .annotating:
            return 0.55
        case .explained:
            return 0.72
        case .questioned:
            return 0.86
        case .measured:
            return 1.0
        }
    }

    private func _trimmed(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Load & Design

    private func _loadAndDesign() async {
        // 1. スケルトン生成（アウトラインキャッシュからロード）
        let outlineCache = _loadOutlineCache()
        let manifests = Inf6LearningFamilyManifestStore.loadAll()

        var loaded: [_DomainData] = manifests.compactMap { manifest in
            let paperStore: Inf6CorePaperStore? = Inf6CorePaperStore.shared
            let outlineItems = _findOutlineItems(for: manifest, cache: outlineCache)
            let syllabusVersionID = _resolvedKnowledgeStructureVersionID(for: manifest)
            guard let structure = try? Inf6KnowledgeDomainStructureStore.loadOrSeed(
                manifest: manifest,
                syllabusVersionID: syllabusVersionID,
                domainTitleJa: manifest.displayNameJa,
                outlineItems: outlineItems,
                paperStore: paperStore
            ) else { return nil }

            return _DomainData(
                id: manifest.familyID,
                manifest: manifest,
                structure: structure,
                accentColor: _parseHex(manifest.accentColorHex) ?? .blue
            )
        }

        _domains = loaded

        let needsDesign = loaded.indices.filter { loaded[$0].structure.edges.isEmpty && loaded[$0].structure.nodes.count > 3 }
        guard !needsDesign.isEmpty else { return }

        _isDesigning = true
        for idx in needsDesign {
            let designed = await Inf6KnowledgeDependencyDesigner.design(structure: loaded[idx].structure)
            loaded[idx].structure = designed
            try? Inf6KnowledgeDomainStructureStore.save(
                designed,
                manifest: loaded[idx].manifest,
                syllabusVersionID: loaded[idx].structure.syllabusVersionID
            )
        }
        _domains = loaded
        _isDesigning = false
    }

    // MARK: - Helpers

    private func _achievementColor(_ state: Inf6KnowledgeAchievementState, accent: Color) -> Color {
        switch state {
        case .measured, .questioned, .explained:
            return .green
        case .annotating, .reading, .collecting:
            return accent
        case .notStarted:
            return Color(uiColor: .systemGray4)
        }
    }

    private func _parseHex(_ hex: String) -> Color? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let val = UInt64(s, radix: 16) else { return nil }
        let r = Double((val >> 16) & 0xFF) / 255.0
        let g = Double((val >> 8) & 0xFF) / 255.0
        let b = Double(val & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    // MARK: - Outline cache → domain mapping

    private func _loadOutlineCache() -> [String: [Inf6SyllabusOutlineItem]] {
        guard let url = try? Inf6Storage.syllabusOutlineCacheURL() else { return [:] }
        return Inf6DiskJSON.load([String: [Inf6SyllabusOutlineItem]].self, from: url) ?? [:]
    }

    /// キャッシュキーからドメインに対応するアウトラインを探す。
    /// キーに jdla.org + "g" → G検定, "e" → E資格, microsoft → AI-102。
    /// 同一ドメインに複数エントリがある場合、最大項目数のものを採用。
    private func _findOutlineItems(
        for manifest: Inf6LearningFamilyManifest,
        cache: [String: [Inf6SyllabusOutlineItem]]
    ) -> [Inf6SyllabusOutlineItem] {
        let familyID = manifest.familyID

        let patterns: [String] = {
            switch familyID {
            case "g-kentei":
                return ["gkentei_outline", "g-syllabus", "g%e6%a4%9c%e5%ae%9a"]
            case "e-shikaku":
                return ["eshikaku_outline", "e-syllabus", "e%e8%b3%87%e6%a0%bc"]
            case "ai-102":
                return ["ai-102", "azure"]
            case "ai-103":
                return ["ai-103", "azure"]
            default:
                return []
            }
        }()

        guard !patterns.isEmpty else { return [] }

        var candidates: [[Inf6SyllabusOutlineItem]] = []
        for (key, items) in cache {
            let lowKey = key.lowercased()
            if patterns.contains(where: { lowKey.contains($0) }) {
                candidates.append(items)
            }
        }

        return candidates.max(by: { $0.count < $1.count }) ?? []
    }

    private func _resolvedKnowledgeStructureVersionID(for manifest: Inf6LearningFamilyManifest) -> String {
        if let examName = _examName(for: manifest),
           let info = Inf6SyllabusUpdateChecker.shared.examScheduleInfo(for: examName) {
            let versionID = info.preferredKnowledgeStructureID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !versionID.isEmpty {
                return versionID
            }
        }
        return ""
    }

    private func _examName(for manifest: Inf6LearningFamilyManifest) -> String? {
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
}

// MARK: - Domain detail tree

private struct _Inf6SubsetSurfaceTreeView: View {
    let structure: Inf6KnowledgeDomainStructure
    let accentColor: Color
    let rootNodeID: String?
    let parentNodeID: String?
    let depth: Int
    let maxDepth: Int?

    var body: some View {
        let childSubsets = _childSubsetNodes
        if childSubsets.isEmpty {
            EmptyView()
        } else {
            _content(childSubsets)
        }
    }

    private func _content(_ childSubsets: [Inf6KnowledgeNode]) -> some View {
        let relations = _relations(for: childSubsets)
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: depth == 0 ? 320 : 280, maximum: 520), spacing: 12, alignment: .top)],
            alignment: .leading,
            spacing: 12
        ) {
            ForEach(childSubsets) { node in
                _subsetCard(node)
                    .anchorPreference(
                        key: _Inf6SurfaceFramePreferenceKey.self,
                        value: .bounds
                    ) { [node.nodeID: $0] }
            }
        }
        .overlayPreferenceValue(_Inf6SurfaceFramePreferenceKey.self) { anchors in
            GeometryReader { proxy in
                Canvas { context, _ in
                    for relation in relations {
                        guard
                            let fromAnchor = anchors[relation.fromNodeID],
                            let toAnchor = anchors[relation.toNodeID]
                        else { continue }
                        let fromRect = proxy[fromAnchor]
                        let toRect = proxy[toAnchor]
                        let path = _relationPath(from: fromRect, to: toRect)
                        context.stroke(
                            path,
                            with: .color(_edgeColor(relation.kind).opacity(0.46)),
                            style: StrokeStyle(
                                lineWidth: relation.kind == .prereq ? 3.0 : 2.0,
                                lineCap: .round,
                                lineJoin: .round,
                                dash: relation.kind == .diff ? [7, 5] : []
                            )
                        )
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func _subsetCard(_ node: Inf6KnowledgeNode) -> some View {
        let children = _childSubsetNodes(of: node.nodeID)
        let papers = _papers(for: node.nodeID)
        let relationCount = _relationCount(for: node.nodeID, within: children)
        let fill = _achievementColor(node.achievement).opacity(0.10)
        let stroke = _achievementColor(node.achievement).opacity(0.46)
        let shapeSeed = abs(node.nodeID.hashValue)

        VStack(alignment: .leading, spacing: 12) {
            _subsetSignatureGlyph(
                node: node,
                childCount: children.count,
                paperCount: papers.count,
                relationCount: relationCount
            )

            if !papers.isEmpty {
                _Inf6FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(papers.prefix(depth == 0 ? 5 : 3), id: \.id) { paper in
                        _Inf6PaperGlyph(paper: paper, accent: accentColor)
                    }
                }
            }

            if !children.isEmpty {
                if maxDepth.map({ depth < $0 }) ?? true {
                    _Inf6SubsetSurfaceTreeView(
                        structure: structure,
                        accentColor: accentColor,
                        rootNodeID: rootNodeID,
                        parentNodeID: node.nodeID,
                        depth: depth + 1,
                        maxDepth: maxDepth
                    )
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            _Inf6OrganicBranchShape(seed: shapeSeed)
                .fill(fill)
        )
        .overlay(
            _Inf6OrganicBranchShape(seed: shapeSeed)
                .stroke(stroke, lineWidth: 1.1)
        )
    }

    private var _nodeMap: [String: Inf6KnowledgeNode] {
        Dictionary(uniqueKeysWithValues: structure.nodes.map { ($0.nodeID, $0) })
    }

    private var _childSubsetNodes: [Inf6KnowledgeNode] {
        _childSubsetNodes(of: parentNodeID)
    }

    private func _childSubsetNodes(of nodeID: String?) -> [Inf6KnowledgeNode] {
        guard let nodeID else { return [] }
        return structure.nodes
            .filter { $0.parentNodeID == nodeID && $0.kind != .paper }
            .sorted { lhs, rhs in
                if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
                return lhs.titleJa.localizedCompare(rhs.titleJa) == .orderedAscending
            }
    }

    private func _papers(for nodeID: String) -> [Inf6KnowledgePaperLink] {
        let descendants = Set(_collectDescendants(startingAt: nodeID))
        return structure.papers
            .filter { !Set($0.syllabusNodeIDs).isDisjoint(with: descendants) }
            .sorted { $0.paperTitle.localizedCompare($1.paperTitle) == .orderedAscending }
    }

    private func _relationCount(for nodeID: String, within children: [Inf6KnowledgeNode]) -> Int {
        let childIDs = Set(children.map(\.nodeID))
        let topAncestor = _topAncestorMap(childIDs: childIDs)
        var related: Set<String> = []
        for edge in structure.edges {
            guard
                let from = topAncestor[edge.fromNodeID],
                let to = topAncestor[edge.toNodeID],
                from != to
            else { continue }
            if from == nodeID { related.insert(to) }
            if to == nodeID { related.insert(from) }
        }
        return related.count
    }

    private func _relations(for childSubsets: [Inf6KnowledgeNode]) -> [_Inf6BranchRelation] {
        let childIDs = Set(childSubsets.map(\.nodeID))
        let topAncestor = _topAncestorMap(childIDs: childIDs)
        var seen: Set<String> = []
        var result: [_Inf6BranchRelation] = []

        for edge in structure.edges {
            guard
                let from = topAncestor[edge.fromNodeID],
                let to = topAncestor[edge.toNodeID],
                from != to
            else { continue }
            let key = "\(from)->\(to):\(edge.kind.rawValue)"
            guard seen.insert(key).inserted else { continue }
            result.append(.init(fromNodeID: from, toNodeID: to, kind: edge.kind))
        }

        return result
    }

    private func _collectDescendants(startingAt nodeID: String) -> [String] {
        let childMap = Dictionary(grouping: structure.nodes.compactMap { node -> (String, String)? in
            guard let parent = node.parentNodeID else { return nil }
            return (parent, node.nodeID)
        }) { $0.0 }
        .mapValues { $0.map(\.1) }

        var visited: Set<String> = [nodeID]
        var queue: [String] = [nodeID]

        while let current = queue.first {
            queue.removeFirst()
            for child in childMap[current] ?? [] where !visited.contains(child) {
                visited.insert(child)
                queue.append(child)
            }
        }
        return Array(visited)
    }

    private func _topAncestorMap(childIDs: Set<String>) -> [String: String] {
        var result: [String: String] = [:]
        for node in structure.nodes {
            var cursor: String? = node.nodeID
            var found: String?
            while let current = cursor {
                if childIDs.contains(current) {
                    found = current
                    break
                }
                cursor = _nodeMap[current]?.parentNodeID
            }
            if let found {
                result[node.nodeID] = found
            }
        }
        return result
    }

    private func _relationPath(from fromRect: CGRect, to toRect: CGRect) -> Path {
        let start = CGPoint(x: fromRect.midX, y: fromRect.maxY - 12)
        let end = CGPoint(x: toRect.midX, y: toRect.minY + 12)
        let midY = (start.y + end.y) / 2
        var path = Path()
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x, y: midY),
            control2: CGPoint(x: end.x, y: midY)
        )
        return path
    }

    private func _achievementColor(_ state: Inf6KnowledgeAchievementState) -> Color {
        switch state {
        case .measured, .questioned, .explained:
            return .green
        case .annotating, .reading, .collecting:
            return accentColor
        case .notStarted:
            return Color(uiColor: .systemGray4)
        }
    }

    private func _edgeColor(_ kind: Inf6KnowledgeEdgeKind) -> Color {
        switch kind {
        case .prereq:
            return .blue
        case .diff:
            return .purple
        case .order:
            return .orange
        case .boundary:
            return .mint
        case .failure:
            return .red
        case .renaming:
            return .teal
        case .confusable:
            return .pink
        case .practical:
            return .green
        }
    }

    private func _subsetSignatureGlyph(
        node: Inf6KnowledgeNode,
        childCount: Int,
        paperCount: Int,
        relationCount: Int
    ) -> some View {
        HStack(spacing: 10) {
            _metricBar(count: max(1, childCount), tint: accentColor)
            _metricBar(count: max(1, paperCount), tint: .orange)
            _metricBar(count: max(1, relationCount), tint: .mint)
            Capsule(style: .continuous)
                .fill(_achievementColor(node.achievement).opacity(0.84))
                .frame(width: CGFloat(26 + min(node.linkedPaperIDs.count, 6) * 12), height: 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func _metricBar(count: Int, tint: Color) -> some View {
        let units = max(1, min(count, 8))
        return HStack(spacing: 4) {
            ForEach(0..<units, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(tint.opacity(0.88 - (Double(index) * 0.07)))
                    .frame(width: 10, height: 18)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.10))
        )
    }
}

private struct _Inf6SurfaceFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct _Inf6BranchRelation: Hashable {
    let fromNodeID: String
    let toNodeID: String
    let kind: Inf6KnowledgeEdgeKind
}

private struct _Inf6PaperGlyph: View {
    let paper: Inf6KnowledgePaperLink
    let accent: Color

    private var seed: Int {
        abs((paper.paperID + "::" + paper.paperTitle).hashValue)
    }

    private var outerColor: Color {
        _palette[(seed / 3) % _palette.count]
    }

    private var innerColor: Color {
        _palette[(seed / 11) % _palette.count]
    }

    private var providerSymbol: String {
        let provider = paper.providerID.lowercased()
        if provider.contains("arxiv") { return "atom" }
        if provider.contains("pubmed") { return "cross.case.fill" }
        if provider.contains("microsoft") { return "doc.text.fill" }
        return "doc.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                _Inf6PaperBloomShape(seed: seed)
                    .fill(
                        LinearGradient(
                            colors: [outerColor.opacity(0.94), innerColor.opacity(0.84)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                _Inf6PaperBloomShape(seed: seed)
                    .stroke(_achievementColor.opacity(0.9), lineWidth: 2.4)

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 4) {
                            ForEach(0..<_petalCount, id: \.self) { index in
                                Circle()
                                    .fill(Color.white.opacity(0.88 - (Double(index) * 0.12)))
                                    .frame(width: 7, height: 7)
                            }
                        }

                        HStack(spacing: 4) {
                            ForEach(0..<max(_knowledgeDots, 1), id: \.self) { _ in
                                Capsule(style: .continuous)
                                    .fill(Color.white.opacity(0.94))
                                    .frame(width: 12, height: 4)
                            }
                        }
                    }

                    Spacer(minLength: 8)

                    Image(systemName: providerSymbol)
                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(15), weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.96))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(width: 92, height: 68)

            Text(paper.paperTitle)
                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(16), weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 180, alignment: .leading)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(paper.paperTitle))
    }

    private var _petalCount: Int {
        2 + (seed % 3)
    }

    private var _knowledgeDots: Int {
        min(max(paper.knowledgeCount, 0), 5)
    }

    private var _achievementColor: Color {
        switch paper.achievement {
        case .measured, .questioned, .explained:
            return .green
        case .annotating, .reading, .collecting:
            return accent
        case .notStarted:
            return Color(uiColor: .systemGray3)
        }
    }

    private var _palette: [Color] {
        [
            .orange, .pink, .mint, .blue, .purple, .teal, .indigo, .yellow
        ]
    }
}

private struct _Inf6SubsetGlyph: View {
    let node: Inf6KnowledgeNode
    let accent: Color

    private var seed: Int {
        abs(node.nodeID.hashValue)
    }

    private var fillA: Color {
        _palette[seed % _palette.count]
    }

    private var fillB: Color {
        _palette[(seed / 7) % _palette.count]
    }

    var body: some View {
        ZStack {
            _Inf6OrganicBranchShape(seed: seed)
                .fill(
                    LinearGradient(
                        colors: [fillA.opacity(0.82), fillB.opacity(0.66)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            _Inf6OrganicBranchShape(seed: seed)
                .stroke(_achievementColor.opacity(0.92), lineWidth: 2.1)

            VStack(spacing: 7) {
                HStack(spacing: 5) {
                    ForEach(0..<max(1, min(node.paperCount, 4)), id: \.self) { _ in
                        Circle()
                            .fill(Color.white.opacity(0.92))
                            .frame(width: 7, height: 7)
                    }
                }

                HStack(spacing: 4) {
                    ForEach(0..<max(1, min(node.depth + 1, 4)), id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(0.88))
                            .frame(width: 14, height: 5)
                    }
                }

                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.9))
                    .frame(width: CGFloat(22 + min(node.linkedPaperIDs.count, 4) * 10), height: 6)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
        }
        .frame(width: 96, height: 74)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(node.titleJa))
    }

    private var _achievementColor: Color {
        switch node.achievement {
        case .measured, .questioned, .explained:
            return .green
        case .annotating, .reading, .collecting:
            return accent
        case .notStarted:
            return Color(uiColor: .systemGray3)
        }
    }

    private var _palette: [Color] {
        [.mint, .teal, .blue, .indigo, .purple, .pink, .orange, .yellow]
    }
}

private struct _Inf6PaperBloomShape: Shape {
    let seed: Int

    func path(in rect: CGRect) -> Path {
        let wobbleA = CGFloat((seed % 9) + 4)
        let wobbleB = CGFloat(((seed / 11) % 9) + 4)
        let wobbleC = CGFloat(((seed / 23) % 9) + 4)
        let inset: CGFloat = 2
        let r = rect.insetBy(dx: inset, dy: inset)

        var path = Path()
        path.move(to: CGPoint(x: r.minX + 18, y: r.minY + wobbleA))
        path.addQuadCurve(
            to: CGPoint(x: r.maxX - 18, y: r.minY + wobbleB),
            control: CGPoint(x: r.midX, y: r.minY - 10)
        )
        path.addQuadCurve(
            to: CGPoint(x: r.maxX - wobbleC, y: r.midY),
            control: CGPoint(x: r.maxX + 10, y: r.minY + 18)
        )
        path.addQuadCurve(
            to: CGPoint(x: r.maxX - 16, y: r.maxY - wobbleA),
            control: CGPoint(x: r.maxX + 4, y: r.maxY - 14)
        )
        path.addQuadCurve(
            to: CGPoint(x: r.minX + 16, y: r.maxY - wobbleB),
            control: CGPoint(x: r.midX, y: r.maxY + 10)
        )
        path.addQuadCurve(
            to: CGPoint(x: r.minX + wobbleC, y: r.midY),
            control: CGPoint(x: r.minX - 10, y: r.maxY - 18)
        )
        path.addQuadCurve(
            to: CGPoint(x: r.minX + 18, y: r.minY + wobbleA),
            control: CGPoint(x: r.minX - 4, y: r.minY + 14)
        )
        path.closeSubpath()
        return path
    }
}

private struct _Inf6OrganicBranchShape: Shape {
    let seed: Int

    func path(in rect: CGRect) -> Path {
        let tl = CGFloat(26 + (seed % 18))
        let tr = CGFloat(34 + ((seed / 7) % 18))
        let br = CGFloat(30 + ((seed / 13) % 20))
        let bl = CGFloat(22 + ((seed / 17) % 16))

        let inset = min(rect.width, rect.height) * 0.03
        let r = rect.insetBy(dx: inset, dy: inset)

        var path = Path()
        path.move(to: CGPoint(x: r.minX + tl, y: r.minY))
        path.addQuadCurve(
            to: CGPoint(x: r.maxX, y: r.minY + tr),
            control: CGPoint(x: r.midX, y: r.minY - 10)
        )
        path.addQuadCurve(
            to: CGPoint(x: r.maxX - br, y: r.maxY),
            control: CGPoint(x: r.maxX + 10, y: r.midY)
        )
        path.addQuadCurve(
            to: CGPoint(x: r.minX, y: r.maxY - bl),
            control: CGPoint(x: r.midX, y: r.maxY + 12)
        )
        path.addQuadCurve(
            to: CGPoint(x: r.minX + tl, y: r.minY),
            control: CGPoint(x: r.minX - 10, y: r.midY)
        )
        path.closeSubpath()
        return path
    }
}

private struct _Inf6FlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    init(horizontalSpacing: CGFloat = 8, verticalSpacing: CGFloat = 8) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? 800
        let frames = _frames(in: width, subviews: subviews)
        let height = frames.map { $0.maxY }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let frames = _frames(in: bounds.width, subviews: subviews)
        for (index, frame) in frames.enumerated() {
            guard index < subviews.count else { break }
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func _frames(in width: CGFloat, subviews: Subviews) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let itemWidth = min(size.width, width)
            if x > 0, x + itemWidth > width {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }

            let frame = CGRect(x: x, y: y, width: itemWidth, height: size.height)
            frames.append(frame)
            x += itemWidth + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }

        return frames
    }
}
