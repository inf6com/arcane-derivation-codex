//
//  Inf6CorePaperAbstractStore.swift
//  inf6
//
//  Core Paper の論文要旨をキャッシュ・取得するストア。
//  arXiv API (Inf6ArxivClient) を使い、要旨テキストを
//  ApplicationSupport/inf6/core_paper_abstracts.json に保存する。
//

import Foundation

// MARK: - Model

struct Inf6CorePaperAbstractEntry: Codable {
    var paperId: String
    var abstractText: String
    var fetchedAt: Date
    var source: String          // "arxiv" | "manual" | "bundle"
    var publishedAt: Date?
    var updatedAt: Date?
}

// MARK: - Store

@Observable
final class Inf6CorePaperAbstractStore {
    static let shared = Inf6CorePaperAbstractStore()

    /// paperId → entry
    private(set) var entries: [String: Inf6CorePaperAbstractEntry] = [:]

    /// paperId → 取得中フラグ
    private(set) var fetchingIds: Set<String> = []

    /// paperId → 最後のエラー文字列
    private(set) var fetchErrors: [String: String] = [:]

    private let saveURL: URL

    init() {
        let dir = Inf6DataRoot.url().appendingPathComponent("cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        saveURL = dir.appendingPathComponent("core_paper_abstracts.json")
        load()
    }

    // MARK: - Access

    func abstract(for paperId: String) -> String? {
        entries[paperId]?.abstractText
    }

    func hasFetched(_ paperId: String) -> Bool {
        entries[paperId] != nil
    }

    func isFetching(_ paperId: String) -> Bool {
        fetchingIds.contains(paperId)
    }

    // MARK: - Fetch

    /// arXiv論文の要旨を取得して保存する
    @MainActor
    func fetchAbstract(for paper: Inf6CorePaper) async {
        guard !fetchingIds.contains(paper.id) else { return }

        // bundle/local curricula: no abstract to fetch
        if paper.provider == "bundle" {
            storeBundleAbstract(for: paper)
            return
        }

        guard let arxivId = paper.arxivId else {
            fetchErrors[paper.id] = "arXiv IDがありません（direct providerは手動入力してください）"
            return
        }

        fetchingIds.insert(paper.id)
        fetchErrors.removeValue(forKey: paper.id)

        do {
            let results = try await Inf6ArxivClient.searchByID(arxivID: arxivId)
            if let result = results.first, !result.abstractText.isEmpty {
                let entry = Inf6CorePaperAbstractEntry(
                    paperId: paper.id,
                    abstractText: result.abstractText,
                    fetchedAt: Date(),
                    source: "arxiv",
                    publishedAt: result.publishedAt,
                    updatedAt: result.updatedAt
                )
                entries[paper.id] = entry
                save()
            } else {
                fetchErrors[paper.id] = "arXiv APIから要旨を取得できませんでした"
            }
        } catch {
            fetchErrors[paper.id] = error.localizedDescription
        }

        fetchingIds.remove(paper.id)
    }

    /// バンドルリソース（カリキュラム文書等）の説明文を手動で登録する
    @MainActor
    func storeManual(paperId: String, text: String) {
        let entry = Inf6CorePaperAbstractEntry(
            paperId: paperId,
            abstractText: text,
            fetchedAt: Date(),
            source: "manual",
            publishedAt: nil,
            updatedAt: nil
        )
        entries[paperId] = entry
        save()
    }

    /// バンドル論文の概要を組み込む
    @MainActor
    private func storeBundleAbstract(for paper: Inf6CorePaper) {
        guard entries[paper.id] == nil else { return }
        // カリキュラムPDFはタイトルと用途を要旨として登録
        let text = "【カリキュラム文書】\(paper.title)\n\nE資格の実装理解を目的としたPyTorch特訓100課題。Tensor/GPU、単語ID化・Embedding、テキスト分類、品詞タグ付け（LSTM）、CoNLL形式POS/NER、UD Japanese GSD読解、Attention/Transformer実装、最小CNNの章構成。Jetson TX1 + PyTorch 1.11系を想定。inf6.com 到達度測定に接続する章ID・課題ID・合格条件つき。"
        let entry = Inf6CorePaperAbstractEntry(
            paperId: paper.id,
            abstractText: text,
            fetchedAt: Date(),
            source: "bundle",
            publishedAt: nil,
            updatedAt: nil
        )
        entries[paper.id] = entry
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: saveURL.path) else { return }
        do {
            let data = try Inf6SafeFileRead.data(at: saveURL)
            let decoded = try JSONDecoder().decode([String: Inf6CorePaperAbstractEntry].self, from: data)
            entries = decoded
        } catch {
            print("[Inf6CorePaperAbstractStore] load failed: \(error)")
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: saveURL, options: .atomic)
        } catch {
            print("[Inf6CorePaperAbstractStore] save failed: \(error)")
        }
    }
}
