import Foundation

public struct PaperCropDeduplicationResult: Sendable {
    public let records: [PaperRecord]
    public let referenceMap: [UUID: UUID]
    public let duplicateImageRelativePaths: Set<String>
}

public struct PaperCropReference: Codable, Hashable, Sendable {
    public let duplicateID: UUID
    public let representativeID: UUID

    public init(duplicateID: UUID, representativeID: UUID) {
        self.duplicateID = duplicateID
        self.representativeID = representativeID
    }
}

public enum PaperCropDeduplicationError: LocalizedError {
    case imageOutsideRoot

    public var errorDescription: String? {
        "重複画像の削除対象がUser Setting Rootの外側にあります。"
    }
}

public struct PaperCropDeduplicator {
    public init() {}

    public func plan(records: [PaperRecord]) -> PaperCropDeduplicationResult {
        var normalized: [PaperRecord] = []
        var referenceMap: [UUID: UUID] = [:]
        var duplicateImages = Set<String>()

        for record in records {
            var seen: [String: PaperCrop] = [:]
            var crops: [PaperCrop] = []
            for crop in record.crops {
                if let representative = seen[crop.deduplicationKey] {
                    referenceMap[crop.id] = representative.id
                    if crop.imageRelativePath != representative.imageRelativePath {
                        duplicateImages.insert(crop.imageRelativePath)
                    }
                } else {
                    seen[crop.deduplicationKey] = crop
                    crops.append(crop)
                }
            }
            normalized.append(PaperRecord(
                id: record.id,
                domainID: record.domainID,
                chapterID: record.chapterID,
                title: record.title,
                sourceURL: record.sourceURL,
                pdfRelativePath: record.pdfRelativePath,
                originVerified: record.originVerified,
                originVerificationFailure: record.originVerificationFailure,
                crops: crops
            ))
        }

        return PaperCropDeduplicationResult(
            records: normalized,
            referenceMap: referenceMap,
            duplicateImageRelativePaths: duplicateImages
        )
    }

    public func removeDuplicateImages(
        from result: PaperCropDeduplicationResult,
        root: WorkspaceStore
    ) throws {
        let rootURL = root.root.standardizedFileURL
        let retainedImagePaths = Set(result.records.flatMap { $0.crops.map(\.imageRelativePath) })
        for relativePath in result.duplicateImageRelativePaths where !retainedImagePaths.contains(relativePath) {
            let imageURL = root.root.appendingPathComponent(relativePath).standardizedFileURL
            guard imageURL.path == rootURL.path || imageURL.path.hasPrefix(rootURL.path + "/") else {
                throw PaperCropDeduplicationError.imageOutsideRoot
            }
            if FileManager.default.fileExists(atPath: imageURL.path) {
                try FileManager.default.removeItem(at: imageURL)
            }
        }
    }
}
