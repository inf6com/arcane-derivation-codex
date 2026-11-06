import SwiftUI

struct PaperDiscoveryView: View {
    let language: InterfaceLanguage
    let rootPath: String
    let leaf: SyllabusLeaf
    @State private var query: String
    @State private var results: [ArXivPaperResult] = []
    @State private var busy = false
    @State private var message: String?
    @State private var cropPaper: PaperRecord?
    @State private var chatCrop: PaperCrop?

    private var isJapanese: Bool { language == .japanese }

    init(language: InterfaceLanguage, rootPath: String, leaf: SyllabusLeaf) {
        self.language = language
        self.rootPath = rootPath
        self.leaf = leaf
        _query = State(initialValue: leaf.title)
    }

    var body: some View {
        List {
            Section(isJapanese ? "選択した学習対象" : "Selected learning target") {
                Text(leaf.title).textSelection(.enabled)
            }
            Section(isJapanese ? "ArXivから論文を取得" : "Retrieve papers from ArXiv") {
                TextField(isJapanese ? "論文検索語" : "Paper search terms", text: $query)
                Button(busy ? (isJapanese ? "検索中…" : "Searching…") : (isJapanese ? "論文を検索" : "Search papers")) { search() }
                    .disabled(busy)
            }
            ForEach(results) { result in
                VStack(alignment: .leading, spacing: 8) {
                    Text(result.title).font(.headline).textSelection(.enabled)
                    Text(result.summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(4)
                    HStack {
                        Link(isJapanese ? "原典を開く" : "Open source", destination: result.abstractURL)
                        Button(isJapanese ? "PDFを取得" : "Retrieve PDF") { retrieve(result) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.vertical, 6)
            }
            if let message { Text(message).foregroundStyle(.red).textSelection(.enabled) }
        }
        .navigationTitle(isJapanese ? "論文取得" : "Retrieve paper")
        .navigationDestination(item: $cropPaper) { paper in
            PaperCropEditorView(rootPath: rootPath, paper: paper) { crop in
                chatCrop = crop
                cropPaper = nil
            }
        }
        .navigationDestination(item: $chatCrop) { crop in
            FormulaChatView(language: language, rootPath: rootPath, sourceTitle: crop.title, sourceLocator: "page \(crop.page)", sourceEvidenceID: crop.evidence.id, sourceImageRelativePath: crop.imageRelativePath)
        }
    }

    private func search() {
        busy = true
        message = nil
        Task {
            do { results = try await ArXivSearchService().search(query: query) }
            catch { message = error.localizedDescription }
            busy = false
        }
    }

    private func retrieve(_ result: ArXivPaperResult) {
        busy = true
        message = nil
        Task {
            do {
                let (temporaryURL, response) = try await URLSession.shared.download(from: result.pdfURL)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ArXivSearchError.unavailable }
                let safeID = result.id.split(separator: "/").last.map(String.init)?.replacingOccurrences(of: ".", with: "-") ?? UUID().uuidString
                let namedURL = FileManager.default.temporaryDirectory.appendingPathComponent("arxiv-\(safeID).pdf")
                try? FileManager.default.removeItem(at: namedURL)
                try FileManager.default.copyItem(at: temporaryURL, to: namedURL)
                defer { try? FileManager.default.removeItem(at: namedURL) }
                let workspace = try WorkspaceStore(root: URL(fileURLWithPath: rootPath))
                let imported = try PaperImportService(root: workspace).importPDF(from: namedURL)
                let record = PaperRecord(id: imported.record.id, domainID: "e-qualification", chapterID: leaf.id, title: result.title, sourceURL: result.abstractURL, pdfRelativePath: imported.record.pdfRelativePath, originVerified: false, originVerificationFailure: "ArXivの論文メタデータは取得済みですが、原典の引用情報検証は未完了です。")
                try PaperRepository(root: workspace).save(record)
                cropPaper = record
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
}
