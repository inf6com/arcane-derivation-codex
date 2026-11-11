//
//  Inf6SyllabusDetailView2.swift
//  inf6
//
//  Created by decopin on 2026/01/23.
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
import WebKit
import ObjectiveC
import Security

// ============================================================================
// MARK: - Split 2/2 (Pipeline)
// 目的: 公式PDF探索 / PDFキャッシュ / アウトライン生成 / 解説PDF / E資格論文検索 / ダウンロード
//      などの処理系を extension にまとめ、後で別ファイルへ移し替えやすくする。
// ============================================================================
extension Inf6SyllabusDetailView {

    // MARK: - OpenAI config access (local)

    enum _Inf6OpenAIKeyReadError: LocalizedError {
        case emptyKey
        case notFound
        case unexpectedData
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .emptyKey:
                return Inf6Lang.text("OpenAI APIキーが空です。", "OpenAI API key is empty.")
            case .notFound:
                return Inf6Lang.text("OpenAI APIキーが未設定です。", "OpenAI API key is not set.")
            case .unexpectedData:
                return Inf6Lang.text("Keychain内のAPIキー形式が不正です。", "Unexpected API key data in Keychain.")
            case .keychain(let status):
                return Inf6Lang.text("Keychainエラー: \(status)", "Keychain error: \(status)")
            }
        }
    }

    func openAIModelNameForRequests() -> String {
        let raw = (UserDefaults.standard.string(forKey: "openai_model") ?? "")
        return raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    // MARK: - Language config (local)

    /// Read the generation language code used by the app (e.g. "ja" or "en").
    /// This MUST be configured; failures must surface.
    func _genLangRawOrThrow() throws -> String {
        let raw0 = (UserDefaults.standard.string(forKey: "gen_lang") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !raw0.isEmpty else {
            throw NSError(domain: "Inf6Lang", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Language is not configured (UserDefaults key: gen_lang)."
            ])
        }
        return raw0
    }
    
    
    func loadOpenAIAPIKeyOrThrowForRequests() throws -> String {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.inf6.openai",
            kSecAttrAccount as String: "api_key",
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)

        if status == errSecItemNotFound {
            throw _Inf6OpenAIKeyReadError.notFound
        }
        guard status == errSecSuccess else {
            throw _Inf6OpenAIKeyReadError.keychain(status)
        }
        guard let data = item as? Data, !data.isEmpty else {
            throw _Inf6OpenAIKeyReadError.unexpectedData
        }
        guard let s = String(data: data, encoding: .utf8) else {
            throw _Inf6OpenAIKeyReadError.unexpectedData
        }

        let key = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw _Inf6OpenAIKeyReadError.emptyKey
        }
        return key
    }

    var isIOSAppOnMacRuntime: Bool {
        if #available(iOS 14.0, *) {
            return ProcessInfo.processInfo.isiOSAppOnMac
        }
        return false
    }

    // MARK: - Sources: enabled-sources gate for E資格 paper search

    /// Resolve enabled paper sources from UserDefaults/AppStorage toggles.
    func _enabledPaperSources() -> [Inf6PaperSourceID] {
        Inf6EshikakuPaperSearch.enabledSources(userDefaults: .standard)
    }

    func _eshikakuUsingSourceOrThrow() throws -> (using: Inf6PaperSourceID, note: String?) {
        try Inf6EshikakuPaperSearch.usingSourceOrThrow(userDefaults: .standard)
    }

    func _paperSearchURL(for source: Inf6PaperSourceID, query: String) -> URL? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        return source.searchURL(query: q)
    }

    // MARK: - Outline row UI
    @ViewBuilder
    func outlineRow(_ item: Inf6SyllabusOutlineItem) -> some View {
        let isSelected = selectedOutlineKeys.contains(item.key)

        HStack(alignment: .top, spacing: 10) {
            Button {
                toggleOutlineSelection(item.key)
            } label: {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .imageScale(.medium)
                    .accessibilityLabel(isSelected ? Inf6Lang.text("選択解除", "Deselect") : Inf6Lang.text("選択", "Select"))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayTitle)
                    .font(.body)

                if let s = item.displaySummary?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                    Text(s)
                        .font(.body)
                        .foregroundStyle(.secondary)
                    //.textSelection(.enabled)
                }
            }
            .padding(.leading, CGFloat(item.effectiveDepth) * 12)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            toggleOutlineSelection(item.key)
        }
    }

    // MARK: - Outline selection helpers
    @MainActor
    func toggleOutlineSelection(_ key: String) {
        if selectedOutlineKeys.contains(key) {
            selectedOutlineKeys.remove(key)
        } else {
            selectedOutlineKeys.insert(key)
        }
    }

    private var resolvedLocalDepartment: Inf6CompassLocalDepartment? {
        let targetKey = syllabus.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetKey.isEmpty else { return nil }

        for school in Inf6CompassDefaultConfig.schools {
            for faculty in school.faculties {
                if let department = faculty.departments.first(where: { $0.key == targetKey }) {
                    return department
                }
            }
        }
        return nil
    }

    var resolvedLearningFamilyManifest: Inf6LearningFamilyManifest? {
        guard let department = resolvedLocalDepartment else { return nil }
        let candidates = [
            department.key,
            department.key.replacingOccurrences(of: "-quiz", with: "")
        ]
        for familyID in candidates {
            if let manifest = Inf6LearningFamilyManifestStore.load(familyID: familyID) {
                return manifest
            }
        }
        return nil
    }

    var isGkenteiCourse: Bool {
        guard let manifest = resolvedLearningFamilyManifest else { return false }
        return manifest.isJDLAOutlineFamily
    }

    var isEshikakuCourse: Bool {
        guard let manifest = resolvedLearningFamilyManifest else { return false }
        return manifest.supportsPaperSearchProviders
    }

    var isMicrosoftLearnKnowledgeCourse: Bool {
        guard let manifest = resolvedLearningFamilyManifest else { return false }
        return manifest.usesMicrosoftLearnProvider
            && !syllabus.id.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("-quiz")
    }

    // MARK: - Explanation PDF fixed path bridge (avoid private cross-file access)

    /// Return the fixed local path used by the syllabus detail view for the explanation PDF.
    /// This file must not call the private `_explanationPDFFileURLForCurrentSyllabus` directly.
    @MainActor
    func explanationPDFFixedFileURLForCurrentSyllabusOrThrow(createDirectoryIfNeeded: Bool) throws -> URL {
        let baseDir: URL
        if createDirectoryIfNeeded {
            baseDir = try _inf6EnsureDirectoryChainOrThrow(
                base: Inf6DataRoot.url(),
                components: ["inf6.com", "generated_pdfs"]
            )
        } else {
            baseDir = Inf6DataRoot.url()
                .appendingPathComponent("inf6.com", isDirectory: true)
                .appendingPathComponent("generated_pdfs", isDirectory: true)
        }

        // Require a stable identifier for the currently selected PDF to avoid collisions.
        let sid0 = (selectedSyllabusPDFID?.uuidString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sid0.isEmpty else {
            throw NSError(domain: "Inf6PDF", code: 120, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "保存先パスを決定できません（選択中のPDFがありません）。",
                    "Cannot determine the fixed path (no selected PDF)."
                )
            ])
        }

        func _sanitizeFileComponent(_ s: String) -> String {
            let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
            let cleaned = s.components(separatedBy: bad).joined(separator: "_")
            return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let sid = _sanitizeFileComponent(sid0)
        guard !sid.isEmpty else {
            throw NSError(domain: "Inf6PDF", code: 121, userInfo: [
                NSLocalizedDescriptionKey: "Cannot build a safe filename from selectedSyllabusPDFID."
            ])
        }

        // Keep filename deterministic and per-PDF.
        let fileName = "explanation_\(sid).pdf"
        return baseDir.appendingPathComponent(fileName, isDirectory: false)
    }

    // Split-target file: Inf6SyllabusDetailView+ExplanationAndPapers.swift

    // MARK: - Folder organization (strict; no silent fallback)

    /// Ensure `url` exists and is a directory. If missing, create it.
    /// If a non-directory already exists at the path, throw (do not overwrite).
    func _inf6EnsureDirectoryExistsOrThrow(_ url: URL) throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw NSError(domain: "Inf6FS", code: 10, userInfo: [
                    NSLocalizedDescriptionKey: "Expected a directory but found a file at: \(url.path)"
                ])
            }
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    /// Build (and validate) a directory chain from `base`, creating each component.
    /// This surfaces errors precisely (e.g., when a file blocks a directory path).
    func _inf6EnsureDirectoryChainOrThrow(base: URL, components: [String]) throws -> URL {
        var cur = base
        try _inf6EnsureDirectoryExistsOrThrow(cur)
        for comp in components {
            cur = cur.appendingPathComponent(comp, isDirectory: true)
            try _inf6EnsureDirectoryExistsOrThrow(cur)
        }
        return cur
    }

    func generatedPDFDirectoryURL() throws -> URL {
        // Strict folder organization: create/validate each path component.
        let dir = try _inf6EnsureDirectoryChainOrThrow(
            base: Inf6DataRoot.url(),
            components: [
                "inf6.com",
                "generated_pdfs"
            ]
        )

        return dir
    }

    func drawPDFText(_ attributed: NSAttributedString) -> Data? {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        let margin: CGFloat = 54
        let textRect = pageRect.insetBy(dx: margin, dy: margin)

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var mediaBox = pageRect
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        var currentRange = CFRange(location: 0, length: 0)
        let length = attributed.length

        while currentRange.location < length {
            ctx.beginPage(mediaBox: &mediaBox)
            ctx.saveGState()

            // PDF contexts already use Quartz coordinates (origin bottom-left, Y up).
            // Do NOT flip the context here; flipping causes mirrored/inverted text.
            ctx.textMatrix = .identity

            let path = CGMutablePath()
            path.addRect(textRect)

            let frame = CTFramesetterCreateFrame(framesetter, currentRange, path, nil)
            CTFrameDraw(frame, ctx)

            ctx.restoreGState()
            ctx.endPage()

            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length <= 0 { break }
            currentRange.location += visible.length
            currentRange.length = 0
        }

        ctx.closePDF()
        return data as Data
    }

    enum _Inf6WKPDFRenderError: LocalizedError {
        case webKitUnavailable
        case navigationFailed(String)
        case navigationTimeout
        case pdfTimeout
        case pdfEmpty

        var errorDescription: String? {
            switch self {
            case .webKitUnavailable:
                return "WebKit PDF 生成は iOS 14 以降が必要です。"
            case .navigationFailed(let msg):
                return "HTML の読み込みに失敗しました: \(msg)"
            case .navigationTimeout:
                return "HTML の読み込みがタイムアウトしました。"
            case .pdfTimeout:
                return "PDF 生成がタイムアウトしました。"
            case .pdfEmpty:
                return "生成されたPDFデータが空です。"
            }
        }
    }

    enum _Inf6GenerationTimeoutError: LocalizedError {
        case openAITimeout

        var errorDescription: String? {
            switch self {
            case .openAITimeout:
                return Inf6Lang.text(
                    "OpenAIの解説生成がタイムアウトしました。ネットワーク、またはAPI応答が停止しています。",
                    "OpenAI explanation generation timed out. The network or API response is stuck."
                )
            }
        }
    }

    @MainActor
    final class _Inf6WKNavWaiter: NSObject, WKNavigationDelegate {
        var cont: CheckedContinuation<Void, Error>?
        private var timeoutTask: Task<Void, Never>?
        private var didResume: Bool = false

        func loadHTMLOrThrow(webView: WKWebView, html: String, timeoutSeconds: Double = 30) async throws {
            // Cancel any previous timeout (defensive).
            timeoutTask?.cancel()
            timeoutTask = nil
            didResume = false

            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                self.cont = c
                webView.navigationDelegate = self
                webView.loadHTMLString(html, baseURL: nil)

                // Hard timeout: surface failure instead of hanging forever.
                let ns = UInt64(max(1, timeoutSeconds) * 1_000_000_000)
                self.timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: ns)
                    await MainActor.run {
                        if self.didResume { return }
                        self.didResume = true
                        self.cont?.resume(throwing: _Inf6WKPDFRenderError.navigationTimeout)
                        self.cont = nil
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if didResume { return }
            didResume = true
            timeoutTask?.cancel()
            timeoutTask = nil
            cont?.resume()
            cont = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if didResume { return }
            didResume = true
            timeoutTask?.cancel()
            timeoutTask = nil
            cont?.resume(throwing: error)
            cont = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if didResume { return }
            didResume = true
            timeoutTask?.cancel()
            timeoutTask = nil
            cont?.resume(throwing: error)
            cont = nil
        }
    }

    func _escapeHTML(_ s: String) -> String {
        s
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    func _wrapExplanationHTMLDocument(title: String, bodyHTML: String) -> String {
        let safeTitle = _escapeHTML(title)
        // bodyHTML is generated by the model; we embed it as-is to preserve headings/tables/formulas.
        return """
<!doctype html>
<html>
<head>
  <meta charset=\"utf-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
  <style>
    :root { color-scheme: light; }
    @media print {
      * { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
      body { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
    }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', Helvetica, Arial, sans-serif;
      font-size: 13.5px;
      line-height: 1.6;
      color: #111;
      background: #fff;
      margin: 0;
      padding: 28px 34px;
    }
    header {
      padding-bottom: 12px;
      margin-bottom: 18px;
      border-bottom: 1px solid #e6e6e6;
    }
    header h1 {
      margin: 0 0 4px 0;
      font-size: 22px;
      color: #0b57d0;
      letter-spacing: 0.2px;
    }
    header .meta {
      font-size: 11.5px;
      color: #666;
    }
    h1 { font-size: 18px; color: #0b57d0; margin: 18px 0 10px; }
    h2 { font-size: 16px; color: #1f1f1f; margin: 16px 0 8px; }
    h3 { font-size: 14px; color: #1f1f1f; margin: 12px 0 6px; }
    ul { margin: 6px 0 10px 18px; padding: 0; }
    li { margin: 4px 0; }
    hr { border: none; border-top: 1px solid #e6e6e6; margin: 18px 0; }
    code {
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, 'Liberation Mono', 'Courier New', monospace;
      font-size: 12px;
      background: #f3f5f7;
      padding: 1px 4px;
      border-radius: 4px;
    }
    .formula {
      font-family: 'Times New Roman', Times, serif;
      font-size: 15px;
      background: #f4f7ff;
      border-left: 4px solid #6c63ff;
      padding: 10px 12px;
      margin: 10px 0 12px;
      border-radius: 6px;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      margin: 10px 0 14px;
      table-layout: fixed;
      word-break: break-word;
    }
    th, td {
      border: 1px solid #d9d9d9;
      padding: 8px 8px;
      vertical-align: top;
    }
    th {
      background: #f7f7f7;
      font-weight: 600;
    }
  </style>
</head>
<body>
  <header>
    <h1>\(safeTitle)</h1>
    <div class=\"meta\">Generated by inf6</div>
  </header>
  \(bodyHTML)
</body>
</html>
"""
    }

    @MainActor
    func _renderHTMLToPDFDataOrThrow(html: String) async throws -> Data {
        guard #available(iOS 14.0, *) else {
            throw _Inf6WKPDFRenderError.webKitUnavailable
        }

        // US Letter @ 72dpi (matches existing CoreText renderer)
        let pageSize = CGSize(width: 612, height: 792)
        let paperRect = CGRect(origin: .zero, size: pageSize)

        let webView = WKWebView(frame: paperRect)
        webView.isOpaque = false
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white

        let waiter = _Inf6WKNavWaiter()
        do {
            try await waiter.loadHTMLOrThrow(webView: webView, html: html, timeoutSeconds: 30)
        } catch {
            throw _Inf6WKPDFRenderError.navigationFailed(error.localizedDescription)
        }

        // Ensure layout is up-to-date before PDF capture.
        webView.setNeedsLayout()
        webView.layoutIfNeeded()

        // Prefer WKWebView's native PDF exporter for offscreen rendering and iOS App on Mac.
        let data: Data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            var didResume = false

            // Hard timeout: surface failure instead of hanging forever.
            let timeoutNS: UInt64 = 30 * 1_000_000_000
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: timeoutNS)
                await MainActor.run {
                    if didResume { return }
                    didResume = true
                    cont.resume(throwing: _Inf6WKPDFRenderError.pdfTimeout)
                }
            }

            let cfg = WKPDFConfiguration()
            cfg.rect = paperRect

            webView.createPDF(configuration: cfg) { result in
                Task { @MainActor in
                    if didResume { return }
                    didResume = true
                    timeoutTask.cancel()
                    switch result {
                    case .success(let d):
                        cont.resume(returning: d)
                    case .failure(let e):
                        cont.resume(throwing: e)
                    }
                }
            }
        }

        guard !data.isEmpty else {
            throw _Inf6WKPDFRenderError.pdfEmpty
        }

        return data
    }

    struct _Inf6SnippetPlan {
        let maxTotalChars: Int
        let maxLinesPerHit: Int
        let maxHitBlocks: Int
        let maxHitLines: Int
    }

    func _inf6ExtractContextSnippetOrThrow(
        fullText: String,
        item: Inf6SyllabusOutlineItem,
        plan: _Inf6SnippetPlan
    ) throws -> String {
        let text0 = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text0.isEmpty else {
            throw NSError(domain: "Inf6OpenAI", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "PDF full text is empty"
            ])
        }

        func _lines(_ s: String) -> [String] {
            // Keep empty lines (they can carry structure), but trim trailing CR.
            return s
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0) }
        }

        func _normalizedTokens(_ s: String) -> [String] {
            let raw = s
                .replacingOccurrences(of: "（", with: " ")
                .replacingOccurrences(of: "）", with: " ")
                .replacingOccurrences(of: "(", with: " ")
                .replacingOccurrences(of: ")", with: " ")
                .replacingOccurrences(of: "・", with: " ")
                .replacingOccurrences(of: "、", with: " ")
                .replacingOccurrences(of: "/", with: " ")
                .replacingOccurrences(of: ":", with: " ")
                .replacingOccurrences(of: "：", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            return raw
                .components(separatedBy: .whitespacesAndNewlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        let title = item.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = (item.displaySummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = (title + " " + summary).trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens0 = _normalizedTokens(seed)
        let tokens = tokens0
            .filter { $0.count >= 2 }
            .prefix(12)
            .map { String($0) }

        guard !tokens.isEmpty else {
            throw NSError(domain: "Inf6OpenAI", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "Cannot build snippet tokens (item title/summary empty)"
            ])
        }

        let lines = _lines(text0)
        if lines.isEmpty {
            throw NSError(domain: "Inf6OpenAI", code: 22, userInfo: [
                NSLocalizedDescriptionKey: "PDF full text has no lines"
            ])
        }

        // Find hit line indices. A hit is any line containing any token (case-insensitive).
        var hitIdx: [Int] = []
        hitIdx.reserveCapacity(128)

        for (i, ln) in lines.enumerated() {
            if hitIdx.count >= plan.maxHitLines { break }
            let l = ln.localizedLowercase
            var ok = false
            for tok in tokens {
                if l.contains(tok.localizedLowercase) {
                    ok = true
                    break
                }
            }
            if ok {
                hitIdx.append(i)
            }
        }

        guard !hitIdx.isEmpty else {
            throw NSError(domain: "Inf6OpenAI", code: 23, userInfo: [
                NSLocalizedDescriptionKey: "No matching context found in PDF full text for the selected item"
            ])
        }

        // Build merged ranges around each hit.
        let half = max(0, plan.maxLinesPerHit / 2)
        var ranges: [(start: Int, end: Int)] = []
        ranges.reserveCapacity(min(plan.maxHitBlocks, hitIdx.count))

        for idx in hitIdx {
            if ranges.count >= plan.maxHitBlocks { break }
            let s = max(0, idx - half)
            let e = min(lines.count - 1, idx + half)
            // Merge if overlapping with the last.
            if var last = ranges.last, s <= (last.end + 1) {
                last.end = max(last.end, e)
                ranges[ranges.count - 1] = last
            } else {
                ranges.append((start: s, end: e))
            }
        }

        // Compose snippet with explicit separators.
        var out: [String] = []
        out.reserveCapacity(ranges.count * (plan.maxLinesPerHit + 4))

        for (k, r) in ranges.enumerated() {
            out.append("[ContextBlock #\(k+1) lines \(r.start+1)-\(r.end+1)]")
            if r.start <= r.end {
                for i in r.start...r.end {
                    out.append(lines[i])
                }
            }
            out.append("[EndContextBlock #\(k+1)]")
            out.append("")
        }

        var joined = out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if joined.count > plan.maxTotalChars {
            joined = String(joined.prefix(plan.maxTotalChars))
        }
#if DEBUG
        let lineCount = joined
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .count
        print("[Inf6Snippet] item=\(item.displayTitle) tokens=\(tokens.count) hits=\(hitIdx.count) ranges=\(ranges.count) lines=\(lineCount) chars=\(joined.count)")
#endif
        guard !joined.isEmpty else {
            throw NSError(domain: "Inf6OpenAI", code: 24, userInfo: [
                NSLocalizedDescriptionKey: "Extracted context snippet is empty"
            ])
        }
        return joined
    }

    // MARK: - Retry hint (G検定 Explanation)

    private func _buildGkenteiRetryHintFromLastError(_ error: Error) -> String? {
        let ns = error as NSError
        guard ns.domain == "Inf6OpenAI" else { return nil }

        // Convert validation failures into short, actionable retry instructions.
        switch ns.code {
        case 10:
            // Missing required section / table / formula / MathML.
            let raw = (ns.userInfo[NSLocalizedDescriptionKey] as? String) ?? ns.localizedDescription

            if raw.contains("必須セクション") {
                // Try to extract the missing <h2> title if the message contains it.
                if let re = try? NSRegularExpression(pattern: "<h2>\\s*([^<]+?)\\s*<\\/h2>", options: [.caseInsensitive]) {
                    let s = raw as NSString
                    let ms = re.matches(in: raw, options: [], range: NSRange(location: 0, length: s.length))
                    let titles = ms.compactMap { m -> String? in
                        guard m.numberOfRanges >= 2 else { return nil }
                        let t = s.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                        return t.isEmpty ? nil : t
                    }
                    if !titles.isEmpty {
                        return Inf6Lang.text(
                            "前回の出力で必須セクションが不足しました。次は不足分の <h2> 見出しを“完全一致”で必ず含めてください: \(titles.joined(separator: ", "))。",
                            "Previous output missed required sections. Include these <h2> headings EXACTLY: \(titles.joined(separator: ", "))."
                        )
                    }
                }
                return Inf6Lang.text(
                    "前回の出力で必須セクションが不足しました。必須の <h2> 見出しを漏れなく“完全一致”で含めてください。",
                    "Previous output missed required sections. Include all required <h2> headings EXACTLY."
                )
            }

            if raw.contains("<table>") || raw.contains("<table") {
                return Inf6Lang.text(
                    "前回の出力で表が不足しました。次は必ず <table>…</table> を1つ以上含めてください。",
                    "Previous output missed a table. Include at least one <table>…</table>."
                )
            }

            if raw.contains("数式ブロック") {
                return Inf6Lang.text(
                    "前回の出力で数式ブロックが不足しました。次は必ず <div class=\"formula\">…</div> を含め、内部は MathML（<math xmlns=\"http://www.w3.org/1998/Math/MathML\">…</math>）だけにしてください。",
                    "Previous output missed a formula block. Include <div class=\"formula\">…</div> and put ONLY MathML inside (<math xmlns=\"http://www.w3.org/1998/Math/MathML\">…</math>)."
                )
            }

            if raw.contains("MathML") || raw.contains("<math") {
                return Inf6Lang.text(
                    "前回の出力で MathML が不足しました。数式は必ず <math xmlns=\"http://www.w3.org/1998/Math/MathML\">…</math> の MathML として出力してください。\\ や _ や { } などの TeX 風文字列を数式ブロック内に一切出さないでください。",
                    "Previous output missed MathML. Output formulas as MathML with <math xmlns=\"http://www.w3.org/1998/Math/MathML\">…</math>. Do NOT emit TeX-like text (\\, _, { })."
                )
            }

            return Inf6Lang.text(
                "前回の出力がフォーマット要件を満たしませんでした。必須の見出し/表/数式（MathML）を契約どおりに出力してください。",
                "Previous output did not satisfy the format contract. Emit all required headings, a table, and MathML formulas."
            )

        case 11:
            return Inf6Lang.text(
                "前回の出力が空でした。必須セクション一式と、表と、MathML の数式ブロックを含むHTML断片を出力してください。",
                "Previous output was empty. Output the required HTML fragment with all required sections, a table, and MathML formulas."
            )

        default:
            return nil
        }
    }

    // Strict per-item structure validator for G検定 explanations.
    // If the model returns plain text or omits required sections (figure/table/formula), fail explicitly.
    func _validateGkenteiItemHTMLFragmentOrThrow(_ html: String) throws {
        let s = html.trimmingCharacters(in: .whitespacesAndNewlines)
        let genLangRaw = try _genLangRawOrThrow()
        _ = genLangRaw
        guard !s.isEmpty else {
            throw NSError(domain: "Inf6OpenAI", code: 10, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "生成結果が空です（HTML断片がありません）。",
                    "Generated output is empty (no HTML fragment)."
                )
            ])
        }

        // Required section headings (must exist at least once each).
        // Headings are unified to English to match the figure/table pipeline and avoid mixed-language detection issues.
        let requiredHeadings: [String] = [
            "<h2>Key points (exam framing)</h2>",
            "<h2>Keywords</h2>",
            "<h2>Core idea</h2>",
            "<h2>Figure</h2>",
            "<h2>Table</h2>",
            "<h2>Formula</h2>",
            "<h2>Common traps / misconceptions</h2>",
            "<h2>Memorization points</h2>",
            "<h2>Mini quiz (3)</h2>",
            "<h2>Answers</h2>",
            "<h2>One concrete example</h2>",
            "<h2>Comparison (vs similar concepts)</h2>"
        ]

        for h in requiredHeadings {
            if !s.contains(h) {
                throw NSError(domain: "Inf6OpenAI", code: 10, userInfo: [
                    NSLocalizedDescriptionKey: Inf6Lang.text(
                        "生成結果の形式が不正です（必須セクションが不足）: \(h)",
                        "Invalid output format (missing required section): \(h)"
                    )
                ])
            }
        }

        // Must include at least one table.
        if !s.lowercased().contains("<table") {
            throw NSError(domain: "Inf6OpenAI", code: 10, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "生成結果の形式が不正です（表 <table> がありません）。",
                    "Invalid output format (missing <table>)."
                )
            ])
        }

        // Must include a formula block with MathML.
        let lower = s.lowercased()
        if !lower.contains("<div class=\"formula\">") {
            throw NSError(domain: "Inf6OpenAI", code: 10, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "生成結果の形式が不正です（数式ブロック <div class=\"formula\"> がありません）。",
                    "Invalid output format (missing <div class=\"formula\">)."
                )
            ])
        }
        if !lower.contains("<math") || !lower.contains("xmlns=\"http://www.w3.org/1998/math/mathml\"") {
            throw NSError(domain: "Inf6OpenAI", code: 10, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "生成結果の形式が不正です（MathML の <math xmlns=...> がありません）。",
                    "Invalid output format (missing MathML <math xmlns=...>)."
                )
            ])
        }
    }

    // Strict HTML fragment validator: only allow safe tags, no forbidden HTML elements.
    func _validateExplanationHTMLFragmentOrThrow(_ html: String) throws {
        let s = html.lowercased()
        let forbidden = [
            "<script", "</script",
            "<html", "</html",
            "<head", "</head",
            "<body", "</body",
            "<meta", "<link", "<style", "</style",
            "<iframe", "</iframe",
            "<object", "</object",
            "<embed", "</embed",
            "<svg", "</svg",
            "<mathml", "</mathml"
        ]
        if forbidden.contains(where: { s.contains($0) }) {
            throw NSError(domain: "Inf6OpenAI", code: 9, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "生成結果に許可されていないHTML要素が含まれています。",
                    "Generated output contains forbidden HTML elements."
                )
            ])
        }

        // Allow-list tag validation (minimal, strict): reject any HTML tag not in the allowed set.
        // This prevents newly-introduced executable/interactive elements.
        let allowedTags: Set<String> = [
            "h2","h3","p","ul","ol","li","table","thead","tbody","tr","th","td","pre","code","hr","div",
            // MathML
            "math","mrow","mi","mo","mn","mfrac","msup","msub","munder","mover","munderover",
            "mtable","mtr","mtd"
        ]

        // Scan for tag names like <tag ...> or </tag>
        // If we find a tag whose name is not in allowedTags, throw.
        var idx = s.startIndex
        while idx < s.endIndex {
            guard let lt = s[idx...].firstIndex(of: "<") else { break }
            guard let gt = s[lt...].firstIndex(of: ">") else { break }
            let inner = s[s.index(after: lt)..<gt]
            // Skip comments / doctype
            if inner.hasPrefix("!") {
                idx = s.index(after: gt)
                continue
            }
            // Extract tag name
            let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                idx = s.index(after: gt)
                continue
            }
            var name = trimmed
            if name.hasPrefix("/") { name.removeFirst() }
            // Drop attributes
            if let sp = name.firstIndex(where: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "/" }) {
                name = String(name[..<sp])
            }
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && !allowedTags.contains(name) {
                throw NSError(domain: "Inf6OpenAI", code: 9, userInfo: [
                    NSLocalizedDescriptionKey: Inf6Lang.text(
                        "生成結果に許可されていないHTML要素が含まれています: <\(name)>",
                        "Generated output contains forbidden HTML elements: <\(name)>"
                    )
                ])
            }
            idx = s.index(after: gt)
        }
    }

    // MARK: - English/Japanese output + pipeline-friendly headings (G検定)

    func generateExplanationHTMLFragmentViaGPT(
        apiKey: String,
        courseTitle: String,
        pdfTitle: String,
        selectedItems: [Inf6SyllabusOutlineItem],
        fullText: String
    ) async throws -> String {
        let key = apiKey.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw _Inf6OpenAIKeyReadError.emptyKey
        }

        let snippetPlan = _Inf6SnippetPlan(
            maxTotalChars: 3_600,
            maxLinesPerHit: 14,
            maxHitBlocks: 5,
            maxHitLines: 180
        )

        let model = openAIModelNameForRequests()
        guard !model.isEmpty else {
            throw NSError(domain: "Inf6OpenAI", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "OpenAI model is not configured"
            ])
        }

        let client = OpenAIClient(
            apiKey: key,
            config: try OpenAIClient.Config.default(model: model)
        )

        let genLangRaw = try _genLangRawOrThrow()
        let isEnglishOutput = (genLangRaw == "en")

        func _selectedItemListText(_ it: Inf6SyllabusOutlineItem) -> String {
            let title = it.displayTitle
            let summary = (it.displaySummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if summary.isEmpty {
                return "- \(title)"
            } else {
                return "- \(title)\n  - \(summary)"
            }
        }

        // Deterministic, stable order: preserve the on-screen outline order.
        let selectedKeySet = Set(selectedItems.map { $0.key })
        let orderedSelected: [Inf6SyllabusOutlineItem] = syllabusOutlineItems.filter { selectedKeySet.contains($0.key) }
        let itemsToExplain = orderedSelected.isEmpty ? selectedItems : orderedSelected

        var blocks: [String] = []
        blocks.reserveCapacity(itemsToExplain.count * 2)

        let gkenteiRef = isEnglishOutput
            ? Inf6PromptCatalog.syllabusDetailGKenteiEn
            : Inf6PromptCatalog.syllabusDetailGKenteiJa

        for it in itemsToExplain {
            let pdfSnippet = try _inf6ExtractContextSnippetOrThrow(fullText: fullText, item: it, plan: snippetPlan)
            let selectedItem = _selectedItemListText(it)

            // Bounded regeneration: retry before surfacing a hard failure.
            // This is NOT a fallback; we still fail if the strict contract cannot be satisfied.
            let maxAttempts = 3
            var lastError: Error?
            var out: String = ""

            for _ in 1...maxAttempts {
                try Task.checkCancellation()
                try await _inf6OpenAIRateLimiter.wait(minIntervalSeconds: 1.6)

                let rendered = try Inf6PromptGovernance.renderSystemUserPrompt(
                    ref: gkenteiRef,
                    variables: [
                        "course_title": courseTitle,
                        "pdf_title": pdfTitle,
                        "selected_item": selectedItem,
                        "pdf_snippet": pdfSnippet
                    ]
                )

                let outRaw = try await client.generateText(
                    messages: [
                        .init(role: .system, text: rendered.systemInstruction),
                        .init(role: .user, text: rendered.userPrompt)
                    ],
                    options: .init(
                        maxOutputTokens: 3600,
                        modelOverride: nil
                    )
                )

                out = outRaw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                if out.isEmpty {
                    lastError = NSError(domain: "Inf6OpenAI", code: 3, userInfo: [
                        NSLocalizedDescriptionKey: Inf6Lang.text("OpenAI の応答が空です。", "OpenAI response is empty.")
                    ])
                    continue
                }

                do {
                    try _validateGkenteiItemHTMLFragmentOrThrow(out)
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    continue
                }
            }

            if let lastError {
                throw lastError
            }

            // Keep a clear per-item boundary in the combined HTML fragment.
            let title = it.displayTitle.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !title.isEmpty {
                let safeTitle = _escapeHTML(title)
                blocks.append("<h2>\(safeTitle)</h2>\n\n\(out)")
            } else {
                blocks.append(out)
            }
        }

        let combined = blocks.joined(separator: "\n\n<hr>\n\n").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !combined.isEmpty else {
            throw NSError(domain: "Inf6OpenAI", code: 3, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text("OpenAI の応答が空です。", "OpenAI response is empty.")
            ])
        }
        return combined
    }

    func microsoftLearnSourceDefinitionsOrThrow() throws -> [Inf6MicrosoftLearnSourceDefinition] {
        let key = syllabus.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let manifest = Inf6LearningFamilyManifestStore.load(familyID: key) else {
            throw NSError(domain: "Inf6MicrosoftLearn", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported Microsoft qualification: \(key)"
            ])
        }
        guard let definitions = manifest.currentSources, !definitions.isEmpty else {
            throw NSError(domain: "Inf6MicrosoftLearn", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Microsoft Learn source definitions are empty for \(key)."
            ])
        }
        return definitions
    }

    func fetchMicrosoftLearnSourcesOrThrow(
        definitions: [Inf6MicrosoftLearnSourceDefinition]
    ) async throws -> [Inf6MicrosoftLearnFetchedSource] {
        guard !definitions.isEmpty else {
            throw NSError(domain: "Inf6MicrosoftLearn", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Microsoft Learn source definitions are empty."
            ])
        }

        var out: [Inf6MicrosoftLearnFetchedSource] = []
        out.reserveCapacity(definitions.count)
        for definition in definitions {
            try Task.checkCancellation()
            let item = try await _fetchMicrosoftLearnSourceOrThrow(definition)
            out.append(item)
        }
        return out
    }

    private func _fetchMicrosoftLearnSourceOrThrow(
        _ definition: Inf6MicrosoftLearnSourceDefinition
    ) async throws -> Inf6MicrosoftLearnFetchedSource {
        guard let url = URL(string: definition.urlString), url.scheme != nil else {
            throw NSError(domain: "Inf6MicrosoftLearn", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Invalid Microsoft Learn URL: \(definition.urlString)"
            ])
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("inf6.com/Microsoft Learn Fetcher", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Inf6MicrosoftLearn", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Microsoft Learn response is not HTTP."
            ])
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw NSError(domain: "Inf6MicrosoftLearn", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Microsoft Learn fetch failed (\(http.statusCode)): \(snippet)"
            ])
        }
        guard let html = String(data: data, encoding: .utf8), !html.isEmpty else {
            throw NSError(domain: "Inf6MicrosoftLearn", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Microsoft Learn HTML is empty: \(definition.urlString)"
            ])
        }

        let mainHTML = _extractMicrosoftLearnMainHTML(html)
        let excerpt = _extractMicrosoftLearnExcerpt(mainHTML)
        guard !excerpt.isEmpty else {
            throw NSError(domain: "Inf6MicrosoftLearn", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Microsoft Learn excerpt is empty: \(definition.urlString)"
            ])
        }

        let title = _extractMicrosoftLearnTitle(mainHTML: mainHTML, fullHTML: html, fallback: definition.title)
        let lastUpdated = _extractMicrosoftLearnLastUpdated(fullHTML: html)
        let finalURLString = (http.url ?? url).absoluteString
        let resolution = _resolveMicrosoftLearnRole(
            definition: definition,
            finalURLString: finalURLString,
            title: title,
            excerpt: excerpt
        )
        let checkedAt = ISO8601DateFormatter().string(from: Date())

        return .init(
            id: definition.id,
            topic: definition.topic,
            title: title,
            requestedURL: definition.urlString,
            finalURL: finalURLString,
            roleHint: definition.roleHint,
            resolvedRole: resolution.role,
            httpStatus: http.statusCode,
            checkedAt: checkedAt,
            lastUpdated: lastUpdated,
            evidence: resolution.evidence,
            excerpt: excerpt
        )
    }

    private func _extractMicrosoftLearnMainHTML(_ html: String) -> String {
        let patterns = [
            "(?is)<main[^>]*>(.*?)</main>",
            "(?is)<article[^>]*>(.*?)</article>"
        ]
        for pattern in patterns {
            if let hit = _firstRegexCapture(pattern: pattern, in: html) {
                let trimmed = hit.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return html
    }

    private func _extractMicrosoftLearnTitle(mainHTML: String, fullHTML: String, fallback: String) -> String {
        let candidates = [
            _firstRegexCapture(pattern: "(?is)<h1[^>]*>(.*?)</h1>", in: mainHTML),
            _firstRegexCapture(pattern: "(?is)<meta[^>]+property=[\"']og:title[\"'][^>]+content=[\"']([^\"']+)[\"']", in: fullHTML),
            _firstRegexCapture(pattern: "(?is)<title[^>]*>(.*?)</title>", in: fullHTML)
        ]
        for item in candidates {
            let normalized = _normalizeMicrosoftLearnPlainText(_decodeMicrosoftLearnHTMLEntities(_stripMicrosoftLearnHTMLTags(item ?? "")))
            if !normalized.isEmpty { return normalized }
        }
        return fallback
    }

    private func _extractMicrosoftLearnLastUpdated(fullHTML: String) -> String? {
        let patterns = [
            "(?is)<meta[^>]+name=[\"']ms\\.date[\"'][^>]+content=[\"']([^\"']+)[\"']",
            "(?is)<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+name=[\"']ms\\.date[\"']"
        ]
        for pattern in patterns {
            if let hit = _firstRegexCapture(pattern: pattern, in: fullHTML) {
                let trimmed = hit.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private func _extractMicrosoftLearnExcerpt(_ html: String) -> String {
        var body = html
        for tag in ["script", "style", "svg", "nav"] {
            body = _removeMicrosoftLearnHTMLBlock(tag: tag, from: body)
        }

        let replacements: [(String, String)] = [
            ("(?i)<br\\s*/?>", "\n"),
            ("(?i)</p>", "\n"),
            ("(?i)</li>", "\n"),
            ("(?i)</tr>", "\n"),
            ("(?i)</h1>", "\n"),
            ("(?i)</h2>", "\n"),
            ("(?i)</h3>", "\n"),
            ("(?i)</h4>", "\n"),
            ("(?i)</section>", "\n")
        ]
        for (pattern, replacement) in replacements {
            body = body.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }

        let decoded = _decodeMicrosoftLearnHTMLEntities(body)
        let plain = _stripMicrosoftLearnHTMLTags(decoded)
        let normalized = _normalizeMicrosoftLearnPlainText(plain)
        if normalized.count <= 2800 { return normalized }
        return String(normalized.prefix(2800))
    }

    private func _resolveMicrosoftLearnRole(
        definition: Inf6MicrosoftLearnSourceDefinition,
        finalURLString: String,
        title: String,
        excerpt: String
    ) -> (role: Inf6MicrosoftLearnSourceRole, evidence: [String]) {
        let lower = (title + "\n" + excerpt + "\n" + finalURLString).localizedLowercase
        var evidence: [String] = ["hint:\(definition.roleHint.rawValue)"]

        if lower.contains("deprecated") {
            evidence.append("text:deprecated")
            return (.discontinued, evidence)
        }
        if lower.contains("retired") || lower.contains("will retire") || lower.contains("no longer supported") {
            evidence.append("text:retired")
            return (.discontinued, evidence)
        }
        if definition.roleHint == .wrapper {
            evidence.append("role:wrapper")
            return (.wrapper, evidence)
        }
        if definition.roleHint == .legacyDetail {
            if lower.contains("replaced by") || lower.contains("use") && lower.contains("instead") {
                evidence.append("text:replacement guidance")
            }
            evidence.append("role:legacy_detail")
            return (.legacyDetail, evidence)
        }
        if lower.contains("form recognizer") {
            evidence.append("text:legacy brand form recognizer")
            return (.legacyDetail, evidence)
        }
        evidence.append("role:current")
        return (.current, evidence)
    }

    func generateMicrosoftLearnKnowledgeHTMLFragmentViaGPT(
        apiKey: String,
        qualificationTitle: String,
        sources: [Inf6MicrosoftLearnFetchedSource]
    ) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw _Inf6OpenAIKeyReadError.emptyKey
        }
        guard !sources.isEmpty else {
            throw NSError(domain: "Inf6MicrosoftLearn", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Microsoft Learn sources are empty."
            ])
        }

        let model = openAIModelNameForRequests()
        guard !model.isEmpty else {
            throw NSError(domain: "Inf6OpenAI", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "OpenAI model is not configured"
            ])
        }

        let client = OpenAIClient(
            apiKey: key,
            config: try OpenAIClient.Config.default(model: model)
        )

        let sourcePayload = _microsoftLearnPromptPayload(sources)
        let rendered = try Inf6PromptGovernance.renderSystemUserPrompt(
            ref: Inf6PromptCatalog.syllabusDetailMicrosoftLearnQualification,
            variables: [
                "qualification_title": qualificationTitle,
                "source_payload": sourcePayload
            ]
        )

        let outRaw = try await client.generateText(
            messages: [
                .init(role: .system, text: rendered.systemInstruction),
                .init(role: .user, text: rendered.userPrompt)
            ],
            options: .init(
                maxOutputTokens: 7200,
                modelOverride: nil
            )
        )

        let sanitized = _sanitizeMicrosoftLearnHTMLFragment(outRaw)
        guard !sanitized.isEmpty else {
            throw NSError(domain: "Inf6MicrosoftLearn", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "OpenAI returned an empty Microsoft Learn HTML fragment."
            ])
        }
        return sanitized
    }

    private func _microsoftLearnPromptPayload(_ sources: [Inf6MicrosoftLearnFetchedSource]) -> String {
        var lines: [String] = []
        lines.reserveCapacity(sources.count * 8)

        for source in sources {
            lines.append("[\(source.id)] \(source.title)")
            lines.append("topic: \(source.topic)")
            lines.append("role_hint: \(source.roleHint.rawValue)")
            lines.append("resolved_role: \(source.resolvedRole.rawValue)")
            if let lastUpdated = source.lastUpdated, !lastUpdated.isEmpty {
                lines.append("last_updated: \(lastUpdated)")
            }
            if !source.evidence.isEmpty {
                lines.append("evidence: \(source.evidence.joined(separator: ", "))")
            }
            lines.append("excerpt:")
            lines.append(source.excerpt)
            lines.append("---")
        }

        return lines.joined(separator: "\n")
    }

    private func _sanitizeMicrosoftLearnHTMLFragment(_ raw: String) -> String {
        var out = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.hasPrefix("```") {
            out = out.replacingOccurrences(of: "^```[a-zA-Z0-9_-]*\\n?", with: "", options: .regularExpression)
            out = out.replacingOccurrences(of: "\\n?```$", with: "", options: .regularExpression)
        }

        let patterns = [
            "(?is)<!doctype[^>]*>",
            "(?is)<html[^>]*>",
            "(?is)</html>",
            "(?is)<head[^>]*>.*?</head>",
            "(?is)<body[^>]*>",
            "(?is)</body>",
            "(?is)<script[^>]*>.*?</script>",
            "(?is)<style[^>]*>.*?</style>"
        ]
        for pattern in patterns {
            out = out.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func _firstRegexCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges >= 2 else {
            return nil
        }
        guard let hitRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[hitRange])
    }

    private func _removeMicrosoftLearnHTMLBlock(tag: String, from html: String) -> String {
        let lower = html.lowercased()
        let openNeedle = "<" + tag.lowercased()
        let closeNeedle = "</" + tag.lowercased() + ">"

        var out = ""
        var cursor = lower.startIndex
        while let open = lower.range(of: openNeedle, range: cursor..<lower.endIndex) {
            out += String(html[cursor..<open.lowerBound])
            guard let close = lower.range(of: closeNeedle, range: open.upperBound..<lower.endIndex) else {
                return out
            }
            cursor = close.upperBound
        }
        out += String(html[cursor..<html.endIndex])
        return out
    }

    private func _stripMicrosoftLearnHTMLTags(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var inTag = false
        for ch in s {
            if inTag {
                if ch == ">" { inTag = false }
                continue
            }
            if ch == "<" {
                inTag = true
                continue
            }
            out.append(ch)
        }
        return out
    }

    private func _decodeMicrosoftLearnHTMLEntities(_ s: String) -> String {
        return s
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    private func _normalizeMicrosoftLearnPlainText(_ s: String) -> String {
        var out = s
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: " ")
        while out.contains("  ") {
            out = out.replacingOccurrences(of: "  ", with: " ")
        }
        while out.contains("\n\n\n") {
            out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
