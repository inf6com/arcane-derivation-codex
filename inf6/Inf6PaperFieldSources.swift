//
//  Inf6PaperFieldSources.swift
//  inf6
//
//  External field sources used by paper-search UI.
//

import Foundation

struct Inf6ArxivPubMedFieldItem: Identifiable, Hashable {
    let id: String
    let label: String
}

enum Inf6PaperSourceKind: String, CaseIterable, Identifiable {
    case arxiv
    case pubmed
    case acl
    case isca
    case openalex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arxiv: return "arXiv"
        case .pubmed: return "PubMed"
        case .acl: return "ACL Anthology"
        case .isca: return "ISCA Archive"
        case .openalex: return "OpenAlex"
        }
    }
}

/// Fetches first-level MeSH descriptors through the official MeSH SPARQL endpoint.
enum Inf6MeshTopCategoriesClient {

    static func fetchTopCategories(identity: String) async throws -> [Inf6ArxivPubMedFieldItem] {
        let email = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else {
            throw NSError(
                domain: "Inf6MeshTopCategoriesClient",
                code: -63,
                userInfo: [NSLocalizedDescriptionKey: "Identity (contact email) is empty."]
            )
        }

        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "id.nlm.nih.gov"
        comps.path = "/mesh/sparql"

        let sparql = #"""
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX meshv: <http://id.nlm.nih.gov/mesh/vocab#>

SELECT DISTINCT ?heading ?tnLabel
FROM <http://id.nlm.nih.gov/mesh>
WHERE {
  ?d a meshv:Descriptor .
  ?d meshv:treeNumber ?tn .
  ?d rdfs:label ?heading .
  ?tn rdfs:label ?tnLabel .

  FILTER(lang(?heading) = 'en')
  FILTER(regex(str(?tnLabel), "^[A-Z][0-9][0-9]$"))
}
ORDER BY ?tnLabel
"""#

        comps.queryItems = [
            URLQueryItem(name: "query", value: sparql),
            URLQueryItem(name: "year", value: "current"),
            URLQueryItem(name: "inference", value: "true"),
            URLQueryItem(name: "format", value: "JSON")
        ]

        guard let url = comps.url else {
            throw NSError(
                domain: "Inf6MeshTopCategoriesClient",
                code: -60,
                userInfo: [NSLocalizedDescriptionKey: "Invalid MeSH SPARQL URL."]
            )
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        req.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        req.setValue("inf6 (contact: \(email))", forHTTPHeaderField: "User-Agent")
        req.setValue(email, forHTTPHeaderField: "From")

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let snippet = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw NSError(
                domain: "Inf6MeshTopCategoriesClient",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "MeSH SPARQL failed (\(status)): \(snippet)"]
            )
        }

        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any],
              let results = dict["results"] as? [String: Any],
              let bindings = results["bindings"] as? [[String: Any]] else {
            throw NSError(
                domain: "Inf6MeshTopCategoriesClient",
                code: -61,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected MeSH SPARQL JSON."]
            )
        }

        var out: [Inf6ArxivPubMedFieldItem] = []
        out.reserveCapacity(32)
        var seen = Set<String>()

        for binding in bindings {
            guard let headingObj = binding["heading"] as? [String: Any],
                  let heading = (headingObj["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !heading.isEmpty else {
                continue
            }

            let treeNumber: String = {
                guard let tnObj = binding["tnLabel"] as? [String: Any],
                      let value = tnObj["value"] as? String else { return "" }
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }()

            guard seen.insert(heading).inserted else { continue }

            let display = treeNumber.isEmpty ? heading : "\(heading) (\(treeNumber))"
            out.append(Inf6ArxivPubMedFieldItem(id: heading, label: display))
        }

        if out.isEmpty {
            throw NSError(
                domain: "Inf6MeshTopCategoriesClient",
                code: -62,
                userInfo: [NSLocalizedDescriptionKey: "MeSH top categories are empty (expected first-level tree numbers like A01, C01...)."]
            )
        }

        return out.sorted(by: { $0.label < $1.label })
    }
}

enum Inf6ArxivCategoryTaxonomyClient {

    static func fetchFields() async throws -> [Inf6ArxivPubMedFieldItem] {
        let urlString = "https://arxiv.org/category_taxonomy"
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "Inf6ArxivCategoryTaxonomyClient", code: -10, userInfo: [NSLocalizedDescriptionKey: "Invalid arXiv taxonomy URL."])
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 30

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let snippet = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw NSError(domain: "Inf6ArxivCategoryTaxonomyClient", code: status, userInfo: [NSLocalizedDescriptionKey: "arXiv taxonomy fetch failed (\(status)): \(snippet)"])
        }

        guard let html = String(data: data, encoding: .utf8), !html.isEmpty else {
            throw NSError(domain: "Inf6ArxivCategoryTaxonomyClient", code: -11, userInfo: [NSLocalizedDescriptionKey: "arXiv taxonomy HTML is empty."])
        }

        let cleanedHTML = _removeHTMLBlock(tag: "script", from: html)
        let cleanedHTML2 = _removeHTMLBlock(tag: "style", from: cleanedHTML)
        let decoded = _decodeMinimalHTMLEntities(cleanedHTML2)
        let plain = _stripHTMLTagsMinimally(decoded)

        var out: [Inf6ArxivPubMedFieldItem] = []
        out.reserveCapacity(256)
        var seen = Set<String>()

        for rawLineSub in plain.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLineSub)
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\r", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if line.isEmpty { continue }

            if line.hasPrefix("#### ") {
                line = String(line.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let endIdx = line.firstIndex(where: { $0 == " " || $0 == "(" }) ?? line.endIndex
            let rawCode = String(line[..<endIdx]).trimmingCharacters(in: .whitespacesAndNewlines)

            guard _looksLikeArxivCategoryCode(rawCode) else { continue }
            guard seen.insert(rawCode).inserted else { continue }

            var label = ""
            if let lparen = line.firstIndex(of: "("), let rparen = line[lparen...].firstIndex(of: ")") {
                let inner = line[line.index(after: lparen)..<rparen]
                label = String(inner)
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "  ", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let pretty = label.isEmpty ? rawCode : "\(rawCode) (\(label))"
            out.append(Inf6ArxivPubMedFieldItem(id: rawCode, label: pretty))
        }

        if out.isEmpty {
            throw NSError(domain: "Inf6ArxivCategoryTaxonomyClient", code: -12, userInfo: [NSLocalizedDescriptionKey: "Could not parse any arXiv categories from taxonomy."])
        }

        return out.sorted(by: { $0.label < $1.label })
    }

    private static func _looksLikeArxivCategoryCode(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        guard let dot = t.firstIndex(of: ".") else { return false }
        if t[t.index(after: dot)...].contains(".") { return false }

        let lhs = t[..<dot]
        let rhs = t[t.index(after: dot)...]
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }

        func isASCIILower(_ ch: Character) -> Bool {
            guard let v = ch.unicodeScalars.first?.value, ch.unicodeScalars.count == 1 else { return false }
            return v >= 0x61 && v <= 0x7A
        }

        func isASCIIUpper(_ ch: Character) -> Bool {
            guard let v = ch.unicodeScalars.first?.value, ch.unicodeScalars.count == 1 else { return false }
            return v >= 0x41 && v <= 0x5A
        }

        func isASCIIDigit(_ ch: Character) -> Bool {
            guard let v = ch.unicodeScalars.first?.value, ch.unicodeScalars.count == 1 else { return false }
            return v >= 0x30 && v <= 0x39
        }

        let lhsOK = lhs.allSatisfy { ch in
            isASCIILower(ch) || ch == "-"
        }
        guard lhsOK else { return false }

        guard rhs.count >= 1, rhs.count <= 4 else { return false }
        return rhs.allSatisfy { ch in
            isASCIIUpper(ch) || isASCIIDigit(ch)
        }
    }

    private static func _removeHTMLBlock(tag: String, from html: String) -> String {
        let lower = html.lowercased()
        let openNeedle = "<" + tag.lowercased()
        let closeNeedle = "</" + tag.lowercased() + ">"

        var out = ""
        out.reserveCapacity(html.count)

        var i = lower.startIndex
        while let open = lower.range(of: openNeedle, range: i..<lower.endIndex) {
            out += String(html[i..<open.lowerBound])
            guard let close = lower.range(of: closeNeedle, range: open.upperBound..<lower.endIndex) else {
                return out
            }
            i = close.upperBound
        }

        out += String(html[i..<html.endIndex])
        return out
    }

    private static func _stripHTMLTagsMinimally(_ s: String) -> String {
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

    private static func _decodeMinimalHTMLEntities(_ s: String) -> String {
        s
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
