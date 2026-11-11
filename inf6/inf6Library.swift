//
//  Inf6Library.swift
//  inf6
//

import Foundation
import SwiftUI




// MARK: - Editable extra note model (persisted)

public struct Inf6ExtraNote: Codable, Hashable, Identifiable {
    public var id: UUID

    /// Plain text (always present; used for search/export).
    public var text: String

    /// Optional rich text payload (RTF). When present, editors should prefer this for rendering and styling.
    public var rtf: Data?

    public var createdAt: TimeInterval

    /// Optional: distance from top of the PDF page (used to order notes by on-page position).
    /// Smaller value means closer to the top of the page.
    public var anchorYFromTop: Double?

    /// Optional: structured explanation parts used for source-separated rendering.
    public var structuredExplain: Inf6StructuredExplain?

    /// Optional: structured table payload used by the assets pipeline.
    public var structuredTable: Inf6StructuredTable?

    public init(
        id: UUID = UUID(),
        text: String,
        rtf: Data? = nil,
        createdAt: TimeInterval = Date().timeIntervalSince1970,
        anchorYFromTop: Double? = nil,
        structuredExplain: Inf6StructuredExplain? = nil,
        structuredTable: Inf6StructuredTable? = nil
    ) {
        self.id = id
        self.text = text
        self.rtf = rtf
        self.createdAt = createdAt
        self.anchorYFromTop = anchorYFromTop
        self.structuredExplain = structuredExplain
        self.structuredTable = structuredTable
    }
}

public struct Inf6StructuredExplain: Codable, Hashable {
    public var answer: String
    public var paperEvidence: String
    public var webEvidence: String
    public var webSources: String

    public init(
        answer: String,
        paperEvidence: String,
        webEvidence: String,
        webSources: String
    ) {
        self.answer = answer
        self.paperEvidence = paperEvidence
        self.webEvidence = webEvidence
        self.webSources = webSources
    }
}

public struct Inf6StructuredTableMeaning: Codable, Hashable, Identifiable {
    public var id: String { label + "|" + meaning }
    public var label: String
    public var meaning: String

    public init(label: String, meaning: String) {
        self.label = label
        self.meaning = meaning
    }
}

public enum Inf6StructuredTableOptimization: String, Codable, Hashable {
    case max
    case min
    case none
}

public struct Inf6StructuredTableColumnDescriptor: Codable, Hashable, Identifiable {
    public var id: String { key }
    public var key: String
    public var labelEN: String
    public var labelJA: String
    public var explanationEN: String
    public var explanationJA: String
    public var optimization: Inf6StructuredTableOptimization

    public init(
        key: String,
        labelEN: String,
        labelJA: String,
        explanationEN: String,
        explanationJA: String,
        optimization: Inf6StructuredTableOptimization = .none
    ) {
        self.key = key
        self.labelEN = labelEN
        self.labelJA = labelJA
        self.explanationEN = explanationEN
        self.explanationJA = explanationJA
        self.optimization = optimization
    }

    // Backward-compat decoding: older saved JSON has no `optimization` field.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try c.decode(String.self, forKey: .key)
        self.labelEN = try c.decode(String.self, forKey: .labelEN)
        self.labelJA = try c.decode(String.self, forKey: .labelJA)
        self.explanationEN = try c.decode(String.self, forKey: .explanationEN)
        self.explanationJA = try c.decode(String.self, forKey: .explanationJA)
        self.optimization = (try? c.decode(Inf6StructuredTableOptimization.self, forKey: .optimization)) ?? .none
    }

    private enum CodingKeys: String, CodingKey {
        case key, labelEN, labelJA, explanationEN, explanationJA, optimization
    }
}

public struct Inf6StructuredTableRow: Codable, Hashable, Identifiable {
    public var id: String { label + "|" + values.joined(separator: "|") }
    public var label: String
    public var values: [String]

    public init(label: String, values: [String]) {
        self.label = label
        self.values = values
    }
}

public struct Inf6StructuredTableRowDescriptor: Codable, Hashable, Identifiable {
    public var id: String { key }
    public var key: String
    public var labelEN: String
    public var labelJA: String
    public var explanationEN: String
    public var explanationJA: String
    public var values: [String]

    public init(
        key: String,
        labelEN: String,
        labelJA: String,
        explanationEN: String,
        explanationJA: String,
        values: [String]
    ) {
        self.key = key
        self.labelEN = labelEN
        self.labelJA = labelJA
        self.explanationEN = explanationEN
        self.explanationJA = explanationJA
        self.values = values
    }
}

public struct Inf6StructuredTable: Codable, Hashable {
    public var title: String
    public var columns: [String]
    public var rows: [Inf6StructuredTableRow]
    public var columnMeanings: [Inf6StructuredTableMeaning]
    public var rowMeanings: [Inf6StructuredTableMeaning]
    public var structuredColumns: [Inf6StructuredTableColumnDescriptor]?
    public var structuredRows: [Inf6StructuredTableRowDescriptor]?
    /// 図・表の見方のポイント（英語）。GPT が生成する reading guide。
    public var readingPointsEN: [String]?
    /// 図・表の見方のポイント（日本語）。GPT が生成する reading guide。
    public var readingPointsJA: [String]?

    public init(
        title: String,
        columns: [String],
        rows: [Inf6StructuredTableRow],
        columnMeanings: [Inf6StructuredTableMeaning],
        rowMeanings: [Inf6StructuredTableMeaning],
        structuredColumns: [Inf6StructuredTableColumnDescriptor]? = nil,
        structuredRows: [Inf6StructuredTableRowDescriptor]? = nil,
        readingPointsEN: [String]? = nil,
        readingPointsJA: [String]? = nil
    ) {
        self.title = title
        self.columns = columns
        self.rows = rows
        self.columnMeanings = columnMeanings
        self.rowMeanings = rowMeanings
        self.structuredColumns = structuredColumns
        self.structuredRows = structuredRows
        self.readingPointsEN = readingPointsEN
        self.readingPointsJA = readingPointsJA
    }
}


#if canImport(UIKit)
import UIKit
#endif









//#if canImport(PDFKit)
#if canImport(PDFKit)
import PDFKit
#endif

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif


import Security

#if canImport(OSLog)
import OSLog
 let _mathLog = Logger(subsystem: "com.inf6.inf6", category: "MathJax")
 let _fxLog = Logger(subsystem: "com.inf6.inf6", category: "FormulaPDF")
 let _cacheLog = Logger(subsystem: "com.inf6.inf6", category: "PDFCache")
#endif



// MARK: - Debounce helper (file-scope)
// Use a reference-type box stored in @State, and mutate its internal work item.
final class _Inf6DebounceBox {
    var workItem: DispatchWorkItem? = nil

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        workItem?.cancel()
        let item = DispatchWorkItem(block: action)
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

#if canImport(UIKit)



// MARK: - Inf6LibraryView implementation (split into extensions)

extension Inf6LibraryView {

    // MARK: - Localization glue

    @inline(__always)
     func L(_ ja: String, _ en: String) -> String {
        switch genLangRaw {
        case "ja":
            return ja
        case "en":
            return en
        default:
            // auto: follow current locale
            let lang = Locale.current.language.languageCode?.identifier ?? ""
            return (lang == "ja") ? ja : en
        }
    }

     var uiLocale: Locale {
        switch genLangRaw {
        case "ja": return Locale(identifier: "ja")
        case "en": return Locale(identifier: "en")
        default: return Locale.current
        }
    }

     var isIOSAppOnMac: Bool {
        ProcessInfo.processInfo.isiOSAppOnMac
    }

    static func normalizeSpaces(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func snippetAround(_ text: String, needle: String, radius: Int) -> String {
        let base = Self.normalizeSpaces(text)
        let key = Self.normalizeSpaces(String(needle.prefix(80)))
        guard !base.isEmpty, !key.isEmpty else { return "" }

        if let r = base.range(of: key, options: .caseInsensitive) {
            let pre = base.distance(from: base.startIndex, to: r.lowerBound)
            let suf = base.distance(from: r.upperBound, to: base.endIndex)
            let start = base.index(r.lowerBound, offsetBy: -min(radius, pre))
            let end = base.index(r.upperBound, offsetBy: min(radius, suf))
            return String(base[start..<end])
        }

        return String(base.prefix(max(0, min(base.count, 2 * radius))))
    }
}



#endif

// MARK: - Shared root folder persistence (single source of truth)

extension Inf6LibraryView {

    // MARK: Security-scoped access helper (iOS Files / iCloud Drive)

    @inline(__always)
    static func _withSecurityScopedAccess<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        #if canImport(UIKit)
        // Some File Provider / iCloud Drive URLs require a per-file security scope.
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        #endif
        return try body()
    }


    /// Per-PDF identifier used for on-disk filenames.
    static func _pdfContentKey16(for pdfURL: URL) -> String {
        // Policy: do NOT hash; always use the original PDF base name (no extension).
        // Also sanitize characters that can break File Provider / cross-platform paths.
        let raw = pdfURL.deletingPathExtension().lastPathComponent
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "untitled" : trimmed
        // Remove/replace path separators and a few problematic characters.
        let illegal = CharacterSet(charactersIn: "/\\:\n\r\t")
        let cleaned = base.components(separatedBy: illegal).joined(separator: "_")
        return cleaned.isEmpty ? "untitled" : cleaned
    }

    // MARK: - File Provider safe I/O (coordinated)

    /// Read file contents via NSFileCoordinator (more reliable with iCloud Drive / File Provider).
    static func _readDataCoordinated(from url: URL) -> Data? {
        var data: Data? = nil
        var coordError: NSError? = nil
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            data = Inf6SafeFileRead.dataIfReadable(at: readURL)
        }
        #if canImport(OSLog)
        if let coordError {
            _cacheLog.debug("_readDataCoordinated: coordError=\(String(describing: coordError), privacy: .public) url=\(url.path, privacy: .public)")
        }
        #endif
        return data
    }

    /// Write file contents via NSFileCoordinator (more reliable with iCloud Drive / File Provider).
    /// IMPORTANT: `.forReplacing` can fail when the target does not exist yet (common on iCloud Drive/File Provider).
    /// We choose options based on existence, and ensure parent directories exist.
    static func _writeDataCoordinated(_ data: Data, to url: URL) throws {
        let fm = FileManager.default

        let parent = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        let exists = fm.fileExists(atPath: url.path)

        var coordError: NSError? = nil
        var writeError: Error? = nil
        let coordinator = NSFileCoordinator()

        // Use `.forReplacing` only when replacing an existing item.
        // For a brand-new file, use empty options so File Provider can create it.
        let opts: NSFileCoordinator.WritingOptions = exists ? [.forReplacing] : []

        coordinator.coordinate(writingItemAt: url, options: opts, error: &coordError) { writeURL in
            do {
                try data.write(to: writeURL, options: [])
            } catch {
                writeError = error
                #if canImport(OSLog)
                _cacheLog.error("_writeDataCoordinated: write failed: \(String(describing: error), privacy: .public) url=\(writeURL.path, privacy: .public)")
                #endif
            }
        }

        #if canImport(OSLog)
        if let coordError {
            _cacheLog.error("_writeDataCoordinated: coordError=\(String(describing: coordError), privacy: .public) url=\(url.path, privacy: .public)")
        }
        #endif
        if let coordError {
            throw coordError
        }
        if let writeError {
            throw writeError
        }
    }

  

    #if canImport(PDFKit)
    static func extractFullPageText(from url: URL, pageIndex: Int, maxChars: Int) -> String {
        // Ensure we can read Files/iCloud Drive URLs on iOS (security-scoped).
        return _withSecurityScopedAccess(url) {
            func extract(from doc: PDFDocument) -> String {
                guard pageIndex >= 0,
                      pageIndex < doc.pageCount,
                      let page = doc.page(at: pageIndex) else {
                    return ""
                }
                let raw = page.string ?? ""
                // Keep original line breaks for formula detection; only trim length if requested.
                return (maxChars > 0) ? String(raw.prefix(maxChars)) : raw
            }

            // (1) Fast path: open directly by URL.
            if let doc = PDFDocument(url: url), doc.pageCount > 0 {
                return extract(from: doc)
            }

            return ""
        }
    }
    #endif


    // MARK: Picker initial directory (iOS only)

    /// Configure the initial directory for UIDocumentPickerViewController.
    /// Policy: only seed to the user-selected shared root folder. No other fallbacks.
    static func seedInitialDirectory(_ picker: UIDocumentPickerViewController) throws {
        if #available(iOS 13.0, *) {
            let root = try _sharedRootDir()
            picker.directoryURL = root
        }
    }

    // MARK: Per-PDF cache on disk (iOS only; uses Inf6LibraryView state)

    /// Base directory for per‑PDF caches.
    /// Always lives under the single shared root directory resolved by `_sharedRootDir()`.
    /// This keeps cache layout aligned with the main PDF library.
    static func _pdfCacheBaseDir() throws -> URL {
        let root = try _sharedRootDir()

        // Ensure we can read/write under the user-selected folder.
        let accessed = root.startAccessingSecurityScopedResource()
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }

        #if canImport(UIKit)
        if accessed == false {
            let readable = FileManager.default.isReadableFile(atPath: root.path)
            if !readable {
                throw NSError(
                    domain: "Inf6LibraryView",
                    code: 1002,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Failed to access shared root folder: \(root.path)"
                    ]
                )
            }
        }
        #endif

        let fm = FileManager.default
        let dir = root.appendingPathComponent("inf6_pdf_details", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                #if canImport(OSLog)
                _cacheLog.error("_pdfCacheBaseDir: createDirectory failed: \(String(describing: error), privacy: .public)")
                #endif
                throw error
            }
        }
        return dir
    }

    /// Base directory for Microsoft qualification knowledge PDFs.
    /// Layout: sharedRoot / microsoft / knowledge_pdfs / <qualification-id> /
    static func _microsoftKnowledgePDFDirectory(qualificationID: String) throws -> URL {
        let root = try _sharedRootDir()
        let trimmedID = qualificationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw NSError(domain: "Inf6LibraryView", code: 1003, userInfo: [NSLocalizedDescriptionKey: "Qualification ID is empty."])
        }
        let safeID = String(trimmedID.map { ch -> Character in
            (ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == ".") ? ch : "_"
        })
        let fm = FileManager.default
        var dir = root
        for component in ["microsoft", "knowledge_pdfs", safeID] {
            dir = dir.appendingPathComponent(component, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.path, isDirectory: &isDir) {
                guard isDir.boolValue else {
                    throw NSError(domain: "Inf6LibraryView", code: 1004, userInfo: [NSLocalizedDescriptionKey: "Expected directory but found file: \(dir.path)"])
                }
            } else {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
        return dir
    }

    /// Returns the JSON cache file URL for a given PDF cache key.
    /// Stored under the shared root's `inf6_pdf_details/` directory.
    static func _pdfCacheFileURL(cacheKey: String) throws -> URL {
        let base = try _pdfCacheBaseDir()
        let raw = cacheKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // Sanitize: never allow path separators or control characters inside the filename.
        let illegal = CharacterSet(charactersIn: "/\\:\n\r\t")
        let cleaned = raw.components(separatedBy: illegal).joined(separator: "_")
        let safeKey = cleaned.isEmpty ? "untitled" : cleaned

        let name = safeKey + ".json"  // e.g. "paper.json"
        return base.appendingPathComponent(name)
    }

    static func _pdfFileNameCacheKey(for pdfURL: URL) -> String {
        let raw = pdfURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "untitled.pdf" : raw
    }


    @MainActor
    func restoreCurrentPDFCache() throws {
        guard let u = fullPDFURL else { return }
        let key: String
        if let k = currentPDFCacheKey, !k.isEmpty {
            key = k
        } else {
            let k = Self._pdfFileNameCacheKey(for: u)
            currentPDFCacheKey = k
            key = k
        }
        let file = try Self._pdfCacheFileURL(cacheKey: key)

        // Ensure read access under the user-selected root.
        let root = try Self._sharedRootDir()
        let accessed = root.startAccessingSecurityScopedResource()
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }

        // Missing cache is normal; stay silent.
        guard FileManager.default.fileExists(atPath: file.path) else { return }

        guard let data = Self._readDataCoordinated(from: file) else {
            #if canImport(OSLog)
            _cacheLog.error("restoreCurrentPDFCache: cache exists but read failed. file=\(file.path, privacy: .public)")
            #endif
            return
        }

        struct Payload: Codable {
            var explanationByPage: [Int: String]
            var extraNotesByPage: [Int: [Inf6ExtraNote]]
            /// Optional for backward compatibility with older cache files.
            var paperAbstract: String?
        }

        if let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            pageExplanationCache = payload.explanationByPage
            pageExtraNotes = payload.extraNotesByPage
            // Policy: keep the abstract inside the JSON only (no extra files/folders).
            paperAbstract = payload.paperAbstract ?? ""

            // When opening a PDF, show the last generated abstract by default (without clobbering an existing view state).
            if fullPDFExplanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !paperAbstract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fullPDFExplanation = paperAbstract
            }
        }
    }

    @MainActor
    func persistCurrentPDFCache() throws {
        guard let u = fullPDFURL else { return }
        let key: String
        if let k = currentPDFCacheKey, !k.isEmpty {
            key = k
        } else {
            let k = Self._pdfFileNameCacheKey(for: u)
            currentPDFCacheKey = k
            key = k
        }
        let file = try Self._pdfCacheFileURL(cacheKey: key)

        struct Payload: Codable {
            var explanationByPage: [Int: String]
            var extraNotesByPage: [Int: [Inf6ExtraNote]]
            var paperAbstract: String?
        }

        let payload = Payload(
            explanationByPage: pageExplanationCache,
            extraNotesByPage: pageExtraNotes,
            paperAbstract: paperAbstract
        )

        guard let data = try? JSONEncoder().encode(payload) else {
            #if canImport(OSLog)
            _cacheLog.error("persistCurrentPDFCache: JSON encode failed")
            #endif
            return
        }

        // Ensure write access under the user-selected root.
        let root = try Self._sharedRootDir()
        let accessed = root.startAccessingSecurityScopedResource()
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }

        try Self._writeDataCoordinated(data, to: file)
        #if canImport(OSLog)
        _cacheLog.debug("persistCurrentPDFCache: wrote cache. file=\(file.path, privacy: .public)")
        #endif
    }

    // MARK: PDF Import Helper (iOS only)
    @MainActor
    func importPickedPDFsIntoLibrary(_ urls: [URL]) async throws {
        let picked = urls
        guard !picked.isEmpty else { return }

        let root = try Self._sharedRootDir()
        let accessedRoot = root.startAccessingSecurityScopedResource()
        defer { if accessedRoot { root.stopAccessingSecurityScopedResource() } }

        for src in picked {
            let accessed = src.startAccessingSecurityScopedResource()
            defer { if accessed { src.stopAccessingSecurityScopedResource() } }

            try Self._persistPDFReferenceMetadata(for: src)
        }

        if let openURL = picked.first {
            fullPDFURL = openURL
            currentPDFCacheKey = Self._pdfFileNameCacheKey(for: openURL)
            _addToRecently(openURL)
            refreshPaperLibraryItems(surfacingError: false)

            fullPDFExplanation = ""
            paperAbstract = ""
            isShowingPaperAbstract = false
            isGeneratingExplanation = false
            isExplanationPaneVisible = true

            pageExplanationCache.removeAll(keepingCapacity: true)
            pageExtraNotes.removeAll(keepingCapacity: true)
            lastExplainedPageIndex = nil

            formulaMiniPDFsByPage.removeAll(keepingCapacity: true)
            isFormulaMiniPaneVisible = true
            formulaSelectionText = ""
            formulaSelectionPageIndex = nil
            formulaSelectionAnchorYFromTop = nil

            try restoreCurrentPDFCache()
            restoreNotesDictFromDisk()
            restorePageExplanationCacheFromDisk()
            assetsPipelineRunState = inf6LoadAssetsPipelineRunState(pdfURL: openURL)
            refreshPaperLibraryItems(surfacingError: false)
        }
    }

    private static func _persistPDFReferenceMetadata(for url: URL) throws {
        try Inf6PDFReferenceStore.put(url: url)
    }

    private static func _uniqueDestinationURL(in dir: URL, fileName: String) -> URL {
        let fm = FileManager.default
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension

        var candidate = dir.appendingPathComponent(fileName)
        if !fm.fileExists(atPath: candidate.path) { return candidate }

        // Avoid overwriting: append a counter.
        var i = 2
        while true {
            let name = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }


    // --- PATCH: Alert for extraNotes page index mismatch ---
    // Title:
    // "追加解説: ページ番号の整合性エラー"
    // Body:
    /*
    追加解説（extraNotes）のページキーと、現在表示中PDFのページインデックスが一致していません。

    現在のページ index: \(pageIndex)
    保存済みキー: \(keys)

    想定される原因:
    - 0始まり／1始まりの基準差（PDFKitは0始まり）
    - PDF差し替え等により、既存の追加解説が別ページを指している

    対応:
    - 追加解説のキーを「PDFDocumentのindex(for:)（0始まり）」に統一してください。
    - 上記が満たせない場合、このPDFの追加解説は整合性が取れていないため再生成が必要です。
    */

    @MainActor
    func persistNotesDictToDisk() throws {
        try persistCurrentPDFCache()
    }
    
    
    /// Returns true if the given folder is an allowed shared root.
    static func _isAllowedRootFolder(_ url: URL) -> Bool {
        let std = url.standardizedFileURL
        let path = std.path

        // Reject the known-bad File Provider staging area.
        if path.contains("File Provider Storage/out") { return false }
        if path.contains("/Library/Mobile Documents/")
            || path.contains("/Library/Mobile%20Documents/")
            || path.contains("com~apple~CloudDocs") {
            return false
        }

        // If we can determine it is a directory, require it.
        if let values = try? std.resourceValues(forKeys: [.isDirectoryKey]),
           let isDir = values.isDirectory,
           isDir == false {
            return false
        }
        return true
    }

    /// Decode the user-selected root folder, if any.
    static func _userRootFolderURL() -> URL? {
        Inf6EntityImageLocation.resolvedURL()
    }

    /// Store the user-selected root folder (bookmark).
    static func _storeUserRootFolderURL(_ folder: URL) throws {
        try Inf6EntityImageLocation.set(folder.standardizedFileURL)
    }

    /// Local base root for all user-visible inf6 assets.
    /// Older call sites still use the shared-root name, but the returned URL is the local storage root.
    static func _sharedRootDir() throws -> URL {
        let fm = FileManager.default
        let root = Inf6DataRoot.url().standardizedFileURL

        if !fm.fileExists(atPath: root.path) {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    static func _hasRootFolderPreference() -> Bool {
        return _userRootFolderURL() != nil
    }
}


// MARK: - Rich-text note editor views are in Inf6RichTextNoteViews.swift
// (Keep this file focused on PDF pane + split-view logic.)
// MARK: - Rich-text note editor views are in Inf6RichTextNoteViews.swift
// (Keep this file focused on PDF pane + split-view logic.)

    
 
#if os(iOS)
struct PDFPaneRepresentable: UIViewRepresentable {
    let url: URL
    let document: PDFDocument?
    let onTap: (Int, String, String) -> Void
    var selectedPage: Binding<Int>
    @Binding var zoom: CGFloat
    @Binding var selectionText: String
    var onPDFViewReady: ((PDFView) -> Void)? = nil

    // Ensure iPad‑on‑Mac (iOS app on macOS) exposes scroll indicators.
    // PDFView hosts an internal UIScrollView; find and configure it.
    private func _collectScrollViews(from root: UIView) -> [UIScrollView] {
        var out: [UIScrollView] = []
        if let sv = root as? UIScrollView { out.append(sv) }
        for sub in root.subviews {
            out.append(contentsOf: _collectScrollViews(from: sub))
        }
        return out
    }

    private func _ensureScrollIndicators(_ pdfView: PDFView) {
        let scrollViews = _collectScrollViews(from: pdfView)
        for sv in scrollViews {
            sv.showsHorizontalScrollIndicator = true
            sv.showsVerticalScrollIndicator = true
            sv.alwaysBounceHorizontal = true
            sv.alwaysBounceVertical = true
            if #available(iOS 13.0, *) {
                sv.automaticallyAdjustsScrollIndicatorInsets = false
            }
            // Make indicators appear at least once so users notice them.
            sv.flashScrollIndicators()
        }
    }

    private func _fitWidthScale(_ pdfView: PDFView) -> CGFloat {
        guard let page = (pdfView.currentPage ?? pdfView.document?.page(at: 0)) else {
            return pdfView.scaleFactorForSizeToFit
        }
        let pageBounds = page.bounds(for: pdfView.displayBox)
        let viewW = max(1, pdfView.bounds.width)
        // Keep a small gutter so the page doesn't touch edges/scrollbars.
        let gutter: CGFloat = 24
        return max(0.05, (viewW - gutter) / max(1, pageBounds.width))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self, zoomBinding: $zoom) }

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = false
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        // NOTE: PageViewController mode forces page-by-page behavior and can make continuous scrolling feel like “only the first page”.
        v.usePageViewController(false)
        v.backgroundColor = .clear

        if let doc = document {
            v.document = doc
        }

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        v.addGestureRecognizer(tap)

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: v
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.selectionChanged(_:)),
            name: .PDFViewSelectionChanged,
            object: v
        )

        context.coordinator.pdfView = v

        // Avoid PDFKit hit-test warnings by touching scroll indicators only after the view is in a window.
        DispatchQueue.main.async { [weak v] in
            guard let v, v.window != nil else { return }
            self._ensureScrollIndicators(v)
        }

        onPDFViewReady?(v)
        return v
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        if pdfView.window != nil {
            _ensureScrollIndicators(pdfView)
        }
        if let doc = document, pdfView.document !== doc {
            pdfView.document = doc
        }

        if let doc = pdfView.document, doc.pageCount > 0 {
            let targetIdx = min(max(0, selectedPage.wrappedValue), max(0, doc.pageCount - 1))
            if let targetPage = doc.page(at: targetIdx), pdfView.currentPage != targetPage {
                pdfView.go(to: targetPage)
            }
        }

        // Ensure layout has happened; otherwise bounds can be ~0 and we would lock the scaleFactor to a tiny value.
        pdfView.layoutIfNeeded()

        let z = max(0.5, min(zoom, 5.0))
        let viewWNow = pdfView.bounds.width

        // If the view width is not yet stable, defer scaling.
        if viewWNow < 200 {
            let coordinator = context.coordinator
            DispatchQueue.main.async { [weak pdfView] in
                guard let pdfView = pdfView else { return }
                let viewW = pdfView.bounds.width
                guard viewW >= 200 else { return }

                let fit = self._fitWidthScale(pdfView)
                let target = z * fit
                if abs(pdfView.scaleFactor - target) > 0.01 {
                    coordinator.isProgrammaticScaleChange = true
                    pdfView.scaleFactor = target
                    coordinator.isProgrammaticScaleChange = false
                    coordinator.lastAppliedZoom = z
                    coordinator.lastAppliedViewWidth = viewW
                }
            }
            return
        }

        // Only rescale when the logical zoom value or the view width has changed.
        let needsRescale: Bool = {
            if context.coordinator.lastAppliedZoom < 0 { return true }
            if abs(z - context.coordinator.lastAppliedZoom) > 0.001 { return true }
            if abs(viewWNow - context.coordinator.lastAppliedViewWidth) > 0.5 { return true }
            return false
        }()

        guard needsRescale else { return }

        let fit = _fitWidthScale(pdfView)
        let target = z * fit
        if abs(pdfView.scaleFactor - target) > 0.01 {
            context.coordinator.isProgrammaticScaleChange = true
            pdfView.scaleFactor = target
            context.coordinator.isProgrammaticScaleChange = false
            context.coordinator.lastAppliedZoom = z
            context.coordinator.lastAppliedViewWidth = viewWNow
        }
    }

    final class Coordinator: NSObject {
        var parent: PDFPaneRepresentable
        var zoomBinding: Binding<CGFloat>
        private var scaleObservation: NSKeyValueObservation? = nil
        var lastAppliedZoom: CGFloat = -1
        var lastAppliedViewWidth: CGFloat = 0
        weak var pdfView: PDFView? = nil {
            didSet {
                if pdfView !== oldValue {
                    scaleObservation?.invalidate()
                    lastAppliedZoom = -1
                    lastAppliedViewWidth = 0
                    guard let v = pdfView else { return }
                    // Observe scaleFactor so pinch-zoom updates our SwiftUI zoom state.
                    scaleObservation = v.observe(\.scaleFactor, options: [.new]) { [weak self] view, change in
                        guard let self = self, let newScale = change.newValue else { return }
                        if self.isProgrammaticScaleChange { return }
                        let fit = self._fitWidthScale(view)
                        guard fit > 0 else { return }
                        let raw = newScale / fit
                        let clamped = max(0.5, min(raw, 5.0))
                        // Avoid tiny oscillations.
                        if abs(self.zoomBinding.wrappedValue - clamped) > 0.01 {
                            DispatchQueue.main.async {
                                self.zoomBinding.wrappedValue = clamped
                            }
                        }
                    }
                }
            }
        }
        private func _fitWidthScale(_ pdfView: PDFView) -> CGFloat {
            guard let page = (pdfView.currentPage ?? pdfView.document?.page(at: 0)) else {
                return pdfView.scaleFactorForSizeToFit
            }
            let pageBounds = page.bounds(for: pdfView.displayBox)
            let viewW = max(1, pdfView.bounds.width)
            let gutter: CGFloat = 24
            return max(0.05, (viewW - gutter) / max(1, pageBounds.width))
        }
        var lastURL: URL
        var isProgrammaticScaleChange: Bool = false

        init(_ parent: PDFPaneRepresentable, zoomBinding: Binding<CGFloat>) {
            self.parent = parent
            self.zoomBinding = zoomBinding
            self.lastURL = parent.url
        }

        @objc func pageChanged(_ note: Notification) {
            guard let v = pdfView, let doc = v.document, let page = v.currentPage else { return }
            let idx = doc.index(for: page)
            if idx >= 0 && idx != parent.selectedPage.wrappedValue {
                parent.selectedPage.wrappedValue = idx
            }
        }

        @objc func selectionChanged(_ note: Notification) {
            guard let v = pdfView else { return }
            let sel = v.currentSelection?.string?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
            if sel != parent.selectionText {
                parent.selectionText = sel
            }
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let v = pdfView, let doc = v.document, let page = v.currentPage else { return }
            let idx = max(0, doc.index(for: page))
            let sel = v.currentSelection?.string?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
            if !sel.isEmpty {
                parent.selectionText = sel
                parent.onTap(idx, sel, "selection")
            } else {
                parent.onTap(idx, "", "page")
            }
        }

        deinit {
            scaleObservation?.invalidate()
            if let v = pdfView {
                NotificationCenter.default.removeObserver(self, name: .PDFViewPageChanged, object: v)
                NotificationCenter.default.removeObserver(self, name: .PDFViewSelectionChanged, object: v)
            } else {
                NotificationCenter.default.removeObserver(self)
            }
        }
    }
}
 #elseif os(macOS)

#endif
