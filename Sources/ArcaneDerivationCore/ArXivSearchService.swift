import Foundation

public struct ArXivPaperResult: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let abstractURL: URL
    public let pdfURL: URL

    public init(id: String, title: String, summary: String, abstractURL: URL, pdfURL: URL) {
        self.id = id
        self.title = title
        self.summary = summary
        self.abstractURL = abstractURL
        self.pdfURL = pdfURL
    }
}

public enum ArXivSearchError: LocalizedError {
    case emptyQuery
    case invalidResponse
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .emptyQuery: return "論文検索語を入力してください。"
        case .invalidResponse: return "ArXivの検索結果を解釈できません。"
        case .unavailable: return "ArXivから論文情報を取得できません。ネットワークを確認してください。"
        }
    }
}

public struct ArXivSearchService {
    public init() {}

    public func search(query: String, limit: Int = 20) async throws -> [ArXivPaperResult] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ArXivSearchError.emptyQuery }
        var components = URLComponents(string: "https://export.arxiv.org/api/query")!
        components.queryItems = [
            URLQueryItem(name: "search_query", value: "all:\(value)"),
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "max_results", value: String(max(1, min(limit, 50))))
        ]
        guard let url = components.url else { throw ArXivSearchError.unavailable }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ArXivSearchError.unavailable }
        let parser = ArXivFeedParser()
        guard parser.parse(data) else { throw ArXivSearchError.invalidResponse }
        return parser.results
    }
}

private final class ArXivFeedParser: NSObject, XMLParserDelegate {
    private(set) var results: [ArXivPaperResult] = []
    private var currentElement = ""
    private var currentText = ""
    private var currentID = ""
    private var currentTitle = ""
    private var currentSummary = ""
    private var currentAbstractURL: URL?
    private var currentPDFURL: URL?

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        currentText = ""
        if elementName == "entry" {
            currentID = ""
            currentTitle = ""
            currentSummary = ""
            currentAbstractURL = nil
            currentPDFURL = nil
        } else if elementName == "link", let href = attributeDict["href"], let url = URL(string: href) {
            if attributeDict["title"] == "pdf" { currentPDFURL = url }
            else if attributeDict["rel"] == "alternate" { currentAbstractURL = url }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { currentText += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "id": currentID = text
        case "title": currentTitle = text.replacingOccurrences(of: "\n", with: " ")
        case "summary": currentSummary = text.replacingOccurrences(of: "\n", with: " ")
        case "entry":
            if let abstractURL = currentAbstractURL, let pdfURL = currentPDFURL, !currentID.isEmpty, !currentTitle.isEmpty {
                results.append(ArXivPaperResult(id: currentID, title: currentTitle, summary: currentSummary, abstractURL: abstractURL, pdfURL: pdfURL))
            }
        default: break
        }
        currentElement = ""
        currentText = ""
    }
}
