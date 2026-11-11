//
//  Inf6KnowledgeLiveContext.swift
//  inf6
//
//  ContextModeDesign フェーズ: GPT が知識領域ノードごとに context_mode と
//  live_context を設計する。
//
//  LiveContextRenderer: live ノードの web_search_preview 結果をキャッシュして
//  ビューに供給する。
//

import Foundation
import SwiftUI

// MARK: - ContextModeDesign

/// 1 ノードぶんの設計結果（GPT レスポンス JSON で使う）。
private struct _NodeDesign: Codable {
    let node_id: String
    let context_mode: String          // "static" | "live" | "hybrid"
    let query_ja: String?
    let query_en: String?
    let focus_ja: String?
    let focus_en: String?
}

private struct _DesignResponse: Codable {
    let nodes: [_NodeDesign]
}

/// GPT に知識領域の全ノードを渡し、各ノードの `context_mode` と
/// `live_context` を設計させる。
///
/// - Returns: `context_mode` / `liveContext` が更新された
///   `Inf6KnowledgeDomainStructure`。失敗時は元の構造をそのまま返す。
public enum Inf6KnowledgeContextModeDesigner {

    public static func design(
        structure: Inf6KnowledgeDomainStructure
    ) async -> Inf6KnowledgeDomainStructure {
        do {
            return try await _run(structure: structure)
        } catch {
            return structure
        }
    }

    private static func _run(
        structure: Inf6KnowledgeDomainStructure
    ) async throws -> Inf6KnowledgeDomainStructure {

        // paper ノードは設計不要（常に static）
        let targets = structure.nodes.filter { $0.kind != .paper }
        guard !targets.isEmpty else { return structure }

        let nodeList = targets.map { n in
            "- node_id: \(n.nodeID)\n  kind: \(n.kind.rawValue)\n  title_ja: \(n.titleJa)\n  summary_ja: \(n.summaryJa.prefix(80))"
        }.joined(separator: "\n")

        let system = """
あなたは AI 教育システムの知識構造設計者です。
以下の知識領域ノードリストを見て、各ノードが「静的コンテンツのみ（static）」「リアルタイム LLM 検索が必要（live）」「両方（hybrid）」のどれかを判断してください。

判断基準:
- static: 定義・理論・歴史的事実のように変化しないもの。
- live: 最新論文動向・試験出題傾向・規制・ベンチマーク結果など、時事性・速報性が高いもの。
- hybrid: 定義は固定だが、最新動向も参照したいもの。

live または hybrid のノードには query_ja / query_en / focus_ja / focus_en も設計してください。
query は web 検索クエリ文字列、focus はその検索結果から何を要約すべきかの指示文です。

回答は必ず以下の JSON 形式のみで返してください。Markdown や説明文は不要です。
{
  "nodes": [
    {
      "node_id": "<node_id>",
      "context_mode": "static" | "live" | "hybrid",
      "query_ja": "<検索クエリ（live/hybrid のみ）>",
      "query_en": "<search query (live/hybrid only)>",
      "focus_ja": "<要約指示（live/hybrid のみ）>",
      "focus_en": "<summary instruction (live/hybrid only)>"
    }
  ]
}
"""
        let user = """
ドメイン: \(structure.domainID)  シラバス版: \(structure.syllabusVersionID)

ノード一覧:
\(nodeList)
"""

        let raw = try await Inf6OpenAIWebSearch.ask(system: system, user: user)

        // JSON を抽出（```json ... ``` も対応）
        let jsonStr: String
        if let r = raw.range(of: "\\{[\\s\\S]*\\}", options: .regularExpression) {
            jsonStr = String(raw[r])
        } else {
            jsonStr = raw
        }

        guard let data = jsonStr.data(using: .utf8),
              let response = try? JSONDecoder().decode(_DesignResponse.self, from: data) else {
            throw NSError(domain: "Inf6KnowledgeContextModeDesigner", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "GPT レスポンスの JSON パースに失敗しました。"])
        }

        let designByNodeID = Dictionary(uniqueKeysWithValues: response.nodes.map { ($0.node_id, $0) })

        let updatedNodes: [Inf6KnowledgeNode] = structure.nodes.map { node in
            guard let d = designByNodeID[node.nodeID],
                  let mode = Inf6KnowledgeContextMode(rawValue: d.context_mode) else {
                return node
            }
            var copy = node
            copy.contextMode = mode
            if mode == .live || mode == .hybrid,
               let qja = d.query_ja, let qen = d.query_en,
               let fja = d.focus_ja, let fen = d.focus_en {
                copy.liveContext = Inf6KnowledgeLiveContextSpec(
                    queryJa: qja,
                    queryEn: qen,
                    focusJa: fja,
                    focusEn: fen
                )
            }
            return copy
        }

        return Inf6KnowledgeDomainStructure(
            domainID: structure.domainID,
            syllabusVersionID: structure.syllabusVersionID,
            nodes: updatedNodes,
            papers: structure.papers,
            edges: structure.edges
        )
    }
}

// MARK: - DependencyDesign

/// GPT にシラバスノード一覧を渡し、ノード間の依存関係（prereq エッジ）を設計させる。
/// シラバスの列挙をツリー化する — これが知の構造化である。
public enum Inf6KnowledgeDependencyDesigner {

    public static func design(
        structure: Inf6KnowledgeDomainStructure
    ) async -> Inf6KnowledgeDomainStructure {
        do {
            return try await _run(structure: structure)
        } catch {
            return structure
        }
    }

    private struct _EdgeDesign: Codable {
        let from_node_id: String
        let to_node_id: String
        let kind: String       // "prereq" | "diff" | "order" | "boundary" | ...
        let reason_ja: String?
        let reason_en: String?
    }

    private struct _DependencyResponse: Codable {
        let edges: [_EdgeDesign]
    }

    private static func _run(
        structure: Inf6KnowledgeDomainStructure
    ) async throws -> Inf6KnowledgeDomainStructure {

        // domain / syllabus_version は構造ノードなので依存分析対象外
        let targets = structure.nodes.filter {
            $0.kind != .domain && $0.kind != .syllabusVersion
        }
        guard targets.count >= 2 else { return structure }

        let nodeList = targets.map { n in
            "- node_id: \(n.nodeID)\n  kind: \(n.kind.rawValue)\n  depth: \(n.depth)\n  title_ja: \(n.titleJa)\n  summary_ja: \(n.summaryJa.prefix(120))"
        }.joined(separator: "\n")

        let edgeKinds = Inf6KnowledgeEdgeKind.allCases.map { k in
            "  - \(k.rawValue)"
        }.joined(separator: "\n")

        let system = """
あなたは知識構造設計者です。
以下のシラバスノード一覧を分析し、ノード間の依存関係を設計してください。

目的: シラバスの列挙を「知の構造化」としてツリー化する。
ツリーとは、あるノードを理解するにはどのノードを先に理解しなければならないかを示す依存グラフです。

使用可能なエッジ種別:
\(edgeKinds)

設計ルール:
1. prereq が最重要。A を理解しないと B が理解できないとき、A → B の prereq エッジを張る。
2. 同一 depth 内でも、異なる depth 間でも、依存があればエッジを張る。
3. 循環依存は禁止。prereq エッジは必ず DAG（有向非巡回グラフ）を形成すること。
4. diff, boundary, confusable 等のエッジも、学習順序に影響するものは張る。
5. 根拠 (reason_ja / reason_en) を必ず記載する。

回答は必ず以下の JSON 形式のみで返してください。Markdown や説明文は不要です。
{
  "edges": [
    {
      "from_node_id": "<前提ノード>",
      "to_node_id": "<依存ノード>",
      "kind": "<エッジ種別>",
      "reason_ja": "<根拠>",
      "reason_en": "<reason>"
    }
  ]
}
"""
        let user = """
ドメイン: \(structure.domainID)  シラバス版: \(structure.syllabusVersionID)

ノード一覧 (\(targets.count) 件):
\(nodeList)
"""

        let raw = try await Inf6OpenAIWebSearch.ask(system: system, user: user)

        // JSON を抽出（```json ... ``` も対応）
        let jsonStr: String
        if let r = raw.range(of: "\\{[\\s\\S]*\\}", options: .regularExpression) {
            jsonStr = String(raw[r])
        } else {
            jsonStr = raw
        }

        guard let data = jsonStr.data(using: .utf8),
              let response = try? JSONDecoder().decode(_DependencyResponse.self, from: data) else {
            throw NSError(domain: "Inf6KnowledgeDependencyDesigner", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "GPT レスポンスの JSON パースに失敗しました。"])
        }

        // バリデーション: 存在しない node_id のエッジは捨てる
        let validIDs = Set(structure.nodes.map(\.nodeID))
        let validEdges: [Inf6KnowledgeNodeEdge] = response.edges.compactMap { e in
            guard validIDs.contains(e.from_node_id),
                  validIDs.contains(e.to_node_id),
                  let kind = Inf6KnowledgeEdgeKind(rawValue: e.kind) else {
                return nil
            }
            return Inf6KnowledgeNodeEdge(
                fromNodeID: e.from_node_id,
                toNodeID: e.to_node_id,
                kind: kind,
                reasonJa: e.reason_ja,
                reasonEn: e.reason_en
            )
        }

        // 循環検出: prereq エッジのみで DAG チェック
        let prereqs = validEdges.filter { $0.kind == .prereq }
        let dagEdges = _removeBackEdges(prereqs, allNodeIDs: validIDs)
        let nonPrereqs = validEdges.filter { $0.kind != .prereq }

        return Inf6KnowledgeDomainStructure(
            domainID: structure.domainID,
            syllabusVersionID: structure.syllabusVersionID,
            nodes: structure.nodes,
            papers: structure.papers,
            edges: dagEdges + nonPrereqs
        )
    }

    /// Kahn のアルゴリズムで循環を検出し、循環に含まれるエッジを除去する。
    private static func _removeBackEdges(
        _ edges: [Inf6KnowledgeNodeEdge],
        allNodeIDs: Set<String>
    ) -> [Inf6KnowledgeNodeEdge] {
        var inDegree: [String: Int] = [:]
        var adj: [String: [Int]] = [:]
        for id in allNodeIDs {
            inDegree[id] = 0
            adj[id] = []
        }
        for (i, e) in edges.enumerated() {
            inDegree[e.toNodeID, default: 0] += 1
            adj[e.fromNodeID, default: []].append(i)
        }

        var queue = Array(allNodeIDs.filter { inDegree[$0, default: 0] == 0 })
        var visited = Set<String>()
        var usedEdgeIndices = Set<Int>()

        while !queue.isEmpty {
            let node = queue.removeFirst()
            visited.insert(node)
            for idx in adj[node, default: []] {
                let e = edges[idx]
                usedEdgeIndices.insert(idx)
                inDegree[e.toNodeID, default: 1] -= 1
                if inDegree[e.toNodeID, default: 0] == 0 {
                    queue.append(e.toNodeID)
                }
            }
        }

        return usedEdgeIndices.sorted().map { edges[$0] }
    }
}

// MARK: - LiveContext result

public struct Inf6LiveContextResult: Identifiable {
    public var id: String { nodeID }
    public var nodeID: String
    public var text: String
    public var fetchedAt: Date
}

// MARK: - LiveContextRenderer

/// live / hybrid ノードの LLM 検索結果を管理する @Observable ストア。
///
/// ビューから `request(node:)` を呼ぶと非同期でフェッチし、
/// 結果が来たら `results[nodeID]` に格納される。
/// 7 日間のインメモリキャッシュを持つ（ディスクには保存しない）。
@Observable
public final class Inf6KnowledgeLiveContextRenderer {

    public static let shared = Inf6KnowledgeLiveContextRenderer()

    /// nodeID → 結果テキスト
    public private(set) var results: [String: Inf6LiveContextResult] = [:]

    /// フェッチ中の nodeID セット
    public private(set) var loading: Set<String> = []

    /// エラー nodeID → メッセージ
    public private(set) var errors: [String: String] = [:]

    private let cacheTTL: TimeInterval = 7 * 24 * 3600

    private init() {}

    /// ノードが live / hybrid なら結果をリクエストする（キャッシュ有効なら再フェッチしない）。
    public func request(node: Inf6KnowledgeNode) {
        guard node.contextMode == .live || node.contextMode == .hybrid else { return }
        guard let spec = node.liveContext else { return }
        let nodeID = node.nodeID

        // キャッシュ確認
        if let cached = results[nodeID],
           Date().timeIntervalSince(cached.fetchedAt) < cacheTTL {
            return
        }
        guard !loading.contains(nodeID) else { return }

        loading.insert(nodeID)
        errors.removeValue(forKey: nodeID)

        Task {
            do {
                let text = try await _fetch(spec: spec)
                await MainActor.run {
                    self.results[nodeID] = Inf6LiveContextResult(
                        nodeID: nodeID,
                        text: text,
                        fetchedAt: Date()
                    )
                    self.loading.remove(nodeID)
                }
            } catch {
                await MainActor.run {
                    self.errors[nodeID] = error.localizedDescription
                    self.loading.remove(nodeID)
                }
            }
        }
    }

    /// キャッシュを無効にして強制再フェッチ。
    public func refresh(node: Inf6KnowledgeNode) {
        results.removeValue(forKey: node.nodeID)
        errors.removeValue(forKey: node.nodeID)
        request(node: node)
    }

    private func _fetch(spec: Inf6KnowledgeLiveContextSpec) async throws -> String {
        let system = """
あなたは AI・機械学習の最新動向を把握している専門家アシスタントです。
web_search_preview ツールを使って最新情報を調べ、指示に従って自由文で要約してください。
200文字程度で簡潔に、事実・数字・重要な変化点を中心に書いてください。Markdown 不要、本文のみ。
"""
        let user = "\(spec.queryJa)\n\n指示: \(spec.focusJa)"
        return try await Inf6OpenAIWebSearch.ask(system: system, user: user)
    }
}

// MARK: - SwiftUI helper

/// live / hybrid ノードのリアルタイムコンテンツをインライン表示する View。
/// `.static` ノードには何も表示しない。
public struct Inf6LiveContextView: View {
    public let node: Inf6KnowledgeNode
    @State private var renderer = Inf6KnowledgeLiveContextRenderer.shared

    public init(node: Inf6KnowledgeNode) {
        self.node = node
    }

    public var body: some View {
        let nodeID = node.nodeID
        let isLive = node.contextMode == .live || node.contextMode == .hybrid

        if !isLive || node.liveContext == nil {
            EmptyView()
        } else if renderer.loading.contains(nodeID) {
            HStack(spacing: 8) {
                ProgressView().tint(.pink).scaleEffect(1.25)
                Text(Inf6Lang.text("最新情報を取得中…", "Fetching latest info…"))
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
            }
            .padding(.vertical, 6)
        } else if let result = renderer.results[nodeID] {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(Color.blue)
                    Text(Inf6Lang.text("ライブ情報", "Live"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.blue)
                    Spacer()
                    Button {
                        renderer.refresh(node: node)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Text(result.text)
                    .font(.body)
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        } else if let err = renderer.errors[nodeID] {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                Text(err)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                Spacer()
                Button {
                    renderer.refresh(node: node)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
        } else {
            EmptyView()
                .onAppear { renderer.request(node: node) }
        }
    }
}
