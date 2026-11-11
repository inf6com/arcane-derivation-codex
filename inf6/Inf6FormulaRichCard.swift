//
//  Inf6FormulaRichCard.swift
//  inf6
//
//  Created by decopin on 2026/01/04.
//

import Foundation
import SwiftUI
import PDFKit
import UIKit

#if !os(iOS)
#error("Inf6FormulaRichCard is iOS-only. Remove this file from non-iOS targets.")
#endif

// Move the “formula mini PDF + explanation card” implementation out of inf6InlinePDFView.swift.
// Keep everything as InlinePDFPagesView’s nested types/methods via extension so call sites stay unchanged.
extension InlinePDFPagesView {


    // MARK: - Mini PDF (equation-only) per-page storage (multiple cards)

    /// A selection rect normalized to the page bounds (0..1). Origin is PDF page space (bottom-left).
    struct MiniRect: Codable, Equatable {
        var x: Double
        var y: Double
        var w: Double
        var h: Double

        static let full = MiniRect(x: 0, y: 0, w: 1, h: 1)

        var top: Double { y + h }
        var left: Double { x }
    }

    /// One knowledge card: a mini PDF (cropped selection) + its explanation.
    struct MiniCard: Codable, Equatable, Identifiable {
        var id: String              // UUID string
        var rect: MiniRect          // normalized selection rect
        var createdAt: TimeInterval
        var pdfData: Data           // empty when not yet downloaded (iCloud placeholder) or when text-only
        var explanation: String

        /// Optional rich text payload (RTF). When present, UI editors should prefer this for rendering/styling.
        var rtf: Data?

        // Rich fields (persisted via a separate per-card meta JSON file).
        // These are intentionally optional so older cards can load without fabricating data.
        var sourceText: String?
        var localSnippet: String?
        var promptLang: String?
        var updatedAt: TimeInterval?
    }

    /// Manifest record stored per page (lightweight; PDF/TXT stored as separate files).
    struct _MiniCardRecord: Codable, Equatable {
        var id: String
        var rect: MiniRect
        var createdAt: TimeInterval
    }

    /// Per-card rich metadata stored as a separate JSON file (kept small and independent of PDF/TXT).
    struct _MiniCardMetaFile: Codable, Equatable {
        var version: Int
        var selectionText: String
        var localSnippet: String?
        var lang: String?
        var updatedAt: TimeInterval
    }

    func _miniDir() -> URL? {
        guard let base = _paperBaseDir() else { return nil }
        let dir = base.appendingPathComponent("mini", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            let msg = "[InlinePDFPagesView] _miniDir: cannot create mini dir: \(error)"
            print(msg)
            DispatchQueue.main.async { _ioLastError = msg }
            return nil
        }
        return dir
    }

    func _miniManifestURL(page: Int) -> URL? {
        _miniDir()?.appendingPathComponent("p\(page).cards.json")
    }

    func _miniCardPDFURL(page: Int, cardID: String) -> URL? {
        _miniDir()?.appendingPathComponent("p\(page).\(cardID).mini.pdf")
    }

    func _miniCardTXTURL(page: Int, cardID: String) -> URL? {
        _miniDir()?.appendingPathComponent("p\(page).\(cardID).mini.txt")
    }

    func _miniCardRTFURL(page: Int, cardID: String) -> URL? {
        _miniDir()?.appendingPathComponent("p\(page).\(cardID).mini.rtf")
    }

    func _miniCardMetaURL(page: Int, cardID: String) -> URL? {
        _miniDir()?.appendingPathComponent("p\(page).\(cardID).mini.meta.json")
    }

    func _sortedMiniCards(page: Int) -> [MiniCard] {
        let arr = miniCardsByPage[page] ?? []
        return arr.sorted { a, b in
            let at = a.rect.top
            let bt = b.rect.top
            if abs(at - bt) > 1e-9 { return at > bt }          // top-to-bottom
            if abs(a.rect.left - b.rect.left) > 1e-9 { return a.rect.left < b.rect.left } // left-to-right
            return a.createdAt < b.createdAt
        }
    }

    func _loadMiniCardsFromDisk(page: Int) -> [MiniCard] {
        guard let manifestURL = _miniManifestURL(page: page) else { return [] }

        #if os(iOS)
        let didAccess = manifestURL.startAccessingSecurityScopedResource()
        defer { if didAccess { manifestURL.stopAccessingSecurityScopedResource() } }
        #endif

        let fm = FileManager.default
        let manifestExistsOnDisk = fm.fileExists(atPath: manifestURL.path)

        if let data = _readFileDataCoordinated(manifestURL), !data.isEmpty {
            if let recs = try? JSONDecoder().decode([_MiniCardRecord].self, from: data) {

                var out: [MiniCard] = []
                out.reserveCapacity(recs.count)

                for r in recs {
                    guard let pdfURL = _miniCardPDFURL(page: page, cardID: r.id),
                          let txtURL = _miniCardTXTURL(page: page, cardID: r.id),
                          let rtfURL = _miniCardRTFURL(page: page, cardID: r.id) else {
                        continue
                    }

                    #if os(iOS)
                    let didAccessPDF = pdfURL.startAccessingSecurityScopedResource()
                    defer { if didAccessPDF { pdfURL.stopAccessingSecurityScopedResource() } }
                    let didAccessTXT = txtURL.startAccessingSecurityScopedResource()
                    defer { if didAccessTXT { txtURL.stopAccessingSecurityScopedResource() } }
                    let didAccessRTF = rtfURL.startAccessingSecurityScopedResource()
                    defer { if didAccessRTF { rtfURL.stopAccessingSecurityScopedResource() } }
                    #endif

                    let txtData = _readFileDataCoordinated(txtURL)
                    let explanation = (txtData.flatMap { String(data: $0, encoding: .utf8) }) ?? ""

                    let rtfDataRaw = _readFileDataCoordinated(rtfURL)
                    let rtfData: Data? = (rtfDataRaw != nil && !(rtfDataRaw?.isEmpty ?? true)) ? rtfDataRaw : nil

                    let meta = _loadMiniCardMetaFromDisk(page: page, cardID: r.id)

                    if let pdfData = _readFileDataCoordinated(pdfURL), !pdfData.isEmpty {
                        out.append(MiniCard(
                            id: r.id,
                            rect: r.rect,
                            createdAt: r.createdAt,
                            pdfData: pdfData,
                            explanation: explanation,
                            rtf: rtfData,
                            sourceText: meta?.selectionText,
                            localSnippet: meta?.localSnippet,
                            promptLang: meta?.lang,
                            updatedAt: meta?.updatedAt
                        ))
                    } else {
                        // Keep a placeholder if text exists (or if iCloud is still downloading the PDF).
                        if !explanation.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                            out.append(MiniCard(
                                id: r.id,
                                rect: r.rect,
                                createdAt: r.createdAt,
                                pdfData: Data(),
                                explanation: explanation,
                                rtf: rtfData,
                                sourceText: meta?.selectionText,
                                localSnippet: meta?.localSnippet,
                                promptLang: meta?.lang,
                                updatedAt: meta?.updatedAt
                            ))
                        }
                    }
                }

                return out
            } else if manifestExistsOnDisk {
                let msg = "[InlinePDFPagesView] _loadMiniCardsFromDisk: manifest decode failed: \(manifestURL)"
                print(msg)
                DispatchQueue.main.async { _ioLastError = msg }
            }
        } else if manifestExistsOnDisk {
            let msg = "[InlinePDFPagesView] _loadMiniCardsFromDisk: coordinated read failed: \(manifestURL)"
            print(msg)
            DispatchQueue.main.async { _ioLastError = msg }
        }

        return []
    }

    func _loadMiniCardMetaFromDisk(page: Int, cardID: String) -> _MiniCardMetaFile? {
        guard let url = _miniCardMetaURL(page: page, cardID: cardID) else { return nil }

        #if os(iOS)
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        #endif

        let fm = FileManager.default
        let existsOnDisk = fm.fileExists(atPath: url.path)

        guard let data = _readFileDataCoordinated(url), !data.isEmpty else {
            if existsOnDisk {
                let msg = "[InlinePDFPagesView] _loadMiniCardMetaFromDisk: coordinated read failed: \(url)"
                print(msg)
                DispatchQueue.main.async { _ioLastError = msg }
            }
            return nil
        }

        do {
            return try JSONDecoder().decode(_MiniCardMetaFile.self, from: data)
        } catch {
            if existsOnDisk {
                let msg = "[InlinePDFPagesView] _loadMiniCardMetaFromDisk: decode failed: \(url) error=\(error)"
                print(msg)
                DispatchQueue.main.async { _ioLastError = msg }
            }
            return nil
        }
    }

    func _saveMiniCardMetaToDisk(page: Int, cardID: String, meta: _MiniCardMetaFile) {
        guard let url = _miniCardMetaURL(page: page, cardID: cardID) else { return }
        let payload = meta
        let accessURL = url

        DispatchQueue.global(qos: .utility).async {
            #if os(iOS)
            let didAccess = accessURL.startAccessingSecurityScopedResource()
            defer { if didAccess { accessURL.stopAccessingSecurityScopedResource() } }
            #endif

            guard let data = try? JSONEncoder().encode(payload) else {
                let msg = "[InlinePDFPagesView] _saveMiniCardMetaToDisk: encode failed (page=\(page), id=\(cardID))"
                print(msg)
                DispatchQueue.main.async { _ioLastError = msg }
                return
            }

            var coordError: NSError? = nil
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { writeURL in
                do {
                    try data.write(to: writeURL, options: [.atomic])
                } catch {
                    let msg = "[InlinePDFPagesView] _saveMiniCardMetaToDisk: write failed (page=\(page), id=\(cardID)) error=\(error)"
                    print(msg)
                    DispatchQueue.main.async { _ioLastError = msg }
                }
            }

            if let coordError {
                let msg = "[InlinePDFPagesView] _saveMiniCardMetaToDisk: coordination failed (page=\(page), id=\(cardID)) error=\(coordError)"
                print(msg)
                DispatchQueue.main.async { _ioLastError = msg }
            }
        }
    }

    func _saveMiniManifestToDisk(page: Int, records: [_MiniCardRecord]) {
        guard let url = _miniManifestURL(page: page) else { return }
        let payload = records
        let accessURL = url
        DispatchQueue.global(qos: .utility).async {
            #if os(iOS)
            let didAccess = accessURL.startAccessingSecurityScopedResource()
            defer { if didAccess { accessURL.stopAccessingSecurityScopedResource() } }
            #endif

            guard let data = try? JSONEncoder().encode(payload) else {
                let msg = "[InlinePDFPagesView] _saveMiniManifestToDisk: encode failed (page=\(page))"
                print(msg)
                DispatchQueue.main.async { _ioLastError = msg }
                return
            }

            var coordError: NSError? = nil
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { writeURL in
                do {
                    try data.write(to: writeURL, options: [.atomic])
                } catch {
                    let msg = "[InlinePDFPagesView] _saveMiniManifestToDisk: write failed (page=\(page)) error=\(error)"
                    print(msg)
                    DispatchQueue.main.async { _ioLastError = msg }
                }
            }

            if let coordError {
                let msg = "[InlinePDFPagesView] _saveMiniManifestToDisk: coordination failed (page=\(page)) error=\(coordError)"
                print(msg)
                DispatchQueue.main.async { _ioLastError = msg }
            }
        }
    }

    func _saveMiniCardFilesToDisk(page: Int, card: MiniCard) {
        guard let pdfURL = _miniCardPDFURL(page: page, cardID: card.id),
              let txtURL = _miniCardTXTURL(page: page, cardID: card.id),
              let rtfURL = _miniCardRTFURL(page: page, cardID: card.id) else { return }

        let pdfData = card.pdfData
        let txtData = card.explanation.data(using: .utf8)
        let rtfData: Data? = {
            guard let d = card.rtf, !d.isEmpty else { return nil }
            return d
        }()

        DispatchQueue.global(qos: .utility).async {
            #if os(iOS)
            let didAccessPDF = pdfURL.startAccessingSecurityScopedResource()
            defer { if didAccessPDF { pdfURL.stopAccessingSecurityScopedResource() } }
            let didAccessTXT = txtURL.startAccessingSecurityScopedResource()
            defer { if didAccessTXT { txtURL.stopAccessingSecurityScopedResource() } }
            let didAccessRTF = rtfURL.startAccessingSecurityScopedResource()
            defer { if didAccessRTF { rtfURL.stopAccessingSecurityScopedResource() } }
            #endif

            let coordinator = NSFileCoordinator()

            if !pdfData.isEmpty {
                var pdfErr: NSError? = nil
                coordinator.coordinate(writingItemAt: pdfURL, options: .forReplacing, error: &pdfErr) { writeURL in
                    do {
                        try pdfData.write(to: writeURL, options: [.atomic])
                    } catch {
                        let msg = "[InlinePDFPagesView] _saveMiniCardFilesToDisk: PDF write failed (page=\(page), id=\(card.id)) error=\(error)"
                        print(msg)
                        DispatchQueue.main.async { _ioLastError = msg }
                    }
                }
                if let pdfErr {
                    let msg = "[InlinePDFPagesView] _saveMiniCardFilesToDisk: PDF coordination failed (page=\(page), id=\(card.id)) error=\(pdfErr)"
                    print(msg)
                    DispatchQueue.main.async { _ioLastError = msg }
                }
            }

            if let txtData {
                var txtErr: NSError? = nil
                coordinator.coordinate(writingItemAt: txtURL, options: .forReplacing, error: &txtErr) { writeURL in
                    do {
                        try txtData.write(to: writeURL, options: [.atomic])
                    } catch {
                        let msg = "[InlinePDFPagesView] _saveMiniCardFilesToDisk: TXT write failed (page=\(page), id=\(card.id)) error=\(error)"
                        print(msg)
                        DispatchQueue.main.async { _ioLastError = msg }
                    }
                }
                if let txtErr {
                    let msg = "[InlinePDFPagesView] _saveMiniCardFilesToDisk: TXT coordination failed (page=\(page), id=\(card.id)) error=\(txtErr)"
                    print(msg)
                    DispatchQueue.main.async { _ioLastError = msg }
                }
            } else {
                let msg = "[InlinePDFPagesView] _saveMiniCardFilesToDisk: TXT encode failed (page=\(page), id=\(card.id))"
                print(msg)
                DispatchQueue.main.async { _ioLastError = msg }
            }

            if let rtfData {
                var rtfErr: NSError? = nil
                coordinator.coordinate(writingItemAt: rtfURL, options: .forReplacing, error: &rtfErr) { writeURL in
                    do {
                        try rtfData.write(to: writeURL, options: [.atomic])
                    } catch {
                        let msg = "[InlinePDFPagesView] _saveMiniCardFilesToDisk: RTF write failed (page=\(page), id=\(card.id)) error=\(error)"
                        print(msg)
                        DispatchQueue.main.async { _ioLastError = msg }
                    }
                }
                if let rtfErr {
                    let msg = "[InlinePDFPagesView] _saveMiniCardFilesToDisk: RTF coordination failed (page=\(page), id=\(card.id)) error=\(rtfErr)"
                    print(msg)
                    DispatchQueue.main.async { _ioLastError = msg }
                }
            } else {
                let fm = FileManager.default
                if fm.fileExists(atPath: rtfURL.path) {
                    var delErr: NSError? = nil
                    coordinator.coordinate(writingItemAt: rtfURL, options: .forDeleting, error: &delErr) { u in
                        do {
                            try fm.removeItem(at: u)
                        } catch {
                            let msg = "[InlinePDFPagesView] _saveMiniCardFilesToDisk: RTF delete failed (page=\(page), id=\(card.id)) error=\(error)"
                            print(msg)
                            DispatchQueue.main.async { _ioLastError = msg }
                        }
                    }
                    if let delErr {
                        let msg = "[InlinePDFPagesView] _saveMiniCardFilesToDisk: RTF delete coordination failed (page=\(page), id=\(card.id)) error=\(delErr)"
                        print(msg)
                        DispatchQueue.main.async { _ioLastError = msg }
                    }
                }
            }
        }
    }

    func _deleteMiniCardFiles(page: Int, cardID: String) {
        guard let pdfURL = _miniCardPDFURL(page: page, cardID: cardID),
              let txtURL = _miniCardTXTURL(page: page, cardID: cardID),
              let rtfURL = _miniCardRTFURL(page: page, cardID: cardID),
              let metaURL = _miniCardMetaURL(page: page, cardID: cardID) else { return }

        DispatchQueue.global(qos: .utility).async {
            #if os(iOS)
            let didAccessPDF = pdfURL.startAccessingSecurityScopedResource()
            defer { if didAccessPDF { pdfURL.stopAccessingSecurityScopedResource() } }
            let didAccessTXT = txtURL.startAccessingSecurityScopedResource()
            defer { if didAccessTXT { txtURL.stopAccessingSecurityScopedResource() } }
            let didAccessRTF = rtfURL.startAccessingSecurityScopedResource()
            defer { if didAccessRTF { rtfURL.stopAccessingSecurityScopedResource() } }
            let didAccessMeta = metaURL.startAccessingSecurityScopedResource()
            defer { if didAccessMeta { metaURL.stopAccessingSecurityScopedResource() } }
            #endif

            let fm = FileManager.default
            let coordinator = NSFileCoordinator()

            var e1: NSError? = nil
            coordinator.coordinate(writingItemAt: pdfURL, options: .forDeleting, error: &e1) { u in
                do {
                    try fm.removeItem(at: u)
                } catch {
                    let msg = "[InlinePDFPagesView] _deleteMiniCardFiles: PDF delete failed (page=\(page), id=\(cardID)) error=\(error)"
                    print(msg)
                    DispatchQueue.main.async { _ioLastError = msg }
                }
            }
            if let e1 {
                let msg = "[InlinePDFPagesView] _deleteMiniCardFiles: PDF delete coordination failed (page=\(page), id=\(cardID)) error=\(e1)"
                print(msg)
                DispatchQueue.main.async { _ioLastError = msg }
            }

            var e2: NSError? = nil
            coordinator.coordinate(writingItemAt: txtURL, options: .forDeleting, error: &e2) { u in
                do {
                    try fm.removeItem(at: u)
                } catch {
                    let msg = "[InlinePDFPagesView] _deleteMiniCardFiles: TXT delete failed (page=\(page), id=\(cardID)) error=\(error)"
                    print(msg)
                    DispatchQueue.main.async { _ioLastError = msg }
                }
            }
            if let e2 {
                let msg = "[InlinePDFPagesView] _deleteMiniCardFiles: TXT delete coordination failed (page=\(page), id=\(cardID)) error=\(e2)"
                print(msg)
                DispatchQueue.main.async { _ioLastError = msg }
            }

            var eRTF: NSError? = nil
            coordinator.coordinate(writingItemAt: rtfURL, options: .forDeleting, error: &eRTF) { u in
                do {
                    try fm.removeItem(at: u)
                } catch {
                    let msg = "[InlinePDFPagesView] _deleteMiniCardFiles: RTF delete failed (page=\(page), id=\(cardID)) error=\(error)"
                    print(msg)
                    DispatchQueue.main.async { _ioLastError = msg }
                }
            }
            if let eRTF {
                let msg = "[InlinePDFPagesView] _deleteMiniCardFiles: RTF delete coordination failed (page=\(page), id=\(cardID)) error=\(eRTF)"
                print(msg)
                DispatchQueue.main.async { _ioLastError = msg }
            }

            var e3: NSError? = nil
            coordinator.coordinate(writingItemAt: metaURL, options: .forDeleting, error: &e3) { u in
                do {
                    try fm.removeItem(at: u)
                } catch {
                    let msg = "[InlinePDFPagesView] _deleteMiniCardFiles: META delete failed (page=\(page), id=\(cardID)) error=\(error)"
                    print(msg)
                    DispatchQueue.main.async { _ioLastError = msg }
                }
            }
            if let e3 {
                let msg = "[InlinePDFPagesView] _deleteMiniCardFiles: META delete coordination failed (page=\(page), id=\(cardID)) error=\(e3)"
                print(msg)
                DispatchQueue.main.async { _ioLastError = msg }
            }
        }
    }

    func _pdfDoc(from data: Data) -> PDFDocument? { PDFDocument(data: data) }

    // Publish mini-cards state only when it is safe for UITextView selection.
    // When selection is active, defer publishing until selection clears.
    func _publishMiniCardsOrDefer(page: Int, loaded: [MiniCard]) {
        let selectionActive = _isDetailTextInteracting || !detailSelectedText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty
        if selectionActive {
            _miniPendingLoadedByPage[page] = loaded
            _schedulePendingMiniPublish(page: page)
            return
        }

        miniCardsByPage[page] = loaded
        _miniPendingLoadedByPage.removeValue(forKey: page)

        if _miniSelectedCardIDByPage[page] == nil {
            _miniSelectedCardIDByPage[page] = _sortedMiniCards(page: page).first?.id
        }

        if let w = _miniPendingPublishWorkByPage[page] {
            w.cancel()
            _miniPendingPublishWorkByPage.removeValue(forKey: page)
        }
    }

    func _schedulePendingMiniPublish(page: Int) {
        if let w = _miniPendingPublishWorkByPage[page] {
            if !w.isCancelled { return }
            _miniPendingPublishWorkByPage.removeValue(forKey: page)
        }

        let work = DispatchWorkItem { [page] in
            _miniPendingPublishWorkByPage.removeValue(forKey: page)
            _tryPublishPendingMiniCards(page: page)
        }
        _miniPendingPublishWorkByPage[page] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func _tryPublishPendingMiniCards(page: Int) {
        guard let pending = _miniPendingLoadedByPage[page] else { return }

        let selectionActive = _isDetailTextInteracting || !detailSelectedText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty
        if selectionActive {
            _schedulePendingMiniPublish(page: page)
            return
        }

        miniCardsByPage[page] = pending
        _miniPendingLoadedByPage.removeValue(forKey: page)

        if _miniSelectedCardIDByPage[page] == nil {
            _miniSelectedCardIDByPage[page] = _sortedMiniCards(page: page).first?.id
        }
    }

    func _ensureMiniLoaded(for page: Int) {
        // If already loaded (including loaded empty), do nothing.
        if miniCardsByPage[page] != nil { return }

        // If a load task is already running for this page, do nothing.
        if let t = _miniLoadTaskByPage[page], !t.isCancelled {
            return
        }

        // First attempt: synchronous load from disk.
        let loaded = _loadMiniCardsFromDisk(page: page)
        if !loaded.isEmpty {
            _publishMiniCardsOrDefer(page: page, loaded: loaded)
            return
        }

        guard let manifestURL = _miniManifestURL(page: page) else {
            _publishMiniCardsOrDefer(page: page, loaded: [])
            return
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: manifestURL.path) else {
            _publishMiniCardsOrDefer(page: page, loaded: [])
            return
        }

        let finalLoaded = _loadMiniCardsFromDisk(page: page)
        _publishMiniCardsOrDefer(page: page, loaded: finalLoaded)
    }
    

    func _appendMiniCard(page: Int, doc: PDFDocument, rect: MiniRect, explanation: String, selectionText: String) -> String? {
        guard let data = doc.dataRepresentation() else { return nil }
        let id = UUID().uuidString
        let created = Date().timeIntervalSince1970
        let card = MiniCard(
            id: id,
            rect: rect,
            createdAt: created,
            pdfData: data,
            explanation: explanation,
            rtf: nil,
            sourceText: selectionText,
            localSnippet: nil,
            promptLang: nil,
            updatedAt: created
        )

        var arr = miniCardsByPage[page] ?? []
        arr.append(card)
        _miniSelectedCardIDByPage[page] = id
        _publishMiniCardsOrDefer(page: page, loaded: arr)

        _saveMiniCardFilesToDisk(page: page, card: card)
        let records = arr.map { _MiniCardRecord(id: $0.id, rect: $0.rect, createdAt: $0.createdAt) }
        _saveMiniManifestToDisk(page: page, records: records)
        _saveMiniCardMetaToDisk(page: page, cardID: id, meta: _MiniCardMetaFile(version: 1, selectionText: selectionText, localSnippet: nil, lang: nil, updatedAt: created))
        return id
    }

    @MainActor
    func _updateMiniCardExplanation(page: Int, cardID: String, explanation: String) {
        guard var arr = miniCardsByPage[page] else { return }
        guard let idx = arr.firstIndex(where: { $0.id == cardID }) else { return }

        arr[idx].explanation = explanation
        // GPT生成など「plain text 更新」は、RTFを必ず破棄して整合性を保つ。
        arr[idx].rtf = nil

        let now = Date().timeIntervalSince1970
        arr[idx].updatedAt = now
        _publishMiniCardsOrDefer(page: page, loaded: arr)

        if let sel = arr[idx].sourceText?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), !sel.isEmpty {
            _saveMiniCardMetaToDisk(
                page: page,
                cardID: cardID,
                meta: _MiniCardMetaFile(
                    version: 1,
                    selectionText: sel,
                    localSnippet: arr[idx].localSnippet,
                    lang: arr[idx].promptLang,
                    updatedAt: now
                )
            )
        }

        _saveMiniCardFilesToDisk(page: page, card: arr[idx])
        let records = arr.map { _MiniCardRecord(id: $0.id, rect: $0.rect, createdAt: $0.createdAt) }
        _saveMiniManifestToDisk(page: page, records: records)
    }

    @MainActor
    func _updateMiniCardNote(page: Int, cardID: String, note: Inf6ExtraNote) {
        guard var arr = miniCardsByPage[page] else { return }
        guard let idx = arr.firstIndex(where: { $0.id == cardID }) else { return }

        arr[idx].explanation = note.text
        arr[idx].rtf = note.rtf
        let now = Date().timeIntervalSince1970
        arr[idx].updatedAt = now
        _publishMiniCardsOrDefer(page: page, loaded: arr)

        _saveMiniCardFilesToDisk(page: page, card: arr[idx])
        let records = arr.map { _MiniCardRecord(id: $0.id, rect: $0.rect, createdAt: $0.createdAt) }
        _saveMiniManifestToDisk(page: page, records: records)
    }

    func _miniExtraNoteBinding(page: Int, cardID: String) -> Binding<Inf6ExtraNote> {
        Binding<Inf6ExtraNote>(
            get: {
                guard let card = (miniCardsByPage[page] ?? []).first(where: { $0.id == cardID }) else {
                    let msg = "[InlinePDFPagesView] _miniExtraNoteBinding: missing mini card (page=\(page), id=\(cardID))"
                    print(msg)
                    DispatchQueue.main.async { _ioLastError = msg }
                    return Inf6ExtraNote(text: "⚠︎ missing mini card (page=\(page), id=\(cardID))")
                }
                let stableID = UUID(uuidString: cardID) ?? UUID()
                return Inf6ExtraNote(id: stableID, text: card.explanation, rtf: card.rtf, createdAt: card.createdAt)
            },
            set: { newNote in
                Task { @MainActor in
                    _updateMiniCardNote(page: page, cardID: cardID, note: newNote)
                }
            }
        )
    }

    @MainActor
    func _deleteMiniCard(page: Int, cardID: String) {
        guard var arr = miniCardsByPage[page] else { return }
        arr.removeAll { $0.id == cardID }
        _publishMiniCardsOrDefer(page: page, loaded: arr)

        _deleteMiniCardFiles(page: page, cardID: cardID)
        let records = arr.map { _MiniCardRecord(id: $0.id, rect: $0.rect, createdAt: $0.createdAt) }
        _saveMiniManifestToDisk(page: page, records: records)

        if _miniSelectedCardIDByPage[page] == cardID {
            _miniSelectedCardIDByPage[page] = _sortedMiniCards(page: page).first?.id
        }
    }

    // --- Mini math explanation task management ---

    func _cancelInFlightMathTask(cardID: String) {
        _inFlightMathTaskByCardID[cardID]?.cancel()
        _inFlightMathTaskByCardID[cardID] = nil
    }

    func _cancelAllInFlightMathTasks() {
        for (_, t) in _inFlightMathTaskByCardID {
            t.cancel()
        }
        _inFlightMathTaskByCardID = [:]
    }

    typealias _PlatformImage = UIImage

    // MARK: - Mini PDF image/explanation helpers
    // Render the selected rect on the current page into an image, by drawing a high-res thumbnail and cropping to selection.
    func _miniImageFrom(page: PDFPage, selectionRect: CGRect, displayBox: PDFDisplayBox) -> _PlatformImage? {
        let pageBounds = page.bounds(for: displayBox)
        // Render a 2x thumbnail of the whole page, then crop to selection in image space.
        let scale: CGFloat = 2.0
        let targetSize = CGSize(width: max(1, pageBounds.width * scale), height: max(1, pageBounds.height * scale))

        let fullImg = page.thumbnail(of: targetSize, for: displayBox)
        guard let cg = fullImg.cgImage else { return nil }
        let cw = CGFloat(cg.width), ch = CGFloat(cg.height)
        let sx = selectionRect.origin.x * (cw / pageBounds.width)
        let sw = max(1, selectionRect.width * (cw / pageBounds.width))
        let sh = max(1, selectionRect.height * (ch / pageBounds.height))
        // Flip Y because image origin is top-left, PDF page origin is bottom-left.
        let sy = ch - ((selectionRect.origin.y * (ch / pageBounds.height)) + sh)
        let crop = CGRect(x: round(sx), y: round(sy), width: round(sw), height: round(sh))
        guard let cropped = cg.cropping(to: crop) else { return nil }
        return UIImage(cgImage: cropped, scale: fullImg.scale, orientation: .up)
    }

    func _buildMiniPDFFromCurrentSelection() {
        // Surface failures instead of silently returning.
        func fail(_ message: String) {
            print("[InlinePDFPagesView] _buildMiniPDFFromCurrentSelection: \(message)")
            _miniBuildLastError = message
        }

        guard let v = pdfViewRef else {
            fail("pdfViewRef is nil (PDFView not ready yet)")
            return
        }
        guard let rawSel = v.currentSelection else {
            fail("no currentSelection (select an equation/text on the PDF first)")
            return
        }
        guard let page = v.currentPage else {
            fail("no currentPage (PDFView has no focused page)")
            return
        }

        let displayBox = v.displayBox
        let pageBounds = page.bounds(for: displayBox)

        let rawBounds = rawSel.bounds(for: page)
        guard rawBounds.width > 2, rawBounds.height > 2 else {
            fail("selection bounds too small (w=\(rawBounds.width), h=\(rawBounds.height))")
            return
        }

        // 1) Build a band around the selected line.
        // IMPORTANT: Limit X to the selected column. On 2-column pages, a full-width band
        // can re-select text from both columns and produce a full-width rectangle.
        let padY: CGFloat = 4
        let padX: CGFloat = 10

        let bandMinX = max(pageBounds.minX, rawBounds.minX - padX)
        let bandMaxX = min(pageBounds.maxX, rawBounds.maxX + padX)
        let bandMinY = max(pageBounds.minY, rawBounds.minY - padY)
        let bandMaxY = min(pageBounds.maxY, rawBounds.maxY + padY)

        let band = CGRect(
            x: bandMinX,
            y: bandMinY,
            width: max(1, bandMaxX - bandMinX),
            height: max(1, bandMaxY - bandMinY)
        )

        // 2) Re-select from the band so we can capture the whole line.
        let lineSel = page.selection(for: band) ?? rawSel
        let lineBounds = lineSel.bounds(for: page)
        guard lineBounds.width > 2, lineBounds.height > 2 else {
            fail("line selection bounds too small (w=\(lineBounds.width), h=\(lineBounds.height))")
            return
        }

        // 3) Crop around the line bounds.
        let cropMinX = max(pageBounds.minX, lineBounds.minX - padX)
        let cropMaxX = min(pageBounds.maxX, lineBounds.maxX + padX)
        let cropMinY = max(pageBounds.minY, lineBounds.minY - padY)
        let cropMaxY = min(pageBounds.maxY, lineBounds.maxY + padY)
        let crop = CGRect(
            x: cropMinX,
            y: cropMinY,
            width: max(1, cropMaxX - cropMinX),
            height: max(1, cropMaxY - cropMinY)
        )

        guard let img = _miniImageFrom(page: page, selectionRect: crop, displayBox: displayBox) else {
            fail("failed to render/crop mini image")
            return
        }

        let d = PDFDocument()
        guard let p = PDFPage(image: img) else {
            fail("failed to create PDFPage from image")
            return
        }

        d.insert(p, at: 0)
        // IMPORTANT: bind the card to the actual PDFView currentPage index.
        let idx: Int = {
            // If PDFView's currentPage is available, use its index; otherwise, fallback to selectedPage.wrappedValue.
            if let v = pdfViewRef, let page = v.currentPage, let doc = v.document {
                let pageIdx = doc.index(for: page)
                if pageIdx != NSNotFound && pageIdx >= 0 {
                    return pageIdx
                }
            }
            return selectedPage.wrappedValue
        }()
        // Keep SwiftUI state in sync so the newly created card is visible immediately.
        // Without this, a lagging `selectedPage` can make it look like the card was not created.
        if selectedPage.wrappedValue != idx {
            selectedPage.wrappedValue = idx
        }

        let pw = max(1, pageBounds.width)
        let ph = max(1, pageBounds.height)
        let rect = MiniRect(
            x: Double(crop.origin.x / pw),
            y: Double(crop.origin.y / ph),
            w: Double(crop.width / pw),
            h: Double(crop.height / ph)
        )

        let selectionText = (lineSel.string ?? pdfSelectedText)
        guard let newID = _appendMiniCard(page: idx, doc: d, rect: rect, explanation: "", selectionText: selectionText) else {
            fail("failed to append mini card (doc.dataRepresentation returned nil)")
            return
        }

        _requestMiniMathExplain(selectionText: selectionText, pageIndex: idx, cardID: newID)
    }

    func _requestMiniMathExplain(selectionText: String?, pageIndex: Int, cardID: String) {
        let targetLang = (genLangRaw == "en") ? "en" : "ja"
        let selectionTrimmed = (selectionText ?? "").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let idx = pageIndex


        guard !selectionTrimmed.isEmpty else {
            Task { @MainActor in
                _updateMiniCardExplanation(
                    page: idx,
                    cardID: cardID,
                    explanation: L(
                        "⚠︎ 数式の選択がありません。PDF上で数式を選択してください。",
                        "⚠︎ No math selection. Please select an equation on the PDF."
                    )
                )
            }
            return
        }

        Task { @MainActor in
            _updateMiniCardExplanation(page: idx, cardID: cardID, explanation: L("数式解説を生成中…", "Generating math explanation…"))
        }

        let selectionForPrompt = String(selectionTrimmed.prefix(_maxSelectionPromptChars))

        _cancelInFlightMathTask(cardID: cardID)
        let task = Task {
            defer { Task { @MainActor in _inFlightMathTaskByCardID[cardID] = nil } }

            // Simple timeout helper (kept local to avoid extra surface area)
            // IMPORTANT: Use detached tasks so the timeout still fires even if the caller is on MainActor
            func withTimeout<T>(seconds: Double, _ op: @Sendable @escaping () async throws -> T) async throws -> T {
                let opTask: Task<T, Error> = Task.detached(priority: Task.currentPriority) {
                    try await op()
                }
                let timeoutDescription = (targetLang == "en")
                    ? "Timed out. Please check network/API key settings."
                    : "タイムアウトしました。ネットワーク/キー設定を確認してください。"
                let timeoutTask: Task<T, Error> = Task.detached(priority: Task.currentPriority) {
                    try await Task.sleep(nanoseconds: UInt64(max(0.1, seconds) * 1_000_000_000))
                    throw NSError(domain: "inf6.timeout", code: 408, userInfo: [
                        NSLocalizedDescriptionKey: timeoutDescription
                    ])
                }

                do {
                    let value = try await withThrowingTaskGroup(of: T.self) { group in
                        group.addTask { try await opTask.value }
                        group.addTask { try await timeoutTask.value }
                        guard let first = try await group.next() else { throw CancellationError() }
                        group.cancelAll()
                        return first
                    }
                    opTask.cancel()
                    timeoutTask.cancel()
                    return value
                } catch {
                    opTask.cancel()
                    timeoutTask.cancel()
                    throw error
                }
            }

            do {
                try Task.checkCancellation()

                // PDFKit is not reliably thread-safe; fetch page text on MainActor.
                let pageText: String = await MainActor.run {
                    _pageText(pageIndex: idx, maxChars: _maxPagePromptChars)
                }
                try Task.checkCancellation()

                let local = Inf6LibraryView.snippetAround(pageText, needle: selectionForPrompt, radius: 280)

                let now = Date().timeIntervalSince1970
                _saveMiniCardMetaToDisk(page: idx, cardID: cardID, meta: _MiniCardMetaFile(version: 1, selectionText: selectionForPrompt, localSnippet: local, lang: targetLang, updatedAt: now))

                await MainActor.run {
                    if var arr = miniCardsByPage[idx], let i = arr.firstIndex(where: { $0.id == cardID }) {
                        arr[i].sourceText = selectionForPrompt
                        arr[i].localSnippet = local
                        arr[i].promptLang = targetLang
                        arr[i].updatedAt = now
                        _publishMiniCardsOrDefer(page: idx, loaded: arr)
                    }
                }

                let promptRef = (targetLang == "en")
                    ? Inf6PromptCatalog.mathMiniExplainEn
                    : Inf6PromptCatalog.mathMiniExplainJa
                let rendered = try Inf6PromptGovernance.renderSystemUserPrompt(
                    ref: promptRef,
                    variables: [
                        "selection_equation": selectionForPrompt,
                        "local_snippet": local.isEmpty ? ((targetLang == "en") ? "(no local snippet)" : "(抜粋なし)") : local
                    ]
                )

                // Prevent “stuck at generating…” by bounding the request.
                let ai = try await withTimeout(seconds: 60) {
                    try await Inf6LibraryView.askOpenAIText(
                        systemInstruction: rendered.systemInstruction,
                        userPrompt: rendered.userPrompt,
                        lang: targetLang
                    )
                }
                try Task.checkCancellation()

                let trimmed = ai.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                let capped = (trimmed.count > 8000) ? String(trimmed.prefix(8000)) : trimmed

                await MainActor.run {
                    _updateMiniCardExplanation(page: idx, cardID: cardID, explanation: capped)
                    _scheduleAutoQuizRegeneration()
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    _updateMiniCardExplanation(page: idx, cardID: cardID, explanation: L("⚠︎ エラー: \(error.localizedDescription)", "⚠︎ Error: \(error.localizedDescription)"))
                }
            }
        }
        _inFlightMathTaskByCardID[cardID] = task
    }

    /// Mini-card renderer for a single card.
    ///
    /// IMPORTANT: Do NOT use `PDFView` here.
    /// The mini card content is effectively an image-in-a-PDF (single page) and using `PDFView`
    /// inside the detail pane has been causing hit-test instability and text-selection resets.
    ///
    /// We keep the persisted format (`MiniCard.pdfData`) unchanged; we only change rendering.
    struct _Inf6MiniPDFCardPDFView: View {
        let document: PDFDocument

        private func _thumb(page: PDFPage, size: CGSize) -> UIImage {
            // Use cropBox; mini PDFs are created from a cropped image.
            // Render at 2x to keep text/lines crisp.
            let w = max(1, size.width * 2.0)
            let h = max(1, size.height * 2.0)
            return page.thumbnail(of: CGSize(width: w, height: h), for: .cropBox)
        }

        var body: some View {
            GeometryReader { proxy in
                let size = proxy.size

                if let page = document.page(at: 0) {
                    let img = _thumb(page: page, size: size)
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // No silent fallback: if the PDF has no page, show an explicit placeholder.
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            Text(Inf6Lang.text("⚠︎ ミニPDFのページがありません。", "⚠︎ Mini PDF has no pages."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(8)
                        }
                }
            }
        }
    }
}
