import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Binding var language: InterfaceLanguage
    @Binding var rootPath: String
    let onLanguageChange: (InterfaceLanguage) -> Void
    let onRootChange: (String) throws -> Void
    @State private var folderPickerPresented = false
    @State private var provider: AIProvider = .openAI
    @State private var model = AIProvider.openAI.defaultModel
    @State private var apiKey = ""
    @State private var providerMessage: String?
    @State private var providerBusy = false
    @State private var paperMessage: String?
    @State private var paperRecords: [PaperRecord] = []
    @State private var selectedPaper: PaperRecord?
    @State private var paperImporterPresented = false
    @State private var rootMessage: String?
    @State private var syllabus: SyllabusSnapshot?
    @State private var syllabusFailure: String?
    @State private var bundledModels: [BundledModelStatus] = []

    var body: some View {
        Form {
            Section(language == .japanese ? "表示" : "Display") {
                Picker(language == .japanese ? "言語" : "Language", selection: $language) {
                    Text("日本語").tag(InterfaceLanguage.japanese)
                    Text("English").tag(InterfaceLanguage.english)
                }
                .onChange(of: language) { _, value in onLanguageChange(value) }
            }
            Section(language == .japanese ? "保存先" : "Storage") {
                Text(rootPath.isEmpty ? (language == .japanese ? "未設定" : "Not set") : rootPath)
                    .textSelection(.enabled)
                Button(language == .japanese ? "保存先を選択" : "Choose storage root") { folderPickerPresented = true }
                if let rootMessage { Text(rootMessage).foregroundStyle(.red).textSelection(.enabled) }
            }
            Section(language == .japanese ? "AIプロバイダ" : "AI provider") {
                Picker(language == .japanese ? "Provider" : "Provider", selection: $provider) {
                    ForEach(AIProvider.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: provider) { _, value in
                    model = value.defaultModel
                    apiKey = APIKeychain.load(for: value) ?? ""
                    providerMessage = nil
                }
                TextField(language == .japanese ? "モデル" : "Model", text: $model)
                    .textInputAutocapitalization(.never)
                if provider.needsAPIKey {
                    SecureField(language == .japanese ? "APIキー" : "API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                }
                Button(language == .japanese ? "Providerを検証して保存" : "Verify and save provider") { saveProvider() }
                    .disabled(providerBusy)
                if let providerMessage { Text(providerMessage).font(.caption).textSelection(.enabled) }
            }
            Section(language == .japanese ? "E資格" : "E-Qualification") {
                if let syllabus {
                    Text(syllabus.domainName).font(.headline).textSelection(.enabled)
                    Text(syllabus.revision).textSelection(.enabled)
                    if let sourceURL = syllabus.sourceURL {
                        Link(language == .japanese ? "JDLA公式シラバス" : "JDLA official syllabus", destination: sourceURL)
                    }
                    Text(syllabus.checkedAt.formatted(date: .numeric, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text(language == .japanese ? "シラバス未取得" : "Syllabus not retrieved")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let syllabusFailure {
                    Text(syllabusFailure).foregroundStyle(.red).textSelection(.enabled)
                }
                Button(language == .japanese ? "E資格シラバスを更新" : "Update E-Qualification syllabus") {
                    refreshSyllabus()
                }
            }
            Section(language == .japanese ? "論文データ" : "Paper data") {
                Button(language == .japanese ? "論文原典PDFを登録" : "Register source paper PDF") {
                    paperImporterPresented = true
                }
                ForEach(paperRecords) { paper in
                    Button {
                        selectedPaper = paper
                    } label: {
                        HStack {
                            Text(paper.title).lineLimit(1).textSelection(.enabled)
                            Spacer()
                            Text("\(paper.crops.count)件").foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                if paperRecords.isEmpty {
                    Text(language == .japanese ? "論文原典PDFが未登録です。" : "No source PDF is registered.")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button(language == .japanese ? "クロップの重複を整理" : "Deduplicate paper crops") {
                    deduplicatePaperCrops()
                }
                if let paperMessage { Text(paperMessage).font(.caption).textSelection(.enabled) }
            }
            Section(language == .japanese ? "ローカルAI" : "Local AI") {
                ForEach(bundledModels) { model in
                    HStack {
                        Image(systemName: model.available ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(model.available ? Color.green : Color.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName)
                            if let loadFailure = model.loadFailure {
                                Text(loadFailure)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
        .fileImporter(isPresented: $folderPickerPresented,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                do {
                    try onRootChange(url.path)
                    rootPath = url.path
                    rootMessage = nil
                    paperRecords = []
                    Task { await reloadWorkspaceData() }
                } catch {
                    rootMessage = error.localizedDescription
                }
            }
        }
        .fileImporter(isPresented: $paperImporterPresented, allowedContentTypes: [.pdf]) { result in
            importPaper(result)
        }
        .navigationDestination(item: $selectedPaper) { paper in
            PaperCropEditorView(rootPath: rootPath, paper: paper) { crop in
                paperMessage = language == .japanese ? "保存しました: \(crop.title)" : "Saved: \(crop.title)"
                Task { await reloadWorkspaceData() }
            }
        }
        .task {
            if !rootPath.isEmpty {
                do {
                    let workspace = try WorkspaceStore(root: URL(fileURLWithPath: rootPath))
                    if let configuration = try AIProviderConfigurationStore(root: workspace).load() {
                        provider = configuration.provider
                        model = configuration.model
                    }
                } catch {
                    providerMessage = error.localizedDescription
                }
            }
            apiKey = APIKeychain.load(for: provider) ?? ""
            bundledModels = BundledModelCatalog().statuses()
            await reloadWorkspaceData()
        }
    }

    private func reloadWorkspaceData() async {
        guard !rootPath.isEmpty else {
            syllabus = nil
            paperRecords = []
            return
        }
        let path = rootPath
        let syllabusResult = await Task.detached(priority: .userInitiated) {
            Result<SyllabusSnapshot?, Error> {
                let workspace = try WorkspaceStore(root: URL(fileURLWithPath: path))
                let repository = SyllabusRepository(root: workspace)
                return try repository.current(domain: "E資格")
            }
        }.value
        let papersResult = await Task.detached(priority: .userInitiated) {
            Result<[PaperRecord], Error> {
                let workspace = try WorkspaceStore(root: URL(fileURLWithPath: path))
                return try PaperRepository(root: workspace).allRecords()
            }
        }.value

        switch syllabusResult {
        case .success(let snapshot):
            syllabus = snapshot
            do {
                let workspace = try WorkspaceStore(root: URL(fileURLWithPath: path))
                syllabusFailure = try SyllabusRepository(root: workspace).refreshStatus(domain: "E資格")?.lastFailure
            } catch {
                syllabusFailure = error.localizedDescription
            }
        case .failure(let error):
            syllabus = nil
            syllabusFailure = error.localizedDescription
        }
        switch papersResult {
        case .success(let records): paperRecords = records
        case .failure(let error):
            paperRecords = []
            paperMessage = error.localizedDescription
        }
    }

    private func saveProvider() {
        guard !rootPath.isEmpty else { providerMessage = language == .japanese ? "保存先を設定してください。" : "Set a storage root first."; return }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { providerMessage = language == .japanese ? "モデル名を入力してください。" : "Enter a model name."; return }
        providerBusy = true
        providerMessage = nil
        Task {
            do {
                let configuration = AIProviderConfiguration(provider: provider, model: model)
                let key = provider.needsAPIKey ? apiKey : nil
                _ = try await AIProviderClient(configuration: configuration, apiKey: key).generate(prompt: "接続確認。OKだけを返してください。")
                if provider.needsAPIKey { try APIKeychain.save(apiKey, for: provider) }
                let workspace = try WorkspaceStore(root: URL(fileURLWithPath: rootPath))
                try AIProviderConfigurationStore(root: workspace).save(configuration)
                providerMessage = language == .japanese ? "接続済み: \(provider.rawValue) / \(model)" : "Connected: \(provider.rawValue) / \(model)"
            } catch {
                providerMessage = error.localizedDescription
            }
            providerBusy = false
        }
    }

    private func deduplicatePaperCrops() {
        guard !rootPath.isEmpty else { paperMessage = language == .japanese ? "保存先を設定してください。" : "Set a storage root first."; return }
        do {
            let workspace = try WorkspaceStore(root: URL(fileURLWithPath: rootPath))
            let result = try PaperRepository(root: workspace).deduplicateCrops()
            paperMessage = language == .japanese
                ? "統合: \(result.referenceMap.count)件 / 削除画像: \(result.duplicateImageRelativePaths.count)件"
                : "Merged: \(result.referenceMap.count) / Removed images: \(result.duplicateImageRelativePaths.count)"
            Task { await reloadWorkspaceData() }
        } catch {
            paperMessage = error.localizedDescription
        }
    }

    private func importPaper(_ result: Result<URL, Error>) {
        do {
            let sourceURL = try result.get()
            guard !rootPath.isEmpty else { throw WorkspaceError.rootUnavailable }
            let accessing = sourceURL.startAccessingSecurityScopedResource()
            defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }
            let workspace = try WorkspaceStore(root: URL(fileURLWithPath: rootPath))
            let imported = try PaperImportService(root: workspace).importPDF(from: sourceURL)
            Task { await reloadWorkspaceData() }
            paperMessage = language == .japanese
                ? "登録しました: \(imported.record.title)（\(imported.pageCount)ページ）"
                : "Registered: \(imported.record.title) (\(imported.pageCount) pages)"
        } catch {
            paperMessage = error.localizedDescription
        }
    }

    private func refreshSyllabus() {
        guard !rootPath.isEmpty else {
            syllabusFailure = language == .japanese ? "保存先を設定してください。" : "Set a storage root first."
            return
        }
        let url = URL(string: "https://www.jdla.org/certificate/engineer/")!
        Task {
            do {
                let workspace = try WorkspaceStore(root: URL(fileURLWithPath: rootPath))
                let result = try await SyllabusUpdateService(root: workspace).refresh(domain: "E資格", sourceURL: url)
                syllabus = result.snapshot
                syllabusFailure = nil
            } catch {
                syllabusFailure = error.localizedDescription
            }
        }
    }

}
