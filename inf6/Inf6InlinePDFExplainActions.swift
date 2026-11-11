import Foundation
import SwiftUI
import UIKit

#if !os(iOS)
#error("Inf6InlinePDFExplainActions.swift is iOS-only. Remove this file from non-iOS targets.")
#endif

extension InlinePDFPagesView {
    func _explainPromptTitle() -> String {
        explainPromptUseWebSearch
            ? L("コメントを入力して検索", "Enter comment and search")
            : L("コメントを入力", "Enter comment")
    }

    func _explainPromptInputTitle() -> String {
        L("何を知りたいですか", "What do you want to know?")
    }

    func _explainPromptConfirmTitle() -> String {
        explainPromptUseWebSearch
            ? L("検索する", "Search")
            : L("考察する", "Analyze")
    }

    func _explainScopeChoiceTitle(_ scope: _ExplainActionScope) -> String {
        scope == .local
            ? L("使わない", "Do not use web")
            : L("使う", "Use web")
    }

    func _userFacingExplainErrorMessage(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "inf6.structuredExplain" || nsError.domain == "inf6.openai.structuredExplain" {
            return L(
                "Web検索の結果を整形できませんでした。もう一度実行してください。",
                "The web-backed explanation could not be formatted. Please try again."
            )
        }
        if nsError.domain == "inf6.webGroundedExplain" {
            return nsError.localizedDescription
        }
        return error.localizedDescription
    }

    func _validateWebGroundedExplainText(_ text: String) throws {
        guard text.range(
            of: #"https?://"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil else {
            throw NSError(
                domain: "inf6.webGroundedExplain",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: L(
                        "Web検索の結果に出典URLを付けられませんでした。もう一度実行してください。",
                        "The web-backed explanation did not include a source URL. Please try again."
                    )
                ]
            )
        }
    }

    // Per-note selection mirror to avoid cross-UITextView selection feedback loops.
    func _noteSelectionMirrorBinding(_ noteID: UUID) -> Binding<String> {
        Binding<String>(
            get: {
                _selectionMirrorByNoteID[noteID] ?? ""
            },
            set: { newValue in
                // まずは「カード個別」のミラーだけを更新する。
                // detailSelectedText への即時反映は、SwiftUI の更新サイクルと衝突して
                // AttributeGraph cycle / "Modifying state during view update" を誘発し得るため行わない。
                DispatchQueue.main.async {
                    _selectionMirrorByNoteID[noteID] = newValue
                }

                // 全体の current selection への集約は「選択が落ち着いた後」に限定して行う。
                // - 選択ドラッグ中（_isInteractingDetailPaneText）は反映しない
                // - 反映時点で値が変わっていない場合のみ反映する（不整合・スパム更新を防止）
                // - ドラッグ中だった場合は、短い再試行で「確定」を拾う（無限ループはしない）
                let candidate = newValue

                func _tryCommitSelection(remainingRetries: Int) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        // まだ同じノートのミラー値が candidate のままなら「確定候補」とみなす
                        if (_selectionMirrorByNoteID[noteID] ?? "") != candidate { return }

                        // 選択操作中は commit しない。終了を待って少数回だけ再試行する。
                        if _isInteractingDetailPaneText {
                            if remainingRetries > 0 {
                                _tryCommitSelection(remainingRetries: remainingRetries - 1)
                            }
                            return
                        }

                        if detailSelectedText != candidate {
                            detailSelectedText = candidate
                        }
                    }
                }

                _tryCommitSelection(remainingRetries: 4)
            }
        )
    }
    // MARK: - Commented explain (non-modal floating panel)

    @ViewBuilder
    func _explainPromptPanelOverlay_UI() -> some View {
        if !isShowingExplainPromptPanel {
            EmptyView()
        } else {
            let screenW = max(1, UIScreen.main.bounds.width)
            let screenH = max(1, UIScreen.main.bounds.height)

            // Keep the panel compact (the previous one was too large).
            let panelW: CGFloat = max(260, min(340, screenW * 0.38))
            let editorH: CGFloat = max(110, min(180, screenH * 0.20))

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(_explainPromptTitle())
                            .font(.headline)
                        Text(L("ページ \(explainPromptTargetPage + 1)", "Page \(explainPromptTargetPage + 1)"))
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.10))
                            .clipShape(Capsule())
                    }

                    Spacer(minLength: 0)

                    Button {
                        isShowingExplainPromptPanel = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .imageScale(.large)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(L("閉じる", "Close"))
                    .disabled(_isRunningExplain)
                }

                if let sel = explainPromptSelection,
                   !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(sel)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                #if canImport(UIKit)
                Inf6PlainTextEditor(text: $explainPromptText)
                    .frame(height: editorH)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.quaternary)
                    )
                    .overlay(alignment: .topLeading) {
                        if explainPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(_explainPromptInputTitle())
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.top, 12)
                                .padding(.leading, 10)
                                .allowsHitTesting(false)
                        }
                    }
                    .transaction { tx in
                        // Avoid animation churn while typing.
                        tx.animation = nil
                    }
                #else
                TextEditor(text: $explainPromptText)
                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(14)))
                    .frame(height: editorH)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.quaternary)
                    )
                    .transaction { tx in
                        // Avoid animation churn while typing.
                        tx.animation = nil
                    }
                #endif

                if let msg = explainPromptError,
                   !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(msg)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                HStack {
                    Button(L("キャンセル", "Cancel")) {
                        isShowingExplainPromptPanel = false
                    }
                    .buttonStyle(.bordered)
                    .disabled(_isRunningExplain)

                    Spacer(minLength: 0)

                    Button {
                        let trimmed = explainPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        Task { @MainActor in
                            await explainWithPromptInternal()
                        }
                    } label: {
                        if _isRunningExplain {
                            ProgressView().tint(.pink).scaleEffect(1.25)
                        } else {
                            Text(_explainPromptConfirmTitle())
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(_isRunningExplain || explainPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(12)
            .frame(width: panelW)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(UIColor.systemBlue).opacity(0.12), lineWidth: 1)
            }
            .shadow(radius: 10)
            .environment(\.colorScheme, .light)
            .padding(12)
            .padding(.bottom, 84)
        }
    }

    @MainActor
    func explainWithPromptInternal() async {
        let trimmedPrompt = explainPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        explainPromptError = nil

        let pageIndex = explainPromptTargetPage
        let sel = (explainPromptSelection ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let pageText: String = {
            guard let doc = pdfDocument else { return "" }
            guard pageIndex >= 0, pageIndex < doc.pageCount else { return "" }
            return (doc.page(at: pageIndex)?.string ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        let localPageContext: String = {
            guard !pageText.isEmpty else { return "" }
            guard !sel.isEmpty else { return pageText }
            let snippet = Inf6LibraryView.snippetAround(pageText, needle: sel, radius: 240)
            return snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? pageText : snippet
        }()

        let evidence = sel.isEmpty
            ? pageText
            : "選択対象（この文字列だけを説明）:\n\(sel)"
        guard !evidence.isEmpty else {
            explainPromptError = L(
                "本文テキストを取得できないため、コメント付き解説を生成できません（PDFにテキストが含まれない可能性があります）。",
                "Cannot generate commented explanation because the page text could not be extracted (the PDF may not contain selectable text)."
            )
            return
        }

        _isRunningExplain = true
        defer { _isRunningExplain = false }
        do {
            let targetLang = (genLangRaw == "en") ? "en" : "ja"
            let ragChunks = _collectRAGChunksSnapshot(
                maxCharsPerPage: _maxPagePromptChars,
                chunkChars: 900,
                overlapChars: 180
            )
            let ragQuery = evidence + "\n\n" + trimmedPrompt
            let ragContext = try await Self._buildRAGEvidenceText(
                query: ragQuery,
                focusPageIndex: pageIndex,
                chunks: ragChunks,
                topK: 4,
                lexicalTopK: 24
            )
            let promptRef: Inf6PromptRef = {
                if targetLang == "en" {
                    return explainPromptUseWebSearch
                        ? Inf6PromptCatalog.commentedExplainEnWeb
                        : Inf6PromptCatalog.commentedExplainEnLocal
                }
                return explainPromptUseWebSearch
                    ? Inf6PromptCatalog.commentedExplainJaWeb
                    : Inf6PromptCatalog.commentedExplainJaLocal
            }()
            let rendered = try Inf6PromptGovernance.renderSystemUserPrompt(
                ref: promptRef,
                variables: [
                    "user_comment": trimmedPrompt,
                    "evidence_text": evidence,
                    "selected_focus": sel.isEmpty
                        ? (targetLang == "en" ? "No text was selected; answer the comment about the page." : "選択範囲なし。ページについてのコメントに答える。")
                        : (targetLang == "en"
                            ? "The exact answer target is only this selected text: \(sel). If the comment asks what it means, define this selected text first and do not replace it with the surrounding topic."
                            : "回答対象はこの選択文字列だけです：\(sel)。コメントが意味や定義を尋ねている場合は、まずこの選択文字列そのものを定義し、周辺の話題全体に置き換えないでください。"),
                    "current_page_context": localPageContext,
                    "rag_context": ragContext
                ]
            )

            let note: Inf6ExtraNote
            if explainPromptUseWebSearch {
                let structured = try await Inf6LibraryView.askOpenAICommentWebExplain(
                    systemInstruction: rendered.systemInstruction,
                    userPrompt: rendered.userPrompt,
                    lang: targetLang
                )
                note = Self._makeStructuredWebExplainNote(structured, lang: targetLang)
            } else {
                let result = try await Inf6LibraryView.askOpenAIText(
                    systemInstruction: rendered.systemInstruction,
                    userPrompt: rendered.userPrompt,
                    lang: targetLang,
                    allowWebSearch: false
                )
                note = Inf6ExtraNote(text: result)
            }

            var arr = extraNotesByPage[pageIndex] ?? _loadExtraNotesResolved(page: pageIndex)
            arr.append(note)
            extraNotesByPage[pageIndex] = arr
            _persistExtraNotes(page: pageIndex, arr)

            isShowingExplainPromptPanel = false
        } catch {
            _ioLastError = "[InlinePDFPagesView] explainWithPromptInternal failed: \(error.localizedDescription)"
            explainPromptError = _userFacingExplainErrorMessage(error)
        }
    }

    func _presentExplainPromptPanel(
        useWebSearch: Bool,
        selectionText: String,
        initialComment: String = ""
    ) {
        explainPromptError = nil
        explainPromptText = initialComment
        explainPromptTargetPage = selectedPage.wrappedValue
        explainPromptUseWebSearch = useWebSearch

        let trimmedSelection = selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
        explainPromptSelection = trimmedSelection.isEmpty ? nil : trimmedSelection

        isShowingExplainActionsPanel = false
        isShowingExplainPromptPanel = true
    }

    func _rememberLatestSelectionText() {
        let trimmed = _selectionTextUnified.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if _lastNonEmptySelectionText != trimmed {
            _lastNonEmptySelectionText = trimmed
        }
    }

    func _clearRememberedSelectionText() {
        if !_lastNonEmptySelectionText.isEmpty {
            _lastNonEmptySelectionText = ""
        }
        if !_explainPanelSelectionText.isEmpty {
            _explainPanelSelectionText = ""
        }
    }

    func _prepareExplainActionsPanel() {
        explainPromptError = nil

        // Fix (Issue 1): read directly from PDFView to bypass any async-update lag
        // in the pdfSelectedText Binding before falling back to unified state.
        let directSel = (pdfViewRef?.currentSelection?.string ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Sync the binding so the rest of the UI is also up to date.
        if !directSel.isEmpty, directSel != pdfSelectedText {
            pdfSelectedText = directSel
        }

        let liveSelection = directSel.isEmpty
            ? _selectionTextUnified.trimmingCharacters(in: .whitespacesAndNewlines)
            : directSel
        if !liveSelection.isEmpty, _lastNonEmptySelectionText != liveSelection {
            _lastNonEmptySelectionText = liveSelection
        }
        let sel = liveSelection.isEmpty
            ? _lastNonEmptySelectionText.trimmingCharacters(in: .whitespacesAndNewlines)
            : liveSelection
        _explainPanelSelectionText = sel
        isShowingExplainActionsPanel = true
    }

    func _runExplainCombination(
        draft: _ExplainActionsDraft,
        selectionText: String,
        userComment: String = ""
    ) {
        let idx = selectedPage.wrappedValue
        let sel = selectionText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (draft.target, draft.kind, draft.scope) {
        case (.selection, .summarize, .local):
            isShowingExplainActionsPanel = false
            _requestExplain(pageIndex: idx, selectionText: sel)

        case (.selection, .comment, .local):
            _presentExplainPromptPanel(useWebSearch: false, selectionText: sel, initialComment: userComment)

        case (.selection, .comment, .web):
            _presentExplainPromptPanel(useWebSearch: true, selectionText: sel, initialComment: userComment)

        case (.page, .summarize, .local):
            isShowingExplainActionsPanel = false
            _requestExplain(pageIndex: idx, selectionText: nil)

        case (.term, .explain, .local):
            isShowingExplainActionsPanel = false
            _requestExplainSelectedTerm(pageIndex: idx, selectionText: sel, userPrompt: nil, allowWebSearch: false)

        case (.term, .explain, .web):
            isShowingExplainActionsPanel = false
            _requestExplainSelectedTerm(pageIndex: idx, selectionText: sel, userPrompt: nil, allowWebSearch: true)

        default:
            return
        }
    }

    struct _ExplainActionsPanelView: View {
        let pageIndex: Int
        let selectionText: String
        let genLangRaw: String
        let isRunningExplain: Bool
        let onRun: (_ExplainActionsDraft, String, String) -> Void
        let onClose: () -> Void

        @State private var draft: _ExplainActionsDraft
        @State private var commentText = ""

        init(
            pageIndex: Int,
            selectionText: String,
            genLangRaw: String,
            isRunningExplain: Bool,
            onRun: @escaping (_ExplainActionsDraft, String, String) -> Void,
            onClose: @escaping () -> Void
        ) {
            let trimmedSelection = selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasSelection = !trimmedSelection.isEmpty
            self.pageIndex = pageIndex
            self.selectionText = trimmedSelection
            self.genLangRaw = genLangRaw
            self.isRunningExplain = isRunningExplain
            self.onRun = onRun
            self.onClose = onClose
            _draft = State(initialValue: Self._defaultDraft(hasSelection: hasSelection))
        }

        var body: some View {
            let hasSelection = !selectionText.isEmpty

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 12) {
                    HStack(spacing: 10) {
                        Text(L("解説", "Explain"))
                            .font(.title3.weight(.semibold))
                        Text(L("ページ \(pageIndex + 1)", "Page \(pageIndex + 1)"))
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.10))
                            .clipShape(Capsule())
                    }

                    Spacer(minLength: 0)

                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(11), weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(Color.secondary.opacity(0.10))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("閉じる", "Close"))
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text(L("どこを対象にしますか", "What should be targeted?"))
                        .font(.subheadline.weight(.semibold))

                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            _ExplainChoiceChipView(
                                title: L("選択範囲", "Selected text"),
                                systemImage: "text.cursor",
                                tint: .blue,
                                selected: draft.target == .selection,
                                enabled: hasSelection
                            ) {
                                _selectTarget(.selection, hasSelection: hasSelection)
                            }

                            _ExplainChoiceChipView(
                                title: L("このページ", "This page"),
                                systemImage: "doc.plaintext",
                                tint: .teal,
                                selected: draft.target == .page,
                                enabled: true
                            ) {
                                _selectTarget(.page, hasSelection: hasSelection)
                            }
                        }

                        HStack(spacing: 10) {
                            _ExplainChoiceChipView(
                                title: L("選択語句", "Selected term"),
                                systemImage: "textformat.abc",
                                tint: .mint,
                                selected: draft.target == .term,
                                enabled: hasSelection
                            ) {
                                _selectTarget(.term, hasSelection: hasSelection)
                            }

                            Color.clear
                                .frame(maxWidth: .infinity, minHeight: 68)
                                .allowsHitTesting(false)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text(L("何をしますか", "What should be done?"))
                        .font(.subheadline.weight(.semibold))

                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            _ExplainChoiceChipView(
                                title: L("短く要約", "Summarize"),
                                systemImage: "doc.text.magnifyingglass",
                                tint: .blue,
                                selected: draft.kind == .summarize,
                                enabled: _isActionEnabled(.summarize, for: draft.target)
                            ) {
                                _selectAction(.summarize)
                            }

                            _ExplainChoiceChipView(
                                title: L("コメント付き解説", "Comment-based explanation"),
                                systemImage: "text.bubble",
                                tint: .indigo,
                                selected: draft.kind == .comment,
                                enabled: _isActionEnabled(.comment, for: draft.target)
                            ) {
                                _selectAction(.comment)
                            }
                        }

                        HStack(spacing: 10) {
                            _ExplainChoiceChipView(
                                title: L("意味を説明", "Explain meaning"),
                                systemImage: "character.book.closed",
                                tint: .mint,
                                selected: draft.kind == .explain,
                                enabled: _isActionEnabled(.explain, for: draft.target)
                            ) {
                                _selectAction(.explain)
                            }

                            Color.clear
                                .frame(maxWidth: .infinity, minHeight: 68)
                                .allowsHitTesting(false)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text(L("Web検索を使いますか", "Use web search?"))
                        .font(.subheadline.weight(.semibold))

                    HStack(spacing: 10) {
                        _ExplainChoiceChipView(
                            title: L("使わない", "Do not use web"),
                            systemImage: "doc.text",
                            tint: .blue,
                            selected: draft.scope == .local,
                            enabled: _isScopeEnabled(.local, target: draft.target, action: draft.kind)
                        ) {
                            _selectScope(.local)
                        }

                        _ExplainChoiceChipView(
                            title: L("使う", "Use web"),
                            systemImage: "globe",
                            tint: .orange,
                            selected: draft.scope == .web,
                            enabled: _isScopeEnabled(.web, target: draft.target, action: draft.kind)
                        ) {
                            _selectScope(.web)
                        }
                    }
                }

                if draft.kind == .comment {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("コメント", "Comment"))
                            .font(.subheadline.weight(.semibold))
                        TextField(
                            L("知りたい点を入力", "Enter what you want to know"),
                            text: $commentText,
                            axis: .vertical
                        )
                        .lineLimit(3...6)
                        .textFieldStyle(.roundedBorder)
                    }
                }

                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    onRun(draft, selectionText, commentText.trimmingCharacters(in: .whitespacesAndNewlines))
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: _combinationSystemImage())
                            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(14), weight: .semibold))
                        Text(_combinationTitle())
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(_combinationTint())
                .disabled(!_canRun(hasSelection: hasSelection))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial)
            }
            .frame(width: 344)
            .frame(maxHeight: 640)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.blue.opacity(0.10), lineWidth: 1)
            }
            .environment(\.colorScheme, .light)
        }

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

        func _isActionEnabled(
            _ action: _ExplainActionKind,
            for target: _ExplainActionTarget
        ) -> Bool {
            switch target {
            case .selection:
                return action == .summarize || action == .comment
            case .page:
                return action == .summarize
            case .term:
                return action == .explain
            }
        }

        func _isScopeEnabled(
            _ scope: _ExplainActionScope,
            target: _ExplainActionTarget,
            action: _ExplainActionKind
        ) -> Bool {
            switch (target, action) {
            case (.page, .summarize):
                return scope == .local
            case (.selection, .summarize):
                return scope == .local
            case (.selection, .comment):
                return true
            case (.term, .explain):
                return true
            default:
                return false
            }
        }

        static func _defaultDraft(hasSelection: Bool) -> _ExplainActionsDraft {
            if hasSelection {
                return _ExplainActionsDraft(
                    target: .selection,
                    kind: .comment,
                    scope: .local
                )
            }

            return _ExplainActionsDraft(
                target: .page,
                kind: .summarize,
                scope: .local
            )
        }

        func _defaultAction(for target: _ExplainActionTarget) -> _ExplainActionKind {
            switch target {
            case .selection:
                return .comment
            case .page:
                return .summarize
            case .term:
                return .explain
            }
        }

        func _defaultScope(
            target: _ExplainActionTarget,
            action: _ExplainActionKind
        ) -> _ExplainActionScope {
            switch (target, action) {
            case (.selection, .comment), (.term, .explain):
                return .local
            default:
                return .local
            }
        }

        func _selectTarget(
            _ target: _ExplainActionTarget,
            hasSelection: Bool
        ) {
            guard target == .page || hasSelection else { return }

            var next = draft
            next.target = target

            if !_isActionEnabled(next.kind, for: target) {
                next.kind = _defaultAction(for: target)
            }

            if !_isScopeEnabled(next.scope, target: target, action: next.kind) {
                next.scope = _defaultScope(target: target, action: next.kind)
            }

            draft = next
        }

        func _selectAction(_ action: _ExplainActionKind) {
            guard _isActionEnabled(action, for: draft.target) else { return }

            var next = draft
            next.kind = action

            if !_isScopeEnabled(next.scope, target: next.target, action: action) {
                next.scope = _defaultScope(target: next.target, action: action)
            }

            draft = next
        }

        func _selectScope(_ scope: _ExplainActionScope) {
            guard _isScopeEnabled(scope, target: draft.target, action: draft.kind) else { return }

            var next = draft
            next.scope = scope
            draft = next
        }

        func _canRun(hasSelection: Bool) -> Bool {
            guard !isRunningExplain else { return false }

            switch draft.target {
            case .selection, .term:
                if draft.kind == .comment {
                    return hasSelection && !commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                return hasSelection
            case .page:
                return true
            }
        }

        func _combinationTitle() -> String {
            switch draft.target {
            case .selection:
                switch draft.kind {
                case .summarize:
                    return L("選択範囲を要約する", "Summarize selected text")
                case .comment:
                    return draft.scope == .web
                        ? L("コメントを入力して検索する", "Enter comment and search")
                        : L("コメントを入力する", "Enter comment")
                case .explain:
                    return L("選択範囲", "Selection")
                }

            case .page:
                return L("このページを要約する", "Summarize this page")

            case .term:
                return draft.scope == .web
                    ? L("選択語句をWebでも調べる", "Search selected term on web")
                    : L("選択語句を説明する", "Explain selected term")
            }
        }

        func _combinationSystemImage() -> String {
            switch draft.target {
            case .selection:
                switch draft.kind {
                case .summarize:
                    return "doc.text.magnifyingglass"
                case .comment:
                    return draft.scope == .web ? "globe.badge.chevron.backward" : "text.bubble"
                case .explain:
                    return "text.cursor"
                }
            case .page:
                return "doc.plaintext"
            case .term:
                return draft.scope == .web ? "globe" : "textformat.abc"
            }
        }

        func _combinationTint() -> Color {
            switch draft.target {
            case .selection:
                switch draft.kind {
                case .summarize:
                    return .blue
                case .comment:
                    return draft.scope == .web ? .orange : .indigo
                case .explain:
                    return .blue
                }
            case .page:
                return .teal
            case .term:
                return draft.scope == .web ? .cyan : .mint
            }
        }
    }

    @ViewBuilder
    func _explainActionsPanel() -> some View {
        _ExplainActionsPanelView(
            pageIndex: selectedPage.wrappedValue,
            selectionText: _explainPanelSelectionText,
            genLangRaw: genLangRaw,
            isRunningExplain: _isRunningExplain,
            onRun: { draft, selectionText, commentText in
                _runExplainCombination(draft: draft, selectionText: selectionText, userComment: commentText)
            },
            onClose: {
                isShowingExplainActionsPanel = false
            }
        )
    }

    @ViewBuilder
    func _explainActionsLauncher() -> some View {
        Button {
            _prepareExplainActionsPanel()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: _isRunningExplain ? "hourglass" : "sparkles")
                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(14), weight: .semibold))
                if !_isRunningExplain {
                    Image(systemName: "chevron.down")
                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(9), weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.86))
                }
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.blue.opacity(0.96),
                                Color.cyan.opacity(0.84)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.24), lineWidth: 1)
            }
            .overlay(alignment: .topTrailing) {
                if _isRunningExplain {
                    ProgressView().tint(.pink).scaleEffect(1.25)
                        .controlSize(.mini)
                        .tint(.white)
                        .padding(.top, 2)
                        .padding(.trailing, 2)
                }
            }
            .shadow(color: Color.blue.opacity(0.18), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .popover(
            isPresented: $isShowingExplainActionsPanel,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            _explainActionsPanel()
        }
        .accessibilityLabel(L("解説を追加", "Add explanation"))
        .accessibilityHint(L("解説アクションを開きます", "Open explanation actions"))
        .help(L("対象と操作を選んで解説を実行", "Choose the target and action before running"))
        .disabled(_isRunningExplain)
    }
}
