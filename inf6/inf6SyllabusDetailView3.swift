//
//  inf6SyllabusDetailView3.swift
//  inf6
//
//  Created by decopin on 2026/02/22.
//


import Foundation
import Dispatch
import SwiftUI
import CoreText


#if canImport(PDFKit)
import PDFKit
#endif

#if !canImport(UIKit)
#error("inf6CreatePDF.swift requires UIKit (iOS / iPadOS / Designed for iPad on Mac only). Remove this file from non-UIKit targets.")
#endif


import UIKit
import WebKit
import ObjectiveC


#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

import Security

extension Inf6SyllabusDetailView {

    
    
    // MARK: - E資格: open external paper search (web) (4/5)
    
    @MainActor
    func openPaperSearchForEshikaku(selectedItems: [Inf6SyllabusOutlineItem]) {
        do {
            let res = try _eshikakuUsingSourceOrThrow()
            if let note = res.note, !note.isEmpty {
                self.explanationPDFStatus = self.explanationPDFStatus.isEmpty ? note : (note + "\n" + self.explanationPDFStatus)
            }
        } catch {
            // Surface the failure explicitly; do not silently fall back.
            explanationPDFStatus = Inf6Lang.text(
                "論文検索を開始できません: \(error.localizedDescription)",
                "Cannot start paper search: \(error.localizedDescription)"
            )
            return
        }
        
        let query = _buildEshikakuPaperQueryLocal(selectedItems: selectedItems)
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            explanationPDFStatus = Inf6Lang.text(
                "検索クエリを生成できませんでした（選択項目のタイトル／要約が空です）。",
                "Could not build a search query (selected item titles/summaries are empty)."
            )
            return
        }
        
        let enabled = _enabledPaperSources()
        guard !enabled.isEmpty else {
            explanationPDFStatus = Inf6Lang.text(
                "論文検索の収集サイトが無効です。『収集サイト』で1つ以上を有効にしてください。",
                "All paper sources are disabled. In Sources, enable at least one."
            )
            return
        }
        
        // Open tabs in the Sources settings order (Inf6PaperSourceID.allCases).
        let enabledSet = Set(enabled)
        let orderedSources = Inf6PaperSourceID.allCases.filter { enabledSet.contains($0) }
        
        var opened: [String] = []
        var unsupported: [String] = []
        
        for src in orderedSources {
            if let u = _paperSearchURL(for: src, query: query) {
                UIApplication.shared.open(u)
                opened.append(src.displayName)
            } else {
                unsupported.append(src.displayName)
            }
        }
        
        if !unsupported.isEmpty {
            let names = unsupported.joined(separator: ", ")
            let msg = Inf6Lang.text(
                "未対応の収集元が含まれています: \(names)",
                "Some enabled sources are not supported here: \(names)"
            )
            self.explanationPDFStatus = self.explanationPDFStatus.isEmpty ? msg : (self.explanationPDFStatus + "\n" + msg)
        }
        
        if opened.isEmpty {
            explanationPDFStatus = Inf6Lang.text(
                "有効な収集サイトはありますが、検索URLを生成できませんでした。",
                "Enabled sources exist, but no search URL could be built."
            )
            return
        }
    }
    
    @MainActor
    func openPaperSearchForSelectedOutlineItemsEshikaku() {
        startEshikakuPaperSearchUI()
    }
    
    // MARK: - E資格: paper search helpers (arXiv API) (4/5)
    
    /// Build a stable search query for E資格 paper search from selected syllabus items.
    /// Includes nearest parent headings as lightweight context.
    func _buildEshikakuPaperQueryLocal(selectedItems: [Inf6SyllabusOutlineItem]) -> String {
        guard !selectedItems.isEmpty else { return "" }
        
        let selectedKeySet = Set(selectedItems.map { $0.key })
        
        // Collect nearest parents (up to 2 levels) for each selected item.
        var contextKeys = Set<String>()
        for it in selectedItems {
            guard let idx = syllabusOutlineItems.firstIndex(where: { $0.key == it.key }) else { continue }
            let myDepth = syllabusOutlineItems[idx].effectiveDepth
            guard myDepth > 0 else { continue }
            
            var foundDepths = Set<Int>()
            var j = idx - 1
            while j >= 0 {
                let cand = syllabusOutlineItems[j]
                let d = cand.effectiveDepth
                
                if d < myDepth {
                    // We want the nearest parent per depth (up to 2 levels: e.g., depth 1 and 0).
                    // If we already captured a heading at this depth, skip siblings and keep scanning
                    // until we reach a higher-level parent (e.g., depth 0).
                    if foundDepths.contains(d) {
                        if d == 0 { break }
                        j -= 1
                        continue
                    }
                    
                    if contextKeys.insert(cand.key).inserted {
                        foundDepths.insert(d)
                    }
                    
                    if d == 0 || foundDepths.count >= 2 { break }
                }
                
                j -= 1
            }
        }
        
        // Preserve the on-screen order for query stability.
        let ordered = syllabusOutlineItems.filter { selectedKeySet.contains($0.key) || contextKeys.contains($0.key) }
        
        func normalizeForQuery(_ s: String) -> String {
            var t = s
            t = t.replacingOccurrences(of: "/", with: " ")
            t = t.replacingOccurrences(of: "・", with: " ")
            t = t.replacingOccurrences(of: "、", with: " ")
            t = t.replacingOccurrences(of: "（", with: " ")
            t = t.replacingOccurrences(of: "）", with: " ")
            t = t.replacingOccurrences(of: "(", with: " ")
            t = t.replacingOccurrences(of: ")", with: " ")
            t = t.replacingOccurrences(of: "：", with: " ")
            t = t.replacingOccurrences(of: ":", with: " ")
            t = t.replacingOccurrences(of: "\n", with: " ")
            t = t.replacingOccurrences(of: "\r", with: " ")
            t = t
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        var terms: [String] = []
        terms.reserveCapacity(ordered.count * 2 + 16)
        
        func appendTerm(_ raw: String) {
            let t = normalizeForQuery(raw)
            guard !t.isEmpty else { return }
            terms.append(t)
        }
        
        for it in ordered {
            //let isSelected = selectedKeySet.contains(it.key)
            
            // “チェックした語”は選択項目のタイトルのみ。
            // “文脈”は親見出し（contextKeys）としてタイトルのみを追加。
            func pickOneTitle(_ item: Inf6SyllabusOutlineItem) -> String {
                let cands: [String] = [item.titleJa, item.titleEn, item.title]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                return cands.first ?? ""
            }
            
            let title = pickOneTitle(it)
            if !title.isEmpty {
                // 選択項目・文脈ともに「タイトル1つ」だけを語として採用する。
                // （要約は混入させない）
                appendTerm(title)
            }
            
            // NOTE:
            // summary は「チェック以外の語」が混ざる原因になるため、ここでは一切追加しない。
        }
        
        // De-duplicate terms (case-insensitive), keep order.
        var seen = Set<String>()
        terms = terms.filter { t in
            let k = t.localizedLowercase
            if seen.contains(k) { return false }
            seen.insert(k)
            return true
        }
        
        var query = terms.joined(separator: " ")
        query = query
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        
        if query.count > 240 { query = String(query.prefix(240)) }
        return query
    }
    @MainActor
    func startEshikakuPaperSearchUI() {
        let keys = selectedOutlineKeys
        guard !keys.isEmpty else {
            eshikakuPaperSearchStatus = Inf6Lang.text("シラバス項目を選択してください。", "Select syllabus items.")
            return
        }
        let selected = syllabusOutlineItems.filter { keys.contains($0.key) }
        guard !selected.isEmpty else {
            eshikakuPaperSearchStatus = Inf6Lang.text("選択された項目が見つかりません。", "Selected items not found.")
            return
        }
        
        do {
            let res = try _eshikakuUsingSourceOrThrow()
            if let note = res.note, !note.isEmpty {
                eshikakuPaperSearchStatus = note
            }
        } catch {
            eshikakuPaperSearchStatus = Inf6Lang.text(
                "論文検索を開始できません: \(error.localizedDescription)",
                "Cannot start paper search: \(error.localizedDescription)"
            )
            return
        }
        
        // In-app candidate list supports providers with direct API fetch.
        // If no such provider is enabled, still support paper search by opening external web search tabs.
        let enabled = _enabledPaperSources()
        guard !enabled.isEmpty else {
            eshikakuPaperSearchStatus = Inf6Lang.text(
                "論文検索の収集サイトが無効です。『収集サイト』で1つ以上を有効にしてください。",
                "All paper sources are disabled. In Sources, enable at least one."
            )
            return
        }
        let supportedInApp: Set<Inf6PaperSourceID> = [.arxiv, .pubmed]
        if enabled.allSatisfy({ !supportedInApp.contains($0) }) {
            eshikakuPaperQuery = _buildEshikakuPaperQueryLocal(selectedItems: selected)
            
            // Open tabs in the Sources settings order (Inf6PaperSourceID.allCases).
            let enabledSet = Set(enabled)
            let orderedSources = Inf6PaperSourceID.allCases.filter { enabledSet.contains($0) }
            
            var opened: [String] = []
            var unsupported: [String] = []
            
            for src in orderedSources {
                if let u = _paperSearchURL(for: src, query: eshikakuPaperQuery) {
                    UIApplication.shared.open(u)
                    opened.append(src.displayName)
                } else {
                    unsupported.append(src.displayName)
                }
            }
            
            if opened.isEmpty {
                eshikakuPaperSearchStatus = Inf6Lang.text(
                    "有効な収集サイトはありますが、検索URLを生成できませんでした。",
                    "Enabled sources exist, but no search URL could be built."
                )
            } else {
                var msg = Inf6Lang.text(
                    "候補一覧（アプリ内表示）は現在 arXiv / PubMed API に対応です。外部検索（タブを開く）で有効な収集サイト検索を実行しました: \(opened.joined(separator: ", "))",
                    "The in-app candidate list currently supports arXiv / PubMed APIs. Opened external search tabs for enabled sources: \(opened.joined(separator: ", "))"
                )
                if !unsupported.isEmpty {
                    let names = unsupported.joined(separator: ", ")
                    msg += "\n" + Inf6Lang.text(
                        "未対応の収集元が含まれています: \(names)",
                        "Some enabled sources are not supported here: \(names)"
                    )
                }
                eshikakuPaperSearchStatus = msg
            }
            return
        }
        
        eshikakuPaperQuery = _buildEshikakuPaperQueryLocal(selectedItems: selected)
        eshikakuPaperCandidates = []
        selectedEshikakuPaperIDs = []
        generatedEshikakuPapersYAML = ""

        Task { await runEshikakuPaperSearch(query: eshikakuPaperQuery) }
    }
    
    @MainActor
    func toggleEshikakuPaperSelection(_ id: String) {
        if selectedEshikakuPaperIDs.contains(id) {
            selectedEshikakuPaperIDs.remove(id)
        } else {
            selectedEshikakuPaperIDs.insert(id)
        }
    }
    
@MainActor
func runEshikakuPaperSearch(query: String) async {
    let raw0 = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw0.isEmpty else {
        eshikakuPaperCandidates = []
        selectedEshikakuPaperIDs = []
        eshikakuPaperSearchStatus = Inf6Lang.text(
            "検索クエリが空です。シラバス項目を選択してください。",
            "Search query is empty. Select syllabus items."
        )
        return
    }

    guard !isSearchingEshikakuPapers else {
        eshikakuPaperSearchStatus = Inf6Lang.text(
            "すでに検索中です。完了までお待ちください。",
            "A search is already running. Please wait until it finishes."
        )
        return
    }

    isSearchingEshikakuPapers = true
    defer {
        // 例外や早期 return でも、検索中フラグが残存しないよう必ず解除する。
        self.isSearchingEshikakuPapers = false
    }

    // IMPORTANT: E資格の検索は「チェックした語 + 文脈（親見出し）」から毎回再構築する。
    // TextField の手入力値や過去の翻訳結果が混入しても、選択状態が唯一の正とする。
    let selectedKeys = selectedOutlineKeys
    let selectedItems = syllabusOutlineItems.filter { selectedKeys.contains($0.key) }
    let raw = _buildEshikakuPaperQueryLocal(selectedItems: selectedItems)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !raw.isEmpty else {
        eshikakuPaperCandidates = []
        selectedEshikakuPaperIDs = []
        eshikakuPaperSearchStatus = Inf6Lang.text(
            "検索クエリを生成できませんでした（選択項目が空です）。",
            "Could not build a search query (no selected items)."
        )
        isSearchingEshikakuPapers = false
        return
    }

    // Keep UI field in sync with the actual pre-translation query.
    eshikakuPaperQuery = raw

    // Translate each search term with the iOS system translation service before
    // calling external paper APIs. Semantic paper selection remains local/API work.
    let q: String
    do {
        eshikakuPaperSearchStatus = Inf6Lang.text("検索クエリを英語へ変換中…", "Translating query to English…")
        let srcTerms = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !srcTerms.isEmpty else {
            throw NSError(domain: "Inf6OpenAI", code: 5, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text("検索語が空です。", "Source terms are empty.")
            ])
        }
        var parts: [String] = []
        parts.reserveCapacity(srcTerms.count)
        for term in srcTerms {
            try Task.checkCancellation()
            let translated = try await Inf6SystemTranslationCoordinator.shared.translate(
                term,
                source: "ja",
                target: "en"
            )
            let value = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw NSError(domain: "Inf6SystemTranslation", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: Inf6Lang.text("英語変換結果が空です。", "Translated query is empty.")
                ])
            }
            parts.append(value)
        }
        let joined = parts.joined(separator: " ")
        let finalQ = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalQ.isEmpty else {
            throw NSError(domain: "Inf6OpenAI", code: 5, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text("英語変換結果が空です。", "Translated query is empty.")
            ])
        }

        q = finalQ
        eshikakuPaperQuery = q
    } catch {
        eshikakuPaperCandidates = []
        selectedEshikakuPaperIDs = []
        eshikakuPaperSearchStatus = Inf6Lang.text(
            "検索クエリの英語変換に失敗: \(error.localizedDescription)",
            "Failed to translate query to English: \(error.localizedDescription)"
        )
        isSearchingEshikakuPapers = false
        return
    }

    do {
        let res = try _eshikakuUsingSourceOrThrow()
        let fetchingMsg: String = {
            switch res.using {
            case .arxiv:
                return Inf6Lang.text("arXiv API で論文候補を取得中…", "Fetching candidates from arXiv API…")
            case .pubmed:
                return Inf6Lang.text("PubMed API で論文候補を取得中…", "Fetching candidates from PubMed API…")
            default:
                return Inf6Lang.text("論文候補を取得中…", "Fetching candidates…")
            }
        }()

        if let note = res.note, !note.isEmpty {
            eshikakuPaperSearchStatus = note + "\n" + fetchingMsg
        } else {
            eshikakuPaperSearchStatus = fetchingMsg
        }

        switch res.using {
        case .arxiv:
            do {
                let results = try await fetchArxivCandidates(query: q, maxResults: 30)

                await MainActor.run {
                    self.eshikakuPaperCandidates = results
                    self.selectedEshikakuPaperIDs = []
                    if results.isEmpty {
                        self.eshikakuPaperSearchStatus = Inf6Lang.text("候補が見つかりませんでした。", "No candidates found.")
                    } else {
                        self.eshikakuPaperSearchStatus = ""
                    }
                    self.isSearchingEshikakuPapers = false
                }
            } catch {
                await MainActor.run {
                    self.eshikakuPaperCandidates = []
                    self.selectedEshikakuPaperIDs = []
                    self.eshikakuPaperSearchStatus = Inf6Lang.text(
                        "論文候補の取得に失敗: \(error.localizedDescription)",
                        "Failed to fetch candidates: \(error.localizedDescription)"
                    )
                    self.isSearchingEshikakuPapers = false
                }
            }

        case .pubmed:
            do {
                let results = try await fetchPubMedCandidates(query: q, maxResults: 30)

                await MainActor.run {
                    self.eshikakuPaperCandidates = results
                    self.selectedEshikakuPaperIDs = []
                    if results.isEmpty {
                        self.eshikakuPaperSearchStatus = Inf6Lang.text("候補が見つかりませんでした。", "No candidates found.")
                    } else {
                        self.eshikakuPaperSearchStatus = ""
                    }
                    self.isSearchingEshikakuPapers = false
                }
            } catch {
                await MainActor.run {
                    self.eshikakuPaperCandidates = []
                    self.selectedEshikakuPaperIDs = []
                    self.eshikakuPaperSearchStatus = Inf6Lang.text(
                        "論文候補の取得に失敗: \(error.localizedDescription)",
                        "Failed to fetch candidates: \(error.localizedDescription)"
                    )
                    self.isSearchingEshikakuPapers = false
                }
            }

        default:
            // Explicitly surface unsupported provider for in-app candidate list.
            let enabled = _enabledPaperSources()
            // Open tabs in the Sources settings order (Inf6PaperSourceID.allCases).
            let enabledSet = Set(enabled)
            let orderedSources = Inf6PaperSourceID.allCases.filter { enabledSet.contains($0) }

            var opened: [String] = []
            var unsupported: [String] = []

            for src in orderedSources {
                if let u = _paperSearchURL(for: src, query: q) {
                    let ok: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                        UIApplication.shared.open(u, options: [:]) { success in
                            cont.resume(returning: success)
                        }
                    }
                    if ok {
                        opened.append(src.displayName)
                    } else {
                        unsupported.append(src.displayName)
                    }
                } else {
                    unsupported.append(src.displayName)
                }
            }

            if opened.isEmpty {
                eshikakuPaperSearchStatus = Inf6Lang.text(
                    "有効な収集サイトはありますが、検索URLを生成できませんでした。",
                    "Enabled sources exist, but no search URL could be built."
                )
            } else {
                var msg = Inf6Lang.text(
                    "候補一覧（アプリ内表示）は現在 arXiv / PubMed API に対応です。外部検索（タブを開く）で有効な収集サイト検索を実行しました: \(opened.joined(separator: ", "))",
                    "The in-app candidate list currently supports arXiv / PubMed APIs. Opened external search tabs for enabled sources: \(opened.joined(separator: ", "))"
                )
                if !unsupported.isEmpty {
                    let names = unsupported.joined(separator: ", ")
                    msg += "\n" + Inf6Lang.text(
                        "未対応の収集元が含まれています: \(names)",
                        "Some enabled sources are not supported here: \(names)"
                    )
                }
                eshikakuPaperSearchStatus = msg
            }

            isSearchingEshikakuPapers = false
        }
    } catch {
        eshikakuPaperSearchStatus = Inf6Lang.text(
            "論文検索を開始できません: \(error.localizedDescription)",
            "Cannot start paper search: \(error.localizedDescription)"
        )
        isSearchingEshikakuPapers = false
        return
    }
}


@MainActor
func buildEshikakuPapersYAMLOrThrow(from selected: [Inf6PaperCandidate]) throws -> String {
    guard !selected.isEmpty else { return "" }

    let res = try _eshikakuUsingSourceOrThrow()
    let provider = res.using

    let idKey: String
    switch provider {
    case .arxiv:
        idKey = "arxiv_id"
    case .pubmed:
        idKey = "pmid"
    default:
        throw NSError(domain: "Inf6PaperSearch", code: 1002, userInfo: [
            NSLocalizedDescriptionKey: Inf6Lang.text(
                "YAML生成は現在 arXiv / PubMed のみ対応です（要求: \(provider.displayName)）。",
                "YAML generation currently supports arXiv / PubMed only (requested: \(provider.displayName))."
            )
        ])
    }

    func yq(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(t)\""
    }

    var lines: [String] = []
    lines.append("papers:")

    for p in selected {
        let title = p.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { continue }

        lines.append("  - title: \(yq(title))")
        lines.append("    provider: \(provider.rawValue)")
        lines.append("    \(idKey): \(yq(p.id))")
        lines.append("    tags: [eshikaku]")
    }

    return lines.joined(separator: "\n") + "\n"
}

func openURLExternal(_ url: URL) {
    UIApplication.shared.open(url)
}

func copyTextToClipboard(_ text: String) {
    UIPasteboard.general.string = text
}

// MARK: - E資格: PDF download (user-chosen destination via Files)

enum _Inf6EshikakuExportError: LocalizedError {
    case noPresenter
    case presentingBlocked
    case fileMissing(String)
    case presentFailed
    case cancelled

    // Preselected destination folder (G検定-style)
    case destinationNotConfigured
    case destinationAccessDenied
    case destinationNotFolder
    case destinationWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .noPresenter:
            return Inf6Lang.text("ダウンロード画面を表示できません。", "Cannot present download UI.")
        case .presentingBlocked:
            return Inf6Lang.text(
                "すでに別の画面が表示中のため、保存先選択を開けません。",
                "Another modal is already being presented; cannot open the save destination picker."
            )
        case .fileMissing(let name):
            return Inf6Lang.text(
                "書き出し対象ファイルが見つかりません: \(name)",
                "Export file is missing: \(name)"
            )
        case .presentFailed:
            return Inf6Lang.text(
                "保存先選択（Files）の画面提示に失敗しました。",
                "Failed to present the save destination picker (Files)."
            )
        case .cancelled:
            return Inf6Lang.text("ユーザーがダウンロードをキャンセルしました。", "User cancelled download.")

        case .destinationNotConfigured:
            return Inf6Lang.text(
                "保存先フォルダが未設定です。先に『保存先フォルダを選択…』を実行してください。",
                "Destination folder is not configured. Run 'Choose destination folder…' first."
            )
        case .destinationAccessDenied:
            return Inf6Lang.text(
                "保存先フォルダへアクセスできません（権限がありません）。もう一度フォルダを選択してください。",
                "Cannot access the destination folder (permission denied). Choose the folder again."
            )
        case .destinationNotFolder:
            return Inf6Lang.text(
                "選択された保存先はフォルダではありません。フォルダを選択してください。",
                "The selected destination is not a folder. Please choose a folder."
            )
        case .destinationWriteFailed(let name):
            return Inf6Lang.text(
                "保存先フォルダへの書き込みに失敗しました: \(name)",
                "Failed to write into the destination folder: \(name)"
            )
        }
    }
}

static var _inf6DocPickerAssocKey: UInt8 = 0

// MARK: - E資格: pre-selected export folder (G検定-style)

private static let _eshikakuExportFolderBookmarkKey = "inf6_eshikaku_export_folder_bookmark"

@MainActor
func _eshikakuExportFolderURLOrThrow() throws -> URL {
    let ud = UserDefaults.standard
    guard let data = ud.data(forKey: Self._eshikakuExportFolderBookmarkKey), !data.isEmpty else {
        throw _Inf6EshikakuExportError.destinationNotConfigured
    }

    var stale = false
    let resolved: URL
    let resolveOptions: URL.BookmarkResolutionOptions = []

    do {
        resolved = try URL(
            resolvingBookmarkData: data,
            options: resolveOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    } catch {
        throw _Inf6EshikakuExportError.destinationAccessDenied
    }

    if stale {
        do {
            let createOptions: URL.BookmarkCreationOptions = []

            let refreshed = try resolved.bookmarkData(
                options: createOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            ud.set(refreshed, forKey: Self._eshikakuExportFolderBookmarkKey)
        } catch {
            throw _Inf6EshikakuExportError.destinationAccessDenied
        }
    }

    #if os(iOS)
    let didAccess = resolved.startAccessingSecurityScopedResource()
    defer { if didAccess { resolved.stopAccessingSecurityScopedResource() } }
    if !didAccess {
        throw _Inf6EshikakuExportError.destinationAccessDenied
    }

    let values = try resolved.resourceValues(forKeys: [.isDirectoryKey])
    guard values.isDirectory == true else {
        throw _Inf6EshikakuExportError.destinationNotFolder
    }
    #else
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir) {
        guard isDir.boolValue else { throw _Inf6EshikakuExportError.destinationNotFolder }
    } else {
        throw _Inf6EshikakuExportError.destinationAccessDenied
    }
    #endif

    return resolved
}

@MainActor
func _persistEshikakuExportFolderBookmarkOrThrow(_ folderURL: URL) throws {
    let createOptions: URL.BookmarkCreationOptions = []

    let data = try folderURL.bookmarkData(
        options: createOptions,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
    )
    UserDefaults.standard.set(data, forKey: Self._eshikakuExportFolderBookmarkKey)
}

@MainActor
func _chooseEshikakuExportFolderOrThrow() async throws {
    #if !canImport(UniformTypeIdentifiers)
    throw NSError(domain: "Inf6FS", code: 901, userInfo: [
        NSLocalizedDescriptionKey: "UniformTypeIdentifiers is unavailable on this target"
    ])
    #else
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        guard let presenter = _topMostViewControllerOrNil() else {
            cont.resume(throwing: _Inf6EshikakuExportError.noPresenter)
            return
        }

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)

        // Match G検定 UX: if a destination folder is already configured, open the picker there.
        if let data = UserDefaults.standard.data(forKey: Self._eshikakuExportFolderBookmarkKey), !data.isEmpty {
            var stale = false
            let resolveOptions: URL.BookmarkResolutionOptions = []

            if let resolved = try? URL(
                resolvingBookmarkData: data,
                options: resolveOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                picker.directoryURL = resolved
            }
        }

        var resumed = false
        func resumeOnce(_ result: Result<Void, Error>) {
            guard !resumed else { return }
            resumed = true
            switch result {
            case .success: cont.resume()
            case .failure(let e): cont.resume(throwing: e)
            }
        }

        let coordinator = _Inf6DocPickerCoordinator(
            onPick: { urls in
                guard let first = urls.first else {
                    resumeOnce(.failure(_Inf6EshikakuExportError.cancelled))
                    return
                }

                let didAccess = first.startAccessingSecurityScopedResource()
                defer { if didAccess { first.stopAccessingSecurityScopedResource() } }
                if !didAccess {
                    resumeOnce(.failure(_Inf6EshikakuExportError.destinationAccessDenied))
                    return
                }

                do {
                    let values = try first.resourceValues(forKeys: [.isDirectoryKey])
                    guard values.isDirectory == true else {
                        resumeOnce(.failure(_Inf6EshikakuExportError.destinationNotFolder))
                        return
                    }

                    try _persistEshikakuExportFolderBookmarkOrThrow(first)
                    resumeOnce(.success(()))
                } catch {
                    resumeOnce(.failure(_Inf6EshikakuExportError.destinationAccessDenied))
                }
            },
            onCancel: {
                resumeOnce(.failure(_Inf6EshikakuExportError.cancelled))
            }
        )

        picker.delegate = coordinator
        objc_setAssociatedObject(picker, &Self._inf6DocPickerAssocKey, coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        picker.modalPresentationStyle = .automatic
        presenter.present(picker, animated: true)
    }
    #endif
}

@MainActor
func _exportEshikakuPDFsToPreselectedFolderOrThrow(_ fileURLs: [URL]) async throws {
    guard !fileURLs.isEmpty else { return }

    let folder = try _eshikakuExportFolderURLOrThrow()

    #if os(iOS)
    let didAccess = folder.startAccessingSecurityScopedResource()
    defer { if didAccess { folder.stopAccessingSecurityScopedResource() } }
    if !didAccess {
        throw _Inf6EshikakuExportError.destinationAccessDenied
    }
    #endif

    for src in fileURLs {
        guard src.isFileURL else {
            throw NSError(domain: "Inf6FS", code: 31, userInfo: [
                NSLocalizedDescriptionKey: "Export requires a file URL: \(src.absoluteString)"
            ])
        }
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw _Inf6EshikakuExportError.fileMissing(src.lastPathComponent)
        }

        let dest = folder.appendingPathComponent(src.lastPathComponent)

        // No overwrite: surface as a failure.
        if FileManager.default.fileExists(atPath: dest.path) {
            throw NSError(domain: "Inf6Eshikaku", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Duplicate filename exists in destination: \(dest.lastPathComponent)"
            ])
        }

        do {
            try FileManager.default.copyItem(at: src, to: dest)
        } catch {
            throw _Inf6EshikakuExportError.destinationWriteFailed(dest.lastPathComponent)
        }

        // Verify the destination actually materialized.
        // On iOS / Files providers (and iOS App on Mac), a successful copy call can still result in
        // a delayed materialization; we must not claim success unless it becomes visible.
        var verified = false
        let deadlineNs: UInt64 = DispatchTime.now().uptimeNanoseconds + 3_000_000_000 // ~3s
        while true {
            if FileManager.default.fileExists(atPath: dest.path) {
                verified = true
                break
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadlineNs {
                break
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        if !verified {
            throw _Inf6EshikakuExportError.destinationWriteFailed(dest.lastPathComponent)
        }
    }
}

final class _Inf6DocPickerCoordinator: NSObject, UIDocumentPickerDelegate {
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
        self.onPick = onPick
        self.onCancel = onCancel
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        onPick(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        onCancel()
    }
}

@MainActor
func _topMostViewControllerOrNil() -> UIViewController? {
    // Prefer scene-based resolution.
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }

    // Prefer an active scene; fall back to any available scene.
    let orderedScenes: [UIWindowScene] = {
        if let s = scenes.first(where: { $0.activationState == .foregroundActive }) {
            return [s] + scenes.filter { $0 != s }
        }
        if let s = scenes.first(where: { $0.activationState == .foregroundInactive }) {
            return [s] + scenes.filter { $0 != s }
        }
        return scenes
    }()

    func topPresented(from root: UIViewController) -> UIViewController {
        var vc: UIViewController = root
        while let p = vc.presentedViewController, !p.isBeingDismissed {
            vc = p
        }
        return vc
    }

    func bestPresenter(from root: UIViewController) -> UIViewController {
        let top = topPresented(from: root)
        // If the top is a container, present from the visible/selected child.
        if let nav = top as? UINavigationController {
            if let vis = nav.visibleViewController {
                return bestPresenter(from: vis)
            }
            return nav
        }
        if let tab = top as? UITabBarController {
            if let sel = tab.selectedViewController {
                return bestPresenter(from: sel)
            }
            return tab
        }
        if let split = top as? UISplitViewController {
            if let last = split.viewControllers.last {
                return bestPresenter(from: last)
            }
            return split
        }
        return top
    }

    // Scene windows only (no UIApplication.shared.windows fallback)
    for scene in orderedScenes {
        let windows = scene.windows
        guard !windows.isEmpty else { continue }

        // Consider only visible normal-level windows.
        let visible = windows.filter { !$0.isHidden && $0.alpha > 0.0 && $0.windowLevel == .normal }
        let candidates = visible.isEmpty ? windows : visible

        // Prefer key window first.
        var orderedWindows: [UIWindow] = []
        if let key = candidates.first(where: { $0.isKeyWindow }) {
            orderedWindows.append(key)
        }
        orderedWindows.append(contentsOf: candidates.filter { !$0.isKeyWindow })

        for win in orderedWindows {
            guard let root = win.rootViewController else { continue }

            // Only present from a VC that is actually in a window hierarchy.
            // If we present from a detached VC, UIKit will deny the presentation and nothing will appear.
            if root.viewIfLoaded?.window == nil {
                // Force a load attempt once; if it still has no window, skip.
                _ = root.view
                if root.viewIfLoaded?.window == nil { continue }
            }

            let presenter = bestPresenter(from: root)
            // The top presenter must also be attached.
            if presenter.viewIfLoaded?.window == nil {
                _ = presenter.view
                if presenter.viewIfLoaded?.window == nil { continue }
            }

            return presenter
        }
    }

    return nil
}

@MainActor
func _exportFilesViaDocumentPickerOrThrow(_ fileURLs: [URL]) async throws {
    guard !fileURLs.isEmpty else { return }

    // Hard check: exporting requires existing local files.
    for u in fileURLs {
        guard u.isFileURL else {
            throw NSError(domain: "Inf6FS", code: 31, userInfo: [
                NSLocalizedDescriptionKey: "Export requires a file URL: \(u.absoluteString)"
            ])
        }
        guard FileManager.default.fileExists(atPath: u.path) else {
            throw _Inf6EshikakuExportError.fileMissing(u.lastPathComponent)
        }
    }

    // Resolve a stable presenter. If presentation is currently blocked by a dismissing modal,
    // re-resolve the presenter after yielding to avoid capturing a stale presented VC.
    await Task.yield()

    guard var presenter = _topMostViewControllerOrNil() else {
        throw _Inf6EshikakuExportError.noPresenter
    }

    // If the resolved presenter is detached from any window hierarchy, UIKit will refuse to present.
    // Re-resolve once after yielding; if still detached, fail explicitly.
    if presenter.viewIfLoaded?.window == nil {
        _ = presenter.view
    }
    if presenter.viewIfLoaded?.window == nil {
        await Task.yield()
        guard let refreshed = _topMostViewControllerOrNil() else {
            throw _Inf6EshikakuExportError.noPresenter
        }
        presenter = refreshed
        _ = presenter.view
        if presenter.viewIfLoaded?.window == nil {
            throw _Inf6EshikakuExportError.presentFailed
        }
    }

    // If another modal is already presented (common with SwiftUI sheets), resolve the top-most presenter
    // again and try to present from there. Do not hard-block here; UIKit will deny invalid presentations.
    // Any denial must surface via the explicit presentFailed path below.
    if presenter.presentedViewController != nil {
        await Task.yield()
        guard let refreshed = _topMostViewControllerOrNil() else {
            throw _Inf6EshikakuExportError.noPresenter
        }
        presenter = refreshed
    }

    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        let picker = UIDocumentPickerViewController(forExporting: fileURLs, asCopy: true)

        // Ensure we always resume exactly once; never hang silently.
        var resumed = false
        func resumeOnce(_ result: Result<Void, Error>) {
            guard !resumed else { return }
            resumed = true
            switch result {
            case .success:
                cont.resume()
            case .failure(let e):
                cont.resume(throwing: e)
            }
        }

        let coordinator = _Inf6DocPickerCoordinator(
            onPick: { _ in resumeOnce(.success(())) },
            onCancel: { resumeOnce(.failure(_Inf6EshikakuExportError.cancelled)) }
        )

        picker.delegate = coordinator
        // Retain coordinator (delegate is weak)
        objc_setAssociatedObject(picker, &Self._inf6DocPickerAssocKey, coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        picker.modalPresentationStyle = .automatic

        Task { @MainActor in
            // Present.
            // Do NOT fail-fast here: on iPad, the system may complete the presentation after a noticeable delay.
            // We fail only if the picker still has no presenting controller/window after a bounded wait.
            var didCallPresentCompletion = false

            await Task.yield()

            presenter.present(picker, animated: true) {
                didCallPresentCompletion = true
            }

            // Bounded wait for the picker to actually attach.
            // IMPORTANT: on iPad / Files, the UI can appear several seconds later due to system file-provider discovery.
            // We must not claim failure early; fail only after a longer, bounded wait.
            let deadlineNs: UInt64 = DispatchTime.now().uptimeNanoseconds + 12_000_000_000 // ~12s

            while true {
                // If the user already finished/cancelled, stop waiting.
                // (The delegate will resume the continuation.)
                if resumed { return }

                let attached = (presenter.presentedViewController === picker)
                    || (picker.presentingViewController != nil)
                    || (picker.viewIfLoaded?.window != nil)
                    || didCallPresentCompletion

                if attached {
                    return
                }

                let now = DispatchTime.now().uptimeNanoseconds
                if now >= deadlineNs {
                    resumeOnce(.failure(_Inf6EshikakuExportError.presentFailed))
                    return
                }

                // Small yield to let UIKit/SwiftUI finish transitions.
                await Task.yield()
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }
}

func _inf6EnsureTempDirOrThrow(_ name: String) throws -> URL {
    let base = FileManager.default.temporaryDirectory
    let dir = base.appendingPathComponent(name, isDirectory: true)
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) {
        guard isDir.boolValue else {
            throw NSError(domain: "Inf6FS", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "Expected a directory but found a file at: \(dir.path)"
            ])
        }
        return dir
    }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    return dir
}

func _downloadPDFsToTemporaryOrThrow(_ urls: [URL]) async throws -> [URL] {
    guard !urls.isEmpty else { return [] }

    let outDir = try _inf6EnsureTempDirOrThrow("inf6_eshikaku_export")

    var out: [URL] = []
    out.reserveCapacity(urls.count)

    for url in urls {
        // Only gate when accessing arXiv hosts
        let host = (url.host ?? "").lowercased()
        if host.hasSuffix("arxiv.org") {
            try await Self._inf6ArxivRateGate.waitIfNeeded()
        }

        let (tmp, resp) = try await URLSession.shared.download(from: url)

        guard let http = resp as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: tmp)
            throw NSError(domain: "Inf6AutoPapers", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Non-HTTP response"
            ])
        }

        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 429, host.hasSuffix("arxiv.org") {
                let ra = http.value(forHTTPHeaderField: "Retry-After")
                if let sec = Self._parseRetryAfterSeconds(ra) {
                    await Self._inf6ArxivRateGate.noteRateLimited(retryAfterSeconds: sec)
                    try? FileManager.default.removeItem(at: tmp)
                    throw NSError(domain: "Inf6AutoPapers", code: 429, userInfo: [
                        NSLocalizedDescriptionKey: "HTTP 429 (Retry-After: \(sec)s)"
                    ])
                } else {
                    try? FileManager.default.removeItem(at: tmp)
                    throw NSError(domain: "Inf6AutoPapers", code: 429, userInfo: [
                        NSLocalizedDescriptionKey: "HTTP 429 (Retry-After missing or unparseable)"
                    ])
                }
            }

            try? FileManager.default.removeItem(at: tmp)
            throw NSError(domain: "Inf6AutoPapers", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"
            ])
        }

        let magicOK: Bool
        do {
            magicOK = try _isPDFMagicHeader(at: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw NSError(domain: "Inf6AutoPapers", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Failed to read downloaded file header: \(error.localizedDescription)"
            ])
        }

        if !magicOK {
            let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? http.mimeType ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let msg = ct.isEmpty
                ? "Downloaded content is not a PDF"
                : "Downloaded content is not a PDF (Content-Type: \(ct))"
            try? FileManager.default.removeItem(at: tmp)
            throw NSError(domain: "Inf6AutoPapers", code: 415, userInfo: [
                NSLocalizedDescriptionKey: msg
            ])
        }

        var rawName: String = ""
        if let cd = http.value(forHTTPHeaderField: "Content-Disposition"),
           let hinted = _extractFilenameFromContentDisposition(cd) {
            rawName = hinted
        }
        if rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rawName = (url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
        }
        rawName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawName.isEmpty {
            try? FileManager.default.removeItem(at: tmp)
            throw NSError(domain: "Inf6AutoPapers", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not determine a filename for the downloaded PDF"
            ])
        }

        let base = sanitizeFileName(rawName)
        var dest = outDir.appendingPathComponent(base)
        if dest.pathExtension.lowercased() != "pdf" {
            dest = dest.deletingPathExtension().appendingPathExtension("pdf")
        }

        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }

        try FileManager.default.copyItem(at: tmp, to: dest)
        try? FileManager.default.removeItem(at: tmp)

        out.append(dest)
    }

    return out
}

// MARK: - iOS keyboard dismiss (explicit; no silent fallback)
#if os(iOS)
@MainActor
func _dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
#endif

@MainActor
func downloadSingleEshikakuPaperPDF(_ p: Inf6PaperCandidate) async {
    guard let u = p.pdfURL else {
        eshikakuPaperSearchStatus = Inf6Lang.text(
            "この候補はPDF取得に未対応です（PDF URL がありません）。",
            "This candidate does not support PDF download (missing PDF URL)."
        )
        return
    }

    eshikakuPaperSearchStatus = Inf6Lang.text("PDFをダウンロードします…", "Downloading PDF…")

    do {
        let tmpURLs = try await _downloadPDFsToTemporaryOrThrow([u])
        guard let first = tmpURLs.first else {
            throw NSError(domain: "Inf6Eshikaku", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Downloaded temp file is missing"
            ])
        }

        let desiredRaw = p.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !desiredRaw.isEmpty else {
            eshikakuPaperSearchStatus = Inf6Lang.text(
                "保存名を決定できません（候補タイトルが空です）。",
                "Cannot determine a save name (candidate title is empty)."
            )
            return
        }

        let dir = first.deletingLastPathComponent()
        let base = sanitizeFileName(desiredRaw)
        guard !base.isEmpty else {
            throw NSError(domain: "Inf6Eshikaku", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Cannot determine a safe filename from the selected title"
            ])
        }

        let target = dir.appendingPathComponent(base).appendingPathExtension("pdf")

        if FileManager.default.fileExists(atPath: target.path) {
            throw NSError(domain: "Inf6Eshikaku", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Duplicate filename exists: \(target.lastPathComponent)"
            ])
        }

        if target.path != first.path {
            try FileManager.default.moveItem(at: first, to: target)
        }

        try await _exportEshikakuPDFsToPreselectedFolderOrThrow([target])

        try? FileManager.default.removeItem(at: target)
        eshikakuPaperSearchStatus = Inf6Lang.text("PDFをダウンロードしました。", "Downloaded PDF.")
    } catch {
        eshikakuPaperSearchStatus = Inf6Lang.text(
            "PDFダウンロードに失敗: \(error.localizedDescription)",
            "Failed to download PDF: \(error.localizedDescription)"
        )
    }
}

@MainActor
func downloadSelectedEshikakuPaperPDFs() async {
    let selected = eshikakuPaperCandidates.filter { selectedEshikakuPaperIDs.contains($0.id) }
    guard !selected.isEmpty else { return }

    eshikakuPaperSearchStatus = Inf6Lang.text("PDFをダウンロードします…", "Downloading PDFs…")

    let selectedWithPDF: [(url: URL, title: String)] = selected.compactMap { p in
        guard let u = p.pdfURL else { return nil }
        return (u, p.title)
    }
    let pdfURLs: [URL] = selectedWithPDF.map { $0.url }
    let missingCount = selected.count - selectedWithPDF.count

    if pdfURLs.isEmpty {
        eshikakuPaperSearchStatus = Inf6Lang.text(
            "選択した候補にPDF URLがありません。",
            "Selected candidates have no PDF URLs."
        )
        return
    }

    do {
        let tmpURLs = try await _downloadPDFsToTemporaryOrThrow(pdfURLs)
        guard tmpURLs.count == selectedWithPDF.count else {
            throw NSError(domain: "Inf6Eshikaku", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Downloaded PDF count mismatch"
            ])
        }

        var outURLs: [URL] = []
        outURLs.reserveCapacity(tmpURLs.count)

        var used = Set<String>()

        for (tmp, meta) in zip(tmpURLs, selectedWithPDF) {
            let desiredRaw = meta.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !desiredRaw.isEmpty else {
                throw NSError(domain: "Inf6Eshikaku", code: 7, userInfo: [
                    NSLocalizedDescriptionKey: "Cannot determine a save name (candidate title is empty)"
                ])
            }

            let base0 = sanitizeFileName(desiredRaw)
            guard !base0.isEmpty else {
                throw NSError(domain: "Inf6Eshikaku", code: 8, userInfo: [
                    NSLocalizedDescriptionKey: "Cannot determine a safe filename from the selected title"
                ])
            }

            let dir = tmp.deletingLastPathComponent()

            var base = base0
            var candidate = dir.appendingPathComponent(base).appendingPathExtension("pdf")

            var n = 2
            while used.contains(candidate.lastPathComponent) || FileManager.default.fileExists(atPath: candidate.path) {
                base = "\(base0)_\(n)"
                candidate = dir.appendingPathComponent(base).appendingPathExtension("pdf")
                n += 1
            }

            used.insert(candidate.lastPathComponent)

            if candidate.path != tmp.path {
                try FileManager.default.moveItem(at: tmp, to: candidate)
                outURLs.append(candidate)
            } else {
                outURLs.append(tmp)
            }
        }

        if outURLs.isEmpty {
            throw NSError(domain: "Inf6Eshikaku", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No PDFs were downloaded"
            ])
        }

        try await _exportEshikakuPDFsToPreselectedFolderOrThrow(outURLs)

        for u in outURLs { try? FileManager.default.removeItem(at: u) }

        if missingCount > 0 {
            eshikakuPaperSearchStatus = Inf6Lang.text(
                "PDFをダウンロードしました（対象外: \(missingCount) 件）。",
                "Downloaded PDFs (missing PDF URL: \(missingCount))."
            )
        } else {
            eshikakuPaperSearchStatus = Inf6Lang.text("PDFをダウンロードしました。", "Downloaded PDFs.")
        }
    } catch {
        eshikakuPaperSearchStatus = Inf6Lang.text(
            "PDFダウンロードに失敗: \(error.localizedDescription)",
            "Failed to download PDFs: \(error.localizedDescription)"
        )
    }
}

// MARK: - arXiv rate-limit gate (no guessed interval; obey Retry-After only)

actor _Inf6ArxivRateGate {
    private var nextAllowedNs: UInt64 = 0

    func waitIfNeeded() async throws {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < nextAllowedNs else { return }
        try await Task.sleep(nanoseconds: nextAllowedNs - now)
    }

    func noteRateLimited(retryAfterSeconds: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        let target = now &+ (retryAfterSeconds * 1_000_000_000)
        if target > nextAllowedNs {
            nextAllowedNs = target
        }
    }
}

// Single shared gate for this view (file-local behavior)
nonisolated static let _inf6ArxivRateGate = _Inf6ArxivRateGate()

// Parse Retry-After: either delta-seconds or HTTP-date (RFC1123)
nonisolated static func _parseRetryAfterSeconds(_ value: String?) -> UInt64? {
    guard let raw0 = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw0.isEmpty else { return nil }
    let raw = raw0

    // 1) delta-seconds
    if let n = UInt64(raw), n > 0 {
        return n
    }

    // 2) HTTP-date (RFC1123)
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone(secondsFromGMT: 0)
    df.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"

    if let d = df.date(from: raw) {
        let now = Date()
        let sec = UInt64(max(0, d.timeIntervalSince(now)))
        return sec > 0 ? sec : nil
    }

    return nil
}

func fetchArxivCandidates(query: String, maxResults: Int) async throws -> [Inf6PaperCandidate] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return [] }

    #if DEBUG
    print("[Inf6Eshikaku] runEshikakuPaperSearch query=\(q)")
    #endif

    // arXiv API is ATOM XML.
    // Use export.arxiv.org (recommended for automated requests).
    var components = URLComponents(string: "https://export.arxiv.org/api/query")
    components?.queryItems = [
        URLQueryItem(name: "search_query", value: "(cat:cs.* OR cat:stat.*) AND all:" + q),
        URLQueryItem(name: "start", value: "0"),
        URLQueryItem(name: "max_results", value: String(max(1, min(50, maxResults))))
    ]

    guard let url = components?.url else { return [] }

    #if DEBUG
    print("[Inf6Arxiv] requestURL=\(url.absoluteString)")
    let qi = (components?.queryItems ?? [])
        .map { "\($0.name)=\($0.value ?? "")" }
        .joined(separator: "&")
    print("[Inf6Arxiv] queryItems=\(qi)")
    #endif

    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.timeoutInterval = 25

    // Gate: wait only if we were previously rate-limited (Retry-After)
    try await Self._inf6ArxivRateGate.waitIfNeeded()

    let (data, resp) = try await URLSession.shared.data(for: req)

    if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
        if http.statusCode == 429 {
            let ra = http.value(forHTTPHeaderField: "Retry-After")
            if let sec = Self._parseRetryAfterSeconds(ra) {
                await Self._inf6ArxivRateGate.noteRateLimited(retryAfterSeconds: sec)
                throw NSError(domain: "Inf6Arxiv", code: 429, userInfo: [
                    NSLocalizedDescriptionKey: "HTTP 429 (Retry-After: \(sec)s)"
                ])
            } else {
                // No guessing: surface as-is
                throw NSError(domain: "Inf6Arxiv", code: 429, userInfo: [
                    NSLocalizedDescriptionKey: "HTTP 429 (Retry-After missing or unparseable)"
                ])
            }
        }

        throw NSError(domain: "Inf6Arxiv", code: http.statusCode, userInfo: [
            NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"
        ])
    }

    let parser = _ArxivFeedParser()
    let xml = XMLParser(data: data)
    xml.delegate = parser
    let ok = xml.parse()
    if !ok {
        throw xml.parserError ?? NSError(domain: "Inf6Arxiv", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "XML parse failed"
        ])
    }

    #if DEBUG
    print("[Inf6Arxiv] parsedEntries=\(parser.items.count)")
    #endif

    // Post-process: stabilize id, de-dup.
    var out: [Inf6PaperCandidate] = []
    out.reserveCapacity(parser.items.count)
    var seen = Set<String>()

    for it in parser.items {
        let stableID = normalizeArxivID(it.arxivAbsID)
        guard !stableID.isEmpty else { continue }
        guard seen.insert(stableID).inserted else { continue }

        out.append(.init(
            id: stableID,
            title: it.title,
            authors: it.authors,
            summary: it.summary,
            absURL: it.absURL,
            pdfURL: it.pdfURL
        ))
    }
    return out
}

// MARK: - E資格: paper search helpers (PubMed E-utilities)

struct _PubMedESearchResponse: Decodable {
    struct _Result: Decodable {
        let idlist: [String]?
    }
    let esearchresult: _Result
}

struct _PubMedESummaryResponse: Decodable {
    struct _Author: Decodable {
        let name: String?
    }

    struct _Item: Decodable {
        let uid: String?
        let title: String?
        let authors: [_Author]?
    }

    struct _Result: Decodable {
        let uids: [String]?
        // Dynamic keys: PMID -> _Item
        let itemsByUID: [String: _Item]

        struct _DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: _DynamicKey.self)

            if let k = _DynamicKey(stringValue: "uids") {
                self.uids = try c.decodeIfPresent([String].self, forKey: k)
            } else {
                self.uids = nil
            }

            var dict: [String: _Item] = [:]
            for key in c.allKeys {
                if key.stringValue == "uids" { continue }
                if let item = try? c.decode(_Item.self, forKey: key) {
                    dict[key.stringValue] = item
                }
            }
            self.itemsByUID = dict
        }
    }

    let result: _Result
}

func fetchPubMedCandidates(query: String, maxResults: Int) async throws -> [Inf6PaperCandidate] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return [] }

    let capped = max(1, min(50, maxResults))

    // 1) ESearch: resolve PMIDs
    var search = URLComponents(string: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi")
    search?.queryItems = [
        URLQueryItem(name: "db", value: "pubmed"),
        URLQueryItem(name: "term", value: q),
        URLQueryItem(name: "retmode", value: "json"),
        URLQueryItem(name: "retmax", value: String(capped)),
        URLQueryItem(name: "sort", value: "relevance")
    ]

    guard let searchURL = search?.url else {
        throw NSError(domain: "Inf6PubMed", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Failed to build PubMed ESearch URL"
        ])
    }

    var req1 = URLRequest(url: searchURL)
    req1.httpMethod = "GET"
    req1.timeoutInterval = 25

    let (d1, r1) = try await URLSession.shared.data(for: req1)
    if let http = r1 as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
        throw NSError(domain: "Inf6PubMed", code: http.statusCode, userInfo: [
            NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"
        ])
    }

    let sres = try JSONDecoder().decode(_PubMedESearchResponse.self, from: d1)
    let pmids = (sres.esearchresult.idlist ?? []).filter { !$0.isEmpty }
    guard !pmids.isEmpty else { return [] }

    // 2) ESummary: fetch titles/authors
    var summary = URLComponents(string: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi")
    summary?.queryItems = [
        URLQueryItem(name: "db", value: "pubmed"),
        URLQueryItem(name: "id", value: pmids.joined(separator: ",")),
        URLQueryItem(name: "retmode", value: "json")
    ]

    guard let summaryURL = summary?.url else {
        throw NSError(domain: "Inf6PubMed", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Failed to build PubMed ESummary URL"
        ])
    }

    var req2 = URLRequest(url: summaryURL)
    req2.httpMethod = "GET"
    req2.timeoutInterval = 25

    let (d2, r2) = try await URLSession.shared.data(for: req2)
    if let http = r2 as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
        throw NSError(domain: "Inf6PubMed", code: http.statusCode, userInfo: [
            NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"
        ])
    }

    let eres = try JSONDecoder().decode(_PubMedESummaryResponse.self, from: d2)

    // Preserve PubMed relevance order (pmids order).
    var out: [Inf6PaperCandidate] = []
    out.reserveCapacity(pmids.count)

    for pmid in pmids {
        guard let item = eres.result.itemsByUID[pmid] else { continue }

        let title = (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { continue }

        let authors: [String] = (item.authors ?? [])
            .compactMap { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let absURL = URL(string: "https://pubmed.ncbi.nlm.nih.gov/\(pmid)/")

        // NOTE: PubMed ESummary does not provide a stable direct-PDF URL.
        // We keep pdfURL=nil so the app will surface that PDF fetch is unavailable for most PubMed entries.
        out.append(.init(
            id: pmid,
            title: title,
            authors: authors,
            summary: "",
            absURL: absURL,
            pdfURL: nil
        ))
    }

    return out
}

func normalizeArxivID(_ absID: String) -> String {
    // Examples:
    //   http://arxiv.org/abs/1706.03762v7
    //   https://arxiv.org/abs/1506.01497
    let s = absID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return "" }

    // If a full URL, keep the tail.
    let tail: String = {
        if let u = URL(string: s), u.scheme != nil {
            return u.lastPathComponent
        }
        return s
    }()

    // Drop version suffix: vN
    if let r = tail.range(of: "v", options: .backwards),
       r.lowerBound < tail.endIndex {
        let suffix = String(tail[r.lowerBound...])
        if suffix.count >= 2, suffix.dropFirst().allSatisfy({ $0.isNumber }) {
            return String(tail[..<r.lowerBound])
        }
    }
    return tail
}

// MARK: - E資格: 解説PDF 保存先フォルダ UI（G検定と同じ行）

private var eshikakuExplanationPDFFolderRow: some View {
    VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 10) {
            Text(Inf6Lang.text("解説PDF保存先", "Explanation PDF destination"))
                .font(.headline)
            Spacer()
            Button {
                Task { @MainActor in
                    do {
                        try await _chooseEshikakuExportFolderOrThrow()
                        eshikakuPaperSearchStatus = Inf6Lang.text(
                            "保存先フォルダを設定しました。",
                            "Destination folder has been set."
                        )
                    } catch {
                        let msg = Inf6Lang.text(
                            "保存先フォルダの選択に失敗: \(error.localizedDescription)",
                            "Failed to choose destination folder: \(error.localizedDescription)"
                        )
                        eshikakuPaperSearchStatus = msg
                        explanationPDFErrorAlertMessage = msg
                        showExplanationPDFErrorAlert = true
                    }
                }
            } label: {
                Text(Inf6Lang.text("選択…", "Choose…"))
            }
            .buttonStyle(.bordered)
        }

        if let u = try? _eshikakuExportFolderURLOrThrow() {
            Text(u.path)
                .font(.caption)
                .foregroundStyle(Color.blue)
                .lineLimit(2)
                .truncationMode(.middle)
        } else {
            Text(Inf6Lang.text(
                "解説PDF保存先が未指定です。「選択…」でフォルダを指定してください。",
                "Explanation PDF destination is not set. Choose a folder with “Choose…”."
            ))
            .font(.caption)
            .foregroundStyle(Color.blue)
        }

        if !eshikakuPaperSearchStatus.isEmpty {
            Text(eshikakuPaperSearchStatus)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

@ViewBuilder
private var eshikakuExplanationBlock: some View {
    if isEshikakuCourse {
        // 保存先フォルダ行（UIとして見える場所に出す）
        eshikakuExplanationPDFFolderRow
    }
}

// MARK: - E資格: Paper search UI (sheet/fullscreen) (4/5)
@ViewBuilder
var eshikakuPaperSearchSheet: some View {
    #if os(iOS)
    NavigationStack {
        eshikakuPaperSearchSheetContent
            .navigationTitle(Inf6Lang.text("論文サーチ", "Paper Search"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(Inf6Lang.text("閉じる", "Close")) {
                        showEshikakuPaperSearchSheet = false
                        showEshikakuPaperSearchFullScreen = false
                    }
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(Inf6Lang.text("完了", "Done")) {
                        _dismissKeyboard()
                    }
                }
            }
    }
    #else
    #endif
}

@ViewBuilder
var eshikakuPaperSearchSheetContent: some View {
    VStack(alignment: .leading, spacing: 10) {
        if !eshikakuPaperSearchStatus.isEmpty {
            Text(eshikakuPaperSearchStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        HStack(spacing: 10) {
            TextField(Inf6Lang.text("検索クエリ", "Search query"), text: $eshikakuPaperQuery)
                .textFieldStyle(.roundedBorder)

            let canShowFetchPDFButton = true

            Spacer(minLength: 0)

            // All actions are routed through a menu.
            Menu {

                Button(Inf6Lang.text("関連ページを開く", "Open relation")) {
                    let selected = eshikakuPaperCandidates.filter { selectedEshikakuPaperIDs.contains($0.id) }
                    guard let first = selected.first, let u = first.absURL else { return }
                    openURLExternal(u)
                }
                .disabled(selectedEshikakuPaperIDs.isEmpty)

                if canShowFetchPDFButton {
                    Button(Inf6Lang.text("PDFをダウンロード…", "Download PDFs…")) {
                        Task { await downloadSelectedEshikakuPaperPDFs() }
                    }
                    .disabled(selectedEshikakuPaperIDs.isEmpty)
                } else {
                    Text(Inf6Lang.text(
                        "PDFの自動取得は、直接PDF URLを持つ候補のみ対応です。",
                        "Automatic PDF download is only available for candidates with a direct PDF URL."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } label: {
                if isSearchingEshikakuPapers {
                    HStack(spacing: 8) {
                        ProgressView().tint(.pink).scaleEffect(1.25)
                        Text(Inf6Lang.text("ダウンロード…", "Downloading…"))
                    }
                } else {
                    Label(Inf6Lang.text("ダウンロード", "Download"), systemImage: "ellipsis.circle")
                }
            }
            .buttonStyle(.borderedProminent)
        }

        Divider()

        if eshikakuPaperCandidates.isEmpty {
            Spacer(minLength: 0)
            Text(Inf6Lang.text("候補がありません。シラバス項目を選んでから検索してください。", "No candidates yet. Select syllabus items and search."))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        } else {
            List {
                ForEach(eshikakuPaperCandidates) { p in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 10) {
                            Button {
                                toggleEshikakuPaperSelection(p.id)
                            } label: {
                                Image(systemName: selectedEshikakuPaperIDs.contains(p.id) ? "checkmark.square.fill" : "square")
                            }
                            .buttonStyle(.plain)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.title)
                                    .font(.headline)
                                    .fixedSize(horizontal: false, vertical: true)

                                if !p.authors.isEmpty {
                                    Text(p.authors.prefix(6).joined(separator: ", ") + (p.authors.count > 6 ? " …" : ""))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                if !p.summary.isEmpty {
                                    Text(p.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(5)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                            }

                            Spacer(minLength: 0)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

        }
    }

    // (onAppear removed)
    .padding(.top, 8)
}

// MARK: - Open generated explanation PDF
@MainActor
func openGeneratedExplanationPDF() {
    guard let url = generatedExplanationPDFURL else {
        explanationPDFStatus = Inf6Lang.text(
            "解説PDFがまだ生成されていません。",
            "Explanation PDF has not been generated yet."
        )
        return
    }

    // Hard checks: never fail silently.
    if url.isFileURL {
        guard FileManager.default.fileExists(atPath: url.path) else {
            explanationPDFStatus = Inf6Lang.text(
                "解説PDFが見つかりません（ファイルが存在しません）。",
                "Explanation PDF was not found (file does not exist)."
            )
            return
        }
    }

    UIApplication.shared.open(url, options: [:]) { success in
        if !success {
            DispatchQueue.main.async {
                self.explanationPDFStatus = Inf6Lang.text(
                    "解説PDFを開けませんでした（システムが拒否しました）。",
                    "Failed to open explanation PDF (system denied the request)."
                )
            }
        }
    }
}
var canGenerateExplanationPDF: Bool {
    let hasSelection = !selectedOutlineKeys.isEmpty
    if isEshikakuCourse {
        return hasSelection
    }
    // Microsoft Learn: シラバス項目の選択は不要。APIキーがあれば即時生成可能。
    if isMicrosoftLearnKnowledgeCourse {
        return true
    }
    // G検定: シラバス項目（タイトル/要約）そのものが入力になるため、PDF全文テキストの有無で生成可否を硬く制限しない。
    // 必要情報が不足している場合は、生成処理側で明示的に失敗として表面化させる。
    return isGkenteiCourse && hasSelection
}

// MARK: - PDF download & parsing pipeline (5/5)
// Split-target file: Inf6SyllabusDetailView+SyllabusPDFPipeline.swift

func _firstBytes(of fileURL: URL, count: Int) throws -> Data {
    let fh = try FileHandle(forReadingFrom: fileURL)
    let d = try fh.read(upToCount: max(0, count)) ?? Data()
    try fh.close()
    return d
}

func _isPDFMagicHeader(at fileURL: URL) throws -> Bool {
    // PDF files start with "%PDF-".
    let d = try _firstBytes(of: fileURL, count: 5)
    guard d.count >= 5 else { return false }
    if let s = String(data: d, encoding: .ascii) {
        return s == "%PDF-"
    }
    return false
}

func _extractFilenameFromContentDisposition(_ cd: String) -> String? {
    // Very small parser for: filename="..." or filename*=UTF-8''...
    // We only use it as a hint; final decision is sanitized.
    let parts = cd.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

    // Prefer RFC5987 form (filename*=UTF-8''...)
    if let p = parts.first(where: { $0.lowercased().hasPrefix("filename*=") }) {
        var v = String(p.dropFirst("filename*=".count))
        v = v.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip optional quotes
        if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
            v = String(v.dropFirst().dropLast())
        }
        // Expect: UTF-8''percent-encoded
        if let r = v.range(of: "''") {
            let encPart = String(v[r.upperBound...])
            if let decoded = encPart.removingPercentEncoding, !decoded.isEmpty {
                return decoded
            }
        }

    }

    if let p = parts.first(where: { $0.lowercased().hasPrefix("filename=") }) {
        var v = String(p.dropFirst("filename=".count))
        v = v.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
            v = String(v.dropFirst().dropLast())
        }
        return v.isEmpty ? nil : v
    }

    return nil
}

func _responseHintsPDF(_ http: HTTPURLResponse) -> Bool {
    let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? http.mimeType ?? "").lowercased()
    if ct.contains("application/pdf") { return true }
    if ct.contains("application/x-pdf") { return true }
    if ct.contains("application/acrobat") { return true }

    // Some servers provide PDF as octet-stream; accept only if magic header also matches.
    if ct.contains("application/octet-stream") || ct.contains("binary/octet-stream") {
        return true
    }

    let cd = (http.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
    if cd.contains(".pdf") { return true }

    return false
}

func downloadToAppSupport(_ url: URL) async throws -> URL {
    // Only gate when accessing arXiv hosts
    let host = (url.host ?? "").lowercased()
    if host.hasSuffix("arxiv.org") {
        try await Self._inf6ArxivRateGate.waitIfNeeded()
    }

    let (tmp, resp) = try await URLSession.shared.download(from: url)

    guard let http = resp as? HTTPURLResponse else {
        try? FileManager.default.removeItem(at: tmp)
        throw NSError(domain: "Inf6AutoPapers", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Non-HTTP response"
        ])
    }

    guard (200...299).contains(http.statusCode) else {
        if http.statusCode == 429, host.hasSuffix("arxiv.org") {
            let ra = http.value(forHTTPHeaderField: "Retry-After")
            if let sec = Self._parseRetryAfterSeconds(ra) {
                await Self._inf6ArxivRateGate.noteRateLimited(retryAfterSeconds: sec)
                try? FileManager.default.removeItem(at: tmp)
                throw NSError(domain: "Inf6AutoPapers", code: 429, userInfo: [
                    NSLocalizedDescriptionKey: "HTTP 429 (Retry-After: \(sec)s)"
                ])
            } else {
                try? FileManager.default.removeItem(at: tmp)
                throw NSError(domain: "Inf6AutoPapers", code: 429, userInfo: [
                    NSLocalizedDescriptionKey: "HTTP 429 (Retry-After missing or unparseable)"
                ])
            }
        }

        try? FileManager.default.removeItem(at: tmp)
        throw NSError(domain: "Inf6AutoPapers", code: http.statusCode, userInfo: [
            NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"
        ])
    }

    // Hard safety: never cache a non-PDF as ".pdf".
    // We validate by magic header first; Content-Type is unreliable.
    let magicOK: Bool
    do {
        magicOK = try _isPDFMagicHeader(at: tmp)
    } catch {
        try? FileManager.default.removeItem(at: tmp)
        throw NSError(domain: "Inf6AutoPapers", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Failed to read downloaded file header: \(error.localizedDescription)"
        ])
    }

    if !magicOK {
        let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? http.mimeType ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let msg = ct.isEmpty
            ? "Downloaded content is not a PDF"
            : "Downloaded content is not a PDF (Content-Type: \(ct))"
        try? FileManager.default.removeItem(at: tmp)
        throw NSError(domain: "Inf6AutoPapers", code: 415, userInfo: [
            NSLocalizedDescriptionKey: msg
        ])
    }

    // Secondary hint check: keep logging-friendly info in DEBUG only.
    #if DEBUG
    if !_responseHintsPDF(http) {
        let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? http.mimeType ?? "").lowercased()
        print("[Inf6AutoPapers] downloadToAppSupport: PDF magic ok but response headers look odd ct=\(ct) url=\(url.absoluteString)")
    }
    #endif

    let dir = try syllabusPDFCacheDirectoryURL()

    // Determine output name:
    // 1) Content-Disposition filename
    // 2) URL lastPathComponent
    var rawName: String = ""
    if let cd = http.value(forHTTPHeaderField: "Content-Disposition"),
       let hinted = _extractFilenameFromContentDisposition(cd) {
        rawName = hinted
    }
    if rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        rawName = (url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
    }
    rawName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    if rawName.isEmpty {
        try? FileManager.default.removeItem(at: tmp)
        throw NSError(domain: "Inf6AutoPapers", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Could not determine a filename for the downloaded PDF"
        ])
    }

    // If the server provided an HTML-ish name (no extension), enforce .pdf.
    let base = sanitizeFileName(rawName)
    var dest = dir.appendingPathComponent(base)
    if dest.pathExtension.lowercased() != "pdf" {
        // Remove any existing extension and add .pdf
        dest = dest.deletingPathExtension().appendingPathExtension("pdf")
    }

    // Name-stable: do not add extra prefixes. Replace existing file if any.
    if FileManager.default.fileExists(atPath: dest.path) {
        try FileManager.default.removeItem(at: dest)
    }

    // Copy into iCloud Documents (tmp is in app container; move can fail across volumes/providers).
    try FileManager.default.copyItem(at: tmp, to: dest)
    try? FileManager.default.removeItem(at: tmp)

    return dest
}

// --- Stage ①: PDF candidates -> local cache -> items ---

@MainActor
func prepareSyllabusPDFs(from urls: [URL]) {
    #if canImport(PDFKit)
    guard !isPreparingSyllabusPDFs else { return }
    guard !urls.isEmpty else {
        syllabusPDFStatus = Inf6Lang.text("PDF候補URLが空です。", "No PDF candidate URLs.")
        return
    }

    isPreparingSyllabusPDFs = true
    syllabusPDFStatus = ""
    syllabusPDFItems = []
    selectedSyllabusPDFID = nil

    Task {
        var items: [Inf6SyllabusPDFItem] = []
        var seen = Set<String>()

        // Load cache and OpenAI key before loop
        var titleCache: [String: String] = [:]
        do {
            titleCache = try loadPDFTitleCache()
        } catch {
            await MainActor.run {
                self.syllabusPDFStatus = Inf6Lang.text(
                    "PDFタイトルキャッシュの読み込みに失敗: \(error.localizedDescription)",
                    "Failed to load PDF title cache: \(error.localizedDescription)"
                )
            }
            titleCache = [:]
        }

        var apiKey: String = ""
        var apiKeyNote: String? = nil
        do {
            apiKey = try loadOpenAIAPIKeyOrThrowForRequests()
        } catch {
            apiKey = ""
            apiKeyNote = Inf6Lang.text(
                "OpenAI APIキーが未設定のため、PDFタイトル推定（GPT）はスキップします。",
                "OpenAI API key is unavailable; skipping GPT title inference."
            )
        }

        if let note = apiKeyNote, !note.isEmpty {
            await MainActor.run {
                if self.syllabusPDFStatus.isEmpty {
                    self.syllabusPDFStatus = note
                }
            }
        }

        // Always clear the spinner even if something hangs/throws/cancels
        defer {
            Task { @MainActor in
                if items.isEmpty {
                    self.syllabusPDFStatus = Inf6Lang.text(
                        "PDFを解析できませんでした。",
                        "No PDFs could be parsed."
                    )
                } else {
                    // Success: hide noisy progress messages.
                    if self.syllabusPDFStatus.isEmpty {
                        self.syllabusPDFStatus = ""
                    }
                }
                self.isPreparingSyllabusPDFs = false
            }
        }

        for u in urls {
            let key = u.absoluteString
            guard seen.insert(key).inserted else { continue }

            do {
                let local = try await downloadToAppSupport(u)

                // Parse PDF synchronously (no async work inside autoreleasepool)
                struct _PDFParsed {
                    let doc: PDFDocument
                    let metaTitle: String
                    let urlFallback: String
                    let localFallback: String
                    let coverRawText: String
                    let pageCount: Int
                }

                let parsed: _PDFParsed? = autoreleasepool {
                    guard let doc = PDFDocument(url: local) else { return nil }

                    let metaTitle = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
                        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
                    let urlFallback = (u.lastPathComponent.removingPercentEncoding ?? u.lastPathComponent)
                        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    let localFallback = local.deletingPathExtension().lastPathComponent
                    let coverRawText = deriveTitleFromPDFCover(doc)
                        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    let pageCount = doc.pageCount

                    return _PDFParsed(
                        doc: doc,
                        metaTitle: metaTitle,
                        urlFallback: urlFallback,
                        localFallback: localFallback,
                        coverRawText: coverRawText,
                        pageCount: pageCount
                    )
                }

                guard let p = parsed else {
                    continue
                }

                // Determine display title (NO blocking semaphores)
                let cacheKey = pdfTitleCacheKey(sourceURL: u, localURL: local)
                var gptTitle: String? = nil

                if let cached = titleCache[cacheKey], !cached.isEmpty {
                    gptTitle = cached
                } else if !apiKey.isEmpty, !p.coverRawText.isEmpty {
                    let heuristic = (!p.metaTitle.isEmpty ? p.metaTitle : (!p.urlFallback.isEmpty ? p.urlFallback : p.localFallback))
                    if let r = await generatePDFDisplayTitleViaGPT(
                        apiKey: apiKey,
                        coverText: p.coverRawText,
                        fallbackHeuristicTitle: heuristic,
                        sourceURL: u
                    ), !r.isEmpty {
                        gptTitle = r
                        titleCache[cacheKey] = r
                        do {
                            try savePDFTitleCache(titleCache)
                        } catch {
                            await MainActor.run {
                                self.syllabusPDFStatus = Inf6Lang.text(
                                    "PDFタイトルキャッシュの保存に失敗: \(error.localizedDescription)",
                                    "Failed to save PDF title cache: \(error.localizedDescription)"
                                )
                            }
                        }
                    }
                }

                let title: String
                if let gpt = gptTitle, !gpt.isEmpty {
                    title = gpt
                } else if !p.coverRawText.isEmpty {
                    title = p.coverRawText
                } else if !p.metaTitle.isEmpty {
                    title = p.metaTitle
                } else if !p.urlFallback.isEmpty {
                    title = p.urlFallback
                } else {
                    title = p.localFallback
                }

                let item = Inf6SyllabusPDFItem(
                    sourceURL: u,
                    localURL: local,
                    title: title,
                    pageCount: p.pageCount
                )

                items.append(item)

                await MainActor.run {
                    self.syllabusPDFItems = items
                    if self.selectedSyllabusPDFID == nil {
                        let preferred: Inf6SyllabusPDFItem
                        if let examName = self._resolvedExamScheduleName(),
                           let info = Inf6SyllabusUpdateChecker.shared.examScheduleInfo(for: examName),
                           let matched = self._preferredSyllabusPDFItem(in: items, scheduleInfo: info) {
                            preferred = matched
                        } else {
                            preferred = item
                        }
                        self.selectedSyllabusPDFID = preferred.id
                        // Auto: start full-text extraction immediately (no button).
                        self.extractFullTextIfNeeded(from: preferred)
                    }
                }
            } catch {
                // Keep going; reflect the last error briefly.
                await MainActor.run {
                    self.syllabusPDFStatus = Inf6Lang.text(
                        "PDF取得に失敗: \(error.localizedDescription)",
                        "Failed to fetch PDF: \(error.localizedDescription)"
                    )
                }
            }
        }
    }
    #else
    syllabusPDFStatus = Inf6Lang.text(
        "この環境ではPDFKitが利用できません。",
        "PDFKit is not available on this platform."
    )
    #endif
}

// --- Stage ②: PDF -> full text extraction ---

@MainActor
func extractFullTextIfNeeded(from item: Inf6SyllabusPDFItem) {
    #if canImport(PDFKit)
    // Avoid duplicate extraction.
    guard !isExtractingSyllabusText else { return }
    if !syllabusExtractedText.isEmpty { return }

    isExtractingSyllabusText = true

    let localURL = item.localURL
    Task(priority: .userInitiated) {
        let extracted: String = autoreleasepool {
            guard let doc = PDFDocument(url: localURL) else { return "" }
            var parts: [String] = []
            parts.reserveCapacity(max(1, doc.pageCount))
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let s = (page.string ?? "").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                if !s.isEmpty { parts.append(s) }
            }
            return parts.joined(separator: "\n\n")
        }

        await MainActor.run {
            self.syllabusExtractedText = extracted
            self.isExtractingSyllabusText = false

            // Kick the next stage: generate outline once full-text is ready.
            let trimmed = extracted.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !trimmed.isEmpty {
                self.generateSyllabusOutlineIfNeeded(from: item, extractedText: extracted)
            } else {
                self.syllabusOutlineItems = []
                self.selectedOutlineKeys = []
                self.syllabusOutlineStatus = Inf6Lang.text(
                    "PDF全文テキストを抽出できませんでした。",
                    "Could not extract PDF full text."
                )
            }
        }
    }

    #endif
}

// --- Stage ③: selection -> reset derived state -> kick pipeline ---

@MainActor
func selectSyllabusPDFItem(_ item: Inf6SyllabusPDFItem) {
    // Update selection
    selectedSyllabusPDFID = item.id

    // Reset derived state so a different PDF can be processed
    syllabusExtractedText = ""

    syllabusOutlineItems = []
    selectedOutlineKeys = []
    syllabusOutlineStatus = ""
    explanationPDFStatus = ""
    generatedExplanationPDFURL = nil

    // Kick the next stage (idempotent for the same PDF, but will run after reset)
    extractFullTextIfNeeded(from: item)
}
}
