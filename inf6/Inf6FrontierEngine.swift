import Foundation
import UserNotifications

// MARK: - Knowledge Frontier Engine
// 論文リンクの変化を検出し、概要解説の再確認が必要なノードを記録する。

enum Inf6FrontierEngine {

    // MARK: - Full Frontier Sync

    static func syncNow() async -> Inf6FrontierSyncReport {
        NSLog("[inf6-frontier] sync started")
        let startedAt = Date()

        let previousPaperCounts = _currentPaperCounts()

        let worldSyncSuccess = await Inf6KnowledgeWorldSync.shared.syncNow(trigger: .dailyBackground)
        guard worldSyncSuccess else {
            NSLog("[inf6-frontier] world sync failed, aborting")
            return Inf6FrontierSyncReport(startedAt: startedAt, completedAt: Date(), newPapers: 0, updatedExplanations: 0, changes: [])
        }

        let newPaperCounts = _currentPaperCounts()
        var totalNewPapers = 0
        var changedNodes: [(sourceFamily: String, nodeID: String)] = []

        for (key, newCount) in newPaperCounts {
            let oldCount = previousPaperCounts[key] ?? 0
            if newCount > oldCount {
                totalNewPapers += (newCount - oldCount)
                let parts = key.split(separator: "|", maxSplits: 1)
                if parts.count == 2 {
                    changedNodes.append((sourceFamily: String(parts[0]), nodeID: String(parts[1])))
                }
            }
        }

        let updatedExplanations = 0
        var changes: [Inf6FrontierChange] = []

        if totalNewPapers > 0 {
            let lastSyncAt = Date().timeIntervalSince1970
            Inf6MetadataStore.put(domain: .settings, key: "syllabus_paper_auto_search_at", json: String(lastSyncAt))

            for node in changedNodes {
                let rawID = "inf6-explanation:\(node.sourceFamily):\(node.nodeID)"

                let previousSections = _loadExplanationSections(rawID: rawID)

                if let json = Inf6MetadataStore.get(domain: .generatedExplanations, key: rawID) {
                    Inf6MetadataStore.put(domain: .settings, key: "frontier_prev_explanation:\(rawID)", json: json)
                }

                Inf6MetadataStore.put(domain: .settings, key: "frontier_needs_regen:\(rawID)", json: "true")

                let nodeTitle = _nodeTitle(sourceFamily: node.sourceFamily, nodeID: node.nodeID)
                changes.append(Inf6FrontierChange(
                    rawID: rawID,
                    nodeTitle: nodeTitle,
                    sourceFamily: node.sourceFamily,
                    nodeID: node.nodeID,
                    previousSectionCount: previousSections,
                    kind: .newPapersAdded
                ))
            }
        }

        let report = Inf6FrontierSyncReport(
            startedAt: startedAt,
            completedAt: Date(),
            newPapers: totalNewPapers,
            updatedExplanations: updatedExplanations,
            changes: changes
        )

        _saveReport(report)

        if totalNewPapers > 0 {
            _sendNotification(report: report)
        }

        NSLog("[inf6-frontier] sync completed: %d new papers, %d explanations to update", totalNewPapers, updatedExplanations)
        return report
    }

    // MARK: - Diff Detection

    static func explanationDiff(rawID: String) -> Inf6ExplanationDiff? {
        let prevKey = "frontier_prev_explanation:\(rawID)"
        guard let prevJSON = Inf6MetadataStore.get(domain: .settings, key: prevKey),
              let currJSON = Inf6MetadataStore.get(domain: .generatedExplanations, key: rawID) else { return nil }

        let prevSections = _parseSectionHeadings(prevJSON)
        let currSections = _parseSectionHeadings(currJSON)

        let prevSet = Set(prevSections)
        let currSet = Set(currSections)

        let added = currSet.subtracting(prevSet)
        let removed = prevSet.subtracting(currSet)

        let prevGeneratedAt = _parseGeneratedAt(prevJSON)
        let currGeneratedAt = _parseGeneratedAt(currJSON)

        guard !added.isEmpty || !removed.isEmpty || prevSections.count != currSections.count else { return nil }

        return Inf6ExplanationDiff(
            rawID: rawID,
            previousGeneratedAt: prevGeneratedAt,
            currentGeneratedAt: currGeneratedAt,
            addedSections: Array(added).sorted(),
            removedSections: Array(removed).sorted(),
            previousSectionCount: prevSections.count,
            currentSectionCount: currSections.count
        )
    }

    static func needsRegeneration(rawID: String) -> Bool {
        Inf6MetadataStore.get(domain: .settings, key: "frontier_needs_regen:\(rawID)") == "true"
    }

    static func clearRegenerationFlag(rawID: String) {
        Inf6MetadataStore.put(domain: .settings, key: "frontier_needs_regen:\(rawID)", json: "false")
    }

    // MARK: - Achievement

    static func recalculateAchievement(sourceFamily: String) -> Inf6FrontierAchievement {
        var totalNodes = 0
        var coveredNodes = 0
        var nodeAchievements: [String: Double] = [:]

        for item in Inf6MetadataStore.listByPrefix(domain: .syllabus, prefix: "structure:\(sourceFamily)#") {
            guard let data = item.json.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let nodes = root["nodes"] as? [[String: Any]] else { continue }
            for node in nodes {
                guard let kind = node["kind"] as? String, kind != "paper" else { continue }
                guard let nodeID = node["node_id"] as? String else { continue }
                totalNodes += 1

                let rawID = "inf6-explanation:\(sourceFamily):\(nodeID)"
                let hasExplanation = Inf6MetadataStore.get(domain: .generatedExplanations, key: rawID) != nil
                let paperCount = Inf6SyllabusPaperAutoSearch.linkedPaperIDs(sourceFamily: sourceFamily, syllabusNodeID: nodeID).count
                let hasPapers = paperCount > 0

                var score = 0.0
                if hasExplanation { score += 0.5 }
                if hasPapers { score += 0.3 }
                if hasExplanation && !needsRegeneration(rawID: rawID) { score += 0.2 }

                nodeAchievements[nodeID] = score
                if score > 0 { coveredNodes += 1 }
            }
        }

        let overall = totalNodes > 0 ? Double(coveredNodes) / Double(totalNodes) : 0.0

        let staleCount = nodeAchievements.filter { key, _ in
            let rawID = "inf6-explanation:\(sourceFamily):\(key)"
            return needsRegeneration(rawID: rawID)
        }.count

        return Inf6FrontierAchievement(
            sourceFamily: sourceFamily,
            totalNodes: totalNodes,
            coveredNodes: coveredNodes,
            overallScore: overall,
            staleNodes: staleCount,
            nodeScores: nodeAchievements
        )
    }

    // MARK: - Private

    private static func _currentPaperCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        let families = ["jdla_eshikaku", "jdla_gkentei", "microsoft_ai_103", "microsoft_ai_102"]
        for sf in families {
            for item in Inf6MetadataStore.listByPrefix(domain: .syllabusPaperLinks, prefix: "\(sf)|") {
                let parts = item.key.split(separator: "|")
                if parts.count >= 2 {
                    let nodeKey = "\(sf)|\(parts[1])"
                    counts[nodeKey, default: 0] += 1
                }
            }
        }
        return counts
    }

    private static func _nodeTitle(sourceFamily: String, nodeID: String) -> String {
        for item in Inf6MetadataStore.listByPrefix(domain: .syllabus, prefix: "structure:\(sourceFamily)#") {
            guard let data = item.json.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let nodes = root["nodes"] as? [[String: Any]] else { continue }
            for node in nodes {
                if (node["node_id"] as? String) == nodeID {
                    return (node["title"] as? String) ?? nodeID
                }
            }
        }
        return nodeID
    }

    private static func _loadExplanationSections(rawID: String) -> Int {
        guard let json = Inf6MetadataStore.get(domain: .generatedExplanations, key: rawID),
              let data = json.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = payload["content"] as? [String: Any],
              let sections = content["sections"] as? [[String: Any]] else { return 0 }
        return sections.count
    }

    private static func _parseSectionHeadings(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = payload["content"] as? [String: Any],
              let sections = content["sections"] as? [[String: Any]] else { return [] }
        return sections.compactMap { $0["heading"] as? String }
    }

    private static func _parseGeneratedAt(_ json: String) -> Date? {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ts = payload["generatedAt"] as? Double else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    private static func _saveReport(_ report: Inf6FrontierSyncReport) {
        if let data = try? JSONEncoder().encode(report),
           let json = String(data: data, encoding: .utf8) {
            Inf6MetadataStore.put(domain: .settings, key: "frontier_last_report", json: json)
        }
    }

    static func lastReport() -> Inf6FrontierSyncReport? {
        guard let json = Inf6MetadataStore.get(domain: .settings, key: "frontier_last_report"),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Inf6FrontierSyncReport.self, from: data)
    }

    // MARK: - Notifications

    private static func _requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            NSLog("[inf6-frontier] notification permission: %@", granted ? "granted" : "denied")
        }
    }

    private static func _sendNotification(report: Inf6FrontierSyncReport) {
        let content = UNMutableNotificationContent()
        content.title = "知のフロンティアが更新されました"
        content.body = "\(report.newPapers)件の新論文を検出。\(report.updatedExplanations)件の概要解説が更新対象です。"
        content.sound = .default
        content.badge = NSNumber(value: report.updatedExplanations)

        let request = UNNotificationRequest(
            identifier: "frontier-sync-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

}

// MARK: - Models

struct Inf6FrontierSyncReport: Codable {
    let startedAt: Date
    let completedAt: Date
    let newPapers: Int
    let updatedExplanations: Int
    let changes: [Inf6FrontierChange]
}

struct Inf6FrontierChange: Codable {
    let rawID: String
    let nodeTitle: String
    let sourceFamily: String
    let nodeID: String
    let previousSectionCount: Int
    let kind: Kind

    enum Kind: String, Codable {
        case newPapersAdded
        case explanationRegenerated
    }
}

struct Inf6ExplanationDiff {
    let rawID: String
    let previousGeneratedAt: Date?
    let currentGeneratedAt: Date?
    let addedSections: [String]
    let removedSections: [String]
    let previousSectionCount: Int
    let currentSectionCount: Int

    var summary: String {
        var parts: [String] = []
        if !addedSections.isEmpty {
            parts.append("追加: \(addedSections.joined(separator: ", "))")
        }
        if !removedSections.isEmpty {
            parts.append("削除: \(removedSections.joined(separator: ", "))")
        }
        if previousSectionCount != currentSectionCount {
            parts.append("セクション数: \(previousSectionCount) → \(currentSectionCount)")
        }
        return parts.isEmpty ? "内容が更新されました" : parts.joined(separator: " / ")
    }
}

struct Inf6FrontierAchievement {
    let sourceFamily: String
    let totalNodes: Int
    let coveredNodes: Int
    let overallScore: Double
    let staleNodes: Int
    let nodeScores: [String: Double]

    var percentText: String {
        "\(Int(overallScore * 100))%"
    }

    var frontierGapText: String {
        let gap = totalNodes - coveredNodes
        if gap == 0 && staleNodes == 0 { return "最新" }
        var parts: [String] = []
        if gap > 0 { parts.append("未解説 \(gap)件") }
        if staleNodes > 0 { parts.append("要更新 \(staleNodes)件") }
        return parts.joined(separator: " / ")
    }
}
