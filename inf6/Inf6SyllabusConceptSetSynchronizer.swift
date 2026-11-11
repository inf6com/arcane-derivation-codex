//
//  Inf6SyllabusConceptSetSynchronizer.swift
//  inf6
//
//  公式シラバス更新を、outline cache / knowledge structure / concept set へ伝播する。
//  PDF 本体は保存せず、取得時だけ本文抽出に使う。
//

import Foundation
import SwiftUI
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif
#if canImport(PDFKit)
import PDFKit
#endif

enum Inf6SyllabusConceptSetSynchronizer {
    struct Summary: Codable, Hashable {
        let checkedDomainCount: Int
        let refreshedDomainCount: Int
        let conceptSummary: Inf6SyllabusConceptSetBuilder.Summary
    }

    static func synchronize(
        manifests: [Inf6LearningFamilyManifest]
    ) async throws -> Summary {
        for manifest in manifests {
            try await synchronize(manifest: manifest)
        }
        let domains = try _loadDomains(manifests: manifests)
        let conceptSummary = try Inf6SyllabusConceptSetBuilder.rebuildAndPersist(domains: domains)
        return Summary(
            checkedDomainCount: manifests.count,
            refreshedDomainCount: manifests.count,
            conceptSummary: conceptSummary
        )
    }

    static func synchronize(manifest: Inf6LearningFamilyManifest) async throws {
        let schedule = Inf6DomainSyncSchedule.current(for: manifest)
        let lastPeriod = Inf6DomainSyncSchedule._lastSyncPeriod(familyID: manifest.familyID)
        if lastPeriod.isEmpty {
            Inf6DomainSyncSchedule.recordSync(familyID: manifest.familyID, manifest: manifest)
            return
        }
        if lastPeriod == schedule.periodID { return }

        if manifest.usesMicrosoftLearnProvider {
            Inf6DomainUpdatePrompt.flagAvailable(familyID: manifest.familyID)
            NSLog("[inf6] Microsoft Learn update needed for %@ (period %@, last synced in %@)", manifest.familyID, schedule.periodID, lastPeriod)
        } else if manifest.usesJDLAHTMLProvider {
            Inf6DomainUpdatePrompt.flagAvailable(familyID: manifest.familyID)
            NSLog("[inf6] JDLA update needed for %@ (period %@, last synced in %@)", manifest.familyID, schedule.periodID, lastPeriod)
        }
    }

    static func synchronizeWithUserApproval(manifest: Inf6LearningFamilyManifest) async throws {
        if manifest.usesMicrosoftLearnProvider {
            let summary = await Inf6CorpusFetchCoordinator.refreshDomain(manifest: manifest)
            let failures = summary.outcomes.filter { !$0.success }
            if !failures.isEmpty {
                let details = failures.map { "\($0.sourceID): \($0.error ?? "unknown error")" }.joined(separator: "\n")
                throw NSError(domain: "Inf6SyllabusConceptSetSynchronizer", code: 10,
                              userInfo: [NSLocalizedDescriptionKey: "Microsoft Learn syllabus refresh failed.\n\(details)"])
            }
        } else if manifest.usesJDLAHTMLProvider {
            try await _synchronizeJDLASyllabus(manifest: manifest)
        } else {
            return
        }
        Inf6DomainUpdatePrompt.clearFlag(familyID: manifest.familyID)
        Inf6DomainSyncSchedule.recordSync(familyID: manifest.familyID, manifest: manifest)
    }

    static func synchronizeJDLAWithUserApproval(manifest: Inf6LearningFamilyManifest) async throws {
        try await synchronizeWithUserApproval(manifest: manifest)
    }

    static func loadDomainsForCurrentCache(
        manifests: [Inf6LearningFamilyManifest]
    ) throws -> [Inf6KnowledgeGraphView._KnowledgeGraphDomain] {
        try _loadDomains(manifests: manifests, skipValidation: true, skipPaperLink: true)
    }

    @discardableResult
    static func persistVerifiedEshikakuOutline(snapshot: SyllabusSnapshot) throws -> [Inf6SyllabusOutlineItem] {
        guard snapshot.verified else {
            throw NSError(
                domain: "Inf6SyllabusConceptSetSynchronizer",
                code: 60,
                userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text(
                    "E資格シラバスが公式出典として検証されていません。",
                    "The E-Qualification syllabus has not been verified against its official source."
                )]
            )
        }
        guard let content = snapshot.content, !content.isEmpty else {
            throw NSError(
                domain: "Inf6SyllabusConceptSetSynchronizer",
                code: 61,
                userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text(
                    "検証済みE資格シラバスにノード生成用の本文がありません。",
                    "The verified E-Qualification syllabus has no content for building its node structure."
                )]
            )
        }
        let plainText = content
            .replacingOccurrences(of: #"<[^>]+>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
        let outline = Inf6EshikakuOutlineParser.extract(from: plainText)
        let deepCount = outline.filter { $0.effectiveDepth >= 2 }.count
        guard outline.count >= 12, deepCount >= 4 else {
            throw NSError(
                domain: "Inf6SyllabusConceptSetSynchronizer",
                code: 62,
                userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text(
                    "検証済みE資格シラバスからノード構造を復元できませんでした（項目数: \(outline.count)、第3階層以上: \(deepCount)）。",
                    "Could not reconstruct the E-Qualification node structure from the verified syllabus (items: \(outline.count), third-level or deeper: \(deepCount))."
                )]
            )
        }

        let cacheURL = try Inf6Storage.syllabusOutlineCacheURL()
        var cache = Inf6DiskJSON.load([String: [Inf6SyllabusOutlineItem]].self, from: cacheURL) ?? [:]
        let cacheKey = "eshikaku_outline:\(snapshot.revision)"
        if cache[cacheKey] != outline {
            cache[cacheKey] = outline
            try Inf6DiskJSON.save(cache, to: cacheURL)
        }
        guard Inf6DiskJSON.load([String: [Inf6SyllabusOutlineItem]].self, from: cacheURL)?[cacheKey] == outline else {
            throw NSError(
                domain: "Inf6SyllabusConceptSetSynchronizer",
                code: 63,
                userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text(
                    "E資格プリセットのノード構造を保存先から再読込できませんでした。",
                    "Could not reload the E-Qualification preset node structure from the selected storage root."
                )]
            )
        }
        return outline
    }

    static func loadDomainsEnsuringCurrentCache(
        manifests: [Inf6LearningFamilyManifest]
    ) async throws -> [Inf6KnowledgeGraphView._KnowledgeGraphDomain] {
        var cache = _loadOutlineCache()
        for manifest in manifests where manifest.usesMicrosoftLearnProvider {
            guard _findMicrosoftLearnOutlineItems(for: manifest, cache: cache).isEmpty else { continue }
            let summary = await Inf6CorpusFetchCoordinator.refreshDomain(manifest: manifest)
            cache = _loadOutlineCache()
            guard !_findMicrosoftLearnOutlineItems(for: manifest, cache: cache).isEmpty else {
                let outlineFailures = summary.outcomes.filter {
                    !$0.success && ($0.sourceID.contains("study-guide") || $0.sourceID.contains("microsoft_learn_outline_bilingual_v1"))
                }
                let details = outlineFailures.map { "\($0.sourceID): \($0.error ?? "unknown error")" }
                    .joined(separator: "\n")
                throw NSError(
                    domain: "Inf6SyllabusConceptSetSynchronizer",
                    code: 12,
                    userInfo: [NSLocalizedDescriptionKey: "Microsoft Learn bilingual outline was not produced: \(manifest.sourceFamily)\n\(details)"]
                )
            }
        }
        return try _loadDomains(manifests: manifests)
    }

    private static func _synchronizeJDLASyllabus(manifest: Inf6LearningFamilyManifest) async throws {
        guard manifest.familyID == "g-kentei" || manifest.familyID == "e-shikaku" else {
            throw NSError(
                domain: "Inf6SyllabusConceptSetSynchronizer",
                code: 20,
                userInfo: [NSLocalizedDescriptionKey: "JDLA parser is not defined for domain: \(manifest.familyID)"]
            )
        }

        let discoveredURLs = try await _discoverJDLAPDFURLs(manifest: manifest)
        guard !discoveredURLs.isEmpty else {
            throw NSError(
                domain: "Inf6SyllabusConceptSetSynchronizer",
                code: 21,
                userInfo: [NSLocalizedDescriptionKey: "JDLA syllabus PDF was not discovered: \(manifest.familyID)"]
            )
        }
        let urls = try _selectCurrentJDLAPDFURLs(manifest: manifest, urls: discoveredURLs)

        var cache = _loadOutlineCache()
        var parsedByKey: [String: [Inf6SyllabusOutlineItem]] = [:]
        var parseErrors: [String] = []
        for url in urls {
            let key = _outlineCacheKey(manifest: manifest, sourceURL: url)
            do {
                let hasCachedOutline = cache[key]?.isEmpty == false
                switch try await _downloadPDFTextIfChanged(url, allowUnchanged: hasCachedOutline) {
                case .changed(let text):
                    parsedByKey[key] = try _parseJDLAOutline(manifest: manifest, text: text)
                case .unchanged:
                    parsedByKey[key] = cache[key]!
                }
            } catch {
                parseErrors.append("\(url.absoluteString): \(error.localizedDescription)")
            }
        }

        guard !parsedByKey.isEmpty else {
            throw NSError(
                domain: "Inf6SyllabusConceptSetSynchronizer",
                code: 22,
                userInfo: [NSLocalizedDescriptionKey: "JDLA syllabus parsing failed for all candidates.\n\(parseErrors.joined(separator: "\n"))"]
            )
        }

        _removeExistingJDLAOutlineEntries(from: &cache, manifest: manifest)
        for (key, items) in parsedByKey {
            cache[key] = items
        }
        try _saveOutlineCache(cache)
    }

    private static func _discoverJDLAPDFURLs(manifest: Inf6LearningFamilyManifest) async throws -> [URL] {
        let cacheKey = "jdla_pdf_urls_cache:\(manifest.familyID)"
        let cacheTimeKey = "jdla_pdf_urls_cache_at:\(manifest.familyID)"
        if let cachedJSON = Inf6MetadataStore.get(domain: .settings, key: cacheKey),
           let cachedAtStr = Inf6MetadataStore.get(domain: .settings, key: cacheTimeKey),
           let cachedAt = Double(cachedAtStr),
           (Date().timeIntervalSince1970 - cachedAt) < 86400 * 30,
           let data = cachedJSON.data(using: .utf8),
           let urls = try? JSONDecoder().decode([String].self, from: data),
           !urls.isEmpty {
            NSLog("[inf6] JDLA PDF URL cache hit for %@ (%d urls)", manifest.familyID, urls.count)
            return urls.compactMap { URL(string: $0) }
        }

        var out: [URL] = []
        var seen: Set<String> = []
        let builder = Inf6SyllabusPipelineBuilder()
        for raw in manifest.officialSources + manifest.trendSources {
            guard let officialURL = URL(string: raw) else {
                throw NSError(
                    domain: "Inf6SyllabusConceptSetSynchronizer",
                    code: 23,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid official source URL: \(raw)"]
                )
            }
            // JDLA's current WordPress download URL is an official PDF source,
            // even though it has no .pdf suffix. Preserve it as a direct source
            // instead of requiring HTML link discovery to succeed.
            if officialURL.absoluteString.localizedCaseInsensitiveContains("wpdmdl=")
                || inf6URLLooksLikePDF(officialURL) {
                if seen.insert(officialURL.absoluteString).inserted {
                    out.append(officialURL)
                }
                continue
            }
            let found = await inf6DiscoverReachablePDFURLsScoped(
                builder: builder,
                officialURL: officialURL,
                scopeKeywords: [],
                keywords: [],
                timeout: 30,
                maxConcurrency: 2
            )
            for url in found where seen.insert(url.absoluteString).inserted {
                out.append(url)
            }
        }

        if !out.isEmpty {
            let urlStrings = out.map(\.absoluteString)
            if let data = try? JSONEncoder().encode(urlStrings),
               let json = String(data: data, encoding: .utf8) {
                Inf6MetadataStore.put(domain: .settings, key: cacheKey, json: json)
                Inf6MetadataStore.put(domain: .settings, key: cacheTimeKey, json: String(Date().timeIntervalSince1970))
            }
        }
        return out
    }

    private static func _selectCurrentJDLAPDFURLs(
        manifest: Inf6LearningFamilyManifest,
        urls: [URL]
    ) throws -> [URL] {
        let ranked = urls.compactMap { url -> (URL, Int)? in
            guard let rank = jdlaRevisionRank(familyID: manifest.familyID, urlString: url.absoluteString) else { return nil }
            return (url, rank)
        }
        if let highest = ranked.map({ $0.1 }).max() {
            return ranked.filter { $0.1 == highest }.map({ $0.0 })
        }

        throw NSError(
            domain: "Inf6SyllabusConceptSetSynchronizer",
            code: 24,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Current JDLA syllabus PDF could not be identified: \(manifest.familyID)\n" +
                    urls.map(\.absoluteString).joined(separator: "\n")
            ]
        )
    }

    static func jdlaRevisionRank(
        familyID: String,
        urlString: String
    ) -> Int? {
        let key = urlString.lowercased()
        let prefix: String
        switch familyID {
        case "g-kentei": prefix = "g"
        case "e-shikaku": prefix = "e"
        default: return nil
        }
        let pattern = "\(prefix)([0-9]{4})(?:%23|#)?([0-9]+)"
        guard let match = key.range(of: pattern, options: .regularExpression) else { return nil }
        let token = String(key[match])
        let suffix = String(token.dropFirst())
        let digits = suffix.split(whereSeparator: { !$0.isNumber })
        let year: Int
        let revision: Int
        if digits.count >= 2 {
            guard let parsedYear = Int(digits[0]), let parsedRevision = Int(digits[1]) else { return nil }
            year = parsedYear
            revision = parsedRevision
        } else {
            guard suffix.count >= 5,
                  let parsedYear = Int(suffix.prefix(4)),
                  let parsedRevision = Int(suffix.dropFirst(4)) else { return nil }
            year = parsedYear
            revision = parsedRevision
        }
        return year * 100 + revision
    }

    private enum _PDFTextFetchResult {
        case changed(String)
        case unchanged
    }

    private static func _downloadPDFTextIfChanged(
        _ url: URL,
        allowUnchanged: Bool
    ) async throws -> _PDFTextFetchResult {
        let metadataKey = _pdfValidationMetadataKey(url)
        var request = URLRequest(url: url)
        if allowUnchanged {
            if let etag = Inf6MetadataStore.get(domain: .settings, key: "\(metadataKey):etag")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !etag.isEmpty {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }
            if let lastModified = Inf6MetadataStore.get(domain: .settings, key: "\(metadataKey):last_modified")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !lastModified.isEmpty {
                request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
            }
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(
                domain: "Inf6SyllabusConceptSetSynchronizer",
                code: 30,
                userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response: \(url.absoluteString)"]
            )
        }
        if http.statusCode == 304 {
            return .unchanged
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "Inf6SyllabusConceptSetSynchronizer",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(url.absoluteString)"]
            )
        }
        guard data.count >= 4, data.prefix(4) == Data([0x25, 0x50, 0x44, 0x46]) else {
            let type = http.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
            throw NSError(
                domain: "Inf6SyllabusConceptSetSynchronizer",
                code: 31,
                userInfo: [NSLocalizedDescriptionKey: "Downloaded content is not a PDF: \(url.absoluteString) Content-Type=\(type)"]
            )
        }

        #if canImport(PDFKit)
        guard let doc = PDFDocument(data: data), doc.pageCount > 0 else {
            throw NSError(
                domain: "Inf6SyllabusConceptSetSynchronizer",
                code: 32,
                userInfo: [NSLocalizedDescriptionKey: "PDFKit could not open syllabus PDF: \(url.absoluteString)"]
            )
        }
        var parts: [String] = []
        parts.reserveCapacity(doc.pageCount)
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { continue }
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                parts.append(text)
            }
        }
        let fullText = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullText.isEmpty else {
            throw NSError(
                domain: "Inf6SyllabusConceptSetSynchronizer",
                code: 33,
                userInfo: [NSLocalizedDescriptionKey: "PDF text extraction produced empty text: \(url.absoluteString)"]
            )
        }
        _recordPDFValidationMetadata(response: http, metadataKey: metadataKey)
        return .changed(fullText)
        #else
        throw NSError(
            domain: "Inf6SyllabusConceptSetSynchronizer",
            code: 34,
            userInfo: [NSLocalizedDescriptionKey: "PDFKit is unavailable; JDLA syllabus PDF cannot be parsed."]
        )
        #endif
    }

    private static func _recordPDFValidationMetadata(
        response: HTTPURLResponse,
        metadataKey: String
    ) {
        let etag = response.value(forHTTPHeaderField: "ETag") ?? ""
        let lastModified = response.value(forHTTPHeaderField: "Last-Modified") ?? ""
        Inf6MetadataStore.put(domain: .settings, key: "\(metadataKey):etag", json: etag)
        Inf6MetadataStore.put(domain: .settings, key: "\(metadataKey):last_modified", json: lastModified)
        Inf6MetadataStore.put(domain: .settings, key: "\(metadataKey):checked_at", json: String(Date().timeIntervalSince1970))
    }

    private static func _pdfValidationMetadataKey(_ url: URL) -> String {
        "syllabus_pdf_validation:\(_stableHex(url.absoluteString))"
    }

    private static func _stableHex(_ raw: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }

    private static func _parseJDLAOutline(
        manifest: Inf6LearningFamilyManifest,
        text: String
    ) throws -> [Inf6SyllabusOutlineItem] {
        let outlineText = try _jdlaOutlineBodyText(manifest: manifest, text: text)
        let items: [Inf6SyllabusOutlineItem]
        switch manifest.familyID {
        case "g-kentei":
            items = Inf6GkenteiOutlineExtractor.extract(from: outlineText)
            guard items.count >= 20 else {
                throw NSError(
                    domain: "Inf6SyllabusConceptSetSynchronizer",
                    code: 40,
                    userInfo: [NSLocalizedDescriptionKey: "G検定 outline extraction was too small: \(items.count)"]
                )
            }
        case "e-shikaku":
            items = Inf6EshikakuOutlineExtractor.extract(from: outlineText)
            let deepCount = items.filter { ($0.depth ?? 0) >= 2 }.count
            guard items.count >= 12 && deepCount >= 4 else {
                throw NSError(
                    domain: "Inf6SyllabusConceptSetSynchronizer",
                    code: 41,
                    userInfo: [NSLocalizedDescriptionKey: "E資格 outline extraction was too small: count=\(items.count) deep=\(deepCount)"]
                )
            }
        default:
            items = []
        }
        return items
    }

    private static func _jdlaOutlineBodyText(
        manifest: Inf6LearningFamilyManifest,
        text: String
    ) throws -> String {
        guard manifest.familyID == "e-shikaku" else { return text }
        let patterns = [
            #"(?m)^\s*[１1][\.．]\s*数学的基礎"#,
            #"(?m)^\s*[１1][\.．]\s*応用数学"#
        ]
        for pattern in patterns {
            if let range = text.range(of: pattern, options: .regularExpression) {
                return String(text[range.lowerBound...])
            }
        }
        throw NSError(
            domain: "Inf6SyllabusConceptSetSynchronizer",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "E資格 syllabus body start was not found in the current PDF."]
        )
    }

    private static func _loadDomains(
        manifests: [Inf6LearningFamilyManifest],
        skipValidation: Bool = false,
        skipPaperLink: Bool = false
    ) throws -> [Inf6KnowledgeGraphView._KnowledgeGraphDomain] {
        let cache = _loadOutlineCache()
        NSLog("[inf6-board] _loadDomains: cache keys=%d, skipValidation=%d, skipPaperLink=%d", cache.count, skipValidation ? 1 : 0, skipPaperLink ? 1 : 0)
        let paperStore: Inf6CorePaperStore? = skipPaperLink ? nil : Inf6CorePaperStore.shared

        var results: [Inf6KnowledgeGraphView._KnowledgeGraphDomain] = []
        for manifest in manifests {
            NSLog("[inf6-board] _loadDomains: processing %@", manifest.familyID)
            do {
                let outlineItems = try _outlineItems(for: manifest, cache: cache)
                NSLog("[inf6-board] _loadDomains: %@ outlineItems=%d", manifest.familyID, outlineItems.count)
                let syllabusVersionID = _resolvedKnowledgeStructureVersionID(for: manifest)
                let structure = try Inf6KnowledgeDomainStructureStore.loadOrSeed(
                    manifest: manifest,
                    syllabusVersionID: syllabusVersionID,
                    domainTitleJa: manifest.displayNameJa,
                    outlineItems: outlineItems,
                    paperStore: paperStore
                )
                NSLog("[inf6-board] _loadDomains: %@ structure loaded, nodes=%d", manifest.familyID, structure.nodes.count)
                if !skipValidation {
                    try _validateSyllabusStructureCoverage(
                        manifest: manifest,
                        outlineItems: outlineItems,
                        structure: structure
                    )
                }
                let domain = Inf6KnowledgeGraphView._KnowledgeGraphDomain(
                    manifest: manifest,
                    structure: structure,
                    accentColor: _parseHex(manifest.accentColorHex) ?? .blue
                )
                results.append(domain)
            } catch {
                NSLog("[inf6-board] _loadDomains: %@ failed: %@", manifest.familyID, error.localizedDescription)
            }
        }
        return results
    }

    private static func _validateSyllabusStructureCoverage(
        manifest: Inf6LearningFamilyManifest,
        outlineItems: [Inf6SyllabusOutlineItem],
        structure: Inf6KnowledgeDomainStructure
    ) throws {
        let expectedNodeIDs = Set(outlineItems.compactMap { item -> String? in
            let title = (item.titleJa ?? item.title).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !_isNonConceptSyllabusTitle(title) else { return nil }
            return item.key
        })
        guard !expectedNodeIDs.isEmpty else { return }
        let actualNodeIDs = Set(structure.nodes.compactMap { node -> String? in
            switch node.kind {
            case .major, .minor, .topic:
                return node.nodeID
            case .domain, .syllabusVersion, .paper:
                return nil
            }
        })
        let missing = expectedNodeIDs.subtracting(actualNodeIDs).sorted()
        guard missing.isEmpty else {
            throw NSError(
                domain: "Inf6SyllabusConceptSetSynchronizer",
                code: 52,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Syllabus structure coverage is incomplete: \(manifest.sourceFamily) missing=\(missing.prefix(12).joined(separator: ", ")) outlineConceptNodes=\(expectedNodeIDs.count) structureConceptNodes=\(actualNodeIDs.count)"
                ]
            )
        }
    }

    private static func _isNonConceptSyllabusTitle(_ title: String) -> Bool {
        let key = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
            .replacingOccurrences(of: "　", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*,\s*$"#, with: "", options: .regularExpression)
        let withoutNumberPrefix = key.replacingOccurrences(
            of: #"^[0-9]+[.)]?\s*"#,
            with: "",
            options: .regularExpression
        )
        return key.hasPrefix("※")
            || key.contains("出題対象外")
            || key.contains("シラバス") && key.contains("新規作成")
            || withoutNumberPrefix.hasPrefix("以下のキーワード")
    }

    private static func _outlineItems(
        for manifest: Inf6LearningFamilyManifest,
        cache: [String: [Inf6SyllabusOutlineItem]]
    ) throws -> [Inf6SyllabusOutlineItem] {
        if manifest.usesMicrosoftLearnProvider {
            let items = _findMicrosoftLearnOutlineItems(for: manifest, cache: cache)
            guard !items.isEmpty else {
                throw NSError(
                    domain: "Inf6SyllabusConceptSetSynchronizer",
                    code: 50,
                    userInfo: [NSLocalizedDescriptionKey: "Microsoft Learn outline cache is empty: \(manifest.sourceFamily)"]
                )
            }
            return items
        }

        let items = _findJDLAOutlineItems(for: manifest, cache: cache)
        if manifest.usesJDLAHTMLProvider {
            guard !items.isEmpty else {
                throw NSError(
                    domain: "Inf6SyllabusConceptSetSynchronizer",
                    code: 51,
                    userInfo: [NSLocalizedDescriptionKey: "JDLA outline cache is empty: \(manifest.sourceFamily)"]
                )
            }
        }
        return items
    }

    static func currentOutlineItemsForPaperSearch(
        for manifest: Inf6LearningFamilyManifest
    ) throws -> [Inf6SyllabusOutlineItem] {
        try _outlineItems(for: manifest, cache: _loadOutlineCache())
    }

    private static func _findMicrosoftLearnOutlineItems(
        for manifest: Inf6LearningFamilyManifest,
        cache: [String: [Inf6SyllabusOutlineItem]]
    ) -> [Inf6SyllabusOutlineItem] {
        let sourceURLs = Set((manifest.currentSources ?? []).map {
            $0.urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })
        guard !sourceURLs.isEmpty else { return [] }

        var candidates: [[Inf6SyllabusOutlineItem]] = []
        for (key, items) in cache {
            let lowKey = key.lowercased()
            guard lowKey.hasSuffix("|microsoft_learn_outline_bilingual_v1") else { continue }
            if sourceURLs.contains(where: { lowKey.contains($0) }) {
                candidates.append(items)
            }
        }
        return candidates.max(by: { $0.count < $1.count }) ?? []
    }

    private static func _findJDLAOutlineItems(
        for manifest: Inf6LearningFamilyManifest,
        cache: [String: [Inf6SyllabusOutlineItem]]
    ) -> [Inf6SyllabusOutlineItem] {
        let patterns = _jdlaOutlineKeyPatterns(manifest: manifest)
        guard !patterns.isEmpty else { return [] }
        let candidates = cache.compactMap { key, items -> (rank: Int, count: Int, items: [Inf6SyllabusOutlineItem])? in
            let lower = key.lowercased()
            guard patterns.contains(where: { lower.contains($0) }) else { return nil }
            return (_jdlaOutlineCacheRank(manifest: manifest, key: lower), items.count, items)
        }
        return candidates.max {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return $0.count < $1.count
        }?.items ?? []
    }

    private static func _jdlaOutlineCacheRank(
        manifest: Inf6LearningFamilyManifest,
        key: String
    ) -> Int {
        jdlaRevisionRank(familyID: manifest.familyID, urlString: key) ?? 0
    }

    private static func _removeExistingJDLAOutlineEntries(
        from cache: inout [String: [Inf6SyllabusOutlineItem]],
        manifest: Inf6LearningFamilyManifest
    ) {
        let patterns = _jdlaOutlineKeyPatterns(manifest: manifest)
        guard !patterns.isEmpty else { return }
        for key in cache.keys {
            let lower = key.lowercased()
            if patterns.contains(where: { lower.contains($0) }) {
                cache.removeValue(forKey: key)
            }
        }
    }

    private static func _jdlaOutlineKeyPatterns(manifest: Inf6LearningFamilyManifest) -> [String] {
        switch manifest.familyID {
        case "g-kentei":
            return ["gkentei_outline", "g-syllabus", "g%e6%a4%9c%e5%ae%9a"]
        case "e-shikaku":
            return ["eshikaku_outline", "e-syllabus", "e%e8%b3%87%e6%a0%bc"]
        default:
            return []
        }
    }

    private static func _outlineCacheKey(
        manifest: Inf6LearningFamilyManifest,
        sourceURL: URL
    ) -> String {
        switch manifest.familyID {
        case "g-kentei":
            return sourceURL.absoluteString + "|gkentei_outline_v2"
        case "e-shikaku":
            return sourceURL.absoluteString + "|eshikaku_outline_v3"
        default:
            return sourceURL.absoluteString + "|outline_v1"
        }
    }

    private static func _loadOutlineCache() -> [String: [Inf6SyllabusOutlineItem]] {
        guard let url = try? Inf6Storage.syllabusOutlineCacheURL() else { return [:] }
        return Inf6DiskJSON.load([String: [Inf6SyllabusOutlineItem]].self, from: url) ?? [:]
    }

    private static func _saveOutlineCache(_ cache: [String: [Inf6SyllabusOutlineItem]]) throws {
        let url = try Inf6Storage.syllabusOutlineCacheURL()
        try Inf6DiskJSON.save(cache, to: url)
    }

    private static func _resolvedKnowledgeStructureVersionID(for manifest: Inf6LearningFamilyManifest) -> String {
        if let examName = _examName(for: manifest),
           let info = Inf6SyllabusUpdateChecker.shared.examScheduleInfo(for: examName) {
            let versionID = info.preferredKnowledgeStructureID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !versionID.isEmpty {
                return versionID
            }
        }
        return ""
    }

    private static func _examName(for manifest: Inf6LearningFamilyManifest) -> String? {
        switch manifest.familyID {
        case "e-shikaku": return "E資格"
        case "g-kentei": return "G検定"
        case "ai-102": return "AI-102"
        case "ai-103": return "AI-103"
        default: return nil
        }
    }

    private static func _parseHex(_ hex: String) -> Color? {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xff) / 255.0
        let g = Double((v >> 8) & 0xff) / 255.0
        let b = Double(v & 0xff) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}

actor Inf6SyllabusSourceAutoRefresh {
    static let shared = Inf6SyllabusSourceAutoRefresh()

    private var _isRunning = false

    func refreshIfCalendarDayChanged() async -> Bool {
        let today = Self._calendarDayString(Date())
        if Inf6MetadataStore.get(domain: .settings, key: "syllabus_auto_refresh_day") == today {
            return true
        }
        return await refreshNow(checkedDay: today)
    }

    func refreshNow() async -> Bool {
        await refreshNow(checkedDay: Self._calendarDayString(Date()))
    }

    private func refreshNow(checkedDay: String) async -> Bool {
        guard !_isRunning else { return true }
        _isRunning = true
        defer { _isRunning = false }

        let manifests = Inf6LearningFamilyManifestStore.loadCurrentSyllabusDomains()
            .sorted { $0.familyID < $1.familyID }
        guard !manifests.isEmpty else {
            _recordFailure(
                "No current syllabus domains are available for synchronization.",
                checkedDay: checkedDay
            )
            return false
        }

        do {
            let summary = try await Inf6SyllabusConceptSetSynchronizer.synchronize(manifests: manifests)
            _recordSuccess(summary: summary, checkedDay: checkedDay)
            return true
        } catch {
            _recordFailure(error.localizedDescription, checkedDay: checkedDay)
            return false
        }
    }

    private static func _calendarDayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func nextCalendarDayRefreshDate(after date: Date = Date()) -> Date {
        let calendar = Calendar.current
        let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date
        return calendar.date(bySettingHour: 3, minute: 0, second: 0, of: nextDay) ?? nextDay
    }

    private func _recordSuccess(summary: Inf6SyllabusConceptSetSynchronizer.Summary, checkedDay: String) {
        Inf6MetadataStore.put(domain: .settings, key: "syllabus_auto_refresh_status", json: "ok")
        Inf6MetadataStore.put(domain: .settings, key: "syllabus_auto_refresh_error", json: "")
        Inf6MetadataStore.put(domain: .settings, key: "syllabus_auto_refresh_at", json: String(Date().timeIntervalSince1970))
        Inf6MetadataStore.put(domain: .settings, key: "syllabus_auto_refresh_day", json: checkedDay)
        Inf6MetadataStore.putCodable(summary, domain: .settings, key: "syllabus_auto_refresh_summary")
    }

    private func _recordFailure(_ message: String, checkedDay: String) {
        Inf6MetadataStore.put(domain: .settings, key: "syllabus_auto_refresh_status", json: "failed")
        Inf6MetadataStore.put(domain: .settings, key: "syllabus_auto_refresh_error", json: message)
        Inf6MetadataStore.put(domain: .settings, key: "syllabus_auto_refresh_at", json: String(Date().timeIntervalSince1970))
        Inf6MetadataStore.put(domain: .settings, key: "syllabus_auto_refresh_day", json: checkedDay)
    }
}

enum Inf6KnowledgeWorldSyncTrigger: String {
    case launch
    case foreground
    case inactive
    case background
    case dailyBackground
    case manual
}

actor Inf6KnowledgeWorldSync {
    static let shared = Inf6KnowledgeWorldSync()

    private var _currentTask: Task<Bool, Never>?

    func syncNow(trigger: Inf6KnowledgeWorldSyncTrigger) async -> Bool {
        if let currentTask = _currentTask {
            return await currentTask.value
        }

        let task = Task {
            await Self._run(trigger: trigger)
        }
        _currentTask = task
        let result = await task.value
        _currentTask = nil
        return result
    }

    private static func _run(trigger: Inf6KnowledgeWorldSyncTrigger) async -> Bool {
        Inf6MetadataStore.put(domain: .settings, key: "knowledge_world_sync_status", json: "running")
        Inf6MetadataStore.put(domain: .settings, key: "knowledge_world_sync_trigger", json: trigger.rawValue)
        Inf6MetadataStore.put(domain: .settings, key: "knowledge_world_sync_started_at", json: String(Date().timeIntervalSince1970))

        await MainActor.run {
            Inf6SyllabusUpdateChecker.shared.fetchExamScheduleIfNeeded(examName: "E資格")
            Inf6SyllabusUpdateChecker.shared.fetchExamScheduleIfNeeded(examName: "G検定")
        }

        let syllabusSuccess = await Inf6SyllabusSourceAutoRefresh.shared.refreshNow()
        guard syllabusSuccess else {
            _recordFailure(trigger: trigger, message: "Syllabus source synchronization failed.")
            return false
        }

        do {
            let manifests = Inf6LearningFamilyManifestStore.loadCurrentSyllabusDomains()
                .sorted { $0.familyID < $1.familyID }
            for manifest in manifests {
                let outlineItems = try Inf6SyllabusConceptSetSynchronizer.currentOutlineItemsForPaperSearch(for: manifest)
                _ = try await Inf6SyllabusPaperAutoSearch.refresh(
                    sourceFamily: manifest.sourceFamily,
                    outlineItems: outlineItems
                )
            }
            Inf6MetadataStore.put(domain: .settings, key: "knowledge_world_sync_status", json: "ok")
            Inf6MetadataStore.put(domain: .settings, key: "knowledge_world_sync_error", json: "")
            Inf6MetadataStore.put(domain: .settings, key: "knowledge_world_sync_completed_at", json: String(Date().timeIntervalSince1970))
            Inf6MetadataStore.put(domain: .settings, key: "knowledge_world_sync_trigger", json: trigger.rawValue)
            return true
        } catch {
            Inf6CorePaperStore.shared.reloadPapersFromMetadataStore()
            Inf6KnowledgeDomainStructureStore.invalidateCache()
            _recordFailure(trigger: trigger, message: error.localizedDescription)
            return false
        }
    }

    private static func _recordFailure(trigger: Inf6KnowledgeWorldSyncTrigger, message: String) {
        Inf6MetadataStore.put(domain: .settings, key: "knowledge_world_sync_status", json: "failed")
        Inf6MetadataStore.put(domain: .settings, key: "knowledge_world_sync_error", json: message)
        Inf6MetadataStore.put(domain: .settings, key: "knowledge_world_sync_completed_at", json: String(Date().timeIntervalSince1970))
        Inf6MetadataStore.put(domain: .settings, key: "knowledge_world_sync_trigger", json: trigger.rawValue)
    }
}

enum Inf6DailySyllabusRefreshScheduler {
    static let taskIdentifier = "com.inf6.inf6.syllabus.daily-refresh"

    static func register() {
        #if canImport(BackgroundTasks)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            _handle(refreshTask)
        }
        #endif
    }

    static func scheduleNext() {
        #if canImport(BackgroundTasks)
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Inf6SyllabusSourceAutoRefresh.nextCalendarDayRefreshDate()
        do {
            try BGTaskScheduler.shared.submit(request)
            Inf6MetadataStore.put(domain: .settings, key: "syllabus_daily_background_schedule_status", json: "ok")
            Inf6MetadataStore.put(domain: .settings, key: "syllabus_daily_background_scheduled_at", json: String(Date().timeIntervalSince1970))
        } catch {
            Inf6MetadataStore.put(domain: .settings, key: "syllabus_daily_background_schedule_status", json: "failed")
            Inf6MetadataStore.put(domain: .settings, key: "syllabus_daily_background_schedule_error", json: error.localizedDescription)
            Inf6MetadataStore.put(domain: .settings, key: "syllabus_daily_background_scheduled_at", json: String(Date().timeIntervalSince1970))
        }
        #endif
    }

    #if canImport(BackgroundTasks)
    private static func _handle(_ task: BGAppRefreshTask) {
        scheduleNext()
        let refresh = Task {
            let success = await Inf6KnowledgeWorldSync.shared.syncNow(trigger: .dailyBackground)
            task.setTaskCompleted(success: success)
        }
        task.expirationHandler = {
            refresh.cancel()
            Inf6MetadataStore.put(domain: .settings, key: "syllabus_auto_refresh_status", json: "expired")
            Inf6MetadataStore.put(domain: .settings, key: "syllabus_auto_refresh_error", json: "Daily background refresh expired before completion.")
            Inf6MetadataStore.put(domain: .settings, key: "syllabus_auto_refresh_at", json: String(Date().timeIntervalSince1970))
            task.setTaskCompleted(success: false)
        }
    }
    #endif
}

// MARK: - Domain Update Prompt

enum Inf6DomainUpdatePrompt {
    static func flagAvailable(familyID: String) {
        Inf6MetadataStore.put(domain: .settings, key: "domain_update_available:\(familyID)", json: "true")
        NotificationCenter.default.post(name: .inf6DomainUpdateAvailable, object: familyID)
    }

    static func clearFlag(familyID: String) {
        Inf6MetadataStore.put(domain: .settings, key: "domain_update_available:\(familyID)", json: "false")
    }

    static func isAvailable(familyID: String) -> Bool {
        Inf6MetadataStore.get(domain: .settings, key: "domain_update_available:\(familyID)") == "true"
    }
}

extension Notification.Name {
    static let inf6DomainUpdateAvailable = Notification.Name("inf6DomainUpdateAvailable")
}

// MARK: - Domain Sync Schedule

struct Inf6DomainSyncSchedule {
    let periodID: String
    let label: String

    enum Cadence {
        case jdlaHalfYear      // 3-8月(H1) / 9-2月(H2)
        case quarterly         // Q1-Q4 (Microsoft Learn等)
    }

    static func cadence(for manifest: Inf6LearningFamilyManifest) -> Cadence {
        if manifest.usesJDLAHTMLProvider { return .jdlaHalfYear }
        return .quarterly
    }

    static func current(cadence: Cadence) -> Inf6DomainSyncSchedule {
        let cal = Calendar.current
        let year = cal.component(.year, from: Date())
        let month = cal.component(.month, from: Date())
        switch cadence {
        case .jdlaHalfYear:
            if month >= 3 && month <= 8 {
                return Inf6DomainSyncSchedule(periodID: "\(year)-H1", label: "\(year)年3-8月期")
            } else {
                let fiscalYear = month >= 9 ? year : year - 1
                return Inf6DomainSyncSchedule(periodID: "\(fiscalYear)-H2", label: "\(fiscalYear)年9-2月期")
            }
        case .quarterly:
            let q = (month - 1) / 3 + 1
            return Inf6DomainSyncSchedule(periodID: "\(year)-Q\(q)", label: "\(year)年Q\(q)")
        }
    }

    static func current(for manifest: Inf6LearningFamilyManifest) -> Inf6DomainSyncSchedule {
        current(cadence: cadence(for: manifest))
    }

    static func needsUpdate(familyID: String, manifest: Inf6LearningFamilyManifest) -> Bool {
        let lastPeriod = _lastSyncPeriod(familyID: familyID)
        if lastPeriod.isEmpty { return false }
        return lastPeriod != current(for: manifest).periodID
    }

    static func needsUpdate(familyID: String) -> Bool {
        let lastPeriod = _lastSyncPeriod(familyID: familyID)
        if lastPeriod.isEmpty { return false }
        let jdlaFamilies = ["g-kentei", "e-shikaku"]
        let cadence: Cadence = jdlaFamilies.contains(familyID) ? .jdlaHalfYear : .quarterly
        return lastPeriod != current(cadence: cadence).periodID
    }

    static func recordSync(familyID: String, manifest: Inf6LearningFamilyManifest) {
        Inf6MetadataStore.put(domain: .settings, key: "domain_last_sync_period:\(familyID)", json: current(for: manifest).periodID)
    }

    static func _lastSyncPeriod(familyID: String) -> String {
        if let v = Inf6MetadataStore.get(domain: .settings, key: "domain_last_sync_period:\(familyID)"), !v.isEmpty {
            return v
        }
        if let old = Inf6MetadataStore.get(domain: .settings, key: "jdla_last_sync_period:\(familyID)"), !old.isEmpty {
            Inf6MetadataStore.put(domain: .settings, key: "domain_last_sync_period:\(familyID)", json: old)
            return old
        }
        return ""
    }
}

// Legacy aliases
typealias Inf6JDLASyncPeriod = Inf6DomainSyncSchedule
typealias Inf6JDLAUpdatePrompt = Inf6DomainUpdatePrompt
