//
//  Inf6PDFPaneRepresentable.swift
//  inf6
//
//  Small, dependency-light PDFKit representables used by the PDF pane on iOS.
//

import Foundation
import SwiftUI

// PDFKit import for platforms that support it.
#if canImport(PDFKit)
import PDFKit
#endif


#if canImport(UIKit)
import UIKit
#endif




// MARK: - Multi mini-PDF cards (position-ordered, save/load helpers)
// Goal: allow multiple mini PDFs per page, sorted by their on-page position (reading order),
// and provide dependency-light persistence helpers. Integration happens from the calling view.

#if canImport(PDFKit) && os(iOS)

/// Codable CGRect surrogate (selection rectangle in rendered-view coordinates; origin is top-left, Y increases downward).
public struct Inf6PDFRectCodable: Codable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.size.width)
        self.height = Double(rect.size.height)
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// In PDF space, higher Y means visually higher on the page.
    public var maxY: Double { y + height }
}

/// A lightweight manifest entry for a single mini-PDF card.
/// - `pageIndex`: 0-based page index in the source PDF
/// - `rect`: selection bounds on that page (PDF coordinate space)
/// - `pdfFile`: file name (relative) for the mini PDF bytes
/// - `txtFile`: file name (relative) for the associated explanation text
public struct Inf6MiniPDFCardDescriptor: Codable, Hashable, Identifiable {
    public var id: UUID
    public var pageIndex: Int
    public var rect: Inf6PDFRectCodable
    public var createdAt: TimeInterval
    public var pdfFile: String
    public var txtFile: String

    public init(
        id: UUID = UUID(),
        pageIndex: Int,
        rect: Inf6PDFRectCodable,
        createdAt: TimeInterval = Date().timeIntervalSince1970,
        pdfFile: String,
        txtFile: String
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.rect = rect
        self.createdAt = createdAt
        self.pdfFile = pdfFile
        self.txtFile = txtFile
    }

    /// Reading order within a page: top-to-bottom, then left-to-right.
    /// Reading order within a page: top-to-bottom, then left-to-right.
    /// IMPORTANT: `rect` is treated as a *rendered-view* coordinate (origin = top-left, Y increases downward),
    /// so smaller `rect.y` is visually higher on the page.
    public var readingOrderKey: (Int, Double, Double) {
        (pageIndex, rect.y, rect.x)
    }
}

/// In-memory card that includes loaded payloads.
public struct Inf6MiniPDFCard: Identifiable, Hashable {
    public var id: UUID { descriptor.id }
    public var descriptor: Inf6MiniPDFCardDescriptor
    public var pdfData: Data
    public var explanationText: String

    public init(descriptor: Inf6MiniPDFCardDescriptor, pdfData: Data, explanationText: String) {
        self.descriptor = descriptor
        self.pdfData = pdfData
        self.explanationText = explanationText
    }

    public func pdfDocument() -> PDFDocument? {
        guard !pdfData.isEmpty else { return nil }
        return PDFDocument(data: pdfData)
    }
}

/// Minimal persistence for multiple mini-PDF cards under a caller-provided directory.
/// Layout (example):
///   <baseDir>/mini/
///     cards.json
///     card_<uuid>.pdf
///     card_<uuid>.txt
public enum Inf6MiniPDFCardsStore {
    public static let manifestFileName: String = "cards.json"

    public static func cardsDirectory(under baseDir: URL) -> URL {
        baseDir.appendingPathComponent("mini", isDirectory: true)
    }

    public static func manifestURL(under baseDir: URL) -> URL {
        cardsDirectory(under: baseDir).appendingPathComponent(manifestFileName)
    }

    /// Sort descriptors in reading order: page asc, Y desc, X asc.
    public static func sortDescriptorsInReadingOrder(_ descriptors: [Inf6MiniPDFCardDescriptor]) -> [Inf6MiniPDFCardDescriptor] {
        descriptors.sorted {
            let a = $0.readingOrderKey
            let b = $1.readingOrderKey
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1 != b.1 { return a.1 < b.1 }
            if a.2 != b.2 { return a.2 < b.2 }
            // Stable tie-breaker
            return $0.createdAt < $1.createdAt
        }
    }

    /// Create default filenames for a new card.
    public static func defaultFilenames(for id: UUID) -> (pdf: String, txt: String) {
        let s = id.uuidString.lowercased()
        return ("card_\(s).pdf", "card_\(s).txt")
    }

    /// Best-effort: make sure the mini directory exists.
    @discardableResult
    public static func ensureDirectoryExists(under baseDir: URL) -> URL {
        let dir = cardsDirectory(under: baseDir)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            fatalError("Inf6MiniPDFCardsStore: failed to create directory: \(dir.path). \(error)")
        }
        return dir
    }

    /// Load only the manifest entries (descriptors).
    /// - If the manifest file does not exist yet, returns empty.
    /// - If it exists but cannot be read/decoded, it is treated as a fatal corruption and stops.
    public static func loadDescriptors(from baseDir: URL) -> [Inf6MiniPDFCardDescriptor] {
        let u = manifestURL(under: baseDir)
        if !FileManager.default.fileExists(atPath: u.path) {
            return []
        }

        let data: Data
        do {
            data = try Data(contentsOf: u)
        } catch {
            fatalError("Inf6MiniPDFCardsStore: failed to read manifest: \(u.path). \(error)")
        }

        guard !data.isEmpty else {
            fatalError("Inf6MiniPDFCardsStore: manifest is empty but exists: \(u.path)")
        }

        do {
            return try JSONDecoder().decode([Inf6MiniPDFCardDescriptor].self, from: data)
        } catch {
            fatalError("Inf6MiniPDFCardsStore: failed to decode manifest JSON: \(u.path). \(error)")
        }
    }

    /// Save only the manifest entries (descriptors). Uses atomic write.
    /// Any failure is fatal and must not be silently ignored.
    public static func saveDescriptors(_ descriptors: [Inf6MiniPDFCardDescriptor], to baseDir: URL) {
        _ = ensureDirectoryExists(under: baseDir)
        let u = manifestURL(under: baseDir)

        let data: Data
        do {
            data = try JSONEncoder().encode(descriptors)
        } catch {
            fatalError("Inf6MiniPDFCardsStore: failed to encode manifest JSON: \(u.path). \(error)")
        }

        do {
            try data.write(to: u, options: [.atomic])
        } catch {
            fatalError("Inf6MiniPDFCardsStore: failed to write manifest: \(u.path). \(error)")
        }
    }

    public static func loadCards(from baseDir: URL) -> [Inf6MiniPDFCard] {
        let sorted = sortDescriptorsInReadingOrder(loadDescriptors(from: baseDir))
        if sorted.isEmpty {
            return []
        }

        let dir = cardsDirectory(under: baseDir)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            fatalError("Inf6MiniPDFCardsStore: missing cards directory but manifest has entries: \(dir.path)")
        }

        return sorted.map { d in
            let pdfURL = dir.appendingPathComponent(d.pdfFile)
            let txtURL = dir.appendingPathComponent(d.txtFile)

            guard FileManager.default.fileExists(atPath: pdfURL.path) else {
                fatalError("Inf6MiniPDFCardsStore: missing mini PDF payload: \(pdfURL.path)")
            }
            guard FileManager.default.fileExists(atPath: txtURL.path) else {
                fatalError("Inf6MiniPDFCardsStore: missing mini TXT payload: \(txtURL.path)")
            }

            let pdfData: Data
            do {
                pdfData = try Inf6SafeFileRead.data(at: pdfURL)
            } catch {
                fatalError("Inf6MiniPDFCardsStore: failed to read mini PDF payload: \(pdfURL.path). \(error)")
            }
            guard !pdfData.isEmpty else {
                fatalError("Inf6MiniPDFCardsStore: mini PDF payload is empty: \(pdfURL.path)")
            }

            let txtData: Data
            do {
                txtData = try Inf6SafeFileRead.data(at: txtURL)
            } catch {
                fatalError("Inf6MiniPDFCardsStore: failed to read mini TXT payload: \(txtURL.path). \(error)")
            }

            guard let text = String(data: txtData, encoding: .utf8) else {
                fatalError("Inf6MiniPDFCardsStore: mini TXT payload is not valid UTF-8: \(txtURL.path)")
            }

            return Inf6MiniPDFCard(descriptor: d, pdfData: pdfData, explanationText: text)
        }
    }

    /// Load cards for a single page only (still in reading order).
    public static func loadCards(from baseDir: URL, pageIndex: Int) -> [Inf6MiniPDFCard] {
        let all = loadCards(from: baseDir)
        return all.filter { $0.descriptor.pageIndex == pageIndex }
    }

    /// Load only descriptors for a single page (sorted in reading order).
    public static func loadDescriptors(from baseDir: URL, pageIndex: Int) -> [Inf6MiniPDFCardDescriptor] {
        let all = loadDescriptors(from: baseDir)
        return sortDescriptorsInReadingOrder(all.filter { $0.pageIndex == pageIndex })
    }

    /// Save or update a single card (pdf/txt), and upsert its descriptor into the manifest.
    public static func upsertCard(
        baseDir: URL,
        pageIndex: Int,
        rect: CGRect,
        pdfData: Data,
        explanationText: String,
        id: UUID = UUID()
    ) -> UUID {
        let dir = ensureDirectoryExists(under: baseDir)
        let files = defaultFilenames(for: id)

        // Write payloads first.
        let pdfURL = dir.appendingPathComponent(files.pdf)
        let txtURL = dir.appendingPathComponent(files.txt)
        if !pdfData.isEmpty {
            do {
                try pdfData.write(to: pdfURL, options: [.atomic])
            } catch {
                fatalError("Inf6MiniPDFCardsStore: failed to write mini PDF payload: \(pdfURL.path). \(error)")
            }
        }
        if let txtData = explanationText.data(using: .utf8) {
            do {
                try txtData.write(to: txtURL, options: [.atomic])
            } catch {
                fatalError("Inf6MiniPDFCardsStore: failed to write mini TXT payload: \(txtURL.path). \(error)")
            }
        }

        // Upsert descriptor.
        var desc = loadDescriptors(from: baseDir)
        let d = Inf6MiniPDFCardDescriptor(
            id: id,
            pageIndex: pageIndex,
            rect: Inf6PDFRectCodable(rect),
            pdfFile: files.pdf,
            txtFile: files.txt
        )
        if let i = desc.firstIndex(where: { $0.id == id }) {
            desc[i] = d
        } else {
            desc.append(d)
        }
        saveDescriptors(sortDescriptorsInReadingOrder(desc), to: baseDir)
        return id
    }

    public static func deleteCard(baseDir: URL, id: UUID) -> Bool {
        var desc = loadDescriptors(from: baseDir)
        guard let idx = desc.firstIndex(where: { $0.id == id }) else { return false }
        let d = desc.remove(at: idx)

        let dir = cardsDirectory(under: baseDir)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            fatalError("Inf6MiniPDFCardsStore: missing cards directory while deleting: \(dir.path)")
        }

        let pdfURL = dir.appendingPathComponent(d.pdfFile)
        let txtURL = dir.appendingPathComponent(d.txtFile)
        do {
            try FileManager.default.removeItem(at: pdfURL)
        } catch {
            fatalError("Inf6MiniPDFCardsStore: failed to remove mini PDF payload: \(pdfURL.path). \(error)")
        }
        do {
            try FileManager.default.removeItem(at: txtURL)
        } catch {
            fatalError("Inf6MiniPDFCardsStore: failed to remove mini TXT payload: \(txtURL.path). \(error)")
        }

        saveDescriptors(sortDescriptorsInReadingOrder(desc), to: baseDir)
        return true
    }
}

/// File-private mini PDF renderer used only by `Inf6MiniPDFCardsView`.
private struct _Inf6MiniPDFPageView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePage
        v.displayDirection = .vertical
        v.backgroundColor = .clear
        v.document = document
        return v
    }

    func updateUIView(_ v: PDFView, context: Context) {
        if v.document !== document {
            v.document = document
        }
    }
}

/// A tiny SwiftUI view to render multiple mini PDFs in reading order.
/// The caller supplies already-loaded cards.
public struct Inf6MiniPDFCardsView: View {
    public let cards: [Inf6MiniPDFCard]
    public var maxCardHeight: CGFloat = 220
    public var showsPageLabel: Bool = false
    public var onDeleteCard: ((UUID) -> Void)? = nil

    public init(
        cards: [Inf6MiniPDFCard],
        maxCardHeight: CGFloat = 220,
        showsPageLabel: Bool = false,
        onDeleteCard: ((UUID) -> Void)? = nil
    ) {
        self.cards = cards
        self.maxCardHeight = maxCardHeight
        self.showsPageLabel = showsPageLabel
        self.onDeleteCard = onDeleteCard
    }

    private var orderedCards: [Inf6MiniPDFCard] {
        cards.sorted {
            let a = $0.descriptor.readingOrderKey
            let b = $1.descriptor.readingOrderKey
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1 != b.1 { return a.1 < b.1 }
            if a.2 != b.2 { return a.2 < b.2 }
            return $0.descriptor.createdAt < $1.descriptor.createdAt
        }
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 10) {
                if orderedCards.isEmpty {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .frame(height: max(120, maxCardHeight))
                        .overlay {
                            Text("No mini PDFs")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                }

                ForEach(orderedCards) { card in
                    VStack(alignment: .leading, spacing: 8) {
                        if showsPageLabel || onDeleteCard != nil {
                            HStack(spacing: 10) {
                                if showsPageLabel {
                                    Text("p\(card.descriptor.pageIndex + 1)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if let onDeleteCard {
                                    Button {
                                        onDeleteCard(card.id)
                                    } label: {
                                        Label(Inf6Lang.text("削除11", "Delete"), systemImage: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .tint(.blue)
                                }
                            }
                        }

                        if let doc = card.pdfDocument() {
                            _Inf6MiniPDFPageView(document: doc)
                                .frame(height: maxCardHeight)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        } else {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .frame(height: maxCardHeight)
                                .overlay {
                                    Text("Mini PDF not available")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                        }

                        let trimmed = card.explanationText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            Text(trimmed)
                                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(14)))
                                .foregroundStyle(.primary)
                                .lineLimit(nil)
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
                }
            }
            .padding(.vertical, 8)
        }
    }
}

#endif




// MARK: - PDF Pane Representable (iOS)

#if canImport(PDFKit) && os(iOS)
public struct Inf6PDFPaneRepresentable: UIViewRepresentable {
    public let url: URL
    public let document: PDFDocument?
    public let onTap: (Int, String, String) -> Void
    public var selectedPage: Binding<Int>

    @Binding public var zoom: CGFloat
    @Binding public var selectionText: String

    public var onPDFViewReady: ((PDFView) -> Void)? = nil

    public var suppressProgrammaticLayout: Bool = false

    // Avoid SwiftUI feedback loops during split drag: we schedule one deferred scale update
    // after resizing ends instead of mutating PDFView scale continuously.
    public var isSplitDragActive: Bool = false
    // While split drag is active, freeze the visible anchor (page + point) and restore it when drag ends.
    public var restoreAnchorAfterSplitDrag: Bool = true

    // Called when split drag begins/ends (caller can bind this to the grab bar gesture state).
    public var onSplitDragStateChanged: ((Bool) -> Void)? = nil

    public init(
        url: URL,
        document: PDFDocument?,
        onTap: @escaping (Int, String, String) -> Void,
        selectedPage: Binding<Int>,
        zoom: Binding<CGFloat>,
        selectionText: Binding<String>,
        onPDFViewReady: ((PDFView) -> Void)? = nil,
        suppressProgrammaticLayout: Bool = false,
        isSplitDragActive: Bool = false,
        restoreAnchorAfterSplitDrag: Bool = true,
        onSplitDragStateChanged: ((Bool) -> Void)? = nil
    ) {
        self.url = url
        self.document = document
        self.onTap = onTap
        self.selectedPage = selectedPage
        self._zoom = zoom
        self._selectionText = selectionText
        self.onPDFViewReady = onPDFViewReady
        self.suppressProgrammaticLayout = suppressProgrammaticLayout
        self.isSplitDragActive = isSplitDragActive
        self.restoreAnchorAfterSplitDrag = restoreAnchorAfterSplitDrag
        self.onSplitDragStateChanged = onSplitDragStateChanged
    }

    private func _shouldForceZeroScrollInsets() -> Bool {
        // On iOS, PDFKit’s internal UIScrollView can inherit automatic insets from the host
        // (SwiftUI / navigation bars / safe-area adjustments). That can shift the page horizontally,
        // most visibly on iPhone. Always force zero insets for PDFView’s internal scroll views.
        return true
    }

    // Ensure iPad-on-Mac (iOS app on macOS) exposes scroll indicators.
    // PDFView hosts an internal UIScrollView; find and configure it.
    private func _collectScrollViews(from root: UIView, limit: Int = 16) -> [UIScrollView] {
        var out: [UIScrollView] = []
        var stack: [UIView] = [root]
        while let v = stack.popLast() {
            if let sv = v as? UIScrollView {
                out.append(sv)
                if out.count >= limit { break }
            }
            if out.count < limit {
                stack.append(contentsOf: v.subviews)
            }
        }
        return out
    }

    private func _configureScrollIndicators(_ pdfView: PDFView) -> [UIScrollView] {
        let scrollViews = _collectScrollViews(from: pdfView)
        for sv in scrollViews {
            if sv.showsHorizontalScrollIndicator != true { sv.showsHorizontalScrollIndicator = true }
            if sv.showsVerticalScrollIndicator != true { sv.showsVerticalScrollIndicator = true }
            if sv.alwaysBounceHorizontal != true { sv.alwaysBounceHorizontal = true }
            if sv.alwaysBounceVertical != true { sv.alwaysBounceVertical = true }

            if _shouldForceZeroScrollInsets() {
                // Remove automatic inset adjustments that can create a persistent gutter / centering drift.
                if #available(iOS 11.0, *) {
                    if sv.contentInsetAdjustmentBehavior != .never { sv.contentInsetAdjustmentBehavior = .never }
                }
                if sv.contentInset != .zero { sv.contentInset = .zero }
                if #available(iOS 13.0, *) {
                    if sv.verticalScrollIndicatorInsets != .zero { sv.verticalScrollIndicatorInsets = .zero }
                    if sv.horizontalScrollIndicatorInsets != .zero { sv.horizontalScrollIndicatorInsets = .zero }
                } else {
                    if sv.scrollIndicatorInsets != .zero { sv.scrollIndicatorInsets = .zero }
                }

                if #available(iOS 13.0, *) {
                    if sv.automaticallyAdjustsScrollIndicatorInsets != false {
                        sv.automaticallyAdjustsScrollIndicatorInsets = false
                    }
                }
            }
        }
        return scrollViews
    }

    private func _flashScrollIndicatorsOnce(_ scrollViews: [UIScrollView]) {
        for sv in scrollViews {
            sv.flashScrollIndicators()
        }
    }

    private func _fitWidthScale(_ pdfView: PDFView) -> CGFloat {
        guard let page = (pdfView.currentPage ?? pdfView.document?.page(at: 0)) else {
            return pdfView.scaleFactorForSizeToFit
        }
        let pageBounds = page.bounds(for: pdfView.displayBox)
        let viewW = max(1, pdfView.bounds.width)
        // Fit-to-width without an artificial gutter (prevents persistent left gutter).
        return max(0.05, viewW / max(1, pageBounds.width))
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self, zoomBinding: $zoom)
    }

    public func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        // Initial layout: let PDFKit compute a sane fit-to-width / centering on the first visible frame.
        // We will switch to explicit scaleFactor control in `updateUIView` once bounds are stable.
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        // NOTE: PageViewController mode forces page-by-page behavior and can make continuous scrolling feel like “only the first page”.
        v.usePageViewController(false)
        // PDFKitのページ外領域を透明にすると、親ビューのsystemBackgroundが見えて
        // 肌色の余白になるため、PDF表示領域は白で統一する。
        v.backgroundColor = .white
        v.delegate = context.coordinator

        if let doc = document {
            v.document = doc
        }

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.require(toFail: v.gestureRecognizers?.first { $0 is UITapGestureRecognizer } ?? tap)
        v.addGestureRecognizer(tap)

        // Disable PDFKit's internal pointer/annotation tracking views that can return invalid hit-test targets
        // during SwiftUI navigation / remote view transitions (not in a window hierarchy).

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: v
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.selectionChanged(_:)),
            name: .PDFViewSelectionChanged,
            object: v
        )

        context.coordinator._lastGoToPageIndex = -1
        context.coordinator.pdfView = v
        context.coordinator.configureScrollIndicatorsIfNeeded(for: v, flash: true)
        onPDFViewReady?(v)
        return v
    }

    public func updateUIView(_ pdfView: PDFView, context: Context) {
        // Guard against SwiftUI update cycles: ignore KVO-driven feedback while we are actively updating.
        context.coordinator.isInUpdateUIView = true
        defer { context.coordinator.isInUpdateUIView = false }
        // Avoid touching PDFKit subview hierarchy while the view is not in a window.
        // PDFKit can transiently return hit-test views not attached to a window during navigation/transitions.
        guard pdfView.window != nil else {
            return
        }
        context.coordinator.disableAnnotationPointerTrackingIfNeeded(for: pdfView)

        // Keep document identity in sync first (this is a real content change, not a layout tweak).
        if let doc = document, pdfView.document !== doc {
            pdfView.document = doc

            // If the PDFDocument instance changed, PDFKit may rebuild page objects.
            // Reset the go(to:) gate so we can restore the intended page exactly once.
            context.coordinator._lastDocumentObjectID = ObjectIdentifier(doc)
            context.coordinator._lastGoToPageIndex = -1
        } else if let doc = pdfView.document {
            // Keep the cached identity in sync even when `document` is nil (we rely on pdfView.document).
            let oid = ObjectIdentifier(doc)
            if context.coordinator._lastDocumentObjectID != oid {
                context.coordinator._lastDocumentObjectID = oid
                context.coordinator._lastGoToPageIndex = -1
            }
        }

        // During grab-bar (split) resizing, *do not* force layout or touch PDFView properties.
        // Any programmatic intervention here can cause PDFKit to re-anchor to page top.
        let splitActive = suppressProgrammaticLayout || isSplitDragActive

        // Prevent AttributeGraph cycles: `updateUIView` is called frequently, so only act on state transitions.
        // `noteSplitDrag(active:)` has side effects (deferred relayout scheduling / callbacks), so avoid re-running it
        // when `splitActive` hasn't changed.
        context.coordinator.noteSplitDragTransitionIfNeeded(active: splitActive, pdfView: pdfView)

        if splitActive {
            // During grab-bar resizing, do not touch PDFView state. Capture anchor once.
            if restoreAnchorAfterSplitDrag {
                context.coordinator.captureAnchorIfNeeded(pdfView)
            }
            return
        }

        context.coordinator.configureScrollIndicatorsIfNeeded(for: pdfView, flash: false)

        if let doc = pdfView.document, doc.pageCount > 0 {
            let targetIdx = min(max(0, selectedPage.wrappedValue), max(0, doc.pageCount - 1))

            // If PDFKit is in an unstable layout phase, `currentPage` can momentarily become nil.
            // In that state, any programmatic `go(to:)` will snap to the top and looks like a reset.
            // Therefore, do not attempt page jumps unless the current page is known.
            guard let current = pdfView.currentPage else {
                return
            }

            let currentIdx = doc.index(for: current)
            guard currentIdx >= 0 else {
                return
            }

            // Layout-only updates (e.g. split-ratio drag) must not reset the scroll position.
            // Only call go(to:) when the *page number* differs, and we haven't already jumped to it.
            if currentIdx != targetIdx, context.coordinator._lastGoToPageIndex != targetIdx {
                if let targetPage = doc.page(at: targetIdx) {
                    context.coordinator.isProgrammaticPageChange = true
                    pdfView.go(to: targetPage)
                    context.coordinator._lastGoToPageIndex = targetIdx
                    DispatchQueue.main.async {
                        context.coordinator.isProgrammaticPageChange = false
                    }
                }
            }
        }

        // Ensure layout has happened; otherwise bounds can be ~0 and we would lock the scaleFactor to a tiny value.
        // Force layout only when we are going to apply scaling; never during grab-bar resizing.
        if !suppressProgrammaticLayout && !isSplitDragActive {
            pdfView.layoutIfNeeded()
        }

        let z = max(0.5, min(zoom, 5.0))
        let viewWNow = pdfView.bounds.width

        // Once bounds are stable enough, hand control back to our explicit zoom pipeline.
        // Keeping `autoScales` enabled would fight with our `scaleFactor` updates.
        if viewWNow >= 200, pdfView.autoScales != false {
            pdfView.autoScales = false
        }

        // If the view width is not yet stable, defer scaling.
        if viewWNow < 200 {
            let coordinator = context.coordinator
            DispatchQueue.main.async { [weak pdfView] in
                guard let pdfView = pdfView else { return }
                let viewW = pdfView.bounds.width
                // If bounds are still not ready, keep autoScales enabled so the first frame stays centered.
                if pdfView.autoScales != true {
                    pdfView.autoScales = true
                }
                guard viewW >= 200 else { return }

                // Bounds are now stable; we will take over scale control.
                if pdfView.autoScales != false {
                    pdfView.autoScales = false
                }

                let fitWidth = coordinator.parent._fitWidthScale(pdfView)
                let minSF = fitWidth * 0.5
                let maxSF = fitWidth * 5.0
                let target = z * fitWidth

                let needsAnyScaleChange: Bool = {
                    if abs(pdfView.minScaleFactor - minSF) > 0.001 { return true }
                    if abs(pdfView.maxScaleFactor - maxSF) > 0.001 { return true }
                    if abs(pdfView.scaleFactor - target) > 0.01 { return true }
                    return false
                }()

                guard needsAnyScaleChange else {
                    coordinator.lastAppliedZoom = z
                    coordinator.lastAppliedViewWidth = viewW
                    return
                }

                coordinator.isProgrammaticScaleChange = true
                if abs(pdfView.minScaleFactor - minSF) > 0.001 { pdfView.minScaleFactor = minSF }
                if abs(pdfView.maxScaleFactor - maxSF) > 0.001 { pdfView.maxScaleFactor = maxSF }
                if abs(pdfView.scaleFactor - target) > 0.01 { pdfView.scaleFactor = target }
                coordinator.isProgrammaticScaleChange = false

                coordinator.lastAppliedZoom = z
                coordinator.lastAppliedViewWidth = viewW
            }
            return
        }

        // Only rescale when the logical zoom value or the view width has changed.
        let needsRescale: Bool = {
            if context.coordinator.lastAppliedZoom < 0 { return true }
            if abs(z - context.coordinator.lastAppliedZoom) > 0.001 { return true }
            if abs(viewWNow - context.coordinator.lastAppliedViewWidth) > 0.5 { return true }
            return false
        }()

        guard needsRescale else { return }

        let fitWidth: CGFloat = {
            guard let page = (pdfView.currentPage ?? pdfView.document?.page(at: 0)) else {
                return pdfView.scaleFactorForSizeToFit
            }
            let pageBounds = page.bounds(for: pdfView.displayBox)
            let viewW = max(1, pdfView.bounds.width)
            // Fit-to-width without an artificial gutter (prevents persistent left gutter).
            return max(0.05, viewW / max(1, pageBounds.width))
        }()

        let minSF = fitWidth * 0.5
        let maxSF = fitWidth * 5.0
        let target = z * fitWidth

        let needsAnyScaleChange: Bool = {
            if abs(pdfView.minScaleFactor - minSF) > 0.001 { return true }
            if abs(pdfView.maxScaleFactor - maxSF) > 0.001 { return true }
            if abs(pdfView.scaleFactor - target) > 0.01 { return true }
            return false
        }()

        guard needsAnyScaleChange else {
            context.coordinator.lastAppliedZoom = z
            context.coordinator.lastAppliedViewWidth = viewWNow
            return
        }

        context.coordinator.isProgrammaticScaleChange = true
        if abs(pdfView.minScaleFactor - minSF) > 0.001 { pdfView.minScaleFactor = minSF }
        if abs(pdfView.maxScaleFactor - maxSF) > 0.001 { pdfView.maxScaleFactor = maxSF }
        if abs(pdfView.scaleFactor - target) > 0.01 { pdfView.scaleFactor = target }
        context.coordinator.isProgrammaticScaleChange = false

        context.coordinator.lastAppliedZoom = z
        context.coordinator.lastAppliedViewWidth = viewWNow
    }

    public final class Coordinator: NSObject, PDFViewDelegate {
        var parent: Inf6PDFPaneRepresentable
        var zoomBinding: Binding<CGFloat>
        private var scaleObservation: NSKeyValueObservation? = nil

        var lastAppliedZoom: CGFloat = -1
        var lastAppliedViewWidth: CGFloat = 0
        var isProgrammaticScaleChange: Bool = false
        var isProgrammaticPageChange: Bool = false
        var isInUpdateUIView: Bool = false
        var _lastGoToPageIndex: Int = -1
        var _lastDocumentObjectID: ObjectIdentifier? = nil

        private var wasSplitDragActive: Bool = false
        // Anchor restore across split drag (prevents snapping to page top).
        private var pendingAnchorRestore: Bool = false
        private var capturedAnchorPageIndex: Int? = nil
        private var capturedAnchorPoint: CGPoint? = nil
        private var pendingDeferredRelayout: Bool = false
        // Capture an anchor (page + point in page coordinates) once during split drag.
        func captureAnchorIfNeeded(_ pdfView: PDFView) {
            guard pendingAnchorRestore != true else { return }
            guard pdfView.window != nil else { return }
            guard let page = pdfView.currentPage else { return }
            // Use the center of the visible bounds as the anchor.
            let viewPt = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
            let pagePt = pdfView.convert(viewPt, to: page)
            capturedAnchorPageIndex = pdfView.document?.index(for: page)
            capturedAnchorPoint = pagePt
            pendingAnchorRestore = true
        }

        // Restore captured anchor after split drag ends.
        func restoreAnchorIfNeeded(_ pdfView: PDFView) {
            guard pendingAnchorRestore else { return }
            guard pdfView.window != nil else { return }
            guard let doc = pdfView.document else { return }
            guard let idx = capturedAnchorPageIndex, idx >= 0, idx < doc.pageCount else {
                pendingAnchorRestore = false
                capturedAnchorPageIndex = nil
                capturedAnchorPoint = nil
                return
            }
            guard let page = doc.page(at: idx) else {
                pendingAnchorRestore = false
                capturedAnchorPageIndex = nil
                capturedAnchorPoint = nil
                return
            }
            guard let pt = capturedAnchorPoint else {
                pendingAnchorRestore = false
                capturedAnchorPageIndex = nil
                return
            }

            // Go to the precise point on the page (prevents snapping to top).
            isProgrammaticPageChange = true
            pdfView.go(to: CGRect(origin: pt, size: .zero), on: page)
            DispatchQueue.main.async { [weak self] in
                self?.isProgrammaticPageChange = false
            }

            pendingAnchorRestore = false
            capturedAnchorPageIndex = nil
            capturedAnchorPoint = nil
        }
        private var deferredRelayoutWork: DispatchWorkItem? = nil

        private var cachedScrollViews: [UIScrollView] = []
        private var didConfigureScrollIndicators: Bool = false
        private var didFlashScrollIndicators: Bool = false
        private var lastScrollIndicatorScanAt: CFAbsoluteTime = 0
        private var lastDocumentURL: URL? = nil

        // PDFKit (especially on iPad-on-Mac / during remote view transitions) can install an internal
        // PDFAnnotationPointerTrackingView which sometimes returns itself from hitTest while not attached
        // to any window. That triggers UIKit warnings and can cause touch routing instability.
        // We explicitly disable user interaction for those tracking views.
        func disableAnnotationPointerTrackingIfNeeded(for pdfView: PDFView) {
            guard pdfView.window != nil else { return }

            // Walk a small portion of the subview tree; the tracking view is typically near the document view.
            var stack: [UIView] = [pdfView]
            var visited = 0
            while let v = stack.popLast() {
                visited += 1
                if visited > 128 { break }

                let name = String(describing: type(of: v))
                if name.contains("PDFAnnotationPointerTrackingView") {
                    if v.isUserInteractionEnabled != false {
                        v.isUserInteractionEnabled = false
                    }
                }

                // Only descend a bit to avoid heavy scans.
                if visited < 128 {
                    stack.append(contentsOf: v.subviews)
                }
            }
        }

        func configureScrollIndicatorsIfNeeded(for pdfView: PDFView, flash: Bool) {
            // If the displayed URL changed, PDFKit may rebuild its internal scroll view hierarchy.
            // (The caller may recreate PDFDocument instances for the same URL; avoid expensive resets in that case.)
            if lastDocumentURL?.absoluteString != parent.url.absoluteString {
                lastDocumentURL = parent.url
                cachedScrollViews = []
                didConfigureScrollIndicators = false
                didFlashScrollIndicators = false
                lastScrollIndicatorScanAt = 0
            }

            // If PDFKit rebuilt the internal UIScrollView hierarchy, cached references can become stale.
            if !cachedScrollViews.isEmpty {
                let stillValid = cachedScrollViews.contains { sv in
                    sv.window != nil && sv.isDescendant(of: pdfView)
                }
                if !stillValid {
                    cachedScrollViews = []
                    didConfigureScrollIndicators = false
                    didFlashScrollIndicators = false
                    lastScrollIndicatorScanAt = 0
                }
            }

            // Keep indicator configuration enforced on cached scroll views (cheap and prevents “sometimes disappears”).
            if !cachedScrollViews.isEmpty {
                for sv in cachedScrollViews {
                    if sv.showsHorizontalScrollIndicator != true { sv.showsHorizontalScrollIndicator = true }
                    if sv.showsVerticalScrollIndicator != true { sv.showsVerticalScrollIndicator = true }
                    if sv.alwaysBounceHorizontal != true { sv.alwaysBounceHorizontal = true }
                    if sv.alwaysBounceVertical != true { sv.alwaysBounceVertical = true }

                    if parent._shouldForceZeroScrollInsets() {
                        if #available(iOS 11.0, *) {
                            if sv.contentInsetAdjustmentBehavior != .never { sv.contentInsetAdjustmentBehavior = .never }
                        }
                        if sv.contentInset != .zero { sv.contentInset = .zero }
                        if #available(iOS 13.0, *) {
                            if sv.verticalScrollIndicatorInsets != .zero { sv.verticalScrollIndicatorInsets = .zero }
                            if sv.horizontalScrollIndicatorInsets != .zero { sv.horizontalScrollIndicatorInsets = .zero }
                        } else {
                            if sv.scrollIndicatorInsets != .zero { sv.scrollIndicatorInsets = .zero }
                        }

                        if #available(iOS 13.0, *) {
                            if sv.automaticallyAdjustsScrollIndicatorInsets != false {
                                sv.automaticallyAdjustsScrollIndicatorInsets = false
                            }
                        }
                    }
                }
                didConfigureScrollIndicators = true
            }

            // If we don't have scroll views yet, retry until PDFKit has created them.
            if cachedScrollViews.isEmpty {
                let now = CFAbsoluteTimeGetCurrent()
                // Throttle the subview walk to avoid UI stalls when SwiftUI updates frequently.
                if now - lastScrollIndicatorScanAt >= 0.35 {
                    lastScrollIndicatorScanAt = now
                    let svs = parent._configureScrollIndicators(pdfView)
                    if !svs.isEmpty {
                        cachedScrollViews = svs
                        didConfigureScrollIndicators = true
                    } else {
                        didConfigureScrollIndicators = false
                    }
                }
            }

            if flash && !didFlashScrollIndicators && !cachedScrollViews.isEmpty {
                parent._flashScrollIndicatorsOnce(cachedScrollViews)
                didFlashScrollIndicators = true
            }
        }

        weak var pdfView: PDFView? = nil {
            didSet {
                if pdfView !== oldValue {
                    scaleObservation?.invalidate()
                    lastAppliedZoom = -1
                    lastAppliedViewWidth = 0
                    cachedScrollViews = []
                    didConfigureScrollIndicators = false
                    didFlashScrollIndicators = false
                    guard let v = pdfView else { return }

                    // Observe scaleFactor so pinch-zoom updates our SwiftUI zoom state.
                    scaleObservation = v.observe(\.scaleFactor, options: [.new]) { [weak self] view, change in
                        guard let self = self, let newScale = change.newValue else { return }
                        // Avoid feedback loops into SwiftUI while we are updating the representable.
                        if self.isInUpdateUIView { return }
                        // While split-drag resizing suppresses programmatic layout, also ignore PDFKit scale churn.
                        if self.parent.suppressProgrammaticLayout || self.parent.isSplitDragActive { return }
                        if self.isProgrammaticScaleChange { return }
                        // Ignore PDFKit-driven scale changes until we have applied an initial logical zoom.
                        if self.lastAppliedZoom < 0 { return }
                        // Ignore changes while the view is not in a window / bounds not yet stable.
                        guard view.window != nil else { return }
                        if view.bounds.width < 200 { return }

                        let fitWidth = self.parent._fitWidthScale(view)
                        guard fitWidth > 0 else { return }
                        let raw = newScale / fitWidth
                        let clamped = max(0.5, min(raw, 5.0))
                        // Avoid tiny oscillations.
                        if abs(self.zoomBinding.wrappedValue - clamped) > 0.01 {
                            DispatchQueue.main.async {
                                self.zoomBinding.wrappedValue = clamped
                            }
                        }
                    }
                }
            }
        }

        // `updateUIView` can be invoked repeatedly with the same `splitActive` value.
        // This wrapper ensures we only execute `noteSplitDrag(active:)` when the active state transitions.
        func noteSplitDragTransitionIfNeeded(active: Bool, pdfView: PDFView) {
            if active == wasSplitDragActive { return }
            noteSplitDrag(active: active, pdfView: pdfView)
        }

        func noteSplitDrag(active: Bool, pdfView: PDFView) {
            if active {
                if parent.restoreAnchorAfterSplitDrag {
                    captureAnchorIfNeeded(pdfView)
                }
                if wasSplitDragActive != true {
                    wasSplitDragActive = true
                    parent.onSplitDragStateChanged?(true)
                }
                // Cancel any pending relayout while actively dragging.
                deferredRelayoutWork?.cancel()
                deferredRelayoutWork = nil
                pendingDeferredRelayout = false
                return
            }

            // Transition: active -> inactive
            if wasSplitDragActive {
                wasSplitDragActive = false
                parent.onSplitDragStateChanged?(false)

                // Schedule exactly one deferred relayout after the next runloop tick.
                // This lets the grab bar finish resizing before we compute fitWidth/scale.
                if !pendingDeferredRelayout {
                    pendingDeferredRelayout = true
                    let work = DispatchWorkItem { [weak self, weak pdfView] in
                        guard let self, let pdfView else { return }
                        self.pendingDeferredRelayout = false

                        // Only apply if the view is in a window and bounds are stable.
                        guard pdfView.window != nil else { return }
                        let viewW = pdfView.bounds.width
                        guard viewW >= 200 else { return }

                        // Take over scale control after resize.
                        if pdfView.autoScales != false { pdfView.autoScales = false }

                        let z = max(0.5, min(self.zoomBinding.wrappedValue, 5.0))
                        let fitWidth = self.parent._fitWidthScale(pdfView)
                        let minSF = fitWidth * 0.5
                        let maxSF = fitWidth * 5.0
                        let target = z * fitWidth

                        self.isProgrammaticScaleChange = true
                        if abs(pdfView.minScaleFactor - minSF) > 0.001 { pdfView.minScaleFactor = minSF }
                        if abs(pdfView.maxScaleFactor - maxSF) > 0.001 { pdfView.maxScaleFactor = maxSF }
                        if abs(pdfView.scaleFactor - target) > 0.01 { pdfView.scaleFactor = target }
                        self.isProgrammaticScaleChange = false

                        self.lastAppliedZoom = z
                        self.lastAppliedViewWidth = viewW
                        if self.parent.restoreAnchorAfterSplitDrag {
                            self.restoreAnchorIfNeeded(pdfView)
                        }
                    }
                    deferredRelayoutWork = work
                    DispatchQueue.main.async(execute: work)
                }
            }
        }

        init(_ parent: Inf6PDFPaneRepresentable, zoomBinding: Binding<CGFloat>) {
            self.parent = parent
            self.zoomBinding = zoomBinding
        }

        @objc func pageChanged(_ note: Notification) {
            guard let v = pdfView, v.window != nil, !parent.suppressProgrammaticLayout, let doc = v.document, let page = v.currentPage else { return }
            let idx = doc.index(for: page)
            guard !isProgrammaticPageChange else { return }
            if idx >= 0 && idx != parent.selectedPage.wrappedValue {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if idx != self.parent.selectedPage.wrappedValue {
                        self.parent.selectedPage.wrappedValue = idx
                    }
                }
            }
        }

        @objc func selectionChanged(_ note: Notification) {
            guard let v = pdfView, v.window != nil, !parent.suppressProgrammaticLayout else { return }
            let pdfSel = v.currentSelection
            let sel = pdfSel?.string?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""

            // Fix (Issue 3): scroll to show the selection extent while the user is dragging.
            // Only do this when the selection is non-empty and user-driven (not programmatic).
            if !sel.isEmpty, let pdfSel, !isInUpdateUIView {
                v.go(to: pdfSel)
            }

            // Fix (Issue 1): always push the current selection string to the binding immediately
            // (synchronous on main thread when already on main, async otherwise).
            // The old guard `sel != parent.selectionText` caused stale-struct reads to suppress updates.
            let update = { [weak self] in
                guard let self else { return }
                self.parent.selectionText = sel
            }
            if Thread.isMainThread {
                update()
            } else {
                DispatchQueue.main.async(execute: update)
            }
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard g.state == .ended, let v = pdfView, v.window != nil, !parent.suppressProgrammaticLayout else { return }
            let tapPoint = g.location(in: v)
            if let hitPage = v.page(for: tapPoint, nearest: true),
               let linkURL = _webLinkURL(at: tapPoint, in: v, on: hitPage) {
                _openExternalURL(linkURL)
                return
            }

            guard let doc = v.document, let page = v.currentPage else { return }
            let idx = max(0, doc.index(for: page))
            let sel = v.currentSelection?.string?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
            if !sel.isEmpty {
                // Sync immediately; don't rely on selectionChanged async path.
                parent.selectionText = sel
                parent.onTap(idx, sel, "selection")
            } else {
                // Fix (Issue 2): tap on empty area — clear old selection in both PDFKit and state.
                if !parent.selectionText.isEmpty {
                    v.clearSelection()
                    parent.selectionText = ""
                }
                parent.onTap(idx, "", "page")
            }
        }

        private func _isWebURL(_ url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased() else { return false }
            return scheme == "http" || scheme == "https"
        }

        private func _webLinkURL(at tapPoint: CGPoint, in pdfView: PDFView, on page: PDFPage) -> URL? {
            let pagePoint = pdfView.convert(tapPoint, to: page)
            guard let annotation = page.annotation(at: pagePoint) else { return nil }

            if let url = annotation.url, _isWebURL(url) {
                return url
            }
            if let action = annotation.action as? PDFActionURL,
               let url = action.url,
               _isWebURL(url) {
                return url
            }
            if let action = annotation.action as? PDFActionRemoteGoTo,
               _isWebURL(action.url) {
                return action.url
            }
            return nil
        }

        private func _openExternalURL(_ url: URL) {
            if #available(iOS 10.0, *) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            } else {
                UIApplication.shared.openURL(url)
            }
        }

        // When PDFKit itself detects a link tap, open only web URLs here and let other action types fall through.
        public func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
            guard sender.window != nil, _isWebURL(url) else { return }
            _openExternalURL(url)
        }

        deinit {
            deferredRelayoutWork?.cancel()
            deferredRelayoutWork = nil
            scaleObservation?.invalidate()
            if let v = pdfView {
                NotificationCenter.default.removeObserver(self, name: .PDFViewPageChanged, object: v)
                NotificationCenter.default.removeObserver(self, name: .PDFViewSelectionChanged, object: v)
            } else {
                NotificationCenter.default.removeObserver(self)
            }
        }
    }
}
#endif

// MARK: - Minimal thumbnail sidebar (iOS)

#if canImport(PDFKit) && os(iOS)
public struct PDFThumbnailSidebarRepresentable: UIViewRepresentable {
    public var pdfView: PDFView?

    public init(pdfView: PDFView? = nil) {
        self.pdfView = pdfView
    }

    public func makeUIView(context: Context) -> PDFThumbnailView {
        let t = PDFThumbnailView()
        t.layoutMode = .vertical
        t.thumbnailSize = CGSize(width: 88, height: 120)
        t.backgroundColor = .clear
        t.pdfView = pdfView
        return t
    }

    public func updateUIView(_ uiView: PDFThumbnailView, context: Context) {
        if uiView.pdfView !== pdfView {
            uiView.pdfView = pdfView
        }
    }
}
#endif
