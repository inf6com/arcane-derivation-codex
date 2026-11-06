import Foundation

public struct LearningExercise: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var cropReferences: [UUID]

    public init(id: UUID = UUID(), title: String, cropReferences: [UUID] = []) {
        self.id = id
        self.title = title
        self.cropReferences = cropReferences
    }
}

public struct LearningExerciseRepository {
    private let root: WorkspaceStore

    public init(root: WorkspaceStore) {
        self.root = root
    }

    public func all() throws -> [LearningExercise] {
        let directory = root.root.appendingPathComponent("learning/exercises", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let candidates = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        var urls: [URL] = []
        for candidate in candidates {
            let values = try candidate.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true { urls.append(candidate) }
        }
        urls.sort { $0.lastPathComponent < $1.lastPathComponent }
        return try urls.map { try JSONDecoder.workspace.decode(LearningExercise.self, from: Data(contentsOf: $0)) }
    }

    @discardableResult
    public func retargetCropReferences(_ referenceMap: [UUID: UUID]) throws -> Int {
        let exercises = try all()
        var changed = 0
        for var exercise in exercises {
            let updated = exercise.cropReferences.map { referenceMap[$0] ?? $0 }
            guard updated != exercise.cropReferences else { continue }
            exercise.cropReferences = updated
            try root.save(exercise, named: "\(exercise.id.uuidString).json", in: "learning/exercises")
            let legacyURL = root.root.appendingPathComponent("learning/exercises/\(exercise.id.uuidString)")
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                try FileManager.default.removeItem(at: legacyURL)
            }
            changed += 1
        }
        return changed
    }
}
