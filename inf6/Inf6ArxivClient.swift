//
//  Inf6ArxivClient.swift
//  inf6
//
//  arXiv search client (Atom API).
//

import Foundation

actor Inf6ArxivRateLimiter {
    static let shared = Inf6ArxivRateLimiter()

    private static let _minIntervalUserDefaultsKey = "inf6_arxiv_min_interval_seconds"

    static func configuredMinIntervalSeconds() -> Double {
        let v = UserDefaults.standard.double(forKey: _minIntervalUserDefaultsKey)
        return v > 0.0 ? v : 3.2
    }

    /// 次に送信してよい時刻。待つ前にここを進めて順番を予約する。
    private var nextAvailableAt: Date = .distantPast

    func waitIfNeeded(minIntervalSeconds: Double) async {
        // 待ってから記録するのでは、同時に呼ばれたとき全員が同じ時刻を読む。
        //
        // actor は await で中断した隙に次の呼び出しを受け入れるため、
        // sleep のあとに lastRequestAt を更新する実装では、待っている間に
        // 入ってきた呼び出しが同じ基準時刻から待ち時間を計算する。結果として
        // 全員が同時に起きて一斉に発射し、レート制限に当たる。
        //
        // 中断する前に自分の順番を確定させ、そのぶん次の呼び出しを後ろへ送る。
        let interval = max(0.0, minIntervalSeconds)
        let now = Date()
        let slot = max(now, nextAvailableAt)
        nextAvailableAt = slot.addingTimeInterval(interval)

        let delay = slot.timeIntervalSince(now)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000.0))
        }
    }
}

enum Inf6ArxivClientError: LocalizedError {
    case badURL
    case badStatus(Int, String)
    case notAtom
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Invalid URL."
        case .badStatus(let code, let snippet):
            return "HTTP error \(code): \(snippet)"
        case .notAtom:
            return "Response is not an Atom feed."
        case .parseFailed(let msg):
            return "Failed to parse arXiv feed: \(msg)"
        }
    }
}

enum Inf6ArxivClient {

    static func fetchByID(arxivID: String) async throws -> [Inf6PaperSearchResult] {
        try await searchByID(arxivID: arxivID)
    }

    static func fetchRecent(category: String, maxResults: Int) async throws -> [Inf6PaperSearchResult] {
        let c = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return [] }

        let aiMLCats = [
            "cs.LG",
            "stat.ML",
            "cs.AI",
            "cs.CV",
            "cs.CL",
            "cs.NE"
        ]
        let aiMLClause = aiMLCats
            .map { "cat:\($0)" }
            .joined(separator: " OR ")

        let query = "(\(aiMLClause)) AND (cat:\(c))"
        return try await search(
            query: query,
            maxResults: maxResults,
            sortBy: "lastUpdatedDate",
            sortOrder: "descending"
        )
    }

    /// 429 とタイムアウトに耐える送信。
    ///
    /// arXiv は短時間に集中すると 429 を返し、混雑時は応答も遅くなる。
    /// 一度で諦めると生成が失敗するため、待ってから作り直す。待ち時間は
    /// Retry-After があればそれに従い、無ければ指数的に伸ばす。
    /// 待つ前にレート制御の順番も取り直し、再試行が新たなバーストにならない
    /// ようにする。
    private static func _send(_ url: URL) async throws -> Data {
        let maxAttempts = 3
        var attempt = 0
        var lastError: Error?

        while attempt < maxAttempts {
            attempt += 1
            await Inf6ArxivRateLimiter.shared.waitIfNeeded(
                minIntervalSeconds: Inf6ArxivRateLimiter.configuredMinIntervalSeconds()
            )

            let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let http = resp as? HTTPURLResponse
                let status = http?.statusCode ?? -1
                if status == 429, attempt < maxAttempts {
                    let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                    let backoff = retryAfter ?? Double(1 << attempt) * 2.0
                    NSLog("[Arxiv] 429; retrying in %.1fs (attempt %d/%d)", backoff, attempt, maxAttempts)
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    continue
                }
                guard (200..<300).contains(status) else {
                    let snippet = String(data: data.prefix(600), encoding: .utf8) ?? ""
                    throw Inf6ArxivClientError.badStatus(status, snippet)
                }
                return data
            } catch let error as URLError where error.code == .timedOut && attempt < maxAttempts {
                let backoff = Double(1 << attempt) * 2.0
                NSLog("[Arxiv] timeout; retrying in %.1fs (attempt %d/%d)", backoff, attempt, maxAttempts)
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                lastError = error
                continue
            }
        }
        throw lastError ?? Inf6ArxivClientError.badStatus(429, "Rate exceeded after \(maxAttempts) attempts.")
    }

    static func searchByID(arxivID: String) async throws -> [Inf6PaperSearchResult] {
        let id = arxivID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return [] }

        var comps = URLComponents(string: "https://export.arxiv.org/api/query")
        comps?.queryItems = [
            URLQueryItem(name: "id_list", value: id),
            URLQueryItem(name: "max_results", value: "1")
        ]
        guard let url = comps?.url else { throw Inf6ArxivClientError.badURL }

        let data = try await _send(url)

        let head = String(data: data.prefix(200), encoding: .utf8) ?? ""
        guard head.contains("<feed") else { throw Inf6ArxivClientError.notAtom }

        let parser = Inf6ArxivAtomParser()
        return try parser.parse(data: data)
    }

    static func search(query: String, maxResults: Int) async throws -> [Inf6PaperSearchResult] {
        try await search(query: query, maxResults: maxResults, sortBy: "relevance", sortOrder: "descending")
    }

    static func search(
        query: String,
        maxResults: Int,
        sortBy: String,
        sortOrder: String
    ) async throws -> [Inf6PaperSearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        var comps = URLComponents(string: "https://export.arxiv.org/api/query")
        comps?.queryItems = [
            URLQueryItem(name: "search_query", value: q),
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "max_results", value: String(max(1, min(maxResults, 50)))),
            URLQueryItem(name: "sortBy", value: sortBy),
            URLQueryItem(name: "sortOrder", value: sortOrder)
        ]
        guard let url = comps?.url else { throw Inf6ArxivClientError.badURL }

        let data = try await _send(url)

        let head = String(data: data.prefix(200), encoding: .utf8) ?? ""
        guard head.contains("<feed") else { throw Inf6ArxivClientError.notAtom }

        let parser = Inf6ArxivAtomParser()
        return try parser.parse(data: data)
    }
}

final class Inf6ArxivAtomParser: NSObject, XMLParserDelegate {

    private var currentElement: String = ""
    private var currentTitle: String = ""
    private var currentSummary: String = ""
    private var currentID: String = ""
    private var currentPublished: String = ""
    private var currentUpdated: String = ""
    private var currentPDFURL: URL? = nil
    private var currentLandingURL: URL? = nil
    private let dateFormatter = ISO8601DateFormatter()

    private var inEntry: Bool = false
    private var items: [Inf6PaperSearchResult] = []
    private var parseErrorMessage: String? = nil

    func parse(data: Data) throws -> [Inf6PaperSearchResult] {
        items = []
        parseErrorMessage = nil

        let xml = XMLParser(data: data)
        xml.delegate = self
        let ok = xml.parse()

        if !ok {
            let msg = parseErrorMessage ?? xml.parserError?.localizedDescription ?? "unknown"
            throw Inf6ArxivClientError.parseFailed(msg)
        }
        return items
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        parseErrorMessage = parseError.localizedDescription
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String : String] = [:]) {

        currentElement = elementName

        if elementName == "entry" {
            inEntry = true
            currentTitle = ""
            currentSummary = ""
            currentID = ""
            currentPublished = ""
            currentUpdated = ""
            currentPDFURL = nil
            currentLandingURL = nil
            return
        }

        guard inEntry else { return }

        if elementName == "link" {
            let rel = attributeDict["rel"] ?? ""
            let href = attributeDict["href"] ?? ""
            let title = attributeDict["title"] ?? ""

            if rel == "alternate", let u = URL(string: href) {
                currentLandingURL = u
            }
            if title.lowercased() == "pdf", let u = URL(string: href) {
                currentPDFURL = u
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inEntry else { return }

        switch currentElement {
        case "title":
            currentTitle += string
        case "summary":
            currentSummary += string
        case "id":
            currentID += string
        case "published":
            currentPublished += string
        case "updated":
            currentUpdated += string
        default:
            break
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {

        if elementName == "entry" {
            inEntry = false

            let title = currentTitle
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let summary = currentSummary
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let rawID = currentID.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = rawID.isEmpty ? UUID().uuidString : rawID
            let published = dateFormatter.date(from: currentPublished.trimmingCharacters(in: .whitespacesAndNewlines))
            let updated = dateFormatter.date(from: currentUpdated.trimmingCharacters(in: .whitespacesAndNewlines))

            let item = Inf6PaperSearchResult(
                id: id,
                title: title.isEmpty ? "(no title)" : title,
                subtitle: summary,
                landingURL: currentLandingURL,
                pdfURL: currentPDFURL,
                abstractText: summary,
                publishedAt: published,
                updatedAt: updated
            )
            items.append(item)

            currentElement = ""
            return
        }

        if elementName == currentElement {
            currentElement = ""
        }
    }
}
