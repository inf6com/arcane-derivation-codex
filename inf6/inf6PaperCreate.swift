//
//  inf6PaperCreate.swift
//  inf6
//
//  Created by decopin on 2025/12/02.
//

import Foundation
import SwiftUI
import CoreText

#if canImport(PDFKit)
import PDFKit
#endif

#if !canImport(UIKit)
#error("inf6CreatePDF.swift requires UIKit (iOS / iPadOS / Designed for iPad on Mac only). Remove this file from non-UIKit targets.")
#endif
import UIKit


// ============================================================================
// MARK: - Split 2/2 (Pipeline)
// 目的: 公式PDF探索 / PDFキャッシュ / アウトライン生成 / 解説PDF / E資格論文検索 / ダウンロード
//      などの処理系を extension にまとめ、後で別ファイルへ移し替えやすくする。
// ============================================================================
extension Inf6SyllabusDetailView {

    
    private struct _Inf6ArxivCategoryOption: Identifiable {
        let id: String
        let searchQueryExpr: String
        init(_ id: String, _ expr: String) {
            self.id = id
            self.searchQueryExpr = expr
        }
    }
    
    private static let _eshikakuArxivCategoryOptions: [_Inf6ArxivCategoryOption] = [
        .init("ai_default", "(cat:cs.AI* OR cat:cs.LG* OR cat:stat.ML*)"),
        .init("cs_or_stat_all", "(cat:cs.* OR cat:stat.*)"),
        .init("cs_only", "(cat:cs.*)"),
        .init("stat_only", "(cat:stat.*)")
    ]
    
    private struct _Inf6ArxivCategoryPickerSheet: View {
        let title: String
        let options: [_Inf6ArxivCategoryOption]
        @Binding var selectedExpr: String
        @Environment(\.dismiss) private var dismiss
        
        var body: some View {
            NavigationStack {
                List {
                    ForEach(options) { opt in
                        Button {
                            selectedExpr = opt.searchQueryExpr
                            dismiss()
                        } label: {
                            HStack {
                                Text(opt.searchQueryExpr)
                                    .font(.body)
                                    .lineLimit(1)
                                Spacer()
                                if selectedExpr == opt.searchQueryExpr {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(Inf6Lang.text("閉じる", "Close")) { dismiss() }
                    }
                }
            }
        }
    }

    
    /// ローカル定義（Inf6CompassDefaultConfig.schools）の school.homeURLString から、
    /// このシラバスの「所属(=level)」に対応する公式URLを解決する。
    var resolvedOfficialHomeURL: URL? {
        // Prefer per-department official URL when provided (stored in manifestRef for local entries).
        if let s = syllabus.manifestRef?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
           let u = URL(string: s), u.scheme != nil {
            return u
        }
        let levelLabel = syllabus.level.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !levelLabel.isEmpty else { return nil }
        
        for school in Inf6CompassDefaultConfig.schools {
            let schoolLabel = Inf6Lang.text(school.labelJa, school.labelEn)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard schoolLabel == levelLabel else { continue }
            
            // homeURLString の型( String / String? )に依存しないよう、Mirror で取り出す。
            let mirror = Mirror(reflecting: school)
            if let child = mirror.children.first(where: { $0.label == "homeURLString" }) {
                if let s = child.value as? String {
                    let raw = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    if let u = URL(string: raw), u.scheme != nil { return u }
                } else {
                    let inner = Mirror(reflecting: child.value)
                    if inner.displayStyle == .optional,
                       let some = inner.children.first?.value as? String {
                        let raw = some.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        if let u = URL(string: raw), u.scheme != nil { return u }
                    }
                }
            }
            return nil
        }
        return nil
    }
    
    // MARK: - Local helpers (split files cannot access `private` members in other files)
    
    @inline(__always)
    private var _openAIModelLocal: String {
        let raw = (UserDefaults.standard.string(forKey: "openai_model") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty { return raw }
        
        // If still empty, treat as misconfiguration and let callers fail fast (they guard this).
        return ""
    }
    
    @inline(__always)
    private func _loadOpenAIAPIKeyOrThrow() throws -> String {
        return try OpenAIKeyStore.load()
    }
    
    @inline(__always)
    private func _officialPDFDiscoveryCacheKeyLocal(officialURL: URL) -> String {
        return officialURL.absoluteString.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }
    
    private func _officialPDFDiscoveryCacheURLLocal() throws -> URL {
        return try Inf6UserSettingRootPaths.cacheFileURL("official_pdf_discovery_cache_v1")
    }
    
    private func _loadOfficialPDFDiscoveryCacheLocal() throws -> [String: [String]] {
        let url = try _officialPDFDiscoveryCacheURLLocal()
        if let dict = Inf6DiskJSON.load([String: [String]].self, from: url) {
            return dict
        }
        return [:]
    }
    
    private func _saveOfficialPDFDiscoveryCacheLocal(_ dict: [String: [String]]) throws {
        let url = try _officialPDFDiscoveryCacheURLLocal()
        try Inf6DiskJSON.save(dict, to: url)
    }
    
    private var _isIOSAppOnMacLocal: Bool {
        if #available(iOS 14.0, *) {
            return ProcessInfo.processInfo.isiOSAppOnMac
        }
        return false
    }
    
    // MARK: - Split targets (cut-ready blocks)
    //
    // NOTE: UIが所有するカテゴリ式（例: arXiv用のカテゴリクエリ）は
    // extension内では@Stateで持てないため、struct本体側で
    //   var _eshikakuArxivCategoryExpr: String
    // などとして保存しておき、
    // extensionからは self._eshikakuArxivCategoryExpr を参照すること。
    // NOTE: ここで挙げた「塊」ごとに、後でそのまま別ファイルへ移動できるように整理します。
    // Future files (one block per file):
    //  - Inf6SyllabusDetailView+OfficialPDFDiscovery.swift
    //      - discoverOfficialPDFs(from:)
    //      - (discovery cache helpers) officialPDFDiscoveryCacheKey / loadOfficialPDFDiscoveryCache / saveOfficialPDFDiscoveryCache
    //      - (crawler helpers) inf6DiscoverReachablePDFURLsScoped / inf6URLMatchesDiscoveryKeywords
    //  - Inf6SyllabusDetailView+PDFCache.swift
    //      - syllabusPDFCacheDirectoryURL / sanitizeFileName
    //      - (title cache) pdfTitleCacheURL / loadPDFTitleCache / savePDFTitleCache / pdfTitleCacheKey
    //      - generatePDFDisplayTitleViaGPT
    //  - Inf6SyllabusDetailView+Outline.swift
    //      - syllabusOutlineCacheURL / loadSyllabusOutlineCache / saveSyllabusOutlineCache / syllabusOutlineCacheKey
    //      - extractJSONArrayString / translateOutlineJaToEn / generateSyllabusOutlineViaGPT / generateSyllabusOutlineIfNeeded
    //      - outlineRow / toggleOutlineSelection / isGkenteiCourse / isEshikakuCourse
    //  - Inf6SyllabusDetailView+ExplanationAndPapers.swift
    //      - (G検定) generateExplanationPDFForSelectedOutlineItems + explanation PDF helpers
    
    //  - Inf6SyllabusDetailView+SyllabusPDFPipeline.swift
    //      - downloadToAppSupport / prepareSyllabusPDFs / extractFullTextIfNeeded / selectSyllabusPDFItem
    
    // MARK: - Official PDF discovery (1/5)
    // Split-target file: Inf6SyllabusDetailView+OfficialPDFDiscovery.swift
    // NOTE: このブロックは別ファイルへ切り出しやすいように、まとまり単位で区切っています。
    
    @MainActor
    func discoverOfficialPDFs(from officialURL: URL) {
        guard !isDiscoveringOfficialPDFs else { return }
        isDiscoveringOfficialPDFs = true
        officialPDFStatus = ""
        
        // Use cached discovery result when available to avoid re-fetching noisy official pages.
        // Include keyword-scoping parameters in the cache key so different modes don't collide.
        let cacheKey = _officialPDFDiscoveryCacheKeyLocal(officialURL: officialURL)
        + (wantsKeywordScopedPDFDiscovery ? "|kw" : "|all")
        + "|k=" + pdfDiscoveryKeywords.joined(separator: ",")
        
        // bypassDiscoveryCache フラグが立っているときはキャッシュをスキップする
        let shouldUseCache = !bypassDiscoveryCache
        bypassDiscoveryCache = false   // フラグをリセット（一回限り）

        if shouldUseCache {
            do {
                let dict = try _loadOfficialPDFDiscoveryCacheLocal()
                let cached = dict[cacheKey] ?? []
                let cachedURLs: [URL] = cached.compactMap { URL(string: $0) }.filter { $0.scheme != nil }
                if !cachedURLs.isEmpty {
                    self.isDiscoveringOfficialPDFs = false
                    self.officialPDFStatus = ""
                    self.prepareSyllabusPDFs(from: cachedURLs)
                    return
                }
            } catch {
                // Cache I/O failure must surface.
                self.isDiscoveringOfficialPDFs = false
                self.officialPDFStatus = Inf6Lang.text(
                    "公式PDF探索キャッシュの読み込みに失敗: \(error.localizedDescription)",
                    "Failed to load discovery cache: \(error.localizedDescription)"
                )
                return
            }
        }
        
        // Reset ①〜⑤ pipeline
        isPreparingSyllabusPDFs = false
        syllabusPDFStatus = ""
        syllabusPDFItems = []
        selectedSyllabusPDFID = nil
        
        Task(priority: .userInitiated) {
            let builder = Inf6SyllabusPipelineBuilder()
            
            // If the official URL is the JDLA domain root, also try the certificate landing pages.
            var targets: [URL] = [officialURL]
            if let host = officialURL.host?.lowercased(), host.contains("jdla.org"),
               (officialURL.path.isEmpty || officialURL.path == "/") {
                if let u1 = URL(string: "https://www.jdla.org/certificate/engineer/") {
                    targets.append(u1)
                }
                if let u2 = URL(string: "https://www.jdla.org/certificate/general/") {
                    targets.append(u2)
                }
            }
            
            var merged: [URL] = []
            var seen = Set<String>()
            for t in targets {
                let scope = wantsKeywordScopedPDFDiscovery ? pdfDiscoveryKeywords : []
                if !scope.isEmpty {
                    // Only log when scope is active.
                    print("[Inf6AutoPapers] discoverOfficialPDFs: scopeKeywords=\(scope)")
                }
                let tunedTimeout: TimeInterval = scope.isEmpty ? 30 : 18
                let tunedConcurrency: Int = scope.isEmpty ? 2 : 1
                let found = await inf6DiscoverReachablePDFURLsScoped(
                    builder: builder,
                    officialURL: t,
                    scopeKeywords: scope,
                    keywords: pdfDiscoveryKeywords,
                    timeout: tunedTimeout,
                    maxConcurrency: tunedConcurrency
                )
                for u in found {
                    let key = u.absoluteString
                    if seen.insert(key).inserted {
                        merged.append(u)
                    }
                }
            }
            
            // If keyword scoping is enabled, narrow results to URLs that also contain the keyword.
            // (Full DOM section scoping is implemented in the pipeline/inspector; this is an extra safety net.)
            if wantsKeywordScopedPDFDiscovery {
                let before = merged.count
                let filtered = merged.filter { inf6URLMatchesDiscoveryKeywords($0, keywords: pdfDiscoveryKeywords) }
                if !filtered.isEmpty {
                    merged = filtered
                }
                let after = merged.count
                print("[Inf6AutoPapers] discoverOfficialPDFs: keyword filter applied before=\(before) after=\(after) keywords=\(pdfDiscoveryKeywords)")
            }
            
            let urls = merged
            
            // Persist discovery cache (must surface failure).
            if !urls.isEmpty {
                do {
                    var dict = try _loadOfficialPDFDiscoveryCacheLocal()
                    dict[cacheKey] = urls.map { $0.absoluteString }
                    try _saveOfficialPDFDiscoveryCacheLocal(dict)
                } catch {
                    await MainActor.run {
                        self.officialPDFStatus = Inf6Lang.text(
                            "公式PDF探索キャッシュの保存に失敗: \(error.localizedDescription)",
                            "Failed to save discovery cache: \(error.localizedDescription)"
                        )
                    }
                }
            }
            
            await MainActor.run {
                if urls.isEmpty {
                    self.officialPDFStatus = Inf6Lang.text(
                        "公式サイトからPDFリンクを検出できませんでした。",
                        "No PDF links were detected."
                    )
                } else {
                    // Success: hide noisy progress messages.
                    if self.officialPDFStatus.isEmpty {
                        self.officialPDFStatus = ""
                    }
                    // 更新チェッカーに発見済み URL を記録（初回 & 以降の差分検出に使う）
                    Inf6SyllabusUpdateChecker.shared.recordDiscovery(
                        officialURL: officialURL,
                        foundURLs: urls
                    )
                }
                self.isDiscoveringOfficialPDFs = false
                if !urls.isEmpty {
                    self.prepareSyllabusPDFs(from: urls)
                }
            }
        }
    }
    
    // MARK: - PDF cache paths & file-name utilities (2a/5)
    // Split-target file: Inf6SyllabusDetailView+PDFCache.swift
    
    func syllabusPDFCacheDirectoryURL() throws -> URL {
        let root = try Inf6LibraryView._sharedRootDir()

        // Strict directory creation (no silent fallback)
        func ensureDir(_ url: URL) throws {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                guard isDir.boolValue else {
                    throw NSError(domain: "Inf6FS", code: 20, userInfo: [
                        NSLocalizedDescriptionKey: "Expected a directory but found a file at: \(url.path)"
                    ])
                }
                return
            }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }

        let accessed = root.startAccessingSecurityScopedResource()
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }
        #if canImport(UIKit)
        if accessed == false, !FileManager.default.isReadableFile(atPath: root.path) {
            throw NSError(domain: "Inf6Storage", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to access shared root folder: \(root.path)"
            ])
        }
        #endif

        var cur = root
        try ensureDir(cur)

        for comp in ["jdla", "syllabus_pdfs"] {
            cur = cur.appendingPathComponent(comp, isDirectory: true)
            try ensureDir(cur)
        }

        return cur
    }
    
    func sanitizeFileName(_ s: String) -> String {
        // Keep it conservative and file-system friendly.
        // Also cap length to avoid pathological long file names.
        let allowed = CharacterSet.alphanumerics
            .union(.init(charactersIn: "-_."))
        
        let mapped = s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        var out = String(mapped)
        
        // Collapse runs of underscores.
        while out.contains("__") {
            out = out.replacingOccurrences(of: "__", with: "_")
        }
        
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_ .-\n\r\t"))
        if out.isEmpty { out = "syllabus" }
        
        // Keep room for adding ".pdf" later.
        let maxLen = 120
        if out.count > maxLen {
            out = String(out.prefix(maxLen))
            out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_ .-"))
            if out.isEmpty { out = "syllabus" }
        }
        return out
    }
    
    // MARK: - PDF title cache (Application Support) (2b/5)
    func pdfTitleCacheURL() throws -> URL {
        return try Inf6UserSettingRootPaths.cacheFileURL("syllabus_pdf_titles")
    }
    
    func loadPDFTitleCache() throws -> [String: String] {
        let url = try pdfTitleCacheURL()
        if let dict = Inf6DiskJSON.load([String: String].self, from: url) {
            return dict
        }
        return [:]
    }
    
    func savePDFTitleCache(_ dict: [String: String]) throws {
        let url = try pdfTitleCacheURL()
        try Inf6DiskJSON.save(dict, to: url)
    }
    
    @inline(__always)
    func pdfTitleCacheKey(sourceURL: URL, localURL: URL) -> String {
        let s = sourceURL.absoluteString.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if !s.isEmpty { return s }
        return localURL.lastPathComponent
    }
    
    func generatePDFDisplayTitleViaGPT(
        apiKey: String,
        coverText: String,
        fallbackHeuristicTitle: String,
        sourceURL: URL
    ) async -> String? {
        let key = apiKey.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let t = coverText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        let model = _openAIModelLocal
        guard !model.isEmpty else { return nil }

        let coverSnippet = String(t.prefix(5000))

        do {
            let client = try OpenAIClient(
                apiKey: key,
                config: .default(model: model)
            )
            let rendered = try Inf6PromptGovernance.renderSystemUserPrompt(
                ref: Inf6PromptCatalog.paperCreatePDFTitle,
                variables: [
                    "cover_snippet": coverSnippet,
                    "fallback_heuristic_title": fallbackHeuristicTitle,
                    "source_url": sourceURL.absoluteString
                ]
            )

            let raw0 = try await client.generateText(
                messages: [
                    OpenAIClient.InputMessage(role: .system, text: rendered.systemInstruction),
                    OpenAIClient.InputMessage(role: .user, text: rendered.userPrompt)
                ],
                options: .init()
            )
            let raw = raw0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }

            let normalized = raw
                .replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(4)
                .joined(separator: "\n")

            return normalized.isEmpty ? nil : normalized
        } catch {
#if DEBUG
            print("[Inf6AutoPapers] generatePDFDisplayTitleViaGPT failed: \(error)")
#endif
            return nil
        }
    }
    
    // MARK: - Syllabus outline (cache + extraction + GPT) (3/5)
    // Split-target file: Inf6SyllabusDetailView+Outline.swift
    func syllabusOutlineCacheURL() throws -> URL {
        return try Inf6Storage.syllabusOutlineCacheURL()
    }
    
    func loadSyllabusOutlineCache() throws -> [String: [Inf6SyllabusOutlineItem]] {
        let url = try syllabusOutlineCacheURL()
        if let dict = Inf6DiskJSON.load([String: [Inf6SyllabusOutlineItem]].self, from: url) {
            return dict
        }
        return [:]
    }
    
    func saveSyllabusOutlineCache(_ dict: [String: [Inf6SyllabusOutlineItem]]) throws {
        let url = try syllabusOutlineCacheURL()
        try Inf6DiskJSON.save(dict, to: url)
    }
    
    @inline(__always)
    func syllabusOutlineCacheKey(for item: Inf6SyllabusPDFItem) -> String {
        let s = item.sourceURL.absoluteString.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if !s.isEmpty { return s }
        return item.localURL.lastPathComponent
    }
    
    func extractJSONArrayString(_ s: String) -> String? {
        guard let start = s.firstIndex(of: "["), let end = s.lastIndex(of: "]"), start < end else {
            return nil
        }
        return String(s[start...end])
    }
    
    func translateOutlineJaToEn(items: [Inf6SyllabusOutlineItem]) async throws -> [Inf6SyllabusOutlineItem] {
        guard !items.isEmpty else { return items }
        var translated: [Inf6SyllabusOutlineItem] = []
        translated.reserveCapacity(items.count)
        for item in items {
            try Task.checkCancellation()
            let title = (item.titleJa ?? item.title).trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = (item.summaryJa ?? item.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let titleEn = try await Inf6SystemTranslationCoordinator.shared.translate(title, source: "ja", target: "en")
            let summaryEn = try await Inf6SystemTranslationCoordinator.shared.translate(summary, source: "ja", target: "en")
            translated.append(.init(
                key: item.key,
                title: item.title,
                summary: item.summary,
                titleJa: item.titleJa,
                titleEn: titleEn.isEmpty ? item.titleEn : titleEn,
                summaryJa: item.summaryJa,
                summaryEn: summaryEn.isEmpty ? item.summaryEn : summaryEn,
                depth: item.depth
            ))
        }
        return translated
    }
    
    func generateSyllabusOutlineViaGPT(
        apiKey: String,
        courseTitle: String,
        pdfTitle: String,
        fullText: String
    ) async throws -> [Inf6SyllabusOutlineItem] {
        let key = apiKey.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !key.isEmpty else { return [] }
        
        let t = fullText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        
        let maxChars = 120_000
        let snippet: String
        if t.count <= maxChars {
            snippet = t
        } else {
            let head = String(t.prefix(80_000))
            let tail = String(t.suffix(40_000))
            snippet = head + "\n\n---\n(…truncated…)\n---\n\n" + tail
        }
        
        let model = _openAIModelLocal
        guard !model.isEmpty else {
            throw NSError(domain: "Inf6OpenAI", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "OpenAI model is not configured"
            ])
        }

        let client = try OpenAIClient(
            apiKey: key,
            config: .default(model: model)
        )
        let rendered = try Inf6PromptGovernance.renderSystemUserPrompt(
            ref: Inf6PromptCatalog.paperCreateOutlineGenerate,
            variables: [
                "course_title": courseTitle,
                "pdf_title": pdfTitle,
                "full_text_snippet": snippet
            ]
        )

        let content0 = try await client.generateText(
            messages: [
                OpenAIClient.InputMessage(role: .system, text: rendered.systemInstruction),
                OpenAIClient.InputMessage(role: .user, text: rendered.userPrompt)
            ],
            options: .init()
        )
        let content = content0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !content.isEmpty else { return [] }
        
        guard let json = extractJSONArrayString(content), let jsonData = json.data(using: .utf8) else {
            return []
        }
        
        struct _Row: Decodable {
            let key: String?
            let title: String?
            let summary: String?
            let title_ja: String?
            let title_en: String?
            let summary_ja: String?
            let summary_en: String?
        }
        let rows = try JSONDecoder().decode([_Row].self, from: jsonData)
        
        var out: [Inf6SyllabusOutlineItem] = []
        out.reserveCapacity(rows.count)
        var used = Set<String>()
        
        for (idx, r) in rows.enumerated() {
            let rawKey = (r.key ?? "item_\(idx)").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            
            let jaTitle = (r.title_ja ?? "").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let enTitle = (r.title_en ?? "").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let jaSummary = r.summary_ja?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let enSummary = r.summary_en?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            
            // Legacy fallback
            let legacyTitle = (r.title ?? "").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let legacySummary = r.summary?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            
            let k0 = rawKey.isEmpty ? "item_\(idx)" : rawKey
            let k = used.insert(k0).inserted ? k0 : "\(k0)_\(idx)"
            
            let baseTitle = (!jaTitle.isEmpty ? jaTitle : (!enTitle.isEmpty ? enTitle : (!legacyTitle.isEmpty ? legacyTitle : k)))
            let baseSummary: String? = {
                if let s = legacySummary, !s.isEmpty { return s }
                if let s = jaSummary, !s.isEmpty { return s }
                if let s = enSummary, !s.isEmpty { return s }
                return nil
            }()
            
            out.append(.init(
                key: k,
                title: baseTitle,
                summary: baseSummary,
                titleJa: jaTitle.isEmpty ? nil : jaTitle,
                titleEn: enTitle.isEmpty ? nil : enTitle,
                summaryJa: (jaSummary?.isEmpty == false) ? jaSummary : nil,
                summaryEn: (enSummary?.isEmpty == false) ? enSummary : nil,
                depth: 0
            ))
        }
        return out
    }
    
    @MainActor
    func generateSyllabusOutlineIfNeeded(from item: Inf6SyllabusPDFItem, extractedText: String) {
        syllabusOutlineStatus = ""
        
        let cacheKey: String = {
            let base = syllabusOutlineCacheKey(for: item)
            if isEshikakuCourse { return base + "|eshikaku_outline_v2" }
            if isGkenteiCourse { return base + "|gkentei_outline_v1" }
            return base + "|outline_v1"
        }()
        
        do {
            let cache = try loadSyllabusOutlineCache()
            if let cached = cache[cacheKey], !cached.isEmpty {
                syllabusOutlineItems = cached
                let available = Set(cached.map { $0.key })
                selectedOutlineKeys = selectedOutlineKeys.intersection(available)
                return
            }
        } catch {
            syllabusOutlineStatus = Inf6Lang.text(
                "シラバス一覧キャッシュの読み込みに失敗: \(error.localizedDescription)",
                "Failed to load outline cache: \(error.localizedDescription)"
            )
        }
        
        // Prefer deterministic extraction for E資格: it has stable multi-level headings (1./(1)/ⅰ).
        if isEshikakuCourse {
            let parsed = Inf6EshikakuOutlineExtractor.extract(from: extractedText)
            let depth2plus = parsed.filter { ($0.depth ?? 0) >= 2 }.count
            let keywordCount = parsed.filter { ($0.depth ?? 0) >= 3 }.count
            if parsed.count >= 12 && (depth2plus >= 4 || keywordCount >= 6) {
                if !Inf6Lang.isJapanese {
                    syllabusOutlineStatus = Inf6Lang.text("英語表示用に翻訳中…", "Translating to English…")
                    isGeneratingSyllabusOutline = true
                        
                        Task(priority: .userInitiated) {
                            do {
                                let translated = try await translateOutlineJaToEn(items: parsed)
                                await MainActor.run {
                                    self.isGeneratingSyllabusOutline = false
                                    self.syllabusOutlineItems = translated
                                    self.selectedOutlineKeys = []
                                    self.syllabusOutlineStatus = ""
                                    
                                    do {
                                        var dict = try self.loadSyllabusOutlineCache()
                                        dict[cacheKey] = translated
                                        try self.saveSyllabusOutlineCache(dict)
                                    } catch {
                                        self.syllabusOutlineStatus = Inf6Lang.text(
                                            "シラバス一覧キャッシュの保存に失敗: \(error.localizedDescription)",
                                            "Failed to save outline cache: \(error.localizedDescription)"
                                        )
                                    }
                                }
                            } catch {
                                await MainActor.run {
                                    self.isGeneratingSyllabusOutline = false
                                    self.syllabusOutlineItems = parsed
                                    self.selectedOutlineKeys = []
                                    self.syllabusOutlineStatus = Inf6Lang.text(
                                        "英語翻訳に失敗したため、日本語のまま表示します: \(error.localizedDescription)",
                                        "English translation failed; showing Japanese: \(error.localizedDescription)"
                                    )
                                    
                                    do {
                                        var dict = try self.loadSyllabusOutlineCache()
                                        dict[cacheKey] = parsed
                                        try self.saveSyllabusOutlineCache(dict)
                                    } catch {
                                        self.syllabusOutlineStatus = Inf6Lang.text(
                                            "シラバス一覧キャッシュの保存に失敗: \(error.localizedDescription)",
                                            "Failed to save outline cache: \(error.localizedDescription)"
                                        )
                                    }
                                }
                            }
                        }
                        return
                    }
                
                syllabusOutlineItems = parsed
                selectedOutlineKeys = []
                syllabusOutlineStatus = ""
                
                do {
                    var dict = try loadSyllabusOutlineCache()
                    dict[cacheKey] = parsed
                    try saveSyllabusOutlineCache(dict)
                } catch {
                    syllabusOutlineStatus = Inf6Lang.text(
                        "シラバス一覧キャッシュの保存に失敗: \(error.localizedDescription)",
                        "Failed to save outline cache: \(error.localizedDescription)"
                    )
                }
                return
            }
        }
        
        // Prefer deterministic extraction for JDLA/G検定 PDF text: it tends to have stable numbered headings.
        if isGkenteiCourse {
            let parsed = Inf6GkenteiOutlineExtractor.extract(from: extractedText)
            if parsed.count >= 20 {
                // If English mode, translate to English when possible; otherwise show Japanese as-is.
                if !Inf6Lang.isJapanese {
                    syllabusOutlineStatus = Inf6Lang.text("英語表示用に翻訳中…", "Translating to English…")
                    isGeneratingSyllabusOutline = true
                        
                        Task(priority: .userInitiated) {
                            do {
                                let translated = try await translateOutlineJaToEn(items: parsed)
                                await MainActor.run {
                                    self.isGeneratingSyllabusOutline = false
                                    self.syllabusOutlineItems = translated
                                    self.selectedOutlineKeys = []
                                    self.syllabusOutlineStatus = ""
                                    
                                    do {
                                        var dict = try self.loadSyllabusOutlineCache()
                                        dict[cacheKey] = translated
                                        try self.saveSyllabusOutlineCache(dict)
                                    } catch {
                                        self.syllabusOutlineStatus = Inf6Lang.text(
                                            "シラバス一覧キャッシュの保存に失敗: \(error.localizedDescription)",
                                            "Failed to save outline cache: \(error.localizedDescription)"
                                        )
                                    }
                                }
                            } catch {
                                await MainActor.run {
                                    self.isGeneratingSyllabusOutline = false
                                    self.syllabusOutlineItems = parsed
                                    self.selectedOutlineKeys = []
                                    self.syllabusOutlineStatus = Inf6Lang.text(
                                        "英語翻訳に失敗したため、日本語のまま表示します: \(error.localizedDescription)",
                                        "English translation failed; showing Japanese: \(error.localizedDescription)"
                                    )
                                    
                                    do {
                                        var dict = try self.loadSyllabusOutlineCache()
                                        dict[cacheKey] = parsed
                                        try self.saveSyllabusOutlineCache(dict)
                                    } catch {
                                        self.syllabusOutlineStatus = Inf6Lang.text(
                                            "シラバス一覧キャッシュの保存に失敗: \(error.localizedDescription)",
                                            "Failed to save outline cache: \(error.localizedDescription)"
                                        )
                                    }
                                }
                            }
                        }
                        return
                    }
                
                // Japanese mode: show extracted Japanese outline.
                syllabusOutlineItems = parsed
                selectedOutlineKeys = []
                syllabusOutlineStatus = ""
                
                do {
                    var dict = try loadSyllabusOutlineCache()
                    dict[cacheKey] = parsed
                    try saveSyllabusOutlineCache(dict)
                } catch {
                    syllabusOutlineStatus = Inf6Lang.text(
                        "シラバス一覧キャッシュの保存に失敗: \(error.localizedDescription)",
                        "Failed to save outline cache: \(error.localizedDescription)"
                    )
                }
                return
            }
        }
        
        let apiKey: String
        do {
            apiKey = try _loadOpenAIAPIKeyOrThrow()
        } catch {
            syllabusOutlineStatus = Inf6Lang.text(
                "OpenAI APIキーを取得できないため、シラバス一覧の自動生成をスキップしました: \(error.localizedDescription)",
                "OpenAI API key is unavailable; skipped outline generation: \(error.localizedDescription)"
            )
            return
        }
        
        guard !isGeneratingSyllabusOutline else { return }
        isGeneratingSyllabusOutline = true
        syllabusOutlineStatus = Inf6Lang.text("シラバス一覧を生成中…", "Generating syllabus outline…")
        
        let courseTitle = syllabus.title
        let pdfTitle = item.title
        
        Task(priority: .userInitiated) {
            do {
                let items = try await generateSyllabusOutlineViaGPT(
                    apiKey: apiKey,
                    courseTitle: courseTitle,
                    pdfTitle: pdfTitle,
                    fullText: extractedText
                )
                
                await MainActor.run {
                    self.isGeneratingSyllabusOutline = false
                    if items.isEmpty {
                        self.syllabusOutlineStatus = Inf6Lang.text(
                            "シラバス一覧を生成できませんでした（抽出テキストが不足している可能性があります）。",
                            "Could not generate outline (PDF text may be insufficient)."
                        )
                        self.syllabusOutlineItems = []
                        self.selectedOutlineKeys = []
                        return
                    }
                    
                    self.syllabusOutlineItems = items
                    self.selectedOutlineKeys = [] // default: select none
                    self.syllabusOutlineStatus = ""
                    
                    do {
                        var dict = try self.loadSyllabusOutlineCache()
                        dict[cacheKey] = items
                        try self.saveSyllabusOutlineCache(dict)
                    } catch {
                        self.syllabusOutlineStatus = Inf6Lang.text(
                            "シラバス一覧キャッシュの保存に失敗: \(error.localizedDescription)",
                            "Failed to save outline cache: \(error.localizedDescription)"
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    self.isGeneratingSyllabusOutline = false
                    self.syllabusOutlineStatus = Inf6Lang.text(
                        "シラバス一覧の生成に失敗: \(error.localizedDescription)",
                        "Failed to generate outline: \(error.localizedDescription)"
                    )
                }
            }
        }
    }
    // MARK: - arXiv/PubMed 論文候補検索 (E資格)
    
    /// arXiv候補を取得する（カテゴリ式を引数で指定。UI側で所持すること）。
    func fetchArxivCandidates(query: String, categoryExpr: String, maxResults: Int) async throws -> [Inf6PaperCandidate] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            throw NSError(domain: "Inf6Arxiv", code: 10, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "検索クエリが空です。",
                    "Search query is empty."
                )
            ])
        }
        
        let cat = categoryExpr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cat.isEmpty else {
            throw NSError(domain: "Inf6Arxiv", code: 11, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "arXivカテゴリ式が未設定です。上部のカテゴリ選択で設定してください。",
                    "arXiv category expression is not set. Please choose it in the category selector."
                )
            ])
        }
        
        var components = URLComponents(string: "https://export.arxiv.org/api/query")!
        components.queryItems = [
            URLQueryItem(name: "search_query", value: cat + " AND all:" + q),
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "max_results", value: "\(maxResults)"),
            URLQueryItem(name: "sortBy", value: "relevance"),
            URLQueryItem(name: "sortOrder", value: "descending")
        ]
        let url = components.url!
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "arXiv", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "arXiv API HTTP \(http.statusCode)"
            ])
        }
        return try _parseArxivCandidatesAtom(data: data)
    }
    
    /// E資格候補検索の実行。
    /// in-app 候補一覧の許可ソースは `Inf6PaperSource.fetchCandidates` の正本契約に従う。
    func runEshikakuPaperSearch(query: String, source: Inf6PaperSourceID) async throws -> [Inf6PaperCandidate] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        if source == .arxiv, q.localizedCaseInsensitiveContains("cat:") {
            throw NSError(domain: "Inf6Arxiv", code: 12, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "カテゴリ指定（cat:...）は上部のカテゴリ選択ボックスで固定します。検索クエリから cat: を削除してください。",
                    "Category constraints (cat:...) are owned by the category selector. Remove cat: from the search query."
                )
            ])
        }
        switch source {
        case .arxiv:
            return try await Inf6EshikakuPaperSearch.fetchArxivCandidates(query: q, maxResults: 30)
        case .pubmed:
            return try await Inf6EshikakuPaperSearch.fetchPubMedCandidates(query: q, maxResults: 30)
        case .openreview, .acl, .pmlr, .cvf:
            throw NSError(domain: "Inf6PaperSearch", code: 1002, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "アプリ内の候補一覧は arXiv / PubMed のみ対応です。その他の収集元は外部ブラウザ検索を使用してください。",
                    "The in-app candidate list currently supports arXiv / PubMed only. Use external browser search for other sources."
                )
            ])
        }
    }

    // MARK: - arXiv Atom parsing (local, no cross-file dependency)

    private func _parseArxivCandidatesAtom(data: Data) throws -> [Inf6PaperCandidate] {
        final class _Delegate: NSObject, XMLParserDelegate {
            var items: [Inf6PaperCandidate] = []

            private var inEntry = false
            private var currentID: String = ""
            private var currentTitle: String = ""
            private var currentAuthors: [String] = []
            private var currentPdfURL: String? = nil

            private var currentElement: String = ""
            private var buffer: String = ""

            func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
                currentElement = elementName
                buffer = ""

                if elementName == "entry" {
                    inEntry = true
                    currentID = ""
                    currentTitle = ""
                    currentAuthors = []
                    currentPdfURL = nil
                }

                if inEntry, elementName == "link" {
                    // Prefer direct PDF link: <link title="pdf" href="..." /> or rel="related" type="application/pdf"
                    let href = attributeDict["href"]
                    let title = attributeDict["title"]?.lowercased()
                    let type = attributeDict["type"]?.lowercased()
                    let rel = attributeDict["rel"]?.lowercased()

                    if let h = href {
                        if title == "pdf" {
                            currentPdfURL = h
                        } else if type == "application/pdf" {
                            currentPdfURL = h
                        } else if rel == "related", h.lowercased().hasSuffix(".pdf") {
                            currentPdfURL = h
                        }
                    }
                }
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                buffer += string
            }

            func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
                let text = buffer.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

                if inEntry {
                    if elementName == "id" {
                        currentID = text
                    } else if elementName == "title" {
                        // arXiv titles may include newlines; normalize whitespace.
                        let normalized = text
                            .replacingOccurrences(of: "\r", with: " ")
                            .replacingOccurrences(of: "\n", with: " ")
                            .replacingOccurrences(of: "\t", with: " ")
                        currentTitle = normalized
                            .split(separator: " ")
                            .map(String.init)
                            .joined(separator: " ")
                            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    } else if elementName == "name" {
                        if !text.isEmpty {
                            currentAuthors.append(text)
                        }
                    } else if elementName == "entry" {
                        inEntry = false

                        let id = currentID.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        let title = currentTitle.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

                        // Derive a stable arXiv id for `Inf6PaperCandidate.id`.
                        // Prefer the last path component of the id URL if possible.
                        let derivedID: String = {
                            if let u = URL(string: id), u.scheme != nil {
                                let last = u.lastPathComponent.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                                if !last.isEmpty { return last }
                            }
                            return id
                        }()

                        guard !derivedID.isEmpty, !title.isEmpty else { return }

                        let authors: [String] = currentAuthors
                            .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }

                        let pdfURL: String? = currentPdfURL?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

                        items.append(Inf6PaperCandidate(
                            id: derivedID,
                            title: title,
                            authors: authors,
                            summary: "",
                            absURL: URL(string: id),
                            pdfURL: (pdfURL?.isEmpty == false) ? URL(string: pdfURL!) : nil
                        ))
                    }
                }

                buffer = ""
                currentElement = ""
            }
        }

        let parser = XMLParser(data: data)
        let delegate = _Delegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? NSError(domain: "Inf6ArxivAtom", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to parse arXiv Atom feed."
            ])
        }

        return delegate.items
    }

    // MARK: - arXiv/PubMed 論文候補検索 (E資格)
    
    /// 指定URLのPDFデータを読み込む (throwing, for arXiv direct PDF download etc.)
    func loadPDFData(from url: URL) throws -> Data {
        guard url.isFileURL || url.scheme != nil else {
            throw NSError(domain: "Inf6PDF", code: 30, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "PDF URL が不正です: \(url.absoluteString)",
                    "Invalid PDF URL: \(url.absoluteString)"
                )
            ])
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(NSError(domain: "Inf6PDF", code: 32, userInfo: [
            NSLocalizedDescriptionKey: "Unknown download error."
        ]))

        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        if url.isFileURL {
            do {
                let d = try Data(contentsOf: url)
                guard !d.isEmpty else {
                    throw NSError(domain: "Inf6PDF", code: 33, userInfo: [
                        NSLocalizedDescriptionKey: "Empty PDF data."
                    ])
                }
                return d
            } catch {
                throw NSError(domain: "Inf6PDF", code: 31, userInfo: [
                    NSLocalizedDescriptionKey: Inf6Lang.text(
                        "PDFデータの読み込みに失敗: \(error.localizedDescription)",
                        "Failed to load PDF data: \(error.localizedDescription)"
                    )
                ])
            }
        }

        let task = URLSession.shared.dataTask(with: req) { data, response, error in
            defer { semaphore.signal() }

            if let e = error {
                result = .failure(e)
                return
            }

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                result = .failure(NSError(domain: "Inf6PDF", code: http.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"
                ]))
                return
            }

            guard let d = data, !d.isEmpty else {
                result = .failure(NSError(domain: "Inf6PDF", code: 33, userInfo: [
                    NSLocalizedDescriptionKey: "Empty PDF data."
                ]))
                return
            }

            result = .success(d)
        }
        task.resume()

        let waitResult: DispatchTimeoutResult = semaphore.wait(timeout: .now() + 35)
        guard waitResult != .timedOut else {
            task.cancel()
            throw NSError(domain: "Inf6PDF", code: 34, userInfo: [
                NSLocalizedDescriptionKey: "PDF download timed out."
            ])
        }

        switch result {
        case .success(let d):
            return d
        case .failure(let e):
            throw NSError(domain: "Inf6PDF", code: 31, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "PDFデータの読み込みに失敗: \(e.localizedDescription)",
                    "Failed to load PDF data: \(e.localizedDescription)"
                )
            ])
        }
    }
}
