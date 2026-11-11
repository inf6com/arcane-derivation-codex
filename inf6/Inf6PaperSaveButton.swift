//
//  Inf6PaperSaveButton.swift
//  inf6
//

import SwiftUI
import PDFKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Inf6PaperSaveButton (REPLACED)

struct Inf6PaperSaveButton: View {
    let result: Inf6PaperSearchResult
    let pdfURL: URL
    let saveFolderURL: URL?
    let saveFolderErrorText: String?

    init(
        result: Inf6PaperSearchResult,
        pdfURL: URL,
        saveFolderURL: URL? = nil,
        saveFolderErrorText: String? = nil
    ) {
        self.result = result
        self.pdfURL = pdfURL
        self.saveFolderURL = saveFolderURL
        self.saveFolderErrorText = saveFolderErrorText
    }

    @State private var _isSaving: Bool = false
    @State private var _lastError: String? = nil
    @State private var _savedFileName: String? = nil
    @State private var _savedFileURL: URL? = nil
    @State private var _isAlreadySaved: Bool = false
    @State private var _alreadySavedCheckedPath: String = ""
    @State private var _isUpdateAvailable: Bool = false
    @State private var _localArxivVersion: Int? = nil
    @State private var _remoteArxivVersion: Int? = nil
    @State private var _localArxivBaseID: String? = nil



    @Environment(\.dismiss) private var dismiss

    // MARK: - Open saved PDF in-app (security-scope grace window)

    @MainActor
    private func _openSavedPDFInApp(_ pdfURL: URL, folderURL: URL?) {
        // When the PDF lives under a user-selected iCloud Drive folder, the app often needs an active
        // security-scoped access session to open the file without triggering a system picker.
        // Keep the folder access open briefly while we hand off the URL.
        var didStart: Bool = false
        if let folderURL {
            didStart = folderURL.startAccessingSecurityScopedResource()
        }

        NotificationCenter.default.post(
            name: Notification.Name("inf6.openSavedPaperPDFInLibrary"),
            object: pdfURL,
            userInfo: {
                guard let folderURL else { return nil }
                return ["inf6.folderURL": folderURL]
            }()
        )

        // Stop access after a short grace window so the receiver can open/read immediately.
        if didStart, let folderURL {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        dismiss()
    }

    @MainActor
    private func _copyToPasteboard(_ text: String) -> Bool {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        return true
        #else
        return false
        #endif
    }

    // MARK: - arXiv version helpers (local)

    private func _parseArxivIDAndVersion(fromCandidate sRaw: String) -> (base: String, version: Int?) {
        let s0 = sRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s0.isEmpty { return ("", nil) }

        // Accept forms like:
        //   "2602.17205v1"
        //   "arxiv:2602.17205v1"
        //   "https://arxiv.org/abs/2602.17205v1"
        // Extract the last path component when it looks like a URL.
        let s: String = {
            if let u = URL(string: s0), !u.lastPathComponent.isEmpty {
                return u.lastPathComponent
            }
            if s0.lowercased().hasPrefix("arxiv:") {
                return String(s0.dropFirst("arxiv:".count))
            }
            return s0
        }()

        // Split into base and optional version suffix "v<digits>".
        guard let vPos = s.lastIndex(of: "v") else {
            return (s, nil)
        }

        // Ensure "v" is followed by digits.
        let afterV = s.index(after: vPos)
        guard afterV < s.endIndex else {
            return (s, nil)
        }

        var digits = ""
        var i = afterV
        while i < s.endIndex {
            let ch = s[i]
            if ch >= "0" && ch <= "9" {
                digits.append(ch)
                i = s.index(after: i)
                continue
            }
            break
        }

        guard !digits.isEmpty, let n = Int(digits) else {
            return (s, nil)
        }

        let base = String(s[..<vPos])
        return (base, n)
    }

    private func _remoteArxivBaseAndVersion() -> (base: String, version: Int?) {
        if let u = result.landingURL {
            let parsed = _parseArxivIDAndVersion(fromCandidate: u.absoluteString)
            if !parsed.base.isEmpty {
                return parsed
            }
        }
        // Fallback to result.id (often "arxiv:<id>" derived from abs URL)
        return _parseArxivIDAndVersion(fromCandidate: result.id)
    }

    private func _resolveLatestArxivForSaveOrThrow(base: String) async throws -> (pdfURL: URL, absURLString: String, version: Int?) {
        let cleanBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBase.isEmpty else {
            throw NSError(
                domain: "Inf6PaperSave",
                code: -90,
                userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("arXiv ID が空のため、最新版を確認できません。", "Cannot check latest arXiv version: empty arXiv id.")]
            )
        }

        var components = URLComponents(string: "https://export.arxiv.org/api/query")
        components?.queryItems = [URLQueryItem(name: "id_list", value: cleanBase)]
        guard let feedURL = components?.url else {
            throw NSError(
                domain: "Inf6PaperSave",
                code: -91,
                userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("arXiv API URL の生成に失敗しました。", "Failed to build arXiv API URL.")]
            )
        }

        let (data, response) = try await URLSession.shared.data(from: feedURL)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(
                domain: "Inf6PaperSave",
                code: -92,
                userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("arXiv API 応答の解析に失敗しました。", "Failed to parse arXiv API response.")]
            )
        }
        guard (200...299).contains(http.statusCode) else {
            throw NSError(
                domain: "Inf6PaperSave",
                code: -93,
                userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("arXiv API が失敗しました。HTTP \(http.statusCode)", "arXiv API failed. HTTP \(http.statusCode)")]
            )
        }
        guard let xml = String(data: data, encoding: .utf8), !xml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(
                domain: "Inf6PaperSave",
                code: -94,
                userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("arXiv API の応答本文が空です。", "arXiv API returned an empty response body.")]
            )
        }

        let escapedBase = NSRegularExpression.escapedPattern(for: cleanBase)
        let nsRange = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        var resolvedVersion: Int? = nil
        if let versionRegex = try? NSRegularExpression(pattern: escapedBase + "v([0-9]+)", options: [.caseInsensitive]) {
            for m in versionRegex.matches(in: xml, options: [], range: nsRange) {
                guard m.numberOfRanges >= 2, let vr = Range(m.range(at: 1), in: xml) else { continue }
                let vText = String(xml[vr])
                guard let v = Int(vText) else { continue }
                if let cur = resolvedVersion {
                    resolvedVersion = max(cur, v)
                } else {
                    resolvedVersion = v
                }
            }
        }

        let absURLString: String
        if let v = resolvedVersion {
            absURLString = "https://arxiv.org/abs/\(cleanBase)v\(v)"
        } else {
            if let noVersionRegex = try? NSRegularExpression(pattern: escapedBase + "(?!v[0-9])", options: [.caseInsensitive]),
               noVersionRegex.firstMatch(in: xml, options: [], range: nsRange) != nil {
                absURLString = "https://arxiv.org/abs/\(cleanBase)"
            } else {
                throw NSError(
                    domain: "Inf6PaperSave",
                    code: -95,
                    userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("arXiv 最新版IDの解析に失敗しました。", "Failed to parse latest arXiv id from API response.")]
                )
            }
        }

        let pdfURLString: String
        if let v = resolvedVersion {
            pdfURLString = "https://arxiv.org/pdf/\(cleanBase)v\(v).pdf"
        } else {
            pdfURLString = "https://arxiv.org/pdf/\(cleanBase).pdf"
        }
        guard let latestPDFURL = URL(string: pdfURLString) else {
            throw NSError(
                domain: "Inf6PaperSave",
                code: -96,
                userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("arXiv 最新PDF URLの生成に失敗しました。", "Failed to build latest arXiv PDF URL.")]
            )
        }
        return (latestPDFURL, absURLString, resolvedVersion)
    }

    private func _resolveDownloadTargetForSaveOrThrow() async throws -> (downloadURL: URL, sidecarBase: String, sidecarVersion: Int?, sourceURLOverride: String?) {
        let provider = _paperProviderKey()
        if provider == "arxiv" {
            let remote = _remoteArxivBaseAndVersion()
            guard !remote.base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(
                    domain: "Inf6PaperSave",
                    code: -97,
                    userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("arXiv 論文のIDを特定できないため、保存できません。", "Cannot save arXiv paper because arXiv id could not be determined.")]
                )
            }
            let latest = try await _resolveLatestArxivForSaveOrThrow(base: remote.base)
            return (
                downloadURL: latest.pdfURL,
                sidecarBase: remote.base,
                sidecarVersion: latest.version,
                sourceURLOverride: latest.absURLString
            )
        }

        let sourceURLOverride = (
            result.pdfURL?.absoluteString ??
            result.landingURL?.absoluteString ??
            ""
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        return (
            downloadURL: pdfURL,
            sidecarBase: "",
            sidecarVersion: nil,
            sourceURLOverride: sourceURLOverride.isEmpty ? nil : sourceURLOverride
        )
    }

    private func _arxivSidecarURL(forPDF destPDFURL: URL) -> URL {
        // "paper.pdf" -> "paper.pdf.arxiv"
        return destPDFURL.appendingPathExtension("arxiv")
    }

    private func _readLocalArxivSidecarVersion(sidecarURL: URL) throws -> (base: String, version: Int?) {
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else {
            return ("", nil)
        }
        let data = try Data(contentsOf: sidecarURL)
        let s = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty {
            return ("", nil)
        }
        // Expected one-line format: "<base> vN <absURL>" (absURL is optional)
        // We parse the first two tokens only.
        let parts = s.split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return ("", nil) }
        let base = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        var ver: Int? = nil
        if parts.count >= 2 {
            let p1 = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if p1.lowercased().hasPrefix("v") {
                let ds = String(p1.dropFirst())
                if let n = Int(ds) { ver = n }
            }
        }
        return (base, ver)
    }

    private func _writeLocalArxivSidecarOrThrow(sidecarURL: URL, base: String, version: Int?, absURLString: String?) throws {
        let b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty else {
            throw NSError(domain: "Inf6PaperSave", code: -80, userInfo: [NSLocalizedDescriptionKey: "arXiv base id is empty; cannot write .arxiv sidecar."])
        }
        let vText: String = {
            if let version { return "v\(version)" }
            return "v?"
        }()
        let urlText = (absURLString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let line = urlText.isEmpty ? "\(b) \(vText)" : "\(b) \(vText) \(urlText)"
        let data = (line + "\n").data(using: .utf8) ?? Data()
        try data.write(to: sidecarURL, options: [.atomic])
    }

    private func _paperProviderKey() -> String {
        let idLower = result.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if idLower.hasPrefix("arxiv:") { return "arxiv" }
        if idLower.hasPrefix("pubmed:") { return "pubmed" }
        if idLower.hasPrefix("acl:") { return "acl" }
        if idLower.hasPrefix("isca:") { return "isca" }

        let host = (
            result.landingURL?.host ??
            result.pdfURL?.host ??
            ""
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

        if host.contains("arxiv.org") { return "arxiv" }
        if host.contains("pubmed.ncbi.nlm.nih.gov") || host.contains("ncbi.nlm.nih.gov") { return "pubmed" }
        if host.contains("aclanthology.org") { return "acl" }
        if host.contains("isca-archive.org") { return "isca" }
        return "unknown"
    }

    private func _paperMetadataSidecarURL(forPDF destPDFURL: URL) -> URL {
        destPDFURL
            .deletingPathExtension()
            .appendingPathExtension("papermeta.json")
    }

    private func _derivePaperMetadataTags(title: String, abstractText: String) -> [String] {
        let blob = [title, abstractText].joined(separator: " ")
        let tokens = _metadataTagTokens(from: blob)
        guard !tokens.isEmpty else { return [] }

        var counts: [String: Int] = [:]
        counts.reserveCapacity(tokens.count)
        for t in tokens {
            counts[t, default: 0] += 1
        }

        let sorted = counts.keys.sorted { lhs, rhs in
            let lc = counts[lhs] ?? 0
            let rc = counts[rhs] ?? 0
            if lc != rc { return lc > rc }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }

        let limit = 8
        return Array(sorted.prefix(limit))
    }

    private func _metadataTagTokens(from text: String) -> [String] {
        let lower = text.lowercased()
        let parts = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
        var out: [String] = []
        out.reserveCapacity(parts.count)

        for raw in parts {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count < 3 { continue }
            if _metadataTagStopwords.contains(t) { continue }
            if Int(t) != nil { continue }
            out.append(t)
        }
        return out
    }

    private var _metadataTagStopwords: Set<String> {
        [
            "the", "and", "for", "with", "from", "into", "using", "towards", "through", "across",
            "under", "over", "without", "within", "via", "based", "this", "that", "these", "those",
            "are", "was", "were", "been", "being", "have", "has", "had", "its", "our", "their", "your",
            "can", "may", "will", "shall", "also", "new", "paper", "study", "method", "methods",
            "approach", "approaches", "result", "results", "task", "tasks", "analysis", "toward"
        ]
    }

    private func _resolvedAbstractTextForSidecar(downloadedPDFData: Data?) -> String {
        let fromSource = result.abstractText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fromSource.isEmpty {
            return fromSource
        }

        #if canImport(PDFKit)
        guard let downloadedPDFData else { return "" }
        return _generatedAbstractFromDownloadedPDFData(downloadedPDFData)
        #else
        return ""
        #endif
    }

    #if canImport(PDFKit)
    private func _generatedAbstractFromDownloadedPDFData(_ data: Data) -> String {
        guard let doc = PDFDocument(data: data), doc.pageCount > 0 else { return "" }
        let rawText = _generatedRawTextFromPDFDocument(doc, maxPages: 3, maxChars: 24_000)
        let abstract = _generatedAbstractFromRawText(rawText)
        return abstract.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func _generatedRawTextFromPDFDocument(_ doc: PDFDocument, maxPages: Int, maxChars: Int) -> String {
        guard doc.pageCount > 0, maxPages > 0, maxChars > 0 else { return "" }

        var chunks: [String] = []
        chunks.reserveCapacity(maxPages)
        var consumed = 0
        for i in 0..<min(maxPages, doc.pageCount) {
            guard let page = doc.page(at: i), let text = page.string else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            if consumed >= maxChars { break }
            let remaining = maxChars - consumed
            let clipped = trimmed.count > remaining ? String(trimmed.prefix(remaining)) : trimmed
            chunks.append(clipped)
            consumed += clipped.count
        }
        return chunks.joined(separator: "\n")
    }

    private func _generatedAbstractFromRawText(_ rawText: String) -> String {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        let scanRange = NSRange(text.startIndex..<text.endIndex, in: text)
        if let abstractRegex = try? NSRegularExpression(pattern: "\\babstract\\b[:\\s-]*", options: [.caseInsensitive]),
           let match = abstractRegex.firstMatch(in: text, options: [], range: scanRange),
           let abstractRange = Range(match.range, in: text) {
            let tail = String(text[abstractRange.upperBound...])
            let tailRange = NSRange(tail.startIndex..<tail.endIndex, in: tail)
            let stopPatterns: [String] = [
                "\\n\\s*(keywords?|index terms?)\\b",
                "\\n\\s*[0-9]+\\.?\\s+[A-Z]",
                "\\n\\s*[IVX]+\\.?\\s+[A-Z]",
            ]

            var stopIndex = tail.endIndex
            for pattern in stopPatterns {
                if let stopRegex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                   let stopMatch = stopRegex.firstMatch(in: tail, options: [], range: tailRange),
                   let range = Range(stopMatch.range, in: tail),
                   range.lowerBound < stopIndex {
                    stopIndex = range.lowerBound
                }
            }

            let candidate = _normalizedAbstractLine(String(tail[..<stopIndex]))
            if candidate.count >= 40 {
                return candidate.count <= 1000 ? candidate : String(candidate.prefix(1000))
            }
        }

        let fallback = _normalizedAbstractLine(text)
        if fallback.count <= 900 { return fallback }
        return String(fallback.prefix(900))
    }

    private func _normalizedAbstractLine(_ raw: String) -> String {
        var s = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while s.contains("  ") {
            s = s.replacingOccurrences(of: "  ", with: " ")
        }
        return s
    }
    #endif

    private func _writePaperMetadataSidecarOrThrow(forPDF destPDFURL: URL, downloadedPDFData: Data?, sourceURLOverride: String?) throws {
        let provider = _paperProviderKey()
        let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let abstractText = _resolvedAbstractTextForSidecar(downloadedPDFData: downloadedPDFData)
        let sourceURL = (
            sourceURLOverride ??
            result.pdfURL?.absoluteString ??
            result.landingURL?.absoluteString ??
            ""
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        let metadataTags = _derivePaperMetadataTags(title: title, abstractText: abstractText)

        var raw: [String: Any] = [
            "id": result.id,
            "title": title,
            "provider": provider,
        ]
        if !abstractText.isEmpty {
            raw["abstract"] = abstractText
        }

        if provider == "arxiv" {
            let remote = _remoteArxivBaseAndVersion()
            if !remote.base.isEmpty {
                raw["arxiv_id"] = remote.base
            }
            if let v = remote.version {
                raw["arxiv_version"] = "v\(v)"
            }
        }

        let payload: [String: Any] = [
            "title": title,
            "provider": provider,
            "source_url": sourceURL,
            "abstract": abstractText,
            "tags": metadataTags,
            "raw": raw,
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: _paperMetadataSidecarURL(forPDF: destPDFURL), options: [.atomic])
    }

    @ViewBuilder
    var body: some View {
        let folderURL = saveFolderURL
        let folderError = saveFolderErrorText
        
        // If saveFolderURL is nil, this button becomes impossible to use.
        // Surface a clear, actionable error. (Do not early-return; keep a single ViewBuilder path.)
        if folderURL == nil {
            VStack(alignment: .leading, spacing: 6) {
                Text(Inf6Lang.text(
                    "PDF保存先が未選択です。このシート内に保存先選択UIが無いため、前の画面で『PDF保存先』を選択してから再度お試しください。",
                    "PDF destination is not selected. This sheet does not provide a folder picker; please choose 'PDF destination' in the previous screen and try again."
                ))
                .font(.footnote)
                .foregroundStyle(.red)
                .textSelection(.enabled)

                if let folderError {
                    Text(folderError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        } else {

        let destInfo = _resolveDestURLInfo(folderURL: folderURL)
        let destURL = destInfo.url
        let destFileName = destInfo.fileName
        let destError = destInfo.error

        let isAlreadySaved: Bool = _isAlreadySaved

        VStack(alignment: .leading, spacing: 6) {
            if let folderError {
                Text(folderError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if let destError {
                Text(destError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if let destURL {
                #if os(iOS)
                Text(Inf6Lang.text("保存先: ", "Destination: ") + destURL.path)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .contentShape(Rectangle())
                    .onTapGesture { }
                #else
                Text(Inf6Lang.text("保存先: ", "Destination: ") + destURL.path)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                #endif
            }

            if isAlreadySaved, let destURL, let destFileName {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")

                        // Show saved filename as selectable text (no preview on tap)
                        Text(Inf6Lang.text("保存済み: ", "Saved: ") + destFileName)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                        // Copy filename button (always copies lastPathComponent)
                        Button {
                            if !_copyToPasteboard(destURL.lastPathComponent) {
                                _lastError = Inf6Lang.text(
                                    "この環境ではコピーできません。",
                                    "Copy is unavailable on this platform."
                                )
                            }
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.footnote)
                        }
                        .buttonStyle(.plain)
                        .help(Inf6Lang.text("コピー", "Copy"))
                    }

                    if _isUpdateAvailable {
                        let lv = _localArxivVersion
                        let rv = _remoteArxivVersion
                        let base = _localArxivBaseID
                        let lhs = lv != nil ? "v\(lv!)" : "v?"
                        let rhs = rv != nil ? "v\(rv!)" : "v?"
                        let head = (base ?? "").isEmpty ? "" : "\(base!) "

                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Inf6Lang.text(
                                "更新版あり: \(head)\(lhs) → \(rhs)",
                                "Update available: \(head)\(lhs) → \(rhs)"
                            ))
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                        }
                    }

                    Button(L("PDFを開く", "Open PDF")) {
                        _openSavedPDFInApp(destURL, folderURL: folderURL)
                    }
                }
            } else {
                Button {
                    Task { @MainActor in
                        await _save()
                    }
                } label: {
                    Label(Inf6Lang.text("PDFを保存", "Save PDF"), systemImage: "square.and.arrow.down")
                }
                .disabled(_isSaving || folderURL == nil)
            }

            if _isSaving {
                ProgressView().tint(.pink).scaleEffect(1.25)
            }

                if let saved = _savedFileName {
                    Text(Inf6Lang.text("保存完了: ", "Saved: ") + saved)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    if _savedFileURL != nil {
                        VStack(alignment: .leading, spacing: 6) {

                            Button(L("PDFを開く", "Open PDF")) {
                                guard let u = _savedFileURL else {
                                    _lastError = Inf6Lang.text(
                                        "保存済みPDFのURLがありません。保存に失敗している可能性があります。",
                                        "Saved PDF URL is missing. The save may have failed."
                                    )
                                    return
                                }
                                _openSavedPDFInApp(u, folderURL: folderURL)
                            }
                        }
                    }
                }

            if let e = _lastError {
                Text(e)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }

        .task(id: {
            let p = destURL?.path ?? ""
            let r = (result.landingURL?.absoluteString ?? result.id)
            return p + "|" + r
        }()) {
            await MainActor.run {
                _refreshAlreadySavedStatus(destURL: destURL, folderURL: folderURL)
            }
        }
        }
    }

    @MainActor
    private func _refreshAlreadySavedStatus(destURL: URL?, folderURL: URL?) {
        let path = destURL?.path ?? ""
        let remoteSig = (result.landingURL?.absoluteString ?? result.id)
        let sig = path + "|" + remoteSig
        if _alreadySavedCheckedPath == sig {
            return
        }
        _alreadySavedCheckedPath = sig
        _isAlreadySaved = false

        // Determine update availability (arXiv only). We rely on the local sidecar "<pdf>.arxiv".
        _isUpdateAvailable = false
        _localArxivVersion = nil
        _remoteArxivVersion = nil
        _localArxivBaseID = nil

        guard let destURL, let folderURL else {
            return
        }

        let started = folderURL.startAccessingSecurityScopedResource()
        defer {
            if started {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        let exists = FileManager.default.fileExists(atPath: destURL.path)
        _isAlreadySaved = exists

        guard exists else {
            return
        }

        // Remote (from current search result)
        let remote = _remoteArxivBaseAndVersion()
        if !remote.base.isEmpty {
            _remoteArxivVersion = remote.version
        }

        // Local (from sidecar next to the saved PDF)
        do {
            let sidecar = _arxivSidecarURL(forPDF: destURL)
            let local = try _readLocalArxivSidecarVersion(sidecarURL: sidecar)
            if !local.base.isEmpty {
                _localArxivBaseID = local.base
                _localArxivVersion = local.version
            }
        } catch {
            // Surface sidecar read failure as non-fatal state (show in UI via _lastError if needed later).
        }

        // If we can compare versions and bases match, mark update.
        if let lb = _localArxivBaseID, !lb.isEmpty, lb == remote.base {
            if let lv = _localArxivVersion, let rv = remote.version, rv > lv {
                _isUpdateAvailable = true
            }
        }
    }

    @MainActor
    private func _save() async {
        _lastError = nil
        _savedFileName = nil
        _savedFileURL = nil
        _isSaving = true
        defer { _isSaving = false }

        do {
            guard let folder = saveFolderURL else {
                throw NSError(
                    domain: "Inf6PaperSave",
                    code: -10,
                    userInfo: [NSLocalizedDescriptionKey: "Save destination folder is not selected."]
                )
            }

            let destInfo = _resolveDestURLInfo(folderURL: folder)
            if let destError = destInfo.error {
                throw NSError(
                    domain: "Inf6PaperSave",
                    code: -13,
                    userInfo: [NSLocalizedDescriptionKey: destError]
                )
            }
            guard let dest = destInfo.url else {
                throw NSError(
                    domain: "Inf6PaperSave",
                    code: -14,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to resolve classified destination path."]
                )
            }

            let started = folder.startAccessingSecurityScopedResource()
            guard started else {
                throw NSError(
                    domain: "Inf6PaperSave",
                    code: -15,
                    userInfo: [NSLocalizedDescriptionKey: "Could not obtain access permission to the destination folder. Please re-add the folder via 'Add mapping…'."]
                )
            }
            defer {
                if started {
                    folder.stopAccessingSecurityScopedResource()
                }
            }
            let destDirectory = dest.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: destDirectory, withIntermediateDirectories: true, attributes: nil)

            // Allow overwrite so users can refresh to the latest arXiv version.
            // The save operation is explicit and uses atomic write.

            let target = try await _resolveDownloadTargetForSaveOrThrow()
            let data = try await Inf6PaperSaveShared.downloadValidatedPDFData(from: target.downloadURL)

            try data.write(to: dest, options: [.atomic])

            // Write minimal arXiv sidecar next to the saved PDF for version/update tracking.
            if !target.sidecarBase.isEmpty {
                let sidecar = _arxivSidecarURL(forPDF: dest)
                try _writeLocalArxivSidecarOrThrow(
                    sidecarURL: sidecar,
                    base: target.sidecarBase,
                    version: target.sidecarVersion,
                    absURLString: target.sourceURLOverride
                )
                _remoteArxivVersion = target.sidecarVersion
            }

            try _writePaperMetadataSidecarOrThrow(forPDF: dest, downloadedPDFData: data, sourceURLOverride: target.sourceURLOverride)

            _savedFileName = dest.lastPathComponent
            _savedFileURL = dest
            // Always refresh already-saved status after saving, even for the same path
            _alreadySavedCheckedPath = ""
            _refreshAlreadySavedStatus(destURL: _savedFileURL, folderURL: saveFolderURL)

            NotificationCenter.default.post(name: .inf6PaperPDFDidSave, object: nil, userInfo: ["pdfURL": dest])
        } catch {
            _lastError = error.localizedDescription
        }
    }


    private func _resolveDestURLInfo(folderURL: URL?) -> (url: URL?, fileName: String?, error: String?) {
        guard let folderURL else { return (nil, nil, nil) }

        do {
            let fileName = try Inf6PaperStorage.safeFileName(title: result.title, fallbackID: result.id)
            let classificationDir = Inf6PaperSaveShared.classificationDirectoryName(
                title: result.title,
                abstractText: result.abstractText,
                fallbackID: result.id,
                landingURL: result.landingURL,
                pdfURL: result.pdfURL
            )
            let dest = folderURL
                .appendingPathComponent(classificationDir, isDirectory: true)
                .appendingPathComponent(fileName)
            return (dest, fileName, nil)
        } catch {
            return (nil, nil, error.localizedDescription)
        }
    }
}
