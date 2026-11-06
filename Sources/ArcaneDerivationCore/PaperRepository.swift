import Foundation

public struct PaperRepository {
    private let root: WorkspaceStore

    public init(root: WorkspaceStore) {
        self.root = root
    }

    public func allRecords() throws -> [PaperRecord] {
        let directory = root.root.appendingPathComponent("papers/records", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let candidates = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        var urls: [URL] = []
        for candidate in candidates {
            let values = try candidate.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true { urls.append(candidate) }
        }
        urls.sort { $0.lastPathComponent < $1.lastPathComponent }
        return try urls.map { url in
            try JSONDecoder.workspace.decode(PaperRecord.self, from: Data(contentsOf: url))
        }
    }

    public func save(_ record: PaperRecord) throws {
        try root.save(record, named: "\(record.id.uuidString).json", in: "papers/records")
    }

    @discardableResult
    public func deduplicateCrops() throws -> PaperCropDeduplicationResult {
        let result = PaperCropDeduplicator().plan(records: try allRecords())
        for record in result.records {
            try root.save(record, named: "\(record.id.uuidString).json", in: "papers/records")
            let legacyURL = root.root.appendingPathComponent("papers/records/\(record.id.uuidString)")
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                try FileManager.default.removeItem(at: legacyURL)
            }
        }
        _ = try LearningExerciseRepository(root: root).retargetCropReferences(result.referenceMap)
        let references = result.referenceMap.map { PaperCropReference(duplicateID: $0.key, representativeID: $0.value) }
            .sorted { $0.duplicateID.uuidString < $1.duplicateID.uuidString }
        try root.save(references, named: "crop-reference-map", in: "papers")
        try PaperCropDeduplicator().removeDuplicateImages(from: result, root: root)
        return result
    }
}
