//
//  inf6LibraryView2.swift
//  inf6
//
//  Created by decopin on 2026/01/03.
//

import Foundation
import SwiftUI
import Combine
import OSLog
#if canImport(CoreText)
import CoreText
#endif

// MARK: - File layout



// Top-level platform imports
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

#if canImport(UIKit)
import UIKit
#endif

#if canImport(PencilKit)
import PencilKit
#endif

#if canImport(PencilKit)
private struct Inf6PencilRecognitionEvidence: Codable {
    struct ModelProvenance: Codable {
        let name: String
        let checkpointSHA256: String
        let epoch: Int
    }

    let format: String
    let createdAt: Date
    let drawingDataBase64: String
    let samples: [Inf6CanonicalSample]
    let symbolStrokeIndices: [[Int]]
    let segmenter: ModelProvenance
    let classifier: ModelProvenance
    let ensembleModelName: String?
    let ensembleCalibrationSHA256: String?
    let fold7Top5ClassIndices: [[Int]]
    let fold7Top5Logits: [[Float]]
    let segmentationThreshold: Float
    let recognizedExpression: String
    let selectedSymbolLabels: [String]
    let candidateLabels: [[String]]
    let typesetCandidates: [[HinotoriTypesetCandidate]]
    let modelCandidates: [[Inf6SpatialRelationAnalysis.Candidate]]
    let similarityExpansion: HinotoriVisualSubsetExpansion
    let positionClassification: Inf6PositionSensitiveClassification
    let spatialAnalysis: Inf6SpatialRelationAnalysis
    let structureKind: String?
    let structureOrder: [Int]?
}

private struct Inf6PencilSegmenterManifest: Decodable {
    struct Decode: Decodable {
        let algorithm: String
        let positivePairLogitThreshold: Float
    }
    let format: String
    let modelName: String
    let checkpointSHA256: String
    let selectedEpoch: Int
    let validationThreshold: Float
    let decode: Decode
}

private struct Inf6PencilClassifierManifest: Decodable {
    struct Checkpoint: Decodable { let sha256: String; let epoch: Int }
    let checkpoint: Checkpoint
}

private struct Inf6PencilInputEvidence: Codable {
    let format: String
    let createdAt: Date
    let drawingDataBase64: String
    let drawingStrokeCount: Int
    let finishedStrokePointCount: Int
    let surfaceWidth: CGFloat
    let surfaceHeight: CGFloat
    let gridCenterFraction: CGFloat
}
#endif

#if canImport(PencilKit)
private struct FormulaGrid9Overlay: View {
    let centerFraction: CGFloat
    @Binding var selectedCellIndex: Int?

    private var edges: [CGFloat] {
        let margin = (1 - centerFraction) / 2
        return [0, margin, 1 - margin, 1]
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(0..<9, id: \.self) { index in
                    let row = index / 3
                    let column = index % 3
                    let x0 = edges[column]
                    let x1 = edges[column + 1]
                    let y0 = edges[row]
                    let y1 = edges[row + 1]
                    Rectangle()
                        .fill(
                            selectedCellIndex == index + 1
                                ? Color.cyan.opacity(0.26)
                                : Color.clear
                        )
                        .overlay(
                            selectedCellIndex == index + 1
                                ? Rectangle().stroke(Color.cyan.opacity(0.82), lineWidth: 2)
                                : nil
                        )
                        .frame(width: proxy.size.width * (x1 - x0), height: proxy.size.height * (y1 - y0))
                        .position(x: proxy.size.width * (x0 + x1) / 2,
                                  y: proxy.size.height * (y0 + y1) / 2)
                }
                ForEach(1..<3, id: \.self) { index in
                    Rectangle()
                        .fill(Color.cyan.opacity(0.30))
                        .frame(width: 0.9, height: proxy.size.height)
                        .position(x: proxy.size.width * edges[index], y: proxy.size.height / 2)
                    Rectangle()
                        .fill(Color.cyan.opacity(0.30))
                        .frame(width: proxy.size.width, height: 0.9)
                        .position(x: proxy.size.width / 2, y: proxy.size.height * edges[index])
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture()
                    .onEnded { event in
                        let x = min(max(event.location.x / max(proxy.size.width, 1), 0), 0.999999)
                        let y = min(max(event.location.y / max(proxy.size.height, 1), 0), 0.999999)
                        let column = x < edges[1] ? 0 : (x < edges[2] ? 1 : 2)
                        let row = y < edges[1] ? 0 : (y < edges[2] ? 1 : 2)
                        selectedCellIndex = row * 3 + column + 1
                    }
            )
            // The grid is a visual guide only. It must never consume PencilKit
            // events from the formula input surface beneath it.
            .allowsHitTesting(false)
        }
    }
}
#endif

#if canImport(WebKit)
import WebKit
#endif

#if canImport(Translation)
import Translation
#endif

private struct Inf6CompactFontSizeSlider: View {
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>

    var body: some View {
        GeometryReader { proxy in
            let trackWidth = max(proxy.size.width - 12, 1)
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Inf6CodexDesign.cyan.opacity(0.28))
                    .frame(width: trackWidth, height: 3)
                Circle()
                    .fill(Inf6CodexDesign.cyan)
                    .frame(width: 12, height: 12)
                    .offset(x: min(max(fraction, 0), 1) * (trackWidth - 12))
            }
            .frame(width: trackWidth, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let position = min(max(gesture.location.x - 6, 0), trackWidth - 12)
                        value = range.lowerBound + (position / max(trackWidth - 12, 1)) * (range.upperBound - range.lowerBound)
                    }
            )
        }
        .frame(width: 108, height: 24)
        .accessibilityElement()
        .accessibilityLabel(Inf6Lang.text("文字サイズ", "Text size"))
        .accessibilityValue(Text("\(Int(value)) pt"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                value = min(range.upperBound, value + 1)
            case .decrement:
                value = max(range.lowerBound, value - 1)
            @unknown default:
                break
            }
        }
    }
}




#if canImport(PDFKit)
import PDFKit
#endif
// MARK: - Notes dict persistence (per-PDF)
// (Moved from above for sidecar logic)


// MARK: - 2) PDF last-folder memory (no copying, no hashing)

extension Inf6LibraryView {

    #if canImport(PDFKit)
    /// Render a small thumbnail image of the generated mini PDF so it can be shown inline in the list.
    private func _miniPDFThumbnailImage(_ url: URL, size: CGSize) -> PlatformImage? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
        #if canImport(UIKit)
        return page.thumbnail(of: size, for: .mediaBox)

        #else
        return nil
        #endif
    }

    @ViewBuilder
    private func _miniPDFThumbnailView(_ url: URL) -> some View {
        let target = CGSize(width: 420, height: 180)
        if let img = _miniPDFThumbnailImage(url, size: target) {
            #if canImport(UIKit)
            Image(uiImage: img)
                .resizable()
                .scaledToFit()

            #endif
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.thinMaterial)
                VStack(spacing: 6) {
                    Image(systemName: "function")
                        .imageScale(.large)
                        .foregroundStyle(.secondary)
                    Text(Inf6Lang.text("プレビューなし", "No preview"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                }
            }
        }
    #endif




    private struct _FormulaMiniRow: Identifiable, Hashable {
        let id: UUID
        let globalIndex: Int
        let page: Int
        let indexInPage: Int
        let url: URL

        init(globalIndex: Int, page: Int, indexInPage: Int, entryID: UUID, url: URL) {
            self.id = entryID
            self.globalIndex = globalIndex
            self.page = page
            self.indexInPage = indexInPage
            self.url = url
        }
    }

    private func _openFormulaMiniPDF(_ url: URL) {
        #if canImport(UIKit)
        guard FileManager.default.fileExists(atPath: url.path) else {
            showFormulaError = true
            formulaErrorMessage = Inf6Lang.text(
                "数式ミニPDFが見つかりません: \(url.lastPathComponent)",
                "Formula mini PDF not found: \(url.lastPathComponent)"
            )
            return
        }

        UIApplication.shared.open(url)
        #endif
    }

    /// Remember the folder of a picked PDF so the next picker can start there.
    /// Stored as a plain file-system path (no extra names, no hashes).
    static func rememberPDFFolder(for fileURL: URL) {
        // If the URL is a file, store its parent directory; if it's already a directory, store it as-is.
        let folderURL: URL
        if fileURL.hasDirectoryPath {
            folderURL = fileURL
        } else {
            folderURL = fileURL.deletingLastPathComponent()
        }

        let path = folderURL.path
        guard !path.isEmpty else { return }
        UserDefaults.standard.set(path, forKey: "inf6.lastPDFFolderPath")
    }

    /// Returns the last remembered folder URL for the document picker, if any.
    static func lastPDFFolderURL() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: "inf6.lastPDFFolderPath"), !path.isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return url
    }


}

// MARK: - 3) Formula mini PDF preview (v2: iPhone compatible + removable)

extension Inf6LibraryView {

    @ViewBuilder
    var formulaMiniPreviewOverlayV2: some View {
        #if canImport(PDFKit)
        // Stack in original PDF order: page asc, then position on page (top -> bottom).
        let rows: [_FormulaMiniRow] = {
            var out: [_FormulaMiniRow] = []
            var g = 0
            for p in formulaMiniPDFsByPage.keys.sorted() {
                let sorted = (formulaMiniPDFsByPage[p] ?? []).sorted(by: { $0.yFromTop < $1.yFromTop })
                for (idx, e) in sorted.enumerated() {
                    out.append(_FormulaMiniRow(globalIndex: g, page: p, indexInPage: idx, entryID: e.id, url: e.url))
                    g += 1
                }
            }
            return out
        }()

        if !rows.isEmpty {
            Group {
                if isFormulaMiniPaneVisible {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            Text(Inf6Lang.text("数式プレビュー", "Formula previews"))
                                .font(.callout)
                                .fontWeight(.semibold)

                            Text(Inf6Lang.text("全\(rows.count)", "total \(rows.count)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button {
                                showFormulaMiniHistorySheet = true
                            } label: {
                                Image(systemName: "clock.arrow.circlepath")
                                    .imageScale(.large)
                                    .symbolRenderingMode(.hierarchical)
                            }
                            .accessibilityLabel(Inf6Lang.text("履歴", "History"))

                            Button {
                                // Hide without deleting; keep history.
                                isFormulaMiniPaneVisible = false
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .imageScale(.large)
                                    .symbolRenderingMode(.hierarchical)
                            }
                            .accessibilityLabel(Inf6Lang.text("閉じる", "Hide"))
                        }

                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVStack(spacing: 10) {
                                ForEach(rows) { r in
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("#\(r.globalIndex + 1)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Text(L("p\(r.page + 1)", "p\(r.page + 1)"))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .frame(width: 56, alignment: .leading)

                                        Button {
                                            _openFormulaMiniPDF(r.url)
                                        } label: {
                                            _miniPDFThumbnailView(r.url)
                                                .frame(height: 120)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(.thinMaterial)
                                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        }
                                        .buttonStyle(.plain)

                                        Button {
                                            Task { @MainActor in
                                                deleteFormulaMiniPDF(page: r.page, entryID: r.id, url: r.url)
                                            }
                                        } label: {
                                            Label(Inf6Lang.text("削除7", "Delete"), systemImage: "trash")
                                                .foregroundStyle(.blue)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                            .padding(.horizontal, 2)
                        }
                        .frame(maxWidth: .infinity)
                        // Keep this compact but scrollable.
                        .frame(height: 260)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 10)
                    .background(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                } else {
                    // Collapsed bar
                    HStack(spacing: 10) {
                        Text(Inf6Lang.text("数式プレビュー", "Formula previews"))
                            .font(.callout)
                            .fontWeight(.semibold)

                        Text(Inf6Lang.text("全\(rows.count)", "total \(rows.count)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button {
                            showFormulaMiniHistorySheet = true
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                                .imageScale(.large)
                                .symbolRenderingMode(.hierarchical)
                        }
                        .accessibilityLabel(Inf6Lang.text("履歴", "History"))

                        Button {
                            isFormulaMiniPaneVisible = true
                        } label: {
                            Image(systemName: "chevron.up")
                                .imageScale(.large)
                                .symbolRenderingMode(.hierarchical)
                        }
                        .accessibilityLabel(Inf6Lang.text("表示", "Show"))
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 10)
                    .background(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
            }
            .sheet(isPresented: $showFormulaMiniHistorySheet) {
                formulaMiniHistorySheetView
            }
        } else {
            EmptyView()
        }
        #else
        EmptyView()
        #endif
    }


    // Sheet UI: formula mini PDF history (moved out of the bottom split pane)
    @ViewBuilder
     var formulaMiniHistorySheetView: some View {
        #if canImport(PDFKit)
        let rows: [_FormulaMiniRow] = {
            var out: [_FormulaMiniRow] = []
            var g = 0
            for p in formulaMiniPDFsByPage.keys.sorted() {
                let sorted = (formulaMiniPDFsByPage[p] ?? []).sorted(by: { $0.yFromTop < $1.yFromTop })
                for (idx, e) in sorted.enumerated() {
                    out.append(_FormulaMiniRow(globalIndex: g, page: p, indexInPage: idx, entryID: e.id, url: e.url))
                    g += 1
                }
            }
            return out
        }()

        NavigationStack {
            Group {
                if rows.isEmpty {
                    VStack(spacing: 10) {
                        Text(Inf6Lang.text("数式ミニPDFはまだありません。", "No formula mini PDFs yet."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(Inf6Lang.text("PDF上で範囲選択して『数式 → 生成』を押してください。", "Select a range in the PDF and choose Formula → Generate."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)
                } else {
                    List {
                        ForEach(rows) { r in
                            HStack(spacing: 12) {
                                Text("#\(r.globalIndex + 1)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 46, alignment: .leading)

                                Text(L("p\(r.page + 1)", "p\(r.page + 1)"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .leading)

                                Button {
                                    _openFormulaMiniPDF(r.url)
                                } label: {
                                    HStack(spacing: 10) {
                                        #if canImport(PDFKit)
                                        _miniPDFThumbnailView(r.url)
                                            .frame(width: 220, height: 88)
                                            .background(.thinMaterial)
                                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        #else
                                        Image(systemName: "doc.richtext")
                                            .imageScale(.large)
                                        #endif

                                        VStack(alignment: .leading, spacing: 2) {
                                Text(Inf6Lang.text("開く", "Open"))
                                                .font(.callout)
                                            Text(r.url.lastPathComponent)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                Button {
                                    Task { @MainActor in
                                        deleteFormulaMiniPDF(page: r.page, entryID: r.id, url: r.url)
                                    }
                                } label: {
                                    Label(Inf6Lang.text("削除8", "Delete"), systemImage: "trash")
                                        .foregroundStyle(.blue)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            .navigationTitle(Inf6Lang.text("数式（履歴）", "Formula (History)"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Inf6Lang.text("閉じる", "Close")) {
                        showFormulaMiniHistorySheet = false
                    }
                }
            }
        }
        #else
        Text(Inf6Lang.text("PDFKit が利用できないため表示できません。", "PDFKit is unavailable."))
        #endif
    }

    @MainActor
    private func deleteFormulaMiniPDF(page: Int, entryID: UUID, url: URL) {
        // Never clear `formulaSelectionText` automatically.
        // Deletion is per-page and only removes the selected item.

        // If the file exists, try to delete it first.
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                showFormulaError = true
                formulaErrorMessage = Inf6Lang.text(
                    "数式ミニPDFの削除に失敗しました: \(error.localizedDescription)",
                    "Failed to delete the formula mini PDF: \(error.localizedDescription)"
                )
                return
            }
        }

        var arr = formulaMiniPDFsByPage[page] ?? []
        arr.removeAll(where: { $0.id == entryID })

        if arr.isEmpty {
            formulaMiniPDFsByPage[page] = nil
        } else {
            // Keep consistent ordering after deletion.
            formulaMiniPDFsByPage[page] = arr.sorted(by: { $0.yFromTop < $1.yFromTop })
        }

        // Keep the pane visible so the user can continue reviewing.
        isFormulaMiniPaneVisible = true
    }


}




// MARK: - 8) Mini formula PDF generation

#if canImport(UIKit)
extension Inf6LibraryView {

    /// Generate a small PDF from the most recent PDF selection for quick formula inspection.
    /// UIKit-only (uses UIGraphicsPDFRenderer).
    @MainActor
     func generateFormulaMiniPDF() {
        // Use the stable selection text. If the user hasn't selected anything, do not generate.
        let raw = formulaSelectionText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !raw.isEmpty else {
            showFormulaError = true
            formulaErrorMessage = Inf6Lang.text(
                "数式ミニPDFを作るには、まずPDF上で範囲選択してください。",
                "To generate a formula mini PDF, first select a range on the PDF."
            )
            return
        }

        let fm = FileManager.default
        let root = Inf6DataRoot.url()

        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            showFormulaError = true
            formulaErrorMessage = Inf6Lang.text(
                "保存先フォルダを作成できませんでした: \(error.localizedDescription)",
                "Could not create the storage folder: \(error.localizedDescription)"
            )
            return
        }

        let dir = root.appendingPathComponent("inf6_formula_mini", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            showFormulaError = true
            formulaErrorMessage = Inf6Lang.text(
                "数式ミニPDFの保存先フォルダを作成できませんでした: \(error.localizedDescription)",
                "Could not create the folder for the formula mini PDF: \(error.localizedDescription)"
            )
            return
        }

        // The selection anchor position is required to keep per-page ordering reliable.
        // If we cannot resolve it, surface the failure explicitly (no fallback).
        guard let yFromTop = formulaSelectionAnchorYFromTop else {
            showFormulaError = true
            formulaErrorMessage = Inf6Lang.text(
                "選択範囲の位置情報が取得できませんでした。PDF上で選択し直してください。",
                "Could not resolve the selection position. Please reselect in the PDF."
            )
            return
        }

        let filename = "formula_mini_\(UUID().uuidString).pdf"
        let outURL = dir.appendingPathComponent(filename)

        // Compact page size: fit the content so previews don't waste vertical space.
        let pageWidth: CGFloat = 595
        let margin: CGFloat = 24
        let contentWidth = pageWidth - margin * 2

        let title = Inf6Lang.text("数式（選択範囲）", "Formula (selection)")
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: UIColor.label
        ]
        let titleSize = (title as NSString).size(withAttributes: titleAttrs)

        let bodyAttrs: [NSAttributedString.Key: Any] = {
            let p = NSMutableParagraphStyle()
            p.lineBreakMode = .byWordWrapping
            p.alignment = .left
            return [
                .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: UIColor.label,
                .paragraphStyle: p
            ]
        }()

        let bodyMaxSize = CGSize(width: contentWidth, height: .greatestFiniteMagnitude)
        let bodyBounds = (raw as NSString).boundingRect(
            with: bodyMaxSize,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: bodyAttrs,
            context: nil
        ).integral

        let minHeight: CGFloat = 220
        let maxHeight: CGFloat = 1200
        let neededHeight = margin + titleSize.height + 12 + bodyBounds.height + margin
        let pageHeight = max(minHeight, min(maxHeight, neededHeight))
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        do {
            try renderer.writePDF(to: outURL, withActions: { ctx in
                ctx.beginPage()

                (title as NSString).draw(at: CGPoint(x: margin, y: margin), withAttributes: titleAttrs)

                let bodyRect = CGRect(
                    x: margin,
                    y: margin + titleSize.height + 12,
                    width: contentWidth,
                    height: pageRect.height - (margin * 2 + titleSize.height + 12)
                )

                (raw as NSString).draw(
                    with: bodyRect,
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: bodyAttrs,
                    context: nil
                )
            })

            // Store the generated mini PDF under the page where the selection occurred.
            // Also store its on-page position so we can sort by the formula’s location within the page.
            let targetPage = formulaSelectionPageIndex ?? currentPageIndexForUI
            var arr = formulaMiniPDFsByPage[targetPage] ?? []
            arr.append(_FormulaMiniEntry(url: outURL, yFromTop: yFromTop))
            formulaMiniPDFsByPage[targetPage] = arr.sorted(by: { $0.yFromTop < $1.yFromTop })
            isFormulaMiniPaneVisible = true

        } catch {
            showFormulaError = true
            formulaErrorMessage = Inf6Lang.text(
                "数式ミニPDFの生成に失敗しました: \(error.localizedDescription)",
                "Failed to generate the formula mini PDF: \(error.localizedDescription)"
            )
        }
    }
}

#if canImport(PencilKit)
struct Inf6CodexChapterOption: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let paperID: String?
    let depth: Int

    init(id: String, title: String, paperID: String?, depth: Int = 0) {
        self.id = id
        self.title = title
        self.paperID = paperID
        self.depth = depth
    }
}

struct Inf6CodexRootContext: Codable, Hashable {
    let paperID: String
    let paperTitle: String
    let sourceFamily: String?
    let chapterID: String?
    let chapterTitle: String?
    let chapterOptions: [Inf6CodexChapterOption]
    let evidence: [Inf6CodexEvidenceReference]

    init(
        paperID: String,
        paperTitle: String,
        sourceFamily: String? = nil,
        chapterID: String?,
        chapterTitle: String?,
        chapterOptions: [Inf6CodexChapterOption] = [],
        evidence: [Inf6CodexEvidenceReference]
    ) {
        self.paperID = paperID
        self.paperTitle = paperTitle
        self.sourceFamily = sourceFamily
        self.chapterID = chapterID
        self.chapterTitle = chapterTitle
        self.chapterOptions = chapterOptions
        self.evidence = evidence
    }

    enum CodingKeys: String, CodingKey {
        case paperID, paperTitle, sourceFamily, chapterID, chapterTitle, chapterOptions, evidence
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        paperID = try values.decode(String.self, forKey: .paperID)
        paperTitle = try values.decode(String.self, forKey: .paperTitle)
        sourceFamily = try values.decodeIfPresent(String.self, forKey: .sourceFamily)
        chapterID = try values.decodeIfPresent(String.self, forKey: .chapterID)
        chapterTitle = try values.decodeIfPresent(String.self, forKey: .chapterTitle)
        chapterOptions = try values.decodeIfPresent([Inf6CodexChapterOption].self, forKey: .chapterOptions) ?? []
        evidence = try values.decode([Inf6CodexEvidenceReference].self, forKey: .evidence)
    }
}

struct Inf6CodexEvidenceReference: Codable, Hashable, Identifiable {
    let id: UUID
    let kind: String
    let pageIndex: Int?
    let imagePath: String
}

struct Inf6CodexOriginalArtifact: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case formula
        case table
    }

    let id: String
    let kind: Kind
    let heading: String
    let bodyHTML: String
    let sourceID: String
}

private enum Inf6CodexSettingsDestination: String, Identifiable {
    case learningDomains
    case font
    case api
    case sources
    case prompts
    case storage
    case dataExchange

    var id: String { rawValue }
}

private enum Inf6SyllabusNodeWorkspaceRoute {
    case overview
    case explanation
    case papers
}

private struct Inf6LearningDomainManagementView: View {
    let onSelect: (Inf6LearningDomain) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var domains: [Inf6LearningDomain] = []
    @State private var paperReferences: [Inf6PDFReferenceRecord] = []
    @State private var activeID = Inf6LearningDomain.eQualification.id
    @State private var isAddPresented = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(domains) { domain in
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                select(domain)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: activeID == domain.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(activeID == domain.id ? Inf6CodexDesign.cyan : .secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                    Text(domain.name).foregroundStyle(.primary)
                                    Text(domain.kind.title(isJapanese: Inf6Lang.isJapanese) + " · " + (domain.isPreset
                                        ? Inf6Lang.text("プリセット", "Preset")
                                        : Inf6Lang.text("利用者が追加", "Added by user")))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let sourceURL = domain.sourceURL {
                                        Link(sourceURL.absoluteString, destination: sourceURL)
                                            .font(.caption2)
                                            .lineLimit(1)
                                    }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            ForEach(paperReferences.filter { $0.learningDomainIDs?.contains(domain.id) == true }, id: \.resolvedPath) { paper in
                                Button {
                                    openWindow(id: "paper", value: URL(fileURLWithPath: paper.resolvedPath))
                                } label: {
                                    Label(paper.title ?? paper.fileName, systemImage: "doc.text")
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                                .buttonStyle(.plain)
                                .padding(.leading, 32)
                            }
                        }
                    }
                }
            }
            .navigationTitle(Inf6Lang.text("学習分野", "Learning domains"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Inf6Lang.text("閉じる", "Close")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAddPresented = true
                    } label: {
                        Label(Inf6Lang.text("追加", "Add"), systemImage: "plus")
                    }
                }
            }
            .task { reload() }
            .sheet(isPresented: $isAddPresented) {
                Inf6LearningDomainAddView { name, kind, source in
                    do {
                        let domain = try Inf6LearningDomainStore.add(name: name, kind: kind, source: source)
                        try Inf6LearningDomainStore.select(id: domain.id)
                        reload()
                        activeID = domain.id
                        onSelect(domain)
                        isAddPresented = false
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            .alert(
                Inf6Lang.text("分野を保存できません", "Could not save domain"),
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button(Inf6Lang.text("閉じる", "Close")) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func reload() {
        do {
            let state = try Inf6LearningDomainStore.load()
            domains = state.domains
            activeID = state.activeID
            paperReferences = try Inf6PDFReferenceStore.list()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func select(_ domain: Inf6LearningDomain) {
        do {
            try Inf6LearningDomainStore.select(id: domain.id)
            activeID = domain.id
            errorMessage = nil
            onSelect(domain)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct Inf6LearningDomainAddView: View {
    let onSave: (String, Inf6LearningDomainKind, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: Inf6LearningDomainKind = .technicalSubject
    @State private var sourceURL = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField(Inf6Lang.text("分野名", "Name"), text: $name)
                    .textInputAutocapitalization(.never)
                Picker(Inf6Lang.text("種類", "Type"), selection: $kind) {
                    ForEach(Inf6LearningDomainKind.allCases) { value in
                        Text(value.title(isJapanese: Inf6Lang.isJapanese)).tag(value)
                    }
                }
                TextField(Inf6Lang.text("出典URL（任意）", "Source URL (optional)"), text: $sourceURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                if !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(Inf6Lang.text("URLは記録しますが、出典の同一性や内容は検証しません。", "The URL is recorded; source identity and content are not verified."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(Inf6Lang.text("分野を追加", "Add domain"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Inf6Lang.text("キャンセル", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Inf6Lang.text("保存", "Save")) { onSave(name, kind, sourceURL) }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct Inf6CodexRootView: View {
    @State private var context: Inf6CodexRootContext
    @Environment(\.openWindow) private var openWindow
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var expression = ""
    @State private var steps: [String] = []
    @State private var selectedEvidenceID: UUID?
    @State private var chatQuestion = ""
    @State private var chatMessages: [String] = []
    @State private var isChatting = false
    @State private var saveError: String?
    @State private var verificationMessage: String?
    @State private var isVerified = false
    @State private var entities: [Inf6DocEntity] = []
    @State private var entitySourcePaperIDs: [UUID: String] = [:]
    @State private var entitySourcePaperTitles: [UUID: String] = [:]
    @State private var entityLoadError: String?
    @State private var syllabusOverview: Inf6SyllabusOutlineItem?
    @State private var selectedEntityID: UUID?
    @FocusState private var isEntityRailFocused: Bool
    @State private var selectedCodeFramework = "PyTorch"
    @State private var originalArtifacts: [Inf6CodexOriginalArtifact] = []
    @State private var selectedOriginalArtifactID: String?
    @State private var collectedNotes: [Inf6ExtraNote] = []
    @State private var railScrollAccumulator: CGFloat = 0
    @State private var activeSettingsDestination: Inf6CodexSettingsDestination?
    @State private var activeLearningDomainID = Inf6LearningDomain.eQualification.id
    @State private var activeLearningDomainName = Inf6LearningDomain.eQualification.name
    @State private var activeLearningDomainKind = Inf6LearningDomainKind.qualification
    @State private var hydratedEshikakuOutline: [Inf6SyllabusOutlineItem] = []
    @State private var isShowingSyllabusNodeHome = false
    @State private var expandedSyllabusNodeIDs: Set<String> = []
    @State private var syllabusNodeWorkspaceRoute = Inf6SyllabusNodeWorkspaceRoute.overview
    @State private var isRecropping = false
    @State private var recropTask: Task<Void, Never>?
    @State private var recropStatus: String?
    @State private var recropError: String?
    @State private var isSourcePDFPickerPresented = false
    @State private var sourcePDFImportStatus: String?
    @State private var sourcePDFImportError: String?
    @State private var userFormulaTarget: Inf6DocEntity?
    @State private var isGeneratingNodeExplanation = false
    @State private var nodeExplanationTask: Task<Void, Never>?
    @State private var nodeExplanationError: String?
    @State private var translationError: String?
    @AppStorage(Inf6ApplicationSystemFont.userDefaultsKey)
    private var applicationSystemFontFamily: String = Inf6ApplicationSystemFont.systemValue
    @AppStorage(Inf6ApplicationSystemFont.sizeUserDefaultsKey)
    private var applicationSystemFontSize: Double = Inf6ApplicationSystemFont.defaultSize
    @AppStorage("gen_lang")
    private var generationLanguageRaw: String = "ja"
    @AppStorage("inf6_ui_language")
    private var interfaceLanguageRaw: String = "auto"

    init(context: Inf6CodexRootContext) {
        _context = State(initialValue: context)
    }

    private var paperFolderKey: String {
        if let paper = sourcePaper {
            return Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paper.titleEn ?? paper.title)
        }
        return Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: context.paperTitle)
    }

    private var sourcePaper: Inf6CorePaper? {
        guard !context.paperID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return Inf6CorePaperStore.shared.papers.first { $0.id == context.paperID }
            ?? Inf6MetadataStore.getCodable(Inf6CorePaper.self, domain: .papers, key: context.paperID)
            ?? Inf6MetadataStore.listAllCodable(Inf6CorePaper.self, domain: .papers)
                .first { $0.value.id == context.paperID }?.value
    }

    private var recropEntry: Inf6EshikakuDrillPipeline.DrillEntry? {
        guard let paper = sourcePaper else { return nil }
        guard let folderKey = Inf6EshikakuDrillPipeline.storedPaperArtifactKey(for: paper)
            ?? _storedEntityIndexKey(for: paper) else {
            return nil
        }
        return Inf6EshikakuDrillPipeline.DrillEntry(
            id: folderKey,
            paper: paper,
            folderKey: folderKey,
            domainPrefix: context.sourceFamily ?? "",
            domainLabelJa: "",
            domainLabelEn: "",
            quiz: nil,
            pdfURL: paper.resolvedPDFURL,
            downloadURL: nil,
            kcExists: false,
            syllabusTitle: context.chapterTitle,
            syllabusNodeID: context.chapterID,
            syllabusContext: context.chapterTitle ?? ""
        )
    }

    private func _storedEntityIndexKey(for paper: Inf6CorePaper) -> String? {
        let aliases = [
            paper.id,
            paper.title,
            paper.titleEn ?? "",
            paper.resolvedPDFURL?.lastPathComponent ?? ""
        ]
        .map { Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: $0) }
        .filter { !$0.isEmpty }
        let records = Inf6MetadataStore.listAllCodable(Inf6DocEntityIndex.self, domain: .docEntities)
        return records.first { record in
            let stored = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: record.value.pdfKey)
            return aliases.contains { alias in
                stored == alias || stored.hasSuffix("_\(alias)") || alias.hasSuffix("_\(stored)")
            }
        }?.key
    }

    private var displayPaperTitle: String {
        let title = context.paperTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let year = sourcePaper?.year, year > 0 else { return title }
        return String(year) + " — " + title
    }

    private var displayChapterTitle: String? {
        let sourceTitle = context.chapterID.flatMap { id in
            _selectableChapters.first(where: { $0.id == id })?.title
        } ?? context.chapterTitle
        guard let raw = sourceTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              !raw.contains("\n"),
              !raw.contains("\r"),
              raw.count <= 120 else {
            return nil
        }
        return raw
    }

    private var explanationRawID: String? {
        guard let sourceFamily = _effectiveSyllabusSourceFamily,
              let chapterID = context.chapterID,
              !sourceFamily.isEmpty,
              !chapterID.isEmpty else { return nil }
        return "inf6-explanation:\(sourceFamily):\(chapterID)"
    }

    private var _effectiveSyllabusSourceFamily: String? {
        let sourceFamily = context.sourceFamily?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sourceFamily, !sourceFamily.isEmpty {
            switch sourceFamily.lowercased() {
            case "eshikaku", "jdla_eshikaku": return "jdla_eshikaku"
            default: return sourceFamily
            }
        }
        return activeLearningDomainID == Inf6LearningDomain.eQualification.id ? "jdla_eshikaku" : nil
    }

    private var hasStoredNodeExplanation: Bool {
        guard let explanationRawID else { return false }
        return Inf6MetadataStore.get(domain: .generatedExplanations, key: explanationRawID) != nil
    }

    private var storedNodeExplanationFormulaCount: Int? {
        guard let explanationRawID,
              let json = Inf6MetadataStore.get(domain: .generatedExplanations, key: explanationRawID),
              let data = json.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = payload["content"] as? [String: Any],
              let sections = content["sections"] as? [[String: Any]] else { return nil }
        return sections.reduce(into: 0) { count, section in
            if section["kind"] as? String == "formula" { count += 1 }
        }
    }

    private var hasExplanation: Bool {
        !entities.isEmpty && entityLoadError == nil
    }

    private var hasValidStoredNodeExplanation: Bool {
        guard let explanationRawID else { return false }
        return (try? Inf6LibraryView()._loadNodeExplanationEntities(rawID: explanationRawID)) != nil
    }

    private var _linkedSyllabusPaperRecords: [Inf6CorePaper] {
        guard let sourceFamily = _effectiveSyllabusSourceFamily,
              let chapterID = context.chapterID,
              !sourceFamily.isEmpty,
              !chapterID.isEmpty else { return [] }
        return Inf6SyllabusPaperAutoSearch.linkedPaperIDs(
            sourceFamily: sourceFamily,
            syllabusNodeID: chapterID
        ).compactMap { paperID in
            Inf6CorePaperStore.shared.papers.first { $0.id == paperID }
                ?? Inf6MetadataStore.getCodable(Inf6CorePaper.self, domain: .papers, key: paperID)
                ?? Inf6MetadataStore.listAllCodable(Inf6CorePaper.self, domain: .papers)
                    .first { $0.value.id == paperID }?.value
        }
    }

    private var _linkedSyllabusPapers: [Inf6CorePaper] {
        _linkedSyllabusPaperRecords.filter { paper in
            let isExplanationRecord = paper.provider == "generated_explanation"
                || paper.id.hasPrefix("textbook:")
                || paper.tags.contains("explanation_item")
            let hasSourceIdentifier = !(paper.arxivId ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasSourceURL = !(paper.pdfURL ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return !isExplanationRecord
                && (hasSourceIdentifier || hasSourceURL || paper.resolvedPDFURL != nil)
        }
    }

    private var _unresolvedLinkedPaperIDs: [String] {
        guard let sourceFamily = _effectiveSyllabusSourceFamily,
              let chapterID = context.chapterID,
              !sourceFamily.isEmpty,
              !chapterID.isEmpty else { return [] }
        let resolvedIDs = Set(_linkedSyllabusPaperRecords.map(\.id))
        return Inf6SyllabusPaperAutoSearch.linkedPaperIDs(
            sourceFamily: sourceFamily,
            syllabusNodeID: chapterID
        ).filter { !resolvedIDs.contains($0) }
    }

    private var applicationSystemFont: Font {
        let family = applicationSystemFontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        return family.isEmpty
            ? .system(size: applicationSystemFontSize)
            : .custom(family, size: applicationSystemFontSize)
    }

    private var explanationFontSize: CGFloat {
        CGFloat(applicationSystemFontSize)
    }

    private var explanationFontSizeBinding: Binding<CGFloat> {
        Binding(
            get: { CGFloat(applicationSystemFontSize) },
            set: { applicationSystemFontSize = Double($0) }
        )
    }

    private var selectedEntity: Inf6DocEntity? {
        guard selectedOriginalArtifactID == nil else { return nil }
        guard let selectedEntityID else { return entities.first }
        return entities.first { $0.id == selectedEntityID } ?? entities.first
    }

    private var selectedPaperEntityID: UUID? {
        selectedEntity?.id
    }

    private var selectedEntityPaperID: String {
        selectedEntity.flatMap { entitySourcePaperIDs[$0.id] } ?? context.paperID
    }

    private var selectedEntityPaperTitle: String {
        guard let selectedEntity else { return displayPaperTitle }
        return entitySourcePaperTitles[selectedEntity.id] ?? displayPaperTitle
    }

    private var selectedOriginalArtifact: Inf6CodexOriginalArtifact? {
        guard let selectedOriginalArtifactID else { return nil }
        return originalArtifacts.first { $0.id == selectedOriginalArtifactID }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                _codexMainContent
                .padding(.horizontal, 0)
                .padding(.top, horizontalSizeClass == .compact ? 84 : 44)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                GeometryReader { proxy in
                    Group {
                        if proxy.size.width < 600 {
                            VStack(spacing: 0) {
                                HStack(spacing: 6) {
                                    Spacer(minLength: 0)
                                    _codeFrameworkPicker
                                    _codexNavigationPanel
                                    _codexFontSizeControl
                                }
                                .frame(maxWidth: .infinity, alignment: .trailing)

                                _codexPaperIdentityPanel
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        } else {
                            ZStack {
                                HStack(spacing: 8) {
                                    _codexPaperIdentityPanel
                                        .frame(maxWidth: 430, alignment: .leading)
                                    Spacer(minLength: 0)
                                }

                                if proxy.size.width >= 600 {
                                    HStack(spacing: 8) {
                                        Image("ArcaneCompact")
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 34, height: 34)
                                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                            .accessibilityHidden(true)
                                        if proxy.size.width >= 1100 {
                                            let title = Text("Arcane Derivation Codex")
                                                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(20), weight: .semibold, design: .rounded))
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.65)
                                            title
                                                .foregroundStyle(.clear)
                                                .overlay {
                                                    Inf6CodexDesign.featureVectorGradient
                                                        .mask(title)
                                                }
                                            }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .center)
                                }

                                HStack(alignment: .center, spacing: 6) {
                                    Spacer(minLength: 0)
                                    _codeFrameworkPicker
                                    _codexNavigationPanel
                                    _codexFontSizeControl
                                }
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 0)
                }
                .frame(height: horizontalSizeClass == .compact ? 84 : 44)

                if isGeneratingNodeExplanation {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Inf6CodexDesign.cyan)
                        Text(Inf6Lang.text("ノード解説を作成中", "Creating node explanation"))
                            .font(.headline)
                            .foregroundStyle(.white)
                        Button(Inf6Lang.text("キャンセル", "Cancel"), role: .cancel) {
                            nodeExplanationTask?.cancel()
                        }
                        .buttonStyle(.bordered)
                        .tint(Inf6CodexDesign.cyan)
                    }
                    .padding(24)
                    .background(Inf6CodexDesign.ink.opacity(0.96), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Inf6CodexDesign.cyan.opacity(0.7), lineWidth: 1))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .zIndex(2)
                } else if !context.paperID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && entities.isEmpty && originalArtifacts.isEmpty && entityLoadError == nil {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Inf6CodexDesign.cyan)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .zIndex(1)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Inf6CodexMarbleBackdrop().ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            isShowingSyllabusNodeHome = context.chapterID != nil
            syllabusNodeWorkspaceRoute = .overview
            do {
                let domainState = try Inf6LearningDomainStore.load()
                activeLearningDomainID = domainState.activeID
                let activeDomain = domainState.domains.first(where: { $0.id == domainState.activeID })
                activeLearningDomainName = activeDomain?.name ?? Inf6LearningDomain.eQualification.name
                activeLearningDomainKind = activeDomain?.kind ?? .qualification
            } catch {
                entityLoadError = error.localizedDescription
            }
            if activeLearningDomainID == Inf6LearningDomain.eQualification.id,
               let root = Inf6EntityImageLocation.resolvedURL() {
                do {
                    let workspace = try WorkspaceStore(root: root)
                    if let snapshot = try SyllabusRepository(root: workspace).current(domain: "E資格"), snapshot.verified {
                        hydratedEshikakuOutline = try Inf6SyllabusConceptSetSynchronizer
                            .persistVerifiedEshikakuOutline(snapshot: snapshot)
                    }
                } catch {
                    entityLoadError = error.localizedDescription
                }
            }
            if let chapterID = context.chapterID,
               context.paperID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let sourceFamily = context.sourceFamily
                    ?? (activeLearningDomainID == Inf6LearningDomain.eQualification.id ? "jdla_eshikaku" : nil)
                if let paperID = _paperID(forChapterID: chapterID, sourceFamily: sourceFamily) {
                    let paper = Inf6CorePaperStore.shared.papers.first { $0.id == paperID }
                        ?? Inf6MetadataStore.getCodable(Inf6CorePaper.self, domain: .papers, key: paperID)
                    context = Inf6CodexRootContext(
                        paperID: paperID,
                        paperTitle: paper?.titleEn ?? paper?.title ?? context.chapterTitle ?? context.paperTitle,
                        sourceFamily: sourceFamily,
                        chapterID: chapterID,
                        chapterTitle: context.chapterTitle,
                        chapterOptions: context.chapterOptions,
                        evidence: context.evidence
                    )
                    Inf6CodexTopContextStore.save(context)
                } else {
                    entityLoadError = Inf6Lang.text(
                        "このシラバスノードに対応する論文の関連付けがありません。",
                        "No paper is linked to this syllabus node."
                    )
                }
            }
            _loadSyllabusOverview()
            _loadPaperEntities()
            _loadOriginalArtifacts()
        }
        .onDisappear {
            nodeExplanationTask?.cancel()
            nodeExplanationTask = nil
        }
        .alert(
            Inf6Lang.text("数式を保存できませんでした", "Could not save the formula"),
            isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
        ) {
            Button(Inf6Lang.text("閉じる", "Close")) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .alert(
            Inf6Lang.text("再クロップに失敗しました", "Recrop failed"),
            isPresented: Binding(get: { recropError != nil }, set: { if !$0 { recropError = nil } })
        ) {
            Button(Inf6Lang.text("閉じる", "Close")) { recropError = nil }
        } message: {
            Text(recropError ?? "")
                .textSelection(.enabled)
        }
        .alert(
            Inf6Lang.text("日本語訳に失敗しました", "Translation failed"),
            isPresented: Binding(get: { translationError != nil }, set: { if !$0 { translationError = nil } })
        ) {
            Button(Inf6Lang.text("閉じる", "Close")) { translationError = nil }
        } message: {
            Text(translationError ?? "")
                .textSelection(.enabled)
        }
        .alert(
            Inf6Lang.text("ノード解説を追加できませんでした", "Could not add node explanation"),
            isPresented: Binding(get: { nodeExplanationError != nil }, set: { if !$0 { nodeExplanationError = nil } })
        ) {
            Button(Inf6Lang.text("閉じる", "Close")) { nodeExplanationError = nil }
        } message: {
            Text(nodeExplanationError ?? "")
                .textSelection(.enabled)
        }
        .environment(\.font, applicationSystemFont)
        .sheet(item: $activeSettingsDestination) { destination in
            switch destination {
            case .learningDomains:
                Inf6LearningDomainManagementView { domain in
                    _selectLearningDomain(domain)
                    activeSettingsDestination = nil
                }
            case .font:
                Inf6ApplicationSystemFontSettingsView()
            case .api:
                APIKeySettingsView()
            case .sources:
                Inf6SourcesSettingsSheet()
            case .prompts:
                Inf6PromptSettingsView()
            case .storage:
                Inf6InitialStorageSetupView(isPresented: Binding(
                    get: { true },
                    set: { if !$0 { activeSettingsDestination = nil } }
                ))
            case .dataExchange:
                NavigationStack {
                    Inf6DataExchangeView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(Inf6Lang.text("閉じる", "Close")) {
                                    activeSettingsDestination = nil
                                }
                            }
                        }
                }
            }
        }
        .sheet(isPresented: $isSourcePDFPickerPresented) {
            Inf6DocumentFilePickerWrapper(onPick: { urls in
                _registerPickedSourcePDF(urls)
            })
        }
        .sheet(item: $userFormulaTarget) { target in
            NavigationStack {
                _FormulaEntityDetail(
                    entity: target,
                    paperID: "user:\(target.id.uuidString)",
                    chapterID: context.chapterID,
                    paperTitle: context.chapterID == nil
                        ? Inf6Lang.text("ユーザー起点の数式", "User-started formula")
                        : (displayChapterTitle ?? activeLearningDomainName),
                    collectedNotes: [],
                    explanationFontSize: explanationFontSizeBinding,
                    selectedCodeFramework: $selectedCodeFramework,
                    origin: .userAuthored,
                    userDerivationID: target.id
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(Inf6Lang.text("閉じる", "Close")) {
                            userFormulaTarget = nil
                        }
                    }
                }
            }
        }
        .alert(
            Inf6Lang.text("論文原典PDFを登録できませんでした", "Could not register the source paper PDF"),
            isPresented: Binding(get: { sourcePDFImportError != nil }, set: { if !$0 { sourcePDFImportError = nil } })
        ) {
            Button(Inf6Lang.text("閉じる", "Close")) { sourcePDFImportError = nil }
        } message: {
            Text(sourcePDFImportError ?? "")
        }
    }

    @ViewBuilder
    private var _codexMainContent: some View {
        if isShowingSyllabusNodeHome, context.chapterID != nil {
            switch syllabusNodeWorkspaceRoute {
            case .overview:
                _syllabusNodeWorkspace
            case .explanation:
                _selectedEntityWorkspace
            case .papers:
                _syllabusNodePapersWorkspace
            }
        } else if _isEQualificationRoot {
            _syllabusRootContent
        } else if activeLearningDomainID == Inf6LearningDomain.eQualification.id,
                  context.chapterID == nil,
                  context.paperID.isEmpty,
                  context.sourceFamily == nil {
            _unavailableSyllabusRootContent
        } else if let explanationRawID, hasExplanation, entities.isEmpty, originalArtifacts.isEmpty {
            Inf6ExplanationWindowView(rawID: explanationRawID)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let overview = syllabusOverview, entities.isEmpty, originalArtifacts.isEmpty {
            _syllabusOverviewContent(overview)
        } else if let entityLoadError, entities.isEmpty && originalArtifacts.isEmpty {
            Text(verbatim: entityLoadError)
                .foregroundStyle(.white)
                .textSelection(.enabled)
        } else if selectedEntity != nil {
            _selectedEntityWorkspace
        } else if let selectedOriginalArtifact {
            HStack(alignment: .top, spacing: 0) {
                _codexEntityRail()
                    .frame(minWidth: 48, maxWidth: 48, maxHeight: .infinity)
                _FormulaOriginalArtifactDetail(
                    artifact: selectedOriginalArtifact,
                    paperTitle: displayChapterTitle ?? displayPaperTitle,
                    explanationFontSize: explanationFontSizeBinding
                )
                .environment(\.font, .system(size: explanationFontSize))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    Text(activeLearningDomainKind == .paper
                         ? Inf6Lang.text("論文原典", "Source papers")
                         : activeLearningDomainName)
                        .font(Inf6CodexDesign.section)
                        .foregroundStyle(Inf6CodexDesign.cyan)
                    ForEach(_rootPaperTargets) { paper in
                        Button { _selectPaper(paper) } label: {
                            Text(_paperMenuTitle(paper))
                                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(16), weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Inf6CodexDesign.ink.opacity(0.82), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Inf6CodexDesign.cyan.opacity(0.58), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    if _rootPaperTargets.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(activeLearningDomainKind == .paper
                                 ? Inf6Lang.text("User Setting Rootに表示できる論文数式がありません。", "No paper equation is available in the User Setting Root.")
                                 : Inf6Lang.text("この分野には表示できる論文数式がありません。", "No paper equation is available in this domain."))
                                .foregroundStyle(.white)
                            Button {
                                isSourcePDFPickerPresented = true
                            } label: {
                                Label(
                                    Inf6Lang.text("論文原典PDFを取り込む", "Import source paper PDF"),
                                    systemImage: "tray.and.arrow.down"
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Inf6CodexDesign.cyan)
                            .accessibilityLabel(Inf6Lang.text("論文原典PDFを取り込む", "Import source paper PDF"))
                            Button {
                                userFormulaTarget = Inf6DocEntity(
                                    kind: .equation,
                                    pageIndex: 0,
                                    title: Inf6Lang.text("新しい数式", "New formula"),
                                    snippet: ""
                                )
                            } label: {
                                Label(
                                    Inf6Lang.text("手書き数式を開始", "Start handwritten formula"),
                                    systemImage: "pencil.and.outline"
                                )
                            }
                            .buttonStyle(.bordered)
                            .tint(Inf6CodexDesign.magenta)
                            .accessibilityLabel(Inf6Lang.text("手書き数式を開始", "Start handwritten formula"))
                        }
                    }
                    if let sourcePDFImportStatus {
                        Text(sourcePDFImportStatus)
                            .font(Inf6CodexDesign.technical)
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                    }
                }
                .padding(16)
            }
        }
    }

    private var _selectedEntityWorkspace: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isShowingSyllabusNodeHome {
                _nodeWorkspaceBackButton(to: .overview, title: Inf6Lang.text("ノードに戻る", "Back to node"))
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            if let selectedEntity {
                HStack(alignment: .top, spacing: 0) {
                    _codexEntityRail()
                        .frame(minWidth: 48, maxWidth: 48, maxHeight: .infinity)
                    _FormulaEntityDetail(
                        entity: selectedEntity,
                        paperID: selectedEntityPaperID,
                        chapterID: context.chapterID,
                        paperTitle: selectedEntityPaperTitle,
                        collectedNotes: collectedNotes,
                        explanationFontSize: explanationFontSizeBinding,
                        selectedCodeFramework: $selectedCodeFramework,
                        isNodeExplanationItem: isShowingSyllabusNodeHome,
                        origin: isShowingSyllabusNodeHome ? .userAuthored : .paperEvidence,
                        userDerivationID: isShowingSyllabusNodeHome ? selectedEntity.id : nil
                    )
                    .environment(\.font, .system(size: explanationFontSize))
                    .id(selectedEntityPaperID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if isShowingSyllabusNodeHome {
                        _nodeWorkspaceBackButton(to: .overview, title: Inf6Lang.text("ノードに戻る", "Back to node"))
                    }
                    Text(entityLoadError ?? Inf6Lang.text(
                        "ノード解説項目がありません。ノード解説を作成してください。",
                        "No node explanation items exist. Create the node explanation."
                    ))
                    .foregroundStyle(entityLoadError == nil ? Color.secondary : Color.red)
                    .textSelection(.enabled)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Inf6CodexDesign.ink.opacity(0.42))
        .foregroundStyle(.white)
    }

    private func _syllabusOverviewContent(_ item: Inf6SyllabusOutlineItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let summary = item.displaySummary,
                   !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(summary)
                        .font(.system(size: explanationFontSize))
                        .fixedSize(horizontal: false, vertical: true)
                }
                _nodeExplanationAction
                _startNodeFormulaButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(Inf6CodexDesign.ink.opacity(0.42))
        .foregroundStyle(.white)
    }

    private var _isEQualificationRoot: Bool {
        context.chapterID == nil
            && activeLearningDomainID == Inf6LearningDomain.eQualification.id
    }

    private var _syllabusRootContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                Text(Inf6Lang.text("E資格シラバス", "E Qualification syllabus"))
                    .font(Inf6CodexDesign.section)
                    .foregroundStyle(Inf6CodexDesign.cyan)
                    .padding(.bottom, 4)
                if let entityLoadError {
                    Text(verbatim: entityLoadError)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if _selectableChapters.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(Inf6Lang.text(
                            "選択中のUser Setting Rootに、E資格シラバスのノード構造がありません。既存の保存先を確認してください。",
                            "The selected User Setting Root has no E Qualification node structure. Check the storage root containing the existing data."
                        ))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        Button {
                            activeSettingsDestination = .storage
                        } label: {
                            Label(Inf6Lang.text("保存先を確認", "Check storage root"), systemImage: "externaldrive")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Inf6CodexDesign.cyan)
                    }
                } else {
                    ForEach(_visibleSyllabusChapters) { option in
                        HStack(spacing: 8) {
                            Color.clear
                                .frame(width: CGFloat(option.depth) * 18, height: 1)
                                .accessibilityHidden(true)
                            if _syllabusNodeHasChildren(option.id) {
                                Button {
                                    _toggleSyllabusNode(option.id)
                                } label: {
                                    Image(systemName: _isSyllabusNodeExpanded(option.id) ? "chevron.down" : "chevron.right")
                                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(11), weight: .semibold))
                                        .foregroundStyle(Inf6CodexDesign.cyan)
                                        .frame(width: 28, height: 36)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(_isSyllabusNodeExpanded(option.id)
                                    ? Inf6Lang.text("\(option.title)を折りたたむ", "Collapse \(option.title)")
                                    : Inf6Lang.text("\(option.title)を展開", "Expand \(option.title)"))
                            } else {
                                Color.clear
                                    .frame(width: 28, height: 1)
                                    .accessibilityHidden(true)
                            }
                            Button { _selectChapter(option) } label: {
                                Text(option.title)
                                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(16), weight: .medium))
                                    .foregroundStyle(.white)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Inf6Lang.text("\(option.title)を開く", "Open \(option.title)"))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Inf6CodexDesign.ink.opacity(0.82), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Inf6CodexDesign.cyan.opacity(0.38), lineWidth: 1))
                    }
                }
            }
            .padding(16)
        }
    }

    private var _unavailableSyllabusRootContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Inf6Lang.text("検証済みのE資格シラバスがありません。", "No verified E Qualification syllabus is available."))
                .foregroundStyle(.white)
            Button {
                activeSettingsDestination = .sources
            } label: {
                Label(Inf6Lang.text("シラバスの設定を開く", "Open syllabus settings"), systemImage: "books.vertical")
            }
            .buttonStyle(.borderedProminent)
            .tint(Inf6CodexDesign.cyan)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var _syllabusNodeWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                _nodeWorkspaceRouteButton(
                    title: Inf6Lang.text("ノードの解説", "Node explanation"),
                    detail: entities.isEmpty
                        ? Inf6Lang.text("関連する数式・図・表を表示", "View related formulas, figures, and tables")
                        : Inf6Lang.text("数式・図・表 \(entities.count) 件", "\(entities.count) formulas, figures, and tables"),
                    systemImage: "function"
                ) {
                    _openOrConfirmNodeExplanation()
                }
                _nodeWorkspaceRouteButton(
                    title: Inf6Lang.text("ノードの論文", "Node papers"),
                    detail: Inf6Lang.text("関連付けられた論文を選ぶ", "Choose a paper linked to this node"),
                    systemImage: "doc.text.magnifyingglass"
                ) {
                    syllabusNodeWorkspaceRoute = .papers
                }
            }
            .padding(20)
        }
        .background(Inf6CodexDesign.ink.opacity(0.42))
        .foregroundStyle(.white)
    }

    private var _syllabusNodePapersWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                _nodeWorkspaceBackButton(to: .overview, title: Inf6Lang.text("ノードに戻る", "Back to node"))
                if _linkedSyllabusPapers.isEmpty && _unresolvedLinkedPaperIDs.isEmpty {
                    Text(Inf6Lang.text(
                        "このノードに関連付けられた論文はありません。",
                        "No papers are linked to this node."
                    ))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
                ForEach(_linkedSyllabusPapers) { paper in
                    Button { _selectPaper(paper) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(Inf6CodexDesign.cyan)
                            Text(_paperMenuTitle(paper))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .foregroundStyle(Inf6CodexDesign.cyan)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Inf6CodexDesign.ink.opacity(0.82), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                if !_unresolvedLinkedPaperIDs.isEmpty {
                    Text(Inf6Lang.text(
                        "関連付けられた論文データを読み込めません。論文ID: \(_unresolvedLinkedPaperIDs.joined(separator: ", "))",
                        "Linked paper records could not be loaded. Paper IDs: \(_unresolvedLinkedPaperIDs.joined(separator: ", "))"
                    ))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .background(Inf6CodexDesign.ink.opacity(0.42))
        .foregroundStyle(.white)
    }

    private func _nodeWorkspaceRouteButton(
        title: String,
        detail: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(19), weight: .semibold))
                    .foregroundStyle(Inf6CodexDesign.cyan)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(Inf6CodexDesign.section)
                        .foregroundStyle(.white)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(Inf6CodexDesign.cyan)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Inf6CodexDesign.ink.opacity(0.82), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func _nodeWorkspaceBackButton(to route: Inf6SyllabusNodeWorkspaceRoute, title: String) -> some View {
        Button {
            syllabusNodeWorkspaceRoute = route
        } label: {
            Label(title, systemImage: "chevron.left")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Inf6CodexDesign.cyan)
    }

    private var _startNodeFormulaButton: some View {
        Button {
            userFormulaTarget = Inf6DocEntity(
                kind: .equation,
                pageIndex: 0,
                title: Inf6Lang.text("新しい数式", "New formula"),
                snippet: ""
            )
        } label: {
            Label(Inf6Lang.text("数式導出を開始", "Start formula derivation"), systemImage: "pencil.and.outline")
        }
        .buttonStyle(.borderedProminent)
        .tint(Inf6CodexDesign.magenta)
    }

    @ViewBuilder
    private var _nodeExplanationAction: some View {
        if explanationRawID != nil {
            if isGeneratingNodeExplanation {
                HStack(spacing: 10) {
                    ProgressView().tint(Inf6CodexDesign.cyan)
                    Text(Inf6Lang.text("ノード解説を生成しています", "Generating node explanation"))
                        .font(.callout)
                    Button(Inf6Lang.text("キャンセル", "Cancel")) {
                        nodeExplanationTask?.cancel()
                    }
                    .buttonStyle(.bordered)
                }
            } else if hasValidStoredNodeExplanation {
                Button {
                    _openOrConfirmNodeExplanation()
                } label: {
                    Label(Inf6Lang.text("ノード解説を開く", "Open node explanation"), systemImage: "text.book.closed")
                }
                .buttonStyle(.borderedProminent)
                .tint(Inf6CodexDesign.cyan)
            } else if hasStoredNodeExplanation {
                Button {
                    _startNodeExplanationGeneration()
                } label: {
                    Label(
                        storedNodeExplanationFormulaCount.map {
                            Inf6Lang.text("保存済み数式\($0)件を再生成", "Regenerate saved explanation (\($0) formulas)")
                        } ?? Inf6Lang.text("保存済み解説を再生成", "Regenerate saved explanation"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(Inf6CodexDesign.cyan)
            } else {
                Button {
                    _startNodeExplanationGeneration()
                } label: {
                    Label(Inf6Lang.text("ノード解説を追加", "Add node explanation"), systemImage: "text.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(Inf6CodexDesign.cyan)
            }
        }
    }

    private func _openOrConfirmNodeExplanation() {
        guard context.chapterID != nil,
              _effectiveSyllabusSourceFamily != nil else {
            nodeExplanationError = Inf6Lang.text(
                "選択中ノードの識別情報を取得できません。",
                "The selected node identity is unavailable."
            )
            return
        }

        guard !isGeneratingNodeExplanation else { return }
        guard hasValidStoredNodeExplanation,
              let nodeID = context.chapterID,
              let sourceFamily = _effectiveSyllabusSourceFamily else {
            _startNodeExplanationGeneration()
            return
        }

        _loadSyllabusNodeEntities(sourceFamily: sourceFamily, nodeID: nodeID)
        if !entities.isEmpty && entityLoadError == nil {
            isShowingSyllabusNodeHome = true
            syllabusNodeWorkspaceRoute = .explanation
            return
        }
        if let entityLoadError {
            nodeExplanationError = entityLoadError
        } else {
            _startNodeExplanationGeneration()
        }
    }

    private func _startNodeExplanationGeneration() {
        guard explanationRawID != nil else {
            nodeExplanationError = Inf6Lang.text("シラバスの出典とノードIDを解決できません。", "The syllabus source and node ID could not be resolved.")
            return
        }
        do {
            _ = try OpenAIKeyStore.load()
        } catch {
            nodeExplanationError = error.localizedDescription
            return
        }
        let library = Inf6LibraryView()
        isGeneratingNodeExplanation = true
        nodeExplanationError = nil
        nodeExplanationTask = Task { @MainActor in
            defer {
                isGeneratingNodeExplanation = false
                nodeExplanationTask = nil
            }
            do {
                guard let nodeID = context.chapterID,
                      let sourceFamily = _effectiveSyllabusSourceFamily else {
                    throw NSError(domain: "inf6.nodeExplanation", code: 7, userInfo: [
                        NSLocalizedDescriptionKey: "シラバスの出典とノードIDを解決できません。"
                    ])
                }
                let rawID = "inf6-explanation:\(sourceFamily):\(nodeID)"
                try await library._generateOriginalExplanationJSON(rawID: rawID)
                guard !Task.isCancelled else { return }
                entities = try library._loadNodeExplanationEntities(rawID: rawID)
                let nodeSourceID = "node:\(rawID)"
                entitySourcePaperIDs = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, nodeSourceID) })
                let nodeTitle = displayChapterTitle ?? context.chapterTitle ?? nodeID
                entitySourcePaperTitles = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, nodeTitle) })
                selectedEntityID = entities.first?.id
                selectedOriginalArtifactID = nil
                originalArtifacts = []
                entityLoadError = nil
                isShowingSyllabusNodeHome = true
                syllabusNodeWorkspaceRoute = .explanation
            } catch is CancellationError {
                return
            } catch {
                nodeExplanationError = error.localizedDescription
            }
        }
    }

    private func _codexEntityRail() -> some View {
        GeometryReader { proxy in
            let itemCount = entities.count + originalArtifacts.count
            let interRowSpacing: CGFloat = 2
            let rowHeight = itemCount == 0
                ? 1
                : max(1, (proxy.size.height - 8 - interRowSpacing * CGFloat(itemCount - 1)) / CGFloat(itemCount))
            VStack(spacing: 2) {
                ForEach(Array(entities.enumerated()), id: \.element.id) { index, entity in
                    HStack(spacing: 0) {
                        Button {
                            _selectRailItem(at: index)
                        } label: {
                            _CodexEntityThumbnail(entity: entity, isSelected: entity.id == selectedEntity?.id)
                                .frame(width: 29, height: 25)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(Inf6Lang.text(entity.kind.labelJa, entity.kind.labelEn)) \(entity.title)")

                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Inf6CodexDesign.cyan)
                    .frame(height: rowHeight)
                }

                ForEach(Array(originalArtifacts.enumerated()), id: \.element.id) { index, artifact in
                    let itemIndex = entities.count + index
                    HStack(spacing: 0) {
                        Button { _selectRailItem(at: itemIndex) } label: {
                            _CodexOriginalArtifactThumbnail(artifact: artifact, isSelected: artifact.id == selectedOriginalArtifactID)
                                .frame(width: 29, height: 25)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(artifact.heading)

                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Inf6CodexDesign.cyan)
                    .frame(height: rowHeight)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .focusable()
            .focused($isEntityRailFocused)
            .onKeyPress(.upArrow) {
                _moveRailSelection(by: -1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                _moveRailSelection(by: 1)
                return .handled
            }
        }
        .frame(minWidth: 48, maxWidth: 48, maxHeight: .infinity)
        .background(Inf6CodexDesign.ink.opacity(0.28))
    }

    private func _selectRailItem(at index: Int) {
        let itemCount = entities.count + originalArtifacts.count
        guard (0..<itemCount).contains(index) else { return }
        isEntityRailFocused = true
        if index < entities.count {
            selectedEntityID = entities[index].id
            selectedOriginalArtifactID = nil
        } else {
            selectedEntityID = nil
            selectedOriginalArtifactID = originalArtifacts[index - entities.count].id
        }
    }

    private func _moveRailSelection(by offset: Int) {
        let itemCount = entities.count + originalArtifacts.count
        guard itemCount > 0 else { return }
        let currentIndex: Int
        if let selectedEntityID,
           let index = entities.firstIndex(where: { $0.id == selectedEntityID }) {
            currentIndex = index
        } else if let selectedOriginalArtifactID,
                  let index = originalArtifacts.firstIndex(where: { $0.id == selectedOriginalArtifactID }) {
            currentIndex = entities.count + index
        } else {
            return
        }
        _selectRailItem(at: min(max(currentIndex + offset, 0), itemCount - 1))
    }

    private var _codexNavigationPanel: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                if let pdfURL = sourcePaper?.resolvedPDFURL, !isShowingSyllabusNodeHome {
                    Menu {
                        Button(Inf6Lang.text("論文PDFを開く", "Open paper PDF"), systemImage: "doc.text") {
                            openWindow(id: "paper", value: pdfURL)
                        }
                    } label: {
                        _codexRouteLabel(
                            Inf6Lang.text("論文PDFを開く", "Open paper PDF"),
                            systemImage: "doc.text",
                            tint: Inf6CodexDesign.cyan
                        )
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                }

                if let explanationRawID, hasExplanation, !isShowingSyllabusNodeHome {
                    Menu {
                        Button(Inf6Lang.text("解説を開く", "Open explanation"), systemImage: "text.book.closed") {
                            openWindow(id: "explanation", value: explanationRawID)
                        }
                    } label: {
                        _codexRouteLabel("解説", systemImage: "text.book.closed", tint: Inf6CodexDesign.cyan)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                }
            }
            Menu {
                Menu(Inf6Lang.text("ローカル処理", "Local processing")) {
                if isRecropping {
                    Button(role: .cancel) {
                        recropTask?.cancel()
                    } label: {
                        Label(Inf6Lang.text("再クロップをキャンセル", "Cancel recrop"), systemImage: "xmark.circle")
                    }
                    Divider()
                }
                Section {
                    Button {
                        _recropCurrentPaper()
                    } label: {
                        Label(
                            Inf6Lang.text("表示中の論文を再クロップ", "Recrop current paper"),
                            systemImage: "cpu"
                        )
                        .foregroundStyle(Inf6CodexDesign.cyan)
                    }
                    .disabled(isRecropping || recropEntry == nil)
                } header: {
                    Text(Inf6Lang.text("ローカル Core ML", "Local Core ML"))
                        .foregroundStyle(Inf6CodexDesign.cyan)
                }
                }

                Menu(Inf6Lang.text("AI処理", "AI processing")) {
                Section {
                    Button {
                        _recropSelectedEntity()
                    } label: {
                        Label(
                            Inf6Lang.text(
                                "選択中のEntityを再クロップしてLLM処理",
                                "Recrop selected entity and run LLM processing"
                            ),
                            systemImage: "sparkles"
                        )
                        .foregroundStyle(Inf6CodexDesign.magenta)
                    }
                    .disabled(isRecropping || recropEntry == nil || selectedPaperEntityID == nil)
                } header: {
                    Text(Inf6Lang.text("LLM", "LLM"))
                        .foregroundStyle(Inf6CodexDesign.magenta)
                }
                }

                Menu(Inf6Lang.text("翻訳", "Translation")) {
                Section {
                    Button {
                        _translateSelectedEntity()
                    } label: {
                        Label(
                            Inf6Lang.text("選択中のEntityをOS標準翻訳", "Translate selected entity with OS translation"),
                            systemImage: "character.book.closed"
                        )
                        .foregroundStyle(.green)
                    }
                    .disabled(isRecropping || recropEntry == nil || selectedPaperEntityID == nil)
                } header: {
                    Text(Inf6Lang.text("OS標準翻訳", "OS Translation"))
                        .foregroundStyle(.green)
                }
                }

                Menu(Inf6Lang.text("学習分野", "Learning domain")) {
                    Label(activeLearningDomainName, systemImage: "square.stack.3d.up")
                    Button {
                        activeSettingsDestination = .learningDomains
                    } label: {
                        Label(Inf6Lang.text("分野を管理…", "Manage domains…"), systemImage: "plus.circle")
                    }
                }

                Menu(Inf6Lang.text("表示設定", "Display")) {
                    Menu {
                        Button {
                            generationLanguageRaw = "ja"
                            interfaceLanguageRaw = "ja"
                        } label: {
                            HStack {
                                if generationLanguageRaw == "ja" && interfaceLanguageRaw == "ja" {
                                    Image(systemName: "checkmark")
                                }
                                Text(Inf6Lang.text("日本語（表示・生成）", "Japanese (display and generation)"))
                            }
                        }
                        Button {
                            generationLanguageRaw = "en"
                            interfaceLanguageRaw = "en"
                        } label: {
                            HStack {
                                if generationLanguageRaw == "en" && interfaceLanguageRaw == "en" {
                                    Image(systemName: "checkmark")
                                }
                                Text(Inf6Lang.text("英語（表示・生成）", "English (display and generation)"))
                            }
                        }
                        Button {
                            generationLanguageRaw = "auto"
                            interfaceLanguageRaw = "auto"
                        } label: {
                            HStack {
                                if generationLanguageRaw == "auto" && interfaceLanguageRaw == "auto" {
                                    Image(systemName: "checkmark")
                                }
                                Text(Inf6Lang.text("システム設定に従う", "Follow system language"))
                            }
                        }
                    } label: {
                        Label(Inf6Lang.text("日英設定…", "Language…"), systemImage: "globe")
                    }
                    Button {
                        activeSettingsDestination = .font
                    } label: {
                        Label(Inf6Lang.text("アプリケーションシステムフォント…", "Application system font…"), systemImage: "textformat")
                    }
                }
                Menu(Inf6Lang.text("資料とAI設定", "Sources and AI settings")) {
                    Button {
                        activeSettingsDestination = .api
                    } label: {
                        Label(Inf6Lang.text("API キー設定…", "API key settings…"), systemImage: "key.horizontal")
                    }
                    Button {
                        activeSettingsDestination = .sources
                    } label: {
                        Label(Inf6Lang.text("ソース設定…", "Sources settings…"), systemImage: "list.bullet.rectangle")
                    }
                    Button {
                        isSourcePDFPickerPresented = true
                    } label: {
                        Label(Inf6Lang.text("論文原典PDFを取り込む…", "Import source paper PDF…"), systemImage: "tray.and.arrow.down")
                    }
                    Button {
                        activeSettingsDestination = .prompts
                    } label: {
                        Label(Inf6Lang.text("Prompt管理…", "Prompt management…"), systemImage: "slider.horizontal.3")
                    }
                }
                Menu(Inf6Lang.text("データ", "Data")) {
                    Button {
                        activeSettingsDestination = .storage
                    } label: {
                        Label(Inf6Lang.text("保存する場所…", "Storage folder…"), systemImage: "externaldrive")
                    }
                    Button {
                        activeSettingsDestination = .dataExchange
                    } label: {
                        Label(Inf6Lang.text("エクスポート / インポート", "Export / Import"), systemImage: "arrow.up.arrow.down")
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    if isRecropping {
                        ProgressView().tint(.pink).scaleEffect(1.25)
                            .controlSize(.small)
                            .tint(Inf6CodexDesign.cyan)
                    .accessibilityLabel(Inf6Lang.text("処理中", "Processing"))
                    }
                        Image(systemName: "gearshape")
                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(14), weight: .semibold))
                        .foregroundStyle(Inf6CodexDesign.cyan)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel(Inf6Lang.text("全設定", "All settings"))
            .help(Inf6Lang.text("全設定", "All settings"))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Inf6CodexDesign.ink.opacity(0.82))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Inf6CodexDesign.cyan.opacity(0.78), lineWidth: 1)
                    }
            )

            if let recropStatus {
                Text(recropStatus)
                    .font(Inf6CodexDesign.technical)
                    .foregroundStyle(isRecropping ? Inf6CodexDesign.cyan : .white)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 360, alignment: .leading)
                    .layoutPriority(0)
                if isRecropping {
                    Button(role: .cancel) {
                        recropTask?.cancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(14), weight: .semibold))
                            .foregroundStyle(Inf6CodexDesign.cyan)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Inf6Lang.text("再クロップをキャンセル", "Cancel recrop"))
                }
            }
        }
    }

    private func _recropCurrentPaper() {
        guard !isRecropping else { return }
        guard let entry = recropEntry else {
            recropStatus = Inf6Lang.text("再クロップ対象の保存データがありません", "No saved data is available for recropping")
            return
        }
        isRecropping = true
        let paperName = entry.paper.titleEn ?? entry.paper.title
        let target = Inf6Lang.text("論文全体", "Entire paper")
        let recropTarget = Inf6Lang.text("\(paperName) / \(target)", "\(paperName) / \(target)")
        recropStatus = Inf6Lang.text("再クロップ中: \(recropTarget)", "Recropping: \(recropTarget)")
        recropError = nil
        recropTask = Task.detached(priority: .userInitiated) {
            do {
                try await Inf6EshikakuDrillPipeline.recutEntityImages(
                    entry: entry,
                    expansion: .init(top: 0, bottom: 0, left: 0, right: 0),
                    entityFilter: [.figure, .table, .equation]
                )
                await MainActor.run {
                    isRecropping = false
                    recropTask = nil
                    recropStatus = Inf6Lang.text("再クロップ完了: \(recropTarget)", "Recrop completed: \(recropTarget)")
                    _loadPaperEntities()
                }
            } catch {
                await MainActor.run {
                    isRecropping = false
                    recropTask = nil
                    if error is CancellationError || Task.isCancelled {
                        recropStatus = Inf6Lang.text("再クロップをキャンセルしました", "Recrop cancelled")
                    } else {
                        recropStatus = Inf6Lang.text("再クロップ失敗", "Recrop failed")
                        recropError = error.localizedDescription
                    }
                }
            }
        }
    }

    private func _recropSelectedEntity() {
        guard !isRecropping,
              let entry = recropEntry,
              let selectedEntityID = selectedPaperEntityID else { return }
        isRecropping = true
        let paperName = entry.paper.titleEn ?? entry.paper.title
        let selectedEntity = entities.first(where: { $0.id == selectedEntityID })
        let target = selectedEntity.map { "\($0.title) / p.\($0.pageIndex + 1)" }
            ?? selectedEntityID.uuidString
        let recropTarget = Inf6Lang.text("\(paperName) / \(target)", "\(paperName) / \(target)")
        recropStatus = Inf6Lang.text("再クロップ中: \(recropTarget)", "Recropping: \(recropTarget)")
        recropError = nil
        recropTask = Task.detached(priority: .userInitiated) {
            do {
                _ = try await Inf6EshikakuDrillPipeline.recutSingleEntityImage(
                    entry: entry,
                    docEntityID: selectedEntityID.uuidString,
                    expansion: .init(top: 0, bottom: 0, left: 0, right: 0)
                )
                await MainActor.run {
                    isRecropping = false
                    recropTask = nil
                    recropStatus = Inf6Lang.text("再クロップ完了: \(recropTarget)", "Recrop completed: \(recropTarget)")
                    _loadPaperEntities()
                }
            } catch {
                await MainActor.run {
                    isRecropping = false
                    recropTask = nil
                    if error is CancellationError || Task.isCancelled {
                        recropStatus = Inf6Lang.text("再クロップをキャンセルしました", "Recrop cancelled")
                    } else {
                        recropStatus = Inf6Lang.text("再クロップ失敗", "Recrop failed")
                        recropError = error.localizedDescription
                    }
                }
            }
        }
    }

    private func _translateSelectedEntity() {
        guard !isRecropping,
              let entry = recropEntry,
              let selectedEntityID = selectedPaperEntityID else { return }
        isRecropping = true
        let paperName = entry.paper.titleEn ?? entry.paper.title
        let selectedEntity = entities.first(where: { $0.id == selectedEntityID })
        let target = selectedEntity.map { "\($0.title) / p.\($0.pageIndex + 1)" } ?? selectedEntityID.uuidString
        let translationTarget = Inf6Lang.text("\(paperName) / \(target)", "\(paperName) / \(target)")
        recropStatus = Inf6Lang.text("OS翻訳の利用可否を確認中: \(translationTarget)", "Checking OS translation availability: \(translationTarget)")
        recropError = nil
        recropTask = Task.detached(priority: .userInitiated) {
            do {
                try await Inf6SystemTranslationCoordinator.shared.verifyReadyForTranslation()
                await MainActor.run {
                    recropStatus = Inf6Lang.text("Entity内の論文本文を日本語訳中: \(translationTarget)", "Translating entity paper text: \(translationTarget)")
                }
                try await Inf6EshikakuDrillPipeline.translateEntityPartsToJapanese(
                    paperKey: entry.folderKey,
                    entityID: selectedEntityID
                )
                await MainActor.run {
                    isRecropping = false
                    recropTask = nil
                    recropStatus = Inf6Lang.text("Entity内の日本語訳を取得しました", "Entity paper text translated")
                    _loadPaperEntities()
                }
            } catch {
                await MainActor.run {
                    isRecropping = false
                    recropTask = nil
                    if error is CancellationError || Task.isCancelled {
                        recropStatus = Inf6Lang.text("日本語訳をキャンセルしました", "Translation cancelled")
                    } else {
                        recropStatus = Inf6Lang.text("日本語訳に失敗しました", "Translation failed")
                        translationError = error.localizedDescription
                    }
                }
            }
        }
    }

    private var _codeFrameworkPicker: some View {
        Menu {
            Button {
                selectedCodeFramework = "PyTorch"
            } label: {
                HStack {
                    Label("PyTorch", systemImage: "p.square.fill")
                    Spacer()
                    if selectedCodeFramework == "PyTorch" {
                        Image(systemName: "checkmark")
                    }
                }
            }
            Button {
                selectedCodeFramework = "TensorFlow"
            } label: {
                HStack {
                    Label("TensorFlow", systemImage: "t.square.fill")
                    Spacer()
                    if selectedCodeFramework == "TensorFlow" {
                        Image(systemName: "checkmark")
                    }
                }
            }
        } label: {
            Text(selectedCodeFramework == "PyTorch" ? "P" : "T")
                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(13), weight: .bold, design: .rounded))
                .frame(width: 26, height: 26)
                .foregroundStyle(Inf6CodexDesign.cyan)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Inf6CodexDesign.cyan.opacity(0.78), lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(Inf6Lang.text("実行フレームワーク", "Execution framework"))
        .help(Inf6Lang.text("実行フレームワーク", "Execution framework"))
    }

    private var _codexFontSizeControl: some View {
        HStack(spacing: 3) {
            Image(systemName: "textformat.size")
                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(13), weight: .semibold))
                .foregroundStyle(Inf6CodexDesign.cyan)
                .accessibilityHidden(true)
            Button {
                applicationSystemFontSize = max(12, applicationSystemFontSize - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Inf6CodexDesign.cyan)
            .disabled(applicationSystemFontSize <= 12)
            .accessibilityLabel(Inf6Lang.text("文字を小さく", "Decrease text size"))

            Inf6CompactFontSizeSlider(value: explanationFontSizeBinding, range: 12...32)

            Button {
                applicationSystemFontSize = min(32, applicationSystemFontSize + 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Inf6CodexDesign.cyan)
            .disabled(applicationSystemFontSize >= 32)
            .accessibilityLabel(Inf6Lang.text("文字を大きく", "Increase text size"))
        }
        .frame(width: 178, height: 26)
        .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Inf6CodexDesign.cyan.opacity(0.62), lineWidth: 1))
        .help(Inf6Lang.text("文字サイズ \(Int(explanationFontSize)) pt", "Text size \(Int(explanationFontSize)) pt"))
    }

    private var _codexPaperIdentityPanel: some View {
        HStack(alignment: .center, spacing: 14) {
            if context.chapterID != nil {
                Button {
                    _showSyllabusRoot()
                } label: {
                    _codexSelectionLabel(Inf6Lang.text("シラバス", "Syllabus"))
                }
                .buttonStyle(.plain)
            }
            if !_chapterPath.isEmpty {
                ForEach(Array(_chapterPath.enumerated()), id: \.element.id) { pathIndex, option in
                    if pathIndex > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(9), weight: .bold))
                            .foregroundStyle(Inf6CodexDesign.cyan.opacity(0.78))
                    }
                    Menu {
                        if option.id != context.chapterID {
                            Button(option.title) { _selectChapter(option) }
                            Divider()
                        }
                        ForEach(_chapterSiblings(of: option)) { sibling in
                            Button(sibling.title) { _selectChapter(sibling) }
                        }
                        if option.id == context.chapterID {
                            let children = _directSyllabusChildren(of: option.id)
                            if !children.isEmpty {
                                Divider()
                                ForEach(children) { child in
                                    Button(child.title) { _selectChapter(child) }
                                }
                            }
                        }
                    } label: {
                        _codexSelectionLabel(option.title)
                    }
                    .buttonStyle(.plain)
                    .layoutPriority(pathIndex == _chapterPath.count - 1 ? 2 : 1)
                }
            }
            if !context.paperID.isEmpty && !_isEQualificationRoot && !isShowingSyllabusNodeHome {
                Menu {
                    ForEach(_selectablePapers) { paper in
                        Button { _selectPaper(paper) } label: {
                            Text(_paperMenuTitle(paper))
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(displayPaperTitle)
                            .font(Inf6CodexDesign.section)
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                            .layoutPriority(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(12), weight: .bold))
                            .foregroundStyle(Inf6CodexDesign.cyan)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func _codexSelectionLabel(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(Inf6CodexDesign.section)
                .foregroundStyle(Inf6CodexDesign.cyan)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Image(systemName: "chevron.down")
                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(10), weight: .bold))
                .foregroundStyle(Inf6CodexDesign.cyan)
        }
    }

    private var _showsOfficialSyllabusHierarchy: Bool {
        let sourceFamily = (context.sourceFamily ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["jdla_eshikaku", "eshikaku", "jdla_gkentei", "microsoft_ai_102"].contains(sourceFamily)
            && !_chapterPath.isEmpty
    }

    private var _selectablePapers: [Inf6CorePaper] {
        Inf6CorePaperStore.shared.papers
            .filter { paper in
                paper.arxivId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    || paper.pdfURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    || paper.resolvedPDFURL != nil
            }
            .sorted {
                if ($0.year ?? 0) != ($1.year ?? 0) { return ($0.year ?? 0) < ($1.year ?? 0) }
                return ($0.titleEn ?? $0.title).localizedCaseInsensitiveCompare($1.titleEn ?? $1.title) == .orderedAscending
            }
    }

    private var _rootPaperTargets: [Inf6CorePaper] {
        let entityIndexes = Inf6MetadataStore.listAllCodable(Inf6DocEntityIndex.self, domain: .docEntities)
        return _selectablePapers.filter { paper in
            let keys = [
                Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paper.id),
                Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paper.title),
                Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paper.titleEn ?? "")
            ].filter { !$0.isEmpty }
            return entityIndexes.contains { record in
                let storedKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: record.value.pdfKey)
                return keys.contains { key in
                    storedKey == key || storedKey.hasSuffix("_\(key)") || key.hasSuffix("_\(storedKey)")
                }
            }
        }
    }

    private func _registerPickedSourcePDF(_ urls: [URL]) {
        guard !urls.isEmpty else {
            sourcePDFImportStatus = Inf6Lang.text(
                "論文原典PDFの選択をキャンセルしました。既存の保存済み成果物は変更していません。",
                "Source paper PDF selection was cancelled. Existing saved artifacts were not changed."
            )
            return
        }
        guard urls.count == 1, let sourceURL = urls.first else {
            sourcePDFImportError = Inf6Lang.text(
                "一度に登録できる論文原典PDFは1件です。",
                "Register exactly one source paper PDF at a time."
            )
            return
        }

        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        do {
            try Inf6PDFReferenceStore.put(url: sourceURL, learningDomainID: activeLearningDomainID)
            let selectedPath = sourceURL.standardizedFileURL.path
            let papersDirectory = Inf6LocalStore.url(.papers).standardizedFileURL.path + "/"
            let persisted = try Inf6PDFReferenceStore.list().first {
                $0.originalPath == selectedPath
                    && $0.resolvedPath.hasPrefix(papersDirectory)
            }
            guard persisted != nil else {
                throw NSError(
                    domain: "Inf6CodexRootView",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text(
                        "登録したPDF実体をUser Setting Rootから再読込できませんでした。",
                        "The saved PDF bytes could not be reloaded from the User Setting Root."
                    )]
                )
            }
            sourcePDFImportStatus = Inf6Lang.text(
                "PDF実体をUser Setting Rootへ保存しました: \(sourceURL.lastPathComponent)。論文の同一性確認と数式entity抽出は、この保存だけでは完了していません。",
                "Saved PDF bytes to the User Setting Root: \(sourceURL.lastPathComponent). Paper identity verification and formula-entity extraction are not completed by this save alone."
            )
            _loadPaperEntities()
        } catch {
            sourcePDFImportError = error.localizedDescription
        }
    }


    private var _selectableChapters: [Inf6CodexChapterOption] {
        let sourceFamily = (context.sourceFamily ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isEshikaku = activeLearningDomainID == Inf6LearningDomain.eQualification.id
            || sourceFamily == "jdla_eshikaku"
            || sourceFamily == "eshikaku"
            || (context.chapterID?.hasPrefix("e_") ?? false)
        if !context.chapterOptions.isEmpty && !isEshikaku { return context.chapterOptions }
        if isEshikaku,
           let manifest = Inf6LearningFamilyManifestStore.loadAll().first(where: {
               $0.sourceFamily.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "jdla_eshikaku"
           }),
           let versionID = _codexSyllabusStructureVersionID(for: manifest),
           let structure = Inf6MetadataStore.getCodable(
               Inf6KnowledgeDomainStructure.self,
               domain: .syllabus,
               key: "structure:\(manifest.sourceFamily)#\(versionID)"
           ) {
            let canonicalNodes = structure.nodes.compactMap { node -> Inf6CodexChapterOption? in
                guard node.kind != .domain,
                      node.kind != .syllabusVersion,
                      node.kind != .paper else { return nil }
                let title = (Inf6Lang.isJapanese ? node.titleJa : node.titleEn)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !node.nodeID.isEmpty, !title.isEmpty else { return nil }
                return Inf6CodexChapterOption(
                    id: node.nodeID,
                    title: title,
                    paperID: nil,
                    depth: max(0, node.depth)
                )
            }
            if !canonicalNodes.isEmpty { return canonicalNodes }
        }
        if isEshikaku, !hydratedEshikakuOutline.isEmpty {
            return hydratedEshikakuOutline.compactMap { item in
                let title = item.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !item.key.isEmpty, !title.isEmpty else { return nil }
                let componentCount = item.key.split(separator: "_").count
                return Inf6CodexChapterOption(
                    id: item.key,
                    title: title,
                    paperID: nil,
                    depth: max(item.effectiveDepth, componentCount - 2)
                )
            }
        }
        if let cacheURL = try? Inf6Storage.syllabusOutlineCacheURL(),
            let cache = Inf6DiskJSON.load([String: [Inf6SyllabusOutlineItem]].self, from: cacheURL) {
            let sourceCacheMarker: String
            switch sourceFamily {
            case "jdla_eshikaku", "eshikaku":
                sourceCacheMarker = "eshikaku_outline"
            case "jdla_gkentei":
                sourceCacheMarker = "gkentei_outline"
            case "microsoft_ai_102":
                sourceCacheMarker = "microsoft_learn_outline"
            default:
                if isEshikaku {
                    sourceCacheMarker = "eshikaku_outline"
                } else {
                    return []
                }
            }
            var seen = Set<String>()
            let matchingCaches = cache
                .filter { $0.key.lowercased().contains(sourceCacheMarker) }
                .sorted { $0.key < $1.key }
            let cachedItems = matchingCaches.last?.value ?? []
            let cached: [Inf6CodexChapterOption] = cachedItems.compactMap { (item: Inf6SyllabusOutlineItem) -> Inf6CodexChapterOption? in
                let title = item.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !item.key.isEmpty, !title.isEmpty, seen.insert(item.key).inserted else { return nil }
                let storedDepth = item.effectiveDepth
                let pathDepth: Int? = {
                    guard isEshikaku, item.key.hasPrefix("e_") else { return nil }
                    let componentCount = item.key.split(separator: "_").count
                    return max(0, componentCount - 2)
                }()
                return Inf6CodexChapterOption(
                    id: item.key,
                    title: title,
                    paperID: nil,
                    depth: max(storedDepth, pathDepth ?? 0)
                )
            }
            if !cached.isEmpty { return cached }
        }
        return isEshikaku ? [] : context.chapterOptions
    }

    private func _codexSyllabusStructureVersionID(for manifest: Inf6LearningFamilyManifest) -> String? {
        if let info = Inf6SyllabusUpdateChecker.shared.examScheduleInfo(for: "E資格") {
            let versionID = info.preferredKnowledgeStructureID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !versionID.isEmpty { return versionID }
        }
        let manifestVersion = manifest.displayNameJa.trimmingCharacters(in: .whitespacesAndNewlines)
        return manifestVersion.isEmpty ? nil : manifestVersion
    }

    private var _chapterPath: [Inf6CodexChapterOption] {
        guard let chapterID = context.chapterID,
              let currentIndex = _selectableChapters.firstIndex(where: { $0.id == chapterID }) else {
            return []
        }
        var path: [Inf6CodexChapterOption] = []
        for option in _selectableChapters[...currentIndex] {
            while let last = path.last, last.depth >= option.depth {
                path.removeLast()
            }
            path.append(option)
        }
        return path
    }

    private var _visibleSyllabusChapters: [Inf6CodexChapterOption] {
        let chapters = _selectableChapters
        var visible: [Inf6CodexChapterOption] = []
        var ancestors: [(depth: Int, id: String)] = []
        for (index, option) in chapters.enumerated() {
            while let last = ancestors.last, last.depth >= option.depth {
                ancestors.removeLast()
            }
            if ancestors.allSatisfy({ _isSyllabusNodeExpanded($0.id) }) {
                visible.append(option)
            }
            let hasChildren = index + 1 < chapters.count && chapters[index + 1].depth > option.depth
            if hasChildren {
                ancestors.append((depth: option.depth, id: option.id))
            }
        }
        return visible
    }

    private func _syllabusNodeHasChildren(_ nodeID: String) -> Bool {
        guard let index = _selectableChapters.firstIndex(where: { $0.id == nodeID }),
              index + 1 < _selectableChapters.count else { return false }
        return _selectableChapters[index + 1].depth > _selectableChapters[index].depth
    }

    private func _isSyllabusNodeExpanded(_ nodeID: String) -> Bool {
        expandedSyllabusNodeIDs.contains(nodeID)
    }

    private func _toggleSyllabusNode(_ nodeID: String) {
        if expandedSyllabusNodeIDs.contains(nodeID) {
            expandedSyllabusNodeIDs.remove(nodeID)
        } else {
            expandedSyllabusNodeIDs.insert(nodeID)
        }
    }

    private func _chapterSiblings(of option: Inf6CodexChapterOption) -> [Inf6CodexChapterOption] {
        guard let optionIndex = _selectableChapters.firstIndex(where: { $0.id == option.id }) else {
            return []
        }
        guard option.depth > 0 else {
            return _selectableChapters.filter { $0.depth == 0 }
        }
        guard let parent = _selectableChapters[..<optionIndex].last(where: { $0.depth < option.depth }),
              let parentIndex = _selectableChapters.firstIndex(where: { $0.id == parent.id }) else {
            return []
        }
        let following = _selectableChapters.dropFirst(parentIndex + 1)
        let endIndex = following.firstIndex(where: { $0.depth <= parent.depth }) ?? following.endIndex
        return Array(following[..<endIndex]).filter { $0.depth == option.depth }
    }

    private func _directSyllabusChildren(of nodeID: String) -> [Inf6CodexChapterOption] {
        guard let parentIndex = _selectableChapters.firstIndex(where: { $0.id == nodeID }) else {
            return []
        }
        let parentDepth = _selectableChapters[parentIndex].depth
        var children: [Inf6CodexChapterOption] = []
        for node in _selectableChapters.dropFirst(parentIndex + 1) {
            if node.depth <= parentDepth { break }
            if node.depth == parentDepth + 1 { children.append(node) }
        }
        return children
    }

    private func _paperID(forChapterID chapterID: String, sourceFamily: String?) -> String? {
        let family = (sourceFamily ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !family.isEmpty, !chapterID.isEmpty else { return nil }
        let links: [Inf6SyllabusPaperLink] = Inf6MetadataStore
            .listByPrefix(domain: .syllabusPaperLinks, prefix: "\(family)|")
            .compactMap { row in
                guard let data = row.json.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(Inf6SyllabusPaperLink.self, from: data)
            }
            .filter { $0.syllabusNodeID == chapterID }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.paperID < $1.paperID
            }
        if let paperID = links.first?.paperID, !paperID.isEmpty {
            return paperID
        }
        return nil
    }

    private func _selectChapter(_ option: Inf6CodexChapterOption) {
        let sourceFamily = context.sourceFamily
            ?? (activeLearningDomainID == Inf6LearningDomain.eQualification.id ? "jdla_eshikaku" : nil)
        if _syllabusNodeHasChildren(option.id) {
            expandedSyllabusNodeIDs.insert(option.id)
        }
        let resolvedPaperID = _paperID(forChapterID: option.id, sourceFamily: sourceFamily)
        context = Inf6CodexRootContext(
            paperID: resolvedPaperID ?? "",
            paperTitle: resolvedPaperID.flatMap { paperID in
                Inf6CorePaperStore.shared.papers.first(where: { $0.id == paperID })?.titleEn
                    ?? Inf6CorePaperStore.shared.papers.first(where: { $0.id == paperID })?.title
            } ?? option.title,
            sourceFamily: sourceFamily,
            chapterID: option.id,
            chapterTitle: option.title,
            chapterOptions: _selectableChapters,
            evidence: []
        )
        selectedEntityID = nil
        selectedOriginalArtifactID = nil
        entitySourcePaperIDs = [:]
        entitySourcePaperTitles = [:]
        isShowingSyllabusNodeHome = true
        syllabusNodeWorkspaceRoute = .overview
        entities = []
        originalArtifacts = []
        syllabusOverview = nil
        entityLoadError = nil
        Inf6CodexTopContextStore.save(context)
        _loadSyllabusOverview()
        _loadPaperEntities()
        if resolvedPaperID != nil {
            _loadOriginalArtifacts()
        } else {
            originalArtifacts = []
        }
    }

    private func _selectLearningDomain(_ selected: Inf6LearningDomain) {
        activeLearningDomainID = selected.id
        activeLearningDomainName = selected.name
        activeLearningDomainKind = selected.kind
        let sourceFamily: String?
        if selected.id == Inf6LearningDomain.eQualification.id, _hasVerifiedEshikakuSyllabus {
            sourceFamily = "jdla_eshikaku"
        } else {
            sourceFamily = nil
        }
        context = Inf6CodexRootContext(
            paperID: "",
            paperTitle: selected.name,
            sourceFamily: sourceFamily,
            chapterID: nil,
            chapterTitle: nil,
            evidence: []
        )
        selectedEntityID = nil
        selectedOriginalArtifactID = nil
        entitySourcePaperIDs = [:]
        entitySourcePaperTitles = [:]
        isShowingSyllabusNodeHome = false
        syllabusNodeWorkspaceRoute = .overview
        entities = []
        originalArtifacts = []
        collectedNotes = []
        syllabusOverview = nil
        entityLoadError = nil
        Inf6CodexTopContextStore.save(context)
    }

    private func _showSyllabusRoot() {
        let sourceFamily = activeLearningDomainID == Inf6LearningDomain.eQualification.id
            && _hasVerifiedEshikakuSyllabus ? "jdla_eshikaku" : nil
        context = Inf6CodexRootContext(
            paperID: "",
            paperTitle: activeLearningDomainName,
            sourceFamily: sourceFamily,
            chapterID: nil,
            chapterTitle: nil,
            evidence: []
        )
        selectedEntityID = nil
        selectedOriginalArtifactID = nil
        entitySourcePaperIDs = [:]
        entitySourcePaperTitles = [:]
        isShowingSyllabusNodeHome = false
        syllabusNodeWorkspaceRoute = .overview
        entities = []
        originalArtifacts = []
        collectedNotes = []
        syllabusOverview = nil
        entityLoadError = nil
        Inf6CodexTopContextStore.save(context)
    }

    private var _hasVerifiedEshikakuSyllabus: Bool {
        guard let root = Inf6EntityImageLocation.resolvedURL() else { return false }
        do {
            let workspace = try WorkspaceStore(root: root)
            return try SyllabusRepository(root: workspace).current(domain: "E資格")?.verified == true
        } catch {
            return false
        }
    }

    private func _paperMenuTitle(_ paper: Inf6CorePaper) -> String {
        let title = paper.titleEn ?? paper.title
        if let year = paper.year, year > 0 { return "\(year) — \(title)" }
        return title
    }

    private func _selectPaper(_ paper: Inf6CorePaper) {
        let title = paper.titleEn ?? paper.title
        context = Inf6CodexRootContext(
            paperID: paper.id,
            paperTitle: title,
            sourceFamily: _effectiveSyllabusSourceFamily,
            chapterID: context.chapterID,
            chapterTitle: context.chapterTitle,
            chapterOptions: context.chapterOptions,
            evidence: []
        )
        selectedEntityID = nil
        selectedOriginalArtifactID = nil
        entitySourcePaperIDs = [:]
        entitySourcePaperTitles = [:]
        isShowingSyllabusNodeHome = false
        syllabusNodeWorkspaceRoute = .overview
        entities = []
        originalArtifacts = []
        collectedNotes = []
        entityLoadError = nil
        Inf6CodexTopContextStore.save(context)
        _loadPaperEntities()
    }

    private func _codexRouteLabel(_ title: String, systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(14), weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(Inf6CodexDesign.ink.opacity(0.82), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Inf6CodexDesign.cyan.opacity(0.78), lineWidth: 1))
            .contentShape(Rectangle())
            .accessibilityLabel(title)
            .help(title)
    }

    private func _loadPaperEntities() {
        if isShowingSyllabusNodeHome, let nodeID = context.chapterID,
           let sourceFamily = _effectiveSyllabusSourceFamily {
            _loadSyllabusNodeEntities(sourceFamily: sourceFamily, nodeID: nodeID)
            return
        }
        entitySourcePaperIDs = [:]
        entitySourcePaperTitles = [:]
        guard !context.paperID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            entities = []
            collectedNotes = []
            // The root Codex has no paper or syllabus node by design.
            // It is not a missing-paper state and must not surface a node-link error.
            entityLoadError = nil
            return
        }
        var candidateKeys = [paperFolderKey]
        candidateKeys.append(contentsOf: context.evidence.compactMap { evidence in
            evidence.imagePath.split(separator: "/").first.map(String.init)
        })
        // CorePaperStore is the authoritative in-memory snapshot after startup.
        // Looking up the same paper again by metadata key can fail when the
        // persisted record key is an import key rather than the paper ID.
        if let paper = sourcePaper ?? Inf6MetadataStore.getCodable(Inf6CorePaper.self, domain: .papers, key: context.paperID) {
            if let storedKey = Inf6EshikakuDrillPipeline.storedPaperArtifactKey(for: paper) {
                candidateKeys.append(storedKey)
            }
            candidateKeys.append(Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paper.id))
            candidateKeys.append(Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paper.title))
            if let titleEn = paper.titleEn {
                candidateKeys.append(Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: titleEn))
            }
            if let pdfURL = paper.resolvedPDFURL {
                candidateKeys.append(Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: pdfURL.lastPathComponent))
            }
        }
        candidateKeys = Array(Set(candidateKeys.filter { !$0.isEmpty }))
        NSLog("[Inf6Codex] entity lookup paperID=%@ candidates=%@", context.paperID, candidateKeys.sorted().joined(separator: ","))
        let index = candidateKeys
            .filter { !$0.isEmpty }
            .compactMap { Inf6MetadataStore.getCodable(Inf6DocEntityIndex.self, domain: .docEntities, key: $0) }
            .first
        let normalizedCandidates = Set(candidateKeys.map {
            Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: $0)
        }.filter { !$0.isEmpty })
        let indexedRecord = Inf6MetadataStore
            .listAllCodable(Inf6DocEntityIndex.self, domain: .docEntities)
            .first { record in
                let key = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: record.value.pdfKey)
                return normalizedCandidates.contains { candidate in
                    key == candidate || key.hasSuffix("_\(candidate)") || candidate.hasSuffix("_\(key)")
                }
            }?.value
        NSLog("[Inf6Codex] entity lookup result direct=%@ indexed=%@", index == nil ? "no" : "yes", indexedRecord == nil ? "no" : "yes")
        let resolvedIndex = index ?? candidateKeys
            .filter { !$0.isEmpty }
            .compactMap { key -> Inf6DocEntityIndex? in
                let directory = Inf6KnowledgeCardsPaths.rootDirectoryURL()?
                    .appendingPathComponent(key, isDirectory: true)
                guard let directory,
                      let files = try? FileManager.default.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: nil
                      ) else { return nil }
                for file in files where file.pathExtension == "json" && file.lastPathComponent.hasSuffix(".entities.json") {
                    guard let data = try? Data(contentsOf: file),
                          let index = try? JSONDecoder().decode(Inf6DocEntityIndex.self, from: data) else { continue }
                    return index
                }
                return nil
            }
            .first
            ?? indexedRecord
            ?? _loadEntityIndexFromStoredFolders(candidateKeys: candidateKeys)
        guard let index = resolvedIndex else {
            collectedNotes = []
            entityLoadError = Inf6Lang.text("論文の図表数式インデックスを読み込めません。", "The paper's figure, table, and equation index could not be loaded.")
            return
        }
        entities = index.entities.enumerated().sorted {
            if $0.element.pageIndex != $1.element.pageIndex { return $0.element.pageIndex < $1.element.pageIndex }
            return $0.offset < $1.offset
        }.map(\.element)
        _loadCollectedNotes(for: entities, candidateKeys: candidateKeys)
    }

    private func _loadSyllabusNodeEntities(sourceFamily: String, nodeID: String) {
        let rawID = "inf6-explanation:\(sourceFamily):\(nodeID)"
        entities = []
        entitySourcePaperIDs = [:]
        entitySourcePaperTitles = [:]
        entityLoadError = nil
        if Inf6MetadataStore.get(domain: .generatedExplanations, key: rawID) != nil {
            do {
                let library = Inf6LibraryView()
                let loaded = try library._loadNodeExplanationEntities(rawID: rawID)
                entities = loaded
                let sourceID = "node:\(rawID)"
                let title = displayChapterTitle ?? context.chapterTitle ?? nodeID
                entitySourcePaperIDs = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, sourceID) })
                entitySourcePaperTitles = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, title) })
                if selectedEntityID == nil || !loaded.contains(where: { $0.id == selectedEntityID }) {
                    selectedEntityID = loaded.first?.id
                }
                return
            } catch {
                entityLoadError = error.localizedDescription
                selectedEntityID = nil
                return
            }
        }

        selectedEntityID = nil
    }

    private func _loadSyllabusOverview() {
        syllabusOverview = nil
        guard let sourceFamily = context.sourceFamily,
              let chapterID = context.chapterID,
              !sourceFamily.isEmpty,
              !chapterID.isEmpty,
              let cacheURL = try? Inf6Storage.syllabusOutlineCacheURL(),
              let cache = Inf6DiskJSON.load([String: [Inf6SyllabusOutlineItem]].self, from: cacheURL) else {
            return
        }
        let marker: String
        switch sourceFamily.lowercased() {
        case "jdla_eshikaku", "eshikaku": marker = "eshikaku_outline"
        case "jdla_gkentei": marker = "gkentei_outline"
        case "microsoft_ai_102": marker = "microsoft_learn_outline"
        default: return
        }
        syllabusOverview = cache
            .filter { $0.key.lowercased().contains(marker) }
            .sorted { $0.key < $1.key }
            .last?.value
            .first { $0.key == chapterID }
    }

    private func _loadEntityIndexFromStoredFolders(candidateKeys: [String]) -> Inf6DocEntityIndex? {
        guard let root = Inf6KnowledgeCardsPaths.rootDirectoryURL(),
              let folders = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey]
              ) else { return nil }
        let keys = Set(candidateKeys.filter { !$0.isEmpty })
        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let files = try? FileManager.default.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: nil
                  ) else { continue }
            for file in files where file.lastPathComponent.hasSuffix(".entities.json") {
                guard let data = try? Data(contentsOf: file),
                      let index = try? JSONDecoder().decode(Inf6DocEntityIndex.self, from: data) else { continue }
                let aliases = [
                    folder.lastPathComponent,
                    file.deletingPathExtension().deletingPathExtension().lastPathComponent,
                    index.pdfKey
                ].map { Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: $0) }
                if aliases.contains(where: { alias in
                    keys.contains { key in alias == key || alias.hasSuffix("_\(key)") || key.hasSuffix("_\(alias)") }
                }) {
                    return index
                }
            }
        }
        return nil
    }

    private func _loadCollectedNotes(for entities: [Inf6DocEntity], candidateKeys: [String]) {
        var loaded: [Inf6ExtraNote] = []
        var seen = Set<UUID>()
        struct NotesFile: Codable {
            let notesByPage: [Int: [Inf6ExtraNote]]
        }
        for page in Set(entities.map(\.pageIndex)) {
            for key in candidateKeys where !key.isEmpty {
                let storageKey = "\(key):\(page)"
                guard let notes = Inf6MetadataStore.getCodable([Inf6ExtraNote].self, domain: .notes, key: storageKey) else { continue }
                for note in notes where seen.insert(note.id).inserted {
                    loaded.append(note)
                }
            }
        }
        if let root = Inf6KnowledgeCardsPaths.rootDirectoryURL() {
            for key in candidateKeys where !key.isEmpty {
                let folderKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: key)
                let safeKey = key.replacingOccurrences(of: "/", with: "_")
                let url = root.appendingPathComponent(folderKey, isDirectory: true)
                    .appendingPathComponent("\(safeKey).extraNotes.json")
                guard let data = try? Data(contentsOf: url),
                      let file = try? JSONDecoder().decode(NotesFile.self, from: data) else { continue }
                for note in file.notesByPage.values.flatMap({ $0 }) where seen.insert(note.id).inserted {
                    loaded.append(note)
                }
            }
        }
        collectedNotes = loaded
    }

    private func _loadOriginalArtifacts() {
        guard !isShowingSyllabusNodeHome else {
            originalArtifacts = []
            return
        }
        guard let sourceFamily = context.sourceFamily,
              let chapterID = context.chapterID,
              !sourceFamily.isEmpty,
              !chapterID.isEmpty else {
            originalArtifacts = []
            return
        }
        let rawID = "inf6-explanation:\(sourceFamily):\(chapterID)"
        guard let json = Inf6MetadataStore.get(domain: .generatedExplanations, key: rawID),
              let data = json.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = payload["content"] as? [String: Any],
              let sections = content["sections"] as? [[String: Any]] else {
            originalArtifacts = []
            return
        }

        originalArtifacts = sections.enumerated().compactMap { index, section in
            guard let heading = section["heading"] as? String,
                  let body = section["body"] as? String,
                  !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let kind: Inf6CodexOriginalArtifact.Kind?
            if (section["kind"] as? String) == "formula" || heading.localizedCaseInsensitiveContains("formula") || heading.contains("数式") {
                kind = .formula
            } else if (section["kind"] as? String) == "table" || heading.localizedCaseInsensitiveContains("table") || heading.contains("表") {
                kind = .table
            } else {
                kind = nil
            }
            guard let kind else { return nil }
            let artifactID = "\(rawID):\(kind.rawValue):\(index)"
            return Inf6CodexOriginalArtifact(
                id: artifactID,
                kind: kind,
                heading: heading,
                bodyHTML: body,
                sourceID: rawID
            )
        }
        if selectedEntityID == nil, selectedOriginalArtifactID == nil {
            selectedOriginalArtifactID = originalArtifacts.first?.id
        }
    }

    private func _sendChat(context: Inf6CodexRootContext) {
        guard let selected = context.evidence.first(where: { $0.id == selectedEvidenceID }) else { return }
        let question = chatQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        chatMessages.append("Q: \(question)")
        chatQuestion = ""
        isChatting = true
        Task {
            do {
                let prompt = "論文: \(context.paperTitle)\n根拠: \(selected.kind), page \((selected.pageIndex ?? 0) + 1)\n質問: \(question)\n選択した根拠だけを使って回答してください。"
                let answer = try await Inf6LibraryView.askOpenAIText(prompt, lang: "ja")
                chatMessages.append("A: \(answer)")
            } catch {
                chatMessages.append(Inf6Lang.text("回答を取得できませんでした: \(error.localizedDescription)", "Could not get an answer: \(error.localizedDescription)"))
            }
            isChatting = false
        }
    }

    private func _verifyExpression() {
        let value = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var depth = 0
        var previousWasOperator = true
        for character in value {
            if character == "(" { depth += 1; previousWasOperator = true; continue }
            if character == ")" {
                depth -= 1
                if depth < 0 { verificationMessage = Inf6Lang.text("括弧の対応が不正です。", "Parentheses are not balanced."); isVerified = false; return }
                previousWasOperator = false
                continue
            }
            if "=+−×÷∑∂".contains(character) {
                if previousWasOperator && character != "∑" && character != "∂" {
                    verificationMessage = Inf6Lang.text("演算子の位置を確認してください。", "Check the operator order.")
                    isVerified = false
                    return
                }
                previousWasOperator = true
            } else if !character.isWhitespace {
                previousWasOperator = false
            }
        }
        guard depth == 0, !previousWasOperator else {
            verificationMessage = Inf6Lang.text("式の終わりを確認してください。", "Check the end of the expression.")
            isVerified = false
            return
        }
        verificationMessage = Inf6Lang.text("構文を確認しました。", "Expression syntax verified.")
        isVerified = true
    }
}

private struct _CodexEntityThumbnail: View {
    let entity: Inf6DocEntity
    let isSelected: Bool
    @State private var image: UIImage?

    private var gemColor: Color {
        switch entity.kind {
        case .figure:
            return Color(red: 0.00, green: 0.78, blue: 1.00)
        case .table:
            return Color(red: 1.00, green: 0.66, blue: 0.16)
        case .equation:
            return Color(red: 0.93, green: 0.18, blue: 0.72)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                _CodexGemShape()
                    .fill(
                        LinearGradient(
                            colors: [gemColor.opacity(isSelected ? 0.42 : 0.22), gemColor.opacity(0.08), gemColor.opacity(isSelected ? 0.25 : 0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .clipShape(_CodexGemShape())
                }

                _CodexGemFacetArtwork(color: gemColor, isSelected: isSelected)
                _CodexGemFacetLines()
                    .stroke(.white.opacity(isSelected ? 0.82 : 0.58), style: StrokeStyle(lineWidth: 0.65, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1.25, contentMode: .fit)
        .clipped()
        .overlay {
            _CodexGemShape()
                .stroke(isSelected ? gemColor : gemColor.opacity(0.62), lineWidth: isSelected ? 2 : 1.2)
        }
        .shadow(
            color: gemColor.opacity(isSelected ? 0.82 : 0.12),
            radius: isSelected ? 8 : 2
        )
        .task(id: entity.imagePath ?? "") {
            guard let imagePath = entity.imagePath else { return }
            let url = Inf6LibraryView._entityImagesBaseURL().appendingPathComponent(imagePath)
            image = UIImage(contentsOfFile: url.path)
        }
    }
}

private struct _CodexOriginalArtifactThumbnail: View {
    let artifact: Inf6CodexOriginalArtifact
    let isSelected: Bool

    private var gemColor: Color {
        artifact.kind == .formula
            ? Color(red: 0.93, green: 0.18, blue: 0.72)
            : Color(red: 1.00, green: 0.66, blue: 0.16)
    }

    var body: some View {
        ZStack {
            _CodexGemShape()
                .fill(
                    LinearGradient(
                        colors: [gemColor.opacity(isSelected ? 0.42 : 0.22), gemColor.opacity(0.08), gemColor.opacity(isSelected ? 0.25 : 0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            _CodexGemFacetArtwork(color: gemColor, isSelected: isSelected)
            _CodexGemFacetLines()
                .stroke(.white.opacity(isSelected ? 0.82 : 0.58), style: StrokeStyle(lineWidth: 0.65, lineCap: .round, lineJoin: .round))
            Text(artifact.kind == .formula ? "数式" : "表")
                .font(Inf6CodexDesign.section)
                .foregroundStyle(gemColor)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1.25, contentMode: .fit)
        .overlay {
            _CodexGemShape()
                .stroke(isSelected ? gemColor : gemColor.opacity(0.62), lineWidth: isSelected ? 2 : 1.2)
        }
        .shadow(color: gemColor.opacity(isSelected ? 0.82 : 0.12), radius: isSelected ? 8 : 2)
    }
}

private struct _CodexGemFacetArtwork: View {
    let color: Color
    let isSelected: Bool

    var body: some View {
        Canvas { context, size in
            let point: (CGFloat, CGFloat) -> CGPoint = { x, y in
                CGPoint(x: size.width * x, y: size.height * y)
            }
            func facet(_ vertices: [(CGFloat, CGFloat)]) -> Path {
                var path = Path()
                guard let first = vertices.first else { return path }
                path.move(to: point(first.0, first.1))
                for vertex in vertices.dropFirst() {
                    path.addLine(to: point(vertex.0, vertex.1))
                }
                path.closeSubpath()
                return path
            }

            let apex = (CGFloat(0.5), CGFloat(0.06))
            let leftShoulder = (CGFloat(0.04), CGFloat(0.38))
            let rightShoulder = (CGFloat(0.96), CGFloat(0.38))
            let leftGirdle = (CGFloat(0.14), CGFloat(0.58))
            let centerGirdle = (CGFloat(0.5), CGFloat(0.58))
            let rightGirdle = (CGFloat(0.86), CGFloat(0.58))
            let tip = (CGFloat(0.5), CGFloat(0.96))

            context.fill(facet([apex, leftShoulder, centerGirdle]), with: .color(.white.opacity(isSelected ? 0.70 : 0.48)))
            context.fill(facet([apex, centerGirdle, rightShoulder]), with: .color(color.opacity(isSelected ? 0.92 : 0.76)))
            context.fill(facet([leftShoulder, leftGirdle, centerGirdle]), with: .color(color.opacity(isSelected ? 0.74 : 0.54)))
            context.fill(facet([centerGirdle, rightGirdle, rightShoulder]), with: .color(.black.opacity(isSelected ? 0.34 : 0.46)))
            context.fill(facet([leftGirdle, tip, centerGirdle]), with: .color(.black.opacity(isSelected ? 0.27 : 0.38)))
            context.fill(facet([centerGirdle, tip, rightGirdle]), with: .color(color.opacity(isSelected ? 0.96 : 0.78)))
        }
        .clipShape(_CodexGemShape())
        .allowsHitTesting(false)
    }
}

private struct _CodexGemShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.27, y: rect.minY + rect.height * 0.06))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.73, y: rect.minY + rect.height * 0.06))
            path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.04, y: rect.minY + rect.height * 0.38))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.86, y: rect.minY + rect.height * 0.58))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.04))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.14, y: rect.minY + rect.height * 0.58))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.04, y: rect.minY + rect.height * 0.38))
            path.closeSubpath()
        }
    }
}

private struct _CodexGemFacetLines: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            let topLeft = CGPoint(x: rect.minX + rect.width * 0.27, y: rect.minY + rect.height * 0.06)
            let topRight = CGPoint(x: rect.minX + rect.width * 0.73, y: rect.minY + rect.height * 0.06)
            let shoulderLeft = CGPoint(x: rect.minX + rect.width * 0.04, y: rect.minY + rect.height * 0.38)
            let shoulderRight = CGPoint(x: rect.maxX - rect.width * 0.04, y: rect.minY + rect.height * 0.38)
            let girdleLeft = CGPoint(x: rect.minX + rect.width * 0.14, y: rect.minY + rect.height * 0.58)
            let girdleRight = CGPoint(x: rect.minX + rect.width * 0.86, y: rect.minY + rect.height * 0.58)
            let girdleCenter = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.58)
            let tip = CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.04)
            path.move(to: shoulderLeft); path.addLine(to: topLeft); path.addLine(to: girdleCenter)
            path.addLine(to: topRight); path.addLine(to: shoulderRight)
            path.move(to: girdleLeft); path.addLine(to: girdleRight)
            path.move(to: girdleLeft); path.addLine(to: tip); path.addLine(to: girdleRight)
        }
    }
}

private struct _FormulaOriginalArtifactDetail: View {
    let artifact: Inf6CodexOriginalArtifact
    let paperTitle: String
    @Binding var explanationFontSize: CGFloat

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {
                Text(artifact.kind == .formula ? "数式" : "表")
                    .font(Inf6CodexDesign.section)
                    .foregroundStyle(artifact.kind == .formula ? Inf6CodexDesign.magenta : Color.orange)
                Text(artifact.heading)
                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(17), weight: .semibold))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                Text("オリジナル解説: \(paperTitle)")
                    .font(Inf6CodexDesign.technical)
                    .foregroundStyle(.white.opacity(0.80))
                    .textSelection(.enabled)
                Inf6CodexHTMLFragmentView(
                    html: artifact.bodyHTML,
                    fontSize: explanationFontSize
                )
                .frame(minHeight: 220)
            }
            .padding(18)
        }
        .inf6CodexPanel(radius: 12)
        .padding(14)
    }
}

#if canImport(WebKit)
private struct Inf6CodexHTMLFragmentView: UIViewRepresentable {
    let html: String
    let fontSize: CGFloat
    var textColor: String = "white"

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.showsVerticalScrollIndicator = false
        view.scrollView.showsHorizontalScrollIndicator = false
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let document = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        body { background: transparent; color: \(textColor); font-family: -apple-system; font-size: \(fontSize)px; line-height: 1.55; margin: 0; }
        table { border-collapse: collapse; width: 100%; } th, td { border: 1px solid rgba(0,220,255,.55); padding: 7px; text-align: left; }
        .formula { overflow-x: auto; padding: 12px; border: 1px solid rgba(230,40,180,.65); border-radius: 8px; }
        </style></head><body>\(html)</body></html>
        """
        view.loadHTMLString(document, baseURL: nil)
    }
}

private enum InlineMathMLEditCommand: String {
    case moveLeft = "left"
    case moveRight = "right"
    case deleteBackward = "backspace"
    case deleteForward = "deleteForward"
}

#if canImport(WebKit)
private struct Inf6EditableMathMLView: UIViewRepresentable {
    let token: String
    let mathML: String
    let editCommandID: Int
    let editCommand: InlineMathMLEditCommand?
    let onChange: (String) -> Bool
    let onFocusChange: (Bool) -> Void
    let onCommandFailure: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(token: token, onChange: onChange, onFocusChange: onFocusChange, onCommandFailure: onCommandFailure)
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "mathMLChanged")
        controller.add(context.coordinator, name: "mathMLFocus")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = true
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.onFocusChange = onFocusChange
        context.coordinator.onCommandFailure = onCommandFailure
        if context.coordinator.lastEditCommandID != editCommandID,
           let editCommand {
            context.coordinator.lastEditCommandID = editCommandID
            context.coordinator.pendingEditCommands.append(editCommand)
        }
        guard context.coordinator.loadedMathML != mathML else {
            context.coordinator.applyPendingEditCommands(in: view)
            return
        }
        guard (try? MathMLValidator().validate(mathML)) != nil else { return }
        context.coordinator.isEditorLoaded = false
        context.coordinator.loadedMathML = mathML
        let mathMLBase64 = Data(mathML.utf8).base64EncodedString()
        view.loadHTMLString("""
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;background:transparent;color:white;font:19px -apple-system;white-space:normal;overflow-wrap:anywhere}#math{min-height:100%;outline:none;white-space:normal;overflow-wrap:anywhere;caret-color:#00dcff}#math math{display:inline-block;max-width:100%;white-space:normal;color:white;user-select:text;-webkit-user-select:text}</style>
        </head><body><div id="math" contenteditable="true" tabindex="0" autocapitalize="off" spellcheck="false"></div>
        <script>
        const editor=document.getElementById('math');
        const mathNS='http://www.w3.org/1998/Math/MathML';
        const leafNames=new Set(['mi','mn','mo','mtext']);
        const rowNames=new Set(['math','mrow','mstyle','mpadded','mtd']);
        let savedMathRange=null;
        const mathRoot=()=>editor.querySelector('math');
        const selection=()=>window.getSelection();
        function saveMathSelection(){
          const current=selection();
          if(!current?.rangeCount)return;
          const range=current.getRangeAt(0),root=mathRoot();
          if(root&&root.contains(range.startContainer)&&root.contains(range.endContainer))savedMathRange=range.cloneRange();
        }
        function restoreMathSelection(){
          const current=selection(),root=mathRoot();
          if(!current||!root)return false;
          if(current.rangeCount&&root.contains(current.anchorNode))return true;
          if(!savedMathRange||!root.contains(savedMathRange.startContainer)||!root.contains(savedMathRange.endContainer))return false;
          current.removeAllRanges();current.addRange(savedMathRange);return true;
        }
        function activeLeaf(node){
          let element=node&&node.nodeType===Node.TEXT_NODE?node.parentElement:node;
          while(element&&element!==editor){if(leafNames.has(element.localName))return element;element=element.parentElement;}
          return null;
        }
        function textNodeFor(leaf){
          for(const child of leaf.childNodes){if(child.nodeType===Node.TEXT_NODE)return child;}
          const text=document.createTextNode('');leaf.appendChild(text);return text;
        }
        function placeCaret(node,offset){
          const range=document.createRange();range.setStart(node,Math.max(0,Math.min(offset,node.length)));range.collapse(true);
          const current=selection();current.removeAllRanges();current.addRange(range);
        }
        function notifyMathChange(inputType){editor.dispatchEvent(new InputEvent('input',{bubbles:true,inputType}));}
        function symbolElement(value){
          if(/^[0-9]$/.test(value))return 'mn';
          if(/^[A-Za-z\\u0370-\\u03FF\\u1F00-\\u1FFF]$/.test(value))return 'mi';
          return 'mo';
        }
        function leaves(root){return Array.from(root.querySelectorAll('mi,mn,mo,mtext'));}
        function nearestLeafAtPoint(x,y){
          const root=mathRoot();if(!root)return null;
          const point=document.caretPositionFromPoint?document.caretPositionFromPoint(x,y):null;
          const range=point?null:(document.caretRangeFromPoint?document.caretRangeFromPoint(x,y):null);
          const anchor=point?.offsetNode||range?.startContainer;
          const direct=activeLeaf(anchor);
          if(direct)return {leaf:direct,offset:point?.offset??range?.startOffset??0,direct:true};
          let best=null,bestDistance=Infinity;
          for(const leaf of leaves(root)){
            const box=leaf.getBoundingClientRect();
            if(box.width===0&&box.height===0)continue;
            const dx=x<box.left?box.left-x:(x>box.right?x-box.right:0);
            const dy=y<box.top?box.top-y:(y>box.bottom?y-box.bottom:0);
            const distance=dx*dx+dy*dy;
            if(distance<bestDistance){
              const text=textNodeFor(leaf),value=text.nodeValue||'';
              best={leaf,offset:x<box.left+box.width/2?0:value.length,direct:false};
              bestDistance=distance;
            }
          }
          return best;
        }
        function replaceLeafRange(range,value){
          const root=mathRoot(),startLeaf=activeLeaf(range.startContainer),endLeaf=activeLeaf(range.endContainer);
          if(!root||!startLeaf||!endLeaf)return false;
          const ordered=leaves(root),startIndex=ordered.indexOf(startLeaf),endIndex=ordered.indexOf(endLeaf);
          if(startIndex<0||endIndex<startIndex)return false;
          const startText=textNodeFor(startLeaf),endText=textNodeFor(endLeaf);
          const startOffset=range.startContainer===startText?range.startOffset:startText.length;
          const endOffset=range.endContainer===endText?range.endOffset:endText.length;
          const startValue=startText.nodeValue||'',endValue=endText.nodeValue||'';
          if(startLeaf===endLeaf){
            startText.nodeValue=startValue.slice(0,startOffset)+value+startValue.slice(range.collapsed?startOffset:endOffset);
            placeCaret(startText,startOffset+value.length);
            return true;
          }
          startText.nodeValue=startValue.slice(0,startOffset)+value;
          for(let index=startIndex+1;index<endIndex;index++)textNodeFor(ordered[index]).nodeValue='';
          endText.nodeValue=endValue.slice(endOffset);
          placeCaret(startText,startOffset+value.length);
          return true;
        }
        function insertSymbol(value){
          const root=mathRoot(),current=selection();if(!root||!current.rangeCount)return false;
          const range=current.getRangeAt(0);if(!root.contains(range.startContainer)||!root.contains(range.endContainer))return false;
          let leaf=activeLeaf(range.startContainer);
          if(leaf){
            return replaceLeafRange(range,value);
          }
          if(!range.collapsed)return false;
          let parent=range.startContainer.nodeType===Node.ELEMENT_NODE?range.startContainer:range.startContainer.parentElement;
          while(parent&&parent!==root&&!rowNames.has(parent.localName))parent=parent.parentElement;
          if(!parent)parent=root;
          const element=document.createElementNS(mathNS,symbolElement(value));element.textContent=value;
          let reference=null;
          if(range.startContainer===parent&&range.startOffset<parent.childNodes.length)reference=parent.childNodes[range.startOffset];
          parent.insertBefore(element,reference);
          placeCaret(textNodeFor(element),value.length);return true;
        }
        function eraseSymbol(backward){
          const root=mathRoot(),current=selection();if(!root||!current.rangeCount)return false;
          const range=current.getRangeAt(0);if(!root.contains(range.startContainer))return false;
          const leaf=activeLeaf(range.startContainer);if(!leaf)return false;
          if(!range.collapsed)return replaceLeafRange(range,'');
          const text=textNodeFor(leaf),value=text.nodeValue||'';
          const start=range.startContainer===text?range.startOffset:value.length;
          if(backward&&start>0){text.nodeValue=value.slice(0,start-1)+value.slice(start);placeCaret(text,start-1);return true;}
          if(!backward&&start<value.length){text.nodeValue=value.slice(0,start)+value.slice(start+1);placeCaret(text,start);return true;}
          const ordered=leaves(root),index=ordered.indexOf(leaf),step=backward?-1:1;
          for(let adjacent=index+step;adjacent>=0&&adjacent<ordered.length;adjacent+=step){
            const adjacentText=textNodeFor(ordered[adjacent]),adjacentValue=adjacentText.nodeValue||'';
            if(!adjacentValue.length)continue;
            if(backward){adjacentText.nodeValue=adjacentValue.slice(0,-1);placeCaret(adjacentText,adjacentValue.length-1);}
            else{adjacentText.nodeValue=adjacentValue.slice(1);placeCaret(adjacentText,0);}
            return true;
          }
          return false;
        }
        function moveCaret(direction){
          const root=mathRoot(),current=selection();if(!root||!current.rangeCount)return;
          const range=current.getRangeAt(0);
          if(!range.collapsed){current.collapse(direction<0?range.startContainer:range.endContainer,direction<0?range.startOffset:range.endOffset);return;}
          const leaf=activeLeaf(range.startContainer);if(!leaf)return;
          const text=textNodeFor(leaf),offset=range.startContainer===text?range.startOffset:text.length;
          if(direction<0&&offset>0){placeCaret(text,offset-1);return;}
          if(direction>0&&offset<text.length){placeCaret(text,offset+1);return;}
          const ordered=leaves(root),index=ordered.indexOf(leaf),step=direction<0?-1:1;
          for(let adjacent=index+step;adjacent>=0&&adjacent<ordered.length;adjacent+=step){
            const adjacentText=textNodeFor(ordered[adjacent]);
            if(!adjacentText.length)continue;
            placeCaret(adjacentText,direction<0?adjacentText.length:0);return;
          }
        }
        window.arcaneApplyEditCommand=command=>{
          restoreMathSelection();editor.focus({preventScroll:true});
          if(command==='left'){moveCaret(-1);return;}
          if(command==='right'){moveCaret(1);return;}
          if(command==='backspace'&&eraseSymbol(true))notifyMathChange('deleteContentBackward');
          if(command==='deleteForward'&&eraseSymbol(false))notifyMathChange('deleteContentForward');
        };
        editor.addEventListener('focus',()=>window.webkit.messageHandlers.mathMLFocus.postMessage(true));
        document.addEventListener('selectionchange',saveMathSelection);
        editor.addEventListener('focusout',saveMathSelection);
        editor.addEventListener('pointerdown',event=>{
          if(!mathRoot()?.contains(event.target))return;
          editor.focus({preventScroll:true});
          const target=nearestLeafAtPoint(event.clientX,event.clientY);
          if(target&&!target.direct){event.preventDefault();placeCaret(textNodeFor(target.leaf),target.offset);}
        },true);
        editor.addEventListener('click',()=>editor.focus({preventScroll:true}));
        editor.addEventListener('beforeinput',event=>{
          const root=mathRoot(),current=selection();if(!root||!current.rangeCount||!root.contains(current.anchorNode))return;
          const insertedText=event.data||(event.dataTransfer&&event.dataTransfer.getData('text/plain'));
          if((event.inputType==='insertText'||event.inputType==='insertFromPaste')&&insertedText){
            event.preventDefault();
            if(insertSymbol(insertedText))notifyMathChange(event.inputType);
            else editor.dispatchEvent(new CustomEvent('mathMLEditRejected',{detail:event.inputType}));
          }
          else if(event.inputType==='deleteContentBackward'||event.inputType==='deleteContentForward'){
            event.preventDefault();if(eraseSymbol(event.inputType==='deleteContentBackward'))notifyMathChange(event.inputType);
          }else if(event.inputType==='insertParagraph'||event.inputType==='insertLineBreak'){
            event.preventDefault();const leaf=activeLeaf(current.anchorNode);if(!leaf)return;
            let row=leaf.parentElement;while(row&&row!==root&&!rowNames.has(row.localName))row=row.parentElement;
            const newline=document.createElementNS(mathNS,'mspace');newline.setAttribute('linebreak','newline');
            if(row&&row!==root){row.insertBefore(newline,leaf.nextSibling);}
            else{
              const parent=leaf.parentElement;if(!parent)return;
              const wrapper=document.createElementNS(mathNS,'mrow');parent.insertBefore(wrapper,leaf);wrapper.appendChild(leaf);wrapper.appendChild(newline);
            }
            notifyMathChange('insertLineBreak');
          }
        });
        editor.addEventListener('keydown',event=>{
          if(event.key!=='ArrowLeft'&&event.key!=='ArrowRight')return;
          const root=mathRoot(),current=selection();if(!root||!current.rangeCount)return;
          const range=current.getRangeAt(0);if(!range.collapsed)return;
          const leaf=activeLeaf(range.startContainer);if(!leaf)return;
          const text=textNodeFor(leaf),offset=range.startContainer===text?range.startOffset:text.length;
          const atEdge=event.key==='ArrowLeft'?offset===0:offset===text.length;
          if(!atEdge)return;
          const ordered=leaves(root),index=ordered.indexOf(leaf),step=event.key==='ArrowLeft'?-1:1;
          for(let adjacent=index+step;adjacent>=0&&adjacent<ordered.length;adjacent+=step){
            event.preventDefault();event.stopPropagation();
            const adjacentText=textNodeFor(ordered[adjacent]);
            placeCaret(adjacentText,event.key==='ArrowLeft'?adjacentText.length:0);
            return;
          }
        });
        editor.addEventListener('input',()=>{
          const root=mathRoot();if(!root)return;
          for(const br of root.querySelectorAll('br')){const space=document.createElementNS(mathNS,'mspace');space.setAttribute('linebreak','newline');br.replaceWith(space);}
          window.webkit.messageHandlers.mathMLChanged.postMessage(new XMLSerializer().serializeToString(root));
        });
        </script>
        <script>document.getElementById('math').innerHTML=new TextDecoder().decode(Uint8Array.from(atob('\(mathMLBase64)'),c=>c.charCodeAt(0)));</script>
        </body></html>
        """, baseURL: nil)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let token: String
        var onChange: (String) -> Bool
        var onFocusChange: (Bool) -> Void
        var onCommandFailure: () -> Void
        var loadedMathML = ""
        var lastEditCommandID = 0
        var isEditorLoaded = false
        var pendingEditCommands: [InlineMathMLEditCommand] = []
        init(token: String, onChange: @escaping (String) -> Bool, onFocusChange: @escaping (Bool) -> Void, onCommandFailure: @escaping () -> Void) {
            self.token = token
            self.onChange = onChange
            self.onFocusChange = onFocusChange
            self.onCommandFailure = onCommandFailure
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "mathMLFocus" { onFocusChange(true); return }
            guard message.name == "mathMLChanged", let value = message.body as? String else { return }
            // Keep the browser's in-progress DOM when it is not yet valid MathML.
            // Advance the model snapshot only after Swift accepted and persisted it;
            // otherwise updateUIView would reload the previous value and erase typing.
            if onChange(value) {
                loadedMathML = value
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isEditorLoaded = false
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isEditorLoaded = true
            applyPendingEditCommands(in: webView)
        }

        func applyPendingEditCommands(in webView: WKWebView) {
            guard isEditorLoaded, !pendingEditCommands.isEmpty else { return }
            let command = pendingEditCommands.removeFirst()
            webView.evaluateJavaScript("window.arcaneApplyEditCommand ? (window.arcaneApplyEditCommand('\(command.rawValue)'), true) : false") { result, error in
                guard error == nil, (result as? Bool) == true else {
                    NSLog("[InlineMathMLEdit] command=\(command.rawValue) failed: \(error?.localizedDescription ?? "editor command handler is unavailable")")
                    self.onCommandFailure()
                    return
                }
                self.applyPendingEditCommands(in: webView)
            }
        }
    }
}

/// One visible editing DOM for both prose and MathML. The serialized chat draft
/// remains the stable token-based storage representation; formula tokens are
/// rendered as editable MathML nodes inside this same contenteditable surface.
private struct Inf6UnifiedChatComposerView: UIViewRepresentable {
    let text: String
    let formulae: [InlineFormulaTextDescriptor]
    let fontSize: CGFloat
    let selectionRange: NSRange
    let clearGeneration: Int
    let editCommandID: Int
    let editCommand: InlineMathMLEditCommand?
    let onDocumentChange: (String, [InlineFormulaTextDescriptor], NSRange) -> Bool
    let onSelectionChange: (NSRange, CGRect?) -> Void
    let onHandwriting: (PKDrawing, NSRange, String, CGSize) -> Void
    let onFocus: () -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onDocumentChange: onDocumentChange,
            onSelectionChange: onSelectionChange,
            onHandwriting: onHandwriting,
            onFocus: onFocus,
            onFailure: onFailure
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "composerChanged")
        controller.add(context.coordinator, name: "composerSelection")
        controller.add(context.coordinator, name: "composerFocus")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = true
        view.scrollView.keyboardDismissMode = .interactive
        context.coordinator.installHandwritingCapture(on: view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onDocumentChange = onDocumentChange
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onHandwriting = onHandwriting
        context.coordinator.onFocus = onFocus
        context.coordinator.onFailure = onFailure
        context.coordinator.latestText = text
        context.coordinator.loadedFormulae = Dictionary(uniqueKeysWithValues: formulae.map { ($0.token, $0) })
        context.coordinator.requestedFontSize = fontSize

        if context.coordinator.isLoaded, context.coordinator.lastFontSize != fontSize {
            context.coordinator.lastFontSize = fontSize
            let cssSize = String(format: "%.1fpx", Double(fontSize))
            view.evaluateJavaScript(
                "document.documentElement.style.setProperty('--composer-font-size', '\(cssSize)');",
                completionHandler: { _, error in
                    if let error { context.coordinator.onFailure(error.localizedDescription) }
                }
            )
        }

        if context.coordinator.lastClearGeneration != clearGeneration {
            context.coordinator.lastClearGeneration = clearGeneration
            context.coordinator.loadedSignature = nil
        }
        if context.coordinator.lastEditCommandID != editCommandID {
            context.coordinator.lastEditCommandID = editCommandID
            if let editCommand { context.coordinator.pendingCommands.append(editCommand) }
        }

        let signature = Self.signature(text: text, formulae: formulae)
        guard context.coordinator.loadedSignature != signature else {
            context.coordinator.applyPendingCommands(in: view)
            return
        }
        do {
            let html = try Self.documentHTML(text: text, formulae: formulae, selectionRange: selectionRange, fontSize: fontSize)
            context.coordinator.loadedSignature = signature
            context.coordinator.lastFontSize = fontSize
            view.loadHTMLString(html, baseURL: nil)
        } catch {
            context.coordinator.onFailure(error.localizedDescription)
        }
    }

    private static func signature(text: String, formulae: [InlineFormulaTextDescriptor]) -> String {
        let records: [[String: String]] = formulae.map { ["token": $0.token, "mathML": $0.mathML] }
        let object: [String: Any] = ["text": text, "formulae": records]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "" }
        return data.base64EncodedString()
    }

    private static func documentHTML(text: String, formulae: [InlineFormulaTextDescriptor], selectionRange: NSRange, fontSize: CGFloat) throws -> String {
        let byToken = Dictionary(uniqueKeysWithValues: formulae.map { ($0.token, $0) })
        let source = text as NSString
        var parts: [[String: String]] = []
        var plain = ""
        var offset = 0
        while offset < source.length {
            let range = source.rangeOfComposedCharacterSequence(at: offset)
            let unit = source.substring(with: range)
            if let formula = byToken[unit] {
                if !plain.isEmpty { parts.append(["text": plain]); plain = "" }
                parts.append(["token": formula.token, "mathMLBase64": Data(formula.mathML.utf8).base64EncodedString()])
            } else {
                plain += unit
            }
            offset = NSMaxRange(range)
        }
        if !plain.isEmpty { parts.append(["text": plain]) }
        let json = try JSONSerialization.data(withJSONObject: parts, options: [.fragmentsAllowed])
        let encoded = json.base64EncodedString()
        let selectionLocation = max(0, selectionRange.location)
        let selectionLength = max(0, selectionRange.length)
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>
        html,body{margin:0;width:100%;height:100%;background:transparent;color:#f5f8ff}
        :root{--composer-font-size:\(fontSize)px}
        body{font:var(--composer-font-size) -apple-system,BlinkMacSystemFont,sans-serif;overflow:auto}
        #composer{box-sizing:border-box;min-height:100%;width:100%;padding:8px;outline:none;white-space:pre-wrap;overflow-wrap:anywhere;caret-color:#00dcff;-webkit-user-select:text;user-select:text}
        .formula{display:inline-block;vertical-align:middle;white-space:normal;max-width:100%;outline:none}
        .formula math{font-size:var(--composer-font-size);color:#f5f8ff;max-width:100%;white-space:normal;caret-color:#00dcff}
        .formula:focus-within{background:rgba(0,220,255,.08);border-radius:3px}
        br{display:block;content:"";margin-top:.2em}
        </style></head><body><div id="composer" contenteditable="false" spellcheck="false" autocapitalize="off"></div>
        <script>
        const editor=document.getElementById('composer');
        const mathNS='http://www.w3.org/1998/Math/MathML';
        const formulaNodes=()=>Array.from(editor.querySelectorAll('[data-formula-token]'));
        const mathLeaves=new Set(['mi','mn','mo','mtext']);
        let activeFormula=null;
        let savedRange=null;
        let lastSelectionKey='';
        function currentSelection(){return window.getSelection();}
        function rememberSelection(){
          const selection=currentSelection();if(!selection||!selection.rangeCount)return;
          const range=selection.getRangeAt(0);if(editor.contains(range.startContainer)&&editor.contains(range.endContainer))savedRange=range.cloneRange();
        }
        function restoreSelection(){
          const selection=currentSelection();if(!selection)return false;
          if(selection.rangeCount&&editor.contains(selection.anchorNode))return true;
          if(!savedRange||!editor.contains(savedRange.startContainer)||!editor.contains(savedRange.endContainer))return false;
          selection.removeAllRanges();selection.addRange(savedRange);return true;
        }
        function formulaFor(node){
          let element=node&&node.nodeType===Node.TEXT_NODE?node.parentElement:node;
          while(element&&element!==editor){if(element.hasAttribute&&element.hasAttribute('data-formula-token'))return element;element=element.parentElement;}
          return null;
        }
        function activeMath(){return activeFormula?.querySelector('math')||null;}
        function activeLeaf(node){let element=node&&node.nodeType===Node.TEXT_NODE?node.parentElement:node;while(element&&element!==activeMath()){if(mathLeaves.has(element.localName))return element;element=element.parentElement;}return null;}
        function leaves(root){return root?Array.from(root.querySelectorAll('mi,mn,mo,mtext')):[];}
        function textNodeFor(leaf){for(const child of leaf.childNodes){if(child.nodeType===Node.TEXT_NODE)return child;}const node=document.createTextNode('');leaf.appendChild(node);return node;}
        function placeCaret(node,offset){const range=document.createRange();range.setStart(node,Math.max(0,Math.min(offset,node.length)));range.collapse(true);const selection=currentSelection();selection.removeAllRanges();selection.addRange(range);rememberSelection();}
        function formulaCaretAtPoint(formula,x,y){
          const math=formula?.querySelector('math');if(!math)return false;
          let range=null;
          if(document.caretRangeFromPoint){const candidate=document.caretRangeFromPoint(x,y);if(candidate&&math.contains(candidate.startContainer))range=candidate;}
          if(!range&&document.caretPositionFromPoint){const point=document.caretPositionFromPoint(x,y);if(point&&math.contains(point.offsetNode)){range=document.createRange();range.setStart(point.offsetNode,point.offset);range.collapse(true);}}
          if(range){const selection=currentSelection();selection.removeAllRanges();selection.addRange(range);return true;}
          const candidates=leaves(math).map(leaf=>{const bounds=leaf.getBoundingClientRect();const dx=x<bounds.left?bounds.left-x:x>bounds.right?x-bounds.right:0;const dy=y<bounds.top?bounds.top-y:y>bounds.bottom?y-bounds.bottom:0;return {leaf,bounds,distance:Math.hypot(dx,dy)};}).filter(item=>item.bounds.width>0&&item.bounds.height>0).sort((a,b)=>a.distance-b.distance);
          const nearest=candidates[0];if(!nearest)return false;
          const node=textNodeFor(nearest.leaf),text=node.nodeValue||'';
          const fraction=nearest.bounds.width>0?Math.max(0,Math.min(1,(x-nearest.bounds.left)/nearest.bounds.width)):0;
          placeCaret(node,Math.round(fraction*text.length));return true;
        }
        function symbolTag(value){if(/^[0-9]$/.test(value))return 'mn';if(/^[A-Za-z\\u0370-\\u03FF\\u1F00-\\u1FFF]$/.test(value))return 'mi';return 'mo';}
        function replaceMathRange(range,value){
          const root=activeMath(),start=activeLeaf(range.startContainer),end=activeLeaf(range.endContainer);if(!root||!start||!end)return false;
          const ordered=leaves(root),a=ordered.indexOf(start),b=ordered.indexOf(end);if(a<0||b<a)return false;
          const first=textNodeFor(start),last=textNodeFor(end);const startOffset=range.startContainer===first?range.startOffset:first.length;const endOffset=range.endContainer===last?range.endOffset:last.length;
          const firstValue=first.nodeValue||'',lastValue=last.nodeValue||'';
          if(start===end){first.nodeValue=firstValue.slice(0,startOffset)+value+firstValue.slice(range.collapsed?startOffset:endOffset);placeCaret(first,startOffset+value.length);return true;}
          first.nodeValue=firstValue.slice(0,startOffset)+value;for(let i=a+1;i<b;i++)textNodeFor(ordered[i]).nodeValue='';last.nodeValue=lastValue.slice(endOffset);placeCaret(first,startOffset+value.length);return true;
        }
        function insertMathText(value){
          const math=activeMath(),selection=currentSelection();if(!math||!selection?.rangeCount)return false;const range=selection.getRangeAt(0);if(!math.contains(range.startContainer)||!math.contains(range.endContainer))return false;
          const leaf=activeLeaf(range.startContainer);if(leaf)return replaceMathRange(range,value);if(!range.collapsed)return false;
          const tag=symbolTag(value),node=document.createElementNS(mathNS,tag);node.textContent=value;let parent=range.startContainer.nodeType===Node.ELEMENT_NODE?range.startContainer:range.startContainer.parentElement;
          while(parent&&parent!==math&&!['math','mrow','mstyle','mpadded','mtd'].includes(parent.localName))parent=parent.parentElement;if(!parent)parent=math;
          const reference=range.startContainer===parent&&range.startOffset<parent.childNodes.length?parent.childNodes[range.startOffset]:null;parent.insertBefore(node,reference);placeCaret(textNodeFor(node),value.length);return true;
        }
        function eraseMath(backward){
          const math=activeMath(),selection=currentSelection();if(!math||!selection?.rangeCount)return false;const range=selection.getRangeAt(0);if(!math.contains(range.startContainer))return false;
          const leaf=activeLeaf(range.startContainer);if(!leaf)return false;if(!range.collapsed)return replaceMathRange(range,'');
          const text=textNodeFor(leaf),value=text.nodeValue||'',offset=range.startContainer===text?range.startOffset:value.length;
          if(backward&&offset>0){text.nodeValue=value.slice(0,offset-1)+value.slice(offset);placeCaret(text,offset-1);return true;}
          if(!backward&&offset<value.length){text.nodeValue=value.slice(0,offset)+value.slice(offset+1);placeCaret(text,offset);return true;}
          const all=leaves(math),index=all.indexOf(leaf),step=backward?-1:1;for(let i=index+step;i>=0&&i<all.length;i+=step){const adjacent=textNodeFor(all[i]),content=adjacent.nodeValue||'';if(!content)continue;if(backward){adjacent.nodeValue=content.slice(0,-1);placeCaret(adjacent,content.length-1);}else{adjacent.nodeValue=content.slice(1);placeCaret(adjacent,0);}return true;}return false;
        }
        function serializedOffset(target,offset){
          let count=0,result=null;
          function visit(node){if(result!==null)return;if(node===target){if(node.nodeType===Node.TEXT_NODE)count+=Math.max(0,Math.min(offset,node.nodeValue.length));else for(let i=0;i<Math.min(offset,node.childNodes.length);i++)count+=serializedLength(node.childNodes[i]);result=count;return;}
            if(node.nodeType===Node.TEXT_NODE){count+=node.nodeValue.length;return;}
            if(node.nodeType===Node.ELEMENT_NODE&&node.hasAttribute('data-formula-token')){if(node.contains(target)){result=count+(offset>0?1:0);return;}count+=1;return;}
            for(const child of node.childNodes)visit(child);
          }
          function serializedLength(node){if(node.nodeType===Node.TEXT_NODE)return node.nodeValue.length;if(node.nodeType!==Node.ELEMENT_NODE)return 0;if(node.hasAttribute('data-formula-token'))return 1;if(node.localName==='br')return 1;let sum=0;for(const child of node.childNodes)sum+=serializedLength(child);return sum;}
          visit(editor);return result===null?count:result;
        }
        function serializedDocument(){
          let text='';const formulae=[];
          function walk(node){if(node.nodeType===Node.TEXT_NODE){text+=node.nodeValue;return;}if(node.nodeType!==Node.ELEMENT_NODE)return;if(node.hasAttribute('data-formula-token')){const token=node.getAttribute('data-formula-token'),math=node.querySelector('math');if(!math)throw new Error('数式のMathML要素がありません');text+=token;formulae.push({token,mathML:new XMLSerializer().serializeToString(math)});return;}if(node.localName==='br'){text+='\\n';return;}for(const child of node.childNodes)walk(child);}
          for(const child of editor.childNodes)walk(child);return {text,formulae};
        }
        function restoreSerializedSelection(location,length){
          function pointAt(target){let remaining=Math.max(0,target),result=null;
            function walk(node,parent,index){if(result)return;if(node.nodeType===Node.TEXT_NODE){if(remaining<=node.nodeValue.length){result={node,offset:remaining};return;}remaining-=node.nodeValue.length;return;}
              if(node.nodeType!==Node.ELEMENT_NODE)return;if(node.hasAttribute('data-formula-token')){if(remaining===0){result={node:parent,offset:index};return;}if(remaining===1){result={node:parent,offset:index+1};return;}remaining-=1;return;}if(node.localName==='br'){if(remaining===0)result={node:parent,offset:index};else if(remaining===1)result={node:parent,offset:index+1};else remaining-=1;return;}for(let i=0;i<node.childNodes.length;i++)walk(node.childNodes[i],node,i);}
            for(let i=0;i<editor.childNodes.length;i++)walk(editor.childNodes[i],editor,i);return result||{node:editor,offset:editor.childNodes.length};}
          const start=pointAt(location),end=length===0?start:pointAt(location+length);
          const range=document.createRange();range.setStart(start.node,start.offset);range.setEnd(end.node,end.offset);const selection=currentSelection();selection.removeAllRanges();selection.addRange(range);rememberSelection();editor.focus({preventScroll:true});
        }
        function notifyChange(){try{const documentValue=serializedDocument();const selection=currentSelection();let range={location:documentValue.text.length,length:0};if(selection?.rangeCount){const value=selection.getRangeAt(0);const start=serializedOffset(value.startContainer,value.startOffset),end=serializedOffset(value.endContainer,value.endOffset);range={location:Math.min(start,end),length:Math.abs(end-start)};}
            window.webkit.messageHandlers.composerChanged.postMessage({text:documentValue.text,formulae:documentValue.formulae,selection:range});}
          catch(error){window.webkit.messageHandlers.composerChanged.postMessage({error:String(error)});}}
        function notifySelection(){const selection=currentSelection();if(!selection?.rangeCount)return;const range=selection.getRangeAt(0);if(!editor.contains(range.startContainer)||!editor.contains(range.endContainer))return;rememberSelection();const doc=serializedDocument(),start=serializedOffset(range.startContainer,range.startOffset),end=serializedOffset(range.endContainer,range.endOffset);const rect=range.getBoundingClientRect();const value={location:Math.min(start,end),length:Math.abs(end-start),x:rect.left,y:rect.top,height:rect.height};const key=JSON.stringify(value);if(key===lastSelectionKey)return;lastSelectionKey=key;window.webkit.messageHandlers.composerSelection.postMessage(value);}
        window.arcaneApplyEditCommand=command=>{
          restoreSelection();editor.focus({preventScroll:true});const selection=currentSelection();if(!selection?.rangeCount)return false;
          const math=formulaFor(selection.anchorNode);if(math){activeFormula=math;if(command==='left'||command==='right'){const direction=command==='left'?'backward':'forward';if(selection.isCollapsed)selection.modify('move',direction,'character');else selection.collapseToStart();return true;}if(command==='backspace'&&eraseMath(true)){notifyChange();return true;}if(command==='deleteForward'&&eraseMath(false)){notifyChange();return true;}return true;}
          const direction=command==='left'||command==='backspace'?'backward':'forward';if(command==='left'||command==='right'){selection.modify('move',direction,'character');rememberSelection();return true;}
          if(selection.isCollapsed){selection.modify('extend',direction,'character');}if(selection.rangeCount){selection.getRangeAt(0).deleteContents();rememberSelection();notifyChange();return true;}return false;
        };
        editor.addEventListener('focus',()=>window.webkit.messageHandlers.composerFocus.postMessage(true));
        document.addEventListener('selectionchange',notifySelection);
        editor.addEventListener('pointerdown',event=>{activeFormula=formulaFor(event.target);editor.focus({preventScroll:true});if(activeFormula){event.preventDefault();formulaCaretAtPoint(activeFormula,event.clientX,event.clientY);rememberSelection();}});
        editor.addEventListener('beforeinput',event=>{
          const selection=currentSelection();if(!selection?.rangeCount||!editor.contains(selection.anchorNode))return;const math=formulaFor(selection.anchorNode);
          if(math){activeFormula=math;if(event.inputType==='insertText'||event.inputType==='insertFromPaste'){const value=event.data||(event.dataTransfer&&event.dataTransfer.getData('text/plain'));if(value){event.preventDefault();if(insertMathText(value))notifyChange();}}else if(event.inputType==='deleteContentBackward'||event.inputType==='deleteContentForward'){event.preventDefault();if(eraseMath(event.inputType==='deleteContentBackward'))notifyChange();}}
          if(event.inputType==='insertParagraph'||event.inputType==='insertLineBreak'){
            event.preventDefault();
            const range=selection.getRangeAt(0),startFormula=formulaFor(range.startContainer),endFormula=formulaFor(range.endContainer);
            const br=document.createElement('br'),after=document.createTextNode('');
            if(startFormula&&startFormula===endFormula){startFormula.after(br,after);}
            else{range.deleteContents();range.insertNode(br);br.after(after);}
            const next=document.createRange();next.setStart(after,0);next.collapse(true);selection.removeAllRanges();selection.addRange(next);notifyChange();
          }
        });
        editor.addEventListener('input',()=>{rememberSelection();notifyChange();});
        editor.addEventListener('paste',event=>{if(formulaFor(currentSelection()?.anchorNode))return;event.preventDefault();const value=event.clipboardData?.getData('text/plain');if(value)document.execCommand('insertText',false,value);});
        editor.addEventListener('keydown',event=>{if(event.key==='ArrowLeft'||event.key==='ArrowRight'){activeFormula=formulaFor(currentSelection()?.anchorNode);return;}if(event.key==='Backspace'||event.key==='Delete'){activeFormula=formulaFor(currentSelection()?.anchorNode);return;}});
        const parts=JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(encoded)'),c=>c.charCodeAt(0))));
        for(const part of parts){if(part.text!==undefined){editor.appendChild(document.createTextNode(part.text));continue;}const wrapper=document.createElement('span');wrapper.className='formula';wrapper.setAttribute('data-formula-token',part.token);wrapper.contentEditable='true';const markup=new TextDecoder().decode(Uint8Array.from(atob(part.mathMLBase64),c=>c.charCodeAt(0)));const template=document.createElement('template');template.innerHTML=markup;wrapper.appendChild(template.content);editor.appendChild(wrapper);}
        editor.contentEditable='true';
        restoreSerializedSelection(\(selectionLocation),\(selectionLength));
        </script></body></html>
        """
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onDocumentChange: (String, [InlineFormulaTextDescriptor], NSRange) -> Bool
        var onSelectionChange: (NSRange, CGRect?) -> Void
        var onHandwriting: (PKDrawing, NSRange, String, CGSize) -> Void
        var onFocus: () -> Void
        var onFailure: (String) -> Void
        var latestText = ""
        var latestSelection = NSRange(location: 0, length: 0)
        var loadedSignature: String?
        var lastClearGeneration = 0
        var lastFontSize: CGFloat = 0
        var requestedFontSize: CGFloat = 0
        var lastEditCommandID = 0
        var isLoaded = false
        var pendingCommands: [InlineMathMLEditCommand] = []
        private var capturedStrokes: [PKStroke] = []
        private var strokeRange = NSRange(location: 0, length: 0)
        private var strokeText = ""
        private var strokeFlushWorkItem: DispatchWorkItem?

        init(onDocumentChange: @escaping (String, [InlineFormulaTextDescriptor], NSRange) -> Bool, onSelectionChange: @escaping (NSRange, CGRect?) -> Void, onHandwriting: @escaping (PKDrawing, NSRange, String, CGSize) -> Void, onFocus: @escaping () -> Void, onFailure: @escaping (String) -> Void) {
            self.onDocumentChange = onDocumentChange
            self.onSelectionChange = onSelectionChange
            self.onHandwriting = onHandwriting
            self.onFocus = onFocus
            self.onFailure = onFailure
        }

        func installHandwritingCapture(on view: WKWebView) {
            let pan = FormulaInkPanGestureRecognizer(target: self, action: #selector(captureFormulaStroke(_:)))
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            pan.maximumNumberOfTouches = 1
            pan.cancelsTouchesInView = true
            pan.delaysTouchesBegan = false
            pan.delaysTouchesEnded = false
            view.addGestureRecognizer(pan)
        }

        @objc private func captureFormulaStroke(_ pan: FormulaInkPanGestureRecognizer) {
            switch pan.state {
            case .began:
                if capturedStrokes.isEmpty {
                    strokeText = latestText
                    strokeRange = latestSelection
                }
                strokeFlushWorkItem?.cancel()
                appendStrokePoints(pan.capturedLocations)
            case .changed:
                appendStrokePoints(pan.drainLocations())
            case .ended:
                appendStrokePoints(pan.drainLocations())
                guard !capturedStrokes.isEmpty else { return }
                let work = DispatchWorkItem { [weak self, weak view = pan.view] in
                    guard let self else { return }
                    guard self.latestText == self.strokeText else {
                        self.onFailure("入力文が変わったため、手書きストロークを認識対象へ渡しませんでした。")
                        self.capturedStrokes.removeAll()
                        return
                    }
                    let drawing = PKDrawing(strokes: self.capturedStrokes)
                    self.capturedStrokes.removeAll()
                    self.onHandwriting(drawing, self.strokeRange, self.strokeText, view?.bounds.size ?? .zero)
                }
                strokeFlushWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
            case .cancelled, .failed:
                strokeFlushWorkItem?.cancel()
                capturedStrokes.removeAll()
            default:
                break
            }
        }

        private func appendStrokePoints(_ locations: [CGPoint]) {
            guard locations.count >= 2 else { return }
            let points = locations.enumerated().map { index, point in
                PKStrokePoint(location: point, timeOffset: Double(index) / 60, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            let path = PKStrokePath(controlPoints: points, creationDate: Date())
            capturedStrokes.append(PKStroke(ink: PKInk(.pen, color: .cyan), path: path))
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "composerFocus" { onFocus(); return }
            guard let value = message.body as? [String: Any] else { return }
            if let error = value["error"] as? String { onFailure(error); return }
            guard let location = value["location"] as? Int else { return }
            let length = value["length"] as? Int ?? 0
            if message.name == "composerSelection" {
                let selection = NSRange(location: location, length: length)
                let documentLength = (latestText as NSString).length
                guard selection.location >= 0,
                      selection.length >= 0,
                      selection.location <= documentLength,
                      NSMaxRange(selection) <= documentLength else {
                    return
                }
                let rect: CGRect?
                if let x = value["x"] as? Double, let y = value["y"] as? Double, let height = value["height"] as? Double {
                    let webRect = CGRect(x: x, y: y, width: 1, height: height)
                    rect = message.webView?.convert(webRect, to: message.webView?.superview)
                } else { rect = nil }
                latestSelection = selection
                onSelectionChange(selection, rect)
                return
            }
            guard message.name == "composerChanged",
                  let text = value["text"] as? String,
                  let records = value["formulae"] as? [[String: String]] else { return }
            let descriptors = records.compactMap { record -> InlineFormulaTextDescriptor? in
                guard let token = record["token"], let mathML = record["mathML"] else { return nil }
                let prior = loadedFormulae[token]
                return InlineFormulaTextDescriptor(token: token, expression: prior?.expression, mathML: mathML)
            }
            guard descriptors.count == records.count else { onFailure("チャット数式のMathML構造を読み取れません。"); return }
            if onDocumentChange(text, descriptors, NSRange(location: location, length: length)) {
                latestText = text
                latestSelection = NSRange(location: location, length: length)
                loadedFormulae = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.token, $0) })
                loadedSignature = Self.signature(text: text, formulae: descriptors)
            }
        }

        var loadedFormulae: [String: InlineFormulaTextDescriptor] = [:]

        private static func signature(text: String, formulae: [InlineFormulaTextDescriptor]) -> String {
            let records = formulae.map { ["token": $0.token, "mathML": $0.mathML] }
            guard let data = try? JSONSerialization.data(withJSONObject: ["text": text, "formulae": records], options: [.sortedKeys]) else { return "" }
            return data.base64EncodedString()
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { isLoaded = false }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            if lastFontSize != requestedFontSize {
                lastFontSize = requestedFontSize
                let cssSize = String(format: "%.1fpx", Double(requestedFontSize))
                webView.evaluateJavaScript("document.documentElement.style.setProperty('--composer-font-size', '\(cssSize)');") { _, error in
                    if let error { self.onFailure(error.localizedDescription) }
                }
            }
            applyPendingCommands(in: webView)
        }
        func applyPendingCommands(in webView: WKWebView) {
            guard isLoaded, !pendingCommands.isEmpty else { return }
            let command = pendingCommands.removeFirst()
            webView.evaluateJavaScript("window.arcaneApplyEditCommand ? (window.arcaneApplyEditCommand('\(command.rawValue)'), true) : false") { result, error in
                guard error == nil, (result as? Bool) == true else {
                    self.onFailure(error?.localizedDescription ?? "編集位置へコマンドを適用できません。")
                    return
                }
                self.applyPendingCommands(in: webView)
            }
        }
    }
}
#endif
#else
private struct Inf6CodexHTMLFragmentView: View {
    let html: String
    let fontSize: CGFloat
    var textColor: String = "white"

    var body: some View {
        Text(html)
            .font(.system(size: fontSize))
            .foregroundStyle(.white)
            .textSelection(.enabled)
    }
}
#endif

private struct HinotoriBrandMark: View {
    var width: CGFloat
    var height: CGFloat

    var body: some View {
        Image("HinotoriMessenger")
            .resizable()
            .scaledToFit()
            .frame(width: width * 2, height: height * 2)
            .frame(width: width, height: height)
            .clipped()
            .accessibilityHidden(true)
    }
}

private struct HinotoriRecognitionSpinner: View {
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.08, to: 0.82)
                .stroke(Inf6CodexDesign.cyan.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(isAnimating ? 360 : 0))
                .animation(.linear(duration: 1.25).repeatForever(autoreverses: false), value: isAnimating)
            HinotoriBrandMark(width: 27, height: 14)
                .scaleEffect(isAnimating ? 1.06 : 0.94)
                .animation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true), value: isAnimating)
        }
        .frame(width: 34, height: 34)
        .accessibilityLabel(Inf6Lang.text("ANEの認識中", "ANE recognition in progress"))
        .onAppear { isAnimating = true }
    }
}

private struct AIResponseIndicator: View {
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.08, to: 0.82)
                .stroke(Inf6CodexDesign.magenta.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(isAnimating ? 360 : 0))
                .animation(.linear(duration: 1.25).repeatForever(autoreverses: false), value: isAnimating)
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Inf6CodexDesign.magenta)
                .scaleEffect(isAnimating ? 1.08 : 0.9)
                .animation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true), value: isAnimating)
        }
        .frame(width: 30, height: 30)
        .accessibilityLabel(Inf6Lang.text("AIの応答中", "AI response in progress"))
        .onAppear { isAnimating = true }
    }
}

#if canImport(UIKit)
private struct InlineFormulaTextDescriptor: Equatable {
    let token: String
    let expression: String?
    let mathML: String
}

private final class InlineMathTextAttachment: NSTextAttachment {
    private(set) var token: String
    private(set) var expression: String?
    private(set) var mathML: String
    private(set) var fontSize: CGFloat

    init(descriptor: InlineFormulaTextDescriptor, fontSize: CGFloat, usesAttachmentView: Bool) {
        token = descriptor.token
        expression = descriptor.expression
        mathML = descriptor.mathML
        self.fontSize = fontSize
        super.init(data: nil, ofType: usesAttachmentView ? "com.arcane.derivation.inline-mathml" : nil)
        fileType = usesAttachmentView ? "com.arcane.derivation.inline-mathml" : nil
        allowsTextAttachmentView = usesAttachmentView
        if !usesAttachmentView {
            image = InlineFormulaTextRendering.clearAttachmentImage
        }
        let measuredCharacterCount = expression?.count
            ?? mathML.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression).count
        let width = min(max(CGFloat(measuredCharacterCount) * fontSize * 0.48, fontSize * 2), 460)
        bounds = CGRect(x: 0, y: -fontSize * 0.22, width: width, height: fontSize * 1.8)
    }

    required init?(coder: NSCoder) {
        token = coder.decodeObject(of: NSString.self, forKey: "token") as? String ?? ""
        expression = coder.decodeObject(of: NSString.self, forKey: "expression") as? String
        mathML = coder.decodeObject(of: NSString.self, forKey: "mathML") as? String ?? ""
        let decodedFontSize = coder.decodeDouble(forKey: "fontSize")
        fontSize = decodedFontSize > 0 ? CGFloat(decodedFontSize) : 18
        super.init(coder: coder)
    }

    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(token as NSString, forKey: "token")
        if let expression { coder.encode(expression as NSString, forKey: "expression") }
        coder.encode(mathML as NSString, forKey: "mathML")
        coder.encode(Double(fontSize), forKey: "fontSize")
    }
}

@MainActor
private final class InlineMathAttachmentHostView: UIView {
    private let mathML: String
    private let fontSize: CGFloat
    private var formulaView: WKWebView?

    init(mathML: String, fontSize: CGFloat, size: CGSize) {
        self.mathML = mathML
        self.fontSize = fontSize
        super.init(frame: CGRect(origin: .zero, size: size))
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, formulaView == nil else { return }

        let webView = WKWebView(frame: bounds)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.isOpaque = false
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.layer.backgroundColor = UIColor.clear.cgColor
        webView.isUserInteractionEnabled = false
        addSubview(webView)
        formulaView = webView

        let document = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{width:100%;height:100%;margin:0;padding:0;background:rgba(0,0,0,0)!important;color:#f5f8ff;overflow:hidden}
        math{font-size:\(fontSize)px;white-space:nowrap}</style></head><body>\(mathML)</body></html>
        """
        webView.loadHTMLString(document, baseURL: nil)
    }
}

@MainActor
private final class InlineMathTextAttachmentViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        guard let attachment = textAttachment as? InlineMathTextAttachment else {
            super.loadView()
            return
        }
        view = InlineMathAttachmentHostView(
            mathML: attachment.mathML,
            fontSize: attachment.fontSize,
            size: attachment.bounds.size
        )
    }
}

private enum InlineFormulaTextRendering {
    static let attachmentType = "com.arcane.derivation.inline-mathml"
    fileprivate static let inlineFormulaTokenAttribute = NSAttributedString.Key("ArcaneDerivationInlineFormulaToken")
    private static let inlineFormulaWidthAttribute = NSAttributedString.Key("ArcaneDerivationInlineFormulaWidth")

    static func registerProvider() {
        NSTextAttachment.registerViewProviderClass(
            InlineMathTextAttachmentViewProvider.self,
            forFileType: attachmentType
        )
    }

    static func attributedString(
        from serializedText: String,
        descriptors: [InlineFormulaTextDescriptor],
        font: UIFont,
        color: UIColor,
        usesAttachmentViews: Bool = true
    ) -> NSAttributedString {
        let byToken = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.token, $0) })
        let source = serializedText as NSString
        let result = NSMutableAttributedString(string: "")
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byCharWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]
        var location = 0
        while location < source.length {
            let range = source.rangeOfComposedCharacterSequence(at: location)
            let value = source.substring(with: range)
            if let descriptor = byToken[value] {
                if usesAttachmentViews {
                    let attachment = InlineMathTextAttachment(
                        descriptor: descriptor,
                        fontSize: font.pointSize,
                        usesAttachmentView: true
                    )
                    result.append(NSAttributedString(attachment: attachment))
                } else {
                    let mathText = descriptor.mathML
                        .replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: #"&[^;]+;"#, with: " ", options: .regularExpression)
                    let measuredWidth = (mathText as NSString).size(withAttributes: [.font: font]).width
                    let width = min(max(measuredWidth, font.pointSize * 2), 460)
                    var tokenAttributes = attributes
                    tokenAttributes[.foregroundColor] = UIColor.clear
                    tokenAttributes[.kern] = max(0, width - font.pointSize)
                    tokenAttributes[inlineFormulaTokenAttribute] = descriptor.token
                    tokenAttributes[inlineFormulaWidthAttribute] = width
                    result.append(NSAttributedString(string: "\u{FFFC}", attributes: tokenAttributes))
                }
            } else {
                result.append(NSAttributedString(string: value, attributes: attributes))
            }
            location = NSMaxRange(range)
        }
        return result
    }

    static func inlineFormulaFrames(in textView: UITextView) -> [String: CGRect] {
        let layoutManager = textView.layoutManager
        let textContainer = textView.textContainer
        layoutManager.ensureLayout(for: textContainer)
        let storage = textView.textStorage
        var frames: [String: CGRect] = [:]
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? InlineMathTextAttachment else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += textView.textContainerInset.left - textView.contentOffset.x
            rect.origin.y += textView.textContainerInset.top - textView.contentOffset.y
            frames[attachment.token] = rect
        }
        storage.enumerateAttribute(inlineFormulaTokenAttribute, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let token = value as? String,
                  let width = storage.attribute(inlineFormulaWidthAttribute, at: range.location, effectiveRange: nil) as? CGFloat else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += textView.textContainerInset.left - textView.contentOffset.x
            rect.origin.y += textView.textContainerInset.top - textView.contentOffset.y
            rect.size.width = max(rect.width, width)
            let lineHeight = textView.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
            let mathHeight = max(rect.height, lineHeight * 2.6)
            let proposedY = rect.origin.y + rect.height - mathHeight + lineHeight * 0.5
            // The overlay is drawn over the editor. Clamp its complete MathML
            // box to the editor viewport so tall fractions cannot escape its border.
            rect.origin.y = min(max(0, proposedY), max(0, textView.bounds.height - mathHeight))
            rect.size.height = mathHeight
            frames[token] = rect
        }
        return frames
    }

    fileprivate static let clearAttachmentImage: UIImage = {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { _ in }
    }()

    static func serializedText(from textView: UITextView) -> String {
        let visibleText = textView.text as NSString
        let storage = textView.textStorage
        var output = ""
        var location = 0
        while location < visibleText.length {
            let range = visibleText.rangeOfComposedCharacterSequence(at: location)
            if let token = storage.attribute(inlineFormulaTokenAttribute, at: location, effectiveRange: nil) as? String {
                output += token
            } else if let attachment = storage.attribute(.attachment, at: location, effectiveRange: nil) as? InlineMathTextAttachment {
                output += attachment.token
            } else {
                output += visibleText.substring(with: range)
            }
            location = NSMaxRange(range)
        }
        return output
    }

    static func serializedRange(forVisibleRange range: NSRange, in textView: UITextView) -> NSRange {
        let visibleText = textView.text as NSString
        precondition(range.location != NSNotFound && NSMaxRange(range) <= visibleText.length)
        let start = serializedOffset(forVisibleOffset: range.location, in: textView)
        let end = serializedOffset(forVisibleOffset: NSMaxRange(range), in: textView)
        return NSRange(location: start, length: end - start)
    }

    static func visibleRange(forSerializedRange range: NSRange, in textView: UITextView) -> NSRange {
        let serializedLength = (serializedText(from: textView) as NSString).length
        precondition(range.location != NSNotFound && NSMaxRange(range) <= serializedLength)
        let start = visibleOffset(forSerializedOffset: range.location, in: textView)
        let end = visibleOffset(forSerializedOffset: NSMaxRange(range), in: textView)
        return NSRange(location: start, length: end - start)
    }

    private static func serializedOffset(forVisibleOffset offset: Int, in textView: UITextView) -> Int {
        let visibleText = textView.text as NSString
        let storage = textView.textStorage
        var visiblePosition = 0
        var serializedPosition = 0
        while visiblePosition < visibleText.length {
            if offset == visiblePosition { return serializedPosition }
            let visibleUnit = visibleText.rangeOfComposedCharacterSequence(at: visiblePosition)
            let attachment = storage.attribute(.attachment, at: visiblePosition, effectiveRange: nil) as? InlineMathTextAttachment
            let inlineToken = storage.attribute(inlineFormulaTokenAttribute, at: visiblePosition, effectiveRange: nil) as? String
            let serializedUnit = inlineToken ?? attachment?.token ?? visibleText.substring(with: visibleUnit)
            let unitLength = (serializedUnit as NSString).length
            let visibleEnd = NSMaxRange(visibleUnit)
            if offset < visibleEnd {
                if attachment != nil || inlineToken != nil {
                    return offset - visiblePosition < visibleUnit.length ? serializedPosition : serializedPosition + unitLength
                }
                return serializedPosition + min(offset - visiblePosition, unitLength)
            }
            visiblePosition = visibleEnd
            serializedPosition += unitLength
        }
        return serializedPosition
    }

    private static func visibleOffset(forSerializedOffset offset: Int, in textView: UITextView) -> Int {
        let visibleText = textView.text as NSString
        let storage = textView.textStorage
        var visiblePosition = 0
        var serializedPosition = 0
        while visiblePosition < visibleText.length {
            if offset == serializedPosition { return visiblePosition }
            let visibleUnit = visibleText.rangeOfComposedCharacterSequence(at: visiblePosition)
            let attachment = storage.attribute(.attachment, at: visiblePosition, effectiveRange: nil) as? InlineMathTextAttachment
            let inlineToken = storage.attribute(inlineFormulaTokenAttribute, at: visiblePosition, effectiveRange: nil) as? String
            let serializedUnit = inlineToken ?? attachment?.token ?? visibleText.substring(with: visibleUnit)
            let unitLength = (serializedUnit as NSString).length
            let serializedEnd = serializedPosition + unitLength
            if offset < serializedEnd {
                if attachment != nil || inlineToken != nil {
                    return offset - serializedPosition < unitLength ? visiblePosition : NSMaxRange(visibleUnit)
                }
                return visiblePosition + min(offset - serializedPosition, visibleUnit.length)
            }
            visiblePosition = NSMaxRange(visibleUnit)
            serializedPosition = serializedEnd
        }
        return visiblePosition
    }
}

private struct Inf6ChatTextInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var clearGeneration: Int
    @Binding var selectionRange: NSRange
    @Binding var caretRect: CGRect?
    var inlineFormulae: [InlineFormulaTextDescriptor]
    var onHandwriting: (PKDrawing, NSRange, String, CGSize) -> Void
    var onInlineFormulaFrames: ([String: CGRect]) -> Void
    var onBeginEditing: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            selectionRange: $selectionRange,
            caretRect: $caretRect,
            onBeginEditing: onBeginEditing,
            onInlineFormulaFrames: onInlineFormulaFrames
        )
    }

    func makeUIView(context: Context) -> PencilSafeTextView {
        let view = PencilSafeTextView(usesCustomInk: true)
        view.delegate = context.coordinator
        view.onHandwriting = onHandwriting
        view.onInlineFormulaLayout = { [weak view, weak coordinator = context.coordinator] in
            guard let view else { return }
            coordinator?.reportInlineFormulaFrames(from: view)
        }
        view.backgroundColor = .clear
        view.textColor = .white
        view.tintColor = .cyan
        view.textContentType = .none
        view.font = UIFont.preferredFont(forTextStyle: .body)
        InlineFormulaTextRendering.registerProvider()
        view.attributedText = InlineFormulaTextRendering.attributedString(
            from: text,
            descriptors: inlineFormulae,
            font: view.font ?? UIFont.preferredFont(forTextStyle: .body),
            color: .white,
            usesAttachmentViews: false
        )
        context.coordinator.lastInlineFormulae = inlineFormulae
        view.selectedRange = InlineFormulaTextRendering.visibleRange(forSerializedRange: selectionRange, in: view)
        context.coordinator.reportCaretRect(from: view)
        view.isScrollEnabled = true
        view.textContainer.widthTracksTextView = true
        context.coordinator.reportInlineFormulaFrames(from: view)
        view.alwaysBounceVertical = false
        view.alwaysBounceHorizontal = false
        view.keyboardDismissMode = .interactive
        view.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        view.interactions
            .compactMap { $0 as? UIScribbleInteraction }
            .forEach { view.removeInteraction($0) }
        context.coordinator.lastClearGeneration = clearGeneration
        return view
    }

    func updateUIView(_ view: PencilSafeTextView, context: Context) {
        view.onHandwriting = onHandwriting
        context.coordinator.onBeginEditing = onBeginEditing
        view.onInlineFormulaLayout = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.reportInlineFormulaFrames(from: view)
        }
        if context.coordinator.lastClearGeneration != clearGeneration {
            context.coordinator.lastClearGeneration = clearGeneration
            context.coordinator.isInternalUpdate = true
            view.clearHandwriting()
            view.text = ""
            view.selectedRange = NSRange(location: 0, length: 0)
            view.undoManager?.removeAllActions()
            context.coordinator.isInternalUpdate = false
        }
        if InlineFormulaTextRendering.serializedText(from: view) != text
            || context.coordinator.lastInlineFormulae != inlineFormulae {
            view.cancelHandwritingCapture()
            let serializedSelection = InlineFormulaTextRendering.serializedRange(forVisibleRange: view.selectedRange, in: view)
            context.coordinator.isInternalUpdate = true
            view.attributedText = InlineFormulaTextRendering.attributedString(
                from: text,
                descriptors: inlineFormulae,
                font: view.font ?? UIFont.preferredFont(forTextStyle: .body),
                color: .white,
                usesAttachmentViews: false
            )
            context.coordinator.lastInlineFormulae = inlineFormulae
            view.selectedRange = InlineFormulaTextRendering.visibleRange(forSerializedRange: serializedSelection, in: view)
            context.coordinator.isInternalUpdate = false
            context.coordinator.reportCaretRect(from: view)
            context.coordinator.reportInlineFormulaFrames(from: view)
        }
        let visibleSelection = InlineFormulaTextRendering.visibleRange(forSerializedRange: selectionRange, in: view)
        if view.selectedRange != visibleSelection {
            context.coordinator.isInternalUpdate = true
            view.selectedRange = visibleSelection
            context.coordinator.isInternalUpdate = false
            context.coordinator.reportCaretRect(from: view)
            context.coordinator.reportInlineFormulaFrames(from: view)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        @Binding var selectionRange: NSRange
        @Binding var caretRect: CGRect?
        var isInternalUpdate = false
        var lastClearGeneration: Int = 0
        var lastInlineFormulae: [InlineFormulaTextDescriptor] = []
        var onBeginEditing: () -> Void
        var onInlineFormulaFrames: ([String: CGRect]) -> Void
        private var lastInlineFormulaFrames: [String: CGRect] = [:]

        init(
            text: Binding<String>,
            selectionRange: Binding<NSRange>,
            caretRect: Binding<CGRect?>,
            onBeginEditing: @escaping () -> Void,
            onInlineFormulaFrames: @escaping ([String: CGRect]) -> Void
        ) {
            _text = text
            _selectionRange = selectionRange
            _caretRect = caretRect
            self.onBeginEditing = onBeginEditing
            self.onInlineFormulaFrames = onInlineFormulaFrames
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            onBeginEditing()
        }

        func textViewDidChange(_ textView: UITextView) {
            (textView as? PencilSafeTextView)?.cancelHandwritingCapture()
            text = InlineFormulaTextRendering.serializedText(from: textView)
            selectionRange = InlineFormulaTextRendering.serializedRange(forVisibleRange: textView.selectedRange, in: textView)
            reportCaretRect(from: textView)
            reportInlineFormulaFrames(from: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isInternalUpdate else { return }
            (textView as? PencilSafeTextView)?.cancelHandwritingCapture()
            selectionRange = InlineFormulaTextRendering.serializedRange(forVisibleRange: textView.selectedRange, in: textView)
            reportCaretRect(from: textView)
            reportInlineFormulaFrames(from: textView)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let textView = scrollView as? UITextView else { return }
            reportInlineFormulaFrames(from: textView)
        }

        func reportInlineFormulaFrames(from textView: UITextView) {
            let frames = InlineFormulaTextRendering.inlineFormulaFrames(in: textView)
            guard frames != lastInlineFormulaFrames else { return }
            lastInlineFormulaFrames = frames
            DispatchQueue.main.async { [weak self] in
                self?.onInlineFormulaFrames(frames)
            }
        }

        func reportCaretRect(from textView: UITextView) {
            let location = NSMaxRange(textView.selectedRange)
            guard let position = textView.position(from: textView.beginningOfDocument, offset: location) else {
                caretRect = nil
                return
            }
            let rect = textView.caretRect(for: position)
            caretRect = rect.isNull || rect.isInfinite ? nil : rect
        }

    }
}

private struct Inf6ChatMessageText: UIViewRepresentable {
    let text: String
    let inlineFormulae: [InlineFormulaTextDescriptor]
    let fontSize: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.isUserInteractionEnabled = true
        context.coordinator.load(text: text, formulae: inlineFormulae, fontSize: fontSize, in: view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.load(text: text, formulae: inlineFormulae, fontSize: fontSize, in: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: WKWebView, context: Context) -> CGSize? {
        let width = max(proposal.width ?? 320, 1)
        let descriptors = Dictionary(uniqueKeysWithValues: inlineFormulae.map { ($0.token, $0) })
        let source = text as NSString
        var readableText = ""
        var offset = 0
        var containsFormula = false
        while offset < source.length {
            let range = source.rangeOfComposedCharacterSequence(at: offset)
            let unit = source.substring(with: range)
            if let formula = descriptors[unit] {
                containsFormula = true
                readableText += formula.expression ?? "∑"
            } else {
                readableText += unit
            }
            offset = NSMaxRange(range)
        }
        let font = UIFont.systemFont(ofSize: fontSize)
        let measured = (readableText as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        let formulaHeight = containsFormula ? font.lineHeight * 2.0 : font.lineHeight * 1.4
        return CGSize(width: width, height: ceil(max(measured.height, formulaHeight)))
    }

    final class Coordinator {
        private var loadedSignature: String?

        func load(text: String, formulae: [InlineFormulaTextDescriptor], fontSize: CGFloat, in view: WKWebView) {
            let signature = Self.signature(text: text, formulae: formulae, fontSize: fontSize)
            guard loadedSignature != signature else { return }
            loadedSignature = signature
            view.loadHTMLString(Self.document(text: text, formulae: formulae, fontSize: fontSize), baseURL: nil)
        }

        private static func signature(text: String, formulae: [InlineFormulaTextDescriptor], fontSize: CGFloat) -> String {
            let records = formulae.map { ["token": $0.token, "mathML": $0.mathML] }
            let value: [String: Any] = ["text": text, "formulae": records, "fontSize": fontSize]
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "" }
            return data.base64EncodedString()
        }

        private static func document(text: String, formulae: [InlineFormulaTextDescriptor], fontSize: CGFloat) -> String {
            let byToken = Dictionary(uniqueKeysWithValues: formulae.map { ($0.token, $0) })
            let source = text as NSString
            var body = ""
            var offset = 0
            while offset < source.length {
                let range = source.rangeOfComposedCharacterSequence(at: offset)
                let unit = source.substring(with: range)
                if let formula = byToken[unit] {
                    body += "<span class=\"math\">\(formula.mathML)</span>"
                } else {
                    body += escapeHTML(unit)
                }
                offset = NSMaxRange(range)
            }
            return """
            <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
            <style>
            html,body{margin:0;padding:0;width:100%;background:transparent;color:#f5f8ff}
            body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;font-size:\(fontSize)px;line-height:1.45;white-space:pre-wrap;overflow-wrap:anywhere}
            .math{display:inline-block;vertical-align:middle;white-space:nowrap;max-width:100%}
            math{font-size:\(fontSize)px;color:#f5f8ff;white-space:nowrap}
            </style></head><body>\(body)</body></html>
            """
        }

        private static func escapeHTML(_ value: String) -> String {
            value
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
    }
}

private final class PencilSafeTextView: UITextView {
    private let usesCustomInk: Bool
    private let inkLayer = CAShapeLayer()
    private var transientInk = UIBezierPath()
    private var capturedStrokes: [PKStroke] = []
    private var currentPath: UIBezierPath?
    private var currentStrokeStartedAt: Date?
    private var insertionRange = NSRange(location: 0, length: 0)
    private var originalText = ""
    private var strokeFlushWorkItem: DispatchWorkItem?
    var onHandwriting: ((PKDrawing, NSRange, String, CGSize) -> Void)?
    var onInlineFormulaLayout: (() -> Void)?
    private var inlineFormulaLayoutUpdateQueued = false

    init(usesCustomInk: Bool) {
        self.usesCustomInk = usesCustomInk
        super.init(frame: .zero, textContainer: nil)
        if usesCustomInk { installMouseHandwriting() }
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        self.usesCustomInk = true
        super.init(frame: frame, textContainer: textContainer)
        installMouseHandwriting()
    }

    required init?(coder: NSCoder) {
        self.usesCustomInk = true
        super.init(coder: coder)
        installMouseHandwriting()
    }

    private func installMouseHandwriting() {
        inkLayer.strokeColor = UIColor.cyan.cgColor
        inkLayer.fillColor = UIColor.clear.cgColor
        inkLayer.lineWidth = 2
        inkLayer.lineCap = .round
        inkLayer.lineJoin = .round
        layer.addSublayer(inkLayer)
        let pan = FormulaInkPanGestureRecognizer(target: self, action: #selector(captureFormulaStroke(_:)))
        pan.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ]
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = true
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        addGestureRecognizer(pan)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        inkLayer.frame = bounds
        guard !inlineFormulaLayoutUpdateQueued else { return }
        inlineFormulaLayoutUpdateQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.inlineFormulaLayoutUpdateQueued = false
            self.onInlineFormulaLayout?()
        }
    }

    @objc private func captureFormulaStroke(_ pan: FormulaInkPanGestureRecognizer) {
        switch pan.state {
        case .began:
            guard let first = pan.capturedLocations.first else { return }
            strokeFlushWorkItem?.cancel()
            if capturedStrokes.isEmpty {
                originalText = InlineFormulaTextRendering.serializedText(from: self)
                if selectedRange.length > 0 {
                    insertionRange = InlineFormulaTextRendering.serializedRange(forVisibleRange: selectedRange, in: self)
                } else if let position = closestPosition(to: first) {
                    let offset = self.offset(from: beginningOfDocument, to: position)
                    insertionRange = InlineFormulaTextRendering.serializedRange(
                        forVisibleRange: NSRange(location: offset, length: 0),
                        in: self
                    )
                } else {
                    insertionRange = InlineFormulaTextRendering.serializedRange(forVisibleRange: selectedRange, in: self)
                }
            }
            currentStrokeStartedAt = Date()
            currentPath = UIBezierPath()
            currentPath?.move(to: first)
            transientInk.move(to: first)
            append(pan.capturedLocations.dropFirst())
        case .changed:
            append(pan.drainLocations())
        case .ended:
            append(pan.drainLocations())
            if let path = currentPath, let startedAt = currentStrokeStartedAt {
                let points = Self.strokePoints(from: path)
                if points.count >= 2 {
                    let strokePath = PKStrokePath(controlPoints: points, creationDate: startedAt)
                    capturedStrokes.append(PKStroke(ink: PKInk(.pen, color: .cyan), path: strokePath))
                }
            }
            currentPath = nil
            currentStrokeStartedAt = nil
            scheduleRecognitionDelivery()
        default: break
        }
        inkLayer.path = transientInk.cgPath
    }

    @objc func clearHandwriting() {
        strokeFlushWorkItem?.cancel()
        strokeFlushWorkItem = nil
        capturedStrokes.removeAll()
        currentPath = nil
        currentStrokeStartedAt = nil
        transientInk = UIBezierPath()
        inkLayer.path = nil
    }

    func cancelHandwritingCapture() {
        guard !capturedStrokes.isEmpty || currentPath != nil else { return }
        clearHandwriting()
    }

    private func append<S: Sequence>(_ locations: S) where S.Element == CGPoint {
        for location in locations where bounds.contains(location) {
            if currentPath?.isEmpty == true {
                currentPath?.move(to: location)
                transientInk.move(to: location)
            } else {
                currentPath?.addLine(to: location)
                transientInk.addLine(to: location)
            }
        }
    }

    private func scheduleRecognitionDelivery() {
        strokeFlushWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.capturedStrokes.isEmpty else { return }
            guard InlineFormulaTextRendering.serializedText(from: self) == self.originalText else {
                NSLog("[Inf6ChatTextInput] discarded handwriting because composer text changed")
                self.clearHandwriting()
                return
            }
            let drawing = PKDrawing(strokes: self.capturedStrokes)
            self.onHandwriting?(drawing, self.insertionRange, self.originalText, self.bounds.size)
            self.clearHandwriting()
        }
        strokeFlushWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private static func strokePoints(from path: UIBezierPath) -> [PKStrokePoint] {
        var points: [PKStrokePoint] = []
        path.cgPath.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            let point: CGPoint
            switch element.type {
            case .moveToPoint, .addLineToPoint:
                point = element.points[0]
            case .addQuadCurveToPoint:
                point = element.points[1]
            case .addCurveToPoint:
                point = element.points[2]
            case .closeSubpath:
                return
            @unknown default:
                return
            }
            let timeOffset = points.isEmpty ? 0 : Double(points.count) / 60
            points.append(PKStrokePoint(
                location: point,
                timeOffset: timeOffset,
                size: CGSize(width: 2, height: 2),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            ))
        }
        return points
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            clearHandwriting()
        }
    }
}

private final class FormulaInkPanGestureRecognizer: UIPanGestureRecognizer {
    private(set) var capturedLocations: [CGPoint] = []
    private var lastLocation: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        capturedLocations.removeAll(keepingCapacity: true)
        lastLocation = nil
        collect(touches, event: event)
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        collect(touches, event: event)
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        collect(touches, event: event)
        super.touchesEnded(touches, with: event)
    }

    func drainLocations() -> [CGPoint] {
        let result = capturedLocations
        capturedLocations.removeAll(keepingCapacity: true)
        return result
    }

    private func collect(_ touches: Set<UITouch>, event: UIEvent) {
        for touch in touches {
            let coalesced = event.coalescedTouches(for: touch) ?? [touch]
            for sample in coalesced {
                let point = sample.location(in: view)
                if point != lastLocation {
                    capturedLocations.append(point)
                    lastLocation = point
                }
            }
        }
    }
}

#endif

private struct _FormulaEntityDetail: View {
    private struct InlineFormulaCapture {
        let id: UUID
        let drawingData: Data
        let originalText: String
        let range: NSRange
        let editingMessageIndex: Int?
        let editingMessage: String?
        let entityID: UUID
        let paperID: String
        let chapterID: String?
        let surfaceSize: CGSize
        let priorDrawing: PKDrawing
        let priorSurfaceSize: CGSize
        let priorRecognition: Inf6HandwrittenMathMLResult?
        let priorRecognitionError: String?
        let priorStructureDraft: FormulaStructure?
        let priorStructureScopeStack: [String]
        let priorStructureSelection: [String]
    }

    private struct InlineFormulaReference: Codable, Equatable {
        let token: String
        let expression: String?
        let mathML: String
        let derivationID: String?
        let sourcePartID: String?
    }

    private enum PaperTextDisplayMode: String, CaseIterable {
        case original
        case japanese
    }

    private enum PartDisplayMode: String, CaseIterable {
        case text
        case formula
    }

    private struct FormulaPaletteItem: Identifiable {
        let id: String
        let title: String
        let expression: String
        let systemImage: String

        static let all: [FormulaPaletteItem] = [
            .init(id: "sqrt", title: "ルート", expression: "\\sqrt{x}", systemImage: "checkmark.square"),
            .init(id: "frac", title: "分数", expression: "\\frac{a}{b}", systemImage: "divide"),
            .init(id: "superscript", title: "上付き", expression: "x^2", systemImage: "textformat.superscript"),
            .init(id: "subscript", title: "下付き", expression: "x_i", systemImage: "textformat.subscript"),
            .init(id: "integral", title: "積分", expression: "\\int xdx", systemImage: "integral"),
            .init(id: "summation", title: "総和", expression: "\\sum_{i=1}^{n}x_i", systemImage: "sigma"),
            .init(id: "product", title: "総積", expression: "\\prod_{i=1}^{n}x_i", systemImage: "product"),
            .init(id: "limit", title: "極限", expression: "\\lim_{x=0}f(x)", systemImage: "arrow.down.to.line"),
            .init(id: "matrix", title: "行列", expression: "\\begin{matrix}a&b\\\\c&d\\end{matrix}", systemImage: "tablecells"),
            .init(id: "cases", title: "場合分け", expression: "\\begin{cases}x&x>0\\\\0&x\\le0\\end{cases}", systemImage: "list.number"),
            .init(id: "partial", title: "偏微分", expression: "\\partial f/\\partial x", systemImage: "partial"),
            .init(id: "gradient", title: "勾配", expression: "\\nabla f", systemImage: "gradient"),
            .init(id: "vector", title: "ベクトル", expression: "\\vec{x}", systemImage: "arrow.up.right"),
            .init(id: "hat", title: "ハット", expression: "\\hat{x}", systemImage: "hat.wide"),
            .init(id: "overline", title: "平均・線", expression: "\\overline{x}", systemImage: "macwindow"),
            .init(id: "parentheses", title: "括弧", expression: "\\left(x\\right)", systemImage: "parentheses"),
            .init(id: "absolute", title: "絶対値", expression: "\\left|x\\right|", systemImage: "rectangle"),
            .init(id: "infinity", title: "無限大", expression: "\\infty", systemImage: "infinity"),
            .init(id: "not-equal", title: "不等号", expression: "\\neq", systemImage: "equal.circle"),
            .init(id: "less-equal", title: "以下", expression: "\\le", systemImage: "lessequal"),
            .init(id: "greater-equal", title: "以上", expression: "\\ge", systemImage: "greaterequal"),
            .init(id: "approx", title: "近似", expression: "\\approx", systemImage: "equal.circle.fill"),
            .init(id: "plus-minus", title: "±", expression: "\\pm", systemImage: "plusminus"),
            .init(id: "rightarrow", title: "右矢印", expression: "\\rightarrow", systemImage: "arrow.right"),
            .init(id: "leftrightarrow", title: "両矢印", expression: "\\leftrightarrow", systemImage: "arrow.left.and.right"),
            .init(id: "alpha", title: "α", expression: "\\alpha", systemImage: "a.circle"),
            .init(id: "beta", title: "β", expression: "\\beta", systemImage: "b.circle"),
            .init(id: "pi", title: "π", expression: "\\pi", systemImage: "p.circle"),
            .init(id: "theta", title: "θ", expression: "\\theta", systemImage: "theta"),
            .init(id: "forall", title: "全称", expression: "\\forall", systemImage: "a.circle"),
            .init(id: "exists", title: "存在", expression: "\\exists", systemImage: "e.circle"),
            .init(id: "in", title: "所属", expression: "\\in", systemImage: "circle"),
            .init(id: "subseteq", title: "部分集合", expression: "\\subseteq", systemImage: "square.dashed"),
            .init(id: "union", title: "和集合", expression: "\\cup", systemImage: "plus"),
            .init(id: "intersection", title: "共通集合", expression: "\\cap", systemImage: "xmark"),
            .init(id: "real", title: "実数体", expression: "\\mathbb{R}", systemImage: "r.circle"),
            .init(id: "bold-vector", title: "太字ベクトル", expression: "\\mathbf{x}", systemImage: "bold"),
            .init(id: "dot", title: "ドット", expression: "\\dot{x}", systemImage: "dot.squareroot"),
            .init(id: "tilde", title: "チルダ", expression: "\\tilde{x}", systemImage: "waveform"),
            .init(id: "double-integral", title: "二重積分", expression: "\\iint fdxdy", systemImage: "integral"),
            .init(id: "contour-integral", title: "周回積分", expression: "\\oint fdx", systemImage: "circle.dotted"),
            .init(id: "pmatrix", title: "丸括弧行列", expression: "\\begin{pmatrix}a&b\\\\c&d\\end{pmatrix}", systemImage: "tablecells"),
            .init(id: "bmatrix", title: "角括弧行列", expression: "\\begin{bmatrix}a&b\\\\c&d\\end{bmatrix}", systemImage: "tablecells.fill")
        ]
    }

    let entity: Inf6DocEntity
    let paperID: String
    let chapterID: String?
    let paperTitle: String
    let collectedNotes: [Inf6ExtraNote]
    let origin: DerivationOrigin
    let userDerivationID: UUID?
    let isNodeExplanationItem: Bool
    @State private var image: UIImage?
    @State private var imageZoom: CGFloat = 1
    @Binding var explanationFontSize: CGFloat
    @State private var chatQuestion = ""
    @State private var chatSelectionRange = NSRange(location: 0, length: 0)
    @State private var chatCaretRect: CGRect?
    @State private var chatInlineFormulaFrames: [String: CGRect] = [:]
    @State private var activeInlineFormulaToken: String?
    @State private var inlineMathMLEditCommandID = 0
    @State private var inlineMathMLEditCommand: InlineMathMLEditCommand?
    @State private var chatClearGeneration = 0
    @State private var chatDraftPersistenceTask: Task<Void, Never>?
    @State private var inlineFormulaCapture: InlineFormulaCapture?
    @State private var inlineFormulaProgrammaticTextChange: String?
    @State private var inlineFormulaReferences: [InlineFormulaReference] = []
    @State private var chatMessages: [String] = []
    @State private var loadedChatThreadID: String?
    @State private var editingChatMessageIndex: Int?
    @State private var isGeneratingPythonCode = false
    @State private var pythonCodeGenerationTask: Task<Void, Never>?
    @State private var isChatting = false
    @State private var chatError: String?
    @State private var formulaExpression = ""
    @State private var formulaMathML: String?
    @Binding var selectedCodeFramework: String
    @State private var hoveredPart: Inf6DocEntityPart?
    // Hover is transient; selection is the explicit user choice that remains stable.
    @State private var selectedPart: Inf6DocEntityPart?
    @State private var paperTextDisplayMode: PaperTextDisplayMode = .original
    @State private var partDisplayMode: PartDisplayMode = .text
    @State private var pencilDrawing = PKDrawing()
    @State private var pencilSurfaceSize = CGSize.zero
    @State private var isLoadingSavedDerivation = true
    @State private var pencilRecognition: Inf6HandwrittenMathMLResult?
    @State private var pencilRecognitionError: String?
    @State private var pencilRecognitionRunning = false
    @State private var pencilRecognitionTask: Task<Void, Never>?
    @State private var pencilRecognitionGeneration = 0
    @State private var formulaStructureDraft: FormulaStructure?
    /// Selected direct children of the active expression scope, in user-specified role order.
    @State private var formulaStructureSelection: [String] = []
    @State private var formulaStructureScopeStack: [String] = []
    @State private var pencilRedoDrawing: PKDrawing?
    @State private var selectedFormulaGridCell: Int?
    @State private var gridCenterFraction: CGFloat = 0.44
    @State private var isCandidatePopoverPresented = false
    @State private var isFormulaPalettePresented = false
    @AppStorage(Inf6OpenAIModelResolver.userDefaultsModelKey) private var selectedChatModel = ""
    @AppStorage(Inf6OpenAIModelResolver.availableModelsUserDefaultsKey) private var cachedChatModelsJSON = ""
    @State private var isRefreshingChatModels = false
    @State private var chatModelRefreshError: String?

    init(
        entity: Inf6DocEntity,
        paperID: String,
        chapterID: String?,
        paperTitle: String,
        collectedNotes: [Inf6ExtraNote],
        explanationFontSize: Binding<CGFloat>,
        selectedCodeFramework: Binding<String>,
        isNodeExplanationItem: Bool = false,
        origin: DerivationOrigin = .paperEvidence,
        userDerivationID: UUID? = nil
    ) {
        self.entity = entity
        self.paperID = paperID
        self.chapterID = chapterID
        self.paperTitle = paperTitle
        self.collectedNotes = collectedNotes
        self.origin = origin
        self.userDerivationID = userDerivationID
        self.isNodeExplanationItem = isNodeExplanationItem
        _explanationFontSize = explanationFontSize
        _selectedCodeFramework = selectedCodeFramework
    }

    #if canImport(UIKit)
    private var chatInputHeight: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 180 : 112
    }
    #else
    private var chatInputHeight: CGFloat { 112 }
    #endif

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    _sourceEntityPane
                        .padding(14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(width: _sourcePaneWidth(in: proxy.size.width))
                .inf6CodexPanel(radius: 12)

                ZStack {
                    Rectangle()
                        .fill(Inf6CodexDesign.cyan.opacity(0.72))
                        .frame(width: 1)
                }

                VStack(spacing: 0) {
                    ScrollView(.vertical, showsIndicators: true) {
                        _chatPane
                    }
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .background(Color.clear)
                    _chatComposer
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 0)
        .padding(.top, 0)
        .task(id: entity.id) {
            isLoadingSavedDerivation = true
            defer { isLoadingSavedDerivation = false }
            if loadedChatThreadID != paperID {
                chatQuestion = ""
                chatMessages = []
                inlineFormulaReferences = []
                editingChatMessageIndex = nil
                chatError = nil
                _loadChat()
                loadedChatThreadID = paperID
            }
            image = nil
            if let path = entity.imagePath,
               let url = await Inf6EntityImageStore.ensureLocalFile(relativePath: path),
               let data = try? Data(contentsOf: url),
               let loaded = UIImage(data: data) {
                // Part coordinates are normalized against the persisted entity image.
                // Do not trim the displayed image without transforming every part rectangle.
                image = loaded
            }
            formulaExpression = ""
            formulaMathML = nil
            _loadSavedDerivation()
            inlineFormulaCapture = nil
        }
    }

    private func _paperTextModeButton(_ mode: PaperTextDisplayMode, title: String) -> some View {
        let selected = paperTextDisplayMode == mode
        return Button {
            paperTextDisplayMode = mode
        } label: {
            Text(title)
                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(13), weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Color.black.opacity(0.82) : Color.white.opacity(0.86))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(selected ? Color.white : Color.white.opacity(0.04), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(title)
    }

    private func _partDisplayModeButton(_ mode: PartDisplayMode, title: String) -> some View {
        let selected = partDisplayMode == mode
        return Button {
            partDisplayMode = mode
        } label: {
            Text(title)
                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(13), weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Color.black.opacity(0.82) : Color.white.opacity(0.86))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(selected ? Color.white : Color.white.opacity(0.04), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(title)
    }

    private func _sourcePaneWidth(in totalWidth: CGFloat) -> CGFloat {
        return max((totalWidth - 1) / 2, 1)
    }

    private var _interactiveParts: [Inf6DocEntityPart] {
        entity.parts.sorted {
            let leftArea = $0.normalizedRect.width * $0.normalizedRect.height
            let rightArea = $1.normalizedRect.width * $1.normalizedRect.height
            return leftArea > rightArea
        }
    }

    private var _sourceEntityPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isNodeExplanationItem {
                HStack(spacing: 8) {
                    Label(entity.kind.labelJa, systemImage: entity.kind.systemImage)
                        .font(Inf6CodexDesign.technical)
                        .foregroundStyle(Inf6CodexDesign.cyan)
                    Spacer(minLength: 0)
                    _copyEntityToEditorButton
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("p.\(entity.pageIndex + 1)")
                        .font(Inf6CodexDesign.technical)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    HStack(spacing: 0) {
                        _paperTextModeButton(.original, title: "English")
                        _paperTextModeButton(.japanese, title: "日本語")
                    }
                    .frame(width: 118, height: 24)
                }
            }
            if let image {
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .scaleEffect(imageZoom, anchor: .top)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    imageZoom = min(max(value, 1), 3)
                                }
                        )
                    GeometryReader { imageProxy in
                        ForEach(_interactiveParts) { part in
                            Rectangle()
                                .fill((selectedPart ?? hoveredPart)?.stableID == part.stableID ? Color.cyan.opacity(0.20) : .clear)
                                .overlay(Rectangle().stroke(Color.cyan.opacity((selectedPart ?? hoveredPart)?.stableID == part.stableID ? 0.8 : 0), lineWidth: 1))
                                .frame(
                                    width: imageProxy.size.width * part.normalizedRect.width,
                                    height: imageProxy.size.height * part.normalizedRect.height
                                )
                                .position(
                                    x: imageProxy.size.width * part.normalizedRect.midX,
                                    y: imageProxy.size.height * part.normalizedRect.midY
                                )
                                .allowsHitTesting(false)
                        }
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .gesture(
                                SpatialTapGesture()
                                    .onEnded { event in
                                        let normalizedPoint = CGPoint(
                                            x: event.location.x / max(imageProxy.size.width, 1),
                                            y: event.location.y / max(imageProxy.size.height, 1)
                                        )
                                        if let part = _interactiveParts
                                            .filter({ $0.normalizedRect.contains(normalizedPoint) })
                                            .min(by: {
                                                ($0.normalizedRect.width * $0.normalizedRect.height)
                                                    < ($1.normalizedRect.width * $1.normalizedRect.height)
                                            }) {
                                            selectedPart = part
                                        }
                                    }
                            )
                        .onContinuousHover(coordinateSpace: .local) { phase in
                            switch phase {
                            case .active(let location):
                                let normalizedPoint = CGPoint(
                                    x: location.x / max(imageProxy.size.width, 1),
                                    y: location.y / max(imageProxy.size.height, 1)
                                )
                                hoveredPart = _interactiveParts
                                    .filter { $0.normalizedRect.contains(normalizedPoint) }
                                    .min {
                                        ($0.normalizedRect.width * $0.normalizedRect.height)
                                            < ($1.normalizedRect.width * $1.normalizedRect.height)
                                    }
                            case .ended:
                                if selectedPart == nil {
                                    hoveredPart = nil
                                }
                            @unknown default:
                                if selectedPart == nil {
                                    hoveredPart = nil
                                }
                            }
                        }
                    }
                    if let displayedPart = selectedPart ?? hoveredPart {
                        _partInfoPanel(displayedPart)
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .onHover { isHovering in
                    if !isHovering, selectedPart == nil {
                        hoveredPart = nil
                    }
                }
                .aspectRatio(image.size, contentMode: .fit)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(!isNodeExplanationItem && paperTextDisplayMode == .japanese && !entity.titleJapanese.isEmpty ? entity.titleJapanese : entity.title)
                    .font(Inf6CodexDesign.display)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                if !isNodeExplanationItem, entity.kind != .equation, !entity.snippet.isEmpty {
                    Text(paperTextDisplayMode == .japanese && !entity.snippetJapanese.isEmpty ? entity.snippetJapanese : entity.snippet)
                        .font(.system(size: explanationFontSize))
                        .foregroundStyle(.white.opacity(0.92))
                        .textSelection(.enabled)
                }
                if !isNodeExplanationItem, paperTextDisplayMode == .japanese,
                   let explanationJapanese = entity.explanationJapanese,
                   !explanationJapanese.isEmpty {
                    Text(explanationJapanese)
                        .font(.system(size: explanationFontSize))
                        .foregroundStyle(.white.opacity(0.92))
                        .textSelection(.enabled)
                }
            }
            if isNodeExplanationItem {
                if entity.kind == .equation,
                   let mathML = entity.paperFormulaMathML,
                   !mathML.isEmpty {
                    Inf6CodexHTMLFragmentView(
                        html: mathML,
                        fontSize: max(explanationFontSize, 24),
                        textColor: "#ffffff"
                    )
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .padding(12)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if let steps = entity.nodeDiagramSteps, !steps.isEmpty {
                    _nodeRelationDiagram(steps)
                }
                if let columns = entity.nodeTableColumns,
                   let rows = entity.nodeTableRows {
                    _nodeExplanationTable(columns: columns, rows: rows, fontSize: explanationFontSize)
                }
                if let explanation = entity.explanation, !explanation.isEmpty {
                    Text(explanation)
                        .font(.system(size: explanationFontSize))
                        .foregroundStyle(.white.opacity(0.9))
                        .textSelection(.enabled)
                }
            }
            if !collectedNotes.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("収集済みの解説")
                        .font(Inf6CodexDesign.section)
                        .foregroundStyle(Inf6CodexDesign.cyan)
                    ForEach(collectedNotes) { note in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(note.text)
                                .font(.system(size: explanationFontSize))
                                .foregroundStyle(.white.opacity(0.92))
                                .textSelection(.enabled)
                            if let table = note.structuredTable {
                                _structuredTableView(table)
                            }
                        }
                        .padding(10)
                        .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
        .onChange(of: entity.id) { _, _ in
            _persistChat()
            chatDraftPersistenceTask?.cancel()
            chatDraftPersistenceTask = nil
            hoveredPart = nil
            selectedPart = nil
            imageZoom = 1
            pencilRecognitionGeneration += 1
            pencilRecognitionTask?.cancel()
            pencilRecognitionTask = nil
            inlineFormulaCapture = nil
            pencilRecognitionRunning = false
            pencilDrawing = PKDrawing()
            pencilRecognition = nil
            pencilRecognitionError = nil
            formulaStructureSelection = []
            isCandidatePopoverPresented = false
            formulaExpression = ""
            formulaMathML = nil
            _loadSavedDerivation()
        }
        .onChange(of: chatQuestion) { _, newValue in
            if inlineFormulaProgrammaticTextChange == newValue {
                inlineFormulaProgrammaticTextChange = nil
            }
            _scheduleChatDraftPersistence()
        }
        .onChange(of: chatSelectionRange) { _, _ in
            _scheduleChatDraftPersistence()
        }
        .onDisappear {
            chatDraftPersistenceTask?.cancel()
            chatDraftPersistenceTask = nil
            if inlineFormulaCapture != nil {
                _cancelInlineFormulaRecognition()
            }
        }
    }

    private var _copyEntityToEditorButton: some View {
        Button {
            _copySourceEntityToEditor()
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Inf6CodexDesign.cyan)
        .accessibilityLabel(Inf6Lang.text("編集面にコピー", "Copy to editor"))
        .help(Inf6Lang.text("編集面にコピー", "Copy to editor"))
    }

    private func _nodeRelationDiagram(_ steps: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { item in
                    Text(item.element)
                        .font(Inf6CodexDesign.technical)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Inf6CodexDesign.ink.opacity(0.9), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Inf6CodexDesign.cyan, lineWidth: 1))
                    if item.offset < steps.count - 1 {
                        Image(systemName: "arrow.right")
                            .foregroundStyle(Inf6CodexDesign.cyan)
                            .accessibilityLabel(Inf6Lang.text("次へ", "then"))
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .accessibilityElement(children: .combine)
    }

    private func _nodeExplanationTable(columns: [String], rows: [[String]], fontSize: CGFloat) -> some View {
        let tableTextSize = max(12, fontSize * 0.72)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach(columns.indices, id: \.self) { index in
                    Text(columns[index])
                        .font(.system(size: tableTextSize, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .foregroundStyle(Inf6CodexDesign.cyan)
            .padding(10)
            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(spacing: 8) {
                    ForEach(rows[rowIndex].indices, id: \.self) { columnIndex in
                        Text(rows[rowIndex][columnIndex])
                            .font(.system(size: tableTextSize))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(10)
                if rowIndex < rows.count - 1 {
                    Rectangle().fill(Inf6CodexDesign.cyan.opacity(0.24)).frame(height: 1)
                }
            }
        }
        .background(Inf6CodexDesign.ink.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Inf6CodexDesign.cyan.opacity(0.45), lineWidth: 1))
    }

    @ViewBuilder
    private func _partInfoPanel(_ displayedPart: Inf6DocEntityPart) -> some View {
        let sourceFormula = _sourcePaperFormula(for: displayedPart)
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entity.kind == .equation ? entity.title : displayedPart.text)
                            .font(Inf6CodexDesign.section)
                            .foregroundStyle(Inf6CodexDesign.cyan)
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        HStack(spacing: 0) {
                            _partDisplayModeButton(.text, title: "本文")
                            _partDisplayModeButton(.formula, title: "数式")
                        }
                        .frame(width: 136, height: 24)
                        Button {
                            selectedPart = nil
                            hoveredPart = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(11), weight: .bold))
                                .foregroundStyle(Inf6CodexDesign.ink.opacity(0.72))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Inf6Lang.text("クリア", "Clear"))
                    }
                    if partDisplayMode == .formula {
                        if let formulaMathML = displayedPart.paperFormulaMathML ?? sourceFormula?.mathML,
                           !formulaMathML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Inf6CodexHTMLFragmentView(
                                html: formulaMathML,
                                fontSize: explanationFontSize,
                                textColor: "#10203a"
                            )
                                .frame(minHeight: 30, maxHeight: 84, alignment: .leading)
                        } else if let formulaExpression = (displayedPart.paperFormulaExpression ?? sourceFormula?.expression)?.trimmingCharacters(in: .whitespacesAndNewlines),
                                  !formulaExpression.isEmpty {
                            _mathExpressionPreview(formulaExpression, fontSize: explanationFontSize)
                                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        } else if entity.kind == .equation, let image {
                            Text(Inf6Lang.text("論文の数式画像", "Paper equation image"))
                                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(12), weight: .semibold))
                                .foregroundStyle(Inf6CodexDesign.ink.opacity(0.72))
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 340, maxHeight: 160, alignment: .leading)
                                .background(Color.white)
                        } else {
                            Text(
                                paperTextDisplayMode == .original
                                    ? "No formula is registered for this item."
                                    : "このアイテムの数式は未登録です。"
                            )
                                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(12)))
                                .foregroundStyle(Inf6CodexDesign.ink.opacity(0.62))
                                .textSelection(.enabled)
                        }
                    } else {
                        Text(paperTextDisplayMode == .original ? "Original paper text" : "論文原文")
                            .font(Inf6CodexDesign.technical)
                            .foregroundStyle(Inf6CodexDesign.ink.opacity(0.72))
                            .textSelection(.enabled)
                        if paperTextDisplayMode == .original {
                            Text(displayedPart.paperText)
                                .font(.system(size: explanationFontSize))
                                .foregroundStyle(Inf6CodexDesign.ink)
                                .textSelection(.enabled)
                                .frame(maxWidth: 360, alignment: .leading)
                        } else if !displayedPart.paperTextJapanese.isEmpty {
                            Text(displayedPart.paperTextJapanese)
                                .font(.system(size: explanationFontSize))
                                .foregroundStyle(Inf6CodexDesign.ink)
                                .textSelection(.enabled)
                                .frame(maxWidth: 360, alignment: .leading)
                        } else {
                            Text(Inf6Lang.text("この部位の日本語訳は保存されていません。再クロップしてください。", "No saved Japanese translation exists for this part. Recrop it."))
                                .font(.system(size: explanationFontSize))
                                .foregroundStyle(Inf6CodexDesign.ink.opacity(0.72))
                                .frame(maxWidth: 360, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
            HStack(spacing: 8) {
                Button {
                    _copySourcePartToEditor(displayedPart)
                } label: {
                    Label(Inf6Lang.text("編集面にコピー", "Copy to editor"), systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .accessibilityHint(Inf6Lang.text("選択した論文項目をチャット編集欄の現在位置へ挿入します。", "Inserts the selected paper item at the current chat-editor position."))
                Button(Inf6Lang.text("チャットに引用", "Quote in chat")) {
                    _appendPartToChat(displayedPart)
                }
                .buttonStyle(.borderedProminent)
                .tint(Inf6CodexDesign.cyan)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Inf6CodexDesign.cyan.opacity(0.78), lineWidth: 1)
        }
        .shadow(color: Inf6CodexDesign.cyan.opacity(0.42), radius: 10)
    }

    private func _structuredTableView(_ table: Inf6StructuredTable) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(table.title)
                .font(.system(size: explanationFontSize, weight: .semibold))
                .foregroundStyle(.white)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                ForEach(table.columns, id: \.self) { column in
                    Text(column)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: explanationFontSize, weight: .semibold))
            .foregroundStyle(Inf6CodexDesign.cyan)
            ForEach(table.rows) { row in
                HStack(spacing: 8) {
                    Text(row.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(row.values.indices, id: \.self) { index in
                        Text(row.values[index])
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.system(size: explanationFontSize))
                .foregroundStyle(.white.opacity(0.88))
            }
        }
        .textSelection(.enabled)
    }

    /*
     The source pane and chat pane are intentionally separate scroll containers.
     The source pane stays attached to the selected entity while chat history can
     grow without moving the source image or explanation out of view.
    */
    /* legacy body removed
            VStack(alignment: .leading, spacing: 16) {
                Label(entity.kind.labelJa, systemImage: entity.kind.systemImage)
                    .font(Inf6CodexDesign.section)
                    .foregroundStyle(.white)
                Text(entity.title)
                    .font(Inf6CodexDesign.display)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                Text("論文: \(paperTitle)・p.\(entity.pageIndex + 1)")
                    .font(Inf6CodexDesign.technical)
                    .foregroundStyle(.white.opacity(0.82))
                    .textSelection(.enabled)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 560)
                        .frame(maxWidth: .infinity)
                }
                if let explanation = entity.explanation, !explanation.isEmpty {
                    Text(explanation)
                        .textSelection(.enabled)
                } else if !entity.snippet.isEmpty {
                    Text(entity.snippet)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.9))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 10) {
                    if !isChatReady {
                        Button {
                            isChatReady = true
                        } label: {
                            Label(
                                Inf6Lang.text("この対象について開始", "Start with this source"),
                                systemImage: "bubble.left.and.bubble.right"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Inf6CodexDesign.blue)
                    } else {
                        ForEach(Array(chatMessages.enumerated()), id: \.offset) { _, message in
                            Text(message)
                                .font(.body)
                                .foregroundStyle(.white)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        HStack(alignment: .bottom, spacing: 8) {
                            TextField(
                                Inf6Lang.text("この対象について質問", "Ask about this source"),
                                text: $chatQuestion,
                                axis: .vertical
                            )
                            .textFieldStyle(.roundedBorder)
                            Button(Inf6Lang.text("送信", "Send")) {
                                _sendChat()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Inf6CodexDesign.magenta)
                            .disabled(isChatting || chatQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if let chatError {
                            Text(chatError)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(12)
                .inf6CodexPanel(stroke: Inf6CodexDesign.blue, radius: 10)
            }
            .padding(20)
        }
        .navigationTitle(entity.title)
        .task {
            guard let path = entity.imagePath,
                  let url = await Inf6EntityImageStore.ensureLocalFile(relativePath: path),
                  let data = try? Data(contentsOf: url),
                  let loaded = UIImage(data: data) else { return }
            image = _trimEntityImageMargins(loaded)
        }
    }

    */

    private var _chatPane: some View {
        ScrollViewReader { proxy in
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(chatMessages.enumerated()).filter { !$0.element.hasPrefix("数式SEED:") }, id: \.offset) { index, message in
                HStack {
                    if message.hasPrefix("質問:") || message.hasPrefix("Q:") {
                        Spacer(minLength: 36)
                    }
                    if message.hasPrefix("AI: ") || message.hasPrefix("A: ") {
                        Image(systemName: "sparkles")
                            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(14), weight: .semibold))
                            .foregroundStyle(Inf6CodexDesign.magenta)
                            .accessibilityLabel("AI")
                    }
                    _chatBubble(message)
                    Button {
                        editingChatMessageIndex = index
                        chatQuestion = _chatEditableText(message)
                        chatSelectionRange = NSRange(location: (chatQuestion as NSString).length, length: 0)
                        chatClearGeneration &+= 1
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(12), weight: .semibold))
                            .foregroundStyle(Inf6CodexDesign.cyan.opacity(0.85))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Inf6Lang.text("この発言を編集", "Edit this message"))
                    Button {
                        let previousMessages = chatMessages
                        let previousEditingIndex = editingChatMessageIndex
                        let previousQuestion = chatQuestion
                        let previousSelection = chatSelectionRange
                        let wasEditingDeletedMessage = editingChatMessageIndex == index
                        chatMessages.remove(at: index)
                        if wasEditingDeletedMessage {
                            editingChatMessageIndex = nil
                            chatQuestion = ""
                            chatSelectionRange = NSRange(location: 0, length: 0)
                        } else if let editingChatMessageIndex, editingChatMessageIndex > index {
                            self.editingChatMessageIndex = editingChatMessageIndex - 1
                        }
                        guard _persistChat() else {
                            chatMessages = previousMessages
                            editingChatMessageIndex = previousEditingIndex
                            chatQuestion = previousQuestion
                            chatSelectionRange = previousSelection
                            return
                        }
                        if wasEditingDeletedMessage {
                            _cancelActiveFormulaComposition()
                            chatClearGeneration &+= 1
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(12), weight: .semibold))
                            .foregroundStyle(Inf6CodexDesign.cyan.opacity(0.85))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Inf6Lang.text("この発言を削除", "Delete this message"))
                    if message.hasPrefix("質問:") || message.hasPrefix("Q:") {
                        EmptyView()
                    } else {
                        Spacer(minLength: 36)
                    }
                }
                .id(index)
            }
            if isChatting {
                AIResponseIndicator()
            }
            if let chatModelRefreshError {
                Text(chatModelRefreshError)
                    .font(Inf6CodexDesign.technical)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.25), value: pencilRecognition?.decodedExpression)
        .onChange(of: chatMessages.count) { _, count in
            guard count > 0 else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
        }
    }

    private var _visibleChatMessages: [String] {
        chatMessages.filter { !$0.hasPrefix("数式SEED:") }
    }

    private var _chatComposer: some View {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                    if editingChatMessageIndex != nil {
                        HStack {
                            Text(Inf6Lang.text("発言を編集中", "Editing message"))
                                .font(Inf6CodexDesign.technical)
                                .foregroundStyle(Inf6CodexDesign.cyan)
                            Spacer()
                            Button(Inf6Lang.text("編集を取り消す", "Cancel edit")) {
                                _cancelActiveFormulaComposition()
                                self.editingChatMessageIndex = nil
                                chatQuestion = ""
                                chatSelectionRange = NSRange(location: 0, length: 0)
                                chatClearGeneration &+= 1
                            }
                            .font(Inf6CodexDesign.technical)
                            .buttonStyle(.plain)
                            .foregroundStyle(Inf6CodexDesign.cyan)
                        }
                        .padding(.horizontal, 8)
                    }
                    if inlineFormulaCapture != nil {
                        if inlineFormulaCapture != nil && pencilRecognitionRunning {
                            HStack(spacing: 8) {
                                HinotoriRecognitionSpinner()
                                Text(Inf6Lang.text("入力位置の数式を認識中", "Recognizing formula at the insertion point"))
                                    .font(Inf6CodexDesign.technical)
                                    .foregroundStyle(Inf6CodexDesign.cyan)
                                Spacer(minLength: 0)
                                Button(Inf6Lang.text("取消", "Cancel")) { _cancelActiveFormulaComposition() }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Inf6CodexDesign.cyan)
                            }
                            .padding(.horizontal, 8)
                        }
                        if let pencilRecognition, inlineFormulaCapture != nil, _inlineCaptureIsCurrent {
                            if pencilRecognition.isProvisional || inlineFormulaCapture != nil {
                                _candidateFairyBubbleFollowingCaret(pencilRecognition)
                            } else {
                                HStack(spacing: 8) {
                                    _mathExpressionPreview(
                                        pencilRecognition.decodedExpression,
                                        fontSize: Inf6ApplicationSystemFont.scaledSize(16)
                                    )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Spacer(minLength: 0)
                                    Button(Inf6Lang.text("検証して挿入", "Verify and insert")) {
                                        _ = _commitFormulaToChat()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(Inf6CodexDesign.cyan)
                                    Button(Inf6Lang.text("取消", "Cancel")) { _cancelActiveFormulaComposition() }
                                        .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8)
                            }
                        }
                        if let pencilRecognitionError {
                            HStack(spacing: 8) {
                                Text(pencilRecognitionError)
                                    .font(Inf6CodexDesign.technical)
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                                if inlineFormulaCapture != nil {
                                    Button(Inf6Lang.text("再認識", "Retry")) { _retryInlineFormulaRecognition() }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Inf6CodexDesign.cyan)
                                }
                                Button(Inf6Lang.text("取消", "Cancel")) { _cancelActiveFormulaComposition() }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Inf6CodexDesign.cyan)
                            }
                            .padding(.horizontal, 8)
                        }
                    }
                    if inlineFormulaCapture == nil,
                       let pencilRecognitionError {
                        Text(pencilRecognitionError)
                            .font(Inf6CodexDesign.technical)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .padding(.horizontal, 8)
                    }
#if canImport(WebKit)
                    Inf6UnifiedChatComposerView(
                        text: chatQuestion,
                        formulae: _inlineFormulaTextDescriptors,
                        fontSize: explanationFontSize,
                        selectionRange: chatSelectionRange,
                        clearGeneration: chatClearGeneration,
                        editCommandID: inlineMathMLEditCommandID,
                        editCommand: inlineMathMLEditCommand,
                        onDocumentChange: { text, formulae, selection in
                            _acceptUnifiedComposerDocument(text, formulae: formulae, selection: selection)
                        },
                        onSelectionChange: { range, rect in
                            chatSelectionRange = range
                            chatCaretRect = rect
                        },
                        onHandwriting: _beginInlineFormulaRecognition,
                        onFocus: { activeInlineFormulaToken = nil },
                        onFailure: { pencilRecognitionError = $0 }
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: chatInputHeight, alignment: .topLeading)
                    .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Inf6CodexDesign.cyan.opacity(0.42), lineWidth: 1))
#else
                    ZStack(alignment: .topLeading) {
                        Inf6ChatTextInput(
                            text: $chatQuestion,
                            clearGeneration: $chatClearGeneration,
                            selectionRange: $chatSelectionRange,
                            caretRect: $chatCaretRect,
                            inlineFormulae: _inlineFormulaTextDescriptors,
                            onHandwriting: _beginInlineFormulaRecognition,
                            onInlineFormulaFrames: { frames in
                                if chatInlineFormulaFrames != frames {
                                    chatInlineFormulaFrames = frames
                                }
                            },
                            onBeginEditing: { activeInlineFormulaToken = nil }
                        )
                            .frame(maxWidth: .infinity)
                            .frame(height: chatInputHeight, alignment: .topLeading)
                        ForEach(_inlineFormulaTextDescriptors, id: \.token) { descriptor in
                            if let frame = chatInlineFormulaFrames[descriptor.token],
                               frame.width > 0,
                               frame.height > 0 {
                                #if canImport(WebKit)
                                Inf6EditableMathMLView(
                                    token: descriptor.token,
                                    mathML: descriptor.mathML,
                                    editCommandID: activeInlineFormulaToken == descriptor.token ? inlineMathMLEditCommandID : 0,
                                    editCommand: activeInlineFormulaToken == descriptor.token ? inlineMathMLEditCommand : nil,
                                    onChange: { updatedMathML in
                                        _updateInlineFormulaMathML(descriptor.token, mathML: updatedMathML)
                                    },
                                    onFocusChange: { focused in
                                        if focused {
                                            activeInlineFormulaToken = descriptor.token
                                        }
                                    },
                                    onCommandFailure: {
                                        pencilRecognitionError = Inf6Lang.text(
                                            "数式内のカーソル操作を適用できませんでした。数式をタップし直してから操作してください。",
                                            "Could not apply the formula cursor command. Tap the formula again and retry."
                                        )
                                    }
                                )
                                .frame(width: frame.width, height: max(frame.height, 48))
                                .position(x: frame.midX, y: frame.midY)
                                .accessibilityLabel(_inlineFormulaActionLabel(for: descriptor.token))
                                #else
                                Inf6CodexHTMLFragmentView(html: descriptor.mathML, fontSize: 19)
                                    .frame(width: frame.width, height: frame.height)
                                    .position(x: frame.midX, y: frame.midY)
                                #endif
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: chatInputHeight, alignment: .topLeading)
                    .padding(8)
                    .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Inf6CodexDesign.cyan.opacity(0.42), lineWidth: 1))
#endif
                    }

                    if let chatError {
                        Text(chatError)
                            .font(Inf6CodexDesign.technical)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .padding(.horizontal, 8)
                    }

                    GeometryReader { toolbarGeometry in
                        HStack(spacing: 4) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 1) {
                                Button {
                                    _wrapChatSelection(prefix: "**", suffix: "**")
                                } label: {
                                    Text("B")
                                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(14), weight: .bold))
                                    .foregroundStyle(Inf6CodexDesign.cyan)
                                    .frame(width: 30, height: 30)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Inf6Lang.text("選択範囲を太字", "Bold selection"))
                                Button {
                                    _wrapChatSelection(prefix: "==", suffix: "==")
                                } label: {
                                    Image(systemName: "highlighter")
                                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(14), weight: .semibold))
                                    .foregroundStyle(.yellow)
                                    .frame(width: 30, height: 30)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Inf6Lang.text("選択範囲にマーカー", "Highlight selection"))
                                Menu {
                                    Button(Inf6Lang.text("シアン", "Cyan")) { _wrapChatSelection(prefix: "[[c=cyan]]", suffix: "[[/c]]") }
                                    Button(Inf6Lang.text("マゼンタ", "Magenta")) { _wrapChatSelection(prefix: "[[c=magenta]]", suffix: "[[/c]]") }
                                    Button(Inf6Lang.text("緑", "Green")) { _wrapChatSelection(prefix: "[[c=green]]", suffix: "[[/c]]") }
                                    Button(Inf6Lang.text("オレンジ", "Orange")) { _wrapChatSelection(prefix: "[[c=orange]]", suffix: "[[/c]]") }
                                    Button(Inf6Lang.text("赤", "Red")) { _wrapChatSelection(prefix: "[[c=red]]", suffix: "[[/c]]") }
                                } label: {
                                    Image(systemName: "paintpalette")
                                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(14), weight: .semibold))
                                    .foregroundStyle(Inf6CodexDesign.cyan)
                                    .frame(width: 30, height: 30)
                                }
                                .menuStyle(.borderlessButton)
                                .accessibilityLabel(Inf6Lang.text("選択範囲の文字色", "Text color for selection"))
                                Button {
                                    _performComposerEditCommand(.moveLeft)
                                } label: {
                                    Image(systemName: "chevron.left")
                                    .foregroundStyle(Inf6CodexDesign.cyan)
                                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(14), weight: .bold))
                                    .frame(width: 30, height: 30)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Inf6Lang.text("カーソルを左へ", "Move cursor left"))
                                Button {
                                    _performComposerEditCommand(.moveRight)
                                } label: {
                                    Image(systemName: "chevron.right")
                                    .foregroundStyle(Inf6CodexDesign.cyan)
                                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(14), weight: .bold))
                                    .frame(width: 30, height: 30)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Inf6Lang.text("カーソルを右へ", "Move cursor right"))
                                Button {
                                    _performComposerEditCommand(.deleteBackward)
                                } label: {
                                    Image(systemName: "delete.left")
                                    .foregroundStyle(Inf6CodexDesign.cyan)
                                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(14), weight: .bold))
                                    .frame(width: 30, height: 30)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Inf6Lang.text("一文字削除", "Delete one character"))
                                Button {
                                    if inlineFormulaCapture != nil {
                                        _cancelInlineFormulaRecognition()
                                    }
                                    chatQuestion = ""
                                    editingChatMessageIndex = nil
                                    chatSelectionRange = NSRange(location: 0, length: 0)
                                    chatClearGeneration &+= 1
                                } label: {
                                    Image(systemName: "eraser")
                                    .foregroundStyle(Inf6CodexDesign.cyan)
                                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(14), weight: .bold))
                                    .frame(width: 30, height: 30)
                                }
                                .buttonStyle(.plain)
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                                .background(Color.clear)
                                .zIndex(2)
                                .opacity(chatQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.35 : 1)
                                .accessibilityLabel(Inf6Lang.text("入力を消去", "Clear text input"))
                            }
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                        Menu {
                                    let currentModel = Inf6OpenAIModelResolver.resolvedModel()
                                    let cachedModels = Inf6OpenAIModelResolver.cachedAvailableModels(fromJSON: cachedChatModelsJSON)
                                    let models = Array(Set([currentModel] + cachedModels)).sorted()
                                    ForEach(models, id: \.self) { model in
                                        Button {
                                            selectedChatModel = model
                                        } label: {
                                            HStack {
                                                Text(model)
                                                if model == currentModel {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                    Divider()
                                    Button {
                                        _refreshChatModels()
                                    } label: {
                                        Label(
                                        isRefreshingChatModels ? Inf6Lang.text("モデル一覧を取得中", "Refreshing models") : Inf6Lang.text("モデル一覧を更新", "Refresh models"),
                                        systemImage: "arrow.clockwise"
                                        )
                                    }
                                } label: {
                            Text(Inf6OpenAIModelResolver.resolvedModel())
                                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(12), weight: .medium))
                                .foregroundStyle(Inf6CodexDesign.cyan)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .frame(height: 30)
                        .contentShape(Rectangle())
                        .accessibilityLabel(Inf6Lang.text(
                                "使用モデル: \(Inf6OpenAIModelResolver.resolvedModel())",
                                "Selected model: \(Inf6OpenAIModelResolver.resolvedModel())"
                        ))
                        .help(Inf6OpenAIModelResolver.resolvedModel())
                        Button {
                            _appendChatText()
                        } label: {
                            Image(systemName: editingChatMessageIndex == nil ? "paperplane.fill" : "checkmark")
                                .foregroundStyle(Inf6CodexDesign.cyan)
                                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(14), weight: .bold))
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                        .disabled(chatQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .opacity(chatQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.35 : 1)
                        .accessibilityLabel(editingChatMessageIndex == nil
                            ? Inf6Lang.text("チャットに送る", "Send to chat")
                            : Inf6Lang.text("編集内容を保存", "Save edited message"))
                        Button {
                            _sendChat()
                        } label: {
                            Image(systemName: "sparkles")
                                .foregroundStyle(Inf6CodexDesign.cyan)
                                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(14), weight: .bold))
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                        .disabled(editingChatMessageIndex != nil || isChatting)
                        .accessibilityLabel(Inf6Lang.text("AIに質問", "Ask AI"))
                        }
                        .frame(width: toolbarGeometry.size.width, height: toolbarGeometry.size.height, alignment: .leading)
                    }
                    .frame(height: 30)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
        }
    }

    private func _performComposerEditCommand(_ command: InlineMathMLEditCommand) {
#if canImport(WebKit)
        inlineMathMLEditCommand = command
        inlineMathMLEditCommandID &+= 1
#else
        guard activeInlineFormulaToken != nil else {
            switch command {
            case .moveLeft:
                _moveChatCursor(by: -1)
            case .moveRight:
                _moveChatCursor(by: 1)
            case .deleteBackward:
                _deleteChatCharacter()
            case .deleteForward:
                return
            }
            return
        }
        inlineMathMLEditCommand = command
        inlineMathMLEditCommandID &+= 1
#endif
    }

    private func _acceptUnifiedComposerDocument(
        _ text: String,
        formulae: [InlineFormulaTextDescriptor],
        selection: NSRange
    ) -> Bool {
        let source = text as NSString
        guard selection.location >= 0,
              selection.length >= 0,
              selection.location <= source.length,
              NSMaxRange(selection) <= source.length else {
            pencilRecognitionError = Inf6Lang.text("編集カーソルが本文の範囲外です。変更を保存していません。", "The editor selection is outside the message; changes were not saved.")
            return false
        }
        var seen = Set<String>()
        var nextReferences: [InlineFormulaReference] = []
        for formula in formulae {
            guard seen.insert(formula.token).inserted,
                  source.range(of: formula.token).location != NSNotFound,
                  source.range(of: formula.token).length == (formula.token as NSString).length,
                  (try? MathMLValidator().validate(formula.mathML)) != nil else {
                pencilRecognitionError = Inf6Lang.text("数式識別子またはMathMLが不正です。変更を保存していません。", "A formula identifier or MathML value is invalid; changes were not saved.")
                return false
            }
            let matches = _occurrenceCount(of: formula.token, in: text)
            guard matches == 1 else {
                pencilRecognitionError = Inf6Lang.text("数式の識別子が編集本文内で一意ではありません。変更を保存していません。", "A formula identifier is not unique in the edited message; changes were not saved.")
                return false
            }
            let prior = inlineFormulaReferences.first { $0.token == formula.token }
            let unchanged = prior?.mathML == formula.mathML
            nextReferences.append(InlineFormulaReference(
                token: formula.token,
                expression: unchanged ? prior?.expression : nil,
                mathML: formula.mathML,
                derivationID: unchanged ? prior?.derivationID : nil,
                sourcePartID: prior?.sourcePartID
            ))
        }
        let previousText = chatQuestion
        let previousSelection = chatSelectionRange
        let previousReferences = inlineFormulaReferences
        guard previousText != text || previousSelection != selection || previousReferences != nextReferences else { return true }
        chatQuestion = text
        chatSelectionRange = selection
        inlineFormulaReferences = nextReferences
        guard _persistChat() else {
            chatQuestion = previousText
            chatSelectionRange = previousSelection
            inlineFormulaReferences = previousReferences
            return false
        }
        pencilRecognitionError = nil
        return true
    }

    private func _occurrenceCount(of token: String, in text: String) -> Int {
        let source = text as NSString
        let needle = token as NSString
        guard needle.length > 0 else { return 0 }
        var count = 0
        var search = NSRange(location: 0, length: source.length)
        while search.length > 0 {
            let match = source.range(of: token, options: [], range: search)
            guard match.location != NSNotFound else { break }
            count += 1
            let next = NSMaxRange(match)
            search = NSRange(location: next, length: source.length - next)
        }
        return count
    }

    private func _moveChatCursor(by offset: Int) {
        let length = (chatQuestion as NSString).length
        let current = min(max(chatSelectionRange.location, 0), length)
        let end = min(max(chatSelectionRange.location + chatSelectionRange.length, 0), length)
        let location = chatSelectionRange.length > 0
            ? (offset < 0 ? chatSelectionRange.location : end)
            : min(max(current + offset, 0), length)
        chatSelectionRange = NSRange(location: location, length: 0)
    }

    private func _wrapChatSelection(prefix: String, suffix: String) {
        let value = chatQuestion as NSString
        let length = value.length
        let start = min(max(chatSelectionRange.location, 0), length)
        let end = min(max(start + chatSelectionRange.length, start), length)
        let selected = NSRange(location: start, length: end - start)
        let replacement = prefix + value.substring(with: selected) + suffix
        chatQuestion = value.replacingCharacters(in: selected, with: replacement)
        let cursor = selected.length == 0
            ? start + (prefix as NSString).length
            : start + (replacement as NSString).length
        chatSelectionRange = NSRange(location: cursor, length: selected.length == 0 ? 0 : 0)
    }

    private func _deleteChatCharacter() {
        let value = chatQuestion as NSString
        let length = value.length
        let start = min(max(chatSelectionRange.location, 0), length)
        let end = min(max(start + chatSelectionRange.length, start), length)
        let range: NSRange
        let nextLocation: Int
        if end > start {
            range = NSRange(location: start, length: end - start)
            nextLocation = start
        } else if start > 0 {
            range = NSRange(location: start - 1, length: 1)
            nextLocation = start - 1
        } else {
            return
        }
        chatQuestion = value.replacingCharacters(in: range, with: "")
        chatSelectionRange = NSRange(location: nextLocation, length: 0)
    }

    private func _refreshChatModels() {
        guard !isRefreshingChatModels else { return }
        isRefreshingChatModels = true
        chatModelRefreshError = nil
        Task { @MainActor in
            defer { isRefreshingChatModels = false }
            do {
                let key = try OpenAIKeyStore.load()
                let models = try await Inf6OpenAIModelsService.fetchAvailableModelIDs(apiKey: key)
                guard !models.isEmpty else {
                    throw NSError(
                        domain: "Inf6OpenAIModelsService",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "利用可能なモデルが返されませんでした。"]
                    )
                }
                Inf6OpenAIModelResolver.cacheAvailableModels(models)
                let data = try JSONEncoder().encode(Array(Set(models)).sorted())
                cachedChatModelsJSON = String(decoding: data, as: UTF8.self)
                let now = Date().timeIntervalSince1970
                try Inf6OpenAIModelResolver.saveAvailableModelsToDisk(models, updatedAt: now)
            } catch {
                chatModelRefreshError = error.localizedDescription
            }
        }
    }

    private var _paperEquationSpaceCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "function")
                    .foregroundStyle(Inf6CodexDesign.cyan)
                Text(isNodeExplanationItem
                    ? Inf6Lang.text("ノード数式空間", "Node formula space")
                    : Inf6Lang.text("論文数式空間", "Paper equation space"))
                    .font(Inf6CodexDesign.section)
                    .foregroundStyle(.white)
                Spacer(minLength: 4)
                Text(Inf6Lang.text("入力待ち", "Ready for input"))
                    .font(Inf6CodexDesign.technical)
                    .foregroundStyle(.white.opacity(0.62))
            }
            Text(isNodeExplanationItem
                ? paperTitle
                : "\(paperTitle) · p.\(entity.pageIndex + 1)")
                .font(Inf6CodexDesign.technical)
                .foregroundStyle(Inf6CodexDesign.cyan)
                .lineLimit(1)
            HStack(spacing: 6) {
                _equationSpaceChip(
                    isNodeExplanationItem
                        ? Inf6Lang.text("ノード項目", "Node item")
                        : Inf6Lang.text("ページ根拠", "Page evidence"),
                    systemImage: isNodeExplanationItem ? "square.stack.3d.up" : "doc.text"
                )
                _equationSpaceChip(Inf6Lang.text("位置関係", "Spatial relation"), systemImage: "square.grid.3x3")
                _equationSpaceChip(
                    _currentPaperEquationSpace?.equations.first?.mathML != nil
                        ? "f(x) MathML"
                        : Inf6Lang.text("MathML待ち", "MathML pending"),
                    systemImage: "function"
                )
            }
        }
        .padding(10)
        .inf6CodexPanel(stroke: Inf6CodexDesign.cyan, radius: 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isNodeExplanationItem
            ? Inf6Lang.text("ノード数式空間", "Node formula space")
            : Inf6Lang.text("論文数式空間", "Paper equation space"))
    }

    private func _equationSpaceChip(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(11), weight: .semibold))
            .foregroundStyle(Inf6CodexDesign.cyan)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Inf6CodexDesign.cyan.opacity(0.10), in: Capsule())
            .overlay(Capsule().stroke(Inf6CodexDesign.cyan.opacity(0.45), lineWidth: 1))
            .lineLimit(1)
    }

    private var _selectedFormulaCard: some View {
        let activePart = selectedPart ?? hoveredPart ?? entity.parts.first
        let expression = pencilRecognition?.decodedExpression.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? formulaExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = activePart?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (expression.isEmpty ? nil : expression)
        let mathML = pencilRecognition?.mathML ?? activePart?.paperFormulaMathML ?? formulaMathML

        return Group {
            if let title, !title.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    if let _ = activePart {
                        Text(title)
                            .font(Inf6CodexDesign.section)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    } else {
                        _mathExpressionPreview(title, fontSize: explanationFontSize)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let mathML, !mathML.isEmpty {
                        Inf6CodexHTMLFragmentView(html: mathML, fontSize: explanationFontSize)
                            .frame(minHeight: 28, maxHeight: 72, alignment: .leading)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .inf6CodexPanel(stroke: Inf6CodexDesign.cyan, radius: 9)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(_displayFormulaExpression(title))
            }
        }
    }

    private func _candidateFairyBubble(_ recognition: Inf6HandwrittenMathMLResult) -> some View {
        let draft = formulaStructureDraft
        let scopeID = formulaStructureScopeStack.last ?? draft?.rootID
        let nodes = draft.flatMap { draft in
            scopeID.flatMap { scopeID in
                draft.nodes.first(where: { $0.id == scopeID })?.children.compactMap { childID in
                draft.nodes.first(where: { $0.id == childID })
                }
            }
        } ?? []
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                HinotoriBrandMark(width: 34, height: 17)
                    .accessibilityLabel("ANE")
                Spacer(minLength: 0)
                    if inlineFormulaCapture != nil {
                    Button(Inf6Lang.text("取消", "Cancel")) { _cancelActiveFormulaComposition() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Inf6CodexDesign.cyan)
                }
            }
            if let draft, let scopeID {
                HStack(spacing: 6) {
                    Text(_formulaStructureScopeTitle(scopeID, in: draft))
                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(10), weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if formulaStructureScopeStack.count > 1 {
                        Button(Inf6Lang.text("一つ上", "Up one level")) {
                            _leaveFormulaStructureScope()
                        }
                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(10), weight: .semibold))
                        .buttonStyle(.bordered)
                    }
                }
            }
            if draft == nil || nodes.isEmpty {
                if recognition.isProvisional {
                    Text(Inf6Lang.text("構造編集を開始できません", "Structure editing is unavailable"))
                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(10), design: .monospaced))
                        .foregroundStyle(.white.opacity(0.72))
                } else {
                    HStack(spacing: 8) {
                        _mathExpressionPreview(
                            recognition.decodedExpression,
                            fontSize: Inf6ApplicationSystemFont.scaledSize(15)
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Spacer(minLength: 0)
                        _confirmFirebirdFormulaButton(recognition)
                    }
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(nodes, id: \.id) { node in
                            let selectionText = _formulaStructureSelectionText(node)
                            HStack(spacing: 5) {
                                _formulaStructureNodeSelectionButton(node, title: selectionText, draft: draft)
                                if let candidateID = node.candidateID,
                                   let candidateIndex = _candidateIndex(candidateID),
                                   recognition.candidateLabels.indices.contains(candidateIndex) {
                                    _recognitionCandidateButtons(recognition, candidateID: candidateID, candidateIndex: candidateIndex)
                                }
                                if !node.children.isEmpty {
                                    ForEach(Array(node.children.enumerated()), id: \.element) { childIndex, childID in
                                        Button(_formulaStructureChildRole(node, childIndex: childIndex)) {
                                            _enterFormulaStructureScope(childID)
                                        }
                                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(9), weight: .semibold))
                                        .buttonStyle(.bordered)
                                        .tint(Inf6CodexDesign.magenta)
                                        .accessibilityLabel(Inf6Lang.text(
                                            "\(_formulaStructureChildRole(node, childIndex: childIndex))の中を編集",
                                            "Edit inside \(_formulaStructureChildRole(node, childIndex: childIndex))"
                                        ))
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 92)
                if let spatialAnalysis = recognition.spatialAnalysis,
                   !spatialAnalysis.proposals.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Inf6Lang.text("位置関係候補（確定には選択と構造指定が必要です）", "Spatial candidates — selection and structure confirmation are required"))
                            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(10), weight: .semibold))
                            .foregroundStyle(.white.opacity(0.78))
                        ForEach(spatialAnalysis.proposals.sorted { lhs, rhs in
                            let leftRank = Inf6SpatialRelationAnalyzer.rank(of: lhs, in: spatialAnalysis)
                            let rightRank = Inf6SpatialRelationAnalyzer.rank(of: rhs, in: spatialAnalysis)
                            switch (leftRank, rightRank) {
                            case let (.some(left), .some(right)):
                                return left == right ? lhs.id < rhs.id : left < right
                            case (.some, .none):
                                return true
                            case (.none, .some):
                                return false
                            case (.none, .none):
                                return lhs.id < rhs.id
                            }
                        }) { proposal in
                            _spatialProposalRow(proposal, analysis: spatialAnalysis, visibleNodeIDs: Set(nodes.map(\.id)))
                        }
                    }
                    .frame(maxHeight: 88, alignment: .topLeading)
                }
                if nodes.count > 1 {
                    HStack(spacing: 6) {
                        Button {
                            _composeRecognitionStructure(kind: .sequence)
                        } label: {
                            Label(Inf6Lang.text("横並び", "Sequence"), systemImage: "arrow.right.to.line.compact")
                                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(11), weight: .semibold))
                        }
                        Button {
                            _composeRecognitionStructure(kind: .superscript)
                        } label: {
                            Label(Inf6Lang.text("上付き", "Superscript"), systemImage: "arrow.up.right")
                                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(11), weight: .semibold))
                        }
                        Button {
                            _composeRecognitionStructure(kind: .subscripted)
                        } label: {
                            Label(Inf6Lang.text("下付き", "Subscript"), systemImage: "arrow.down.right")
                                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(11), weight: .semibold))
                        }
                    }
                    HStack(spacing: 6) {
                        Button {
                            _composeRecognitionStructure(kind: .fraction)
                        } label: {
                            Label(Inf6Lang.text("分数", "Fraction"), systemImage: "divide")
                                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(11), weight: .semibold))
                        }
                        Button {
                            _composeRecognitionStructure(kind: .squareRoot)
                        } label: {
                            Label(Inf6Lang.text("根号", "Square root"), systemImage: "square.root")
                                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(11), weight: .semibold))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Inf6CodexDesign.cyan)
                    .accessibilityLabel(Inf6Lang.text("選択順を使って下書き構造を追加", "Add a draft formula structure with selected order"))
                }
                _confirmFirebirdFormulaButton(recognition)
                Button(Inf6Lang.text("構造を選び直す", "Reset structure")) {
                    _resetFormulaStructureDraft(recognition)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .leading)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Inf6Lang.text("手書き認識候補", "Handwritten recognition candidate"))
    }

    @ViewBuilder
    private func _confirmFirebirdFormulaButton(_ recognition: Inf6HandwrittenMathMLResult) -> some View {
        Button {
            if recognition.isProvisional {
                _confirmRecognitionStructure()
            } else {
                _ = _commitFormulaToChat()
            }
        } label: {
            Label(
                recognition.isProvisional
                    ? Inf6Lang.text("構造を検証して確定", "Verify and confirm structure")
                    : Inf6Lang.text("数式を確定", "Confirm formula"),
                systemImage: "checkmark.seal"
            )
            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(11), weight: .semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(Inf6CodexDesign.magenta)
    }

    private func _candidateFairyBubbleFollowingCaret(_ recognition: Inf6HandwrittenMathMLResult) -> some View {
        GeometryReader { geometry in
            let bubbleWidth = min(max(geometry.size.width - 16, 0), 360)
            let caretX = chatCaretRect?.midX ?? 12
            let leading = min(max(caretX - bubbleWidth / 2, 0), max(geometry.size.width - bubbleWidth, 0))
            _candidateFairyBubble(recognition)
                .frame(width: bubbleWidth, alignment: .leading)
                .padding(8)
                .background(Inf6CodexDesign.ink.opacity(0.96), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Inf6CodexDesign.cyan.opacity(0.74), lineWidth: 1))
                .offset(x: leading)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Inf6Lang.text("入力位置に追従する数式候補", "Formula candidates following the insertion position"))
        }
        .frame(height: 270)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func _candidateIndex(_ candidateID: String) -> Int? {
        guard candidateID.hasPrefix("candidate-") else { return nil }
        return Int(candidateID.dropFirst("candidate-".count))
    }

    private func _formulaStructureSelectionText(_ node: FormulaStructure.Node) -> String {
        if let index = formulaStructureSelection.firstIndex(of: node.id) {
            return _formulaStructureNodeTitle(node) + ":" + String(index + 1)
        }
        return _formulaStructureNodeTitle(node)
    }

    private func _formulaStructureNodeSelectionButton(
        _ node: FormulaStructure.Node,
        title: String,
        draft: FormulaStructure?
    ) -> some View {
        let isSelected = formulaStructureSelection.contains(node.id)
        let selectedOrder = formulaStructureSelection.firstIndex(of: node.id).map { $0 + 1 }
        let candidateLabel = node.candidateID.flatMap { candidateID in
            draft?.candidates.first(where: { $0.id == candidateID })?.label
        }
        return Button {
            _toggleFormulaStructureSelection(node.id)
        } label: {
            _formulaStructureNodeSelectionLabel(
                candidateLabel: candidateLabel,
                selectedOrder: selectedOrder,
                title: title,
                isSelected: isSelected
            )
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? .white : Inf6CodexDesign.cyan)
        .accessibilityLabel(Inf6Lang.text("\(title)を構造順へ追加または削除", "Add or remove \(title) from structure order"))
    }

    @ViewBuilder
    private func _formulaStructureNodeSelectionLabel(
        candidateLabel: String?,
        selectedOrder: Int?,
        title: String,
        isSelected: Bool
    ) -> some View {
        if let candidateLabel {
            _mathExpressionPreview(candidateLabel, fontSize: Inf6ApplicationSystemFont.scaledSize(13))
                .frame(width: isSelected ? 64 : 42, height: 26)
                .overlay(alignment: .bottomTrailing) {
                    if let selectedOrder {
                        Text(String(selectedOrder))
                            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(8), weight: .bold))
                            .foregroundStyle(Inf6CodexDesign.cyan)
                    }
                }
        } else {
            Text(title)
                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(10), weight: .semibold))
                .frame(width: 42, alignment: .leading)
        }
    }

    private func _formulaStructureNodeTitle(_ node: FormulaStructure.Node) -> String {
        guard let draft = formulaStructureDraft else { return node.id }
        if let candidateID = node.candidateID,
           let candidate = draft.candidates.first(where: { $0.id == candidateID }) {
            return candidate.label
        }
        switch node.kind {
        case .sequence: return Inf6Lang.text("横並び", "Sequence")
        case .superscript: return Inf6Lang.text("上付き", "Superscript")
        case .subscripted: return Inf6Lang.text("下付き", "Subscript")
        case .fraction: return Inf6Lang.text("分数", "Fraction")
        case .squareRoot: return Inf6Lang.text("根号", "Square root")
        case .symbol: return Inf6Lang.text("記号", "Symbol")
        }
    }

    private func _formulaStructureScopeTitle(_ scopeID: String, in structure: FormulaStructure) -> String {
        guard scopeID != structure.rootID,
              let parent = structure.nodes.first(where: { $0.children.contains(scopeID) }),
              let childIndex = parent.children.firstIndex(of: scopeID) else {
            return Inf6Lang.text("式全体", "Whole expression")
        }
        let role = _formulaStructureChildRole(parent, childIndex: childIndex)
        return Inf6Lang.text("編集範囲：\(role)", "Editing: \(role)")
    }

    private func _formulaStructureChildRole(_ parent: FormulaStructure.Node, childIndex: Int) -> String {
        switch parent.kind {
        case .fraction:
            return childIndex == 0 ? Inf6Lang.text("分子", "Numerator") : Inf6Lang.text("分母", "Denominator")
        case .squareRoot:
            return Inf6Lang.text("根号内", "Radicand")
        case .superscript:
            return childIndex == 0 ? Inf6Lang.text("底", "Base") : Inf6Lang.text("指数", "Exponent")
        case .subscripted:
            return childIndex == 0 ? Inf6Lang.text("底", "Base") : Inf6Lang.text("添字", "Subscript")
        case .sequence:
            return Inf6Lang.text("部分式", "Subexpression")
        case .symbol:
            return Inf6Lang.text("部分式", "Subexpression")
        }
    }

    private func _enterFormulaStructureScope(_ nodeID: String) {
        guard let structure = formulaStructureDraft else { return }
        do {
            let editable = try FormulaStructureEditor().editableSequenceScope(structure, nodeID: nodeID)
            formulaStructureDraft = editable.structure
            formulaStructureScopeStack.append(editable.scopeID)
            formulaStructureSelection = []
            pencilRecognitionError = nil
        } catch {
            pencilRecognitionError = Inf6Lang.text(
                "部分式を編集範囲にできません: \(error.localizedDescription)",
                "Could not open this subexpression for editing: \(error.localizedDescription)"
            )
        }
    }

    private func _leaveFormulaStructureScope() {
        guard formulaStructureScopeStack.count > 1 else { return }
        formulaStructureScopeStack.removeLast()
        formulaStructureSelection = []
    }

    @ViewBuilder
    private func _recognitionCandidateButtons(_ recognition: Inf6HandwrittenMathMLResult, candidateID: String, candidateIndex: Int) -> some View {
        let supplements = recognition.positionSensitiveClassification?.symbols.first(where: { $0.sourceSymbolID == candidateID })?.ruleSupplements ?? []
        let supplementLabels = Set(supplements.map(\.label))
        let similaritySupplements = recognition.similarityExpansion?.symbols.first(where: { $0.sourceSymbolID == candidateID })?.supplements ?? []
        let similarityByLabel = Dictionary(uniqueKeysWithValues: similaritySupplements.map { ($0.label, $0) })
        let typesetCandidates = recognition.typesetCandidates.indices.contains(candidateIndex)
            ? recognition.typesetCandidates[candidateIndex]
            : []
        let typesetByLabel = Dictionary(uniqueKeysWithValues: typesetCandidates.map { ($0.label, $0) })
        let modelCandidates = recognition.spatialAnalysis?.symbols.first(where: { $0.id == candidateID })?.candidates ?? []
        let modelRankByLabel = Dictionary(uniqueKeysWithValues: modelCandidates.enumerated().map { ($0.element.label, $0.offset + 1) })
        let labels = recognition.candidateLabels[candidateIndex].filter { !$0.isEmpty && !supplementLabels.contains($0) }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(labels, id: \.self) { label in
                    let typesetCandidate = typesetByLabel[label]
                    let modelRank = modelRankByLabel[label]
                    Button { _selectRecognitionCandidate(symbolIndex: candidateIndex, label: label) } label: {
                        HStack(spacing: 4) {
                            _recognitionCandidateMathPreview(label)
                            if similarityByLabel[label] != nil {
                                Text(Inf6Lang.text("類似", "Similar")).font(.system(size: Inf6ApplicationSystemFont.scaledSize(8), weight: .semibold))
                            }
                            if let modelRank {
                                Text(Inf6Lang.text("手書き\(modelRank)", "INK\(modelRank)"))
                                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(8), weight: .semibold))
                                    .foregroundStyle(Inf6CodexDesign.cyan)
                            }
                            if let typesetCandidate {
                                Text(Inf6Lang.text("活字\(typesetCandidate.rank)", "TYPE\(typesetCandidate.rank)"))
                                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(8), weight: .semibold))
                                    .foregroundStyle(Color.green)
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.bordered)
                    .tint(typesetCandidate != nil && modelRank == nil ? Color.green : (similarityByLabel[label] == nil ? Inf6CodexDesign.cyan : Inf6CodexDesign.magenta))
                    .accessibilityLabel(typesetCandidate.map { candidate in
                        let handwritingSource = modelRank.map { Inf6Lang.text("手書きモデル第\($0)候補", "handwriting model rank \($0)") }
                            ?? Inf6Lang.text("手書きモデルの候補外", "outside handwriting model candidates")
                        return Inf6Lang.text(
                            "\(handwritingSource)、活字モデル第\(candidate.rank)候補 \(label)。スコアは別々です。選択して確定します。",
                            "\(handwritingSource); typeset model rank \(candidate.rank): \(label). Scores are separate. Select to confirm."
                        )
                    } ?? similarityByLabel[label].map { _ in
                        Inf6Lang.text("類似記号候補 \(label)。モデルスコアなし。選択して確定します。", "Similar-symbol candidate \(label). No model score; select to confirm.")
                    } ?? label)
                }
                ForEach(supplements, id: \.classIndex) { supplement in
                    Button { _selectRecognitionCandidate(symbolIndex: candidateIndex, label: supplement.label) } label: {
                        HStack(spacing: 3) {
                            _recognitionCandidateMathPreview(supplement.label)
                            Text(Inf6Lang.text("位置", "Position")).font(.system(size: Inf6ApplicationSystemFont.scaledSize(8), weight: .semibold))
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.bordered)
                    .tint(Inf6CodexDesign.magenta)
                    .accessibilityLabel(Inf6Lang.text("位置規則の補助候補 \(supplement.label)。モデルlogitなし。選択で確定します。", "Position-rule supplemental candidate \(supplement.label). No model logit; selection confirms it."))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func _recognitionCandidateMathPreview(_ label: String) -> some View {
        let expression = _recognitionCandidatePreviewExpression(for: label)
        _mathExpressionPreview(expression, fontSize: Inf6ApplicationSystemFont.scaledSize(15))
            .frame(width: 42, height: 28)
            .fixedSize()
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func _mathExpressionPreview(_ expression: String, fontSize: CGFloat) -> some View {
        let rendering = Result { try LaTeXMathMLConverter().convert(expression) }
        switch rendering {
        case .success(let mathML):
            Inf6CodexHTMLFragmentView(html: mathML, fontSize: fontSize, textColor: "#ffffff")
        case .failure(let error):
            Text(Inf6Lang.text(
                "数式を組版できません: \(error.localizedDescription)",
                "Could not typeset formula: \(error.localizedDescription)"
            ))
            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(9)))
            .foregroundStyle(.red)
            .lineLimit(2)
        }
    }

    private func _recognitionCandidatePreviewExpression(for label: String) -> String {
        switch label {
        case "\\frac": return "\\frac{x}{x}"
        case "\\sqrt": return "\\sqrt{x}"
        case "\\underline": return "\\underline{x}"
        case "\\overline": return "\\overline{x}"
        case "\\hat": return "\\hat{x}"
        case "\\tilde": return "\\tilde{x}"
        case "\\vec": return "\\vec{x}"
        case "\\dot": return "\\dot{x}"
        default: return label
        }
    }

    @ViewBuilder
    private func _spatialProposalRow(
        _ proposal: Inf6SpatialRelationAnalysis.Proposal,
        analysis: Inf6SpatialRelationAnalysis,
        visibleNodeIDs: Set<String>
    ) -> some View {
        if proposal.kind == .superscriptCandidate || proposal.kind == .subscriptCandidate {
            Button(_spatialProposalTitle(proposal, analysis: analysis)) {
                _applySpatialProposal(proposal, visibleNodeIDs: visibleNodeIDs)
            }
            .buttonStyle(.bordered)
            .tint(Inf6CodexDesign.magenta)
        } else {
            Text(_spatialProposalTitle(proposal, analysis: analysis))
                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(10)))
                .foregroundStyle(.white.opacity(0.70))
        }
    }

    private func _spatialProposalTitle(
        _ proposal: Inf6SpatialRelationAnalysis.Proposal,
        analysis: Inf6SpatialRelationAnalysis
    ) -> String {
        let rank = Inf6SpatialRelationAnalyzer.rank(of: proposal, in: analysis).map {
            Inf6Lang.text("第\($0 + 1)候補", "Rank \($0 + 1)")
        } ?? Inf6Lang.text("順位不明", "Rank unavailable")
        func label(for symbolID: String) -> String {
            analysis.symbols.first(where: { $0.id == symbolID })?.candidates.first?.label ?? symbolID
        }
        let source = label(for: proposal.sourceSymbolID)
        switch proposal.kind {
        case .minusCandidate:
            return Inf6Lang.text("\(rank) \(source)：マイナス候補（未確定）", "\(rank) \(source): minus candidate (unconfirmed)")
        case .fractionBarCandidate:
            return Inf6Lang.text("\(rank) \(source)：分数線候補（未確定）", "\(rank) \(source): fraction-bar candidate (unconfirmed)")
        case .underlineCandidate:
            return Inf6Lang.text("\(rank) \(source)：下線候補（未確定）", "\(rank) \(source): underline candidate (unconfirmed)")
        case .superscriptCandidate:
            return Inf6Lang.text("\(rank) \(source) → \(label(for: proposal.targetSymbolID ?? ""))：上付き候補を選ぶ", "\(rank) \(source) → \(label(for: proposal.targetSymbolID ?? "")): select superscript candidate")
        case .subscriptCandidate:
            return Inf6Lang.text("\(rank) \(source) → \(label(for: proposal.targetSymbolID ?? ""))：下付き候補を選ぶ", "\(rank) \(source) → \(label(for: proposal.targetSymbolID ?? "")): select subscript candidate")
        }
    }

    private func _applySpatialProposal(
        _ proposal: Inf6SpatialRelationAnalysis.Proposal,
        visibleNodeIDs: Set<String>
    ) {
        guard let targetID = proposal.targetSymbolID,
              visibleNodeIDs.contains(proposal.sourceSymbolID),
              visibleNodeIDs.contains(targetID) else {
            pencilRecognitionError = "位置関係候補の対象が現在の編集範囲にありません。構造を選び直してください。"
            return
        }
        switch proposal.kind {
        case .superscriptCandidate, .subscriptCandidate:
            formulaStructureSelection = [proposal.sourceSymbolID, targetID]
            pencilRecognitionError = proposal.kind == .superscriptCandidate
                ? "上付き候補を選択しました。上付き操作を選んで構造へ追加してください。"
                : "下付き候補を選択しました。下付き操作を選んで構造へ追加してください。"
        case .minusCandidate, .fractionBarCandidate, .underlineCandidate:
            pencilRecognitionError = "横線の役割は未確定です。候補記号と分子・分母または付加対象を選択して構造を指定してください。"
        }
    }

    private func _resetFormulaStructureDraft(_ recognition: Inf6HandwrittenMathMLResult) {
        do {
            formulaStructureDraft = try FormulaStructureEditor().makeDraft(labels: recognition.symbolLabels)
            formulaStructureScopeStack = ["root"]
            formulaStructureSelection = []
            pencilRecognitionError = nil
        } catch {
            pencilRecognitionError = "構造編集を初期化できません: \(error.localizedDescription)"
        }
    }

    private func _selectRecognitionCandidate(symbolIndex: Int, label: String) {
        guard let recognition = pencilRecognition,
              recognition.symbolLabels.indices.contains(symbolIndex),
              recognition.candidateLabels.indices.contains(symbolIndex),
              recognition.candidateLabels[symbolIndex].contains(label),
              let classIndex = _recognitionClassIndex(recognition, symbolIndex: symbolIndex, label: label) else { return }
        var labels = recognition.symbolLabels
        var tokenIDs = recognition.tokenIDs
        var candidateRanks = recognition.candidateRanks
        labels[symbolIndex] = label
        if tokenIDs.indices.contains(symbolIndex) { tokenIDs[symbolIndex] = Int32(classIndex) }
        if candidateRanks.indices.contains(symbolIndex) {
            if let analysis = recognition.spatialAnalysis,
               analysis.symbols.indices.contains(symbolIndex) {
                candidateRanks[symbolIndex] = analysis.symbols[symbolIndex].candidates.firstIndex(where: { $0.label == label })
            } else {
                candidateRanks[symbolIndex] = nil
            }
        }
        guard let draft = formulaStructureDraft else {
            pencilRecognitionError = "構造編集が初期化されていません。再認識してください。"
            return
        }
        do {
            formulaStructureDraft = try FormulaStructureEditor().replacingCandidate(draft, candidateID: "candidate-\(symbolIndex)", label: label)
        } catch {
            pencilRecognitionError = "候補を構造へ反映できません: \(error.localizedDescription)"
            return
        }
        formulaStructureSelection = []
        pencilRecognition = Inf6HandwrittenMathMLResult(
            tokenIDs: tokenIDs,
            decodedExpression: "",
            mathML: "",
            grid9: recognition.grid9,
            symbolLabels: labels,
            symbolGridCellIndices: recognition.symbolGridCellIndices,
            symbolStrokeIndices: recognition.symbolStrokeIndices,
            candidateRanks: candidateRanks,
            candidateLabels: recognition.candidateLabels,
            candidateModelName: recognition.candidateModelName,
            candidateCalibrationSHA256: recognition.candidateCalibrationSHA256,
            fold7Top5ClassIndices: recognition.fold7Top5ClassIndices,
            fold7Top5Logits: recognition.fold7Top5Logits,
            fold7SimilarityCandidates: recognition.fold7SimilarityCandidates,
            typesetCandidates: recognition.typesetCandidates,
            spatialAnalysis: recognition.spatialAnalysis,
            positionSensitiveClassification: recognition.positionSensitiveClassification,
            similarityExpansion: recognition.similarityExpansion,
            isProvisional: true
        )
        pencilRecognitionError = "候補を更新しました。記号欄をタップして構造順を選び、関係を指定してください。"
    }

    private func _recognitionClassIndex(_ recognition: Inf6HandwrittenMathMLResult, symbolIndex: Int, label: String) -> Int? {
        guard let spatialAnalysis = recognition.spatialAnalysis,
              spatialAnalysis.symbols.indices.contains(symbolIndex) else { return nil }
        let spatialSymbol = spatialAnalysis.symbols[symbolIndex]
        if let modelCandidate = spatialSymbol.candidates.first(where: { $0.label == label }) {
            return modelCandidate.classIndex
        }
        let symbolID = "symbol-\(symbolIndex)"
        if let similarCandidate = recognition.similarityExpansion?.symbols
            .first(where: { $0.sourceSymbolID == symbolID })?.supplements
            .first(where: { $0.label == label }) {
            return similarCandidate.classIndex
        }
        if let ruleCandidate = recognition.positionSensitiveClassification?.symbols
            .first(where: { $0.sourceSymbolID == symbolID })?.ruleSupplements?
            .first(where: { $0.label == label }) {
            return ruleCandidate.classIndex
        }
        guard recognition.typesetCandidates.indices.contains(symbolIndex) else { return nil }
        return recognition.typesetCandidates[symbolIndex]
            .first(where: { $0.label == label })?.classIndex
    }

    private func _composeRecognitionStructure(kind: FormulaStructure.Kind) {
        guard let recognition = pencilRecognition,
              recognition.isProvisional,
              let draft = formulaStructureDraft else { return }
        let selectedNodeIDs = formulaStructureSelection
        guard !selectedNodeIDs.isEmpty else {
            pencilRecognitionError = Inf6Lang.text("構造化する候補または部分式を順に選択してください。", "Select candidates or subexpressions in order.")
            return
        }
        do {
            let scopeID = formulaStructureScopeStack.last ?? draft.rootID
            let structure = try FormulaStructureEditor().combine(draft, in: scopeID, kind: kind, selectedNodeIDs: selectedNodeIDs)
            formulaStructureDraft = structure
            formulaStructureSelection = []
            pencilRecognitionError = Inf6Lang.text("構造を追加しました。必要な記号をすべて接続後に「構造を検証して保存」を選択してください。", "Structure added. Connect all required symbols, then verify and save.")
        } catch {
            pencilRecognitionError = Inf6Lang.text("選択した数式構造を追加できません: \(error.localizedDescription)", "Could not add the selected structure: \(error.localizedDescription)")
        }
    }

    private func _confirmRecognitionStructure() {
        guard let recognition = pencilRecognition,
              recognition.isProvisional,
              let structure = formulaStructureDraft else { return }
        do {
            let verified = try FormulaStructureComposer().compose(structure)
            let confirmedResult = Inf6HandwrittenMathMLResult(
                tokenIDs: recognition.tokenIDs,
                decodedExpression: verified.latex,
                mathML: verified.mathML,
                grid9: recognition.grid9,
                symbolLabels: recognition.symbolLabels,
                symbolGridCellIndices: recognition.symbolGridCellIndices,
                symbolStrokeIndices: recognition.symbolStrokeIndices,
                candidateRanks: recognition.candidateRanks,
                candidateLabels: recognition.candidateLabels,
                candidateModelName: recognition.candidateModelName,
                candidateCalibrationSHA256: recognition.candidateCalibrationSHA256,
                fold7Top5ClassIndices: recognition.fold7Top5ClassIndices,
                fold7Top5Logits: recognition.fold7Top5Logits,
                fold7SimilarityCandidates: recognition.fold7SimilarityCandidates,
                typesetCandidates: recognition.typesetCandidates,
                spatialAnalysis: recognition.spatialAnalysis,
                positionSensitiveClassification: recognition.positionSensitiveClassification,
                similarityExpansion: recognition.similarityExpansion,
                isProvisional: false
            )
            if inlineFormulaCapture != nil {
                _commitConfirmedInlineFormula(confirmedResult, structure: structure)
                return
            }
            let handwritingEvidence = try _makePencilRecognitionEvidence(
                drawingData: pencilDrawing.dataRepresentation(),
                result: confirmedResult,
                structureKind: "nested",
                structureOrder: nil
            )
            guard _saveRecognitionResult(
                confirmedResult,
                drawingData: pencilDrawing.dataRepresentation(),
                inputMethod: .handwriting,
                handwritingEvidence: handwritingEvidence,
                formulaStructure: structure
            ) else {
                return
            }
            pencilRecognition = confirmedResult
            formulaStructureDraft = structure
            pencilRecognitionError = nil
            formulaStructureSelection = []
            isCandidatePopoverPresented = false
        } catch {
            pencilRecognitionError = Inf6Lang.text("数式構造を検証または保存準備できません: \(error.localizedDescription)", "Could not verify or prepare the structure for saving: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func _commitConfirmedInlineFormula(
        _ recognition: Inf6HandwrittenMathMLResult,
        structure: FormulaStructure?
    ) -> Bool {
        guard let capture = inlineFormulaCapture,
              _inlineCaptureIsCurrent else {
            pencilRecognitionError = Inf6Lang.text(
                "入力範囲または編集中の発言が変わったため、数式を挿入しませんでした。元の文章は保持されています。",
                "The insertion range or edited message changed; the formula was not inserted. Existing text is preserved."
            )
            return false
        }
        do {
            try MathMLValidator().validate(recognition.mathML)
            let token = try _newInlineFormulaToken()
            let evidence = try _makePencilRecognitionEvidence(
                drawingData: capture.drawingData,
                result: recognition,
                structureKind: structure == nil ? nil : "nested"
            )
            guard _saveRecognitionResult(
                recognition,
                drawingData: capture.drawingData,
                inputMethod: .handwriting,
                handwritingEvidence: evidence,
                formulaStructure: structure,
                storeIdentifier: "chat-\(capture.id.uuidString)"
            ) else { return false }

            let insertion = token
            let current = chatQuestion as NSString
            let previousQuestion = chatQuestion
            let previousSelection = chatSelectionRange
            let updated = current.replacingCharacters(in: capture.range, with: insertion)
            chatQuestion = updated
            chatSelectionRange = NSRange(
                location: capture.range.location + (insertion as NSString).length,
                length: 0
            )
            inlineFormulaReferences.append(InlineFormulaReference(
                token: token,
                expression: recognition.decodedExpression,
                mathML: recognition.mathML,
                derivationID: "chat-\(capture.id.uuidString)",
                sourcePartID: nil
            ))
            guard _persistChat() else {
                chatQuestion = previousQuestion
                chatSelectionRange = previousSelection
                inlineFormulaReferences.removeLast()
                let derivationURL = Inf6DataRoot.url()
                    .appendingPathComponent("derivations", isDirectory: true)
                    .appendingPathComponent("chat-\(capture.id.uuidString).json")
                var cleanupFailure: String?
                if FileManager.default.fileExists(atPath: derivationURL.path) {
                    do {
                        try FileManager.default.removeItem(at: derivationURL)
                    } catch {
                        cleanupFailure = Inf6Lang.text(
                            "未参照の数式導出を削除できませんでした: \(error.localizedDescription)",
                            "Could not remove the unreferenced derivation: \(error.localizedDescription)"
                        )
                    }
                }
                let recoveryDetail = [chatError, cleanupFailure].compactMap { $0 }.joined(separator: " / ")
                pencilRecognitionError = Inf6Lang.text(
                    "チャットを保存できませんでした。入力文を保持しました。\(recoveryDetail)",
                    "The chat could not be saved. The original text is retained. \(recoveryDetail)"
                )
                return false
            }
            formulaExpression = recognition.decodedExpression
            formulaMathML = recognition.mathML
            pencilRecognitionGeneration &+= 1
            pencilRecognitionTask?.cancel()
            pencilRecognitionTask = nil
            pencilRecognitionRunning = false
            pencilRecognition = nil
            formulaStructureDraft = nil
            formulaStructureScopeStack = []
            formulaStructureSelection = []
            inlineFormulaCapture = nil
            chatError = nil
            return true
        } catch {
            pencilRecognitionError = Inf6Lang.text(
                "数式を検証・保存・挿入できませんでした。入力文は変更していません: \(error.localizedDescription)",
                "The formula could not be validated, saved, and inserted. Existing text is unchanged: \(error.localizedDescription)"
            )
            return false
        }
    }

    private func _toggleFormulaStructureSelection(_ nodeID: String) {
        if let selectionIndex = formulaStructureSelection.firstIndex(of: nodeID) {
            formulaStructureSelection.remove(at: selectionIndex)
        } else {
            formulaStructureSelection.append(nodeID)
        }
    }

    private var _currentPaperEquationSpace: PaperEquationSpace? {
        try? _makeCurrentPaperEquationSpace()
    }

    private func _makeCurrentPaperEquationSpace(
        recognition: Inf6HandwrittenMathMLResult? = nil
    ) throws -> PaperEquationSpace {
        let currentRecognition = recognition ?? pencilRecognition
        let equationID = entity.id.uuidString
        let pageID = isNodeExplanationItem
            ? "\(paperID):item:\(entity.id.uuidString)"
            : "\(paperID):page:\(entity.pageIndex)"
        let recognizedExpression = currentRecognition?.decodedExpression.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let expression = !recognizedExpression.isEmpty
            ? recognizedExpression
            : (formulaExpression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? entity.paperFormulaExpression
            : formulaExpression)
        let labels = currentRecognition?.symbolLabels ?? []
        let cells = currentRecognition?.symbolGridCellIndices ?? []
        let symbols: [PaperEquationSymbol] = labels.enumerated().map { index, label in
            let cell = index < cells.count ? cells[index] : 0
            return PaperEquationSymbol(
                id: "\(equationID):symbol:\(index)",
                token: label,
                role: "recognized-candidate",
                allowedGridCells: (1...9).contains(cell) ? [cell] : []
            )
        }
        let relations: [PaperEquationRelation] = symbols.indices.dropFirst().compactMap { index in
            guard index < cells.count, index - 1 < cells.count else { return nil }
            let previousCell = cells[index - 1]
            let currentCell = cells[index]
            guard (1...9).contains(previousCell), (1...9).contains(currentCell) else { return nil }
            let previousRow = (previousCell - 1) / 3
            let currentRow = (currentCell - 1) / 3
            let kind: String
            if currentRow < previousRow {
                kind = "superscript-candidate"
            } else if currentRow > previousRow {
                kind = "subscript-candidate"
            } else {
                kind = "spatial-order"
            }
            return PaperEquationRelation(
                sourceSymbolID: symbols[index - 1].id,
                targetSymbolID: symbols[index].id,
                kind: kind
            )
        }
        let equation = PaperEquation(
            id: equationID,
            pageID: pageID,
            sourceLocator: isNodeExplanationItem
                ? "\(paperID)#item=\(entity.id.uuidString)"
                : "\(paperID)#page=\(entity.pageIndex + 1)",
            latex: expression,
            mathML: currentRecognition?.mathML ?? entity.paperFormulaMathML,
            symbols: symbols,
            relations: relations
        )
        let page = PaperEquationPage(
            id: pageID,
            pageIndex: entity.pageIndex,
            equationIDs: [equationID]
        )
        let space = PaperEquationSpace(
            id: paperID,
            paperTitle: paperTitle,
            version: "entity-v2-spatial-recognition",
            pages: [page],
            equations: [equation]
        )
        return try space.validated()
    }

    private func _emptyFormulaGrid9() -> Inf6FormulaGrid9 {
        let margin = (1 - gridCenterFraction) / 2
        let edges: [CGFloat] = [0, margin, 1 - margin, 1]
        let cells = (0..<9).map { index in
            let row = index / 3
            let column = index % 3
            return Inf6FormulaGrid9.Cell(
                index: index + 1,
                row: row,
                column: column,
                strokeCount: 0,
                strokeIndices: [],
                normalizedBounds: CGRect(
                    x: edges[column],
                    y: edges[row],
                    width: edges[column + 1] - edges[column],
                    height: edges[row + 1] - edges[row]
                )
            )
        }
        return Inf6FormulaGrid9(cells: cells)
    }

    private func _selectFormulaPaletteItem(_ item: FormulaPaletteItem) {
        do {
            let currentExpression = pencilRecognition?.decodedExpression
                ?? formulaExpression
            let expression = Inf6MathMLStructureComposer.apply(
                itemID: item.id,
                itemExpression: item.expression,
                to: currentExpression
            )
            let mathML = try LaTeXMathMLConverter().convert(expression)
            let grid = _emptyFormulaGrid9()
            let result = Inf6HandwrittenMathMLResult(
                tokenIDs: [],
                decodedExpression: expression,
                mathML: mathML,
                grid9: grid,
                symbolLabels: [expression],
                symbolGridCellIndices: selectedFormulaGridCell.map { [$0] } ?? [],
                candidateRanks: [0],
                candidateLabels: [[expression]],
                isProvisional: false
            )
            pencilRecognitionGeneration += 1
            pencilRecognitionTask?.cancel()
            pencilRecognitionTask = nil
            pencilRecognitionRunning = false
            pencilRecognitionError = nil
            isCandidatePopoverPresented = false
            isFormulaPalettePresented = false
            pencilRedoDrawing = pencilDrawing.strokes.isEmpty ? nil : pencilDrawing
            pencilDrawing = PKDrawing()
            formulaStructureDraft = nil
            formulaStructureScopeStack = []
            formulaStructureSelection = []
            pencilRecognition = result
        } catch {
            pencilRecognitionError = "選択した記号をMathMLに変換できません: \(error.localizedDescription)"
        }
    }

    private var _inlineCaptureIsCurrent: Bool {
        guard let capture = inlineFormulaCapture,
              capture.entityID == entity.id,
              capture.paperID == paperID,
              capture.chapterID == chapterID,
              chatQuestion == capture.originalText,
              chatSelectionRange == capture.range,
              editingChatMessageIndex == capture.editingMessageIndex else { return false }
        if let index = capture.editingMessageIndex {
            guard chatMessages.indices.contains(index),
                  chatMessages[index] == capture.editingMessage else { return false }
        }
        return true
    }

    private func _cancelActiveFormulaComposition() {
        if inlineFormulaCapture != nil {
            _cancelInlineFormulaRecognition()
        }
    }

    @discardableResult
    private func _updateInlineFormulaMathML(_ token: String, mathML: String) -> Bool {
        guard inlineFormulaReferences.filter({ $0.token == token }).count == 1,
              (chatQuestion as NSString).range(of: token).location != NSNotFound else {
            pencilRecognitionError = Inf6Lang.text(
                "編集対象の数式を一意に特定できません。変更を保存していません。",
                "The formula edit target is not unique. The change was not saved."
            )
            return false
        }
        do {
            try MathMLValidator().validate(mathML)
            let previousReferences = inlineFormulaReferences
            inlineFormulaReferences = inlineFormulaReferences.map { reference in
                guard reference.token == token else { return reference }
                return InlineFormulaReference(
                    token: reference.token,
                    expression: nil,
                    mathML: mathML,
                    derivationID: nil,
                    sourcePartID: reference.sourcePartID
                )
            }
            guard _persistChat() else {
                inlineFormulaReferences = previousReferences
                return false
            }
            pencilRecognitionError = nil
            return true
        } catch {
            pencilRecognitionError = Inf6Lang.text(
                "編集途中の数式はまだ保存できません: \(error.localizedDescription)",
                "The in-progress formula is not valid for saving yet: \(error.localizedDescription)"
            )
            return false
        }
    }

    private func _beginInlineFormulaRecognition(
        drawing: PKDrawing,
        range: NSRange,
        originalText: String,
        surfaceSize: CGSize
    ) {
        guard !drawing.strokes.isEmpty else {
            pencilRecognitionError = Inf6Lang.text("手書きストロークがありません。", "No handwriting strokes were captured.")
            return
        }
        let textLength = (originalText as NSString).length
        guard range.location >= 0,
              range.length >= 0,
              range.location <= textLength,
              range.location + range.length <= textLength,
              chatQuestion == originalText else {
            pencilRecognitionError = Inf6Lang.text("入力内容が変わったため、数式を認識しませんでした。元の入力は保持されています。", "The composer changed; handwriting was not applied. Existing text is preserved.")
            return
        }
        pencilRecognitionGeneration &+= 1
        pencilRecognitionTask?.cancel()
        pencilRecognitionRunning = false
        let capture = InlineFormulaCapture(
            id: UUID(),
            drawingData: drawing.dataRepresentation(),
            originalText: originalText,
            range: range,
            editingMessageIndex: editingChatMessageIndex,
            editingMessage: editingChatMessageIndex.flatMap { chatMessages.indices.contains($0) ? chatMessages[$0] : nil },
            entityID: entity.id,
            paperID: paperID,
            chapterID: chapterID,
            surfaceSize: surfaceSize,
            priorDrawing: pencilDrawing,
            priorSurfaceSize: pencilSurfaceSize,
            priorRecognition: pencilRecognition,
            priorRecognitionError: pencilRecognitionError,
            priorStructureDraft: formulaStructureDraft,
            priorStructureScopeStack: formulaStructureScopeStack,
            priorStructureSelection: formulaStructureSelection
        )
        inlineFormulaCapture = capture
        chatSelectionRange = range
        pencilDrawing = drawing
        pencilSurfaceSize = surfaceSize
        pencilRecognition = nil
        pencilRecognitionError = nil
        formulaStructureDraft = nil
        formulaStructureScopeStack = []
        formulaStructureSelection = []
        pencilRecognitionGeneration &+= 1
        _recognizePencilDrawing(generation: pencilRecognitionGeneration)
    }

    private func _retryInlineFormulaRecognition() {
        guard let capture = inlineFormulaCapture,
              _inlineCaptureIsCurrent else {
            pencilRecognitionError = Inf6Lang.text("入力位置または編集中の発言が変わりました。手書き数式をもう一度入力してください。", "The insertion point or edited message changed. Write the formula again.")
            return
        }
        do {
            pencilDrawing = try PKDrawing(data: capture.drawingData)
            pencilSurfaceSize = capture.surfaceSize
            pencilRecognitionGeneration &+= 1
            _recognizePencilDrawing(generation: pencilRecognitionGeneration)
        } catch {
            pencilRecognitionError = Inf6Lang.text("保存したストロークを再読込できません: \(error.localizedDescription)", "Could not reload captured strokes: \(error.localizedDescription)")
        }
    }

    private func _cancelInlineFormulaRecognition() {
        pencilRecognitionGeneration &+= 1
        pencilRecognitionTask?.cancel()
        pencilRecognitionTask = nil
        pencilRecognitionRunning = false
        guard let capture = inlineFormulaCapture else { return }
        pencilDrawing = capture.priorDrawing
        pencilSurfaceSize = capture.priorSurfaceSize
        pencilRecognition = capture.priorRecognition
        pencilRecognitionError = capture.priorRecognitionError
        formulaStructureDraft = capture.priorStructureDraft
        formulaStructureScopeStack = capture.priorStructureScopeStack
        formulaStructureSelection = capture.priorStructureSelection
        inlineFormulaCapture = nil
    }

    private func _recognizePencilDrawing(generation: Int) {
        guard generation == pencilRecognitionGeneration,
              !pencilDrawing.strokes.isEmpty else { return }
        NSLog("[Inf6Codex] recognition start generation=%d strokes=%d", generation, pencilDrawing.strokes.count)
        pencilRecognitionRunning = true
        pencilRecognitionError = nil
        let drawingData = pencilDrawing.dataRepresentation()
        let centerFraction = gridCenterFraction
        let surfaceSize = pencilSurfaceSize
        pencilRecognitionTask = Task { @MainActor in
            let recognitionTask = Task.detached(priority: .userInitiated) { () -> (Inf6HandwrittenMathMLResult?, String?) in
                do {
                    let drawing = try PKDrawing(data: drawingData)
                    let result = try Inf6HandwrittenFormulaRecognition.recognize(
                        drawing: drawing,
                        centerFraction: centerFraction,
                        surfaceSize: surfaceSize,
                        cancellationCheck: { Task.isCancelled }
                    )
                    return (result, nil)
                } catch {
                    return (nil, error.localizedDescription)
                }
            }
            let outcome = await withTaskCancellationHandler(operation: {
                await recognitionTask.value
            }, onCancel: {
                recognitionTask.cancel()
            })
            guard !Task.isCancelled, generation == pencilRecognitionGeneration else {
                if generation == pencilRecognitionGeneration {
                    pencilRecognitionRunning = false
                }
                return
            }
            if inlineFormulaCapture != nil, !_inlineCaptureIsCurrent {
                pencilRecognition = nil
                pencilRecognitionRunning = false
                pencilRecognitionError = Inf6Lang.text(
                    "認識中に文章・カーソル・編集中の発言が変わりました。元の文章は変更していません。手書き数式を再入力してください。",
                    "The text, caret, or edited message changed during recognition. Existing text was not changed; write the formula again."
                )
                return
            }
            if let result = outcome.0 {
                NSLog("[Inf6Codex] recognition success generation=%d symbols=%@", generation, result.symbolLabels.joined(separator: ","))
                if result.isProvisional {
                    do {
                        formulaStructureDraft = try FormulaStructureEditor().makeDraft(labels: result.symbolLabels)
                        formulaStructureScopeStack = ["root"]
                        formulaStructureSelection = []
                    } catch {
                        pencilRecognition = nil
                        pencilRecognitionError = "認識候補の構造編集を開始できません: \(error.localizedDescription)"
                        pencilRecognitionRunning = false
                        return
                    }
                } else {
                    formulaStructureDraft = nil
                    formulaStructureScopeStack = []
                    formulaStructureSelection = []
                }
                pencilRecognition = result
            } else if let message = outcome.1 {
                NSLog("[Inf6Codex] recognition failure generation=%d error=%@", generation, message)
                pencilRecognition = nil
                pencilRecognitionError = message
            }
            pencilRecognitionRunning = false
        }
    }

    private func _makePencilRecognitionEvidence(
        drawingData: Data,
        result: Inf6HandwrittenMathMLResult,
        structureKind: String? = nil,
        structureOrder: [Int]? = nil
    ) throws -> Data {
        let symbolStrokeIndices = result.symbolStrokeIndices
        guard symbolStrokeIndices.count == result.symbolLabels.count,
              !symbolStrokeIndices.isEmpty else {
            throw Inf6HandwrittenFormulaError.invalidInput("認識結果に記号ストローク対応がありません")
        }
        let drawing = try PKDrawing(data: drawingData)
        var samples: [Inf6CanonicalSample] = []
        samples.reserveCapacity(symbolStrokeIndices.count)
        for strokeIndices in symbolStrokeIndices {
            guard !strokeIndices.isEmpty,
                  strokeIndices.allSatisfy(drawing.strokes.indices.contains) else {
                throw Inf6HandwrittenFormulaError.invalidInput("認識結果のストローク対応が不正です")
            }
            let strokes = strokeIndices.map { drawing.strokes[$0] }
            samples.append(try Inf6NonAutoregressiveSymbolRecognizer.canonicalSample(
                for: strokes,
                allStrokes: drawing.strokes,
                cancellationCheck: { false }
            ))
        }
        guard let segmenterManifestURL = Bundle.main.url(forResource: "HinotoriFormulaSegmenter.manifest", withExtension: "json"),
              let classifierManifestURL = Bundle.main.url(forResource: "HinotoriFold7CoreML.manifest", withExtension: "json") else {
            throw Inf6HandwrittenFormulaError.modelUnavailable("HinotoriFormulaSegmenter.manifest.json または HinotoriFold7CoreML.manifest.json")
        }
        let segmenterManifest = try JSONDecoder().decode(
            Inf6PencilSegmenterManifest.self,
            from: Data(contentsOf: segmenterManifestURL)
        )
        let classifierManifest = try JSONDecoder().decode(
            Inf6PencilClassifierManifest.self,
            from: Data(contentsOf: classifierManifestURL)
        )
        guard segmenterManifest.format == "hinotori-formula-frame-pair-segmenter-coreml-v2",
              segmenterManifest.modelName == "HinotoriFormulaSegmenter",
              segmenterManifest.checkpointSHA256 == HinotoriFormulaFold7Engine.checkpointSHA256,
              segmenterManifest.selectedEpoch == HinotoriFormulaFold7Engine.selectedEpoch,
              segmenterManifest.validationThreshold == HinotoriFormulaFold7Engine.validationThreshold,
              segmenterManifest.decode.algorithm == "average-linkage",
              segmenterManifest.decode.positivePairLogitThreshold == HinotoriFormulaFold7Engine.partitionThreshold,
              classifierManifest.checkpoint.sha256 == HinotoriFold7CoreMLClassifier.checkpointSHA256,
              classifierManifest.checkpoint.epoch == HinotoriFold7CoreMLClassifier.selectedEpoch,
              let spatialAnalysis = result.spatialAnalysis,
              let similarityExpansion = result.similarityExpansion,
              let positionClassification = result.positionSensitiveClassification,
              spatialAnalysis.symbols.count == result.symbolLabels.count,
              similarityExpansion.symbols.count == result.symbolLabels.count,
              positionClassification.symbols.count == result.symbolLabels.count else {
            throw Inf6HandwrittenFormulaError.invalidModelInterface("保存する分割・分類モデル版または候補判定の記号数が認識結果と一致しません")
        }
        let evidence = Inf6PencilRecognitionEvidence(
            format: "hinotori-pencil-recognition-evidence-v1",
            createdAt: Date(),
            drawingDataBase64: drawingData.base64EncodedString(),
            samples: samples,
            symbolStrokeIndices: symbolStrokeIndices,
            segmenter: .init(
                name: "HinotoriFormulaSegmenter",
                checkpointSHA256: segmenterManifest.checkpointSHA256,
                epoch: segmenterManifest.selectedEpoch
            ),
            classifier: .init(
                name: "HinotoriFold7Classifier",
                checkpointSHA256: classifierManifest.checkpoint.sha256,
                epoch: classifierManifest.checkpoint.epoch
            ),
            ensembleModelName: result.candidateModelName,
            ensembleCalibrationSHA256: result.candidateCalibrationSHA256,
            fold7Top5ClassIndices: result.fold7Top5ClassIndices,
            fold7Top5Logits: result.fold7Top5Logits,
            segmentationThreshold: segmenterManifest.decode.positivePairLogitThreshold,
            recognizedExpression: result.decodedExpression,
            selectedSymbolLabels: result.symbolLabels,
            candidateLabels: result.candidateLabels,
            typesetCandidates: result.typesetCandidates,
            modelCandidates: spatialAnalysis.symbols.map(\.candidates),
            similarityExpansion: similarityExpansion,
            positionClassification: positionClassification,
            spatialAnalysis: spatialAnalysis,
            structureKind: structureKind,
            structureOrder: structureOrder
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(evidence)
    }

    private func _schedulePencilRecognition(finishedStrokePointCount: Int) {
        pencilRecognitionGeneration += 1
        let generation = pencilRecognitionGeneration
        NSLog("[Inf6Codex] recognition scheduled generation=%d strokes=%d", generation, pencilDrawing.strokes.count)
        pencilRecognitionTask?.cancel()
        pencilRecognitionError = nil
        // Do not keep displaying a result for a drawing that is being edited.
        // Recognition is retriggered only after the input has been idle long
        // enough for the user to finish a multi-stroke symbol.
        pencilRecognition = nil
        formulaStructureDraft = nil
        formulaStructureScopeStack = []
        formulaStructureSelection = []
        guard !pencilDrawing.strokes.isEmpty else {
            pencilRecognitionRunning = false
            return
        }
        if finishedStrokePointCount >= 2 {
            do {
                try _savePencilInputEvidence(
                    drawingData: pencilDrawing.dataRepresentation(),
                    finishedStrokePointCount: finishedStrokePointCount
                )
            } catch {
                pencilRecognitionRunning = false
                pencilRecognitionError = "手書き入力証拠を保存できません: \(error.localizedDescription)"
                NSLog("[Inf6Codex] input evidence export failed: %@", error.localizedDescription)
                return
            }
        }
        pencilRecognitionRunning = true
        pencilRecognitionTask = Task { @MainActor in
            // Do not recognize between strokes of one handwritten formula.
            // The previous 350ms window produced intermediate expressions
            // while the user was still writing the next symbol.
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            guard generation == pencilRecognitionGeneration else { return }
            _recognizePencilDrawing(generation: generation)
        }
    }

    private func _savePencilInputEvidence(
        drawingData: Data,
        finishedStrokePointCount: Int
    ) throws {
        let drawing = try PKDrawing(data: drawingData)
        guard !drawing.strokes.isEmpty, finishedStrokePointCount >= 2 else {
            throw Inf6HandwrittenFormulaError.invalidInput("保存対象の手書きストロークが不正です")
        }
        let evidenceDirectory = try Inf6UserSettingRootPaths.inf6Directory(
            ["derivations", "handwriting_input"],
            createIfNeeded: true
        )
        let evidence = Inf6PencilInputEvidence(
            format: "inf6-pencil-input-evidence-v1",
            createdAt: Date(),
            drawingDataBase64: drawingData.base64EncodedString(),
            drawingStrokeCount: drawing.strokes.count,
            finishedStrokePointCount: finishedStrokePointCount,
            surfaceWidth: pencilSurfaceSize.width,
            surfaceHeight: pencilSurfaceSize.height,
            gridCenterFraction: gridCenterFraction
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(evidence)
        let evidenceFileName = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: _derivationIdentifier)
        guard !evidenceFileName.isEmpty else {
            throw Inf6HandwrittenFormulaError.invalidInput("認識証拠の識別子が不正です")
        }
        let destination = evidenceDirectory.appendingPathComponent("\(evidenceFileName).json")
        let temporary = evidenceDirectory.appendingPathComponent(".\(evidenceFileName).tmp")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        NSLog("[Inf6Codex] input evidence exported path=%@ strokes=%d points=%d", destination.path, drawing.strokes.count, finishedStrokePointCount)
    }

    private var _derivationIdentifier: String {
        if origin == .userAuthored, let userDerivationID {
            return "user-\(userDerivationID.uuidString)"
        }
        return "\(paperID)-\(entity.id.uuidString)"
    }

    private func _loadSavedDerivation() {
        do {
            let root = try Inf6UserSettingRootPaths.userSettingRootDirectory(create: false)
            let store = DerivationStore(root: root, identifier: _derivationIdentifier)
            let document = try store.load()
            if origin == .userAuthored {
                guard document.derivationID != nil else { return }
                try _restoreUserAuthoredDerivation(document)
                return
            }
            pencilDrawing = PKDrawing()
            pencilRecognition = nil
            formulaStructureDraft = nil
            formulaStructureScopeStack = []
            formulaStructureSelection = []
            let currentSpace: PaperEquationSpace
            do {
                currentSpace = try _makeCurrentPaperEquationSpace()
            } catch {
                pencilRecognition = nil
                pencilRecognitionError = "保存済み数式空間を検証できませんでした: \(error.localizedDescription)"
                return
            }
            guard let savedSpace = document.paperEquationSpace else {
                pencilRecognition = nil
                pencilRecognitionError = "保存済み数式空間がありません。数式を再入力してください。"
                return
            }
            guard document.mathMLVerified == true,
                  document.paperEquationSpaceID == currentSpace.id,
                  document.paperEquationID == currentSpace.equations.first?.id,
                  let expression = document.recognizedExpression,
                  let mathML = document.mathML else {
                pencilRecognition = nil
                pencilRecognitionError = "保存済み認識結果の検証情報が不足しているか、現在の論文・数式対象と一致しないため、再読込しません。数式を再入力してください。"
                return
            }
            let inputMethod = document.inputMethod ?? .handwriting
            if inputMethod == .handwriting || inputMethod == .mixed {
                guard let grid9 = document.grid9, grid9.isStructurallyValid else {
                    pencilRecognition = nil
                    pencilRecognitionError = "保存済み手書き数式の位置検証情報が不足しているため、再入力してください。"
                    return
                }
            }
            guard savedSpace.id == currentSpace.id,
                  savedSpace.equations.first?.id == currentSpace.equations.first?.id else {
                pencilRecognition = nil
                pencilRecognitionError = "保存済み数式空間の論文・数式IDが現在の対象と一致しません。数式を再入力してください。"
                return
            }
            do {
                _ = try savedSpace.validated()
                let validator = MathMLValidator()
                try validator.validate(mathML)
                for equation in savedSpace.equations {
                    if let equationMathML = equation.mathML {
                        try validator.validate(equationMathML)
                    }
                }
            } catch {
                pencilRecognition = nil
                pencilRecognitionError = "保存済みMathMLまたは数式空間の検証に失敗しました: \(error.localizedDescription)"
                return
            }
            formulaExpression = expression
            formulaMathML = mathML
            // Restore structural editing only after every persisted component
            // below has been revalidated against the saved MathML artifact.
            pencilRecognitionError = nil
            let savedLabels = document.recognizedSymbols ?? [expression]
            let savedCells = document.recognizedGridCellIndices ?? []
            guard Inf6NonAutoregressiveSymbolRecognizer.containsSupportedFormulaTokenSequence(in: savedLabels),
                  !savedLabels.isEmpty else {
                pencilRecognition = nil
                pencilRecognitionError = "保存済み認識結果の数式記号が受入条件を満たさないため、再読込しません。数式を再入力してください。"
                return
            }
            if inputMethod == .handwriting || inputMethod == .mixed {
                guard savedLabels.count == savedCells.count,
                      savedCells.allSatisfy({ (1...9).contains($0) }) else {
                    pencilRecognition = nil
                    pencilRecognitionError = "保存済み手書き数式の記号位置が不正なため、再入力してください。"
                    return
                }
            }
            guard let structure = document.formulaStructure else {
                // Legacy artifacts remain readable but do not claim that they
                // can be structurally edited without a saved structure graph.
                pencilRecognition = nil
                return
            }
            guard let drawingData = document.pencilDrawingData,
                  let savedStrokeIndices = document.recognizedSymbolStrokeIndices,
                  savedStrokeIndices.count == savedLabels.count else {
                pencilRecognition = nil
                pencilRecognitionError = "保存済み構造の手書きストローク対応がないため編集できません。"
                return
            }
            let restoredDrawing = try PKDrawing(data: drawingData)
            guard savedStrokeIndices.allSatisfy({ !$0.isEmpty && $0.allSatisfy(restoredDrawing.strokes.indices.contains) }) else {
                pencilRecognition = nil
                pencilRecognitionError = "保存済み構造の手書きストローク対応が不正なため編集できません。"
                return
            }
            if let spatialAnalysis = document.spatialAnalysis {
                do {
                    try Inf6SpatialRelationAnalyzer.validate(
                        spatialAnalysis,
                        symbolLabels: savedLabels,
                        symbolStrokeIndices: savedStrokeIndices
                    )
                } catch {
                    pencilRecognition = nil
                    pencilRecognitionError = "保存済み位置関係候補を検証できないため編集できません: \(error.localizedDescription)"
                    return
                }
            }
            let restoredCandidates: [[String]]
            let restoredCandidateRanks: [Int?]
            if let spatialAnalysis = document.spatialAnalysis,
               let classification = document.positionSensitiveClassification,
               let similarity = document.similarityExpansion {
                restoredCandidates = try Inf6PositionSensitiveSymbolClassifier.candidateLabels(
                    analysis: spatialAnalysis,
                    classification: classification,
                    similarityExpansion: similarity
                )
                guard spatialAnalysis.symbols.count == savedLabels.count else {
                    throw DerivationError.positionSensitiveClassificationVerificationFailed
                }
                restoredCandidateRanks = zip(savedLabels, spatialAnalysis.symbols).map { selectedLabel, symbol in
                    symbol.candidates.firstIndex(where: { $0.label == selectedLabel })
                }
            } else {
                guard document.spatialAnalysis == nil,
                      document.positionSensitiveClassification == nil,
                      document.similarityExpansion == nil else {
                    throw DerivationError.similarityExpansionVerificationFailed
                }
                restoredCandidates = savedLabels.map { [$0] }
                restoredCandidateRanks = Array(repeating: 0, count: savedLabels.count)
            }
            let verifiedStructure = try FormulaStructureComposer().compose(structure)
            guard verifiedStructure.latex == expression,
                  verifiedStructure.mathML == mathML else {
                pencilRecognition = nil
                pencilRecognitionError = "保存済み構造と検証済み数式が一致しないため編集できません。"
                return
            }
            pencilDrawing = restoredDrawing
            formulaStructureDraft = structure
            formulaStructureScopeStack = [structure.rootID]
            formulaStructureSelection = []
            pencilRecognition = Inf6HandwrittenMathMLResult(
                tokenIDs: (document.recognizedTokenIDs ?? []).map(Int32.init),
                decodedExpression: "",
                mathML: "",
                grid9: document.grid9 ?? _emptyFormulaGrid9(),
                symbolLabels: savedLabels,
                symbolGridCellIndices: savedCells,
                symbolStrokeIndices: savedStrokeIndices,
                candidateRanks: restoredCandidateRanks,
                candidateLabels: restoredCandidates,
                spatialAnalysis: document.spatialAnalysis,
                positionSensitiveClassification: document.positionSensitiveClassification,
                similarityExpansion: document.similarityExpansion,
                isProvisional: true
            )
            pencilRecognitionError = "保存済み構造を編集できます。変更後は構造を検証して保存してください。"
        } catch {
            // A missing saved document is a normal first-use state. Any other
            // read failure must remain visible instead of silently discarding
            // a persisted derivation or masking a corrupted artifact.
            if case DerivationError.rootUnavailable = error {
                pencilRecognition = nil
                pencilRecognitionError = "保存済み数式を再読込できません。User Setting Rootが利用できません。"
                return
            }
            pencilRecognition = nil
            pencilRecognitionError = "保存済み数式を再読込できませんでした: \(error.localizedDescription)"
        }
    }

    private func _restoreUserAuthoredDerivation(_ document: DerivationDocument) throws {
        guard let userDerivationID,
              document.derivationID == userDerivationID,
              document.origin == .userAuthored,
              document.sourceEvidenceID == nil,
              document.sourceTitle == nil,
              document.sourceLocator == nil,
              document.paperEquationSpaceID == nil,
              document.paperEquationID == nil,
              document.paperEquationSpace == nil else {
            throw DerivationError.derivationIdentityVerificationFailed
        }
        guard document.mathMLVerified == true,
              let expression = document.recognizedExpression,
              !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let mathML = document.mathML,
              let structure = document.formulaStructure,
              let inputMethod = document.inputMethod,
              inputMethod != .paper else {
            throw DerivationError.formulaStructureVerificationFailed
        }
        let labels = document.recognizedSymbols ?? []
        guard !labels.isEmpty,
              Inf6NonAutoregressiveSymbolRecognizer.containsSupportedFormulaTokenSequence(in: labels) else {
            throw Inf6HandwrittenFormulaError.invalidInput("保存済みユーザー数式の記号列が受入条件を満たしません")
        }
        try MathMLValidator().validate(mathML)
        let verified = try FormulaStructureComposer().compose(structure)
        guard verified.latex == expression, verified.mathML == mathML else {
            throw DerivationError.formulaStructureVerificationFailed
        }

        let drawing: PKDrawing
        let cells: [Int]
        let strokeIndices: [[Int]]
        if inputMethod == .handwriting || inputMethod == .mixed {
            guard let grid9 = document.grid9, grid9.isStructurallyValid,
                  let savedCells = document.recognizedGridCellIndices,
                  savedCells.count == labels.count,
                  savedCells.allSatisfy({ (1...9).contains($0) }),
                  let savedStrokeIndices = document.recognizedSymbolStrokeIndices,
                  savedStrokeIndices.count == labels.count,
                  let drawingData = document.pencilDrawingData else {
                throw Inf6HandwrittenFormulaError.invalidInput("保存済みユーザー手書き式の位置・ストローク対応が不足しています")
            }
            drawing = try PKDrawing(data: drawingData)
            guard !drawing.strokes.isEmpty,
                  savedStrokeIndices.allSatisfy({ !$0.isEmpty && $0.allSatisfy(drawing.strokes.indices.contains) }) else {
                throw DerivationError.invalidPencilDrawingData
            }
            if let spatialAnalysis = document.spatialAnalysis {
                try Inf6SpatialRelationAnalyzer.validate(
                    spatialAnalysis,
                    symbolLabels: labels,
                    symbolStrokeIndices: savedStrokeIndices
                )
            }
            cells = savedCells
            strokeIndices = savedStrokeIndices
        } else {
            guard inputMethod == .symbolPalette,
                  document.pencilDrawingData == nil,
                  document.spatialAnalysis == nil,
                  document.positionSensitiveClassification == nil,
                  document.similarityExpansion == nil else {
                throw Inf6HandwrittenFormulaError.invalidInput("保存済みユーザー数式の入力方式と位置証拠が一致しません")
            }
            drawing = PKDrawing()
            cells = []
            strokeIndices = labels.map { _ in [] }
        }

        var candidateLabels = labels.map { [$0] }
        var candidateRanks: [Int?] = Array(repeating: nil, count: labels.count)
        if let spatialAnalysis = document.spatialAnalysis,
           let classification = document.positionSensitiveClassification,
           let similarity = document.similarityExpansion {
            candidateLabels = try Inf6PositionSensitiveSymbolClassifier.candidateLabels(
                analysis: spatialAnalysis,
                classification: classification,
                similarityExpansion: similarity
            )
            guard spatialAnalysis.symbols.count == labels.count else {
                throw DerivationError.positionSensitiveClassificationVerificationFailed
            }
            candidateRanks = zip(labels, spatialAnalysis.symbols).map { label, symbol in
                symbol.candidates.firstIndex(where: { $0.label == label })
            }
        } else if document.spatialAnalysis != nil
                    || document.positionSensitiveClassification != nil
                    || document.similarityExpansion != nil {
            throw DerivationError.similarityExpansionVerificationFailed
        }

        formulaExpression = expression
        formulaMathML = mathML
        pencilDrawing = drawing
        formulaStructureDraft = structure
        formulaStructureScopeStack = [structure.rootID]
        formulaStructureSelection = []
        pencilRecognition = Inf6HandwrittenMathMLResult(
            tokenIDs: (document.recognizedTokenIDs ?? []).map(Int32.init),
            decodedExpression: "",
            mathML: "",
            grid9: document.grid9 ?? _emptyFormulaGrid9(),
            symbolLabels: labels,
            symbolGridCellIndices: cells,
            symbolStrokeIndices: strokeIndices,
            candidateRanks: candidateRanks,
            candidateLabels: candidateLabels,
            spatialAnalysis: document.spatialAnalysis,
            positionSensitiveClassification: document.positionSensitiveClassification,
            similarityExpansion: document.similarityExpansion,
            isProvisional: true
        )
        pencilRecognitionError = Inf6Lang.text(
            "保存済みユーザー数式を検証し、編集状態へ戻しました。",
            "The saved user-authored formula was verified and reopened for editing."
        )
    }

    @discardableResult
    private func _saveRecognitionResult(
        _ result: Inf6HandwrittenMathMLResult,
        drawingData: Data,
        inputMethod: Inf6FormulaInputMethod = .handwriting,
        handwritingEvidence: Data? = nil,
        formulaStructure: FormulaStructure? = nil,
        storeIdentifier: String? = nil
    ) -> Bool {
        do {
            let equationSpace: PaperEquationSpace?
            if origin == .paperEvidence {
                equationSpace = try _makeCurrentPaperEquationSpace(recognition: result)
                guard equationSpace?.equations.first != nil else {
                    throw PaperEquationSpaceError.missingEquationReference(entity.id.uuidString)
                }
            } else {
                guard origin == .userAuthored, userDerivationID != nil else {
                    throw DerivationError.derivationIdentityVerificationFailed
                }
                equationSpace = nil
            }
            guard !result.symbolLabels.isEmpty,
                  Inf6NonAutoregressiveSymbolRecognizer.containsSupportedFormulaTokenSequence(in: result.symbolLabels) else {
                throw Inf6HandwrittenFormulaError.invalidInput("数式記号が受入条件を満たしていません")
            }
            if inputMethod == .handwriting || inputMethod == .mixed {
                guard result.grid9.isStructurallyValid,
                      result.symbolLabels.count == result.symbolGridCellIndices.count,
                      result.symbolGridCellIndices.allSatisfy({ (1...9).contains($0) }) else {
                    throw Inf6HandwrittenFormulaError.invalidInput("手書き記号と位置特徴の対応が不正です")
                }
                if let spatialAnalysis = result.spatialAnalysis {
                    try Inf6SpatialRelationAnalyzer.validate(
                        spatialAnalysis,
                        symbolLabels: result.symbolLabels,
                        symbolStrokeIndices: result.symbolStrokeIndices
                    )
                }
            }
            try MathMLValidator().validate(result.mathML)
            let root = try Inf6UserSettingRootPaths.userSettingRootDirectory()
            let store = DerivationStore(root: root, identifier: storeIdentifier ?? _derivationIdentifier)
            var document = try store.load()
            let retainsEvidence = document.pencilDrawingData == drawingData && document.mathML == result.mathML
            let committedEvidence = handwritingEvidence ?? (retainsEvidence ? document.handwritingEvidence : nil)
            document.derivationID = origin == .userAuthored ? userDerivationID : document.derivationID
            document.origin = origin
            document.sourceTitle = origin == .paperEvidence ? paperTitle : nil
            document.sourceLocator = origin == .paperEvidence ? "(paperID)#page=\(entity.pageIndex + 1)" : nil
            document.sourceEvidenceID = origin == .userAuthored ? nil : document.sourceEvidenceID
            document.pencilDrawingData = inputMethod == .paper || inputMethod == .symbolPalette ? nil : drawingData
            document.handwritingEvidence = committedEvidence
            document.mathML = result.mathML
            document.mathMLVerified = true
            document.recognizedExpression = result.decodedExpression
            document.recognizedTokenIDs = result.tokenIDs.map(Int.init)
            document.recognizedSymbols = result.symbolLabels
            document.recognizedGridCellIndices = inputMethod == .handwriting || inputMethod == .mixed
                ? result.symbolGridCellIndices
                : nil
            document.recognizedSymbolStrokeIndices = inputMethod == .handwriting || inputMethod == .mixed
                ? result.symbolStrokeIndices
                : nil
            document.spatialAnalysis = inputMethod == .handwriting || inputMethod == .mixed
                ? result.spatialAnalysis
                : nil
            document.positionSensitiveClassification = inputMethod == .handwriting || inputMethod == .mixed
                ? result.positionSensitiveClassification
                : nil
            document.similarityExpansion = inputMethod == .handwriting || inputMethod == .mixed
                ? result.similarityExpansion
                : nil
            document.grid9 = inputMethod == .handwriting || inputMethod == .mixed ? result.grid9 : nil
            document.inputMethod = inputMethod
            document.formulaStructure = formulaStructure
            document.paperEquationSpaceID = equationSpace?.id
            document.paperEquationID = equationSpace?.equations.first?.id
            document.paperEquationSpace = equationSpace
            document.updatedAt = .now
            try store.save(document)
            return true
        } catch {
            pencilRecognitionError = "認識結果を保存できませんでした: \(error.localizedDescription)"
            return false
        }
    }

    private func _displayFormulaExpression(_ expression: String) -> String {
        expression
            .replacingOccurrences(of: "\\sqrt", with: "√")
            .replacingOccurrences(of: "\\times", with: "×")
            .replacingOccurrences(of: "\\cdot", with: "·")
            .replacingOccurrences(of: "\\div", with: "÷")
            .replacingOccurrences(of: "-", with: "−")
    }

    private func _chatBubble(_ message: String) -> some View {
        let displayMessage: String
        if message.hasPrefix("AI: ") {
            displayMessage = String(message.dropFirst("AI: ".count))
        } else if message.hasPrefix("A: ") {
            displayMessage = String(message.dropFirst("A: ".count))
        } else {
            displayMessage = message
        }
        return Group {
            if inlineFormulaReferences.contains(where: { displayMessage.contains($0.token) }) {
                Inf6ChatMessageText(
                    text: displayMessage,
                    inlineFormulae: _inlineFormulaTextDescriptors,
                    fontSize: Inf6ApplicationSystemFont.scaledSize(14)
                )
                .fixedSize(horizontal: false, vertical: true)
            } else {
                _highlightedMessage(displayMessage)
                    .textSelection(.enabled)
            }
        }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                (message.hasPrefix("引用") ? Inf6CodexDesign.cyan : Inf6CodexDesign.magenta)
                    .opacity(0.18),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        (message.hasPrefix("引用") ? Inf6CodexDesign.cyan : Inf6CodexDesign.magenta)
                            .opacity(0.72),
                        lineWidth: 1
                    )
            }
    }

    private func _chatEditableText(_ message: String) -> String {
        let editablePrefixes = ["AI: ", "質問: ", "Q: ", "A: "]
        guard let prefix = editablePrefixes.first(where: message.hasPrefix) else { return message }
        return String(message.dropFirst(prefix.count))
    }

    private func _chatMessageByReplacingEditableText(_ text: String, in message: String) -> String {
        let rolePrefixes = ["AI: ", "質問: ", "Q: ", "A: "]
        guard let prefix = rolePrefixes.first(where: message.hasPrefix) else { return text }
        return prefix + text
    }

    private var _frameworkPicker: some View {
        HStack(spacing: 2) {
            _formulaFrameworkButton("PyTorch")
            _formulaFrameworkButton("TensorFlow")
        }
        .padding(3)
        .background(Color.black.opacity(0.22), in: Capsule())
        .overlay(Capsule().stroke(Inf6CodexDesign.cyan.opacity(0.62), lineWidth: 1))
    }

    private func _formulaFrameworkButton(_ framework: String) -> some View {
        let isSelected = selectedCodeFramework == framework
        return Button {
            selectedCodeFramework = framework
        } label: {
            HStack(spacing: 5) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(10), weight: .bold))
                }
                Text(framework)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(minWidth: 0)
        }
        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(12), weight: .semibold))
        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.62))
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(isSelected ? Inf6CodexDesign.cyan : Color.white.opacity(0.08), in: Capsule())
        .overlay(Capsule().stroke(isSelected ? Color.white : Color.white.opacity(0.2), lineWidth: 1))
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func _highlightedMessage(_ message: String) -> Text {
        var result = AttributedString()
        let source = message as NSString
        let baseColor: Color = message.hasPrefix("質問:") || message.hasPrefix("Q:")
            ? Inf6CodexDesign.cyan
            : (message.hasPrefix("AI:") || message.hasPrefix("A:") ? Inf6CodexDesign.magenta : .white)
        let pattern = #"\*\*(.+?)\*\*|==(.+?)==|\[\[c=(cyan|magenta|green|orange|red)\]\](.+?)\[\[/c\]\]"#
        let matches = (try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]))?
            .matches(in: message, range: NSRange(location: 0, length: source.length)) ?? []
        var cursor = 0
        for match in matches {
            guard match.range.location >= cursor else { continue }
            _appendSyntaxColored(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), baseColor: baseColor, to: &result)
            let contentGroup: Int
            if match.range(at: 1).location != NSNotFound {
                contentGroup = 1
            } else if match.range(at: 2).location != NSNotFound {
                contentGroup = 2
            } else {
                contentGroup = 4
            }
            let contentRange = match.range(at: contentGroup)
            var formatted = AttributedString(source.substring(with: contentRange))
            formatted.foregroundColor = baseColor
            formatted.font = .system(size: explanationFontSize)
            if contentGroup == 1 {
                formatted.font = .system(size: explanationFontSize, weight: .bold)
                formatted.inlinePresentationIntent = .stronglyEmphasized
            } else if contentGroup == 2 {
                formatted.backgroundColor = Color.yellow.opacity(0.48)
            } else {
                formatted.foregroundColor = _chatMarkupColor(source.substring(with: match.range(at: 3)))
            }
            result.append(formatted)
            cursor = NSMaxRange(match.range)
        }
        if cursor < source.length {
            _appendSyntaxColored(source.substring(from: cursor), baseColor: baseColor, to: &result)
        }
        return Text(result)
    }

    private func _appendSyntaxColored(_ text: String, baseColor: Color, to output: inout AttributedString) {
        let source = text as NSString
        let codePattern = #"```(?:python)?[ \t]*\n([\s\S]*?)```"#
        let codeMatches = (try? NSRegularExpression(pattern: codePattern, options: [.caseInsensitive]))?
            .matches(in: text, range: NSRange(location: 0, length: source.length)) ?? []
        var cursor = 0
        for match in codeMatches {
            guard match.range.location >= cursor else { continue }
            _appendPlainSyntaxWords(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), baseColor: baseColor, to: &output)
            _appendPythonSyntax(source.substring(with: match.range(at: 1)), to: &output)
            cursor = NSMaxRange(match.range)
        }
        if cursor < source.length {
            _appendPlainSyntaxWords(source.substring(from: cursor), baseColor: baseColor, to: &output)
        }
    }

    private func _appendPlainSyntaxWords(_ text: String, baseColor: Color, to output: inout AttributedString) {
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        for (index, item) in words.enumerated() {
            let word = String(item)
            let color: Color
            if ["class", "def", "import", "from", "return", "let", "var", "func", "if", "else", "for", "in"].contains(word) {
                color = .purple
            } else if word.first?.isNumber == true {
                color = .orange
            } else if word.contains("=") || word.contains("+") || word.contains("−") || word.contains("×") || word.contains("÷") {
                color = .pink
            } else if word.hasPrefix("#") || word.hasPrefix("//") {
                color = .green
            } else {
                color = baseColor
            }
            var fragment = AttributedString(word + (index + 1 < words.count ? " " : ""))
            fragment.foregroundColor = color
            fragment.font = .system(size: explanationFontSize)
            output.append(fragment)
        }
    }

    private func _appendPythonSyntax(_ code: String, to output: inout AttributedString) {
        let tokenPattern = #"(?m)#.*|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|\b(?:False|None|True|and|as|assert|async|await|break|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|nonlocal|not|or|pass|raise|return|try|while|with|yield|self|torch|nn)\b|\b\d+(?:\.\d+)?\b|[=+*/<>!%-]+"#
        let source = code as NSString
        let matches = (try? NSRegularExpression(pattern: tokenPattern))?
            .matches(in: code, range: NSRange(location: 0, length: source.length)) ?? []
        var cursor = 0
        for match in matches {
            guard match.range.location >= cursor else { continue }
            _appendPythonFragment(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), color: .white, to: &output)
            let token = source.substring(with: match.range)
            let color: Color
            if token.hasPrefix("#") {
                color = .green
            } else if token.hasPrefix("\"") || token.hasPrefix("'") {
                color = .orange
            } else if Double(token) != nil {
                color = .orange
            } else if ["=", "+", "-", "*", "/", "<", ">", "!", "%"].contains(where: token.contains) {
                color = .pink
            } else {
                color = .purple
            }
            _appendPythonFragment(token, color: color, to: &output)
            cursor = NSMaxRange(match.range)
        }
        if cursor < source.length {
            _appendPythonFragment(source.substring(from: cursor), color: .white, to: &output)
        }
    }

    private func _appendPythonFragment(_ text: String, color: Color, to output: inout AttributedString) {
        var fragment = AttributedString(text)
        fragment.foregroundColor = color
        fragment.font = .system(size: explanationFontSize, design: .monospaced)
        output.append(fragment)
    }

    private func _chatMarkupColor(_ name: String) -> Color {
        switch name {
        case "cyan": return Inf6CodexDesign.cyan
        case "magenta": return Inf6CodexDesign.magenta
        case "green": return .green
        case "orange": return .orange
        case "red": return .red
        default: return .white
        }
    }

    private func _sendChat() {
        let serializedQuestion = chatQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = _expandedInlineFormulaText(serializedQuestion)
        guard !question.isEmpty, !isChatting, editingChatMessageIndex == nil else { return }
        let previousQuestion = chatQuestion
        let previousSelection = chatSelectionRange
        let previousMessages = chatMessages
        chatQuestion = ""
        chatSelectionRange = NSRange(location: 0, length: 0)
        chatMessages.append("質問: \(serializedQuestion)")
        guard _persistChat() else {
            chatQuestion = previousQuestion
            chatSelectionRange = previousSelection
            chatMessages = previousMessages
            return
        }
        isChatting = true
        let languageInstruction = Inf6Lang.text("日本語で回答してください。", "Answer in English.")
        let firebirdSystemInstruction = Inf6Lang.text(
            "あなたはArcane Derivation Codexの案内役である火の鳥です。物語上の全知全能の使いとして親身に導きますが、実際の回答では選択された対象・提示された出典・検証可能な計算に根拠を置いてください。未確認の情報や不確実な点を事実として断定せず、根拠がない場合はその旨を明確に述べてください。ユーザーが注目している数式、図、表、コード、質問の範囲に沿って答えてください。",
            "You are Hinotori, the guide of Arcane Derivation Codex. Speak as a helpful messenger with an all-knowing mythic character, but ground actual answers in the selected object, supplied sources, and verifiable calculations. Do not present unverified or uncertain claims as facts; state when evidence is missing. Stay focused on the formula, figure, table, code, or question the user selected."
        )
        Task {
            do {
                let activePart = selectedPart ?? hoveredPart
                let seed = _visibleChatMessages.joined(separator: "\n---\n")
                let sourceFormula = activePart.flatMap { _sourcePaperFormula(for: $0)?.expression }
                let formula = formulaExpression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? (activePart?.paperFormulaExpression ?? sourceFormula ?? activePart?.text ?? entity.title)
                    : formulaExpression
                let prompt: String
                if isNodeExplanationItem {
                    prompt = "シラバスノード: \(paperTitle)\nノードID: \(chapterID ?? "")\nノード解説アイテムID: \(entity.id.uuidString)\n対象: \(Inf6Lang.text(entity.kind.labelJa, entity.kind.labelEn)) \(entity.title)\nこのノード項目の説明: \(entity.explanation ?? entity.snippet)\n対応する数式: \(formula)\nコード方式: \(selectedCodeFramework)\n質問: \(question)\n\(languageInstruction)\nこのノード項目を起点に、数式・依存関係・導出根拠と\(selectedCodeFramework)コードを分けて説明してください。論文原典の記述であるかのように扱わないでください。"
                } else {
                    prompt = "論文ID: \(paperID)\n章ID: \(chapterID ?? "")\n対象ID: \(entity.id.uuidString)\n対象: \(entity.kind.labelEn) \(entity.title), page \(entity.pageIndex + 1)\n論文本文・キャプション: \(entity.snippet)\n対応する数式: \(formula)\nコード方式: \(selectedCodeFramework)\n質問: \(question)\n\(languageInstruction)\n対象の原典から逸脱せず、対応する数式の分解・記号・根拠と\(selectedCodeFramework)コードを区別して回答してください。"
                }
                let answer = try await Inf6LibraryView.askOpenAIText(
                    systemInstruction: firebirdSystemInstruction,
                    userPrompt: prompt + "\nチャットSEED（選択した本文・数式・根拠）:\n" + seed,
                    lang: Inf6Lang.text("ja", "en")
                )
                let messagesBeforeAnswer = chatMessages
                chatMessages.append("AI: \(answer)")
                if !_persistChat() {
                    chatMessages = messagesBeforeAnswer
                } else {
                    chatError = nil
                }
            } catch is CancellationError {
                chatError = Inf6Lang.text("回答取得をキャンセルしました。", "Answer request cancelled.")
            } catch {
                chatError = error.localizedDescription
            }
            isChatting = false
        }
    }

    private func _appendChatText() {
        let text = chatQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let previousMessages = chatMessages
        let previousEditingIndex = editingChatMessageIndex
        let previousQuestion = chatQuestion
        let previousSelection = chatSelectionRange
        if let editingChatMessageIndex, chatMessages.indices.contains(editingChatMessageIndex) {
            chatMessages[editingChatMessageIndex] = _chatMessageByReplacingEditableText(text, in: chatMessages[editingChatMessageIndex])
            self.editingChatMessageIndex = nil
        } else {
            chatMessages.append(text)
        }
        chatQuestion = ""
        chatSelectionRange = NSRange(location: 0, length: 0)
        guard _persistChat() else {
            chatMessages = previousMessages
            editingChatMessageIndex = previousEditingIndex
            chatQuestion = previousQuestion
            chatSelectionRange = previousSelection
            return
        }
        chatClearGeneration &+= 1
    }

    private func _expandedInlineFormulaText(_ serialized: String) -> String {
        inlineFormulaReferences.reduce(serialized) { text, reference in
            text.replacingOccurrences(of: reference.token, with: "\nMathML:\n\(reference.mathML)\n")
        }
    }

    private var _codeGenerationFormula: String? {
        if let recognition = pencilRecognition,
           !recognition.isProvisional,
           !recognition.decodedExpression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return recognition.decodedExpression
        }
        let candidate = formulaExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.isEmpty {
            return candidate
        }
        return nil
    }

    private func _copySourceEntityToEditor() {
        if let expression = entity.paperFormulaExpression {
            do {
                let mathML = try LaTeXMathMLConverter().convert(expression)
                _insertInlineFormulaIntoExistingEditor(expression, mathML: mathML, sourcePartID: nil)
            } catch {
                pencilRecognitionError = Inf6Lang.text("原典数式を組版できません。編集欄は変更していません: \(error.localizedDescription)", "The source formula could not be typeset. The editor was not changed: \(error.localizedDescription)")
            }
        } else {
            _insertSourceTextIntoExistingEditor(entity.title)
        }
    }

    private func _generatePythonFromCurrentFormula() {
        guard !isGeneratingPythonCode, let formula = _codeGenerationFormula else { return }
        isGeneratingPythonCode = true
        chatError = nil
        let framework = selectedCodeFramework
        let prompt = Inf6Lang.text(
            "次の確定済み数式を入力として、\(framework)を使うPythonコード案を作成してください。\n数式: \(formula)\n対象: \(paperTitle) / \(entity.title)\n原典の記述: \(entity.snippet)\n日本語で、コードブロック一つと、入出力shape・記号とコードの対応・必要な仮定を短く添えてください。根拠がない数値やshapeを捏造せず、不足する値は明示してください。回答には説明を含め、コード部分は必ず ```python と ``` で囲んでください。これは未実行のコード案であり、実行済みと表現しないでください。",
            "Using the confirmed formula below, draft executable Python code with \(framework).\nFormula: \(formula)\nContext: \(paperTitle) / \(entity.title)\nSource text: \(entity.snippet)\nReply in English with one fenced Python block and concise notes on input/output shapes, the correspondence between symbols and code, and any assumptions. Do not invent unsupported values or shapes; identify missing information. The code is a draft and must not be described as executed or verified."
        )
        pythonCodeGenerationTask = Task { @MainActor in
            defer {
                isGeneratingPythonCode = false
                pythonCodeGenerationTask = nil
            }
            do {
                let response = try await Inf6LibraryView.askOpenAIText(prompt, lang: Inf6Lang.text("ja", "en"))
                try Task.checkCancellation()
                guard response.contains("```python"), response.components(separatedBy: "```").count >= 3 else {
                    throw NSError(
                        domain: "ArcaneDerivationCodeGeneration",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("Pythonコードブロックを含む応答ではありません。生成結果は入力欄へ渡していません。", "The response did not contain a Python code block. It was not inserted into the editor.")]
                    )
                }
                chatQuestion = response
                editingChatMessageIndex = nil
                chatSelectionRange = NSRange(location: 0, length: 0)
                chatClearGeneration &+= 1
                    } catch is CancellationError {
                chatError = Inf6Lang.text("Pythonコード生成をキャンセルしました。", "Python code generation was cancelled.")
            } catch {
                chatError = error.localizedDescription
            }
        }
    }

    private func _updateFormulaPart(_ part: Inf6DocEntityPart) {
        let sourceFormula = _sourcePaperFormula(for: part)
        formulaMathML = part.paperFormulaMathML ?? sourceFormula?.mathML
        formulaExpression = part.paperFormulaExpression ?? sourceFormula?.expression ?? part.text
    }

    private func _persistRecoveredSourceFormula(for part: Inf6DocEntityPart) {
        guard part.paperFormulaExpression == nil,
              let sourceFormula = _sourcePaperFormula(for: part) else { return }
        guard var index = Inf6MetadataStore.getCodable(
            Inf6DocEntityIndex.self,
            domain: .docEntities,
            key: paperID
        ),
        let entityIndex = index.entities.firstIndex(where: { $0.id == entity.id }),
        let partIndex = index.entities[entityIndex].parts.firstIndex(where: { $0.id == part.id }) else {
            return
        }
        index.entities[entityIndex].parts[partIndex].paperFormulaExpression = sourceFormula.expression
        index.entities[entityIndex].parts[partIndex].paperFormulaMathML = sourceFormula.mathML
        index.entities[entityIndex].updatedAt = Date().timeIntervalSince1970
        _ = Inf6MetadataStore.putCodable(index, domain: .docEntities, key: paperID)
    }

    /// Extracts a formula only when the selected figure part's stored paper
    /// text contains the corresponding formal expression. The label selects
    /// the component; the expression itself must be present in paperText.
    /// This is source recovery, not a label-to-formula fallback.
    private func _sourcePaperFormula(for part: Inf6DocEntityPart) -> (expression: String, mathML: String?)? {
        let label = part.text
            .replacingOccurrences(of: "&", with: "and")
            .lowercased()
        let source = part.paperText
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)

        let expression: String?
        if label.contains("add") && label.contains("norm"),
           source.contains("LayerNorm(x+Sublayer(x))") {
            expression = "\\mathrm{LayerNorm}(x+\\mathrm{Sublayer}(x))"
        } else if label.contains("feed") && label.contains("forward"),
                  source.contains("FFN(x)=max(0,xW1+b1)W2+b2") {
            expression = "\\mathrm{FFN}(x)=\\mathrm{max}(0,xW_1+b_1)W_2+b_2"
        } else if label.contains("multi") && label.contains("head"),
                  source.contains("MultiHead(Q,K,V)=Concat(head1,...,headh)WO") {
            expression = "\\mathrm{MultiHead}(Q,K,V)=\\mathrm{Concat}(head_1,\\ldots,head_h)W^O"
        } else {
            expression = nil
        }
        guard let expression else { return nil }
        return (expression: expression, mathML: try? LaTeXMathMLConverter().convert(expression))
    }

    private func _copySourcePartToEditor(_ part: Inf6DocEntityPart) {
        let sourceFormula = _sourcePaperFormula(for: part)
        _persistRecoveredSourceFormula(for: part)
        guard let expression = part.paperFormulaExpression ?? sourceFormula?.expression else {
            _insertSourceTextIntoExistingEditor(part.text)
            return
        }
        do {
            let mathML = try part.paperFormulaMathML.map { value -> String in
                try MathMLValidator().validate(value)
                return value
            } ?? sourceFormula?.mathML ?? LaTeXMathMLConverter().convert(expression)
            try MathMLValidator().validate(mathML)
            _insertInlineFormulaIntoExistingEditor(expression, mathML: mathML, sourcePartID: part.id.uuidString)
        } catch {
            pencilRecognitionError = Inf6Lang.text("原典数式を組版できません。編集欄は変更していません: \(error.localizedDescription)", "The source formula could not be typeset. The editor was not changed: \(error.localizedDescription)")
        }
    }

    private func _insertInlineFormulaIntoExistingEditor(_ expression: String, mathML: String, sourcePartID: String?) {
        do {
            try MathMLValidator().validate(mathML)
            let token = try _newInlineFormulaToken()
            _insertSourceTextIntoExistingEditor(token)
            inlineFormulaReferences.append(InlineFormulaReference(
                token: token,
                expression: expression,
                mathML: mathML,
                derivationID: nil,
                sourcePartID: sourcePartID
            ))
            pencilRecognitionError = nil
        } catch {
            pencilRecognitionError = Inf6Lang.text("数式を編集欄へ組版できません: \(error.localizedDescription)", "Could not typeset the formula into the composer: \(error.localizedDescription)")
        }
    }

    private func _newInlineFormulaToken(additionallyUsed: Set<String> = []) throws -> String {
        let usedTokens = Set(inlineFormulaReferences.map(\.token)).union(additionallyUsed)
        for value in 0xE000...0xF8FF {
            guard let scalar = UnicodeScalar(value) else { continue }
            let token = String(scalar)
            if !usedTokens.contains(token) { return token }
        }
        throw NSError(
            domain: "ArcaneDerivationInlineFormula",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("編集欄の数式識別子を確保できません。", "Could not allocate an inline formula identifier.")]
        )
    }

    private var _inlineFormulaTextDescriptors: [InlineFormulaTextDescriptor] {
        inlineFormulaReferences.map {
            InlineFormulaTextDescriptor(token: $0.token, expression: $0.expression, mathML: $0.mathML)
        }
    }

    private func _inlineFormulaActionLabel(for token: String) -> String {
        guard inlineFormulaReferences.contains(where: { $0.token == token }) else {
            return Inf6Lang.text("数式", "Formula")
        }
        return Inf6Lang.text("数式を編集", "Edit formula")
    }

    private func _insertSourceTextIntoExistingEditor(_ text: String) {
        let insertion = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !insertion.isEmpty else {
            pencilRecognitionError = Inf6Lang.text("コピーできる式または項目名がありません。", "There is no formula or item title to copy.")
            return
        }
        let current = chatQuestion as NSString
        let start = min(max(chatSelectionRange.location, 0), current.length)
        let end = min(max(start + chatSelectionRange.length, start), current.length)
        let selectedRange = NSRange(location: start, length: end - start)
        chatQuestion = current.replacingCharacters(in: selectedRange, with: insertion)
        chatSelectionRange = NSRange(location: start + (insertion as NSString).length, length: 0)
    }

    private func _appendPartToChat(_ part: Inf6DocEntityPart) {
        let text = paperTextDisplayMode == .japanese && !part.paperTextJapanese.isEmpty
            ? part.paperTextJapanese
            : part.paperText
        let sourceFormula = _sourcePaperFormula(for: part)
        let formula = part.paperFormulaExpression ?? sourceFormula?.expression
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || formula != nil else { return }
        var seed = "引用（論文: \(paperTitle) / Entity: \(entity.title) / 部位: \(part.text)）"
        if let formula, !formula.isEmpty { seed += "\n数式SEED: \(formula)" }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { seed += "\n論文本文:\n\(text)" }
        let previousMessages = chatMessages
        chatMessages.append(seed)
        guard _persistChat() else {
            chatMessages = previousMessages
            return
        }
    }

    private func _commitFormulaToChat() -> Bool {
        guard let recognition = pencilRecognition,
              !recognition.isProvisional,
              !recognition.decodedExpression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pencilRecognitionError = Inf6Lang.text("数式が確定していません。認識候補を選択してから確定してください。", "The formula is not confirmed. Select a recognition candidate before confirming.")
            return false
        }
        if inlineFormulaCapture != nil {
            return _commitConfirmedInlineFormula(recognition, structure: formulaStructureDraft)
        }
        let inputMethod: Inf6FormulaInputMethod = recognition.symbolLabels.count == 1 && pencilDrawing.strokes.isEmpty ? .symbolPalette : .handwriting
        let evidence: Data?
        do {
            evidence = inputMethod == .handwriting && recognition.symbolLabels.count == 1
                ? try _makePencilRecognitionEvidence(drawingData: pencilDrawing.dataRepresentation(), result: recognition)
                : nil
        } catch {
            pencilRecognitionError = "手書き認識の証拠を作成できません: \(error.localizedDescription)"
            return false
        }
        guard _saveRecognitionResult(
            recognition,
            drawingData: pencilDrawing.dataRepresentation(),
            inputMethod: inputMethod,
            handwritingEvidence: evidence,
            formulaStructure: formulaStructureDraft
        ) else {
            return false
        }
        formulaExpression = recognition.decodedExpression
        formulaMathML = recognition.mathML
        return _persistChat()
    }

    @discardableResult
    private func _persistChat() -> Bool {
        let directory = Inf6DataRoot.url().appendingPathComponent("derivations", isDirectory: true)
        do {
            let composerLength = (chatQuestion as NSString).length
            guard chatSelectionRange.location >= 0,
                  chatSelectionRange.length >= 0,
                  chatSelectionRange.location <= composerLength,
                  chatSelectionRange.location + chatSelectionRange.length <= composerLength else {
                throw NSError(
                    domain: "ArcaneDerivationChatStorage",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("チャット編集位置が本文の範囲外です。", "The chat selection is outside the composer text.")]
                )
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formulaRecords: [[String: Any]] = inlineFormulaReferences.map { reference in
                var record: [String: Any] = [
                    "token": reference.token,
                    "mathML": reference.mathML
                ]
                if let expression = reference.expression { record["expression"] = expression }
                if let derivationID = reference.derivationID { record["derivationID"] = derivationID }
                if let sourcePartID = reference.sourcePartID { record["sourcePartID"] = sourcePartID }
                return record
            }
            let threadStorageID = Data(paperID.utf8)
                .base64EncodedString()
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "=", with: "")
            let payload: [String: Any] = [
                "schemaVersion": 4,
                "paperID": paperID,
                "chatThreadID": paperID,
                "chapterID": chapterID ?? "",
                "entityID": entity.id.uuidString,
                "entityTitle": entity.title,
                "pageIndex": entity.pageIndex,
                "messages": chatMessages,
                "composerDraft": chatQuestion,
                "composerSelection": [
                    "location": chatSelectionRange.location,
                    "length": chatSelectionRange.length
                ],
                "editingMessageIndex": editingChatMessageIndex.map { NSNumber(value: $0) as Any } ?? NSNull(),
                "inlineFormulae": formulaRecords
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("thread-\(threadStorageID).chat.json"), options: .atomic)
            chatError = nil
            return true
        } catch {
            chatError = error.localizedDescription
            return false
        }
    }

    private func _scheduleChatDraftPersistence() {
        chatDraftPersistenceTask?.cancel()
        chatDraftPersistenceTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
                try Task.checkCancellation()
                _persistChat()
            } catch is CancellationError {
                return
            } catch {
                chatError = error.localizedDescription
            }
        }
    }

    private func _loadChat() {
        let directory = Inf6DataRoot.url().appendingPathComponent("derivations", isDirectory: true)
        let threadStorageID = Data(paperID.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        let threadURL = directory.appendingPathComponent("thread-\(threadStorageID).chat.json")
        let legacyEntityURL = directory.appendingPathComponent("\(entity.id.uuidString).chat.json")
        let isLegacyEntityChat = !FileManager.default.fileExists(atPath: threadURL.path)
            && FileManager.default.fileExists(atPath: legacyEntityURL.path)
        let url = isLegacyEntityChat ? legacyEntityURL : threadURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let previousChatMessages = chatMessages
        let previousChatQuestion = chatQuestion
        let previousChatSelectionRange = chatSelectionRange
        let previousEditingChatMessageIndex = editingChatMessageIndex
        let previousInlineFormulaReferences = inlineFormulaReferences
        do {
            let data = try Data(contentsOf: url)
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let savedPaperID = payload["paperID"] as? String,
                  let savedChapterID = payload["chapterID"] as? String,
                  let savedEntityID = payload["entityID"] as? String,
                  let messages = payload["messages"] as? [String] else {
                throw NSError(
                    domain: "ArcaneDerivationChatStorage",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("保存されたチャットの形式が不正です。", "Saved chat data has an invalid format.")]
                )
            }
            let schemaVersion = payload["schemaVersion"] as? Int ?? 1
            let belongsToCurrentThread = schemaVersion >= 4
                ? payload["chatThreadID"] as? String == paperID
                : savedEntityID == entity.id.uuidString && savedChapterID == (chapterID ?? "")
            guard savedPaperID == paperID, belongsToCurrentThread else {
                throw NSError(
                    domain: "ArcaneDerivationChatStorage",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("保存されたチャットの対象IDが現在の項目と一致しません。", "Saved chat IDs do not match the selected item.")]
                )
            }
            guard schemaVersion == 1 || schemaVersion == 2 || schemaVersion == 3 || schemaVersion == 4 else {
                throw NSError(
                    domain: "ArcaneDerivationChatStorage",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("保存されたチャットの版に対応していません: \(schemaVersion)", "Unsupported saved chat version: \(schemaVersion)")]
                )
            }
            chatMessages = messages
            if schemaVersion >= 2 {
                guard let draft = payload["composerDraft"] as? String,
                      let selection = payload["composerSelection"] as? [String: Any],
                      let location = selection["location"] as? Int,
                      let length = selection["length"] as? Int else {
                    throw NSError(
                        domain: "ArcaneDerivationChatStorage",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("保存されたチャット編集状態が不正です。", "Saved composer state is invalid.")]
                    )
                }
                let utf16Length = (draft as NSString).length
                guard location >= 0, length >= 0, location <= utf16Length, location + length <= utf16Length else {
                    throw NSError(
                        domain: "ArcaneDerivationChatStorage",
                        code: 5,
                        userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("保存された選択範囲が本文の範囲外です。", "Saved selection is outside the composer text.")]
                    )
                }
                let editingIndex = (payload["editingMessageIndex"] as? NSNumber)?.intValue
                if let editingIndex {
                    guard messages.indices.contains(editingIndex) else {
                        throw NSError(
                            domain: "ArcaneDerivationChatStorage",
                            code: 6,
                            userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("編集中の発言が保存済み会話にありません。", "The edited message is missing from the saved conversation.")]
                        )
                    }
                }
                chatQuestion = draft
                chatSelectionRange = NSRange(location: location, length: length)
                editingChatMessageIndex = editingIndex
                guard let savedFormulae = payload["inlineFormulae"] as? [[String: Any]] else {
                    throw NSError(
                        domain: "ArcaneDerivationChatStorage",
                        code: 8,
                        userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("保存された数式参照が不正です。", "Saved inline formula references are invalid.")]
                    )
                }
                let root = try Inf6UserSettingRootPaths.userSettingRootDirectory(create: false)
                var loadedReferences: [InlineFormulaReference] = []
                var usedTokens = Set<String>()
                for record in savedFormulae {
                    let expression = record["expression"] as? String
                    guard expression == nil || !(expression ?? "").isEmpty else {
                        throw NSError(
                            domain: "ArcaneDerivationChatStorage",
                            code: 9,
                            userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("保存された数式参照に式がありません。", "A saved formula reference is missing its expression.")]
                        )
                    }
                    let derivationID = record["derivationID"] as? String
                    if let derivationID, !derivationID.hasPrefix("chat-") {
                        throw NSError(
                            domain: "ArcaneDerivationChatStorage",
                            code: 9,
                            userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("チャット数式参照の識別子が不正です: \(derivationID)", "Invalid chat formula reference ID: \(derivationID)")]
                        )
                    }
                    let mathML: String
                    if let storedMathML = record["mathML"] as? String {
                        mathML = storedMathML
                    } else if let derivationID {
                        let document = try DerivationStore(root: root, identifier: derivationID).load()
                        guard document.mathMLVerified == true,
                              expression != nil,
                              document.recognizedExpression == expression,
                              let storedMathML = document.mathML else {
                            throw NSError(
                                domain: "ArcaneDerivationChatStorage",
                                code: 11,
                                userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("保存された数式導出の式または検証状態が参照と一致しません: \(derivationID)", "Saved formula derivation does not match its chat reference: \(derivationID)")]
                            )
                        }
                        mathML = storedMathML
                    } else {
                        throw NSError(
                            domain: "ArcaneDerivationChatStorage",
                            code: 12,
                            userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("数式参照に検証済みMathMLも導出IDもありません。", "Formula reference has neither verified MathML nor a derivation ID.")]
                        )
                    }
                    try MathMLValidator().validate(mathML)
                    if let derivationID {
                        let document = try DerivationStore(root: root, identifier: derivationID).load()
                        guard document.mathMLVerified == true,
                              expression != nil,
                              document.recognizedExpression == expression,
                              document.mathML == mathML else {
                            throw NSError(
                                domain: "ArcaneDerivationChatStorage",
                                code: 11,
                                userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("保存された数式導出とチャット参照のMathMLが一致しません: \(derivationID)", "Saved derivation MathML does not match its chat reference: \(derivationID)")]
                            )
                        }
                    }
                    let token: String
                    if let savedToken = record["token"] as? String {
                        guard (savedToken.unicodeScalars.count == 1), !usedTokens.contains(savedToken) else {
                            throw NSError(
                                domain: "ArcaneDerivationChatStorage",
                                code: 13,
                                userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("保存された数式識別子が重複または不正です。", "Saved inline formula token is duplicated or invalid.")]
                            )
                        }
                        token = savedToken
                    } else {
                        token = try _newInlineFormulaToken(additionallyUsed: usedTokens)
                    }
                    usedTokens.insert(token)
                    loadedReferences.append(InlineFormulaReference(
                        token: token,
                        expression: expression,
                        mathML: mathML,
                        derivationID: derivationID,
                        sourcePartID: record["sourcePartID"] as? String
                    ))
                    if schemaVersion == 2, let expression {
                        let legacy = "\\(\(expression)\\)"
                        let draftNSString = chatQuestion as NSString
                        let draftRange = draftNSString.range(of: legacy)
                        if draftRange.location != NSNotFound {
                            chatQuestion = draftNSString.replacingCharacters(in: draftRange, with: token)
                            if NSMaxRange(draftRange) <= chatSelectionRange.location {
                                chatSelectionRange.location += (token as NSString).length - draftRange.length
                            } else if draftRange.location < chatSelectionRange.location {
                                chatSelectionRange = NSRange(location: draftRange.location + (token as NSString).length, length: 0)
                            }
                        } else {
                            for index in chatMessages.indices {
                                let messageNSString = chatMessages[index] as NSString
                                let messageRange = messageNSString.range(of: legacy)
                                guard messageRange.location != NSNotFound else { continue }
                                chatMessages[index] = messageNSString.replacingCharacters(in: messageRange, with: token)
                                break
                            }
                        }
                    }
                }
                inlineFormulaReferences = loadedReferences
                let referenceTokens = Set(inlineFormulaReferences.map(\.token))
                guard referenceTokens.count == inlineFormulaReferences.count else {
                    throw NSError(
                        domain: "ArcaneDerivationChatStorage",
                        code: 10,
                        userInfo: [NSLocalizedDescriptionKey: Inf6Lang.text("数式トークンが重複しています。", "Inline formula tokens are duplicated.")]
                    )
                }
                if schemaVersion == 2 {
                    guard _persistChat() else {
                        throw NSError(
                            domain: "ArcaneDerivationChatStorage",
                            code: 14,
                            userInfo: [NSLocalizedDescriptionKey: chatError ?? Inf6Lang.text("旧形式チャットの移行結果を保存できませんでした。", "Could not persist the migrated chat data.")]
                        )
                    }
                }
                let standaloneDraft = chatQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
                let draftHasFormulaReference = inlineFormulaReferences.contains { chatQuestion.contains($0.token) }
                if !draftHasFormulaReference,
                   !standaloneDraft.contains("\n"),
                   standaloneDraft.hasPrefix("\\"),
                   let mathML = try? LaTeXMathMLConverter().convert(standaloneDraft) {
                    try MathMLValidator().validate(mathML)
                    let token = try _newInlineFormulaToken()
                    chatQuestion = token
                    chatSelectionRange = NSRange(location: (token as NSString).length, length: 0)
                    inlineFormulaReferences.append(InlineFormulaReference(
                        token: token,
                        expression: standaloneDraft,
                        mathML: mathML,
                        derivationID: nil,
                        sourcePartID: nil
                    ))
                    guard _persistChat() else {
                        throw NSError(
                            domain: "ArcaneDerivationChatStorage",
                            code: 15,
                            userInfo: [NSLocalizedDescriptionKey: chatError ?? Inf6Lang.text("数式下書きの組版移行を保存できませんでした。", "Could not save the typeset formula-draft migration.")]
                        )
                    }
                }
            }
            if isLegacyEntityChat {
                guard _persistChat() else {
                    throw NSError(
                        domain: "ArcaneDerivationChatStorage",
                        code: 16,
                        userInfo: [NSLocalizedDescriptionKey: chatError ?? Inf6Lang.text("既存の会話を共通チャットへ移行できませんでした。", "Could not migrate the existing conversation into the shared chat.")]
                    )
                }
            }
        } catch {
            chatMessages = previousChatMessages
            chatQuestion = previousChatQuestion
            chatSelectionRange = previousChatSelectionRange
            editingChatMessageIndex = previousEditingChatMessageIndex
            inlineFormulaReferences = previousInlineFormulaReferences
            chatError = Inf6Lang.text("チャットを読み込めませんでした: \(error.localizedDescription)", "Could not load chat: \(error.localizedDescription)")
        }
    }

    /* obsolete duplicate body removed
    private func _sendChat() {
        let question = chatQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        chatQuestion = ""
        chatMessages.append("質問: \(question)")
        isChatting = true
        let languageInstruction = Inf6Lang.text("日本語で回答してください。", "Answer in English.")
        Task {
            do {
                let prompt = "論文ID: \(paperID)\n章ID: \(chapterID ?? "")\n対象ID: \(entity.id.uuidString)\n対象: \(entity.kind.labelEn) \(entity.title), page \(entity.pageIndex + 1)\n論文本文・キャプション: \(entity.snippet)\n質問: \(question)\n\(languageInstruction)\n対象の論文本文・キャプションと原典から逸脱せず、導出・計算・根拠を区別して回答してください。"
                let answer = try await Inf6LibraryView.askOpenAIText(prompt, lang: Inf6Lang.text("ja", "en"))
                chatMessages.append("AI: \(answer)")
                _persistChat()
                chatError = nil
            } catch {
                chatError = error.localizedDescription
            }
            isChatting = false
        }
    }

    private func _persistChat() {
        let directory = Inf6DataRoot.url().appendingPathComponent("derivations", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let payload: [String: Any] = [
                "paperID": paperID,
                "chapterID": chapterID ?? "",
                "entityID": entity.id.uuidString,
                "entityTitle": entity.title,
                "pageIndex": entity.pageIndex,
                "messages": chatMessages
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("\(entity.id.uuidString).chat.json"), options: .atomic)
        } catch {
            chatError = error.localizedDescription
        }
    }
    */
}

private func _trimEntityImageMargins(_ image: UIImage) -> UIImage {
    guard let source = image.cgImage else { return image }
    let width = source.width
    let height = source.height
    let bytesPerRow = width * 4
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let data = context.data else { return image }

    context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
    let pixels = data.assumingMemoryBound(to: UInt8.self)
    var minX = width
    var minY = height
    var maxX = -1
    var maxY = -1
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * bytesPerRow + x * 4
            let red = pixels[offset]
            let green = pixels[offset + 1]
            let blue = pixels[offset + 2]
            guard red < 238 || green < 238 || blue < 238 else { continue }
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
    }

    guard maxX >= minX, maxY >= minY else { return image }
    let margin = 12
    let rect = CGRect(
        x: max(0, minX - margin),
        y: max(0, minY - margin),
        width: min(width - max(0, minX - margin), maxX - minX + 1 + margin * 2),
        height: min(height - max(0, minY - margin), maxY - minY + 1 + margin * 2)
    )
    guard let cropped = source.cropping(to: rect) else { return image }
    return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
}

private struct Inf6FormulaEvidenceView: View {
    let evidence: Inf6CodexEvidenceReference
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 5) {
            Text(evidence.kind.capitalized + (evidence.pageIndex.map { " · p.\($0 + 1)" } ?? ""))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView().tint(.pink).scaleEffect(1.25)
                }
            }
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(8)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2) }
        }
        .buttonStyle(.plain)
        .task {
            guard let url = await Inf6EntityImageStore.ensureLocalFile(relativePath: evidence.imagePath),
                  let data = try? Data(contentsOf: url),
                  let loaded = UIImage(data: data) else { return }
            image = loaded
        }
    }
}

#endif

#endif






// MARK: - 5) Document pickers (iOS + macOS)

#if os(iOS)

import UIKit

struct DocumentFilePickerWrapper: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [.pdf]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: DocumentFilePickerWrapper
        init(_ parent: DocumentFilePickerWrapper) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onPick([])
        }
    }
}

struct RootFolderPickerWrapper: UIViewControllerRepresentable {
    var onPick: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [.folder]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: RootFolderPickerWrapper
        init(_ parent: RootFolderPickerWrapper) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPick(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onPick(nil)
        }
    }
}



#endif

// MARK: - 9) Explanation editor (selectable text + note cards)

struct ExplanationSelectableTextView: View {
    @Binding var explanation: String
    @Binding var notes: [Inf6ExtraNote]

    let placeholder: String
    let fontSize: CGFloat

    @Binding var selectedText: String
    let onAddExplanation: (String) -> Void
    /// Optional: if provided, the caller receives (selectedText, userHint).
    let onAddExplanationWithHint: ((String, String) -> Void)?

    @State private var userPrompt: String = ""

    @State private var editingNoteID: UUID? = nil

    private func _trimmedSelection() -> String {
        selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func _insertMemoBelowCard(at idx: Int, selection: String) {
        let s = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        let header = L("メモ", "Memo")
        let payload = header + "\n" + s
        let insertIndex = min(idx + 1, notes.count)
        notes.insert(Inf6ExtraNote(text: payload), at: insertIndex)
    }

    private func _runAskFromSelection() {
        let evidence = _trimmedSelection()
        guard !evidence.isEmpty else { return }

        let hint = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let f = onAddExplanationWithHint {
            f(evidence, hint)
        } else {
            onAddExplanation(evidence)
        }
        userPrompt = ""
    }

    #if canImport(UIKit)
    private func _dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    #endif

    init(
        explanation: Binding<String>,
        notes: Binding<[Inf6ExtraNote]>,
        placeholder: String,
        fontSize: CGFloat,
        selectedText: Binding<String>,
        onAddExplanation: @escaping (String) -> Void,
        onAddExplanationWithHint: ((String, String) -> Void)? = nil
    ) {
        self._explanation = explanation
        self._notes = notes
        self.placeholder = placeholder
        self.fontSize = fontSize
        self._selectedText = selectedText
        self.onAddExplanation = onAddExplanation
        self.onAddExplanationWithHint = onAddExplanationWithHint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $explanation)
                .font(.system(size: fontSize))
                .frame(maxWidth: .infinity, minHeight: 120)
                .overlay(alignment: .topLeading) {
                    if explanation.isEmpty && !placeholder.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 6)
                    }
                }

            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Inf6Lang.text("ページ追記", "Page notes"))
                        .font(.headline)

                    ForEach(Array(notes.enumerated()), id: \.element.id) { idx, n in
                        let bg: Color = {
                            let firstLine = n.text
                                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                                .first
                                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""

                            switch firstLine {
                            case "図", "Figures":
                                return Color.blue.opacity(0.10)
                            case "表", "Tables":
                                return Color.green.opacity(0.10)
                            case "式", "Equations":
                                return Color.purple.opacity(0.10)
                            default:
                                return Color.primary.opacity(0.05)
                            }
                        }()
                        VStack(alignment: .leading, spacing: 6) {
                            Inf6ReadOnlySelectableText(
                                text: n.text,
                                fontSize: fontSize,
                                onSelectionChanged: { sel in
                                    let t = sel.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !t.isEmpty {
                                        // Expose the selection to the caller so “Ask” can use it.
                                        selectedText = t
                                    }
                                }
                            )
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .topLeading)

                            HStack {
                                Spacer()
                                Button {
                                    notes.remove(at: idx)
                                } label: {
                                    Label(Inf6Lang.text("削除9", "Delete"), systemImage: "trash")
                                        .foregroundStyle(.blue)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(10)
                        .background(bg)
                        .background(.thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contextMenu {
                            Button {
                                _runAskFromSelection()
                            } label: {
                            Label(Inf6Lang.text("AddExplanation", "AddExplanation"), systemImage: "wand.and.stars")
                            }
                            .disabled(_trimmedSelection().isEmpty)

                            Button {
                                _insertMemoBelowCard(at: idx, selection: _trimmedSelection())
                            } label: {
                            Label(Inf6Lang.text("メモ追記", "Add memo"), systemImage: "plus.bubble")
                            }
                            .disabled(_trimmedSelection().isEmpty)

                            Divider()

                            Button {
                                editingNoteID = n.id
                            } label: {
                            Label(Inf6Lang.text("編集", "Edit"), systemImage: "pencil")
                            }

                            Button {
                                notes.remove(at: idx)
                            } label: {
                                Label(Inf6Lang.text("削除10", "Delete"), systemImage: "trash")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                TextField(Inf6Lang.text("追加指示（任意）", "Additional hint (optional)"), text: $userPrompt)
                    .textFieldStyle(.roundedBorder)

                Button(Inf6Lang.text("Ask", "Ask")) {
                    let evidence = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !evidence.isEmpty else { return }

                    let hint = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let f = onAddExplanationWithHint {
                        f(evidence, hint)
                    } else {
                        onAddExplanation(evidence)
                    }
                    userPrompt = ""
                }
                .buttonStyle(.borderedProminent)
            }

            // Keep this binding in place for callers that expect a selection mirror.
            // We only store a lightweight snapshot here.
            .inf6OnChange(explanation) { newValue in
                let snap = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if selectedText.isEmpty {
                    selectedText = String(snap.prefix(200))
                }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { editingNoteID != nil },
                set: { if !$0 { editingNoteID = nil } }
            )
        ) {
            if let id = editingNoteID {
                NavigationStack {
                    Group {
                        if notes.firstIndex(where: { $0.id == id }) != nil {
                            TextEditor(
                                text: Binding(
                                    get: { notes.first(where: { $0.id == id })?.text ?? "" },
                                    set: { newValue in
                                        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
                                        notes[i].text = newValue
                                    }
                                )
                            )
                            .font(.system(size: fontSize))
                            .padding(12)
                        } else {
                            VStack(spacing: 10) {
                                Text(Inf6Lang.text("ノートが見つかりません。", "The note was not found."))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(16)
                        }
                    }
                    .navigationTitle(Inf6Lang.text("ノート編集", "Edit note"))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(Inf6Lang.text("閉じる", "Close")) {
                                editingNoteID = nil
                            }
                        }
                    }
                }
            }
        }
    }
}

#if canImport(UIKit)
/// Read-only, selectable text view that works reliably on iOS and Designed for iPad on Mac.
/// Also reports user selection changes so the caller can reuse the selected snippet.
private struct Inf6ReadOnlySelectableText: UIViewRepresentable {
    final class IntrinsicTextView: UITextView {
        override var intrinsicContentSize: CGSize {
            // SwiftUI measures this view before it has a real width. If we guess a wide width
            // (e.g., screen width), the computed height becomes too small and the text gets clipped.
            // So: when width is not yet known, return a tiny height and let layoutSubviews
            // invalidate the intrinsic size once bounds are set.
            let w = bounds.width
            guard w > 1 else {
                return CGSize(width: UIView.noIntrinsicMetric, height: 1)
            }
            let size = sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
            return CGSize(width: UIView.noIntrinsicMetric, height: ceil(size.height))
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Keep the intrinsic height in sync with the actual width after SwiftUI lays us out.
            invalidateIntrinsicContentSize()
        }
    }

    let text: String
    let fontSize: CGFloat
    let onSelectionChanged: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelectionChanged: onSelectionChanged) }

    func makeUIView(context: Context) -> UITextView {
        let tv = IntrinsicTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.lineBreakMode = .byWordWrapping
        tv.isUserInteractionEnabled = true
        tv.textContainer.widthTracksTextView = true
        tv.textContainer.heightTracksTextView = false
        tv.delegate = context.coordinator
        // Let it grow vertically.
        tv.setContentHuggingPriority(.required, for: .vertical)
        tv.setContentCompressionResistancePriority(.required, for: .vertical)
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        uiView.font = UIFont.systemFont(ofSize: fontSize)
        uiView.setNeedsLayout()
        uiView.layoutIfNeeded()
        uiView.invalidateIntrinsicContentSize()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let onSelectionChanged: (String) -> Void
        private var lastPublishedSelection: String = ""
        init(onSelectionChanged: @escaping (String) -> Void) {
            self.onSelectionChanged = onSelectionChanged
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let r = textView.selectedRange
            guard r.location != NSNotFound, r.length > 0 else {
                if !lastPublishedSelection.isEmpty {
                    lastPublishedSelection = ""
                    onSelectionChanged("")
                }
                return
            }

            let ns = textView.text as NSString
            let s = ns.substring(with: r)
            if s != lastPublishedSelection {
                lastPublishedSelection = s
                onSelectionChanged(s)
            }
        }
    }
}
#endif

// MARK: - 7) TeX normalization

extension Inf6LibraryView {
    /// Best-effort normalization of common PDF/OCR math glyphs into TeX-friendly text.
    /// This is intentionally conservative (no aggressive $...$ insertion).
     func _rewriteCommonPDFMathToTeX(_ s: String) -> String {
        var out = s

        // Normalize unicode math symbols to TeX-ish equivalents.
        out = out.replacingOccurrences(of: "−", with: "-")
        out = out.replacingOccurrences(of: "×", with: "\\\\times")
        out = out.replacingOccurrences(of: "·", with: "\\\\cdot")
        out = out.replacingOccurrences(of: "≤", with: "\\\\leq")
        out = out.replacingOccurrences(of: "≥", with: "\\\\geq")
        out = out.replacingOccurrences(of: "≈", with: "\\\\approx")
        out = out.replacingOccurrences(of: "→", with: "\\\\to")
        out = out.replacingOccurrences(of: "←", with: "\\\\leftarrow")
        out = out.replacingOccurrences(of: "∞", with: "\\\\infty")

        // Collapse obvious PDF ligature spacing issues.
        out = out.replacingOccurrences(of: "  ", with: " ")

        return out
    }
}
