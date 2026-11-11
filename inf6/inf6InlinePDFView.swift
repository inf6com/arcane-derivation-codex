//
//  inf6InlinePDFView.swift
//  inf6
//
//  Created by decopin on 2026/01/03.
//

import Foundation
import SwiftUI

#if !os(iOS)
#error("InlinePDFPagesView is iOS-only. Remove this file from non-iOS targets.")
#endif

// PDFKit is required for InlinePDFPagesView.
#if canImport(PDFKit)
import PDFKit
#else
#error("InlinePDFPagesView requires PDFKit. Add PDFKit to the iOS target, or remove this file from the target.")
#endif

// UIKit is required for InlinePDFPagesView.
#if canImport(UIKit)
import UIKit
#else
#error("InlinePDFPagesView requires UIKit. Add UIKit to the iOS target, or remove this file from the target.")
#endif

#if canImport(CryptoKit)
import CryptoKit
#endif


// MARK: - File sections (internal split; same-file)
//  1) PDF load & file-provider I/O (security-scope, coordinated reads, iCloud download)
//  2) Generated overview persistence (paper.abstract.txt)
//  3) Per-page notes persistence (pN.notes.json)
//  4) iCloud Documents helpers (Inf6KnowledgeCardsPaths.rootFolderName/<paperKey>/...)
//  5) Figure detection + Base64 export helpers
//  6) Text extraction helpers (page/document text)
//  7) View state transitions (PDF change / page change)
//  8) AI actions (overview / page explain / ask)
//  9) UI components (HUDs / sliders / sheets / editors)
// 10) Layout (split view + toolbar + body)

// MARK: - Inline PDF pages view (rebuilt, minimal)
// MARK: - 1) PDF load & file-provider I/O

struct InlinePDFPagesView: View {
    enum _ExplainActionTarget: String {
        case selection
        case page
        case term
    }

    enum _ExplainActionKind: String {
        case summarize
        case comment
        case explain
    }

    enum _ExplainActionScope: String {
        case local
        case web
    }

    struct _ExplainActionsDraft: Equatable {
        var target: _ExplainActionTarget
        var kind: _ExplainActionKind
        var scope: _ExplainActionScope
    }

    // Last surfaced I/O error (read/write/delete/create-dir). No silent fallback.
    @State var _ioLastError: String? = nil
    // --- Long-running action state flags ---
    @State var _isRunningAssetsPipeline: Bool = false
    @State var _assetsPipelineTask: Task<Void, Never>? = nil
    @State var _isRunningExplain: Bool = false
    @State var _isRunningMiniBuild: Bool = false
    @State var _isRunningAbstractGen: Bool = false
    @State var _isPinchingMiniMathImage: Bool = false
    @State var _entityIndexRefreshID: UUID = UUID()


    
    

    // MARK: - Key normalization helpers

    @inline(__always)
    func _trimWS(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    /// Returns the PDF base name (no trailing ".pdf"), trimmed.
    /// If a non-PDF URL reaches here, it surfaces an error (this view is PDF-only).
    func _pdfBaseName(from u: URL) -> String {
        let raw = _trimWS(u.lastPathComponent)
        if raw.lowercased().hasSuffix(".pdf") {
            return _trimWS(String(raw.dropLast(4)))
        }

        let ext = u.pathExtension.lowercased()
        if !ext.isEmpty && ext != "pdf" {
            let msg = "[InlinePDFPagesView] _pdfBaseName: non-PDF URL (unexpected): \(u)"
            print(msg)
            DispatchQueue.main.async { _ioLastError = msg }
        }

        return _trimWS(u.deletingPathExtension().lastPathComponent)
    }

    func _loadPDFDocument(from url: URL) -> PDFDocument? {
        let result = Inf6InlinePDFDocumentLoader.load(from: url)
        if let msg = result.errorMessage {
            print(msg)
            DispatchQueue.main.async { _ioLastError = msg }
        }
        return result.document
    }

    let url: URL
    @State var _activeURL: URL
    let onTap: (Int, String, String) -> Void

    /// 取り込んだ論文を別ウィンドウで開くために使う。
    @Environment(\.openWindow) var openWindow

    @Binding var explanation: String
    let onPageChange: (Int) -> String?

    /// Injected action (owned by the parent) to run the assets pipeline across all pages.
    /// This is intentionally not implemented inside this view so other UI entry points can reuse it.
    let assetsPipelineAllPagesAction: @MainActor () async -> Void

    let loadExtraNotes: ((Int) -> [Inf6ExtraNote]?)?
    let saveExtraNotes: ((Int, [Inf6ExtraNote]) -> Void)?

    var _selectedPageExternal: Binding<Int>? = nil
    @State var _selectedPageInternal: Int = 0
    var selectedPage: Binding<Int> { _selectedPageExternal ?? $_selectedPageInternal }

    @State var pdfDocument: PDFDocument? = nil
    @State var pdfTitle: String = "Explanation"
    @State var pdfViewRef: PDFView? = nil

    @State var zoom: CGFloat = 1.0

    @AppStorage("inf6_pdfZoom") var storedZoom: Double = 1.0
    @State var detailFontScalePDF: CGFloat = 1.8
    @State var _detailPinchStartFontScale: CGFloat? = nil

    @State var pdfSelectedText: String = ""
    @State var detailSelectedText: String = ""
    @State var _lastNonEmptySelectionText: String = ""
    @State var _explainPanelSelectionText: String = ""
    @State var _isInteractingDetailPaneText: Bool = false
    @State var _isDetailTextInteracting: Bool = false
    @State var _selectionMirrorByNoteID: [UUID: String] = [:]
    @State var _miniCardSelectedText: String = ""
    @State var extraNotesByPage: [Int: [Inf6ExtraNote]] = [:]

    @State var _inFlightExplainTask: Task<Void, Never>? = nil
    @State var _inFlightAbstractTask: Task<Void, Never>? = nil
    @State var _inFlightMathTask: Task<Void, Never>? = nil

    @State var sourceAbstractNote: Inf6ExtraNote = Inf6ExtraNote(text: "")
    @State var abstractNote: Inf6ExtraNote = Inf6ExtraNote(text: "")

    @State var _suppressZoomPersistUntilPDFViewReady: Bool = true
    
    // MARK: - Mini PDF (equation-only) per-page storage (multiple cards)

    @State var miniCardsByPage: [Int: [MiniCard]] = [:]
    // Pending mini-cards publish (defer UI state churn while text selection is active).
    @State var _miniPendingLoadedByPage: [Int: [MiniCard]] = [:]
    @State var _miniPendingPublishWorkByPage: [Int: DispatchWorkItem] = [:]
    @State var _miniLoadRetryCountByPage: [Int: Int] = [:]

    // Per-page selected mini card (for actions like “regen explanation” / default focus).
    @State var _miniSelectedCardIDByPage: [Int: String] = [:]
    @State var _miniLoadTaskByPage: [Int: Task<Void, Never>] = [:]

    @State var _notesLoadRetryCountByPage: [Int: Int] = [:]
    let _maxAbstractChars: Int = 18000

    // Localized string helper (module-local)
    @inline(__always)
    func L(_ ja: String, _ en: String) -> String {
        switch genLangRaw {
        case "ja":
            return ja
        case "en":
            return en
        default:
            let lang = (Locale.preferredLanguages.first ?? Locale.current.identifier).lowercased()
            return lang.hasPrefix("ja") ? ja : en
        }
    }

    let _maxSelectionPreviewChars: Int = 180
    let _maxSelectionPromptChars: Int = 800
    let _maxPagePromptChars: Int = 6000

    @AppStorage("inf6_showDetailPane") var showDetailPane: Bool = true
    @AppStorage("gen_lang") var genLangRaw: String = "ja"
    @AppStorage("inf6_showThumbnailSidebar") var showThumbnailSidebar: Bool = true

     var _thumbnailSidebarWidth: CGFloat {
        #if os(iOS)
        switch UIDevice.current.userInterfaceIdiom {
        case .phone:
            return 120
        default:
            return 140
        }
        #else
        return 160
        #endif
    }

    // Split position between PDF pane (top) and detail pane (bottom).
    // Keep drag-time updates local and persist only when the drag ends.
    @AppStorage("inf6_detailPaneSplitRatio") var _persistedDetailPaneSplitRatio: Double = 0.62
    @State var detailPaneSplitRatio: Double = {
        if let stored = UserDefaults.standard.object(forKey: "inf6_detailPaneSplitRatio") as? NSNumber {
            return stored.doubleValue
        }
        return 0.62
    }()
    @State var _splitDragStartRatio: Double? = nil

    @State var showOpenAISettings: Bool = false
    @State var _storageAvailable: Bool = true

    @State var _abstractSaveTask: Task<Void, Never>? = nil
    @State var _suppressAbstractAutosave: Bool = false
    @State var _inFlightMathTaskByCardID: [String: Task<Void, Never>] = [:]
    @State var _pendingDeleteMiniCardID: String? = nil
    @State var _miniBuildLastError: String? = nil
    @State var showQuizSheet: Bool = false
    @State var _inFlightAutoQuizRegenerationTask: Task<Void, Never>? = nil
    @State var _autoQuizLastError: String? = nil
    @State var isPresentingAskNoteSheet: Bool = false
    @State var askNotePrompt: String = ""
    @State var isAskingNote: Bool = false
    @State var askNoteErrorMessage: String? = nil
    @State var _assetsPipelineDidFinish: Bool = false
    @State var _assetsPipelineFinishedMessage: String? = nil
    @State var isShowingExplainActionsPanel: Bool = false
    @State var isShowingExplainPromptPanel: Bool = false
    @State var explainPromptText: String = ""
    @State var explainPromptError: String? = nil
    @State var explainPromptTargetPage: Int = 0
    @State var explainPromptSelection: String? = nil
    @State var explainPromptUseWebSearch: Bool = false

    init(
        url: URL,
        onTap: @escaping (Int, String, String) -> Void,
        explanation: Binding<String>,
        onPageChange: @escaping (Int) -> String?,
        assetsPipelineAllPagesAction: @escaping @MainActor () async -> Void,
        selectedPage: Binding<Int>? = nil,
        loadExtraNotes: ((Int) -> [Inf6ExtraNote]?)? = nil,
        saveExtraNotes: ((Int, [Inf6ExtraNote]) -> Void)? = nil
    ) {
        self.url = url
        self.onTap = onTap
        self._explanation = explanation
        self.onPageChange = onPageChange
        self.assetsPipelineAllPagesAction = assetsPipelineAllPagesAction
        self.loadExtraNotes = loadExtraNotes
        self.saveExtraNotes = saveExtraNotes
        self._selectedPageExternal = selectedPage
        let initialLoad = Inf6InlinePDFDocumentLoader.load(from: url)
        self.__activeURL = State(initialValue: url)
        self._pdfDocument = State(initialValue: initialLoad.document)
        self.__ioLastError = State(initialValue: initialLoad.errorMessage)
    }

    var _explainPromptPanelMaxWidth: CGFloat {
        #if os(iOS)
        switch UIDevice.current.userInterfaceIdiom {
        case .phone:
            return 320
        default:
            return 360
        }
        #else
        return 360
        #endif
    }


    // MARK: - 5) Figure detection + Base64 export

    @State var _figureCandidatePages: [Int] = []
    @State var _figureDetectLastError: String? = nil
    @State var _lastCopiedPageBase64Preview: String? = nil




    // MARK: - 5) Figure detection (text scan + Base64 page export)

    func _detectFigureCandidatePagesByText() {
        _figureDetectLastError = nil

        guard let doc = pdfDocument else {
            _figureCandidatePages = []
            _figureDetectLastError = "[FigureDetect] pdfDocument is nil (PDF not loaded yet)"
            return
        }

        _figureCandidatePages = InlinePDFFigureDetect.detectCandidatePages(doc: doc)
        if _figureCandidatePages.isEmpty {
            _figureDetectLastError = "[FigureDetect] No figure keywords found in page text (Fig/Figure/図)"
        }
    }

    func _copyCurrentPageImageBase64ForGPT() {
        _figureDetectLastError = nil
        _lastCopiedPageBase64Preview = nil
        let idx = selectedPage.wrappedValue

        guard let doc = pdfDocument else {
            _figureDetectLastError = "[FigureDetect] pdfDocument is nil (PDF not loaded yet)"
            return
        }

        do {
            let preview = try InlinePDFFigureDetect.copyPageImageBase64ToPasteboard(
                doc: doc,
                pageIndex: idx,
                targetWidth: 1800,
                quality: 0.82
            )
            _lastCopiedPageBase64Preview = preview
        } catch {
            _figureDetectLastError = "[FigureDetect] \(error.localizedDescription)"
        }
    }

    // MARK: - 8) AI actions (overview / explanation / ask)

    @MainActor
    func generatePaperAbstractInternal() async {
        let targetLang = (genLangRaw == "en") ? "en" : "ja"

        func _setOverviewUI(_ text: String) {
            explanation = text
            if abstractNote.text != text {
                abstractNote.text = text
                abstractNote.rtf = nil
            }
            // If the detail-pane text interaction flag is stuck true (e.g. selection mirror),
            // UIKit note views may refuse to refresh their attributedText on iPad.
            // Abstract generation must always surface immediately.
            if _isInteractingDetailPaneText {
                _isInteractingDetailPaneText = false
            }
        }

        // Ensure the external PDF URL is readable before the pipeline tries to open it.
        let pdfURL = _activeURL

        #if os(iOS)
        let didAccess = pdfURL.startAccessingSecurityScopedResource()
        defer { if didAccess { pdfURL.stopAccessingSecurityScopedResource() } }
        #endif

        guard FileManager.default.isReadableFile(atPath: pdfURL.path) else {
            _setOverviewUI(L(
                "⚠︎ PDFファイルを読めないため、概略解説生成を開始できません。外部PDFの実体を端末上で読める場所に置いてから再実行してください。",
                "⚠︎ Overview generation cannot start because the PDF file is not readable. Place the external PDF where this device can read it, then try again."
            ))
            return
        }

        do {
            let out = try await Inf6AssetsAbstractPipeline.generatePaperAbstract(
                pdfURL: pdfURL,
                paperTitle: pdfTitle,
                genLang: targetLang,
                askModel: { prompt in
                    let promptRef = (targetLang == "en")
                        ? Inf6PromptCatalog.assetsPromptBridgeEn
                        : Inf6PromptCatalog.assetsPromptBridgeJa
                    let rendered = try Inf6PromptGovernance.renderSystemUserPrompt(
                        ref: promptRef,
                        variables: ["task_prompt": prompt]
                    )
                    return try await Inf6LibraryView.askOpenAIText(
                        systemInstruction: rendered.systemInstruction,
                        userPrompt: rendered.userPrompt,
                        lang: targetLang
                    )
                }
            )

            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                _setOverviewUI(L("⚠︎ 概略解説生成結果が空です。", "⚠︎ Empty overview result."))
                return
            }

            _setOverviewUI(trimmed)
            _scheduleAbstractSave(trimmed)
        } catch {
            _setOverviewUI(L(
                "⚠︎ エラー: \(error.localizedDescription)",
                "⚠︎ Error: \(error.localizedDescription)"
            ))
        }
    }

    func _appendNote(page: Int, placeholderHead: String) {
        withAnimation {
            var notes = extraNotesByPage
            var arr = notes[page, default: []]
            let needsGap = !arr.isEmpty
            let text = (needsGap ? "\n" : "") + placeholderHead
            arr.append(Inf6ExtraNote(text: text))
            notes[page] = arr
            extraNotesByPage = notes
            showDetailPane = true
            _persistExtraNotes(page: page, arr)
        }
    }

    func _replaceLastNote(page: Int, with finalText: String) {
        withAnimation {
            var notes = extraNotesByPage
            var arr = notes[page, default: []]
            if !arr.isEmpty {
                arr[arr.count - 1].text = finalText
                arr[arr.count - 1].rtf = nil
            } else {
                arr.append(Inf6ExtraNote(text: finalText))
            }
            notes[page] = arr
            extraNotesByPage = notes
            _persistExtraNotes(page: page, arr)
        }
    }

    func _handlePassiveTap(idx: Int, snippet: String, tag: String) {
        let t = tag.lowercased()
        let isSelection = (t == "selection") || t.contains("select")

        if isSelection {
            let trimmed = snippet.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !trimmed.isEmpty {
                pdfSelectedText = trimmed
            }
        } else {
            if !pdfSelectedText.isEmpty {
                pdfSelectedText = ""
            }
            if !detailSelectedText.isEmpty {
                detailSelectedText = ""
            }
            _clearRememberedSelectionText()
        }

        onTap(idx, snippet, tag)
    }


    // MARK: - Commented explain (floating panel helpers)

    @MainActor
    func _openExplainPromptPanelForCurrentContext() {
        explainPromptError = nil
        explainPromptTargetPage = selectedPage.wrappedValue

        let sel = pdfSelectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        explainPromptSelection = sel.isEmpty ? nil : sel

        isShowingExplainPromptPanel = true
    }

    @MainActor
    func _closeExplainPromptPanel() {
        isShowingExplainPromptPanel = false
        explainPromptError = nil
    }

    @MainActor
    func _submitExplainPromptPanel() {
        explainPromptError = nil

        let idx = explainPromptTargetPage
        let comment = explainPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let selection = explainPromptSelection

        _requestExplain(pageIndex: idx, selectionText: selection, userPrompt: comment.isEmpty ? nil : comment)
        isShowingExplainPromptPanel = false
    }

    /// Floating panel view. The UI layer should mount this with `.overlay(alignment: ...)`.
    @ViewBuilder
    func _explainPromptPanelOverlay() -> some View {
        if isShowingExplainPromptPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("コメント付き解説1", "Commented explain"))
                        .font(.headline)

                    Spacer()

                    Button {
                        Task { @MainActor in _closeExplainPromptPanel() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help(L("閉じる", "Close"))
                }

                Text(L("対象ページ: ", "Target page: ") + String(explainPromptTargetPage + 1))
                    .font(.subheadline)

                if let sel = explainPromptSelection, !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let preview = (sel.count <= _maxSelectionPreviewChars)
                        ? sel
                        : (String(sel.prefix(_maxSelectionPreviewChars)) + "…")
                    Text(L("選択: ", "Selection: ") + "\"" + preview + "\"")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                Text(L("コメント（任意）", "Comment (optional)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("", text: $explainPromptText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .submitLabel(.done)
                    .onSubmit {
                        _dismissKeyboard()
                    }

                if let err = explainPromptError, !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button {
                        Task { @MainActor in _closeExplainPromptPanel() }
                    } label: {
                        Text(L("キャンセル", "Cancel"))
                    }

                    Spacer()

                    Button {
                        Task { @MainActor in _submitExplainPromptPanel() }
                    } label: {
                        Text(L("生成", "Generate"))
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(10)
            .frame(maxWidth: _explainPromptPanelMaxWidth)
            .background(Color(UIColor.systemBlue).opacity(0.06))
            .cornerRadius(12)
            .shadow(radius: 10)
            .padding(12)
        }
    }

    func _requestExplain(pageIndex idx: Int, selectionText: String?, userPrompt: String? = nil) {
        _inFlightExplainTask?.cancel()
        _inFlightExplainTask = nil
        _isRunningExplain = true

        let targetLang = (genLangRaw == "en") ? "en" : "ja"
        let selectionTrimmed = (selectionText ?? "").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let useSelection = !selectionTrimmed.isEmpty

        let extra = (userPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let extraPerspectiveEn = extra.isEmpty ? "(none)" : extra
        let extraPerspectiveJa = extra.isEmpty ? "（なし）" : extra

        func preview(_ s: String) -> String {
            if s.count <= _maxSelectionPreviewChars { return s }
            return String(s.prefix(_maxSelectionPreviewChars)) + "…"
        }

        if useSelection {
            let head = preview(selectionTrimmed)
            _appendNote(page: idx, placeholderHead: "ページ解説（選択）: \"\(head)\" …生成中")

            let selectionForPrompt = String(selectionTrimmed.prefix(_maxSelectionPromptChars))

            _inFlightExplainTask = Task {
                defer {
                    Task { @MainActor in
                        _inFlightExplainTask = nil
                        _isRunningExplain = false
                    }
                }
                do {
                    try Task.checkCancellation()

                    let pageText = await MainActor.run { _pageText(pageIndex: idx, maxChars: _maxPagePromptChars) }
                    if pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        await MainActor.run {
                            _replaceLastNote(page: idx, with: "ページ解説（選択）: \"\(head)\"\n⚠︎ 本文テキストを取得できません（PDF未ロード/読み取り失敗）")
                        }
                        return
                    }

                    try Task.checkCancellation()
                    let local = Inf6LibraryView.snippetAround(pageText, needle: selectionForPrompt, radius: 240)
                    let ragChunks = await MainActor.run {
                        _collectRAGChunksSnapshot(
                            maxCharsPerPage: _maxPagePromptChars,
                            chunkChars: 900,
                            overlapChars: 180
                        )
                    }
                    let ragQuery = selectionForPrompt + "\n\n" + extra
                    let ragContext = try await Self._buildRAGEvidenceText(
                        query: ragQuery,
                        focusPageIndex: idx,
                        chunks: ragChunks,
                        topK: 4,
                        lexicalTopK: 24
                    )
                    let promptRef = (targetLang == "en")
                        ? Inf6PromptCatalog.selectionExplainEn
                        : Inf6PromptCatalog.selectionExplainJa
                    let localSnippet = local.isEmpty
                        ? ((targetLang == "en") ? "(no local snippet)" : "(抜粋なし)")
                        : local
                    let rendered = try Inf6PromptGovernance.renderSystemUserPrompt(
                        ref: promptRef,
                        variables: [
                            "selection_excerpt": selectionForPrompt,
                            "local_snippet": localSnippet,
                            "rag_context": ragContext,
                            "additional_instruction": (targetLang == "en") ? extraPerspectiveEn : extraPerspectiveJa
                        ]
                    )

                    let ai = try await Inf6LibraryView.askOpenAIText(
                        systemInstruction: rendered.systemInstruction,
                        userPrompt: rendered.userPrompt,
                        lang: targetLang
                    )
                    try Task.checkCancellation()

                    let trimmed = ai.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    let capped = (trimmed.count > 8000) ? String(trimmed.prefix(8000)) : trimmed

                    await MainActor.run {
                        _replaceLastNote(page: idx, with: "ページ解説（選択）: \"\(head)\"\n\(capped)")
                    }
                } catch is CancellationError {
                    return
                } catch {
                    await MainActor.run {
                        _replaceLastNote(page: idx, with: "ページ解説（選択）: \"\(head)\"\n⚠︎ \(error.localizedDescription)")
                    }
                }
            }
            return
        }

        let pageNumber = idx + 1
        _appendNote(page: idx, placeholderHead: "ページ解説（ページ \(pageNumber)） …生成中")

        _inFlightExplainTask = Task {
            defer {
                Task { @MainActor in
                    _inFlightExplainTask = nil
                    _isRunningExplain = false
                }
            }
            do {
                try Task.checkCancellation()

                let pageText = await MainActor.run { _pageText(pageIndex: idx, maxChars: _maxPagePromptChars) }
                if pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await MainActor.run {
                        _replaceLastNote(page: idx, with: "ページ解説（ページ \(pageNumber)）\n⚠︎ 本文テキストを取得できません（PDF未ロード/読み取り失敗）")
                    }
                    return
                }

                try Task.checkCancellation()
                let ragChunks = await MainActor.run {
                    _collectRAGChunksSnapshot(
                        maxCharsPerPage: _maxPagePromptChars,
                        chunkChars: 900,
                        overlapChars: 180
                    )
                }
                let ragQuery = pageText + "\n\n" + extra
                let ragContext = try await Self._buildRAGEvidenceText(
                    query: ragQuery,
                    focusPageIndex: idx,
                    chunks: ragChunks,
                    topK: 4,
                    lexicalTopK: 24
                )
                let promptRef = (targetLang == "en")
                    ? Inf6PromptCatalog.pageExplainEn
                    : Inf6PromptCatalog.pageExplainJa
                let rendered = try Inf6PromptGovernance.renderSystemUserPrompt(
                    ref: promptRef,
                    variables: [
                        "page_number": String(pageNumber),
                        "page_text": pageText,
                        "rag_context": ragContext,
                        "additional_instruction": (targetLang == "en") ? extraPerspectiveEn : extraPerspectiveJa
                    ]
                )

                let ai = try await Inf6LibraryView.askOpenAIText(
                    systemInstruction: rendered.systemInstruction,
                    userPrompt: rendered.userPrompt,
                    lang: targetLang
                )
                try Task.checkCancellation()

                let trimmed = ai.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                let capped = (trimmed.count > 8000) ? String(trimmed.prefix(8000)) : trimmed

                await MainActor.run {
                    _replaceLastNote(page: idx, with: "ページ解説（ページ \(pageNumber)）\n\(capped)")
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    _replaceLastNote(page: idx, with: "ページ解説（ページ \(pageNumber)）\n⚠︎ \(error.localizedDescription)")
                }
            }
        }
    }



    func _requestExplainSelectedTerm(pageIndex idx: Int, selectionText: String?, userPrompt: String? = nil, allowWebSearch: Bool = false) {
        _inFlightExplainTask?.cancel()
        _inFlightExplainTask = nil
        _isRunningExplain = true

        let targetLang = (genLangRaw == "en") ? "en" : "ja"
        let selectionTrimmed = (selectionText ?? "").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let scopeLabelJa = allowWebSearch ? "Web検索" : "本文"

        let extra = (userPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let extraPerspectiveEn = extra.isEmpty ? "(none)" : extra
        let extraPerspectiveJa = extra.isEmpty ? "（なし）" : extra

        func preview(_ s: String) -> String {
            if s.count <= _maxSelectionPreviewChars { return s }
            return String(s.prefix(_maxSelectionPreviewChars)) + "…"
        }

        // 選択テキストが無い場合は「用語解説」にならないため処理しません（失敗として明示）。
        if selectionTrimmed.isEmpty {
            _isRunningExplain = false
            _appendNote(page: idx, placeholderHead: "用語解説（\(scopeLabelJa)）\n⚠︎ 選択テキストが空のため、用語解説を実行できません。用語（短いフレーズ）を選択してから再実行してください。")
            return
        }

        let head = preview(selectionTrimmed)
        _appendNote(page: idx, placeholderHead: "用語解説（\(scopeLabelJa)）: \"\(head)\" …生成中")

        let selectionForPrompt = String(selectionTrimmed.prefix(_maxSelectionPromptChars))

        // Capture page context for grounding (same pattern as explainWithPromptInternal)
        let pageText: String = {
            guard let doc = pdfDocument else { return "" }
            guard idx >= 0, idx < doc.pageCount else { return "" }
            return (doc.page(at: idx)?.string ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        let localPageContext: String = {
            guard !pageText.isEmpty else { return "" }
            let snippet = Inf6LibraryView.snippetAround(pageText, needle: selectionTrimmed, radius: 240)
            return snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? pageText : snippet
        }()
        let ragChunks = _collectRAGChunksSnapshot(
            maxCharsPerPage: _maxPagePromptChars,
            chunkChars: 900,
            overlapChars: 180
        )

        _inFlightExplainTask = Task {
            defer {
                Task { @MainActor in
                    _inFlightExplainTask = nil
                    _isRunningExplain = false
                }
            }
            do {
                try Task.checkCancellation()

                // Build RAG context only for web variant (adds latency; skip for local)
                let ragContext: String
                if allowWebSearch, !ragChunks.isEmpty {
                    ragContext = (try? await Self._buildRAGEvidenceText(
                        query: selectionForPrompt,
                        focusPageIndex: idx,
                        chunks: ragChunks,
                        topK: 3,
                        lexicalTopK: 16
                    )) ?? ""
                } else {
                    ragContext = ""
                }

                let promptRef: Inf6PromptRef = {
                    if targetLang == "en" {
                        return allowWebSearch
                            ? Inf6PromptCatalog.termExplainEnWeb
                            : Inf6PromptCatalog.termExplainEnLocal
                    }
                    return allowWebSearch
                        ? Inf6PromptCatalog.termExplainJaWeb
                        : Inf6PromptCatalog.termExplainJaLocal
                }()
                let rendered = try Inf6PromptGovernance.renderSystemUserPrompt(
                    ref: promptRef,
                    variables: [
                        "selection_term": selectionForPrompt,
                        "additional_instruction": (targetLang == "en") ? extraPerspectiveEn : extraPerspectiveJa,
                        "current_page_context": localPageContext,
                        "rag_context": ragContext
                    ]
                )

                let ai: String
                if allowWebSearch {
                    ai = try await Inf6LibraryView.askOpenAIText(
                        systemInstruction: rendered.systemInstruction,
                        userPrompt: rendered.userPrompt,
                        lang: targetLang,
                        allowWebSearch: true
                    )
                } else {
                    ai = try await Inf6LibraryView.askOpenAIText(
                        systemInstruction: rendered.systemInstruction,
                        userPrompt: rendered.userPrompt,
                        lang: targetLang
                    )
                }
                try Task.checkCancellation()

                let trimmed = ai.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                if allowWebSearch {
                    try _validateWebGroundedExplainText(trimmed)
                }
                let capped = (trimmed.count > 8000) ? String(trimmed.prefix(8000)) : trimmed

                await MainActor.run {
                    _replaceLastNote(page: idx, with: "用語解説（\(scopeLabelJa)）: \"\(head)\"\n\(capped)")
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    _ioLastError = "[InlinePDFPagesView] _requestExplainSelectedTerm failed: \(error.localizedDescription)"
                    _replaceLastNote(page: idx, with: "用語解説（\(scopeLabelJa)）: \"\(head)\"\n⚠︎ \(_userFacingExplainErrorMessage(error))")
                }
            }
        }
    }

    
    


    // MARK: - 8) AI actions: card insertion helpers

    @MainActor
    func _insertNote(page: Int, at insertAt: Int, text: String) -> Int {
        withAnimation {
            var arr = extraNotesByPage[page] ?? _loadExtraNotesResolved(page: page)
            let i = max(0, min(insertAt, arr.count))
            arr.insert(Inf6ExtraNote(text: text), at: i)
            extraNotesByPage[page] = arr
            showDetailPane = true
            _persistExtraNotes(page: page, arr)
            return i
        }
    }

    @MainActor
    func _replaceNote(page: Int, at index: Int, with finalText: String) {
        withAnimation {
            var arr = extraNotesByPage[page] ?? _loadExtraNotesResolved(page: page)
            guard arr.indices.contains(index) else { return }
            arr[index].text = finalText
            arr[index].rtf = nil
            extraNotesByPage[page] = arr
            _persistExtraNotes(page: page, arr)
        }
    }

    func _requestAskFromCard(pageIndex idx: Int, insertAt: Int, selectionText: String, extraPrompt: String?) {
        let targetLang = (genLangRaw == "en") ? "en" : "ja"
        let selectionTrimmed = selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectionTrimmed.isEmpty else { return }

        let head = selectionTrimmed.count <= _maxSelectionPreviewChars
            ? selectionTrimmed
            : String(selectionTrimmed.prefix(_maxSelectionPreviewChars)) + "…"

        let placeholder = (targetLang == "en")
            ? "Ask: \"\(head)\" …generating"
            : "Ask: \"\(head)\" …生成中"

        Task { @MainActor in
            let insertedIndex = _insertNote(page: idx, at: insertAt, text: placeholder)

            let selectionForPrompt = String(selectionTrimmed.prefix(_maxSelectionPromptChars))
            let pageText = _pageText(pageIndex: idx, maxChars: _maxPagePromptChars)
            if pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _replaceNote(page: idx, at: insertedIndex, with: "Ask: \"\(head)\"\n⚠︎ 本文テキストを取得できません（PDF未ロード/読み取り失敗）")
                return
            }
            let local = Inf6LibraryView.snippetAround(pageText, needle: selectionForPrompt, radius: 280)

            let extra = (extraPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let ragChunks = _collectRAGChunksSnapshot(
                maxCharsPerPage: _maxPagePromptChars,
                chunkChars: 900,
                overlapChars: 180
            )
            let ragQuery = selectionForPrompt + "\n\n" + extra
            let ragContext = try await Self._buildRAGEvidenceText(
                query: ragQuery,
                focusPageIndex: idx,
                chunks: ragChunks,
                topK: 4,
                lexicalTopK: 24
            )
            let promptRef = (targetLang == "en")
                ? Inf6PromptCatalog.askCardExplainEn
                : Inf6PromptCatalog.askCardExplainJa
            let rendered = try Inf6PromptGovernance.renderSystemUserPrompt(
                ref: promptRef,
                variables: [
                    "selection_text": selectionForPrompt,
                    "local_snippet": local.isEmpty ? ((targetLang == "en") ? "(no local snippet)" : "(抜粋なし)") : local,
                    "rag_context": ragContext,
                    "additional_instruction": extra.isEmpty ? ((targetLang == "en") ? "(none)" : "（なし）") : extra
                ]
            )

            do {
                let ai = try await Inf6LibraryView.askOpenAIText(
                    systemInstruction: rendered.systemInstruction,
                    userPrompt: rendered.userPrompt,
                    lang: targetLang
                )
                let trimmed = ai.trimmingCharacters(in: .whitespacesAndNewlines)
                let capped = (trimmed.count > 8000) ? String(trimmed.prefix(8000)) : trimmed
                await MainActor.run {
                    _replaceNote(page: idx, at: insertedIndex, with: "Ask: \"\(head)\"\n\(capped)")
                }
            } catch {
                await MainActor.run {
                    _replaceNote(page: idx, at: insertedIndex, with: "Ask: \"\(head)\"\n⚠︎ \(error.localizedDescription)")
                }
            }
        }
    }

// MARK: - 10) Layout (toolbar + body)

#if os(iOS)
// --- Removed duplicate UI helpers ---
#endif


    // MARK: - Explain prompt panel (overlay)


    // MARK: - iOS helpers

    #if os(iOS)
    @MainActor
    func _dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    #endif

    // (Toolbar block moved; do not define a second `body` here.)
}
