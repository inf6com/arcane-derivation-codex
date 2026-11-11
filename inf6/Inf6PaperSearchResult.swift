//
//  Inf6PaperSearchResult.swift
//  inf6
//
//  Shared paper-search result model.
//

import Foundation

struct Inf6PaperSearchResult: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let landingURL: URL?
    let pdfURL: URL?
    let abstractText: String
    let publishedAt: Date?
    let updatedAt: Date?

    init(
        id: String,
        title: String,
        subtitle: String,
        landingURL: URL?,
        pdfURL: URL?,
        abstractText: String = "",
        publishedAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.landingURL = landingURL
        self.pdfURL = pdfURL
        self.abstractText = abstractText
        self.publishedAt = publishedAt
        self.updatedAt = updatedAt
    }
}

enum Inf6PaperStorage {

    static func toolsPapersDirectoryURL() throws -> URL {
        try Inf6PaperSaveShared.defaultToolsPapersDirectoryURL()
    }

    static func safeFileName(title: String, fallbackID: String) throws -> String {
        try Inf6PaperSaveShared.safeFileName(title: title, fallbackID: fallbackID)
    }
}
