//
//  Inf6PubMedClient.swift
//  inf6
//
//  PubMed search client (NCBI E-utilities).
//

import Foundation

actor Inf6PubMedRateLimiter {
    static let shared = Inf6PubMedRateLimiter()

    private static let _minIntervalUserDefaultsKey = "inf6_pubmed_min_interval_seconds"

    static func configuredMinIntervalSeconds() -> Double {
        let v = UserDefaults.standard.double(forKey: _minIntervalUserDefaultsKey)
        // Be polite by default; user can override in Settings / Defaults.
        return v > 0.0 ? v : 0.6
    }

    private var lastRequestAt: Date? = nil

    func waitIfNeeded(minIntervalSeconds: Double) async {
        let now = Date()
        if let last = lastRequestAt {
            let dt = now.timeIntervalSince(last)
            let minDt = max(0.0, minIntervalSeconds)
            if dt < minDt {
                let sleepSec = (minDt - dt)
                let nanos = UInt64(sleepSec * 1_000_000_000.0)
                if nanos > 0 {
                    try? await Task.sleep(nanoseconds: nanos)
                }
            }
        }
        lastRequestAt = Date()
    }
}

enum Inf6PubMedClientError: LocalizedError {
    case badURL
    case badStatus(Int, String)
    case parseFailed(String)
    case emptyIDList

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Invalid URL."
        case .badStatus(let code, let snippet):
            return "HTTP error \(code): \(snippet)"
        case .parseFailed(let msg):
            return "Failed to parse PubMed response: \(msg)"
        case .emptyIDList:
            return "No PubMed IDs returned."
        }
    }
}

enum Inf6PubMedClient {

    /// Search PubMed by term, returning title + abstract when available.
    static func search(term: String, maxResults: Int) async throws -> [Inf6PaperSearchResult] {
        try await search(term: term, maxResults: maxResults, identityEmail: nil, sort: nil)
    }

    static func fetchRecent(meshHeading: String, maxResults: Int, identityEmail: String) async throws -> [Inf6PaperSearchResult] {
        let mh = meshHeading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mh.isEmpty else { return [] }

        let term = "\"\(mh)\"[mh]"
        return try await search(term: term, maxResults: maxResults, identityEmail: identityEmail, sort: "pub+date")
    }

    static func fetch(pmids: [String], identityEmail: String? = nil) async throws -> [Inf6PaperSearchResult] {
        let ids = pmids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !ids.isEmpty else { return [] }
        return try await fetchByIDCSV(ids.prefix(50).joined(separator: ","), identityEmail: identityEmail)
    }

    static func referencePMIDs(pmid: String, identityEmail: String? = nil) async throws -> [String] {
        try await linkedPMIDs(pmid: pmid, linkName: "pubmed_pubmed_refs", identityEmail: identityEmail)
    }

    static func citedByPMIDs(pmid: String, identityEmail: String? = nil) async throws -> [String] {
        try await linkedPMIDs(pmid: pmid, linkName: "pubmed_pubmed_citedin", identityEmail: identityEmail)
    }

    private static func search(term: String, maxResults: Int, identityEmail: String?, sort: String?) async throws -> [Inf6PaperSearchResult] {
        let q = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        let retmax = max(1, min(maxResults, 20))

        // 1) esearch -> pmid list (JSON)
        var esearch = URLComponents(string: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi")
        var esearchItems = [
            URLQueryItem(name: "db", value: "pubmed"),
            URLQueryItem(name: "term", value: q),
            URLQueryItem(name: "retmode", value: "json"),
            URLQueryItem(name: "retmax", value: String(retmax))
        ]
        if let sort, !sort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            esearchItems.append(URLQueryItem(name: "sort", value: sort))
        }
        esearchItems.append(URLQueryItem(name: "tool", value: "inf6"))
        if let identityEmail {
            let email = identityEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !email.isEmpty {
                esearchItems.append(URLQueryItem(name: "email", value: email))
            }
        }
        esearch?.queryItems = esearchItems
        guard let esearchURL = esearch?.url else { throw Inf6PubMedClientError.badURL }

        await Inf6PubMedRateLimiter.shared.waitIfNeeded(
            minIntervalSeconds: Inf6PubMedRateLimiter.configuredMinIntervalSeconds()
        )

        let req1 = URLRequest(url: esearchURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let (data1, resp1) = try await URLSession.shared.data(for: req1)
        let st1 = (resp1 as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(st1) else {
            let sn = String(data: data1.prefix(600), encoding: .utf8) ?? ""
            throw Inf6PubMedClientError.badStatus(st1, sn)
        }

        struct _ESearchRoot: Decodable {
            struct _ESearchResult: Decodable {
                let idlist: [String]
            }
            let esearchresult: _ESearchResult
        }

        let root = try JSONDecoder().decode(_ESearchRoot.self, from: data1)
        let ids = root.esearchresult.idlist
        guard !ids.isEmpty else { return [] }

        let idCSV = ids.prefix(retmax).joined(separator: ",")
        return try await fetchByIDCSV(idCSV, identityEmail: identityEmail)
    }

    private static func fetchByIDCSV(_ idCSV: String, identityEmail: String?) async throws -> [Inf6PaperSearchResult] {
        // efetch -> XML with titles + abstracts
        var efetch = URLComponents(string: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi")
        var efetchItems = [
            URLQueryItem(name: "db", value: "pubmed"),
            URLQueryItem(name: "id", value: idCSV),
            URLQueryItem(name: "retmode", value: "xml"),
            URLQueryItem(name: "tool", value: "inf6")
        ]
        if let identityEmail {
            let email = identityEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !email.isEmpty {
                efetchItems.append(URLQueryItem(name: "email", value: email))
            }
        }
        efetch?.queryItems = efetchItems
        guard let efetchURL = efetch?.url else { throw Inf6PubMedClientError.badURL }

        await Inf6PubMedRateLimiter.shared.waitIfNeeded(
            minIntervalSeconds: Inf6PubMedRateLimiter.configuredMinIntervalSeconds()
        )

        let req2 = URLRequest(url: efetchURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let (data2, resp2) = try await URLSession.shared.data(for: req2)
        let st2 = (resp2 as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(st2) else {
            let sn = String(data: data2.prefix(600), encoding: .utf8) ?? ""
            throw Inf6PubMedClientError.badStatus(st2, sn)
        }

        let parser = Inf6PubMedEFetchParser()
        return try parser.parse(data: data2)
    }

    private static func linkedPMIDs(pmid: String, linkName: String, identityEmail: String?) async throws -> [String] {
        let id = pmid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return [] }

        var components = URLComponents(string: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/elink.fcgi")
        var items = [
            URLQueryItem(name: "dbfrom", value: "pubmed"),
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "linkname", value: linkName),
            URLQueryItem(name: "retmode", value: "json"),
            URLQueryItem(name: "tool", value: "inf6")
        ]
        if let identityEmail {
            let email = identityEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !email.isEmpty {
                items.append(URLQueryItem(name: "email", value: email))
            }
        }
        components?.queryItems = items
        guard let url = components?.url else { throw Inf6PubMedClientError.badURL }

        await Inf6PubMedRateLimiter.shared.waitIfNeeded(
            minIntervalSeconds: Inf6PubMedRateLimiter.configuredMinIntervalSeconds()
        )

        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let snippet = String(data: data.prefix(600), encoding: .utf8) ?? ""
            throw Inf6PubMedClientError.badStatus(status, snippet)
        }

        struct ELinkRoot: Decodable {
            struct LinkSet: Decodable {
                struct LinkSetDB: Decodable {
                    let linkname: String?
                    let links: [String]?
                }
                let linksetdbs: [LinkSetDB]?
            }
            let linksets: [LinkSet]
        }
        let root = try JSONDecoder().decode(ELinkRoot.self, from: data)
        var out: [String] = []
        for set in root.linksets {
            for db in set.linksetdbs ?? [] where db.linkname == linkName {
                for linked in db.links ?? [] where !out.contains(linked) {
                    out.append(linked)
                }
            }
        }
        return out
    }
}

final class Inf6PubMedEFetchParser: NSObject, XMLParserDelegate {

    private enum _Ctx {
        case none
        case pmid
        case articleTitle
        case abstractText
        case year
    }

    private var ctx: _Ctx = .none

    private var currentPMID: String = ""
    private var currentTitle: String = ""
    private var currentAbstractParts: [String] = []
    private var currentYear: String = ""

    private var inPubmedArticle: Bool = false
    private var results: [Inf6PaperSearchResult] = []

    private var parseErrorMessage: String? = nil

    func parse(data: Data) throws -> [Inf6PaperSearchResult] {
        results = []
        parseErrorMessage = nil

        let xml = XMLParser(data: data)
        xml.delegate = self
        let ok = xml.parse()
        if !ok {
            let msg = parseErrorMessage ?? xml.parserError?.localizedDescription ?? "unknown"
            throw Inf6PubMedClientError.parseFailed(msg)
        }
        return results
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        parseErrorMessage = parseError.localizedDescription
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String : String] = [:]) {

        if elementName == "PubmedArticle" {
            inPubmedArticle = true
            currentPMID = ""
            currentTitle = ""
            currentAbstractParts = []
            currentYear = ""
            ctx = .none
            return
        }

        guard inPubmedArticle else { return }

        switch elementName {
        case "PMID":
            ctx = .pmid
        case "ArticleTitle":
            ctx = .articleTitle
        case "AbstractText":
            ctx = .abstractText
        case "Year":
            if currentYear.isEmpty {
                ctx = .year
            } else {
                ctx = .none
            }
        default:
            ctx = .none
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inPubmedArticle else { return }

        switch ctx {
        case .pmid:
            currentPMID += string
        case .articleTitle:
            currentTitle += string
        case .abstractText:
            // AbstractText can appear multiple times; accumulate and join later.
            currentAbstractParts.append(string)
        case .year:
            currentYear += string
        case .none:
            break
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {

        if elementName == "PubmedArticle" {
            inPubmedArticle = false

            let pmid = currentPMID.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = currentTitle
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let absJoined = currentAbstractParts
                .joined(separator: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let landing: URL? = pmid.isEmpty ? nil : URL(string: "https://pubmed.ncbi.nlm.nih.gov/\(pmid)/")
            let publishedAt: Date? = {
                let y = currentYear.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let year = Int(y), year > 0 else { return nil }
                return Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: 1, day: 1))
            }()

            let item = Inf6PaperSearchResult(
                id: pmid.isEmpty ? UUID().uuidString : pmid,
                title: title.isEmpty ? "(no title)" : title,
                subtitle: absJoined,
                landingURL: landing,
                pdfURL: nil,
                abstractText: absJoined,
                publishedAt: publishedAt,
                updatedAt: nil
            )
            results.append(item)

            ctx = .none
            return
        }

        // Reset context when leaving known tags.
        if elementName == "PMID" || elementName == "ArticleTitle" || elementName == "AbstractText" || elementName == "Year" {
            ctx = .none
        }
    }
}
