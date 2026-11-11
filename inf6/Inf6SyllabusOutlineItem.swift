// NOTE: Inf6PaperSearch was moved to Inf6SyllabusOutlineItem.swift (avoid duplicate type definition).
//
//  Inf6SyllabusOutlineItem.swift
//  inf6
//
//  Created by decopin on 2025/12/01.
//

import Foundation

// MARK: - Shared outline item model
public struct Inf6SyllabusOutlineItem: Identifiable, Hashable, Codable {
    let key: String

    // Legacy single-language fields (kept for backward-compatible cache decoding)
    let title: String
    let summary: String?

    // Optional bilingual fields (preferred)
    let titleJa: String?
    let titleEn: String?
    let summaryJa: String?
    let summaryEn: String?

    // Optional UI indentation depth (0 = top). Optional for backward-compatible cache decoding.
    let depth: Int?

    init(
        key: String,
        title: String,
        summary: String? = nil,
        titleJa: String? = nil,
        titleEn: String? = nil,
        summaryJa: String? = nil,
        summaryEn: String? = nil,
        depth: Int? = nil
    ) {
        self.key = key
        self.title = title
        self.summary = summary
        self.titleJa = titleJa
        self.titleEn = titleEn
        self.summaryJa = summaryJa
        self.summaryEn = summaryEn
        self.depth = depth
    }

    public var id: String { key }

    var effectiveDepth: Int { max(0, depth ?? 0) }

    /// This file should not depend on UI-layer localization helpers.
    /// Prefer the current system language (fallback to `Locale.preferredLanguages`).
    private static var prefersJapanese: Bool {
        if let first = Locale.preferredLanguages.first?.lowercased() {
            return first.hasPrefix("ja")
        }
        return Locale.current.identifier.lowercased().hasPrefix("ja")
    }

    var displayTitle: String {
        if Self.prefersJapanese {
            return (titleJa?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? titleJa! : title
        } else {
            return (titleEn?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? titleEn! : title
        }
    }

    var displaySummary: String? {
        if Self.prefersJapanese {
            let s = (summaryJa?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? summaryJa : summary
            return s
        } else {
            let s = (summaryEn?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? summaryEn : summary
            return s
        }
    }
}

// MARK: - Paper-search keyword helper
extension Inf6SyllabusOutlineItem {
    /// Builds a compact keyword string for paper search using title + optional summary.
    func inf6PaperSearchKeywords(maxSummaryChars: Int = 160) -> String {
        let t = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let s0 = (displaySummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let s = s0.isEmpty ? "" : String(s0.prefix(maxSummaryChars))

        var q = t
        if !s.isEmpty {
            q = q.isEmpty ? s : (q + " " + s)
        }
        q = q.replacingOccurrences(of: "\n", with: " ")
        while q.contains("  ") { q = q.replacingOccurrences(of: "  ", with: " ") }
        return q.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
