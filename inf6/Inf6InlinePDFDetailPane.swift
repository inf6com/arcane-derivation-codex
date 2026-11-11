import Foundation
import SwiftUI
import UIKit

#if !os(iOS)
#error("Inf6InlinePDFDetailPane.swift is iOS-only. Remove this file from non-iOS targets.")
#endif

extension InlinePDFPagesView {
    var _detailPanePinchGesture: some Gesture {
        MagnificationGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if _detailPinchStartFontScale == nil {
                    _detailPinchStartFontScale = _inf6SafeDetailFontScaleForLayout(detailFontScalePDF)
                }
                let start = _detailPinchStartFontScale ?? _inf6SafeDetailFontScaleForLayout(detailFontScalePDF)
                let next = start * value
                detailFontScalePDF = _inf6ClampFinite(next, 0.65...2.55, fallback: start, label: "detailFontScalePDF(pinch)")
            }
            .onEnded { _ in
                _detailPinchStartFontScale = nil
            }
    }

    var _detailPane: some View {
        GeometryReader { proxy in
            _detailPaneContent(proxy: proxy)
        }
    }

    @ViewBuilder
    private func _detailPaneContent(proxy: GeometryProxy) -> some View {
        if #available(iOS 16.0, *) {
            let base = _detailPaneScroll(proxy: proxy)
                .scrollDismissesKeyboard(.never)
                .scrollDisabled(_isPinchingMiniMathImage)

            base.simultaneousGesture(
                _detailPanePinchGesture,
                including: _isPinchingMiniMathImage ? .none : .all
            )
        } else {
            let base = _detailPaneScroll(proxy: proxy)

            base.simultaneousGesture(
                _detailPanePinchGesture,
                including: _isPinchingMiniMathImage ? .none : .all
            )
        }
    }

    @ViewBuilder
    func _detailPaneScroll(proxy: GeometryProxy) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    Text(pdfTitle)
                        .font(.system(
                            size: UIFont.preferredFont(forTextStyle: .headline).pointSize * _inf6SafeDetailFontScaleForLayout(detailFontScalePDF),
                            weight: .semibold
                        ))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    if !_storageAvailable {
                        Text(L(
                            "⚠︎ 保存先rootを解決できないため、要旨・ページ解説・数式カードの保存ができません。",
                            "⚠︎ The storage root is unavailable, so abstract/notes/math cards cannot be saved."
                        ))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                    }
                    Spacer()
                }

                let pageIndex = selectedPage.wrappedValue

                let notesBinding: Binding<[Inf6ExtraNote]> = Binding<[Inf6ExtraNote]>(
                    get: {
                        if let existing = extraNotesByPage[pageIndex] {
                            return existing
                        }
                        let loaded = _loadExtraNotesResolved(page: pageIndex)

                        DispatchQueue.main.async {
                            if extraNotesByPage[pageIndex] == nil {
                                extraNotesByPage[pageIndex] = loaded
                            }
                        }
                        return loaded
                    },
                    set: { newValue in
                        extraNotesByPage[pageIndex] = newValue
                        _persistExtraNotes(page: pageIndex, newValue)
                    }
                )
                let detailFont: CGFloat = 16 * _inf6SafeDetailFontScaleForLayout(detailFontScalePDF)
                let noteSelectionMirror: (UUID) -> Binding<String> = { id in
                    _noteSelectionMirrorBinding(id)
                }
                let onAddExplanationFromSelection: (String) -> Void = { selectedText in
                    let trimmed = selectedText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    let idx = selectedPage.wrappedValue
                    _requestExplain(pageIndex: idx, selectionText: trimmed)
                }
                let onDeleteOverviewAction: () -> Void = {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    _abstractSaveTask?.cancel()
                    _abstractSaveTask = nil

                    _suppressAbstractAutosave = true
                    _deleteAbstractFile()

                    abstractNote.text = ""
                    abstractNote.rtf = nil

                    DispatchQueue.main.async {
                        _suppressAbstractAutosave = false
                    }
                }

                _InlineExplanationSelectableTextView(
                    sourceAbstractNote: $sourceAbstractNote,
                    overviewNote: $abstractNote,
                    notes: notesBinding,
                    placeholder: "",
                    fontSize: detailFont,
                    selectedText: $detailSelectedText,
                    noteSelectionMirror: noteSelectionMirror,
                    isInteractingAnyEditor: $_isInteractingDetailPaneText,
                    onGenerateAbstract: {
                        await generatePaperAbstractInternal()
                    },
                    onAddExplanation: onAddExplanationFromSelection,
                    onDeleteOverview: onDeleteOverviewAction,
                    onRerunAssetsPipeline: {
                        Task { @MainActor in
                            await assetsPipelineAllPagesAction()
                        }
                    },
                    onDeletePaperEntity: { entity in
                        _deletePaperEntity(entity)
                    },
                    entityIndexRefreshID: _entityIndexRefreshID,
                    pdfKey: Self._entityPdfKey(for: _activeURL),
                    pdfTitleKey: {
                        let k = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: pdfTitle)
                        return k.isEmpty ? nil : k
                    }(),
                    currentPageIndex: pageIndex
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .id("notes-\(pageIndex)")

                let cards = _sortedMiniCards(page: pageIndex)
                if !cards.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(cards) { card in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .center, spacing: 10) {
                                    Label(L("数式カード", "Math card"), systemImage: "function")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }

                                if !card.pdfData.isEmpty {
                                    _Inf6MiniPDFCardImageView(
                                        pdfData: card.pdfData,
                                        baseHeight: 220 * _inf6SafeDetailFontScaleForLayout(detailFontScalePDF),
                                        isPinchingMiniMathImage: $_isPinchingMiniMathImage
                                    )
                                } else {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(.ultraThinMaterial)
                                        .frame(height: 220 * _inf6SafeDetailFontScaleForLayout(detailFontScalePDF))
                                        .overlay(alignment: .center) {
                                            VStack(spacing: 6) {
                                                ProgressView().tint(.pink).scaleEffect(1.25)
                                                Text(L("ミニPDFを取得中…", "Downloading mini PDF…"))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L("数式の解説", "Math explanation"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    let noteBinding = _miniExtraNoteBinding(page: pageIndex, cardID: card.id)
                                    Inf6EditableNoteCard(
                                        note: noteBinding,
                                        fontSize: 16 * _inf6SafeDetailFontScaleForLayout(detailFontScalePDF),
                                        selectionMirror: $_miniCardSelectedText,
                                        isInteracting: .constant(false),
                                        onDelete: {
                                            var n = noteBinding.wrappedValue
                                            n.text = ""
                                            n.rtf = nil
                                            noteBinding.wrappedValue = n
                                        }
                                    )
                                }
                            }
                            .padding(12)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
                                    .allowsHitTesting(false)
                            }
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    _pendingDeleteMiniCardID = card.id
                                } label: {
                                    Label(Inf6Lang.text("削除", "Delete"), systemImage: "trash")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                    .alert(
                        L("数式カードを削除しますか？", "Delete math card?"),
                        isPresented: Binding(
                            get: { _pendingDeleteMiniCardID != nil },
                            set: { presenting in
                                if !presenting { _pendingDeleteMiniCardID = nil }
                            }
                        )
                    ) {
                        Button(L("削除", "Delete"), role: .destructive) {
                            if let id = _pendingDeleteMiniCardID {
                                Task { @MainActor in
                                    _deleteMiniCard(page: pageIndex, cardID: id)
                                    _pendingDeleteMiniCardID = nil
                                }
                            }
                        }
                        Button(L("キャンセル", "Cancel"), role: .cancel) {
                            _pendingDeleteMiniCardID = nil
                        }
                    } message: {
                        Text(L("この数式カード（ミニPDFと解説）をまとめて削除します。", "This removes the whole math card (mini PDF and explanation)."))
                    }
                } else {
                    Color.clear
                        .frame(height: 0)
                }
            }
            .alert(
                L("数式の切り出しに失敗", "Failed to create mini PDF"),
                isPresented: Binding(
                    get: { _miniBuildLastError != nil },
                    set: { presenting in
                        if !presenting { _miniBuildLastError = nil }
                    }
                )
            ) {
                Button(L("OK", "OK"), role: .cancel) {
                    _miniBuildLastError = nil
                }
            } message: {
                Text(_miniBuildLastError ?? "")
            }
            .frame(width: proxy.size.width, alignment: .topLeading)
            .padding(.bottom, 12)
        }
        .overlay(alignment: .bottomTrailing) {
            if _isDesignedForiPadOnMac {
                _detailFontHUD
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
            }
        }
    }

    static func _entityPdfKey(for url: URL) -> String? {
        let key = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: url)
        return key.isEmpty ? nil : key
    }
}
