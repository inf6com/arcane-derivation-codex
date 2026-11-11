//
//  Inf6InlinePDFFigureDetect.swift
//  inf6
//
//  Created by decopin on 2026/01/03.
//

import Foundation
import PDFKit
import UIKit

#if !os(iOS)
#error("Inf6InlinePDFFigureDetect is iOS-only. Remove this file from non-iOS targets.")
#endif

/// Figure detection utilities for InlinePDFPagesView:
/// 1) detect candidate pages by scanning page text for Fig/Figure/図
/// 2) export a full page image as Base64 (JPEG) for sending to GPT
enum InlinePDFFigureDetect {

    enum FigureDetectError: LocalizedError {
        case invalidPageIndex(Int)
        case missingPage(Int)
        case renderFailed(Int)
        case jpegEncodeFailed(Int)
        case clipboardWriteFailed

        var errorDescription: String? {
            switch self {
            case .invalidPageIndex(let i):
                return "invalid pageIndex=\(i)"
            case .missingPage(let i):
                return "PDFPage is nil (pageIndex=\(i))"
            case .renderFailed(let i):
                return "failed to render page image (pageIndex=\(i))"
            case .jpegEncodeFailed(let i):
                return "failed to encode JPEG (pageIndex=\(i))"
            case .clipboardWriteFailed:
                return "failed to write Base64 string to clipboard"
            }
        }
    }

    // Matches: "Fig", "Fig.", "Figure", "Figure.", "図", "図表"
    // - English is case-insensitive.
    // - Japanese is literal match.
    private static let _figureKeywordRegex: NSRegularExpression = {
        let pattern = #"(?:\bfig\.?\b|\bfigure\.?\b|図表|図)"#
        do {
            return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            // This is a programmer error: fail loudly.
            preconditionFailure("Invalid regex pattern for figure detection: \(error)")
        }
    }()

    /// Returns 0-based page indexes whose page text contains figure keywords.
    static func detectCandidatePages(doc: PDFDocument) -> [Int] {
        let n = doc.pageCount
        guard n > 0 else { return [] }

        var out: [Int] = []
        out.reserveCapacity(min(n, 24))

        for i in 0..<n {
            guard let page = doc.page(at: i) else { continue }
            let text = page.string ?? ""
            if text.isEmpty { continue }

            if _figureKeywordRegex.firstMatch(in: text) != nil {
                out.append(i)
            }
        }
        return out
    }

    /// Render a full-page image. Uses PDFKit thumbnail rendering.
    /// - targetWidth: desired pixel-ish width (PDFKit interprets in points for thumbnail; practical enough for export)
    static func renderPageImage(
        doc: PDFDocument,
        pageIndex: Int,
        targetWidth: CGFloat,
        displayBox: PDFDisplayBox = .cropBox
    ) throws -> UIImage {
        let count = doc.pageCount
        guard pageIndex >= 0, pageIndex < count else {
            throw FigureDetectError.invalidPageIndex(pageIndex)
        }
        guard let page = doc.page(at: pageIndex) else {
            throw FigureDetectError.missingPage(pageIndex)
        }

        let bounds = page.bounds(for: displayBox)
        let w = max(1, bounds.width)
        let h = max(1, bounds.height)

        let scale = max(1.0, targetWidth / w)
        let size = CGSize(width: max(1, w * scale), height: max(1, h * scale))

        let img = page.thumbnail(of: size, for: displayBox)
        guard let cg = img.cgImage, cg.width > 0, cg.height > 0 else {
            throw FigureDetectError.renderFailed(pageIndex)
        }
        return img
    }

    /// Build Base64(JPEG) for the page image. Also returns a short preview string (first ~96 chars).
    static func pageImageBase64JPEG(
        doc: PDFDocument,
        pageIndex: Int,
        targetWidth: CGFloat = 1800,
        quality: CGFloat = 0.82
    ) throws -> (base64: String, preview: String) {

        let img = try renderPageImage(doc: doc, pageIndex: pageIndex, targetWidth: targetWidth)
        guard let jpeg = img.jpegData(compressionQuality: max(0.0, min(1.0, quality))) else {
            throw FigureDetectError.jpegEncodeFailed(pageIndex)
        }

        let b64 = jpeg.base64EncodedString()
        let previewCount = min(96, b64.count)
        let preview = String(b64.prefix(previewCount)) + (b64.count > previewCount ? "…" : "")
        return (b64, preview)
    }

    /// Copies the Base64(JPEG) string to clipboard (UIPasteboard).
    /// Returns a short preview string.
    static func copyPageImageBase64ToPasteboard(
        doc: PDFDocument,
        pageIndex: Int,
        targetWidth: CGFloat = 1800,
        quality: CGFloat = 0.82
    ) throws -> String {

        let (b64, preview) = try pageImageBase64JPEG(
            doc: doc,
            pageIndex: pageIndex,
            targetWidth: targetWidth,
            quality: quality
        )

        UIPasteboard.general.string = b64

        // Verify write (must surface failures).
        let echoed = UIPasteboard.general.string ?? ""
        guard !echoed.isEmpty else {
            throw FigureDetectError.clipboardWriteFailed
        }

        return preview
    }
}

private extension NSRegularExpression {
    func firstMatch(in s: String) -> NSTextCheckingResult? {
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        return firstMatch(in: s, options: [], range: range)
    }
}
