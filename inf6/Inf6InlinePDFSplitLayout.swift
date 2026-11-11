import Foundation
import SwiftUI
import UIKit
import PDFKit

#if !os(iOS)
#error("Inf6InlinePDFSplitLayout.swift is iOS-only. Remove this file from non-iOS targets.")
#endif

extension InlinePDFPagesView {
    @ViewBuilder
    func _pdfSplitLayout(_ geo: GeometryProxy) -> some View {
        let totalH = max(1, geo.size.height)

        let handleH: CGFloat = {
            guard showDetailPane else { return 0 }

            if UIDevice.current.userInterfaceIdiom == .phone {
                return 40
            }

            if ProcessInfo.processInfo.isiOSAppOnMac || UIDevice.current.userInterfaceIdiom == .mac {
                return 56
            }

            return 44
        }()

        let minTop: CGFloat = 220
        let minBottom: CGFloat = 160

        let available = max(1, totalH - handleH)

        let minR = max(0.12, min(0.88, minTop / available))
        let maxR = max(minR, min(0.88, (available - minBottom) / available))

        let requested = CGFloat(detailPaneSplitRatio)
        let r = max(minR, min(maxR, requested))

        let (topH, bottomH): (CGFloat, CGFloat) = {
            if !showDetailPane {
                return (totalH, 0)
            }

            let rawTop = available * r
            let clampedTop = min(max(minTop, rawTop), available - minBottom)
            let bottom = max(minBottom, totalH - clampedTop - handleH)
            return (clampedTop, bottom)
        }()

        let showThumbs = showThumbnailSidebar

        let onSplitDragChanged: (DragGesture.Value) -> Void = { value in
            if _splitDragStartRatio == nil {
                _splitDragStartRatio = detailPaneSplitRatio
            }
            let start = CGFloat(_splitDragStartRatio ?? detailPaneSplitRatio)
            let raw = start + (value.translation.height / max(1, available))
            let clamped = max(minR, min(maxR, raw))
            detailPaneSplitRatio = Double(clamped)
        }

        let onSplitDragEnded: (DragGesture.Value) -> Void = { _ in
            _persistedDetailPaneSplitRatio = detailPaneSplitRatio
            _splitDragStartRatio = nil
        }

        let splitDragGesture = DragGesture(minimumDistance: 2)
            .onChanged(onSplitDragChanged)
            .onEnded(onSplitDragEnded)

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if showThumbs {
                    PDFThumbnailSidebarRepresentable(pdfView: pdfViewRef)
                        .frame(width: _thumbnailSidebarWidth)
                        .background(_platformSystemBackground)
                }

                let onAddExplanationFromContextMenu: (Int, String?) -> Void = { pageIdx, selection in
                    Task { @MainActor in
                        selectedPage.wrappedValue = pageIdx
                        withAnimation { showDetailPane = true }

                        let trimmed = (selection ?? "").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            _requestExplain(pageIndex: pageIdx, selectionText: nil)
                        } else {
                            pdfSelectedText = trimmed
                            _requestExplain(pageIndex: pageIdx, selectionText: trimmed)
                        }
                    }
                }

                let onTapPDF: (Int, String, String) -> Void = { idx, snippet, tag in
                    let t = tag.lowercased()
                    if (t.contains("add") && (t.contains("explain") || t.contains("explanation"))) || t == "addexplanation" {
                        onAddExplanationFromContextMenu(idx, snippet)
                        return
                    }
                    _handlePassiveTap(idx: idx, snippet: snippet, tag: tag)
                }

                let onPDFViewReadyOnce: (PDFView) -> Void = { v in
                    DispatchQueue.main.async {
                        if let current = pdfViewRef, current === v {
                            return
                        }
                        pdfViewRef = v
                        Task { @MainActor in
                            _enableAndFlashPDFScrollIndicators(v)
                        }
                    }
                }

                ZStack(alignment: .topLeading) {
                    if let document = pdfDocument {
                        Inf6PDFPaneRepresentable(
                            url: url,
                            document: document,
                            onTap: onTapPDF,
                            selectedPage: selectedPage,
                            zoom: $zoom,
                            selectionText: $pdfSelectedText,
                            onPDFViewReady: onPDFViewReadyOnce,
                            suppressProgrammaticLayout: (_splitDragStartRatio != nil),
                            isSplitDragActive: (_splitDragStartRatio != nil)
                        )
                        .id(url)
                        // PDFページ外の余白はPDF画像ではないため、ページ背景と同じ白にする。
                        .background(Color.white)
                        .zIndex(0)
                    } else {
                        Color.clear
                            .background(_platformSystemBackground)
                            .zIndex(0)
                    }

                    if _isDesignedForiPadOnMac {
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            HStack(spacing: 0) {
                                Spacer(minLength: 0)
                                _zoomHUD
                            }
                        }
                        .padding(.trailing, 8)
                        .padding(.bottom, 8)
                        .zIndex(3)
                    }
                }
            }
            .frame(height: topH)

            if showDetailPane {
                ZStack {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.22))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    let grabGestureW: CGFloat = 96
                    let idiom = UIDevice.current.userInterfaceIdiom
                    let isPhoneUI: Bool = (idiom == .phone)
                    let isDesignedForiPadOnMac: Bool = ProcessInfo.processInfo.isiOSAppOnMac || (idiom == .mac)

                    let iconRowSpacing: CGFloat = {
                        if isDesignedForiPadOnMac { return 0 }
                        if isPhoneUI { return 0 }
                        return 10
                    }()

                    Group {
                        if isPhoneUI {
                            HStack(spacing: iconRowSpacing) {
                                _explainActionsLauncher()

                                Spacer().frame(width: 8).allowsHitTesting(false)
                                _formulaMenuButton
                                Spacer().frame(width: 8).allowsHitTesting(false)
                                _overviewMenuButton

                                Spacer(minLength: 0)
                                Spacer()
                                    .frame(width: grabGestureW)
                                    .allowsHitTesting(false)
                                Spacer(minLength: 0)

                                _assetsPipelineMenuButton
                                Spacer().frame(width: 8).allowsHitTesting(false)
                                _quizMenuButton
                                Spacer().frame(width: 8).allowsHitTesting(false)
                                _openInNewWindowButton

                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            HStack(spacing: iconRowSpacing) {
                                Spacer(minLength: 0)
                                _explainActionsLauncher()
                                _formulaMenuButton
                                _overviewMenuButton
                                _assetsPipelineMenuButton
                                _quizMenuButton
                                _openInNewWindowButton
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: handleH)

                    ZStack {
                        Rectangle()
                            .fill(Color.clear)
                            .frame(width: grabGestureW, height: handleH)
                            .contentShape(Rectangle())
                            .gesture(splitDragGesture)
                            .simultaneousGesture(
                                TapGesture().onEnded {
                                    _dismissKeyboard()
                                }
                            )

                        Capsule()
                            .fill(Color.secondary.opacity(0.6))
                            .frame(width: 56, height: 4)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: handleH)

                if _isDesignedForiPadOnMac {
                    _detailPane
                        .environment(\.colorScheme, .light)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .frame(height: bottomH)
                        .background(_platformSystemBackground)
                } else {
                    _detailPane
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .frame(height: bottomH)
                        .background(_platformSystemBackground)
                }
            }
        }
    }

    @ViewBuilder
    private var _formulaMenuButton: some View {
        Menu {
            Button(L("数式カードを作成", "Create math card")) {
                _buildMiniPDFFromCurrentSelection()
            }
            .disabled(_isRunningMiniBuild)
        } label: {
            Label(L("数式", "Formula"), systemImage: _isRunningMiniBuild ? "hourglass" : "function")
                .labelStyle(.iconOnly)
                .foregroundStyle(.purple)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(alignment: .topTrailing) {
                    if _isRunningMiniBuild {
                        ProgressView().tint(.pink).scaleEffect(1.25)
                            .controlSize(.mini)
                            .padding(.top, 2)
                            .padding(.trailing, 2)
                    }
                }
        }
        .disabled(_isRunningMiniBuild || !_storageAvailable)
        .accessibilityLabel(L("数式", "Formula"))
        .accessibilityHint(L("メニューを開いて実行します", "Open menu to run"))
        .help(L("選択した数式を切り出してカード化", "Create a math card from the selected equation"))
    }

    /// 取り込んだ論文PDFを別ウィンドウで開く。演習やツリーと並べて読めるようにする。
    @ViewBuilder
    private var _openInNewWindowButton: some View {
        Button {
            openWindow(id: "paper", value: _activeURL)
        } label: {
            Label(L("別ウィンドウ", "New window"), systemImage: "macwindow.on.rectangle")
                .labelStyle(.iconOnly)
                .foregroundStyle(.teal)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("論文を別ウィンドウで開く", "Open paper in a separate window"))
        .help(L("この論文を別ウィンドウで開く", "Open this paper in a separate window"))
    }

    @ViewBuilder
    private var _overviewMenuButton: some View {
        Menu {
            Button(L("概略解説を生成", "Generate overview")) {
                if _isRunningAbstractGen { return }
                _isRunningAbstractGen = true
                Task { @MainActor in
                    defer { _isRunningAbstractGen = false }
                    await generatePaperAbstractInternal()
                }
            }
            .disabled(_isRunningAbstractGen)
        } label: {
            Label(L("概略", "Overview"), systemImage: _isRunningAbstractGen ? "hourglass" : "wand.and.stars")
                .labelStyle(.iconOnly)
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(alignment: .topTrailing) {
                    if _isRunningAbstractGen {
                        ProgressView().tint(.pink).scaleEffect(1.25)
                            .controlSize(.mini)
                            .padding(.top, 2)
                            .padding(.trailing, 2)
                    }
                }
        }
        .accessibilityLabel(L("概略解説を生成", "Generate overview"))
        .accessibilityHint(L("メニューを開いて実行します", "Open menu to run"))
        .help(L("この論文の概略解説を生成して保存", "Generate and save the paper overview"))
        .disabled(_isRunningAbstractGen)
    }

    @ViewBuilder
    private var _assetsPipelineMenuButton: some View {
        Menu {
            if _isRunningAssetsPipeline {
                Button(role: .cancel) {
                    _assetsPipelineTask?.cancel()
                } label: {
                    Label(L("図表パイプラインをキャンセル", "Cancel figures/tables/equations pipeline"), systemImage: "xmark.circle")
                }
                Divider()
            }
            Button {
                guard !_isRunningAssetsPipeline else { return }
                _assetsPipelineFinishedMessage = nil
                _assetsPipelineDidFinish = false
                _isRunningAssetsPipeline = true

                _assetsPipelineTask = Task { @MainActor in
                    defer { _isRunningAssetsPipeline = false }

                    do {
                        _ = try OpenAIKeyStore.load()

                        await assetsPipelineAllPagesAction()
                        try Task.checkCancellation()
                        try await _generateAndPersistQuizFromCurrentSources()

                        _assetsPipelineFinishedMessage = L(
                            "図表パイプラインと演習生成が完了しました。",
                            "Figures/tables/equations pipeline and exercise generation finished."
                        )
                        _assetsPipelineDidFinish = true
                        _persistAssetsPipelineAttempt(succeeded: true)
                    } catch {
                        _assetsPipelineFinishedMessage = error is CancellationError
                            ? L("図表パイプラインをキャンセルしました。", "Figures/tables/equations pipeline cancelled.")
                            : error.localizedDescription
                        _assetsPipelineDidFinish = false
                        _persistAssetsPipelineAttempt(succeeded: false)
                    }
                    _assetsPipelineTask = nil
                }
            } label: {
                Text(L("図表パイプライン…", "Figures/Tables/Equations…"))
            }
            .disabled(_isRunningAssetsPipeline)
        } label: {
            Label(
                L("図表", "Assets"),
                systemImage: _isRunningAssetsPipeline ? "hourglass" : "wand.and.stars"
            )
            .labelStyle(.iconOnly)
            .foregroundStyle(.blue)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(alignment: .topTrailing) {
                if _isRunningAssetsPipeline {
                    ProgressView().tint(.pink).scaleEffect(1.25)
                        .controlSize(.mini)
                        .padding(.top, 2)
                        .padding(.trailing, 2)
                } else if _assetsPipelineDidFinish {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .padding(.top, 3)
                        .padding(.trailing, 3)
                }
            }
        }
        .accessibilityLabel(L("図表パイプライン", "Figures/Tables/Equations pipeline"))
        .accessibilityHint(L("メニューを開いて実行します", "Open menu to run"))
        .help(L("全ページを対象に図表の抽出・生成を実行", "Run figures/tables/equations pipeline for all pages"))
    }

    @ViewBuilder
    private var _quizMenuButton: some View {
        Menu {
            Button(L("演習を開く", "Open exercise")) {
                showQuizSheet = true
            }
        } label: {
            Label(L("演習", "Exercise"), systemImage: "questionmark.circle")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
        }
        .disabled(!_storageAvailable)
        .accessibilityLabel(L("演習", "Exercise"))
        .accessibilityHint(L("メニューを開いて実行します", "Open menu to run"))
        .help(L("保存済みの要旨・概略解説・解説から演習を生成", "Generate exercises from saved abstract, overview, and notes"))
    }
}
