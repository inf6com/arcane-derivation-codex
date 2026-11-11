//
//  inf6SyllabusDetailView0.swift
//  inf6
//
//  Created by decopin on 2026/02/23.
//

import Foundation
import SwiftUI

#if canImport(WebKit)
import WebKit
#endif

import Foundation
import SwiftUI
import CoreText
import UniformTypeIdentifiers

import Security
import Dispatch



// ============================================================================
// MARK: - TOP (Shared helpers / models)
// 目的: 後で別ファイルへ切り出す対象を「上側」に寄せる
// ============================================================================

// MARK: - Shared User Setting Root paths + JSON cache helpers
enum Inf6UserSettingRootPaths {
    static func userSettingRootDirectory(create: Bool = true) throws -> URL {
        let root = Inf6DataRoot.url()
        if create {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    static func inf6Directory(_ components: [String], createIfNeeded: Bool = true) throws -> URL {
        let base = try userSettingRootDirectory(create: createIfNeeded)
        var dir = base
        for c in components {
            dir = dir.appendingPathComponent(c, isDirectory: true)
        }
        if createIfNeeded {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func cacheFileURL(_ name: String, ext: String = "json") throws -> URL {
        let dir = try inf6Directory(["cache"], createIfNeeded: true)
        return dir.appendingPathComponent(name).appendingPathExtension(ext)
    }

    static func userDataFileURL(_ name: String, ext: String = "json") throws -> URL {
        let dir = try inf6Directory(["user_data"], createIfNeeded: true)
        return dir.appendingPathComponent(name).appendingPathExtension(ext)
    }
}

enum Inf6DiskJSON {
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(type, from: data)
        } catch {
            return nil
        }
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: [.atomic])
    }
}

enum Inf6DiskData {
    static func load(from url: URL) throws -> Data {
        return try Data(contentsOf: url)
    }

    static func save(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }
}

// MARK: - Shared URL heuristics (split out of the View for later file separation)
func inf6URLLooksLikePDF(_ u: URL) -> Bool {
    // Fast heuristics to keep likely-PDF candidates even when keywords are absent.
    if u.pathExtension.localizedLowercase == "pdf" { return true }
    let raw = u.absoluteString
    let dec = raw.removingPercentEncoding ?? raw
    let hay = (raw + "\n" + dec).localizedLowercase
    if hay.contains(".pdf") { return true }
    // Common WordPress media patterns
    if hay.contains("/wp-content/") && (hay.contains("uploads") || hay.contains("pdf")) { return true }
    if hay.contains("attachment") && hay.contains("pdf") { return true }
    if hay.contains("download") && hay.contains("pdf") { return true }
    return false
}

func inf6URLMatchesDiscoveryKeywords(_ u: URL, keywords: [String]) -> Bool {
    let raw = u.absoluteString
    let decoded = u.absoluteString.removingPercentEncoding ?? raw
    let hay = (decoded + "\n" + raw).localizedLowercase
    for k in keywords {
        if hay.contains(k.localizedLowercase) { return true }
    }
    return false
}

func inf6DiscoverReachablePDFURLsScoped(
    builder: Inf6SyllabusPipelineBuilder,
    officialURL: URL,
    scopeKeywords: [String],
    keywords: [String],
    timeout: TimeInterval,
    maxConcurrency: Int
) async -> [URL] {
    let urls = await builder.discoverReachablePDFURLsFromOfficialSite(
        officialURL: officialURL,
        timeout: timeout,
        maxConcurrency: maxConcurrency
    )
    guard !scopeKeywords.isEmpty else { return urls }

    // IMPORTANT:
    // Some sites (e.g., WordPress) use non-descriptive PDF URLs that do not contain keywords.
    // Therefore, treat keyword filtering as a *soft* narrowing: if it would remove everything,
    // keep the original result.
    let narrowed = urls.filter { u in
        let raw = u.absoluteString
        let decoded = raw.removingPercentEncoding ?? raw
        let hay = (decoded + "\n" + raw).localizedLowercase
        for k in scopeKeywords {
            if hay.contains(k.localizedLowercase) { return true }
        }
        // Keep likely-PDF candidates even when keywords are absent.
        return inf6URLLooksLikePDF(u)
    }
    return narrowed.isEmpty ? urls : narrowed
}

#if canImport(PDFKit)
import PDFKit
#endif

#if canImport(UIKit)
import UIKit
#endif

#if canImport(QuickLook)
import QuickLook
#endif

struct Inf6SyllabusPDFItem: Identifiable, Hashable {
    let id = UUID()
    let sourceURL: URL
    let localURL: URL
    let title: String
    let pageCount: Int
}

struct Inf6PaperCandidate: Identifiable, Hashable {
    /// Stable id (prefer arXiv id without version)
    let id: String
    let title: String
    let authors: [String]
    let summary: String
    let absURL: URL?
    let pdfURL: URL?
}

struct Inf6MicrosoftLearnFetchedSource: Codable, Hashable {
    let id: String
    let topic: String
    let title: String
    let requestedURL: String
    let finalURL: String
    let roleHint: Inf6MicrosoftLearnSourceRole
    let resolvedRole: Inf6MicrosoftLearnSourceRole
    let httpStatus: Int
    let checkedAt: String
    let lastUpdated: String?
    let evidence: [String]
    let excerpt: String
}

struct Inf6MicrosoftLearnSourcesSidecar: Codable {
    let qualificationID: String
    let qualificationTitle: String
    let checkedAt: String
    let sources: [Inf6MicrosoftLearnFetchedSource]
}

struct _OpenAIChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
    }
    let choices: [Choice]
}

actor _Inf6OpenAIRateLimiter {
    var lastRequestUptimeNs: UInt64 = 0

    /// Ensures a minimum interval between OpenAI requests to reduce 429 / throttling.
    /// - Important: This never swallows failures; it only delays before a request.
    func wait(minIntervalSeconds: TimeInterval) async throws {
        let now = DispatchTime.now().uptimeNanoseconds
        let minNs = UInt64(max(0, minIntervalSeconds) * 1_000_000_000)

        if lastRequestUptimeNs != 0, now > lastRequestUptimeNs {
            let elapsed = now - lastRequestUptimeNs
            if elapsed < minNs {
                try await Task.sleep(nanoseconds: minNs - elapsed)
            }
        }

        lastRequestUptimeNs = DispatchTime.now().uptimeNanoseconds
    }
}

let _inf6OpenAIRateLimiter = _Inf6OpenAIRateLimiter()

// MARK: - File export helper (generated PDF)
struct Inf6ExportDocument: FileDocument {
    // Explicitly declare both readable + writable types.
    // fileExporter requires the requested contentType to be writable.
    static var readableContentTypes: [UTType] { [.pdf] }
    static var writableContentTypes: [UTType] { [.pdf] }

    let url: URL

    init(url: URL) {
        self.url = url
    }

    init(configuration: ReadConfiguration) throws {
        // Implement a real reader so the type never fails protocol-level instantiation.
        // Any failure must surface.
        guard let data = configuration.file.regularFileContents, !data.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inf6_export", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tmp = dir
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        try data.write(to: tmp, options: [.atomic])

        self.url = tmp
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard url.isFileURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return FileWrapper(regularFileWithContents: data)
    }
}

// ============================================================================
// MARK: - BOTTOM (Inf6SyllabusDetailView)
// 目的: View 本体とパイプラインを「下側」に集約する
// ============================================================================
// MARK: - Syllabus detail (moved out of Inf6AutoPapersView)
// This is intentionally top-level so it can be moved into its own Swift file without changing call sites.
struct Inf6SyllabusDetailView: View {

    @Environment(\.openWindow) private var openWindow

    let syllabus: Inf6StanfordSyllabus
    let branding: Inf6CompassBranding
    let schools: [ECSchool]
    let departmentCode: String
    let onTranslated: ((String, String) -> Void)?

    // --- Official PDF discovery scoping (keyword-based) ---
    /// If true, narrow official-PDF discovery by keywords to avoid noisy links.
    /// JDLA pages are especially noisy; for jdla.org we always enable keyword scoping.
    var wantsKeywordScopedPDFDiscovery: Bool {
        // JDLA: always require keyword match in the discovered URL as a hard guard.
        if let host = resolvedOfficialHomeURL?.host?.localizedLowercase,
           host.contains("jdla.org") {
            return true
        }

        let t = syllabus.title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let d = syllabus.detail.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if t.localizedCaseInsensitiveContains("シラバス") { return true }
        if t.localizedCaseInsensitiveContains("syllabus") { return true }
        if d.localizedCaseInsensitiveContains("シラバス") { return true }
        if d.localizedCaseInsensitiveContains("syllabus") { return true }
        return false
    }

    /// Preferred keywords for narrowing PDF discovery.
    /// NOTE: This is used to filter *detected* candidate URLs; DOM section slicing is handled in the pipeline/inspector.
    var pdfDiscoveryKeywords: [String] {
        // Keep deterministic order
        return ["シラバス", "syllabus"]
    }

    // MARK: - Official PDF discovery cache (Application Support)
    /// Cache file: Application Support/inf6/cache/official_pdf_discovery_cache.json
    func officialPDFDiscoveryCacheURL() throws -> URL {
        return try Inf6UserSettingRootPaths.cacheFileURL("official_pdf_discovery_cache")
    }

    /// NOTE: Call sites may append extra suffixes (e.g. keyword scope flags). Keep this base key stable.
    @inline(__always)
    func officialPDFDiscoveryCacheKey(officialURL: URL) -> String {
        return officialURL.absoluteString.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    /// Returns: cacheKey -> [urlString]
    func loadOfficialPDFDiscoveryCache() -> [String: [String]] {
        if let url = try? officialPDFDiscoveryCacheURL(),
           let dict = Inf6DiskJSON.load([String: [String]].self, from: url) {
            return dict
        }
        return [:]
    }

    func saveOfficialPDFDiscoveryCache(_ dict: [String: [String]]) {
        do {
            let url = try officialPDFDiscoveryCacheURL()
            try Inf6DiskJSON.save(dict, to: url)
        } catch {
            // ignore (best-effort cache)
        }
    }

    // MARK: - E資格 PDF保存先 (bookmark)
    func eshikakuPDFFolderBookmarkFileURL() throws -> URL {
        let url = try Inf6UserSettingRootPaths.userDataFileURL("eshikaku_pdf_destination", ext: "bookmark")
        if !FileManager.default.fileExists(atPath: url.path),
           let old = try? Inf6UserSettingRootPaths.cacheFileURL("eshikaku_pdf_destination", ext: "bookmark"),
           FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: url)
        }
        return url
    }

    func loadPersistedEshikakuPDFFolder() throws -> URL? {
        let fileURL = try eshikakuPDFFolderBookmarkFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let data = try Inf6DiskData.load(from: fileURL)

        var isStale = false
        #if os(macOS)
        let opts: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        #else
        let opts: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif

        let resolved = try URL(
            resolvingBookmarkData: data,
            options: opts,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        if isStale {
            // 再生成して更新（失敗は上位へ throw）
            #if os(macOS)
            let updated = try resolved.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            #else
            let updated = try resolved.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            #endif
            try Inf6DiskData.save(updated, to: fileURL)
        }

        return resolved
    }

    func persistEshikakuPDFFolder(_ url: URL) throws {
        let fileURL = try eshikakuPDFFolderBookmarkFileURL()
        #if os(macOS)
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #else
        let data = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #endif
        try Inf6DiskData.save(data, to: fileURL)
    }

    #if canImport(PDFKit)
    /// PDFメタデータではなく、_toggle_ 表紙(1ページ目)の先頭行から「人間が読むタイトル」を抽出する。
    /// 例: E資格 / 試験出題範囲 / (シラバス 2024) / 2024年8月試験… など
    func deriveTitleFromPDFCover(_ doc: PDFDocument) -> String {
        guard let page0 = doc.page(at: 0) else { return "" }
        let raw = (page0.string ?? "").replacingOccurrences(of: "\r", with: "\n")

        let lines = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return "" }

        var picked: [String] = []
        picked.reserveCapacity(4)

        let digitsSlash = CharacterSet.decimalDigits.union(.init(charactersIn: "/-"))

        for l in lines {
            let t = l.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !t.isEmpty else { continue }

            // 1, 2/7, 2024-08 みたいなノイズを落とす
            if t.unicodeScalars.allSatisfy({ digitsSlash.contains($0) }) { continue }
            if t.contains("http://") || t.contains("https://") { continue }

            picked.append(t)
            if picked.count >= 4 { break }
        }

        return picked.joined(separator: "\n")
    }
    #endif

    @State var isDiscoveringOfficialPDFs = false
    @State var officialPDFStatus: String = ""
    // Auto-start guard so the official PDF pipeline runs once per view appearance.
    @State var didAutoStartSyllabusPDFPipeline: Bool = false
    // 次回の discoverOfficialPDFs でキャッシュを無視してフレッシュ取得する
    @State var bypassDiscoveryCache: Bool = false

    @State var isPreparingSyllabusPDFs = false
    @State var syllabusPDFStatus: String = ""
    @State var syllabusPDFItems: [Inf6SyllabusPDFItem] = []
    @State var selectedSyllabusPDFID: UUID? = nil

    // --- Full-text extraction (for PDFs without outline/TOC) ---
    @State var isExtractingSyllabusText: Bool = false
    @State var syllabusExtractedText: String = ""

    // --- E資格: paper search (API-based) ---
    @State var showEshikakuPaperSearchSheet: Bool = false
    @State var showEshikakuPaperSearchFullScreen: Bool = false

    @State var _exportingExplanationPDFScopeFolderURL: URL? = nil
    @State var _didStartExportingExplanationPDFScope: Bool = false
    
    var isIOSAppOnMac: Bool {
        #if os(iOS)
        if #available(iOS 14.0, *) {
            return ProcessInfo.processInfo.isiOSAppOnMac
        }
        return false
        #else
        return false
        #endif
    }

    @State var isSearchingEshikakuPapers: Bool = false
    @State var eshikakuPaperSearchStatus: String = ""
    @State var eshikakuPaperQuery: String = ""
    // NOTE: This must be derived from selectedOutlineKeys only (no fixed prefix/base list).
    @FocusState var isEshikakuPaperQueryFocused: Bool
    @State var eshikakuPaperCandidates: [Inf6PaperCandidate] = []
    @State var selectedEshikakuPaperIDs: Set<String> = []
    @State var generatedEshikakuPapersYAML: String = ""

    @State var isPickingGkenteiExplanationPDFFolder: Bool = false
    @State var gkenteiFolderURL: URL? = nil
    @State var gkenteiFolderStatus: String = ""
    @State var microsoftKnowledgePDFFolderURL: URL? = nil
    @State var microsoftKnowledgePDFFolderStatus: String = ""
    
    // ★ ユーザーが選択した PDF 保存先フォルダ
    @State var folderURL: URL? = nil
    @State var isPickingEshikakuPDFFolder: Bool = false
    // MARK: - G検定: 解説PDF 保存先フォルダ（UI state）

    @State var isGeneratingSyllabusOutline: Bool = false
    @State var syllabusOutlineStatus: String = ""
    @State var syllabusOutlineItems: [Inf6SyllabusOutlineItem] = []
    @State var selectedOutlineKeys: Set<String> = []
    @State var expandedOutlineSectionKeys: Set<String> = []
    @State var knowledgeDomainStructure: Inf6KnowledgeDomainStructure? = nil
    @State var knowledgeDomainStructureError: String = ""
    @State var expandedKnowledgeNodeIDs: Set<String> = []

    // MARK: - G検定: 解説PDF 保存先

    func _sanitizePathComponent(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if s.isEmpty { return "syllabus" }
        let illegal = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let parts = s.unicodeScalars.map { illegal.contains($0) ? "_" : String($0) }
        var name = parts.joined()
        while name.contains("__") { name = name.replacingOccurrences(of: "__", with: "_") }
        name = name.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if name.count > 120 { name = String(name.prefix(120)) }
        if name.isEmpty { return "syllabus" }
        return name
    }

    func _explanationPDFFilenameBaseFromSelection() -> String {
        // Build a stable, human-readable base from selected outline item titles.
        // Deterministic order: preserve syllabusOutlineItems order.
        let pickedTitles: [String] = syllabusOutlineItems
            .filter { selectedOutlineKeys.contains($0.key) }
            .map { $0.displayTitle.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // De-duplicate while preserving order
        var seen = Set<String>()
        var uniq: [String] = []
        uniq.reserveCapacity(pickedTitles.count)
        for t in pickedTitles {
            if seen.contains(t) { continue }
            seen.insert(t)
            uniq.append(t)
        }

        // Join with underscore and sanitize for filesystem.
        // Keep it reasonably short to avoid path length issues.
        let joined = uniq.joined(separator: "_")
        var base = _sanitizePathComponent(joined)
        if base.count > 80 {
            base = String(base.prefix(80))
        }
        if base.isEmpty {
            base = "explanation"
        }
        return base
    }

    func _explanationPDFDirectoryURLForCurrentSyllabus(createIfNeeded: Bool) throws -> URL {
        let base = Inf6DataRoot.url().appendingPathComponent("inf6_syllabus_cards", isDirectory: true)
        let key = _sanitizePathComponent(self.syllabus.title)
        let dir = base.appendingPathComponent(key, isDirectory: true)
        if createIfNeeded {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func _explanationPDFFileURLForCurrentSyllabus(createDirectoryIfNeeded: Bool) throws -> URL {
        let dir = try _explanationPDFDirectoryURLForCurrentSyllabus(createIfNeeded: createDirectoryIfNeeded)

        // The file name must include the syllabus title so multiple syllabi can coexist.
        // Use the same sanitization rules as directory naming.
        let titleBase = _sanitizePathComponent(self.syllabus.title)
        let base = titleBase.isEmpty ? "syllabus" : titleBase

        return dir
            .appendingPathComponent("\(base)_explanation")
            .appendingPathExtension("pdf")
    }

    // --- GPT explanation PDF (G検定 only) ---
    @State var isGeneratingExplanationPDF: Bool = false
    @State var explanationPDFStatus: String = ""
    @State var generatedExplanationPDFURL: URL? = nil
    @State var showExplanationPDFErrorAlert: Bool = false
    @State var explanationPDFErrorAlertMessage: String = ""
    @State var quickLookExplanationPDFURL: URL? = nil
    @State var isGeneratingMicrosoftKnowledgePDF: Bool = false
    @State var microsoftKnowledgePDFStatus: String = ""
    @State var generatedMicrosoftKnowledgePDFURL: URL? = nil
    // --- Export (G検定 explanation PDF -> Files) ---
    @State var isExportingExplanationPDF: Bool = false
    @State var exportExplanationDocument: Inf6ExportDocument? = nil
    // --- Import PDF (G検定 -> Library) ---
    @State var isPickingGkenteiImportPDF: Bool = false
    // --- Generated explanation PDFs (G検定) ---
    @State var showGkenteiGeneratedPDFListSheet: Bool = false
    @State var gkenteiGeneratedPDFListStatus: String = ""
    @State var gkenteiGeneratedPDFItems: [URL] = []

    // MMA
    @State var showMMAQuizPlayerSheet: Bool = false

}
