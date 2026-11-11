//
//  Inf6ISCAArchiveClient.swift
//  inf6
//

import Foundation

// MARK: - ISCA Archive client (papers_table.txt)

enum Inf6ISCAArchiveClient {

    private static let _tableURLString = "https://www.isca-archive.org/papers_table.txt"
    private static var _cachedRows: [_Row] = []
    private static var _cachedAt: TimeInterval = 0
    private static let _cacheTTLSeconds: TimeInterval = 900

    static func search(query: String, maxResults: Int) async throws -> [Inf6PaperSearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let limit = max(1, maxResults)

        if _isISCAArchiveURLString(q) {
            guard let direct = _parseISCAURLIfISCAHost(q) else {
                throw NSError(
                    domain: "Inf6ISCAArchiveClient",
                    code: -203,
                    userInfo: [NSLocalizedDescriptionKey: "ISCA Archive URL から必要な識別子を抽出できませんでした。"]
                )
            }
            return [try await _fetchDirectResult(from: direct)]
        }
        if _isHTTPURLString(q) {
            throw NSError(
                domain: "Inf6ISCAArchiveClient",
                code: -205,
                userInfo: [NSLocalizedDescriptionKey: "ISCA Archive 検索では isca-archive.org ドメインのURLを指定してください。"]
            )
        }

        let rows = try await _loadRows()
        let normalizedQuery = _normalizeSearchText(q)
        let queryTokens = _queryTokens(from: normalizedQuery)

        let ranked: [(score: Int, row: _Row)] = rows.compactMap { row in
            guard let score = _matchScore(row: row, normalizedQuery: normalizedQuery, queryTokens: queryTokens) else {
                return nil
            }
            return (score, row)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.row.year != rhs.row.year { return lhs.row.year > rhs.row.year }
            return lhs.row.title < rhs.row.title
        }

        return ranked.prefix(limit).map { _toSearchResult($0.row) }
    }

    private static func _loadRows() async throws -> [_Row] {
        let now = Date().timeIntervalSince1970
        objc_sync_enter(Inf6ISCAArchiveClient.self)
        let canUseCache = !_cachedRows.isEmpty && (now - _cachedAt) <= _cacheTTLSeconds
        let cached = _cachedRows
        objc_sync_exit(Inf6ISCAArchiveClient.self)
        if canUseCache { return cached }

        guard let url = URL(string: _tableURLString) else {
            throw NSError(
                domain: "Inf6ISCAArchiveClient",
                code: -200,
                userInfo: [NSLocalizedDescriptionKey: "Invalid ISCA papers table URL."]
            )
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 60

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let snippet = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw NSError(
                domain: "Inf6ISCAArchiveClient",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "ISCA papers table fetch failed (\(status)): \(snippet)"]
            )
        }

        let rows = try _decodeRows(data: data)
        if rows.isEmpty {
            throw NSError(
                domain: "Inf6ISCAArchiveClient",
                code: -201,
                userInfo: [NSLocalizedDescriptionKey: "ISCA papers table is empty."]
            )
        }

        objc_sync_enter(Inf6ISCAArchiveClient.self)
        _cachedRows = rows
        _cachedAt = Date().timeIntervalSince1970
        objc_sync_exit(Inf6ISCAArchiveClient.self)
        return rows
    }

    private static func _decodeRows(data: Data) throws -> [_Row] {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let rawRows = obj as? [[Any]] else {
            throw NSError(
                domain: "Inf6ISCAArchiveClient",
                code: -202,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected ISCA table format (expected JSON array)."]
            )
        }

        var out: [_Row] = []
        out.reserveCapacity(rawRows.count)

        for raw in rawRows {
            guard raw.count >= 6 else { continue }

            let authors = (raw[0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = (raw[1] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let conference = (raw[2] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let year = (raw[3] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let keywords = (raw[4] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let id = (raw[5] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard !title.isEmpty, !conference.isEmpty, !year.isEmpty, !id.isEmpty else { continue }

            let conferenceSlug = conference.lowercased()
            let base = "https://www.isca-archive.org/\(conferenceSlug)_\(year)/\(id)_\(conferenceSlug)"
            out.append(
                _Row(
                    authors: authors,
                    title: title,
                    conference: conference,
                    conferenceSlug: conferenceSlug,
                    year: year,
                    keywords: keywords,
                    id: id,
                    htmlURLString: base + ".html",
                    pdfURLString: base + ".pdf"
                )
            )
        }
        return out
    }

    private static func _normalizeSearchText(_ s: String) -> String {
        s
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func _queryTokens(from normalizedQuery: String) -> [String] {
        let tokens = normalizedQuery
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
        if tokens.isEmpty, !normalizedQuery.isEmpty {
            return [normalizedQuery]
        }
        return tokens
    }

    private static func _matchScore(row: _Row, normalizedQuery: String, queryTokens: [String]) -> Int? {
        let title = _normalizeSearchText(row.title)
        let authors = _normalizeSearchText(row.authors)
        let keywords = _normalizeSearchText(row.keywords)
        let conference = _normalizeSearchText(row.conference)
        let id = _normalizeSearchText(row.id)
        let htmlURL = _normalizeSearchText(row.htmlURLString)
        let pdfURL = _normalizeSearchText(row.pdfURLString)
        let haystack = [title, authors, keywords, conference, id, htmlURL, pdfURL].joined(separator: " ")

        if !haystack.contains(normalizedQuery) {
            let allTokensHit = queryTokens.allSatisfy { token in haystack.contains(token) }
            if !allTokensHit { return nil }
        }

        var score = 0
        if title.contains(normalizedQuery) { score += 120 }
        if authors.contains(normalizedQuery) { score += 40 }
        if keywords.contains(normalizedQuery) { score += 55 }
        if conference.contains(normalizedQuery) { score += 24 }
        if id.contains(normalizedQuery) { score += 10 }

        for token in queryTokens {
            if title.contains(token) { score += 16 }
            if authors.contains(token) { score += 7 }
            if keywords.contains(token) { score += 9 }
            if conference.contains(token) { score += 4 }
            if id.contains(token) { score += 2 }
            if htmlURL.contains(token) { score += 3 }
            if pdfURL.contains(token) { score += 2 }
        }
        return score
    }

    private static func _toSearchResult(_ row: _Row) -> Inf6PaperSearchResult {
        let subtitle = [row.authors, "\(row.conference) \(row.year)"]
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
        let abstractText = row.keywords.isEmpty ? "" : "Keywords: \(row.keywords)"
        return Inf6PaperSearchResult(
            id: "isca:\(row.id)_\(row.conferenceSlug)_\(row.year)",
            title: row.title,
            subtitle: subtitle,
            landingURL: URL(string: row.htmlURLString),
            pdfURL: URL(string: row.pdfURLString),
            abstractText: abstractText
        )
    }

    private static func _isHTTPURLString(_ raw: String) -> Bool {
        guard let c = URLComponents(string: raw),
              let scheme = c.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              c.host != nil else {
            return false
        }
        return true
    }

    private static func _isISCAArchiveURLString(_ raw: String) -> Bool {
        guard let c = URLComponents(string: raw),
              let scheme = c.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = c.host?.lowercased() else {
            return false
        }
        return host.contains("isca-archive.org")
    }

    private static func _parseISCAURLIfISCAHost(
        _ raw: String
    ) -> (conferenceSlug: String, year: String, paperID: String, landingURL: URL, pdfURL: URL)? {
        guard let c = URLComponents(string: raw),
              let scheme = c.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = c.host?.lowercased(),
              host.contains("isca-archive.org") else {
            return nil
        }

        let trimmedPath = c.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = trimmedPath.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }

        let conferenceYearPart = parts[0]
        guard let confSplit = conferenceYearPart.lastIndex(of: "_") else {
            return nil
        }
        let conferenceSlug = String(conferenceYearPart[..<confSplit]).trimmingCharacters(in: .whitespacesAndNewlines)
        let year = String(conferenceYearPart[conferenceYearPart.index(after: confSplit)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !conferenceSlug.isEmpty, !year.isEmpty else { return nil }

        var fileToken = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        if fileToken.lowercased().hasSuffix(".html") {
            fileToken = String(fileToken.dropLast(5))
        } else if fileToken.lowercased().hasSuffix(".pdf") {
            fileToken = String(fileToken.dropLast(4))
        }

        let suffix = "_" + conferenceSlug
        let paperID: String
        if !conferenceSlug.isEmpty, fileToken.hasSuffix(suffix) {
            paperID = String(fileToken.dropLast(suffix.count))
        } else {
            paperID = fileToken
        }
        let normalizedPaperID = paperID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPaperID.isEmpty else { return nil }

        guard let landingURL = URL(string: "https://www.isca-archive.org/\(conferenceSlug)_\(year)/\(normalizedPaperID)_\(conferenceSlug).html"),
              let pdfURL = URL(string: "https://www.isca-archive.org/\(conferenceSlug)_\(year)/\(normalizedPaperID)_\(conferenceSlug).pdf") else {
            return nil
        }

        return (
            conferenceSlug: conferenceSlug,
            year: year,
            paperID: normalizedPaperID,
            landingURL: landingURL,
            pdfURL: pdfURL
        )
    }

    private static func _fetchDirectResult(
        from direct: (conferenceSlug: String, year: String, paperID: String, landingURL: URL, pdfURL: URL)
    ) async throws -> Inf6PaperSearchResult {
        var req = URLRequest(url: direct.landingURL)
        req.httpMethod = "GET"
        req.timeoutInterval = 30

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw NSError(
                domain: "Inf6ISCAArchiveClient",
                code: -206,
                userInfo: [NSLocalizedDescriptionKey: "指定した ISCA Archive URL にアクセスできませんでした（\(status)）。"]
            )
        }

        let html = String(data: data, encoding: .utf8) ?? ""
        let title = _extractTitleTag(html: html) ?? direct.paperID
        let abstractText = _extractISCAAbstractBody(html: html)
            ?? _extractMetaContent(html: html, metaName: "description")
            ?? ""

        return Inf6PaperSearchResult(
            id: "isca:\(direct.paperID)_\(direct.conferenceSlug)_\(direct.year)",
            title: _normalizeDisplayText(title, fallback: direct.paperID),
            subtitle: "ISCA Archive • \(direct.conferenceSlug) \(direct.year)",
            landingURL: direct.landingURL,
            pdfURL: direct.pdfURL,
            abstractText: _normalizeDisplayText(abstractText, fallback: "")
        )
    }

    private static func _extractMetaContent(html: String, metaName: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: metaName)
        let patterns = [
            "<meta\\s+[^>]*name\\s*=\\s*\""+escapedName+"\"[^>]*content\\s*=\\s*\"([^\"]+)\"[^>]*>",
            "<meta\\s+[^>]*content\\s*=\\s*\"([^\"]+)\"[^>]*name\\s*=\\s*\""+escapedName+"\"[^>]*>",
            "<meta\\s+[^>]*name\\s*=\\s*'"+escapedName+"'[^>]*content\\s*=\\s*'([^']+)'[^>]*>",
            "<meta\\s+[^>]*content\\s*=\\s*'([^']+)'[^>]*name\\s*=\\s*'"+escapedName+"'[^>]*>"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let ns = html as NSString
            let full = NSRange(location: 0, length: ns.length)
            guard let match = regex.firstMatch(in: html, options: [], range: full),
                  match.numberOfRanges >= 2 else {
                continue
            }
            let v = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let decoded = _decodeHTMLEntities(v)
            if !decoded.isEmpty { return decoded }
        }
        return nil
    }

    private static func _extractISCAAbstractBody(html: String) -> String? {
        guard let blockRegex = try? NSRegularExpression(
            pattern: #"<div\s+id=["']abstract["'][^>]*>([\s\S]*?)</div>"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let blockMatch = blockRegex.firstMatch(in: html, options: [], range: full),
              blockMatch.numberOfRanges >= 2 else {
            return nil
        }

        var block = ns.substring(with: blockMatch.range(at: 1))
        block = block.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        block = _decodeHTMLEntities(block)
        block = block.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let normalized = block.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func _extractTitleTag(html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<title[^>]*>(.*?)</title>", options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: html, options: [], range: full),
              match.numberOfRanges >= 2 else {
            return nil
        }
        var t = ns.substring(with: match.range(at: 1))
        t = _decodeHTMLEntities(t)
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: " - ISCA Archive", with: "", options: [.caseInsensitive])
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func _decodeHTMLEntities(_ s: String) -> String {
        s
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private static func _normalizeDisplayText(_ s: String, fallback: String) -> String {
        let t = s
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if t.isEmpty { return fallback }
        return t
    }

    private struct _Row: Hashable {
        let authors: String
        let title: String
        let conference: String
        let conferenceSlug: String
        let year: String
        let keywords: String
        let id: String
        let htmlURLString: String
        let pdfURLString: String
    }
}
