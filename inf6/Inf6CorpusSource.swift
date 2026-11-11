//
//  Inf6CorpusSource.swift
//  inf6
//
//  工学的契約（コーパス分析契約）:
//    - U の構築は、関連全文書を対象にしたコーパス分析を経由して達成される。
//    - コーパス構成要素には、各 Provider から取得した全シラバス本文、論文、
//      ユーザー取り込み PDF、Microsoft Learn / arXiv / PubMed 等の関連公式
//      ドキュメントが含まれる。
//
//  本ファイルは、外部から取得したシラバス源泉（HTML 等）を **加工せず raw のまま**
//  metadata file store に保存するレイヤを提供する。パースや概念抽出はこの上位レイヤで行う。
//
//  ストレージ:
//    - metadata file store: `Inf6MetadataStore.Domain.corpusSources`
//        key = sourceID（例 "microsoft_ai_102/ai102-study-guide"）
//        value = Inf6CorpusSource JSON
//
//  最新性保証契約:
//    - fetch 時に HTTP の Last-Modified / ETag を保存する。
//    - 次回 fetch では If-None-Match / If-Modified-Since を送って 304 を期待する。
//    - 失敗は表面化させ、サイレントに古い content を「最新」と偽装してはならない。
//

import Foundation

// MARK: - Model

public struct Inf6CorpusSource: Codable, Hashable {
    /// 一意な源泉 ID。慣習として "<domain>/<source-key>" 形式（例 "microsoft_ai_102/ai102-study-guide"）。
    public let sourceID: String
    /// 取得元 URL（原文書）。
    public let sourceURL: String
    /// content の種類: "html" / "text" / "markdown" / "pdf_text" 等。
    public let contentType: String
    /// 本文。HTML の場合はタグを含む raw のまま。加工なし。
    public let content: String
    /// 取得時刻（UNIX epoch 秒）。
    public let fetchedAt: TimeInterval
    /// HTTP ETag ヘッダ（あれば）。
    public let etag: String?
    /// HTTP Last-Modified ヘッダ（あれば）。
    public let lastModified: String?
    /// 取得元の所属ドメイン（例 "microsoft_ai_102"）。
    public let domainID: String?

    public init(
        sourceID: String,
        sourceURL: String,
        contentType: String,
        content: String,
        fetchedAt: TimeInterval,
        etag: String?,
        lastModified: String?,
        domainID: String?
    ) {
        self.sourceID = sourceID
        self.sourceURL = sourceURL
        self.contentType = contentType
        self.content = content
        self.fetchedAt = fetchedAt
        self.etag = etag
        self.lastModified = lastModified
        self.domainID = domainID
    }
}

// MARK: - Fetcher

public enum Inf6CorpusSourceFetcher {

    public enum FetchError: Error, LocalizedError {
        case invalidURL
        case httpError(statusCode: Int)
        case emptyBody
        case decodingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid source URL."
            case .httpError(let code): return "HTTP error: status code \(code)."
            case .emptyBody: return "Response body was empty."
            case .decodingFailed(let s): return "Failed to decode response body: \(s)."
            }
        }
    }

    /// 既存の保存済みエントリを取得（無ければ nil）。
    public static func get(sourceID: String) -> Inf6CorpusSource? {
        return Inf6MetadataStore.getCodable(Inf6CorpusSource.self, domain: .corpusSources, key: sourceID)
    }

    /// 与えられた URL を fetch し、結果を metadata file store に保存して返す。
    /// 既存に保存済みエントリがあれば conditional request（ETag / Last-Modified）を送って 304 を期待する。
    /// 304 の場合は既存エントリの content をそのまま再利用し、`fetchedAt` のみ現時刻に更新する。
    @discardableResult
    public static func fetchAndStore(
        url: URL,
        sourceID: String,
        domainID: String?,
        contentType: String = "html"
    ) async throws -> Inf6CorpusSource {
        let previous = get(sourceID: sourceID)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag = previous?.etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lm = previous?.lastModified, !lm.isEmpty {
            request.setValue(lm, forHTTPHeaderField: "If-Modified-Since")
        }
        request.setValue("inf6/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html, */*;q=0.5", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.decodingFailed("not an HTTPURLResponse")
        }

        // 304 Not Modified → 既存 content を保持しつつ fetchedAt 更新
        if http.statusCode == 304, let prev = previous {
            let refreshed = Inf6CorpusSource(
                sourceID: prev.sourceID,
                sourceURL: prev.sourceURL,
                contentType: prev.contentType,
                content: prev.content,
                fetchedAt: Date().timeIntervalSince1970,
                etag: prev.etag,
                lastModified: prev.lastModified,
                domainID: prev.domainID
            )
            Inf6MetadataStore.putCodable(refreshed, domain: .corpusSources, key: sourceID)
            return refreshed
        }

        // 2xx 以外は failure として表面化（契約「Failures must surface」）
        guard (200..<300).contains(http.statusCode) else {
            throw FetchError.httpError(statusCode: http.statusCode)
        }

        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            throw FetchError.decodingFailed("could not decode body as UTF-8 or ASCII")
        }
        if text.isEmpty {
            throw FetchError.emptyBody
        }

        let etag = http.value(forHTTPHeaderField: "ETag")
        let lastModified = http.value(forHTTPHeaderField: "Last-Modified")
        let now = Date().timeIntervalSince1970

        let source = Inf6CorpusSource(
            sourceID: sourceID,
            sourceURL: url.absoluteString,
            contentType: contentType,
            content: text,
            fetchedAt: now,
            etag: etag,
            lastModified: lastModified,
            domainID: domainID
        )
        Inf6MetadataStore.putCodable(source, domain: .corpusSources, key: sourceID)
        return source
    }

    /// 指定ドメインに属する全 corpus source を取得（順序保証なし）。
    public static func list(forDomainID domainID: String) -> [Inf6CorpusSource] {
        return Inf6MetadataStore
            .listAllCodable(Inf6CorpusSource.self, domain: .corpusSources)
            .map { $0.value }
            .filter { $0.domainID == domainID }
    }

    /// 全 corpus source（テスト・デバッグ用）。
    public static func listAll() -> [Inf6CorpusSource] {
        return Inf6MetadataStore
            .listAllCodable(Inf6CorpusSource.self, domain: .corpusSources)
            .map { $0.value }
    }
}
