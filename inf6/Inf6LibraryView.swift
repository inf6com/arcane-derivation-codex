//
//  Inf6LibraryView.swift
//  inf6
//
//  Created by decopin on 2025/12/19.
//

import Foundation
import SwiftUI
import Combine
import CryptoKit
#if canImport(CoreText)
import CoreText
#endif

// Top-level platform imports
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

#if canImport(UIKit)
import UIKit
#endif

#if canImport(PDFKit)
import PDFKit
#endif

// MARK: - Localized string helper (file-local)

/// Localized string helper used across this file.
/// Prefer Japanese when the current locale starts with "ja"; otherwise use English.
@inline(__always)
func L(_ ja: String, _ en: String) -> String {
    // Follow the app's language override when set; otherwise follow the system locale.
    let raw = (
        UserDefaults.standard.string(forKey: "inf6_ui_language") ??
        UserDefaults.standard.string(forKey: "gen_lang") ??
        "auto"
    )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

    switch raw {
    case "ja":
        return ja
    case "en":
        return en
    default:
        let id = Locale.current.identifier.lowercased()
        return id.hasPrefix("ja") ? ja : en
    }
}

enum Inf6CodexDesign {
    static let ink = Color(red: 0.025, green: 0.075, blue: 0.19)
    static let blue = Color(red: 0.02, green: 0.34, blue: 0.95)
    static let dodgersBlue = Color(red: 0.02, green: 0.24, blue: 0.62)
    static let cyan = Color(red: 0.00, green: 0.82, blue: 0.95)
    static let magenta = Color(red: 0.95, green: 0.04, blue: 0.42)
    static let featureVectorGradient = LinearGradient(
        colors: [
            Color(red: 0.58, green: 0.22, blue: 0.95),
            Color(red: 0.95, green: 0.16, blue: 0.68),
            Color(red: 0.06, green: 0.82, blue: 0.96),
            Color(red: 0.18, green: 0.92, blue: 0.70),
            Color(red: 0.68, green: 0.82, blue: 0.62),
            Color(red: 1.00, green: 0.32, blue: 0.46),
            Color(red: 0.70, green: 0.22, blue: 0.94)
        ],
        startPoint: .leading,
        endPoint: .trailing
    )
    static let surface = Color(red: 0.025, green: 0.10, blue: 0.22)
    static let surfaceRaised = Color(red: 0.035, green: 0.15, blue: 0.30)
    static var display: Font { Inf6ApplicationSystemFont.font(size: 22, weight: .heavy, design: .default) }
    static var section: Font { Inf6ApplicationSystemFont.font(size: 19, weight: .bold, design: .default) }
    static var technical: Font { Inf6ApplicationSystemFont.font(size: 14, weight: .medium, design: .default) }
}

enum Inf6ApplicationSystemFont {
    static let userDefaultsKey = "inf6.application.systemFontFamily"
    static let sizeUserDefaultsKey = "inf6.application.systemFontSize"
    static let systemValue = ""
    static let defaultSize: Double = 19

    static var selectedFamily: String { UserDefaults.standard.string(forKey: userDefaultsKey) ?? systemValue }
    static var baseSize: Double {
        let value = UserDefaults.standard.double(forKey: sizeUserDefaultsKey)
        return value > 0 ? value : defaultSize
    }
    static func scaledSize(_ size: CGFloat) -> CGFloat {
        size * CGFloat(baseSize / defaultSize)
    }
    static func font(size: CGFloat, weight: Font.Weight, design: Font.Design) -> Font {
        let family = selectedFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        let scaledSize = size * CGFloat(baseSize / defaultSize)
        return family.isEmpty ? .system(size: scaledSize, weight: weight) : .custom(family, size: scaledSize).weight(weight)
    }
}

struct Inf6CodexMarbleBackdrop: View {
    var body: some View {
        Inf6CodexDesign.ink
    }
}

extension View {
    func inf6CodexPanel(stroke: Color = Inf6CodexDesign.cyan, radius: CGFloat = 12) -> some View {
        background(Inf6CodexDesign.surfaceRaised)
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(stroke.opacity(0.72), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: radius))
    }
}

struct Inf6ApplicationSystemFontSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Inf6ApplicationSystemFont.userDefaultsKey) private var selectedFamily = Inf6ApplicationSystemFont.systemValue
    @AppStorage(Inf6ApplicationSystemFont.sizeUserDefaultsKey) private var selectedSize = Inf6ApplicationSystemFont.defaultSize

    var body: some View {
        NavigationStack {
            Form {
                Picker("アプリケーションシステムフォント", selection: $selectedFamily) {
                    Text("システム標準").tag("")
                    #if canImport(UIKit)
                    ForEach(UIFont.familyNames.sorted(), id: \.self) { Text($0).tag($0) }
                    #endif
                }
                VStack(alignment: .leading) {
                    Text("文字サイズ: \(Int(selectedSize)) pt")
                    Slider(value: $selectedSize, in: 12...32, step: 1)
                }
            }
            .navigationTitle("文字表示")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
        }
    }
}

private func _inf6NaturalizedExplanationText(_ raw: String) -> String {
    var text = raw
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")

    text = text
        .replacingOccurrences(of: #"(?m)^```[A-Za-z0-9_-]*\s*$"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"(?m)^```\s*$"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"(?m)^\s{0,3}>\s?"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"(?m)^\s{0,3}[-*_]{3,}\s*$"#, with: "", options: .regularExpression)

    text = text
        .replacingOccurrences(of: #"\*\*([^*\n][\s\S]*?[^*\n])\*\*"#, with: "$1", options: .regularExpression)
        .replacingOccurrences(of: #"__([^_\n][\s\S]*?[^_\n])__"#, with: "$1", options: .regularExpression)
        .replacingOccurrences(of: #"`([^`\n]+)`"#, with: "$1", options: .regularExpression)
        .replacingOccurrences(of: #"\[([^\]\n]+)\]\(([^)\n]+)\)"#, with: "$1", options: .regularExpression)

    text = text
        .replacingOccurrences(of: #"\\left|\\right"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\\quad"#, with: "  ", options: .regularExpression)
        .replacingOccurrences(of: #"\\phi"#, with: "φ", options: .regularExpression)
        .replacingOccurrences(of: #"\\theta"#, with: "θ", options: .regularExpression)
        .replacingOccurrences(of: #"\\lambda"#, with: "λ", options: .regularExpression)
        .replacingOccurrences(of: #"\\alpha"#, with: "α", options: .regularExpression)
        .replacingOccurrences(of: #"\\beta"#, with: "β", options: .regularExpression)
        .replacingOccurrences(of: #"\\gamma"#, with: "γ", options: .regularExpression)
        .replacingOccurrences(of: #"\\sigma"#, with: "σ", options: .regularExpression)
        .replacingOccurrences(of: #"\\sum"#, with: "Σ", options: .regularExpression)
        .replacingOccurrences(of: #"\\prod"#, with: "Π", options: .regularExpression)
        .replacingOccurrences(of: #"\\hat\{y\}"#, with: "ŷ", options: .regularExpression)
        .replacingOccurrences(of: #"\\\{"#, with: "{", options: .regularExpression)
        .replacingOccurrences(of: #"\\\}"#, with: "}", options: .regularExpression)
        .replacingOccurrences(of: #"\^\{([^}]+)\}"#, with: "^$1", options: .regularExpression)
        .replacingOccurrences(of: #"_\{([^}]+)\}"#, with: "_$1", options: .regularExpression)
        .replacingOccurrences(of: #"\\([A-Za-z]+)"#, with: "$1", options: .regularExpression)

    let lines = text.components(separatedBy: "\n").map { line -> String in
        var s = line.trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: #"^[-*+]\s+"#, with: "• ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^\d+[.)]\s+"#, with: "", options: .regularExpression)
        return s
    }
    return lines
        .joined(separator: "\n")
        .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Assets pipeline run-state

enum Inf6AssetsPipelineRunState: String, Codable {
    case none
    case running
    case finished
    case failed
}

func inf6AssetsPipelineRunStateKey(pdfURL: URL) -> String {
    // NOTE: v1 used only `lastPathComponent`, which collides when different PDFs share the same filename.
    // v2 keys the run-state by the *standardized file path* to avoid false carry-over between distinct PDFs.
    let path = pdfURL.standardizedFileURL.path
    let safe = path.replacingOccurrences(of: "/", with: "_")
    return "inf6_assets_pipeline_state_v2_" + safe
}

func inf6AssetsPipelineStatusURL(pdfURL: URL) -> URL? {
    let folderKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: pdfURL)
    guard !folderKey.isEmpty else { return nil }
    guard let sharedRoot = try? Inf6LibraryView._sharedRootDir() else { return nil }
    return sharedRoot
        .appendingPathComponent(Inf6KnowledgeCardsPaths.rootFolderName, isDirectory: true)
        .appendingPathComponent(folderKey, isDirectory: true)
        .appendingPathComponent("assets.pipeline.status.json")
}

func inf6LoadStructuredAssetsPipelineRunState(pdfURL: URL) -> Inf6AssetsPipelineRunState? {
    let key = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: pdfURL)
    if !key.isEmpty,
       let state = Inf6MetadataStore.getCodable(Inf6AssetsPipelineRunState.self, domain: .assetsPipeline, key: key) {
        return state
    }

    guard let url = inf6AssetsPipelineStatusURL(pdfURL: pdfURL) else { return nil }
    guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
    guard let status = try? JSONDecoder().decode(Inf6AssetsPipelineStatus.self, from: data) else { return nil }
    if !key.isEmpty {
        Inf6MetadataStore.putCodable(status.resolvedState, domain: .assetsPipeline, key: key)
    }
    return status.resolvedState
}

func inf6WriteStructuredAssetsPipelineRunState(pdfURL: URL, state: Inf6AssetsPipelineRunState) {
    let key = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: pdfURL)
    if !key.isEmpty {
        Inf6MetadataStore.putCodable(state, domain: .assetsPipeline, key: key)
    }

    guard let url = inf6AssetsPipelineStatusURL(pdfURL: pdfURL) else { return }
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let now = Date().timeIntervalSince1970
        let previousSuccessAt: TimeInterval? = {
            guard let data = try? Data(contentsOf: url), !data.isEmpty,
                  let existing = try? JSONDecoder().decode(Inf6AssetsPipelineStatus.self, from: data)
            else { return nil }
            return existing.lastSuccessAt
        }()
        let status = Inf6AssetsPipelineStatus(
            lastAttemptAt: now,
            lastAttemptSucceeded: state == .finished,
            lastSuccessAt: state == .finished ? now : previousSuccessAt,
            state: state
        )
        let data = try JSONEncoder().encode(status)
        try data.write(to: url, options: [.atomic])
    } catch {
        print("[Inf6AssetsPipelineStatus] write failed: \(url.path) error=\(error)")
    }
}

func inf6LoadAssetsPipelineRunState(pdfURL: URL) -> Inf6AssetsPipelineRunState {
    if let structured = inf6LoadStructuredAssetsPipelineRunState(pdfURL: pdfURL) {
        return structured
    }
    let raw = (UserDefaults.standard.string(forKey: inf6AssetsPipelineRunStateKey(pdfURL: pdfURL)) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let state = Inf6AssetsPipelineRunState(rawValue: raw) ?? .none
    if state != .none {
        inf6WriteStructuredAssetsPipelineRunState(pdfURL: pdfURL, state: state)
    }
    return state
}

func inf6SaveAssetsPipelineRunState(pdfURL: URL, state: Inf6AssetsPipelineRunState) {
    UserDefaults.standard.set(state.rawValue, forKey: inf6AssetsPipelineRunStateKey(pdfURL: pdfURL))
    inf6WriteStructuredAssetsPipelineRunState(pdfURL: pdfURL, state: state)
}

// MARK: - onChange compatibility helper (iOS 17+/macOS 14+)

extension View {
    /// Avoids deprecated `onChange(of:perform:)` on newer SDKs while keeping older OS compatibility.
    @ViewBuilder
    func inf6OnChange<Value: Equatable>(_ value: Value, perform: @escaping (Value) -> Void) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.onChange(of: value) { _, newValue in
                perform(newValue)
            }
        } else {
            self.onChange(of: value, perform: perform)
        }
    }
}

// MARK: - Cross-view notifications

extension Notification.Name {
    /// Posted by AutoPapers: request the Library to show the PDF import picker.
    /// IMPORTANT: The Library must not auto-open the PDF from this notification.
    static let inf6OpenSavedPaperPDFInLibrary = Notification.Name("inf6.openSavedPaperPDFInLibrary")
    /// Posted by AutoPapers: request the Library to show the PDF import picker (no preselected URL).
    static let inf6RequestLibraryImportPicker = Notification.Name("inf6.requestLibraryImportPicker")
    static let inf6PipelineDidStart = Notification.Name("inf6.pipelineDidStart")
    static let inf6PipelineDidFinish = Notification.Name("inf6.pipelineDidFinish")
    static let inf6QuizDidFinish = Notification.Name("inf6.quizDidFinish")
    static let inf6ExplainSelection = Notification.Name("inf6.explainSelection")
    static let inf6ScatterMigrationDidComplete = Notification.Name("inf6.scatterMigrationDidComplete")
}

struct Inf6LibraryPaperListItem: Identifiable, Hashable {
    let url: URL
    let title: String

    var id: String { url.standardizedFileURL.path }
}

private struct _QuizNeedsEntityPipelineError: Error {
    let sourceFamily: String
    let nodeID: String
}

// MARK: - 1) Inf6LibraryView (main)
struct Inf6LibraryView: View {

    // MARK: - Types

#if canImport(UIKit)
    typealias PlatformImage = UIImage
#endif

    // MARK: - Persistent settings

    @AppStorage("gen_lang") var genLangRaw: String = "ja"
    /// 保存先が未設定のあいだは、起動のたびに選んでもらう。
    /// 「一度出したか」で覚えると、選ばずに閉じた利用者が二度と設定に
    /// たどり着けないまま、追い出される場所に置き続けることになる。
    /// 全画面で開くもの。重ねずに、これ一つで出し分ける。
    enum _FullScreenDestination: String, Identifiable {
        case initialStorageSetup
        case storageSettings
        case dataExchange
        case autoPapers
        case help
        var id: String { rawValue }
    }
    @State private var activeFullScreen: _FullScreenDestination?
    @AppStorage("inf6_ui_language") var uiLanguageRaw: String = "auto"
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openWindow) private var openWindow

    /// UI locale override for in-app language switching.
    /// - "ja": force Japanese UI strings
    /// - "en": force English UI strings
    /// - "auto": follow system locale
    var inf6UILocale: Locale {
        switch genLangRaw {
        case "ja":
            return Locale(identifier: "ja_JP")
        case "en":
            return Locale(identifier: "en_US")
        default:
            return Locale.autoupdatingCurrent
        }
    }

    // MARK: - UI State

    @State var showPDFPicker: Bool = false
    @State var showOpenAISettings: Bool = false
    @State var showPromptSettings: Bool = false
    @State var showSourcesSettings: Bool = false
    @State var showRootFolderPicker: Bool = false
    /// 取得元のチェックを切り替えたときにメニューを描き直すための版数。
    @State var autoPapersInitialSearch: String = ""
    /// AI 資格画面（JDLA G検定など）の表示フラグ。
    @State var knowledgeStructureInitialSearch: String = ""
    @State var circuitBoardFocusRawID: String? = nil
    /// IT 資格画面（Microsoft Learn など）の表示フラグ。
    @State var showITCertSheet: Bool = false
    @State var showPaperLibrarySheet: Bool = false
    @State var libraryPaperItems: [Inf6LibraryPaperListItem] = []
    // Formula mini PDFs are page-scoped (you revisit a page many times while studying).
    // Store a per-page history so generating a new one never deletes/replaces the previous.
    @State var formulaMiniPDFsByPage: [Int: [_FormulaMiniEntry]] = [:]

    // Sheet flag for formula mini PDF history.
    @State var showFormulaMiniHistorySheet: Bool = false

    // Whether the bottom mini formula pane is currently visible (entries are kept even when hidden).
    @State var isFormulaMiniPaneVisible: Bool = true

    // Last known selection anchor (distance from top of the page in PDF coordinates).
    // Used to sort mini formulas by their on-page position.
    @State var formulaSelectionAnchorYFromTop: CGFloat? = nil

    struct _FormulaMiniEntry: Identifiable, Hashable {
        let id: UUID
        let url: URL
        let yFromTop: CGFloat
        let createdAt: TimeInterval

        init(url: URL, yFromTop: CGFloat) {
            self.id = UUID()
            self.url = url
            self.yFromTop = yFromTop
            self.createdAt = Date().timeIntervalSince1970
        }
    }

    // Stable formula selection text (NOT cleared by explanation/addendum actions).
    // Formula mini PDF generation relies on this selection text.
    @State var formulaSelectionText: String = ""

    // Page index where the current formula selection was made (used to store history per page).
    @State var formulaSelectionPageIndex: Int? = nil

    // Surface a user-visible hint when formula preview cannot be generated.
    @State var showFormulaError: Bool = false
    @State var formulaErrorMessage: String = ""
    @State var didAutoLoad: Bool = false
    @State var _pagePersistDebounce = _Inf6DebounceBox()
    @State var _notesPersistDebounce = _Inf6DebounceBox()
    @State var _pageExplainCachePersistDebounce = _Inf6DebounceBox()

    // Import error surfacing (previously failures were silent when `fullPDFURL` stayed nil).
    @State var showImportError: Bool = false
    @State var importErrorMessage: String = ""
    @State private var _pendingQuizPipelineRun: (sourceFamily: String, nodeID: String, explanationRawID: String, quizKey: String)?
    @State private var _pendingEntityPipelineRun: (sourceFamily: String, nodeID: String, kinds: Set<Inf6DocEntityKind>, forceRerun: Bool)?
    @State private var _pendingQuizGeneration: (rawID: String, explanationRawID: String, titleJa: String, paperID: String?)?
    @State private var _pendingExplanationGeneration: (rawID: String, titleJa: String)?
    @State var showAssetsPipelineError: Bool = false
    @State var assetsPipelineErrorMessage: String = ""
    @State var assetsPipelineRunState: Inf6AssetsPipelineRunState = .none
    @State private var _retainedSecurityScopeFolderURL: URL? = nil
    @State private var _retainedSecurityScopeIsActive: Bool = false
    @State private var _retainedSecurityScopeFileURL: URL? = nil
    @State private var _retainedSecurityScopeFileIsActive: Bool = false
    @State var showSidecarSaveError: Bool = false
    @State var sidecarSaveErrorMessage: String = ""
    @State private var _showLibrarySidebar: Bool = true
    @State private var _libraryEditMode: Bool = false
    @State private var _selectedLibraryItemIDs: Set<String> = []
    @State private var _showLibraryDeleteConfirm: Bool = false

    let _addExplanationApproxHeight: CGFloat = 56
    let _gapBetweenFabs: CGFloat = 12

    // User-resizable bottom explanation pane height.
    @State var explanationPaneHeight: CGFloat = 280
    @State var _explanationPaneDragStartHeight: CGFloat? = nil

    // Track available vertical space for bottom overlays so the resize range is based on the device/window.
    @State var _bottomOverlayAvailableHeight: CGFloat = 0

    var _explanationPaneMinHeight: CGFloat { 160 }

    var _explanationPaneMaxHeight: CGFloat {
        // Base the max on current available height (iPhone / iPad split view / Stage Manager).
        // Fallback to the legacy cap when we don't know the size yet.
        guard _bottomOverlayAvailableHeight > 0 else { return 640 }
        // Keep at least ~260 so the editor is usable, but avoid covering the whole PDF on small screens.
        let cap = max(260, _bottomOverlayAvailableHeight * 0.60)
        return min(640, cap)
    }

    func _clampExplanationPaneHeight(_ h: CGFloat) -> CGFloat {
        min(max(h, _explanationPaneMinHeight), _explanationPaneMaxHeight)
    }

    // MARK: - Explanation Overlay State

    @State fileprivate var explanationOverlay: _OriginalExplanationContent? = nil
    @State var explanationOverlayTitle: String = ""
    @State var explanationOverlayRawID: String? = nil
    @State var _explanationEntitySidebar: _ExplanationEntitySidebarData? = nil

    struct _ExplanationEntitySidebarData {
        var entities: [Inf6DocEntity]
        var pdfKey: String
    }
    @State var explanationFontSize: CGFloat = 24

    // MARK: - PDF State

    @State var fullPDFURL: URL? = nil
    @State var fullPDFExplanation: String = ""
    /// Paper-level generated overview (persisted per PDF). Kept separate from per-page explanations.
    @State var paperAbstract: String = ""
    /// True when the UI should keep showing the paper-level generated overview even as pages change.
    @State var isShowingPaperAbstract: Bool = false
    @State var isGeneratingExplanation: Bool = false
    /// Bottom explanation pane visibility (paper overview / page explanations / notes).
    @State var isExplanationPaneVisible: Bool = true
    /// Current page index for UI bindings (notes pane, etc.). Updated from the PDF view.
    @State var currentPageIndexForUI: Int = 0

    /// 直近タップ（context-menu用途）: どのページのどの抜粋を解説すべきか。
    @State var pendingPDFTap: (pageIndex: Int, text: String, rectDesc: String)? = nil
    /// Explanation/notes side selection mirror (used by note cards). Not used for formula preview.
    @State var selectedText: String = ""

    /// ページ解説キャッシュ（同一ページへの再問い合わせを抑止）
    @State var pageExplanationCache: [Int: String] = [:]
    @State var lastExplainedPageIndex: Int? = nil

    /// ページごとの追加解説（青文字）
    @State var pageExtraNotes: [Int: [Inf6ExtraNote]] = [:]
    /// Per-PDF stable key (the original PDF filename). Used to name the single iCloud sidecar files.
    @State var currentPDFCacheKey: String? = nil

    // MARK: - View

    var body: some View {
        let nav = SwiftUI.NavigationStack {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    ZStack {
                        content

                        if isGeneratingExplanation {
                            ZStack {
                                Color.black.opacity(0.05).ignoresSafeArea()
                                ProgressView(L("解説生成中…", "Generating…"))
                                    .padding(16)
                                    .background(.ultraThinMaterial)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .toolbar { toolbarContent }
            .tint(.blue)
            .navigationBarTitleDisplayMode(.inline)
        }

        let v1 = nav.sheet(isPresented: $showPDFPicker) {
            Inf6DocumentFilePickerWrapper(initialFolderURL: Self.lastPDFFolderURL(), onPick: { urls in
                handlePickedPDFs(urls)
            })
        }

        let v2 = v1.sheet(isPresented: $showRootFolderPicker) {
            RootFolderPickerWrapper { folderURL in
                guard let folderURL = folderURL else {
                    self.showSidecarSaveError = true
                    self.sidecarSaveErrorMessage = L(
                        "ルートフォルダが選択されていません。",
                        "No root folder selected."
                    )
                    self.showRootFolderPicker = false
                    return
                }
                do {
                    try Inf6LibraryView._storeUserRootFolderURL(folderURL)
                } catch {
                    self.showSidecarSaveError = true
                    self.sidecarSaveErrorMessage = error.localizedDescription
                    self.showRootFolderPicker = false
                    return
                }
                self.showRootFolderPicker = false
                Task { @MainActor in
                    self.refreshPaperLibraryItems(surfacingError: true)
                }
            }
        }

        let v3 = v2.sheet(isPresented: $showOpenAISettings) {
            APIKeySettingsView()
        }

        let v4 = v3.sheet(isPresented: $showSourcesSettings) {
            Inf6SourcesSettingsSheet()
        }

        let v5 = v4.sheet(isPresented: $showPromptSettings) {
            Inf6PromptSettingsView()
        }

        // 同じ画面にいくつも重ねると、後ろのものしか出てこない。初期設定が
        // 出てこなかったのも、メニューから何も開かなかったのもこれである。
        // 出し分けは値で行い、覆いは一つにする。
        let v5exchange = v5.fullScreenCover(item: $activeFullScreen) { destination in
            switch destination {
            case .initialStorageSetup:
                Inf6InitialStorageSetupView(isPresented: Binding(
                    get: { true },
                    set: { if !$0 { activeFullScreen = nil } }
                ))
            case .storageSettings:
                NavigationStack {
                    Inf6InitialStorageSetupView(isPresented: Binding(
                        get: { true },
                        set: { if !$0 { activeFullScreen = nil } }
                    ))
                }
            case .dataExchange:
                NavigationStack {
                    Inf6DataExchangeView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(L("閉じる", "Close")) { activeFullScreen = nil }
                            }
                        }
                }
            case .autoPapers:
                autoPapersPresenterView
            case .help:
                HelpSheetView()
            }
        }

        let v6 = v5exchange

        let v7 = v6.sheet(isPresented: $showFormulaMiniHistorySheet) {
            formulaMiniHistorySheetView
        }

        let v8 = v7.sheet(isPresented: $showPaperLibrarySheet) {
            NavigationStack {
                paperLibraryPanel(inSheet: true)
                    .navigationTitle(L("論文", "Papers"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L("閉じる", "Close")) {
                                showPaperLibrarySheet = false
                            }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }

        let v8m = v8

        let v9 = v8m.onAppear {
            // 保存先が一度も選ばれていなければ尋ねる。選ばれていれば出さない。
            if (Inf6EntityImageLocation.displayPath == nil
                || Inf6EntityImageLocation.hasUnavailableStoredSelection)
                && activeFullScreen == nil {
                activeFullScreen = .initialStorageSetup
            }

            guard !didAutoLoad else { return }
            didAutoLoad = true

            // 以前開いていた PDF フォルダ（＝ picker の初期ディレクトリ）を復元するだけ。
            // PDFファイル自体の自動復元は、セキュリティスコープや場所移動で壊れやすいので行わない。
            _ = Self.lastPDFFolderURL()
            Task { @MainActor in
                refreshPaperLibraryItems(surfacingError: false)
            }
        }

        let v9a = v9.task {
            let storedFontSize = await Task.detached(priority: .utility) {
                guard let raw = Inf6MetadataStore.get(domain: .settings, key: "explanation_font_size"),
                      let value = Double(raw) else { return CGFloat? (nil) }
                return CGFloat(value)
            }.value
            guard !Task.isCancelled, let storedFontSize else { return }
            explanationFontSize = storedFontSize
        }

        let v10 = v9a.inf6OnChange(fullPDFURL) { newURL in
            guard let newURL else { return }
            let u = newURL.standardizedFileURL
            let newKey = u.lastPathComponent.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !newKey.isEmpty else { return }

            // If the document changed (or was set via a non-picker code path), refresh the per-PDF state.
            if (self.currentPDFCacheKey ?? "") != newKey {
                self.currentPDFCacheKey = newKey

                // Reset per-document UI state so we never leak the previous paper’s content.
                self.fullPDFExplanation = ""
                self.paperAbstract = ""
                self.isShowingPaperAbstract = false
                self.isGeneratingExplanation = false
                self.isExplanationPaneVisible = true

                // Per-page caches / notes (reloaded below if a cache exists).
                self.pageExplanationCache.removeAll(keepingCapacity: true)
                self.pageExtraNotes.removeAll(keepingCapacity: true)
                self.lastExplainedPageIndex = nil

                // Formula mini PDFs & selection are document-scoped; clear when switching PDFs.
                self.formulaMiniPDFsByPage.removeAll(keepingCapacity: true)
                self.isFormulaMiniPaneVisible = true
                self.formulaSelectionText = ""
                self.formulaSelectionPageIndex = nil
                self.formulaSelectionAnchorYFromTop = nil

                // Reload persisted per-PDF state whenever the document changes.
                do {
                    try self.restoreCurrentPDFCache()
                } catch {
                    self.showSidecarSaveError = true
                    self.sidecarSaveErrorMessage = L(
                        "PDFキャッシュの復元に失敗しました: \(error.localizedDescription)",
                        "Failed to restore PDF cache: \(error.localizedDescription)"
                    )
                }
                self.restoreNotesDictFromDisk()
                self.restorePageExplanationCacheFromDisk()
                self.assetsPipelineRunState = inf6LoadAssetsPipelineRunState(pdfURL: u)
            }
        }

        let v11 = v10.onReceive(NotificationCenter.default.publisher(for: .inf6OpenSavedPaperPDFInLibrary)) { note in
            // AutoPapers requests the Library to open an already-saved PDF directly.
            // Do NOT show the import picker for this notification.
            // PDF switching is allowed even during pipeline (pipeline guards its own writes via URL snapshot).

            let urls: [URL]? = {
                if let u = note.object as? URL { return [u] }
                if let us = note.object as? [URL], !us.isEmpty { return us }
                return nil
            }()

            guard let urls else {
                // Surface the failure explicitly (do not silently ignore invalid payloads).
                showImportError = true
                importErrorMessage = L(
                    "通知の形式が不正です（URLが渡されていません）。",
                    "Invalid notification payload (no URL provided)."
                )
                return
            }

            if let folderURL = note.userInfo?["inf6.folderURL"] as? URL {
                let folderAccess = _retainSecurityScopeFolder(folderURL)
                if !folderAccess {
                    showImportError = true
                    importErrorMessage = L(
                        "保存先フォルダへのアクセス権を取得できませんでした。端末側で『保存先管理』から同じ保存先フォルダを再選択してください。",
                        "Could not obtain access to the destination folder. Re-select the same destination folder in Destination Management on the device."
                    )
                    return
                }
            } else if let first = urls.first {
                _retainSecurityScopeFolder(first.deletingLastPathComponent())
            }

            // Ensure AutoPapers overlay does not stay on top of the Library.
            activeFullScreen = nil

            // Open the provided PDF URL(s) directly.
            handlePickedPDFs(urls)
            Task { @MainActor in
                refreshPaperLibraryItems(surfacingError: false)
            }
        }

        let v12 = v11.onReceive(NotificationCenter.default.publisher(for: .inf6RequestLibraryImportPicker)) { note in
            // Do NOT auto-open PDFs via this notification.
            // The Library must only show the import picker.
            // Pipeline-in-progress no longer blocks the picker (pipeline guards its own writes).

            // If a folder URL is provided, use it as the picker’s initial location.
            if let folder = note.object as? URL {
                Self.rememberPDFFolderURL(folder)
            }

            // Ensure AutoPapers overlay does not stay on top of the Library.
            activeFullScreen = nil

            // Show the picker only.
            showPDFPicker = true
        }

        let v13 = v12.alert(L("PDF取り込みエラー", "PDF Import Error"), isPresented: $showImportError) {
            Button(L("OK", "OK"), role: .cancel) {}
        } message: {
            Text(importErrorMessage)
        }

        let v13b = v13.alert(
            L("パイプラインアイテムがありません", "No Pipeline Items"),
            isPresented: Binding(
                get: { _pendingQuizPipelineRun != nil },
                set: { if !$0 { _pendingQuizPipelineRun = nil } }
            )
        ) {
            Button(L("実行", "Run"), role: nil) {
                guard let pending = _pendingQuizPipelineRun else { return }
                _pendingQuizPipelineRun = nil
                Task { @MainActor in
                    do {
                        try await _runNewEntityPipeline(sourceFamily: pending.sourceFamily, nodeID: pending.nodeID, kinds: [.figure, .table, .equation])
                        let quizRawID = _canonicalQuizRawID(pending.quizKey)
                        try await _generateQuizJSON(explanationRawID: pending.explanationRawID, quizRawID: quizRawID)
                        NotificationCenter.default.post(name: .inf6QuizDidFinish, object: quizRawID)
                        let result = try _loadQuizContent(rawID: quizRawID)
                        explanationOverlayTitle = result.title
                        explanationOverlayRawID = quizRawID
                        explanationOverlay = result.content
                    } catch {
                        showImportError = true
                        importErrorMessage = L("演習の生成に失敗しました: \(error.localizedDescription)", "Failed to generate exercise: \(error.localizedDescription)")
                    }
                }
            }
            Button(L("キャンセル", "Cancel"), role: .cancel) {
                _pendingQuizPipelineRun = nil
            }
        } message: {
            Text(L("パイプラインを実行して、アイテムを作成しますか？", "Run the pipeline to generate items?"))
        }

        let v13c = v13b.alert(
            L("図表式の生成", "Generate Figures/Tables/Equations"),
            isPresented: Binding(
                get: { _pendingEntityPipelineRun != nil },
                set: {
                    if !$0 {
                        if let pending = _pendingEntityPipelineRun {
                            NotificationCenter.default.post(name: .inf6PipelineDidFinish, object: "\(pending.sourceFamily):\(pending.nodeID)")
                        }
                        _pendingEntityPipelineRun = nil
                    }
                }
            )
        ) {
            Button(L("生成する", "Generate"), role: nil) {
                guard let pending = _pendingEntityPipelineRun else { return }
                _pendingEntityPipelineRun = nil
                Task { @MainActor in
                    NotificationCenter.default.post(name: .inf6PipelineDidStart, object: "\(pending.sourceFamily):\(pending.nodeID)")
                    if pending.forceRerun {
                        _clearExistingEntities(sourceFamily: pending.sourceFamily, nodeID: pending.nodeID, kinds: pending.kinds)
                    }
                    do {
                        try await _runNewEntityPipeline(sourceFamily: pending.sourceFamily, nodeID: pending.nodeID, kinds: pending.kinds)
                    } catch {
                        showImportError = true
                        importErrorMessage = L("図・表・数式の生成に失敗しました: \(error.localizedDescription)", "Failed to generate figure, table, or equation items: \(error.localizedDescription)")
                    }
                }
            }
            Button(L("キャンセル", "Cancel"), role: .cancel) {
                if let pending = _pendingEntityPipelineRun {
                    NotificationCenter.default.post(name: .inf6PipelineDidFinish, object: "\(pending.sourceFamily):\(pending.nodeID)")
                }
                _pendingEntityPipelineRun = nil
            }
        } message: {
            Text(L("図表式の抽出と解説生成を開始しますか？", "Start extracting figures, tables, and equations?"))
        }

        let v13d0 = v13c.alert(
            L("概要解説の生成", "Generate Overview"),
            isPresented: Binding(
                get: { _pendingExplanationGeneration != nil },
                set: { if !$0 { _pendingExplanationGeneration = nil } }
            )
        ) {
            Button(L("生成する", "Generate"), role: nil) {
                guard let pending = _pendingExplanationGeneration else { return }
                _pendingExplanationGeneration = nil
                Task { @MainActor in
                    do {
                        explanationOverlayTitle = pending.titleJa
                        explanationOverlayRawID = pending.rawID
                        explanationOverlay = _OriginalExplanationContent(sections: [
                            .init(heading: L("生成中…", "Generating…"), body: L("概要解説を生成しています。しばらくお待ちください。", "Generating overview. Please wait…"), kind: "text")
                        ])
                        try await _generateOriginalExplanationJSON(rawID: pending.rawID)
                        explanationOverlay = try _loadOriginalExplanationContent(rawID: pending.rawID)
                    } catch {
                        explanationOverlay = nil
                        showImportError = true
                        importErrorMessage = L("概要解説の生成に失敗しました: \(error.localizedDescription)", "Failed to generate overview: \(error.localizedDescription)")
                    }
                }
            }
            Button(L("キャンセル", "Cancel"), role: .cancel) {
                _pendingExplanationGeneration = nil
            }
        } message: {
            Text(L("概要解説を生成しますか？（API通信が発生します）", "Generate overview? (This will use the API.)"))
        }

        let v13d = v13d0.alert(
            L("演習の生成", "Generate Exercises"),
            isPresented: Binding(
                get: { _pendingQuizGeneration != nil },
                set: { if !$0 { _pendingQuizGeneration = nil } }
            )
        ) {
            Button(L("生成する", "Generate"), role: nil) {
                guard let pending = _pendingQuizGeneration else { return }
                _pendingQuizGeneration = nil
                Task { @MainActor in
                    do {
                        let paperTitle: String
                        if let pid = pending.paperID,
                           let paper = Inf6CorePaperStore.shared.papers.first(where: { $0.id == pid }) {
                            paperTitle = "\(pending.titleJa) — \(paper.title) — 演習"
                        } else {
                            paperTitle = "\(pending.titleJa) — 演習"
                        }
                        explanationOverlayTitle = paperTitle
                        explanationOverlayRawID = pending.rawID
                        explanationOverlay = _OriginalExplanationContent(sections: [
                            .init(heading: L("生成中…", "Generating…"), body: L("演習を生成しています。しばらくお待ちください。", "Generating exercises. Please wait…"), kind: "text")
                        ])
                        let filterPaperIDs: [String]? = pending.paperID.map { [$0] }
                        try await _generateQuizJSON(explanationRawID: pending.explanationRawID, quizRawID: pending.rawID, filterPaperIDs: filterPaperIDs)
                        NotificationCenter.default.post(name: .inf6QuizDidFinish, object: pending.rawID)
                        let result = try _loadQuizContent(rawID: pending.rawID)
                        explanationOverlayTitle = result.title
                        explanationOverlay = result.content
                    } catch let e as _QuizNeedsEntityPipelineError {
                        explanationOverlay = nil
                        NotificationCenter.default.post(name: .inf6QuizDidFinish, object: pending.rawID)
                        let quizKey = _quizKeyWithoutPrefix(pending.rawID)
                        _pendingQuizPipelineRun = (sourceFamily: e.sourceFamily, nodeID: e.nodeID, explanationRawID: pending.explanationRawID, quizKey: quizKey)
                    } catch {
                        explanationOverlay = nil
                        NotificationCenter.default.post(name: .inf6QuizDidFinish, object: pending.rawID)
                        showImportError = true
                        importErrorMessage = L("演習の生成に失敗しました: \(error.localizedDescription)", "Failed to generate exercise: \(error.localizedDescription)")
                    }
                }
            }
            Button(L("キャンセル", "Cancel"), role: .cancel) {
                _pendingQuizGeneration = nil
            }
        } message: {
            Text(L("演習問題を生成しますか？（API通信が発生します）", "Generate exercises? (This will use the API.)"))
        }

        let v14 = v13d.alert(L("パイプラインエラー", "Pipeline Error"), isPresented: $showAssetsPipelineError) {
            Button(L("OK", "OK"), role: .cancel) {}
        } message: {
            Text(assetsPipelineErrorMessage)
        }

        let v15 = v14.alert(L("保存エラー", "Save Error"), isPresented: $showSidecarSaveError) {
            Button(L("OK", "OK"), role: .cancel) {}
        } message: {
            Text(sidecarSaveErrorMessage)
        }

        let v16 = v15.alert(L("数式プレビュー", "Formula Preview"), isPresented: $showFormulaError) {
            Button(L("OK", "OK"), role: .cancel) {}
        } message: {
            Text(formulaErrorMessage)
        }

        return v16.environment(\.locale, self.inf6UILocale)
    }

    func _openCircuitBoardPaper(rawID: String) {
        if rawID.hasPrefix("inf6-pipeline:") {
            let payload = String(rawID.dropFirst("inf6-pipeline:".count))
            let forceRerun = payload.contains("::force::")
            let cleanPayload = payload.replacingOccurrences(of: "::force::", with: "")
            let promptParts = cleanPayload.components(separatedBy: "::prompt::")
            let corePart = promptParts[0]
            let parts = corePart.split(separator: ":", maxSplits: 2)
            guard parts.count >= 3 else { return }
            let kind = String(parts[0])
            let sf = String(parts[1])
            let nid = String(parts[2])
            let kinds: Set<Inf6DocEntityKind> = switch kind {
            case "figures": [.figure, .table]
            case "equations": [.equation]
            default: [.figure, .table, .equation]
            }
            _pendingEntityPipelineRun = (sourceFamily: sf, nodeID: nid, kinds: kinds, forceRerun: forceRerun)
            return
        }
        if rawID.hasPrefix("inf6-explanation:") {
            Task { @MainActor in
                do {
                    let target = try _resolveOriginalExplanationTarget(rawID: rawID)
                    explanationOverlayTitle = target.titleJa
                    explanationOverlayRawID = rawID
                    _showLibrarySidebar = false
                    let loadedContent: _OriginalExplanationContent? = try? _loadOriginalExplanationContent(rawID: rawID)
                    if let content = loadedContent {
                        let hasPaperLabel = content.sections.contains { $0.paperLabel != nil && !($0.paperLabel?.isEmpty ?? true) }
                        let hasHeadingWithBracketP = content.sections.contains { $0.heading.hasPrefix("[P") }
                        let isLegacyFormat = !hasPaperLabel && hasHeadingWithBracketP
                        let frontierNeedsRegen = Inf6FrontierEngine.needsRegeneration(rawID: rawID)
                        let needsRegen = frontierNeedsRegen || isLegacyFormat
                        explanationOverlay = content
                        if needsRegen && openAIKeyIsSet() {
                            Task { @MainActor in
                                try? await _generateOriginalExplanationJSON(rawID: rawID)
                                Inf6FrontierEngine.clearRegenerationFlag(rawID: rawID)
                                if let updated = try? _loadOriginalExplanationContent(rawID: rawID) {
                                    explanationOverlay = updated
                                }
                            }
                        }
                    } else {
                        guard openAIKeyIsSet() else {
                            showImportError = true
                            importErrorMessage = L("概要解説を生成するにはOpenAI APIキーを設定してください。", "Please set an OpenAI API key to generate overviews.")
                            return
                        }
                        _pendingExplanationGeneration = (rawID: rawID, titleJa: target.titleJa)
                    }
                } catch {
                    showImportError = true
                    importErrorMessage = L("概要解説の生成に失敗しました: \(error.localizedDescription)", "Failed to generate overview: \(error.localizedDescription)")
                }
            }
            return
        }
        if rawID.hasPrefix("inf6-quiz:") {
            var quizRawID = _canonicalQuizRawID(rawID)
            var selectedPaperID: String? = nil
            if let paperRange = rawID.range(of: "::paper::") {
                selectedPaperID = String(rawID[paperRange.upperBound...])
                quizRawID = _canonicalQuizRawID(String(rawID[..<paperRange.lowerBound]))
            }

            let explanationRawID = _explanationRawID(forQuizRawID: quizRawID)
            let storageKey = selectedPaperID != nil ? "\(quizRawID)::paper::\(selectedPaperID!)" : quizRawID
            do {
                let result = try _loadQuizContent(rawID: storageKey)
                explanationOverlayTitle = result.title
                explanationOverlayRawID = storageKey
                explanationOverlay = result.content
                _showLibrarySidebar = false
            } catch let e as NSError where e.domain == "inf6.quiz" && e.code == 11 {
                Task { @MainActor in
                    do {
                        let target = try _resolveOriginalExplanationTarget(rawID: explanationRawID)
                        guard openAIKeyIsSet() else {
                            showImportError = true
                            importErrorMessage = L("演習を生成するにはOpenAI APIキーを設定してください。", "Please set an OpenAI API key to generate exercises.")
                            return
                        }
                        _pendingQuizGeneration = (rawID: storageKey, explanationRawID: explanationRawID, titleJa: target.titleJa, paperID: selectedPaperID)
                    } catch {
                        showImportError = true
                        importErrorMessage = L("演習の読み込みに失敗しました: \(error.localizedDescription)", "Failed to load exercises: \(error.localizedDescription)")
                    }
                }
            } catch {
                showImportError = true
                importErrorMessage = L("演習の読み込みに失敗しました: \(error.localizedDescription)", "Failed to load exercises: \(error.localizedDescription)")
            }
            return
        }
        guard let paper = Inf6CorePaperStore.shared.papers.first(where: { $0.id == rawID }) else { return }
        // 論文本文は、ツリーや演習と並べて読めるよう別ウィンドウで開く。
        // 同一ウィンドウ内へのインライン表示だと、元の一覧が隠れてしまう。
        if let url = paper.resolvedPDFURL, url.isFileURL {
            openPDFInNewWindow(url)
        } else if let url = paper.resolvedPDFURL {
            Task { @MainActor in
                do {
                    let data = try await Inf6PaperSaveShared.downloadValidatedPDFData(from: url)
                    let fileName = try Inf6PaperSaveShared.safeFileName(
                        title: paper.title, fallbackID: paper.id)
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent(fileName)
                    try data.write(to: tmp, options: .atomic)
                    openPDFInNewWindow(tmp)
                } catch {
                    showImportError = true
                    importErrorMessage = L(
                        "「\(paper.title)」のPDFを取得できませんでした。\n「PDFを取り込む」から手動で追加してください。",
                        "Could not fetch PDF for \"\(paper.title)\".\nPlease add it manually via \"Import PDF\".")
                }
            }
        } else {
            showImportError = true
            importErrorMessage = L(
                "「\(paper.title)」にはPDFのURLが設定されていません。\n「PDFを取り込む」から手動で追加してください。",
                "No PDF URL configured for \"\(paper.title)\".\nPlease add it manually via \"Import PDF\".")
        }
    }

    func _loadOriginalExplanationContent(rawID: String) throws -> _OriginalExplanationContent {
        guard let json = Inf6MetadataStore.get(domain: .generatedExplanations, key: rawID),
              let data = json.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentDict = payload["content"] as? [String: Any],
              let contentData = try? JSONSerialization.data(withJSONObject: contentDict) else {
            throw NSError(domain: "inf6.originalExplanation", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "概要解説データがありません。ツリーに戻って再度お試しください。"
            ])
        }
        var content = try JSONDecoder()
            .decode(_OriginalExplanationContent.self, from: contentData)
            .validated(requireCitationSection: false)
        let hasPaperLabel = content.sections.contains { $0.paperLabel != nil && !($0.paperLabel?.isEmpty ?? true) }
        if !hasPaperLabel {
            let bracketP = try? NSRegularExpression(pattern: #"^\[P\d+\]"#)
            var converted: [_OriginalExplanationContent.Section] = []
            for s in content.sections {
                let range = NSRange(s.heading.startIndex..., in: s.heading)
                if let m = bracketP?.firstMatch(in: s.heading, range: range) {
                    let label = String(s.heading[Range(m.range, in: s.heading)!])
                    converted.append(.init(heading: s.heading, body: s.body, kind: "paper_overview", paperLabel: label, paperID: s.paperID))
                } else {
                    converted.append(s)
                }
            }
            content = try _OriginalExplanationContent(sections: converted)
                .validated(requireCitationSection: false)
        }
        return content
    }

    func _loadNodeExplanationEntities(rawID: String) throws -> [Inf6DocEntity] {
        let content = try _loadOriginalExplanationContent(rawID: rawID)
        let target = try _resolveOriginalExplanationTarget(rawID: rawID)
        // Loading an existing artifact validates its stored structure, not the
        // stricter completeness target used when generating a replacement.
        try _validateNodeExplanationSections(content.sections, target: target, enforceCompleteness: false)
        let sections = content.sections.filter { $0.paperLabel == nil }
        return try sections.map { section in
            guard let rawEntityID = section.entityId, let entityID = UUID(uuidString: rawEntityID) else {
                throw NSError(domain: "inf6.originalExplanation", code: 20, userInfo: [
                    NSLocalizedDescriptionKey: "ノード解説アイテムIDが不正です: \(section.heading)"
                ])
            }
            let kind: Inf6DocEntityKind
            switch section.kind {
            case "formula": kind = .equation
            case "diagram": kind = .figure
            case "table": kind = .table
            default:
                throw NSError(domain: "inf6.originalExplanation", code: 21, userInfo: [
                    NSLocalizedDescriptionKey: "ノード解説に未対応の種類があります: \(section.kind)"
                ])
            }
            let detail = section.body
            return Inf6DocEntity(
                id: entityID,
                kind: kind,
                pageIndex: 0,
                title: section.heading,
                titleJapanese: section.heading,
                snippet: detail,
                snippetJapanese: detail,
                explanation: detail,
                explanationJapanese: detail,
                paperFormulaMathML: section.mathML,
                paperFormulaExpression: section.expression,
                nodeDiagramSteps: section.diagramSteps,
                nodeTableColumns: section.tableColumns,
                nodeTableRows: section.tableRows
            )
        }
    }

    private func _existingOriginalExplanationPDFURL(rawID: String) throws -> URL {
        let target = try _resolveOriginalExplanationTarget(rawID: rawID)
        let fileName = _originalExplanationFileName(target)
        if let reference = try Inf6PDFReferenceStore.first(fileName: fileName) {
            let refPath = reference.resolvedPath
            if FileManager.default.fileExists(atPath: refPath) {
                return URL(fileURLWithPath: refPath)
            }
        }

        let root = try Inf6LibraryView._sharedRootDir()
        let dir = root.appendingPathComponent("inf6_generated_explanations", isDirectory: true)
        let url = dir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "inf6.originalExplanation", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "概要解説PDFがありません: \(url.lastPathComponent)"
            ])
        }
        try Inf6PDFReferenceStore.put(url: url)
        return url
    }

    private struct _OriginalExplanationTarget {
        let rawID: String
        let sourceFamily: String
        let nodeID: String
        let domainTitle: String
        let titleJa: String
        let titleEn: String
        let summaryJa: String
        let summaryEn: String
        let childTitles: [String]
        let citedPapers: [_OriginalExplanationCitedPaper]
    }

    private struct _OriginalExplanationCitedPaper {
        let label: String
        let title: String
        let year: Int?
        let provider: String
        let sourceURL: String
        let abstract: String
    }

    struct _OriginalExplanationContent: Codable {
        struct Section: Codable {
            let heading: String
            let body: String
            let kind: String
            let paperLabel: String?
            let paperID: String?
            let pdfKey: String?
            let entityId: String?
            let topicKey: String?
            let expression: String?
            let mathML: String?
            let diagramSteps: [String]?
            let tableColumns: [String]?
            let tableRows: [[String]]?

            init(heading: String, body: String, kind: String, paperLabel: String? = nil, paperID: String? = nil, pdfKey: String? = nil, entityId: String? = nil, topicKey: String? = nil, expression: String? = nil, mathML: String? = nil, diagramSteps: [String]? = nil, tableColumns: [String]? = nil, tableRows: [[String]]? = nil) {
                self.heading = heading
                self.body = body
                self.kind = kind
                self.paperLabel = paperLabel
                self.paperID = paperID
                self.pdfKey = pdfKey
                self.entityId = entityId
                self.topicKey = topicKey
                self.expression = expression
                self.mathML = mathML
                self.diagramSteps = diagramSteps
                self.tableColumns = tableColumns
                self.tableRows = tableRows
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                heading = try c.decode(String.self, forKey: .heading)
                kind = try c.decode(String.self, forKey: .kind)
                paperLabel = try c.decodeIfPresent(String.self, forKey: .paperLabel)
                paperID = try c.decodeIfPresent(String.self, forKey: .paperID)
                pdfKey = try c.decodeIfPresent(String.self, forKey: .pdfKey)
                entityId = try c.decodeIfPresent(String.self, forKey: .entityId)
                topicKey = try c.decodeIfPresent(String.self, forKey: .topicKey)
                expression = try c.decodeIfPresent(String.self, forKey: .expression)
                mathML = try c.decodeIfPresent(String.self, forKey: .mathML)
                diagramSteps = try c.decodeIfPresent([String].self, forKey: .diagramSteps)
                tableColumns = try c.decodeIfPresent([String].self, forKey: .tableColumns)
                tableRows = try c.decodeIfPresent([[String]].self, forKey: .tableRows)
                if let s = try? c.decode(String.self, forKey: .body) {
                    body = s
                } else if let arr = try? c.decode([String].self, forKey: .body) {
                    body = arr.joined(separator: "\n")
                } else {
                    body = ""
                }
            }

            func validated() -> Section? {
                let cleanHeading = _inf6NaturalizedExplanationText(heading)
                    .replacingOccurrences(of: #"\n+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanBody = _inf6NaturalizedExplanationText(body)
                guard !cleanHeading.isEmpty, !cleanBody.isEmpty else { return nil }
                let cleanKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
                let allowedKinds: Set<String> = ["text", "formula", "diagram", "table", "bullets", "citation", "quiz", "abstract", "paper_overview", "paper_figures", "paper_equations"]
                return Section(
                    heading: cleanHeading,
                    body: cleanBody,
                    kind: allowedKinds.contains(cleanKind) ? cleanKind : "text",
                    paperLabel: paperLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                    paperID: paperID,
                    pdfKey: pdfKey,
                    entityId: entityId,
                    topicKey: topicKey?.trimmingCharacters(in: .whitespacesAndNewlines),
                    expression: expression?.trimmingCharacters(in: .whitespacesAndNewlines),
                    mathML: mathML,
                    diagramSteps: diagramSteps?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                    tableColumns: tableColumns?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                    tableRows: tableRows?.map { $0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
                )
            }
        }

        let sections: [Section]

        func validated(requireCitationSection: Bool) throws -> _OriginalExplanationContent {
            let cleanSections = sections.compactMap { $0.validated() }
            guard !cleanSections.isEmpty else {
                throw NSError(domain: "inf6.originalExplanation", code: 6, userInfo: [NSLocalizedDescriptionKey: "概要解説生成結果が不完全です。"])
            }
            let hasPaperSections = cleanSections.contains { $0.paperLabel != nil && !($0.paperLabel?.isEmpty ?? true) }
            if requireCitationSection, !hasPaperSections, !cleanSections.contains(where: { $0.kind == "citation" }) {
                throw NSError(domain: "inf6.originalExplanation", code: 9, userInfo: [NSLocalizedDescriptionKey: "概要解説生成結果に必須の関連論文セクションがありません。"])
            }
            return _OriginalExplanationContent(sections: Array(cleanSections.prefix(40)))
        }

        struct PaperCard: Identifiable {
            let id: String
            let label: String
            let title: String
            let sections: [Section]
            let paperID: String?

            var hasLocalPDF: Bool {
                guard let pid = paperID else { return false }
                guard let paper = Inf6MetadataStore.getCodable(Inf6CorePaper.self, domain: .papers, key: pid) else { return false }
                guard let localURL = paper._localPapersPDFPublic() else { return false }
                return FileManager.default.fileExists(atPath: localURL.path)
            }

            var hasEntities: Bool {
                guard let pid = paperID else { return false }
                guard let paper = Inf6MetadataStore.getCodable(Inf6CorePaper.self, domain: .papers, key: pid) else { return false }
                let pdfKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paper.titleEn ?? paper.title)
                return Inf6MetadataStore.get(domain: .docEntities, key: pdfKey) != nil
            }
        }

        static func _paperDisplayTitle(paperID: String?, fallback: String) -> String {
            guard let pid = paperID,
                  let paper = Inf6MetadataStore.getCodable(Inf6CorePaper.self, domain: .papers, key: pid) else {
                return fallback
            }
            let title = paper.titleEn ?? paper.title
            if let year = paper.year, year > 0 {
                return "\(year): \(title)"
            }
            return title
        }

        var conceptSections: [Section] {
            sections.filter { ($0.paperLabel ?? "").isEmpty && $0.kind != "abstract" }
        }

        var paperCards: [PaperCard] {
            var labelOrder: [String] = []
            var sectionsByLabel: [String: [Section]] = [:]
            for s in sections {
                guard let label = s.paperLabel, !label.isEmpty else { continue }
                if sectionsByLabel[label] == nil {
                    labelOrder.append(label)
                }
                sectionsByLabel[label, default: []].append(s)
            }
            var cards: [PaperCard] = []
            for label in labelOrder {
                let secs = sectionsByLabel[label] ?? []
                let pid = secs.first(where: { $0.paperID != nil })?.paperID
                let title = Self._paperDisplayTitle(paperID: pid, fallback: label)
                let cardID = pid ?? label
                cards.append(PaperCard(id: cardID, label: label, title: title, sections: secs, paperID: pid))
            }
            if cards.isEmpty {
                let legacyCitations = sections.filter { $0.kind == "citation" || $0.kind == "abstract" }
                for s in legacyCitations {
                    cards.append(PaperCard(id: s.heading, label: "", title: s.heading, sections: [s], paperID: s.paperID))
                }
            }
            return cards
        }
    }

    func _generateOriginalExplanationJSON(rawID: String) async throws {
        let target = try _resolveOriginalExplanationTarget(rawID: rawID)
        let content = try await _generateOriginalExplanationContent(target: target)
        try Task.checkCancellation()
        let payload: [String: Any] = [
            "id": rawID,
            "sourceFamily": target.sourceFamily,
            "nodeID": target.nodeID,
            "title": target.titleJa,
            "content": [
                "sections": content.sections.map { section -> [String: Any] in
                    var d: [String: Any] = [
                        "heading": section.heading,
                        "body": section.body,
                        "kind": section.kind
                    ]
                    if let pl = section.paperLabel, !pl.isEmpty {
                        d["paperLabel"] = pl
                    }
                    if let pid = section.paperID, !pid.isEmpty { d["paperID"] = pid }
                    if let entityID = section.entityId { d["entityId"] = entityID }
                    if let topicKey = section.topicKey { d["topicKey"] = topicKey }
                    if let expression = section.expression { d["expression"] = expression }
                    if let mathML = section.mathML { d["mathML"] = mathML }
                    if let steps = section.diagramSteps { d["diagramSteps"] = steps }
                    if let columns = section.tableColumns { d["tableColumns"] = columns }
                    if let rows = section.tableRows { d["tableRows"] = rows }
                    return d
                }
            ],
            "generatedAt": Date().timeIntervalSince1970
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "inf6.originalExplanation", code: 5, userInfo: [NSLocalizedDescriptionKey: "概要解説メタデータをJSON化できませんでした。"])
        }
        try Task.checkCancellation()
        guard Inf6MetadataStore.put(domain: .generatedExplanations, key: rawID, json: json) else {
            throw NSError(domain: "inf6.originalExplanation", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "ノード解説をUser Setting Rootへ保存できませんでした: \(rawID)"
            ])
        }
    }

    private func _loadQuizContent(rawID: String) throws -> (content: _OriginalExplanationContent, title: String) {
        let canonicalRawID = _canonicalQuizRawID(rawID)
        if let json = Inf6MetadataStore.get(domain: .generatedQuizzes, key: canonicalRawID) {
            return try _parseQuizPayload(json: json, key: canonicalRawID)
        }

        if let paperRange = rawID.range(of: "::paper::") {
            let baseRawID = String(rawID[..<paperRange.lowerBound])
            let paperID = String(rawID[paperRange.upperBound...])
            let baseKey = _canonicalQuizRawID(baseRawID)
            if let json = Inf6MetadataStore.get(domain: .generatedQuizzes, key: baseKey),
               let data = json.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let contentDict = payload["content"] as? [String: Any],
               let sectionsArr = contentDict["sections"] as? [[String: Any]] {
                guard let paper = Inf6MetadataStore.getCodable(Inf6CorePaper.self, domain: .papers, key: paperID) else {
                    throw NSError(domain: "inf6.quiz", code: 11, userInfo: [NSLocalizedDescriptionKey: "演習データがありません。"])
                }
                let pdfKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paper.titleEn ?? paper.title)
                let filtered = sectionsArr.filter { ($0["pdfKey"] as? String) == pdfKey }
                guard !filtered.isEmpty else {
                    throw NSError(domain: "inf6.quiz", code: 11, userInfo: [NSLocalizedDescriptionKey: "演習データがありません。"])
                }
                let filteredContent: [String: Any] = ["sections": filtered]
                let baseTitle = (payload["title"] as? String) ?? ""
                let title = "\(baseTitle.replacingOccurrences(of: " — 演習", with: "")) — \(paper.title) — 演習"
                let contentData = try JSONSerialization.data(withJSONObject: filteredContent)
                let content = try JSONDecoder().decode(_OriginalExplanationContent.self, from: contentData)
                return (content, title)
            }
        }

        throw NSError(domain: "inf6.quiz", code: 11, userInfo: [NSLocalizedDescriptionKey: "演習データがありません。"])
    }

    private func _canonicalQuizRawID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("inf6-quiz:") ? trimmed : "inf6-quiz:\(trimmed)"
    }

    private func _quizKeyWithoutPrefix(_ rawID: String) -> String {
        let canonical = _canonicalQuizRawID(rawID)
        return String(canonical.dropFirst("inf6-quiz:".count))
    }

    private func _explanationRawID(forQuizRawID rawID: String) -> String {
        let canonical = _canonicalQuizRawID(rawID)
        let base: String
        if let paperRange = canonical.range(of: "::paper::") {
            base = String(canonical[..<paperRange.lowerBound])
        } else {
            base = canonical
        }
        let bare = base.hasPrefix("inf6-quiz:") ? String(base.dropFirst("inf6-quiz:".count)) : base
        return "inf6-explanation:\(bare)"
    }

    private func _parseQuizPayload(json: String, key: String) throws -> (content: _OriginalExplanationContent, title: String) {
        guard let data = json.data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentDict = payload["content"] as? [String: Any] else {
            throw NSError(domain: "inf6.quiz", code: 12, userInfo: [NSLocalizedDescriptionKey: "演習データの形式が不正です: \(key)"])
        }

        let storedTitle = (payload["title"] as? String) ?? ""
        let contentData = try JSONSerialization.data(withJSONObject: contentDict)
        let content = try JSONDecoder().decode(_OriginalExplanationContent.self, from: contentData)
        return (content, storedTitle)
    }

    private func _generateQuizJSON(explanationRawID: String, quizRawID: String, additionalPrompt: String = "", filterPaperIDs: [String]? = nil) async throws {
        let dbKey = _canonicalQuizRawID(quizRawID)
        let target = try _resolveOriginalExplanationTarget(rawID: explanationRawID)
        let allPaperIDs = Inf6SyllabusPaperAutoSearch.linkedPaperIDs(sourceFamily: target.sourceFamily, syllabusNodeID: target.nodeID)
        let paperIDs = filterPaperIDs ?? allPaperIDs

        let imagesBase = Self._entityImagesBaseURL()
        var allEntities: [(entity: Inf6DocEntity, pdfKey: String, imageData: Data?)] = []

        for paperID in paperIDs {
            guard let paper = Inf6MetadataStore.getCodable(Inf6CorePaper.self, domain: .papers, key: paperID) else { continue }
            let title = paper.titleEn ?? paper.title
            let pdfKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: title)
            guard !pdfKey.isEmpty else { continue }
            if let index = Inf6MetadataStore.getCodable(Inf6DocEntityIndex.self, domain: .docEntities, key: pdfKey) {
                for entity in index.entities {
                    var imageData: Data?
                    if let imagePath = entity.imagePath {
                        let imageURL = imagesBase.appendingPathComponent(imagePath)
                        imageData = try? Data(contentsOf: imageURL)
                    }
                    allEntities.append((entity: entity, pdfKey: pdfKey, imageData: imageData))
                }
            }
        }

        if allEntities.isEmpty {
            var extraPaperIDs: [String] = []
            for item in Inf6MetadataStore.listByPrefix(domain: .syllabus, prefix: "structure:\(target.sourceFamily)#") {
                guard let data = item.json.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let nodes = root["nodes"] as? [[String: Any]] else { continue }
                for node in nodes where (node["kind"] as? String) == "paper" {
                    guard let parentID = node["parent_node_id"] as? String, parentID == target.nodeID else { continue }
                    if let pid = node["paper_id"] as? String, !paperIDs.contains(pid), !extraPaperIDs.contains(pid) { extraPaperIDs.append(pid) }
                    if let pid = node["node_id"] as? String, !paperIDs.contains(pid), !extraPaperIDs.contains(pid) { extraPaperIDs.append(pid) }
                }
            }
            for paperID in extraPaperIDs {
                guard let paper = Inf6MetadataStore.getCodable(Inf6CorePaper.self, domain: .papers, key: paperID) else { continue }
                let title = paper.titleEn ?? paper.title
                let pdfKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: title)
                guard !pdfKey.isEmpty else { continue }
                if let index = Inf6MetadataStore.getCodable(Inf6DocEntityIndex.self, domain: .docEntities, key: pdfKey) {
                    for entity in index.entities {
                        var imageData: Data?
                        if let imagePath = entity.imagePath {
                            let imageURL = imagesBase.appendingPathComponent(imagePath)
                            imageData = try? Data(contentsOf: imageURL)
                        }
                        allEntities.append((entity: entity, pdfKey: pdfKey, imageData: imageData))
                    }
                }
            }
        }

        guard !allEntities.isEmpty else {
            throw _QuizNeedsEntityPipelineError(sourceFamily: target.sourceFamily, nodeID: target.nodeID)
        }

        var sections: [[String: Any]] = []
        var questionIndex = 1

        for (entity, entityPdfKey, imageData) in allEntities {
            let kindLabel = entity.kind.labelJa
            let promptForKind: String
            switch entity.kind {
            case .figure:
                promptForKind = """
                この図について確認演習を生成してください。
                図のタイトル: \(entity.title)
                図の解説: \(entity.explanation ?? "なし")

                ■ 図に基づく演習のポイント
                - グラフの軸が何を表しているか
                - データの傾向・パターンの読み取り
                - 図から導かれる結論
                - 他の条件との比較
                """
            case .table:
                promptForKind = """
                この表について確認演習を生成してください。
                表のタイトル: \(entity.title)
                表の解説: \(entity.explanation ?? "なし")

                ■ 表に基づく演習のポイント
                - 各列・行の意味
                - 最良/最悪の値の特定
                - 手法間の比較・優劣
                - 数値から読み取れる結論
                """
            case .equation:
                promptForKind = """
                この数式について確認演習を生成してください。
                数式のタイトル: \(entity.title)
                数式の解説: \(entity.explanation ?? "なし")

                ■ 数式に基づく演習のポイント
                - 各変数・記号の意味
                - 数式の導出背景・動機
                - 特殊ケースでの振る舞い
                - 適用条件・制約
                """
            }

            let additionalInstruction = additionalPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\n■ 追加指示\n\(additionalPrompt)"

            let prompt = """
            \(promptForKind)

            ■ 出力形式
            JSON配列のみ。Markdown禁止。
            [{"heading": "Q. 問題文", "body": "A) ...\\nB) ...\\nC) ...\\nD) ...\\n\\n正解: X)\\n\\n解説: ...", "kind": "quiz"}]

            ■ ルール
            - 4択問題を1〜3問（この\(kindLabel)の特徴に基づいて必要な数だけ）
            - 暗記ではなく理解度を測る問題
            - 前置き不要。JSON配列のみ出力\(additionalInstruction)
            """

            let response: String
            if let imageData {
                response = try await Self.askOpenAIVision(
                    systemInstruction: "学術論文の\(kindLabel)に基づく確認演習生成の専門家。JSON配列で出力。",
                    userPrompt: prompt,
                    imageDataList: [(data: imageData, mimeType: "image/jpeg")]
                )
            } else {
                response = try await Inf6LibraryView.askOpenAIText(
                    systemInstruction: "学術論文の\(kindLabel)に基づく確認演習生成の専門家。JSON配列で出力。",
                    userPrompt: prompt,
                    lang: "ja"
                )
            }

            let cleaned = response
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let jsonData = cleaned.data(using: .utf8),
                  let quizArr = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else {
                continue
            }

            for var q in quizArr {
                let heading = q["heading"] as? String ?? "Q\(questionIndex)"
                q["heading"] = "Q\(questionIndex). [\(kindLabel): \(entity.title)] \(heading.replacingOccurrences(of: #"^Q\d+\.?\s*"#, with: "", options: .regularExpression))"
                q["kind"] = "quiz"
                q["pdfKey"] = entityPdfKey
                q["entityId"] = entity.id.uuidString
                sections.append(q)
                questionIndex += 1
            }

            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        guard !sections.isEmpty else {
            throw NSError(domain: "inf6.quiz", code: 4, userInfo: [NSLocalizedDescriptionKey: "演習の生成に失敗しました。"])
        }

        let content: [String: Any] = ["sections": sections]
        let quizTitle: String
        if let filterIDs = filterPaperIDs, filterIDs.count == 1,
           let paper = Inf6MetadataStore.getCodable(Inf6CorePaper.self, domain: .papers, key: filterIDs[0]) {
            quizTitle = "\(target.titleJa) — \(paper.title) — 演習"
        } else {
            quizTitle = "\(target.titleJa) — 演習"
        }
        let payload: [String: Any] = [
            "id": dbKey,
            "sourceFamily": target.sourceFamily,
            "nodeID": target.nodeID,
            "title": quizTitle,
            "content": content,
            "generatedAt": Date().timeIntervalSince1970
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "inf6.quiz", code: 2, userInfo: [NSLocalizedDescriptionKey: "演習メタデータをJSON化できませんでした。"])
        }
        Inf6MetadataStore.put(domain: .generatedQuizzes, key: dbKey, json: json)
    }

    private func _generateOriginalExplanationPDF(rawID: String) async throws -> URL {
        let target = try _resolveOriginalExplanationTarget(rawID: rawID)
        let content = try await _generateOriginalExplanationContent(target: target)
        let root = try Inf6LibraryView._sharedRootDir()
        let dir = root.appendingPathComponent("inf6_generated_explanations", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent(_originalExplanationFileName(target))
        try _renderOriginalExplanationPDF(target: target, content: content, to: fileURL)
        try Inf6PDFReferenceStore.put(url: fileURL)
        let payload: [String: Any] = [
            "id": rawID,
            "sourceFamily": target.sourceFamily,
            "nodeID": target.nodeID,
            "title": target.titleJa,
            "content": [
                "sections": content.sections.map { section -> [String: Any] in
                    var d: [String: Any] = [
                        "heading": section.heading,
                        "body": section.body,
                        "kind": section.kind
                    ]
                    if let pl = section.paperLabel, !pl.isEmpty { d["paperLabel"] = pl }
                    if let topicKey = section.topicKey { d["topicKey"] = topicKey }
                    if let entityID = section.entityId { d["entityId"] = entityID }
                    if let expression = section.expression { d["expression"] = expression }
                    if let mathML = section.mathML { d["mathML"] = mathML }
                    if let steps = section.diagramSteps { d["diagramSteps"] = steps }
                    if let columns = section.tableColumns { d["tableColumns"] = columns }
                    if let rows = section.tableRows { d["tableRows"] = rows }
                    return d
                }
            ],
            "fileName": fileURL.lastPathComponent,
            "absolutePath": fileURL.path,
            "generatedAt": Date().timeIntervalSince1970
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "inf6.originalExplanation", code: 5, userInfo: [NSLocalizedDescriptionKey: "概要解説メタデータをJSON化できませんでした。"])
        }
        Inf6MetadataStore.put(domain: .generatedExplanations, key: rawID, json: json)
        return fileURL
    }

    private func _validateNodeExplanationSections(
        _ sections: [_OriginalExplanationContent.Section],
        target: _OriginalExplanationTarget,
        requireMathML: Bool = true,
        enforceCompleteness: Bool = true
    ) throws {
        guard !sections.isEmpty else {
            throw NSError(domain: "inf6.originalExplanation", code: 31, userInfo: [NSLocalizedDescriptionKey: "保存済みノード解説に表示可能な項目がありません。"])
        }
        guard sections.allSatisfy({ $0.paperLabel == nil && ["formula", "diagram", "table"].contains($0.kind) }) else {
            throw NSError(domain: "inf6.originalExplanation", code: 13, userInfo: [NSLocalizedDescriptionKey: "ノード解説に論文項目または文章セクションが混在しています。"])
        }
        let formulas = sections.filter { $0.kind == "formula" }
        if enforceCompleteness, formulas.isEmpty {
            throw NSError(domain: "inf6.originalExplanation", code: 22, userInfo: [NSLocalizedDescriptionKey: "「\(target.titleJa)」のノード解説に数式項目がありません。"])
        }
        if enforceCompleteness,
           !(sections.contains(where: { $0.kind == "diagram" }) && sections.contains(where: { $0.kind == "table" })) {
            throw NSError(domain: "inf6.originalExplanation", code: 14, userInfo: [NSLocalizedDescriptionKey: "ノード解説には数式に加えて関係図と比較表が必要です。"])
        }
        let expressions = formulas.compactMap(\.expression)
            .map { $0.lowercased().filter { !$0.isWhitespace && $0 != "$" } }
        guard expressions.count == formulas.count,
              (!enforceCompleteness || Set(expressions).count == formulas.count) else {
            throw NSError(domain: "inf6.originalExplanation", code: 23, userInfo: [NSLocalizedDescriptionKey: "ノード解説にLaTeX式の欠落または重複があります。各項目を異なる式にしてください。"])
        }
        guard formulas.allSatisfy({ $0.body.count <= 500 && $0.body.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8 }) else {
            throw NSError(domain: "inf6.originalExplanation", code: 28, userInfo: [NSLocalizedDescriptionKey: "数式項目の解説が空、または500文字を超えています。式ごとに記号・shape・役割を簡潔に記述してください。"])
        }
        for formula in formulas {
            guard let expression = formula.expression, !expression.isEmpty else {
                throw NSError(domain: "inf6.originalExplanation", code: 29, userInfo: [NSLocalizedDescriptionKey: "数式項目にLaTeX expressionがありません: \(formula.heading)"])
            }
            if requireMathML {
                guard let mathML = formula.mathML else {
                    throw NSError(domain: "inf6.originalExplanation", code: 29, userInfo: [NSLocalizedDescriptionKey: "保存済み数式に検証済みMathMLがありません: \(formula.heading)"])
                }
                try MathMLValidator().validate(mathML)
            }
        }
        let topicKeys = formulas.map { $0.topicKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        let missingTopicHeadings = formulas.enumerated().compactMap { index, formula in
            topicKeys[index].isEmpty ? formula.heading : nil
        }
        let duplicateTopicKeys = Dictionary(grouping: topicKeys.filter { !$0.isEmpty }, by: { $0 })
            .filter { $0.value.count > 1 }
            .keys.sorted()
        guard !enforceCompleteness || (missingTopicHeadings.isEmpty && duplicateTopicKeys.isEmpty) else {
            var details: [String] = []
            if !missingTopicHeadings.isEmpty {
                details.append("topicKeyがない数式: \(missingTopicHeadings.joined(separator: "、"))")
            }
            if !duplicateTopicKeys.isEmpty {
                details.append("重複したtopicKey: \(duplicateTopicKeys.joined(separator: "、"))")
            }
            throw NSError(domain: "inf6.originalExplanation", code: 24, userInfo: [NSLocalizedDescriptionKey: "数式項目のtopicKeyが欠落または重複しています。\(details.joined(separator: "。"))"])
        }
        guard sections.filter({ $0.kind == "diagram" }).allSatisfy({ ($0.diagramSteps?.count ?? 0) >= 3 }),
              sections.filter({ $0.kind == "table" }).allSatisfy({ section in
                  guard let columns = section.tableColumns, columns.count >= 2,
                        let rows = section.tableRows, rows.count >= 2 else { return false }
                  return rows.allSatisfy { $0.count == columns.count }
              }) else {
            throw NSError(domain: "inf6.originalExplanation", code: 26, userInfo: [NSLocalizedDescriptionKey: "関係図または比較表の構造が不足しています。"])
        }
    }

    private func _generateOriginalExplanationContent(target: _OriginalExplanationTarget) async throws -> _OriginalExplanationContent {
        let outputLanguageInstruction = Inf6Lang.text("説明と見出しは日本語で作成してください。", "Write the explanations and headings in English.")
        let nodeScope = [target.titleJa, target.titleEn, target.summaryJa, target.summaryEn]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " / ")
        let systemInstruction = """
        選択されたシラバスノードのために、新しい学習アイテムを生成してください。
        論文PDFや既存の図表数式抽出データは入力されていません。論文アイテムを抽出・複製したり、実在の論文図表であるかのように記述してはいけません。
        ノード名・要約・子ノード・関連論文情報を踏まえ、数式を中心にノードの理解に必要なオリジナルアイテムを作成します。
        JSONオブジェクトだけを返し、Markdownや長い散文解説を返さないでください。

        数式項目数は固定件数や固定トピック一覧で決めず、このノードの要約と直接の子ノードに含まれる独立した数学的関係から決めます。各formulaはこのノード固有の異なる関係を一つ扱い、expressionにLaTeX、bodyに記号・shape・成立条件・計算上の役割を具体的かつ簡潔に記します。直接の子ノードがある場合はその範囲を確認し、別ノード用の定型項目を流用しません。同じ式の言い換えや、1つの式を水増し分割した項目は禁止です。
        diagramを最低1件、tableを最低1件作成します。diagramStepsは依存関係を表す3〜8個の短いラベル、tableは比較に必要な列と行を持たせます。論文中の図の番号や図の再現を主張せず、根拠のない数値・実験結果を作りません。
        数式や必要トピックを根拠を保って作れない場合は、内容を捏造せず生成を失敗させてください。空sectionsを成功形式として返してはいけません。
        \(outputLanguageInstruction) 各アイテムは短く具体的にし、長文の概念解説、要約、クイズ、引用論文カードを生成しないでください。
        各sectionはheading、kind、bodyを必須とし、formulaはexpressionを必須とします。topicKeyは出力しないでください。diagramはdiagramSteps、tableはtableColumns/tableRowsを必須とします。paperLabelは出力しません。
        """
        let citedPapersText = target.citedPapers.isEmpty ? "none" : target.citedPapers.map { paper in
            [
                "[\(paper.label)] \(paper.year.map { "\($0) " } ?? "")\(paper.title)",
                paper.abstract.isEmpty ? "" : "Abstract: \(String(paper.abstract.prefix(900)))"
            ].filter { !$0.isEmpty }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        let userPrompt = """
        source_family: \(target.sourceFamily)
        node_id: \(target.nodeID)
        node_scope: \(nodeScope)
        direct_children: \(target.childTitles.joined(separator: " / "))
        formula_count_rule: 固定件数を使わず、このノードに含まれる独立した数学的関係の数に応じて決める。
        formula_topic_key_rule: topicKeyは出力しない。アプリがexpressionから決定的なキーを割り当てる。
        cited_papers:
        \(citedPapersText)

        JSON schema:
        {
          "sections": [
            {
              "heading": "短い項目名",
              "kind": "formula|diagram|table",
              "body": "短い解説",
              "expression": "formulaのみ: LaTeX",
              "diagramSteps": ["diagramのみ: 要素1", "要素2"],
              "tableColumns": ["tableのみ: 列名"],
              "tableRows": [["tableのみ: 値"]]
            }
          ]
        }
        """
        let raw = try await Self.askOpenAIOriginalExplanation(systemInstruction: systemInstruction, userPrompt: userPrompt)
        let jsonText = try _extractJSONObjectText(raw)
        guard let data = jsonText.data(using: .utf8) else {
            throw NSError(domain: "inf6.originalExplanation", code: 7, userInfo: [NSLocalizedDescriptionKey: "概要解説生成JSONをUTF-8化できませんでした。"])
        }
        let decodedContent: _OriginalExplanationContent
        do {
            decodedContent = try JSONDecoder().decode(_OriginalExplanationContent.self, from: data)
        } catch let decodingError as DecodingError {
            let detail: String
            switch decodingError {
            case .typeMismatch(let type, let context):
                detail = "型が一致しません（期待値: \(String(reflecting: type))、項目: \(context.codingPath.map(\.stringValue).joined(separator: "."))）。"
            case .valueNotFound(let type, let context):
                detail = "必須値がありません（期待値: \(String(reflecting: type))、項目: \(context.codingPath.map(\.stringValue).joined(separator: "."))）。"
            case .keyNotFound(let key, let context):
                let path = (context.codingPath + [key]).map(\.stringValue).joined(separator: ".")
                detail = "必須項目がありません（項目: \(path)）。"
            case .dataCorrupted(let context):
                detail = "JSON値が不正です（項目: \(context.codingPath.map(\.stringValue).joined(separator: "."))、\(context.debugDescription)）。"
            @unknown default:
                detail = decodingError.localizedDescription
            }
            throw NSError(
                domain: "inf6.originalExplanation",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "概要解説JSONを読み取れませんでした。\(detail)"]
            )
        }
        let decoded = try decodedContent.validated(requireCitationSection: false)
        let generated = try _assignGeneratedTopicKeys(decoded)
        try _validateNodeExplanationSections(generated.sections, target: target, requireMathML: false)
        let converter = LaTeXMathMLConverter()
        let sections = try generated.sections.map { section -> _OriginalExplanationContent.Section in
            let stableID = UUID().uuidString
            switch section.kind {
            case "formula":
                guard let expression = section.expression, !expression.isEmpty else {
                    throw NSError(domain: "inf6.originalExplanation", code: 15, userInfo: [NSLocalizedDescriptionKey: "数式項目にLaTeX expressionがありません: \(section.heading)"])
                }
                let mathML = try converter.convert(expression)
                return .init(heading: section.heading, body: section.body, kind: section.kind, entityId: stableID, topicKey: section.topicKey, expression: expression, mathML: mathML)
            case "diagram":
                guard let steps = section.diagramSteps, steps.count >= 2, steps.allSatisfy({ !$0.isEmpty }) else {
                    throw NSError(domain: "inf6.originalExplanation", code: 16, userInfo: [NSLocalizedDescriptionKey: "関係図に2個以上の要素がありません: \(section.heading)"])
                }
                return .init(heading: section.heading, body: section.body, kind: section.kind, entityId: stableID, diagramSteps: steps)
            case "table":
                guard let columns = section.tableColumns, columns.count >= 2,
                      let rows = section.tableRows, !rows.isEmpty,
                      rows.allSatisfy({ $0.count == columns.count }) else {
                    throw NSError(domain: "inf6.originalExplanation", code: 17, userInfo: [NSLocalizedDescriptionKey: "表の列と行の構造が一致しません: \(section.heading)"])
                }
                return .init(heading: section.heading, body: section.body, kind: section.kind, entityId: stableID, tableColumns: columns, tableRows: rows)
            default:
                throw NSError(domain: "inf6.originalExplanation", code: 18, userInfo: [NSLocalizedDescriptionKey: "未対応のノード解説アイテムです: \(section.kind)"])
            }
        }
        let content = try _OriginalExplanationContent(sections: sections).validated(requireCitationSection: false)
        try _validateNodeExplanationSections(content.sections, target: target)
        return content
    }

    private func _assignGeneratedTopicKeys(
        _ content: _OriginalExplanationContent
    ) throws -> _OriginalExplanationContent {
        let sections = content.sections.map { section -> _OriginalExplanationContent.Section in
            guard section.kind == "formula", let expression = section.expression else {
                return section
            }
            let normalizedExpression = expression.lowercased()
                .filter { !$0.isWhitespace && $0 != "$" }
            let digest = SHA256.hash(data: Data(normalizedExpression.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            return .init(
                heading: section.heading,
                body: section.body,
                kind: section.kind,
                paperLabel: section.paperLabel,
                paperID: section.paperID,
                pdfKey: section.pdfKey,
                entityId: section.entityId,
                topicKey: "formula_\(digest)",
                expression: section.expression,
                mathML: section.mathML,
                diagramSteps: section.diagramSteps,
                tableColumns: section.tableColumns,
                tableRows: section.tableRows
            )
        }
        return try _OriginalExplanationContent(sections: sections)
            .validated(requireCitationSection: false)
    }

    private func _extractJSONObjectText(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if let range = trimmed.range(of: #"```(?:json)?\s*([\s\S]*?)```"#, options: .regularExpression) {
            candidate = String(trimmed[range])
                .replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"```$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            candidate = trimmed
        }
        guard let start = candidate.firstIndex(of: "{"),
              let end = candidate.lastIndex(of: "}"),
              start < end else {
            throw NSError(domain: "inf6.originalExplanation", code: 8, userInfo: [NSLocalizedDescriptionKey: "概要解説生成結果にJSONオブジェクトがありません。"])
        }
        return String(candidate[start...end])
    }

    private func _resolveOriginalExplanationTarget(rawID: String) throws -> _OriginalExplanationTarget {
        let prefix = "inf6-explanation:"
        guard rawID.hasPrefix(prefix) else {
            throw NSError(domain: "inf6.originalExplanation", code: 1, userInfo: [NSLocalizedDescriptionKey: "概要解説 IDが不正です: \(rawID)"])
        }
        let payload = String(rawID.dropFirst(prefix.count))
        guard let separator = payload.firstIndex(of: ":") else {
            throw NSError(domain: "inf6.originalExplanation", code: 2, userInfo: [NSLocalizedDescriptionKey: "概要解説 IDが不正です: \(rawID)"])
        }
        let sourceFamily = String(payload[..<separator])
        let nodeID = String(payload[payload.index(after: separator)...])
        for item in Inf6MetadataStore.listByPrefix(domain: .syllabus, prefix: "structure:\(sourceFamily)#") {
            guard let data = item.json.data(using: .utf8),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let nodes = root["nodes"] as? [[String: Any]] else { continue }
            guard let node = nodes.first(where: { ($0["node_id"] as? String) == nodeID }) else { continue }
            let children = nodes
                .filter { ($0["parent_node_id"] as? String) == nodeID && ($0["kind"] as? String) != "paper" }
                .compactMap { (($0["title_ja"] as? String) ?? ($0["title_en"] as? String))?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let citedPapers = _originalExplanationCitedPapers(sourceFamily: sourceFamily, nodeID: nodeID, structureNodes: nodes)
            return _OriginalExplanationTarget(
                rawID: rawID,
                sourceFamily: sourceFamily,
                nodeID: nodeID,
                domainTitle: (root["syllabus_version_id"] as? String) ?? (root["domain_id"] as? String) ?? sourceFamily,
                titleJa: (node["title_ja"] as? String) ?? nodeID,
                titleEn: (node["title_en"] as? String) ?? "",
                summaryJa: (node["summary_ja"] as? String) ?? "",
                summaryEn: (node["summary_en"] as? String) ?? "",
                childTitles: children,
                citedPapers: citedPapers
            )
        }
        throw NSError(domain: "inf6.originalExplanation", code: 3, userInfo: [NSLocalizedDescriptionKey: "概要解説対象ノードが見つかりません: \(sourceFamily)/\(nodeID)"])
    }

    private func _originalExplanationCitedPapers(sourceFamily: String, nodeID: String, structureNodes: [[String: Any]]) -> [_OriginalExplanationCitedPaper] {
        var ids: [String] = []
        for paperID in Inf6SyllabusPaperAutoSearch.linkedPaperIDs(sourceFamily: sourceFamily, syllabusNodeID: nodeID) {
            if !ids.contains(paperID) { ids.append(paperID) }
        }
        for node in structureNodes where (node["kind"] as? String) == "paper" {
            guard let parentID = node["parent_node_id"] as? String, parentID == nodeID else { continue }
            if let paperID = node["paper_id"] as? String, !ids.contains(paperID) { ids.append(paperID) }
            if let paperID = node["node_id"] as? String, !ids.contains(paperID) { ids.append(paperID) }
        }
        var out: [_OriginalExplanationCitedPaper] = []
        for paperID in ids {
            let paper = Inf6MetadataStore.getCodable(Inf6CorePaper.self, domain: .papers, key: paperID)
            let abstract = Inf6CorePaperAbstractStore.shared.abstract(for: paperID) ?? ""
            out.append(_OriginalExplanationCitedPaper(
                label: "P\(out.count + 1)",
                title: paper?.titleEn ?? paper?.title ?? paperID,
                year: paper?.year,
                provider: paper?.provider ?? "",
                sourceURL: paper?.resolvedPDFURL?.absoluteString ?? "",
                abstract: abstract
            ))
        }
        return out
    }

    private func _loadPaperEntities(paperID: String, title: String) -> [Inf6DocEntity] {
        let pdfKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: title)
        if !pdfKey.isEmpty,
           let index = Inf6MetadataStore.getCodable(Inf6DocEntityIndex.self, domain: .docEntities, key: pdfKey) {
            return index.entities
        }
        guard let root = try? Inf6LibraryView._sharedRootDir() else { return [] }
        let cardsDir = (Inf6KnowledgeCardsPaths.rootDirectoryURL() ?? root.appendingPathComponent(Inf6KnowledgeCardsPaths.rootFolderName, isDirectory: true))
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(atPath: cardsDir.path) else { return [] }
        let titleSlug = title.prefix(40).lowercased()
        for folder in folders {
            let folderLower = folder.lowercased()
            guard folderLower.contains(titleSlug.prefix(20)) || folderLower.contains(paperID.replacingOccurrences(of: ":", with: "_").lowercased().prefix(30)) else { continue }
            let folderURL = cardsDir.appendingPathComponent(folder, isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(atPath: folderURL.path) else { continue }
            for file in files where file.hasSuffix(".entities.json") {
                let fileURL = folderURL.appendingPathComponent(file)
                guard let data = try? Data(contentsOf: fileURL),
                      let index = try? JSONDecoder().decode(Inf6DocEntityIndex.self, from: data) else { continue }
                return index.entities
            }
        }
        return []
    }


    // MARK: - 新パイプライン（画像切り出し＋OpenAI解説生成）

    /// 表示と保存に使うローカルの置き場。iCloud は配布元として別に扱う。
    static func _entityImagesBaseURL() -> URL {
        Inf6EntityImageStore.localBaseURL()
    }

    private func _clearExistingEntities(sourceFamily: String, nodeID: String, kinds: Set<Inf6DocEntityKind>) {
        let paperIDs = Inf6SyllabusPaperAutoSearch.linkedPaperIDs(sourceFamily: sourceFamily, syllabusNodeID: nodeID)
        let fm = FileManager.default
        let imagesBase = Self._entityImagesBaseURL()

        for paperID in paperIDs {
            guard let paper = Inf6MetadataStore.getCodable(Inf6CorePaper.self, domain: .papers, key: paperID) else { continue }
            let pdfKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paper.titleEn ?? paper.title)
            guard !pdfKey.isEmpty,
                  var index = Inf6MetadataStore.getCodable(Inf6DocEntityIndex.self, domain: .docEntities, key: pdfKey) else { continue }

            let kindsToRemove = kinds
            let toRemove = index.entities.filter { kindsToRemove.contains($0.kind) }
            for entity in toRemove {
                if let path = entity.imagePath {
                    let url = imagesBase.appendingPathComponent(path)
                    try? fm.removeItem(at: url)
                }
            }
            index.entities.removeAll { kindsToRemove.contains($0.kind) }
            Inf6MetadataStore.putCodable(index, domain: .docEntities, key: pdfKey)
            NSLog("[inf6] clearEntities: removed %d entities of kinds %@ from %@", toRemove.count, kinds.map { "\($0)" }.joined(separator: ","), pdfKey)
        }
    }

    private func _runNewEntityPipeline(sourceFamily: String, nodeID: String, kinds: Set<Inf6DocEntityKind>) async throws {
        defer {
            NotificationCenter.default.post(name: .inf6PipelineDidFinish, object: "\(sourceFamily):\(nodeID)")
        }

        let linkedPaperIDs = Inf6SyllabusPaperAutoSearch.linkedPaperIDs(sourceFamily: sourceFamily, syllabusNodeID: nodeID)
        var seenPaperIDs = Set<String>()
        let paperIDs = linkedPaperIDs.filter { seenPaperIDs.insert($0).inserted }
        guard !paperIDs.isEmpty else {
            throw NSError(domain: "inf6.entityPipeline", code: 1, userInfo: [
                NSLocalizedDescriptionKey: L("このノードに論文が関連付けられていません。先に論文を関連付けてください。", "No paper is linked to this node. Link a paper first.")
            ])
        }
        let fm = FileManager.default
        let imagesBase = Self._entityImagesBaseURL()
        try fm.createDirectory(at: imagesBase, withIntermediateDirectories: true)

        var totalPages = 0

        for paperID in paperIDs {
            guard let paper = Inf6CorePaperStore.shared.papers.first(where: { $0.id == paperID })
                    ?? Inf6MetadataStore.getCodable(Inf6CorePaper.self, domain: .papers, key: paperID)
                    ?? Inf6MetadataStore.listAllCodable(Inf6CorePaper.self, domain: .papers)
                        .first(where: { $0.value.id == paperID })?.value else {
                throw NSError(domain: "inf6.entityPipeline", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: L("関連付けられた論文データを読み込めません: \(paperID)", "Could not load linked paper data: \(paperID)")
                ])
            }
            let pdfKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paper.titleEn ?? paper.title)
            guard !pdfKey.isEmpty else {
                throw NSError(domain: "inf6.entityPipeline", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: L("論文名からPDF保存キーを作成できません: \(paper.title)", "Could not create a PDF storage key from the paper title: \(paper.title)")
                ])
            }
            var pdfURL: URL?
            if let localURL = paper._localPapersPDFPublic(), fm.fileExists(atPath: localURL.path) {
                pdfURL = localURL
            } else if let remoteURL = paper.resolvedPDFURL {
                NSLog("[inf6] pipeline: downloading PDF for %@", paperID)
                do {
                    let data = try await Inf6PaperSaveShared.downloadValidatedPDFData(from: remoteURL)
                    let tmpURL = fm.temporaryDirectory.appendingPathComponent("\(pdfKey).pdf")
                    try data.write(to: tmpURL, options: .atomic)
                    pdfURL = tmpURL
                } catch {
                    NSLog("[inf6] pipeline: PDF download failed for %@: %@", paperID, error.localizedDescription)
                    throw NSError(domain: "inf6.entityPipeline", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: L("論文PDFを取得できません: \(paper.titleEn ?? paper.title) — \(error.localizedDescription)", "Could not retrieve the paper PDF: \(paper.titleEn ?? paper.title) — \(error.localizedDescription)")
                    ])
                }
            }
            guard let resolvedPDF = pdfURL else {
                throw NSError(domain: "inf6.entityPipeline", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: L("論文PDFがUser Setting Rootに見つからず、取得先URLもありません: \(paper.titleEn ?? paper.title)", "The paper PDF is missing from the User Setting Root and has no download URL: \(paper.titleEn ?? paper.title)")
                ])
            }

            #if canImport(PDFKit)
            guard let doc = PDFDocument(url: resolvedPDF) else {
                throw NSError(domain: "inf6.entityPipeline", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: L("論文PDFを開けません。破損または読み取り権限を確認してください: \(resolvedPDF.lastPathComponent)", "Could not open the paper PDF. Check that it is valid and readable: \(resolvedPDF.lastPathComponent)")
                ])
            }
            guard doc.pageCount > 0 else {
                throw NSError(domain: "inf6.entityPipeline", code: 7, userInfo: [
                    NSLocalizedDescriptionKey: L("論文PDFに読み取れるページがありません: \(resolvedPDF.lastPathComponent)", "The paper PDF has no readable pages: \(resolvedPDF.lastPathComponent)")
                ])
            }

            let entityDir = imagesBase.appendingPathComponent(String(pdfKey.prefix(80)))
            try fm.createDirectory(at: entityDir, withIntermediateDirectories: true)

            let existingIndex = Inf6DocEntityIndex.load(for: paper)
            let existingEntities = existingIndex?.entities ?? []

            let wantFigures = kinds.contains(.figure) || kinds.contains(.table)
            let wantEquations = kinds.contains(.equation)
            let imageFileExists: (String?) -> Bool = { path in
                guard let path else { return false }
                let url = imagesBase.appendingPathComponent(path)
                return fm.fileExists(atPath: url.path)
            }
            let pageCount = doc.pageCount
            let scannedEntities = Inf6DocEntityScanner.scan(doc: doc).filter { kinds.contains($0.kind) }
            guard !scannedEntities.isEmpty else {
                throw NSError(domain: "inf6.entityPipeline", code: 8, userInfo: [
                    NSLocalizedDescriptionKey: L("PDFから図・表・数式を検出できませんでした: \(paper.titleEn ?? paper.title)", "No figures, tables, or equations were detected in the PDF: \(paper.titleEn ?? paper.title)")
                ])
            }
            let scannedFigures = scannedEntities.filter { $0.kind == .figure || $0.kind == .table }
            let scannedEquations = scannedEntities.filter { $0.kind == .equation }
            let existingFigures = existingEntities.filter { $0.kind == .figure || $0.kind == .table }
            let existingEquations = existingEntities.filter { $0.kind == .equation }
            let matchesExisting: (Inf6DocEntity) -> Inf6DocEntity? = { scanned in
                existingEntities.first {
                    $0.kind == scanned.kind && $0.pageIndex == scanned.pageIndex &&
                    $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        == scanned.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }
            }
            let hasFigures = scannedFigures.count == existingFigures.count && scannedFigures
                .allSatisfy { scanned in
                    guard let existing = matchesExisting(scanned) else { return false }
                    return imageFileExists(existing.imagePath)
                        && !((existing.explanation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)).isEmpty
                }
            let hasEquations = scannedEquations.count == existingEquations.count && scannedEquations
                .allSatisfy { scanned in
                    guard let existing = matchesExisting(scanned) else { return false }
                    return imageFileExists(existing.imagePath)
                        && !((existing.explanation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)).isEmpty
                }
            if (wantFigures == hasFigures || !wantFigures) && (wantEquations == hasEquations || !wantEquations) {
                NSLog("[inf6] pipeline: skipping %@ (already complete)", pdfKey)
                continue
            }

            var entities = scannedEntities
                .map { scanned -> Inf6DocEntity in
                    guard let old = matchesExisting(scanned) else { return scanned }
                    var merged = scanned
                    merged.id = old.id
                    merged.titleJapanese = old.titleJapanese
                    merged.snippetJapanese = old.snippetJapanese
                    merged.explanation = old.explanation
                    merged.explanationJapanese = old.explanationJapanese
                    merged.miniPDFFileName = old.miniPDFFileName
                    merged.imagePath = old.imagePath
                    merged.references = old.references
                    merged.isCore = old.isCore
                    merged.coreImportanceScore = old.coreImportanceScore
                    merged.parts = old.parts
                    merged.paperFormulaMathML = old.paperFormulaMathML
                    merged.paperFormulaExpression = old.paperFormulaExpression
                    merged.llmPyTorchCode = old.llmPyTorchCode
                    merged.llmTensorFlowCode = old.llmTensorFlowCode
                    merged.llmCodeVerification = old.llmCodeVerification
                    return merged
                }
            entities.append(contentsOf: existingEntities.filter { !kinds.contains($0.kind) })
            NSLog("[inf6] pipeline: processing %d pages for %@ with unified entity crop", pageCount, pdfKey)

            do {
                try Inf6EshikakuDrillPipeline.cropEntitiesFromPDF(
                    pdfURL: resolvedPDF,
                    doc: doc,
                    paperKey: pdfKey,
                    entities: &entities,
                    expansion: .standard,
                    reuseExistingImages: true,
                    forceRecut: false
                )
            } catch {
                NSLog("[inf6] pipeline: unified entity crop failed for %@: %@", pdfKey, error.localizedDescription)
                throw NSError(domain: "inf6.entityPipeline", code: 9, userInfo: [
                    NSLocalizedDescriptionKey: L("論文アイテム画像の切り出しに失敗しました: \(paper.titleEn ?? paper.title) — \(error.localizedDescription)", "Failed to crop paper item images: \(paper.titleEn ?? paper.title) — \(error.localizedDescription)")
                ])
            }

            for index in entities.indices where (entities[index].explanation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard kinds.contains(entities[index].kind) else { continue }
                guard let imagePath = entities[index].imagePath else {
                    throw NSError(domain: "inf6.entityPipeline", code: 10, userInfo: [
                        NSLocalizedDescriptionKey: L("論文アイテム画像が作成されていません: \(entities[index].title)", "The source image was not created for paper item: \(entities[index].title)")
                    ])
                }
                let imageURL = imagesBase.appendingPathComponent(imagePath)
                guard let imageData = try? Data(contentsOf: imageURL) else {
                    throw NSError(domain: "inf6.entityPipeline", code: 11, userInfo: [
                        NSLocalizedDescriptionKey: L("論文アイテム画像を読み込めません: \(imageURL.lastPathComponent)", "Could not read the paper item image: \(imageURL.lastPathComponent)")
                    ])
                }
                let pageText = doc.page(at: entities[index].pageIndex)?.string ?? ""
                let prompt: String
                switch entities[index].kind {
                case .figure:
                    prompt = "この図を詳細に解説してください。軸・凡例・傾向・結論を具体的に説明し、本文だけを返してください。\n\nページ本文:\n\(pageText)"
                case .table:
                    prompt = "この表を詳細に解説してください。列の意味・注目すべき数値・比較結果を説明し、本文だけを返してください。\n\nページ本文:\n\(pageText)"
                case .equation:
                    prompt = "この数式を詳細に解説してください。各変数・記号の意味、導出の背景、適用条件を説明し、本文だけを返してください。\n\nページ本文:\n\(pageText)"
                }
                guard openAIKeyIsSet() else {
                    throw NSError(domain: "inf6.entityPipeline", code: 12, userInfo: [
                        NSLocalizedDescriptionKey: L("論文アイテムの解説生成にはOpenAI APIキーが必要です。", "An OpenAI API key is required to generate paper item explanations.")
                    ])
                }
                let generatedExplanation = try await Self.askOpenAIVision(
                    systemInstruction: L("学術論文の図表数式解説の専門家。日本語で回答。", "Explain academic paper figures, tables, and equations accurately in English."),
                    userPrompt: prompt,
                    imageDataList: [(data: imageData, mimeType: "image/jpeg")]
                )
                let explanation = generatedExplanation.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !explanation.isEmpty else {
                    throw NSError(domain: "inf6.entityPipeline", code: 13, userInfo: [
                        NSLocalizedDescriptionKey: L("論文アイテムの解説生成結果が空です: \(entities[index].title)", "The generated explanation is empty for paper item: \(entities[index].title)")
                    ])
                }
                entities[index].explanation = explanation
                totalPages += 1
            }

            let orderedEntities = entities.enumerated().sorted {
                if $0.element.pageIndex != $1.element.pageIndex {
                    return $0.element.pageIndex < $1.element.pageIndex
                }
                return $0.offset < $1.offset
            }.map(\.element)
            let index = Inf6DocEntityIndex(pdfKey: pdfKey, entities: orderedEntities)
            guard Inf6MetadataStore.putCodable(index, domain: .docEntities, key: pdfKey) else {
                throw NSError(domain: "inf6.entityPipeline", code: 14, userInfo: [
                    NSLocalizedDescriptionKey: L("生成した論文項目をUser Setting Rootへ保存できません: \(paper.titleEn ?? paper.title)", "Could not save generated paper items to the User Setting Root: \(paper.titleEn ?? paper.title)")
                ])
            }
            #endif
            #if !canImport(PDFKit)
            throw NSError(domain: "inf6.entityPipeline", code: 15, userInfo: [
                NSLocalizedDescriptionKey: L("この実行環境ではPDF項目抽出に必要なPDFKitを利用できません。", "PDFKit required for PDF item extraction is unavailable in this environment.")
            ])
            #endif
        }

        NSLog("[inf6] pipeline: processed %d pages for %@:%@", totalPages, sourceFamily, nodeID)

    }

    private func _generateEntityExplanations(_ targets: [(pdfKey: String, entityIndex: Int)]) async {
        var byPdfKey: [String: [Int]] = [:]
        for t in targets {
            byPdfKey[t.pdfKey, default: []].append(t.entityIndex)
        }

        for (pdfKey, indices) in byPdfKey {
            guard var index = Inf6MetadataStore.getCodable(Inf6DocEntityIndex.self, domain: .docEntities, key: pdfKey) else { continue }

            let needsExplanation = indices.filter { i in
                i < index.entities.count && (index.entities[i].explanation ?? "").isEmpty
            }
            guard !needsExplanation.isEmpty else { continue }

            let batch = needsExplanation.prefix(8)
            var prompt = "以下の論文中の図表・数式について、それぞれ日本語で簡潔に解説してください（各2〜3文）。\n\n"
            for (n, idx) in batch.enumerated() {
                let e = index.entities[idx]
                prompt += "[\(n+1)] \(e.kind.labelJa): \(e.title)\n文脈: \(e.snippet.prefix(400))\n\n"
            }

            do {
                let response = try await Self.askOpenAIText(prompt, lang: "ja")
                let parts = response.components(separatedBy: "\n").reduce(into: [(Int, String)]()) { result, line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if let match = trimmed.range(of: #"^\[(\d+)\]\s*"#, options: .regularExpression) {
                        let numStr = trimmed[match].filter(\.isNumber)
                        if let num = Int(numStr) {
                            let text = String(trimmed[match.upperBound...])
                            result.append((num, text))
                        }
                    } else if !result.isEmpty {
                        let last = result.count - 1
                        result[last].1 += " " + trimmed
                    }
                }

                for (num, text) in parts {
                    let batchIdx = num - 1
                    guard batchIdx >= 0, batchIdx < batch.count else { continue }
                    let entityIdx = batch[batch.index(batch.startIndex, offsetBy: batchIdx)]
                    if entityIdx < index.entities.count {
                        index.entities[entityIdx].explanation = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }

                Inf6MetadataStore.putCodable(index, domain: .docEntities, key: pdfKey)
                NSLog("[inf6] pipeline: generated %d explanations for %@", parts.count, pdfKey)
            } catch {
                NSLog("[inf6] pipeline: explanation generation failed for %@: %@", pdfKey, error.localizedDescription)
            }
        }
    }

    #if canImport(PDFKit)
    private func _findEntityClip(page: PDFPage, title: String, kind: Inf6DocEntityKind) -> CGRect? {
        let selections = page.selection(for: NSRange(location: 0, length: (page.string ?? "").count))?.selectionsByLine() ?? []
        for sel in selections {
            let text = sel.string ?? ""
            if text.localizedCaseInsensitiveContains(String(title.prefix(20))) {
                return sel.bounds(for: page)
            }
        }
        return nil
    }
    #endif

    private func _originalExplanationFileName(_ target: _OriginalExplanationTarget) -> String {
        let raw = "\(target.sourceFamily)_\(target.nodeID)_\(target.titleJa)_overview"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let base = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return (base.isEmpty ? "inf6_overview" : base) + ".pdf"
    }

    private func _renderOriginalExplanationPDF(target: _OriginalExplanationTarget, content: _OriginalExplanationContent, to url: URL) throws {
        #if canImport(UIKit)
        let page = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        try renderer.writePDF(to: url) { context in
            func beginPage(showTitle: Bool) -> CGFloat {
                context.beginPage()
                let cg = context.cgContext
                UIColor(red: 0.94, green: 0.99, blue: 0.97, alpha: 1).setFill()
                cg.fill(page)
                guard showTitle else { return 58 }
                UIColor(red: 0.00, green: 0.58, blue: 0.45, alpha: 1).setFill()
                cg.fillEllipse(in: CGRect(x: 48, y: 54, width: 18, height: 18))
                _drawPDFText(target.titleJa, rect: CGRect(x: 48, y: 58, width: 500, height: 62), size: 29, weight: .heavy, color: .black)
                _drawPDFText(target.titleEn.isEmpty ? target.domainTitle : target.titleEn, rect: CGRect(x: 50, y: 116, width: 500, height: 28), size: 13, weight: .bold, color: UIColor(red: 0.20, green: 0.43, blue: 0.39, alpha: 1))
                return 160
            }

            var y = beginPage(showTitle: true)
            let cardWidth: CGFloat = 510
            let bottomMargin: CGFloat = 52
            for section in content.sections {
                let monospace = section.kind == "formula" || section.kind == "diagram" || section.kind == "table"
                let title = _inf6NaturalizedExplanationText(section.heading)
                    .replacingOccurrences(of: #"\n+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedBody = _inf6NaturalizedExplanationText(section.body)
                let body = section.kind == "formula" ? _displayFormulaText(normalizedBody) : normalizedBody
                let height = _estimatedPDFCardHeight(title: title, body: body, width: cardWidth, monospace: monospace)
                if y + height > page.height - bottomMargin {
                    y = beginPage(showTitle: false)
                }
                let cardRect = CGRect(x: 42, y: y, width: cardWidth, height: min(height, page.height - bottomMargin - y))
                _drawPDFCard(title: title, body: body, rect: cardRect, kind: section.kind, monospace: monospace)
                if section.kind == "citation" {
                    _addPDFCitationLinks(context: context.cgContext, body: body, rect: cardRect, citedPapers: target.citedPapers)
                }
                y += height + 16
            }
        }
        #else
        throw NSError(domain: "inf6.originalExplanation", code: 4, userInfo: [NSLocalizedDescriptionKey: "このプラットフォームではPDF生成を実行できません。"])
        #endif
    }

    #if canImport(UIKit)
    private func _displayFormulaText(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\\left|\\right"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\\quad"#, with: "  ", options: .regularExpression)
            .replacingOccurrences(of: #"\\phi"#, with: "φ", options: .regularExpression)
            .replacingOccurrences(of: #"\\theta"#, with: "θ", options: .regularExpression)
            .replacingOccurrences(of: #"\\hat\{y\}"#, with: "ŷ", options: .regularExpression)
            .replacingOccurrences(of: #"\\\{"#, with: "{", options: .regularExpression)
            .replacingOccurrences(of: #"\\\}"#, with: "}", options: .regularExpression)
            .replacingOccurrences(of: #"\\_"#, with: "_", options: .regularExpression)
            .replacingOccurrences(of: #"\^\{([^}]+)\}"#, with: "^$1", options: .regularExpression)
            .replacingOccurrences(of: #"_\{([^}]+)\}"#, with: "_$1", options: .regularExpression)
            .replacingOccurrences(of: #"\\([A-Za-z]+)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func _drawPDFText(_ text: String, rect: CGRect, size: CGFloat, weight: UIFont.Weight, color: UIColor) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: style
        ]
        text.draw(in: rect, withAttributes: attrs)
    }

    private func _drawPDFCard(title: String, body: String, rect: CGRect, kind: String = "text", monospace: Bool = false) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 16)
        UIColor.white.withAlphaComponent(0.82).setFill()
        path.fill()
        UIColor(red: 0.70, green: 0.90, blue: 0.85, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()
        _drawPDFText(title, rect: CGRect(x: rect.minX + 16, y: rect.minY + 14, width: rect.width - 32, height: 24), size: 16, weight: .heavy, color: UIColor(red: 0.00, green: 0.50, blue: 0.38, alpha: 1))
        if kind == "diagram" {
            _drawPDFDiagramFlow(body, rect: CGRect(x: rect.minX + 16, y: rect.minY + 48, width: rect.width - 32, height: rect.height - 64))
            return
        }
        let contentRect = CGRect(x: rect.minX + 16, y: rect.minY + 46, width: rect.width - 32, height: rect.height - 58)
        if kind == "formula" || kind == "citation" || kind == "table" {
            let fill = kind == "formula"
                ? UIColor(red: 0.92, green: 0.96, blue: 1.00, alpha: 1)
                : UIColor(red: 1.00, green: 0.96, blue: 0.90, alpha: 1)
            let stroke = kind == "formula"
                ? UIColor(red: 0.62, green: 0.78, blue: 1.00, alpha: 1)
                : UIColor(red: 0.98, green: 0.72, blue: 0.42, alpha: 1)
            let inner = UIBezierPath(roundedRect: contentRect.insetBy(dx: 0, dy: 0), cornerRadius: 12)
            fill.setFill()
            inner.fill()
            stroke.setStroke()
            inner.lineWidth = 1
            inner.stroke()
        }
        let font = monospace ? UIFont.monospacedSystemFont(ofSize: 11.5, weight: .bold) : UIFont.systemFont(ofSize: 12.5, weight: .semibold)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        if kind == "formula" {
            style.alignment = .center
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(red: 0.10, green: 0.20, blue: 0.18, alpha: 1), .paragraphStyle: style]
        body.draw(in: contentRect.insetBy(dx: kind == "text" || kind == "bullets" ? 0 : 12, dy: kind == "text" || kind == "bullets" ? 0 : 12), withAttributes: attrs)
    }

    private func _addPDFCitationLinks(context: CGContext, body: String, rect: CGRect, citedPapers: [_OriginalExplanationCitedPaper]) {
        let lines = body.components(separatedBy: .newlines)
        let _ = UIFont.systemFont(ofSize: 12.5, weight: .semibold)
        let lineHeight: CGFloat = 16.5
        var currentY = rect.minY + 46 + 12
        for line in lines {
            for paper in citedPapers {
                guard !paper.sourceURL.isEmpty,
                      let url = URL(string: paper.sourceURL),
                      line.contains("[\(paper.label)]") else { continue }
                let titleFragment = paper.title.prefix(60)
                if line.contains(titleFragment) || line.contains("[\(paper.label)]") {
                    let linkRect = CGRect(x: rect.minX + 28, y: currentY, width: rect.width - 56, height: lineHeight)
                    context.setFillColor(UIColor(red: 0.00, green: 0.45, blue: 0.75, alpha: 0.08).cgColor)
                    context.fill(linkRect)
                    let pdfRect = CGRect(x: linkRect.minX, y: rect.maxY - (linkRect.maxY - rect.minY) + rect.minY, width: linkRect.width, height: linkRect.height)
                    UIGraphicsSetPDFContextURLForRect(url, pdfRect)
                    break
                }
            }
            currentY += lineHeight
        }
    }

    private func _drawPDFDiagramFlow(_ body: String, rect: CGRect) {
        let parts = body
            .components(separatedBy: CharacterSet(charactersIn: "→"))
            .flatMap { $0.components(separatedBy: "->") }
            .flatMap { $0.components(separatedBy: "⇒") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.count >= 2 else {
            _drawPDFText(body, rect: rect, size: 12.5, weight: .bold, color: UIColor(red: 0.10, green: 0.20, blue: 0.18, alpha: 1))
            return
        }
        let colors: [(fill: UIColor, stroke: UIColor, text: UIColor)] = [
            (UIColor(red: 0.86, green: 0.93, blue: 1.00, alpha: 1), UIColor(red: 0.12, green: 0.46, blue: 0.86, alpha: 1), UIColor(red: 0.07, green: 0.23, blue: 0.49, alpha: 1)),
            (UIColor(red: 0.86, green: 0.98, blue: 0.91, alpha: 1), UIColor(red: 0.00, green: 0.60, blue: 0.39, alpha: 1), UIColor(red: 0.03, green: 0.37, blue: 0.27, alpha: 1)),
            (UIColor(red: 1.00, green: 0.93, blue: 0.84, alpha: 1), UIColor(red: 0.91, green: 0.36, blue: 0.04, alpha: 1), UIColor(red: 0.49, green: 0.18, blue: 0.06, alpha: 1)),
            (UIColor(red: 0.96, green: 0.90, blue: 1.00, alpha: 1), UIColor(red: 0.58, green: 0.20, blue: 0.91, alpha: 1), UIColor(red: 0.35, green: 0.11, blue: 0.53, alpha: 1))
        ]
        let count = min(parts.count, 5)
        let arrowWidth: CGFloat = 20
        let boxWidth = max(62, min(118, (rect.width - CGFloat(count - 1) * arrowWidth) / CGFloat(count)))
        let boxHeight: CGFloat = min(68, rect.height - 8)
        var x = rect.minX + max(0, (rect.width - CGFloat(count) * boxWidth - CGFloat(count - 1) * arrowWidth) / 2)
        let y = rect.midY - boxHeight / 2
        for index in 0..<count {
            let palette = colors[index % colors.count]
            let box = CGRect(x: x, y: y, width: boxWidth, height: boxHeight)
            let path = UIBezierPath(roundedRect: box, cornerRadius: 16)
            palette.fill.setFill()
            path.fill()
            palette.stroke.setStroke()
            path.lineWidth = 2
            path.stroke()
            _drawPDFText(parts[index], rect: box.insetBy(dx: 8, dy: 12), size: 9.5, weight: .heavy, color: palette.text)
            x += boxWidth
            if index < count - 1 {
                _drawPDFText("→", rect: CGRect(x: x, y: rect.midY - 12, width: arrowWidth, height: 24), size: 17, weight: .heavy, color: UIColor(red: 0.00, green: 0.48, blue: 0.40, alpha: 1))
                x += arrowWidth
            }
        }
    }

    private func _estimatedPDFCardHeight(title: String, body: String, width: CGFloat, monospace: Bool) -> CGFloat {
        let font = monospace ? UIFont.monospacedSystemFont(ofSize: 11.5, weight: .bold) : UIFont.systemFont(ofSize: 12.5, weight: .semibold)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: style
        ]
        let bodyHeight = (body as NSString).boundingRect(
            with: CGSize(width: width - 32, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs,
            context: nil
        ).height
        return max(104, ceil(bodyHeight) + 76)
    }
    #endif


    // MARK: - PDF view identity

    private func _pdfViewIdentity(_ url: URL) -> String {
        let mod = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            .map { String(Int($0.timeIntervalSince1970)) } ?? ""
        return url.absoluteString + "|" + mod
    }

    // MARK: - User Setting Root safe reads (for assets pipeline)

    private func _startParentFolderSecurityScopeForPDFRead(_ url: URL) -> () -> Void {
        #if canImport(UIKit)
        let targetURL = url.standardizedFileURL
        var urlsToStop: [URL] = []

        func _start(_ candidate: URL) {
            let std = candidate.standardizedFileURL
            if urlsToStop.contains(where: { $0.standardizedFileURL.path == std.path }) {
                return
            }
            if std.startAccessingSecurityScopedResource() {
                urlsToStop.append(std)
            }
        }

        _start(targetURL.deletingLastPathComponent())
        _start(targetURL)

        return {
            for u in urlsToStop.reversed() {
                u.stopAccessingSecurityScopedResource()
            }
        }
        #else
        return {}
        #endif
    }

    @discardableResult
    private func _retainSecurityScopeFolder(_ folderURL: URL) -> Bool {
        let std = folderURL.standardizedFileURL

        if let current = _retainedSecurityScopeFolderURL?.standardizedFileURL,
           current.path == std.path {
            return _retainedSecurityScopeIsActive
        }

        if _retainedSecurityScopeIsActive, let current = _retainedSecurityScopeFolderURL {
            current.stopAccessingSecurityScopedResource()
            _retainedSecurityScopeIsActive = false
            _retainedSecurityScopeFolderURL = nil
        }

        if std.startAccessingSecurityScopedResource() {
            _retainedSecurityScopeFolderURL = std
            _retainedSecurityScopeIsActive = true
            return true
        }

        return false
    }

    @discardableResult
    private func _retainSecurityScopeFile(_ fileURL: URL) -> Bool {
        let std = fileURL.standardizedFileURL

        if let current = _retainedSecurityScopeFileURL?.standardizedFileURL,
           current.path == std.path,
           _retainedSecurityScopeFileIsActive {
            return true
        }

        if _retainedSecurityScopeFileIsActive, let current = _retainedSecurityScopeFileURL {
            current.stopAccessingSecurityScopedResource()
            _retainedSecurityScopeFileIsActive = false
            _retainedSecurityScopeFileURL = nil
        }

        if std.startAccessingSecurityScopedResource() {
            _retainedSecurityScopeFileURL = std
            _retainedSecurityScopeFileIsActive = true
            return true
        }

        return false
    }



    private func _readFileDataCoordinatedOrThrow(_ url: URL) throws -> Data {
        var out: Data? = nil
        var coordError: NSError? = nil
        var readError: Error? = nil

        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url, options: [.withoutChanges, .resolvesSymbolicLink], error: &coordError) { readURL in
            do {
                out = try Inf6SafeFileRead.data(at: readURL)
            } catch {
                readError = error
                out = nil
            }
        }

        if let coordError {
            throw coordError
        }
        if let readError {
            throw readError
        }
        guard let out, !out.isEmpty else {
            throw NSError(
                domain: "Inf6AssetsPipeline",
                code: 2001,
                userInfo: [NSLocalizedDescriptionKey: "Coordinated read returned empty data: \(url.path)"]
            )
        }
        return out
    }

    private func _ensurePDFReadableOrThrow(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw NSError(
                domain: "Inf6AssetsPipeline",
                code: 2002,
                userInfo: [NSLocalizedDescriptionKey: "PDF file does not exist: \(url.path)"]
            )
        }
        guard fm.isReadableFile(atPath: url.path) else {
            throw NSError(
                domain: "Inf6AssetsPipeline",
                code: 2003,
                userInfo: [NSLocalizedDescriptionKey: "PDF file is not readable: \(url.path)"]
            )
        }
        let data = try _readFileDataCoordinatedOrThrow(url)
        guard PDFDocument(data: data)?.pageCount ?? 0 > 0 else {
            throw NSError(
                domain: "Inf6AssetsPipeline",
                code: 2004,
                userInfo: [NSLocalizedDescriptionKey: "PDFDocument(data:) failed for readable local file: \(url.path)"]
            )
        }
    }

    @MainActor
    private func _openPDFDocumentForAssetsPipelineOrShowError(url: URL) async -> PDFDocument? {
        let stopSecurityScope = _startParentFolderSecurityScopeForPDFRead(url)
        defer { stopSecurityScope() }

        let fm = FileManager.default

        if !url.isFileURL {
            self.showAssetsPipelineError = true
            self.assetsPipelineErrorMessage = L(
                "PDFのURLがファイルURLではありません: \(url.absoluteString)",
                "PDF URL is not a file URL: \(url.absoluteString)"
            )
            return nil
        }

        do {
            try _ensurePDFReadableOrThrow(url)

            let data = try _readFileDataCoordinatedOrThrow(url)
            if let doc = PDFDocument(data: data), doc.pageCount > 0 {
                return doc
            }

            if let doc = PDFDocument(url: url), doc.pageCount > 0 {
                return doc
            }

            throw NSError(
                domain: "Inf6AssetsPipeline",
                code: 2006,
                userInfo: [NSLocalizedDescriptionKey: "PDFDocument could not be created after readability preflight: \(url.path)"]
            )
        } catch {
            let exists = fm.fileExists(atPath: url.path)
            let existsText = exists ? "YES" : "NO"
            let readableText: String = {
                if let data = try? _readFileDataCoordinatedOrThrow(url), PDFDocument(data: data)?.pageCount ?? 0 > 0 {
                    return "YES"
                }
                if let raw = FileManager.default.contents(atPath: url.path), !raw.isEmpty, let doc = PDFDocument(data: raw), doc.pageCount > 0 {
                    return "YES"
                }
                if let doc = PDFDocument(url: url), doc.pageCount > 0 {
                    return "YES"
                }
                return "NO"
            }()

            let scopeInfo = "pdfParent=\(url.deletingLastPathComponent().standardizedFileURL.path)"

            self.showAssetsPipelineError = true
            self.assetsPipelineErrorMessage = L(
                "PDFを開けませんでした（図表パイプラインのための本文抽出に失敗）。\n\n存在: \(existsText)\n読取可: \(readableText)\n\(scopeInfo)\nパス: \(url.path)\n\n詳細: \(error.localizedDescription)",
                "Failed to open the PDF for the assets pipeline.\n\nExists: \(existsText)\nReadable: \(readableText)\n\(scopeInfo)\nPath: \(url.path)\n\nDetail: \(error.localizedDescription)"
            )
            return nil
        }
    }

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Link(destination: URL(string: "https://inf6.com")!) {
                Text("inf6.com")
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .help(L("inf6.com へ", "Open inf6.com"))
        }
#if os(iOS)
        ToolbarItem(placement: .topBarLeading) {
            if shouldShowPaperLibrarySidebar(in: 0) && fullPDFURL != nil {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        _showLibrarySidebar.toggle()
                        if !_showLibrarySidebar { _libraryEditMode = false }
                    }
                } label: {
                    Image(systemName: _showLibrarySidebar ? "sidebar.left" : "sidebar.left")
                        .symbolVariant(_showLibrarySidebar ? .fill : .none)
                }
                .help(L("論文一覧を表示 / 非表示", "Show / hide paper list"))
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            if fullPDFURL != nil {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        fullPDFURL = nil
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text(L("解説に戻る", "Back"))
                    }
                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(15)))
                }
                .help(L("解説に戻る", "Back to explanation"))
            } else if explanationOverlay != nil {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        explanationOverlay = nil
                        explanationOverlayRawID = nil
                        _explanationEntitySidebar = nil
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text(L("ホームに戻る", "Home"))
                    }
                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(15)))
                }
                .help(L("ホームに戻る", "Back to home"))
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            if let u = fullPDFURL {
                Button {
                    openPDFInNewWindow(u)
                } label: {
                    Image(systemName: "macwindow.badge.plus")
                }
                .help(L("別ウィンドウで開く", "Open in new window"))
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            generationLanguageMenu
        }
#else
        ToolbarItem(placement: .navigation) {
            if shouldShowPaperLibrarySidebar(in: 0) && fullPDFURL != nil {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        _showLibrarySidebar.toggle()
                        if !_showLibrarySidebar { _libraryEditMode = false }
                    }
                } label: {
                    Image(systemName: _showLibrarySidebar ? "sidebar.left" : "sidebar.left")
                        .symbolVariant(_showLibrarySidebar ? .fill : .none)
                }
                .help(L("論文一覧を表示 / 非表示", "Show / hide paper list"))
            }
        }
        ToolbarItem(placement: .primaryAction) {
            generationLanguageMenu
        }
#endif
        // ── 論文収集メニュー（arXiv / PubMed / PDF取り込み / 論文一覧）──
        ToolbarItem(placement: .automatic) {
            Menu {
                // arXiv / PubMed 論文検索
                Button {
                    activeFullScreen = .autoPapers
                } label: {
                    Label(L("arXiv / PubMed 論文検索…", "arXiv / PubMed paper search…"),
                          systemImage: "doc.text.magnifyingglass")
                }

                Divider()

                // PDF取り込み
                Button {
                    if isGeneratingExplanation {
                        showImportError = true
                        importErrorMessage = L(
                            "生成中は別のPDFを開けません。処理が完了してから再度『取り込む』を実行してください。",
                            "You can't open another PDF while generation is running. Please wait until it finishes, then import again."
                        )
                        return
                    }
                    activeFullScreen = nil
                    showPDFPicker = true
                } label: {
                    Label(L("PDFを取り込む…", "Import PDF…"), systemImage: "tray.and.arrow.down")
                }

                // 保存済み論文一覧
                Button {
                    Task { @MainActor in
                        refreshPaperLibraryItems(surfacingError: true)
                        showPaperLibrarySheet = true
                    }
                } label: {
                    Label(L("収集済み論文一覧…", "Collected papers…"), systemImage: "books.vertical")
                }
            } label: {
                Label(L("論文収集", "Papers"), systemImage: "doc.text.magnifyingglass")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help(L("論文収集・管理メニュー", "Paper collection and management menu"))
        }

        // ── ヘルプ ──
        ToolbarItem(placement: .automatic) {
            Menu {
                Button {
                    activeFullScreen = .help
                } label: {
                    Label(L("ヘルプを開く…", "Open Help…"), systemImage: "info.circle")
                }
            } label: {
                Label(L("ヘルプ", "Help"), systemImage: "info.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help(L("アプリの使い方と機能の概要", "App help and feature overview"))
        }

        // ── 設定 ──
        ToolbarItem(placement: .automatic) {
            Menu {
                Button {
                    showOpenAISettings = true
                } label: {
                    Label(L("API キー設定…", "API key settings…"), systemImage: "key.horizontal")
                }
                Button {
                    showSourcesSettings = true
                } label: {
                    Label(L("ソース設定…", "Sources settings…"), systemImage: "list.bullet.rectangle")
                }
                Button {
                    showPromptSettings = true
                } label: {
                    Label(L("Prompt管理…", "Prompt management…"), systemImage: "slider.horizontal.3")
                }
                Divider()
                // 保存先と受け渡しは、API キーの画面の奥に置くと見つからない。
                // 探しに来る人が最初に開くのは歯車であり、ここに並べる。
                Button {
                    activeFullScreen = .storageSettings
                } label: {
                    Label(L("保存する場所…", "Storage folder…"), systemImage: "externaldrive")
                }
                Button {
                    activeFullScreen = .dataExchange
                } label: {
                    Label(L("エクスポート / インポート", "Export / Import"), systemImage: "arrow.up.arrow.down")
                }
                // 演習の再生成と削除は、集中特訓の各行から行える。
                // 対象を見ながら操作できるため、設定の奥に別の入口を置かない。
            } label: {
                Label(L("設定", "Settings"), systemImage: "gearshape")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help(L("API キーとソースを設定", "Configure API keys and sources"))
        }
    }

    var generationLanguageMenu: some View {
        Menu {
            Button {
                genLangRaw = "ja"
                uiLanguageRaw = "ja"
            } label: {
                HStack {
                    if genLangRaw == "ja" { Image(systemName: "checkmark") }
                    Text(L("表示/生成: 日本語（JP）", "Display/generation: Japanese (JP)"))
                }
            }
            Button {
                genLangRaw = "en"
                uiLanguageRaw = "en"
            } label: {
                HStack {
                    if genLangRaw == "en" { Image(systemName: "checkmark") }
                    Text(L("表示/生成: 英語（EN）", "Display/generation: English (EN)"))
                }
            }
            Button {
                genLangRaw = "auto"
                uiLanguageRaw = "auto"
            } label: {
                HStack {
                    if genLangRaw == "auto" { Image(systemName: "checkmark") }
                    Text(L("表示/生成: 自動", "Display/generation: Auto"))
                }
            }
        } label: {
            Label(L("日英切替", "JP/EN switch"), systemImage: "globe")
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(Color.accentColor)
        .help(L("日英表示と生成言語を切り替えます", "Switch display and generation language"))
    }

    @ViewBuilder
    var autoPapersPresenterView: some View {
        Inf6AutoPapersView(initialSearchText: autoPapersInitialSearch) {
            activeFullScreen = nil
        }
            .onDisappear { autoPapersInitialSearch = "" }
    }

    /// AI 資格画面（JDLA G検定など、Inf6SchoolCategory.ai）。
    // assetsPipelinePresenterView removed

    @MainActor
    func runAssetsPipelineAllPages() async {
        guard openAIKeyIsSet() else {
            showAssetsPipelineError = true
            assetsPipelineErrorMessage = L(
                "OpenAI APIキーが未設定です。「OpenAI 設定」からキーを保存してください。",
                "OpenAI API key is not set. Please save it in OpenAI Settings."
            )
            if let u = fullPDFURL {
                assetsPipelineRunState = .failed
                inf6SaveAssetsPipelineRunState(pdfURL: u, state: .failed)
            }
            return
        }
        guard let url = fullPDFURL else {
            showAssetsPipelineError = true
            assetsPipelineErrorMessage = L(
                "PDFが未選択です。先にPDFを取り込んでください。",
                "No PDF selected. Import a PDF first."
            )
            return
        }
        // Keep access for the currently opened PDF while this view is active.
        _ = _retainSecurityScopeFile(url)

        assetsPipelineRunState = .running
        inf6SaveAssetsPipelineRunState(pdfURL: url, state: .running)

        let stopSecurityScope = _startParentFolderSecurityScopeForPDFRead(url)
        defer { stopSecurityScope() }

#if canImport(PDFKit)
        guard let doc = await _openPDFDocumentForAssetsPipelineOrShowError(url: url) else {
            assetsPipelineRunState = .failed
            inf6SaveAssetsPipelineRunState(pdfURL: url, state: .failed)
            return
        }
#endif

        // Ensure per-PDF key exists for persistence.
        if (self.currentPDFCacheKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.currentPDFCacheKey = url.lastPathComponent
        }

        // Snapshot the URL at pipeline start. All writes below are guarded by this snapshot
        // so that switching to a new PDF mid-pipeline cannot corrupt the new PDF's data.
        let pipelineURL = url

        isGeneratingExplanation = true
        defer { isGeneratingExplanation = false }

        do {
            let bundles = try await Inf6AssetsAbstractPipeline.generateAllPagesAssetsBundle(
                pdfURL: url,
                genLang: genLangRaw,
                askModel: { prompt in
                    let targetLang = (genLangRaw == "en") ? "en" : "ja"
                    let promptRef = (targetLang == "en")
                        ? Inf6PromptCatalog.assetsPromptBridgeEn
                        : Inf6PromptCatalog.assetsPromptBridgeJa
                    let rendered = try Inf6PromptGovernance.renderSystemUserPrompt(
                        ref: promptRef,
                        variables: ["task_prompt": prompt]
                    )
                    return try await Self.askOpenAIText(
                        systemInstruction: rendered.systemInstruction,
                        userPrompt: rendered.userPrompt,
                        lang: targetLang
                    )
                }
            )

            // PDF が切り替わっていた場合は書き込みを全てスキップする（旧 PDF の結果で新 PDF を上書きしない）。
            guard fullPDFURL?.standardizedFileURL == pipelineURL.standardizedFileURL else {
                assetsPipelineRunState = .finished
                inf6SaveAssetsPipelineRunState(pdfURL: pipelineURL, state: .finished)
                return
            }

            // 再実行時に古い結果が残らないよう、適用前に全ページのノートをリセットする。
            pageExtraNotes.removeAll(keepingCapacity: true)

            // Apply results page-by-page.
            for b in bundles {
                let pageIndex = b.pageResult.pageIndex
                let renderedNotes = b.pageResult.renderedNotes
                if !renderedNotes.isEmpty {
                    let arr = renderedNotes.map { rendered in
                        Inf6ExtraNote(
                            text: rendered.text,
                            structuredTable: rendered.structuredTable
                        )
                    }
                    pageExtraNotes[pageIndex] = arr
                }

                // Attach generated equation mini PDFs to the existing formula preview history.
#if canImport(PDFKit)
                let pageText = (doc.page(at: pageIndex)?.string ?? "")
#endif

                for mini in b.miniPDFs {
#if canImport(PDFKit)
                    // Stable ordering key derived from page text position (not a fake coordinate).
                    let keyText: String = {
                        if let src = b.pageResult.items.first(where: { $0.id == mini.sourceItemID }) {
                            if let eq = src.equationText?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), !eq.isEmpty {
                                return eq
                            }
                            let ev = src.evidence.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                            return ev
                        }
                        return ""
                    }()

                    let yKey: CGFloat = {
                        guard !keyText.isEmpty else { return 0 }
                        if let r = pageText.range(of: keyText) {
                            return CGFloat(pageText.distance(from: pageText.startIndex, to: r.lowerBound))
                        }
                        return 0
                    }()
#else
                    let yKey: CGFloat = 0
#endif

                    var m = formulaMiniPDFsByPage[mini.pageIndex] ?? []
                    m.append(_FormulaMiniEntry(url: mini.url, yFromTop: yKey))
                    // Keep deterministic ordering.
                    formulaMiniPDFsByPage[mini.pageIndex] = m.sorted(by: { $0.yFromTop < $1.yFromTop })
                }
            }

            // Persist once after applying everything.
            _persistNotesDictToDiskSidecar()
            do {
                try persistCurrentPDFCache()
            } catch {
                showSidecarSaveError = true
                sidecarSaveErrorMessage = L(
                    "PDFキャッシュの保存に失敗しました: \(error.localizedDescription)",
                    "Failed to save PDF cache: \(error.localizedDescription)"
                )
            }

            // Keep the formula pane visible so the user can review generated minis.
            isFormulaMiniPaneVisible = true

            assetsPipelineRunState = .finished
            inf6SaveAssetsPipelineRunState(pdfURL: url, state: .finished)

        } catch {
            showAssetsPipelineError = true
            assetsPipelineErrorMessage = L(
                "図表パイプラインに失敗しました: \(error.localizedDescription)",
                "Assets pipeline failed: \(error.localizedDescription)"
            )
            assetsPipelineRunState = .failed
            inf6SaveAssetsPipelineRunState(pdfURL: url, state: .failed)
        }
    }

    @ViewBuilder
    var content: some View {
        GeometryReader { proxy in
            let isPDFOpen = fullPDFURL != nil
            let hasEntitySidebar = _explanationEntitySidebar != nil
            let showSidebar = shouldShowPaperLibrarySidebar(in: proxy.size.width)
                && _showLibrarySidebar
                && (isPDFOpen || hasEntitySidebar)

            HStack(spacing: 12) {
                if showSidebar {
                    if let sidebarData = _explanationEntitySidebar {
                        _ExplanationEntitySidebarView(data: sidebarData, fontSize: explanationFontSize)
                            .frame(width: min(max(220, proxy.size.width * 0.24), 280))
                            .padding(.leading, 12)
                            .padding(.vertical, 12)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    } else if isPDFOpen {
                        paperLibraryPanel(inSheet: false)
                            .frame(width: min(max(220, proxy.size.width * 0.24), 280))
                            .padding(.leading, 12)
                            .padding(.vertical, 12)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }

                currentDocumentPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.trailing, showSidebar ? 12 : 0)
                    .padding(.vertical, showSidebar ? 12 : 0)
            }
        }
    }

    @ViewBuilder
    var currentDocumentPane: some View {
        ZStack {
            Inf6GraphBoardView(
                focusRawID: circuitBoardFocusRawID,
                onSelectNode: { rawID in
                    _openCircuitBoardDomain(rawID: rawID)
                },
                onSelectPaper: { rawID in
                    _openCircuitBoardPaper(rawID: rawID)
                },
                onSearchConcept: { _ in }
            )
            .opacity(fullPDFURL == nil && explanationOverlay == nil ? 1 : 0)
            .allowsHitTesting(fullPDFURL == nil && explanationOverlay == nil)

            if let content = explanationOverlay {
                _OriginalExplanationOverlayView(title: explanationOverlayTitle, content: content, fontSize: $explanationFontSize, rawID: explanationOverlayRawID, entitySidebar: $_explanationEntitySidebar) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        explanationOverlay = nil
                        explanationOverlayRawID = nil
                        _explanationEntitySidebar = nil
                    }
                }
            }

            if let u = fullPDFURL {
                InlinePDFPagesView(
                    url: u,
                    onTap: { pageIndex, text, rectDesc in
                        // 直ちに解説を生成せず、次の「解説」実行に紐づける
                        self.pendingPDFTap = (pageIndex, text, rectDesc)
                        // NOTE: Do NOT overwrite formula selection here.
                        // Formula selection for mini PDFs is owned by `PDFViewSelectionChanged` (range selection),
                        // while this onTap is for addendum/context actions.
                        // Keep the UI page index in sync with the tap page so the viewer reflects the same page.
                        DispatchQueue.main.async {
                            self.currentPageIndexForUI = pageIndex
                        }
                    },
                    explanation: $fullPDFExplanation,
                    onPageChange: { page in
                        let cached = self.pageExplanationCache[page]
                        DispatchQueue.main.async {
                            self._schedulePersistCurrentPageIndex(page)
                            self.currentPageIndexForUI = page
                        }

                        if self.isShowingPaperAbstract, !self.paperAbstract.isEmpty {
                            return self.paperAbstract
                        }

                        if let cached {
                            return cached
                        }

                        return self.fullPDFExplanation.isEmpty ? nil : self.fullPDFExplanation
                    },
                    assetsPipelineAllPagesAction: { @MainActor in
                        await runAssetsPipelineAllPages()
                    },
                    selectedPage: $currentPageIndexForUI,
                    loadExtraNotes: { page in
                        self.pageExtraNotes[page]
                    },
                    saveExtraNotes: { page, notes in
                        DispatchQueue.main.async {
                            self.pageExtraNotes[page] = notes
                            self._schedulePersistNotes()
                        }
                    }
                )
                .id(_pdfViewIdentity(u))
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    formulaMiniPreviewOverlayV2
                }
                .clipped()
            }
        }
    }

    @MainActor
    func _openCircuitBoardDomain(rawID: String) {
        if rawID.hasPrefix("inf6-explanation:") {
            _openCircuitBoardPaper(rawID: rawID)
            return
        }
        if rawID.hasPrefix("inf6-pipeline:") {
            let payload = String(rawID.dropFirst("inf6-pipeline:".count))
            let forceRerun = payload.contains("::force::")
            let cleanPayload = payload.replacingOccurrences(of: "::force::", with: "")
            let promptParts = cleanPayload.components(separatedBy: "::prompt::")
            let corePart = promptParts[0]
            let parts = corePart.split(separator: ":", maxSplits: 2)
            guard parts.count >= 3 else { return }
            let kind = String(parts[0])
            let sf = String(parts[1])
            let nid = String(parts[2])
            let kinds: Set<Inf6DocEntityKind> = switch kind {
            case "figures": [.figure, .table]
            case "equations": [.equation]
            default: [.figure, .table, .equation]
            }
            _pendingEntityPipelineRun = (sourceFamily: sf, nodeID: nid, kinds: kinds, forceRerun: forceRerun)
            return
        }
        let normalized = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "home:ai":
            circuitBoardFocusRawID = nil
        case let id where id.contains("ai-102") || id.contains("ai-103") || id.contains("microsoft_ai_102") || id.contains("microsoft_ai_103"):
            circuitBoardFocusRawID = rawID
        case let id where id.contains("gkentei") || id.contains("g-kentei"):
            circuitBoardFocusRawID = rawID
        case let id where id.contains("eshikaku") || id.contains("e-shikaku"):
            circuitBoardFocusRawID = rawID
        case let id where id.hasPrefix("concept:"):
            circuitBoardFocusRawID = rawID
        default:
            showImportError = true
            importErrorMessage = L(
                "ホームノードの遷移先を解決できません: \(rawID)",
                "Could not resolve the home node destination: \(rawID)"
            )
        }
    }

    func shouldShowPaperLibrarySidebar(in width: CGFloat) -> Bool {
        if ProcessInfo.processInfo.isiOSAppOnMac { return true }
        guard horizontalSizeClass == .regular else { return false }
        return width <= 0 ? true : width >= 760
    }

    @ViewBuilder
    func paperLibraryPanel(inSheet: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ──────────────────────────────────────────────
            HStack(spacing: 8) {
                Text(L("履歴", "History"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                // Refresh
                Button {
                    Task { @MainActor in
                        refreshPaperLibraryItems(surfacingError: true)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(_libraryEditMode)
                // Edit / Done
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        _libraryEditMode.toggle()
                        if !_libraryEditMode { _selectedLibraryItemIDs.removeAll() }
                    }
                } label: {
                    Text(_libraryEditMode ? L("完了", "Done") : L("編集", "Edit"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(libraryPaperItems.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // ── Delete bar (edit mode) ───────────────────────────────
            if _libraryEditMode {
                HStack(spacing: 10) {
                    Button {
                        if _selectedLibraryItemIDs.count == libraryPaperItems.count {
                            _selectedLibraryItemIDs.removeAll()
                        } else {
                            _selectedLibraryItemIDs = Set(libraryPaperItems.map { $0.id })
                        }
                    } label: {
                        // 集中特訓の行と同じ丸に揃える。文字ボタンだと何を選ぶのか伝わらない。
                        let allSelected = _selectedLibraryItemIDs.count == libraryPaperItems.count
                        VStack(spacing: 1) {
                            Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                            Text(allSelected ? L("全解除", "Deselect") : L("全選択", "Select"))
                                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(8), weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)

                    Spacer()

                    if !_selectedLibraryItemIDs.isEmpty {
                        Button(role: .destructive) {
                            _showLibraryDeleteConfirm = true
                        } label: {
                            Label(
                                L("削除 (\(_selectedLibraryItemIDs.count)件)", "Delete (\(_selectedLibraryItemIDs.count))"),
                                systemImage: "trash"
                            )
                            .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider().padding(.horizontal, 8)

            // ── List ─────────────────────────────────────────────────
            if libraryPaperItems.isEmpty {
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(libraryPaperItems) { item in
                            let isSelected = _selectedLibraryItemIDs.contains(item.id)
                            Button {
                                if _libraryEditMode {
                                    withAnimation(.easeInOut(duration: 0.12)) {
                                        if isSelected {
                                            _selectedLibraryItemIDs.remove(item.id)
                                        } else {
                                            _selectedLibraryItemIDs.insert(item.id)
                                        }
                                    }
                                } else {
                                    if inSheet { showPaperLibrarySheet = false }
                                    handlePickedPDFs([item.url])
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    if _libraryEditMode {
                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(20)))
                                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                                            .transition(.opacity)
                                    }
                                    Text(item.title)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(Color.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .lineLimit(2)
                                        .minimumScaleFactor(0.85)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(
                                            isSelected ? Color.accentColor.opacity(0.12)
                                            : isLibraryPaperSelected(item) ? Color.accentColor.opacity(0.10)
                                            : Color.white.opacity(0.84)
                                        )
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(
                                            isSelected ? Color.accentColor.opacity(0.6)
                                            : isLibraryPaperSelected(item) ? Color.accentColor.opacity(0.35)
                                            : Color.clear,
                                            lineWidth: 1.5
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                            .shadow(color: Color.black.opacity(0.05), radius: 6, y: 3)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        // Delete confirmation
        .alert(
            L("履歴から削除", "Remove from History"),
            isPresented: $_showLibraryDeleteConfirm
        ) {
            Button(L("削除する", "Remove"), role: .destructive) {
                _removeSelectedFromRecently()
            }
            Button(L("キャンセル", "Cancel"), role: .cancel) {}
        } message: {
            Text(L(
                "選択した \(_selectedLibraryItemIDs.count) 件を履歴から削除します。ファイルは削除されません。",
                "\(_selectedLibraryItemIDs.count) item(s) will be removed from History. Files will not be deleted."
            ))
        }
    }

    func isLibraryPaperSelected(_ item: Inf6LibraryPaperListItem) -> Bool {
        guard let fullPDFURL else { return false }
        return Self._pdfFileNameCacheKey(for: fullPDFURL) == Self._pdfFileNameCacheKey(for: item.url)
    }

    @MainActor
    // MARK: - Recently opened list (UserDefaults-backed)

    private static let _recentlyKey = "inf6.recentlyOpenedURLPaths"
    private static let _recentlyMax = 50

    /// Prepends `url` to the recently-opened list and persists to UserDefaults.
    @MainActor
    func _addToRecently(_ url: URL) {
        let normalizedURL = url.standardizedFileURL
        let cacheKey = Self._pdfFileNameCacheKey(for: normalizedURL)
        var paths = (UserDefaults.standard.array(forKey: Self._recentlyKey) as? [String]) ?? []
        paths.removeAll {
            Self._pdfFileNameCacheKey(for: URL(fileURLWithPath: $0)) == cacheKey
        }
        paths.insert(normalizedURL.path, at: 0)
        if paths.count > Self._recentlyMax { paths = Array(paths.prefix(Self._recentlyMax)) }
        UserDefaults.standard.set(paths, forKey: Self._recentlyKey)
    }

    /// Rebuilds `libraryPaperItems` from the recently-opened list.
    /// Non-existent files are silently skipped (file may have been moved/deleted).
    @MainActor
    func refreshPaperLibraryItems(surfacingError: Bool) {
        let paths = (UserDefaults.standard.array(forKey: Self._recentlyKey) as? [String]) ?? []
        var survivingPaths: [String] = []
        var seenKeys = Set<String>()
        libraryPaperItems = paths.compactMap { path -> Inf6LibraryPaperListItem? in
            let original = URL(fileURLWithPath: path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: original.path) else { return nil }
            let cacheKey = Self._pdfFileNameCacheKey(for: original)
            guard seenKeys.insert(cacheKey).inserted else { return nil }
            survivingPaths.append(original.path)
            return Inf6LibraryPaperListItem(
                url: original,
                title: original.deletingPathExtension().lastPathComponent
            )
        }
        if survivingPaths != paths {
            UserDefaults.standard.set(survivingPaths, forKey: Self._recentlyKey)
        }
    }

    /// Removes selected items from the recently-opened list (files are NOT deleted).
    @MainActor
    func _removeSelectedFromRecently() {
        let toRemove = Set(
            libraryPaperItems
                .filter { _selectedLibraryItemIDs.contains($0.id) }
                .map { $0.url.standardizedFileURL.path }
        )
        var paths = (UserDefaults.standard.array(forKey: Self._recentlyKey) as? [String]) ?? []
        paths.removeAll { toRemove.contains($0) }
        UserDefaults.standard.set(paths, forKey: Self._recentlyKey)
        _selectedLibraryItemIDs.removeAll()
        _libraryEditMode = false
        refreshPaperLibraryItems(surfacingError: false)
    }

    // MARK: - Debounced persistence helpers

    func _schedulePersistCurrentPageIndex(_ page: Int) {
        // Avoid mutating @State during view updates: debounce via a reference-type box.
        _pagePersistDebounce.schedule(after: 0.15) {
            UserDefaults.standard.set(page, forKey: "inf6.currentPDFPage")
        }
    }

    func _schedulePersistNotes() {
        // Notes can change frequently while typing; debounce disk writes.
        // Avoid mutating @State during view updates: debounce via a reference-type box.
        _notesPersistDebounce.schedule(after: 0.6) {
            Task { @MainActor in
                self._persistNotesDictToDiskSidecar()
            }
        }
    }

    func _schedulePersistPageExplanationCache() {
        // Page explanations can be generated repeatedly while studying; debounce disk writes.
        _pageExplainCachePersistDebounce.schedule(after: 0.6) {
            Task { @MainActor in
                self.persistPageExplanationCacheToDisk()
            }
        }
    }

    // MARK: - Sidecar file storage (page explanations / extra notes)

    // MARK: - Paper folder key normalization (single source of truth)

    /// Normalize a per-paper folder key so we never create space/punctuation folder names.
    /// Allowed output charset: [a-z0-9_].
    func _normalizedPaperFolderKey(_ raw: String) -> String {
        let s0 = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s0.isEmpty { return "" }

        var s = s0
        if s.lowercased().hasSuffix(".pdf") {
            s = String(s.dropLast(4))
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }

        var out = ""
        out.reserveCapacity(s.count)
        var prevUnderscore = false

        for ch in s {
            let scalar = ch.unicodeScalars.first
            let isSingleScalar = (scalar != nil && ch.unicodeScalars.count == 1)
            let v = scalar?.value ?? 0

            let isDigit = isSingleScalar && (v >= 0x30 && v <= 0x39)
            let isUpper = isSingleScalar && (v >= 0x41 && v <= 0x5A)
            let isLower = isSingleScalar && (v >= 0x61 && v <= 0x7A)

            if isDigit {
                out.append(ch)
                prevUnderscore = false
                continue
            }
            if isUpper {
                out.append(Character(UnicodeScalar(v + 0x20)!))
                prevUnderscore = false
                continue
            }
            if isLower {
                out.append(ch)
                prevUnderscore = false
                continue
            }

            if !prevUnderscore {
                out.append("_")
                prevUnderscore = true
            }
        }

        return out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    /// Resolve the per-paper sidecar directory under the shared root folder.
    /// Storage root: sharedRoot / inf6_knowledge_cards / <PDF folder key>/
    func _iCloudPaperSidecarDir() -> URL? {
        guard let sharedRoot = try? Self._sharedRootDir() else { return nil }
        let root = (Inf6KnowledgeCardsPaths.rootDirectoryURL() ?? sharedRoot.appendingPathComponent("inf6_knowledge_cards", isDirectory: true))

        let keyRaw = (currentPDFCacheKey ?? fullPDFURL?.lastPathComponent ?? "")
        let folderKey = _normalizedPaperFolderKey(keyRaw)
        guard !folderKey.isEmpty else { return nil }

        return root.appendingPathComponent(folderKey, isDirectory: true)
    }

    /// Legacy sidecar directory (pre-fix): folder key included the ".pdf" suffix.
    /// This is used only to *detect* a mismatch and surface a user-visible error.
    /// The app must not silently read from the legacy location.
    func _iCloudPaperSidecarDir_legacyPDFSuffix() -> URL? {
        guard let sharedRoot = try? Self._sharedRootDir() else { return nil }
        let root = (Inf6KnowledgeCardsPaths.rootDirectoryURL() ?? sharedRoot.appendingPathComponent("inf6_knowledge_cards", isDirectory: true))

        let key = (currentPDFCacheKey ?? fullPDFURL?.lastPathComponent ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }

        // Legacy behavior: folder key includes the raw filename (often ends with ".pdf").
        return root.appendingPathComponent(key, isDirectory: true)
    }

    /// Sidecar directory to store per-PDF sidecar JSON files.
    /// Uses the shared root so all platforms see the same knowledge data.
    func _candidateSidecarDirs() -> [URL] {
        if let d = _iCloudPaperSidecarDir() {
            return [d]
        }
        return []
    }

    /// Resolve a sidecar file URL for read/write.
    /// - forWrite: when true, attempts to create the directory and returns the path if successful.
    /// - when false, returns the existing file URL if present.
    func _resolveSidecarURL(fileName: String, forWrite: Bool) -> URL? {
        let fm = FileManager.default
        let dirs = _candidateSidecarDirs()

        guard let dir = dirs.first else {
            DispatchQueue.main.async {
                self.sidecarSaveErrorMessage = L(
                    forWrite
                        ? "保存先フォルダを解決できませんでした。保存先を選び直してから再実行してください。"
                        : "読み込み先フォルダを解決できませんでした。保存先を選び直してから再実行してください。",
                    forWrite
                        ? "Failed to resolve the save folder. Re-select the storage folder and try again."
                        : "Failed to resolve the read folder. Re-select the storage folder and try again."
                )
                self.showSidecarSaveError = true
            }
            return nil
        }

        if forWrite {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                return dir.appendingPathComponent(fileName)
            } catch {
                DispatchQueue.main.async {
                    self.sidecarSaveErrorMessage = L(
                        "保存先フォルダを作成できませんでした: \(dir.path)\n\nエラー: \(error.localizedDescription)",
                        "Failed to create save folder: \(dir.path)\n\nError: \(error.localizedDescription)"
                    )
                    self.showSidecarSaveError = true
                }
#if canImport(OSLog)
                _mathLog.error("create sidecar dir failed: \(dir.path, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
#endif
                return nil
            }
        } else {
            let url = dir.appendingPathComponent(fileName)
            if fm.fileExists(atPath: url.path) {
                return url
            }

            // Detect legacy folder mismatch ("<paper>.pdf/" vs "<paper>/") and surface it.
            if let legacyDir = _iCloudPaperSidecarDir_legacyPDFSuffix() {
                let legacyURL = legacyDir.appendingPathComponent(fileName)
                if fm.fileExists(atPath: legacyURL.path) {
                    DispatchQueue.main.async {
                        self.sidecarSaveErrorMessage = L(
                            "旧保存先フォルダ（末尾 .pdf）が検出されましたが、現在の仕様では読み込みません。\n\n旧: \(legacyDir.path)\n新: \(dir.path)\n\n対処: 保存先 でフォルダ名を『... .pdf』→『...』に変更してから、アプリを再起動してください。",
                            "A legacy sidecar folder (ending with .pdf) was found, but the current app will not read it.\n\nLegacy: \(legacyDir.path)\nCurrent: \(dir.path)\n\nFix: In 保存先, rename the folder from \"... .pdf\" to \"...\" and relaunch the app."
                        )
                        self.showSidecarSaveError = true
                    }
                }
            }

            return nil
        }
    }

// MARK: - PDF import

    /// Always import picked PDFs into the shared library before opening them.

    func handlePickedPDFs(_ urls: [URL]) {
        // reset any prior import error UI
        showImportError = false
        importErrorMessage = ""

        // PDF は図表パイプライン実行中でも切り替え可能。
        // パイプラインは pipelineURL スナップショットで自身の完了時に URL を確認し、
        // 異なる PDF への書き込みを防ぐ。

        guard let firstOriginal = urls.first else { return }

        // remember picker folder for next time
        Self.rememberPDFFolder(for: firstOriginal)

        // keep external listeners informed (use original URLs)
        NotificationCenter.default.post(name: Notification.Name("importPDFsRequested"), object: urls)

        Task { @MainActor in
            do {
                try await importPickedPDFsIntoLibrary(urls)
            } catch {
                showImportError = true
                importErrorMessage = L(
                    "PDF を shared root に取り込めませんでした: \(error.localizedDescription)",
                    "Failed to import the PDF into the shared root: \(error.localizedDescription)"
                )
            }
        }
    }

    @MainActor
    func openGeneratedPDF(_ url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "Inf6LibraryView", code: 91, userInfo: [
                NSLocalizedDescriptionKey: "Generated PDF target does not exist: \(url.path)"
            ])
        }

        fullPDFURL = url
        currentPDFCacheKey = Self._pdfFileNameCacheKey(for: url)

        fullPDFExplanation = ""
        paperAbstract = ""
        isShowingPaperAbstract = false
        isGeneratingExplanation = false
        isExplanationPaneVisible = true

        pageExplanationCache.removeAll(keepingCapacity: true)
        pageExtraNotes.removeAll(keepingCapacity: true)
        lastExplainedPageIndex = nil

        formulaMiniPDFsByPage.removeAll(keepingCapacity: true)
        isFormulaMiniPaneVisible = true
        formulaSelectionText = ""
        formulaSelectionPageIndex = nil
        formulaSelectionAnchorYFromTop = nil

        try restoreCurrentPDFCache()
        restoreNotesDictFromDisk()
        restorePageExplanationCacheFromDisk()
        assetsPipelineRunState = inf6LoadAssetsPipelineRunState(pdfURL: url)
    }

    @MainActor
    func openPDFInNewWindow(_ url: URL) {
        openWindow(id: "paper", value: url)
    }

    // MARK: - Page explain entry points (kept for legacy call-sites)

    /// Accepts plain String selection text and stores it as an extra explanation on the focused PDF page.
    @MainActor
    func explainCurrentPage(selectionText: String) {
        let trimmed = selectionText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let pageIndex = (pendingPDFTap?.pageIndex) ?? lastExplainedPageIndex {
            addExtraExplanationForPDF(pageIndex: pageIndex, selectedText: trimmed, userPrompt: "")
        } else {
            Task { await explainCurrentPageInternal() }
        }
    }

    /// Overload for callers that pass a Binding<String>.
    @MainActor
    func explainCurrentPage(selectionText: Binding<String>) {
        explainCurrentPage(selectionText: selectionText.wrappedValue)
    }

    /// Non-async wrapper for call sites without `await`.
    @MainActor
    func explainCurrentPage() {
        Task { await explainCurrentPageInternal() }
    }

    /// Async variant for call sites already using `await`.
    @MainActor
    func explainCurrentPage() async {
        await explainCurrentPageInternal()
    }

    // MARK: - Core explain implementation

    /// Core implementation: resolve page / selection and generate the main explanation.
    @MainActor
    func explainCurrentPageInternal() async {
        await generateFromDocument(kind: .pageExplain)
    }

    /// Generate an abstract for the *entire paper* (not a per-page explanation).

    /// Shared helper: build a prompt from localized instructions + quoted evidence, call OpenAI, and return MathJax-safe text.
    @MainActor
    func _generateFromQuotedEvidence(
        instructionJa: String,
        instructionEn: String,
        labelJa: String,
        labelEn: String,
        quotedText: String
    ) async throws -> String {
        let baseInstruction = L(instructionJa, instructionEn)
        let label = L(labelJa, labelEn)
        let quoted = quotedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quoted.isEmpty else {
            throw NSError(
                domain: "inf6.openai",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: L(
                    "引用テキストが空のため生成できません（選択またはページ本文を取得できませんでした）。",
                    "Cannot generate because the quoted text is empty (failed to obtain selection or page text)."
                )]
            )
        }

        let rawLang = (UserDefaults.standard.string(forKey: "gen_lang") ?? "auto")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let useEnglish: Bool = {
            if rawLang == "en" { return true }
            if rawLang == "ja" { return false }
            return !Locale.current.identifier.lowercased().hasPrefix("ja")
        }()
        let promptRef = useEnglish
            ? Inf6PromptCatalog.quotedEvidenceBridgeEn
            : Inf6PromptCatalog.quotedEvidenceBridgeJa
        let rendered = try Inf6PromptGovernance.renderSystemUserPrompt(
            ref: promptRef,
            variables: [
                "instruction_text": baseInstruction,
                "label_text": label,
                "quoted_text": quoted
            ]
        )

        let answer = try await Self.askOpenAIText(
            systemInstruction: rendered.systemInstruction,
            userPrompt: rendered.userPrompt,
            lang: useEnglish ? "en" : "ja"
        )
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "inf6.openai",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Empty response from OpenAI"]
            )
        }

        // Normalize common PDF/OCR-ish math into TeX so MathJax can render.
        return _rewriteCommonPDFMathToTeX(trimmed)
    }

    // NOTE: Doc-generation entities are defined in `Inf6DocEntities.swift`.
    // Keep this local alias so the rest of the file can stay unchanged.
    typealias _DocumentGenerationKind = Inf6DocGenerationKind

    /// Single entry point for OpenAI-backed generation. Keeps save destinations consistent.
    @MainActor
    func generateFromDocument(kind: _DocumentGenerationKind) async {
        guard openAIKeyIsSet() else {
            fullPDFExplanation = L(
                "OpenAI APIキーが未設定です。「OpenAI 設定」からキーを保存してください。",
                "OpenAI API key is not set. Please save it in OpenAI Settings."
            )
            return
        }

        guard let url = fullPDFURL else { return }
#if canImport(UIKit)
        // The picked PDF URL is often security-scoped on iOS/iPadOS (and iOS app on Mac).
        // Re-open scope here; otherwise PDFDocument(url:) can fail later and generation appears to do nothing.
        let _scoped = url.startAccessingSecurityScopedResource()
        defer { if _scoped { url.stopAccessingSecurityScopedResource() } }
#endif

        switch kind {
        case .paperAbstract:
            guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
                fullPDFExplanation = L(
                    "PDF を開けませんでした（要旨生成のための本文抽出に失敗）。PDFがアプリからアクセス可能な場所にあるか確認してください。",
                    "Failed to open the PDF for abstract extraction. Please ensure the PDF is accessible to the app."
                )
                return
            }

            var snippet = _extractLikelyAbstractSnippet(from: doc)
            if snippet.isEmpty {
                // Fallback: use early-page text when "Abstract/概要" markers are not detected.
                var raw = ""
                let maxPages = min(2, doc.pageCount)
                for i in 0..<maxPages {
                    raw += "\n" + (doc.page(at: i)?.string ?? "")
                }

                snippet = Self.normalizeSpaces(raw)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if snippet.isEmpty {
                    // Most likely a scanned/image-only PDF (no extractable text).
                    fullPDFExplanation = L(
                        "要旨を抽出できませんでした（PDF本文テキストが取得できません）。画像PDF/スキャンPDFの可能性があります。対処: OCR済みPDFを使うか、テキスト抽出できる版のPDFを選んでください。",
                        "Could not extract text for an abstract (no extractable PDF text). This may be a scanned/image-only PDF. Fix: use an OCR’d PDF or a text-embedded PDF."
                    )
                    return
                }
            }

            isGeneratingExplanation = true
            defer { isGeneratingExplanation = false }

            do {
                let fixed = try await _generateFromQuotedEvidence(
                    instructionJa: """
                    あなたは査読論文の要旨作成者です。以下の引用テキストのみを根拠に、論文全体の要旨を日本語で220〜360字で作成してください。
                    - 背景/目的、手法、主要結果（数値があれば数値も）、結論を含める
                    - 一般論や推測は避け、引用内の語句に対応づけて書く
                    - 箇条書きにせず1段落で
                    - **数式は必ず数式の表記で $...$ / $$...$$ で囲んで表記（必須）**
                    """,
                    instructionEn: """
                    You are an abstract writer for peer-reviewed papers. Using only the quoted text below, write a paper-level abstract in English (about 150–220 words).
                    - Include motivation/goal, method, key results (include numbers if present), and conclusion
                    - Avoid generic statements or speculation; anchor claims to phrases in the quote
                    - Write as a single paragraph (no bullet points)
                    - **Any equations must be written in math notation and wrapped with $...$ / $$...$$ (required).**
                    """,
                    labelJa: "【論文冒頭から抽出した本文（要旨推定）】",
                    labelEn: "【Extracted paper text (likely abstract region)】",
                    quotedText: snippet
                )

                // Persist the paper-level abstract separately, and also show it in the current pane.
                paperAbstract = fixed
                fullPDFExplanation = fixed
                do {
                    try persistCurrentPDFCache()
                } catch {
                    showSidecarSaveError = true
                    sidecarSaveErrorMessage = L(
                        "PDFキャッシュの保存に失敗しました: \(error.localizedDescription)",
                        "Failed to save PDF cache: \(error.localizedDescription)"
                    )
                }
                isShowingPaperAbstract = true
                isExplanationPaneVisible = true
            } catch {
                fullPDFExplanation = "エラー: \(error.localizedDescription)"
            }

        case .pageExplain:
            guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
                fullPDFExplanation = L(
                    "PDF を開けませんでした（ページ解説のための本文抽出に失敗）。PDFがアプリからアクセス可能な場所にあるか確認してください。",
                    "Failed to open the PDF for page explanation extraction. Please ensure the PDF is accessible to the app."
                )
                isShowingPaperAbstract = false
                return
            }

            // Resolve target page
            var pageIndex: Int
            if let tap = pendingPDFTap {
                pageIndex = tap.pageIndex
            } else if let persisted = UserDefaults.standard.object(forKey: "inf6.currentPDFPage") as? Int,
                      persisted >= 0, persisted < doc.pageCount {
                pageIndex = persisted
            } else if let last = lastExplainedPageIndex,
                      last >= 0, last < doc.pageCount {
                pageIndex = last
            } else {
                pageIndex = 0
            }

            pageIndex = max(0, min(pageIndex, doc.pageCount - 1))
            guard let page = doc.page(at: pageIndex) else { return }

            let tap = pendingPDFTap
            pendingPDFTap = nil

            let selectionText = tap?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let useSelection = !selectionText.isEmpty

            let baseInstructionJa = """
            あなたは査読論文の専門解説者です。以下の本文のみを根拠に、図表・指標・結果の読み方と要点を日本語で250〜400字で解説してください。一般論を避け、引用テキスト内の語句や数値と対応づけて具体的に述べてください。
            - 数式を含む場合は **必ず数式の表記で $...$ または $$...$$ で囲んでください（必須）**
            - コードブロックは使わないでください。
            """

            let baseInstructionEn = """
            You are an expert explainer of peer-reviewed papers. Using only the text provided, write an English explanation (about 150–220 words) focusing on how to read the figure/table, the metrics, and the results. Avoid generic statements; anchor each point to phrases or numbers in the quote.
            - **If you include equations, you must write them in math notation and wrap them with $...$ or $$...$$ (required).**
            - Do not use code blocks.
            """

            let snippet: String
            let labelJa: String
            let labelEn: String

            if useSelection {
                let tag: String = {
                    let desc = tap?.rectDesc
                    return (desc?.isEmpty == false) ? (desc ?? "selection") : "selection"
                }()
                snippet = String(selectionText.prefix(1200))
                labelJa = "【選択テキスト（\(tag)）】"
                labelEn = "【Selection (\(tag))】"
            } else {
                let pageText = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !pageText.isEmpty else { return }
                snippet = String(pageText.prefix(1200))
                labelJa = "【本文（ページ \(pageIndex + 1)）】"
                labelEn = "【Body (page \(pageIndex + 1))】"
            }

            guard !snippet.isEmpty else { return }

            isGeneratingExplanation = true
            defer { isGeneratingExplanation = false }

            do {
                let fixed = try await _generateFromQuotedEvidence(
                    instructionJa: baseInstructionJa,
                    instructionEn: baseInstructionEn,
                    labelJa: labelJa,
                    labelEn: labelEn,
                    quotedText: snippet
                )
#if canImport(OSLog)
                _mathLog.debug("explain_fixed len=\(fixed.count, privacy: .public)")
#endif
                isShowingPaperAbstract = false
                fullPDFExplanation = fixed
                pageExplanationCache[pageIndex] = fixed
                lastExplainedPageIndex = pageIndex
                do {
                    try persistCurrentPDFCache()
                } catch {
                    showSidecarSaveError = true
                    sidecarSaveErrorMessage = L(
                        "PDFキャッシュの保存に失敗しました: \(error.localizedDescription)",
                        "Failed to save PDF cache: \(error.localizedDescription)"
                    )
                }
                _schedulePersistPageExplanationCache()
            } catch {
                fullPDFExplanation = "エラー: \(error.localizedDescription)"
            }

        case .selectionAddendum(let pageIndex, let selectedText, let userPrompt):
            let trimmedSelection = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard pageIndex >= 0, !trimmedSelection.isEmpty else { return }

            // Ensure we have a stable per-PDF key; persistence helpers skip work when the key is empty.
            if (self.currentPDFCacheKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.currentPDFCacheKey = (self.fullPDFURL?.lastPathComponent ?? "")
            }

            let hint = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            var evidence = trimmedSelection
            if !hint.isEmpty {
                evidence += "\n\n" + L("【追加指示】\n\(hint)", "[Additional hints]\n\(hint)")
            }

            do {
                let fixed = try await _generateFromQuotedEvidence(
                    instructionJa: """
                    次の引用部分（選択テキスト）を根拠に、既存の解説を補う**短い追記**を日本語で作成してください。120〜200字。一般論は避け、引用語句に対応づけて具体的に書くこと。必要なら**数式は $...$ / $$...$$ で簡潔に表現**して構いません（MathJax表示）。出力は本文のみ。
                    """,
                    instructionEn: """
                    Using the quoted selection below, write a **short addendum** in English that complements the existing explanation (about 80–140 words). Avoid generalities; tie claims to the quoted phrases. If needed, **you may include equations in math notation using $...$ / $$...$$** (MathJax-ready). Output plain text only.
                    """,
                    labelJa: "【選択テキスト】",
                    labelEn: "[Selection]",
                    quotedText: evidence
                )

                var arr = pageExtraNotes[pageIndex] ?? []
                arr.append(Inf6ExtraNote(text: fixed))
                pageExtraNotes[pageIndex] = arr
                // Persist addenda immediately so they survive app restarts.
                _persistNotesDictToDiskSidecar()
                do {
                    try persistCurrentPDFCache()
                } catch {
                    showSidecarSaveError = true
                    sidecarSaveErrorMessage = L(
                        "PDFキャッシュの保存に失敗しました: \(error.localizedDescription)",
                        "Failed to save PDF cache: \(error.localizedDescription)"
                    )
                }
            } catch {
                var arr = pageExtraNotes[pageIndex] ?? []
                arr.append(Inf6ExtraNote(text: "エラー: \(error.localizedDescription)"))
                pageExtraNotes[pageIndex] = arr
                // Persist addenda immediately so they survive app restarts.
                _persistNotesDictToDiskSidecar()
                do {
                    try persistCurrentPDFCache()
                } catch {
                    showSidecarSaveError = true
                    sidecarSaveErrorMessage = L(
                        "PDFキャッシュの保存に失敗しました: \(error.localizedDescription)",
                        "Failed to save PDF cache: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    /// Heuristic extraction: try to isolate the Abstract/概要/要旨 section from early pages.
    func _extractLikelyAbstractSnippet(from doc: PDFDocument) -> String {
        let maxPages = min(4, doc.pageCount)
        var raw = ""
        for i in 0..<maxPages {
            raw += "\n" + (doc.page(at: i)?.string ?? "")
        }

        let text = Self.normalizeSpaces(raw)
        guard !text.isEmpty else { return "" }

        func slice(from startKeys: [String], until endKeys: [String]) -> String? {
            // Find first start marker.
            var startRange: Range<String.Index>? = nil
            for k in startKeys {
                if let r = text.range(of: k, options: [.caseInsensitive]) {
                    startRange = r
                    break
                }
            }
            guard let startRange else { return nil }

            let after = startRange.upperBound
            var endIndex: String.Index = text.endIndex
            for k in endKeys {
                if let r = text.range(of: k, options: [.caseInsensitive], range: after..<text.endIndex) {
                    if r.lowerBound < endIndex { endIndex = r.lowerBound }
                }
            }

            let body = text[after..<endIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":：-–— "))

            let s = String(body)
            return s.isEmpty ? nil : s
        }

        // English: Abstract -> Introduction
        if let s = slice(from: ["Abstract"], until: ["Introduction", "1 Introduction", "1. Introduction"]) {
            return String(s.prefix(4000))
        }

        // Japanese: 概要/要旨 -> はじめに/序論
        if let s = slice(from: ["概要", "要旨"], until: ["はじめに", "序論", "1 はじめに", "1. はじめに"]) {
            return String(s.prefix(4000))
        }

        return ""
    }

    // MARK: - Extra explanations (page notes)

    func addExtraExplanationForPDF(pageIndex: Int, selectedText: String, userPrompt: String) {
        Task { @MainActor in
            await generateFromDocument(kind: .selectionAddendum(pageIndex: pageIndex, selectedText: selectedText, userPrompt: userPrompt))
        }
    }

    func restoreNotesDictFromDisk() {
        let key = (currentPDFCacheKey ?? fullPDFURL?.lastPathComponent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        let safeName = key.replacingOccurrences(of: "/", with: "_")
        let fileName = "\(safeName).extraNotes.json"
        guard let url = _resolveSidecarURL(fileName: fileName, forWrite: false) else { return }

        struct _NotesFile: Codable {
            var version: Int
            var notesByPage: [Int: [Inf6ExtraNote]]
            var savedAt: TimeInterval?
        }

        do {
            let data = try Data(contentsOf: url)
            let payload = try JSONDecoder().decode(_NotesFile.self, from: data)
            self.pageExtraNotes = payload.notesByPage
#if canImport(OSLog)
            let pages = payload.notesByPage.keys.sorted()
            _mathLog.debug("restoreNotesDictFromDisk loaded pages=\(pages, privacy: .public) file=\(url.lastPathComponent, privacy: .public)")
#else
            let pages = payload.notesByPage.keys.sorted()
            print("[Inf6LibraryView] restoreNotesDictFromDisk loaded pages=\(pages) file=\(url.lastPathComponent)")
#endif
        } catch {
            DispatchQueue.main.async {
                self.sidecarSaveErrorMessage = L(
                    "追加解説（青文字）の読み込みに失敗しました。\n\nファイル: \(url.path)\n\nエラー: \(error.localizedDescription)",
                    "Failed to read extra notes.\n\nFile: \(url.path)\n\nError: \(error.localizedDescription)"
                )
                self.showSidecarSaveError = true
            }
#if canImport(OSLog)
            _mathLog.error("restoreNotesDictFromDisk failed: \(error.localizedDescription, privacy: .public)")
#endif
        }
    }

    // MARK: - Page explanation cache persistence (per-PDF)

    func persistPageExplanationCacheToDisk() {
        let key = (currentPDFCacheKey ?? fullPDFURL?.lastPathComponent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        let safeName = key.replacingOccurrences(of: "/", with: "_")
        let fileName = "\(safeName).pageExplainCache.json"
        guard let url = _resolveSidecarURL(fileName: fileName, forWrite: true) else { return }

        struct _CacheFile: Codable {
            var version: Int
            var cacheByPage: [Int: String]
            var savedAt: TimeInterval
        }

        do {
            let payload = _CacheFile(
                version: 1,
                cacheByPage: self.pageExplanationCache,
                savedAt: Date().timeIntervalSince1970
            )
            let data = try JSONEncoder().encode(payload)
            try data.write(to: url, options: [.atomic])
        } catch {
            DispatchQueue.main.async {
                self.sidecarSaveErrorMessage = L(
                    "ページ解説キャッシュの保存に失敗しました。\n\nファイル: \(url.path)\n\nエラー: \(error.localizedDescription)",
                    "Failed to save page explanation cache.\n\nFile: \(url.path)\n\nError: \(error.localizedDescription)"
                )
                self.showSidecarSaveError = true
            }
#if canImport(OSLog)
            _mathLog.error("persistPageExplanationCacheToDisk failed: \(error.localizedDescription, privacy: .public)")
#endif
        }
    }

    func restorePageExplanationCacheFromDisk() {
        let key = (currentPDFCacheKey ?? fullPDFURL?.lastPathComponent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        let safeName = key.replacingOccurrences(of: "/", with: "_")
        let fileName = "\(safeName).pageExplainCache.json"
        guard let url = _resolveSidecarURL(fileName: fileName, forWrite: false) else { return }

        struct _CacheFile: Codable {
            var version: Int
            var cacheByPage: [Int: String]
            var savedAt: TimeInterval?
        }

        do {
            let data = try Data(contentsOf: url)
            let payload = try JSONDecoder().decode(_CacheFile.self, from: data)
            // Merge: keep existing cache entries if already loaded, otherwise take disk.
            for (k, v) in payload.cacheByPage {
                if self.pageExplanationCache[k] == nil {
                    self.pageExplanationCache[k] = v
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.sidecarSaveErrorMessage = L(
                    "ページ解説キャッシュの読み込みに失敗しました。\n\nファイル: \(url.path)\n\nエラー: \(error.localizedDescription)",
                    "Failed to read page explanation cache.\n\nFile: \(url.path)\n\nError: \(error.localizedDescription)"
                )
                self.showSidecarSaveError = true
            }
#if canImport(OSLog)
            _mathLog.error("restorePageExplanationCacheFromDisk failed: \(error.localizedDescription, privacy: .public)")
#endif
        }

    }

    func _persistNotesDictToDiskSidecar() {
        let key = (currentPDFCacheKey ?? fullPDFURL?.lastPathComponent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        let safeName = key.replacingOccurrences(of: "/", with: "_")
        let fileName = "\(safeName).extraNotes.json"
        guard let url = _resolveSidecarURL(fileName: fileName, forWrite: true) else { return }

        struct _NotesFile: Codable {
            var version: Int
            var notesByPage: [Int: [Inf6ExtraNote]]
            var savedAt: TimeInterval
        }

        do {
            let payload = _NotesFile(
                version: 1,
                notesByPage: self.pageExtraNotes,
                savedAt: Date().timeIntervalSince1970
            )
            let data = try JSONEncoder().encode(payload)
            try data.write(to: url, options: [.atomic])
        } catch {
            DispatchQueue.main.async {
                self.sidecarSaveErrorMessage = L(
                    "追加解説（青文字）の保存に失敗しました。\n\nファイル: \(url.path)\n\nエラー: \(error.localizedDescription)",
                    "Failed to save extra notes.\n\nFile: \(url.path)\n\nError: \(error.localizedDescription)"
                )
                self.showSidecarSaveError = true
            }
        #if canImport(OSLog)
            _mathLog.error("persistNotesDictToDisk failed: \(error.localizedDescription, privacy: .public)")
        #endif
        }
    }
}

extension Inf6LibraryView {
    /// Store only the folder URL for the next picker initial directory.
    /// This must NOT auto-open any PDF.
    static func rememberPDFFolderURL(_ folderURL: URL) {
        let u = folderURL.standardizedFileURL
        // Use the same key that `lastPDFFolderURL()` reads.
        UserDefaults.standard.set(u, forKey: "inf6.lastPDFFolderURL")
    }
}





// MARK: - Inf6DocumentFilePickerWrapper

struct Inf6DocumentFilePickerWrapper: UIViewControllerRepresentable {
    let initialFolderURL: URL?
    let onPick: ([URL]) -> Void


    init(initialFolderURL: URL? = nil, _ onPick: @escaping ([URL]) -> Void) {
        self.initialFolderURL = initialFolderURL
        self.onPick = onPick
    }

    init(initialFolderURL: URL? = nil, onPick: @escaping ([URL]) -> Void) {
        self.initialFolderURL = initialFolderURL
        self.onPick = onPick
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: false)
        if let dir = initialFolderURL {
            if #available(iOS 16.0, *) {
                picker.directoryURL = dir
            }
        }
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: Inf6DocumentFilePickerWrapper
        init(_ parent: Inf6DocumentFilePickerWrapper) {
            self.parent = parent
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPick(urls)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onPick([])
        }
    }
}

// MARK: - 概要解説 SwiftUI Overlay

private struct _OriginalExplanationOverlayView: View {
    let title: String
    let content: Inf6LibraryView._OriginalExplanationContent
    @Binding var fontSize: CGFloat
    var rawID: String? = nil
    @Binding var entitySidebar: Inf6LibraryView._ExplanationEntitySidebarData?
    let onClose: () -> Void
    @Environment(\.openWindow) private var openWindow

    @State private var selectedPaperCardId: String?
    @State private var _selectionExplainText: String?
    @State private var _selectionExplainAction: String?
    @State private var _selectionExplainResult: String?
    @State private var _selectionExplainLoading = false
    @State private var _quizPage: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            if let selectedId = selectedPaperCardId,
               let card = content.paperCards.first(where: { $0.id == selectedId }) {
                _PaperDetailView(card: card, fontSize: fontSize, entitySidebar: $entitySidebar, onBack: {
                    selectedPaperCardId = nil
                    entitySidebar = nil
                })
            } else {
                _overviewBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .systemBackground))
        .onReceive(NotificationCenter.default.publisher(for: .inf6ExplainSelection)) { notif in
            guard let text = notif.userInfo?["text"] as? String,
                  let action = notif.userInfo?["action"] as? String else { return }
            _selectionExplainText = text
            _selectionExplainAction = action
            _selectionExplainResult = nil
            _selectionExplainLoading = true
            Task { @MainActor in
                do {
                    let result = try await _askSelectionExplain(text: text, action: action)
                    _selectionExplainResult = result
                } catch {
                    _selectionExplainResult = "エラー: \(error.localizedDescription)"
                }
                _selectionExplainLoading = false
            }
        }
    }

    private var _isQuiz: Bool {
        rawID?.hasPrefix("inf6-quiz:") == true
    }

    private var _quizSortedSections: [Inf6LibraryView._OriginalExplanationContent.Section] {
        let all = content.conceptSections
        func kindOrder(_ s: Inf6LibraryView._OriginalExplanationContent.Section) -> Int {
            let h = s.heading
            if h.contains("[図:") || h.contains("[Figure:") { return 0 }
            if h.contains("[表:") || h.contains("[Table:") { return 1 }
            if h.contains("[数式:") || h.contains("[Equation:") { return 2 }
            return 3
        }
        return all.sorted { kindOrder($0) < kindOrder($1) }
    }

    private var _quizNodeName: String {
        let t = title.replacingOccurrences(of: " — 演習", with: "")
        if let range = t.range(of: " — ") {
            return String(t[t.startIndex..<range.lowerBound])
        }
        return t
    }

    private var _quizPaperTitles: [String] {
        var seen = Set<String>()
        var titles: [String] = []
        for s in content.sections where s.kind == "quiz" {
            guard let pdfKey = s.pdfKey, !pdfKey.isEmpty, !seen.contains(pdfKey) else { continue }
            seen.insert(pdfKey)
            let papers = Inf6CorePaperStore.shared.papers
            if let paper = papers.first(where: {
                Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: $0.titleEn ?? $0.title) == pdfKey
            }) {
                titles.append(paper.title)
            } else {
                titles.append(pdfKey)
            }
        }
        return titles
    }

    @ViewBuilder
    private var _overviewBody: some View {
        _OverviewToolbar(
            title: title,
            fontSize: $fontSize,
            rawID: rawID,
            isQuiz: _isQuiz,
            onClose: onClose
        )

        if _isQuiz {
            let sections = _quizSortedSections
            let pageCount = sections.count
            VStack(alignment: .leading, spacing: 0) {
                if pageCount > 1 {
                    HStack {
                        Spacer()
                        HStack(spacing: 12) {
                            Button {
                                withAnimation { _quizPage = max(0, _quizPage - 1) }
                            } label: {
                                Image(systemName: "chevron.left.circle.fill")
                                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(28)))
                                    .foregroundStyle(_quizPage > 0 ? Color.accentColor : Color.secondary.opacity(0.3))
                            }
                            .buttonStyle(.plain)
                            .disabled(_quizPage <= 0)
                            .keyboardShortcut(.leftArrow, modifiers: [])

                            Text("\(_quizPage + 1) / \(pageCount)")
                                .font(.system(size: fontSize, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.secondary)

                            Button {
                                withAnimation { _quizPage = min(pageCount - 1, _quizPage + 1) }
                            } label: {
                                Image(systemName: "chevron.right.circle.fill")
                                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(28)))
                                    .foregroundStyle(_quizPage < pageCount - 1 ? Color.accentColor : Color.secondary.opacity(0.3))
                            }
                            .buttonStyle(.plain)
                            .disabled(_quizPage >= pageCount - 1)
                            .keyboardShortcut(.rightArrow, modifiers: [])
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color(uiColor: .secondarySystemBackground))

                    Divider()
                }

                if pageCount > 0 {
                    _QuizPageScrollView(
                        page: $_quizPage,
                        pageCount: pageCount
                    ) {
                        _ExplanationSectionView(section: sections[min(_quizPage, pageCount - 1)], fontSize: fontSize)
                            .padding(20)
                            .id(_quizPage)
                    }
                }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if _selectionExplainText != nil {
                        _SelectionExplainCard(
                            selectedText: _selectionExplainText ?? "",
                            action: _selectionExplainAction ?? "explain",
                            result: _selectionExplainResult,
                            isLoading: _selectionExplainLoading,
                            fontSize: fontSize,
                            onDismiss: {
                                _selectionExplainText = nil
                                _selectionExplainResult = nil
                                _selectionExplainLoading = false
                            }
                        )
                    }

                    if let rawID = rawID, let diff = Inf6FrontierEngine.explanationDiff(rawID: rawID) {
                        _FrontierDiffBanner(diff: diff, fontSize: fontSize)
                    }

                    ForEach(Array(content.conceptSections.enumerated()), id: \.offset) { _, section in
                        _ExplanationSectionView(section: section, fontSize: fontSize)
                    }

                    ForEach(content.paperCards) { card in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedPaperCardId = card.id
                            }
                        } label: {
                            _PaperCardView(card: card, fontSize: fontSize)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
        }
    }

    private func _askSelectionExplain(text: String, action: String) async throws -> String {
        let systemInstruction: String
        let userPrompt: String
        switch action {
        case "summarize":
            systemInstruction = "学術テキストを簡潔に要約する専門家。日本語で回答。"
            userPrompt = "以下のテキストを短く要約してください。前置き不要。要約のみ出力。\n\n\(text)"
        case "comment":
            systemInstruction = "学術テキストに深い洞察を加える専門家。日本語で回答。"
            userPrompt = "以下のテキストにコメント・補足説明を付けてください。原文の重要ポイント、背景、関連知識を簡潔に示してください。前置き不要。\n\n\(text)"
        default:
            systemInstruction = "学術用語・概念を平易に解説する専門家。日本語で回答。"
            userPrompt = "以下のテキストの意味を詳しく説明してください。前置き不要。解説のみ出力。\n\n\(text)"
        }
        return try await Inf6LibraryView.askOpenAIText(
            systemInstruction: systemInstruction,
            userPrompt: userPrompt,
            lang: "ja"
        )
    }
}

// MARK: - Quiz Page ScrollView (overscroll → page turn)

private struct _QuizPageScrollView<Content: View>: UIViewRepresentable {
    @Binding var page: Int
    let pageCount: Int
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.delegate = context.coordinator

        let host = context.coordinator.hostController
        host.view.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            host.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        coord.hostController.rootView = AnyView(content())
        coord.hostController.view.setNeedsLayout()
        coord.hostController.view.layoutIfNeeded()

        coord.hostController.view.invalidateIntrinsicContentSize()

        if coord.lastRenderedPage != page {
            DispatchQueue.main.async {
                scrollView.setContentOffset(.zero, animated: false)
            }
            coord.lastRenderedPage = page
            coord.pageTurnCooldown = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                coord.pageTurnCooldown = false
            }
        }
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: _QuizPageScrollView
        var lastRenderedPage: Int = 0
        var pageTurnCooldown = false
        lazy var hostController: UIHostingController<AnyView> = {
            let hc = UIHostingController<AnyView>(rootView: AnyView(EmptyView()))
            hc.view.backgroundColor = .clear
            return hc
        }()

        init(parent: _QuizPageScrollView) {
            self.parent = parent
            super.init()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !pageTurnCooldown else { return }
            let offsetY = scrollView.contentOffset.y
            let contentH = scrollView.contentSize.height
            let frameH = scrollView.bounds.height
            let maxOffset = max(0, contentH - frameH)
            let threshold: CGFloat = 60

            if contentH <= frameH {
                if offsetY < -threshold, parent.page > 0 {
                    turnPage(-1, scrollView: scrollView)
                } else if offsetY > threshold, parent.page < parent.pageCount - 1 {
                    turnPage(1, scrollView: scrollView)
                }
            } else if offsetY < -threshold {
                turnPage(-1, scrollView: scrollView)
            } else if offsetY > maxOffset + threshold {
                turnPage(1, scrollView: scrollView)
            }
        }

        private func turnPage(_ delta: Int, scrollView: UIScrollView) {
            pageTurnCooldown = true
            withAnimation { parent.page += delta }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.pageTurnCooldown = false
            }
        }
    }
}

// MARK: - Overview Toolbar

private struct _OverviewToolbar: View {
    let title: String
    @Binding var fontSize: CGFloat
    var rawID: String?
    var isQuiz: Bool = false
    let onClose: () -> Void
    @Environment(\.openWindow) private var openWindow

    private var _titleColor: UIColor {
        isQuiz ? UIColor(red: 0.0, green: 0.45, blue: 0.15, alpha: 1.0) : .label
    }

    var body: some View {
        HStack {
            Button { onClose() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text(L("戻る", "Back"))
                }
                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(15)))
            }
            .buttonStyle(.plain)

            Spacer()

            #if canImport(UIKit)
            _SelectableExplanationText(
                text: _inf6NaturalizedExplanationText(title),
                font: .systemFont(ofSize: fontSize + 4, weight: .heavy),
                color: _titleColor
            )
            #else
            Text(title)
                .font(.system(size: fontSize + 4, weight: .heavy))
                .foregroundStyle(isQuiz ? Color(red: 0.0, green: 0.45, blue: 0.15) : .primary)
            #endif

            Spacer()

            if let rawID {
                Button {
                    openWindow(id: "explanation", value: rawID)
                } label: {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(16)))
                }
                .buttonStyle(.plain)
                .help(L("別ウィンドウで開く", "Open in new window"))
            }
            Button {
                let newSize = max(14, fontSize - 2)
                fontSize = newSize
                Inf6MetadataStore.put(domain: .settings, key: "explanation_font_size", json: String(Int(newSize)))
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(16)))
            }
            .buttonStyle(.plain)
            .disabled(fontSize <= 14)
            Button {
                let newSize = min(36, fontSize + 2)
                fontSize = newSize
                Inf6MetadataStore.put(domain: .settings, key: "explanation_font_size", json: String(Int(newSize)))
            } label: {
                Image(systemName: "textformat.size.larger")
                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(16)))
            }
            .buttonStyle(.plain)
            .disabled(fontSize >= 36)
            Button { onClose() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(20)))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.8))
    }
}

// MARK: - Per-Paper Detail View

private struct _PaperDetailView: View {
    let card: Inf6LibraryView._OriginalExplanationContent.PaperCard
    let fontSize: CGFloat
    @Binding var entitySidebar: Inf6LibraryView._ExplanationEntitySidebarData?
    let onBack: () -> Void

    @State private var abstractText: String?
    @State private var abstractLoaded = false
    @State private var entities: [Inf6DocEntity] = []
    @State private var resolvedPdfKey: String?

    private var figures: [Inf6DocEntity] { entities.filter { $0.kind == .figure } }
    private var tables: [Inf6DocEntity] { entities.filter { $0.kind == .table } }
    private var equations: [Inf6DocEntity] { entities.filter { $0.kind == .equation } }

    private var overviewSections: [Inf6LibraryView._OriginalExplanationContent.Section] {
        card.sections.filter { $0.kind == "paper_overview" || $0.kind == "text" }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar with back button
            HStack {
                Button { withAnimation(.easeInOut(duration: 0.2)) { onBack() } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text(L("概要解説", "Overview"))
                    }
                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(15)))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemBackground).opacity(0.8))

            // Sticky header: paper title + abstract
            VStack(alignment: .leading, spacing: 8) {
                #if canImport(UIKit)
                _SelectableExplanationText(
                    text: _inf6NaturalizedExplanationText(card.title),
                    font: .systemFont(ofSize: fontSize + 4, weight: .bold),
                    color: .label
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                #else
                Text(card.title)
                    .font(.system(size: fontSize + 4, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                #endif

                if let abstractText {
                    #if canImport(UIKit)
                    _SelectableExplanationText(
                        text: abstractText,
                        font: .systemFont(ofSize: fontSize - 1),
                        color: .secondaryLabel,
                        lineSpacing: 2
                    )
                    #else
                    Text(abstractText)
                        .font(.system(size: fontSize - 1))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                    #endif
                }
            }
            .padding(16)
            .background(Color(uiColor: .secondarySystemBackground))

            Divider()

            // Main scrollable content (sidebar is in the outer history bar area)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(Array(overviewSections.enumerated()), id: \.offset) { _, section in
                            _ExplanationSectionView(section: section, fontSize: fontSize)
                        }

                        if !figures.isEmpty {
                            _EntityGroupHeader(title: L("図", "Figures"), systemImage: "photo", fontSize: fontSize)
                            ForEach(figures) { entity in
                                _EntityDetailPane(entity: entity, pdfKey: resolvedPdfKey ?? "", fontSize: fontSize)
                                    .id("entity-\(entity.id.uuidString)")
                            }
                        }

                        if !tables.isEmpty {
                            _EntityGroupHeader(title: L("表", "Tables"), systemImage: "tablecells", fontSize: fontSize)
                            ForEach(tables) { entity in
                                _EntityDetailPane(entity: entity, pdfKey: resolvedPdfKey ?? "", fontSize: fontSize)
                                    .id("entity-\(entity.id.uuidString)")
                            }
                        }

                        if !equations.isEmpty {
                            _EntityGroupHeader(title: L("数式", "Equations"), systemImage: "function", fontSize: fontSize)
                            ForEach(equations) { entity in
                                _EntityDetailPane(entity: entity, pdfKey: resolvedPdfKey ?? "", fontSize: fontSize)
                                    .id("entity-\(entity.id.uuidString)")
                            }
                        }
                    }
                    .padding(20)
                }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("_inf6ScrollToEntity"))) { notif in
                    if let idStr = notif.userInfo?["id"] as? String {
                        withAnimation { proxy.scrollTo("entity-\(idStr)", anchor: .top) }
                    }
                }
            }
        }
        .task {
            _loadEntities()
            if !abstractLoaded, let pid = card.paperID {
                abstractLoaded = true
                let store = Inf6CorePaperAbstractStore.shared
                if let text = store.abstract(for: pid) {
                    abstractText = text
                    return
                }
                guard let paper = Inf6MetadataStore.getCodable(Inf6CorePaper.self, domain: .papers, key: pid) else { return }
                await store.fetchAbstract(for: paper)
                abstractText = store.abstract(for: pid)
            }
        }
    }

    private func _loadEntities() {
        guard let pid = card.paperID else { return }
        let pdfKey: String
        if let sec = card.sections.first(where: { $0.pdfKey != nil }), let key = sec.pdfKey {
            pdfKey = key
        } else if let paper = Inf6MetadataStore.getCodable(Inf6CorePaper.self, domain: .papers, key: pid) {
            pdfKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paper.titleEn ?? paper.title)
        } else {
            return
        }
        resolvedPdfKey = pdfKey
        guard let index = Inf6MetadataStore.getCodable(Inf6DocEntityIndex.self, domain: .docEntities, key: pdfKey) else { return }
        entities = index.entities
        entitySidebar = .init(entities: index.entities, pdfKey: pdfKey)
    }
}

// MARK: - Sidebar Components

private struct _SidebarGroupLabel: View {
    let title: String
    let systemImage: String
    let fontSize: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: fontSize - 4))
            Text(title)
                .font(.system(size: fontSize - 2, weight: .bold))
        }
        .foregroundStyle(.secondary)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

private struct _SidebarEntityLink: View {
    let entity: Inf6DocEntity
    let fontSize: CGFloat

    var body: some View {
        Button {
            NotificationCenter.default.post(
                name: Notification.Name("_inf6ScrollToEntity"),
                object: nil,
                userInfo: ["id": entity.id.uuidString]
            )
        } label: {
            Text(entity.title)
                .font(.system(size: fontSize - 3))
                .foregroundStyle(Color.accentColor)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(Color.accentColor.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Entity Sidebar (replaces history bar)

private struct _ExplanationEntitySidebarView: View {
    let data: Inf6LibraryView._ExplanationEntitySidebarData
    let fontSize: CGFloat

    private var figures: [Inf6DocEntity] { data.entities.filter { $0.kind == .figure } }
    private var tables: [Inf6DocEntity] { data.entities.filter { $0.kind == .table } }
    private var equations: [Inf6DocEntity] { data.entities.filter { $0.kind == .equation } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.subheadline)
                Text(L("インデックス", "Index"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().padding(.horizontal, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !figures.isEmpty {
                        _SidebarGroupLabel(title: L("図", "Figures"), systemImage: "photo", fontSize: fontSize)
                        ForEach(figures) { entity in
                            _SidebarEntityLink(entity: entity, fontSize: fontSize)
                        }
                    }
                    if !tables.isEmpty {
                        _SidebarGroupLabel(title: L("表", "Tables"), systemImage: "tablecells", fontSize: fontSize)
                        ForEach(tables) { entity in
                            _SidebarEntityLink(entity: entity, fontSize: fontSize)
                        }
                    }
                    if !equations.isEmpty {
                        _SidebarGroupLabel(title: L("数式", "Equations"), systemImage: "function", fontSize: fontSize)
                        ForEach(equations) { entity in
                            _SidebarEntityLink(entity: entity, fontSize: fontSize)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

// MARK: - Entity Detail Pane (split image / explanation)

private struct _EntityGroupHeader: View {
    let title: String
    let systemImage: String
    let fontSize: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: fontSize + 2, weight: .bold))
            Text(title)
                .font(.system(size: fontSize + 2, weight: .bold))
        }
        .foregroundStyle(.primary)
        .padding(.top, 8)
    }
}

private struct _EntityDetailPane: View {
    let entity: Inf6DocEntity
    let pdfKey: String
    let fontSize: CGFloat
    @State private var image: UIImage?
    @State private var loaded = false
    @State private var editingTitle = false
    @State private var editTitleText = ""
    @State private var editingExplanation = false
    @State private var editExplanationText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Entity title
            HStack(spacing: 6) {
                Image(systemName: entity.kind == .equation ? "function" : (entity.kind == .table ? "tablecells" : "photo"))
                    .font(.system(size: fontSize - 2))
                    .foregroundStyle(.secondary)

                if editingTitle {
                    TextField("タイトル", text: $editTitleText)
                        .font(.system(size: fontSize, weight: .bold))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { _saveTitle() }
                    Button { _saveTitle() } label: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }.buttonStyle(.plain)
                    Button { editingTitle = false } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                } else {
                    Text(entity.title)
                        .font(.system(size: fontSize, weight: .bold))
                    Button {
                        editTitleText = entity.title
                        editingTitle = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: fontSize - 4))
                            .foregroundStyle(.secondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Split pane: image (top) / explanation (bottom)
            VStack(alignment: .leading, spacing: 0) {
                // Image: full size, no scroll
                if let img = image {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(Color(uiColor: .tertiarySystemBackground))
                } else if entity.imagePath != nil && !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 80)
                        .background(Color(uiColor: .tertiarySystemBackground))
                }

                Divider()

                // Explanation
                VStack(alignment: .leading, spacing: 4) {
                    if editingExplanation {
                        TextEditor(text: $editExplanationText)
                            .font(.system(size: fontSize - 2))
                            .frame(minHeight: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                        HStack {
                            Button { _saveExplanation() } label: {
                                Label(L("保存", "Save"), systemImage: "checkmark.circle.fill")
                                    .font(.system(size: fontSize - 2))
                            }.buttonStyle(.borderedProminent).tint(.green)
                            Button { editingExplanation = false } label: {
                                Label(L("キャンセル", "Cancel"), systemImage: "xmark")
                                    .font(.system(size: fontSize - 2))
                            }.buttonStyle(.bordered)
                        }
                    } else {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading) {
                                if let explanation = entity.explanation, !explanation.isEmpty {
                                    #if canImport(UIKit)
                                    _SelectableExplanationText(
                                        text: _inf6NaturalizedExplanationText(explanation),
                                        font: .systemFont(ofSize: fontSize - 1),
                                        color: .label.withAlphaComponent(0.85),
                                        lineSpacing: 3
                                    )
                                    #else
                                    Text(_inf6NaturalizedExplanationText(explanation))
                                        .font(.system(size: fontSize - 1))
                                        .foregroundStyle(.primary.opacity(0.85))
                                        .lineSpacing(3)
                                    #endif
                                } else if !entity.snippet.isEmpty {
                                    #if canImport(UIKit)
                                    _SelectableExplanationText(
                                        text: _inf6NaturalizedExplanationText(entity.snippet),
                                        font: .systemFont(ofSize: fontSize - 1),
                                        color: .secondaryLabel
                                    )
                                    #else
                                    Text(_inf6NaturalizedExplanationText(entity.snippet))
                                        .font(.system(size: fontSize - 1))
                                        .foregroundStyle(.secondary)
                                    #endif
                                }
                            }
                            Spacer(minLength: 4)
                            Button {
                                editExplanationText = entity.explanation ?? entity.snippet
                                editingExplanation = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: fontSize - 4))
                                    .foregroundStyle(.secondary.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.12), lineWidth: 1))
        .task {
            guard !loaded, let path = entity.imagePath else { return }
            loaded = true
            let url = Inf6LibraryView._entityImagesBaseURL().appendingPathComponent(path)
            if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
                await MainActor.run { image = img }
            }
        }
    }

    private func _saveTitle() {
        let newTitle = editTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newTitle.isEmpty else { return }
        _updateEntity { $0.title = newTitle }
        editingTitle = false
    }

    private func _saveExplanation() {
        let newText = editExplanationText.trimmingCharacters(in: .whitespacesAndNewlines)
        _updateEntity { $0.explanation = newText.isEmpty ? nil : newText }
        editingExplanation = false
    }

    private func _updateEntity(_ mutate: (inout Inf6DocEntity) -> Void) {
        guard var index = Inf6MetadataStore.getCodable(Inf6DocEntityIndex.self, domain: .docEntities, key: pdfKey) else { return }
        guard let idx = index.entities.firstIndex(where: { $0.id == entity.id }) else { return }
        mutate(&index.entities[idx])
        index.entities[idx].updatedAt = Date().timeIntervalSince1970
        Inf6MetadataStore.putCodable(index, domain: .docEntities, key: pdfKey)
    }
}

private struct _SelectionExplainCard: View {
    let selectedText: String
    let action: String
    let result: String?
    let isLoading: Bool
    let fontSize: CGFloat
    let onDismiss: () -> Void

    private var actionLabel: String {
        switch action {
        case "summarize": return "短く要約"
        case "comment": return "コメント付き"
        default: return "意味を説明"
        }
    }

    private var actionIcon: String {
        switch action {
        case "summarize": return "text.quote"
        case "comment": return "bubble.left"
        default: return "lightbulb"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: actionIcon)
                    .font(.system(size: fontSize - 2, weight: .bold))
                    .foregroundStyle(.white)
                Text(actionLabel)
                    .font(.system(size: fontSize - 2, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(18)))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            #if canImport(UIKit)
            _SelectableExplanationText(
                text: selectedText,
                font: .italicSystemFont(ofSize: fontSize - 3),
                color: .secondaryLabel,
                maximumNumberOfLines: 4
            )
            .padding(.horizontal, 4)
            #else
            Text(selectedText)
                .font(.system(size: fontSize - 3))
                .italic()
                .foregroundStyle(.secondary)
                .lineLimit(4)
            #endif

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("生成中…", "Generating…"))
                        .font(.system(size: fontSize - 2))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            if let result {
                Divider()
                #if canImport(UIKit)
                _SelectableExplanationText(
                    text: result,
                    font: .systemFont(ofSize: fontSize, weight: .regular),
                    color: .label,
                    lineSpacing: 4
                )
                #else
                Text(result)
                    .font(.system(size: fontSize))
                    .foregroundStyle(.primary)
                #endif
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct _PipelineActionBar: View {
    let rawID: String
    let fontSize: CGFloat
    @State private var isRunningFigures = false
    @State private var isRunningEquations = false
    @State private var resultMessage: String?

    private var sourceFamily: String {
        let parts = rawID.dropFirst("inf6-explanation:".count).split(separator: ":", maxSplits: 1)
        return parts.count >= 1 ? String(parts[0]) : ""
    }
    private var nodeID: String {
        let parts = rawID.dropFirst("inf6-explanation:".count).split(separator: ":", maxSplits: 1)
        return parts.count >= 2 ? String(parts[1]) : ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    runPipeline(kind: "figures")
                } label: {
                    HStack(spacing: 6) {
                        if isRunningFigures {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "photo.badge.plus")
                        }
                        Text(L("図表パイプライン", "Figures Pipeline"))
                            .font(.system(size: fontSize - 2))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(isRunningFigures || isRunningEquations)

                Button {
                    runPipeline(kind: "equations")
                } label: {
                    HStack(spacing: 6) {
                        if isRunningEquations {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "function")
                        }
                        Text(L("数式パイプライン", "Equations Pipeline"))
                            .font(.system(size: fontSize - 2))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(isRunningFigures || isRunningEquations)
            }

            if let msg = resultMessage {
                Text(msg)
                    .font(.system(size: fontSize - 3))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func runPipeline(kind: String) {
        let sf = sourceFamily
        let nid = nodeID
        guard !sf.isEmpty, !nid.isEmpty else { return }

        if kind == "figures" { isRunningFigures = true }
        else { isRunningEquations = true }
        resultMessage = L("実行中…", "Running…")

        Task { @MainActor in
            defer {
                isRunningFigures = false
                isRunningEquations = false
            }
            let paperIDs = Inf6SyllabusPaperAutoSearch.linkedPaperIDs(sourceFamily: sf, syllabusNodeID: nid)
            guard !paperIDs.isEmpty else {
                resultMessage = "リンクされた論文がありません"
                return
            }
            var processed = 0
            var skipped = 0
            let fm = FileManager.default

            for paperID in paperIDs {
                guard let paper = Inf6MetadataStore.getCodable(Inf6CorePaper.self, domain: .papers, key: paperID) else { continue }
                let pdfKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paper.titleEn ?? paper.title)
                guard !pdfKey.isEmpty else { continue }

                if Inf6MetadataStore.getCodable(Inf6DocEntityIndex.self, domain: .docEntities, key: pdfKey) != nil {
                    skipped += 1
                    continue
                }

                guard let localURL = paper._localPapersPDFPublic(), fm.fileExists(atPath: localURL.path) else {
                    continue
                }

                do {
                    let bundles = try await Inf6AssetsAbstractPipeline.generateAllPagesAssetsBundle(
                        pdfURL: localURL,
                        genLang: "ja",
                        askModel: { prompt in
                            let promptRef = Inf6PromptCatalog.assetsPromptBridgeJa
                            let rendered = try Inf6PromptGovernance.renderSystemUserPrompt(
                                ref: promptRef,
                                variables: ["task_prompt": prompt]
                            )
                            return try await Inf6LibraryView.askOpenAIText(
                                systemInstruction: rendered.systemInstruction,
                                userPrompt: rendered.userPrompt,
                                lang: "ja"
                            )
                        }
                    )

                    var entities: [Inf6DocEntity] = []
                    for bundle in bundles {
                        for item in bundle.pageResult.items {
                            let entityKind: Inf6DocEntityKind
                            if kind == "figures" {
                                guard item.kind == .figure || item.kind == .table else { continue }
                                entityKind = Inf6DocEntityKind(rawValue: item.kind.rawValue) ?? .figure
                            } else {
                                guard item.kind == .equation else { continue }
                                entityKind = .equation
                            }
                            entities.append(Inf6DocEntity(
                                kind: entityKind,
                                pageIndex: item.pageIndex,
                                title: item.titleLine,
                                snippet: item.evidence,
                                explanation: bundle.pageResult.renderedNotes
                                    .first(where: { $0.text.contains(item.titleLine.prefix(20)) })?.text
                            ))
                        }
                    }

                    if !entities.isEmpty {
                        let index = Inf6DocEntityIndex(pdfKey: pdfKey, entities: entities)
                        Inf6MetadataStore.putCodable(index, domain: .docEntities, key: pdfKey)
                        processed += 1
                    }
                } catch {
                    NSLog("[inf6] pipeline button: failed for %@: %@", paperID, error.localizedDescription)
                }
            }
            resultMessage = "完了: \(processed)件処理, \(skipped)件スキップ（抽出済み）"
        }
    }
}

private struct _FrontierDiffBanner: View {
    let diff: Inf6ExplanationDiff
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.orange)
                Text(L("フロンティア更新", "Frontier Update"))
                    .font(.system(size: fontSize - 2, weight: .bold))
                    .foregroundStyle(.orange)
            }
            Text(diff.summary)
                .font(.system(size: fontSize - 3))
                .foregroundStyle(.secondary)
            if let prev = diff.previousGeneratedAt {
                Text(L("前回生成: \(_formatDate(prev))", "Last generated: \(_formatDate(prev))"))
                    .font(.system(size: fontSize - 4))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func _formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.locale = Locale(identifier: "ja_JP")
        return f.string(from: date)
    }
}

private struct _FrontierAchievementBar: View {
    let achievement: Inf6FrontierAchievement
    let fontSize: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: achievement.overallScore)
                    .stroke(achievement.overallScore >= 1.0 ? Color.green : Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(achievement.percentText)
                    .font(.system(size: fontSize - 6, weight: .bold, design: .monospaced))
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(L("解説カバー率", "Coverage"))
                    .font(.system(size: fontSize - 3, weight: .semibold))
                Text(achievement.frontierGapText)
                    .font(.system(size: fontSize - 4))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct _PaperCardView: View {
    let card: Inf6LibraryView._OriginalExplanationContent.PaperCard
    let fontSize: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(card.label)
                    .font(.system(size: fontSize - 2, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                Text(card.title)
                    .font(.system(size: fontSize + 1, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
            _PaperStatusIcons(card: card, fontSize: fontSize)
            Image(systemName: "chevron.right")
                .font(.system(size: fontSize - 2))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }
}

private struct _PaperStatusIcons: View {
    let card: Inf6LibraryView._OriginalExplanationContent.PaperCard
    let fontSize: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            let hasPDF = card.hasLocalPDF
            let _ = card.hasEntities
            let hasFigs = card.sections.contains { $0.kind == "paper_figures" }
            let hasEqs = card.sections.contains { $0.kind == "paper_equations" }

            Image(systemName: hasPDF ? "doc.fill" : "arrow.down.doc")
                .font(.system(size: fontSize - 3))
                .foregroundStyle(hasPDF ? .green : .secondary.opacity(0.5))
                .help(hasPDF ? "PDF downloaded" : "PDF not downloaded")

            Image(systemName: hasFigs ? "photo.fill" : "photo")
                .font(.system(size: fontSize - 3))
                .foregroundStyle(hasFigs ? .orange : .secondary.opacity(0.5))
                .help(hasFigs ? "Figures extracted" : "No figures")

            Image(systemName: hasEqs ? "function" : "x.squareroot")
                .font(.system(size: fontSize - 3))
                .foregroundStyle(hasEqs ? .blue : .secondary.opacity(0.5))
                .help(hasEqs ? "Equations extracted" : "No equations")
        }
    }
}

private struct _ExplanationSectionView: View {
    let section: Inf6LibraryView._OriginalExplanationContent.Section
    let fontSize: CGFloat

    @State private var showExplainPanel = false
    @State private var explainKind: _OverviewExplainKind = .summarize
    @State private var explainResult: String?
    @State private var explainLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                #if canImport(UIKit)
                _SelectableExplanationText(
                    text: _inf6NaturalizedExplanationText(section.heading),
                    font: .systemFont(ofSize: fontSize + 4, weight: .bold),
                    color: kindUIColor
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                #else
                Text(section.heading)
                    .font(.system(size: fontSize + 4, weight: .bold))
                    .foregroundStyle(kindColor)
                Spacer()
                #endif

                if section.kind != "quiz" {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showExplainPanel.toggle()
                            if !showExplainPanel {
                                explainResult = nil
                                explainLoading = false
                            }
                        }
                    } label: {
                        Image(systemName: showExplainPanel ? "xmark.circle.fill" : "text.bubble")
                            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(16)))
                            .foregroundStyle(showExplainPanel ? .secondary : kindColor.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }

            if showExplainPanel {
                _OverviewExplainPanel(
                    kind: $explainKind,
                    result: explainResult,
                    isLoading: explainLoading,
                    fontSize: fontSize,
                    onRun: { _runExplain() }
                )
            }

            switch section.kind {
            case "paper_equations":
                _PaperEntitiesImageView(section: section, fontSize: fontSize, entityKinds: [.equation])
            case "formula":
                _FormulaBodyView(content: section.body, fontSize: fontSize)
            case "diagram":
                _DiagramBodyView(content: section.body, fontSize: fontSize)
            case "bullets":
                _BulletsBodyView(content: section.body, fontSize: fontSize)
            case "paper_figures":
                _PaperEntitiesImageView(section: section, fontSize: fontSize, entityKinds: [.figure, .table])
            case "table":
                _TableBodyView(content: section.body, fontSize: fontSize)
            case "quiz":
                _QuizEntityImageInline(pdfKey: section.pdfKey, entityId: section.entityId, heading: section.heading)
                _QuizBodyView(content: section.body, fontSize: fontSize, sectionKey: section.entityId ?? section.pdfKey)
            case "abstract":
                _AbstractBodyView(content: section.body, fontSize: fontSize)
            default:
                _TextBodyView(content: section.body, fontSize: fontSize)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kindBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func _runExplain() {
        guard !explainLoading else { return }
        explainLoading = true
        explainResult = nil
        let sectionBody = section.body
        let sectionHeading = section.heading
        let kind = explainKind
        Task { @MainActor in
            do {
                let systemInstruction: String
                let userPrompt: String
                switch kind {
                case .summarize:
                    systemInstruction = "学術テキストを簡潔に要約する専門家。日本語で回答。"
                    userPrompt = "以下のセクション「\(sectionHeading)」の内容を短く要約してください。前置き不要。\n\n\(sectionBody)"
                case .comment:
                    systemInstruction = "学術テキストに深い洞察を加える専門家。日本語で回答。"
                    userPrompt = "以下のセクション「\(sectionHeading)」にコメント・補足説明を付けてください。重要ポイント、背景、関連知識を簡潔に示してください。前置き不要。\n\n\(sectionBody)"
                case .explain:
                    systemInstruction = "学術用語・概念を平易に解説する専門家。日本語で回答。"
                    userPrompt = "以下のセクション「\(sectionHeading)」の意味を詳しく説明してください。前置き不要。\n\n\(sectionBody)"
                }
                let result = try await Inf6LibraryView.askOpenAIText(
                    systemInstruction: systemInstruction,
                    userPrompt: userPrompt,
                    lang: "ja"
                )
                explainResult = result
            } catch {
                explainResult = "エラー: \(error.localizedDescription)"
            }
            explainLoading = false
        }
    }

    private var kindColor: Color {
        switch section.kind {
        case "formula", "paper_equations": return Color(red: 0.12, green: 0.46, blue: 0.86)
        case "diagram": return Color(red: 0.00, green: 0.60, blue: 0.39)
        case "citation", "paper_overview": return Color(red: 0.58, green: 0.20, blue: 0.91)
        case "table", "paper_figures": return Color(red: 0.91, green: 0.36, blue: 0.04)
        case "quiz": return Color(red: 0.85, green: 0.16, blue: 0.50)
        case "abstract": return Color(red: 0.40, green: 0.40, blue: 0.45)
        default: return .primary
        }
    }

    #if canImport(UIKit)
    private var kindUIColor: UIColor {
        switch section.kind {
        case "formula", "paper_equations": return UIColor(red: 0.12, green: 0.46, blue: 0.86, alpha: 1)
        case "diagram": return UIColor(red: 0.00, green: 0.60, blue: 0.39, alpha: 1)
        case "citation", "paper_overview": return UIColor(red: 0.58, green: 0.20, blue: 0.91, alpha: 1)
        case "table", "paper_figures": return UIColor(red: 0.91, green: 0.36, blue: 0.04, alpha: 1)
        case "quiz": return UIColor(red: 0.85, green: 0.16, blue: 0.50, alpha: 1)
        case "abstract": return UIColor(red: 0.40, green: 0.40, blue: 0.45, alpha: 1)
        default: return .label
        }
    }
    #endif

    private var kindBackground: Color {
        switch section.kind {
        case "formula", "paper_equations": return Color(red: 0.86, green: 0.93, blue: 1.00).opacity(0.5)
        case "diagram": return Color(red: 0.86, green: 0.98, blue: 0.91).opacity(0.5)
        case "citation", "paper_overview": return Color(red: 0.96, green: 0.90, blue: 1.00).opacity(0.5)
        case "table", "paper_figures": return Color(red: 1.00, green: 0.93, blue: 0.84).opacity(0.5)
        case "quiz": return Color(red: 1.00, green: 0.90, blue: 0.95).opacity(0.5)
        case "abstract": return Color(uiColor: .tertiarySystemBackground)
        default: return Color(uiColor: .secondarySystemBackground)
        }
    }
}

private struct _FormulaPart {
    let text: String
    let isFormula: Bool
}

#if canImport(UIKit)
    private struct _SelectableExplanationText: UIViewRepresentable {
        final class IntrinsicTextView: UITextView {
            override var canBecomeFirstResponder: Bool {
                true
            }

            override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
                action == #selector(copy(_:))
                    || action == #selector(select(_:))
                    || action == #selector(selectAll(_:))
                    || action == #selector(_summarize(_:))
                    || action == #selector(_explain(_:))
                    || action == #selector(_comment(_:))
            }

            @objc func _summarize(_ sender: Any?) {
                _postExplainNotification(action: "summarize")
            }
            @objc func _explain(_ sender: Any?) {
                _postExplainNotification(action: "explain")
            }
            @objc func _comment(_ sender: Any?) {
                _postExplainNotification(action: "comment")
            }

            private func _postExplainNotification(action: String) {
                guard let range = selectedTextRange, !range.isEmpty else { return }
                guard let selected = text(in: range), !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                NotificationCenter.default.post(name: .inf6ExplainSelection, object: nil, userInfo: [
                    "text": selected,
                    "action": action
                ])
            }

            override func buildMenu(with builder: any UIMenuBuilder) {
                super.buildMenu(with: builder)

                let summarize = UIAction(title: "短く要約", image: UIImage(systemName: "text.quote")) { [weak self] _ in
                    self?._summarize(nil)
                }
                let explain = UIAction(title: "意味を説明", image: UIImage(systemName: "lightbulb")) { [weak self] _ in
                    self?._explain(nil)
                }
                let comment = UIAction(title: "コメント付き", image: UIImage(systemName: "bubble.left")) { [weak self] _ in
                    self?._comment(nil)
                }

                let aiMenu = UIMenu(title: "解説", image: UIImage(systemName: "sparkles"), children: [summarize, explain, comment])
                builder.insertChild(aiMenu, atStartOfMenu: .root)
            }

        override var intrinsicContentSize: CGSize {
            let w = bounds.width
            guard w > 1 else {
                return CGSize(width: UIView.noIntrinsicMetric, height: 1)
            }
            let size = sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
            return CGSize(width: UIView.noIntrinsicMetric, height: ceil(size.height))
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            invalidateIntrinsicContentSize()
        }
    }

    let text: String
    let font: UIFont
    let color: UIColor
    var lineSpacing: CGFloat = 0
    var maximumNumberOfLines: Int = 0
    var alignment: NSTextAlignment = .natural

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = IntrinsicTextView()
        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.isUserInteractionEnabled = true
        tv.backgroundColor = .clear
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.spellCheckingType = .no
        tv.smartDashesType = .no
        tv.smartQuotesType = .no
        tv.smartInsertDeleteType = .no
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.widthTracksTextView = true
        tv.textContainer.heightTracksTextView = false
        tv.dataDetectorTypes = []
        tv.setContentHuggingPriority(.required, for: .vertical)
        tv.setContentCompressionResistancePriority(.required, for: .vertical)
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        longPress.cancelsTouchesInView = false
        longPress.delegate = context.coordinator
        tv.addGestureRecognizer(longPress)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.alignment = alignment
        paragraph.lineBreakMode = maximumNumberOfLines > 0 ? .byTruncatingTail : .byWordWrapping
        uiView.textContainer.maximumNumberOfLines = maximumNumberOfLines
        uiView.textContainer.lineBreakMode = paragraph.lineBreakMode
        let next = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
        if uiView.attributedText != next {
            uiView.attributedText = next
        }
        uiView.setNeedsLayout()
        uiView.layoutIfNeeded()
        uiView.invalidateIntrinsicContentSize()
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        weak var textView: UITextView?

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            false
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began,
                  let textView = recognizer.view as? UITextView,
                  !textView.text.isEmpty else {
                return
            }
            textView.becomeFirstResponder()
            let point = recognizer.location(in: textView)
            guard let position = textView.closestPosition(to: point) else {
                textView.selectedRange = NSRange(location: 0, length: textView.text.count)
                return
            }
            if let range = textView.tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: UITextDirection.storage(.forward)) {
                textView.selectedTextRange = range
            } else {
                textView.selectedRange = NSRange(location: 0, length: textView.text.count)
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
#endif

private func _splitFormulaAndText(_ raw: String) -> [_FormulaPart] {
    let lines = raw.components(separatedBy: "\n")
    var parts: [_FormulaPart] = []
    var textBuffer: [String] = []

    func flushText() {
        let joined = textBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty { parts.append(_FormulaPart(text: joined, isFormula: false)) }
        textBuffer.removeAll()
    }

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        let hasOperator = trimmed.contains("=") || trimmed.contains("≈") || trimmed.contains("∑") || trimmed.contains("∏") || trimmed.contains("→")
        let isMathLike = hasOperator && trimmed.count < 120 && !trimmed.hasSuffix("。") && !trimmed.hasSuffix("す") && !trimmed.hasSuffix("た")
        if isMathLike {
            flushText()
            parts.append(_FormulaPart(text: trimmed, isFormula: true))
        } else {
            textBuffer.append(trimmed)
        }
    }
    flushText()
    return parts
}

private struct _FormulaBodyView: View {
    let content: String
    let fontSize: CGFloat

    var body: some View {
        let parts = _splitFormulaAndText(_inf6NaturalizedExplanationText(content))
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                if part.isFormula {
                    #if canImport(UIKit)
                    _SelectableExplanationText(
                        text: part.text,
                        font: .monospacedSystemFont(ofSize: fontSize + 1, weight: .bold),
                        color: .label,
                        alignment: .center
                    )
                    .padding(.vertical, 8)
                    #else
                    Text(part.text)
                        .font(.system(size: fontSize + 1, weight: .bold, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                    #endif
                } else {
                    #if canImport(UIKit)
                    _SelectableExplanationText(
                        text: part.text,
                        font: .systemFont(ofSize: fontSize - 1),
                        color: .label.withAlphaComponent(0.85)
                    )
                    #else
                    Text(part.text)
                        .font(.system(size: fontSize - 1))
                        .foregroundStyle(.primary.opacity(0.85))
                    #endif
                }
            }
        }
    }
}

private struct _DiagramBodyView: View {
    let content: String
    let fontSize: CGFloat

    var body: some View {
        let parts = _inf6NaturalizedExplanationText(content)
            .components(separatedBy: CharacterSet(charactersIn: "→"))
            .flatMap { $0.components(separatedBy: "->") }
            .flatMap { $0.components(separatedBy: "⇒") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if parts.count >= 2 {
	            ScrollView(.horizontal, showsIndicators: false) {
	                HStack(spacing: 4) {
	                    ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
	                        #if canImport(UIKit)
	                        _SelectableExplanationText(
	                            text: part,
	                            font: .systemFont(ofSize: fontSize - 3, weight: .semibold),
	                            color: .label,
	                            maximumNumberOfLines: 1
	                        )
	                        .padding(.horizontal, 12)
	                        .padding(.vertical, 8)
	                        .background(Color.accentColor.opacity(0.12))
	                        .clipShape(RoundedRectangle(cornerRadius: 8))
	                        #else
	                        Text(part)
	                            .font(.system(size: fontSize - 3, weight: .semibold))
	                            .padding(.horizontal, 12)
	                            .padding(.vertical, 8)
	                            .background(Color.accentColor.opacity(0.12))
	                            .clipShape(RoundedRectangle(cornerRadius: 8))
	                        #endif
	                        if i < parts.count - 1 {
	                            Image(systemName: "arrow.right")
	                                .font(.system(size: fontSize - 4, weight: .bold))
	                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        } else {
            #if canImport(UIKit)
            _SelectableExplanationText(
                text: _inf6NaturalizedExplanationText(content),
                font: .monospacedSystemFont(ofSize: fontSize - 2, weight: .regular),
                color: .label
            )
            #else
            Text(_inf6NaturalizedExplanationText(content))
                .font(.system(size: fontSize - 2, design: .monospaced))
            #endif
        }
    }
}

private struct _BulletsBodyView: View {
    let content: String
    let fontSize: CGFloat

    var body: some View {
        let items = _inf6NaturalizedExplanationText(content).components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { line in
                var s = line
                if s.hasPrefix("- ") || s.hasPrefix("• ") || s.hasPrefix("・") {
                    s = String(s.dropFirst(s.hasPrefix("・") ? 1 : 2))
                }
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Text("•")
                        .font(.system(size: fontSize, weight: .bold))
                        .foregroundStyle(.secondary)
                    #if canImport(UIKit)
                    _SelectableExplanationText(
                        text: item,
                        font: .systemFont(ofSize: fontSize),
                        color: .label
                    )
                    #else
                    Text(item)
                        .font(.system(size: fontSize))
                    #endif
                }
            }
        }
    }
}

private struct _TableBodyView: View {
    let content: String
    let fontSize: CGFloat

    var body: some View {
        #if canImport(UIKit)
        _SelectableExplanationText(
            text: _inf6NaturalizedExplanationText(content),
            font: .monospacedSystemFont(ofSize: fontSize - 2, weight: .regular),
            color: .label
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        #else
        Text(_inf6NaturalizedExplanationText(content))
            .font(.system(size: fontSize - 2, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
        #endif
    }
}

private struct _PaperEntitiesImageView: View {
    let section: Inf6LibraryView._OriginalExplanationContent.Section
    let fontSize: CGFloat
    let entityKinds: Set<Inf6DocEntityKind>

    var body: some View {
        let metadata = _loadEntityMetadata()
        if metadata.isEmpty {
            _PaperEntitiesTextView(content: section.body, fontSize: fontSize, icon: entityKinds.contains(.equation) ? "function" : "photo")
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(metadata.enumerated()), id: \.offset) { _, meta in
                    _LazyEntityRowView(meta: meta, fontSize: fontSize)
                }
            }
        }
    }

    struct _EntityMeta {
        let entityId: UUID
        let pdfKey: String
        let title: String
        let kind: Inf6DocEntityKind
        let snippet: String
        let explanation: String?
        let imagePath: String?
    }

    private func _loadEntityMetadata() -> [_EntityMeta] {
        let resolvedPdfKey: String
        if let key = section.pdfKey, !key.isEmpty {
            resolvedPdfKey = key
        } else if let paperID = section.paperID,
                  let paper = Inf6MetadataStore.getCodable(Inf6CorePaper.self, domain: .papers, key: paperID) {
            resolvedPdfKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paper.titleEn ?? paper.title)
        } else {
            return []
        }
        guard let index = Inf6MetadataStore.getCodable(Inf6DocEntityIndex.self, domain: .docEntities, key: resolvedPdfKey) else {
            return []
        }

        var items: [_EntityMeta] = []
        for entity in index.entities where entityKinds.contains(entity.kind) {
            items.append(_EntityMeta(
                entityId: entity.id,
                pdfKey: resolvedPdfKey,
                title: entity.title,
                kind: entity.kind,
                snippet: entity.snippet,
                explanation: entity.explanation,
                imagePath: entity.imagePath
            ))
            if items.count >= 30 { break }
        }
        return items
    }
}

private struct _LazyEntityRowView: View {
    let meta: _PaperEntitiesImageView._EntityMeta
    let fontSize: CGFloat
    @State private var image: UIImage?
    @State private var loaded = false
    @State private var editingTitle = false
    @State private var editingExplanation = false
    @State private var editTitleText = ""
    @State private var editExplanationText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: meta.kind == .equation ? "function" : (meta.kind == .table ? "tablecells" : "photo"))
                    .font(.system(size: fontSize - 3))
                    .foregroundStyle(.secondary)

                if editingTitle {
                    TextField("タイトル", text: $editTitleText)
                        .font(.system(size: fontSize - 1, weight: .semibold))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { _saveTitle() }
                    Button { _saveTitle() } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                    Button { editingTitle = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    #if canImport(UIKit)
                    _SelectableExplanationText(
                        text: _inf6NaturalizedExplanationText(meta.title),
                        font: .systemFont(ofSize: fontSize - 1, weight: .semibold),
                        color: .label,
                        maximumNumberOfLines: 2
                    )
                    #else
                    Text(meta.title)
                        .font(.system(size: fontSize - 1, weight: .semibold))
                    #endif
                    Button {
                        editTitleText = meta.title
                        editingTitle = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: fontSize - 4))
                            .foregroundStyle(.secondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }

            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                    )
            } else if meta.imagePath != nil && !loaded {
                ProgressView()
                    .frame(height: 100)
                    .frame(maxWidth: .infinity)
            }

            if editingExplanation {
                VStack(alignment: .leading, spacing: 4) {
                    TextEditor(text: $editExplanationText)
                        .font(.system(size: fontSize - 2))
                        .frame(minHeight: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                    HStack {
                        Button { _saveExplanation() } label: {
                            Label("保存", systemImage: "checkmark.circle.fill")
                                .font(.system(size: fontSize - 2))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        Button { editingExplanation = false } label: {
                            Label("キャンセル", systemImage: "xmark")
                                .font(.system(size: fontSize - 2))
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                HStack(alignment: .top) {
                    VStack(alignment: .leading) {
                        if let explanation = meta.explanation, !explanation.isEmpty {
                            #if canImport(UIKit)
                            _SelectableExplanationText(
                                text: _inf6NaturalizedExplanationText(explanation),
                                font: .systemFont(ofSize: fontSize - 2),
                                color: .label.withAlphaComponent(0.85),
                                lineSpacing: 3
                            )
                            #else
                            Text(_inf6NaturalizedExplanationText(explanation))
                                .font(.system(size: fontSize - 2))
                                .foregroundStyle(.primary.opacity(0.85))
                                .lineSpacing(3)
                            #endif
                        } else if !meta.snippet.isEmpty {
                            #if canImport(UIKit)
                            _SelectableExplanationText(
                                text: _inf6NaturalizedExplanationText(meta.snippet),
                                font: .systemFont(ofSize: fontSize - 2),
                                color: .secondaryLabel,
                                maximumNumberOfLines: 3
                            )
                            #else
                            Text(_inf6NaturalizedExplanationText(meta.snippet))
                                .font(.system(size: fontSize - 2))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                            #endif
                        }
                    }
                    Spacer(minLength: 4)
                    Button {
                        editExplanationText = meta.explanation ?? meta.snippet
                        editingExplanation = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: fontSize - 4))
                            .foregroundStyle(.secondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear {
            guard !loaded, let path = meta.imagePath else { return }
            loaded = true
            DispatchQueue.global(qos: .userInitiated).async {
                let url = Inf6LibraryView._entityImagesBaseURL().appendingPathComponent(path)
                let img = Self._downsampledImage(at: url, maxPixelSize: 1600)
                DispatchQueue.main.async { image = img }
            }
        }
        .onDisappear {
            image = nil
        }
    }

    private func _saveTitle() {
        let newTitle = editTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newTitle.isEmpty else { return }
        _updateEntity { $0.title = newTitle }
        editingTitle = false
    }

    private func _saveExplanation() {
        let newText = editExplanationText.trimmingCharacters(in: .whitespacesAndNewlines)
        _updateEntity { $0.explanation = newText.isEmpty ? nil : newText }
        editingExplanation = false
    }

    private func _updateEntity(_ mutate: (inout Inf6DocEntity) -> Void) {
        guard var index = Inf6MetadataStore.getCodable(Inf6DocEntityIndex.self, domain: .docEntities, key: meta.pdfKey) else { return }
        guard let idx = index.entities.firstIndex(where: { $0.id == meta.entityId }) else { return }
        mutate(&index.entities[idx])
        index.entities[idx].updatedAt = Date().timeIntervalSince1970
        Inf6MetadataStore.putCodable(index, domain: .docEntities, key: meta.pdfKey)
    }

    private static func _downsampledImage(at url: URL, maxPixelSize: CGFloat) -> UIImage? {
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, opts as CFDictionary) else { return nil }
        let downsampleOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOpts as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private struct _PaperEntitiesTextView: View {
    let content: String
    let fontSize: CGFloat
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let blocks = _inf6NaturalizedExplanationText(content).components(separatedBy: "\n\n")
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let parts = trimmed.split(separator: "\n", maxSplits: 1)
	                    VStack(alignment: .leading, spacing: 4) {
	                        HStack(spacing: 4) {
	                            Image(systemName: icon)
	                                .font(.system(size: fontSize - 3))
	                                .foregroundStyle(.secondary)
	                            #if canImport(UIKit)
	                            _SelectableExplanationText(
	                                text: _inf6NaturalizedExplanationText(String(parts[0])),
                                font: .systemFont(ofSize: fontSize - 1, weight: .semibold),
                                color: .label
                            )
                            #else
                            Text(_inf6NaturalizedExplanationText(String(parts[0])))
                                .font(.system(size: fontSize - 1, weight: .semibold))
                                .textSelection(.enabled)
                            #endif
                        }
                        if parts.count > 1 {
                            #if canImport(UIKit)
                            _SelectableExplanationText(
                                text: _inf6NaturalizedExplanationText(String(parts[1])),
                                font: .systemFont(ofSize: fontSize - 2),
                                color: .secondaryLabel,
                                maximumNumberOfLines: 4
                            )
                            #else
                            Text(_inf6NaturalizedExplanationText(String(parts[1])))
                                .font(.system(size: fontSize - 2))
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                            #endif
                        }
                    }
                }
            }
        }
    }
}

private struct _AbstractBodyView: View {
    let content: String
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: fontSize - 4))
                    .foregroundStyle(.secondary)
            Text("Abstract (原文)")
                .font(.system(size: fontSize - 3, weight: .semibold))
                .foregroundStyle(.secondary)
            }
            #if canImport(UIKit)
            _SelectableExplanationText(
                text: _inf6NaturalizedExplanationText(content),
                font: .italicSystemFont(ofSize: fontSize - 2),
                color: .label,
                lineSpacing: 4
            )
            #else
            Text(_inf6NaturalizedExplanationText(content))
                .font(.system(size: fontSize - 2))
                .italic()
                .lineSpacing(4)
            #endif
        }
    }
}

private struct _QuizEntityImageInline: View {
    let pdfKey: String?
    let entityId: String?
    var heading: String? = nil
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 0) {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    }
            }
        }
        .task {
            guard image == nil else { return }
            guard let pdfKey, !pdfKey.isEmpty else { return }
            guard let index = Inf6MetadataStore.getCodable(Inf6DocEntityIndex.self, domain: .docEntities, key: pdfKey) else { return }
            var entity: Inf6DocEntity?
            if let entityId, let uuid = UUID(uuidString: entityId) {
                entity = index.entities.first(where: { $0.id == uuid })
            }
            if entity == nil, let heading, let bracketMatch = heading.range(of: #"\[(?:図|表|式|fig|table|eq)[:\s]+(.+?)\]"#, options: [.regularExpression, .caseInsensitive]) {
                let bracket = String(heading[bracketMatch])
                if let colonIdx = bracket.firstIndex(of: ":") ?? bracket.firstIndex(of: "：") {
                    let title = bracket[bracket.index(after: colonIdx)...].trimmingCharacters(in: CharacterSet(charactersIn: " ]"))
                    entity = index.entities.first(where: { $0.title == title })
                }
            }
            guard let entity, let imagePath = entity.imagePath else { return }
            let url = Inf6LibraryView._entityImagesBaseURL().appendingPathComponent(imagePath)
            if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
                image = img
            }
        }
    }
}

private struct _QuizBodyView: View {
    let content: String
    let fontSize: CGFloat
    var sectionKey: String? = nil
    @State private var revealedAnswers: Set<Int> = []

    var body: some View {
        let questions = _parseQuizQuestions(content)
        VStack(alignment: .leading, spacing: 20) {
	            ForEach(Array(questions.enumerated()), id: \.offset) { idx, q in
	                VStack(alignment: .leading, spacing: 8) {
	                    #if canImport(UIKit)
	                    _SelectableExplanationText(
	                        text: _inf6NaturalizedExplanationText(q.questionText),
	                        font: .systemFont(ofSize: fontSize, weight: .semibold),
	                        color: .label
	                    )
	                    #else
	                    Text(q.questionText)
	                        .font(.system(size: fontSize, weight: .semibold))
	                    #endif
	                    ForEach(Array(q.choices.enumerated()), id: \.offset) { _, choice in
	                        let isCorrect = revealedAnswers.contains(idx) && q.correctLabel == choice.label
	                        HStack(alignment: .top, spacing: 8) {
                            Text(choice.label + ")")
	                                .font(.system(size: fontSize - 1, weight: .bold, design: .monospaced))
	                                .foregroundStyle(isCorrect ? Color.green : .secondary)
	                                .fixedSize()
		                                .frame(minWidth: 28, alignment: .leading)
	                            #if canImport(UIKit)
	                            _SelectableExplanationText(
	                                text: _inf6NaturalizedExplanationText(choice.text),
	                                font: .systemFont(ofSize: fontSize - 1),
	                                color: isCorrect ? .systemGreen : .label
	                            )
	                            #else
	                            Text(choice.text)
	                                .font(.system(size: fontSize - 1))
	                                .foregroundStyle(isCorrect ? Color.green : .primary)
	                            #endif
	                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 8)
                        .background(isCorrect ? Color.green.opacity(0.12) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
	                    if revealedAnswers.contains(idx) {
	                        #if canImport(UIKit)
	                        _SelectableExplanationText(
	                            text: _inf6NaturalizedExplanationText(q.explanation),
	                            font: .systemFont(ofSize: fontSize - 2),
	                            color: .secondaryLabel
	                        )
	                        .padding(.top, 4)
	                        #else
	                        Text(q.explanation)
	                            .font(.system(size: fontSize - 2))
	                            .foregroundStyle(.secondary)
	                            .padding(.top, 4)
	                        #endif
                    } else {
                        Button {
                            withAnimation { _ = revealedAnswers.insert(idx) }
                            if let key = sectionKey {
                                _recordQuizAttempt(sectionKey: key, questionIndex: idx)
                            }
                        } label: {
                            Label(L("正解を表示", "Show Answer"), systemImage: "eye")
                                .font(.system(size: fontSize - 2))
                        }
                        .buttonStyle(.bordered)
                        .tint(.pink)
                        .padding(.top, 4)
                    }
                }
                if idx < questions.count - 1 {
                    Divider()
                }
            }
        }
    }

    private struct _QuizQuestion {
        let questionText: String
        let choices: [(label: String, text: String)]
        let correctLabel: String
        let explanation: String
    }

    private func _parseQuizQuestions(_ raw: String) -> [_QuizQuestion] {
        let blocks = raw.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var questions: [_QuizQuestion] = []
        var currentLines: [String] = []

        func flushQuestion() {
            guard !currentLines.isEmpty else { return }
            var qText = ""
            var choices: [(String, String)] = []
            var correctLabel = ""
            var explanation = ""
            for line in currentLines {
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { continue }
                if t.range(of: #"^Q\d+\."#, options: .regularExpression) != nil {
                    qText = String(t.drop(while: { $0 != "." }).dropFirst()).trimmingCharacters(in: .whitespaces)
                } else if t.range(of: #"^[A-D]\)"#, options: .regularExpression) != nil {
                    let label = String(t.prefix(1))
                    let text = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    choices.append((label, text))
                } else if t.hasPrefix("正解:") || t.hasPrefix("正解：") {
                    let answer = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    if let first = answer.first, "ABCD".contains(first) {
                        correctLabel = String(first)
                    }
                    if let dotIdx = answer.firstIndex(of: "。") {
                        explanation = String(answer[answer.index(after: dotIdx)...]).trimmingCharacters(in: .whitespaces)
                        if explanation.isEmpty {
                            explanation = String(answer.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                        }
                    } else {
                        explanation = String(answer.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    }
                } else if qText.isEmpty {
                    qText = t
                }
            }
            if !qText.isEmpty && !choices.isEmpty {
                questions.append(_QuizQuestion(questionText: qText, choices: choices, correctLabel: correctLabel, explanation: explanation))
            }
            currentLines.removeAll()
        }

        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            for line in lines {
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.range(of: #"^Q\d+\."#, options: .regularExpression) != nil && !currentLines.isEmpty {
                    flushQuestion()
                }
                currentLines.append(t)
            }
        }
        flushQuestion()
        return questions
    }

    private func _recordQuizAttempt(sectionKey: String, questionIndex: Int) {
        var attempted: Set<Int> = []
        if let json = Inf6MetadataStore.get(domain: .quizAttempts, key: sectionKey),
           let data = json.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [Int] {
            attempted = Set(arr)
        }
        attempted.insert(questionIndex)
        if let data = try? JSONSerialization.data(withJSONObject: Array(attempted).sorted()),
           let json = String(data: data, encoding: .utf8) {
            Inf6MetadataStore.put(domain: .quizAttempts, key: sectionKey, json: json)
        }
    }
}

private struct _TextBodyView: View {
    let content: String
    let fontSize: CGFloat

    var body: some View {
        let parts = _splitFormulaAndText(_inf6NaturalizedExplanationText(content))
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                if part.isFormula {
                    #if canImport(UIKit)
                    _SelectableExplanationText(
                        text: part.text,
                        font: .monospacedSystemFont(ofSize: fontSize, weight: .bold),
                        color: .label,
                        alignment: .center
                    )
                    .padding(.vertical, 6)
                    #else
                    Text(part.text)
                        .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 6)
                    #endif
                } else {
                    #if canImport(UIKit)
                    _SelectableExplanationText(
                        text: part.text,
                        font: .systemFont(ofSize: fontSize),
                        color: .label,
                        lineSpacing: 4
                    )
                    #else
                    Text(part.text)
                        .font(.system(size: fontSize))
                        .lineSpacing(4)
                    #endif
                }
            }
        }
    }
}

// MARK: - 概要解説マルチウィンドウ

struct Inf6ExplanationWindowView: View {
    let rawID: String
    var onLoadStateChange: ((Bool, String?) -> Void)? = nil
    @State private var content: Inf6LibraryView._OriginalExplanationContent?
    @State private var title: String = ""
    @State private var fontSize: CGFloat = 24
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let content = content {
                _OriginalExplanationOverlayView(title: title, content: content, fontSize: $fontSize, entitySidebar: .constant(nil)) {}
            } else if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                    Text(Inf6Lang.text("ノード解説を読み込み中…", "Loading node explanation…"))
                        .foregroundStyle(.secondary)
                }
            } else if let err = errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(err)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            onLoadStateChange?(false, nil)
            let storedFontSize = await Task.detached(priority: .utility) {
                guard let raw = Inf6MetadataStore.get(domain: .settings, key: "explanation_font_size"),
                      let value = Double(raw) else { return CGFloat? (nil) }
                return CGFloat(value)
            }.value
            guard !Task.isCancelled else { return }
            if let storedFontSize {
                fontSize = storedFontSize
            }
            await _load()
        }
    }

    private func _load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let prefix = "inf6-explanation:"
            guard rawID.hasPrefix(prefix) else {
                errorMessage = "Invalid rawID"
                return
            }
            let payload = String(rawID.dropFirst(prefix.count))
            guard let sep = payload.firstIndex(of: ":") else {
                errorMessage = "Invalid rawID format"
                return
            }
            let sourceFamily = String(payload[..<sep])
            let nodeID = String(payload[payload.index(after: sep)...])

            if let json = Inf6MetadataStore.get(domain: .generatedExplanations, key: rawID),
               let data = json.data(using: .utf8),
               let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let storedTitle = stored["title"] as? String,
               !storedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                title = storedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let structureJSON = Inf6MetadataStore.listByPrefix(domain: .syllabus, prefix: "structure:\(sourceFamily)#")
            for item in structureJSON {
                guard let data = item.json.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let nodes = root["nodes"] as? [[String: Any]] else { continue }
                for node in nodes {
                    if (node["node_id"] as? String) == nodeID {
                        title = (node["title"] as? String) ?? nodeID
                        break
                    }
                }
            }
            if title.isEmpty { title = nodeID }

            do {
                content = try Inf6LibraryView()._loadOriginalExplanationContent(rawID: rawID)
                onLoadStateChange?(true, nil)
            } catch {
                errorMessage = error.localizedDescription
                onLoadStateChange?(false, error.localizedDescription)
            }
        }
    }
}

// MARK: - Overview Explain Panel

private enum _OverviewExplainKind: String {
    case summarize, comment, explain
}

private struct _OverviewExplainPanel: View {
    @Binding var kind: _OverviewExplainKind
    let result: String?
    let isLoading: Bool
    let fontSize: CGFloat
    let onRun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("何をしますか", "What should be done?"))
                .font(.subheadline.weight(.semibold))

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Inf6ExplainChoiceChipView(
                        title: L("短く要約", "Summarize"),
                        systemImage: "doc.text.magnifyingglass",
                        tint: .blue,
                        selected: kind == .summarize,
                        enabled: true
                    ) { kind = .summarize }

                    Inf6ExplainChoiceChipView(
                        title: L("コメント付き", "Comment"),
                        systemImage: "text.bubble",
                        tint: .indigo,
                        selected: kind == .comment,
                        enabled: true
                    ) { kind = .comment }
                }

                HStack(spacing: 8) {
                    Inf6ExplainChoiceChipView(
                        title: L("意味を説明", "Explain"),
                        systemImage: "character.book.closed",
                        tint: .mint,
                        selected: kind == .explain,
                        enabled: true
                    ) { kind = .explain }

                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 68)
                        .allowsHitTesting(false)
                }
            }

            Button {
                onRun()
            } label: {
                HStack {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(_buttonLabel)
                        .font(.system(size: fontSize, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(isLoading)

            if let result {
                Divider()
                #if canImport(UIKit)
                _SelectableExplanationText(
                    text: _inf6NaturalizedExplanationText(result),
                    font: .systemFont(ofSize: fontSize - 1),
                    color: .label.withAlphaComponent(0.9),
                    lineSpacing: 3
                )
                #else
                Text(result)
                    .font(.system(size: fontSize - 1))
                    .lineSpacing(3)
                #endif
            }
        }
        .padding(12)
        .background(Color(uiColor: .tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var _buttonLabel: String {
        switch kind {
        case .summarize: return L("このセクションを要約する", "Summarize this section")
        case .comment: return L("コメントを生成する", "Generate comment")
        case .explain: return L("意味を説明する", "Explain meaning")
        }
    }
}

// MARK: - Quiz Regenerate Sheet


// MARK: - Generated Artifact Maintenance


// MARK: - 初回の保存先設定

/// 初めて起動したときに、保存 root を選んでもらう。
struct Inf6InitialStorageSetupView: View {
    @Binding var isPresented: Bool
    @State private var showFolderPicker = false
    @State private var chosenPath: String? = Inf6EntityImageLocation.displayPath
    @State private var selectedPathIsUsable: Bool = Inf6EntityImageLocation.resolvedURL() != nil
    @State private var rootSelectionError: String?

    private func L(_ ja: String, _ en: String) -> String { Inf6Lang.text(ja, en) }

    private var chosenFolderLabel: String {
        guard let chosenPath, !chosenPath.isEmpty else {
            return L("保存先が未選択です", "No storage folder selected")
        }
        let name = URL(fileURLWithPath: chosenPath).lastPathComponent
        return name.isEmpty ? L("選択済みの保存先", "Selected storage folder") : name
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(L("保存先を選んでください", "Choose a storage folder"))
                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(26), weight: .bold))

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("現在の保存先", "Current folder"))
                            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(13), weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(chosenFolderLabel)
                            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(15), weight: .medium))
                        if chosenPath != nil && !selectedPathIsUsable {
                            Text(L("この端末では使えません。ここで選び直してください。", "This folder is unavailable on this device. Choose it again here."))
                                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(13), weight: .semibold))
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Button {
                        showFolderPicker = true
                    } label: {
                        Label(
                            L("フォルダを選ぶ", "Choose a folder"),
                            systemImage: "externaldrive"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    if let rootSelectionError {
                        Text(rootSelectionError)
                            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(13), weight: .semibold))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }

                }
                .padding(28)
                .frame(maxWidth: 720, alignment: .leading)
            }
            .navigationTitle(L("初期設定", "Initial setup"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // 選ぶまで進ませない。ここを飛ばせると、追い出される場所に
                    // 置いたまま使い続けることになり、図が表示できない。
                    Button(chosenPath == nil
                           ? L("この保存先で始める", "Start with this folder")
                           : L("閉じる", "Close")) {
                        isPresented = false
                    }
                    .disabled(chosenPath == nil || !selectedPathIsUsable)
                }
            }
            .fileImporter(
                isPresented: $showFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                showFolderPicker = false
                switch result {
                case .success(let urls):
                    guard let url = urls.first else {
                        rootSelectionError = L("保存先フォルダが選択されませんでした。", "No storage folder was selected.")
                        return
                    }
                    let started = url.startAccessingSecurityScopedResource()
                    defer { if started { url.stopAccessingSecurityScopedResource() } }
                    do {
                        try Inf6EntityImageLocation.set(url)
                        chosenPath = Inf6EntityImageLocation.displayPath
                        selectedPathIsUsable = Inf6EntityImageLocation.resolvedURL() != nil
                        rootSelectionError = nil
                    } catch {
                        rootSelectionError = error.localizedDescription
                    }
                case .failure(let error):
                    rootSelectionError = L("保存先フォルダを選べませんでした: \(error.localizedDescription)", "Could not select the storage folder: \(error.localizedDescription)")
                }
            } onCancellation: {
                showFolderPicker = false
            }
            .onAppear {
                chosenPath = Inf6EntityImageLocation.displayPath
                selectedPathIsUsable = Inf6EntityImageLocation.resolvedURL() != nil
            }
        }
    }
}
