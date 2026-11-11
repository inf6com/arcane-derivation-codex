//
//  Inf6ACLAnthologyClient.swift
//  inf6
//

import Foundation

// MARK: - ACL Anthology client (RSS index.xml)

enum Inf6ACLAnthologyClient {

    private static let _indexURLString = "https://aclanthology.org/papers/index.xml"
    private static var _cachedItems: [_ACLItem] = []
    private static var _cachedAt: TimeInterval = 0
    private static let _cacheTTLSeconds: TimeInterval = 900

    static func search(query: String, maxResults: Int) async throws -> [Inf6PaperSearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let limit = max(1, maxResults)

        if let direct = _parseACLURLIfACLHost(q) {
            return [try await _fetchDirectResult(from: direct)]
        }
        if _isHTTPURLString(q) {
            throw NSError(
                domain: "Inf6ACLAnthologyClient",
                code: -104,
                userInfo: [NSLocalizedDescriptionKey: "ACL Anthology 検索では ACL Anthology ドメインのURLを指定してください。"]
            )
        }

        let items = try await _loadItems()
        let normalizedQuery = _normalizeSearchText(q)
        let queryTokens = _queryTokens(from: normalizedQuery)

        let ranked: [(score: Int, item: _ACLItem)] = items.compactMap { item in
            guard let score = _matchScore(item: item, normalizedQuery: normalizedQuery, queryTokens: queryTokens) else {
                return nil
            }
            return (score, item)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.item.pubDate > rhs.item.pubDate
        }

        return ranked.prefix(limit).map { _toSearchResult($0.item) }
    }

    private static func _loadItems() async throws -> [_ACLItem] {
        let now = Date().timeIntervalSince1970
        objc_sync_enter(Inf6ACLAnthologyClient.self)
        let canUseCache = !_cachedItems.isEmpty && (now - _cachedAt) <= _cacheTTLSeconds
        let cached = _cachedItems
        objc_sync_exit(Inf6ACLAnthologyClient.self)
        if canUseCache { return cached }

        guard let url = URL(string: _indexURLString) else {
            throw NSError(
                domain: "Inf6ACLAnthologyClient",
                code: -100,
                userInfo: [NSLocalizedDescriptionKey: "Invalid ACL Anthology index URL."]
            )
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 45

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let snippet = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw NSError(
                domain: "Inf6ACLAnthologyClient",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "ACL Anthology index fetch failed (\(status)): \(snippet)"]
            )
        }

        let parser = _Inf6ACLRSSParser()
        let parsed = try parser.parseItems(data: data)
        if parsed.isEmpty {
            throw NSError(
                domain: "Inf6ACLAnthologyClient",
                code: -101,
                userInfo: [NSLocalizedDescriptionKey: "ACL Anthology index feed is empty."]
            )
        }

        objc_sync_enter(Inf6ACLAnthologyClient.self)
        _cachedItems = parsed
        _cachedAt = Date().timeIntervalSince1970
        objc_sync_exit(Inf6ACLAnthologyClient.self)
        return parsed
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

    private static func _matchScore(item: _ACLItem, normalizedQuery: String, queryTokens: [String]) -> Int? {
        let title = _normalizeSearchText(item.title)
        let desc = _normalizeSearchText(item.description)
        let id = _normalizeSearchText(item.id)
        let link = _normalizeSearchText(item.link)
        let pdfURL = _normalizeSearchText(item.pdfURLString)
        let haystack = [title, desc, id, link, pdfURL].joined(separator: " ")

        if !haystack.contains(normalizedQuery) {
            let allTokensHit = queryTokens.allSatisfy { token in haystack.contains(token) }
            if !allTokensHit { return nil }
        }

        var score = 0
        if title.contains(normalizedQuery) { score += 120 }
        if desc.contains(normalizedQuery) { score += 45 }
        if id.contains(normalizedQuery) { score += 18 }

        for token in queryTokens {
            if title.contains(token) { score += 16 }
            if desc.contains(token) { score += 6 }
            if id.contains(token) { score += 4 }
            if link.contains(token) { score += 3 }
            if pdfURL.contains(token) { score += 2 }
        }
        return score
    }

    private static func _toSearchResult(_ item: _ACLItem) -> Inf6PaperSearchResult {
        let subtitle: String = item.pubDate.isEmpty ? "ACL Anthology" : "ACL Anthology • \(item.pubDate)"
        return Inf6PaperSearchResult(
            id: "acl:\(item.id)",
            title: item.title,
            subtitle: subtitle,
            landingURL: URL(string: item.link),
            pdfURL: URL(string: item.pdfURLString),
            abstractText: item.description
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

    private static func _parseACLURLIfACLHost(_ raw: String) -> (paperID: String, landingURL: URL, pdfURL: URL)? {
        guard let c = URLComponents(string: raw),
              let scheme = c.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = c.host?.lowercased(),
              host.contains("aclanthology.org") else {
            return nil
        }
        let trimmedPath = c.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedPath.isEmpty else {
            return (paperID: "", landingURL: URL(string: "https://aclanthology.org/")!, pdfURL: URL(string: "https://aclanthology.org/")!)
        }
        guard let last = trimmedPath.split(separator: "/").last else {
            return (paperID: "", landingURL: URL(string: "https://aclanthology.org/")!, pdfURL: URL(string: "https://aclanthology.org/")!)
        }
        var token = String(last).trimmingCharacters(in: .whitespacesAndNewlines)
        if token.lowercased().hasSuffix(".pdf") {
            token = String(token.dropLast(4))
        }
        token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return (paperID: "", landingURL: URL(string: "https://aclanthology.org/")!, pdfURL: URL(string: "https://aclanthology.org/")!)
        }

        guard let landingURL = URL(string: "https://aclanthology.org/\(token)/"),
              let pdfURL = URL(string: "https://aclanthology.org/\(token).pdf") else {
            return nil
        }
        return (paperID: token, landingURL: landingURL, pdfURL: pdfURL)
    }

    private static func _fetchDirectResult(
        from direct: (paperID: String, landingURL: URL, pdfURL: URL)
    ) async throws -> Inf6PaperSearchResult {
        let paperID = direct.paperID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paperID.isEmpty else {
            throw NSError(
                domain: "Inf6ACLAnthologyClient",
                code: -105,
                userInfo: [NSLocalizedDescriptionKey: "ACL Anthology のURLから論文IDを抽出できませんでした。"]
            )
        }

        var req = URLRequest(url: direct.landingURL)
        req.httpMethod = "GET"
        req.timeoutInterval = 30

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw NSError(
                domain: "Inf6ACLAnthologyClient",
                code: -106,
                userInfo: [NSLocalizedDescriptionKey: "指定した ACL Anthology URL にアクセスできませんでした（\(status)）。"]
            )
        }

        let html = String(data: data, encoding: .utf8) ?? ""
        let title = _extractMetaContent(html: html, metaName: "citation_title")
            ?? _extractTitleTag(html: html)
            ?? paperID
        let abstractText = _extractACLPaperParamsAbstract(html: html)
            ?? _extractMetaContent(html: html, metaName: "description")
            ?? ""

        return Inf6PaperSearchResult(
            id: "acl:\(paperID)",
            title: _normalizeDisplayText(title, fallback: paperID),
            subtitle: "ACL Anthology",
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

    private static func _extractACLPaperParamsAbstract(html: String) -> String? {
        // ACL Anthology pages embed metadata in:
        // const paper_params={...,abstract:"..."} ,deleted_authors=[];
        guard let regex = try? NSRegularExpression(
            pattern: #"paper_params\s*=\s*\{[\s\S]*?abstract:"((?:\\.|[^"\\])*)""#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: html, options: [], range: full),
              match.numberOfRanges >= 2 else {
            return nil
        }

        let raw = ns.substring(with: match.range(at: 1))
        let unescaped = _decodeJavaScriptEscapedString(raw)
        let normalized = _normalizeDisplayText(unescaped, fallback: "")
        return normalized.isEmpty ? nil : normalized
    }

    private static func _decodeJavaScriptEscapedString(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "\\\\n", with: "\n")
        out = out.replacingOccurrences(of: "\\\\r", with: "\r")
        out = out.replacingOccurrences(of: "\\\\t", with: "\t")
        out = out.replacingOccurrences(of: #"\""#, with: "\"")
        out = out.replacingOccurrences(of: #"\/"#, with: "/")
        out = out.replacingOccurrences(of: #"\\'"#, with: "'")
        out = out.replacingOccurrences(of: #"\\\\"#, with: "\\")
        return _decodeHTMLEntities(out)
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
        t = t.replacingOccurrences(of: " - ACL Anthology", with: "", options: [.caseInsensitive])
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

    fileprivate struct _ACLItem: Hashable {
        let id: String
        let title: String
        let link: String
        let pdfURLString: String
        let pubDate: String
        let description: String
    }
}

fileprivate final class _Inf6ACLRSSParser: NSObject, XMLParserDelegate {

    private var _items: [Inf6ACLAnthologyClient._ACLItem] = []

    private var _inItem = false
    private var _currentElement = ""
    private var _buffer = ""

    private var _title = ""
    private var _link = ""
    private var _pubDate = ""
    private var _description = ""

    func parseItems(data: Data) throws -> [Inf6ACLAnthologyClient._ACLItem] {
        _items = []
        _inItem = false
        _currentElement = ""
        _buffer = ""
        _resetItem()

        let parser = XMLParser(data: data)
        parser.delegate = self
        let ok = parser.parse()
        if !ok {
            let msg = parser.parserError?.localizedDescription ?? "Unknown XMLParser error."
            throw NSError(
                domain: "_Inf6ACLRSSParser",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "ACL RSS parse failed: \(msg)"]
            )
        }
        return _items
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        _currentElement = elementName
        _buffer = ""

        if elementName == "item" {
            _inItem = true
            _resetItem()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard _inItem else { return }
        _buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "item" {
            _appendCurrentItemIfValid()
            _inItem = false
            _currentElement = ""
            _buffer = ""
            return
        }

        guard _inItem else { return }
        let value = _normalizeText(_buffer)
        switch elementName {
        case "title":
            _title = value
        case "link":
            _link = value
        case "pubDate":
            _pubDate = value
        case "description":
            _description = _normalizeText(_decodeEntities(_stripHTMLTags(value)))
        default:
            break
        }
        _currentElement = ""
        _buffer = ""
    }

    private func _appendCurrentItemIfValid() {
        let title = _normalizeText(_title)
        let link = _normalizeText(_link)
        guard !title.isEmpty, !link.isEmpty else { return }

        let normalizedLink = link.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let id = URL(string: link)?.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines) ?? normalizedLink
        if id.isEmpty { return }

        let pdfURLString = normalizedLink + ".pdf"
        _items.append(
            Inf6ACLAnthologyClient._ACLItem(
                id: id,
                title: title,
                link: link,
                pdfURLString: pdfURLString,
                pubDate: _normalizeText(_pubDate),
                description: _normalizeText(_description)
            )
        )
    }

    private func _resetItem() {
        _title = ""
        _link = ""
        _pubDate = ""
        _description = ""
    }

    private func _normalizeText(_ s: String) -> String {
        var t = s
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while t.contains("  ") {
            t = t.replacingOccurrences(of: "  ", with: " ")
        }
        return t
    }

    private func _stripHTMLTags(_ s: String) -> String {
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

    private func _decodeEntities(_ s: String) -> String {
        s
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
