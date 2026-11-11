import Foundation

extension InlinePDFPagesView {
    // MARK: - Quiz sheet wiring helpers

    var _quizPaperKey: String {
        url.deletingPathExtension().lastPathComponent
    }

    func _currentQuizPageNotes() -> [Int: [String]] {
        var pages = Set(extraNotesByPage.keys)
        let pageCount = pdfDocument?.pageCount ?? 0
        if pageCount > 0 {
            for p in 0..<pageCount {
                pages.insert(p)
            }
        }

        var out: [Int: [String]] = [:]
        for p in pages.sorted() {
            _ensureExtraNotesLoaded(for: p)
            let notes = extraNotesByPage[p] ?? _loadExtraNotesResolved(page: p)
            let texts = notes
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !texts.isEmpty {
                out[p] = texts
            }
        }
        return out
    }

    func _currentQuizMathCardSources() -> [Int: [Inf6PaperQuizMathCardSource]] {
        var out: [Int: [Inf6PaperQuizMathCardSource]] = [:]
        let pageCount = pdfDocument?.pageCount ?? 0
        guard pageCount > 0 else { return out }

        for p in 0..<pageCount {
            _ensureMiniLoaded(for: p)
            let cards = _sortedMiniCards(page: p)
            guard !cards.isEmpty else { continue }

            var arr: [Inf6PaperQuizMathCardSource] = []
            arr.reserveCapacity(cards.count)

            for c in cards {
                let note = _miniExtraNoteBinding(page: p, cardID: c.id).wrappedValue
                let t = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { continue }
                arr.append(Inf6PaperQuizMathCardSource(cardID: c.id, explanation: t))
            }

            if !arr.isEmpty {
                out[p] = arr
            }
        }

        return out
    }

    func _notesRenderKey(page: Int) -> String {
        "notes-\(page)"
    }

    var _selectionTextUI: String {
        let pdfSel = pdfSelectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let detailSel = detailSelectedText.trimmingCharacters(in: .whitespacesAndNewlines)

        if pdfSel.isEmpty { return detailSel }
        if detailSel.isEmpty { return pdfSel }
        if pdfSel == detailSel { return pdfSel }
        if pdfSel.contains(detailSel) { return pdfSel }
        if detailSel.contains(pdfSel) { return detailSel }

        return pdfSel + "\n\n" + detailSel
    }
}
