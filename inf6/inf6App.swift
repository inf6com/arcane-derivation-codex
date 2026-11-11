//
//  inf6App.swift
//
//  Updated to use Inf6AutoPapersView as the app's root.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

#if canImport(Translation)
import Translation
#endif

#if canImport(Translation)
@MainActor
final class Inf6SystemTranslationCoordinator: ObservableObject {
    static let shared = Inf6SystemTranslationCoordinator()

    private enum TranslationError: LocalizedError {
        case timeout
        case needsPreparation
        case unsupported(source: String, target: String)

        var errorDescription: String? {
            switch self {
            case .timeout:
                return "OS標準翻訳が制限時間内に応答しませんでした。"
            case .needsPreparation:
                return "英語→日本語のOS翻訳モデルが未準備です。起動時の準備を完了してください。"
            case let .unsupported(source, target):
                return "\(source)から\(target)へのOS標準翻訳は、この端末では対応していません。"
            }
        }
    }

    @Published private(set) var configuration: TranslationSession.Configuration?
    @Published private(set) var preparationConfiguration: TranslationSession.Configuration?
    @Published private(set) var startupStatus: StartupStatus = .checking

    enum StartupStatus: Equatable {
        case checking
        case installed
        case needsPreparation
        case unsupported
        case failed(String)
    }

    private struct Pending {
        let source: Locale.Language
        let target: Locale.Language
        let text: String
        let continuation: CheckedContinuation<String, Error>
    }

    private var pending: [UUID: Pending] = [:]
    private var processing = false

    func checkStartupAvailability() async {
        let source = Locale.Language(identifier: "en")
        let target = Locale.Language(identifier: "ja")
        let status = await LanguageAvailability().status(from: source, to: target)
        if status == .installed,
           #available(iOS 26.0, macOS 26.0, *) {
            let session = TranslationSession(installedSource: source, target: target)
            guard await session.isReady else {
                startupStatus = .needsPreparation
                return
            }
        }
        _applyStartupStatus(status)
    }

    func verifyReadyForTranslation() async throws {
        let source = Locale.Language(identifier: "en")
        let target = Locale.Language(identifier: "ja")
        startupStatus = .checking
        let status = await LanguageAvailability().status(from: source, to: target)
        _applyStartupStatus(status)
        switch status {
        case .installed:
            if #available(iOS 26.0, macOS 26.0, *) {
                let session = TranslationSession(installedSource: source, target: target)
                guard await session.isReady else {
                    startupStatus = .needsPreparation
                    throw TranslationError.needsPreparation
                }
            }
            return
        case .supported:
            throw TranslationError.needsPreparation
        case .unsupported:
            throw TranslationError.unsupported(source: "英語", target: "日本語")
        @unknown default:
            throw TranslationError.needsPreparation
        }
    }

    private func _applyStartupStatus(_ status: LanguageAvailability.Status) {
        switch status {
        case .installed:
            startupStatus = .installed
        case .supported:
            startupStatus = .needsPreparation
        case .unsupported:
            startupStatus = .unsupported
        @unknown default:
            startupStatus = .failed("翻訳機能の状態を確認できませんでした。")
        }
    }

    func beginStartupPreparation() {
        preparationConfiguration = TranslationSession.Configuration(
            source: Locale.Language(identifier: "en"),
            target: Locale.Language(identifier: "ja")
        )
    }

    func processStartupPreparation(_ session: TranslationSession) async {
        do {
            if #available(iOS 26.0, macOS 26.0, *) {
                try await session.prepareTranslation()
            }
            preparationConfiguration = nil
            await checkStartupAvailability()
        } catch is CancellationError {
            preparationConfiguration = nil
        } catch {
            preparationConfiguration = nil
            startupStatus = .failed(error.localizedDescription)
        }
    }

    func translate(_ text: String, source: String, target: String) async throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        try Task.checkCancellation()

        let sourceLanguage = Locale.Language(identifier: source)
        let targetLanguage = Locale.Language(identifier: target)
        let availability = await LanguageAvailability().status(from: sourceLanguage, to: targetLanguage)
        guard availability != .unsupported else {
            throw TranslationError.unsupported(source: source, target: target)
        }
        guard availability == .installed else {
            throw TranslationError.needsPreparation
        }

        if #available(iOS 26.0, macOS 26.0, *) {
            let session = TranslationSession(
                installedSource: sourceLanguage,
                target: targetLanguage
            )
            let response = try await session.translate(value)
            return response.targetText
        }

        let requestID = UUID()

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { @MainActor in
                    try await withCheckedThrowingContinuation { continuation in
                        self.pending[requestID] = Pending(
                            source: sourceLanguage,
                            target: targetLanguage,
                            text: value,
                            continuation: continuation
                        )
                        self._activateNextConfiguration()
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(30))
                    await MainActor.run {
                        self._cancel(requestID)
                    }
                    throw TranslationError.timeout
                }
                guard let result = try await group.next() else {
                    throw TranslationError.timeout
                }
                group.cancelAll()
                return result
            }
        } onCancel: {
            Task { @MainActor in
                self._cancel(requestID)
            }
        }
    }

    func process(_ session: TranslationSession) async {
        guard !processing else { return }
        processing = true
        defer { processing = false }

        while let requestID = _nextRequestID(for: session.sourceLanguage, target: session.targetLanguage),
              let request = pending[requestID] {
            do {
                let response = try await session.translate(request.text)
                pending.removeValue(forKey: requestID)
                request.continuation.resume(returning: response.targetText)
            } catch is CancellationError {
                return
            } catch {
                pending.removeValue(forKey: requestID)
                request.continuation.resume(throwing: error)
            }
        }

        _activateNextConfiguration()
    }

    private func _nextRequestID(
        for source: Locale.Language?,
        target: Locale.Language?
    ) -> UUID? {
        pending.first {
            $0.value.source == source && $0.value.target == target
        }?.key
    }

    private func _activateNextConfiguration() {
        guard let request = pending.values.first else {
            configuration = nil
            return
        }
        let next = TranslationSession.Configuration(source: request.source, target: request.target)
        if configuration != next {
            configuration = next
        }
    }

    private func _cancel(_ requestID: UUID) {
        guard let request = pending.removeValue(forKey: requestID) else { return }
        request.continuation.resume(throwing: CancellationError())
        _activateNextConfiguration()
    }
}
#endif

#if canImport(PencilKit)
enum Inf6CodexTopContextStore {
    private static let userDefaultsKey = "inf6.codex.topContext"
    private static let metadataKey = "codex_top_context"

    static func save(_ context: Inf6CodexRootContext) {
        // 起動先ごとの UserDefaults ではなく、選択中の保存先へ保存する。
        // これにより同じ User Setting Root を使う iPad／シミュレータ間で
        // 最後に開いた論文コンテキストを共有できる。
        guard Inf6MetadataStore.putCodable(context, domain: .settings, key: metadataKey),
              let data = try? JSONEncoder().encode(context) else { return }
        // 既存インストールからの移行用。一度保存した後の正本は metadata である。
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }

    static func load() -> Inf6CodexRootContext? {
        if let stored = Inf6MetadataStore.getCodable(
            Inf6CodexRootContext.self,
            domain: .settings,
            key: metadataKey
        ) {
            return stored
        }
        // 旧版の UserDefaults を保存先へ一度だけ移行する。
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let legacy = try? JSONDecoder().decode(Inf6CodexRootContext.self, from: data) else {
            return nil
        }
        _ = Inf6MetadataStore.putCodable(legacy, domain: .settings, key: metadataKey)
        return legacy
    }
}
#endif

/// 保存先が決まるまでは、設定画面そのものを根にする。
///
/// はじめは onAppear で fullScreenCover を出していたが、同じ画面に
/// いくつも cover が重なっており、初期設定だけが出てこなかった。
/// 出す・出さないを条件に頼らず、根の中身を入れ替える。
struct Inf6RootView: View {

    @State private var _appUpdateChecker = Inf6AppUpdateChecker.shared
#if canImport(PencilKit)
    @State private var startupFormulaContext: Inf6CodexRootContext?
    @State private var startupContextResolutionCompleted = false
#endif
    @State private var setupCompletionCommittedInSession = false
    @AppStorage("inf6_ui_language")
    private var setupLanguage = InterfaceLanguage.japanese.rawValue
    @State private var setupRootPath = Inf6EntityImageLocation.displayPath ?? ""
    @AppStorage(Inf6ApplicationSystemFont.userDefaultsKey)
    private var applicationSystemFontFamily: String = Inf6ApplicationSystemFont.systemValue
    @AppStorage(Inf6ApplicationSystemFont.sizeUserDefaultsKey)
    private var applicationSystemFontSize: Double = Inf6ApplicationSystemFont.defaultSize
#if canImport(Translation)
    @ObservedObject private var systemTranslation = Inf6SystemTranslationCoordinator.shared
#endif

    private var applicationSystemFont: Font {
        let family = applicationSystemFontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        return family.isEmpty
            ? .system(size: applicationSystemFontSize)
            : .custom(family, size: applicationSystemFontSize)
    }

    private var _initialSetupIsComplete: Bool {
        if setupCompletionCommittedInSession { return true }
        guard Inf6EntityImageLocation.displayPath != nil,
              Inf6EntityImageLocation.resolvedURL() != nil,
              let marker = Inf6MetadataStore.get(
            domain: .settings,
            key: "initial_setup_completed"
              ),
              let data = marker.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["completed"] as? Bool == true else {
            return false
        }
        return true
    }

#if canImport(PencilKit)
    private var hasVerifiedEshikakuSyllabus: Bool {
        guard let root = Inf6EntityImageLocation.resolvedURL() else {
            return false
        }
        do {
            let workspace = try WorkspaceStore(root: root)
            guard let verifiedSnapshot = try SyllabusRepository(root: workspace).current(domain: "E資格") else {
                return false
            }
            return verifiedSnapshot.verified
        } catch {
            return false
        }
    }

    private var codexRootContext: Inf6CodexRootContext {
        Inf6CodexRootContext(
            paperID: "",
            paperTitle: "Arcane Derivation Codex",
            sourceFamily: hasVerifiedEshikakuSyllabus ? "jdla_eshikaku" : nil,
            chapterID: nil,
            chapterTitle: nil,
            evidence: []
        )
    }

    private func resolvedStartupContext() -> Inf6CodexRootContext {
        guard let stored = Inf6CodexTopContextStore.load() else {
            return codexRootContext
        }
        if stored.paperID.isEmpty && stored.sourceFamily == nil {
            return codexRootContext
        }
        return stored
    }

    private func _importPendingDeviceData() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let archive = documents?.appendingPathComponent("inf6_simulator_seed.zip")
        guard let archive, FileManager.default.fileExists(atPath: archive.path) else { return }
        do {
            let restored = try Inf6DataExchange.importArchives(at: [archive])
            try FileManager.default.removeItem(at: archive)
            NSLog("[Inf6RootView] imported pending device data: files=%d", restored)
        } catch {
            NSLog("[Inf6RootView] pending device data import failed: %@", error.localizedDescription)
        }
    }
#endif

    var body: some View {
        ZStack(alignment: .top) {
            if !_initialSetupIsComplete {
                SetupWizardView(
                    language: $setupLanguage,
                    rootPath: $setupRootPath,
                    onRootChange: { selectedRoot in
                        try Inf6EntityImageLocation.set(selectedRoot)
                        setupRootPath = Inf6EntityImageLocation.displayPath ?? selectedRoot.path
                    },
                    onComplete: {
                        setupCompletionCommittedInSession = true
                        startupFormulaContext = resolvedStartupContext()
                        startupContextResolutionCompleted = true
                    }
                )
            } else {
                if startupContextResolutionCompleted {
                    Inf6CodexRootView(
                        context: startupFormulaContext ?? codexRootContext
                    )
                } else {
                    ProgressView()
                        .tint(Inf6CodexDesign.cyan)
                }
            }

            if let update = _appUpdateChecker.availableUpdate {
                Inf6AppUpdateBanner(update: update) {
                    _appUpdateChecker.dismiss()
                }
            }
        }
        .textSelection(.enabled)
        .environment(\.font, applicationSystemFont)
        .task {
            await _appUpdateChecker.checkIfNeeded()
#if canImport(Translation)
            await systemTranslation.checkStartupAvailability()
#endif
#if canImport(PencilKit)
            // 保存先の初期設定中は、metadata を読む論文復旧処理を開始しない。
            // ここを通すと未設定 root に Inf6CorePaperStore がアクセスして落ちる。
            guard _initialSetupIsComplete else {
                startupContextResolutionCompleted = true
                return
            }
            _importPendingDeviceData()
            startupFormulaContext = resolvedStartupContext()
            startupContextResolutionCompleted = true
#endif
        }
#if canImport(Translation)
        .translationTask(systemTranslation.configuration) { session in
            await systemTranslation.process(session)
        }
        .translationTask(systemTranslation.preparationConfiguration) { session in
            await systemTranslation.processStartupPreparation(session)
        }
#endif
    }
}

#if canImport(Translation)
private struct Inf6TranslationPreparationView: View {
    @ObservedObject var coordinator: Inf6SystemTranslationCoordinator
    @Binding var acknowledged: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("日本語訳の準備")
                .font(.title2.weight(.semibold))

            switch coordinator.startupStatus {
            case .checking:
                Text("英語→日本語のOS翻訳が利用できるか確認しています。")
            case .installed:
                Text("英語→日本語のOS翻訳を利用できます。")
            case .needsPreparation:
                Text("英語→日本語のOS翻訳言語が未準備です。準備すると、論文本文の日本語訳を端末上で実行できます。")
                Button("翻訳言語を準備") {
                    coordinator.beginStartupPreparation()
                }
                .buttonStyle(.borderedProminent)
            case .unsupported:
                Text("この端末では、英語→日本語のOS標準翻訳を利用できません。")
            case let .failed(message):
                Text(message)
                Button("もう一度確認") {
                    Task { await coordinator.checkStartupAvailability() }
                }
                .buttonStyle(.bordered)
            }

            if coordinator.startupStatus != .needsPreparation {
                Button("閉じる") {
                    acknowledged = true
                    dismiss()
                }
                    .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}
#endif

@main
struct inf6App: App {

    // App appearance (system / light / dark)
    @AppStorage("inf6.appearance.mode") private var appearanceModeRaw: String = "system"
    @AppStorage(Inf6ApplicationSystemFont.userDefaultsKey)
    private var applicationSystemFontFamily: String = Inf6ApplicationSystemFont.systemValue
    @AppStorage(Inf6ApplicationSystemFont.sizeUserDefaultsKey)
    private var applicationSystemFontSize: Double = Inf6ApplicationSystemFont.defaultSize
    @Environment(\.scenePhase) private var scenePhase

    private var applicationSystemFont: Font {
        let family = applicationSystemFontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        return family.isEmpty
            ? .system(size: applicationSystemFontSize)
            : .custom(family, size: applicationSystemFontSize)
    }

    init() {
        // App-wide defaults. This ensures `gen_lang` is always configured.
        UserDefaults.standard.register(defaults: [
            "gen_lang": "auto",
            "inf6_ui_language": "auto"
        ])
        Inf6DailySyllabusRefreshScheduler.register()
        // 保存先が到達不能な状態では、別 root への移行や書き込みを開始しない。
        // 先に初期設定でユーザーが保存先を選び直す。
        if Inf6EntityImageLocation.displayPath != nil
            && !Inf6EntityImageLocation.hasUnavailableStoredSelection {
            Task.detached(priority: .utility) {
                Inf6MetadataStore.migrateIfNeeded()
                Inf6DailySyllabusRefreshScheduler.scheduleNext()
                Inf6ErrorIntelligence.clearExpiredRules()
            }
        }
        _ = Inf6WatchConnectivityPhone.shared
    }

    private var preferredScheme: ColorScheme? {
        switch appearanceModeRaw {
        case "light":
            return .light
        case "dark":
            return .dark
        default:
            return nil // follow system
        }
    }

    var body: some Scene {
        WindowGroup("Arcane Derivation Codex", id: "main") {
            Inf6RootView()
                .preferredColorScheme(preferredScheme)
                .environment(\.font, applicationSystemFont)
                .textSelection(.enabled)
                .inf6OnChange(scenePhase) { phase in
                    if phase == .active {
                        Task { @MainActor in
                            await Inf6AppUpdateChecker.shared.check()
                        }
                    }
                }
        }
        WindowGroup("Arcane Derivation Codex — 論文", id: "paper", for: URL.self) { $url in
            if let url {
                Inf6PaperWindowView(url: url)
                    .preferredColorScheme(preferredScheme)
                    .environment(\.font, applicationSystemFont)
                .textSelection(.enabled)
            }
        }

        WindowGroup("Arcane Derivation Codex — 解説", id: "explanation", for: String.self) { $rawID in
            if let rawID {
                Inf6ExplanationWindowView(rawID: rawID)
                    .preferredColorScheme(preferredScheme)
                    .environment(\.font, applicationSystemFont)
                .textSelection(.enabled)
            }
        }

    }
}
