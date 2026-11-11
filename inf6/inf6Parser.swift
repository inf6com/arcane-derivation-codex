//
//  inf6Parser.swift
//  inf6
//
//  Created by decopin on 2025/12/02.
//

import Foundation

public final class _ArxivFeedParser: NSObject, XMLParserDelegate {
    struct _Item {
        var arxivAbsID: String = ""
        var title: String = ""
        var summary: String = ""
        var authors: [String] = []
        var absURL: URL? = nil
        var pdfURL: URL? = nil
    }

    var items: [_Item] = []

    private var inEntry: Bool = false
    private var current: _Item = .init()
    private var currentText: String = ""
    private var currentElement: String = ""
    private var inAuthor: Bool = false

    public func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        currentText = ""

        if elementName == "entry" {
            inEntry = true
            current = .init()
            return
        }

        if inEntry {
            if elementName == "author" {
                inAuthor = true
            }

            if elementName == "link" {
                // PDF link is usually: title="pdf" href="http://arxiv.org/pdf/..."
                let title = (attributeDict["title"] ?? "").lowercased()
                let type = (attributeDict["type"] ?? "").lowercased()
                let rel = (attributeDict["rel"] ?? "").lowercased()
                let href = attributeDict["href"] ?? ""
                if let u = URL(string: href), u.scheme != nil {
                    if title == "pdf" || type.contains("pdf") {
                        current.pdfURL = u
                    }
                    if rel.contains("alternate") {
                        // Keep abs URL if it looks like /abs/
                        if href.contains("/abs/") { current.absURL = u }
                    }
                }
            }
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let trimmed = currentText
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if inEntry {
            switch elementName {
            case "id":
                if !trimmed.isEmpty {
                    current.arxivAbsID = trimmed
                    if current.absURL == nil, let u = URL(string: trimmed), u.scheme != nil {
                        current.absURL = u
                    }
                }
            case "title":
                if !trimmed.isEmpty { current.title = trimmed }
            case "summary":
                if !trimmed.isEmpty { current.summary = trimmed }
            case "name":
                if inAuthor, !trimmed.isEmpty {
                    current.authors.append(trimmed)
                }
            case "author":
                inAuthor = false
            case "entry":
                inEntry = false
                // Only keep entries with a title and id
                if !current.title.isEmpty, !current.arxivAbsID.isEmpty {
                    items.append(current)
                }
            default:
                break
            }
        }

        currentText = ""
        currentElement = ""
    }
}
