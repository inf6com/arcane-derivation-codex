//
//  Inf6ArxivPubMedToolsSection.swift
//  inf6
//

import Foundation
import SwiftUI
import PDFKit

struct Inf6ArxivPubMedToolsSection: View {
    private let _onOpenPaperChat: () -> Void

    @Environment(\.horizontalSizeClass) private var _horizontalSizeClass
    @Environment(\.openURL) private var _openURL
    @ScaledMetric(relativeTo: .title3) private var _toolsTileIconSize: CGFloat = 18
    @ScaledMetric(relativeTo: .title3) private var _toolsTileIconFrame: CGFloat = 36
    @ScaledMetric(relativeTo: .title3) private var _toolsTilePadding: CGFloat = 20
    @ScaledMetric(relativeTo: .title3) private var _toolsTileMinHeight: CGFloat = 140

    init(onOpenPaperChat: @escaping () -> Void = {}) {
        self._onOpenPaperChat = onOpenPaperChat
    }


    @State private var _source: Inf6PaperSourceKind = .arxiv
    @State private var _papersFolderAccessOK: Bool? = nil
    @State private var _papersFolderAccessErrorText: String? = nil
    @State private var _isLoadingFields: Bool = false
    @State private var _isLoadingPapers: Bool = false
    @State private var _pendingReloadFieldsTask: Task<Void, Never>? = nil
    @State private var _pendingLoadPapersTask: Task<Void, Never>? = nil

    @MainActor
    private func _scheduleReloadFields(resetSelection: Bool) {
        // Prevent rapid repeated network calls triggered by UI (.task / onChange / button).
        _pendingReloadFieldsTask?.cancel()
        _pendingReloadFieldsTask = Task { @MainActor in
            // Debounce: wait a short moment so multiple UI changes collapse into one.
            try? await Task.sleep(nanoseconds: 600_000_000) // 0.6s
            guard !Task.isCancelled else { return }
            await _reloadFields(resetSelection: resetSelection)
        }
    }

    @MainActor
    private func _scheduleLoadPapersForSelectedField() {
        // Prevent rapid repeated network calls triggered by picker changes.
        _pendingLoadPapersTask?.cancel()
        _pendingLoadPapersTask = Task { @MainActor in
            // Debounce: collapse multiple rapid selection changes into one fetch.
            try? await Task.sleep(nanoseconds: 600_000_000) // 0.6s
            guard !Task.isCancelled else { return }
            await _loadPapersForSelectedField()
        }
    }

    private func _filteredFieldItems(query: String) -> [Inf6ArxivPubMedFieldItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return _fields }
        return _fields.filter { f in
            f.label.localizedCaseInsensitiveContains(q) || f.id.localizedCaseInsensitiveContains(q)
        }
    }

    private struct _DiscoveredTargetSite: Identifiable, Hashable {
        let host: String
        let sampleURLString: String
        let hitCount: Int
        var id: String { host }
    }

    private func _discoveredTargetSites(from results: [Inf6PaperSearchResult]) -> [_DiscoveredTargetSite] {
        var countsByHost: [String: Int] = [:]
        var sampleURLByHost: [String: String] = [:]

        for r in results {
            let candidates: [URL] = [r.landingURL, r.pdfURL].compactMap { $0 }
            for u in candidates {
                guard var host = u.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else { continue }
                host = host.lowercased()
                if host.hasPrefix("www.") {
                    host.removeFirst(4)
                }
                countsByHost[host, default: 0] += 1
                if sampleURLByHost[host] == nil {
                    sampleURLByHost[host] = u.absoluteString
                }
            }
        }

        var out: [_DiscoveredTargetSite] = []
        out.reserveCapacity(countsByHost.count)
        for (host, count) in countsByHost {
            guard let sample = sampleURLByHost[host], !sample.isEmpty else { continue }
            out.append(_DiscoveredTargetSite(host: host, sampleURLString: sample, hitCount: count))
        }
        out.sort {
            if $0.hitCount != $1.hitCount { return $0.hitCount > $1.hitCount }
            return $0.host.localizedCaseInsensitiveCompare($1.host) == .orderedAscending
        }
        return out
    }

    private func _extractArxivID(from raw: String) -> String {
        let s0 = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s0.isEmpty { return "" }

        if let u = URL(string: s0), !u.lastPathComponent.isEmpty {
            var last = u.lastPathComponent
                .replacingOccurrences(of: ".pdf", with: "", options: [.caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            last = last.replacingOccurrences(of: "arXiv:", with: "", options: [.caseInsensitive])
            return last.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return s0
            .replacingOccurrences(of: "arXiv:", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func _validateArxivID(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        guard let dot = t.firstIndex(of: ".") else { return false }

        let lhs = t[..<dot]
        let rhs = t[t.index(after: dot)...]

        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        guard lhs.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return false }

        var i = rhs.startIndex
        var digitCount = 0
        while i < rhs.endIndex {
            let ch = rhs[i]
            if ch >= "0" && ch <= "9" {
                digitCount += 1
                i = rhs.index(after: i)
                continue
            }
            break
        }
        guard digitCount >= 1 else { return false }

        if i < rhs.endIndex {
            if rhs[i] != "v" { return false }
            let afterV = rhs.index(after: i)
            if afterV >= rhs.endIndex { return false }
            let rest = rhs[afterV...]
            if rest.isEmpty { return false }
            if !rest.allSatisfy({ $0 >= "0" && $0 <= "9" }) { return false }
        }
        return true
    }

    @State private var _fields: [Inf6ArxivPubMedFieldItem] = []
    @State private var _selectedFieldID: String = ""
    @State private var _directArxivID: String = ""
    @State private var _directArxivInput: String = ""
    @State private var _directArxivInputError: String? = nil
    @State private var _directSourceQueryInput: String = ""
    @State private var _directSourceQueryInputError: String? = nil
    @State private var _fieldSearchText: String = ""

    @State private var _results: [Inf6PaperSearchResult] = []
    @State private var _errorText: String? = nil

    // Contact email (shared with APIKeySettingsView).
    @AppStorage("inf6.external_api_identity.email") private var _externalAPIEmail: String = ""

    @State private var _showAPIKeySettingsSheet: Bool = false

    private enum _IdentityIssue {
        case missing
        case invalid
    }

    @State private var _identityIssue: _IdentityIssue? = nil
    @State private var _issuesByResultID: [String: String] = [:]

    // Papers save destination is per-source (arXiv vs PubMed) and per-platform (iOS vs iOS-on-Mac).
    @AppStorage("inf6.tools.papers.saveFolderBookmark.b64.arxiv.ios") private var _papersSaveFolderBookmarkB64_arxiv_iOS: String = ""
    @AppStorage("inf6.tools.papers.saveFolderBookmark.b64.arxiv.iosonmac") private var _papersSaveFolderBookmarkB64_arxiv_iOSOnMac: String = ""
    @AppStorage("inf6.tools.papers.saveFolderBookmark.b64.pubmed.ios") private var _papersSaveFolderBookmarkB64_pubmed_iOS: String = ""
    @AppStorage("inf6.tools.papers.saveFolderBookmark.b64.pubmed.iosonmac") private var _papersSaveFolderBookmarkB64_pubmed_iOSOnMac: String = ""
    @AppStorage("inf6.tools.papers.saveFolderBookmark.b64.acl.ios") private var _papersSaveFolderBookmarkB64_acl_iOS: String = ""
    @AppStorage("inf6.tools.papers.saveFolderBookmark.b64.acl.iosonmac") private var _papersSaveFolderBookmarkB64_acl_iOSOnMac: String = ""
    @AppStorage("inf6.tools.papers.saveFolderBookmark.b64.isca.ios") private var _papersSaveFolderBookmarkB64_isca_iOS: String = ""
    @AppStorage("inf6.tools.papers.saveFolderBookmark.b64.isca.iosonmac") private var _papersSaveFolderBookmarkB64_isca_iOSOnMac: String = ""
    @AppStorage("inf6.tools.papers.saveFolderBookmark.b64.openalex.ios") private var _papersSaveFolderBookmarkB64_openalex_iOS: String = ""
    @AppStorage("inf6.tools.papers.saveFolderBookmark.b64.openalex.iosonmac") private var _papersSaveFolderBookmarkB64_openalex_iOSOnMac: String = ""

    private var _isIOSAppOnMac: Bool {
        #if os(iOS)
        if #available(iOS 14.0, *) {
            return ProcessInfo.processInfo.isiOSAppOnMac
        }
        return false
        #else
        return false
        #endif
    }

    private var _papersSaveFolderBookmarkB64_active: String {
        get {
            switch _source {
            case .arxiv:
                return _isIOSAppOnMac ? _papersSaveFolderBookmarkB64_arxiv_iOSOnMac : _papersSaveFolderBookmarkB64_arxiv_iOS
            case .pubmed:
                return _isIOSAppOnMac ? _papersSaveFolderBookmarkB64_pubmed_iOSOnMac : _papersSaveFolderBookmarkB64_pubmed_iOS
            case .acl:
                return _isIOSAppOnMac ? _papersSaveFolderBookmarkB64_acl_iOSOnMac : _papersSaveFolderBookmarkB64_acl_iOS
            case .isca:
                return _isIOSAppOnMac ? _papersSaveFolderBookmarkB64_isca_iOSOnMac : _papersSaveFolderBookmarkB64_isca_iOS
            case .openalex:
                return _isIOSAppOnMac ? _papersSaveFolderBookmarkB64_openalex_iOSOnMac : _papersSaveFolderBookmarkB64_openalex_iOS
            }
        }
        nonmutating set {
            switch _source {
            case .arxiv:
                if _isIOSAppOnMac {
                    _papersSaveFolderBookmarkB64_arxiv_iOSOnMac = newValue
                } else {
                    _papersSaveFolderBookmarkB64_arxiv_iOS = newValue
                }
            case .pubmed:
                if _isIOSAppOnMac {
                    _papersSaveFolderBookmarkB64_pubmed_iOSOnMac = newValue
                } else {
                    _papersSaveFolderBookmarkB64_pubmed_iOS = newValue
                }
            case .acl:
                if _isIOSAppOnMac {
                    _papersSaveFolderBookmarkB64_acl_iOSOnMac = newValue
                } else {
                    _papersSaveFolderBookmarkB64_acl_iOS = newValue
                }
            case .isca:
                if _isIOSAppOnMac {
                    _papersSaveFolderBookmarkB64_isca_iOSOnMac = newValue
                } else {
                    _papersSaveFolderBookmarkB64_isca_iOS = newValue
                }
            case .openalex:
                if _isIOSAppOnMac {
                    _papersSaveFolderBookmarkB64_openalex_iOSOnMac = newValue
                } else {
                    _papersSaveFolderBookmarkB64_openalex_iOS = newValue
                }
            }
        }
    }

    @State private var _showPapersFolderPicker: Bool = false
    @State private var _papersFolderPickerTargetSourceRaw: String? = nil
    @State private var _papersFolderErrorText: String? = nil
    @State private var _papersFolderStatusText: String? = nil
    @State private var _showSavedPapersListSheet: Bool = false
    @State private var _savedPapersListItems: [_SavedPaperListItem] = []
    @State private var _savedPapersListStatus: String = ""
    @State private var _savedPapersListQuery: String = ""
    @State private var _savedPapersListPage: Int = 1
    @State private var _savedPapersListPageSize: Int = 20
    @State private var _savedPapersListSortRaw: String = "corpus_vector"
    @State private var _savedPapersClusterLabelByPath: [String: String] = [:]
    @State private var _savedPapersClusterRankByPath: [String: Int] = [:]
    @State private var _savedPapersRowMetaByPath: [String: _SavedPaperRowMeta] = [:]
    @State private var _savedPaperLatestByPath: [String: _SavedPaperLatestCheckStatus] = [:]
    @State private var _savedPaperLatestCheckInFlightPath: String = ""
    @State private var _savedPaperUpdateInFlightPath: String = ""
    @State private var _savedPaperPendingUpdateConfirmPath: String = ""
    @State private var _savedPaperLatestErrorByPath: [String: String] = [:]
    @State private var _savedPaperAbstractFillInFlightPath: String = ""
    @State private var _savedPaperAbstractFillErrorByPath: [String: String] = [:]
    @State private var _savedPaperAbstractFillTriedPaths: Set<String> = []
    @State private var _savedPapersSelectedItemPath: String = ""
    @State private var _savedPapersLastFolderPath: String = ""
    @State private var _savedPapersLastFolderModifiedAt: Date? = nil
    @State private var _savedPapersLastPDFSignature: String = ""
    @State private var _isLoadingSavedPapersList: Bool = false
    @State private var _savedPapersClassificationErrorText: String? = nil
    @State private var _pendingSavedPapersClassificationTask: Task<Void, Never>? = nil
    @State private var _showDestinationChooserSheet: Bool = false
    @State private var _isGeneratingSavedPaperMetadataJSON: Bool = false
    @State private var _savedPaperMetadataGenerationStatusText: String? = nil
    @State private var _savedPaperMetadataGenerationErrorText: String? = nil
    @State private var _papersDestinationRows: [_PapersDestinationRow] = []

    /// 版の更新確認。論文を開いたときは1本ずつ確認しているが、まとめて
    /// 確かめる手段が無かった。158件を1本ずつ開くのは現実的でない。
    @State private var _versionCheckTask: Task<Void, Never>?
    @State private var _versionCheckProgress: String?
    @State private var _versionCheckResults: [(title: String, from: Int, to: Int)] = []
    @State private var _destinationRowPendingDeletion: _PapersDestinationRow? = nil
    @State private var _isRepairingDestinationBookmarks: Bool = false
    @State private var _destinationRepairStatusText: String? = nil
    private let _savedPapersClassificationSnapshotStoreFileName = "savedpapers_classification_snapshot_store_v1.json"
    private let _papersDestinationHistoryUserDefaultsKey = "inf6.tools.papers.destination.history.v1"

    private enum _SavedPapersSortMode: String, CaseIterable, Identifiable {
        case corpusVector = "corpus_vector"
        case fileNameAsc = "name_asc"
        var id: String { rawValue }
    }

    private var _savedPapersSortMode: _SavedPapersSortMode {
        get {
            if let mode = _SavedPapersSortMode(rawValue: _savedPapersListSortRaw) {
                return mode
            }
            // Migrate legacy values.
            if _savedPapersListSortRaw == "modified_desc" || _savedPapersListSortRaw == "size_desc" {
                return .corpusVector
            }
            return .corpusVector
        }
        nonmutating set { _savedPapersListSortRaw = newValue.rawValue }
    }

    @SceneStorage("inf6.autopapers.tools.active_pane.raw") private var _paneRaw: String = ""

    private enum _ToolsPane: String, CaseIterable, Identifiable {
        case search
        case destination
        case manage
        case paperChat
        var id: String { rawValue }
    }

    private var _activePane: _ToolsPane? {
        get { _ToolsPane(rawValue: _paneRaw) }
        nonmutating set { _paneRaw = newValue?.rawValue ?? "" }
    }

    private struct _SavedPaperListItem: Identifiable, Hashable {
        let url: URL
        let modifiedAt: Date?
        var id: String { url.path }
    }

    private struct _SavedPaperLatestCheckStatus: Hashable {
        let baseID: String
        let localVersion: Int?
        let remoteVersion: Int?
        let remoteLandingURL: URL?
        let remotePDFURL: URL?

        var hasUpdate: Bool {
            guard let localVersion, let remoteVersion else { return false }
            return remoteVersion > localVersion
        }
    }

    private struct _PapersDestinationHistoryEntry: Codable, Hashable {
        let path: String
        let sourceRaw: String
        let platformRaw: String
        let bookmarkB64: String?
        let selectedAt: Date
    }

    private struct _PapersDestinationRow: Identifiable, Hashable {
        let path: String
        let sourceLabels: [String]
        let platformLabels: [String]
        let selectedAt: Date
        let isCurrent: Bool
        var id: String { path }
    }

    private struct _PapersDestinationMappingRow: Identifiable, Hashable {
        let sourceRaw: String
        let sourceLabel: String
        let platformLabel: String
        let directoryName: String
        let path: String
        let isConfigured: Bool
        let isActiveSource: Bool
        var id: String { sourceRaw }
    }

    private struct _PapersDestinationAggregate {
        var sourceRaws: Set<String> = []
        var platformRaws: Set<String> = []
        var selectedAt: Date = .distantPast
        var isCurrent: Bool = false
    }

    @MainActor
    private func _copyToPasteboard(_ text: String) -> Bool {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        return true
        #else
        return false
        #endif
    }

    @MainActor
    private func _openSavedPaperInLibrary(item: _SavedPaperListItem, folderURL: URL?) {
        guard let folderURL else {
            _savedPapersListStatus = Inf6Lang.text(
                "保存先フォルダが解決できないため、PDFを開けません。",
                "Cannot open PDF because destination folder is unresolved."
            )
            return
        }
        NotificationCenter.default.post(
            name: .inf6OpenSavedPaperPDFInLibrary,
            object: item.url,
            userInfo: ["inf6.folderURL": folderURL]
        )
    }

    @MainActor
    private func _savedPaperAutoCheckLatestIfNeeded(
        item: _SavedPaperListItem,
        rowMeta: _SavedPaperRowMeta?
    ) {
        let providerRaw = rowMeta?.providerRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard providerRaw == "arxiv" else { return }

        let path = item.url.path
        if _savedPaperLatestByPath[path] != nil { return }
        if _savedPaperLatestCheckInFlightPath == path { return }
        if _savedPaperUpdateInFlightPath == path { return }

        Task { @MainActor in
            await _checkSavedPaperLatestArxiv(item: item, rowMeta: rowMeta)
        }
    }

    @MainActor
    private func _savedPaperAutoFillAbstractIfNeeded(
        item: _SavedPaperListItem,
        rowMeta: _SavedPaperRowMeta?,
        folderURL: URL?
    ) {
        let path = item.url.path
        let abstractNow = _savedPaperNormalizedAbstractText(rowMeta?.abstractText ?? "")
        guard abstractNow.isEmpty else { return }
        if _savedPaperAbstractFillInFlightPath == path { return }
        if _savedPaperAbstractFillTriedPaths.contains(path) { return }

        _savedPaperAbstractFillTriedPaths.insert(path)
        _savedPaperAbstractFillErrorByPath[path] = ""

        Task { @MainActor in
            await _fillSavedPaperAbstractIfNeeded(item: item, rowMeta: rowMeta, folderURL: folderURL)
        }
    }

    @MainActor
    private func _fillSavedPaperAbstractIfNeeded(
        item: _SavedPaperListItem,
        rowMeta: _SavedPaperRowMeta?,
        folderURL: URL?
    ) async {
        let path = item.url.path
        if _savedPaperAbstractFillInFlightPath == path { return }
        _savedPaperAbstractFillInFlightPath = path
        defer {
            if _savedPaperAbstractFillInFlightPath == path {
                _savedPaperAbstractFillInFlightPath = ""
            }
        }

        do {
            let abstract = try await _fetchSavedPaperSupplementalAbstractOrThrow(item: item, rowMeta: rowMeta, folderURL: folderURL)
            let normalized = _savedPaperNormalizedAbstractText(abstract)
            guard !normalized.isEmpty else {
                throw NSError(
                    domain: "Inf6SavedPaperAbstractFill",
                    code: -10,
                    userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("要旨補完結果が空でした。", "Abstract completion result was empty.")]
                )
            }

            try _updateSavedPaperMetadataSidecarAbstractOrThrow(forPDF: item.url, abstractText: normalized)
            let metadata = try _loadSavedPaperMetadataOrThrow(forPDF: item.url)
            let featureKeywords = _savedPapersRowMetaByPath[path]?.featureKeywords ?? []
            _savedPapersRowMetaByPath[path] = _savedPaperRowMeta(
                from: metadata,
                fileName: item.url.lastPathComponent,
                featureKeywords: featureKeywords
            )
            _savedPaperAbstractFillErrorByPath[path] = ""
        } catch {
            _savedPaperAbstractFillErrorByPath[path] = error.localizedDescription
        }
    }

    private func _fetchSavedPaperSupplementalAbstractOrThrow(
        item: _SavedPaperListItem,
        rowMeta: _SavedPaperRowMeta?,
        folderURL: URL?
    ) async throws -> String {
        var providerErrors: [String] = []
        let provider = _savedPaperEffectiveProviderRaw(rowMeta: rowMeta)

        if !provider.isEmpty {
            do {
                let fromProvider = try await _fetchSavedPaperAbstractFromProviderOrThrow(
                    providerRaw: provider,
                    item: item,
                    rowMeta: rowMeta
                )
                let normalized = _savedPaperNormalizedAbstractText(fromProvider)
                if !normalized.isEmpty {
                    return normalized
                }
                providerErrors.append(Inf6Lang.text("検索元から要旨を取得できませんでした。", "Could not fetch abstract from source provider."))
            } catch {
                providerErrors.append(error.localizedDescription)
            }
        }

        do {
            let fromPDF = try _extractSavedPaperAbstractFromPDFOrThrow(item: item, folderURL: folderURL)
            let normalized = _savedPaperNormalizedAbstractText(fromPDF)
            if !normalized.isEmpty {
                return normalized
            }
        } catch {
            providerErrors.append(error.localizedDescription)
        }

        let detail = providerErrors.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: " / ")
        if !detail.isEmpty {
            throw NSError(
                domain: "Inf6SavedPaperAbstractFill",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("要旨を補完できませんでした: ", "Failed to complete abstract: ") + detail]
            )
        }
        throw NSError(
            domain: "Inf6SavedPaperAbstractFill",
            code: -12,
            userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("要旨を補完できませんでした。", "Failed to complete abstract.")]
        )
    }

    private func _savedPaperEffectiveProviderRaw(rowMeta: _SavedPaperRowMeta?) -> String {
        let direct = rowMeta?.providerRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if direct == "arxiv" || direct == "pubmed" || direct == "acl" || direct == "isca" {
            return direct
        }

        let sourceURLText = rowMeta?.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let host = URL(string: sourceURLText)?.host?.lowercased() {
            if host.contains("arxiv.org") { return "arxiv" }
            if host.contains("pubmed.ncbi.nlm.nih.gov") || host.contains("ncbi.nlm.nih.gov") { return "pubmed" }
            if host.contains("aclanthology.org") { return "acl" }
            if host.contains("isca-archive.org") { return "isca" }
        }
        return ""
    }

    private func _fetchSavedPaperAbstractFromProviderOrThrow(
        providerRaw: String,
        item: _SavedPaperListItem,
        rowMeta: _SavedPaperRowMeta?
    ) async throws -> String {
        let sourceURLText = rowMeta?.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawIDText = rowMeta?.rawID.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch providerRaw {
        case "arxiv":
            let local = _savedPaperLocalArxivBaseAndVersion(item: item, rowMeta: rowMeta)
            var queryID = local.base.trimmingCharacters(in: .whitespacesAndNewlines)
            if queryID.isEmpty {
                let parsedFromSource = _parseArxivBaseAndVersion(fromCandidate: sourceURLText)
                queryID = parsedFromSource.base.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if queryID.isEmpty {
                let parsedFromRaw = _parseArxivBaseAndVersion(fromCandidate: rawIDText)
                queryID = parsedFromRaw.base.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !queryID.isEmpty else {
                throw NSError(
                    domain: "Inf6SavedPaperAbstractFill",
                    code: -20,
                    userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("arXiv ID を特定できません。", "Could not determine arXiv id.")]
                )
            }
            let papers = try await Inf6ArxivClient.fetchByID(arxivID: queryID)
            if let abstract = papers.first(where: { !$0.abstractText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.abstractText {
                return abstract
            }
            throw NSError(
                domain: "Inf6SavedPaperAbstractFill",
                code: -21,
                userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("arXiv から要旨を取得できませんでした。", "Could not fetch abstract from arXiv.")]
            )

        case "acl":
            let query: String = {
                if !sourceURLText.isEmpty { return sourceURLText }
                if rawIDText.lowercased().hasPrefix("acl:") {
                    let token = String(rawIDText.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !token.isEmpty { return "https://aclanthology.org/\(token).pdf" }
                }
                return ""
            }()
            guard !query.isEmpty else {
                throw NSError(
                    domain: "Inf6SavedPaperAbstractFill",
                    code: -22,
                    userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("ACL URL/ID が不足しています。", "ACL URL/ID is missing.")]
                )
            }
            let papers = try await Inf6ACLAnthologyClient.search(query: query, maxResults: 1)
            if let abstract = papers.first?.abstractText.trimmingCharacters(in: .whitespacesAndNewlines), !abstract.isEmpty {
                return abstract
            }
            throw NSError(
                domain: "Inf6SavedPaperAbstractFill",
                code: -23,
                userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("ACL Anthology から要旨を取得できませんでした。", "Could not fetch abstract from ACL Anthology.")]
            )

        case "isca":
            let query: String = {
                if !sourceURLText.isEmpty { return sourceURLText }
                return ""
            }()
            guard !query.isEmpty else {
                throw NSError(
                    domain: "Inf6SavedPaperAbstractFill",
                    code: -24,
                    userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("ISCA URL が不足しています。", "ISCA URL is missing.")]
                )
            }
            let papers = try await Inf6ISCAArchiveClient.search(query: query, maxResults: 1)
            if let abstract = papers.first?.abstractText.trimmingCharacters(in: .whitespacesAndNewlines), !abstract.isEmpty {
                return abstract
            }
            throw NSError(
                domain: "Inf6SavedPaperAbstractFill",
                code: -25,
                userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("ISCA Archive から要旨を取得できませんでした。", "Could not fetch abstract from ISCA Archive.")]
            )

        default:
            throw NSError(
                domain: "Inf6SavedPaperAbstractFill",
                code: -26,
                userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("この検索元はネットワーク要旨補完に未対応です。", "This provider is not supported for network abstract completion.")]
            )
        }
    }

    private func _extractSavedPaperAbstractFromPDFOrThrow(
        item: _SavedPaperListItem,
        folderURL: URL?
    ) throws -> String {
        #if canImport(PDFKit)
        let started = folderURL?.startAccessingSecurityScopedResource() ?? true
        if folderURL != nil, !started {
            throw NSError(
                domain: "Inf6SavedPaperAbstractFill",
                code: -30,
                userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("保存先フォルダへのアクセス権を取得できませんでした。", "Could not access destination folder.")]
            )
        }
        defer {
            if started, let folderURL {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        guard let doc = PDFDocument(url: item.url), doc.pageCount > 0 else {
            throw NSError(
                domain: "Inf6SavedPaperAbstractFill",
                code: -31,
                userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("PDF本文を読み取れませんでした。", "Could not read PDF text.")]
            )
        }

        let rawText = _savedPaperGeneratedRawText(from: doc, maxPages: 3, maxChars: 24_000)
        let abstract = _savedPaperGeneratedAbstract(from: rawText)
        let normalized = _savedPaperNormalizedAbstractText(abstract)
        guard !normalized.isEmpty else {
            throw NSError(
                domain: "Inf6SavedPaperAbstractFill",
                code: -32,
                userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("PDFから要旨を抽出できませんでした。", "Could not extract abstract from PDF.")]
            )
        }
        return normalized
        #else
        throw NSError(
            domain: "Inf6SavedPaperAbstractFill",
            code: -33,
            userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("この環境ではPDF要旨抽出が利用できません。", "PDF abstract extraction is unavailable in this environment.")]
        )
        #endif
    }

    private func _updateSavedPaperMetadataSidecarAbstractOrThrow(
        forPDF pdfURL: URL,
        abstractText: String
    ) throws {
        let normalized = _savedPaperNormalizedAbstractText(abstractText)
        guard !normalized.isEmpty else {
            throw NSError(
                domain: "Inf6SavedPaperAbstractFill",
                code: -40,
                userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("更新対象の要旨が空です。", "The abstract to persist is empty.")]
            )
        }

        let existingCandidates = _savedPaperMetadataSidecarCandidates(forPDF: pdfURL)
        let sidecarURL: URL
        if let existing = existingCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            sidecarURL = existing
        } else {
            try _writeGeneratedPaperMetadataSidecarOrThrow(forPDF: pdfURL)
            sidecarURL = _savedPaperMetadataPrimarySidecarURL(forPDF: pdfURL)
        }

        let data = try Data(contentsOf: sidecarURL)
        let jsonObj = try JSONSerialization.jsonObject(with: data, options: [])
        guard var root = jsonObj as? [String: Any] else {
            throw NSError(
                domain: "Inf6SavedPaperAbstractFill",
                code: -41,
                userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("メタデータJSONの形式が不正です。", "Metadata JSON format is invalid.")]
            )
        }

        root["abstract"] = normalized
        let title = _trimmedMetadataString(root["title"]).isEmpty ? pdfURL.deletingPathExtension().lastPathComponent : _trimmedMetadataString(root["title"])
        let provider = _trimmedMetadataString(root["provider"]).isEmpty ? "unknown" : _trimmedMetadataString(root["provider"])
        root["title"] = title
        root["provider"] = provider

        var raw = (root["raw"] as? [String: Any]) ?? [:]
        if _trimmedMetadataString(raw["id"]).isEmpty {
            raw["id"] = "\(provider):\(pdfURL.deletingPathExtension().lastPathComponent)"
        }
        if _trimmedMetadataString(raw["title"]).isEmpty {
            raw["title"] = title
        }
        if _trimmedMetadataString(raw["provider"]).isEmpty {
            raw["provider"] = provider
        }
        raw["abstract"] = normalized
        root["raw"] = raw

        if (root["tags"] as? [Any]) == nil {
            root["tags"] = _savedPaperGeneratedTags(title: title, abstractText: normalized)
        }

        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: sidecarURL, options: [.atomic])
    }

    private func _savedPaperShouldShowFileName(
        displayTitle: String,
        fileName: String,
        hasMetadataTitle: Bool
    ) -> Bool {
        guard hasMetadataTitle else { return false }
        let normalizedTitle = _savedPaperComparableText(displayTitle)
        let normalizedFileName = _savedPaperComparableText((fileName as NSString).deletingPathExtension)
        if normalizedTitle.isEmpty || normalizedFileName.isEmpty { return true }
        return normalizedTitle != normalizedFileName
    }

    private func _savedPaperComparableText(_ raw: String) -> String {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return "" }
        let tokens = lower
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return tokens.joined(separator: " ")
    }

    #if canImport(UIKit)
    private func _savedPaperSelectableCardAttributedText(
        displayTitle: String,
        fileName: String,
        showFileName: Bool,
        featureKeywords: [String]
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()

        func appendLine(_ text: String, font: UIFont, color: UIColor) {
            let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return }
            if out.length > 0 {
                out.append(NSAttributedString(string: "\n"))
            }
            out.append(
                NSAttributedString(
                    string: s,
                    attributes: [
                        .font: font,
                        .foregroundColor: color,
                    ]
                )
            )
        }

        let titleFont = UIFont.systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .title3).pointSize,
            weight: .semibold
        )
        let fileNameFont = UIFont.systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .callout).pointSize,
            weight: .medium
        )
        let keywordFont = UIFont.systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .callout).pointSize,
            weight: .semibold
        )

        appendLine(displayTitle, font: titleFont, color: .label)
        if showFileName {
            appendLine(fileName, font: fileNameFont, color: .systemBlue)
        }
        if !featureKeywords.isEmpty {
            appendLine(featureKeywords.joined(separator: "  "), font: keywordFont, color: UIColor(red: 0.0, green: 0.35, blue: 0.0, alpha: 1.0))
        }
        return out
    }
    #endif

    @MainActor
    private func _selectToolsPane(_ pane: _ToolsPane) {
        if pane == .paperChat {
            _activePane = nil
            _showSavedPapersListSheet = false
            _onOpenPaperChat()
            return
        }

        if _activePane == pane {
            if pane == .manage {
                _reloadPapersDestinationRows()
                _showSavedPapersListSheet = false
            } else if pane == .destination {
                _reloadPapersDestinationRows()
                _papersFolderErrorText = nil
                _papersFolderAccessErrorText = nil
                _destinationRepairStatusText = nil
            }
            return
        }

        _activePane = pane

        switch pane {
        case .search:
            _showSavedPapersListSheet = false
        case .destination:
            _showSavedPapersListSheet = false
            _reloadPapersDestinationRows()
            _papersFolderErrorText = nil
            _papersFolderAccessErrorText = nil
            _destinationRepairStatusText = nil
        case .manage:
            _reloadPapersDestinationRows()
            _showSavedPapersListSheet = false
        case .paperChat:
            _showSavedPapersListSheet = false
        }
    }

    /// 収集済みの論文に、新しい版が出ていないかをまとめて確かめる。
    ///
    /// arXiv は 3.2秒に1回までしか受け付けない。件数分の時間がかかるため、
    /// 進み具合を出し、途中で止められるようにする。
    @ViewBuilder
    private func _versionCheckSection() -> some View {
        let papers = Inf6CorePaperStore.shared.papers.filter {
            !($0.arxivId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if _versionCheckTask == nil {
                    Button {
                        _startVersionCheck(papers)
                    } label: {
                        Label(
                            Inf6Lang.text("新しい版を確認 (\(papers.count)件)", "Check for newer versions (\(papers.count))"),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(papers.isEmpty)
                } else {
                    ProgressView().tint(.pink).scaleEffect(1.25)
                    Button {
                        _versionCheckTask?.cancel()
                        _versionCheckTask = nil
                        _versionCheckProgress = nil
                    } label: {
                        Text(Inf6Lang.text("中止", "Stop"))
                    }
                    .buttonStyle(.bordered)
                }

                if let _versionCheckProgress {
                    Text(_versionCheckProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !_versionCheckResults.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(_versionCheckResults.indices, id: \.self) { index in
                        let result = _versionCheckResults[index]
                        Text("v\(result.from) → v\(result.to)  \(result.title)")
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func _startVersionCheck(_ papers: [Inf6CorePaper]) {
        _versionCheckResults = []
        _versionCheckProgress = nil

        _versionCheckTask = Task { @MainActor in
            for (index, paper) in papers.enumerated() {
                if Task.isCancelled { break }
                _versionCheckProgress = Inf6Lang.text(
                    "\(index + 1)/\(papers.count) 確認中",
                    "Checking \(index + 1)/\(papers.count)"
                )
                if let update = await Inf6PaperSourceService.checkForNewerVersion(of: paper) {
                    _versionCheckResults.append((
                        title: paper.title,
                        from: update.currentVersion,
                        to: update.latestVersion
                    ))
                }
            }
            if !Task.isCancelled {
                _versionCheckProgress = _versionCheckResults.isEmpty
                    ? Inf6Lang.text("すべて最新です。", "All up to date.")
                    : Inf6Lang.text("\(_versionCheckResults.count)件に新しい版があります。",
                                    "\(_versionCheckResults.count) have newer versions.")
            }
            _versionCheckTask = nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let paneColumns = _toolsTileColumns
            LazyVGrid(columns: paneColumns, spacing: 12) {
                ForEach(_ToolsPane.allCases) { pane in
                    _toolsPaneTile(pane)
                }
            }
            .accessibilityIdentifier("Inf6ArxivPubMedToolsSection.PaneTiles")

            if _activePane == .search {
                VStack(alignment: .leading, spacing: 10) {
                    let sourceColumns: [GridItem] = [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                    ]

                    LazyVGrid(columns: sourceColumns, spacing: 12) {
                        ForEach(Inf6PaperSourceKind.allCases) { s in
                            let isSelected = (_source == s)
                            let accent: Color = (s == .arxiv) ? .blue : .indigo
                            Button {
                                _source = s
                            } label: {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack(spacing: 10) {
                                        Image(systemName: {
                                            switch s {
                                            case .arxiv:
                                                return "a.circle.fill"
                                            case .pubmed:
                                                return "p.circle.fill"
                                            case .acl:
                                                return "text.book.closed.fill"
                                            case .isca:
                                                return "waveform.path.ecg"
                                            case .openalex:
                                                return "globe"
                                            }
                                        }())
                                            .font(.title3.weight(.bold))
                                            .foregroundStyle(isSelected ? .white : accent)

                                        Text(s.title)
                                            .font(.title3.weight(.bold))
                                            .foregroundStyle(isSelected ? .white : .primary)

                                        Spacer(minLength: 0)

                                        if isSelected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.white)
                                        }
                                    }

                                    Text(
                                        {
                                            switch s {
                                            case .arxiv:
                                                return Inf6Lang.text("arXiv を検索します。", "Search arXiv.")
                                            case .pubmed:
                                                return Inf6Lang.text("PubMed を検索します。", "Search PubMed.")
                                            case .acl:
                                                return Inf6Lang.text("ACL Anthology を検索します。", "Search ACL Anthology.")
                                            case .isca:
                                                return Inf6Lang.text("ISCA Archive を検索します。", "Search ISCA Archive.")
                                            case .openalex:
                                                return Inf6Lang.text("OpenAlex で横断検索します。", "Search broadly via OpenAlex.")
                                            }
                                        }()
                                    )
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(isSelected ? Color.white.opacity(0.90) : .secondary)
                                }
                                .padding(16)
                                .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(isSelected ? accent : Color.secondary.opacity(0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(isSelected ? accent.opacity(0.90) : Color.clear, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(_isLoadingFields || _isLoadingPapers)
                            .accessibilityIdentifier("Inf6ArxivPubMedToolsSection.Source.\(s.rawValue)")
                        }
                    }
                }

                if _isLoadingFields {
                    HStack(spacing: 10) {
                        ProgressView().tint(.pink).scaleEffect(1.25)
                        Text(Inf6Lang.text("検索分野一覧を取得中…", "Loading fields…"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }

                let _showsDirectSourceSearch = (_source == .acl || _source == .isca || _source == .openalex)
                if !_fields.isEmpty || _showsDirectSourceSearch {
                    let filteredFields = _filteredFieldItems(query: _fieldSearchText)

                    VStack(alignment: .leading, spacing: 10) {
                        if _source == .arxiv {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {

                                    Button {
                                        let extracted = _extractArxivID(from: _directArxivInput)
                                            .trimmingCharacters(in: .whitespacesAndNewlines)
                                        guard _validateArxivID(extracted) else {
                                            _directArxivInputError = Inf6Lang.text(
                                                "arXiv のID/URLを認識できませんでした。例: 2505.23840v4",
                                                "Could not recognize an arXiv ID/URL. Example: 2505.23840v4"
                                            )
                                            return
                                        }
                                        _selectedFieldID = ""
                                        _directArxivID = extracted
                                        _directArxivInput = extracted
                                        _directArxivInputError = nil
                                    } label: {
                                        Text(Inf6Lang.text("この arXiv ID または URL で検索", "Search this arXiv ID or URL"))
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(_isLoadingFields || _isLoadingPapers)
                                    
                                    
                                    TextField(
                                        "",
                                        text: Binding(
                                            get: { _directArxivInput },
                                            set: {
                                                _directArxivInput = $0
                                                _directArxivInputError = nil
                                            }
                                        )
                                    )
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled(true)
                                    .textFieldStyle(.roundedBorder)

  
                                }

                                if let e = _directArxivInputError,
                                   !e.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(e)
                                        .font(.footnote)
                                        .foregroundStyle(.red)
                                        .textSelection(.enabled)
                                }
                            }
                        }

                        if _source == .acl || _source == .isca || _source == .openalex {
                            VStack(alignment: .leading, spacing: 8) {
                                let sourceInputPlaceholder: String = {
                                    if _source == .acl {
                                        return Inf6Lang.text(
                                            "例: transformer, speech recognition, https://aclanthology.org/2025.acl-long.123/",
                                            "e.g. transformer, speech recognition, https://aclanthology.org/2025.acl-long.123/"
                                        )
                                    }
                                    if _source == .openalex {
                                        return Inf6Lang.text(
                                            "例: large language model safety, prompt injection, speech recognition",
                                            "e.g. large language model safety, prompt injection, speech recognition"
                                        )
                                    }
                                    return Inf6Lang.text(
                                        "例: speech recognition, prosody, https://www.isca-archive.org/interspeech_2023/sample_interspeech.html",
                                        "e.g. speech recognition, prosody, https://www.isca-archive.org/interspeech_2023/sample_interspeech.html"
                                    )
                                }()

                                HStack(spacing: 8) {
                                    Button {
                                        let q = _directSourceQueryInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                        guard !q.isEmpty else {
                                            _directSourceQueryInputError = Inf6Lang.text(
                                                "検索キーワードまたはURLを入力してください。",
                                                "Enter a search keyword or URL."
                                            )
                                            return
                                        }
                                        _selectedFieldID = q
                                        _directSourceQueryInputError = nil
                                        Task { @MainActor in
                                            await _loadPapersForSelectedField()
                                        }
                                    } label: {
                                        Text(
                                            Inf6Lang.text(
                                                "このキーワード/URLで検索",
                                                "Search with this keyword/URL"
                                            )
                                        )
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(_isLoadingFields || _isLoadingPapers)

                                    TextField(
                                        sourceInputPlaceholder,
                                        text: Binding(
                                            get: { _directSourceQueryInput },
                                            set: {
                                                _directSourceQueryInput = $0
                                                _directSourceQueryInputError = nil
                                            }
                                        )
                                    )
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled(true)
                                    .textFieldStyle(.roundedBorder)
                                }

                                if let e = _directSourceQueryInputError,
                                   !e.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(e)
                                        .font(.footnote)
                                        .foregroundStyle(.red)
                                        .textSelection(.enabled)
                                }
                            }
                        }

                        if !_fields.isEmpty {
                            TextField(
                                "",
                                text: $_fieldSearchText
                            )
                            .textFieldStyle(.roundedBorder)

                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    Button {
                                        _selectedFieldID = ""
                                        _directArxivID = ""
                                        _directArxivInput = ""
                                        _directArxivInputError = nil
                                    } label: {
                                        HStack(spacing: 8) {
                                            Text(Inf6Lang.text("検索分野を指定しない", "No field filter"))
                                                .lineLimit(1)
                                            Spacer()
                                            if _selectedFieldID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                                                _directArxivID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                                Image(systemName: "checkmark")
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .padding(.vertical, 10)
                                    }
                                    .buttonStyle(.plain)

                                    Divider()

                                    if filteredFields.isEmpty {
                                        Text(Inf6Lang.text("該当する検索分野がありません。", "No matching fields."))
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .padding(.vertical, 10)
                                    } else {
                                        ForEach(filteredFields) { f in
                                            Button {
                                                _selectedFieldID = f.id
                                                _directArxivID = ""
                                                _directArxivInput = ""
                                                _directArxivInputError = nil
                                            } label: {
                                                HStack(spacing: 8) {
                                                    Text(f.label)
                                                        .textSelection(.enabled)
                                                    Spacer()
                                                    if _selectedFieldID == f.id {
                                                        Image(systemName: "checkmark")
                                                            .foregroundStyle(.secondary)
                                                    }
                                                }
                                                .padding(.vertical, 10)
                                            }
                                            .buttonStyle(.plain)

                                            if f.id != filteredFields.last?.id {
                                                Divider()
                                            }
                                        }
                                    }
                                }
                            }
                            .frame(maxHeight: 280)
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.secondary.opacity(0.08))
                    )
                }

                if _isLoadingPapers {
                    HStack(spacing: 10) {
                        ProgressView().tint(.pink).scaleEffect(1.25)
                        Text(Inf6Lang.text("論文一覧を取得中…", "Loading papers…"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }

                if let e = _errorText {
                    Text(e)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                if _identityIssue != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            _showAPIKeySettingsSheet = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "gearshape")
                                Text(Inf6Lang.text("設定を開く", "Open Settings"))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .sheet(isPresented: $_showAPIKeySettingsSheet, onDismiss: {
                            Task { @MainActor in
                                _scheduleReloadFields(resetSelection: true)
                            }
                        }) {
                            APIKeySettingsView()
                        }
                    }
                    .padding(.vertical, 6)
                }
            }

            // Papers save destination is scoped to the currently selected source.
            let folderResolve = _resolvePapersSaveFolderURLOrError()
            let folderURL = folderResolve.url
            let folderError = folderResolve.error

            if _activePane == .destination || _activePane == .manage {
                let isManageSavedPapersListMode = (_activePane == .manage && _showSavedPapersListSheet)
                let isCurrentSourceMappingConfigured = (folderURL != nil)
                VStack(alignment: .leading, spacing: 12) {
                    if !isManageSavedPapersListMode {
                        HStack(spacing: 12) {
                            if _activePane == .destination && !isCurrentSourceMappingConfigured {
                                Button {
                                    _papersFolderErrorText = nil
                                    _papersFolderStatusText = nil
                                    _papersFolderPickerTargetSourceRaw = _source.rawValue
                                    _showPapersFolderPicker = true
                                } label: {
                                    Text(
                                        Inf6Lang.text("マッピング追加", "Add mapping")
                                        + " ("
                                        + _papersDestinationSourceLabel(_source.rawValue)
                                        + ")"
                                    )
                                        .font(.body.weight(.semibold))
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(_isLoadingFields || _isLoadingPapers)

                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(
                                    Inf6Lang.text("現在のマッピング", "Current mapping")
                                    + " ("
                                    + _papersDestinationSourceLabel(_source.rawValue)
                                    + ")"
                                )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(folderURL?.lastPathComponent ?? Inf6Lang.text("未設定", "Not set"))
                                    .font(.title3.weight(.semibold))
                                    .lineLimit(1)
                            }

                            Spacer()
                        }
                    }

                if let e = _papersFolderErrorText, !e.isEmpty {
                    Text(e)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if let status = _papersFolderStatusText, !status.isEmpty {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.blue)
                        .textSelection(.enabled)
                }

                if _activePane == .manage,
                   let folderError,
                   !folderError.isEmpty {
                    Text(folderError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                
                if _activePane == .manage,
                   _papersFolderAccessOK == false,
                   let e = _papersFolderAccessErrorText,
                   !e.isEmpty {
                    Text(e)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                if _activePane == .manage,
                   let repairStatus = _destinationRepairStatusText,
                   !repairStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(repairStatus)
                        .font(.callout)
                        .foregroundStyle(.blue)
                        .textSelection(.enabled)
                }

                if let generationError = _savedPaperMetadataGenerationErrorText,
                   !generationError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   _activePane == .manage {
                    Text(generationError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                if let generationStatus = _savedPaperMetadataGenerationStatusText,
                   !generationStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   _activePane == .manage {
                    Text(generationStatus)
                        .font(.callout)
                        .foregroundStyle(.blue)
                        .textSelection(.enabled)
                }

                if _activePane == .destination {
                    _destinationListSectionView()
                }

                if _activePane == .manage {
                    _versionCheckSection()

                    if _showSavedPapersListSheet {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Button {
                                    _showSavedPapersListSheet = false
                                } label: {
                                    Text(Inf6Lang.text("戻る", "Back"))
                                        .font(.body.weight(.semibold))
                                }
                                .buttonStyle(.bordered)

                                Spacer(minLength: 0)
                            }

                            Text(
                                Inf6Lang.text("現在のマッピング: ", "Current mapping: ")
                                + _papersDestinationSourceLabel(_source.rawValue)
                                + " → "
                                + (folderURL?.lastPathComponent ?? Inf6Lang.text("未設定", "Not set"))
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                            if let classificationError = _savedPapersClassificationErrorText,
                               !classificationError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(classificationError)
                                    .font(.callout)
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }

                            let query = _savedPapersListQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                            let filteredItems: [_SavedPaperListItem] = {
                                if query.isEmpty { return _savedPapersListItems }
                                return _savedPapersListItems.filter {
                                    $0.url.lastPathComponent.localizedCaseInsensitiveContains(query)
                                }
                            }()

                            let sortedItems: [_SavedPaperListItem] = {
                                switch _savedPapersSortMode {
                                case .corpusVector:
                                    return filteredItems.sorted { lhs, rhs in
                                        let lr = _savedPapersClusterRankByPath[lhs.url.path] ?? Int.max
                                        let rr = _savedPapersClusterRankByPath[rhs.url.path] ?? Int.max
                                        if lr != rr { return lr < rr }
                                        return lhs.url.lastPathComponent.localizedCaseInsensitiveCompare(rhs.url.lastPathComponent) == .orderedAscending
                                    }
                                case .fileNameAsc:
                                    return filteredItems.sorted {
                                        $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending
                                    }
                                }
                            }()

                            let pageSize = max(_savedPapersListPageSize, 1)
                            let totalCount = sortedItems.count
                            let pageCount = max(1, (totalCount + pageSize - 1) / pageSize)
                            let safePage = min(max(_savedPapersListPage, 1), pageCount)
                            let start = (safePage - 1) * pageSize
                            let end = min(start + pageSize, totalCount)
                            let pageItems: [_SavedPaperListItem] = {
                                guard totalCount > 0 else { return [] }
                                return Array(sortedItems[start..<end])
                            }()

                            HStack(spacing: 8) {
                                TextField(
                                    Inf6Lang.text("ファイル名で絞り込み", "Filter by filename"),
                                    text: $_savedPapersListQuery
                                )
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: _savedPapersListQuery) { _, _ in
                                    _savedPapersListPage = 1
                                }

                                Menu {
                                    Button {
                                        _savedPapersSortMode = .corpusVector
                                        _savedPapersListPage = 1
                                    } label: {
                                        Text(Inf6Lang.text("分類順", "By classification"))
                                    }
                                    Button {
                                        _savedPapersSortMode = .fileNameAsc
                                        _savedPapersListPage = 1
                                    } label: {
                                        Text(Inf6Lang.text("ファイル名順", "Filename"))
                                    }
                                } label: {
                                    Label(_savedPapersSortLabel(_savedPapersSortMode), systemImage: "arrow.up.arrow.down")
                                        .font(.body)
                                }

                                Menu {
                                    Button("20") {
                                        _savedPapersListPageSize = 20
                                        _savedPapersListPage = 1
                                    }
                                    Button("50") {
                                        _savedPapersListPageSize = 50
                                        _savedPapersListPage = 1
                                    }
                                    Button("100") {
                                        _savedPapersListPageSize = 100
                                        _savedPapersListPage = 1
                                    }
                                } label: {
                                    Label(
                                        Inf6Lang.text("1ページ", "Per page")
                                        + " \(_savedPapersListPageSize)",
                                        systemImage: "list.number"
                                    )
                                    .font(.body)
                                }
                            }

                            if _isLoadingSavedPapersList || _pendingSavedPapersClassificationTask != nil {
                                HStack(spacing: 8) {
                                    ProgressView().tint(.pink).scaleEffect(1.25)
                                    Text(
                                        _isLoadingSavedPapersList
                                        ? Inf6Lang.text("論文一覧を読み込み中…", "Loading saved papers…")
                                        : Inf6Lang.text("分類を実行中…", "Running classification…")
                                    )
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                }
                            }

                            if totalCount == 0 {
                                Text(Inf6Lang.text("条件に一致するPDFはありません。", "No PDFs match the current filter."))
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            } else {
                                let grouped: [(label: String, items: [_SavedPaperListItem])] = {
                                    var order: [String] = []
                                    var buckets: [String: [_SavedPaperListItem]] = [:]
                                    for item in pageItems {
                                        let label = _savedPapersClusterLabelByPath[item.url.path]
                                            ?? Inf6Lang.text("未分類", "Uncategorized")
                                        if buckets[label] == nil {
                                            order.append(label)
                                            buckets[label] = []
                                        }
                                        buckets[label, default: []].append(item)
                                    }
                                    return order.map { ($0, buckets[$0] ?? []) }
                                }()
                                let effectiveSelectedPath: String = {
                                    if pageItems.contains(where: { $0.url.path == _savedPapersSelectedItemPath }) {
                                        return _savedPapersSelectedItemPath
                                    }
                                    return pageItems.first?.url.path ?? ""
                                }()
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(grouped, id: \.label) { group in
                                        VStack(alignment: .leading, spacing: 10) {
                                            HStack(spacing: 10) {
                                                #if canImport(UIKit)
                                                _Inf6SelectableTextView(
                                                    text: group.label,
                                                    font: .preferredFont(forTextStyle: .title3),
                                                    color: .systemPurple,
                                                    lineLimit: 1
                                                )
                                                #else
                                                Text(group.label)
                                                    .font(.title3.weight(.bold))
                                                    .foregroundStyle(.purple)
                                                    .textSelection(.enabled)
                                                #endif
                                                _otherGroupActionButton(groupLabel: group.label, folderURL: folderURL)
                                                Spacer()
                                                Text(
                                                    Inf6Lang.text(
                                                        "\(group.items.count)件",
                                                        "\(group.items.count) items"
                                                    )
                                                )
                                                .font(.callout.weight(.semibold))
                                                .foregroundStyle(.blue)
                                            }

                                            Divider()

                                            ForEach(group.items, id: \.id) { item in
                                                let rowMeta = _savedPapersRowMetaByPath[item.url.path]
                                                let displayTitle = {
                                                    let t = rowMeta?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                                    if !t.isEmpty { return t }
                                                    return item.url.lastPathComponent
                                                }()
                                                let hasMetadataTitle = (rowMeta?.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                                                let showFileName = _savedPaperShouldShowFileName(
                                                    displayTitle: displayTitle,
                                                    fileName: item.url.lastPathComponent,
                                                    hasMetadataTitle: hasMetadataTitle
                                                )
                                                let featureKeywords = rowMeta?.featureKeywords ?? []
                                                let abstractPreview = rowMeta?.abstractPreview.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                                let isSelectedRow = (item.url.path == effectiveSelectedPath)

                                                VStack(alignment: .leading, spacing: 6) {
                                                    HStack(alignment: .top, spacing: 10) {
                                                        HStack(alignment: .top, spacing: 8) {
                                                            Button {
                                                                _openSavedPaperInLibrary(item: item, folderURL: folderURL)
                                                            } label: {
                                                                Image(systemName: "doc.text")
                                                                    .font(.callout.weight(.semibold))
                                                                    .foregroundStyle(.blue)
                                                            }
                                                            .buttonStyle(.plain)

                                                            #if canImport(UIKit)
                                                            _Inf6SelectableAttributedTextView(
                                                                attributedText: _savedPaperSelectableCardAttributedText(
                                                                    displayTitle: displayTitle,
                                                                    fileName: item.url.lastPathComponent,
                                                                    showFileName: showFileName,
                                                                    featureKeywords: featureKeywords
                                                                )
                                                            )
                                                            .frame(maxWidth: .infinity, alignment: .leading)
                                                            #else
                                                            VStack(alignment: .leading, spacing: 6) {
                                                                Text(displayTitle)
                                                                    .font(.title3.weight(.semibold))
                                                                    .lineLimit(2)
                                                                    .textSelection(.enabled)

                                                                if showFileName {
                                                                    Text(item.url.lastPathComponent)
                                                                        .font(.callout.weight(.medium))
                                                                        .foregroundStyle(.blue)
                                                                        .lineLimit(1)
                                                                        .textSelection(.enabled)
                                                                }

                                                                if !featureKeywords.isEmpty {
                                                                    HStack(alignment: .center, spacing: 6) {
                                                                        ForEach(featureKeywords, id: \.self) { keyword in
                                                                            Text(keyword)
                                                                                .font(.callout.weight(.semibold))
                                                                                .foregroundStyle(.green)
                                                                                .lineLimit(1)
                                                                                .textSelection(.enabled)
                                                                        }
                                                                    }
                                                                }

                                                            }
                                                            .frame(maxWidth: .infinity, alignment: .leading)
                                                            #endif
                                                        }
                                                        .frame(maxWidth: .infinity, alignment: .topLeading)

                                                        Divider()
                                                            .frame(maxHeight: .infinity)

                                                        VStack(alignment: .leading, spacing: 6) {
                                                            let path = item.url.path
                                                            let isAbstractFilling = (_savedPaperAbstractFillInFlightPath == path)
                                                            let abstractFillError = _savedPaperAbstractFillErrorByPath[path]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                                                            if isAbstractFilling {
                                                                HStack(spacing: 8) {
                                                                    ProgressView().tint(.pink).scaleEffect(1.25)
                                                                        .controlSize(.small)
                                                                    Text(Inf6Lang.text("要旨を補完中です…", "Completing abstract..."))
                                                                        .font(.callout)
                                                                        .foregroundStyle(Color(red: 0.05, green: 0.20, blue: 0.45))
                                                                }
                                                            } else if !abstractPreview.isEmpty {
                                                                #if canImport(UIKit)
                                                                _Inf6SelectableTextView(
                                                                    text: abstractPreview,
                                                                    font: UIFont.preferredFont(forTextStyle: .callout),
                                                                    color: UIColor(red: 0.05, green: 0.20, blue: 0.45, alpha: 1.0),
                                                                    lineLimit: 6
                                                                )
                                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                                #else
                                                                Text(abstractPreview)
                                                                .font(.callout)
                                                                .foregroundStyle(Color(red: 0.05, green: 0.20, blue: 0.45))
                                                                .lineLimit(6)
                                                                .textSelection(.enabled)
                                                                #endif
                                                            }
                                                            if abstractPreview.isEmpty && !abstractFillError.isEmpty {
                                                                #if canImport(UIKit)
                                                                _Inf6SelectableTextView(
                                                                    text: abstractFillError,
                                                                    font: UIFont.preferredFont(forTextStyle: .caption1),
                                                                    color: .secondaryLabel,
                                                                    lineLimit: 0
                                                                )
                                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                                #else
                                                                Text(abstractFillError)
                                                                    .font(.caption)
                                                                    .foregroundStyle(.secondary)
                                                                    .textSelection(.enabled)
                                                                #endif
                                                            }

                                                            let sourceURLText = rowMeta?.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                                            if !sourceURLText.isEmpty {
                                                                if let sourceURL = URL(string: sourceURLText),
                                                                   let scheme = sourceURL.scheme?.lowercased(),
                                                                   (scheme == "http" || scheme == "https") {
                                                                    Button {
                                                                        _openURL(sourceURL)
                                                                    } label: {
                                                                        Text(sourceURLText)
                                                                            .font(.caption)
                                                                            .foregroundStyle(.blue)
                                                                            .lineLimit(1)
                                                                            .truncationMode(.middle)
                                                                    }
                                                                    .buttonStyle(.plain)
                                                                } else {
                                                                    Text(sourceURLText)
                                                                        .font(.caption)
                                                                        .foregroundStyle(.secondary)
                                                                        .lineLimit(1)
                                                                        .truncationMode(.middle)
                                                                        .textSelection(.enabled)
                                                                }
                                                            }

                                                            if isSelectedRow,
                                                               (rowMeta?.providerRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "") == "arxiv" {
                                                                let path = item.url.path
                                                                let latest = _savedPaperLatestByPath[path]
                                                                let isChecking = (_savedPaperLatestCheckInFlightPath == path)

                                                                HStack(spacing: 8) {
                                                                    if isChecking {
                                                                        HStack(spacing: 6) {
                                                                            ProgressView().tint(.pink).scaleEffect(1.25)
                                                                                .controlSize(.small)
                                                                            Text(Inf6Lang.text("最新版確認中", "Checking latest"))
                                                                                .font(.caption)
                                                                                .foregroundStyle(.secondary)
                                                                        }
                                                                    }
                                                                }

                                                                if let latest {
                                                                    if latest.hasUpdate {
                                                                        let localText = latest.localVersion.map { "v\($0)" } ?? Inf6Lang.text("不明", "unknown")
                                                                        let remoteText = latest.remoteVersion.map { "v\($0)" } ?? Inf6Lang.text("不明", "unknown")
                                                                        Text(
                                                                            Inf6Lang.text(
                                                                                "更新あり: 保存 \(localText) → 最新 \(remoteText)",
                                                                                "Update available: local \(localText) → latest \(remoteText)"
                                                                            )
                                                                        )
                                                                        .font(.caption)
                                                                        .foregroundStyle(.orange)
                                                                    } else if let local = latest.localVersion {
                                                                        Text(
                                                                            Inf6Lang.text(
                                                                                "最新版です（v\(local)）。",
                                                                                "Already latest (v\(local))."
                                                                            )
                                                                        )
                                                                        .font(.caption)
                                                                        .foregroundStyle(.secondary)
                                                                    } else {
                                                                        Text(Inf6Lang.text("最新版です。", "Already latest."))
                                                                            .font(.caption)
                                                                            .foregroundStyle(.secondary)
                                                                    }
                                                                }

                                                                let latestError = _savedPaperLatestErrorByPath[path]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                                                if !latestError.isEmpty {
                                                                    Text(latestError)
                                                                        .font(.caption)
                                                                        .foregroundStyle(.secondary)
                                                                        .textSelection(.enabled)
                                                                }
                                                            }
                                                        }
                                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                                    }
                                                }
                                                .textSelection(.enabled)
                                                .padding(10)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 10)
                                                        .fill(Color.blue.opacity(isSelectedRow ? 0.12 : 0.06))
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 10)
                                                        .stroke(Color.blue.opacity(isSelectedRow ? 0.34 : 0.14), lineWidth: 1)
                                                )
                                                .padding(.vertical, 2)
                                                .contentShape(Rectangle())
                                                .onAppear {
                                                    _savedPaperAutoFillAbstractIfNeeded(item: item, rowMeta: rowMeta, folderURL: folderURL)
                                                    if isSelectedRow {
                                                        _savedPaperAutoCheckLatestIfNeeded(item: item, rowMeta: rowMeta)
                                                    }
                                                }
                                                .onTapGesture {
                                                    _savedPapersSelectedItemPath = item.url.path
                                                    _savedPaperAutoCheckLatestIfNeeded(item: item, rowMeta: rowMeta)
                                                    _savedPaperAutoFillAbstractIfNeeded(item: item, rowMeta: rowMeta, folderURL: folderURL)
                                                }
                                            }
                                        }
                                        .padding(.vertical, 4)
                                    }
                                }
                            }

                            HStack(spacing: 10) {
                                Button(Inf6Lang.text("前へ", "Prev")) {
                                    _savedPapersListPage = max(1, safePage - 1)
                                }
                                .buttonStyle(.bordered)
                                .disabled(safePage <= 1 || totalCount == 0)

                                Button(Inf6Lang.text("次へ", "Next")) {
                                    _savedPapersListPage = min(pageCount, safePage + 1)
                                }
                                .buttonStyle(.bordered)
                                .disabled(safePage >= pageCount || totalCount == 0)

                                let startDisplay = totalCount == 0 ? 0 : (start + 1)
                                Text(
                                    Inf6Lang.text(
                                        "ページ \(safePage)/\(pageCount)  表示: \(startDisplay)-\(end) / \(totalCount)",
                                        "Page \(safePage)/\(pageCount)  Showing: \(startDisplay)-\(end) / \(totalCount)"
                                    )
                                )
                                .font(.callout)
                                .foregroundStyle(.secondary)

                                Spacer()
                            }
                        }
                        .padding(.top, 4)
                        .textSelection(.enabled)
                    } else {
                        _manageTopMappingSectionView()
                    }
                }
            }
            .padding(.vertical, 4)
            }


            if _activePane == .search, !_results.isEmpty {
                let discoveredSites = _discoveredTargetSites(from: _results)

                if !discoveredSites.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(Inf6Lang.text("対象サイト候補", "Target site candidates"))
                                .font(.headline)
                            Text("(\(discoveredSites.count))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }

                        ForEach(discoveredSites.prefix(12)) { site in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(site.host)
                                        .font(.callout.weight(.semibold))
                                        .textSelection(.enabled)
                                    Text(
                                        Inf6Lang.text(
                                            "検出件数: \(site.hitCount)",
                                            "Hits: \(site.hitCount)"
                                        )
                                    )
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    Text(site.sampleURLString)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .textSelection(.enabled)
                                }

                                Spacer(minLength: 0)

                                Button {
                                    if !_copyToPasteboard(site.sampleURLString) {
                                        _errorText = Inf6Lang.text(
                                            "この環境ではコピーできません。",
                                            "Copy is unavailable on this platform."
                                        )
                                    }
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.footnote)
                                }
                                .buttonStyle(.plain)
                                .help(Inf6Lang.text("URLをコピー", "Copy URL"))
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.secondary.opacity(0.08))
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }

                ForEach(_results, id: \.id) { r in
                    VStack(alignment: .leading, spacing: 6) {
                        if !r.subtitle.isEmpty {
                            Text(r.subtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        if let url = r.landingURL {
                            HStack(spacing: 8) {
                                Text(url.absoluteString)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(2)

                                Button {
                                    if !_copyToPasteboard(url.absoluteString) {
                                        _issuesByResultID[r.id] = Inf6Lang.text(
                                            "この環境ではコピーできません。",
                                            "Copy is unavailable on this platform."
                                        )
                                    }
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                            .font(.footnote)
                                }
                                .buttonStyle(.plain)
                                .help(Inf6Lang.text("コピー", "Copy"))
                            }
                        } else {
                            Text(Inf6Lang.text("詳細ページURLがありません。", "Details URL is missing."))
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }

                        if let pdf = r.pdfURL {
                            HStack(alignment: .top, spacing: 10) {
                                // --- Inf6PaperSaveButton implementation replaced below ---
                                Inf6PaperSaveButton(
                                    result: r,
                                    pdfURL: pdf,
                                    saveFolderURL: folderURL,
                                    saveFolderErrorText: folderError
                                )

                                Button {
                                    do {
                                        let fileName = try Inf6PaperStorage.safeFileName(title: r.title, fallbackID: r.id)
                                        guard let folder = folderURL else {
                                            _issuesByResultID[r.id] = Inf6Lang.text(
                                                "保存先が未選択です。上部の『PDF保存先』で選択してください。",
                                                "Save destination is not selected. Choose it in the 'PDF destination' header."
                                            )
                                            return
                                        }
                                        let classificationDir = Inf6PaperSaveShared.classificationDirectoryName(
                                            title: r.title,
                                            abstractText: r.abstractText,
                                            fallbackID: r.id,
                                            landingURL: r.landingURL,
                                            pdfURL: r.pdfURL
                                        )
                                        let dest = folder
                                            .appendingPathComponent(classificationDir, isDirectory: true)
                                            .appendingPathComponent(fileName)
                                        if !_copyToPasteboard(dest.path) {
                                            _issuesByResultID[r.id] = Inf6Lang.text(
                                                "この環境ではコピーできません。",
                                                "Copy is unavailable on this platform."
                                            )
                                        }
                                    } catch {
                                        _issuesByResultID[r.id] = error.localizedDescription
                                    }
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.footnote)
                                }
                                .buttonStyle(.plain)
                                .help(Inf6Lang.text("パスをコピー", "Copy path"))
                            }
                        } else if let url = r.landingURL {
                            Link(Inf6Lang.text("詳細ページを開く", "Open details page"), destination: url)
                                .font(.footnote)
                        } else {
                            Text(Inf6Lang.text("詳細ページURLがありません。", "Details URL is missing."))
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }

                        if let issue = _issuesByResultID[r.id], !issue.isEmpty {
                            Text(issue)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .task {
            await _bootstrapOnce()
            await MainActor.run {
                _reloadPapersDestinationRows()
            }
        }
        .modifier(_Inf6OnChangeCompat(value: _source) {
            Task { @MainActor in
                _directArxivID = ""
                _directArxivInput = ""
                _directArxivInputError = nil
                _directSourceQueryInput = ""
                _directSourceQueryInputError = nil
                _scheduleReloadFields(resetSelection: true)
                _reloadPapersDestinationRows()
            }
        })
        .modifier(_Inf6OnChangeCompat(value: _selectedFieldID) {
            Task { @MainActor in
                _scheduleLoadPapersForSelectedField()
            }
        })
        .modifier(_Inf6OnChangeCompat(value: _directArxivID) {
            Task { @MainActor in
                let direct = _directArxivID.trimmingCharacters(in: .whitespacesAndNewlines)
                if !direct.isEmpty {
                    _directArxivInput = direct
                }
                _scheduleLoadPapersForSelectedField()
            }
        })
        .fileImporter(
            isPresented: $_showPapersFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { res in
            switch res {
            case .success(let urls):
                guard let u = urls.first else {
                    _papersFolderErrorText = Inf6Lang.text("フォルダが選択されませんでした。", "No folder was selected.")
                    _papersFolderStatusText = nil
                    _papersFolderPickerTargetSourceRaw = nil
                    return
                }

                let started = u.startAccessingSecurityScopedResource()
                guard started else {
                    _papersFolderErrorText = Inf6Lang.text(
                        "フォルダへのアクセス権を開始できませんでした。もう一度『PDF保存先』で選択してください。",
                        "Failed to start accessing the selected folder. Please choose it again in 'PDF destination'."
                    )
                    _papersFolderStatusText = nil
                    _papersFolderPickerTargetSourceRaw = nil
                    return
                }
                defer { u.stopAccessingSecurityScopedResource() }

                guard _canCreateSubfolderUnderPapersDestination(folderURL: u) else {
                    _papersFolderErrorText = Inf6Lang.text(
                        "選択フォルダ配下にサブフォルダを作成できませんでした。書込可能な保存先フォルダを選択してください。",
                        "Cannot create subfolders under the selected folder. Please choose a writable storage folder."
                    )
                    _papersFolderStatusText = nil
                    _papersFolderPickerTargetSourceRaw = nil
                    return
                }

                do {
                    // Persist a minimal bookmark and rely on `startAccessingSecurityScopedResource()` at access time.
                    #if os(macOS)
                    let b = try u.bookmarkData(options: [.minimalBookmark, .withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                    #else
                    let b = try u.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                    #endif
                    let bookmarkB64 = b.base64EncodedString()
                    let platformRaw = _isIOSAppOnMac ? "iosonmac" : "ios"
                    let fallbackSourceRaw = _source.rawValue
                    let targetSourceRaw = (_papersFolderPickerTargetSourceRaw ?? fallbackSourceRaw)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let effectiveSourceRaw = targetSourceRaw.isEmpty ? fallbackSourceRaw : targetSourceRaw
                    _setPapersDestinationBookmarkB64(
                        sourceRaw: effectiveSourceRaw,
                        platformRaw: platformRaw,
                        bookmarkB64: bookmarkB64
                    )
                    if effectiveSourceRaw == _source.rawValue {
                        _papersSaveFolderBookmarkB64_active = bookmarkB64
                    }
                    _papersFolderErrorText = nil
                    _recordPapersDestinationSelection(
                        folderURL: u,
                        sourceRaw: effectiveSourceRaw,
                        bookmarkB64: bookmarkB64
                    )
                    _papersFolderStatusText = Inf6Lang.text(
                        _papersDestinationSourceLabel(effectiveSourceRaw) + " のマッピングを " + u.lastPathComponent + " に更新しました。",
                        "Updated mapping for " + _papersDestinationSourceLabel(effectiveSourceRaw) + " to " + u.lastPathComponent + "."
                    )
                    _papersFolderAccessErrorText = nil
                    _papersFolderAccessOK = nil
                    _reloadPapersDestinationRows()
                    _papersFolderPickerTargetSourceRaw = nil
                    if _activePane == .manage && _showSavedPapersListSheet {
                        Task { @MainActor in
                            _reloadSavedPapersList(folderURL: u)
                        }
                    }
                } catch {
                    _papersFolderErrorText = error.localizedDescription
                    _papersFolderStatusText = nil
                    _papersFolderPickerTargetSourceRaw = nil
                }

            case .failure(let e):
                _papersFolderErrorText = e.localizedDescription
                _papersFolderStatusText = nil
                _papersFolderPickerTargetSourceRaw = nil
            }
        }
        .fullScreenCover(isPresented: $_showDestinationChooserSheet) {
            _destinationChooserOverlayView()
                .interactiveDismissDisabled(true)
        }
    }

    private var _toolsTileColumns: [GridItem] {
        if _horizontalSizeClass == .compact {
            return [GridItem(.flexible(), spacing: 12)]
        }
        return [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
        ]
    }

    private func _toolsPaneAccent(_ pane: _ToolsPane) -> Color {
        switch pane {
        case .search: return .blue
        case .destination: return .teal
        case .manage: return .indigo
        case .paperChat: return .pink
        }
    }

    private func _toolsPaneIconName(_ pane: _ToolsPane) -> String {
        switch pane {
        case .search: return "magnifyingglass"
        case .destination: return "folder"
        case .manage: return "books.vertical"
        case .paperChat: return "sparkles"
        }
    }

    private func _toolsPaneTitle(_ pane: _ToolsPane) -> String {
        switch pane {
        case .search: return Inf6Lang.text("論文検索", "Search")
        case .destination: return Inf6Lang.text("保存先管理", "Destination Management")
        case .manage: return Inf6Lang.text("論文管理", "Manage")
        case .paperChat: return Inf6Lang.text("論文サーベイ", "Paper Survey")
        }
    }

    private func _toolsPaneSummary(_ pane: _ToolsPane) -> String {
        switch pane {
        case .search:
            return Inf6Lang.text("検索条件と検索結果を扱います。", "Search conditions and results.")
        case .destination:
            return Inf6Lang.text("保存先フォルダを管理します。", "Manage destination folders.")
        case .manage:
            return Inf6Lang.text("保存済みPDFを管理します。", "Manage saved PDFs.")
        case .paperChat:
            return Inf6Lang.text("論文サーベイ対話を開きます。", "Open paper survey chat.")
        }
    }

    @ViewBuilder
    private func _toolsPaneTile(_ pane: _ToolsPane) -> some View {
        let isActive = _activePane == pane
        let accent = _toolsPaneAccent(pane)

        Button {
            Task { @MainActor in
                _selectToolsPane(pane)
            }
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(isActive ? Color.white.opacity(0.22) : accent.opacity(0.20))
                        Image(systemName: _toolsPaneIconName(pane))
                            .font(.system(size: _toolsTileIconSize, weight: .bold))
                            .foregroundStyle(isActive ? .white : accent)
                    }
                    .frame(width: _toolsTileIconFrame, height: _toolsTileIconFrame)

                    Text(_toolsPaneTitle(pane))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(isActive ? .white : .primary)
                        .minimumScaleFactor(0.92)

                    Spacer(minLength: 0)
                }

                Text(_toolsPaneSummary(pane))
                    .font(.body.weight(.medium))
                    .foregroundStyle(isActive ? Color.white.opacity(0.90) : .secondary)
                    .lineLimit(2)

                if pane == .destination {
                    Text(
                        Inf6Lang.text("現在: ", "Current: ")
                        + _topPageCurrentDestinationName()
                    )
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isActive ? Color.white.opacity(0.95) : .primary)
                    .lineLimit(1)
                }
            }
            .padding(_toolsTilePadding)
            .frame(maxWidth: .infinity, minHeight: _toolsTileMinHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isActive ? accent : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isActive ? accent.opacity(0.85) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func _destinationChooserOverlayView() -> some View {
        GeometryReader { proxy in
            let cardWidth = min(max(proxy.size.width - 20, 320), 700)
            let cardHeight = min(max(proxy.size.height - 28, 360), 640)

            ZStack {
                Color.black.opacity(0.16)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {}

                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Button(Inf6Lang.text("閉じる", "Close")) {
                            _showDestinationChooserSheet = false
                        }
                        .buttonStyle(.bordered)

                        Spacer(minLength: 0)

                        Text(
                            Inf6Lang.text("保存先選択", "Choose destination")
                            + " ("
                            + _papersDestinationSourceLabel(_source.rawValue)
                            + ")"
                        )
                            .font(.title2.weight(.bold))
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        Color.clear
                            .frame(width: 74, height: 1)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                    Divider()

                    ScrollView {
                        _destinationChooserCardContentView()
                            .padding(16)
                    }
                }
                .frame(width: cardWidth, height: cardHeight, alignment: .top)
                .background(
                    RoundedRectangle(cornerRadius: 22)
                        .fill(_destinationChooserCardBackgroundColor())
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(Color.black.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.16), radius: 18, x: 0, y: 8)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .zIndex(1000)
    }

    private func _destinationChooserCardBackgroundColor() -> Color {
        #if canImport(UIKit)
        return Color(uiColor: .systemBackground)
        #else
        return Color.white
        #endif
    }

    @ViewBuilder
    private func _destinationChooserCardContentView() -> some View {
        let currentPath = _resolvePapersSaveFolderURLOrError().url?.path ?? ""
        let availabilityByPath = Dictionary(
            uniqueKeysWithValues: _papersDestinationRows.map { row in
                (row.path, _canUseDestinationPath(row.path))
            }
        )
        let currentRow = _papersDestinationRows.first(where: { $0.path == currentPath })
        let selectableRows = _papersDestinationRows.filter { row in
            guard row.path != currentPath else { return false }
            return availabilityByPath[row.path] ?? false
        }

        VStack(alignment: .leading, spacing: 10) {
            if _papersDestinationRows.isEmpty {
                Text(Inf6Lang.text("保存先履歴はありません。", "No destination history yet."))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else {
                if let currentRow {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(
                            Inf6Lang.text("現在のマッピング", "Current mapping")
                            + " ("
                            + _papersDestinationSourceLabel(_source.rawValue)
                            + ")"
                        )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        _Inf6PapersDestinationRowCard(
                            folderName: _destinationFolderName(path: currentRow.path),
                            isCurrent: true,
                            sourceText: Inf6Lang.text("検索元: ", "Source: ") + _papersDestinationSourceLabel(_source.rawValue),
                            platformText: Inf6Lang.text("端末: ", "Platform: ") + currentRow.platformLabels.joined(separator: " / "),
                            pathText: currentRow.path
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(Inf6Lang.text("選択可能", "Available"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if selectableRows.isEmpty {
                        Text(Inf6Lang.text("この端末で選択可能な保存先がありません。", "No selectable destination is available on this device."))
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }

                ForEach(selectableRows) { row in
                    Button {
                        if _setCurrentDestinationFromRow(row) {
                            _showDestinationChooserSheet = false
                        }
                    } label: {
                        _Inf6PapersDestinationRowCard(
                            folderName: _destinationFolderName(path: row.path),
                            isCurrent: false,
                            sourceText: Inf6Lang.text("検索元: ", "Source: ") + _papersDestinationSourceLabel(_source.rawValue),
                            platformText: Inf6Lang.text("端末: ", "Platform: ") + row.platformLabels.joined(separator: " / "),
                            pathText: row.path
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func _destinationListSectionView() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            _destinationMappingSectionView()
        }
        .padding(.top, 4)
    }

    private func _destinationMappingSectionView() -> some View {
        let platformLabel = _papersDestinationPlatformLabel(_isIOSAppOnMac ? "iosonmac" : "ios")
        let rows = _destinationMappingRows()

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Inf6Lang.text("マッピング", "Mappings"))
                    .font(.title3.weight(.bold))
                    .textSelection(.enabled)

                Text("(" + platformLabel + ")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            ForEach(rows) { row in
                _destinationMappingRowView(row)
            }
        }
    }

    private func _destinationMappingRowView(_ row: _PapersDestinationMappingRow) -> some View {
        let pathText = row.path.isEmpty ? Inf6Lang.text("未設定", "Not set") : row.path
        let pathColor: Color = row.isConfigured ? .secondary : .red
        let canOpenFromManage = _activePane == .manage && row.isConfigured
        let canManageMapping = (_activePane == .destination || _activePane == .manage)

        let card = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(row.sourceLabel)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .textSelection(.enabled)

                if row.isActiveSource {
                    Text(Inf6Lang.text("選択中", "Selected"))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(0.14))
                        .clipShape(Capsule())
                }

                Spacer(minLength: 0)

                if canManageMapping {
                    HStack(spacing: 6) {
                        Button {
                            _openMappingFolderPicker(for: row.sourceRaw)
                        } label: {
                            Text(Inf6Lang.text("変更", "Edit"))
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)

                        Button(role: .destructive) {
                            _removeDestinationMappingRow(row)
                        } label: {
                            Text(Inf6Lang.text("削除", "Delete"))
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .disabled(!row.isConfigured)
                    }
                }
            }

            Text(Inf6Lang.text("ディレクトリ: ", "Directory: ") + row.directoryName)
                .font(.callout.weight(.medium))
                .textSelection(.enabled)

            if canOpenFromManage {
                Text(Inf6Lang.text("タップで論文一覧を開く", "Tap to open paper list"))
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .textSelection(.enabled)
            }

            Text(pathText)
                .font(.callout)
                .foregroundStyle(pathColor)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.blue.opacity(0.05))
        )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.blue.opacity(0.14), lineWidth: 1)
            )
            .contentShape(Rectangle())

        return card
            .onTapGesture {
                guard canOpenFromManage else { return }
                _openManageSavedPapersListForMappingRow(row)
            }
    }

    @MainActor
    private func _openMappingFolderPicker(for sourceRaw: String) {
        _papersFolderErrorText = nil
        _papersFolderStatusText = nil
        _papersFolderPickerTargetSourceRaw = sourceRaw
        _showPapersFolderPicker = true
    }

    @MainActor
    private func _removeDestinationMappingRow(_ row: _PapersDestinationMappingRow) {
        let platformRaw = _isIOSAppOnMac ? "iosonmac" : "ios"
        _setPapersDestinationBookmarkB64(
            sourceRaw: row.sourceRaw,
            platformRaw: platformRaw,
            bookmarkB64: ""
        )

        var entries = _loadPapersDestinationHistory()
        entries.removeAll { entry in
            entry.sourceRaw == row.sourceRaw && entry.platformRaw == platformRaw
        }
        _savePapersDestinationHistory(entries)

        if row.sourceRaw == _source.rawValue {
            _papersSaveFolderBookmarkB64_active = ""
            _papersFolderAccessErrorText = nil
            _papersFolderAccessOK = nil
            if _activePane == .manage && _showSavedPapersListSheet {
                _showSavedPapersListSheet = false
                _reloadSavedPapersList(folderURL: nil)
            }
        }

        _reloadPapersDestinationRows()
        _papersFolderErrorText = nil
        _papersFolderStatusText = Inf6Lang.text(
            _papersDestinationSourceLabel(row.sourceRaw) + " のマッピングを削除しました。",
            "Removed mapping for " + _papersDestinationSourceLabel(row.sourceRaw) + "."
        )
    }

    @ViewBuilder
    private func _destinationListSectionHeaderView() -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(
                Inf6Lang.text("保存先履歴", "Destination history")
                + " ("
                + _papersDestinationSourceLabel(_source.rawValue)
                + ")"
            )
                .font(.title3.weight(.bold))
                .textSelection(.enabled)

            Spacer(minLength: 10)

            Text(Inf6Lang.text("一覧から削除しても、保存先フォルダ上のフォルダやPDFは削除されません", "Removing from this list does not delete folders or PDFs in the storage folder"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 520, alignment: .trailing)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func _destinationListSectionRowsView() -> some View {
        if _papersDestinationRows.isEmpty {
            Text(Inf6Lang.text("保存先履歴はありません。", "No destination history yet."))
                .font(.body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } else {
            ForEach(_papersDestinationRows) { row in
                _destinationListRowView(row)
            }
        }
    }

    @ViewBuilder
    private func _destinationListRowView(_ row: _PapersDestinationRow) -> some View {
        let folderName = _destinationFolderName(path: row.path)
        let sourceText = Inf6Lang.text("検索元: ", "Source: ") + _papersDestinationSourceLabel(_source.rawValue)
        let platformText = Inf6Lang.text("端末: ", "Platform: ") + row.platformLabels.joined(separator: " / ")

        ZStack(alignment: .trailing) {
            _Inf6PapersDestinationRowCard(
                folderName: folderName,
                isCurrent: row.isCurrent,
                sourceText: sourceText,
                platformText: platformText,
                pathText: row.path
            )
            .padding(.trailing, 52)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(role: .destructive) {
                _destinationRowPendingDeletion = row
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(14), weight: .bold))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .background(
                RoundedRectangle(cornerRadius: 17)
                    .fill(Color.red.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 17)
                    .stroke(Color.red.opacity(0.28), lineWidth: 1)
            )
            .padding(.trailing, 6)
            .help(Inf6Lang.text("一覧から削除（フォルダ自体は削除しません）", "Remove from list only (folder itself is not deleted)"))
            .accessibilityLabel(Inf6Lang.text("保存先を一覧から削除", "Remove destination from list"))
        }
    }

    private func _destinationFolderName(path: String) -> String {
        let folderName = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
        if !folderName.isEmpty { return folderName }
        return path
    }

    private func _topPageCurrentDestinationName() -> String {
        let resolved = _resolvePapersSaveFolderURLOrError()
        if let folderURL = resolved.url {
            let name = folderURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
            return folderURL.path
        }
        return Inf6Lang.text("未設定", "Not set")
    }

    private func _matchingBookmarkSlotsForDestinationPath(_ path: String) -> [(sourceRaw: String, platformRaw: String, bookmarkB64: String)] {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else { return [] }
        let sourceRaw = _source.rawValue

        var dedupe: Set<String> = []
        var out: [(sourceRaw: String, platformRaw: String, bookmarkB64: String)] = []

        for entry in _loadPapersDestinationHistory() {
            guard entry.sourceRaw == sourceRaw else { continue }
            let entryPath = entry.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard entryPath == targetPath else { continue }
            let bookmarkB64 = (entry.bookmarkB64 ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bookmarkB64.isEmpty else { continue }
            let key = entry.sourceRaw + "|" + entry.platformRaw + "|" + bookmarkB64
            if dedupe.insert(key).inserted {
                out.append((entry.sourceRaw, entry.platformRaw, bookmarkB64))
            }
        }

        for slot in _papersDestinationBookmarkSlots() {
            guard slot.sourceRaw == sourceRaw else { continue }
            let bookmarkB64 = slot.bookmarkB64.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bookmarkB64.isEmpty else { continue }
            guard let resolved = _resolvePapersFolderURLFromBookmarkB64(bookmarkB64) else { continue }
            if resolved.path == targetPath {
                let key = slot.sourceRaw + "|" + slot.platformRaw + "|" + bookmarkB64
                if dedupe.insert(key).inserted {
                    out.append(slot)
                }
            }
        }
        return out
    }

    private func _orderedDestinationSelectionSlots(
        _ slots: [(sourceRaw: String, platformRaw: String, bookmarkB64: String)],
        sourceRaw: String,
        platformRaw: String
    ) -> [(sourceRaw: String, platformRaw: String, bookmarkB64: String)] {
        var exact: [(sourceRaw: String, platformRaw: String, bookmarkB64: String)] = []
        var samePlatform: [(sourceRaw: String, platformRaw: String, bookmarkB64: String)] = []
        var others: [(sourceRaw: String, platformRaw: String, bookmarkB64: String)] = []
        exact.reserveCapacity(slots.count)
        samePlatform.reserveCapacity(slots.count)
        others.reserveCapacity(slots.count)

        for slot in slots {
            if slot.sourceRaw == sourceRaw && slot.platformRaw == platformRaw {
                exact.append(slot)
            } else if slot.platformRaw == platformRaw {
                samePlatform.append(slot)
            } else {
                others.append(slot)
            }
        }

        return exact + samePlatform + others
    }

    private func _canUseDestinationPath(_ path: String) -> Bool {
        let sourceRaw = _source.rawValue
        let platformRaw = _isIOSAppOnMac ? "iosonmac" : "ios"
        let slots = _matchingBookmarkSlotsForDestinationPath(path)
        let orderedSlots = _orderedDestinationSelectionSlots(slots, sourceRaw: sourceRaw, platformRaw: platformRaw)

        for candidate in orderedSlots {
            if _canAccessPapersDestination(bookmarkB64: candidate.bookmarkB64) {
                return true
            }
        }

        let folderURL = URL(fileURLWithPath: path, isDirectory: true)
        guard let generatedBookmark = _createPapersDestinationBookmarkB64(folderURL: folderURL) else {
            return false
        }
        return _canAccessPapersDestination(bookmarkB64: generatedBookmark)
    }

    @MainActor
    private func _setCurrentDestinationFromRow(_ row: _PapersDestinationRow) -> Bool {
        if row.isCurrent { return false }

        let sourceRaw = _source.rawValue
        let platformRaw = _isIOSAppOnMac ? "iosonmac" : "ios"
        let slots = _matchingBookmarkSlotsForDestinationPath(row.path)
        let orderedSlots = _orderedDestinationSelectionSlots(slots, sourceRaw: sourceRaw, platformRaw: platformRaw)

        var selected: (sourceRaw: String, platformRaw: String, bookmarkB64: String)? = nil
        for candidate in orderedSlots {
            if _canAccessPapersDestination(bookmarkB64: candidate.bookmarkB64) {
                selected = candidate
                break
            }
        }

        if selected == nil {
            let folderURL = URL(fileURLWithPath: row.path, isDirectory: true)
            if let generatedBookmark = _createPapersDestinationBookmarkB64(folderURL: folderURL),
               _canAccessPapersDestination(bookmarkB64: generatedBookmark) {
                selected = (sourceRaw: sourceRaw, platformRaw: platformRaw, bookmarkB64: generatedBookmark)
            }
        }

        guard let selected else {
            _papersFolderErrorText = Inf6Lang.text(
                "この保存先は現端末で利用できません。『マッピング追加…』で同じ保存先フォルダを追加し直してください。",
                "This destination is not usable on this device. Please add the same storage folder again via 'Add mapping...'."
            )
            _papersFolderAccessErrorText = nil
            _papersFolderAccessOK = nil
            return false
        }

        _papersSaveFolderBookmarkB64_active = selected.bookmarkB64
        guard let folderURL = _resolvePapersFolderURLFromBookmarkB64(selected.bookmarkB64) else {
            _papersFolderErrorText = Inf6Lang.text(
                "保存先ブックマークの解決に失敗しました。『マッピング追加…』で追加し直してください。",
                "Failed to resolve destination bookmark. Add it again via 'Add mapping...'."
            )
            return false
        }

        _papersFolderErrorText = nil
        _recordPapersDestinationSelection(folderURL: folderURL, bookmarkB64: selected.bookmarkB64)
        _validatePapersFolderAccess(folderURL: folderURL)
        _reloadPapersDestinationRows()

        if _activePane == .manage && _showSavedPapersListSheet {
            Task { @MainActor in
                _reloadSavedPapersList(folderURL: folderURL)
            }
        }
        return true
    }

    @MainActor
    private func _openDestinationChooserSheetFromManage() {
        if _showDestinationChooserSheet { return }
        _reloadPapersDestinationRows()
        _showDestinationChooserSheet = true
    }

    @MainActor
    private func _openManageSavedPapersList() {
        let resolved = _resolvePapersSaveFolderURLOrError()
        if let errorText = resolved.error, !errorText.isEmpty {
            _papersFolderErrorText = errorText
            _showSavedPapersListSheet = false
            return
        }
        guard let folderURL = resolved.url else {
            _papersFolderErrorText = Inf6Lang.text(
                "保存先が未設定です。『保存先管理』で設定してください。",
                "Destination is not set. Configure it via destination management."
            )
            _showSavedPapersListSheet = false
            return
        }
        _papersFolderErrorText = nil
        _showSavedPapersListSheet = true
        _reloadSavedPapersList(folderURL: folderURL)
    }

    @MainActor
    private func _openManageSavedPapersListForMappingRow(_ row: _PapersDestinationMappingRow) {
        guard let source = Inf6PaperSourceKind(rawValue: row.sourceRaw) else {
            _papersFolderErrorText = Inf6Lang.text(
                "検索元の切替に失敗しました。",
                "Failed to switch search source."
            )
            return
        }
        _source = source
        _reloadPapersDestinationRows()
        _openManageSavedPapersList()
    }

    @ViewBuilder
    private func _manageTopMappingSectionView() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            _destinationMappingSectionView()

            Text(
                Inf6Lang.text(
                    "マッピング行をタップすると、その検索元の論文一覧を開きます。",
                    "Tap a mapping row to open that source's paper list."
                )
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func _savedPapersAbstractPanelView(
        selectedItem: _SavedPaperListItem?,
        selectedRowMeta: _SavedPaperRowMeta?
    ) -> some View {
        let abstractLabel = Inf6Lang.text("論文要旨", "Paper abstract")

        VStack(alignment: .leading, spacing: 10) {
            Text(abstractLabel)
                .font(.title3.weight(.bold))
                .textSelection(.enabled)

            if let selectedItem {
                let fallbackTitle = selectedItem.url.lastPathComponent
                let displayTitle = {
                    let title = selectedRowMeta?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return title.isEmpty ? fallbackTitle : title
                }()
                let provider = selectedRowMeta?.providerLabel.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let featureKeywords = selectedRowMeta?.featureKeywords ?? []
                let abstractText = selectedRowMeta?.abstractText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                Text(displayTitle)
                    .font(.headline.weight(.semibold))
                    .textSelection(.enabled)

                if !provider.isEmpty {
                    Text(provider)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if !featureKeywords.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .center, spacing: 6) {
                            ForEach(featureKeywords, id: \.self) { keyword in
                                Text(keyword)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule()
                                            .fill(Color.green.opacity(0.12))
                                    )
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                ScrollView {
                    if !abstractText.isEmpty {
                        #if canImport(UIKit)
                        _Inf6SelectableTextView(
                            text: abstractText,
                            font: UIFont.preferredFont(forTextStyle: .body),
                            color: UIColor(red: 0.05, green: 0.20, blue: 0.45, alpha: 1.0),
                            lineLimit: 0
                        )
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        #else
                        Text(abstractText)
                            .font(.body)
                            .foregroundStyle(Color(red: 0.05, green: 0.20, blue: 0.45))
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .textSelection(.enabled)
                        #endif
                    } else {
                        let selectedPath = selectedItem.url.path
                        let isAbstractFilling = (_savedPaperAbstractFillInFlightPath == selectedPath)
                        let abstractFillError = _savedPaperAbstractFillErrorByPath[selectedPath]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                        if isAbstractFilling {
                            HStack(spacing: 8) {
                                ProgressView().tint(.pink).scaleEffect(1.25)
                                    .controlSize(.small)
                                Text(Inf6Lang.text("要旨を補完中です…", "Completing abstract..."))
                                    .font(.callout)
                                    .foregroundStyle(Color(red: 0.05, green: 0.20, blue: 0.45))
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        } else if !abstractFillError.isEmpty {
                            #if canImport(UIKit)
                            _Inf6SelectableTextView(
                                text: abstractFillError,
                                font: UIFont.preferredFont(forTextStyle: .callout),
                                color: .secondaryLabel,
                                lineLimit: 0
                            )
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            #else
                            Text(abstractFillError)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .textSelection(.enabled)
                            #endif
                        }
                    }
                }
            } else {
                Text(Inf6Lang.text("論文を選択してください。", "Please select a paper."))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.blue.opacity(0.15), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func _otherGroupActionButton(groupLabel: String, folderURL: URL?) -> some View {
        let othersLabel = Inf6Lang.text("その他", "Others")

        if groupLabel == othersLabel {
            let isBusy = _isLoadingFields
                || _isLoadingPapers
                || _isGeneratingSavedPaperMetadataJSON

            Button {
                guard let folderURL else { return }
                Task { @MainActor in
                    await _generateMissingSavedPaperMetadataJSON(folderURL: folderURL)
                }
            } label: {
                if _isGeneratingSavedPaperMetadataJSON {
                    HStack(spacing: 6) {
                        ProgressView().tint(.pink).scaleEffect(1.25)
                            .controlSize(.small)
                        Text(Inf6Lang.text("分類更新中", "Updating classification"))
                    }
                } else {
                    Text(Inf6Lang.text("その他を分類更新", "Update Others"))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy || folderURL == nil)
            .help(Inf6Lang.text("この『その他』グループだけを対象に、JSON生成とID名付与を自動実行します。", "Run JSON generation and id-based rename for this Others group."))
        }
    }

    private func _savedPapersSortLabel(_ mode: _SavedPapersSortMode) -> String {
        switch mode {
        case .corpusVector:
            return Inf6Lang.text("分類順", "By classification")
        case .fileNameAsc:
            return Inf6Lang.text("ファイル名順", "Filename")
        }
    }

    private func _savedPapersPDFSignature(items: [_SavedPaperListItem]) -> String {
        let classificationRulesVersion = "classification-rules-v12"
        if items.isEmpty { return classificationRulesVersion + "\n0" }
        let names = items.map { item in
            item.url.lastPathComponent
        }
        .joined(separator: "\n")
        return classificationRulesVersion + "\n" + names
    }

    private func _papersDestinationSourceLabel(_ sourceRaw: String) -> String {
        switch sourceRaw {
        case "arxiv":
            return "arXiv"
        case "pubmed":
            return "PubMed"
        case "acl":
            return "ACL Anthology"
        case "isca":
            return "ISCA Archive"
        case "openalex":
            return "OpenAlex"
        default:
            return sourceRaw
        }
    }

    private func _papersDestinationPlatformLabel(_ platformRaw: String) -> String {
        switch platformRaw {
        case "ios":
            return Inf6Lang.text("iPhone/iPad", "iPhone/iPad")
        case "iosonmac":
            return Inf6Lang.text("Designed for iPad(Mac)", "Designed for iPad (Mac)")
        default:
            return platformRaw
        }
    }

    private func _papersDestinationBookmarkSlots() -> [(sourceRaw: String, platformRaw: String, bookmarkB64: String)] {
        [
            ("arxiv", "ios", _papersSaveFolderBookmarkB64_arxiv_iOS),
            ("arxiv", "iosonmac", _papersSaveFolderBookmarkB64_arxiv_iOSOnMac),
            ("pubmed", "ios", _papersSaveFolderBookmarkB64_pubmed_iOS),
            ("pubmed", "iosonmac", _papersSaveFolderBookmarkB64_pubmed_iOSOnMac),
            ("acl", "ios", _papersSaveFolderBookmarkB64_acl_iOS),
            ("acl", "iosonmac", _papersSaveFolderBookmarkB64_acl_iOSOnMac),
            ("isca", "ios", _papersSaveFolderBookmarkB64_isca_iOS),
            ("isca", "iosonmac", _papersSaveFolderBookmarkB64_isca_iOSOnMac),
            ("openalex", "ios", _papersSaveFolderBookmarkB64_openalex_iOS),
            ("openalex", "iosonmac", _papersSaveFolderBookmarkB64_openalex_iOSOnMac),
        ]
    }

    private func _bookmarkForSourceAndPlatform(sourceRaw: String, platformRaw: String) -> String {
        for slot in _papersDestinationBookmarkSlots() {
            if slot.sourceRaw == sourceRaw && slot.platformRaw == platformRaw {
                return slot.bookmarkB64.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }

    private func _latestDestinationHistoryPath(sourceRaw: String, platformRaw: String) -> String {
        let latest = _loadPapersDestinationHistory()
            .filter { $0.sourceRaw == sourceRaw && $0.platformRaw == platformRaw }
            .sorted { $0.selectedAt > $1.selectedAt }
            .first
        return latest?.path.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func _destinationMappingRows() -> [_PapersDestinationMappingRow] {
        let platformRaw = _isIOSAppOnMac ? "iosonmac" : "ios"
        let platformLabel = _papersDestinationPlatformLabel(platformRaw)
        let sourceOrder = ["arxiv", "pubmed", "acl", "isca", "openalex"]

        return sourceOrder.map { sourceRaw in
            let bookmark = _bookmarkForSourceAndPlatform(sourceRaw: sourceRaw, platformRaw: platformRaw)
            let resolvedPath: String = {
                if !bookmark.isEmpty,
                   let url = _resolvePapersFolderURLFromBookmarkB64(bookmark) {
                    let path = url.path.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !path.isEmpty { return path }
                }
                return _latestDestinationHistoryPath(sourceRaw: sourceRaw, platformRaw: platformRaw)
            }()

            let directoryName: String = {
                if resolvedPath.isEmpty {
                    return Inf6Lang.text("未設定", "Not set")
                }
                return _destinationFolderName(path: resolvedPath)
            }()

            return _PapersDestinationMappingRow(
                sourceRaw: sourceRaw,
                sourceLabel: _papersDestinationSourceLabel(sourceRaw),
                platformLabel: platformLabel,
                directoryName: directoryName,
                path: resolvedPath,
                isConfigured: !resolvedPath.isEmpty,
                isActiveSource: sourceRaw == _source.rawValue
            )
        }
    }

    private func _trimmedDestinationPath(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func _usableBookmarkForDestinationPath(_ rawPath: String) -> String? {
        let path = _trimmedDestinationPath(rawPath)
        guard !path.isEmpty else { return nil }

        let existingSlots = _matchingBookmarkSlotsForDestinationPath(path)
        for slot in existingSlots {
            let bookmark = slot.bookmarkB64.trimmingCharacters(in: .whitespacesAndNewlines)
            if !bookmark.isEmpty && _canAccessPapersDestination(bookmarkB64: bookmark) {
                return bookmark
            }
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }

        let folderURL = URL(fileURLWithPath: path, isDirectory: true)
        guard let generated = _createPapersDestinationBookmarkB64(folderURL: folderURL) else {
            return nil
        }
        let bookmark = generated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bookmark.isEmpty else { return nil }
        guard _canAccessPapersDestination(bookmarkB64: bookmark) else { return nil }
        return bookmark
    }

    @MainActor
    private func _normalizeDestinationHistoryForCurrentDevice() {
        var entries = _loadPapersDestinationHistory()
        if entries.isEmpty {
            _papersSaveFolderBookmarkB64_active = ""
            return
        }

        var usableBookmarkByPath: [String: String] = [:]
        var checkedPaths: Set<String> = []
        var unusablePaths: Set<String> = []
        checkedPaths.reserveCapacity(entries.count)
        usableBookmarkByPath.reserveCapacity(entries.count)

        for entry in entries {
            let path = _trimmedDestinationPath(entry.path)
            guard !path.isEmpty else { continue }
            if checkedPaths.contains(path) { continue }
            checkedPaths.insert(path)

            if let bookmark = _usableBookmarkForDestinationPath(path) {
                usableBookmarkByPath[path] = bookmark
            } else {
                unusablePaths.insert(path)
            }
        }

        var changedEntries = false
        if !unusablePaths.isEmpty {
            entries.removeAll { entry in
                unusablePaths.contains(_trimmedDestinationPath(entry.path))
            }
            changedEntries = true
        }

        for idx in entries.indices {
            let path = _trimmedDestinationPath(entries[idx].path)
            guard let usableBookmark = usableBookmarkByPath[path] else { continue }
            let existingBookmark = entries[idx].bookmarkB64?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if existingBookmark != usableBookmark {
                let old = entries[idx]
                entries[idx] = _PapersDestinationHistoryEntry(
                    path: old.path,
                    sourceRaw: old.sourceRaw,
                    platformRaw: old.platformRaw,
                    bookmarkB64: usableBookmark,
                    selectedAt: old.selectedAt
                )
                changedEntries = true
            }
        }

        if changedEntries {
            _savePapersDestinationHistory(entries)
        }

        for slot in _papersDestinationBookmarkSlots() {
            let bookmark = slot.bookmarkB64.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bookmark.isEmpty else { continue }
            guard let resolvedURL = _resolvePapersFolderURLFromBookmarkB64(bookmark) else {
                _setPapersDestinationBookmarkB64(
                    sourceRaw: slot.sourceRaw,
                    platformRaw: slot.platformRaw,
                    bookmarkB64: ""
                )
                continue
            }
            let path = _trimmedDestinationPath(resolvedURL.path)
            if unusablePaths.contains(path) {
                _setPapersDestinationBookmarkB64(
                    sourceRaw: slot.sourceRaw,
                    platformRaw: slot.platformRaw,
                    bookmarkB64: ""
                )
                continue
            }
            if let usableBookmark = usableBookmarkByPath[path], usableBookmark != bookmark {
                _setPapersDestinationBookmarkB64(
                    sourceRaw: slot.sourceRaw,
                    platformRaw: slot.platformRaw,
                    bookmarkB64: usableBookmark
                )
            }
        }

        let activeBookmark = _papersSaveFolderBookmarkB64_active.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeUsable = !activeBookmark.isEmpty && _canAccessPapersDestination(bookmarkB64: activeBookmark)
        if !activeUsable {
            let sourceRaw = _source.rawValue
            let platformRaw = _isIOSAppOnMac ? "iosonmac" : "ios"
            let candidate = entries
                .filter { $0.sourceRaw == sourceRaw && $0.platformRaw == platformRaw }
                .sorted { $0.selectedAt > $1.selectedAt }
                .first

            if let candidate {
                let path = _trimmedDestinationPath(candidate.path)
                if let usableBookmark = usableBookmarkByPath[path] {
                    _papersSaveFolderBookmarkB64_active = usableBookmark
                } else {
                    _papersSaveFolderBookmarkB64_active = ""
                }
            } else {
                _papersSaveFolderBookmarkB64_active = ""
            }
        }
    }

    private func _setPapersDestinationBookmarkB64(sourceRaw: String, platformRaw: String, bookmarkB64: String) {
        switch (sourceRaw, platformRaw) {
        case ("arxiv", "ios"):
            _papersSaveFolderBookmarkB64_arxiv_iOS = bookmarkB64
        case ("arxiv", "iosonmac"):
            _papersSaveFolderBookmarkB64_arxiv_iOSOnMac = bookmarkB64
        case ("pubmed", "ios"):
            _papersSaveFolderBookmarkB64_pubmed_iOS = bookmarkB64
        case ("pubmed", "iosonmac"):
            _papersSaveFolderBookmarkB64_pubmed_iOSOnMac = bookmarkB64
        case ("acl", "ios"):
            _papersSaveFolderBookmarkB64_acl_iOS = bookmarkB64
        case ("acl", "iosonmac"):
            _papersSaveFolderBookmarkB64_acl_iOSOnMac = bookmarkB64
        case ("isca", "ios"):
            _papersSaveFolderBookmarkB64_isca_iOS = bookmarkB64
        case ("isca", "iosonmac"):
            _papersSaveFolderBookmarkB64_isca_iOSOnMac = bookmarkB64
        case ("openalex", "ios"):
            _papersSaveFolderBookmarkB64_openalex_iOS = bookmarkB64
        case ("openalex", "iosonmac"):
            _papersSaveFolderBookmarkB64_openalex_iOSOnMac = bookmarkB64
        default:
            break
        }
    }

    private func _createPapersDestinationBookmarkB64(folderURL: URL) -> String? {
        do {
            #if os(macOS)
            let bookmarkData = try folderURL.bookmarkData(
                options: [.minimalBookmark, .withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            #else
            let bookmarkData = try folderURL.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            #endif
            return bookmarkData.base64EncodedString()
        } catch {
            return nil
        }
    }

    private func _canAccessPapersDestination(bookmarkB64: String) -> Bool {
        let trimmed = bookmarkB64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let url = _resolvePapersFolderURLFromBookmarkB64(trimmed) else { return false }

        let started = url.startAccessingSecurityScopedResource()
        guard started else { return false }
        defer {
            if started {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return _isReadableDirectoryURL(url)
    }

    private func _isReadableDirectoryURL(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }

        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
            if values.isDirectory == false { return false }
            if let readable = values.isReadable {
                return readable
            }
        } catch {
            return false
        }

        return FileManager.default.isReadableFile(atPath: url.path)
    }

    @MainActor
    private func _repairDestinationBookmarksFromList() {
        if _isRepairingDestinationBookmarks { return }
        _isRepairingDestinationBookmarks = true
        defer { _isRepairingDestinationBookmarks = false }

        _destinationRepairStatusText = nil

        var entries = _loadPapersDestinationHistory()
        if entries.isEmpty {
            _destinationRepairStatusText = Inf6Lang.text(
                "再接続対象の保存先履歴がありません。",
                "No destination history entries to reconnect."
            )
            return
        }

        var repairedCount = 0
        var failedCount = 0
        var repairedEntries: [_PapersDestinationHistoryEntry] = []
        repairedEntries.reserveCapacity(entries.count)

        for entry in entries {
            let path = entry.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else {
                failedCount += 1
                repairedEntries.append(entry)
                continue
            }

            let folderURL = URL(fileURLWithPath: path, isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue else {
                failedCount += 1
                repairedEntries.append(entry)
                continue
            }

            let existingBookmark = (entry.bookmarkB64 ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let existingUsable = !existingBookmark.isEmpty && _canAccessPapersDestination(bookmarkB64: existingBookmark)

            let chosenBookmark: String? = {
                if existingUsable { return existingBookmark }
                guard let generated = _createPapersDestinationBookmarkB64(folderURL: folderURL) else {
                    return nil
                }
                let trimmedGenerated = generated.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedGenerated.isEmpty else { return nil }
                guard _canAccessPapersDestination(bookmarkB64: trimmedGenerated) else { return nil }
                return trimmedGenerated
            }()

            guard let chosenBookmark else {
                failedCount += 1
                repairedEntries.append(entry)
                continue
            }

            repairedCount += 1
            _setPapersDestinationBookmarkB64(
                sourceRaw: entry.sourceRaw,
                platformRaw: entry.platformRaw,
                bookmarkB64: chosenBookmark
            )
            repairedEntries.append(
                _PapersDestinationHistoryEntry(
                    path: entry.path,
                    sourceRaw: entry.sourceRaw,
                    platformRaw: entry.platformRaw,
                    bookmarkB64: chosenBookmark,
                    selectedAt: entry.selectedAt
                )
            )
        }

        _savePapersDestinationHistory(repairedEntries)
        entries = repairedEntries

        let activeSourceRaw = _source.rawValue
        let activePlatformRaw = _isIOSAppOnMac ? "iosonmac" : "ios"
        if let activeEntry = entries
            .filter({ $0.sourceRaw == activeSourceRaw && $0.platformRaw == activePlatformRaw })
            .sorted(by: { $0.selectedAt > $1.selectedAt })
            .first,
           let activeBookmark = activeEntry.bookmarkB64?.trimmingCharacters(in: .whitespacesAndNewlines),
           !activeBookmark.isEmpty {
            _papersSaveFolderBookmarkB64_active = activeBookmark
        }

        let resolved = _resolvePapersSaveFolderURLOrError()
        _validatePapersFolderAccess(folderURL: resolved.url)
        _reloadPapersDestinationRows()
        if _activePane == .manage && _showSavedPapersListSheet {
            Task { @MainActor in
                _reloadSavedPapersList(folderURL: resolved.url)
            }
        }

        if repairedCount > 0 && failedCount == 0 {
            _destinationRepairStatusText = Inf6Lang.text(
                "保存先再接続が完了しました（\(repairedCount)件）。",
                "Destination reconnect completed (\(repairedCount) item(s))."
            )
        } else if repairedCount > 0 {
            _destinationRepairStatusText = Inf6Lang.text(
                "保存先再接続を実行しました（成功 \(repairedCount) / 失敗 \(failedCount)）。失敗分は『マッピング追加…』で再追加してください。",
                "Destination reconnect finished (success \(repairedCount) / failed \(failedCount)). Please re-add failed ones via 'Add mapping...'."
            )
        } else {
            _destinationRepairStatusText = Inf6Lang.text(
                "保存先再接続に失敗しました。『マッピング追加…』で再追加してください。",
                "Destination reconnect failed. Please re-add via 'Add mapping...'."
            )
        }
    }

    private func _resolvePapersFolderURLFromBookmarkB64(_ bookmarkB64: String) -> URL? {
        let trimmed = bookmarkB64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = Data(base64Encoded: trimmed) else { return nil }

        var stale = false
        do {
            return try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            return nil
        }
    }

    private func _loadPapersDestinationHistory() -> [_PapersDestinationHistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: _papersDestinationHistoryUserDefaultsKey) else {
            return []
        }
        do {
            return try JSONDecoder().decode([_PapersDestinationHistoryEntry].self, from: data)
        } catch {
            return []
        }
    }

    private func _savePapersDestinationHistory(_ entries: [_PapersDestinationHistoryEntry]) {
        do {
            let data = try JSONEncoder().encode(entries)
            UserDefaults.standard.set(data, forKey: _papersDestinationHistoryUserDefaultsKey)
        } catch {
            // Persistence failure is non-fatal.
        }
    }

    private func _recordPapersDestinationSelection(
        folderURL: URL,
        sourceRaw: String? = nil,
        bookmarkB64: String? = nil
    ) {
        let path = folderURL.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }

        let fallbackSourceRaw = _source.rawValue
        let normalizedSourceRaw = (sourceRaw ?? fallbackSourceRaw).trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveSourceRaw = normalizedSourceRaw.isEmpty ? fallbackSourceRaw : normalizedSourceRaw
        let platformRaw = _isIOSAppOnMac ? "iosonmac" : "ios"
        let now = Date()
        let incomingBookmark = (bookmarkB64 ?? _papersSaveFolderBookmarkB64_active)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedIncomingBookmark: String? = incomingBookmark.isEmpty ? nil : incomingBookmark

        var entries = _loadPapersDestinationHistory()
        if let idx = entries.firstIndex(where: {
            $0.path == path && $0.sourceRaw == effectiveSourceRaw && $0.platformRaw == platformRaw
        }) {
            entries[idx] = _PapersDestinationHistoryEntry(
                path: path,
                sourceRaw: effectiveSourceRaw,
                platformRaw: platformRaw,
                bookmarkB64: normalizedIncomingBookmark ?? entries[idx].bookmarkB64,
                selectedAt: now
            )
        } else {
            entries.append(
                _PapersDestinationHistoryEntry(
                    path: path,
                    sourceRaw: effectiveSourceRaw,
                    platformRaw: platformRaw,
                    bookmarkB64: normalizedIncomingBookmark,
                    selectedAt: now
                )
            )
        }

        let sorted = entries.sorted { lhs, rhs in lhs.selectedAt > rhs.selectedAt }
        let trimmed = Array(sorted.prefix(64))
        _savePapersDestinationHistory(trimmed)
    }

    @MainActor
    private func _repairDestinationBookmarksIfNeeded() {
        if _isRepairingDestinationBookmarks { return }
        if _papersDestinationRows.isEmpty { return }

        let activeBookmarkB64 = _papersSaveFolderBookmarkB64_active.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeBookmarkUnresolved = !activeBookmarkB64.isEmpty && (_resolvePapersSaveFolderURLOrError().url == nil)
        let hasAccessError = !(_papersFolderAccessErrorText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        if activeBookmarkUnresolved || hasAccessError {
            _repairDestinationBookmarksFromList()
        }
    }

    @MainActor
    private func _removeDestinationRowFromList(_ row: _PapersDestinationRow) {
        let targetPath = row.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else { return }
        let sourceRaw = _source.rawValue

        let currentPath = _resolvePapersSaveFolderURLOrError().url?.path ?? ""
        let removedCurrent = (!currentPath.isEmpty && currentPath == targetPath)

        var entries = _loadPapersDestinationHistory()
        entries.removeAll { entry in
            entry.sourceRaw == sourceRaw
            && entry.path.trimmingCharacters(in: .whitespacesAndNewlines) == targetPath
        }
        _savePapersDestinationHistory(entries)

        for slot in _papersDestinationBookmarkSlots() {
            guard slot.sourceRaw == sourceRaw else { continue }
            guard let resolved = _resolvePapersFolderURLFromBookmarkB64(slot.bookmarkB64) else { continue }
            if resolved.path == targetPath {
                _setPapersDestinationBookmarkB64(
                    sourceRaw: slot.sourceRaw,
                    platformRaw: slot.platformRaw,
                    bookmarkB64: ""
                )
            }
        }

        if removedCurrent {
            _papersFolderAccessErrorText = nil
            _papersFolderAccessOK = nil
            _savedPapersListStatus = Inf6Lang.text(
                "現在の保存先を一覧から削除しました。必要なら『マッピング追加…』で再設定してください。",
                "Current destination was removed from the list. Add it again via 'Add mapping...' if needed."
            )
            if _activePane == .manage && _showSavedPapersListSheet {
                _reloadSavedPapersList(folderURL: nil)
            }
        }

        _reloadPapersDestinationRows()
    }

    @MainActor
    private func _reloadPapersDestinationRows() {
        let currentPath = _resolvePapersSaveFolderURLOrError().url?.path ?? ""
        let sourceRaw = _source.rawValue
        var byPath: [String: _PapersDestinationAggregate] = [:]

        func ingest(path rawPath: String, sourceRaw: String, platformRaw: String, selectedAt: Date, isCurrentPath: String) {
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return }
            var agg = byPath[path] ?? _PapersDestinationAggregate()
            agg.sourceRaws.insert(sourceRaw)
            agg.platformRaws.insert(platformRaw)
            if selectedAt > agg.selectedAt {
                agg.selectedAt = selectedAt
            }
            if !isCurrentPath.isEmpty && isCurrentPath == path {
                agg.isCurrent = true
            }
            byPath[path] = agg
        }

        for entry in _loadPapersDestinationHistory() where entry.sourceRaw == sourceRaw {
            ingest(
                path: entry.path,
                sourceRaw: entry.sourceRaw,
                platformRaw: entry.platformRaw,
                selectedAt: entry.selectedAt,
                isCurrentPath: currentPath
            )
        }

        if !currentPath.isEmpty, byPath[currentPath] == nil {
            let platformRaw = _isIOSAppOnMac ? "iosonmac" : "ios"
            ingest(
                path: currentPath,
                sourceRaw: sourceRaw,
                platformRaw: platformRaw,
                selectedAt: .distantPast,
                isCurrentPath: currentPath
            )
        }

        let rows = byPath.map { pair -> _PapersDestinationRow in
            let path = pair.key
            let agg = pair.value
            let sources = agg.sourceRaws
                .map { _papersDestinationSourceLabel($0) }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            let platforms = agg.platformRaws
                .map { _papersDestinationPlatformLabel($0) }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            return _PapersDestinationRow(
                path: path,
                sourceLabels: sources,
                platformLabels: platforms,
                selectedAt: agg.selectedAt,
                isCurrent: agg.isCurrent
            )
        }
        .sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent && !rhs.isCurrent }
            if lhs.selectedAt != rhs.selectedAt { return lhs.selectedAt > rhs.selectedAt }
            return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
        }

        _papersDestinationRows = rows
    }

    private var _savedPapersClassificationLanguageCode: String {
        _savedPaperUseJapaneseClusterLabel ? "ja" : "en"
    }

    private func _savedPapersClassificationSnapshotEntryKey(folderPath: String, languageCode: String) -> String {
        folderPath + "||" + languageCode
    }

    @MainActor
    private func _savedPapersClassificationSnapshotStoreLocationOrThrow() throws -> (root: URL, file: URL) {
        guard let root = Inf6EntityImageLocation.resolvedURL() else {
            throw NSError(
                domain: "Inf6SavedPapersSnapshot",
                code: -7001,
                userInfo: [NSLocalizedDescriptionKey: "保存先ルートを解決できません。"]
            )
        }
        let cacheDir = root.appendingPathComponent("inf6_cache", isDirectory: true)
        let file = cacheDir.appendingPathComponent(_savedPapersClassificationSnapshotStoreFileName, isDirectory: false)
        return (root, file)
    }

    @MainActor
    private func _loadSavedPapersClassificationSnapshotStore() -> [String: _SavedPapersClassificationSnapshot] {
        do {
            let location = try _savedPapersClassificationSnapshotStoreLocationOrThrow()
            let accessed = location.root.startAccessingSecurityScopedResource()
            defer { if accessed { location.root.stopAccessingSecurityScopedResource() } }

            if !FileManager.default.fileExists(atPath: location.file.path) {
                return [:]
            }

            let data = try Data(contentsOf: location.file)
            let decoded = try JSONDecoder().decode(_SavedPapersClassificationSnapshotStore.self, from: data)
            return decoded.snapshotsByKey
        } catch {
            _savedPapersClassificationErrorText = Inf6Lang.text(
                "分類キャッシュ読込エラー: \(error.localizedDescription)",
                "Classification cache load error: \(error.localizedDescription)"
            )
            return [:]
        }
    }

    @MainActor
    private func _saveSavedPapersClassificationSnapshotStore(_ snapshotsByKey: [String: _SavedPapersClassificationSnapshot]) {
        let trimmed: [String: _SavedPapersClassificationSnapshot] = {
            let maxEntries = 8
            if snapshotsByKey.count <= maxEntries { return snapshotsByKey }
            let sorted = snapshotsByKey.sorted { lhs, rhs in
                lhs.value.createdAt > rhs.value.createdAt
            }
            var out: [String: _SavedPapersClassificationSnapshot] = [:]
            out.reserveCapacity(maxEntries)
            for (idx, pair) in sorted.enumerated() {
                if idx >= maxEntries { break }
                out[pair.key] = pair.value
            }
            return out
        }()
        do {
            let location = try _savedPapersClassificationSnapshotStoreLocationOrThrow()
            let accessed = location.root.startAccessingSecurityScopedResource()
            defer { if accessed { location.root.stopAccessingSecurityScopedResource() } }

            var isDir: ObjCBool = false
            let cacheDir = location.file.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: cacheDir.path, isDirectory: &isDir) {
                guard isDir.boolValue else {
                    throw NSError(
                        domain: "Inf6SavedPapersSnapshot",
                        code: -7002,
                        userInfo: [NSLocalizedDescriptionKey: "分類キャッシュ保存先がディレクトリではありません。"]
                    )
                }
            } else {
                try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            }

            let payload = _SavedPapersClassificationSnapshotStore(snapshotsByKey: trimmed)
            let data = try JSONEncoder().encode(payload)
            try data.write(to: location.file, options: [.atomic])
        } catch {
            _savedPapersClassificationErrorText = Inf6Lang.text(
                "分類キャッシュ保存エラー: \(error.localizedDescription)",
                "Classification cache save error: \(error.localizedDescription)"
            )
        }
    }

    private func _savedPapersFeatureKeywordsByPath(
        from rowMetaByPath: [String: _SavedPaperRowMeta]
    ) -> [String: [String]] {
        var out: [String: [String]] = [:]
        out.reserveCapacity(rowMetaByPath.count)
        for (path, meta) in rowMetaByPath {
            let cleaned = meta.featureKeywords
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !cleaned.isEmpty {
                out[path] = cleaned
            }
        }
        return out
    }

    private func _savedPapersApplyFeatureKeywords(
        baseRowMetaByPath: [String: _SavedPaperRowMeta],
        featureKeywordsByPath: [String: [String]]
    ) -> [String: _SavedPaperRowMeta] {
        var merged = baseRowMetaByPath
        for (path, keywords) in featureKeywordsByPath {
            guard let base = merged[path] else { continue }
            let cleaned = keywords
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            merged[path] = _SavedPaperRowMeta(
                title: base.title,
                fileName: base.fileName,
                featureKeywords: cleaned,
                sourceURL: base.sourceURL,
                providerRaw: base.providerRaw,
                rawID: base.rawID,
                abstractText: base.abstractText,
                abstractPreview: base.abstractPreview,
                providerLabel: base.providerLabel
            )
        }
        return merged
    }

    private func _loadSavedPapersClassificationSnapshotOrNil(
        folderPath: String,
        signature: String,
        items: [_SavedPaperListItem],
        baseRowMetaByPath: [String: _SavedPaperRowMeta]
    ) -> _SavedPapersCorpusClassificationOutcome? {
        let key = _savedPapersClassificationSnapshotEntryKey(
            folderPath: folderPath,
            languageCode: _savedPapersClassificationLanguageCode
        )
        let snapshots = _loadSavedPapersClassificationSnapshotStore()
        guard let snapshot = snapshots[key] else { return nil }
        guard snapshot.folderPath == folderPath else { return nil }
        guard snapshot.languageCode == _savedPapersClassificationLanguageCode else { return nil }
        guard snapshot.pdfSignature == signature else { return nil }
        guard !snapshot.labelByPath.isEmpty, !snapshot.rankByPath.isEmpty else { return nil }
        for item in items {
            let path = item.url.path
            guard snapshot.labelByPath[path] != nil, snapshot.rankByPath[path] != nil else {
                return nil
            }
        }
        return _SavedPapersCorpusClassificationOutcome(
            labelByPath: snapshot.labelByPath,
            rankByPath: snapshot.rankByPath,
            rowMetaByPath: _savedPapersApplyFeatureKeywords(
                baseRowMetaByPath: baseRowMetaByPath,
                featureKeywordsByPath: snapshot.featureKeywordsByPath
            )
        )
    }

    private func _persistSavedPapersClassificationSnapshot(
        folderPath: String,
        signature: String,
        outcome: _SavedPapersCorpusClassificationOutcome
    ) {
        guard !folderPath.isEmpty, !signature.isEmpty else { return }
        let key = _savedPapersClassificationSnapshotEntryKey(
            folderPath: folderPath,
            languageCode: _savedPapersClassificationLanguageCode
        )
        var snapshots = _loadSavedPapersClassificationSnapshotStore()
        snapshots[key] = _SavedPapersClassificationSnapshot(
            createdAt: Date(),
            folderPath: folderPath,
            pdfSignature: signature,
            languageCode: _savedPapersClassificationLanguageCode,
            labelByPath: outcome.labelByPath,
            rankByPath: outcome.rankByPath,
            featureKeywordsByPath: _savedPapersFeatureKeywordsByPath(from: outcome.rowMetaByPath)
        )
        _saveSavedPapersClassificationSnapshotStore(snapshots)
    }

    @MainActor
    private func _reloadSavedPapersList(folderURL: URL?, force: Bool = false) {
        _isLoadingSavedPapersList = true
        defer { _isLoadingSavedPapersList = false }

        guard let folderURL else {
            _pendingSavedPapersClassificationTask?.cancel()
            _savedPapersListItems = []
            _savedPapersSelectedItemPath = ""
            _savedPapersListStatus = ""
            _savedPapersListPage = 1
            _savedPapersClusterLabelByPath = [:]
            _savedPapersClusterRankByPath = [:]
            _savedPapersRowMetaByPath = [:]
            _savedPaperLatestByPath = [:]
            _savedPaperLatestErrorByPath = [:]
            _savedPaperLatestCheckInFlightPath = ""
            _savedPaperUpdateInFlightPath = ""
            _savedPaperPendingUpdateConfirmPath = ""
            _savedPaperAbstractFillInFlightPath = ""
            _savedPaperAbstractFillErrorByPath = [:]
            _savedPaperAbstractFillTriedPaths = []
            _savedPapersClassificationErrorText = nil
            _savedPapersLastFolderPath = ""
            _savedPapersLastFolderModifiedAt = nil
            _savedPapersLastPDFSignature = ""
            _savedPapersListStatus = Inf6Lang.text(
                "PDF保存先が未設定です。先に上部の『マッピング追加…』で保存先を追加してください。",
                "PDF destination is not set. Add a folder first from the header."
            )
            return
        }

        let started = folderURL.startAccessingSecurityScopedResource()
        guard started else {
            _savedPapersListStatus = Inf6Lang.text(
                "保存先フォルダへのアクセス権を取得できませんでした。『マッピング追加…』でフォルダを追加し直してください。",
                "Could not access the destination folder. Please add it again via 'Add mapping…'."
            )
            return
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue else {
            _savedPapersListStatus = Inf6Lang.text(
                "保存先フォルダが見つかりません（フォルダではありません）。",
                "Destination folder was not found (not a directory)."
            )
            return
        }
        let folderPath = folderURL.path
        let folderModifiedAt = try? folderURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if !force,
           folderPath == _savedPapersLastFolderPath,
           let folderModifiedAt,
           let lastModifiedAt = _savedPapersLastFolderModifiedAt,
           folderModifiedAt == lastModifiedAt {
            return
        }

        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            let items: [_SavedPaperListItem] = urls.compactMap { u in
                guard u.isFileURL, u.pathExtension.lowercased() == "pdf" else { return nil }
                let values = try? u.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                if values?.isRegularFile == false { return nil }
                return _SavedPaperListItem(
                    url: u,
                    modifiedAt: values?.contentModificationDate
                )
            }

            let sortedItems = items.sorted { lhs, rhs in
                return lhs.url.lastPathComponent.localizedCaseInsensitiveCompare(rhs.url.lastPathComponent) == .orderedAscending
            }
            let signature = _savedPapersPDFSignature(items: sortedItems)
            let previousFolderPath = _savedPapersLastFolderPath
            let previousItems = _savedPapersListItems
            let previousLabelByPath = _savedPapersClusterLabelByPath
            let previousRankByPath = _savedPapersClusterRankByPath
            let previousRowMetaByPath = _savedPapersRowMetaByPath
            let previousPathSet = Set(previousItems.map { $0.url.path })
            let currentPathSet = Set(sortedItems.map { $0.url.path })
            let addedPaths = currentPathSet.subtracting(previousPathSet)
            let addedItems = sortedItems.filter { addedPaths.contains($0.url.path) }
            let canDeltaClassification = !force
                && folderPath == previousFolderPath
                && !previousLabelByPath.isEmpty
                && !previousRankByPath.isEmpty
                && previousPathSet.allSatisfy { previousLabelByPath[$0] != nil && previousRankByPath[$0] != nil }

            if !force,
               folderPath == _savedPapersLastFolderPath,
               signature == _savedPapersLastPDFSignature {
                return
            }

            _pendingSavedPapersClassificationTask?.cancel()
            _savedPapersListItems = sortedItems
            _savedPaperLatestByPath = _savedPaperLatestByPath.filter { currentPathSet.contains($0.key) }
            _savedPaperLatestErrorByPath = _savedPaperLatestErrorByPath.filter { currentPathSet.contains($0.key) }
            _savedPaperAbstractFillErrorByPath = _savedPaperAbstractFillErrorByPath.filter { currentPathSet.contains($0.key) }
            _savedPaperAbstractFillTriedPaths = _savedPaperAbstractFillTriedPaths.filter { currentPathSet.contains($0) }
            if !currentPathSet.contains(_savedPaperLatestCheckInFlightPath) {
                _savedPaperLatestCheckInFlightPath = ""
            }
            if !currentPathSet.contains(_savedPaperUpdateInFlightPath) {
                _savedPaperUpdateInFlightPath = ""
            }
            if !currentPathSet.contains(_savedPaperPendingUpdateConfirmPath) {
                _savedPaperPendingUpdateConfirmPath = ""
            }
            if !currentPathSet.contains(_savedPaperAbstractFillInFlightPath) {
                _savedPaperAbstractFillInFlightPath = ""
            }
            if sortedItems.contains(where: { $0.url.path == _savedPapersSelectedItemPath }) {
                // keep current selection
            } else {
                _savedPapersSelectedItemPath = sortedItems.first?.url.path ?? ""
            }
            _savedPapersListStatus = ""
            _savedPapersListPage = 1
            _savedPapersClusterLabelByPath = [:]
            _savedPapersClusterRankByPath = [:]
            _savedPapersRowMetaByPath = [:]
            _savedPaperLatestByPath = [:]
            _savedPaperLatestErrorByPath = [:]
            _savedPaperLatestCheckInFlightPath = ""
            _savedPaperUpdateInFlightPath = ""
            _savedPaperPendingUpdateConfirmPath = ""
            _savedPaperAbstractFillInFlightPath = ""
            _savedPaperAbstractFillErrorByPath = [:]
            _savedPaperAbstractFillTriedPaths = []
            _savedPapersClassificationErrorText = nil
            _savedPapersLastFolderPath = folderPath
            _savedPapersLastFolderModifiedAt = folderModifiedAt
            _savedPapersLastPDFSignature = signature

            var rowMetaByPath: [String: _SavedPaperRowMeta] = [:]
            rowMetaByPath.reserveCapacity(_savedPapersListItems.count)
            for item in _savedPapersListItems {
                do {
                    let metadata = try _loadSavedPaperMetadataOrThrow(forPDF: item.url)
                    rowMetaByPath[item.url.path] = _savedPaperRowMeta(
                        from: metadata,
                        fileName: item.url.lastPathComponent,
                        featureKeywords: []
                    )
                } catch {
                    rowMetaByPath[item.url.path] = _SavedPaperRowMeta(
                        title: "",
                        fileName: item.url.lastPathComponent,
                        featureKeywords: [],
                        sourceURL: "",
                        providerRaw: "",
                        rawID: "",
                        abstractText: Inf6Lang.text("メタデータ未取得", "Metadata unavailable"),
                        abstractPreview: Inf6Lang.text("メタデータ未取得", "Metadata unavailable"),
                        providerLabel: ""
                    )
                }
            }
            _savedPapersRowMetaByPath = rowMetaByPath
            if let selected = _savedPapersListItems.first(where: { $0.url.path == _savedPapersSelectedItemPath }) {
                _savedPaperAutoCheckLatestIfNeeded(item: selected, rowMeta: rowMetaByPath[selected.url.path])
                _savedPaperAutoFillAbstractIfNeeded(item: selected, rowMeta: rowMetaByPath[selected.url.path], folderURL: folderURL)
            }

            if _savedPapersListItems.isEmpty {
                _savedPapersListStatus = Inf6Lang.text(
                    "PDFがありません。",
                    "No PDFs found."
                )
            } else {
                _savedPapersListStatus = ""
                if !force,
                   let cached = _loadSavedPapersClassificationSnapshotOrNil(
                    folderPath: folderPath,
                    signature: signature,
                    items: _savedPapersListItems,
                    baseRowMetaByPath: _savedPapersRowMetaByPath
                   ) {
                    _savedPapersClusterLabelByPath = cached.labelByPath
                    _savedPapersClusterRankByPath = cached.rankByPath
                    _savedPapersRowMetaByPath = cached.rowMetaByPath
                    _savedPapersClassificationErrorText = nil
                } else if canDeltaClassification {
                    var mergedRowMetaByPath = _savedPapersRowMetaByPath
                    for (path, meta) in previousRowMetaByPath where currentPathSet.contains(path) {
                        mergedRowMetaByPath[path] = meta
                    }
                    _savedPapersRowMetaByPath = mergedRowMetaByPath
                    let mergedLabelByPath = previousLabelByPath.filter { currentPathSet.contains($0.key) }
                    let mergedRankByPath = previousRankByPath.filter { currentPathSet.contains($0.key) }
                    _savedPapersClusterLabelByPath = mergedLabelByPath
                    _savedPapersClusterRankByPath = mergedRankByPath
                    _savedPapersClassificationErrorText = nil
                    if addedItems.isEmpty {
                        let mergedOutcome = _SavedPapersCorpusClassificationOutcome(
                            labelByPath: mergedLabelByPath,
                            rankByPath: mergedRankByPath,
                            rowMetaByPath: mergedRowMetaByPath
                        )
                        _persistSavedPapersClassificationSnapshot(
                            folderPath: _savedPapersLastFolderPath,
                            signature: _savedPapersLastPDFSignature,
                            outcome: mergedOutcome
                        )
                    } else {
                        _scheduleSavedPapersIncrementalClassification(
                            addedItems: addedItems,
                            existingLabelByPath: mergedLabelByPath,
                            existingRankByPath: mergedRankByPath,
                            existingRowMetaByPath: mergedRowMetaByPath
                        )
                    }
                } else {
                    _scheduleSavedPapersCorpusClassification()
                }
            }
        } catch {
            _pendingSavedPapersClassificationTask?.cancel()
            _savedPapersListItems = []
            _savedPapersSelectedItemPath = ""
            _savedPapersListPage = 1
            _savedPapersClusterLabelByPath = [:]
            _savedPapersClusterRankByPath = [:]
            _savedPapersRowMetaByPath = [:]
            _savedPapersClassificationErrorText = nil
            _savedPapersLastFolderPath = ""
            _savedPapersLastFolderModifiedAt = nil
            _savedPapersLastPDFSignature = ""
            _savedPapersListStatus = Inf6Lang.text(
                "保存先PDF一覧の読み込みに失敗しました: \(error.localizedDescription)",
                "Failed to load saved PDFs: \(error.localizedDescription)"
            )
        }
    }

    private struct _SavedPaperMetadataSidecar {
        let title: String
        let provider: String
        let sourceURL: String
        let abstractText: String
        let tags: [String]
        let rawID: String
        let rawTitle: String
    }

    private struct _SavedPaperRowMeta {
        let title: String
        let fileName: String
        let featureKeywords: [String]
        let sourceURL: String
        let providerRaw: String
        let rawID: String
        let abstractText: String
        let abstractPreview: String
        let providerLabel: String
    }

    private struct _SavedPaperEmbeddingRow {
        let path: String
        let fileName: String
        let metadata: _SavedPaperMetadataSidecar
        let assetFeatureText: String
        let vector: [Float]
    }

    private struct _SavedPapersLabelingContext {
        let documentCount: Int
        let documentFrequency: [String: Int]
    }

    private struct _SavedPapersCorpusClassificationOutcome {
        let labelByPath: [String: String]
        let rankByPath: [String: Int]
        let rowMetaByPath: [String: _SavedPaperRowMeta]
    }

    private struct _SavedPapersClassificationSnapshot: Codable {
        let createdAt: Date
        let folderPath: String
        let pdfSignature: String
        let languageCode: String
        let labelByPath: [String: String]
        let rankByPath: [String: Int]
        let featureKeywordsByPath: [String: [String]]
    }

    private struct _SavedPapersClassificationSnapshotStore: Codable {
        let snapshotsByKey: [String: _SavedPapersClassificationSnapshot]
    }

    private struct _SavedPaperClusterClassificationItem: Codable {
        let clusterID: String
        let label: String

        private enum CodingKeys: String, CodingKey {
            case clusterID = "cluster_id"
            case label
        }
    }

    private struct _SavedPaperClusterClassificationResponse: Codable {
        let items: [_SavedPaperClusterClassificationItem]
    }

    private struct _SavedPaperFeatureKeywordItem: Codable {
        let docID: String
        let keywords: [String]

        private enum CodingKeys: String, CodingKey {
            case docID = "doc_id"
            case keywords
        }
    }

    private struct _SavedPaperFeatureKeywordResponse: Codable {
        let items: [_SavedPaperFeatureKeywordItem]
    }

    private func _savedPapersClassificationTimeoutSeconds(itemCount: Int) -> TimeInterval {
        let n = max(itemCount, 1)
        // 1件あたり8秒を目安にし、最短2分・最長20分で打ち切る。
        return min(1200, max(120, Double(n) * 8.0))
    }

    private func _savedPapersRunWithTimeout<T>(
        seconds: TimeInterval,
        operationLabel: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let timeoutNanoseconds = UInt64(max(1, seconds) * 1_000_000_000)
        let timeoutSecText = String(format: "%.0f", seconds)
        let timeoutMessage = "\(operationLabel) が \(timeoutSecText) 秒でタイムアウトしました。"
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw NSError(
                    domain: "Inf6PaperCorpusClassification",
                    code: -529,
                    userInfo: [NSLocalizedDescriptionKey: timeoutMessage]
                )
            }

            guard let first = try await group.next() else {
                throw NSError(
                    domain: "Inf6PaperCorpusClassification",
                    code: -529,
                    userInfo: [NSLocalizedDescriptionKey: timeoutMessage]
                )
            }
            group.cancelAll()
            return first
        }
    }

    @MainActor
    private func _scheduleSavedPapersCorpusClassification() {
        _pendingSavedPapersClassificationTask?.cancel()

        let items = _savedPapersListItems
        guard !items.isEmpty else {
            _savedPapersClusterLabelByPath = [:]
            _savedPapersClusterRankByPath = [:]
            _savedPapersRowMetaByPath = [:]
            _savedPapersClassificationErrorText = nil
            return
        }

        _savedPapersClassificationErrorText = nil
        _pendingSavedPapersClassificationTask = Task { @MainActor in
            defer { _pendingSavedPapersClassificationTask = nil }

            do {
                let timeout = _savedPapersClassificationTimeoutSeconds(itemCount: items.count)
                let outcome = try await _savedPapersRunWithTimeout(
                    seconds: timeout,
                    operationLabel: Inf6Lang.text("論文分類処理", "Paper classification")
                ) {
                    try await _classifySavedPapersByCorpus(items: items)
                }
                if Task.isCancelled { return }
                _savedPapersClusterLabelByPath = outcome.labelByPath
                _savedPapersClusterRankByPath = outcome.rankByPath
                _savedPapersRowMetaByPath = outcome.rowMetaByPath
                _savedPapersClassificationErrorText = nil
                _persistSavedPapersClassificationSnapshot(
                    folderPath: _savedPapersLastFolderPath,
                    signature: _savedPapersLastPDFSignature,
                    outcome: outcome
                )
            } catch {
                if Task.isCancelled { return }
                _savedPapersClusterLabelByPath = [:]
                _savedPapersClusterRankByPath = [:]
                _savedPapersClassificationErrorText = Inf6Lang.text(
                    "論文分類エラー: \(error.localizedDescription)",
                    "Paper classification error: \(error.localizedDescription)"
                )
            }
        }
    }

    @MainActor
    private func _scheduleSavedPapersIncrementalClassification(
        addedItems: [_SavedPaperListItem],
        existingLabelByPath: [String: String],
        existingRankByPath: [String: Int],
        existingRowMetaByPath: [String: _SavedPaperRowMeta]
    ) {
        _pendingSavedPapersClassificationTask?.cancel()
        guard !addedItems.isEmpty else { return }

        _savedPapersClassificationErrorText = nil
        _pendingSavedPapersClassificationTask = Task { @MainActor in
            defer { _pendingSavedPapersClassificationTask = nil }

            do {
                let timeout = _savedPapersClassificationTimeoutSeconds(itemCount: addedItems.count)
                let outcome = try await _savedPapersRunWithTimeout(
                    seconds: timeout,
                    operationLabel: Inf6Lang.text("追加論文の分類処理", "Incremental paper classification")
                ) {
                    try await _classifySavedPapersByCorpus(items: addedItems)
                }
                if Task.isCancelled { return }

                let currentPaths = Set(_savedPapersListItems.map { $0.url.path })
                var mergedLabelByPath = existingLabelByPath.filter { currentPaths.contains($0.key) }
                var mergedRankByPath = existingRankByPath.filter { currentPaths.contains($0.key) }
                var mergedRowMetaByPath = existingRowMetaByPath.filter { currentPaths.contains($0.key) }
                let fallbackLabel = Inf6Lang.text("未分類", "Uncategorized")

                let addedPathsOrdered = outcome.rankByPath
                    .sorted { lhs, rhs in
                        if lhs.value != rhs.value { return lhs.value < rhs.value }
                        return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
                    }
                    .map(\.key)

                var nextRank = (mergedRankByPath.values.max() ?? -1) + 1
                for path in addedPathsOrdered where currentPaths.contains(path) {
                    mergedLabelByPath[path] = outcome.labelByPath[path] ?? fallbackLabel
                    mergedRankByPath[path] = nextRank
                    nextRank += 1
                }
                for (path, meta) in outcome.rowMetaByPath where currentPaths.contains(path) {
                    mergedRowMetaByPath[path] = meta
                }

                _savedPapersClusterLabelByPath = mergedLabelByPath
                _savedPapersClusterRankByPath = mergedRankByPath
                _savedPapersRowMetaByPath = mergedRowMetaByPath
                _savedPapersClassificationErrorText = nil

                let mergedOutcome = _SavedPapersCorpusClassificationOutcome(
                    labelByPath: mergedLabelByPath,
                    rankByPath: mergedRankByPath,
                    rowMetaByPath: mergedRowMetaByPath
                )
                _persistSavedPapersClassificationSnapshot(
                    folderPath: _savedPapersLastFolderPath,
                    signature: _savedPapersLastPDFSignature,
                    outcome: mergedOutcome
                )
            } catch {
                if Task.isCancelled { return }
                _savedPapersClassificationErrorText = Inf6Lang.text(
                    "論文分類エラー: \(error.localizedDescription)",
                    "Paper classification error: \(error.localizedDescription)"
                )
            }
        }
    }

    private func _classifySavedPapersByCorpus(items: [_SavedPaperListItem]) async throws -> _SavedPapersCorpusClassificationOutcome {
        let folderURL = try _resolvePapersSaveFolderURL()
        let started = folderURL.startAccessingSecurityScopedResource()
        guard started else {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -249,
                userInfo: [NSLocalizedDescriptionKey: "保存先フォルダへのアクセス権を取得できませんでした。"]
            )
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }

        var rows: [_SavedPaperEmbeddingRow] = []
        rows.reserveCapacity(items.count)
        var otherPaths: Set<String> = []
        otherPaths.reserveCapacity(items.count)
        var rowMetaByPath: [String: _SavedPaperRowMeta] = [:]
        rowMetaByPath.reserveCapacity(items.count)

        for item in items {
            if Task.isCancelled {
                throw CancellationError()
            }

            do {
                let metadata = try _loadSavedPaperMetadataOrThrow(forPDF: item.url)
                let assetFeatureText = try Inf6PaperVectorSearchEngine.assetFeatureTextFromLocalPDF(item.url)
                let featureText = try _savedPaperMetadataFeatureText(
                    metadata,
                    assetFeatureText: assetFeatureText
                )
                let emb = try await Inf6EmbeddingService.embedPassage(featureText)
                if emb.vector.isEmpty {
                    otherPaths.insert(item.url.path)
                    rowMetaByPath[item.url.path] = _savedPaperRowMeta(
                        from: metadata,
                        fileName: item.url.lastPathComponent,
                        featureKeywords: []
                    )
                    continue
                }
                rows.append(
                    _SavedPaperEmbeddingRow(
                        path: item.url.path,
                        fileName: item.url.lastPathComponent,
                        metadata: metadata,
                        assetFeatureText: _savedPaperClassificationAssetEvidence(assetFeatureText),
                        vector: emb.vector
                    )
                )
                rowMetaByPath[item.url.path] = _savedPaperRowMeta(
                    from: metadata,
                    fileName: item.url.lastPathComponent,
                    featureKeywords: []
                )
            } catch {
                otherPaths.insert(item.url.path)
                rowMetaByPath[item.url.path] = _SavedPaperRowMeta(
                    title: "",
                    fileName: item.url.lastPathComponent,
                    featureKeywords: [],
                    sourceURL: "",
                    providerRaw: "",
                    rawID: "",
                    abstractText: Inf6Lang.text("メタデータ未取得", "Metadata unavailable"),
                    abstractPreview: Inf6Lang.text("メタデータ未取得", "Metadata unavailable"),
                    providerLabel: ""
                )
            }
        }

        guard !rows.isEmpty else {
            var labelByPath: [String: String] = [:]
            var rankByPath: [String: Int] = [:]
            let othersLabel = Inf6Lang.text("その他", "Others")

            let sortedOthers = items
                .filter { otherPaths.contains($0.url.path) }
                .sorted {
                    $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending
                }

            labelByPath.reserveCapacity(sortedOthers.count)
            rankByPath.reserveCapacity(sortedOthers.count)
            for (idx, item) in sortedOthers.enumerated() {
                labelByPath[item.url.path] = othersLabel
                rankByPath[item.url.path] = idx
            }
            return _SavedPapersCorpusClassificationOutcome(
                labelByPath: labelByPath,
                rankByPath: rankByPath,
                rowMetaByPath: rowMetaByPath
            )
        }

        let dim = rows[0].vector.count
        guard rows.allSatisfy({ $0.vector.count == dim }) else {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -252,
                userInfo: [NSLocalizedDescriptionKey: "埋め込みベクター次元が一致しません。"]
            )
        }

        let featureKeywordsByPath = try await _savedPaperFeatureKeywordsByLLMOrThrow(rows: rows)
        for row in rows {
            guard let base = rowMetaByPath[row.path] else { continue }
            rowMetaByPath[row.path] = _SavedPaperRowMeta(
                title: base.title,
                fileName: base.fileName,
                featureKeywords: featureKeywordsByPath[row.path] ?? [],
                sourceURL: base.sourceURL,
                providerRaw: base.providerRaw,
                rawID: base.rawID,
                abstractText: base.abstractText,
                abstractPreview: base.abstractPreview,
                providerLabel: base.providerLabel
            )
        }

        let clusterCount = _savedPapersClusterCount(totalCount: rows.count)
        let clusterByPath = try _savedPapersKMeansClusterByPath(rows: rows, clusterCount: clusterCount)

        var rowsByCluster: [Int: [_SavedPaperEmbeddingRow]] = [:]
        rowsByCluster.reserveCapacity(clusterCount)
        for row in rows {
            let cid = clusterByPath[row.path] ?? 0
            rowsByCluster[cid, default: []].append(row)
        }

        let labelByCluster = try await _classifyClusterLabelsByLLMOrThrow(rowsByCluster: rowsByCluster)
        if labelByCluster.isEmpty {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -281,
                userInfo: [NSLocalizedDescriptionKey: "クラスタ分類ラベルが空です。"]
            )
        }

        var labelItemCount: [String: Int] = [:]
        labelItemCount.reserveCapacity(rowsByCluster.count)
        let uncategorized = Inf6Lang.text("未分類", "Uncategorized")
        for row in rows {
            let cid = clusterByPath[row.path] ?? 0
            let label = labelByCluster[cid] ?? uncategorized
            labelItemCount[label, default: 0] += 1
        }

        let orderedLabels = labelItemCount.keys.sorted { lhs, rhs in
            let lc = labelItemCount[lhs] ?? 0
            let rc = labelItemCount[rhs] ?? 0
            if lc != rc { return lc > rc }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }

        var labelOrder: [String: Int] = [:]
        labelOrder.reserveCapacity(orderedLabels.count)
        for (idx, label) in orderedLabels.enumerated() {
            labelOrder[label] = idx
        }

        let sortedRows = rows.sorted { lhs, rhs in
            let lcid = clusterByPath[lhs.path] ?? 0
            let rcid = clusterByPath[rhs.path] ?? 0
            let lLabel = labelByCluster[lcid] ?? uncategorized
            let rLabel = labelByCluster[rcid] ?? uncategorized

            let lc = labelOrder[lLabel] ?? Int.max
            let rc = labelOrder[rLabel] ?? Int.max
            if lc != rc { return lc < rc }

            if lLabel != rLabel {
                return lLabel.localizedCaseInsensitiveCompare(rLabel) == .orderedAscending
            }

            let lt = _savedPaperPreferredTitle(metadata: lhs.metadata, fileName: lhs.fileName)
            let rt = _savedPaperPreferredTitle(metadata: rhs.metadata, fileName: rhs.fileName)
            if lt != rt {
                return lt.localizedCaseInsensitiveCompare(rt) == .orderedAscending
            }
            return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
        }

        var labelByPath: [String: String] = [:]
        var rankByPath: [String: Int] = [:]
        labelByPath.reserveCapacity(sortedRows.count)
        rankByPath.reserveCapacity(sortedRows.count)

        for (idx, row) in sortedRows.enumerated() {
            let cid = clusterByPath[row.path] ?? 0
            labelByPath[row.path] = labelByCluster[cid] ?? Inf6Lang.text("未分類", "Uncategorized")
            rankByPath[row.path] = idx
        }

        if !otherPaths.isEmpty {
            let othersLabel = Inf6Lang.text("その他", "Others")
            let sortedOthers = items
                .filter { otherPaths.contains($0.url.path) }
                .sorted {
                    $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending
                }
            var nextRank = sortedRows.count
            for item in sortedOthers {
                labelByPath[item.url.path] = othersLabel
                rankByPath[item.url.path] = nextRank
                nextRank += 1
            }
        }

        return _SavedPapersCorpusClassificationOutcome(
            labelByPath: labelByPath,
            rankByPath: rankByPath,
            rowMetaByPath: rowMetaByPath
        )
    }

    private func _classifyClusterLabelsByLLMOrThrow(
        rowsByCluster: [Int: [_SavedPaperEmbeddingRow]]
    ) async throws -> [Int: String] {
        if rowsByCluster.isEmpty { return [:] }

        let key = try OpenAIKeyStore.load().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -282,
                userInfo: [NSLocalizedDescriptionKey: "クラスタ分類ラベル生成には OpenAI APIキーが必要です。"]
            )
        }

        let model = Inf6OpenAIModelResolver.resolvedModel().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -283,
                userInfo: [NSLocalizedDescriptionKey: "クラスタ分類ラベル生成に使用する OpenAI モデルが未設定です。"]
            )
        }

        let sortedClusterIDs = rowsByCluster.keys.sorted()
        var payload: [[String: Any]] = []
        payload.reserveCapacity(sortedClusterIDs.count)

        for cid in sortedClusterIDs {
            let clusterRows = rowsByCluster[cid] ?? []
            let sampleRows = clusterRows.sorted { lhs, rhs in
                let lt = _savedPaperPreferredTitle(metadata: lhs.metadata, fileName: lhs.fileName)
                let rt = _savedPaperPreferredTitle(metadata: rhs.metadata, fileName: rhs.fileName)
                if lt != rt {
                    return lt.localizedCaseInsensitiveCompare(rt) == .orderedAscending
                }
                return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
            }

            var papers: [[String: Any]] = []
            papers.reserveCapacity(min(sampleRows.count, 8))

            for row in sampleRows.prefix(8) {
                let title = _savedPaperPreferredTitle(metadata: row.metadata, fileName: row.fileName)
                let abstractText = row.metadata.abstractText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var one: [String: Any] = [
                    "title": title,
                    "provider": row.metadata.provider,
                ]
                if !abstractText.isEmpty {
                    one["abstract"] = String(abstractText.prefix(420))
                }
                if !row.metadata.tags.isEmpty {
                    one["tags"] = Array(row.metadata.tags.prefix(8))
                }
                if !row.assetFeatureText.isEmpty {
                    one["asset_evidence"] = row.assetFeatureText
                }
                papers.append(one)
            }

            payload.append([
                "cluster_id": "C\(cid)",
                "size": clusterRows.count,
                "papers": papers,
            ])
        }

        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let payloadText = String(data: payloadData, encoding: .utf8) else {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -284,
                userInfo: [NSLocalizedDescriptionKey: "クラスタ分類入力のJSON化に失敗しました。"]
            )
        }

        let outputLanguage = _savedPaperUseJapaneseClusterLabel ? "日本語" : "English"
        let fallbackLabel = _savedPaperUseJapaneseClusterLabel ? "未分類" : "Uncategorized"
        let maxLabelLength = _savedPaperClusterLabelMaxLength()

        let rendered = try Inf6PromptGovernance.renderSystemUserPrompt(
            ref: Inf6PromptCatalog.autoPapersClusterLabel,
            variables: [
                "output_language": outputLanguage,
                "fallback_label": fallbackLabel,
                "max_label_length": String(maxLabelLength),
                "payload_json": payloadText
            ]
        )

        let client = OpenAIClient(
            apiKey: key,
            config: try OpenAIClient.Config.default(model: model)
        )
        let raw = try await client.generateText(
            messages: [
                OpenAIClient.InputMessage(role: .system, text: rendered.systemInstruction),
                OpenAIClient.InputMessage(role: .user, text: rendered.userPrompt),
            ],
            options: .init(maxOutputTokens: 1600)
        )

        let response = try _decodeClusterClassificationResponseOrThrow(raw)
        var clusterTokenToID: [String: Int] = [:]
        clusterTokenToID.reserveCapacity(sortedClusterIDs.count)
        for cid in sortedClusterIDs {
            clusterTokenToID["C\(cid)"] = cid
        }

        var labelByCluster: [Int: String] = [:]
        labelByCluster.reserveCapacity(sortedClusterIDs.count)

        for item in response.items {
            let token = item.clusterID.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = item.label.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !token.isEmpty else {
                throw NSError(
                    domain: "Inf6PaperCorpusClassification",
                    code: -285,
                    userInfo: [NSLocalizedDescriptionKey: "クラスタ分類結果の cluster_id が空です。"]
                )
            }
            guard !label.isEmpty else {
                throw NSError(
                    domain: "Inf6PaperCorpusClassification",
                    code: -286,
                    userInfo: [NSLocalizedDescriptionKey: "クラスタ分類結果の label が空です。 cluster_id=\(token)"]
                )
            }
            guard !label.contains("/") && !label.contains("・") else {
                throw NSError(
                    domain: "Inf6PaperCorpusClassification",
                    code: -287,
                    userInfo: [NSLocalizedDescriptionKey: "クラスタ分類ラベルが不正です（区切り記号禁止）: \(label)"]
                )
            }
            if _savedPaperUseJapaneseClusterLabel, !_savedPaperContainsJapaneseCharacters(label) {
                throw NSError(
                    domain: "Inf6PaperCorpusClassification",
                    code: -288,
                    userInfo: [NSLocalizedDescriptionKey: "日本語モードの分類ラベルが日本語ではありません: \(label)"]
                )
            }
            guard let cid = clusterTokenToID[token] else {
                throw NSError(
                    domain: "Inf6PaperCorpusClassification",
                    code: -289,
                    userInfo: [NSLocalizedDescriptionKey: "クラスタ分類結果に未知の cluster_id が含まれています: \(token)"]
                )
            }
            labelByCluster[cid] = label
        }

        for cid in sortedClusterIDs {
            if labelByCluster[cid] == nil {
                throw NSError(
                    domain: "Inf6PaperCorpusClassification",
                    code: -290,
                    userInfo: [NSLocalizedDescriptionKey: "クラスタ分類結果が不足しています: C\(cid)"]
                )
            }
        }

        let compacted = try await _compactClusterLabelsIfNeededByLLMOrThrow(
            labelsByCluster: labelByCluster,
            rowsByCluster: rowsByCluster,
            apiKey: key,
            model: model
        )
        var finalLabels = compacted

        for cid in sortedClusterIDs {
            let token = "C\(cid)"
            guard let label = finalLabels[cid] else {
                throw NSError(
                    domain: "Inf6PaperCorpusClassification",
                    code: -291,
                    userInfo: [NSLocalizedDescriptionKey: "クラスタ分類ラベルが欠落しています: \(token)"]
                )
            }
            try _assertClusterLabelFinalOrThrow(label, clusterToken: token)
            finalLabels[cid] = label
        }

        return finalLabels
    }

    private func _savedPaperFeatureKeywordsByLLMOrThrow(
        rows: [_SavedPaperEmbeddingRow]
    ) async throws -> [String: [String]] {
        if rows.isEmpty { return [:] }

        let key = try OpenAIKeyStore.load().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -520,
                userInfo: [NSLocalizedDescriptionKey: "特徴語生成には OpenAI APIキーが必要です。"]
            )
        }

        let model = Inf6OpenAIModelResolver.resolvedModel().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -521,
                userInfo: [NSLocalizedDescriptionKey: "特徴語生成に使用する OpenAI モデルが未設定です。"]
            )
        }

        let sortedRows = rows.sorted { lhs, rhs in
            let lt = _savedPaperPreferredTitle(metadata: lhs.metadata, fileName: lhs.fileName)
            let rt = _savedPaperPreferredTitle(metadata: rhs.metadata, fileName: rhs.fileName)
            if lt != rt {
                return lt.localizedCaseInsensitiveCompare(rt) == .orderedAscending
            }
            return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
        }

        let outputLanguage = _savedPaperUseJapaneseClusterLabel ? "日本語" : "English"
        let client = OpenAIClient(
            apiKey: key,
            config: try OpenAIClient.Config.default(model: model)
        )

        let batchSize = 14
        var keywordsByPath: [String: [String]] = [:]
        keywordsByPath.reserveCapacity(rows.count)

        var batchStart = 0
        while batchStart < sortedRows.count {
            let batchEnd = min(batchStart + batchSize, sortedRows.count)
            let batchRows = Array(sortedRows[batchStart..<batchEnd])

            var payload: [[String: Any]] = []
            payload.reserveCapacity(batchRows.count)
            var tokenToPath: [String: String] = [:]
            tokenToPath.reserveCapacity(batchRows.count)

            for (offset, row) in batchRows.enumerated() {
                let token = "D\(batchStart + offset)"
                tokenToPath[token] = row.path

                let title = _savedPaperPreferredTitle(metadata: row.metadata, fileName: row.fileName)
                let abstractText = row.metadata.abstractText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var one: [String: Any] = [
                    "doc_id": token,
                    "title": title,
                ]
                if !abstractText.isEmpty {
                    one["abstract"] = String(abstractText.prefix(520))
                }
                if !row.metadata.tags.isEmpty {
                    one["tags"] = Array(row.metadata.tags.prefix(10))
                }
                if !row.assetFeatureText.isEmpty {
                    one["asset_evidence"] = String(row.assetFeatureText.prefix(320))
                }
                payload.append(one)
            }

            let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            guard let payloadText = String(data: payloadData, encoding: .utf8) else {
                throw NSError(
                    domain: "Inf6PaperCorpusClassification",
                    code: -522,
                    userInfo: [NSLocalizedDescriptionKey: "特徴語生成入力のJSON化に失敗しました。"]
                )
            }

            let rendered = try Inf6PromptGovernance.renderSystemUserPrompt(
                ref: Inf6PromptCatalog.autoPapersFeatureKeywords,
                variables: [
                    "output_language": outputLanguage,
                    "payload_json": payloadText
                ]
            )

            let raw = try await client.generateText(
                messages: [
                    OpenAIClient.InputMessage(role: .system, text: rendered.systemInstruction),
                    OpenAIClient.InputMessage(role: .user, text: rendered.userPrompt),
                ],
                options: .init(maxOutputTokens: 2200)
            )

            let response = try _decodeSavedPaperFeatureKeywordResponseOrThrow(raw)
            var returnedDocIDs: Set<String> = []
            returnedDocIDs.reserveCapacity(batchRows.count)

            for item in response.items {
                let docID = item.docID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !docID.isEmpty else {
                    throw NSError(
                        domain: "Inf6PaperCorpusClassification",
                        code: -523,
                        userInfo: [NSLocalizedDescriptionKey: "特徴語生成結果の doc_id が空です。"]
                    )
                }
                guard let path = tokenToPath[docID] else { continue }

                let normalizedKeywords = _savedPaperNormalizedLLMFeatureKeywords(item.keywords, maxCount: 5)
                let effectiveKeywords: [String]
                if _savedPaperUseJapaneseClusterLabel {
                    effectiveKeywords = normalizedKeywords.filter { _savedPaperContainsJapaneseCharacters($0) }
                } else {
                    effectiveKeywords = normalizedKeywords
                }

                keywordsByPath[path] = effectiveKeywords
                returnedDocIDs.insert(docID)
            }

            for (docID, path) in tokenToPath {
                if !returnedDocIDs.contains(docID) {
                    keywordsByPath[path] = []
                }
            }

            batchStart = batchEnd
        }

        var documentFrequency: [String: Int] = [:]
        documentFrequency.reserveCapacity(rows.count * 4)

        for keywords in keywordsByPath.values {
            let unique = Set(keywords.map { _savedPaperNormalizedLabelPhrase($0) }.filter { !$0.isEmpty })
            for key in unique {
                documentFrequency[key, default: 0] += 1
            }
        }

        let corpusCount = max(rows.count, 1)
        let genericThreshold = max(3, Int(ceil(Double(corpusCount) * 0.35)))
        var prunedByPath: [String: [String]] = [:]
        prunedByPath.reserveCapacity(keywordsByPath.count)

        for row in sortedRows {
            let rawKeywords = keywordsByPath[row.path] ?? []
            let filtered = rawKeywords.filter { kw in
                let key = _savedPaperNormalizedLabelPhrase(kw)
                if key.isEmpty { return false }
                return (documentFrequency[key] ?? 0) < genericThreshold
            }
            prunedByPath[row.path] = filtered
        }

        return prunedByPath
    }

    private func _savedPaperNormalizedLLMFeatureKeywords(_ keywords: [String], maxCount: Int) -> [String] {
        let limit = max(1, maxCount)
        var out: [String] = []
        out.reserveCapacity(limit)
        var seen: Set<String> = []

        for raw in keywords {
            let normalized = _savedPaperNormalizedLabelPhrase(raw)
            if normalized.isEmpty { continue }

            let key = normalized.lowercased()
            if !seen.insert(key).inserted { continue }

            let localized = _savedPaperLocalizedFeatureKeyword(normalized)
            if localized.isEmpty { continue }

            out.append(localized)
            if out.count >= limit { break }
        }
        return out
    }

    private func _compactClusterLabelsIfNeededByLLMOrThrow(
        labelsByCluster: [Int: String],
        rowsByCluster: [Int: [_SavedPaperEmbeddingRow]],
        apiKey: String,
        model: String
    ) async throws -> [Int: String] {
        if labelsByCluster.isEmpty { return labelsByCluster }

        let maxLen = _savedPaperClusterLabelMaxLength()
        let targetIDs = labelsByCluster.keys.sorted().filter { cid in
            let label = (labelsByCluster[cid] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return _savedPaperClusterLabelNeedsCompaction(label, maxLen: maxLen)
        }
        if targetIDs.isEmpty { return labelsByCluster }

        var payload: [[String: Any]] = []
        payload.reserveCapacity(targetIDs.count)

        for cid in targetIDs {
            let token = "C\(cid)"
            let current = (labelsByCluster[cid] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let rows = rowsByCluster[cid] ?? []
            let titles = rows
                .map { _savedPaperPreferredTitle(metadata: $0.metadata, fileName: $0.fileName) }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .prefix(4)
            payload.append([
                "cluster_id": token,
                "current_label": current,
                "titles": Array(titles),
            ])
        }

        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let payloadText = String(data: payloadData, encoding: .utf8) else {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -293,
                userInfo: [NSLocalizedDescriptionKey: "分類ラベル短縮入力のJSON化に失敗しました。"]
            )
        }

        let outputLanguage = _savedPaperUseJapaneseClusterLabel ? "日本語" : "English"
        let fallbackLabel = _savedPaperUseJapaneseClusterLabel ? "未分類" : "Uncategorized"
        let rendered = try Inf6PromptGovernance.renderSystemUserPrompt(
            ref: Inf6PromptCatalog.autoPapersCompactClusterLabel,
            variables: [
                "output_language": outputLanguage,
                "max_label_length": String(maxLen),
                "fallback_label": fallbackLabel,
                "payload_json": payloadText
            ]
        )

        let client = OpenAIClient(
            apiKey: apiKey,
            config: try OpenAIClient.Config.default(model: model)
        )
        let raw = try await client.generateText(
            messages: [
                OpenAIClient.InputMessage(role: .system, text: rendered.systemInstruction),
                OpenAIClient.InputMessage(role: .user, text: rendered.userPrompt),
            ],
            options: .init(maxOutputTokens: 1200)
        )
        let response = try _decodeClusterClassificationResponseOrThrow(raw)

        var tokenToID: [String: Int] = [:]
        tokenToID.reserveCapacity(targetIDs.count)
        for cid in targetIDs {
            tokenToID["C\(cid)"] = cid
        }

        var updated = labelsByCluster
        for item in response.items {
            let token = item.clusterID.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let cid = tokenToID[token] else {
                throw NSError(
                    domain: "Inf6PaperCorpusClassification",
                    code: -294,
                    userInfo: [NSLocalizedDescriptionKey: "分類ラベル短縮結果に未知の cluster_id が含まれています: \(token)"]
                )
            }
            guard !label.isEmpty else {
                throw NSError(
                    domain: "Inf6PaperCorpusClassification",
                    code: -295,
                    userInfo: [NSLocalizedDescriptionKey: "分類ラベル短縮結果が空です: \(token)"]
                )
            }
            updated[cid] = label
        }

        for cid in targetIDs {
            if updated[cid] == nil {
                throw NSError(
                    domain: "Inf6PaperCorpusClassification",
                    code: -296,
                    userInfo: [NSLocalizedDescriptionKey: "分類ラベル短縮結果が不足しています: C\(cid)"]
                )
            }
        }
        return updated
    }

    private func _savedPaperClusterLabelNeedsCompaction(_ label: String, maxLen: Int) -> Bool {
        let t = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        if t.count > maxLen { return true }

        let markers: [String] = [
            "のための", "に関する", "を用いた", "における", "について", "を通じた", "による", "としての", "に向けた"
        ]
        if markers.contains(where: { t.contains($0) }) { return true }
        if t.contains("。") || t.contains(".") { return true }
        if t.contains("です") || t.contains("ます") { return true }
        return false
    }

    private func _savedPaperClusterLabelMaxLength() -> Int {
        _savedPaperUseJapaneseClusterLabel ? 20 : 48
    }

    private func _assertClusterLabelFinalOrThrow(_ label: String, clusterToken: String) throws {
        let t = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -297,
                userInfo: [NSLocalizedDescriptionKey: "クラスタ分類ラベルが空です: \(clusterToken)"]
            )
        }
        guard !t.contains("/") && !t.contains("・") else {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -298,
                userInfo: [NSLocalizedDescriptionKey: "クラスタ分類ラベルが不正です（区切り記号禁止）: \(clusterToken): \(t)"]
            )
        }
        if _savedPaperUseJapaneseClusterLabel, !_savedPaperContainsJapaneseCharacters(t) {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -299,
                userInfo: [NSLocalizedDescriptionKey: "日本語モードの分類ラベルが日本語ではありません: \(clusterToken): \(t)"]
            )
        }
        let maxLen = _savedPaperClusterLabelMaxLength()
        if t.count > maxLen {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -300,
                userInfo: [NSLocalizedDescriptionKey: "分類ラベルが長すぎます（\(maxLen)文字超過）: \(clusterToken): \(t)"]
            )
        }
        if _savedPaperClusterLabelNeedsCompaction(t, maxLen: maxLen) {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -301,
                userInfo: [NSLocalizedDescriptionKey: "分類ラベルが分類名として不適切です: \(clusterToken): \(t)"]
            )
        }
    }

    private func _decodeClusterClassificationResponseOrThrow(_ raw: String) throws -> _SavedPaperClusterClassificationResponse {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -291,
                userInfo: [NSLocalizedDescriptionKey: "クラスタ分類レスポンスが空です。"]
            )
        }

        let candidateStrings: [String] = {
            if trimmed.first == "{", trimmed.last == "}" {
                return [trimmed]
            }
            if let start = trimmed.firstIndex(of: "{"),
               let end = trimmed.lastIndex(of: "}"),
               start < end {
                return [String(trimmed[start...end])]
            }
            return [trimmed]
        }()

        for s in candidateStrings {
            guard let data = s.data(using: .utf8) else { continue }
            if let parsed = try? JSONDecoder().decode(_SavedPaperClusterClassificationResponse.self, from: data) {
                return parsed
            }
        }

        throw NSError(
            domain: "Inf6PaperCorpusClassification",
            code: -292,
            userInfo: [NSLocalizedDescriptionKey: "クラスタ分類レスポンスのJSON解析に失敗しました。"]
        )
    }

    private func _decodeSavedPaperFeatureKeywordResponseOrThrow(_ raw: String) throws -> _SavedPaperFeatureKeywordResponse {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -528,
                userInfo: [NSLocalizedDescriptionKey: "特徴語生成レスポンスが空です。"]
            )
        }

        let candidateStrings: [String] = {
            if trimmed.first == "{", trimmed.last == "}" {
                return [trimmed]
            }
            if let start = trimmed.firstIndex(of: "{"),
               let end = trimmed.lastIndex(of: "}"),
               start < end {
                return [String(trimmed[start...end])]
            }
            return [trimmed]
        }()

        for s in candidateStrings {
            guard let data = s.data(using: .utf8) else { continue }
            if let parsed = try? JSONDecoder().decode(_SavedPaperFeatureKeywordResponse.self, from: data) {
                return parsed
            }
        }

        throw NSError(
            domain: "Inf6PaperCorpusClassification",
            code: -529,
            userInfo: [NSLocalizedDescriptionKey: "特徴語生成レスポンスのJSON解析に失敗しました。"]
        )
    }

    private func _savedPapersClusterCount(totalCount: Int) -> Int {
        if totalCount <= 1 { return 1 }
        if totalCount <= 8 { return 2 }
        if totalCount <= 20 {
            return min(6, max(3, Int(round(Double(totalCount) / 4.0))))
        }
        let scaled = Int(round(sqrt(Double(totalCount)) * 2.20))
        return min(16, max(6, scaled))
    }

    private func _savedPapersKMeansClusterByPath(rows: [_SavedPaperEmbeddingRow], clusterCount: Int) throws -> [String: Int] {
        guard !rows.isEmpty else { return [:] }

        let dimension = rows[0].vector.count
        guard dimension > 0 else {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -260,
                userInfo: [NSLocalizedDescriptionKey: "埋め込みベクター次元が不正です。"]
            )
        }
        guard rows.allSatisfy({ $0.vector.count == dimension }) else {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -261,
                userInfo: [NSLocalizedDescriptionKey: "k-means実行前にベクター次元が一致していません。"]
            )
        }

        let k = max(1, min(clusterCount, rows.count))
        var centerIndices: [Int] = [0]
        centerIndices.reserveCapacity(k)

        while centerIndices.count < k {
            let selected = Set(centerIndices)
            var bestCandidate = -1
            var bestDistance = -Float.greatestFiniteMagnitude

            for i in rows.indices where !selected.contains(i) {
                var minDistanceToCenters = Float.greatestFiniteMagnitude
                for c in centerIndices {
                    let sim = Inf6VectorMath.cosine(rows[i].vector, rows[c].vector)
                    let distance = 1 - sim
                    if distance < minDistanceToCenters {
                        minDistanceToCenters = distance
                    }
                }
                if minDistanceToCenters > bestDistance {
                    bestDistance = minDistanceToCenters
                    bestCandidate = i
                }
            }

            guard bestCandidate >= 0 else { break }
            centerIndices.append(bestCandidate)
        }

        while centerIndices.count < k {
            centerIndices.append(0)
        }

        var centers = centerIndices.map { rows[$0].vector }
        var assignments = Array(repeating: 0, count: rows.count)
        var iteration = 0
        let maxIterations = 16
        var changed = true

        while changed && iteration < maxIterations {
            changed = false
            iteration += 1

            for i in rows.indices {
                var bestCluster = 0
                var bestScore = -Float.greatestFiniteMagnitude

                for c in centers.indices {
                    let score = Inf6VectorMath.cosine(rows[i].vector, centers[c])
                    if score > bestScore {
                        bestScore = score
                        bestCluster = c
                    }
                }

                if assignments[i] != bestCluster {
                    assignments[i] = bestCluster
                    changed = true
                }
            }

            var sums = Array(
                repeating: Array(repeating: Float(0), count: dimension),
                count: centers.count
            )
            var counts = Array(repeating: 0, count: centers.count)

            for i in rows.indices {
                let c = assignments[i]
                counts[c] += 1
                for d in 0..<dimension {
                    sums[c][d] += rows[i].vector[d]
                }
            }

            for c in centers.indices {
                guard counts[c] > 0 else { continue }
                let inv = Float(1.0 / Double(counts[c]))
                var avg = sums[c].map { $0 * inv }
                avg = Inf6VectorMath.normalizeL2(avg)
                centers[c] = avg
            }
        }

        var clusterByPath: [String: Int] = [:]
        clusterByPath.reserveCapacity(rows.count)
        for (idx, row) in rows.enumerated() {
            clusterByPath[row.path] = assignments[idx]
        }
        return clusterByPath
    }

    private func _savedPapersBuildLabelingContext(rows: [_SavedPaperEmbeddingRow]) -> _SavedPapersLabelingContext {
        var documentFrequency: [String: Int] = [:]
        documentFrequency.reserveCapacity(rows.count * 4)

        for row in rows {
            let terms = _savedPaperLabelTerms(metadata: row.metadata)
            for term in terms {
                documentFrequency[term, default: 0] += 1
            }
        }

        return _SavedPapersLabelingContext(
            documentCount: rows.count,
            documentFrequency: documentFrequency
        )
    }

    private func _savedPapersClusterLabel(
        from rows: [_SavedPaperEmbeddingRow],
        context: _SavedPapersLabelingContext
    ) -> String {
        var clusterFrequency: [String: Int] = [:]
        clusterFrequency.reserveCapacity(rows.count * 3)

        for row in rows {
            let terms = _savedPaperLabelTerms(metadata: row.metadata)
            for term in terms {
                clusterFrequency[term, default: 0] += 1
            }
        }

        if !clusterFrequency.isEmpty {
            let clusterSize = max(rows.count, 1)
            let corpusSize = max(context.documentCount, 1)

            let ranked = clusterFrequency.keys.sorted { lhs, rhs in
                let ltf = clusterFrequency[lhs] ?? 0
                let rtf = clusterFrequency[rhs] ?? 0
                let ldf = context.documentFrequency[lhs] ?? ltf
                let rdf = context.documentFrequency[rhs] ?? rtf

                let lidf = log((Double(corpusSize) + 1.0) / (Double(ldf) + 1.0)) + 1.0
                let ridf = log((Double(corpusSize) + 1.0) / (Double(rdf) + 1.0)) + 1.0
                let lscore = (Double(ltf) / Double(clusterSize)) * lidf
                let rscore = (Double(rtf) / Double(clusterSize)) * ridf

                if lscore != rscore { return lscore > rscore }

                let lWords = lhs.split(separator: " ").count
                let rWords = rhs.split(separator: " ").count
                if lWords != rWords { return lWords > rWords }

                if ltf != rtf { return ltf > rtf }
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }

            let phraseRanked = ranked.filter {
                let wordCount = $0.split(separator: " ").count
                return wordCount >= 2 && !_savedPaperIsWeakLabelPhrase($0)
            }
            var labels: [String] = []
            labels.reserveCapacity(2)
            var seen: Set<String> = []

            for term in phraseRanked {
                let localized = _savedPaperLocalizedFeatureKeyword(term)
                let key = localized.lowercased()
                if key.isEmpty { continue }
                if seen.insert(key).inserted {
                    labels.append(localized)
                }
                if labels.count >= 2 { break }
            }

            if !labels.isEmpty {
                let separator = " / "
                return labels.joined(separator: separator)
            }
        }

        return Inf6Lang.text("未分類", "Uncategorized")
    }

    private var _savedPaperUseJapaneseClusterLabel: Bool {
        Inf6Lang.text("ja", "en") == "ja"
    }

    private func _savedPaperLabelTerms(metadata: _SavedPaperMetadataSidecar) -> Set<String> {
        var terms: Set<String> = []
        terms.reserveCapacity(48)

        for rawTag in metadata.tags {
            let normalizedTag = _savedPaperNormalizedLabelPhrase(_normalizedSavedPaperTag(rawTag))
            if normalizedTag.isEmpty { continue }
            if _savedPaperIsGenericLabelPhrase(normalizedTag) { continue }
            terms.insert(normalizedTag)
        }

        let blob = [
            metadata.title,
            metadata.rawTitle
        ]
        .joined(separator: " ")
        let tokens = _savedPaperKeywordTokens(from: blob)
        let filteredTokens = tokens.filter { !_savedPaperLabelGenericTokens.contains($0) }

        for token in filteredTokens where token.count >= 3 {
            terms.insert(token)
        }
        terms.formUnion(_savedPaperNGramTerms(tokens: filteredTokens, n: 2))
        terms.formUnion(_savedPaperNGramTerms(tokens: filteredTokens, n: 3))
        return terms
    }

    private func _savedPaperNGramTerms(tokens: [String], n: Int) -> Set<String> {
        guard n > 0, tokens.count >= n else { return [] }

        var out: Set<String> = []
        out.reserveCapacity(max(8, tokens.count))

        for idx in 0...(tokens.count - n) {
            let phrase = tokens[idx..<(idx + n)].joined(separator: " ")
            if phrase.isEmpty { continue }
            if _savedPaperIsGenericLabelPhrase(phrase) { continue }
            out.insert(phrase)
        }
        return out
    }

    private func _savedPaperIsGenericLabelPhrase(_ phrase: String) -> Bool {
        let p = _savedPaperNormalizedLabelPhrase(phrase)
        if p.isEmpty { return true }
        if _savedPaperLabelGenericPhrases.contains(p) { return true }

        let words = p.split(separator: " ").map(String.init)
        if words.isEmpty { return true }
        if words.allSatisfy({ _savedPaperLabelGenericTokens.contains($0) }) {
            return true
        }
        return false
    }

    private func _savedPaperIsWeakLabelPhrase(_ phrase: String) -> Bool {
        let p = _savedPaperNormalizedLabelPhrase(phrase)
        if p.isEmpty { return true }
        let words = p.split(separator: " ").map(String.init)
        if words.count <= 1 { return _savedPaperIsWeakSingleLabelTerm(p) }
        if words.allSatisfy({ _savedPaperIsWeakSingleLabelTerm($0) || _savedPaperLabelGenericTokens.contains($0) }) {
            return true
        }
        return false
    }

    private func _savedPaperIsWeakSingleLabelTerm(_ raw: String) -> Bool {
        let t = _savedPaperNormalizedLabelPhrase(raw)
        if t.isEmpty { return true }
        return _savedPaperWeakSingleLabelTerms.contains(t)
    }

    private func _savedPaperNormalizedLabelPhrase(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        let deCamelized = _savedPaperSplitCamelCase(trimmed)
        let lower = deCamelized.lowercased()
        let parts = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let cleaned = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleaned.isEmpty {
            return cleaned.joined(separator: " ")
        }
        return lower
    }

    private func _savedPaperSplitCamelCase(_ text: String) -> String {
        if text.isEmpty { return text }
        let firstPass = text.replacingOccurrences(
            of: "([a-z0-9])([A-Z])",
            with: "$1 $2",
            options: .regularExpression
        )
        let secondPass = firstPass.replacingOccurrences(
            of: "([A-Z])([A-Z][a-z])",
            with: "$1 $2",
            options: .regularExpression
        )
        return secondPass
    }

    private func _savedPaperLocalizedLabelPhrase(_ phrase: String, preserveCase: Bool) -> String {
        let source = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.isEmpty { return "" }

        let normalized = _savedPaperNormalizedLabelPhrase(source)
        if normalized.isEmpty { return "" }

        // Engineering contract: label text must stay data-driven.
        // No hard-coded translation dictionary is applied here.
        if _savedPaperUseJapaneseClusterLabel {
            return normalized
        }

        let words = source.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return normalized }

        let localizedWords = words.map { term -> String in
            if preserveCase { return term }
            if term.count <= 4 { return term.uppercased() }
            return term
        }
        return localizedWords.joined(separator: " ")
    }

    private func _normalizedSavedPaperTag(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        return t.replacingOccurrences(of: "_", with: " ")
    }

    private func _savedPaperKeywordTokens(from text: String) -> [String] {
        let deCamelized = _savedPaperSplitCamelCase(text)
        let lower = deCamelized.lowercased()
        let parts = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
        var out: [String] = []
        out.reserveCapacity(parts.count)

        for raw in parts {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count < 3 { continue }
            if _savedPaperKeywordStopwords.contains(t) { continue }
            if Int(t) != nil { continue }
            out.append(t)
        }
        return out
    }

    private var _savedPaperKeywordStopwords: Set<String> {
        [
            "the", "and", "for", "with", "from", "into", "using", "towards", "through", "across",
            "under", "over", "without", "within", "via", "based", "this", "that", "these", "those",
            "are", "was", "were", "been", "being", "have", "has", "had", "its", "our", "their", "your",
            "can", "may", "will", "shall", "also", "new", "paper", "study", "method", "methods",
            "approach", "approaches", "result", "results", "task", "tasks", "analysis", "toward",
            "out", "limitation", "limitations", "achieve", "achieves", "achieved",
            "comprehensive", "guided", "oriented", "use", "uses", "used", "utilize", "utilized"
        ]
    }

    private var _savedPaperLabelGenericTokens: Set<String> {
        [
            "language", "languages", "model", "models", "llm", "llms",
            "large", "foundation", "artificial", "intelligence", "machine", "learning",
            "deep", "neural", "network", "networks",
            "paper", "study", "method", "methods", "approach", "approaches",
            "research", "survey", "surveys", "review", "reviews",
            "system", "systems", "task", "tasks", "data", "dataset", "datasets",
            "using", "based", "towards", "analysis", "new",
            "out", "limitation", "limitations", "guided", "oriented", "achieve",
            "use", "uses", "used", "utilize", "utilized", "utilizing",
            "arxiv", "pubmed", "pmid", "doi",
        ]
    }

    private var _savedPaperLabelGenericPhrases: Set<String> {
        [
            "language model",
            "language models",
            "large language model",
            "large language models",
            "foundation model",
            "foundation models",
            "machine learning",
            "deep learning",
            "neural network",
            "neural networks",
        ]
    }

    private var _savedPaperWeakSingleLabelTerms: Set<String> {
        [
            "benchmark", "benchmarks", "benchmarking",
            "specification", "specifications",
            "formal", "evaluation", "evaluations",
            "metric", "metrics", "performance",
            "limitations", "limitation",
            "approach", "approaches", "method", "methods",
            "survey", "review", "studies", "study",
            "comprehensive", "generation", "program",
        ]
    }

    private func _savedPaperPreferredTitle(metadata: _SavedPaperMetadataSidecar, fileName: String) -> String {
        let title = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }

        let rawTitle = metadata.rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawTitle.isEmpty { return rawTitle }

        return fileName
    }

    private func _savedPaperRowMeta(
        from metadata: _SavedPaperMetadataSidecar,
        fileName: String,
        featureKeywords: [String]
    ) -> _SavedPaperRowMeta {
        let title = _savedPaperPreferredTitle(metadata: metadata, fileName: fileName)
        let abstractText = _savedPaperNormalizedAbstractText(metadata.abstractText)

        return _SavedPaperRowMeta(
            title: title,
            fileName: fileName,
            featureKeywords: featureKeywords,
            sourceURL: metadata.sourceURL,
            providerRaw: metadata.provider,
            rawID: metadata.rawID,
            abstractText: abstractText,
            abstractPreview: _savedPaperAbstractPreview(abstractText),
            providerLabel: _savedPaperProviderLabel(
                providerRaw: metadata.provider,
                sourceURL: metadata.sourceURL
            )
        )
    }

    private func _savedPaperLocalizedFeatureKeyword(_ phrase: String) -> String {
        let localized = _savedPaperLocalizedLabelPhrase(phrase, preserveCase: false)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if localized.isEmpty { return "" }
        return localized
    }

    private func _savedPaperContainsJapaneseCharacters(_ text: String) -> Bool {
        text.range(of: #"[ぁ-んァ-ヶ一-龯]"#, options: .regularExpression) != nil
    }

    private func _savedPaperNormalizedAbstractText(_ text: String) -> String {
        var s = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while s.contains("  ") {
            s = s.replacingOccurrences(of: "  ", with: " ")
        }
        return s
    }

    private func _savedPaperAbstractPreview(_ text: String, maxLength: Int = 180) -> String {
        let s = _savedPaperNormalizedAbstractText(text)
        guard !s.isEmpty else { return "" }
        if s.count <= maxLength { return s }
        return String(s.prefix(maxLength)) + "…"
    }

    private func _savedPaperProviderLabel(providerRaw: String, sourceURL: String) -> String {
        let p = providerRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch p {
        case "arxiv":
            return "arXiv"
        case "pubmed":
            return "PubMed"
        case "acl":
            return "ACL Anthology"
        case "isca":
            return "ISCA Archive"
        default:
            break
        }

        if let host = URL(string: sourceURL)?.host?.lowercased() {
            if host.contains("aclanthology.org") {
                return "ACL Anthology"
            }
            if host.contains("isca-archive.org") {
                return "ISCA Archive"
            }
            if host.contains("arxiv.org") {
                return "arXiv"
            }
            if host.contains("pubmed.ncbi.nlm.nih.gov") || host.contains("ncbi.nlm.nih.gov") {
                return "PubMed"
            }
        }

        if p.isEmpty || p == "unknown" {
            return "unknown"
        }
        return p
    }

    private func _loadSavedPaperMetadataOrThrow(forPDF pdfURL: URL) throws -> _SavedPaperMetadataSidecar {
        let candidates = _savedPaperMetadataSidecarCandidates(forPDF: pdfURL)
        guard let sidecarURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -270,
                userInfo: [NSLocalizedDescriptionKey: "メタデータJSONが見つかりません: \(pdfURL.lastPathComponent)"]
            )
        }

        let data = try Data(contentsOf: sidecarURL)
        let jsonObj = try JSONSerialization.jsonObject(with: data, options: [])
        guard let root = jsonObj as? [String: Any] else {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -271,
                userInfo: [NSLocalizedDescriptionKey: "メタデータJSONの形式が不正です: \(sidecarURL.lastPathComponent)"]
            )
        }

        let title = _trimmedMetadataString(root["title"])
        var provider = _trimmedMetadataString(root["provider"]).lowercased()
        let sourceURL = _trimmedMetadataString(root["source_url"])
        var abstractText = _trimmedMetadataString(root["abstract"])

        var tags: [String] = []
        if let xs = root["tags"] as? [Any] {
            tags = xs.compactMap { _trimmedMetadataString($0) }.filter { !$0.isEmpty }
        }

        var rawID = ""
        var rawTitle = ""
        if let raw = root["raw"] as? [String: Any] {
            rawID = _trimmedMetadataString(raw["id"])
            rawTitle = _trimmedMetadataString(raw["title"])
            if abstractText.isEmpty {
                abstractText = _trimmedMetadataString(raw["abstract"])
            }
            let rawProvider = _trimmedMetadataString(raw["provider"]).lowercased()
            if provider.isEmpty {
                provider = rawProvider
            }
        }

        if title.isEmpty && rawTitle.isEmpty {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -272,
                userInfo: [NSLocalizedDescriptionKey: "メタデータJSONに title がありません: \(sidecarURL.lastPathComponent)"]
            )
        }
        if provider.isEmpty {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -273,
                userInfo: [NSLocalizedDescriptionKey: "メタデータJSONに provider がありません: \(sidecarURL.lastPathComponent)"]
            )
        }

        return _SavedPaperMetadataSidecar(
            title: title,
            provider: provider,
            sourceURL: sourceURL,
            abstractText: abstractText,
            tags: tags,
            rawID: rawID,
            rawTitle: rawTitle
        )
    }

    private func _savedPaperMetadataSidecarCandidates(forPDF pdfURL: URL) -> [URL] {
        let stem = pdfURL.deletingPathExtension()
        let raw: [URL] = [
            stem.appendingPathExtension("papermeta.json"),
            pdfURL.appendingPathExtension("papermeta.json"),
            stem.appendingPathExtension("json"),
            pdfURL.appendingPathExtension("json"),
        ]

        var seen: Set<String> = []
        var unique: [URL] = []
        unique.reserveCapacity(raw.count)
        for u in raw {
            let p = u.path
            if seen.insert(p).inserted {
                unique.append(u)
            }
        }
        return unique
    }

    private func _savedPaperMetadataPrimarySidecarURL(forPDF pdfURL: URL) -> URL {
        pdfURL
            .deletingPathExtension()
            .appendingPathExtension("papermeta.json")
    }

    @MainActor
    private func _generateMissingSavedPaperMetadataJSON(folderURL: URL) async {
        guard !_isGeneratingSavedPaperMetadataJSON else { return }

        _isGeneratingSavedPaperMetadataJSON = true
        _savedPaperMetadataGenerationStatusText = nil
        _savedPaperMetadataGenerationErrorText = nil
        defer { _isGeneratingSavedPaperMetadataJSON = false }

        let started = folderURL.startAccessingSecurityScopedResource()
        guard started else {
            _savedPaperMetadataGenerationErrorText = Inf6Lang.text(
                "保存先フォルダへのアクセス権を取得できませんでした。",
                "Could not access the destination folder."
            )
            return
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }

        do {
            let othersLabel = Inf6Lang.text("その他", "Others")
            let targetItems = _savedPapersListItems.filter { item in
                (_savedPapersClusterLabelByPath[item.url.path] ?? "") == othersLabel
            }
            guard !targetItems.isEmpty else {
                _savedPaperMetadataGenerationStatusText = Inf6Lang.text(
                    "『その他』分類の対象ファイルはありません。",
                    "No files are currently classified as Others."
                )
                return
            }

            var generatedCount = 0
            var renamedCount = 0
            var alreadyJSONCount = 0
            var noIDCount = 0
            var failures: [String] = []
            failures.reserveCapacity(8)

            for item in targetItems {
                if Task.isCancelled { throw CancellationError() }

                let pdfURL = item.url
                let metadata: _SavedPaperMetadataSidecar
                do {
                    metadata = try _loadSavedPaperMetadataOrThrow(forPDF: pdfURL)
                    alreadyJSONCount += 1
                } catch {
                    do {
                        try _writeGeneratedPaperMetadataSidecarOrThrow(forPDF: pdfURL)
                        generatedCount += 1
                        metadata = try _loadSavedPaperMetadataOrThrow(forPDF: pdfURL)
                    } catch {
                        failures.append("\(pdfURL.lastPathComponent): \(error.localizedDescription)")
                        continue
                    }
                }

                let metadataID = _savedPaperMetadataIDForFileName(metadata)
                if metadataID.isEmpty {
                    noIDCount += 1
                    continue
                }

                do {
                    let didRename = try _renameSavedPaperAndSidecarsOrThrow(
                        folderURL: folderURL,
                        pdfURL: pdfURL,
                        metadata: metadata,
                        metadataID: metadataID
                    )
                    if didRename {
                        renamedCount += 1
                    }
                } catch {
                    failures.append("\(pdfURL.lastPathComponent): \(error.localizedDescription)")
                }
            }

            _savedPaperMetadataGenerationStatusText = Inf6Lang.text(
                "その他分類更新: 対象 \(targetItems.count) 件 / JSON生成 \(generatedCount) 件 / ID名付与 \(renamedCount) 件 / IDなし \(noIDCount) 件 / 既存JSON \(alreadyJSONCount) 件 / 失敗 \(failures.count) 件",
                "Others update: target \(targetItems.count), generated \(generatedCount), renamed \(renamedCount), no id \(noIDCount), existing json \(alreadyJSONCount), failed \(failures.count)"
            )

            if !failures.isEmpty {
                let headCount = min(3, failures.count)
                let head = failures.prefix(headCount).joined(separator: "\n")
                let rest = failures.count - headCount
                if rest > 0 {
                    _savedPaperMetadataGenerationErrorText = head + "\n... (+\(rest))"
                } else {
                    _savedPaperMetadataGenerationErrorText = head
                }
            }

            _reloadSavedPapersList(folderURL: folderURL)
        } catch is CancellationError {
            _savedPaperMetadataGenerationErrorText = Inf6Lang.text(
                "その他分類更新を中断しました。",
                "Others update was cancelled."
            )
        } catch {
            _savedPaperMetadataGenerationErrorText = error.localizedDescription
        }
    }

    private func _savedPaperMetadataIDForFileName(_ metadata: _SavedPaperMetadataSidecar) -> String {
        let rawID = metadata.rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawID.isEmpty { return rawID }

        let provider = metadata.provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if provider == "arxiv" {
            let arxivID = _savedPaperArxivIDFromSourceURL(metadata.sourceURL)
            if !arxivID.isEmpty { return "arxiv:\(arxivID)" }
        }
        if provider == "pubmed" {
            let pmid = _savedPaperPubMedIDFromSourceURL(metadata.sourceURL)
            if !pmid.isEmpty { return "pubmed:\(pmid)" }
        }
        return ""
    }

    private func _savedPaperArxivIDFromSourceURL(_ sourceURL: String) -> String {
        let s = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let u = URL(string: s) else { return "" }
        return u.lastPathComponent
            .replacingOccurrences(of: ".pdf", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func _savedPaperPubMedIDFromSourceURL(_ sourceURL: String) -> String {
        let s = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let u = URL(string: s) else { return "" }
        for c in u.pathComponents.reversed() {
            let token = c.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty { continue }
            if Int(token) != nil { return token }
        }
        return ""
    }

    private func _parseArxivBaseAndVersion(fromCandidate raw: String) -> (base: String, version: Int?) {
        let s0 = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s0.isEmpty else { return ("", nil) }

        let normalized: String = {
            if let u = URL(string: s0), !u.lastPathComponent.isEmpty {
                return u.lastPathComponent
                    .replacingOccurrences(of: ".pdf", with: "", options: [.caseInsensitive])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if s0.lowercased().hasPrefix("arxiv:") {
                return String(s0.dropFirst("arxiv:".count))
            }
            return s0
        }()

        guard !normalized.isEmpty else { return ("", nil) }
        guard let vPos = normalized.lastIndex(of: "v") else { return (normalized, nil) }

        let afterV = normalized.index(after: vPos)
        guard afterV < normalized.endIndex else { return (normalized, nil) }

        let digits = String(normalized[afterV...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }), let version = Int(digits) else {
            return (normalized, nil)
        }

        let base = String(normalized[..<vPos]).trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return (normalized, nil) }
        return (base, version)
    }

    private func _savedPaperLocalArxivBaseAndVersion(
        item: _SavedPaperListItem,
        rowMeta: _SavedPaperRowMeta?
    ) -> (base: String, version: Int?) {
        let sidecarURL = item.url.appendingPathExtension("arxiv")
        if let local = try? _readSavedPaperLocalArxivSidecarVersionOrThrow(sidecarURL: sidecarURL),
           !local.base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return local
        }

        let parsedFromSource = _parseArxivBaseAndVersion(fromCandidate: rowMeta?.sourceURL ?? "")
        if !parsedFromSource.base.isEmpty { return parsedFromSource }

        let parsedFromRawID = _parseArxivBaseAndVersion(fromCandidate: rowMeta?.rawID ?? "")
        if !parsedFromRawID.base.isEmpty { return parsedFromRawID }

        return ("", nil)
    }

    @MainActor
    private func _checkSavedPaperLatestArxiv(
        item: _SavedPaperListItem,
        rowMeta: _SavedPaperRowMeta?
    ) async {
        let path = item.url.path
        if _savedPaperLatestCheckInFlightPath == path { return }

        _savedPaperLatestCheckInFlightPath = path
        _savedPaperLatestErrorByPath[path] = ""
        defer {
            if _savedPaperLatestCheckInFlightPath == path {
                _savedPaperLatestCheckInFlightPath = ""
            }
        }

        do {
            let providerRaw = rowMeta?.providerRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard providerRaw == "arxiv" else {
                throw NSError(
                    domain: "Inf6SavedPaperLatest",
                    code: -10,
                    userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("arXiv 論文のみ最新版確認できます。", "Latest-check is available only for arXiv papers.")]
                )
            }

            let local = _savedPaperLocalArxivBaseAndVersion(item: item, rowMeta: rowMeta)
            guard !local.base.isEmpty else {
                throw NSError(
                    domain: "Inf6SavedPaperLatest",
                    code: -11,
                    userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("arXiv ID を特定できませんでした（source_url/.arxiv を確認してください）。", "Could not determine arXiv ID. Check source_url or .arxiv sidecar.")]
                )
            }

            let remoteResults = try await Inf6ArxivClient.fetchByID(arxivID: local.base)
            guard let remote = remoteResults.first else {
                throw NSError(
                    domain: "Inf6SavedPaperLatest",
                    code: -12,
                    userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("arXiv から最新版情報を取得できませんでした。", "Could not fetch latest arXiv information.")]
                )
            }

            var parsedRemote = _parseArxivBaseAndVersion(fromCandidate: remote.id)
            if parsedRemote.base.isEmpty, let landing = remote.landingURL?.absoluteString {
                parsedRemote = _parseArxivBaseAndVersion(fromCandidate: landing)
            }
            if parsedRemote.base.isEmpty, let pdf = remote.pdfURL?.absoluteString {
                parsedRemote = _parseArxivBaseAndVersion(fromCandidate: pdf)
            }
            guard !parsedRemote.base.isEmpty else {
                throw NSError(
                    domain: "Inf6SavedPaperLatest",
                    code: -13,
                    userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("arXiv の最新版ID解析に失敗しました。", "Failed to parse latest arXiv id.")]
                )
            }

            let status = _SavedPaperLatestCheckStatus(
                baseID: local.base,
                localVersion: local.version,
                remoteVersion: parsedRemote.version,
                remoteLandingURL: remote.landingURL,
                remotePDFURL: remote.pdfURL
            )
            _savedPaperLatestByPath[path] = status
            _savedPaperLatestErrorByPath[path] = ""

        } catch {
            _savedPaperLatestErrorByPath[path] = error.localizedDescription
        }
    }

    private func _writeSavedPaperLocalArxivSidecarOrThrow(
        sidecarURL: URL,
        base: String,
        version: Int?,
        absURLString: String?
    ) throws {
        let b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty else {
            throw NSError(
                domain: "Inf6SavedPaperLatest",
                code: -20,
                userInfo: [NSLocalizedDescriptionKey: "arXiv base id is empty; cannot write .arxiv sidecar."]
            )
        }
        let vText = version.map { "v\($0)" } ?? "v?"
        let urlText = (absURLString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let line = urlText.isEmpty ? "\(b) \(vText)" : "\(b) \(vText) \(urlText)"
        let data = (line + "\n").data(using: .utf8) ?? Data()
        try data.write(to: sidecarURL, options: [.atomic])
    }

    private func _updateSavedPaperMetadataSidecarForArxivOrThrow(
        pdfURL: URL,
        base: String,
        version: Int?,
        sourceURL: String
    ) throws {
        let sidecarURL = _savedPaperMetadataPrimarySidecarURL(forPDF: pdfURL)
        var root: [String: Any] = [:]

        if FileManager.default.fileExists(atPath: sidecarURL.path) {
            let data = try Data(contentsOf: sidecarURL)
            if let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root = existing
            }
        }

        let cleanSourceURL = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingTitle = _trimmedMetadataString(root["title"])
        root["title"] = existingTitle.isEmpty ? pdfURL.deletingPathExtension().lastPathComponent : existingTitle
        root["provider"] = "arxiv"
        if !cleanSourceURL.isEmpty {
            root["source_url"] = cleanSourceURL
        }

        var raw = (root["raw"] as? [String: Any]) ?? [:]
        let idSuffix = version.map { "v\($0)" } ?? ""
        raw["id"] = "arxiv:\(base)\(idSuffix)"
        raw["provider"] = "arxiv"
        raw["title"] = _trimmedMetadataString(raw["title"]).isEmpty ? _trimmedMetadataString(root["title"]) : _trimmedMetadataString(raw["title"])
        raw["arxiv_id"] = base
        if let version {
            raw["arxiv_version"] = "v\(version)"
        } else {
            raw.removeValue(forKey: "arxiv_version")
        }

        let abstractText = _trimmedMetadataString(root["abstract"])
        if !abstractText.isEmpty {
            raw["abstract"] = abstractText
        }
        root["raw"] = raw

        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: sidecarURL, options: [.atomic])
    }

    @MainActor
    private func _updateSavedPaperToLatestArxiv(
        item: _SavedPaperListItem,
        rowMeta: _SavedPaperRowMeta?,
        folderURL: URL?
    ) async {
        let path = item.url.path
        if _savedPaperUpdateInFlightPath == path { return }

        _savedPaperUpdateInFlightPath = path
        defer {
            if _savedPaperUpdateInFlightPath == path {
                _savedPaperUpdateInFlightPath = ""
            }
        }

        do {
            guard let folderURL else {
                throw NSError(
                    domain: "Inf6SavedPaperLatest",
                    code: -30,
                    userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("保存先フォルダが未設定です。", "Destination folder is not set.")]
                )
            }

            if _savedPaperLatestByPath[path] == nil {
                await _checkSavedPaperLatestArxiv(item: item, rowMeta: rowMeta)
            }
            guard let status = _savedPaperLatestByPath[path] else {
                throw NSError(
                    domain: "Inf6SavedPaperLatest",
                    code: -31,
                    userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("最新版情報を取得できませんでした。", "Latest-check data is unavailable.")]
                )
            }
            guard status.hasUpdate else {
                _savedPaperLatestErrorByPath[path] = Inf6Lang.text("この論文は最新版です。", "This paper is already up to date.")
                return
            }
            guard let remotePDFURL = status.remotePDFURL else {
                throw NSError(
                    domain: "Inf6SavedPaperLatest",
                    code: -32,
                    userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("最新版PDFのURLを取得できませんでした。", "Latest PDF URL is unavailable.")]
                )
            }

            let started = folderURL.startAccessingSecurityScopedResource()
            guard started else {
                throw NSError(
                    domain: "Inf6SavedPaperLatest",
                    code: -33,
                    userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("保存先フォルダへのアクセス権を取得できませんでした。", "Could not access destination folder.")]
                )
            }
            defer { folderURL.stopAccessingSecurityScopedResource() }

            let pdfData = try await Inf6PaperSaveShared.downloadValidatedPDFData(from: remotePDFURL)
            try pdfData.write(to: item.url, options: [.atomic])

            let absURLString = status.remoteLandingURL?.absoluteString ?? status.remotePDFURL?.absoluteString
            let arxivSidecarURL = item.url.appendingPathExtension("arxiv")
            try _writeSavedPaperLocalArxivSidecarOrThrow(
                sidecarURL: arxivSidecarURL,
                base: status.baseID,
                version: status.remoteVersion,
                absURLString: absURLString
            )

            try _updateSavedPaperMetadataSidecarForArxivOrThrow(
                pdfURL: item.url,
                base: status.baseID,
                version: status.remoteVersion,
                sourceURL: absURLString ?? ""
            )

            await _checkSavedPaperLatestArxiv(item: item, rowMeta: rowMeta)
            _savedPaperLatestErrorByPath[path] = Inf6Lang.text("最新版へ更新しました。", "Updated to the latest version.")
            _reloadSavedPapersList(folderURL: folderURL, force: true)

            NotificationCenter.default.post(name: .inf6PaperPDFDidSave, object: nil, userInfo: ["pdfURL": item.url])

        } catch {
            _savedPaperLatestErrorByPath[path] = error.localizedDescription
        }
    }

    private func _renameSavedPaperAndSidecarsOrThrow(
        folderURL: URL,
        pdfURL: URL,
        metadata: _SavedPaperMetadataSidecar,
        metadataID: String
    ) throws -> Bool {
        let preferredTitle = _savedPaperPreferredTitle(metadata: metadata, fileName: pdfURL.lastPathComponent)
        let desiredFileName = try Inf6PaperStorage.safeFileName(title: preferredTitle, fallbackID: metadataID)
        if desiredFileName == pdfURL.lastPathComponent {
            return false
        }

        let fileManager = FileManager.default
        let destPDFURL = folderURL.appendingPathComponent(desiredFileName)
        guard !fileManager.fileExists(atPath: destPDFURL.path) else {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -278,
                userInfo: [NSLocalizedDescriptionKey: "同名ファイルが既に存在します: \(desiredFileName)"]
            )
        }

        let oldMetaCandidates = _savedPaperMetadataSidecarCandidates(forPDF: pdfURL)
            .filter { fileManager.fileExists(atPath: $0.path) }
        guard let sourceMetaURL = oldMetaCandidates.first else {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -270,
                userInfo: [NSLocalizedDescriptionKey: "メタデータJSONが見つかりません: \(pdfURL.lastPathComponent)"]
            )
        }
        let sourceMetaData = try Data(contentsOf: sourceMetaURL)

        let destMetaURL = _savedPaperMetadataPrimarySidecarURL(forPDF: destPDFURL)
        if fileManager.fileExists(atPath: destMetaURL.path) {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -279,
                userInfo: [NSLocalizedDescriptionKey: "同名メタデータが既に存在します: \(destMetaURL.lastPathComponent)"]
            )
        }

        let oldArxivURL = pdfURL.appendingPathExtension("arxiv")
        let oldArxivData: Data? = {
            guard fileManager.fileExists(atPath: oldArxivURL.path) else { return nil }
            return try? Data(contentsOf: oldArxivURL)
        }()
        let destArxivURL = destPDFURL.appendingPathExtension("arxiv")
        if oldArxivData != nil, fileManager.fileExists(atPath: destArxivURL.path) {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -280,
                userInfo: [NSLocalizedDescriptionKey: "同名arXivサイドカーが既に存在します: \(destArxivURL.lastPathComponent)"]
            )
        }

        var didMovePDF = false
        do {
            try fileManager.moveItem(at: pdfURL, to: destPDFURL)
            didMovePDF = true

            try sourceMetaData.write(to: destMetaURL, options: [.atomic])
            if let oldArxivData {
                try oldArxivData.write(to: destArxivURL, options: [.atomic])
            }

            for oldMetaURL in oldMetaCandidates where fileManager.fileExists(atPath: oldMetaURL.path) {
                try fileManager.removeItem(at: oldMetaURL)
            }
            if oldArxivData != nil, fileManager.fileExists(atPath: oldArxivURL.path) {
                try fileManager.removeItem(at: oldArxivURL)
            }
            return true
        } catch {
            if didMovePDF, fileManager.fileExists(atPath: destPDFURL.path) {
                try? fileManager.moveItem(at: destPDFURL, to: pdfURL)
            }
            if fileManager.fileExists(atPath: destMetaURL.path) {
                try? fileManager.removeItem(at: destMetaURL)
            }
            if fileManager.fileExists(atPath: destArxivURL.path) {
                try? fileManager.removeItem(at: destArxivURL)
            }
            throw error
        }
    }

    private struct _SavedPaperGeneratedProviderInfo {
        let provider: String
        let sourceURL: String
        let rawID: String
        let arxivID: String?
        let arxivVersion: String?
    }

    private func _writeGeneratedPaperMetadataSidecarOrThrow(forPDF pdfURL: URL) throws {
        #if canImport(PDFKit)
        guard let doc = PDFDocument(url: pdfURL), doc.pageCount > 0 else {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -275,
                userInfo: [NSLocalizedDescriptionKey: "PDFを開けませんでした: \(pdfURL.lastPathComponent)"]
            )
        }

        let title = _savedPaperGeneratedTitle(from: doc, pdfURL: pdfURL)
        let rawText = _savedPaperGeneratedRawText(from: doc, maxPages: 3, maxChars: 24_000)
        let abstractText = _savedPaperGeneratedAbstract(from: rawText)
        let providerInfo = _savedPaperGeneratedProviderInfo(forPDF: pdfURL)
        let tags = _savedPaperGeneratedTags(title: title, abstractText: abstractText)

        var raw: [String: Any] = [
            "id": providerInfo.rawID,
            "title": title,
            "provider": providerInfo.provider,
        ]
        if !abstractText.isEmpty {
            raw["abstract"] = abstractText
        }
        if let arxivID = providerInfo.arxivID {
            raw["arxiv_id"] = arxivID
        }
        if let arxivVersion = providerInfo.arxivVersion {
            raw["arxiv_version"] = arxivVersion
        }

        let payload: [String: Any] = [
            "title": title,
            "provider": providerInfo.provider,
            "source_url": providerInfo.sourceURL,
            "abstract": abstractText,
            "tags": tags,
            "raw": raw,
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: _savedPaperMetadataPrimarySidecarURL(forPDF: pdfURL), options: [.atomic])
        #else
        throw NSError(
            domain: "Inf6PaperCorpusClassification",
            code: -276,
            userInfo: [NSLocalizedDescriptionKey: "この環境ではPDFからJSONを生成できません。"]
        )
        #endif
    }

    private func _savedPaperGeneratedProviderInfo(forPDF pdfURL: URL) -> _SavedPaperGeneratedProviderInfo {
        let sidecarURL = pdfURL.appendingPathExtension("arxiv")
        if let local = try? _readSavedPaperLocalArxivSidecarVersionOrThrow(sidecarURL: sidecarURL),
           !local.base.isEmpty {
            let v = local.version.map { "v\($0)" } ?? ""
            let sourceURL: String = {
                if v.isEmpty { return "https://arxiv.org/pdf/\(local.base).pdf" }
                return "https://arxiv.org/pdf/\(local.base)\(v).pdf"
            }()
            let rawID = v.isEmpty ? "arxiv:\(local.base)" : "arxiv:\(local.base)\(v)"
            return _SavedPaperGeneratedProviderInfo(
                provider: "arxiv",
                sourceURL: sourceURL,
                rawID: rawID,
                arxivID: local.base,
                arxivVersion: v.isEmpty ? nil : v
            )
        }

        let stem = pdfURL.deletingPathExtension().lastPathComponent
        return _SavedPaperGeneratedProviderInfo(
            provider: "unknown",
            sourceURL: "",
            rawID: stem,
            arxivID: nil,
            arxivVersion: nil
        )
    }

    private func _readSavedPaperLocalArxivSidecarVersionOrThrow(sidecarURL: URL) throws -> (base: String, version: Int?) {
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else {
            return ("", nil)
        }
        let data = try Data(contentsOf: sidecarURL)
        let s = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return ("", nil) }

        let parts = s.split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return ("", nil) }
        let base = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return ("", nil) }

        var version: Int? = nil
        if parts.count >= 2 {
            let p = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if p.lowercased().hasPrefix("v") {
                let ds = String(p.dropFirst())
                version = Int(ds)
            }
        }
        return (base, version)
    }

    #if canImport(PDFKit)
    private func _savedPaperGeneratedTitle(from doc: PDFDocument, pdfURL: URL) -> String {
        if let metaTitle = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !metaTitle.isEmpty {
            return metaTitle
        }

        let maxPages = min(2, doc.pageCount)
        for pageIndex in 0..<maxPages {
            guard let page = doc.page(at: pageIndex), let pageText = page.string else { continue }
            let lines = pageText.components(separatedBy: .newlines)
            for rawLine in lines {
                let line = _savedPaperNormalizedLine(rawLine)
                if line.count < 8 || line.count > 220 { continue }

                let lower = line.lowercased()
                if lower == "abstract" || lower.hasPrefix("arxiv:") || lower.hasPrefix("http") { continue }
                if lower.hasPrefix("submitted") || lower.hasPrefix("accepted") { continue }
                return line
            }
        }

        return _savedPaperNormalizedLine(pdfURL.deletingPathExtension().lastPathComponent)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func _savedPaperGeneratedRawText(from doc: PDFDocument, maxPages: Int, maxChars: Int) -> String {
        guard doc.pageCount > 0, maxPages > 0, maxChars > 0 else { return "" }

        var chunks: [String] = []
        chunks.reserveCapacity(maxPages)
        var consumed = 0
        for i in 0..<min(maxPages, doc.pageCount) {
            guard let page = doc.page(at: i), let text = page.string else { continue }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }

            if consumed >= maxChars { break }
            let remaining = maxChars - consumed
            let clipped = text.count > remaining ? String(text.prefix(remaining)) : text
            chunks.append(clipped)
            consumed += clipped.count
        }
        return chunks.joined(separator: "\n")
    }

    private func _savedPaperGeneratedAbstract(from rawText: String) -> String {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        let scanRange = NSRange(text.startIndex..<text.endIndex, in: text)
        if let abstractRegex = try? NSRegularExpression(pattern: "\\babstract\\b[:\\s-]*", options: [.caseInsensitive]),
           let match = abstractRegex.firstMatch(in: text, options: [], range: scanRange),
           let abstractRange = Range(match.range, in: text) {
            let tail = String(text[abstractRange.upperBound...])
            let tailRange = NSRange(tail.startIndex..<tail.endIndex, in: tail)
            let stopPatterns: [String] = [
                "\\n\\s*(keywords?|index terms?)\\b",
                "\\n\\s*[0-9]+\\.?\\s+[A-Z]",
                "\\n\\s*[IVX]+\\.?\\s+[A-Z]",
            ]

            var stopIndex = tail.endIndex
            for pattern in stopPatterns {
                if let stopRegex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                   let stopMatch = stopRegex.firstMatch(in: tail, options: [], range: tailRange),
                   let r = Range(stopMatch.range, in: tail),
                   r.lowerBound < stopIndex {
                    stopIndex = r.lowerBound
                }
            }

            let candidate = _savedPaperNormalizedLine(String(tail[..<stopIndex]))
            if candidate.count >= 40 {
                if candidate.count <= 1000 { return candidate }
                return String(candidate.prefix(1000))
            }
        }

        let fallback = _savedPaperNormalizedLine(text)
        if fallback.count <= 900 { return fallback }
        return String(fallback.prefix(900))
    }
    #endif

    private func _savedPaperGeneratedTags(title: String, abstractText: String) -> [String] {
        let blob = [title, abstractText].joined(separator: " ")
        let tokens = _savedPaperKeywordTokens(from: blob)
        guard !tokens.isEmpty else { return [] }

        var counts: [String: Int] = [:]
        counts.reserveCapacity(tokens.count)
        for t in tokens {
            counts[t, default: 0] += 1
        }

        let sorted = counts.keys.sorted { lhs, rhs in
            let lc = counts[lhs] ?? 0
            let rc = counts[rhs] ?? 0
            if lc != rc { return lc > rc }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        return Array(sorted.prefix(8))
    }

    private func _savedPaperNormalizedLine(_ raw: String) -> String {
        var s = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while s.contains("  ") {
            s = s.replacingOccurrences(of: "  ", with: " ")
        }
        return s
    }

    private func _savedPaperClassificationAssetEvidence(_ raw: String?) -> String {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "" }

        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var out: [String] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            let normalized = _savedPaperNormalizedLine(line)
            if normalized.isEmpty { continue }
            out.append(String(normalized.prefix(360)))
        }
        let merged = out.joined(separator: "\n")
        return String(merged.prefix(1200))
    }

    private func _savedPaperMetadataFeatureText(
        _ metadata: _SavedPaperMetadataSidecar,
        assetFeatureText: String?
    ) throws -> String {
        var lines: [String] = []
        lines.reserveCapacity(10)

        lines.append("source: \(metadata.provider)")

        if !metadata.title.isEmpty {
            lines.append("title: \(metadata.title)")
        }
        if !metadata.rawTitle.isEmpty, metadata.rawTitle != metadata.title {
            lines.append("raw_title: \(metadata.rawTitle)")
        }
        if !metadata.rawID.isEmpty {
            lines.append("id: \(metadata.rawID)")
        }
        if !metadata.abstractText.isEmpty {
            lines.append("abstract: \(metadata.abstractText)")
        }
        if !metadata.tags.isEmpty {
            lines.append("tags: \(metadata.tags.joined(separator: ", "))")
        }
        if !metadata.sourceURL.isEmpty {
            lines.append("url: \(metadata.sourceURL)")
        }
        let assets = assetFeatureText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !assets.isEmpty {
            lines.append(assets)
        }

        let text = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        guard !text.isEmpty else {
            throw NSError(
                domain: "Inf6PaperCorpusClassification",
                code: -274,
                userInfo: [NSLocalizedDescriptionKey: "分類に必要な論文メタデータが空です。"]
            )
        }
        return text
    }

    private func _trimmedMetadataString(_ any: Any?) -> String {
        guard let s = any as? String else { return "" }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func _resolvePapersSaveFolderURLOrError() -> (url: URL?, error: String?) {
        do {
            let u = try _resolvePapersSaveFolderURL()
            return (u, nil)
        } catch {
            if _papersSaveFolderBookmarkB64_active.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (nil, nil)
            }
            let ns = error as NSError
            return (nil, "\(ns.domain) (\(ns.code)): \(ns.localizedDescription)")
        }
    }
    
    @MainActor
    private func _validatePapersFolderAccess(folderURL: URL?) {
        _papersFolderAccessErrorText = nil
        _papersFolderAccessOK = nil

        guard let folderURL else { return }

        let started = folderURL.startAccessingSecurityScopedResource()
        defer { if started { folderURL.stopAccessingSecurityScopedResource() } }

        if !_isReadableDirectoryURL(folderURL) {
            _papersFolderAccessOK = false
            _papersFolderAccessErrorText = Inf6Lang.text(
                "この端末では追加済みフォルダへアクセスできませんでした。『マッピング追加…』で同じ保存先フォルダを追加し直してください。",
                "This device could not access the added folder. Please add the same storage folder again via 'Add mapping…'."
            )
            return
        }

        if !_canCreateSubfolderUnderPapersDestination(folderURL: folderURL) {
            _papersFolderAccessOK = false
            _papersFolderAccessErrorText = Inf6Lang.text(
                "保存先フォルダへの読取は可能ですが、サブフォルダを作成できません。『マッピング追加…』で書込可能な保存先フォルダを再選択してください。",
                "The destination folder is readable but cannot create subfolders. Re-add a writable storage folder via 'Add mapping…'."
            )
            return
        }

        _papersFolderAccessOK = true
    }

    private func _canCreateSubfolderUnderPapersDestination(folderURL: URL) -> Bool {
        let fm = FileManager.default
        let probeURL = folderURL
            .appendingPathComponent(".inf6_write_probe_\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: probeURL, withIntermediateDirectories: false, attributes: nil)
            try fm.removeItem(at: probeURL)
            return true
        } catch {
            try? fm.removeItem(at: probeURL)
            return false
        }
    }

    private func _resolvePapersSaveFolderURL() throws -> URL {
        let b64 = _papersSaveFolderBookmarkB64_active.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b64.isEmpty else {
            throw NSError(
                domain: "Inf6PaperSave",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "Save destination folder is not selected."]
            )
        }
        guard let data = Data(base64Encoded: b64) else {
            throw NSError(
                domain: "Inf6PaperSave",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "Save destination bookmark is invalid. Please choose the folder again."]
            )
        }

        #if os(macOS)
        let opts: URL.BookmarkResolutionOptions = [.withoutUI, .withSecurityScope]
        #else
        let opts: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif

        var stale = false
        let u = try URL(
            resolvingBookmarkData: data,
            options: opts,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )

        if stale {
            throw NSError(
                domain: "Inf6PaperSave",
                code: -12,
                userInfo: [NSLocalizedDescriptionKey: "Save destination bookmark is stale. Please choose the folder again in 'PDF destination'."]
            )
        }

        return u
    }

    // MARK: - Lifecycle

    @MainActor
    private func _requireExternalIdentity() -> String? {
        let email = _externalAPIEmail.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !email.isEmpty else {
            _identityIssue = .missing
            _errorText = Inf6Lang.text(
                "E-mail アドレスが未設定です。設定画面で E-mail アドレスを設定してください。",
                "Contact email address is not set. Please set your email address in Settings."
            )
            return nil
        }

        // Minimal, deterministic validation: email must look like an email.
        guard email.contains("@") else {
            _identityIssue = .invalid
            _errorText = Inf6Lang.text(
                "E-mail アドレスの形式が不正です（'@' を含む必要があります）。",
                "The email format is invalid (must contain '@')."
            )
            return nil
        }

        _identityIssue = nil
        return email
    }

    @MainActor
    private func _bootstrapOnce() async {
        guard _fields.isEmpty, !_isLoadingFields else { return }
        await _reloadFields(resetSelection: true)
    }

    // MARK: - Field loading

    @MainActor
    private func _reloadFields(resetSelection: Bool) async {
        if _isLoadingFields { return }
        _errorText = nil
        _results = []
        _issuesByResultID = [:]

        _isLoadingFields = true
        defer { _isLoadingFields = false }

        let identity: String?
        switch _source {
        case .arxiv, .pubmed:
            guard let externalIdentity = _requireExternalIdentity() else {
                _fields = []
                if resetSelection {
                    _selectedFieldID = ""
                    _fieldSearchText = ""
                }
                return
            }
            identity = externalIdentity
        case .acl, .isca, .openalex:
            _identityIssue = nil
            identity = nil
        }

        do {
            switch _source {
            case .arxiv:
                let fetched = try await Inf6ArxivCategoryTaxonomyClient.fetchFields()
                _fields = fetched

            case .pubmed:
                let fetched = try await Inf6MeshTopCategoriesClient.fetchTopCategories(identity: identity ?? "")
                _fields = fetched
            case .acl, .isca, .openalex:
                _fields = []
            }

            if resetSelection {
                _selectedFieldID = ""
                _fieldSearchText = ""
            }
        } catch {
            _errorText = error.localizedDescription
            _fields = []
            _selectedFieldID = ""
        }
    }
    // MARK: - Paper loading

    @MainActor
    private func _loadPapersForSelectedField() async {
        if _isLoadingPapers { return }
        _errorText = nil
        _results = []
        _issuesByResultID = [:]

        let f = _selectedFieldID.trimmingCharacters(in: .whitespacesAndNewlines)
        let directID = _directArxivID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceQuery = _directSourceQueryInput.trimmingCharacters(in: .whitespacesAndNewlines)

        // In arXiv mode, allow direct-ID search even when no taxonomy field is selected.
        if _source == .arxiv {
            guard !directID.isEmpty || !f.isEmpty else { return }
        } else if _source == .acl || _source == .isca || _source == .openalex {
            guard !sourceQuery.isEmpty || !f.isEmpty else { return }
        } else {
            guard !f.isEmpty else { return }
        }

        let identity: String?
        switch _source {
        case .pubmed:
            guard let externalIdentity = _requireExternalIdentity() else { return }
            identity = externalIdentity
        case .arxiv, .acl, .isca, .openalex:
            identity = nil
        }

        _isLoadingPapers = true
        defer { _isLoadingPapers = false }

        do {
            switch _source {
            case .arxiv:
                let papers: [Inf6PaperSearchResult]
                if !directID.isEmpty {
                    papers = try await Inf6ArxivClient.fetchByID(arxivID: directID)
                } else {
                    papers = try await Inf6ArxivClient.fetchRecent(category: f, maxResults: 20)
                }
                _results = papers
                _issuesByResultID = [:]

            case .pubmed:
                let papers = try await Inf6PubMedClient.fetchRecent(meshHeading: f, maxResults: 20, identityEmail: identity ?? "")
                _results = papers
                _issuesByResultID = [:]
            case .acl:
                let query = sourceQuery.isEmpty ? f : sourceQuery
                let papers = try await Inf6ACLAnthologyClient.search(query: query, maxResults: 20)
                _results = papers
                _issuesByResultID = [:]
            case .isca:
                let query = sourceQuery.isEmpty ? f : sourceQuery
                let papers = try await Inf6ISCAArchiveClient.search(query: query, maxResults: 20)
                _results = papers
                _issuesByResultID = [:]
            case .openalex:
                let query = sourceQuery.isEmpty ? f : sourceQuery
                let papers = try await Inf6OpenAlexClient.search(query: query, maxResults: 20)
                _results = papers
                _issuesByResultID = [:]
            }
        } catch {
            _errorText = error.localizedDescription
            _results = []
            _issuesByResultID = [:]
        }
    }
}
