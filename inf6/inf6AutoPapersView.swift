
//
//  inf6AutoPapersView.swift
//  inf6
//
//  Created by decopin on 2025/11/27.
//



import Foundation

#if canImport(WebKit)
import WebKit
#endif

#if canImport(PDFKit)
import PDFKit
#endif

#if canImport(UIKit)
import UIKit
#endif

#if canImport(SwiftUI)


import SwiftUI

enum Inf6AutoPapersEntryMode: Hashable {
    case qualifications
    case paperCollection
    /// JDLA G検定など AI 系資格のみを表示するモード。
    case aiCertifications
    /// Microsoft Learn など IT 系資格のみを表示するモード。
    case itCertifications

    var navigationTitle: String {
        switch self {
        case .qualifications:
            return "inf6"
        case .paperCollection:
            return Inf6Lang.text("論文収集", "Paper Collection")
        case .aiCertifications:
            return Inf6Lang.text("AI 資格", "AI")
        case .itCertifications:
            return Inf6Lang.text("IT 資格", "IT")
        }
    }

    /// 画面内でカテゴリフィルタとして使う学校カテゴリ。nil = すべて表示。
    var schoolCategoryFilter: Inf6SchoolCategory? {
        switch self {
        case .aiCertifications: return .ai
        case .itCertifications: return .it
        default: return nil
        }
    }
}

/// シラバス一覧から、対応する論文セットを取得するビュー。
/// 旧タクソノミー UI を廃止し、分かりやすい「シラバス一覧＋ダウンローのみに絞る。
struct Inf6AutoPapersView: View {
    let entryMode: Inf6AutoPapersEntryMode
    var onClose: (() -> Void)?

    // MARK: - UI labels
    // Menu strings are provided by Inf6ProperNouns / compass.default.yaml.
    // No local fallback config is defined here.
    static var cachedExploreCoursesByDepartment: [String: [Inf6StanfordSyllabus]] = [:]
    static var cachedSchools: [ECSchool] = []
    static var didAttemptAutoLabels = false
    // Persisted guard so GPT label generation does not run on every app launch.
    // If the user wants to regenerate labels, they should use an explicit UI action.
    static let autoLabelsGeneratedFlagKey = "inf6_taxonomy_labels_generated_v1"

    // MARK: - Type bridging (legacy nested type names)
    // Keep old call sites that refer to `Inf6AutoPapersView.SyllabusSource` buildable,
    // while using the single canonical enum `Inf6SyllabusSource`.
    typealias SyllabusSource = Inf6SyllabusSource
    typealias LegacySyllabusRoot = Inf6SyllabusRoot



    // MARK: - Persistent cache (Application Support)
    enum _CacheIOError: LocalizedError {
        case readCoordinationFailed(NSError)
        case readFailed(Error)
        case writeCoordinationFailed(NSError)
        case writeFailed(Error)
        case readProducedNilData

        var errorDescription: String? {
            switch self {
            case .readCoordinationFailed(let e):
                return "Cache read coordination failed: \(e.localizedDescription)"
            case .readFailed(let e):
                return "Cache read failed: \(e.localizedDescription)"
            case .writeCoordinationFailed(let e):
                return "Cache write coordination failed: \(e.localizedDescription)"
            case .writeFailed(let e):
                return "Cache write failed: \(e.localizedDescription)"
            case .readProducedNilData:
                return "Cache read produced nil data."
            }
        }
    }

    static func _readFileDataCoordinated(_ url: URL) throws -> Data {
        var out: Data? = nil
        var coordError: NSError? = nil
        var readError: Error? = nil

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            do {
                out = try Inf6SafeFileRead.data(at: readURL)
            } catch {
                readError = error
                out = nil
            }
        }

        if let coordError {
            throw _CacheIOError.readCoordinationFailed(coordError)
        }
        if let readError {
            throw _CacheIOError.readFailed(readError)
        }
        guard let out else {
            throw _CacheIOError.readProducedNilData
        }
        return out
    }

    static func _writeFileDataCoordinated(_ url: URL, data: Data) throws {
        var coordError: NSError? = nil
        var writeError: Error? = nil

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { writeURL in
            do {
                try data.write(to: writeURL, options: [.atomic])
            } catch {
                writeError = error
            }
        }

        if let coordError {
            throw _CacheIOError.writeCoordinationFailed(coordError)
        }
        if let writeError {
            throw _CacheIOError.writeFailed(writeError)
        }
    }

    func _appendStatusWarning(_ ja: String, _ en: String) {
        let msg = Inf6Lang.text(ja, en)
        if statusMessage.isEmpty {
            statusMessage = msg
        } else {
            statusMessage += "\n" + msg
        }
    }
    // NOTE: the existing `cached*` properties are process-memory only.
    // This disk cache prevents re-fetching remote ExploreCourses data on every app launch.
    static func _cacheDirectoryURL() -> URL? {
        do {
            let dir = Inf6DataRoot.url().appendingPathComponent("cache", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            return dir
        } catch {
            print("[Inf6AutoPapers] cache dir error: \(error)")
            return nil
        }
    }

    static func _schoolsCacheURL() -> URL? {
        return _cacheDirectoryURL()?.appendingPathComponent("explorecourses_schools").appendingPathExtension("json")
    }

    static func _syllabiCacheURL(dept: String) -> URL? {
        let trimmed = dept.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_"))
        let mapped = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let safe = String(mapped)
        return _cacheDirectoryURL()?.appendingPathComponent("explorecourses_syllabi_\(safe)").appendingPathExtension("json")
    }

    static func loadCachedSchoolsFromDisk() -> (schools: [ECSchool]?, error: Error?) {
        guard let url = _schoolsCacheURL() else { return (nil, nil) }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return (nil, nil) }

        do {
            let data = try _readFileDataCoordinated(url)
            let decoded = try JSONDecoder().decode([ECSchool].self, from: data)
            return (decoded.isEmpty ? nil : decoded, nil)
        } catch {
            print("[Inf6AutoPapers] schools cache load failed (appSupport): \(error)")
            return (nil, error)
        }
    }

    static func saveSchoolsCacheToDisk(_ schools: [ECSchool]) -> Error? {
        guard !schools.isEmpty else { return nil }
        guard let url = _schoolsCacheURL() else {
            let err = NSError(domain: "Inf6AutoPapers.Cache", code: 1, userInfo: [NSLocalizedDescriptionKey: "cache directory unavailable"])
            print("[Inf6AutoPapers] schools cache save failed: \(err.localizedDescription)")
            return err
        }

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            let data = try JSONEncoder().encode(schools)
            try _writeFileDataCoordinated(url, data: data)
            return nil
        } catch {
            print("[Inf6AutoPapers] schools cache save failed: \(error)")
            return error
        }
    }

    static func loadCachedSyllabiFromDisk(dept: String) -> (items: [Inf6StanfordSyllabus]?, error: Error?) {
        guard let url = _syllabiCacheURL(dept: dept) else { return (nil, nil) }
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, nil) }
        do {
            let data = try _readFileDataCoordinated(url)
            let decoded = try JSONDecoder().decode([Inf6StanfordSyllabus].self, from: data)
            if !decoded.isEmpty {
                let code = dept.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                print("[Inf6AutoPapers] loaded syllabi cache dept=\(code) count=\(decoded.count)")
            }
            return (decoded.isEmpty ? nil : decoded, nil)
        } catch {
            print("[Inf6AutoPapers] syllabi cache load failed: \(error)")
            return (nil, error)
        }
    }

    static func saveSyllabiCacheToDisk(dept: String, items: [Inf6StanfordSyllabus]) -> Error? {
        guard let url = _syllabiCacheURL(dept: dept) else {
            let err = NSError(domain: "Inf6AutoPapers.Cache", code: 2, userInfo: [NSLocalizedDescriptionKey: "cache directory unavailable"])
            print("[Inf6AutoPapers] syllabi cache save failed: \(err.localizedDescription)")
            return err
        }
        do {
            let data = try JSONEncoder().encode(items)
            try _writeFileDataCoordinated(url, data: data)
            let code = dept.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            print("[Inf6AutoPapers] saved syllabi cache dept=\(code) count=\(items.count)")
            return nil
        } catch {
            print("[Inf6AutoPapers] syllabi cache save failed: \(error)")
            return error
        }
    }
    
    
    
    /// ローカル YAML からシラバス一覧を生成する（固有名詞なしの汎用ローダ）。
    /// - Parameter resourceBaseName: Bundle に含まれる YAML リソースのベース名（拡張子を除く）。
    /// - Returns: 生成した Inf6StanfordSyllabus 一覧（失敗時は空配列）。
    @MainActor
    public func loadLocalSyllabi(resourceBaseName: String) -> [Inf6StanfordSyllabus] {
        func splitLabel(_ raw: String) -> (title: String, detail: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return ("", "") }
            let separators: [String] = [" - ", " — ", " – "]
            for sep in separators {
                if let range = trimmed.range(of: sep) {
                    let head = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let tail = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !head.isEmpty {
                        return (head, tail)
                    }
                }
            }
            return (trimmed, "")
        }

        // Swift-native fallback (compass.default.swift pure-data).
        var result: [Inf6StanfordSyllabus] = []
        for school in Inf6CompassDefaultConfig.schools {
            let schoolLabel = Inf6Lang.text(school.labelJa, school.labelEn)
            for fac in school.faculties {
                let facLabel = Inf6Lang.text(fac.labelJa, fac.labelEn)
                for dept in fac.departments {
                    let deptKey = dept.key.trimmingCharacters(in: .whitespacesAndNewlines)
                    let localized = Inf6Lang.text(dept.labelJa, dept.labelEn)
                    let split = splitLabel(localized)
                    result.append(
                        Inf6StanfordSyllabus(
                            id: deptKey.isEmpty ? split.title : deptKey,
                            code: "",
                            title: split.title,
                            detail: split.detail,
                            department: facLabel.isEmpty ? schoolLabel : facLabel,
                            level: schoolLabel,
                            manifestRef: dept.homeURLString
                        )
                    )
                }
            }
        }
        return result
    }

    // MARK: - Branding (definition-file driven)
    @State var branding: Inf6CompassBranding = .defaultInf6

    func log(_ message: String) {
        let prefix = "[Inf6AutoPapers]"
        if branding.logPrefix.isEmpty {
            print("\(prefix) \(message)")
        } else {
            print("\(branding.logPrefix) \(prefix) \(message)")
        }
    }
    @Environment(\.dismiss) var dismiss
    @State private var _dismissReady = false

    @State var selectedSource: SyllabusSource = .localYAML
    @State var selectedSyllabusRoot: LegacySyllabusRoot = .localDefault

    // Same unified YAML as branding (unknown keys are ignored by the decoder).
    let localSyllabusDefaultResourceBaseName = Inf6ProperNouns.compassDefaultYAMLBaseName
    @State var syllabi: [Inf6StanfordSyllabus] = []
    @State var schools: [ECSchool] = []
    @State var selectedDepartmentCode: String = ""
    @State var filtered: [Inf6StanfordSyllabus] = []
    @State var searchText: String = ""

    @State var statusMessage: String = ""
    @State var isTranslatingListTitles: Bool = false

    @State var translatedTitles: [String: String] = [:]  // key: syllabus.id
    @State private var showPaperChatSheet: Bool = false
    @StateObject private var paperChatVM = Inf6PaperChatViewModel()
    
    
    let Inf6LastSyllabusDepartmentCode = "inf6_last_syllabus_department_code"
    let Inf6LastSyllabusSourceKey = "inf6_last_syllabus_source"


    /// エラー発生時にのみ、右上のグローバル再読込ボタンを表示するためのフラグ。
    /// statusMessage に「失敗」または "fail" が含まれている場合に true となる。
    var shouldShowGlobalReload: Bool {
        let isQualMode = entryMode == .qualifications
            || entryMode == .aiCertifications
            || entryMode == .itCertifications
        guard isQualMode else { return false }
        guard !statusMessage.isEmpty else { return false }
        if statusMessage.contains("失敗") { return true }
        if statusMessage.localizedLowercase.contains("fail") { return true }
        return false
    }

    @ViewBuilder
    var _trailingToolbarView: some View {
        if isTranslatingListTitles {
            ProgressView().tint(.pink).scaleEffect(1.25)
                .tint(.orange)
                .help(
                    Inf6Lang.text(
                        "シラバス一覧の講義タイトルを日本語に自動翻訳しています。",
                        "Translating the list of syllabus titles into Japanese."
                    )
                )
        } else if shouldShowGlobalReload {
            Menu {
                Button {
                    reload(forceNetwork: true)
                } label: {
                    Label(
                        Inf6Lang.text("再読込（ネットワーク）…", "Reload from network…"),
                        systemImage: "arrow.clockwise"
                    )
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.pink)
            }
            .help(
                Inf6Lang.text(
                    "スクール一覧とシラバス情報を再取得します。",
                    "Reload schools and syllabi."
                )
            )
        } else {
            EmptyView()
        }
    }


    // Break up SwiftUI body expression to help the compiler type-check faster.
    @ViewBuilder
    var _mainContent: some View {
        // Hoist closures with explicit types to reduce generic inference work.
        let displayTitleProvider: (Inf6StanfordSyllabus) -> String = { s in
            self.displayTitle(for: s)
        }
        let onReloadProvider: (Bool) -> Void = { force in
            self.reload(forceNetwork: force)
        }
        let onApplyFilterProvider: () -> Void = {
            self.applyFilter()
        }

        if entryMode == .paperCollection {
            Inf6PaperCollectionBodyView(
                onOpenPaperChat: {
                    _openPaperChatPanel()
                }
            )
        }

        switch selectedSource {
        case .explorecourses:
            Inf6AutoPapersRemoteBodyView(
                branding: branding,
                selectedSource: $selectedSource,
                selectedSyllabusRoot: $selectedSyllabusRoot,
                selectedDepartmentCode: $selectedDepartmentCode,
                syllabi: $syllabi,
                schools: $schools,
                filtered: $filtered,
                searchText: $searchText,
                statusMessage: $statusMessage,
                translatedTitles: $translatedTitles,
                selectedDepartmentLabel: { self.selectedDepartmentLabel },
                displayTitle: displayTitleProvider,
                onReload: onReloadProvider,
                onApplyFilter: onApplyFilterProvider
            )

        case .localYAML:
            Inf6AutoPapersLocalBodyView(
                branding: branding,
                selectedSource: $selectedSource,
                selectedSyllabusRoot: $selectedSyllabusRoot,
                selectedDepartmentCode: $selectedDepartmentCode,
                syllabi: $syllabi,
                schools: $schools,
                filtered: $filtered,
                searchText: $searchText,
                statusMessage: $statusMessage,
                translatedTitles: $translatedTitles,
                categoryFilter: entryMode.schoolCategoryFilter,
                onOpenPaperChat: {
                    _openPaperChatPanel()
                },
                displayTitle: displayTitleProvider,
                onReload: onReloadProvider,
                onApplyFilter: onApplyFilterProvider
            )

        @unknown default:
            EmptyView()
        }
    }

    init(entryMode: Inf6AutoPapersEntryMode = .qualifications, initialSearchText: String = "", onClose: (() -> Void)? = nil) {
        self.entryMode = entryMode
        self.onClose = onClose
        if !initialSearchText.isEmpty {
            _searchText = State(initialValue: initialSearchText)
        }
        let defaults = UserDefaults.standard

        let storedDept = defaults
            .string(forKey: Inf6LastSyllabusDepartmentCode)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !storedDept.isEmpty {
            _selectedDepartmentCode = State(initialValue: storedDept)
        }

        let storedSource = defaults
            .string(forKey: Inf6LastSyllabusSourceKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if entryMode == .qualifications, let s = SyllabusSource(rawValue: storedSource) {
            _selectedSource = State(initialValue: s)
        }

        // Local YAML は資格系モードすべてで強制使用する。
        let isLocalYAMLMode = entryMode == .qualifications
            || entryMode == .aiCertifications
            || entryMode == .itCertifications
        if isLocalYAMLMode {
            _selectedSource = State(initialValue: .localYAML)
        }
    }

    @ViewBuilder
    var _rootView: some View {
        // Base navigation content
        let baseNav = NavigationStack {
            _mainContent
                .navigationTitle(entryMode.navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    #if os(iOS)
                    if #available(iOS 16.0, *) {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                if let onClose { onClose() } else { dismiss() }
                            } label: {
                                Text(Inf6Lang.text("閉じる", "Close"))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                            }
                        }
                    } else {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button {
                                if let onClose { onClose() } else { dismiss() }
                            } label: {
                                Text(Inf6Lang.text("閉じる", "Close"))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                            }
                        }
                    }
                    #else
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            if let onClose { onClose() } else { dismiss() }
                        } label: {
                            Text(Inf6Lang.text("閉じる", "Close"))
                        }
                    }
                    #endif

                    // Trailing toolbar content (avoid ToolbarContent generic inference issues)
                    if isTranslatingListTitles {
                        ToolbarItem(placement: .automatic) {
                            ProgressView().tint(.pink).scaleEffect(1.25)
                                .tint(.orange)
                                .help(
                                    Inf6Lang.text(
                                        "シラバス一覧の講義タイトルを日本語に自動翻訳しています。",
                                        "Translating the list of syllabus titles into Japanese."
                                    )
                                )
                        }
                    } else if shouldShowGlobalReload {
                        ToolbarItem(placement: .automatic) {
                            Menu {
                                Button {
                                    reload(forceNetwork: true)
                                } label: {
                                    Label(
                                        Inf6Lang.text("再読込（ネットワーク）…", "Reload from network…"),
                                        systemImage: "arrow.clockwise"
                                    )
                                }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .foregroundStyle(.pink)
                            }
                            .help(
                                Inf6Lang.text(
                                    "スクール一覧とシラバス情報を再取得します。",
                                    "Reload schools and syllabi."
                                )
                            )
                        }
                    }
                }
                .onChange(of: selectedDepartmentCode) { _, newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    UserDefaults.standard.set(trimmed, forKey: Inf6LastSyllabusDepartmentCode)
                }
                .onChange(of: selectedSource) { _, newValue in
                    UserDefaults.standard.set(newValue.rawValue, forKey: Inf6LastSyllabusSourceKey)
                }
                .onAppear {
                    log("onAppear")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        _dismissReady = true
                    }
                }
                .onDisappear {
                    log("onDisappear")
                    _dismissReady = false
                }
        }
        .task {
            let isQualMode = entryMode == .qualifications
                || entryMode == .aiCertifications
                || entryMode == .itCertifications
            guard isQualMode else { return }
            await reloadAsync()
        }

        let baseNavWithPaperChat = baseNav.overlay(alignment: .bottom) {
            if showPaperChatSheet {
                _paperChatBottomPanel
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.92), value: showPaperChatSheet)

        baseNavWithPaperChat
    }

    var body: some View {
        _rootView
    }

    private var _paperChatPanelBackground: Color {
        #if canImport(UIKit)
        return Color(UIColor.systemBackground)
        #else
        return Color.white
        #endif
    }

    @MainActor
    private func _openPaperChatPanel() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.92)) {
            showPaperChatSheet = true
        }
    }

    @MainActor
    private func _closePaperChatPanel() {
        withAnimation(.spring(response: 0.30, dampingFraction: 0.94)) {
            showPaperChatSheet = false
        }
    }

    @ViewBuilder
    private var _paperChatBottomPanel: some View {
        GeometryReader { geo in
            let horizontalInset: CGFloat = geo.size.width >= 900 ? 8 : 12
            let bottomInset: CGFloat = geo.size.height >= 900 ? 8 : 12
            let panelWidth = min(max(geo.size.width - (horizontalInset * 2), 360), 1600)
            let panelHeightRatio: CGFloat = geo.size.height >= 900 ? 0.93 : 0.88
            let panelHeight = max(min(geo.size.height * panelHeightRatio, 1320), 520)

            ZStack(alignment: .bottom) {
                Color.black
                    .opacity(0.08)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        _closePaperChatPanel()
                    }

                VStack(spacing: 0) {
                    Capsule(style: .continuous)
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 44, height: 6)
                        .padding(.top, 8)
                        .padding(.bottom, 8)

                    NavigationStack {
                        Inf6PaperChatView(vm: paperChatVM)
                            .toolbar {
                                #if os(iOS)
                                if #available(iOS 16.0, *) {
                                    ToolbarItem(placement: .topBarLeading) {
                                        Button {
                                            _closePaperChatPanel()
                                        } label: {
                                            Text(Inf6Lang.text("閉じる", "Close"))
                                        }
                                    }
                                } else {
                                    ToolbarItem(placement: .navigationBarLeading) {
                                        Button {
                                            _closePaperChatPanel()
                                        } label: {
                                            Text(Inf6Lang.text("閉じる", "Close"))
                                        }
                                    }
                                }
                                #else
                                ToolbarItem(placement: .cancellationAction) {
                                    Button {
                                        _closePaperChatPanel()
                                    } label: {
                                        Text(Inf6Lang.text("閉じる", "Close"))
                                    }
                                }
                                #endif
                            }
                    }
                }
                .frame(width: panelWidth, height: panelHeight)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(_paperChatPanelBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.16), radius: 22, x: 0, y: 8)
                .padding(.horizontal, horizontalInset)
                .padding(.bottom, bottomInset)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    var footerText: String {
        switch selectedSource {
        case .localYAML:
            switch selectedSyllabusRoot {
            case .localDefault:
                return Inf6Lang.text(
                    "ローカルシラバスを GPT でリサーチ。",
                    "Explores local syllabi via GPT."
                )
            case .localOther:
                return Inf6Lang.text(
                    "大学名や資格名のシラバスをGPTでリサーチ。",
                    "Explores syllabi via GPT using your university/qualification input."
                )
            @unknown default:
                return ""
            }
        case .explorecourses:
            if syllabi.isEmpty {
                return Inf6Lang.text(
                    "リモートAPIからオンラインでシラバス情報を取得します。「シラバス一覧」セクション右端の更新ボタンで更新できます。",
                    "Fetches syllabus information online from a explorecourses API. Use the reload button in the Syllabi section header to update."
                )
            } else {
                return Inf6Lang.text(
                    "ここではシラバス情報のみを一覧表示します（PDF の一括ダウンロードは行いません）。",
                    "This view only lists syllabus information (it does not download PDFs in bulk)."
                )
            }
        @unknown default:
            return ""
        }
    }


    var selectedDepartmentLabel: String {
        let code = selectedDepartmentCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return Inf6Lang.text("未選択", "Not selected") }
        for school in schools {
            if let dept = school.departments.first(where: { $0.code == code }) {
                return "\(school.displayName) / \(dept.displayName)"
            }
        }
        return code
    }

    func displayTitle(for s: Inf6StanfordSyllabus) -> String {
        let baseTitle: String
        if Inf6Lang.isJapanese,
           let ja = translatedTitles[s.id],
           !ja.isEmpty {
            baseTitle = ja
        } else {
            baseTitle = s.title
        }

        if !s.code.isEmpty {
            return "\(s.code)  \(baseTitle)"
        }
        return baseTitle
    }

    @MainActor
    func applyFilter() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !q.isEmpty else {
            filtered = syllabi
            return
        }
        filtered = syllabi.filter { s in
            let hay = (
                s.code + "\n" +
                s.title + "\n" +
                s.detail + "\n" +
                s.department + "\n" +
                s.level + "\n" +
                (s.manifestRef ?? "")
            ).localizedLowercase
            return hay.contains(q)
        }
    }

    func reload(forceNetwork: Bool = false) {
        log("reload: requested forceNetwork=\(forceNetwork) selectedSource=\(selectedSource.rawValue) root=\(selectedSyllabusRoot.rawValue) dept='\(selectedDepartmentCode)'")
        Task {
            await reloadAsync(forceNetwork: forceNetwork)
        }
    }

    @MainActor
    func reloadAsync(forceNetwork: Bool = false) async {
        log("reloadAsync: start selectedSource=\(selectedSource.rawValue) root=\(selectedSyllabusRoot.rawValue) forceNetwork=\(forceNetwork)")
        let trimmed = selectedDepartmentCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let stored = UserDefaults.standard
                .string(forKey: Inf6LastSyllabusDepartmentCode)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !stored.isEmpty {
                selectedDepartmentCode = stored
            }
        }
        // Before final reloadFromExploreCourses call, log dept code
        log("reloadAsync: using deptCode='\(selectedDepartmentCode.trimmingCharacters(in: .whitespacesAndNewlines))'")
        await reloadFromExploreCourses(forceNetwork: forceNetwork)
        log("reloadAsync: done syllabi=\(syllabi.count) filtered=\(filtered.count) schools=\(schools.count) statusMsgChars=\(statusMessage.count)")
    }


    @MainActor
    func reloadFromExploreCourses(forceNetwork: Bool) async {
        log("reloadFromExploreCourses: enter selectedSource=\(selectedSource.rawValue) root=\(selectedSyllabusRoot.rawValue) dept='\(selectedDepartmentCode)'")
        let connection = ECCourseConnection()

        // Non-API syllabi ("シラバス") branch.
        if selectedSource == .localYAML {
            log("reloadFromExploreCourses: localYAML branch")
            switch selectedSyllabusRoot {
            case .localDefault:
                let items = loadLocalSyllabi(resourceBaseName: localSyllabusDefaultResourceBaseName)
                log("reloadFromExploreCourses: localDefault loaded items=\(items.count)")
                syllabi = items

                // localYAML でも UI が `schools` を参照する（picker / ラベル表示など）ため、
                // 以前に取得した ExploreCourses の schools があればディスクキャッシュから復元して使う。
                // これにより `schools=0` で一覧が出ない問題を避ける。
                let loadedSchools: (schools: [ECSchool]?, error: Error?)?
                if Inf6AutoPapersView.cachedSchools.isEmpty {
                    loadedSchools = await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async {
                            continuation.resume(returning: Inf6AutoPapersView.loadCachedSchoolsFromDisk())
                        }
                    }
                } else {
                    loadedSchools = nil
                }

                let cachedOrDiskSchools: [ECSchool] = {
                    if !Inf6AutoPapersView.cachedSchools.isEmpty {
                        return Inf6AutoPapersView.cachedSchools
                    }
                    if let disk = loadedSchools?.schools, !disk.isEmpty {
                        Inf6AutoPapersView.cachedSchools = disk
                        return disk
                    }
                    if let err = loadedSchools?.error {
                        print("[Inf6AutoPapers] localYAML: schools disk cache load error: \(err)")
                    }
                    return []
                }()
                schools = prependEQualificationSchool(to: cachedOrDiskSchools)
                if loadedSchools?.schools == nil, let err = loadedSchools?.error {
                    _appendStatusWarning(
                        "⚠︎ 学部一覧のディスクキャッシュ読込に失敗しました: \(err.localizedDescription)",
                        "⚠︎ Failed to read schools disk cache: \(err.localizedDescription)"
                    )
                }

                applyFilter()

            case .localOther:
                log("reloadFromExploreCourses: localOther selected (no fetch implemented here)")
                syllabi = []
                filtered = []

                // localOther でも UI が `schools` を参照することがあるため、ディスクキャッシュから復元する。
                let loadedSchools: (schools: [ECSchool]?, error: Error?)?
                if Inf6AutoPapersView.cachedSchools.isEmpty {
                    loadedSchools = await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async {
                            continuation.resume(returning: Inf6AutoPapersView.loadCachedSchoolsFromDisk())
                        }
                    }
                } else {
                    loadedSchools = nil
                }

                let cachedOrDiskSchools: [ECSchool] = {
                    if !Inf6AutoPapersView.cachedSchools.isEmpty {
                        return Inf6AutoPapersView.cachedSchools
                    }
                    if let disk = loadedSchools?.schools, !disk.isEmpty {
                        Inf6AutoPapersView.cachedSchools = disk
                        return disk
                    }
                    if let err = loadedSchools?.error {
                        print("[Inf6AutoPapers] localOther: schools disk cache load error: \(err)")
                    }
                    return []
                }()
                schools = prependEQualificationSchool(to: cachedOrDiskSchools)

                statusMessage = Inf6Lang.text(
                    "大学名や資格名を入力して GPT でシラバスをたどります。",
                    "Explores syllabi via GPT using your university/qualification input."
                )
            }
            return
        }

        // まず学部・一覧を取得（キャッシュ優先）
        if !forceNetwork && Inf6AutoPapersView.cachedSchools.isEmpty {
            let loaded = Inf6AutoPapersView.loadCachedSchoolsFromDisk()
            if let disk = loaded.schools, !disk.isEmpty {
                log("reloadFromExploreCourses: using disk cached schools=\(disk.count)")
                Inf6AutoPapersView.cachedSchools = disk
                schools = prependEQualificationSchool(to: disk)
                scheduleAutoLabelsIfNeeded(using: disk)
            }
            if loaded.schools == nil, let err = loaded.error {
                _appendStatusWarning(
                    "⚠︎ 学部一覧のディスクキャッシュ読込に失敗しました: \(err.localizedDescription)",
                    "⚠︎ Failed to read schools disk cache: \(err.localizedDescription)"
                )
            }
        }

        if forceNetwork || Inf6AutoPapersView.cachedSchools.isEmpty {
            log("reloadFromExploreCourses: fetching schools (forceNetwork=\(forceNetwork))")
            statusMessage = Inf6Lang.text(
                "リモートAPIから学部・一覧を取得しています…",
                "Fetching list of schools from explorecourses API…"
            )
            do {
                let fetchedSchools = try await connection.getSchools()
                log("reloadFromExploreCourses: fetched schools=\(fetchedSchools.count)")
                Inf6AutoPapersView.cachedSchools = fetchedSchools
                if let err = Inf6AutoPapersView.saveSchoolsCacheToDisk(fetchedSchools) {
                    _appendStatusWarning(
                        "⚠︎ 学部一覧のディスクキャッシュ保存に失敗しました: \(err.localizedDescription)",
                        "⚠︎ Failed to save schools disk cache: \(err.localizedDescription)"
                    )
                }
                schools = prependEQualificationSchool(to: fetchedSchools)
                scheduleAutoLabelsIfNeeded(using: fetchedSchools)
            } catch {
                log("reloadFromExploreCourses: getSchools failed error=\(error)")

                // Keep the last known schools/syllabi if we have any cache; do not discard.
                let cached = prependEQualificationSchool(to: Inf6AutoPapersView.cachedSchools)
                if !cached.isEmpty {
                    schools = cached
                    // Keep current `syllabi/filtered` as-is.
                    _appendStatusWarning(
                        "⚠︎ リモートAPIから学部・スクール一覧を取得できませんでした（キャッシュを表示します）: \(error.localizedDescription)",
                        "⚠︎ Failed to fetch schools list (showing cached data): \(error.localizedDescription)"
                    )
                    return
                }

                schools = []
                syllabi = []
                filtered = []
                statusMessage = Inf6Lang.text(
                    "リモートAPIから学部・スクール一覧を取得できませんでした: \(error.localizedDescription)",
                    "Failed to fetch schools list from explorecourses API: \(error.localizedDescription)"
                )
                return
            }
        } else {
            log("reloadFromExploreCourses: using cached schools=\(Inf6AutoPapersView.cachedSchools.count)")
            let cached = Inf6AutoPapersView.cachedSchools
            schools = prependEQualificationSchool(to: cached)
        }

        // スクールコードを選択（ユーザーが明示的に選ぶまで自動選択しない）
        let trimmed = selectedDepartmentCode.trimmingCharacters(in: .whitespacesAndNewlines)
        log("reloadFromExploreCourses: selectedDepartmentCode='\(trimmed)'")
        guard !trimmed.isEmpty else {
            syllabi = []
            filtered = []
            statusMessage = Inf6Lang.text(
                "スクールを選択してから右上の「再読込」でシラバスを取得してください。",
                "Select a school first, then tap Reload in the upper-right to fetch syllabi."
            )
            return
        }
        let dept = trimmed.uppercased()
        let cacheKey = dept

        if !forceNetwork,
           let cached = Inf6AutoPapersView.cachedExploreCoursesByDepartment[cacheKey],
           !cached.isEmpty {
            log("reloadFromExploreCourses: using cached syllabi dept=\(dept) count=\(cached.count)")
            syllabi = cached
            applyFilter()
            autoTranslateListTitlesIfPossible(for: cached)
            statusMessage = Inf6Lang.text(
                "リモートAPIのキャッシュから \(dept) スクールのシラバス \(syllabi.count) 件を読み込みました。",
                "Loaded \(syllabi.count) syllabi for school \(dept) from the explorecourses API cache."
            )
            return
        }

        if !forceNetwork {
            let loaded = Inf6AutoPapersView.loadCachedSyllabiFromDisk(dept: dept)
            if let diskCached = loaded.items, !diskCached.isEmpty {
                log("reloadFromExploreCourses: using disk cached syllabi dept=\(dept) count=\(diskCached.count)")
                syllabi = diskCached
                applyFilter()
                autoTranslateListTitlesIfPossible(for: diskCached)
                Inf6AutoPapersView.cachedExploreCoursesByDepartment[cacheKey] = diskCached
                statusMessage = Inf6Lang.text(
                    "ディスクキャッシュから \(dept) スクールのシラバス \(syllabi.count) 件を読み込みました。",
                    "Loaded \(syllabi.count) syllabi for school \(dept) from disk cache."
                )
                return
            }
            if loaded.items == nil, let err = loaded.error {
                _appendStatusWarning(
                    "⚠︎ ディスクキャッシュ（\(dept)）の読込に失敗しました: \(err.localizedDescription)",
                    "⚠︎ Failed to read disk cache (\(dept)): \(err.localizedDescription)"
                )
            }
        }

        statusMessage = Inf6Lang.text(
            "リモートAPIから \(dept) スクールのシラバスを取得しています…",
            "Fetching syllabi for school \(dept) from explorecourses API…"
        )

        do {
            let courses = try await connection.getCoursesByDepartment(code: dept)
            log("reloadFromExploreCourses: fetched courses=\(courses.count) dept=\(dept)")
            let localizedDeptLabel = Inf6TaxonomyLocalization.localizedLabel(for: dept, fallback: dept)

            let items: [Inf6StanfordSyllabus] = courses.map { c in
                Inf6StanfordSyllabus(
                    id: String(c.courseID),
                    code: "\(c.subject)\(c.code)",
                    title: c.title,
                    detail: c.descriptionText,
                    department: localizedDeptLabel,
                    level: c.academicCareer,
                    manifestRef: nil
                )
            }
            log("reloadFromExploreCourses: mapped syllabi items=\(items.count) dept=\(dept)")

            if Inf6Lang.isJapanese {
                let persisted = Inf6SyllabusGPT.loadTitleTranslations()
                if !persisted.isEmpty {
                    for s in items {
                        if let ja = persisted[s.id] {
                            translatedTitles[s.id] = ja
                        }
                    }
                }
            }

            syllabi = items
            applyFilter()
            autoTranslateListTitlesIfPossible(for: items)
            Inf6AutoPapersView.cachedExploreCoursesByDepartment[cacheKey] = items
            if let err = Inf6AutoPapersView.saveSyllabiCacheToDisk(dept: dept, items: items) {
                _appendStatusWarning(
                    "⚠︎ ディスクキャッシュ（\(dept)）の保存に失敗しました: \(err.localizedDescription)",
                    "⚠︎ Failed to save disk cache (\(dept)): \(err.localizedDescription)"
                )
            }

            if syllabi.isEmpty {
                statusMessage = Inf6Lang.text(
                    "リモートAPIから \(dept) スクールのシラバスを取得できませんでした。",
                    "Could not fetch syllabi for school \(dept) from explorecourses API."
                )
            } else {
                statusMessage = Inf6Lang.text(
                    "リモートAPIから \(dept) スクールのシラバスを \(syllabi.count) 件取得しました。",
                    "Fetched \(syllabi.count) syllabi for school \(dept) from explorecourses API."
                )
            }
        } catch {
            log("reloadFromExploreCourses: getCoursesByDepartment failed dept=\(dept) error=\(error)")

            // Keep last known syllabi if any cache exists; do not discard.
            if let cached = Inf6AutoPapersView.cachedExploreCoursesByDepartment[cacheKey], !cached.isEmpty {
                syllabi = cached
                applyFilter()
                autoTranslateListTitlesIfPossible(for: cached)
                _appendStatusWarning(
                    "⚠︎ リモートAPIからのシラバス取得に失敗しました（キャッシュを表示します）: \(error.localizedDescription)",
                    "⚠︎ Failed to fetch syllabi (showing cached data): \(error.localizedDescription)"
                )
                return
            }

            let loaded = Inf6AutoPapersView.loadCachedSyllabiFromDisk(dept: dept)
            if let disk = loaded.items, !disk.isEmpty {
                syllabi = disk
                applyFilter()
                autoTranslateListTitlesIfPossible(for: disk)
                Inf6AutoPapersView.cachedExploreCoursesByDepartment[cacheKey] = disk
                _appendStatusWarning(
                    "⚠︎ リモートAPIからのシラバス取得に失敗しました（ディスクキャッシュを表示します）: \(error.localizedDescription)",
                    "⚠︎ Failed to fetch syllabi (showing disk cache): \(error.localizedDescription)"
                )
                if let err = loaded.error {
                    _appendStatusWarning(
                        "⚠︎ ディスクキャッシュ（\(dept)）の読込でもエラーがありました: \(err.localizedDescription)",
                        "⚠︎ Disk cache read also reported an error (\(dept)): \(err.localizedDescription)"
                    )
                }
                return
            }

            syllabi = []
            filtered = []
            statusMessage = Inf6Lang.text(
                "リモートAPIからのシラバス取得に失敗しました: \(error.localizedDescription)",
                "Failed to fetch syllabi from explorecourses API: \(error.localizedDescription)"
            )
        }
    }
    
    
    @MainActor
    func scheduleAutoLabelsIfNeeded(using schools: [ECSchool]) {
        // 1) Process-level guard
        if Inf6AutoPapersView.didAttemptAutoLabels {
            log("auto label generation already attempted; skipping.")
            return
        }

        // 2) Persisted guard across launches
        if UserDefaults.standard.bool(forKey: Inf6AutoPapersView.autoLabelsGeneratedFlagKey) {
            Inf6AutoPapersView.didAttemptAutoLabels = true
            log("auto labels already generated previously; skipping GPT generation.")
            return
        }

        Inf6AutoPapersView.didAttemptAutoLabels = true
        log("scheduling auto label generation (schools=\(schools.count))")
        Task {
            await autoGenerateLabelsIfPossible(using: schools)
        }
    }

    @MainActor
    func autoGenerateLabelsIfPossible(using schools: [ECSchool]) async {
        log("autoGenerateLabelsIfPossible invoked (schools=\(schools.count))")

        guard !schools.isEmpty else {
            log("autoGenerateLabelsIfPossible: no schools; skipping GPT label generation.")
            return
        }

        do {
            _ = try OpenAIKeyStore.load()
        } catch {
            log("autoGenerateLabelsIfPossible: OpenAI API key is not set; skipping GPT label generation: \(error.localizedDescription)")
            await MainActor.run {
                self.statusMessage = Inf6Lang.text(
                    "OpenAI APIキーが未設定です。OpenAI 設定でキーを保存してください。",
                    "OpenAI API key is not set. Please save it in OpenAI Settings."
                )
            }
            return
        }

        do {
            log("autoGenerateLabelsIfPossible: calling Inf6TaxonomyGPT.generateAndSaveLabelsYAML...")
            try await Inf6TaxonomyGPT.generateAndSaveLabelsYAML(schools: schools)
            await MainActor.run {
                // 新しいラベルファイルを反映
                Inf6TaxonomyLocalization.invalidateCache()
                // 再代入して SwiftUI に再描画させる
                self.schools = prependEQualificationSchool(to: Inf6AutoPapersView.cachedSchools)
                self.statusMessage = Inf6Lang.text(
                    "スクール/学科名の日本語/英語ラベルを自動生成しました。",
                    "Automatically generated localized labels for schools and departments."
                )
                UserDefaults.standard.set(true, forKey: Inf6AutoPapersView.autoLabelsGeneratedFlagKey)
            }
            log("autoGenerateLabelsIfPossible: label generation succeeded.")
        } catch {
            log("autoGenerateLabelsIfPossible: label generation failed: \(error)")
            await MainActor.run {
                self.statusMessage = Inf6Lang.text(
                    "スクール/学科名ラベルの自動生成に失敗しました: \(error.localizedDescription)",
                    "Failed to generate localized labels for schools/departments: \(error.localizedDescription)"
                )
            }
        }
    }


    /// タイトルが英語主体かどうかの簡易判定（ASCII 以外の文字を含まない場合を「英語らしい」とみなす）。
    func titleSeemsEnglish(_ title: String) -> Bool {
        for scalar in title.unicodeScalars {
            if scalar.value > 0x007E {
                return false
            }
        }
        return true
    }
    
    
    
    
    
    
    /// 日本語モードで一覧に表示する英語シラバスタイトルをOS標準翻訳で変換し、
    /// `translatedTitles` にキャッシュする。
    @MainActor
    func autoTranslateListTitlesIfPossible(for items: [Inf6StanfordSyllabus]) {
        // 日本語モード以外では何もしない
        guard Inf6Lang.isJapanese else { return }

        // 1. 永続化済みのタイトル翻訳を JSON から読み込み、
        //    まだメモリ上に無いものだけ translatedTitles に反映する。
        let persisted = Inf6SyllabusGPT.loadTitleTranslations()
        if !persisted.isEmpty {
            for s in items {
                if let ja = persisted[s.id], translatedTitles[s.id] == nil {
                    translatedTitles[s.id] = ja
                }
            }
        }

        // 2. すでに翻訳済み（メモリ＋永続化）のものを除外して、
        //    GPT に投げる対象だけを抽出する。
        let targets = items.filter {
            translatedTitles[$0.id] == nil && titleSeemsEnglish($0.title)
        }
        guard !targets.isEmpty else { return }

        Task {
            await MainActor.run {
                isTranslatingListTitles = true
            }

            do {
                // タイトルだけをまとめてOS標準翻訳（チャンクごとに反映）
                let _ = try await Inf6SyllabusGPT.translateTitlesBatch(
                    syllabi: targets
                ) { partial in
                    // 3. チャンクごとの結果を JSON に永続化しつつ、
                    //    できたものから順次、行タイトルに反映する。
                    Inf6SyllabusGPT.mergeTitleTranslations(partial)
                    await MainActor.run {
                        for (id, titleJA) in partial {
                            translatedTitles[id] = titleJA
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.log("batch title translation failed: \(error)")
                }
            }

            await MainActor.run {
                isTranslatingListTitles = false
            }
        }
    }
    
    
    /// NOTE: This used to be defined as a nested type in this file.
    /// We keep the old `Inf6AutoPapersView.SyllabusDetailView` name as an alias,
    /// while moving the real implementation to a top-level type so it can live in its own file.
    typealias SyllabusDetailView = Inf6SyllabusDetailView
}


#endif
