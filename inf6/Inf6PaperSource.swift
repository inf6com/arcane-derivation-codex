//
//  Inf6PaperSources.swift
//  inf6
//
//  Sources settings + source identifiers + search URL builder
//

import Foundation
import SwiftUI



// MARK: - Sources settings (Paper Search)

/// Reusable sources toggles UI.
/// Stores state in UserDefaults via AppStorage keys.
struct Inf6SourcesToggleSection: View {
    @AppStorage("inf6.source.arxiv") private var enableArxiv: Bool = true
    @AppStorage("inf6.source.openreview") private var enableOpenReview: Bool = true
    @AppStorage("inf6.source.acl") private var enableACL: Bool = true
    @AppStorage("inf6.source.pmlr") private var enablePMLR: Bool = true
    @AppStorage("inf6.source.cvf") private var enableCVF: Bool = true
    @AppStorage("inf6.source.pubmed") private var enablePubMed: Bool = true

    var body: some View {
        Toggle("arXiv", isOn: $enableArxiv)
        Toggle("PubMed", isOn: $enablePubMed)
        Toggle("OpenReview", isOn: $enableOpenReview)
        Toggle("ACL Anthology", isOn: $enableACL)
        Toggle("PMLR", isOn: $enablePMLR)
        Toggle("CVF (CVPR/ICCV/ECCV)", isOn: $enableCVF)

        Text(Inf6Lang.text(
            "※ この設定は『論文検索』で使用する検索元のON/OFFです。",
            "These toggles enable/disable sources used by paper search."
        ))
        .font(.footnote)
        .foregroundStyle(.secondary)

        Text(Inf6Lang.text(
            "アプリ内の候補一覧（API取得）は現在 arXiv / PubMed のみ対応です。その他のサイトは、外部ブラウザで検索タブを開く動作になります。",
            "The in-app candidate list (API fetch) currently supports arXiv / PubMed only. Other sources open external browser search tabs."
        ))
        .font(.footnote)
        .foregroundStyle(.secondary)

        Text(Inf6Lang.text(
            "PDFの自動取得は、候補に“直接のPDF URL”が存在する場合のみ可能です。arXivは直PDFを提供しますが、PubMedは論文DBのため、多くの論文は直PDFがありません。PubMed候補の自動取得はPMC（PubMed Central）にPDFが存在する場合のみ可能です（存在しない場合は取得できません）。",
            "Automatic PDF fetching is only possible when a candidate has a direct PDF URL. arXiv provides direct PDF links, but PubMed is a literature database and often does not provide a direct PDF. For PubMed candidates, automatic fetching is only possible when a PDF exists in PMC (PubMed Central); otherwise it cannot be fetched."
        ))
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}




// MARK: - Sources (UserDefaults-backed) helpers

/// Paper-source identifiers used by the Sources settings sheet.
/// This reflects the current `@AppStorage("inf6.source.*")` boolean keys.
enum Inf6PaperSourceID: String, CaseIterable, Identifiable, Hashable {
    case arxiv
    case openreview
    case acl
    case pmlr
    case cvf
    case pubmed

    var id: String { rawValue }

    /// The exact UserDefaults/AppStorage key for enabling this source.
    var enableKey: String {
        "inf6.source.\(rawValue)"
    }

    /// UI display name (kept consistent with the Sources settings sheet).
    var displayName: String {
        switch self {
        case .arxiv: return "arXiv"
        case .openreview: return "OpenReview"
        case .acl: return "ACL Anthology"
        case .pmlr: return "PMLR"
        case .cvf: return "CVF (CVPR/ICCV/ECCV)"
        case .pubmed: return "PubMed"
        }
    }
}


// MARK: - Paper source -> search URL (single responsibility)

extension Inf6PaperSourceID {

    /// Build a search URL for the given query.
    /// All endpoints live here so other code never hard-codes per-source URLs.
    func searchURL(query q: String) -> URL? {
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }

        switch self {
        case .arxiv:
            var c = URLComponents(string: "https://arxiv.org/search/")
            c?.queryItems = [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "searchtype", value: "all"),
                URLQueryItem(name: "source", value: "header")
            ]
            return c?.url

        case .openreview:
            var c = URLComponents(string: "https://openreview.net/search")
            c?.queryItems = [URLQueryItem(name: "query", value: query)]
            return c?.url

        case .acl:
            var c = URLComponents(string: "https://aclanthology.org/search/")
            c?.queryItems = [URLQueryItem(name: "q", value: query)]
            return c?.url

        case .pmlr:
            return Self.__duckDuckGoSiteSearchURL(site: "proceedings.mlr.press", query: query)

        case .cvf:
            return Self.__duckDuckGoSiteSearchURL(site: "openaccess.thecvf.com", query: query)

        case .pubmed:
            var c = URLComponents(string: "https://pubmed.ncbi.nlm.nih.gov/")
            c?.queryItems = [URLQueryItem(name: "term", value: query)]
            return c?.url
        }
    }

    private static func __duckDuckGoSiteSearchURL(site: String, query: String) -> URL? {
        var c = URLComponents(string: "https://duckduckgo.com/")
        c?.queryItems = [URLQueryItem(name: "q", value: "site:\(site) \(query)")]
        return c?.url
    }
}


/// Resolves enabled sources and (when unambiguous) a single selected source.
///
/// NOTE: The current UI exposes ON/OFF toggles per source, not a single-choice picker.
/// Therefore, selecting a single source is only possible when exactly one source is enabled.
/// If none or multiple are enabled, this helper returns an explicit error (no fallback).
struct Inf6PaperSourceSelection {

    enum SelectionError: LocalizedError, Equatable {
        case noneEnabled
        case multipleEnabled([Inf6PaperSourceID])

        var errorDescription: String? {
            switch self {
            case .noneEnabled:
                return Inf6Lang.text(
                    "収集元が1つも有効化されていません。『収集サイト』で少なくとも1つ有効にしてください。",
                    "No sources are enabled. Please enable at least one source in Sources."
                )
            case .multipleEnabled(let sources):
                let names = sources.map { $0.displayName }.joined(separator: ", ")
                return Inf6Lang.text(
                    "収集元が複数有効です（\(names)）。単一ソースの操作には、収集元を1つだけ有効にしてください。",
                    "Multiple sources are enabled (\(names)). For single-source operations, enable exactly one source."
                )
            }
        }
    }

    /// Returns all currently enabled sources in a stable order.
    static func enabledSources(userDefaults: UserDefaults = .standard) -> [Inf6PaperSourceID] {
        Inf6PaperSourceID.allCases.filter { src in
            // AppStorage のデフォルト値（= true）と揃える。
            // UserDefaults にキーが無い場合は「未設定」なので true 扱いとする。
            if userDefaults.object(forKey: src.enableKey) == nil {
                return true
            }
            return userDefaults.bool(forKey: src.enableKey)
        }
    }

    /// Returns a single selected source when (and only when) exactly one source is enabled.
    /// Otherwise returns an explicit error.
    static func selectedSingleSource(userDefaults: UserDefaults = .standard) -> Result<Inf6PaperSourceID, SelectionError> {
        let enabled = enabledSources(userDefaults: userDefaults)
        if enabled.isEmpty {
            return .failure(.noneEnabled)
        }
        if enabled.count == 1, let only = enabled.first {
            return .success(only)
        }
        return .failure(.multipleEnabled(enabled))
    }
}


// MARK: - E資格 paper search (logic only)

enum Inf6EshikakuPaperSearch {

    /// Sources toggles -> enabled list
    static func enabledSources(userDefaults: UserDefaults = .standard) -> [Inf6PaperSourceID] {
        Inf6PaperSourceSelection.enabledSources(userDefaults: userDefaults)
    }

    /// Decide a “primary” source (order = Inf6PaperSourceID.allCases).
    static func usingSourceOrThrow(userDefaults: UserDefaults = .standard) throws -> (using: Inf6PaperSourceID, note: String?) {
        let enabled = enabledSources(userDefaults: userDefaults)
        guard !enabled.isEmpty else {
            throw NSError(domain: "Inf6PaperSearch", code: 1001, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "論文検索の収集サイトが無効です。『収集サイト』で1つ以上を有効にしてください。",
                    "All paper sources are disabled. In Sources, enable at least one."
                )
            ])
        }

        let enabledSet = Set(enabled)
        let orderedEnabled = Inf6PaperSourceID.allCases.filter { enabledSet.contains($0) }
        let using = orderedEnabled.first ?? enabled[0]

        let others = enabled.filter { $0 != using }
        if others.isEmpty { return (using: using, note: nil) }

        let names = others.map { $0.displayName }.joined(separator: ", ")
        let note = Inf6Lang.text(
            "※ 有効な収集元: \(using.displayName)（同時に有効: \(names)）。",
            "Note: Enabled sources: \(using.displayName) (also enabled: \(names))."
        )
        return (using: using, note: note)
    }

    /// Build URLs to open externally (caller decides how to open).
    static func searchURLsForEnabledSources(query: String, userDefaults: UserDefaults = .standard) throws -> [(source: Inf6PaperSourceID, url: URL)] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        let enabled = enabledSources(userDefaults: userDefaults)
        guard !enabled.isEmpty else {
            throw NSError(domain: "Inf6PaperSearch", code: 1001, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "論文検索の収集サイトが無効です。『収集サイト』で1つ以上を有効にしてください。",
                    "All paper sources are disabled. In Sources, enable at least one."
                )
            ])
        }

        let enabledSet = Set(enabled)
        let ordered = Inf6PaperSourceID.allCases.filter { enabledSet.contains($0) }

        var out: [(Inf6PaperSourceID, URL)] = []
        out.reserveCapacity(ordered.count)

        for src in ordered {
            if let u = src.searchURL(query: q) {
                out.append((src, u))
            }
        }
        return out
    }

    // MARK: - E資格: query builder

    static func buildEshikakuPaperQuery(selectedItems: [Inf6SyllabusOutlineItem]) -> String {
        func normalize(_ s: String) -> String {
            var t = s
            for ch in ["/", "・", "、", "（", "）", "(", ")", "：", ":", "\n", "\r"] {
                t = t.replacingOccurrences(of: ch, with: " ")
            }
            t = t
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var parts: [String] = []
        parts.reserveCapacity(selectedItems.count * 2)

        for it in selectedItems {
            // Prefer both Ja/En if available so arXiv (mostly English) can match.
            let titleCandidates: [String] = [it.titleEn, it.titleJa, it.title]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            for tt in titleCandidates.prefix(2) {
                let t = normalize(tt)
                if !t.isEmpty { parts.append(t) }
            }

            let summaryCandidates: [String] = [it.summaryEn, it.summaryJa, it.summary]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if let s0 = summaryCandidates.first {
                let clipped = s0.count > 140 ? String(s0.prefix(140)) : s0
                let sn = normalize(clipped)
                if !sn.isEmpty { parts.append(sn) }
            }
        }

        // De-dup (case-insensitive), preserve order
        var seen = Set<String>()
        let deduped = parts.filter {
            let k = $0.localizedLowercase
            if seen.contains(k) { return false }
            seen.insert(k)
            return true
        }

        var q = deduped.joined(separator: " ")
        q = q
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if q.count > 260 { q = String(q.prefix(260)) }
        return q
    }

    // MARK: - E資格: arXiv API

    static func fetchArxivCandidates(query: String, maxResults: Int) async throws -> [Inf6PaperCandidate] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        // arXiv API is ATOM XML.
        // Use export.arxiv.org (recommended for automated requests).
        var components = URLComponents(string: "https://export.arxiv.org/api/query")
        components?.queryItems = [
            URLQueryItem(name: "search_query", value: "all:" + q),
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "max_results", value: String(max(1, min(50, maxResults))))
        ]

        guard let url = components?.url else { return [] }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 25

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "Inf6Arxiv", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"
            ])
        }

        let parser = _ArxivFeedParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        let ok = xml.parse()
        if !ok {
            throw xml.parserError ?? NSError(domain: "Inf6Arxiv", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "XML parse failed"
            ])
        }

        // Post-process: stabilize id, de-dup.
        var out: [Inf6PaperCandidate] = []
        out.reserveCapacity(parser.items.count)
        var seen = Set<String>()

        for it in parser.items {
            let stableID = normalizeArxivID(it.arxivAbsID)
            guard !stableID.isEmpty else { continue }
            guard seen.insert(stableID).inserted else { continue }

            out.append(.init(
                id: stableID,
                title: it.title,
                authors: it.authors,
                summary: it.summary,
                absURL: it.absURL,
                pdfURL: it.pdfURL
            ))
        }
        return out
    }

    // MARK: - E資格: PubMed API (E-utilities)

    static func fetchPubMedCandidates(query: String, maxResults: Int) async throws -> [Inf6PaperCandidate] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        let n = max(1, min(200, maxResults))

        // 1) ESearch: term -> PMID list (JSON)
        var esearch = URLComponents(string: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi")
        esearch?.queryItems = [
            URLQueryItem(name: "db", value: "pubmed"),
            URLQueryItem(name: "term", value: q),
            URLQueryItem(name: "retmode", value: "json"),
            URLQueryItem(name: "retmax", value: String(n)),
            URLQueryItem(name: "tool", value: "inf6")
        ]

        guard let esearchURL = esearch?.url else {
            throw NSError(domain: "Inf6PubMed", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid ESearch URL"
            ])
        }

        var req1 = URLRequest(url: esearchURL)
        req1.httpMethod = "GET"
        req1.timeoutInterval = 25

        let (d1, r1) = try await URLSession.shared.data(for: req1)
        if let http = r1 as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "Inf6PubMed", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"
            ])
        }

        let esearchResp = try JSONDecoder().decode(_PubMedESearchResponse.self, from: d1)
        let pmids = esearchResp.esearchresult.idlist
        if pmids.isEmpty { return [] }

        // 2) ESummary: PMID list -> metadata (JSON)
        //    Keep the batch size modest to avoid overly long URLs.
        let batchSize = 100
        var candidates: [Inf6PaperCandidate] = []
        candidates.reserveCapacity(pmids.count)

        var seen = Set<String>()

        for chunkStart in stride(from: 0, to: pmids.count, by: batchSize) {
            let chunk = Array(pmids[chunkStart..<min(pmids.count, chunkStart + batchSize)])
            let idCSV = chunk.joined(separator: ",")

            var esummary = URLComponents(string: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi")
            esummary?.queryItems = [
                URLQueryItem(name: "db", value: "pubmed"),
                URLQueryItem(name: "id", value: idCSV),
                URLQueryItem(name: "retmode", value: "json"),
                URLQueryItem(name: "tool", value: "inf6")
            ]

            guard let esummaryURL = esummary?.url else {
                throw NSError(domain: "Inf6PubMed", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid ESummary URL"
                ])
            }

            var req2 = URLRequest(url: esummaryURL)
            req2.httpMethod = "GET"
            req2.timeoutInterval = 25

            let (d2, r2) = try await URLSession.shared.data(for: req2)
            if let http = r2 as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw NSError(domain: "Inf6PubMed", code: http.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"
                ])
            }

            let esummaryResp = try JSONDecoder().decode(_PubMedESummaryResponse.self, from: d2)

            for pmid in esummaryResp.result.uids {
                guard !pmid.isEmpty else { continue }
                guard seen.insert(pmid).inserted else { continue }

                guard let item = esummaryResp.result.items[pmid] else { continue }

                let title = (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty { continue }

                let authors: [String] = (item.authors ?? [])
                    .compactMap { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                var summaryParts: [String] = []
                if let source = item.source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty {
                    summaryParts.append(source)
                }
                if let pubdate = item.pubdate?.trimmingCharacters(in: .whitespacesAndNewlines), !pubdate.isEmpty {
                    summaryParts.append(pubdate)
                }
                let summary = summaryParts.joined(separator: " • ")

                let absURL = URL(string: "https://pubmed.ncbi.nlm.nih.gov/\(pmid)/")

                candidates.append(.init(
                    id: pmid,
                    title: title,
                    authors: authors,
                    summary: summary,
                    absURL: absURL,
                    pdfURL: nil
                ))
            }
        }

        return candidates
    }

    // MARK: - PubMed -> PMC -> direct PDF URL (best-effort, explicit)

    /// Resolve a PubMed PMID to a PMC ID (PMCID) when the article is available in PubMed Central.
    /// Returns nil when no PMC full text is linked.
    static func resolvePMCID(forPMID pmid: String) async throws -> String? {
        let id = pmid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        var c = URLComponents(string: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/elink.fcgi")
        c?.queryItems = [
            URLQueryItem(name: "dbfrom", value: "pubmed"),
            URLQueryItem(name: "db", value: "pmc"),
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "retmode", value: "json"),
            URLQueryItem(name: "tool", value: "inf6")
        ]

        guard let url = c?.url else {
            throw NSError(domain: "Inf6PubMed", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Invalid ELink URL"
            ])
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 25

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "Inf6PubMed", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"
            ])
        }

        let decoded = try JSONDecoder().decode(_PubMedELinkResponse.self, from: data)

        // Prefer any linkset that actually targets PMC.
        for ls in decoded.linksets {
            for db in ls.linksetdbs ?? [] {
                let dbto = (db.dbto ?? "").lowercased()
                if dbto == "pmc", let links = db.links, let first = links.first {
                    let raw = first.trimmingCharacters(in: .whitespacesAndNewlines)
                    if raw.isEmpty { continue }
                    if raw.uppercased().hasPrefix("PMC") { return raw }
                    // ELink often returns numeric IDs; PMCID is "PMC" + digits.
                    if raw.allSatisfy({ $0.isNumber }) {
                        return "PMC" + raw
                    }
                    return raw
                }
            }
        }

        return nil
    }

    /// Given a PMCID, fetch the PMC HTML and extract the direct PDF URL.
    /// Returns nil when the page does not expose a direct PDF link.
    static func resolvePMCPDFURL(forPMCID pmcid: String) async throws -> URL? {
        let id = pmcid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        guard let pageURL = URL(string: "https://pmc.ncbi.nlm.nih.gov/articles/\(id)/") else {
            throw NSError(domain: "Inf6PubMed", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "Invalid PMC article URL"
            ])
        }

        var req = URLRequest(url: pageURL)
        req.httpMethod = "GET"
        req.timeoutInterval = 25

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "Inf6PubMed", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"
            ])
        }

        // PMC pages are UTF-8 HTML.
        let html = String(data: data, encoding: .utf8) ?? ""
        if html.isEmpty { return nil }

        // Examples observed:
        //  - /articles/PMCxxxxxxx/pdf/<file>.pdf
        //  - /articles/PMCxxxxxxx/bin/<file>.pdf
        // We extract the first matching href.
        let pattern = "href=\"([^\"]*/articles/PMC[0-9]+/(?:pdf|bin)/[^\"]+\\.pdf[^\"]*)\""
        let re = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)

        guard let m = re.firstMatch(in: html, options: [], range: range), m.numberOfRanges >= 2 else {
            return nil
        }

        let href = ns.substring(with: m.range(at: 1))
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return URL(string: trimmed)
        }

        if trimmed.hasPrefix("/") {
            return URL(string: "https://pmc.ncbi.nlm.nih.gov\(trimmed)")
        }

        return URL(string: "https://pmc.ncbi.nlm.nih.gov/\(trimmed)")
    }

    /// Best-effort: resolve a PubMed PMID into a direct PDF URL via PMC.
    /// Returns nil when the article is not available in PMC or when PMC does not expose a PDF link.
    static func resolvePubMedPDFURLIfPossible(pmid: String) async throws -> URL? {
        guard let pmcid = try await resolvePMCID(forPMID: pmid) else {
            return nil
        }
        return try await resolvePMCPDFURL(forPMCID: pmcid)
    }

    private struct _PubMedELinkResponse: Decodable {
        let linksets: [_PubMedELinkLinkSet]
    }

    private struct _PubMedELinkLinkSet: Decodable {
        let linksetdbs: [_PubMedELinkLinkSetDB]?

        enum CodingKeys: String, CodingKey {
            case linksetdbs = "linksetdbs"
        }
    }

    private struct _PubMedELinkLinkSetDB: Decodable {
        let dbto: String?
        let links: [String]?
        let linkname: String?
    }

    // MARK: - E資格: in-app supported sources (dispatcher)

    enum InAppSupportError: LocalizedError {
        case unsupportedSource(Inf6PaperSourceID)

        var errorDescription: String? {
            switch self {
            case .unsupportedSource(let src):
                return Inf6Lang.text(
                    "候補一覧（アプリ内表示）は現在 arXiv / PubMed のみ対応です（要求: \(src.displayName)）。",
                    "The in-app candidate list currently supports arXiv / PubMed only (requested: \(src.displayName))."
                )
            }
        }
    }

    /// Fetch candidates for the given primary source.
    /// - Important: Only arXiv / PubMed are supported for in-app listing.
    static func fetchCandidates(using source: Inf6PaperSourceID, query: String, maxResults: Int) async throws -> [Inf6PaperCandidate] {
        switch source {
        case .arxiv:
            return try await fetchArxivCandidates(query: query, maxResults: maxResults)
        case .pubmed:
            return try await fetchPubMedCandidates(query: query, maxResults: maxResults)
        default:
            throw InAppSupportError.unsupportedSource(source)
        }
    }

    // MARK: - E資格: YAML builder (generated papers manifest)

    enum YAMLBuildError: LocalizedError {
        case unsupportedProvider(Inf6PaperSourceID)

        var errorDescription: String? {
            switch self {
            case .unsupportedProvider(let src):
                return Inf6Lang.text(
                    "YAML生成は現在 arXiv / PubMed のみ対応です（要求: \(src.displayName)）。",
                    "YAML generation currently supports arXiv / PubMed only (requested: \(src.displayName))."
                )
            }
        }
    }

    /// Build a `papers:` YAML snippet for the selected candidates.
    /// - Important: This is a *generated* manifest snippet for inf6 import.
    /// - Keys:
    ///   - provider: `arxiv` / `pubmed`
    ///   - arXiv id: `arxiv_id`
    ///   - PubMed id: `pmid`
    static func buildPapersYAML(provider: Inf6PaperSourceID, selected: [Inf6PaperCandidate]) throws -> String {
        guard !selected.isEmpty else { return "" }

        let idKey: String
        switch provider {
        case .arxiv:
            idKey = "arxiv_id"
        case .pubmed:
            idKey = "pmid"
        default:
            throw YAMLBuildError.unsupportedProvider(provider)
        }

        func yq(_ s: String) -> String {
            let t = s.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(t)\""
        }

        var lines: [String] = []
        lines.append("papers:")

        for p in selected {
            let title = p.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }

            lines.append("  - title: \(yq(title))")
            lines.append("    provider: \(provider.rawValue)")
            lines.append("    \(idKey): \(yq(p.id))")
            lines.append("    tags: [eshikaku]")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private struct _PubMedESearchResponse: Decodable {
        let esearchresult: _PubMedESearchResult
    }

    private struct _PubMedESearchResult: Decodable {
        let idlist: [String]
    }

    private struct _PubMedESummaryResponse: Decodable {
        let result: _PubMedESummaryResult
    }

    private struct _PubMedESummaryResult: Decodable {
        let uids: [String]
        let items: [String: _PubMedESummaryItem]

        private struct _DynamicKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: _DynamicKey.self)

            let uidsKey = _DynamicKey(stringValue: "uids")!
            self.uids = (try? c.decode([String].self, forKey: uidsKey)) ?? []

            var map: [String: _PubMedESummaryItem] = [:]
            map.reserveCapacity(uids.count)

            for uid in uids {
                guard let k = _DynamicKey(stringValue: uid) else { continue }
                if c.contains(k) {
                    if let item = try? c.decode(_PubMedESummaryItem.self, forKey: k) {
                        map[uid] = item
                    }
                }
            }
            self.items = map
        }
    }

    private struct _PubMedESummaryItem: Decodable {
        let uid: String?
        let title: String?
        let pubdate: String?
        let source: String?
        let authors: [_PubMedAuthor]?
    }

    private struct _PubMedAuthor: Decodable {
        let name: String?
    }

    static func normalizeArxivID(_ absID: String) -> String {
        // Examples:
        //   http://arxiv.org/abs/1706.03762v7
        //   https://arxiv.org/abs/1506.01497
        let s = absID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }

        // If a full URL, keep the tail.
        let tail: String = {
            if let u = URL(string: s), u.scheme != nil {
                return u.lastPathComponent
            }
            return s
        }()

        // Drop version suffix: vN
        if let r = tail.range(of: "v", options: .backwards),
           r.lowerBound < tail.endIndex {
            let suffix = String(tail[r.lowerBound...])
            if suffix.count >= 2, suffix.dropFirst().allSatisfy({ $0.isNumber }) {
                return String(tail[..<r.lowerBound])
            }
        }
        return tail
    }

    // MARK: - arXiv ATOM feed parser

    final class _ArxivFeedParser: NSObject, XMLParserDelegate {

        struct Item {
            var arxivAbsID: String = ""
            var title: String = ""
            var summary: String = ""
            var authors: [String] = []
            var absURL: URL? = nil
            var pdfURL: URL? = nil
        }

        private(set) var items: [Item] = []

        private var inEntry: Bool = false
        private var current = Item()

        private var currentElement: String? = nil
        private var buffer: String = ""

        private var inAuthor: Bool = false
        private var currentAuthorName: String = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
            currentElement = elementName
            buffer = ""

            if elementName == "entry" {
                inEntry = true
                current = Item()
                return
            }

            guard inEntry else { return }

            if elementName == "author" {
                inAuthor = true
                currentAuthorName = ""
                return
            }

            if elementName == "link" {
                // ATOM: <link rel="alternate" href="..."/>, PDF link often has title="pdf" or type="application/pdf"
                let rel = (attributeDict["rel"] ?? "").lowercased()
                let href = attributeDict["href"] ?? ""
                let type = (attributeDict["type"] ?? "").lowercased()
                let title = (attributeDict["title"] ?? "").lowercased()

                if let u = URL(string: href) {
                    if rel == "alternate" {
                        current.absURL = u
                    }
                    if title == "pdf" || type == "application/pdf" {
                        current.pdfURL = u
                    }
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inEntry else { return }
            buffer += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard inEntry else { return }

            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

            if elementName == "id" {
                if !text.isEmpty {
                    current.arxivAbsID = text
                    if current.absURL == nil, let u = URL(string: text) {
                        current.absURL = u
                    }
                }
            } else if elementName == "title" {
                if !text.isEmpty {
                    current.title = text
                }
            } else if elementName == "summary" {
                if !text.isEmpty {
                    current.summary = text
                }
            } else if elementName == "name" {
                if inAuthor {
                    currentAuthorName = text
                }
            } else if elementName == "author" {
                inAuthor = false
                let name = currentAuthorName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    current.authors.append(name)
                }
                currentAuthorName = ""
            } else if elementName == "entry" {
                inEntry = false

                // If no PDF link was provided, derive it from abs id when possible.
                // arXiv commonly uses /abs/<id> and /pdf/<id>.pdf.
                if current.pdfURL == nil {
                    let tail = current.arxivAbsID.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !tail.isEmpty {
                        let idTail: String = {
                            if let u = URL(string: tail), u.scheme != nil {
                                return u.lastPathComponent
                            }
                            return tail
                        }()
                        let base = normalizeArxivID(idTail)
                        if !base.isEmpty {
                            current.pdfURL = URL(string: "https://arxiv.org/pdf/\(base).pdf")
                        }
                    }
                }

                items.append(current)
            }

            buffer = ""
            currentElement = nil
        }
    }
}
