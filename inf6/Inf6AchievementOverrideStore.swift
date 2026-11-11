//
//  Inf6AchievementOverrideStore.swift
//  inf6
//

import Foundation

public enum Inf6AchievementOverrideStore {
    private static func _fileURL() throws -> URL {
        let root = try Inf6LibraryView._sharedRootDir()
        let dir = root.appendingPathComponent("mma", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("achievement_overrides.json")
    }

    public static func load() throws -> [String: Inf6KnowledgeAchievementState] {
        let url = try _fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([String: Inf6KnowledgeAchievementState].self, from: data)
    }

    public static func set(_ state: Inf6KnowledgeAchievementState, forPaperID paperID: String) throws {
        let trimmed = paperID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "Inf6AchievementOverrideStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "paperID is empty; achievement cannot be saved."]
            )
        }
        var values = try load()
        values[trimmed] = state
        try save(values)
    }

    public static func save(_ values: [String: Inf6KnowledgeAchievementState]) throws {
        let url = try _fileURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(values)
        try data.write(to: url, options: .atomic)
    }
}
