import Foundation
import PDFKit
import UIKit

public enum PDFCropError: LocalizedError {
    case unreadablePDF
    case invalidPage(Int)
    case invalidRectangle
    case unreadablePage
    case paperNotFound(UUID)
    case sourceMismatch
    case emptyTitle

    public var errorDescription: String? {
        switch self {
        case .unreadablePDF: return "原典PDFを読み込めません。"
        case .invalidPage(let page): return "指定ページを読み込めません: \(page)"
        case .invalidRectangle: return "クロップ範囲が正規化矩形ではありません。"
        case .unreadablePage: return "指定ページの画像を生成できません。"
        case .paperNotFound(let id): return "クロップ対象の論文レコードがありません: \(id.uuidString)"
        case .sourceMismatch: return "指定PDFが登録済み論文の原典PDFと一致しません。"
        case .emptyTitle: return "クロップのタイトルを入力してください。"
        }
    }
}

public struct PDFCropService {
    private let root: WorkspaceStore

    public init(root: WorkspaceStore) {
        self.root = root
    }

    public func createCrop(
        paperID: UUID,
        pdfURL: URL,
        kind: CropKind,
        page: Int,
        title: String,
        normalizedRect: CGRect
    ) throws -> PaperCrop {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { throw PDFCropError.emptyTitle }
        guard normalizedRect.width > 0, normalizedRect.height > 0,
              normalizedRect.minX >= 0, normalizedRect.minY >= 0,
              normalizedRect.maxX <= 1, normalizedRect.maxY <= 1 else {
            throw PDFCropError.invalidRectangle
        }
        let repository = PaperRepository(root: root)
        guard let paper = try repository.allRecords().first(where: { $0.id == paperID }) else {
            throw PDFCropError.paperNotFound(paperID)
        }
        guard let registeredRelativePath = paper.pdfRelativePath else { throw PDFCropError.sourceMismatch }
        let registeredURL = root.root.appendingPathComponent(registeredRelativePath).standardizedFileURL
        guard registeredURL == pdfURL.standardizedFileURL else { throw PDFCropError.sourceMismatch }
        guard let document = PDFDocument(url: pdfURL) else { throw PDFCropError.unreadablePDF }
        guard page > 0, page <= document.pageCount, let pdfPage = document.page(at: page - 1) else {
            throw PDFCropError.invalidPage(page)
        }
        guard let imageData = try render(page: pdfPage, normalizedRect: normalizedRect) else {
            throw PDFCropError.unreadablePage
        }

        let relativePath = "papers/crops/\(UUID().uuidString).png"
        let imageURL = root.root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try imageData.write(to: imageURL, options: .atomic)

        let crop = PaperCrop(
            kind: kind,
            page: page,
            title: normalizedTitle,
            imageRelativePath: relativePath,
            evidence: KnowledgeEvidence(kind: .paperCrop, source: pdfURL.lastPathComponent, locator: "page \(page)")
        )
        let updated = PaperRecord(id: paper.id, domainID: paper.domainID, chapterID: paper.chapterID, title: paper.title, sourceURL: paper.sourceURL, pdfRelativePath: paper.pdfRelativePath, originVerified: paper.originVerified, originVerificationFailure: paper.originVerificationFailure, crops: paper.crops + [crop])
        try repository.save(updated)
        return crop
    }

    private func render(page: PDFPage, normalizedRect: CGRect) throws -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        let cropRect = CGRect(
            x: bounds.minX + normalizedRect.minX * bounds.width,
            y: bounds.minY + (1 - normalizedRect.maxY) * bounds.height,
            width: normalizedRect.width * bounds.width,
            height: normalizedRect.height * bounds.height
        )
        let scale = min(4, max(1, 2400 / max(cropRect.width, cropRect.height)))
        let size = CGSize(width: cropRect.width * scale, height: cropRect.height * scale)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw PDFCropError.invalidRectangle
        }
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            context.cgContext.saveGState()
            context.cgContext.scaleBy(x: scale, y: scale)
            context.cgContext.translateBy(x: -cropRect.minX, y: -cropRect.minY)
            page.draw(with: .mediaBox, to: context.cgContext)
            context.cgContext.restoreGState()
        }
        return image.pngData()
    }
}
