//
//  APIKeySettingsView.swift
//  inf6
//
//  Created by decopin on 2025/07/21.
//


import Foundation
import Security
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct APIKeySettingsView: View {

    // Key is stored in Keychain via OpenAIKeyStore (AIOpenKeyStore.swift)
    @State private var apiKeyInput: String = ""
    @State private var keychainErrorMessage: String? = nil
    @State private var isHydratingFromKeychain: Bool = true
    @State private var keychainWriteDebounceTask: Task<Void, Never>? = nil
    @State private var externalEmailKeychainErrorMessage: String? = nil
    @State private var isHydratingExternalEmailFromKeychain: Bool = true
    @State private var externalEmailWriteDebounceTask: Task<Void, Never>? = nil

    @AppStorage(Inf6OpenAIModelResolver.userDefaultsModelKey)
    private var selectedModel: String = ""

    @Environment(\.dismiss) private var dismiss

    @AppStorage(Inf6OpenAIModelResolver.availableModelsUserDefaultsKey)
    private var cachedModelsJSON: String = ""

    @AppStorage(Inf6OpenAIModelResolver.availableModelsUpdatedAtKey)
    private var cachedModelsUpdatedAt: Double = 0

    @AppStorage("inf6.openai.last_used_model") private var lastUsedModel: String = ""
    @AppStorage("inf6.openai.last_used_model_at") private var lastUsedModelAt: Double = 0

    @State private var isRefreshingModels: Bool = false
    @State private var refreshModelsErrorMessage: String? = nil
    @State private var iCloudModelsErrorMessage: String? = nil

    // External API identity (required by some public APIs: tool / email / user-agent)
    @AppStorage("inf6.external_api_identity.tool") private var externalAPITool: String = ""
    @AppStorage("inf6.external_api_identity.email") private var externalAPIEmail: String = ""
    @AppStorage("inf6.external_api_identity.user_agent") private var externalAPIUserAgent: String = ""

    // App appearance (system / light / dark)
    @AppStorage("inf6.appearance.mode") private var appearanceModeRaw: String = "system"

    // Vision API detail level (low / high)
    @AppStorage(Inf6VisionDetailSetting.userDefaultsKey) private var visionDetailRaw: String = Inf6VisionDetailSetting.defaultValue

    @AppStorage("inf6.openai.text_token_models_cache_v1") private var textTokenModelsJSON: String = ""
    @AppStorage("inf6.openai.text_token_models_cache_updated_at") private var textTokenModelsUpdatedAt: Double = 0

    private var _textTokenModels: [String] {
        let raw = textTokenModelsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func _saveTextTokenModels(_ ids: [String]) {
        let unique = Array(Set(ids)).sorted()
        guard let data = try? JSONEncoder().encode(unique),
              let s = String(data: data, encoding: .utf8) else { return }
        textTokenModelsJSON = s
        textTokenModelsUpdatedAt = Date().timeIntervalSince1970
    }

    private var displayModels: [String] {
        let all = cachedModels
        let pricing = _textTokenModels
        guard !pricing.isEmpty else { return all }
        let set = Set(pricing)
        let filtered = all.filter { set.contains($0) }
        return filtered.isEmpty ? all : filtered
    }

    private var _modelsForPicker: [String] {
        let trimmedSelected = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        var modelsForPicker = displayModels
        if !trimmedSelected.isEmpty, !modelsForPicker.contains(trimmedSelected) {
            modelsForPicker.insert(trimmedSelected, at: 0)
        }
        return modelsForPicker
    }

    private var _shouldAutoRefreshModels: Bool {
        if cachedModels.isEmpty { return true }
        if cachedModelsUpdatedAt <= 0 { return true }
        return (Date().timeIntervalSince1970 - cachedModelsUpdatedAt) > (60 * 60 * 24 * 7)
    }

    private var _shouldAutoRefreshTextTokenList: Bool {
        if _textTokenModels.isEmpty { return true }
        if textTokenModelsUpdatedAt <= 0 { return true }
        return (Date().timeIntervalSince1970 - textTokenModelsUpdatedAt) > (60 * 60 * 24 * 7)
    }

    private var cachedModels: [String] {
        Inf6OpenAIModelResolver.cachedAvailableModels(fromJSON: cachedModelsJSON)
    }

    private var _trimmedAPIKey: String {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var _hasAPIKey: Bool {
        !_trimmedAPIKey.isEmpty && keychainErrorMessage == nil
    }

    private func L(_ ja: String, _ en: String) -> String {
        Locale.current.language.languageCode?.identifier == "ja" ? ja : en
    }

    private var _suggestedExternalAPITool: String {
        let bid = (Bundle.main.bundleIdentifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return bid
    }

    private var _suggestedExternalAPIUserAgent: String {
        let bid = (Bundle.main.bundleIdentifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let v = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let b = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !bid.isEmpty, !v.isEmpty, !b.isEmpty else { return "" }

        #if os(iOS)
        let platform = "iOS"
        #elseif os(macOS)
        let platform = "macOS"
        #else
        let platform = "Apple"
        #endif

        return "\(bid)/\(v) (\(platform); build \(b))"
    }

    private var _trimmedExternalAPITool: String {
        externalAPITool.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var _trimmedExternalAPIEmail: String {
        externalAPIEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var _trimmedExternalAPIUserAgent: String {
        externalAPIUserAgent.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var _externalAPIIdentityStatusMessage: String? {
        let email = _trimmedExternalAPIEmail

        if email.isEmpty {
            return "論文API連絡先メールが未設定です。"
        }
        if !email.contains("@") {
            return "連絡先メールアドレスの形式が不正です。"
        }
        return nil
    }

    private var _hasExternalAPIIdentity: Bool {
        _externalAPIIdentityStatusMessage == nil
    }

    private func _hydrateAPIKeyFromKeychain() {
        isHydratingFromKeychain = true
        keychainWriteDebounceTask?.cancel()
        keychainErrorMessage = nil

        do {
            let loaded = try OpenAIKeyStore.load()
            apiKeyInput = loaded
        } catch let e as OpenAIKeyStoreError {
            switch e {
            case .notFound:
                apiKeyInput = ""
            default:
                apiKeyInput = ""
                keychainErrorMessage = e.localizedDescription
            }
        } catch {
            apiKeyInput = ""
            keychainErrorMessage = error.localizedDescription
        }

        isHydratingFromKeychain = false
    }

    private func _hydrateExternalEmailFromKeychain() {
        isHydratingExternalEmailFromKeychain = true
        externalEmailWriteDebounceTask?.cancel()
        externalEmailKeychainErrorMessage = nil

        do {
            let loaded = try Inf6ExternalAPIIdentityKeyStore.loadEmail()
            externalAPIEmail = loaded
        } catch let e as Inf6ExternalAPIIdentityKeyStoreError {
            switch e {
            case .notFound:
                externalAPIEmail = ""
            default:
                externalAPIEmail = ""
                externalEmailKeychainErrorMessage = e.localizedDescription
            }
        } catch {
            externalAPIEmail = ""
            externalEmailKeychainErrorMessage = error.localizedDescription
        }

        isHydratingExternalEmailFromKeychain = false
    }

    private func _persistExternalEmailToKeychainFromInput() {
        externalEmailKeychainErrorMessage = nil
        let trimmed = _trimmedExternalAPIEmail

        do {
            if trimmed.isEmpty {
                try Inf6ExternalAPIIdentityKeyStore.deleteEmail()
            } else {
                try Inf6ExternalAPIIdentityKeyStore.saveEmail(trimmed)
            }
        } catch {
            externalEmailKeychainErrorMessage = error.localizedDescription
        }
    }

    private func _persistAPIKeyToKeychainFromInput() {
        keychainErrorMessage = nil
        let trimmed = _trimmedAPIKey

        do {
            if trimmed.isEmpty {
                try OpenAIKeyStore.delete()
            } else {
                try OpenAIKeyStore.save(trimmed)
            }
        } catch {
            keychainErrorMessage = error.localizedDescription
        }
    }

    private func _pasteAPIKeyFromClipboard() {
        keychainErrorMessage = nil

        #if canImport(UIKit)
        guard let s = UIPasteboard.general.string else {
            keychainErrorMessage = "クリップボードが空です。"
            return
        }
        apiKeyInput = s
        #else
        keychainErrorMessage = "この環境ではクリップボードにアクセスできません。"
        #endif
    }

    private func _hydrateModelsCacheFromDiskIfNeeded() {
        iCloudModelsErrorMessage = nil

        do {
            let loaded = try Inf6OpenAIModelResolver.loadAvailableModelsFromDisk()
            if !loaded.models.isEmpty {
                Inf6OpenAIModelResolver.cacheAvailableModels(loaded.models)
                cachedModelsUpdatedAt = loaded.updatedAt
            }
        } catch {
            iCloudModelsErrorMessage = error.localizedDescription
        }
    }

    private func _ensureModelsLoaded() {
        guard _hasAPIKey else { return }
        guard !isRefreshingModels else { return }

        isRefreshingModels = true
        refreshModelsErrorMessage = nil
        iCloudModelsErrorMessage = nil

        let key = _trimmedAPIKey

        Task {
            do {
                let models = try await Inf6OpenAIModelsService.fetchAvailableModelIDs(apiKey: key)
                let now = Date().timeIntervalSince1970

                await MainActor.run {
                    Inf6OpenAIModelResolver.cacheAvailableModels(models)
                    cachedModelsUpdatedAt = now
                }

                do {
                    try Inf6OpenAIModelResolver.saveAvailableModelsToDisk(models, updatedAt: now)
                    await MainActor.run {
                        iCloudModelsErrorMessage = nil
                    }
                } catch {
                    await MainActor.run {
                        iCloudModelsErrorMessage = error.localizedDescription
                    }
                }

                if _shouldAutoRefreshTextTokenList {
                    let textTokenIDs = try await Inf6OpenAIPricingTextTokenModelsService.fetchTextTokenModelIDs()
                    await MainActor.run {
                        _saveTextTokenModels(textTokenIDs)
                    }
                }

                await MainActor.run {
                    let trimmed = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)

                    if trimmed.isEmpty {
                        selectedModel = Inf6OpenAIModelResolver.defaultModel
                        return
                    }

                    if !models.contains(trimmed) {
                        let pricing = _textTokenModels
                        if !pricing.isEmpty {
                            let pricingSet = Set(pricing)
                            if let first = models.first(where: { pricingSet.contains($0) }) {
                                selectedModel = first
                                return
                            }
                        }
                        if models.contains(Inf6OpenAIModelResolver.defaultModel) {
                            selectedModel = Inf6OpenAIModelResolver.defaultModel
                            return
                        }
                        if let first = models.first {
                            selectedModel = first
                            return
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    refreshModelsErrorMessage = error.localizedDescription
                }
            }

            await MainActor.run {
                isRefreshingModels = false
            }
        }
    }

    private var _appearanceLabel: String {
        switch appearanceModeRaw {
        case "light": return L("ライト", "Light")
        case "dark": return L("ダーク", "Dark")
        default: return L("システム", "System")
        }
    }

    @ViewBuilder
    private var _modelsFetchStatusIcon: some View {
        if isRefreshingModels {
            ProgressView().tint(.pink).scaleEffect(1.25)
                .scaleEffect(0.85)
        } else if !cachedModels.isEmpty {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
                .accessibilityLabel(L("完了", "Done"))
        } else {
            EmptyView()
        }
    }

    var body: some View {
        NavigationView {
            Form {
                SwiftUI.Section {
                    HStack(spacing: 8) {
                        Image(systemName: _hasAPIKey ? "checkmark.circle.fill" : "xmark.circle")
                        Text(_hasAPIKey ? "設定済み" : "未設定")
                        Spacer()
                    }
                    .font(.footnote)
                    .foregroundColor(_hasAPIKey ? .green : .secondary)

                    if let msg = keychainErrorMessage,
                       !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("⚠︎ \(msg)")
                            .font(.footnote)
                            .foregroundColor(.red)
                            .textSelection(.enabled)
                    }

                    HStack(spacing: 10) {
                        SecureField("sk-...", text: $apiKeyInput)
                        #if canImport(UIKit)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        #endif
                        .disableAutocorrection(true)
                        .font(.system(.body, design: .monospaced))

                        Button {
                            _pasteAPIKeyFromClipboard()
                        } label: {
                            Label(L("ペースト", "Paste"), systemImage: "doc.on.clipboard")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.bordered)
                        .help(L("クリップボードの内容を入力欄へ貼り付けます。", "Paste from clipboard."))
                    }
                } header: {
                    Text(L("OpenAI APIキー", "OpenAI API Key"))
                } footer: {
                    Text(L("APIキーは端末内のKeychainに保存されます。", "API key is stored in the device Keychain."))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                // 初期設定の画面が「設定からいつでも変更できます」と書いている。
                // 入口が無いままでは、一度決めたら二度と変えられない。
                SwiftUI.Section {
                    NavigationLink {
                        Inf6InitialStorageSetupView(isPresented: .constant(true))
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("保存する場所", "Storage folder"))
                            Text(Inf6EntityImageLocation.displayPath
                                 ?? L("アプリのローカル領域", "The app's local folder"))
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text(L("保存先", "Storage"))
                } footer: {
                    Text(L(
                        "図・論文PDF・演習の記録を置く場所です。変更すると、これまでのものを引き取ります。",
                        "Where figures, paper PDFs, and exercise records are kept. Changing it brings the existing files along."
                    ))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                }

                SwiftUI.Section {
                    NavigationLink {
                        Inf6DataExchangeView()
                    } label: {
                        Text(L("エクスポート / インポート", "Export / Import"))
                    }
                } header: {
                    Text(L("エクスポート / インポート", "Export / Import"))
                }

                SwiftUI.Section {
                    HStack(spacing: 8) {
                        Image(systemName: _hasExternalAPIIdentity ? "checkmark.circle.fill" : "xmark.circle")
                        Text(_hasExternalAPIIdentity ? L("設定済み", "Configured") : L("未設定", "Not set"))
                        Spacer()
                    }
                    .font(.footnote)
                    .foregroundColor(_hasExternalAPIIdentity ? .green : .secondary)

                    if let msg = _externalAPIIdentityStatusMessage,
                       !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("⚠︎ \(msg)")
                            .font(.footnote)
                            .foregroundColor(.red)
                            .textSelection(.enabled)
                    }
                    if let msg = externalEmailKeychainErrorMessage,
                       !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("⚠︎ \(msg)")
                            .font(.footnote)
                            .foregroundColor(.red)
                            .textSelection(.enabled)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        TextField(L("連絡先メール", "Contact email"), text: $externalAPIEmail)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            #if canImport(UIKit)
                            .keyboardType(.emailAddress)
                            #endif
                    }
                } header: {
                    Text(L("論文API連絡先", "Paper API Contact"))
                } footer: {
                    Text(L("arXiv / PubMed など一部の論文APIは、連絡先メールアドレスを要求します。\n※ tool / User-Agent はアプリが自動設定します。", "Some paper APIs (arXiv, PubMed, etc.) require a contact email.\nNote: tool / User-Agent is set automatically."))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                SwiftUI.Section {
                    Picker(L("外観", "Appearance"), selection: $appearanceModeRaw) {
                        Text(L("システム", "System")).tag("system")
                        Text(L("ライト", "Light")).tag("light")
                        Text(L("ダーク", "Dark")).tag("dark")
                    }
                    .pickerStyle(.menu)

                    HStack(spacing: 8) {
                        Text(L("現在", "Current"))
                            .foregroundColor(.secondary)
                        Text(_appearanceLabel)
                        Spacer()
                    }
                    .font(.footnote)
                } header: {
                    Text(L("外観", "Appearance"))
                } footer: {
                    Text(L("アプリの外観（ライト/ダーク）を指定します。\n※ 反映にはアプリ最上位でこの設定を preferredColorScheme に適用している必要があります。", "Set the app appearance (light/dark).\nNote: requires preferredColorScheme to be applied at the app root."))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                SwiftUI.Section {
                    if !_hasAPIKey {
                        Text("APIキーを設定するとモデル一覧を取得できます。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        if cachedModels.isEmpty || isRefreshingModels {
                            HStack(spacing: 8) {
                                ProgressView().tint(.pink).scaleEffect(1.25)
                                Text(L("モデル一覧を取得中…", "Fetching models…"))
                                Spacer()
                            }
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        }

                        if let msg = refreshModelsErrorMessage,
                           !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("⚠︎ \(msg)")
                                .font(.footnote)
                                .foregroundColor(.red)
                                .textSelection(.enabled)
                        }
                        if let msg = iCloudModelsErrorMessage,
                           !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("⚠︎ \(msg)")
                                .font(.footnote)
                                .foregroundColor(.red)
                                .textSelection(.enabled)
                        }
                    }

                    if !_modelsForPicker.isEmpty {
                        Picker(L("モデル", "Model"), selection: $selectedModel) {
                            ForEach(_modelsForPicker, id: \.self) { id in
                                Text(id).tag(id)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(!_hasAPIKey && cachedModels.isEmpty)
                    } else {
                        Text(L("モデル一覧を取得中です…", "Fetching model list…"))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    HStack {
                        Text(L("使用モデル", "Model"))
                        Spacer()
                        _modelsFetchStatusIcon
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if cachedModelsUpdatedAt > 0 {
                            Text(L("最終更新: \(Date(timeIntervalSince1970: cachedModelsUpdatedAt).formatted(date: .abbreviated, time: .shortened))", "Last updated: \(Date(timeIntervalSince1970: cachedModelsUpdatedAt).formatted(date: .abbreviated, time: .shortened))"))
                        }
                        Text(L("選択したモデル（openai_model）は次回のAPI呼び出しから使用されます。", "The selected model will be used from the next API call."))
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)
                }
            }
                SwiftUI.Section {
                    Picker(L("Vision detail", "Vision detail"), selection: $visionDetailRaw) {
                        Text("low (85 tokens/image)").tag("low")
                        Text("high (tiles, ~1000+ tokens/image)").tag("high")
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text(L("Vision API 画像解像度", "Vision API Image Detail"))
                } footer: {
                    Text(L("パイプライン（図表検出・解説生成）で送信する画像の解像度。low は大幅に安価。high は精度が高いが高コスト。", "Image resolution for pipeline (figure detection / explanation). low is significantly cheaper. high has better accuracy but higher cost."))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

            .navigationTitle(L("設定", "Settings"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("閉じる", "Close")) {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            _hydrateAPIKeyFromKeychain()
            _hydrateExternalEmailFromKeychain()

            if cachedModels.isEmpty {
                _hydrateModelsCacheFromDiskIfNeeded()
            }

            if selectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                selectedModel = Inf6OpenAIModelResolver.defaultModel
            }

            // External API identity: tool / User-Agent are deterministic and auto-filled.
            let suggestedTool = _suggestedExternalAPITool
            if !suggestedTool.isEmpty {
                externalAPITool = suggestedTool
            }
            let suggestedUA = _suggestedExternalAPIUserAgent
            if !suggestedUA.isEmpty {
                externalAPIUserAgent = suggestedUA
            }

            if _hasAPIKey {
                let trimmed = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
                let selectionLooksInvalid = (!trimmed.isEmpty && !cachedModels.contains(trimmed))
                if _shouldAutoRefreshModels || _shouldAutoRefreshTextTokenList || selectionLooksInvalid {
                    _ensureModelsLoaded()
                }
            }
        }
        .onChange(of: apiKeyInput) { _, _ in
            if isHydratingFromKeychain { return }

            // Debounce Keychain writes: avoid delete/add on every keystroke.
            keychainWriteDebounceTask?.cancel()
            keychainWriteDebounceTask = Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if Task.isCancelled { return }

                await MainActor.run {
                    _persistAPIKeyToKeychainFromInput()

                    if _hasAPIKey {
                        _ensureModelsLoaded()
                    } else {
                        // If key was cleared (or Keychain save failed), stop showing refresh state
                        isRefreshingModels = false
                    }
                }
            }
        }
        .onChange(of: externalAPIEmail) { _, _ in
            if isHydratingExternalEmailFromKeychain { return }

            externalEmailWriteDebounceTask?.cancel()
            externalEmailWriteDebounceTask = Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if Task.isCancelled { return }

                await MainActor.run {
                    _persistExternalEmailToKeychainFromInput()
                }
            }
        }
        .onChange(of: selectedModel) { _, _ in
            let trimmed = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if _hasAPIKey, !trimmed.isEmpty, !cachedModels.contains(trimmed) {
                _ensureModelsLoaded()
            }
        }
    }

}


// MARK: - Models API (GET /v1/models) -> cached list of model IDs

enum Inf6OpenAIModelsService {
    private struct ModelsListResponse: Decodable {
        struct ModelItem: Decodable {
            let id: String
        }
        let data: [ModelItem]
    }

    static func fetchAvailableModelIDs(apiKey: String) async throws -> [String] {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return [] }

        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "Inf6OpenAIModelsService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) \(body.prefix(200))"]
            )
        }

        let decoded = try JSONDecoder().decode(ModelsListResponse.self, from: data)
        return decoded.data.map { $0.id }.sorted()
    }
}


// MARK: - Pricing page (Text tokens) -> model ID list
// We intentionally derive the filter from the public pricing page category "Text tokens".
// If parsing fails, the UI falls back to showing the account-available list from /v1/models.

enum Inf6OpenAIPricingTextTokenModelsService {
    static func fetchTextTokenModelIDs() async throws -> [String] {
        guard let url = URL(string: "https://platform.openai.com/docs/pricing") else {
            throw NSError(
                domain: "Inf6OpenAIPricingTextTokenModelsService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "invalid pricing url"]
            )
        }

        let (data, resp) = try await URLSession.shared.data(from: url)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(
                domain: "Inf6OpenAIPricingTextTokenModelsService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
            )
        }

        let html = String(data: data, encoding: .utf8) ?? ""
        let lower = html.lowercased()

        guard let start = lower.range(of: "text tokens")?.lowerBound else {
            return []
        }

        let afterStart = lower[start...]
        let endCandidates: [Range<String.Index>?] = [
            afterStart.range(of: "audio tokens"),
            afterStart.range(of: "image"),
            afterStart.range(of: "realtime"),
            afterStart.range(of: "embeddings")
        ]
        let end = endCandidates.compactMap { $0?.lowerBound }.min() ?? afterStart.endIndex
        let section = String(afterStart[..<end])

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._")
        var out: [String] = []
        out.reserveCapacity(64)

        var current = ""
        current.reserveCapacity(64)

        func flush() {
            let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.count >= 3, (s.contains("gpt") || s.hasPrefix("o")) {
                out.append(s)
            }
            current.removeAll(keepingCapacity: true)
        }

        for scalar in section.unicodeScalars {
            if allowed.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else {
                if !current.isEmpty { flush() }
            }
        }
        if !current.isEmpty { flush() }

        return Array(Set(out)).sorted()
    }
}



// MARK: - OpenAI model resolution (single source of truth)

enum Inf6ModelsCacheError: LocalizedError {
    case iCloudUnavailable
    case encode(Error)
    case decode(Error)
    case io(Error)

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            return "モデルキャッシュの保存先を解決できません。"
        case .encode(let e):
            return "モデルキャッシュのエンコードに失敗しました: \(e.localizedDescription)"
        case .decode(let e):
            return "モデルキャッシュのデコードに失敗しました: \(e.localizedDescription)"
        case .io(let e):
            return "モデルキャッシュの読み書きに失敗しました: \(e.localizedDescription)"
        }
    }
}
//
// Resolution order:
//  1) UserDefaults[openai_model] (explicit, user-selected)
//  2) UserDefaults[openai_default_model] (app-wide default override)
//  3) Info.plist key `Inf6OpenAI_DefaultModel` (bundled default override)
//  4) Built-in fallback (single place)
//
// Keep this enum defined exactly once in the module.

enum Inf6OpenAIModelResolver {
    static let userDefaultsModelKey = "openai_model"
    static let userDefaultsDefaultModelKey = "openai_default_model"
    static let infoPlistDefaultModelKey = "Inf6OpenAI_DefaultModel"

    static let availableModelsUserDefaultsKey = "openai_available_models_v1"
    static let availableModelsUpdatedAtKey = "openai_available_models_updated_at"

    /// Ultimate built-in fallback (single place). Prefer overriding via UserDefaults/Info.plist.
    static let builtInFallbackModel = "gpt-5-mini"

    @inline(__always)
    private static func _trim(_ s: String?) -> String {
        (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var defaultModel: String {
        // 2) UserDefaults default override
        let ud = UserDefaults.standard
        let fromUD = _trim(ud.string(forKey: userDefaultsDefaultModelKey))
        if !fromUD.isEmpty { return fromUD }

        // 3) Info.plist default override
        if let v = Bundle.main.object(forInfoDictionaryKey: infoPlistDefaultModelKey) as? String {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }

        // 4) Ultimate fallback (single place)
        return builtInFallbackModel
    }

    static func resolvedModel() -> String {
        let ud = UserDefaults.standard
        let m = _trim(ud.string(forKey: userDefaultsModelKey))
        // If the user explicitly set a model, use it as-is.
        // (The models list can lag behind aliases/rollouts; let the API validate.)
        if !m.isEmpty { return m }
        return defaultModel
    }

    private struct ModelsCacheFile: Codable {
        let updatedAt: Double
        let models: [String]
    }

    private static func _modelsCacheURL() throws -> URL {
        let fm = FileManager.default

        func ensureDirectory(_ url: URL) throws {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
                guard isDir.boolValue else {
                    let e = NSError(
                        domain: "Inf6ModelsCache",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Expected directory but found a file at: \(url.path)"]
                    )
                    throw Inf6ModelsCacheError.io(e)
                }
                return
            }
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: false)
            } catch {
                throw Inf6ModelsCacheError.io(error)
            }
        }

        let dir = Inf6DataRoot.url().appendingPathComponent("Inf6OpenAI", isDirectory: true)
        try ensureDirectory(dir)

        return dir.appendingPathComponent("openai_available_models_v1.json")
    }

    static func saveAvailableModelsToDisk(_ models: [String], updatedAt: Double) throws {
        let unique = Array(Set(models)).sorted()
        let payload = ModelsCacheFile(updatedAt: updatedAt, models: unique)

        let data: Data
        do {
            data = try JSONEncoder().encode(payload)
        } catch {
            throw Inf6ModelsCacheError.encode(error)
        }

        let url = try _modelsCacheURL()
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw Inf6ModelsCacheError.io(error)
        }
    }

    static func loadAvailableModelsFromDisk() throws -> (models: [String], updatedAt: Double) {
        let url = try _modelsCacheURL()

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Inf6ModelsCacheError.io(error)
        }

        let decoded: ModelsCacheFile
        do {
            decoded = try JSONDecoder().decode(ModelsCacheFile.self, from: data)
        } catch {
            throw Inf6ModelsCacheError.decode(error)
        }

        return (models: decoded.models, updatedAt: decoded.updatedAt)
    }

    static func cachedAvailableModels(fromJSON json: String? = nil) -> [String] {
        let raw = (json ?? UserDefaults.standard.string(forKey: availableModelsUserDefaultsKey) ?? "")
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return [] }
        do {
            let arr = try JSONDecoder().decode([String].self, from: data)
            return arr
        } catch {
            return []
        }
    }

    static func cacheAvailableModels(_ models: [String]) {
        // Persist in one place (UserDefaults) so other files can read without importing UI.
        let unique = Array(Set(models)).sorted()
        if let data = try? JSONEncoder().encode(unique),
           let s = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(s, forKey: availableModelsUserDefaultsKey)
        }
    }

    static func isKnownAvailableModel(_ modelID: String) -> Bool {
        let list = cachedAvailableModels()
        // If we have no cache yet, do not block (allow user to proceed).
        guard !list.isEmpty else { return true }
        return list.contains(modelID)
    }
}



enum OpenAIKeyStoreError: LocalizedError {
    case emptyKey
    case notFound
    case unexpectedData
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyKey:
            return "OpenAI APIキーが空です。"
        case .notFound:
            return "OpenAI APIキーが未設定です。"
        case .unexpectedData:
            return "Keychain内のAPIキー形式が不正です。"
        case .keychain(let status):
            switch status {
            case errSecNotAvailable:
                return "Keychainが利用できません（iCloudキーチェーンが無効の可能性）。iPadの設定 > Apple ID > iCloud > パスワードとキーチェーン を確認してください。 (OSStatus: \(status))"
            case errSecInteractionNotAllowed:
                return "端末ロック中などでKeychainにアクセスできません。アンロックして再試行してください。 (OSStatus: \(status))"
            case errSecAuthFailed:
                return "Keychain認証に失敗しました。 (OSStatus: \(status))"
            case errSecMissingEntitlement:
                return "Keychainの権限が不足しています（Keychain Sharing / Access Group を確認）。 (OSStatus: \(status))"
            default:
                return "Keychainエラー: \(status)"
            }
        }
    }
}

struct OpenAIKeyStore {
    // Bundle ID に合わせて一意であればOK（固定でいい）
    private static let service = "com.inf6.openai"
    private static let account = "api_key"

    // iCloud Keychain 同期対象にするため、ThisDeviceOnly は使わない（ThisDeviceOnly は同期不可）
    private static let accessible: CFString = kSecAttrAccessibleAfterFirstUnlock

    static func save(_ rawKey: String) throws {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw OpenAIKeyStoreError.emptyKey }

        let data = Data(key.utf8)

        // service/account で一意にし、必ず「同期あり」の項目として作り直す
        // （同期属性が付かない状態を残さない）
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny
        ]

        let statusDelete = SecItemDelete(deleteQuery as CFDictionary)
        guard statusDelete == errSecSuccess || statusDelete == errSecItemNotFound else {
            throw OpenAIKeyStoreError.keychain(statusDelete)
        }

        let add: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: accessible,
            kSecAttrSynchronizable: kCFBooleanTrue as Any
        ]

        let statusAdd = SecItemAdd(add as CFDictionary, nil)
        guard statusAdd == errSecSuccess else {
            throw OpenAIKeyStoreError.keychain(statusAdd)
        }
    }

    static func load() throws -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)

        if status == errSecItemNotFound {
            throw OpenAIKeyStoreError.notFound
        }
        guard status == errSecSuccess else {
            throw OpenAIKeyStoreError.keychain(status)
        }
        guard let data = out as? Data else {
            throw OpenAIKeyStoreError.unexpectedData
        }
        guard let key = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            throw OpenAIKeyStoreError.unexpectedData
        }
        return key
    }

    static func delete() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OpenAIKeyStoreError.keychain(status)
        }
    }
}

#if canImport(UIKit)


// MARK: - Shared helpers (OpenAI / persistence / fallbacks)

extension Inf6LibraryView {
    
    // MARK: OpenAI key presence
    
    func openAIKeyIsSet() -> Bool {
        do {
            let k = try OpenAIKeyStore.load()
            return !k.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty
        } catch let e as OpenAIKeyStoreError {
            switch e {
            case .notFound:
                return false
            default:
                // Surface the concrete reason in logs; callers can still handle the "not set" UI separately.
                print("[Inf6LibraryView] openAIKeyIsSet: Keychain error: \(e.localizedDescription)")
                return false
            }
        } catch {
            print("[Inf6LibraryView] openAIKeyIsSet: Keychain error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: OpenAI text generation (Responses API)

    static func askOpenAIText(_ prompt: String) async throws -> String {
        try await askOpenAIText(prompt, lang: nil)
    }

    static func askOpenAIText(_ prompt: String, lang: String) async throws -> String {
        try await askOpenAIText(prompt, lang: Optional(lang))
    }

    static func askOpenAIText(_ prompt: String, lang: String?) async throws -> String {
        try await askOpenAIText(prompt, lang: lang, allowWebSearch: false)
    }

    static func askOpenAIText(_ prompt: String, lang: String?, allowWebSearch: Bool) async throws -> String {
        let key = try OpenAIKeyStore.load()
        let trimmedKey = key.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw OpenAIKeyStoreError.notFound
        }

        let model = Inf6OpenAIModelResolver.resolvedModel()
        UserDefaults.standard.set(model, forKey: "inf6.openai.last_used_model")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "inf6.openai.last_used_model_at")

        let config = try OpenAIClient.Config.default(model: model)
        let client = OpenAIClient(apiKey: trimmedKey, config: config)
        if allowWebSearch {
            return try await client.generateTextWithWebSearch(prompt: prompt)
        }
        return try await client.generateText(
            messages: [.init(role: .user, text: prompt)],
            options: .init()
        )
    }

    static func askOpenAIText(systemInstruction: String, userPrompt: String, lang: String?) async throws -> String {
        try await askOpenAIText(
            systemInstruction: systemInstruction,
            userPrompt: userPrompt,
            lang: lang,
            allowWebSearch: false
        )
    }

    static func askOpenAIText(systemInstruction: String, userPrompt: String, lang: String?, allowWebSearch: Bool) async throws -> String {
        let key = try OpenAIKeyStore.load()
        let trimmedKey = key.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw OpenAIKeyStoreError.notFound
        }

        let trimmedSystem = systemInstruction.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmedSystem.isEmpty else {
            throw NSError(
                domain: "inf6.openai",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "system instruction is empty"]
            )
        }
        let trimmedUser = userPrompt.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmedUser.isEmpty else {
            throw NSError(
                domain: "inf6.openai",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "user prompt is empty"]
            )
        }

        let model = Inf6OpenAIModelResolver.resolvedModel()
        UserDefaults.standard.set(model, forKey: "inf6.openai.last_used_model")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "inf6.openai.last_used_model_at")

        let config = try OpenAIClient.Config.default(model: model)
        let client = OpenAIClient(apiKey: trimmedKey, config: config)
        if allowWebSearch {
            return try await client.generateTextWithWebSearch(
                prompt: "\(trimmedSystem)\n\n\(trimmedUser)"
            )
        }
        return try await client.generateText(
            messages: [
                .init(role: .system, text: trimmedSystem),
                .init(role: .user, text: trimmedUser)
            ],
            options: .init()
        )
    }

    static func askOpenAIJSONObject(systemInstruction: String, userPrompt: String) async throws -> String {
        let key = try OpenAIKeyStore.load().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw OpenAIKeyStoreError.notFound }

        let trimmedSystem = systemInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSystem.isEmpty, !trimmedUser.isEmpty else {
            throw NSError(
                domain: "inf6.openai.json",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "JSON generation instructions are empty"]
            )
        }

        let model = Inf6OpenAIModelResolver.resolvedModel()
        let config = try OpenAIClient.Config.default(model: model)
        let client = OpenAIClient(apiKey: key, config: config)
        return try await client.generateText(
            messages: [
                .init(role: .system, text: trimmedSystem),
                .init(role: .user, text: trimmedUser)
            ],
            options: .init(maxOutputTokens: 6000, requiresJSONObject: true)
        )
    }

    static func askOpenAICommentWebExplain(
        systemInstruction: String,
        userPrompt: String,
        lang: String?
    ) async throws -> Inf6StructuredExplain {
        struct _WebSource: Decodable {
            let url: String
            let checkedAt: String
        }

        struct _StructuredPayload: Decodable {
            let answer: String
            let paperEvidence: String
            let webEvidence: String
            let webSources: [_WebSource]
        }

        let key = try OpenAIKeyStore.load()
        let trimmedKey = key.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw OpenAIKeyStoreError.notFound
        }

        let trimmedSystem = systemInstruction.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmedSystem.isEmpty else {
            throw NSError(
                domain: "inf6.openai.structuredExplain",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "structured system instruction is empty"]
            )
        }
        let trimmedUser = userPrompt.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmedUser.isEmpty else {
            throw NSError(
                domain: "inf6.openai.structuredExplain",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "structured user prompt is empty"]
            )
        }

        let model = Inf6OpenAIModelResolver.resolvedModel()
        UserDefaults.standard.set(model, forKey: "inf6.openai.last_used_model")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "inf6.openai.last_used_model_at")

        let jsonInstruction = trimmedSystem + "\n\nRespond with a JSON object: {\"answer\": string, \"paperEvidence\": string, \"webEvidence\": string, \"webSources\": [{\"url\": string, \"checkedAt\": string}]}. Output ONLY the JSON."

        let config = try OpenAIClient.Config.default(model: model)
        let client = OpenAIClient(apiKey: trimmedKey, config: config)
        let rawText = try await client.generateText(
            messages: [
                .init(role: .system, text: jsonInstruction),
                .init(role: .user, text: trimmedUser)
            ],
            options: .init()
        )

        let payload: _StructuredPayload
        do {
            payload = try JSONDecoder().decode(_StructuredPayload.self, from: Data(rawText.utf8))
        } catch {
            throw NSError(
                domain: "inf6.openai.structuredExplain",
                code: -13,
                userInfo: [
                    NSLocalizedDescriptionKey: "Web explanation payload decode failed: \(error.localizedDescription)"
                ]
            )
        }

        let answer = payload.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let paperEvidence = payload.paperEvidence.trimmingCharacters(in: .whitespacesAndNewlines)
        let webEvidence = payload.webEvidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, !paperEvidence.isEmpty, !webEvidence.isEmpty else {
            throw NSError(
                domain: "inf6.openai.structuredExplain",
                code: -14,
                userInfo: [NSLocalizedDescriptionKey: "Structured web explanation contained empty sections."]
            )
        }

        var renderedSources: [String] = []
        renderedSources.reserveCapacity(payload.webSources.count)
        for source in payload.webSources {
            let url = source.url.trimmingCharacters(in: .whitespacesAndNewlines)
            let checkedAt = source.checkedAt.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasHttpsURL = url.range(
                of: #"^https://.+"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
            let hasDate = checkedAt.range(
                of: #"^\d{4}-\d{2}-\d{2}$"#,
                options: .regularExpression
            ) != nil
            guard hasHttpsURL, hasDate else {
                throw NSError(
                    domain: "inf6.openai.structuredExplain",
                    code: -15,
                    userInfo: [NSLocalizedDescriptionKey: "Structured web explanation contained invalid source fields."]
                )
            }
            renderedSources.append("- \(url) | \(checkedAt)")
        }

        guard !renderedSources.isEmpty else {
            throw NSError(
                domain: "inf6.openai.structuredExplain",
                code: -16,
                userInfo: [NSLocalizedDescriptionKey: "Structured web explanation had no web sources."]
            )
        }

        return Inf6StructuredExplain(
            answer: answer,
            paperEvidence: paperEvidence,
            webEvidence: webEvidence,
            webSources: renderedSources.joined(separator: "\n")
        )
    }

    // Require a JSON object so explanation generation cannot return prose or
    // Markdown where the caller expects a structured payload.
    static func askOpenAIOriginalExplanation(
        systemInstruction: String,
        userPrompt: String
    ) async throws -> String {
        let key = try OpenAIKeyStore.load()
        let trimmedKey = key.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw OpenAIKeyStoreError.notFound
        }

        let trimmedSystem = systemInstruction.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmedSystem.isEmpty else {
            throw NSError(
                domain: "inf6.openai.originalExplanation",
                code: -20,
                userInfo: [NSLocalizedDescriptionKey: "original explanation system instruction is empty"]
            )
        }
        let trimmedUser = userPrompt.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmedUser.isEmpty else {
            throw NSError(
                domain: "inf6.openai.originalExplanation",
                code: -21,
                userInfo: [NSLocalizedDescriptionKey: "original explanation user prompt is empty"]
            )
        }

        let model = Inf6OpenAIModelResolver.resolvedModel()
        UserDefaults.standard.set(model, forKey: "inf6.openai.last_used_model")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "inf6.openai.last_used_model_at")

        let config = try OpenAIClient.Config.default(model: model)
        let client = OpenAIClient(apiKey: trimmedKey, config: config)
        let trimmed = try await client.generateText(
            messages: [
                .init(role: .system, text: trimmedSystem),
                .init(role: .user, text: trimmedUser)
            ],
            options: .init(maxOutputTokens: 6000, requiresJSONObject: true)
        )
        return trimmed
    }

    static func askOpenAIVision(
        systemInstruction: String,
        userPrompt: String,
        imageDataList: [(data: Data, mimeType: String)]
    ) async throws -> String {
        let key = try OpenAIKeyStore.load()
        let trimmedKey = key.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw OpenAIKeyStoreError.notFound }

        let model = Inf6OpenAIModelResolver.resolvedModel()
        UserDefaults.standard.set(model, forKey: "inf6.openai.last_used_model")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "inf6.openai.last_used_model_at")

        let config = try OpenAIClient.Config.default(model: model)
        let client = OpenAIClient(apiKey: trimmedKey, config: config)
        return try await client.generateTextWithVision(
            systemPrompt: systemInstruction,
            userText: userPrompt,
            imageDataList: imageDataList,
            options: .init(maxOutputTokens: 4096)
        )
    }
}

#endif


enum Inf6ExternalAPIIdentityKeyStoreError: LocalizedError {
    case emptyEmail
    case invalidEmail
    case notFound
    case unexpectedData
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyEmail:
            return "連絡先メールが空です。"
        case .invalidEmail:
            return "連絡先メールアドレスの形式が不正です。"
        case .notFound:
            return "連絡先メールが未設定です。"
        case .unexpectedData:
            return "Keychain内の連絡先メール形式が不正です。"
        case .keychain(let status):
            switch status {
            case errSecNotAvailable:
                return "Keychainが利用できません（iCloudキーチェーンが無効の可能性）。端末設定の『パスワードとキーチェーン』をご確認ください。 (OSStatus: \(status))"
            case errSecInteractionNotAllowed:
                return "端末ロック中などでKeychainにアクセスできません。アンロックして再試行してください。 (OSStatus: \(status))"
            case errSecAuthFailed:
                return "Keychain認証に失敗しました。 (OSStatus: \(status))"
            case errSecMissingEntitlement:
                return "Keychainの権限が不足しています（Keychain Sharing / Access Group をご確認ください）。 (OSStatus: \(status))"
            default:
                return "Keychainエラー: \(status)"
            }
        }
    }
}

struct Inf6ExternalAPIIdentityKeyStore {
    private static let service = "com.inf6.external_api_identity"
    private static let accountEmail = "email"
    private static let accessible: CFString = kSecAttrAccessibleAfterFirstUnlock

    static func saveEmail(_ rawEmail: String) throws {
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { throw Inf6ExternalAPIIdentityKeyStoreError.emptyEmail }
        guard email.contains("@") else { throw Inf6ExternalAPIIdentityKeyStoreError.invalidEmail }

        let data = Data(email.utf8)

        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: accountEmail,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny
        ]

        let statusDelete = SecItemDelete(deleteQuery as CFDictionary)
        guard statusDelete == errSecSuccess || statusDelete == errSecItemNotFound else {
            throw Inf6ExternalAPIIdentityKeyStoreError.keychain(statusDelete)
        }

        let add: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: accountEmail,
            kSecValueData: data,
            kSecAttrAccessible: accessible,
            kSecAttrSynchronizable: kCFBooleanTrue as Any
        ]

        let statusAdd = SecItemAdd(add as CFDictionary, nil)
        guard statusAdd == errSecSuccess else {
            throw Inf6ExternalAPIIdentityKeyStoreError.keychain(statusAdd)
        }
    }

    static func loadEmail() throws -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: accountEmail,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)

        if status == errSecItemNotFound {
            throw Inf6ExternalAPIIdentityKeyStoreError.notFound
        }
        guard status == errSecSuccess else {
            throw Inf6ExternalAPIIdentityKeyStoreError.keychain(status)
        }
        guard let data = out as? Data else {
            throw Inf6ExternalAPIIdentityKeyStoreError.unexpectedData
        }
        guard let email = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else {
            throw Inf6ExternalAPIIdentityKeyStoreError.unexpectedData
        }
        return email
    }

    static func deleteEmail() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: accountEmail,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Inf6ExternalAPIIdentityKeyStoreError.keychain(status)
        }
    }
}
