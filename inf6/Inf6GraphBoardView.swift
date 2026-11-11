//
//  Inf6GraphBoardView.swift
//  inf6
//
//  回路基板ビューの観測済み概念集合表示。
//  Inf6CircuitBoardView と同じ公開 API を持ち、内部は
//  Inf6KnowledgeGraphView を使用する。
//
//  ## 工学的契約 (Engineering Contract)
//
//  ### ログ体系 [inf6-venn]
//  全ログは NSLog("[inf6-venn] ...") プレフィクスで統一。
//  各フェーズのタイミング（ms）とデータ件数を出力する。
//
//  フェーズ別ログ:
//    _reloadModel      — 入力ドメイン数、inputKey
//    _makeModel         — 開始、conceptSets構築(ms,概念数)、完了(ms,syllabusItems数)
//    _toggleSelection   — パターンID、breakdown構築(ms,subsets数)
//    _subsetBreakdown   — paperIDsByConceptID(ms)、papers(ms,件数)
//    _preloadLinkedPaperIDs — sourceFamily、links数、nodes数(ms)
//
//  ### スレッディング契約
//  - _makeModel:        DispatchQueue.global(qos: .userInitiated) で実行。結果はメインスレッドで _model に格納。
//  - _toggleSelection:  選択追加時は DispatchQueue.global(qos: .userInitiated) で _subsetBreakdown を実行。
//                       _loadingPatternID で UI にスピナー表示。完了後メインスレッドで state 更新。
//  - _subsetBreakdown:  バックグラウンドスレッドで呼ばれる前提。MetadataStore I/O を含む。
//                       メインスレッドで呼んではならない。
//
//  ### データソース契約
//  - 概念集合: Inf6SyllabusConceptSetBuilder.conceptIDs(for:sourceFamily:) を使用。
//             MetadataStore の knowledgeMemberships / knowledgeEvidence は使用しない。
//             理由: iCloud 上の evidence ファイル（366件）読み込みが 5秒超タイムアウトするため。
//  - 論文リンク: _preloadLinkedPaperIDs で listByPrefix 一括読み込み。
//              ノード単位の linkedPaperIDs() 呼び出しは禁止（173回の I/O が発生するため）。
//  - _checkPipelineStatus: onAppear/onReceive から呼ばれる。
//              DispatchQueue.global(qos: .utility) で実行し、結果をメインスレッドで _pipelineStatus に格納。
//              メインスレッドで同期呼び出し禁止（linkedPaperIDs + MetadataStore I/O でフリーズするため）。
//

import CryptoKit
import Foundation
import SwiftUI


private struct _Inf6DomainLoadFailure {
    let familyID: String
    let displayName: String
    let message: String
    let canUpdate: Bool
}

// MARK: - Inf6GraphBoardView

struct Inf6GraphBoardView: View {

    var focusRawID: String? = nil
    var onSelectNode: ((String) -> Void)?
    var onSelectPaper: ((String) -> Void)?
    let onSearchConcept: (Inf6ConceptPaperSearchRequest) -> Void

    @State private var _domains: [Inf6KnowledgeGraphView._KnowledgeGraphDomain] = []
    @State private var _isLoading = true
    @State private var _loadRunID: UUID?

    var body: some View {
        Group {
            if _isLoading && _domains.isEmpty {
                Color(uiColor: .systemBackground)
                    .overlay {
                        _Inf6LargeProgressStatus(
                            title: Inf6Lang.text("ドメイン構造を読み込み中", "Loading domain structures"),
                            detail: Inf6Lang.text("fingerprint を確認し、保存済み構造を復元しています。", "Checking fingerprints and restoring cached structures."),
                            onCancel: _cancelLoad
                        )
                    }
            } else if _domains.isEmpty {
                Color(uiColor: .systemBackground)
            } else if _isHomeFocus {
                _Inf6VennHomeView(
                    domains: _domains,
                    onSelectPaper: onSelectPaper,
                    onUpdateDomain: { fid in _runDomainUpdate(familyID: fid) }
                )
                .id(_taskID)
                .overlay(alignment: .bottomTrailing) {
                    if _isLoading {
                        _Inf6LargeProgressStatus(
                            title: Inf6Lang.text("ドメインを更新中", "Updating domains"),
                            detail: Inf6Lang.text("domain structure を順次読み込んでいます。", "Loading domain structures incrementally."),
                            compact: true,
                            onCancel: _cancelLoad
                        )
                        .padding(.trailing, 24)
                        .padding(.bottom, 24)
                    }
                }
            } else {
                Inf6KnowledgeGraphView(
                    domains: _domains,
                    showPapers: _showPapers,
                    onSelectNode: onSelectNode,
                    onSelectPaper: onSelectPaper,
                    onSearchConcept: onSearchConcept
                )
                // フォーカス変更時にグラフを再構築するため id を切り替える
                .id(_taskID)
                .overlay(alignment: .bottomTrailing) {
                    if _isLoading {
                        _Inf6LargeProgressStatus(
                            title: Inf6Lang.text("ナレッジ構造を更新中", "Updating knowledge structure"),
                            detail: Inf6Lang.text("選択ドメインの構造を再読み込みしています。", "Reloading the selected domain structure."),
                            compact: true,
                            onCancel: _cancelLoad
                        )
                        .padding(.trailing, 24)
                        .padding(.bottom, 24)
                    }
                }
            }
        }
        .textSelection(.enabled)
        .ignoresSafeArea()
        .task(id: _taskID) {
            await _load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .inf6SyllabusPaperLinksDidChange)) { _ in
            Task {
                await _load()
            }
        }
    }

    // MARK: - Static cache invalidation (Inf6CircuitBoardView 互換)

    static func invalidateRenderedCache() {
        Inf6KnowledgeDomainStructureStore.invalidateCache()
    }

    // MARK: - Private helpers

    private var _showPapers: Bool {
        guard let focus = focusRawID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !focus.isEmpty else { return false }
        return !focus.hasPrefix("home:") && !_isHomeDomainFocus(focus)
    }

    private var _taskID: String { focusRawID ?? "" }

    private var _isHomeFocus: Bool {
        guard let focus = focusRawID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !focus.isEmpty else { return true }
        return focus.hasPrefix("home:") || _isHomeDomainFocus(focus)
    }

    private func _isHomeDomainFocus(_ raw: String) -> Bool {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("microsoft_ai_102")
            || normalized.contains("microsoft_ai_103")
            || normalized.contains("ai-102")
            || normalized.contains("ai-103")
            || normalized.contains("jdla_gkentei")
            || normalized.contains("gkentei")
            || normalized.contains("g-kentei")
            || normalized.contains("jdla_eshikaku")
            || normalized.contains("eshikaku")
            || normalized.contains("e-shikaku")
    }

    private func _load() async {
        let runID = UUID()
        _loadRunID = runID
        let isFirstLoad = _domains.isEmpty
        defer {
            if _loadRunID == runID {
                _isLoading = false
                _loadRunID = nil
            }
        }
        _isLoading = true
        // 既にドメインが表示されている状態でのバックグラウンド再読み込みでは、
        // _domains を空にしない。空にするとフルスクリーンの読み込みスピナー条件
        // (_isLoading && _domains.isEmpty) が再度成立し、画面が白紙に戻ってしまう。
        if isFirstLoad {
            _domains = []
        }
        let manifests: [Inf6LearningFamilyManifest]
        var failures: [_Inf6DomainLoadFailure] = []
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try await Inf6LearningFamilyManifestStore.loadCurrentSyllabusDomainsEnsuringDownloaded()
            }.value
            manifests = result.manifests
            failures = result.failures.map { failure in
                _Inf6DomainLoadFailure(
                    familyID: failure.familyID,
                    displayName: failure.displayName,
                    message: failure.message,
                    canUpdate: false
                )
            }
        } catch is CancellationError {
            return
        } catch {
            guard _loadRunID == runID, !Task.isCancelled else { return }
            NSLog("[inf6-board] domain manifest load failed: %@", error.localizedDescription)
            return
        }
        let focus = focusRawID?.trimmingCharacters(in: .whitespacesAndNewlines)

        var loaded: [Inf6KnowledgeGraphView._KnowledgeGraphDomain] = []
        let paperStore: Inf6CorePaperStore? = nil
        var outlineCache = _loadOutlineCache()
        for manifest in manifests {
            do {
                if let focus, !focus.isEmpty, !focus.hasPrefix("home:"), !focus.hasPrefix("concept:") {
                    let lf = focus.lowercased()
                    let sf = manifest.sourceFamily.lowercased()
                    let fid = manifest.familyID.lowercased()
                    guard lf.contains(sf) || lf.contains(fid) else { continue }
                }

                let outlineItems: [Inf6SyllabusOutlineItem]
                do {
                    outlineItems = try await _findOutlineItems(for: manifest, cache: outlineCache)
                } catch {
                    // 初回起動時に保存済みアウトラインがない場合だけ、正本ソースを同期して再取得する。
                    // 内部エラーを画面へ渡さず、成功した実データだけを次の処理へ渡す。
                    try Task.checkCancellation()
                    try await Inf6SyllabusConceptSetSynchronizer.synchronizeWithUserApproval(manifest: manifest)
                    outlineCache = _loadOutlineCache()
                    outlineItems = try await _findOutlineItems(for: manifest, cache: outlineCache)
                }
                guard _loadRunID == runID, !Task.isCancelled else { return }
                outlineCache = _loadOutlineCache()
                let syllabusVersionID = _resolvedKnowledgeStructureVersionID(for: manifest)
                let capturedManifest = manifest
                nonisolated(unsafe) let capturedOutlineItems = outlineItems
                let capturedVersionID = syllabusVersionID
                nonisolated(unsafe) let capturedPaperStore = paperStore
                let structure: Inf6KnowledgeDomainStructure = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        NSLog("[inf6-board] _load: loadOrSeed %@ (background)", capturedManifest.sourceFamily)
                        do {
                            let s = try Inf6KnowledgeDomainStructureStore.loadOrSeed(
                                manifest: capturedManifest,
                                syllabusVersionID: capturedVersionID,
                                domainTitleJa: capturedManifest.displayNameJa,
                                outlineItems: capturedOutlineItems,
                                paperStore: capturedPaperStore
                            )
                            NSLog("[inf6-board] _load: %@ done, nodes=%d", capturedManifest.sourceFamily, s.nodes.count)
                            continuation.resume(returning: s)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                guard _loadRunID == runID, !Task.isCancelled else { return }

                loaded.append(Inf6KnowledgeGraphView._KnowledgeGraphDomain(
                    manifest: manifest,
                    structure: structure,
                    accentColor: _parseHex(manifest.accentColorHex) ?? .blue
                ))
                // 初回ロードのみ逐次表示（体感速度優先）。バックグラウンド更新では
                // 全ドメインが揃うまで既存表示を維持し、末尾で一括差し替える。
                if isFirstLoad {
                    _domains = loaded
                }
            } catch is CancellationError {
                return
            } catch {
                guard _loadRunID == runID, !Task.isCancelled else { return }
                failures.append(_Inf6DomainLoadFailure(
                    familyID: manifest.familyID,
                    displayName: manifest.displayNameJa,
                    message: error.localizedDescription,
                    canUpdate: true
                ))
            }
        }
        guard _loadRunID == runID, !Task.isCancelled else { return }
        _domains = loaded
        if !failures.isEmpty {
            let failureSummary = failures.map { "\($0.displayName): \($0.message)" }.joined(separator: " | ")
            NSLog("[inf6-board] domain load failures: %@", failureSummary)
        }
        guard _loadRunID == runID, !Task.isCancelled else { return }
    }

    private func _cancelLoad() {
        _loadRunID = nil
        _isLoading = false
    }

    private func _runDomainUpdate(familyID: String) {
        Task {
            let manifests = Inf6LearningFamilyManifestStore.loadCurrentSyllabusDomains()
            if let manifest = manifests.first(where: { $0.familyID == familyID }) {
                do {
                    try await Inf6SyllabusConceptSetSynchronizer.synchronizeWithUserApproval(manifest: manifest)
                } catch {
                    NSLog("[inf6] Domain update failed for %@: %@", familyID, error.localizedDescription)
                }
            }
            await _load()
        }
    }

    private func _loadOutlineCache() -> [String: [Inf6SyllabusOutlineItem]] {
        guard let url = try? Inf6Storage.syllabusOutlineCacheURL() else { return [:] }
        return Inf6DiskJSON.load([String: [Inf6SyllabusOutlineItem]].self, from: url) ?? [:]
    }

    private func _findOutlineItems(
        for manifest: Inf6LearningFamilyManifest,
        cache: [String: [Inf6SyllabusOutlineItem]]
    ) async throws -> [Inf6SyllabusOutlineItem] {
        if manifest.usesMicrosoftLearnProvider {
            let existing = _findMicrosoftLearnOutlineItems(for: manifest, cache: cache)
            if !existing.isEmpty {
                return existing
            }

            throw NSError(
                domain: "Inf6GraphBoardView",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Microsoft Learn outline cache is empty: \(manifest.sourceFamily)"]
            )
        }

        let patterns: [String] = {
            switch manifest.familyID {
            case "g-kentei":  return ["gkentei_outline", "g-syllabus", "g%e6%a4%9c%e5%ae%9a"]
            case "e-shikaku": return ["eshikaku_outline", "e-syllabus", "e%e8%b3%87%e6%a0%bc"]
            default:          return []
            }
        }()
        guard !patterns.isEmpty else {
            throw NSError(
                domain: "Inf6GraphBoardView",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Syllabus outline source is not defined: \(manifest.sourceFamily)"]
            )
        }
        var candidates: [[Inf6SyllabusOutlineItem]] = []
        for (key, items) in cache {
            let lk = key.lowercased()
            if patterns.contains(where: { lk.contains($0) }) {
                candidates.append(items)
            }
        }
        guard let selected = candidates.max(by: { $0.count < $1.count }), !selected.isEmpty else {
            throw NSError(
                domain: "Inf6GraphBoardView",
                code: 13,
                userInfo: [NSLocalizedDescriptionKey: "Syllabus outline cache is empty: \(manifest.sourceFamily)"]
            )
        }
        return selected
    }

    private func _findMicrosoftLearnOutlineItems(
        for manifest: Inf6LearningFamilyManifest,
        cache: [String: [Inf6SyllabusOutlineItem]]
    ) -> [Inf6SyllabusOutlineItem] {
        let sourceURLs = Set((manifest.currentSources ?? []).map {
            $0.urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })
        guard !sourceURLs.isEmpty else { return [] }

        var candidates: [[Inf6SyllabusOutlineItem]] = []
        for (key, items) in cache {
            let lowKey = key.lowercased()
            guard lowKey.hasSuffix("|microsoft_learn_outline_bilingual_v1") else { continue }
            if sourceURLs.contains(where: { lowKey.contains($0) }) {
                candidates.append(items)
            }
        }
        return candidates.max(by: { $0.count < $1.count }) ?? []
    }

    private func _resolvedKnowledgeStructureVersionID(for manifest: Inf6LearningFamilyManifest) -> String {
        if let examName = _examName(for: manifest),
           let info = Inf6SyllabusUpdateChecker.shared.examScheduleInfo(for: examName) {
            let versionID = info.preferredKnowledgeStructureID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !versionID.isEmpty { return versionID }
        }
        return manifest.displayNameJa.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func _examName(for manifest: Inf6LearningFamilyManifest) -> String? {
        switch manifest.familyID {
        case "e-shikaku": return "E資格"
        case "g-kentei":  return "G検定"
        case "ai-102":    return "AI-102"
        case "ai-103":    return "AI-103"
        default:          return nil
        }
    }

    private func _sourceKind(for manifest: Inf6LearningFamilyManifest) -> Inf6KnowledgeSourceKind {
        if manifest.usesMicrosoftLearnProvider { return .microsoftLearn }
        if manifest.supportsPaperSearchProviders { return .arxivPaper }
        if manifest.usesJDLAHTMLProvider { return .jdlaGKenteiSyllabus }
        return .other
    }

    private func _parseHex(_ hex: String) -> Color? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let val = UInt64(s, radix: 16) else { return nil }
        let r = Double((val >> 16) & 0xFF) / 255.0
        let g = Double((val >> 8)  & 0xFF) / 255.0
        let b = Double(val         & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}

private struct _Inf6LargeProgressStatus: View {
    let title: String
    let detail: String
    var compact: Bool = false
    var onCancel: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: compact ? 12 : 16) {
            ProgressView()
                .controlSize(.large)
                .scaleEffect(compact ? 1.2 : 1.45)
                .frame(width: compact ? 34 : 46, height: compact ? 34 : 46)

            VStack(alignment: .leading, spacing: compact ? 3 : 6) {
                Text(title)
                    .font(.system(size: compact ? 15 : 18, weight: .heavy))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                Text(detail)
                    .font(.system(size: compact ? 12 : 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if let onCancel {
                Button(role: .cancel, action: onCancel) {
                    Label(Inf6Lang.text("キャンセル", "Cancel"), systemImage: "xmark.circle.fill")
                        .font(.system(size: compact ? 13 : 15, weight: .bold))
                }
                .buttonStyle(.bordered)
                .controlSize(compact ? .small : .regular)
            }
        }
        .padding(compact ? 12 : 18)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(uiColor: .systemBackground).opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.blue.opacity(0.26), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 14, x: 0, y: 8)
    }
}

private struct _Inf6VennHomeView: View {
    let domains: [Inf6KnowledgeGraphView._KnowledgeGraphDomain]
    let onSelectPaper: ((String) -> Void)?
    var onUpdateDomain: ((String) -> Void)?
    @State private var _model: _VennModel?
    @State private var _selectedSubsetBreakdowns: [_SetMembershipSubsetBreakdown] = []
    @State private var _selectedPatternIDs: Set<String> = []
    @State private var _showIntensiveDrill = false
    @State private var _breakdownRunID: UUID?
    @State private var _modelRunID: UUID?
    @State private var _domainsNeedingUpdate: Set<String> = []
    @State private var _reloadDebounceTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ScrollView(.vertical) {
                Group {
                    if let model = _model, model.domains.count >= 2 {
                        VStack(alignment: .leading, spacing: 22) {
                            _SetMembershipMapView(
                                model: model,
                                selectedPatternIDs: _selectedPatternIDs,
                                domainsNeedingUpdate: _domainsNeedingUpdate,
                                onSelectPattern: { row in
                                    _toggleSelection(row, model: model)
                                },
                                onUpdateDomain: onUpdateDomain,
                                onOpenIntensiveDrill: {
                                    withAnimation(.easeInOut(duration: 0.25)) { _showIntensiveDrill = true }
                                }
                            )

                            if _loadingPatternID != nil {
                                _Inf6LargeProgressStatus(
                                    title: Inf6Lang.text("部分集合を展開中", "Building subset breakdown"),
                                    detail: Inf6Lang.text("membership pattern、論文リンク、進捗サマリを照合しています。", "Resolving membership pattern, paper links, and progress summary."),
                                    compact: true,
                                    onCancel: _cancelSubsetBreakdown
                                )
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.top, 8)
                            }

                            if !_selectedSubsetBreakdowns.isEmpty {
                                _SetMembershipSelectionSideView(selections: _selectedSubsetBreakdowns) { selection in
                                    _removeSelection(selection)
                                } onSelectPaper: { paperID in
                                    onSelectPaper?(paperID)
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    } else if let model = _model {
                        _UnsupportedVennDomainCountView(count: model.domains.count)
                            .frame(width: 360)
                    } else {
                        Color.clear
                    }
                }
                .padding(.horizontal, 0)
                .padding(.top, 56)
                .padding(.bottom, 28)
                .frame(width: size.width, alignment: .top)
                .frame(minHeight: size.height, alignment: .top)
            }
            .background(Color(uiColor: .systemBackground))
        }
        .ignoresSafeArea()
        .onAppear {
            _reloadModel()
            _reloadDomainUpdateState()
        }
        .inf6OnChange(_modelInputKey) { _ in
            _selectedPatternIDs.removeAll()
            _selectedSubsetBreakdowns.removeAll()
            // 短時間に複数回変化することがあるため、少し待ってからまとめて再計算する。
            _reloadDebounceTask?.cancel()
            _reloadDebounceTask = Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                _reloadModel()
                _reloadDomainUpdateState()
            }
        }
        .onDisappear {
            _reloadDebounceTask?.cancel()
            _reloadDebounceTask = nil
        }
        .navigationDestination(isPresented: $_showIntensiveDrill) {
            Inf6IntensiveDrillView(
                sourceFamily: _eshikakuSourceFamily
            )
        }
        .textSelection(.enabled)
    }

    private var _eshikakuSourceFamily: String {
        domains.first(where: {
            $0.manifest.sourceFamily.lowercased().contains("eshikaku")
        })?.manifest.sourceFamily ?? "jdla_eshikaku"
    }

    private func _reloadModel() {
        let runID = UUID()
        _modelRunID = runID
        let inputKey = _modelInputKey
        let currentDomains = domains
        let tintsByDomainID = Dictionary(uniqueKeysWithValues: currentDomains.map {
            ($0.manifest.sourceFamily, $0.accentColor)
        })
        if let cached = Self._loadCachedModel(inputKey: inputKey, tintsByDomainID: tintsByDomainID) {
            NSLog("[inf6-venn] _reloadModel: restored cached model, domains=%d", cached.domains.count)
            if _modelRunID == runID {
                _model = cached
            }
            return
        }
        NSLog("[inf6-venn] _reloadModel: cache miss, dispatching to background, inputKey=%@", inputKey)
        DispatchQueue.global(qos: .userInitiated).async {
            let model = Self._makeModel(domains: currentDomains)
            Self._saveCachedModel(model, inputKey: inputKey)
            DispatchQueue.main.async {
                guard _modelRunID == runID else {
                    NSLog("[inf6-venn] _reloadModel: stale inputKey, discarding")
                    return
                }
                NSLog("[inf6-venn] _reloadModel: _model set, domains=%d", model.domains.count)
                _model = model
            }
        }
    }

    private func _reloadDomainUpdateState() {
        let familyIDs = domains.map(\.manifest.sourceFamily)
        DispatchQueue.global(qos: .utility).async {
            let pending = Set(familyIDs.filter {
                Inf6DomainSyncSchedule.needsUpdate(familyID: $0)
            })
            DispatchQueue.main.async {
                _domainsNeedingUpdate = pending
            }
        }
    }

    @State private var _loadingPatternID: String?

    private func _toggleSelection(_ row: _SetMembershipPatternRow, model: _VennModel) {
        if _selectedPatternIDs.contains(row.id) {
            _selectedPatternIDs.remove(row.id)
            _selectedSubsetBreakdowns.removeAll { $0.patternID == row.id }
        } else {
            let runID = UUID()
            _breakdownRunID = runID
            _selectedPatternIDs.insert(row.id)
            _loadingPatternID = row.id
            NSLog("[inf6-venn] _toggleSelection: start loading patternID=%@, domains=%d", row.id, row.indexes.count)
            DispatchQueue.global(qos: .userInitiated).async {
                let t0 = CFAbsoluteTimeGetCurrent()
                let fingerprint = _subsetBreakdownInputKey(for: row, model: model)
                let tintsByDomainID = Dictionary(uniqueKeysWithValues: model.domains.map { ($0.id, $0.tint) })
                let breakdown: _SetMembershipSubsetBreakdown
                if let cached = _loadCachedSubsetBreakdown(
                    patternID: row.id,
                    fingerprint: fingerprint,
                    tintsByDomainID: tintsByDomainID
                ) {
                    NSLog("[inf6-venn] _toggleSelection: restored cached breakdown, patternID=%@", row.id)
                    breakdown = cached
                } else {
                    let built = _subsetBreakdown(for: row, model: model)
                    _saveCachedSubsetBreakdown(built, fingerprint: fingerprint)
                    breakdown = built
                }
                let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                NSLog("[inf6-venn] _toggleSelection: breakdown built, %.1fms, subsets=%@",
                      elapsed,
                      breakdown.domains.map { "\($0.id):\($0.subsets.count)" }.joined(separator: ","))
                DispatchQueue.main.async {
                    guard _breakdownRunID == runID, _loadingPatternID == row.id else { return }
                    _selectedSubsetBreakdowns.append(breakdown)
                    _loadingPatternID = nil
                    _breakdownRunID = nil
                }
            }
        }
    }

    private func _removeSelection(_ selection: _SetMembershipSubsetBreakdown) {
        _selectedPatternIDs.remove(selection.patternID)
        _selectedSubsetBreakdowns.removeAll { $0.patternID == selection.patternID }
    }

    private func _cancelSubsetBreakdown() {
        if let loadingPatternID = _loadingPatternID {
            _selectedPatternIDs.remove(loadingPatternID)
        }
        _loadingPatternID = nil
        _breakdownRunID = nil
    }

    private var _modelInputKey: String {
        Self._domainInputKey(domains: domains)
    }

    private static func _makeModel(domains: [Inf6KnowledgeGraphView._KnowledgeGraphDomain]) -> _VennModel {
        let t0 = CFAbsoluteTimeGetCurrent()
        NSLog("[inf6-venn] _makeModel: start, domains=%d", domains.count)
        let inputKey = _domainInputKey(domains: domains)
        var conceptIDsByDomain: [String: Set<String>] = [:]
        var conceptIDsBySourceNodeID: [String: Set<String>] = [:]
        for domain in domains {
            let sourceFamily = domain.manifest.sourceFamily
            for node in domain.structure.nodes {
                let conceptIDs = Inf6SyllabusConceptSetBuilder.conceptIDs(
                    for: node,
                    sourceFamily: sourceFamily
                )
                guard !conceptIDs.isEmpty else { continue }
                conceptIDsByDomain[sourceFamily, default: []].formUnion(conceptIDs)
                conceptIDsBySourceNodeID["\(sourceFamily)|\(node.nodeID)"] = conceptIDs
            }
        }
        NSLog("[inf6-venn] _makeModel: conceptSets built, %.1fms, concepts=%@",
              (CFAbsoluteTimeGetCurrent() - t0) * 1000,
              domains.map { "\($0.manifest.sourceFamily):\(conceptIDsByDomain[$0.manifest.sourceFamily]?.count ?? 0)" }.joined(separator: ","))
        let domainIndexByID = Dictionary(uniqueKeysWithValues: domains.enumerated().map {
            ($0.element.manifest.sourceFamily, $0.offset)
        })
        var indexesByConceptID: [String: Set<Int>] = [:]
        for (sourceFamily, conceptIDs) in conceptIDsByDomain {
            guard let index = domainIndexByID[sourceFamily] else { continue }
            for conceptID in conceptIDs {
                indexesByConceptID[conceptID, default: []].insert(index)
            }
        }

        let itemsLock = NSLock()
        var itemResults: [(Int, _VennDomain)] = []
        DispatchQueue.concurrentPerform(iterations: domains.count) { index in
            let domain = domains[index]
            let sourceFamily = domain.manifest.sourceFamily
            let conceptIDs = conceptIDsByDomain[sourceFamily] ?? []
            let mastery = Self._masteryState(qualificationID: domain.manifest.familyID)
            let title = Self._displayTitle(
                ja: domain.manifest.displayNameJa,
                en: domain.manifest.displayNameEn
            )
            let versionTitle = domain.structure.nodes
                .first(where: { $0.kind == .syllabusVersion })
                .map { Self._displayTitle(ja: $0.titleJa, en: $0.titleEn) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let syllabusTitle = versionTitle.isEmpty || versionTitle == title
                ? title
                : "\(title) \(versionTitle)"
            let syllabusItems = domain.structure.nodes.compactMap { node -> _SyllabusItem? in
                guard Self._isSyllabusSubset(node) else { return nil }
                let itemConceptIDs = conceptIDsBySourceNodeID["\(sourceFamily)|\(node.nodeID)"] ?? []
                var indexes = Set([index])
                for conceptID in itemConceptIDs {
                    indexes.formUnion(indexesByConceptID[conceptID] ?? [])
                }
                guard !indexes.isEmpty else { return nil }
                return _SyllabusItem(
                    id: node.nodeID,
                    title: Self._displayTitle(ja: node.titleJa, en: node.titleEn),
                    conceptIDs: itemConceptIDs,
                    membershipIndexes: indexes
                )
            }
            let item = _VennDomain(
                id: sourceFamily,
                rawID: domain.manifest.familyID,
                title: title,
                syllabusTitle: syllabusTitle,
                conceptIDs: conceptIDs,
                syllabusItems: syllabusItems,
                masteryLevelsByConceptID: mastery.atomStates,
                nodes: domain.structure.nodes,
                audit: nil,
                tint: domain.accentColor
            )
            itemsLock.lock()
            itemResults.append((index, item))
            itemsLock.unlock()
        }
        let items = itemResults.sorted { $0.0 < $1.0 }.map(\.1)

        NSLog("[inf6-venn] _makeModel: done, %.1fms, syllabusItems=%@",
              (CFAbsoluteTimeGetCurrent() - t0) * 1000,
              items.map { "\($0.id):\($0.syllabusItems.count)" }.joined(separator: ","))
        return _VennModel(inputKey: inputKey, domains: items)
    }

    private static func _masteryState(qualificationID: String) -> Inf6MasteryState {
        Inf6MetadataStore.getCodable(
            Inf6MasteryState.self,
            domain: .mmaMastery,
            key: qualificationID
        ) ?? Inf6MasteryState()
    }

    private static func _displayTitle(ja: String, en: String) -> String {
        let jaText = ja.trimmingCharacters(in: .whitespacesAndNewlines)
        let enText = en.trimmingCharacters(in: .whitespacesAndNewlines)
        return Inf6Lang.text(jaText, enText)
    }

    private static func _audit(sourceFamily: String) -> _VennDomainAudit? {
        Inf6MetadataStore.getCodable(
            _VennDomainAudit.self,
            domain: .settings,
            key: "semantic_concept_set_audit:\(sourceFamily)"
        )
    }

    private func _subsetBreakdown(for row: _SetMembershipPatternRow, model: _VennModel) -> _SetMembershipSubsetBreakdown {
        let t0 = CFAbsoluteTimeGetCurrent()
        let paperIDsByConceptID = _paperIDsByConceptID()
        NSLog("[inf6-venn] _subsetBreakdown: paperIDsByConceptID loaded, %.1fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        let papersByID = _papersByID()
        let paperProgressByID = _paperProgressByID()
        NSLog("[inf6-venn] _subsetBreakdown: papers loaded, %.1fms, papers=%d", (CFAbsoluteTimeGetCurrent() - t0) * 1000, papersByID.count)

        let domainBreakdowns = row.indexes.sorted().compactMap { index -> _SetMembershipSubsetBreakdown.Domain? in
            guard index < model.domains.count else { return nil }
            let domain = model.domains[index]
            let nodesByID = Dictionary(uniqueKeysWithValues: domain.nodes.map { ($0.nodeID, $0) })
            let selectedItemIDs = row.syllabusItemIDsByDomainID[domain.id] ?? []
            var itemIDsByNodeID: [String: Set<String>] = [:]

            for itemID in selectedItemIDs {
                for ancestorID in _syllabusSubsetPath(for: itemID, nodesByID: nodesByID) {
                    itemIDsByNodeID[ancestorID, default: []].insert(itemID)
                }
            }

            let linkedPaperIDsByNodeID = _preloadLinkedPaperIDs(
                sourceFamily: domain.id,
                nodes: domain.nodes
            )

            let subsets = _subsetTree(
                parentID: domain.nodes.first(where: { $0.kind == .syllabusVersion })?.nodeID,
                nodes: domain.nodes,
                nodesByID: nodesByID,
                itemIDsByNodeID: itemIDsByNodeID,
                conceptIDsByItemID: Dictionary(uniqueKeysWithValues: domain.syllabusItems.map { ($0.id, $0.conceptIDs) }),
                masteryLevelsByConceptID: domain.masteryLevelsByConceptID,
                paperIDsByConceptID: paperIDsByConceptID,
                papersByID: papersByID,
                paperProgressByID: paperProgressByID,
                linkedPaperIDsByNodeID: linkedPaperIDsByNodeID
            )

            return _SetMembershipSubsetBreakdown.Domain(
                id: domain.id,
                title: domain.syllabusTitle,
                tint: domain.tint,
                subsets: subsets
            )
        }

        return _SetMembershipSubsetBreakdown(
            patternID: row.id,
            title: _patternTitle(row: row, model: model),
            mastery: _masterySummary(for: row.conceptIDs, indexes: row.indexes, model: model),
            domains: domainBreakdowns
        )
    }

    private func _masterySummary(
        for conceptIDs: Set<String>,
        indexes: Set<Int>,
        model: _VennModel
    ) -> _SetMembershipMasterySummary {
        var verified = 0
        var inProgress = 0
        var wrong = 0

        for conceptID in conceptIDs {
            let levels = indexes.compactMap { index -> Inf6MasteryLevel? in
                guard index < model.domains.count else { return nil }
                return model.domains[index].masteryLevelsByConceptID[conceptID]
            }
            if levels.contains(.verified) {
                verified += 1
            } else if levels.contains(.wrong) {
                wrong += 1
            } else if levels.contains(.inProgress) {
                inProgress += 1
            }
        }

        return _SetMembershipMasterySummary(
            total: conceptIDs.count,
            verified: verified,
            inProgress: inProgress,
            wrong: wrong
        )
    }

    private func _masterySummary(
        for conceptIDs: Set<String>,
        masteryLevelsByConceptID: [String: Inf6MasteryLevel]
    ) -> _SetMembershipMasterySummary {
        var verified = 0
        var inProgress = 0
        var wrong = 0

        for conceptID in conceptIDs {
            switch masteryLevelsByConceptID[conceptID] ?? .unverified {
            case .verified:
                verified += 1
            case .inProgress:
                inProgress += 1
            case .wrong:
                wrong += 1
            case .unverified:
                break
            }
        }

        return _SetMembershipMasterySummary(
            total: conceptIDs.count,
            verified: verified,
            inProgress: inProgress,
            wrong: wrong
        )
    }

    private func _syllabusSubsetPath(
        for nodeID: String,
        nodesByID: [String: Inf6KnowledgeNode]
    ) -> [String] {
        guard var current = nodesByID[nodeID] else { return [] }
        var out: [String] = []
        if Self._isSyllabusSubset(current) {
            out.append(current.nodeID)
        }
        while let parentID = current.parentNodeID,
              let parent = nodesByID[parentID] {
            guard parent.kind != .syllabusVersion, parent.kind != .domain else { break }
            current = parent
            if Self._isSyllabusSubset(current) {
                out.append(current.nodeID)
            }
        }
        return out
    }

    private func _preloadLinkedPaperIDs(
        sourceFamily: String,
        nodes: [Inf6KnowledgeNode]
    ) -> [String: Set<String>] {
        let t0 = CFAbsoluteTimeGetCurrent()
        let allLinks = Inf6MetadataStore
            .listByPrefix(domain: .syllabusPaperLinks, prefix: "\(sourceFamily)|")
            .compactMap { pair -> (nodeID: String, paperID: String)? in
                guard let data = pair.json.data(using: .utf8),
                      let link = try? JSONDecoder().decode(Inf6SyllabusPaperLink.self, from: data) else { return nil }
                return (link.syllabusNodeID, link.paperID)
            }
        var result: [String: Set<String>] = [:]
        for (nodeID, paperID) in allLinks {
            result[nodeID, default: []].insert(paperID)
        }
        NSLog("[inf6-venn] _preloadLinkedPaperIDs: %@, links=%d, nodes=%d, %.1fms",
              sourceFamily, allLinks.count, result.count, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        return result
    }

    private func _subsetTree(
        parentID: String?,
        nodes: [Inf6KnowledgeNode],
        nodesByID: [String: Inf6KnowledgeNode],
        itemIDsByNodeID: [String: Set<String>],
        conceptIDsByItemID: [String: Set<String>],
        masteryLevelsByConceptID: [String: Inf6MasteryLevel],
        paperIDsByConceptID: [String: Set<String>],
        papersByID: [String: Inf6CorePaper],
        paperProgressByID: [String: _SetMembershipPaperProgress],
        linkedPaperIDsByNodeID: [String: Set<String>]
    ) -> [_SetMembershipSubsetBreakdown.Subset] {
        nodes
            .filter { node in
                node.parentNodeID == parentID && Self._isSyllabusSubset(node) && !(itemIDsByNodeID[node.nodeID]?.isEmpty ?? true)
            }
            .map { node in
                let itemIDs = itemIDsByNodeID[node.nodeID] ?? []
                let conceptIDs = itemIDs.reduce(into: Set<String>()) { partial, itemID in
                    partial.formUnion(conceptIDsByItemID[itemID] ?? [])
                }
                var nodePaperIDs = Set(node.linkedPaperIDs)
                nodePaperIDs.formUnion(linkedPaperIDsByNodeID[node.nodeID] ?? [])
                return _SetMembershipSubsetBreakdown.Subset(
                    id: node.nodeID,
                    title: Self._displayTitle(ja: node.titleJa, en: node.titleEn),
                    count: itemIDs.count,
                    mastery: _masterySummary(
                        for: conceptIDs,
                        masteryLevelsByConceptID: masteryLevelsByConceptID
                    ),
                    originalExplanationID: _originalExplanationID(for: node, nodesByID: nodesByID),
                    relatedPapers: _relatedPapers(
                        conceptIDs: conceptIDs,
                        nodePaperIDs: nodePaperIDs,
                        paperIDsByConceptID: paperIDsByConceptID,
                        papersByID: papersByID,
                        paperProgressByID: paperProgressByID
                    ),
                    children: _subsetTree(
                        parentID: node.nodeID,
                        nodes: nodes,
                        nodesByID: nodesByID,
                        itemIDsByNodeID: itemIDsByNodeID,
                        conceptIDsByItemID: conceptIDsByItemID,
                        masteryLevelsByConceptID: masteryLevelsByConceptID,
                        paperIDsByConceptID: paperIDsByConceptID,
                        papersByID: papersByID,
                        paperProgressByID: paperProgressByID,
                        linkedPaperIDsByNodeID: linkedPaperIDsByNodeID
                    )
                )
            }
    }

    private func _paperIDsByConceptID() -> [String: Set<String>] {
        Inf6MetadataStore
            .listAllCodable(Inf6CorpusConceptMention.self, domain: .corpusConceptMentions)
            .map(\.value)
            .reduce(into: [String: Set<String>]()) { out, mention in
                guard mention.sourceID.hasPrefix("paper/") else { return }
                let paperID = String(mention.sourceID.dropFirst("paper/".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !paperID.isEmpty else { return }
                out[mention.canonicalID, default: []].insert(paperID)
            }
    }

    private func _originalExplanationID(for node: Inf6KnowledgeNode, nodesByID: [String: Inf6KnowledgeNode]) -> String? {
        guard let sourceFamily = _sourceFamily(for: node, nodesByID: nodesByID) else { return nil }
        return "inf6-explanation:\(sourceFamily):\(node.nodeID)"
    }

    private func _sourceFamily(for node: Inf6KnowledgeNode, nodesByID: [String: Inf6KnowledgeNode]) -> String? {
        var current: Inf6KnowledgeNode? = node
        while let value = current {
            let nodeID = value.nodeID.lowercased()
            if nodeID.contains("jdla_gkentei") || nodeID.contains("g-kentei") || nodeID.contains("gkentei") {
                return "jdla_gkentei"
            }
            if nodeID.contains("jdla_eshikaku") || nodeID.contains("e-shikaku") || nodeID.contains("eshikaku") {
                return "jdla_eshikaku"
            }
            if nodeID.contains("microsoft_ai_103") || nodeID.contains("ai-103") {
                return "microsoft_ai_103"
            }
            if nodeID.contains("microsoft_ai_102") || nodeID.contains("ai-102") {
                return "microsoft_ai_102"
            }
            if let parentID = value.parentNodeID {
                current = nodesByID[parentID]
            } else {
                current = nil
            }
        }
        return nil
    }

    private func _papersByID() -> [String: Inf6CorePaper] {
        Dictionary(uniqueKeysWithValues: Inf6CorePaperStore.shared.papers.map { ($0.id, $0) })
    }

    private func _paperProgressByID() -> [String: _SetMembershipPaperProgress] {
        let store = Inf6CorePaperStore.shared
        let learning = store.learningArtifactStateByPaperID()
        let assets = store.assetsPipelineStateByPaperID()
        return store.papers.reduce(into: [:]) { result, paper in
            let artifacts = learning[paper.id] ?? Inf6CorePaperLearningArtifactState()
            result[paper.id] = _SetMembershipPaperProgress(
                hasOverview: artifacts.hasOverview,
                hasAssetsPipeline: assets[paper.id] == .finished,
                hasFormula: artifacts.hasFormulaCard || artifacts.hasFormulaExplanation,
                hasComment: artifacts.hasAddedExplanation,
                hasQuiz: artifacts.hasQuiz
            )
        }
    }

    private func _subsetBreakdownInputKey(for row: _SetMembershipPatternRow, model: _VennModel) -> String {
        let rowPart = [
            model.inputKey,
            row.id,
            row.conceptIDs.sorted().joined(separator: ","),
            row.syllabusItemIDsByDomainID
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.sorted().joined(separator: ","))" }
                .joined(separator: "|")
        ].joined(separator: "\u{1f}")
        let paperPart = Inf6CorePaperStore.shared.papers.map { paper in
            [
                paper.id,
                paper.title,
                paper.titleEn ?? "",
                "\(paper.year ?? -1)"
            ].joined(separator: "\u{1f}")
        }
        .sorted()
        .joined(separator: "\u{1e}")
        let progressPart = _paperProgressByID()
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.cacheFingerprint)" }
            .joined(separator: "|")
        let mentionPart = Inf6MetadataStore
            .listAll(domain: .corpusConceptMentions)
            .map { "\($0.key)=\($0.json)" }
            .joined(separator: "\u{1e}")
        let linkPart = row.indexes
            .sorted()
            .compactMap { index -> String? in
                guard index < model.domains.count else { return nil }
                let sourceFamily = model.domains[index].id
                return Inf6MetadataStore
                    .listByPrefix(domain: .syllabusPaperLinks, prefix: "\(sourceFamily)|")
                    .map { "\($0.key)=\($0.json)" }
                    .joined(separator: "\u{1e}")
            }
            .joined(separator: "\u{1d}")
        return Self._sha256([rowPart, paperPart, progressPart, mentionPart, linkPart].joined(separator: "\u{1c}"))
    }

    private func _loadCachedSubsetBreakdown(
        patternID: String,
        fingerprint: String,
        tintsByDomainID: [String: Color]
    ) -> _SetMembershipSubsetBreakdown? {
        guard let cache = Inf6MetadataStore.getCodable(
            _SetMembershipSubsetBreakdownCache.self,
            domain: .settings,
            key: _subsetBreakdownCacheKey(patternID: patternID)
        ), cache.schemaVersion == 1, cache.fingerprint == fingerprint else { return nil }
        return cache.breakdown(tintsByDomainID: tintsByDomainID)
    }

    private func _saveCachedSubsetBreakdown(_ breakdown: _SetMembershipSubsetBreakdown, fingerprint: String) {
        Inf6MetadataStore.putCodable(
            breakdown.cache(fingerprint: fingerprint),
            domain: .settings,
            key: _subsetBreakdownCacheKey(patternID: breakdown.patternID)
        )
    }

    private func _subsetBreakdownCacheKey(patternID: String) -> String {
        "venn_subset_breakdown_v1:\(patternID)"
    }

    private func _relatedPapers(
        conceptIDs: Set<String>,
        nodePaperIDs: Set<String>,
        paperIDsByConceptID: [String: Set<String>],
        papersByID: [String: Inf6CorePaper],
        paperProgressByID: [String: _SetMembershipPaperProgress]
    ) -> [_SetMembershipRelatedPaper] {
        let paperIDs = conceptIDs.reduce(into: nodePaperIDs) { out, conceptID in
            out.formUnion(paperIDsByConceptID[conceptID] ?? [])
        }
        return paperIDs.compactMap { paperID -> _SetMembershipRelatedPaper? in
            guard let paper = papersByID[paperID] else { return nil }
            return _SetMembershipRelatedPaper(
                id: paper.id,
                title: Inf6Lang.text(paper.title, paper.titleEn ?? paper.title),
                year: paper.year,
                progress: paperProgressByID[paper.id] ?? _SetMembershipPaperProgress()
            )
        }
        .sorted {
            if ($0.year ?? 0) != ($1.year ?? 0) {
                return ($0.year ?? 0) > ($1.year ?? 0)
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private static func _isSyllabusSubset(_ node: Inf6KnowledgeNode) -> Bool {
        switch node.kind {
        case .major, .minor, .topic:
            return true
        case .domain, .syllabusVersion, .paper:
            return false
        }
    }

    private func _patternTitle(row: _SetMembershipPatternRow, model: _VennModel) -> String {
        let titles = row.indexes
            .sorted()
            .compactMap { index in
                index < model.domains.count ? model.domains[index].title : nil
            }
        return titles.isEmpty ? "概念集合" : titles.joined(separator: " / ")
    }

    private func _threeSetLayout(model: _VennModel, canvas: CGSize) -> _ThreeSetLayout {
        let counts = _threeSetRegionCounts(model: model)
        let diameters = _circleDiameters(model: model, canvas: canvas)
        let radii = diameters.map { $0 / 2 }
        let center = CGPoint(x: canvas.width * 0.50, y: canvas.height * 0.50)
        let radius = radii.first ?? 140
        let horizontalOffset = radius * 0.54
        let topOffset = radius * 0.30
        let bottomOffset = radius * 0.48
        let centers = [
            CGPoint(x: center.x - horizontalOffset, y: center.y - topOffset),
            CGPoint(x: center.x + horizontalOffset, y: center.y - topOffset),
            CGPoint(x: center.x, y: center.y + bottomOffset)
        ]
        let frames = zip(centers, diameters).map { center, diameter in
            CGRect(center: center, size: CGSize(width: diameter, height: diameter))
        }
        let anchors = _regionAnchors(counts: counts, centers: centers, radii: radii, canvas: canvas)
        return _ThreeSetLayout(
            domainFrames: frames,
            aOnly: anchors[0b001] ?? _fallbackRegionLabelPosition(mask: 0b001, centers: centers),
            bOnly: anchors[0b010] ?? _fallbackRegionLabelPosition(mask: 0b010, centers: centers),
            cOnly: anchors[0b100] ?? _fallbackRegionLabelPosition(mask: 0b100, centers: centers),
            abOnly: anchors[0b011] ?? _fallbackRegionLabelPosition(mask: 0b011, centers: centers),
            acOnly: anchors[0b101] ?? _fallbackRegionLabelPosition(mask: 0b101, centers: centers),
            bcOnly: anchors[0b110] ?? _fallbackRegionLabelPosition(mask: 0b110, centers: centers),
            abc: anchors[0b111] ?? _fallbackRegionLabelPosition(mask: 0b111, centers: centers)
        )
    }

    private func _threeSetRegionLabels(model: _VennModel, layout: _ThreeSetLayout) -> [_RegionLabel] {
        let counts = _threeSetRegionCounts(model: model)

        return [
            _RegionLabel(id: "a", count: counts.aOnly, position: layout.aOnly),
            _RegionLabel(id: "b", count: counts.bOnly, position: layout.bOnly),
            _RegionLabel(id: "c", count: counts.cOnly, position: layout.cOnly),
            _RegionLabel(id: "ab", count: counts.abOnly, position: layout.abOnly),
            _RegionLabel(id: "ac", count: counts.acOnly, position: layout.acOnly),
            _RegionLabel(id: "bc", count: counts.bcOnly, position: layout.bcOnly),
            _RegionLabel(id: "abc", count: counts.abc, position: layout.abc)
        ]
    }

    private func _domainLabelPosition(index: Int, frame: CGRect) -> CGPoint {
        switch index {
        case 0:
            return CGPoint(x: frame.minX + frame.width * 0.22, y: frame.minY - 18)
        case 1:
            return CGPoint(x: frame.maxX - frame.width * 0.22, y: frame.minY - 18)
        default:
            return CGPoint(x: frame.midX, y: frame.maxY + 22)
        }
    }

    private func _threeSetRegionCounts(model: _VennModel) -> _ThreeSetRegionCounts {
        let a = model.domains[0].conceptIDs
        let b = model.domains[1].conceptIDs
        let c = model.domains[2].conceptIDs
        let ab = a.intersection(b)
        let ac = a.intersection(c)
        let bc = b.intersection(c)
        let abc = ab.intersection(c)
        return _ThreeSetRegionCounts(
            aOnly: a.subtracting(b).subtracting(c).count,
            bOnly: b.subtracting(a).subtracting(c).count,
            cOnly: c.subtracting(a).subtracting(b).count,
            abOnly: ab.subtracting(c).count,
            acOnly: ac.subtracting(b).count,
            bcOnly: bc.subtracting(a).count,
            abc: abc.count
        )
    }

    private func _circleDiameters(model: _VennModel, canvas: CGSize) -> [CGFloat] {
        let diameter = min(canvas.width * 0.34, canvas.height * 0.44, 300)
        return Array(repeating: max(220, diameter), count: model.domains.count)
    }

    private func _regionAnchors(
        counts: _ThreeSetRegionCounts,
        centers: [CGPoint],
        radii: [CGFloat],
        canvas: CGSize
    ) -> [Int: CGPoint] {
        let visibleMasks: [(Int, Int)] = [
            (0b001, counts.aOnly),
            (0b010, counts.bOnly),
            (0b100, counts.cOnly),
            (0b011, counts.abOnly),
            (0b101, counts.acOnly),
            (0b110, counts.bcOnly),
            (0b111, counts.abc)
        ].filter { $0.1 > 0 }

        var positions: [Int: CGPoint] = [:]
        for (mask, _) in visibleMasks.sorted(by: { _labelClearance(mask: $0.0) > _labelClearance(mask: $1.0) }) {
            let candidates = _regionLabelCandidates(mask: mask, centers: centers, radii: radii, canvas: canvas)
            let point: CGPoint
            if candidates.isEmpty {
                point = _fallbackRegionLabelPosition(mask: mask, centers: centers)
            } else {
                let centroid = _centroid(of: candidates)
                point = candidates.min(by: { _distanceSquared($0, centroid) < _distanceSquared($1, centroid) }) ?? centroid
            }
            positions[mask] = point
        }
        return positions
    }

    private func _regionLabelCandidates(mask targetMask: Int, centers: [CGPoint], radii: [CGFloat], canvas: CGSize) -> [CGPoint] {
        let minX = max(0, centers.enumerated().map { $0.element.x - radii[$0.offset] }.min() ?? 0)
        let maxX = min(canvas.width, centers.enumerated().map { $0.element.x + radii[$0.offset] }.max() ?? canvas.width)
        let minY = max(0, centers.enumerated().map { $0.element.y - radii[$0.offset] }.min() ?? 0)
        let maxY = min(canvas.height, centers.enumerated().map { $0.element.y + radii[$0.offset] }.max() ?? canvas.height)
        let step: CGFloat = 5
        let margins: [CGFloat] = [16, 10, 4, 0]

        for margin in margins {
            var points: [CGPoint] = []
            var y = minY
            while y <= maxY {
                var x = minX
                while x <= maxX {
                    let point = CGPoint(x: x, y: y)
                    if _labelFootprintFits(
                        center: point,
                        mask: targetMask,
                        centers: centers,
                        radii: radii,
                        margin: margin
                    ) {
                        points.append(point)
                    }
                    x += step
                }
                y += step
            }
            if !points.isEmpty { return points }
        }
        return []
    }

    private func _centroid(of points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        return CGPoint(
            x: points.reduce(CGFloat(0)) { $0 + $1.x } / CGFloat(points.count),
            y: points.reduce(CGFloat(0)) { $0 + $1.y } / CGFloat(points.count)
        )
    }

    private func _labelClearance(mask: Int) -> CGFloat {
        switch mask {
        case 0b001, 0b010, 0b100:
            return 54
        default:
            return 40
        }
    }

    private func _labelFootprintFits(
        center: CGPoint,
        mask targetMask: Int,
        centers: [CGPoint],
        radii: [CGFloat],
        margin: CGFloat
    ) -> Bool {
        let radius = _labelFootprintRadius(mask: targetMask)
        let samplePoints = [
            center,
            CGPoint(x: center.x - radius, y: center.y),
            CGPoint(x: center.x + radius, y: center.y),
            CGPoint(x: center.x, y: center.y - radius),
            CGPoint(x: center.x, y: center.y + radius),
            CGPoint(x: center.x - radius * 0.72, y: center.y - radius * 0.72),
            CGPoint(x: center.x + radius * 0.72, y: center.y - radius * 0.72),
            CGPoint(x: center.x - radius * 0.72, y: center.y + radius * 0.72),
            CGPoint(x: center.x + radius * 0.72, y: center.y + radius * 0.72)
        ]
        return samplePoints.allSatisfy {
            _membershipMask(at: $0, centers: centers, radii: radii, margin: margin) == targetMask
        }
    }

    private func _labelFootprintRadius(mask: Int) -> CGFloat {
        switch mask {
        case 0b001, 0b010, 0b100:
            return 34
        default:
            return 18
        }
    }

    private func _membershipMask(at point: CGPoint, centers: [CGPoint], radii: [CGFloat], margin: CGFloat) -> Int {
        var mask = 0
        for index in 0..<min(centers.count, radii.count) {
            let radius = max(0, radii[index] - margin)
            if _distanceSquared(point, centers[index]) <= radius * radius {
                mask |= (1 << index)
            }
        }
        return mask
    }

    private func _distanceSquared(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private func _fallbackRegionLabelPosition(mask: Int, centers: [CGPoint]) -> CGPoint {
        let included = (0..<centers.count).filter { (mask & (1 << $0)) != 0 }
        guard !included.isEmpty else {
            return CGPoint(
                x: centers.reduce(CGFloat(0)) { $0 + $1.x } / CGFloat(max(1, centers.count)),
                y: centers.reduce(CGFloat(0)) { $0 + $1.y } / CGFloat(max(1, centers.count))
            )
        }
        return CGPoint(
            x: included.reduce(CGFloat(0)) { $0 + centers[$1].x } / CGFloat(included.count),
            y: included.reduce(CGFloat(0)) { $0 + centers[$1].y } / CGFloat(included.count)
        )
    }

    fileprivate struct _VennModel {
        let inputKey: String
        let domains: [_VennDomain]

        fileprivate func cache(inputKey: String) -> _VennModelCache {
            _VennModelCache(
                schemaVersion: 1,
                inputKey: inputKey,
                domains: domains.map { domain in
                    _VennDomainCache(
                        id: domain.id,
                        rawID: domain.rawID,
                        title: domain.title,
                        syllabusTitle: domain.syllabusTitle,
                        conceptIDs: domain.conceptIDs.sorted(),
                        syllabusItems: domain.syllabusItems.map {
                            _SyllabusItemCache(
                                id: $0.id,
                                title: $0.title,
                                conceptIDs: $0.conceptIDs.sorted(),
                                membershipIndexes: $0.membershipIndexes.sorted()
                            )
                        },
                        masteryLevelsByConceptID: domain.masteryLevelsByConceptID,
                        nodes: domain.nodes,
                        audit: domain.audit
                    )
                }
            )
        }
    }

    fileprivate struct _VennDomain: Identifiable {
        let id: String
        let rawID: String
        let title: String
        let syllabusTitle: String
        let conceptIDs: Set<String>
        let syllabusItems: [_SyllabusItem]
        let masteryLevelsByConceptID: [String: Inf6MasteryLevel]
        let nodes: [Inf6KnowledgeNode]
        let audit: _VennDomainAudit?
        let tint: Color
    }

    fileprivate struct _SyllabusItem: Identifiable, Hashable {
        let id: String
        let title: String
        let conceptIDs: Set<String>
        let membershipIndexes: Set<Int>
    }

    fileprivate struct _VennDomainAudit: Codable, Hashable {
        let sourceFamily: String
        let outlineCount: Int?
        let conceptNodeCount: Int
        let emittedAtomCount: Int
        let membershipCount: Int
    }

    fileprivate struct _VennModelCache: Codable {
        let schemaVersion: Int
        let inputKey: String
        let domains: [_VennDomainCache]

        func model(tintsByDomainID: [String: Color]) -> _VennModel? {
            guard schemaVersion == 1 else { return nil }
            return _VennModel(
                inputKey: inputKey,
                domains: domains.map { domain in
                    _VennDomain(
                        id: domain.id,
                        rawID: domain.rawID,
                        title: domain.title,
                        syllabusTitle: domain.syllabusTitle,
                        conceptIDs: Set(domain.conceptIDs),
                        syllabusItems: domain.syllabusItems.map {
                            _SyllabusItem(
                                id: $0.id,
                                title: $0.title,
                                conceptIDs: Set($0.conceptIDs),
                                membershipIndexes: Set($0.membershipIndexes)
                            )
                        },
                        masteryLevelsByConceptID: domain.masteryLevelsByConceptID,
                        nodes: domain.nodes,
                        audit: domain.audit,
                        tint: tintsByDomainID[domain.id] ?? .blue
                    )
                }
            )
        }
    }

    fileprivate struct _VennDomainCache: Codable {
        let id: String
        let rawID: String
        let title: String
        let syllabusTitle: String
        let conceptIDs: [String]
        let syllabusItems: [_SyllabusItemCache]
        let masteryLevelsByConceptID: [String: Inf6MasteryLevel]
        let nodes: [Inf6KnowledgeNode]
        let audit: _VennDomainAudit?
    }

    fileprivate struct _SyllabusItemCache: Codable {
        let id: String
        let title: String
        let conceptIDs: [String]
        let membershipIndexes: [Int]
    }

    private static let _vennModelCacheKey = "venn_home_model_cache_v1"

    private static func _loadCachedModel(inputKey: String, tintsByDomainID: [String: Color]) -> _VennModel? {
        guard let cache = Inf6MetadataStore.getCodable(
            _VennModelCache.self,
            domain: .settings,
            key: _vennModelCacheKey
        ), cache.inputKey == inputKey else { return nil }
        return cache.model(tintsByDomainID: tintsByDomainID)
    }

    private static func _saveCachedModel(_ model: _VennModel, inputKey: String) {
        Inf6MetadataStore.putCodable(
            model.cache(inputKey: inputKey),
            domain: .settings,
            key: _vennModelCacheKey
        )
    }

    private static func _sha256(_ text: String) -> String {
        let data = Data(text.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func _domainInputKey(domains: [Inf6KnowledgeGraphView._KnowledgeGraphDomain]) -> String {
        let raw = domains
            .map { domain in
                let nodeFP = domain.structure.nodes.map { node in
                    [
                        node.nodeID,
                        node.parentNodeID ?? "",
                        node.kind.rawValue,
                        "\(node.depth)",
                        node.titleJa,
                        node.titleEn,
                        node.linkedPaperIDs.sorted().joined(separator: ",")
                    ].joined(separator: "\u{1f}")
                }
                .joined(separator: "\u{1e}")
                return [
                    domain.manifest.familyID,
                    domain.manifest.sourceFamily,
                    "\(domain.structure.nodes.count)",
                    nodeFP
                ].joined(separator: "\u{1d}")
            }
            .joined(separator: "\u{1c}")
        return _sha256(raw)
    }

    private struct _ThreeSetLayout {
        let domainFrames: [CGRect]
        let aOnly: CGPoint
        let bOnly: CGPoint
        let cOnly: CGPoint
        let abOnly: CGPoint
        let acOnly: CGPoint
        let bcOnly: CGPoint
        let abc: CGPoint
    }

    private struct _RegionLabel {
        let id: String
        let count: Int
        let position: CGPoint
    }

    private struct _ThreeSetRegionCounts {
        let aOnly: Int
        let bOnly: Int
        let cOnly: Int
        let abOnly: Int
        let acOnly: Int
        let bcOnly: Int
        let abc: Int
    }
}

private struct _VennRegionLabel: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(34), weight: .heavy))
            .monospacedDigit()
            .foregroundStyle(.primary.opacity(0.86))
            .frame(width: 72, height: 44)
    }
}

private struct _VennDomainLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(17), weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .multilineTextAlignment(.center)
            .foregroundStyle(.primary.opacity(0.86))
            .frame(width: 150, height: 28)
    }
}

private struct _SetMembershipMapView: View {
    let model: _Inf6VennHomeView._VennModel
    let selectedPatternIDs: Set<String>
    let domainsNeedingUpdate: Set<String>
    let onSelectPattern: (_SetMembershipPatternRow) -> Void
    var onUpdateDomain: ((String) -> Void)?
    var onOpenIntensiveDrill: (() -> Void)?
    /// ウィンドウ幅から求めた表示倍率。全ての寸法をこれに掛けて拡縮する。
    @State private var _scale: CGFloat = 1.0

    /// この版面が想定する基準幅。実幅との比を倍率にする。
    private let _referenceWidth: CGFloat = 1100

    private var _domainLabelWidth: CGFloat { 140 * _scale }
    private var _patternColumnWidth: CGFloat { 88 * _scale }
    private var _rowHeight: CGFloat { 60 * _scale }
    private var _dotSize: CGFloat { 40 * _scale }
    private var _selectedDotSize: CGFloat { 48 * _scale }
    private var _domainTitleSize: CGFloat { 23 * _scale }
    private var _rowSpacing: CGFloat { 14 * _scale }

    private var _rows: [_SetMembershipPatternRow] {
        var rowsBySignature: [String: (indexes: Set<Int>, conceptIDs: Set<String>, itemIDsByDomainID: [String: Set<String>])] = [:]
        for domain in model.domains {
            for item in domain.syllabusItems {
                let indexes = item.membershipIndexes
                let signature = indexes.sorted().map(String.init).joined(separator: ".")
                guard !signature.isEmpty else { continue }
                var current = rowsBySignature[signature] ?? (indexes: indexes, conceptIDs: [], itemIDsByDomainID: [:])
                current.conceptIDs.formUnion(item.conceptIDs)
                current.itemIDsByDomainID[domain.id, default: []].insert(item.id)
                rowsBySignature[signature] = current
            }
        }

        return _membershipIndexSets(domainCount: model.domains.count).map { indexes in
            let signature = indexes.sorted().map(String.init).joined(separator: ".")
            let value = rowsBySignature[signature]
            return _SetMembershipPatternRow(
                indexes: indexes,
                conceptIDs: value?.conceptIDs ?? [],
                syllabusItemIDsByDomainID: value?.itemIDsByDomainID ?? [:]
            )
        }
    }

    private func _membershipIndexSets(domainCount: Int) -> [Set<Int>] {
        guard domainCount > 0 else { return [] }
        let maxMask = (1 << domainCount) - 1
        return stride(from: maxMask, through: 1, by: -1).map { mask in
            Set((0..<domainCount).filter { index in
                (mask & (1 << (domainCount - index - 1))) != 0
            })
        }
    }

    @ViewBuilder
    private func _domainCircle(domain: _Inf6VennHomeView._VennDomain) -> some View {
        let needs = domainsNeedingUpdate.contains(domain.rawID)
        let fid = domain.rawID
        Circle()
            .fill(domain.tint.opacity(0.28))
            .overlay(Circle().stroke(domain.tint.opacity(0.95), lineWidth: 2.6))
            .frame(width: 36, height: 36)
            .overlay(alignment: .topTrailing) {
                if needs {
                    Circle()
                        .fill(.orange)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                        .offset(x: 2, y: -2)
                        .onTapGesture { onUpdateDomain?(fid) }
                }
            }
    }

    var body: some View {
        GeometryReader { geo in
            _content
                .onAppear { _updateScale(geo.size.width) }
                .inf6OnChange(geo.size.width) { width in _updateScale(width) }
        }
    }

    /// 幅に対する倍率。極端に伸縮すると読めなくなるため範囲を絞る。
    private func _updateScale(_ width: CGFloat) {
        guard width.isFinite, width > 0 else { return }
        let raw = width / _referenceWidth
        let clamped = min(max(raw, 0.72), 1.60)
        if abs(clamped - _scale) > 0.01 { _scale = clamped }
    }

    private var _content: some View {
        HStack(alignment: .top, spacing: 16 * _scale) {
            VStack(alignment: .leading, spacing: _rowSpacing) {
                ForEach(Array(model.domains.enumerated()), id: \.element.id) { _, domain in
                    HStack(spacing: 12) {
                        _domainCircle(domain: domain)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(domain.title)
                                .font(.system(size: _domainTitleSize, weight: .heavy))
                                .foregroundStyle(domain.tint.opacity(0.95))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                            Button {
                                onUpdateDomain?(domain.rawID)
                            } label: {
                                Label(
                                    Inf6Lang.text("シラバスを更新", "Update syllabus"),
                                    systemImage: "arrow.clockwise"
                                )
                                .font(.caption2.weight(.semibold))
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(domain.tint)
                    }
                    }
                    .frame(width: _domainLabelWidth, height: _rowHeight, alignment: .leading)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: _rowSpacing) {
                    ForEach(_rows) { row in
                        let isSelected = selectedPatternIDs.contains(row.id)
                        Button {
                            onSelectPattern(row)
                        } label: {
                            VStack(spacing: _rowSpacing) {
                                ForEach(Array(model.domains.enumerated()), id: \.element.id) { index, domain in
                                    _SetMembershipPieDot(
                                        tint: domain.tint,
                                        fraction: _masterySummary(for: row, domainIndex: index).fraction,
                                        isActive: row.indexes.contains(index)
                                    )
                                        .frame(width: isSelected && row.indexes.contains(index) ? _selectedDotSize : _dotSize, height: isSelected && row.indexes.contains(index) ? _selectedDotSize : _dotSize)
                                        .frame(width: _patternColumnWidth, height: _rowHeight)
                                }
                            }
                            .padding(.vertical, 8)
                            .frame(width: _patternColumnWidth)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(isSelected ? Color.secondary.opacity(0.10) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    _domainRowTrailingActions()
                }
                .padding(.trailing, 6)
            }
        }
        .padding(22 * _scale)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(uiColor: .systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func _domainRowTrailingActions() -> some View {
        VStack(spacing: _rowSpacing) {
            ForEach(Array(model.domains.enumerated()), id: \.element.id) { _, domain in
                Group {
                    if domain.rawID == "e-shikaku" || domain.id == "jdla_eshikaku" {
                        _intensiveDrillDomainAction(tint: domain.tint)
                    } else {
                        Color.clear
                    }
                }
                // 演習ボタンは文字を含むため、丸1つ分の列幅では足りない。
                .frame(width: _drillActionColumnWidth, height: _rowHeight)
            }
        }
        .padding(.vertical, 8 * _scale)
        .frame(width: _drillActionColumnWidth)
    }

    private var _drillActionColumnWidth: CGFloat { 150 * _scale }

    @ViewBuilder
    private func _intensiveDrillDomainAction(tint: Color) -> some View {
        // アイコンだけでは何が起きるか分からないため、右横に文字を添える。
        // 色は E資格 行と同じドメイン色に揃える。
        Button {
            onOpenIntensiveDrill?()
        } label: {
            // 同じ行のラベルは23pt、丸は40pt。それらと釣り合う大きさにする。
            // 縮小は掛けない。読めなくなるくらいなら幅を取る。
            HStack(spacing: 8 * _scale) {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(26 * _scale), weight: .semibold))
                Text(Inf6Lang.text("演習", "Drill"))
                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(19 * _scale), weight: .bold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(tint.opacity(0.95))
            .padding(.horizontal, 14 * _scale)
            .padding(.vertical, 10 * _scale)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Inf6Lang.text("E資格 集中特訓演習", "E-Cert Intensive Drill"))
        .help(Inf6Lang.text("E資格 集中特訓演習", "E-Cert Intensive Drill"))
    }

    private func _masterySummary(for row: _SetMembershipPatternRow) -> _SetMembershipMasterySummary {
        var verified = 0
        var inProgress = 0
        var wrong = 0

        for conceptID in row.conceptIDs {
            let levels = row.indexes.compactMap { index -> Inf6MasteryLevel? in
                guard index < model.domains.count else { return nil }
                return model.domains[index].masteryLevelsByConceptID[conceptID]
            }
            if levels.contains(.verified) {
                verified += 1
            } else if levels.contains(.wrong) {
                wrong += 1
            } else if levels.contains(.inProgress) {
                inProgress += 1
            }
        }

        return _SetMembershipMasterySummary(
            total: row.count,
            verified: verified,
            inProgress: inProgress,
            wrong: wrong
        )
    }

    private func _masterySummary(for row: _SetMembershipPatternRow, domainIndex: Int) -> _SetMembershipMasterySummary {
        guard domainIndex < model.domains.count else {
            return _SetMembershipMasterySummary(total: 0, verified: 0, inProgress: 0, wrong: 0)
        }
        let domain = model.domains[domainIndex]
        let itemIDs = row.syllabusItemIDsByDomainID[domain.id] ?? []
        let conceptIDs = domain.syllabusItems.reduce(into: Set<String>()) { out, item in
            guard itemIDs.contains(item.id) else { return }
            out.formUnion(item.conceptIDs)
        }
        return _masterySummary(for: conceptIDs, masteryLevelsByConceptID: domain.masteryLevelsByConceptID)
    }

    private func _masterySummary(
        for conceptIDs: Set<String>,
        masteryLevelsByConceptID: [String: Inf6MasteryLevel]
    ) -> _SetMembershipMasterySummary {
        var verified = 0
        var inProgress = 0
        var wrong = 0

        for conceptID in conceptIDs {
            switch masteryLevelsByConceptID[conceptID] ?? .unverified {
            case .verified:
                verified += 1
            case .inProgress:
                inProgress += 1
            case .wrong:
                wrong += 1
            case .unverified:
                break
            }
        }

        return _SetMembershipMasterySummary(
            total: conceptIDs.count,
            verified: verified,
            inProgress: inProgress,
            wrong: wrong
        )
    }

    private func _masteryTint(_ mastery: _SetMembershipMasterySummary) -> Color {
        if mastery.wrong > 0 { return .red }
        if mastery.fraction >= 0.8 { return .green }
        if mastery.fraction >= 0.35 { return .orange }
        return .blue
    }
}

private struct _SetMembershipPieDot: View {
    let tint: Color
    let fraction: Double
    let isActive: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isActive ? tint.opacity(0.22) : Color.secondary.opacity(0.14))
            if isActive {
                Circle()
                    .trim(from: 0, to: CGFloat(min(1, max(0, fraction))))
                    .rotation(Angle(degrees: -90))
                    .fill(tint.opacity(0.92))
            }
            Circle()
                .stroke(isActive ? tint.opacity(0.92) : Color.secondary.opacity(0.28), lineWidth: 1.4)
        }
    }
}

private struct _SetMembershipPatternRow: Identifiable, Hashable {
    let indexes: Set<Int>
    let conceptIDs: Set<String>
    let syllabusItemIDsByDomainID: [String: Set<String>]

    var count: Int {
        syllabusItemIDsByDomainID.values.reduce(0) { $0 + $1.count }
    }

    var id: String {
        indexes.sorted().map(String.init).joined(separator: ".")
    }
}

private struct _SetMembershipMasterySummary: Hashable, Codable {
    let total: Int
    let verified: Int
    let inProgress: Int
    let wrong: Int

    var unverified: Int {
        max(0, total - verified - inProgress - wrong)
    }

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(verified) / Double(total)))
    }
}

private struct _SetMembershipSubsetBreakdown: Identifiable {
    struct Domain: Identifiable {
        let id: String
        let title: String
        let tint: Color
        let subsets: [Subset]
    }

    struct Subset: Identifiable {
        let id: String
        let title: String
        let count: Int
        let mastery: _SetMembershipMasterySummary
        let originalExplanationID: String?
        let relatedPapers: [_SetMembershipRelatedPaper]
        let children: [Subset]
    }

    let patternID: String
    let title: String
    let mastery: _SetMembershipMasterySummary
    let domains: [Domain]

    var id: String {
        patternID
    }

    func cache(fingerprint: String) -> _SetMembershipSubsetBreakdownCache {
        _SetMembershipSubsetBreakdownCache(
            schemaVersion: 1,
            fingerprint: fingerprint,
            patternID: patternID,
            title: title,
            mastery: mastery,
            domains: domains.map { domain in
                _SetMembershipSubsetBreakdownCache.Domain(
                    id: domain.id,
                    title: domain.title,
                    subsets: domain.subsets.map { $0.cache }
                )
            }
        )
    }
}

private struct _SetMembershipSubsetBreakdownCache: Codable {
    struct Domain: Codable {
        let id: String
        let title: String
        let subsets: [_SetMembershipSubsetBreakdownCache.Subset]
    }

    struct Subset: Codable {
        let id: String
        let title: String
        let count: Int
        let mastery: _SetMembershipMasterySummary
        let originalExplanationID: String?
        let relatedPapers: [_SetMembershipRelatedPaper]
        let children: [_SetMembershipSubsetBreakdownCache.Subset]

        var runtime: _SetMembershipSubsetBreakdown.Subset {
            _SetMembershipSubsetBreakdown.Subset(
                id: id,
                title: title,
                count: count,
                mastery: mastery,
                originalExplanationID: originalExplanationID,
                relatedPapers: relatedPapers,
                children: children.map(\.runtime)
            )
        }
    }

    let schemaVersion: Int
    let fingerprint: String
    let patternID: String
    let title: String
    let mastery: _SetMembershipMasterySummary
    let domains: [Domain]

    func breakdown(tintsByDomainID: [String: Color]) -> _SetMembershipSubsetBreakdown {
        _SetMembershipSubsetBreakdown(
            patternID: patternID,
            title: title,
            mastery: mastery,
            domains: domains.map { domain in
                _SetMembershipSubsetBreakdown.Domain(
                    id: domain.id,
                    title: domain.title,
                    tint: tintsByDomainID[domain.id] ?? .blue,
                    subsets: domain.subsets.map(\.runtime)
                )
            }
        )
    }
}

private extension _SetMembershipSubsetBreakdown.Subset {
    var cache: _SetMembershipSubsetBreakdownCache.Subset {
        _SetMembershipSubsetBreakdownCache.Subset(
            id: id,
            title: title,
            count: count,
            mastery: mastery,
            originalExplanationID: originalExplanationID,
            relatedPapers: relatedPapers,
            children: children.map(\.cache)
        )
    }
}

private struct _SetMembershipRelatedPaper: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let year: Int?
    let progress: _SetMembershipPaperProgress
}

private struct _SetMembershipPaperProgress: Hashable, Codable {
    var hasOverview: Bool = false
    var hasAssetsPipeline: Bool = false
    var hasFormula: Bool = false
    var hasComment: Bool = false
    var hasQuiz: Bool = false

    var cacheFingerprint: String {
        [
            hasOverview ? "1" : "0",
            hasAssetsPipeline ? "1" : "0",
            hasFormula ? "1" : "0",
            hasComment ? "1" : "0",
            hasQuiz ? "1" : "0"
        ].joined()
    }
}

private struct _SetMembershipSelectionSideView: View {
    let selections: [_SetMembershipSubsetBreakdown]
    let onClose: (_SetMembershipSubsetBreakdown) -> Void
    let onSelectPaper: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(selections) { selection in
                    _SetMembershipSubsetBreakdownView(selection: selection) {
                        onClose(selection)
                    } onSelectPaper: { paperID in
                        onSelectPaper?(paperID)
                    }
                }
            }
            .padding(.top, 18)
            .padding(.horizontal, 0)
            .padding(.bottom, 22)
        }
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(uiColor: .systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
        .textSelection(.enabled)
    }
}

private struct _SetMembershipSubsetBreakdownView: View {
    let selection: _SetMembershipSubsetBreakdown
    let onClose: () -> Void
    let onSelectPaper: (String) -> Void
    @State private var _expandedSubsetIDs: Set<String> = []
    @State private var _selectedSubsetIDs: Set<String> = []
    @State private var _runningPipelineNodeIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(selection.title)
                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(30), weight: .heavy))
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }
                Spacer(minLength: 12)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(18), weight: .heavy))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.secondary.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 24)

            VStack(alignment: .leading, spacing: 24) {
                ForEach(selection.domains) { domain in
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(domain.tint.opacity(0.88))
                                .frame(width: 18, height: 18)
                            Text(domain.title)
                                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(27), weight: .heavy))
                                .foregroundStyle(.primary)
                        }

                        if domain.subsets.isEmpty {
                            Text(L("下位集合なし", "No subsets"))
                                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(22), weight: .bold))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 25)
                        } else {
                            ForEach(domain.subsets) { subset in
                                _SetMembershipSubsetRowView(
                                    subset: subset,
                                    tint: domain.tint,
                                    depth: 0,
                                    expandedSubsetIDs: $_expandedSubsetIDs,
                                    selectedSubsetIDs: $_selectedSubsetIDs,
                                    runningPipelineNodeIDs: $_runningPipelineNodeIDs,
                                    onSelectPaper: onSelectPaper
                                )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(domain.tint.opacity(0.055))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(domain.tint.opacity(0.24), lineWidth: 1)
                    )
                    .padding(.horizontal, 0)
                }
            }
            .padding(.vertical, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(uiColor: .systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
        .textSelection(.enabled)
    }

    private func _masteryTint(_ mastery: _SetMembershipMasterySummary) -> Color {
        if mastery.wrong > 0 { return .red }
        if mastery.fraction >= 0.8 { return .green }
        if mastery.fraction >= 0.35 { return .orange }
        return .blue
    }
}

private struct _SetMembershipSubsetRowView: View {
    let subset: _SetMembershipSubsetBreakdown.Subset
    let tint: Color
    let depth: Int
    @Binding var expandedSubsetIDs: Set<String>
    @Binding var selectedSubsetIDs: Set<String>
    @Binding var runningPipelineNodeIDs: Set<String>
    let onSelectPaper: (String) -> Void

    var body: some View {
        let isOpen = depth == 0 || expandedSubsetIDs.contains(subset.id)
        let isSelected = selectedSubsetIDs.contains(subset.id)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if subset.children.isEmpty {
                    if selectedSubsetIDs.contains(subset.id) {
                        selectedSubsetIDs.remove(subset.id)
                    } else {
                        selectedSubsetIDs.insert(subset.id)
                    }
                } else {
                    if expandedSubsetIDs.contains(subset.id) {
                        expandedSubsetIDs.remove(subset.id)
                    } else {
                        expandedSubsetIDs.insert(subset.id)
                    }
                }
            } label: {
                HStack(spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: subset.children.isEmpty ? (isSelected ? "checkmark.circle.fill" : "circle.fill") : (isOpen ? "chevron.down" : "chevron.right"))
                            .font(.system(size: subset.children.isEmpty ? 10 : 18, weight: .heavy))
                            .foregroundStyle(tint.opacity(isSelected ? 0.95 : (subset.children.isEmpty ? 0.55 : 0.95)))
                            .frame(width: 22)
                        Text(subset.title)
                            .font(.system(size: CGFloat(max(21, 24 - depth)), weight: .heavy))
                            .foregroundStyle(isSelected ? tint.opacity(0.98) : .primary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(depth) * 28)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 12)
                    if subset.mastery.total > 0 {
                        Text("\(Int(subset.mastery.fraction * 100))%")
                            .font(.system(size: CGFloat(max(13, 16 - depth)), weight: .semibold, design: .monospaced))
                            .foregroundStyle(_masteryTint(subset.mastery).opacity(0.82))
                    }
                    RoundedRectangle(cornerRadius: 3)
                        .fill(_masteryTint(subset.mastery).opacity(0.72))
                        .frame(width: 6, height: depth == 0 ? 28 : 22)
                }
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(isSelected ? tint.opacity(0.10) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if depth > 1, let originalExplanationID = subset.originalExplanationID {
                _pipelineButtonsOnly(pipelinePrefix: _pipelinePrefix(from: originalExplanationID), subsetID: subset.id, depth: depth, tint: tint, runningPipelineNodeIDs: $runningPipelineNodeIDs, onSelectPaper: onSelectPaper)
            }

            if subset.children.isEmpty, !subset.relatedPapers.isEmpty {
                let indent = CGFloat(depth + 1) * 28

                let baseSize = CGFloat(max(21, 24 - depth))
                let itemSize = baseSize - 2
                let headingSize = baseSize - 4
                let yearSize = baseSize - 5

                // ── 概説 ──
                if let originalExplanationID = subset.originalExplanationID {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: "text.book.closed")
                                .font(.system(size: headingSize, weight: .bold))
                                .foregroundStyle(tint.opacity(0.7))
                            Text(L("概説", "Summaries"))
                                .font(.system(size: headingSize, weight: .bold))
                                .foregroundStyle(tint.opacity(0.7))
                        }
                        .padding(.leading, indent)
                        .padding(.top, 4)

                        ForEach(subset.relatedPapers) { paper in
                            Button {
                                onSelectPaper(originalExplanationID)
                            } label: {
                                HStack(alignment: .center, spacing: 8) {
                                    Text(paper.title)
                                        .font(.system(size: itemSize, weight: .regular))
                                        .foregroundStyle(tint.opacity(0.88))
                                        .lineLimit(2)
                                    Image(systemName: paper.progress.hasOverview ? "book.pages.fill" : "book.pages")
                                        .font(.system(size: itemSize - 2))
                                        .foregroundStyle(paper.progress.hasOverview ? Color.blue : Color.blue.opacity(0.35))
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, indent + 16)
                            .padding(.vertical, 4)
                        }
                    }

                    // ── 演習 ──
                    let quizID = originalExplanationID.replacingOccurrences(of: "inf6-explanation:", with: "inf6-quiz:")
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: "pencil.circle.fill")
                                .font(.system(size: headingSize, weight: .bold))
                                .foregroundStyle(Color(red: 0.85, green: 0.16, blue: 0.50).opacity(0.7))
                            Text(L("演習", "Exercises"))
                                .font(.system(size: headingSize, weight: .bold))
                                .foregroundStyle(Color(red: 0.85, green: 0.16, blue: 0.50).opacity(0.7))
                        }
                        .padding(.leading, indent)
                        .padding(.top, 4)

                        ForEach(subset.relatedPapers) { paper in
                            let paperQuizKey = "\(quizID)::paper::\(paper.id)"
                            let baseQuizKey = quizID
                            let hasPaperQuiz = Inf6MetadataStore.get(domain: .generatedQuizzes, key: paperQuizKey) != nil
                                || Inf6MetadataStore.get(domain: .generatedQuizzes, key: baseQuizKey) != nil
                            Button {
                                onSelectPaper(quizID + "::paper::" + paper.id)
                            } label: {
                                HStack(alignment: .center, spacing: 8) {
                                    Text(paper.title)
                                        .font(.system(size: itemSize, weight: .regular))
                                        .foregroundStyle(Color(red: 0.85, green: 0.16, blue: 0.50).opacity(0.88))
                                        .lineLimit(2)
                                    Image(systemName: hasPaperQuiz ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: itemSize - 2))
                                        .foregroundStyle(hasPaperQuiz ? Color.green : Color.secondary.opacity(0.35))
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, indent + 16)
                            .padding(.vertical, 4)
                        }
                    }
                }

                // ── 論文 ──
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.system(size: headingSize, weight: .bold))
                            .foregroundStyle(tint.opacity(0.7))
                        Text(L("論文", "Papers"))
                            .font(.system(size: headingSize, weight: .bold))
                            .foregroundStyle(tint.opacity(0.7))
                    }
                    .padding(.leading, indent)
                    .padding(.top, 4)

                    ForEach(subset.relatedPapers) { paper in
                        Button {
                            onSelectPaper(paper.id)
                        } label: {
                            HStack(alignment: .center, spacing: 8) {
                                if let year = paper.year {
                                    Text("\(year)")
                                        .font(.system(size: yearSize, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(tint.opacity(0.55))
                                }
                                Text(paper.title)
                                    .font(.system(size: itemSize, weight: .regular))
                                    .foregroundStyle(tint.opacity(0.88))
                                    .lineLimit(2)
                            }
                            .padding(.leading, indent + 16)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if isOpen {
                ForEach(subset.children) { child in
                    _SetMembershipSubsetRowView(
                        subset: child,
                        tint: tint,
                        depth: depth + 1,
                        expandedSubsetIDs: $expandedSubsetIDs,
                        selectedSubsetIDs: $selectedSubsetIDs,
                        runningPipelineNodeIDs: $runningPipelineNodeIDs,
                        onSelectPaper: onSelectPaper
                    )
                }
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func _概要解説Button(originalExplanationID: String, pipelinePrefix: String?, subsetID: String, depth: Int, tint: Color, runningPipelineNodeIDs: Binding<Set<String>>, onSelectPaper: @escaping (String) -> Void) -> some View {
        _概要解説ButtonContent(originalExplanationID: originalExplanationID, pipelinePrefix: pipelinePrefix, subsetID: subsetID, depth: depth, tint: tint, runningPipelineNodeIDs: runningPipelineNodeIDs, onSelectPaper: onSelectPaper)
    }

    @ViewBuilder
    private func _pipelineButtonsOnly(pipelinePrefix: String?, subsetID: String, depth: Int, tint: Color, runningPipelineNodeIDs: Binding<Set<String>>, onSelectPaper: @escaping (String) -> Void) -> some View {
        _PipelineButtonsOnlyContent(pipelinePrefix: pipelinePrefix, subsetID: subsetID, depth: depth, tint: tint, runningPipelineNodeIDs: runningPipelineNodeIDs, onSelectPaper: onSelectPaper)
    }

    @ViewBuilder
    private func _確認クイズButton(quizID: String, depth: Int, tint: Color, runningPipelineNodeIDs: Binding<Set<String>>, onSelectPaper: @escaping (String) -> Void) -> some View {
        let quizSpinnerID = "quiz:\(quizID)"
        let isRunning = runningPipelineNodeIDs.wrappedValue.contains(quizSpinnerID)
        let quizColor = Color(red: 0.85, green: 0.16, blue: 0.50)
        HStack(spacing: 10) {
            Button {
                runningPipelineNodeIDs.wrappedValue.insert(quizSpinnerID)
                onSelectPaper(quizID)
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(18), weight: .bold))
                        .foregroundStyle(quizColor.opacity(isRunning ? 0.4 : 0.86))
                        .frame(width: 22)
                    Text(L("演習", "Exercise"))
                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(20), weight: .heavy))
                        .foregroundStyle(quizColor.opacity(isRunning ? 0.4 : 0.96))
                }
            }
            .buttonStyle(.plain)
            .disabled(isRunning)
            .padding(.leading, CGFloat(depth + 1) * 28)
            .padding(.vertical, 7)

            if isRunning {
                _Inf6LargeProgressStatus(
                    title: L("演習を生成中", "Generating exercise"),
                    detail: L("選択した部分集合の演習問題を作成しています。", "Generating exercises for the selected subset."),
                    compact: true
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(NotificationCenter.default.publisher(for: .inf6QuizDidFinish)) { _ in
            runningPipelineNodeIDs.wrappedValue.remove(quizSpinnerID)
        }
    }

    private func _pipelinePrefix(from explanationID: String) -> String? {
        let prefix = "inf6-explanation:"
        guard explanationID.hasPrefix(prefix) else { return nil }
        return String(explanationID.dropFirst(prefix.count))
    }

    private func _paperTitle(_ paper: _SetMembershipRelatedPaper) -> String {
        guard let year = paper.year else { return paper.title }
        return "\(year) \(paper.title)"
    }

    private func _masteryTint(_ mastery: _SetMembershipMasterySummary) -> Color {
        if mastery.wrong > 0 { return .red }
        if mastery.fraction >= 0.8 { return .green }
        if mastery.fraction >= 0.35 { return .orange }
        return .blue
    }

}

private struct _PipelineStatus {
    var hasFigures: Bool = false
    var hasEquations: Bool = false
    var figureCount: Int = 0
    var equationCount: Int = 0
}

private func _checkPipelineStatus(prefix: String) -> _PipelineStatus {
    let parts = prefix.split(separator: ":", maxSplits: 1)
    guard parts.count == 2 else {
        NSLog("[inf6] pipelineStatus: prefix parse failed: '%@'", prefix)
        return _PipelineStatus()
    }
    let sf = String(parts[0])
    let nid = String(parts[1])

    let paperIDs = Inf6SyllabusPaperAutoSearch.linkedPaperIDs(sourceFamily: sf, syllabusNodeID: nid)
    NSLog("[inf6] pipelineStatus: sf=%@ nid=%@ papers=%d", sf, nid, paperIDs.count)
    var status = _PipelineStatus()

    for paperID in paperIDs {
        guard let paper = Inf6MetadataStore.getCodable(Inf6CorePaper.self, domain: .papers, key: paperID) else {
            NSLog("[inf6] pipelineStatus: paper not found: %@", paperID)
            continue
        }
        let pdfKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paper.titleEn ?? paper.title)
        guard !pdfKey.isEmpty else { continue }
        guard let index = Inf6MetadataStore.getCodable(Inf6DocEntityIndex.self, domain: .docEntities, key: pdfKey) else {
            NSLog("[inf6] pipelineStatus: no entity index for pdfKey=%@", pdfKey)
            continue
        }
        let figs = index.entities.filter { ($0.kind == .figure || $0.kind == .table) && $0.imagePath != nil && $0.explanation != nil }
        let eqs = index.entities.filter { $0.kind == .equation && $0.explanation != nil }
        NSLog("[inf6] pipelineStatus: pdfKey=%@ figs=%d eqs=%d", pdfKey, figs.count, eqs.count)
        if !figs.isEmpty { status.hasFigures = true; status.figureCount += figs.count }
        if !eqs.isEmpty { status.hasEquations = true; status.equationCount += eqs.count }
    }
    NSLog("[inf6] pipelineStatus: result hasFigures=%d hasEquations=%d figCount=%d eqCount=%d", status.hasFigures ? 1 : 0, status.hasEquations ? 1 : 0, status.figureCount, status.equationCount)
    return status
}

private struct _PipelineRerunRequest: Identifiable {
    let id = UUID()
    let kind: String
    let prefix: String
    let subsetID: String
}

private struct _PipelineButtonsOnlyContent: View {
    let pipelinePrefix: String?
    let subsetID: String
    let depth: Int
    let tint: Color
    @Binding var runningPipelineNodeIDs: Set<String>
    let onSelectPaper: (String) -> Void

    @State private var _pipelineStatus: _PipelineStatus?
    @State private var _rerunRequest: _PipelineRerunRequest?

    var body: some View {
        if let prefix = pipelinePrefix {
            let isRunningPipeline = runningPipelineNodeIDs.contains(subsetID)
            let status = _pipelineStatus ?? _PipelineStatus()
            HStack(spacing: 8) {
                let hasAll = status.hasFigures || status.hasEquations
                _pipelineButton(
                    label: L("図表式", "Assets"),
                    icon: hasAll ? "checkmark.seal.fill" : "square.stack.3d.up",
                    color: .blue,
                    hasExisting: hasAll,
                    count: status.figureCount + status.equationCount
                ) {
                    _handlePipelineTap(kind: "all", prefix: prefix, hasExisting: hasAll)
                }
                .disabled(isRunningPipeline)

                if isRunningPipeline {
                    _Inf6LargeProgressStatus(
                        title: L("図表・数式を処理中", "Processing figures and equations"),
                        detail: L("PDF から図表、表、数式の抽出状態を更新しています。", "Updating extracted figures, tables, and equations from the PDF."),
                        compact: true
                    )
                }
            }
            .padding(.leading, CGFloat(depth + 1) * 28)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                DispatchQueue.global(qos: .utility).async {
                    let status = _checkPipelineStatus(prefix: prefix)
                    DispatchQueue.main.async { _pipelineStatus = status }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .inf6PipelineDidStart)) { notification in
                guard (notification.object as? String) == prefix else { return }
                runningPipelineNodeIDs.insert(subsetID)
            }
            .onReceive(NotificationCenter.default.publisher(for: .inf6PipelineDidFinish)) { notification in
                guard (notification.object as? String) == prefix else { return }
                runningPipelineNodeIDs.remove(subsetID)
                DispatchQueue.global(qos: .utility).async {
                    let status = _checkPipelineStatus(prefix: prefix)
                    DispatchQueue.main.async { _pipelineStatus = status }
                }
            }
            .sheet(item: $_rerunRequest) { request in
                _PipelineRerunSheet(request: request) {
                    _rerunRequest = nil
                } onRun: { selectedIDs, additionalPrompt in
                    _rerunRequest = nil
                    let extra = additionalPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    var pipelineID = "inf6-pipeline:\(request.kind):\(request.prefix)::force::"
                    if !extra.isEmpty {
                        pipelineID += "::prompt::\(extra)"
                    }
                    onSelectPaper(pipelineID)
                }
            }
        }
    }

    @ViewBuilder
    private func _pipelineButton(label: String, icon: String, color: Color, hasExisting: Bool, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(label)
                if hasExisting {
                    Text("(\(count))")
                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(10), weight: .semibold))
                }
            }
            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(12), weight: .bold))
        }
        .buttonStyle(.bordered)
        .tint(hasExisting ? color.opacity(0.5) : color)
        .controlSize(.small)
    }

    private func _handlePipelineTap(kind: String, prefix: String, hasExisting: Bool) {
        NSLog("[inf6] pipelineTap: kind=%@ hasExisting=%d prefix=%@", kind, hasExisting ? 1 : 0, prefix)
        if hasExisting {
            _rerunRequest = _PipelineRerunRequest(kind: kind, prefix: prefix, subsetID: subsetID)
        } else {
            onSelectPaper("inf6-pipeline:\(kind):\(prefix)")
        }
    }
}

private struct _概要解説ButtonContent: View {
    let originalExplanationID: String
    let pipelinePrefix: String?
    let subsetID: String
    let depth: Int
    let tint: Color
    @Binding var runningPipelineNodeIDs: Set<String>
    let onSelectPaper: (String) -> Void

    @State private var _pipelineStatus: _PipelineStatus?
    @State private var _rerunRequest: _PipelineRerunRequest?

    var body: some View {
        HStack(spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "book.pages.fill")
                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(18), weight: .bold))
                    .foregroundStyle(tint.opacity(0.86))
                    .frame(width: 22)
                Text(L("概要解説", "Overview"))
                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(20), weight: .heavy))
                    .foregroundStyle(tint.opacity(0.96))
            }

            if depth > 0, let prefix = pipelinePrefix {
                let isRunningPipeline = runningPipelineNodeIDs.contains(subsetID)
                    let status = _pipelineStatus ?? _PipelineStatus()

                    let hasAll = status.hasFigures || status.hasEquations
                    _pipelineButton(
                        label: L("図表式", "Assets"),
                        icon: hasAll ? "checkmark.seal.fill" : "square.stack.3d.up",
                        color: .blue,
                        hasExisting: hasAll,
                        count: status.figureCount + status.equationCount
                    ) {
                        _handlePipelineTap(kind: "all", prefix: prefix, hasExisting: hasAll)
                    }
                    .disabled(isRunningPipeline)

                    if isRunningPipeline {
                        _Inf6LargeProgressStatus(
                            title: L("図表・数式を処理中", "Processing figures and equations"),
                            detail: L("PDF から図表、表、数式の抽出状態を更新しています。", "Updating extracted figures, tables, and equations from the PDF."),
                            compact: true
                        )
                    }
            }
        }
        .padding(.leading, CGFloat(depth + 1) * 28)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if let prefix = pipelinePrefix {
                DispatchQueue.global(qos: .utility).async {
                    let status = _checkPipelineStatus(prefix: prefix)
                    DispatchQueue.main.async { _pipelineStatus = status }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .inf6PipelineDidStart)) { notification in
            guard let prefix = pipelinePrefix, (notification.object as? String) == prefix else { return }
            runningPipelineNodeIDs.insert(subsetID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .inf6PipelineDidFinish)) { notification in
            guard let prefix = pipelinePrefix, (notification.object as? String) == prefix else { return }
            runningPipelineNodeIDs.remove(subsetID)
            DispatchQueue.global(qos: .utility).async {
                let status = _checkPipelineStatus(prefix: prefix)
                DispatchQueue.main.async { _pipelineStatus = status }
            }
        }
        .sheet(item: $_rerunRequest) { request in
            _PipelineRerunSheet(request: request) {
                _rerunRequest = nil
            } onRun: { selectedIDs, additionalPrompt in
                _rerunRequest = nil
                let extra = additionalPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                var pipelineID = "inf6-pipeline:\(request.kind):\(request.prefix)::force::"
                if !extra.isEmpty {
                    pipelineID += "::prompt::\(extra)"
                }
                onSelectPaper(pipelineID)
            }
        }
    }

    @ViewBuilder
    private func _pipelineButton(label: String, icon: String, color: Color, hasExisting: Bool, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(label)
                if hasExisting {
                    Text("(\(count))")
                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(10), weight: .semibold))
                }
            }
            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(12), weight: .bold))
        }
        .buttonStyle(.bordered)
        .tint(hasExisting ? color.opacity(0.5) : color)
        .controlSize(.small)
    }

    private func _handlePipelineTap(kind: String, prefix: String, hasExisting: Bool) {
        NSLog("[inf6] pipelineTap: kind=%@ hasExisting=%d prefix=%@", kind, hasExisting ? 1 : 0, prefix)
        if hasExisting {
            _rerunRequest = _PipelineRerunRequest(kind: kind, prefix: prefix, subsetID: subsetID)
        } else {
            onSelectPaper("inf6-pipeline:\(kind):\(prefix)")
        }
    }
}

private struct _PipelineRerunPaper: Identifiable {
    let id: String
    let title: String
}

private struct _PipelineRerunSheet: View {
    let request: _PipelineRerunRequest
    let onCancel: () -> Void
    let onRun: (Set<String>, String) -> Void

    @State private var _papers: [_PipelineRerunPaper] = []
    @State private var _selectedIDs: Set<String> = []
    @State private var _additionalPrompt: String = ""

    private var kindLabel: String {
        switch request.kind {
        case "figures": return L("図表", "Figures")
        case "equations": return L("数式", "Equations")
        default: return L("図表式", "All")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L("パイプライン再実行しますか？", "Re-run pipeline?"))
                        .font(.headline)
                    Text(L("既存の結果は上書きされます。", "Existing results will be overwritten."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section(header: HStack {
                    // 全選択と選択解除を丸ひとつにまとめ、左端に置く。
                    // 他の一覧と同じ形にして、どこでも同じ操作で選べるようにする。
                    let allSelected = !_papers.isEmpty && _selectedIDs.count == _papers.count
                    Button {
                        if allSelected {
                            _selectedIDs.removeAll()
                        } else {
                            _selectedIDs = Set(_papers.map { $0.id })
                        }
                    } label: {
                        VStack(spacing: 1) {
                            Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                            Text(allSelected ? L("全解除", "Deselect") : L("全選択", "Select"))
                                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(8), weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(_papers.isEmpty)

                    Text(L("対象論文", "Target Papers"))
                    Spacer()
                }) {
                    if _papers.isEmpty {
                        Text(L("論文が見つかりません", "No papers found"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(_papers) { paper in
                            Button {
                                if _selectedIDs.contains(paper.id) {
                                    _selectedIDs.remove(paper.id)
                                } else {
                                    _selectedIDs.insert(paper.id)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: _selectedIDs.contains(paper.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(_selectedIDs.contains(paper.id) ? .blue : .secondary)
                                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(20)))
                                    Text(paper.title)
                                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(15)))
                                        .foregroundStyle(.primary)
                                        .lineLimit(3)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section(header: Text(L("追加プロンプト（任意）", "Additional Prompt (optional)"))) {
                    TextEditor(text: $_additionalPrompt)
                        .frame(minHeight: 80)
                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(15)))
                }
            }
            .navigationTitle(L("パイプライン再実行: \(kindLabel)", "Re-run Pipeline: \(kindLabel)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("キャンセル", "Cancel"), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("実行", "Run")) {
                        onRun(_selectedIDs, _additionalPrompt)
                    }
                    .bold()
                    .disabled(_selectedIDs.isEmpty)
                }
            }
            .onAppear {
                _loadPapers()
            }
        }
    }

    private func _loadPapers() {
        let parts = request.prefix.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return }
        let sf = String(parts[0])
        let nid = String(parts[1])
        let paperIDs = Inf6SyllabusPaperAutoSearch.linkedPaperIDs(sourceFamily: sf, syllabusNodeID: nid)
        var papers: [_PipelineRerunPaper] = []
        for pid in paperIDs {
            if let paper = Inf6MetadataStore.getCodable(Inf6CorePaper.self, domain: .papers, key: pid) {
                papers.append(_PipelineRerunPaper(id: pid, title: paper.titleEn ?? paper.title))
            }
        }
        _papers = papers
        _selectedIDs = Set(papers.map { $0.id })
        NSLog("[inf6] rerunSheet: loaded %d papers for %@:%@", papers.count, sf, nid)
    }
}

private struct _SetMembershipPaperProgressStrip: View {
    let progress: _SetMembershipPaperProgress
    let tint: Color

    private var items: [(systemName: String, isComplete: Bool, label: String)] {
        [
            ("doc.text.fill", progress.hasOverview, L("要旨", "Abstract")),
            ("photo.on.rectangle.angled", progress.hasAssetsPipeline, L("図表", "Figures")),
            ("function", progress.hasFormula, L("数式", "Equations")),
            ("text.bubble.fill", progress.hasComment, L("コメント", "Comments")),
            ("pencil.circle.fill", progress.hasQuiz, L("演習", "Exercise"))
        ]
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.label) { item in
                Image(systemName: item.systemName)
                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(10), weight: .heavy))
                    .foregroundStyle(item.isComplete ? Color.white : tint.opacity(0.62))
                    .frame(width: 22, height: 22)
                    .background(
                        Circle()
                            .fill(item.isComplete ? tint.opacity(0.95) : tint.opacity(0.14))
                    )
                    .overlay(
                        Circle()
                            .stroke(tint.opacity(item.isComplete ? 0.95 : 0.28), lineWidth: 1)
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(_accessibilityLabel)
    }

    private var _accessibilityLabel: Text {
        let names: [(String, Bool)] = [
            (L("要旨", "Abstract"), progress.hasOverview),
            (L("図表", "Figures"), progress.hasAssetsPipeline),
            (L("数式", "Equations"), progress.hasFormula),
            (L("コメント", "Comments"), progress.hasComment),
            (L("演習", "Exercise"), progress.hasQuiz)
        ]
        let sep = L("、", ", ")
        let done = names.filter(\.1).map(\.0).joined(separator: sep)
        return Text(done.isEmpty ? L("論文達成度 0", "Paper progress 0") : L("論文達成度 \(done)", "Paper progress: \(done)"))
    }
}

private struct _UnsupportedVennDomainCountView: View {
    let count: Int

    var body: some View {
        Text(L("正確なベン図は3ドメインで表示します。現在のドメイン数: \(count)", "Accurate Venn diagrams require exactly 3 domains. Current count: \(count)"))
            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(15), weight: .semibold))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }
}

private extension CGRect {
    init(center: CGPoint, size: CGSize) {
        self.init(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
