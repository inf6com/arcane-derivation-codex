//
//  Inf6ConceptPaperSearchView.swift
//  inf6
//

import SwiftUI

struct Inf6ConceptPaperSearchRequest: Hashable, Identifiable {
    let titleJa: String
    let titleEn: String
    let paperIDs: [String]

    var id: String {
        "\(titleJa)|\(titleEn)|\(paperIDs.joined(separator: ","))"
    }
}

struct Inf6ConceptPaperSearchView: View {
    let request: Inf6ConceptPaperSearchRequest
    let store: Inf6CorePaperStore
    let onOpenPaper: (String) -> Void

    @AppStorage("gen_lang") private var _genLangRaw: String = "ja"
    @AppStorage("inf6_ui_language") private var _uiLanguageRaw: String = "auto"

    private var _paperIDSet: Set<String> {
        Set(request.paperIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    private var _papers: [Inf6CorePaper] {
        let ids = _paperIDSet
        return store.papers
            .filter { ids.contains($0.id) }
            .sorted {
                if ($0.year ?? 0) != ($1.year ?? 0) {
                    return ($0.year ?? 0) > ($1.year ?? 0)
                }
                return _paperTitle($0).localizedStandardCompare(_paperTitle($1)) == .orderedAscending
            }
    }

    private var _missingPaperIDs: [String] {
        let existing = Set(store.papers.map(\.id))
        return request.paperIDs.filter { !existing.contains($0) }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(_displayText(ja: request.titleJa, en: request.titleEn))
                        .font(.title3.weight(.bold))
                    Text(_displayText(ja: "紐付け論文 \(_papers.count) 件", en: "\(_papers.count) linked papers"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            if !_missingPaperIDs.isEmpty {
                Section {
                    Text(_displayText(
                        ja: "構造データの linked_paper_ids に、論文ストアへ存在しない ID が含まれています: \(_missingPaperIDs.joined(separator: ", "))",
                        en: "linked_paper_ids contains IDs that are missing from the paper store: \(_missingPaperIDs.joined(separator: ", "))"
                    ))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
                }
            }

            Section {
                if _papers.isEmpty {
                    Text(_displayText(
                        ja: "この概念に紐付いた論文はありません。",
                        en: "No papers are linked to this concept."
                    ))
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(_papers) { paper in
                        Button {
                            onOpenPaper(paper.id)
                        } label: {
                            _ConceptPaperRow(paper: paper, title: _paperTitle(paper))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle(_displayText(ja: "論文", en: "Papers"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func _paperTitle(_ paper: Inf6CorePaper) -> String {
        Inf6Lang.text(paper.title, paper.titleEn ?? paper.title)
    }

    private func _displayText(ja: String, en: String) -> String {
        Inf6Lang.text(ja.trimmingCharacters(in: .whitespacesAndNewlines),
                      en.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private struct _ConceptPaperRow: View {
    let paper: Inf6CorePaper
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Color(uiColor: .label))
                .lineLimit(3)

            HStack(spacing: 8) {
                if let year = paper.year {
                    Text(String(year))
                }
                Text(paper.provider)
                ForEach(paper.tags.prefix(4), id: \.self) { tag in
                    Text(tag)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 6)
    }
}
