import Foundation

// MARK: - Content Provider Protocol

protocol Inf6ContentProvider {
    var providerID: String { get }
    var displayName: String { get }
    func search(query: String, maxResults: Int) async throws -> [Inf6ContentItem]
}

// MARK: - Content Item (unified result)

struct Inf6ContentItem: Identifiable, Hashable {
    let id: String
    let title: String
    let authors: [String]
    let summary: String
    let sourceURL: URL?
    let pdfURL: URL?
    let publishedYear: Int?
    let providerID: String
}

// MARK: - Provider Registry

enum Inf6ContentProviderRegistry {

    static func providers(for ids: [String]) -> [any Inf6ContentProvider] {
        ids.compactMap { provider(for: $0) }
    }

    static func provider(for id: String) -> (any Inf6ContentProvider)? {
        switch id {
        case "arxiv":           return Inf6ArxivContentProvider()
        case "pubmed":          return Inf6PubMedContentProvider()
        case "microsoft_learn": return Inf6MicrosoftLearnContentProvider()
        case "ai_generated":    return Inf6AIGeneratedContentProvider()
        default:                return nil
        }
    }
}

// MARK: - arXiv Provider

struct Inf6ArxivContentProvider: Inf6ContentProvider {
    let providerID = "arxiv"
    let displayName = "arXiv"

    func search(query: String, maxResults: Int) async throws -> [Inf6ContentItem] {
        let candidates = try await Inf6EshikakuPaperSearch.fetchArxivCandidates(
            query: query, maxResults: maxResults
        )
        return candidates.map { c in
            Inf6ContentItem(
                id: c.id,
                title: c.title,
                authors: c.authors,
                summary: c.summary,
                sourceURL: c.absURL,
                pdfURL: c.pdfURL,
                publishedYear: nil,
                providerID: providerID
            )
        }
    }
}

// MARK: - PubMed Provider

struct Inf6PubMedContentProvider: Inf6ContentProvider {
    let providerID = "pubmed"
    let displayName = "PubMed"

    func search(query: String, maxResults: Int) async throws -> [Inf6ContentItem] {
        let candidates = try await Inf6EshikakuPaperSearch.fetchPubMedCandidates(
            query: query, maxResults: maxResults
        )
        return candidates.map { c in
            Inf6ContentItem(
                id: c.id,
                title: c.title,
                authors: c.authors,
                summary: c.summary,
                sourceURL: c.absURL,
                pdfURL: c.pdfURL,
                publishedYear: nil,
                providerID: providerID
            )
        }
    }
}

// MARK: - Microsoft Learn Provider

struct Inf6MicrosoftLearnContentProvider: Inf6ContentProvider {
    let providerID = "microsoft_learn"
    let displayName = "Microsoft Learn"

    func search(query: String, maxResults: Int) async throws -> [Inf6ContentItem] {
        let url = URL(string: "https://learn.microsoft.com/api/search?search=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)&locale=en-us&%24top=\(maxResults)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return []
        }
        return results.prefix(maxResults).compactMap { result -> Inf6ContentItem? in
            guard let title = result["title"] as? String,
                  let urlStr = result["url"] as? String else { return nil }
            let desc = result["description"] as? String ?? ""
            let itemURL = URL(string: urlStr)
            return Inf6ContentItem(
                id: urlStr,
                title: title,
                authors: [],
                summary: desc,
                sourceURL: itemURL,
                pdfURL: nil,
                publishedYear: nil,
                providerID: providerID
            )
        }
    }
}

// MARK: - AI Generated Content Provider

struct Inf6AIGeneratedContentProvider: Inf6ContentProvider {
    let providerID = "ai_generated"
    let displayName = "AI生成"

    func search(query: String, maxResults: Int) async throws -> [Inf6ContentItem] {
        let prompt = _buildPrompt(query: query, maxResults: maxResults)
        let apiKey = try OpenAIKeyStore.load()
        let cfg = try OpenAIClient.Config.default(model: "gpt-4o-mini")
        let client = OpenAIClient(apiKey: apiKey, config: cfg)
        let response = try await client.generateText(prompt: prompt)
        return _parseResponse(response, query: query)
    }

    private func _buildPrompt(query: String, maxResults: Int) -> String {
        """
        以下のトピックについて、学習に役立つ情報を\(maxResults)件、JSON配列で生成してください。
        トピック: \(query)

        各項目は以下の形式:
        [{"id":"一意ID","title":"タイトル","summary":"200字以内の解説","year":出版年または該当年}]

        信頼性の高い情報源（教科書、公式ドキュメント、著名な解説記事）を優先してください。
        JSONのみ出力してください。
        """
    }

    private func _parseResponse(_ response: String, query: String) -> [Inf6ContentItem] {
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item -> Inf6ContentItem? in
            guard let id = item["id"] as? String,
                  let title = item["title"] as? String else { return nil }
            return Inf6ContentItem(
                id: id,
                title: title,
                authors: [],
                summary: item["summary"] as? String ?? "",
                sourceURL: (item["url"] as? String).flatMap { URL(string: $0) },
                pdfURL: nil,
                publishedYear: item["year"] as? Int,
                providerID: providerID
            )
        }
    }
}
