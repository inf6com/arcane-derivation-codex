//
//  Inf6InlinePDFTextExtraction.swift
//  inf6
//
//  Created by Codex on 2026/05/27.
//

import Foundation

#if !os(iOS)
#error("InlinePDFPagesView text extraction is iOS-only. Remove this file from non-iOS targets.")
#endif

#if canImport(PDFKit)
import PDFKit
#else
#error("InlinePDFPagesView text extraction requires PDFKit.")
#endif

extension InlinePDFPagesView {
    func _normalizeSpaces(_ s: String) -> String {
        let replaced = s
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        var out = ""
        out.reserveCapacity(replaced.count)
        var prevSpace = false
        for ch in replaced {
            if ch == " " {
                if !prevSpace { out.append(ch) }
                prevSpace = true
            } else {
                out.append(ch)
                prevSpace = false
            }
        }
        return out.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    func _pageText(pageIndex: Int, maxChars: Int) -> String {
        guard let doc = pdfDocument else {
            let msg = "[InlinePDFPagesView] _pageText: pdfDocument is nil (not loaded)."
            print(msg)
            DispatchQueue.main.async { _ioLastError = msg }
            return ""
        }
        guard pageIndex >= 0, pageIndex < doc.pageCount, let page = doc.page(at: pageIndex) else {
            let msg = "[InlinePDFPagesView] _pageText: page out of range (idx=\(pageIndex), pages=\(doc.pageCount))."
            print(msg)
            DispatchQueue.main.async { _ioLastError = msg }
            return ""
        }

        let raw = page.string ?? ""
        let normalized = _normalizeSpaces(raw)
        return maxChars > 0 ? String(normalized.prefix(maxChars)) : normalized
    }

    func _documentText(maxChars: Int) -> String {
        guard let doc = pdfDocument else { return "" }
        var out = ""
        out.reserveCapacity(min(maxChars, 32768))
        for i in 0 ..< doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let raw = page.string ?? ""
            let normalized = _normalizeSpaces(raw)
            guard !normalized.isEmpty else { continue }
            if out.isEmpty {
                if out.count + normalized.count >= maxChars {
                    let remain = max(0, maxChars - out.count)
                    if remain > 0 { out += String(normalized.prefix(remain)) }
                    break
                } else {
                    out += normalized
                }
            } else {
                let sep = "\n\n"
                if out.count + sep.count + normalized.count >= maxChars {
                    let remain = max(0, maxChars - out.count - sep.count)
                    if remain > 0 { out += sep + String(normalized.prefix(remain)) }
                    break
                } else {
                    out += sep + normalized
                }
            }
        }
        return out
    }

    func _collectRAGChunksSnapshot(
        maxCharsPerPage: Int = 7000,
        chunkChars: Int = 900,
        overlapChars: Int = 180
    ) -> [_InlineRAGChunk] {
        guard let doc = pdfDocument else { return [] }
        let effectiveChunkChars = max(300, chunkChars)
        let effectiveOverlap = max(0, min(overlapChars, effectiveChunkChars - 50))
        let step = max(120, effectiveChunkChars - effectiveOverlap)

        var out: [_InlineRAGChunk] = []
        out.reserveCapacity(max(8, doc.pageCount * 3))

        for pageIdx in 0..<doc.pageCount {
            let pageText = _pageText(pageIndex: pageIdx, maxChars: maxCharsPerPage)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pageText.isEmpty else { continue }

            let chars = Array(pageText)
            if chars.count <= effectiveChunkChars {
                out.append(_InlineRAGChunk(pageIndex: pageIdx, text: pageText))
                continue
            }

            var start = 0
            while start < chars.count {
                let end = min(chars.count, start + effectiveChunkChars)
                let raw = String(chars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !raw.isEmpty {
                    out.append(_InlineRAGChunk(pageIndex: pageIdx, text: raw))
                }
                if end >= chars.count { break }
                start += step
            }
        }

        return out
    }

    func _injectCachedPageExplanationIfNeeded(for page: Int) {
        if loadExtraNotes == nil && !_notesJSONExists(page: page) { return }
        guard let cached = onPageChange(page)?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
              !cached.isEmpty else {
            return
        }

        let abstractNow = explanation.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if !abstractNow.isEmpty && cached == abstractNow {
            return
        }

        var arr = extraNotesByPage[page] ?? _loadExtraNotesResolved(page: page)

        if arr.contains(where: { $0.text == cached }) {
            extraNotesByPage[page] = arr
            return
        }

        arr.insert(Inf6ExtraNote(text: cached), at: 0)
        extraNotesByPage[page] = arr
        _persistExtraNotes(page: page, arr)
    }
}
