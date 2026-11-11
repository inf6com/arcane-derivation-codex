//
//  Inf6InlinePDFDocumentLoader.swift
//  inf6
//
//  Created by Codex on 2026/05/27.
//

import Foundation
import PDFKit

struct Inf6InlinePDFLoadResult {
    let document: PDFDocument?
    let errorMessage: String?
}

enum Inf6InlinePDFDocumentLoader {
    static func load(from url: URL) -> Inf6InlinePDFLoadResult {
        guard url.isFileURL else {
            return Inf6InlinePDFLoadResult(
                document: nil,
                errorMessage: "[InlinePDFPagesView] _loadPDFDocument: non-file URL is not supported: \(url)"
            )
        }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let read = readFileDataCoordinated(url)
        if let error = read.errorMessage {
            return Inf6InlinePDFLoadResult(document: nil, errorMessage: error)
        }

        guard let data = read.data, !data.isEmpty else {
            return Inf6InlinePDFLoadResult(
                document: nil,
                errorMessage: "[InlinePDFPagesView] _loadPDFDocument: coordinated read returned empty data for url: \(url)"
            )
        }

        guard let doc = PDFDocument(data: data), doc.pageCount > 0 else {
            return Inf6InlinePDFLoadResult(
                document: nil,
                errorMessage: "[InlinePDFPagesView] _loadPDFDocument: PDFKit could not open document data for url: \(url)"
            )
        }

        return Inf6InlinePDFLoadResult(document: doc, errorMessage: nil)
    }

    private static func readFileDataCoordinated(_ url: URL) -> (data: Data?, errorMessage: String?) {
        var out: Data? = nil
        var coordError: NSError? = nil
        var readError: Error? = nil

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            do {
                out = try Inf6SafeFileRead.data(at: readURL)
            } catch {
                readError = error
                out = nil
            }
        }

        if let coordError {
            return (nil, "[InlinePDFPagesView] _readFileDataCoordinated: coordination failed: \(coordError) url=\(url)")
        }

        if let readError {
            let fm = FileManager.default
            let existsOnDisk = fm.fileExists(atPath: url.path)
            if existsOnDisk {
                return (nil, "[InlinePDFPagesView] _readFileDataCoordinated: read failed: \(readError) url=\(url)")
            }
        }

        return (out, nil)
    }
}
