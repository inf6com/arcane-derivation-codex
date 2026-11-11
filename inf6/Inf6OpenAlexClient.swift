//
//  Inf6OpenAlexClient.swift
//  inf6
//
//  OpenAlex scholarly works search client.
//

import Foundation

enum Inf6OpenAlexClient {

    private static let _worksURLString = "https://api.openalex.org/works"

    static func search(query: String, maxResults: Int) async throws -> [Inf6PaperSearchResult] {
        let q = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "?", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return try await _fetchWorks(
            queryItem: URLQueryItem(name: "search", value: q),
            maxResults: maxResults,
            sorted: true
        )
    }

    /// タイトル指定でのみ照合する。OpenAlex の `title.search:` は filter パラメータの構文であり、
    /// search パラメータに渡すと "title.search:" という文字列自体が検索語として扱われ、
    /// 実在する論文でもヒット0件になる(arXiv 未収録の古典論文が軒並み検証不能になっていた原因)。
    /// DOI で一意に引く。
    ///
    /// search= に "doi:..." を渡しても全文検索として扱われ、DOI とは無関係な
    /// 論文が返る。実測では Support-vector networks の DOI で Rayyan などが
    /// 返った。DOI は filter= で指定しなければならない。
    static func searchByDOI(doi: String, maxResults: Int = 1) async throws -> [Inf6PaperSearchResult] {
        let d = doi
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "doi:", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty else { return [] }
        return try await _fetchWorks(
            queryItem: URLQueryItem(name: "filter", value: "doi:\(d)"),
            maxResults: maxResults,
            sorted: false
        )
    }

    static func searchByTitle(title: String, maxResults: Int) async throws -> [Inf6PaperSearchResult] {
        let t = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "|", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        return try await _fetchWorks(
            queryItem: URLQueryItem(name: "filter", value: "title.search:\(t)"),
            maxResults: maxResults,
            sorted: false
        )
    }

    /// 指定した論文の参考文献をOpenAlexから取得する。
    /// OpenAlexの検索結果URLではなく、work IDを直接照会してから参考文献を取得する。
    static func references(workID: String, maxResults: Int = 50) async throws -> [Inf6PaperSearchResult] {
        let rawID = workID
            .replacingOccurrences(of: "openalex:", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawID.isEmpty else { return [] }
        guard let url = URL(string: "\(_worksURLString)/\(rawID)?select=referenced_works") else {
            throw NSError(domain: "Inf6OpenAlexClient", code: -302, userInfo: [NSLocalizedDescriptionKey: "Invalid OpenAlex work URL."])
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let snippet = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw NSError(domain: "Inf6OpenAlexClient", code: status, userInfo: [NSLocalizedDescriptionKey: "OpenAlex reference lookup failed (\(status)): \(snippet)"])
        }
        struct Work: Decodable { let referenced_works: [String]? }
        let work = try JSONDecoder().decode(Work.self, from: data)
        let ids = (work.referenced_works ?? []).prefix(max(1, min(maxResults, 50)))
        guard !ids.isEmpty else { return [] }
        return try await _fetchWorks(
            queryItem: URLQueryItem(name: "filter", value: "openalex_id:\(ids.joined(separator: "|"))"),
            maxResults: ids.count,
            sorted: false
        )
    }

    private static func _fetchWorks(
        queryItem: URLQueryItem,
        maxResults: Int,
        sorted: Bool
    ) async throws -> [Inf6PaperSearchResult] {
        let limit = max(1, min(maxResults, 50))

        guard var comps = URLComponents(string: _worksURLString) else {
            throw NSError(
                domain: "Inf6OpenAlexClient",
                code: -300,
                userInfo: [NSLocalizedDescriptionKey: "Invalid OpenAlex works URL."]
            )
        }
        var items: [URLQueryItem] = [
            queryItem,
            URLQueryItem(name: "per-page", value: String(limit)),
            URLQueryItem(
                name: "select",
                value: "id,doi,display_name,publication_year,primary_location,open_access,abstract_inverted_index"
            ),
        ]
        // relevance_score での並べ替えは search パラメータ使用時のみ有効。
        if sorted {
            items.append(URLQueryItem(name: "sort", value: "relevance_score:desc"))
        }
        comps.queryItems = items
        guard let url = comps.url else {
            throw NSError(
                domain: "Inf6OpenAlexClient",
                code: -301,
                userInfo: [NSLocalizedDescriptionKey: "Failed to build OpenAlex request URL."]
            )
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let snippet = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw NSError(
                domain: "Inf6OpenAlexClient",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "OpenAlex search failed (\(status)): \(snippet)"]
            )
        }

        let decoded = try JSONDecoder().decode(_OpenAlexWorksResponse.self, from: data)
        if decoded.results.isEmpty { return [] }

        var out: [Inf6PaperSearchResult] = []
        out.reserveCapacity(decoded.results.count)

        for (idx, work) in decoded.results.enumerated() {
            let fallbackID = "openalex:\(idx)"
            let id = _idFromWork(work, fallback: fallbackID)
            let title = _normalizeDisplayText(work.display_name, fallback: id)
            let sourceName = _normalizeDisplayText(work.primary_location?.source?.display_name, fallback: "OpenAlex")
            let yearText = work.publication_year.map(String.init) ?? ""
            let subtitle = [sourceName, yearText].filter { !$0.isEmpty }.joined(separator: " • ")
            let landingURL = _preferredLandingURL(work: work)
            let pdfURL = _preferredPDFURL(work: work)
            let abstractText = _abstractFromInvertedIndex(work.abstract_inverted_index)

            out.append(
                Inf6PaperSearchResult(
                    id: id,
                    title: title,
                    subtitle: subtitle.isEmpty ? "OpenAlex" : subtitle,
                    landingURL: landingURL,
                    pdfURL: pdfURL,
                    abstractText: abstractText,
                    publishedAt: _dateFromPublicationYear(work.publication_year)
                )
            )
        }
        return out
    }

    /// OpenAlex は発行年しか返さないため、その年の1月1日として保持する。
    /// これを埋めないと呼び出し側で year が nil となり、検証済み論文が
    /// 表示フィルタ(year != nil)で落とされてしまう。
    private static func _dateFromPublicationYear(_ year: Int?) -> Date? {
        guard let year, year > 0 else { return nil }
        var comps = DateComponents()
        comps.year = year
        comps.month = 1
        comps.day = 1
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return cal.date(from: comps)
    }

    private static func _idFromWork(_ work: _OpenAlexWork, fallback: String) -> String {
        if let rawID = work.id?.trimmingCharacters(in: .whitespacesAndNewlines), !rawID.isEmpty {
            if let u = URL(string: rawID), !u.lastPathComponent.isEmpty {
                return "openalex:" + u.lastPathComponent
            }
            return "openalex:" + rawID
        }
        if let doi = work.doi?.trimmingCharacters(in: .whitespacesAndNewlines), !doi.isEmpty {
            return "doi:" + doi
        }
        return fallback
    }

    private static func _preferredLandingURL(work: _OpenAlexWork) -> URL? {
        if let s = work.primary_location?.landing_page_url?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty,
           let u = URL(string: s) {
            return u
        }
        if let doi = work.doi?.trimmingCharacters(in: .whitespacesAndNewlines),
           !doi.isEmpty,
           let u = URL(string: doi) {
            return u
        }
        return nil
    }

    private static func _preferredPDFURL(work: _OpenAlexWork) -> URL? {
        if let s = work.primary_location?.pdf_url?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty,
           let u = URL(string: s),
           _looksLikePDFURL(u) {
            return u
        }
        if let s = work.open_access?.oa_url?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty,
           let u = URL(string: s),
           _looksLikePDFURL(u) {
            return u
        }
        return nil
    }

    private static func _looksLikePDFURL(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        if path.hasSuffix(".pdf") { return true }
        return url.absoluteString.lowercased().contains("pdf")
    }

    private static func _abstractFromInvertedIndex(_ index: [String: [Int]]?) -> String {
        guard let index, !index.isEmpty else { return "" }
        let maxPosition = index.values.compactMap { $0.max() }.max() ?? -1
        guard maxPosition >= 0 else { return "" }

        var words = Array(repeating: "", count: maxPosition + 1)
        for (token, positions) in index {
            for pos in positions where pos >= 0 && pos < words.count {
                words[pos] = token
            }
        }
        return words
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func _normalizeDisplayText(_ raw: String?, fallback: String) -> String {
        let normalized = (raw ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return normalized.isEmpty ? fallback : normalized
    }

    private struct _OpenAlexWorksResponse: Decodable {
        let results: [_OpenAlexWork]
    }

    private struct _OpenAlexWork: Decodable {
        let id: String?
        let doi: String?
        let display_name: String?
        let publication_year: Int?
        let primary_location: _OpenAlexLocation?
        let open_access: _OpenAlexOpenAccess?
        let abstract_inverted_index: [String: [Int]]?
    }

    private struct _OpenAlexLocation: Decodable {
        let landing_page_url: String?
        let pdf_url: String?
        let source: _OpenAlexSource?
    }

    private struct _OpenAlexSource: Decodable {
        let display_name: String?
    }

    private struct _OpenAlexOpenAccess: Decodable {
        let oa_url: String?
    }
}
