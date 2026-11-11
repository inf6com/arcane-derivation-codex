//
//  Inf6PaperSourceService.swift
//  inf6
//
//  論文の出典情報(原文 Abstract と版)を照会・保持する。
//
//  Abstract の取得は集中特訓の概要生成と論文ウィンドウの両方から必要になるため、
//  片方に閉じた実装にせず、ここに集約する。
//

import Foundation

enum Inf6PaperSourceService {

    // MARK: - Abstract

    /// 保存済みの Abstract を返す。無ければ照会して取得し、論文レコードへ保存する。
    /// 照会順は arXiv ID、タイトル指定の arXiv 照会、OpenAlex。
    @discardableResult
    static func resolveAbstract(for paper: Inf6CorePaper) async -> String {
        if let stored = paper.abstract?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored
        }

        var fetched = ""
        if let arxivID = _normalizedArxivID(paper), !arxivID.isEmpty,
           let hits = try? await Inf6ArxivClient.searchByID(arxivID: arxivID),
           let match = hits.first {
            fetched = match.abstractText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if fetched.isEmpty,
           let hits = try? await Inf6ArxivClient.search(query: "ti:\"\(paper.title)\"", maxResults: 1),
           let match = hits.first {
            fetched = match.abstractText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if fetched.isEmpty,
           let hits = try? await Inf6OpenAlexClient.searchByTitle(title: paper.title, maxResults: 1),
           let match = hits.first {
            fetched = match.abstractText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !fetched.isEmpty else {
            NSLog("[PaperSource] abstract not found for %@", paper.id)
            return ""
        }
        var updated = paper
        updated.abstract = fetched
        Inf6MetadataStore.putCodable(updated, domain: .papers, key: paper.id)
        NSLog("[PaperSource] abstract stored for %@ (%d chars)", paper.id, fetched.count)
        return fetched
    }

    /// PDF のファイル名から論文レコードを引き当てる。
    /// 集中特訓が保存する PDF は「タイトル＋ID」形式のため前方一致も許す。
    static func paperMatching(fileStem: String) -> Inf6CorePaper? {
        let stemKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: fileStem)
        guard !stemKey.isEmpty else { return nil }

        for record in Inf6MetadataStore.listAllCodable(Inf6CorePaper.self, domain: .papers) {
            let paper = record.value
            let keys = [
                Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paper.title),
                Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paper.titleEn ?? ""),
                Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: paper.id),
            ].filter { !$0.isEmpty }
            for key in keys where stemKey == key
                || stemKey.hasPrefix(key + "_")
                || key.hasPrefix(stemKey + "_") {
                return paper
            }
        }
        return nil
    }

    // MARK: - 版の更新確認

    struct VersionUpdate: Sendable {
        /// 手元が参照している版 (例: 7)
        let currentVersion: Int
        /// arXiv 上の最新版
        let latestVersion: Int
        /// 最新版の arXiv ID (版付き)
        let latestArxivID: String
    }

    /// arXiv 上に新しい版があるかを確認する。
    /// 版を判定できない、または最新でない場合のみ結果を返す。
    static func checkForNewerVersion(of paper: Inf6CorePaper) async -> VersionUpdate? {
        guard let raw = paper.arxivId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let base = _baseArxivID(raw)
        else { return nil }

        let current = _versionNumber(raw) ?? 1
        guard let hits = try? await Inf6ArxivClient.searchByID(arxivID: base),
              let match = hits.first,
              let latest = _versionNumber(match.id)
        else { return nil }

        guard latest > current else { return nil }
        NSLog("[PaperSource] newer version found for %@: v%d -> v%d", paper.id, current, latest)
        return VersionUpdate(currentVersion: current, latestVersion: latest, latestArxivID: match.id)
    }

    // MARK: - ID の解釈

    /// "http://arxiv.org/abs/1706.03762v7" などから "1706.03762v7" を取り出す。
    private static func _normalizedArxivID(_ paper: Inf6CorePaper) -> String? {
        let raw = (paper.arxivId ?? paper.id).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        guard let match = raw.range(
            of: #"\d{4}\.\d{4,5}(v\d+)?"#,
            options: .regularExpression
        ) else { return raw }
        return String(raw[match])
    }

    /// 版を除いた ID。"1706.03762v7" -> "1706.03762"
    private static func _baseArxivID(_ raw: String) -> String? {
        guard let match = raw.range(
            of: #"\d{4}\.\d{4,5}"#,
            options: .regularExpression
        ) else { return nil }
        return String(raw[match])
    }

    /// 末尾の版番号。"...v7" -> 7
    private static func _versionNumber(_ raw: String) -> Int? {
        guard let match = raw.range(
            of: #"v(\d+)\s*$"#,
            options: .regularExpression
        ) else { return nil }
        return Int(raw[match].dropFirst())
    }
}
