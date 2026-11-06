import Foundation
#if canImport(PencilKit)
import PencilKit
#endif

public struct DerivationStore {
    private let fileManager: FileManager
    private let root: URL?
    private let identifier: String

    public init(root: URL?, identifier: String = "formula", fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
        let safeIdentifier = identifier.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        self.identifier = safeIdentifier.isEmpty ? "formula" : safeIdentifier
    }

    public func load() throws -> DerivationDocument {
        guard let root else { throw DerivationError.rootUnavailable }
        let url = root.appendingPathComponent("derivations/\(identifier).json")
        guard fileManager.fileExists(atPath: url.path) else { return DerivationDocument() }
        let document = try JSONDecoder().decode(DerivationDocument.self, from: Data(contentsOf: url))
#if canImport(PencilKit)
        if let drawingData = document.pencilDrawingData {
            do {
                let drawing = try PKDrawing(data: drawingData)
                guard !drawing.strokes.isEmpty else {
                    throw DerivationError.invalidPencilDrawingData
                }
            } catch let error as DerivationError {
                throw error
            } catch {
                throw DerivationError.invalidPencilDrawingData
            }
        }
#endif
        if let supplement = document.paperSupplement {
            try validatePaperSupplement(supplement, matches: document)
        }
        return document
    }

    public func save(_ document: DerivationDocument) throws {
        guard let root else { throw DerivationError.rootUnavailable }
        let directory = root.appendingPathComponent("derivations", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        let destination = directory.appendingPathComponent("\(identifier).json")
        let candidate = directory.appendingPathComponent(".\(identifier).\(UUID().uuidString).json")
        do {
            try data.write(to: candidate, options: .atomic)
            let restored = try JSONDecoder().decode(DerivationDocument.self, from: Data(contentsOf: candidate))
            guard restored.derivationID == document.derivationID,
                  restored.origin == document.origin else {
                throw DerivationError.derivationIdentityVerificationFailed
            }
            guard restored.updatedAt == document.updatedAt else {
                throw DerivationError.derivationRevisionVerificationFailed
            }
            guard restored.pencilDrawingData == document.pencilDrawingData else {
                throw DerivationError.pencilDrawingVerificationFailed
            }
            guard restored.handwritingEvidence == document.handwritingEvidence else {
                throw DerivationError.handwritingEvidenceVerificationFailed
            }
            guard restored.formulaStructure == document.formulaStructure else {
                throw DerivationError.formulaStructureVerificationFailed
            }
            guard restored.spatialAnalysis == document.spatialAnalysis else {
                throw DerivationError.spatialAnalysisVerificationFailed
            }
            guard restored.positionSensitiveClassification == document.positionSensitiveClassification else {
                throw DerivationError.positionSensitiveClassificationVerificationFailed
            }
            guard restored.similarityExpansion == document.similarityExpansion else {
                throw DerivationError.similarityExpansionVerificationFailed
            }
            guard restored.paperSupplement == document.paperSupplement else {
                throw DerivationError.paperSupplementVerificationFailed
            }
            if let supplement = restored.paperSupplement {
                try validatePaperSupplement(supplement, matches: restored)
            }
            guard try encoder.encode(restored) == data else {
                throw DerivationError.documentContentVerificationFailed
            }
#if canImport(PencilKit)
            if let drawingData = restored.pencilDrawingData {
                do {
                    let drawing = try PKDrawing(data: drawingData)
                    guard !drawing.strokes.isEmpty else {
                        throw DerivationError.invalidPencilDrawingData
                    }
                } catch let error as DerivationError {
                    throw error
                } catch {
                    throw DerivationError.invalidPencilDrawingData
                }
            }
#endif

            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.replaceItemAt(destination, withItemAt: candidate)
            } else {
                try fileManager.moveItem(at: candidate, to: destination)
            }
        } catch {
            let originalError = error
            try? fileManager.removeItem(at: candidate)
            throw originalError
        }
    }

    public func saveSupplement(_ supplement: PaperSupplement) throws {
        guard let root else { throw DerivationError.rootUnavailable }
        let directory = root.appendingPathComponent("supplements", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(supplement)
        try data.write(to: directory.appendingPathComponent("\(supplement.sourceEvidenceID.uuidString).json"), options: Data.WritingOptions.atomic)
    }

    public func loadSupplement(sourceEvidenceID: UUID) throws -> PaperSupplement? {
        guard let root else { throw DerivationError.rootUnavailable }
        let derivationStore = DerivationStore(root: root, identifier: sourceEvidenceID.uuidString, fileManager: fileManager)
        let derivationURL = root.appendingPathComponent("derivations/\(sourceEvidenceID.uuidString).json")
        if fileManager.fileExists(atPath: derivationURL.path) {
            var document = try derivationStore.load()
            if let supplement = document.paperSupplement {
                guard supplement.sourceEvidenceID == sourceEvidenceID,
                      supplement.id == sourceEvidenceID,
                      let sourceTitle = document.sourceTitle,
                      supplement == PaperSupplement(
                        id: sourceEvidenceID,
                        sourceEvidenceID: sourceEvidenceID,
                        sourceTitle: sourceTitle,
                        sourceLocator: document.sourceLocator,
                        mathML: document.mathML,
                        derivationSteps: document.steps,
                        dialogue: document.chatMessages,
                        updatedAt: document.updatedAt
                      ) else {
                    throw DerivationError.paperSupplementVerificationFailed
                }
                return supplement
            }

            if document.sourceEvidenceID == sourceEvidenceID,
               let sourceTitle = document.sourceTitle {
                let migratedSupplement = PaperSupplement(
                    id: sourceEvidenceID,
                    sourceEvidenceID: sourceEvidenceID,
                    sourceTitle: sourceTitle,
                    sourceLocator: document.sourceLocator,
                    mathML: document.mathML,
                    derivationSteps: document.steps,
                    dialogue: document.chatMessages,
                    updatedAt: document.updatedAt
                )
                document.paperSupplement = migratedSupplement
                try derivationStore.save(document)
                return migratedSupplement
            }
        }

        let url = root.appendingPathComponent("supplements/\(sourceEvidenceID.uuidString).json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let supplement = try JSONDecoder().decode(PaperSupplement.self, from: Data(contentsOf: url))
        guard supplement.sourceEvidenceID == sourceEvidenceID else {
            throw DerivationError.paperSupplementVerificationFailed
        }
        return supplement
    }

    private func validatePaperSupplement(_ supplement: PaperSupplement, matches document: DerivationDocument) throws {
        guard let evidenceID = document.sourceEvidenceID,
              evidenceID == supplement.sourceEvidenceID,
              supplement.id == evidenceID,
              let sourceTitle = document.sourceTitle else {
            throw DerivationError.paperSupplementVerificationFailed
        }
        let expected = PaperSupplement(
            id: evidenceID,
            sourceEvidenceID: evidenceID,
            sourceTitle: sourceTitle,
            sourceLocator: document.sourceLocator,
            mathML: document.mathML,
            derivationSteps: document.steps,
            dialogue: document.chatMessages,
            updatedAt: document.updatedAt
        )
        guard supplement == expected else {
            throw DerivationError.paperSupplementVerificationFailed
        }
    }
}
