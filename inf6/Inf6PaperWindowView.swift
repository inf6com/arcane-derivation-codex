//
//  Inf6PaperWindowView.swift
//  inf6
//
//  PDF 表示・図表パイプラインの独立ウィンドウ。
//

import SwiftUI
#if canImport(PDFKit)
import PDFKit
#endif

struct Inf6PaperWindowView: View {

    let initialURL: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @AppStorage("gen_lang") private var genLangRaw: String = "ja"
    @State private var pdfURL: URL
    @State private var explanation: String = ""
    @State private var currentPage: Int = 0
    @State private var pageExtraNotes: [Int: [Inf6ExtraNote]] = [:]
    @State private var pageExplanationCache: [Int: String] = [:]
    @State private var isRunningPipeline: Bool = false
    @State private var pipelineState: Inf6AssetsPipelineRunState = .none
    @State private var errorMessage: String?
    @State private var currentPDFCacheKey: String?

    // 出典の確認: 原文 Abstract の取得と、arXiv 上の新しい版の有無
    /// 版の更新確認を行うかどうか。ウィンドウを開くたびに arXiv へ問い合わせるため、
    /// 利用者が切れるようにする。設定は保存する。
    @AppStorage("inf6_paper_check_updates") private var _checkUpdatesEnabled: Bool = true
    @State private var _sourcePaper: Inf6CorePaper?
    @State private var _versionUpdate: Inf6PaperSourceService.VersionUpdate?
    @State private var _isDownloadingUpdate = false
    @State private var _updateMessage: String?

    init(url: URL) {
        self.initialURL = url
        self._pdfURL = State(initialValue: url)
        self._currentPDFCacheKey = State(initialValue: url.lastPathComponent)
    }

    var body: some View {
        NavigationStack {
            _pdfContent
                .navigationTitle(pdfURL.deletingPathExtension().lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            openWindow(id: "main")
                            dismiss()
                        } label: {
                            Label(Inf6Lang.text("戻る", "Back"), systemImage: "chevron.left")
                        }
                        .accessibilityLabel(Inf6Lang.text("論文画面へ戻る", "Back to paper screen"))
                    }
                    ToolbarItem(placement: .primaryAction) {
                        _updateCheckToggle
                    }
                    ToolbarItem(placement: .primaryAction) {
                        _pipelineButton
                    }
                }
        }
        .onAppear {
            pipelineState = inf6LoadAssetsPipelineRunState(pdfURL: pdfURL)
            _loadPersistedNotes()
        }
        .task(id: pdfURL.standardizedFileURL.path) {
            await _checkPaperSource()
        }
        .safeAreaInset(edge: .top) {
            _updateBanner
        }
    }


    /// 更新確認の有無を切り替えるチェックボックス。
    private var _updateCheckToggle: some View {
        Button {
            _checkUpdatesEnabled.toggle()
            if !_checkUpdatesEnabled { _versionUpdate = nil }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: _checkUpdatesEnabled ? "checkmark.square.fill" : "square")
                Text(Inf6Lang.text("更新確認", "Check updates"))
                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(12), weight: .semibold))
            }
        }
        .buttonStyle(.plain)
        .help(Inf6Lang.text(
            "開いたときに arXiv 上の新しい版を確認する",
            "Check arXiv for a newer version when opening"
        ))
        .accessibilityLabel(Inf6Lang.text("更新確認", "Check updates"))
    }

    /// 新しい版が見つかったときだけ出す帯。取り込むかどうかは利用者が決める。
    @ViewBuilder
    private var _updateBanner: some View {
        if let update = _versionUpdate {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle")
                VStack(alignment: .leading, spacing: 2) {
                    Text(Inf6Lang.text(
                        "新しい版があります (v\(update.currentVersion) → v\(update.latestVersion))",
                        "A newer version is available (v\(update.currentVersion) → v\(update.latestVersion))"
                    ))
                    .font(.subheadline.weight(.semibold))
                    Text(Inf6Lang.text("ダウンロードしますか。", "Download it?"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if _isDownloadingUpdate {
                    ProgressView().tint(.pink).scaleEffect(1.25).controlSize(.small)
                } else {
                    Button(Inf6Lang.text("ダウンロード", "Download")) {
                        Task { await _downloadUpdate(update) }
                    }
                    .buttonStyle(.borderedProminent)
                    Button(Inf6Lang.text("後で", "Later")) {
                        _versionUpdate = nil
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(12)
            .background(.regularMaterial)
        } else if let message = _updateMessage {
            HStack(spacing: 8) {
                Text(message).font(.caption)
                Spacer(minLength: 8)
                Button(Inf6Lang.text("閉じる", "Close")) { _updateMessage = nil }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(12)
            .background(.regularMaterial)
        }
    }

    /// 論文ウィンドウを開いた時点で、原文 Abstract の取得と版の確認を行う。
    private func _checkPaperSource() async {
        let stem = pdfURL.deletingPathExtension().lastPathComponent
        guard let paper = Inf6PaperSourceService.paperMatching(fileStem: stem) else { return }
        _sourcePaper = paper

        // 要旨欄が空にならないよう、未保存なら取得して保存する。
        await Inf6PaperSourceService.resolveAbstract(for: paper)

        guard _checkUpdatesEnabled else { return }
        if let update = await Inf6PaperSourceService.checkForNewerVersion(of: paper) {
            _versionUpdate = update
        }
    }

    private func _downloadUpdate(_ update: Inf6PaperSourceService.VersionUpdate) async {
        guard let paper = _sourcePaper else { return }
        _isDownloadingUpdate = true
        defer { _isDownloadingUpdate = false }
        do {
            guard let url = URL(string: "https://arxiv.org/pdf/\(update.latestArxivID).pdf") else { return }
            let data = try await Inf6PaperSaveShared.downloadValidatedPDFData(from: url)
            try data.write(to: pdfURL, options: .atomic)
            var updated = paper
            updated.abstract = nil
            Inf6MetadataStore.putCodable(updated, domain: .papers, key: paper.id)
            _versionUpdate = nil
            _updateMessage = Inf6Lang.text(
                "v\(update.latestVersion) を取り込みました。",
                "Updated to v\(update.latestVersion)."
            )
        } catch {
            _updateMessage = error.localizedDescription
        }
    }

    // MARK: - PDF Content

    @ViewBuilder
    private var _pdfContent: some View {
        InlinePDFPagesView(
            url: pdfURL,
            onTap: { pageIndex, text, rectDesc in
                currentPage = pageIndex
            },
            explanation: $explanation,
            onPageChange: { page in
                currentPage = page
                return pageExplanationCache[page] ?? (explanation.isEmpty ? nil : explanation)
            },
            assetsPipelineAllPagesAction: {
                await _runAssetsPipeline()
            },
            selectedPage: $currentPage,
            loadExtraNotes: { page in
                pageExtraNotes[page]
            },
            saveExtraNotes: { page, notes in
                DispatchQueue.main.async {
                    pageExtraNotes[page] = notes
                    _persistNotes()
                }
            }
        )
        .id(pdfURL.standardizedFileURL.path)
    }

    // MARK: - Pipeline Button

    @ViewBuilder
    private var _pipelineButton: some View {
        switch pipelineState {
        case .running:
            ProgressView().tint(.pink).scaleEffect(1.25)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Button {
                Task { await _runAssetsPipeline() }
            } label: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        case .none:
            Button {
                Task { await _runAssetsPipeline() }
            } label: {
                Label(Inf6Lang.text("図表分析", "Analyze"), systemImage: "wand.and.stars")
            }
        }
    }

    // MARK: - Assets Pipeline

    @MainActor
    private func _runAssetsPipeline() async {
        guard _openAIKeyIsSet() else {
            errorMessage = Inf6Lang.text(
                "OpenAI APIキーが未設定です。",
                "OpenAI API key is not set."
            )
            return
        }

        let url = pdfURL
        pipelineState = .running
        inf6SaveAssetsPipelineRunState(pdfURL: url, state: .running)
        isRunningPipeline = true
        defer { isRunningPipeline = false }

        do {
#if canImport(PDFKit)
            let stopScope = _startSecurityScope(url)
            defer { stopScope() }
            guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
                pipelineState = .failed
                inf6SaveAssetsPipelineRunState(pdfURL: url, state: .failed)
                errorMessage = Inf6Lang.text("PDFを開けません。", "Cannot open PDF.")
                return
            }
#endif

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
                    return try await Inf6LibraryView.askOpenAIText(
                        systemInstruction: rendered.systemInstruction,
                        userPrompt: rendered.userPrompt,
                        lang: targetLang
                    )
                }
            )

            pageExtraNotes.removeAll(keepingCapacity: true)

            for b in bundles {
                let pageIndex = b.pageResult.pageIndex
                let renderedNotes = b.pageResult.renderedNotes
                if !renderedNotes.isEmpty {
                    pageExtraNotes[pageIndex] = renderedNotes.map { rendered in
                        Inf6ExtraNote(
                            text: rendered.text,
                            structuredTable: rendered.structuredTable
                        )
                    }
                }
            }

            pipelineState = .finished
            inf6SaveAssetsPipelineRunState(pdfURL: url, state: .finished)
            _persistNotes()

        } catch {
            pipelineState = .failed
            inf6SaveAssetsPipelineRunState(pdfURL: url, state: .failed)
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Notes Persistence

    private func _persistNotes() {
        guard let key = currentPDFCacheKey, !key.isEmpty else { return }
        guard let root = try? Inf6LibraryView._sharedRootDir() else { return }
        let folderKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: pdfURL)
        guard !folderKey.isEmpty else { return }
        let dir = root
            .appendingPathComponent(Inf6KnowledgeCardsPaths.rootFolderName, isDirectory: true)
            .appendingPathComponent(folderKey, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let notesURL = dir.appendingPathComponent("extra_notes.json")
        if let data = try? JSONEncoder().encode(pageExtraNotes) {
            try? data.write(to: notesURL, options: .atomic)
        }
    }

    private func _loadPersistedNotes() {
        let folderKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: pdfURL)
        guard !folderKey.isEmpty else { return }
        guard let root = try? Inf6LibraryView._sharedRootDir() else { return }
        let notesURL = root
            .appendingPathComponent(Inf6KnowledgeCardsPaths.rootFolderName, isDirectory: true)
            .appendingPathComponent(folderKey, isDirectory: true)
            .appendingPathComponent("extra_notes.json")
        guard let data = try? Data(contentsOf: notesURL),
              let decoded = try? JSONDecoder().decode([Int: [Inf6ExtraNote]].self, from: data) else { return }
        pageExtraNotes = decoded
    }

    // MARK: - Helpers

    private func _openAIKeyIsSet() -> Bool {
        (try? OpenAIKeyStore.load())?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func _startSecurityScope(_ url: URL) -> () -> Void {
        let std = url.standardizedFileURL
        var stopped: [URL] = []
        for candidate in [std.deletingLastPathComponent(), std] {
            let c = candidate.standardizedFileURL
            if c.startAccessingSecurityScopedResource() {
                stopped.append(c)
            }
        }
        return { stopped.reversed().forEach { $0.stopAccessingSecurityScopedResource() } }
    }
}
