import Foundation
import PDFKit

public struct PaperImportResult: Sendable {
    public let record: PaperRecord
    public let pdfRelativePath: String
    public let pageCount: Int
}

public enum PaperImportError: LocalizedError {
    case unreadablePDF
    case emptyPDF
    case duplicateFile

    public var errorDescription: String? {
        switch self {
        case .unreadablePDF: return "PDFを読み込めません。"
        case .emptyPDF: return "PDFにページがありません。"
        case .duplicateFile: return "同名の論文原典PDFがすでに登録されています。"
        }
    }
}

public struct PaperImportService {
    private let root: WorkspaceStore

    public init(root: WorkspaceStore) {
        self.root = root
    }

    public func importPDF(from sourceURL: URL) throws -> PaperImportResult {
        guard let document = PDFDocument(url: sourceURL) else { throw PaperImportError.unreadablePDF }
        guard document.pageCount > 0 else { throw PaperImportError.emptyPDF }

        let papersDirectory = root.root.appendingPathComponent("papers", isDirectory: true)
        try FileManager.default.createDirectory(at: papersDirectory, withIntermediateDirectories: true)
        let fileName = sourceURL.lastPathComponent
        let destination = papersDirectory.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw PaperImportError.duplicateFile }
        try FileManager.default.copyItem(at: sourceURL, to: destination)

        let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
            ?? sourceURL.deletingPathExtension().lastPathComponent
        let record = PaperRecord(
            title: title,
            sourceURL: sourceURL,
            pdfRelativePath: "papers/\(fileName)",
            originVerified: false,
            originVerificationFailure: "原典の論文名・引用・出典が未検証です。"
        )
        try root.save(record, named: "\(record.id.uuidString).json", in: "papers/records")

        return PaperImportResult(
            record: record,
            pdfRelativePath: "papers/\(fileName)",
            pageCount: document.pageCount
        )
    }
}
