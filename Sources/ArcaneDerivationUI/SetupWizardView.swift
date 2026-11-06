import SwiftUI
import UniformTypeIdentifiers

struct SetupWizardView: View {
    @Binding var language: String
    @Binding var rootPath: String
    let onRootChange: (URL) throws -> Void
    let onComplete: () -> Void
    @State private var page = 0
    @State private var folderPickerPresented = false
    @State private var syllabusURL = "https://www.jdla.org/certificate/engineer/"
    @State private var syllabusRevision = ""
    @State private var syllabusMessage: String?
    @State private var syllabusAvailable = false
    @State private var rootMessage: String?
    @State private var setupErrorMessage: String?
    @State private var provider: AIProvider = .openAI
    @State private var model = AIProvider.openAI.defaultModel
    @State private var apiKey = ""
    @State private var providerMessage: String?
    @State private var providerBusy = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(jp("初期設定", "Initial setup")).font(.largeTitle.bold())
                Text(stepName).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            ProgressView(value: Double(page + 1), total: 5).tint(.blue).padding(.horizontal, 24)
            ScrollView {
                pageContent
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let setupErrorMessage {
                Text(setupErrorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.horizontal, 24)
            }
            HStack {
                if page > 0 { Button(jp("戻る", "Back")) { page -= 1 } }
                Spacer()
                if page < 4 { Button(jp("次へ", "Next")) { advance() }.buttonStyle(.borderedProminent) }
                else { Button(jp("利用を開始", "Start using Arcane Derivation Codex")) { completeSetup() }.buttonStyle(.borderedProminent).disabled(!canComplete) }
            }
            .padding(24)
        }
        .textSelection(.enabled)
        .fileImporter(isPresented: $folderPickerPresented,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else {
                    rootMessage = jp("保存先が選択されませんでした。", "No storage root was selected.")
                    return
                }
                do {
                    let started = url.startAccessingSecurityScopedResource()
                    defer { if started { url.stopAccessingSecurityScopedResource() } }
                    try onRootChange(url)
                    rootPath = url.path
                    rootMessage = nil
                } catch {
                    rootMessage = error.localizedDescription
                }
            case .failure(let error):
                rootMessage = jp("保存先を選択できません: \(error.localizedDescription)", "Could not select the storage root: \(error.localizedDescription)")
            }
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case 0: languagePage
        case 1: rootPage
        case 2: syllabusPage
        case 3: providerPage
        default: paperPage
        }
    }

    private var languagePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(jp("言語", "Language")).font(.title2.bold())
            Picker(jp("表示言語", "Display language"), selection: $language) {
                Text("日本語").tag(InterfaceLanguage.japanese.rawValue)
                Text("English").tag(InterfaceLanguage.english.rawValue)
            }
            .pickerStyle(.inline)
        }
    }

    private var rootPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(jp("保存先", "Storage root")).font(.title2.bold())
            Text(jp("論文、シラバス、導出履歴、生成物をここへ保存します。", "Papers, syllabi, derivations, and generated artifacts are saved here."))
                .foregroundStyle(.secondary).textSelection(.enabled)
            Text(rootPath.isEmpty ? jp("未設定", "Not set") : rootPath)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            Button(jp("保存先を選択", "Choose storage root")) { folderPickerPresented = true }.buttonStyle(.borderedProminent)
            if let rootMessage { Text(rootMessage).foregroundStyle(.red).textSelection(.enabled) }
        }
    }

    private var syllabusPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(jp("プリセットドメイン：E資格", "Preset domain: E-Qualification")).font(.title2.bold())
            Text(syllabusAvailable ? jp("保存済みのシラバスを最新情報と照合します。", "Compare the saved syllabus with the latest information.") : jp("E資格の最新シラバス情報を取得してください。", "Retrieve the latest E-Qualification syllabus."))
                .foregroundStyle(.secondary).textSelection(.enabled)
            Link(jp("JDLA E資格シラバス", "JDLA E-Qualification syllabus"), destination: URL(string: syllabusURL)!)
            Button(syllabusAvailable ? jp("E資格シラバスを最新確認", "Check the latest E-Qualification syllabus") : jp("E資格シラバスを取得", "Retrieve the E-Qualification syllabus")) {
                verifySyllabus()
            }
            .buttonStyle(.borderedProminent)
            if let syllabusMessage { Text(syllabusMessage).textSelection(.enabled).foregroundStyle(syllabusMessage.hasPrefix("取得済み:") ? Color.green : Color.red) }
        }
        .task {
            loadExistingSyllabus()
        }
    }

    private var providerPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(jp("AIプロバイダを選択", "Select an AI provider"))
                .font(.title2.bold())
            Picker(jp("AIプロバイダ", "AI provider"), selection: $provider) {
                ForEach(AIProvider.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .onChange(of: provider) { _, value in
                model = value.defaultModel
                apiKey = APIKeychain.load(for: value) ?? ""
                providerMessage = nil
            }
            TextField(jp("モデル名", "Model name"), text: $model)
                .textInputAutocapitalization(.never)
            if provider.needsAPIKey {
                SecureField(jp("APIキー", "API key"), text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .textContentType(.oneTimeCode)
                    .autocorrectionDisabled(true)
                Text(apiKey.isEmpty ? jp("APIキー：未入力", "API key: Not entered") : jp("APIキー：入力済み", "API key: Entered"))
                    .font(.caption)
                    .foregroundStyle(apiKey.isEmpty ? Color.secondary : Color.green)
            }
            Button(providerBusy ? jp("接続を確認中…", "Checking connection…") : jp("AIプロバイダを検証して保存", "Verify and save AI provider")) {
                saveProvider()
            }
            .buttonStyle(.borderedProminent)
            .disabled(providerBusy)
            if let providerMessage {
                Text(providerMessage)
                    .foregroundStyle(providerMessage.hasPrefix("接続済み:") ? Color.green : Color.red)
                    .textSelection(.enabled)
            }
        }
        .task {
            guard !rootPath.isEmpty else { return }
            do {
                let workspace = try WorkspaceStore(root: URL(fileURLWithPath: rootPath))
                if let configuration = try AIProviderConfigurationStore(root: workspace).load() {
                    provider = configuration.provider
                    model = configuration.model
                }
                apiKey = APIKeychain.load(for: provider) ?? ""
            } catch {
                providerMessage = error.localizedDescription
            }
        }
    }

    private var paperPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(jp("論文探索", "Paper discovery")).font(.title2.bold())
            HStack {
                Text("ArXiv")
                Spacer()
                Text(jp("標準", "Default")).foregroundStyle(.secondary)
            }
            Text(jp("利用開始後に論文を検索できます。", "Search papers after setup is complete."))
                .foregroundStyle(.secondary)
        }
    }

    // The E-Qualification syllabus is an optional preset. Storage is the only
    // prerequisite for entering the app; the preset can be installed later.
    private var canComplete: Bool { !rootPath.isEmpty }

    private var stepName: String {
        [jp("言語", "Language"), jp("保存先", "Storage"), jp("シラバス", "Syllabus"), jp("AI", "AI"), jp("論文探索", "Paper discovery")][page]
    }

    private func advance() {
        if page == 1 {
            guard !rootPath.isEmpty else {
                rootMessage = jp("保存先を選択してください。", "Choose a storage root before continuing.")
                return
            }
            guard Inf6EntityImageLocation.resolvedURL() != nil else {
                rootMessage = jp(
                    "保存済みの保存先にアクセスできません。フォルダを選び直してください。",
                    "The saved storage location is inaccessible. Choose the folder again."
                )
                return
            }
            rootMessage = nil
        }
        setupErrorMessage = nil
        page += 1
    }

    private func jp(_ japanese: String, _ english: String) -> String {
        language == InterfaceLanguage.english.rawValue ? english : japanese
    }

    private func saveProvider() {
        guard !rootPath.isEmpty else {
            providerMessage = "保存先を設定してください。"
            return
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            providerMessage = "モデル名を入力してください。"
            return
        }
        providerBusy = true
        providerMessage = nil
        Task {
            do {
                let configuration = AIProviderConfiguration(provider: provider, model: model)
                let key = provider.needsAPIKey ? apiKey : nil
                _ = try await AIProviderClient(configuration: configuration, apiKey: key)
                    .generate(prompt: "接続確認。OKだけを返してください。")
                if provider.needsAPIKey { try APIKeychain.save(apiKey, for: provider) }
                let workspace = try WorkspaceStore(root: URL(fileURLWithPath: rootPath))
                try AIProviderConfigurationStore(root: workspace).save(configuration)
                providerMessage = "接続済み: \(provider.rawValue) / \(model)"
            } catch {
                providerMessage = error.localizedDescription
            }
            providerBusy = false
        }
    }

    private func verifySyllabus() {
        guard let url = URL(string: syllabusURL), url.scheme == "https" else { syllabusMessage = "HTTPSの公式URLを入力してください。"; return }
        syllabusMessage = "確認中…"
        Task {
            do {
                let root = try WorkspaceStore(root: URL(fileURLWithPath: rootPath))
                let refresh = try await SyllabusUpdateService(root: root).refresh(domain: "E資格", sourceURL: url)
                persistCodexOutlineIfAvailable(refresh.snapshot)
                syllabusRevision = refresh.snapshot.revision
                syllabusAvailable = true
                syllabusMessage = "取得済み: \(refresh.snapshot.domainName) / \(refresh.snapshot.revision)"
            } catch { syllabusMessage = error.localizedDescription }
        }
    }

    private func persistCodexOutlineIfAvailable(_ snapshot: SyllabusSnapshot) {
        guard let rawContent = snapshot.content, !rawContent.isEmpty else { return }
        let plainText = rawContent
            .replacingOccurrences(of: #"<[^>]+>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
        let outline = Inf6EshikakuOutlineExtractor.extract(from: plainText)
        guard outline.count >= 12 else { return }
        do {
            let cacheURL = try Inf6Storage.syllabusOutlineCacheURL()
            var cache = Inf6DiskJSON.load([String: [Inf6SyllabusOutlineItem]].self, from: cacheURL) ?? [:]
            cache["eshikaku_outline:\(snapshot.revision)"] = outline
            try Inf6DiskJSON.save(cache, to: cacheURL)
        } catch {
            NSLog("[SetupWizard] E資格 outline cache was not written: %@", error.localizedDescription)
        }
    }

    private func loadExistingSyllabus() {
        guard !rootPath.isEmpty else { return }
        let path = rootPath
        Task {
            do {
                let workspace = try WorkspaceStore(root: URL(fileURLWithPath: path))
                guard let snapshot = try SyllabusRepository(root: workspace).current(domain: "E資格") else { return }
                syllabusRevision = snapshot.revision
                syllabusAvailable = true
                syllabusMessage = "取得済み: \(snapshot.domainName) / \(snapshot.revision)"
            } catch {
                syllabusMessage = error.localizedDescription
            }
        }
    }

    private func completeSetup() {
            do {
                let workspace = try WorkspaceStore(root: URL(fileURLWithPath: rootPath))
                try PaperSearchConfigurationStore(root: workspace).save(PaperSearchConfiguration(sources: [.arxiv]))
                let marker = "{\"completed\":true,\"version\":1}"
                guard Inf6MetadataStore.put(domain: .settings, key: "initial_setup_completed", json: marker) else {
                    throw WorkspaceError.rootUnavailable
                }
                setupErrorMessage = nil
                onComplete()
            } catch {
                setupErrorMessage = error.localizedDescription
        }
    }
}
