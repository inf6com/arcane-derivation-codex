//
//  Inf6InlinePDFDocumentState.swift
//  inf6
//
//  Created by Codex on 2026/05/27.
//

import Foundation
import PDFKit

extension InlinePDFPagesView {
    func _handlePDFChanged(to newURL: URL) {
        _activeURL = newURL

        _abstractSaveTask?.cancel()
        _abstractSaveTask = nil
        _inFlightAbstractTask?.cancel()
        _inFlightAbstractTask = nil

        _storageAvailable = (_sharedRootDirForKnowledgeCards() != nil)
        _isRunningAssetsPipeline = false
        _assetsPipelineDidFinish = false
        _assetsPipelineFinishedMessage = nil

        pdfViewRef = nil
        _ioLastError = nil

        let base = _pdfBaseName(from: newURL)
        pdfTitle = base.isEmpty ? "Explanation" : base

        if let base = _paperBaseDir() {
            Task { @MainActor in
                do {
                    try Inf6WatchConnectivityPhone.shared.sendCurrentQuiz(from: base)
                } catch {
                    _ioLastError = "[InlinePDFPagesView] watch quiz sync failed: \(error.localizedDescription)"
                }
            }
        }

        sourceAbstractNote = _loadSourceAbstractFromMetadata()
        abstractNote = Inf6ExtraNote(text: "")
        if !explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            explanation = ""
        }

        let persisted = _loadAbstractFromDisk()
        let persistedText = persisted.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !persistedText.isEmpty {
            abstractNote = persisted
            if explanation != persisted.text {
                explanation = persisted.text
            }
        } else {
            let current = abstractNote.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !current.isEmpty {
                _scheduleAbstractSave(current)
            }
        }

        miniCardsByPage = [:]
        for (_, t) in _miniLoadTaskByPage { t.cancel() }
        _miniLoadTaskByPage = [:]
        _cancelAllInFlightMathTasks()
        _miniSelectedCardIDByPage = [:]

        extraNotesByPage = [:]
        pdfSelectedText = ""
        detailSelectedText = ""
        _clearRememberedSelectionText()

        selectedPage.wrappedValue = 0
        _applyPDFDocumentLoadResult(Inf6InlinePDFDocumentLoader.load(from: newURL), for: newURL)
    }

    private func _applyPDFDocumentLoadResult(_ result: Inf6InlinePDFLoadResult, for newURL: URL) {
        if let msg = result.errorMessage {
            print(msg)
            _ioLastError = msg
        }

        guard let doc = result.document else {
            pdfDocument = nil
            if _ioLastError == nil {
                _ioLastError = "[InlinePDFPagesView] PDF document could not be loaded: \(newURL.path)"
            }
            return
        }

        pdfDocument = doc

        if let metaTitle = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
           !metaTitle.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            pdfTitle = metaTitle
        } else {
            let base = _pdfBaseName(from: newURL)
            pdfTitle = base.isEmpty ? "Explanation" : base
        }

        let initialPage: Int = {
            let backed = _pagesBackedByNotesJSON(doc: doc)
            if let first = backed.first { return first }

            let msg = "[InlinePDFPagesView] _handlePDFChanged: no JSON-backed pages found (no pN.notes.json)."
            print(msg)
            DispatchQueue.main.async { _ioLastError = msg }
            return 0
        }()

        selectedPage.wrappedValue = initialPage

        DispatchQueue.main.async {
            _ensureExtraNotesLoaded(for: initialPage)
            _ensureMiniLoaded(for: initialPage)
            _injectCachedPageExplanationIfNeeded(for: initialPage)
        }
    }

    func _handleSelectedPageChange(_ idx: Int) {
        detailSelectedText = ""
        _clearRememberedSelectionText()

        DispatchQueue.main.async {
            _ensureExtraNotesLoaded(for: idx)
            _ensureMiniLoaded(for: idx)
            _injectCachedPageExplanationIfNeeded(for: idx)
        }
    }
}
