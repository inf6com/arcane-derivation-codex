//
//  Inf6CorpusFetchCoordinator.swift
//  inf6
//
//  工学的契約:
//    最新性保証契約 — 「inf6.com は常に最新情報とリンクしている必要がある」。
//    コーパス分析契約 — 「Microsoft Learn / arXiv / PubMed 等の関連公式
//    ドキュメントが U の構築に寄与する」。
//
//  本ファイルは、各 manifest が宣言した `current_sources` と `trend_sources` を
//  巡回 fetch し、結果を `Inf6CorpusSource` として metadata file store に蓄積するコーディネータ。
//  単発の fetch（Inf6CorpusSourceFetcher）の上位に位置する継続更新層。
//
//  動作モード:
//    - refreshAll(manifests:)：すべての manifest の全 sources を順に fetch。
//    - refreshDomain(manifest:)：単一ドメインの sources のみ fetch。
//
//  契約遵守:
//    - 失敗は表面化（errors を返す配列に蓄積し、呼び出し元に返す）。
//    - サイレントな fallback 禁止。失敗した source は metadata file store に古いまま残る；
//      UI は「最終確認時刻」と「失敗有無」をユーザに見せられる必要がある。
//    - 起動時のブロッキング fetch は禁止（呼び出し側がバックグラウンド Task で呼ぶ）。
//

import Foundation

public enum Inf6CorpusFetchCoordinator {

    public struct SourceFetchOutcome {
        public let sourceID: String
        public let sourceURL: String
        public let success: Bool
        public let error: String?
        public let fetchedAt: TimeInterval

        public init(sourceID: String, sourceURL: String, success: Bool, error: String?, fetchedAt: TimeInterval) {
            self.sourceID = sourceID
            self.sourceURL = sourceURL
            self.success = success
            self.error = error
            self.fetchedAt = fetchedAt
        }
    }

    public struct RefreshSummary {
        public let attempted: Int
        public let succeeded: Int
        public let failed: Int
        public let outcomes: [SourceFetchOutcome]
        public var lastError: String? { outcomes.first(where: { !$0.success })?.error }
    }

    /// すべての manifests について、current_sources と trend_sources を巡回 fetch。
    @discardableResult
    public static func refreshAll(manifests: [Inf6LearningFamilyManifest]) async -> RefreshSummary {
        var outcomes: [SourceFetchOutcome] = []
        for m in manifests {
            let domainOutcomes = await refreshDomain(manifest: m).outcomes
            outcomes.append(contentsOf: domainOutcomes)
        }
        let succeeded = outcomes.filter { $0.success }.count
        return RefreshSummary(
            attempted: outcomes.count,
            succeeded: succeeded,
            failed: outcomes.count - succeeded,
            outcomes: outcomes
        )
    }

    /// 単一ドメインの sources を fetch。
    @discardableResult
    public static func refreshDomain(manifest: Inf6LearningFamilyManifest) async -> RefreshSummary {
        var outcomes: [SourceFetchOutcome] = []

        // 1) current_sources: 構造化された ID 付きエントリ（manifest によっては nil）
        for target in _currentSourceTargets(for: manifest) {
            outcomes.append(
                await _fetchOne(
                    urlString: target.url,
                    sourceID: target.sourceID,
                    domainID: manifest.sourceFamily
                )
            )
        }

        // 2) trend_sources: URL のみの配列
        for (i, urlString) in manifest.trendSources.enumerated() {
            let sourceID = "\(manifest.sourceFamily)/trend-\(i)"
            outcomes.append(
                await _fetchOne(
                    urlString: urlString,
                    sourceID: sourceID,
                    domainID: manifest.sourceFamily
                )
            )
        }

        // 3) official_sources: manifest に明示された公式 URL 列。
        for (i, urlString) in manifest.officialSources.enumerated() {
            let sourceID = "\(manifest.sourceFamily)/official-\(i)"
            outcomes.append(
                await _fetchOne(
                    urlString: urlString,
                    sourceID: sourceID,
                    domainID: manifest.sourceFamily
                )
            )
        }
        outcomes.append(contentsOf: _refreshDerivedArtifacts(for: manifest))

        let succeeded = outcomes.filter { $0.success }.count
        return RefreshSummary(
            attempted: outcomes.count,
            succeeded: succeeded,
            failed: outcomes.count - succeeded,
            outcomes: outcomes
        )
    }

    // MARK: - Private

    private static func _fetchOne(urlString: String, sourceID: String, domainID: String) async -> SourceFetchOutcome {
        let now = Date().timeIntervalSince1970
        guard let url = URL(string: urlString) else {
            return SourceFetchOutcome(sourceID: sourceID, sourceURL: urlString, success: false, error: "invalid URL", fetchedAt: now)
        }
        do {
            _ = try await Inf6CorpusSourceFetcher.fetchAndStore(
                url: url,
                sourceID: sourceID,
                domainID: domainID,
                contentType: "html"
            )
            return SourceFetchOutcome(sourceID: sourceID, sourceURL: urlString, success: true, error: nil, fetchedAt: Date().timeIntervalSince1970)
        } catch {
        return SourceFetchOutcome(sourceID: sourceID, sourceURL: urlString, success: false, error: error.localizedDescription, fetchedAt: Date().timeIntervalSince1970)
        }
    }

    private static func _refreshDerivedArtifacts(for manifest: Inf6LearningFamilyManifest) -> [SourceFetchOutcome] {
        guard manifest.usesMicrosoftLearnProvider else { return [] }
        let now = Date().timeIntervalSince1970
        guard let definitions = manifest.currentSources, !definitions.isEmpty else {
            return [
                SourceFetchOutcome(
                    sourceID: "\(manifest.sourceFamily)/microsoft_learn_outline_bilingual_v1",
                    sourceURL: "",
                    success: false,
                    error: "Microsoft Learn current_sources is empty; bilingual outline cannot be built.",
                    fetchedAt: now
                )
            ]
        }

        var cache = _loadOutlineCache()
        var outcomes: [SourceFetchOutcome] = []
        var cacheChanged = false

        let outlineDefinitions = definitions.filter(_isMicrosoftLearnOutlineSource)
        guard !outlineDefinitions.isEmpty else {
            return [
                SourceFetchOutcome(
                    sourceID: "\(manifest.sourceFamily)/microsoft_learn_outline_bilingual_v1",
                    sourceURL: "",
                    success: false,
                    error: "Microsoft Learn study guide source is missing; bilingual outline cannot be built.",
                    fetchedAt: now
                )
            ]
        }

        for definition in outlineDefinitions {
            let enSourceID = "\(manifest.sourceFamily)/\(definition.id)"
            let jaSourceID = enSourceID + "@ja-jp"
            let derivedID = enSourceID + "|microsoft_learn_outline_bilingual_v1"

            guard let enSource = Inf6CorpusSourceFetcher.get(sourceID: enSourceID) else {
                outcomes.append(SourceFetchOutcome(
                    sourceID: derivedID,
                    sourceURL: definition.urlString,
                    success: false,
                    error: "Missing Microsoft Learn en-us source: \(enSourceID)",
                    fetchedAt: now
                ))
                continue
            }
            guard let jaSource = Inf6CorpusSourceFetcher.get(sourceID: jaSourceID) else {
                outcomes.append(SourceFetchOutcome(
                    sourceID: derivedID,
                    sourceURL: definition.urlString,
                    success: false,
                    error: "Missing Microsoft Learn ja-jp source: \(jaSourceID)",
                    fetchedAt: now
                ))
                continue
            }

            let enItems = Inf6MicrosoftLearnOutlineParser.extract(from: enSource.content)
            let jaItems = Inf6MicrosoftLearnOutlineParser.extract(from: jaSource.content)
            do {
                let items = try _mergeMicrosoftLearnBilingualOutline(enItems: enItems, jaItems: jaItems, sourceID: derivedID)
                let cacheKey = enSource.sourceURL + "|microsoft_learn_outline_bilingual_v1"
                if cache[cacheKey] != items {
                    cache[cacheKey] = items
                    cacheChanged = true
                }
                outcomes.append(SourceFetchOutcome(
                    sourceID: derivedID,
                    sourceURL: enSource.sourceURL,
                    success: true,
                    error: nil,
                    fetchedAt: now
                ))
            } catch {
                outcomes.append(SourceFetchOutcome(
                    sourceID: derivedID,
                    sourceURL: enSource.sourceURL,
                    success: false,
                    error: error.localizedDescription,
                    fetchedAt: now
                ))
            }
        }

        if cacheChanged {
            do {
                try _saveOutlineCache(cache)
            } catch {
                outcomes.append(SourceFetchOutcome(
                    sourceID: "\(manifest.sourceFamily)/microsoft_learn_outline_bilingual_v1/cache",
                    sourceURL: "",
                    success: false,
                    error: "Failed to save Microsoft Learn bilingual outline cache: \(error.localizedDescription)",
                    fetchedAt: now
                ))
            }
        }

        return outcomes
    }

    private static func _mergeMicrosoftLearnBilingualOutline(
        enItems: [Inf6SyllabusOutlineItem],
        jaItems: [Inf6SyllabusOutlineItem],
        sourceID: String
    ) throws -> [Inf6SyllabusOutlineItem] {
        guard !enItems.isEmpty else {
            throw NSError(domain: "Inf6CorpusFetchCoordinator", code: 40, userInfo: [
                NSLocalizedDescriptionKey: "Microsoft Learn en-us outline is empty: \(sourceID)"
            ])
        }
        guard !jaItems.isEmpty else {
            throw NSError(domain: "Inf6CorpusFetchCoordinator", code: 41, userInfo: [
                NSLocalizedDescriptionKey: "Microsoft Learn ja-jp outline is empty: \(sourceID)"
            ])
        }
        guard enItems.count == jaItems.count else {
            throw NSError(domain: "Inf6CorpusFetchCoordinator", code: 42, userInfo: [
                NSLocalizedDescriptionKey: "Microsoft Learn bilingual outline count mismatch: \(sourceID) en=\(enItems.count) ja=\(jaItems.count)"
            ])
        }

        var out: [Inf6SyllabusOutlineItem] = []
        out.reserveCapacity(enItems.count)
        for i in enItems.indices {
            let en = enItems[i]
            let ja = jaItems[i]
            guard en.effectiveDepth == ja.effectiveDepth else {
                throw NSError(domain: "Inf6CorpusFetchCoordinator", code: 43, userInfo: [
                    NSLocalizedDescriptionKey: "Microsoft Learn bilingual outline depth mismatch: \(sourceID) index=\(i) en=\(en.effectiveDepth) ja=\(ja.effectiveDepth)"
                ])
            }
            out.append(Inf6SyllabusOutlineItem(
                key: en.key,
                title: ja.title,
                summary: ja.summary,
                titleJa: ja.titleJa ?? ja.title,
                titleEn: en.titleEn ?? en.title,
                summaryJa: ja.summaryJa ?? ja.summary,
                summaryEn: en.summaryEn ?? en.summary,
                depth: en.depth
            ))
        }
        return out
    }

    private static func _loadOutlineCache() -> [String: [Inf6SyllabusOutlineItem]] {
        guard let url = try? Inf6Storage.syllabusOutlineCacheURL() else { return [:] }
        return Inf6DiskJSON.load([String: [Inf6SyllabusOutlineItem]].self, from: url) ?? [:]
    }

    private static func _saveOutlineCache(_ cache: [String: [Inf6SyllabusOutlineItem]]) throws {
        let url = try Inf6Storage.syllabusOutlineCacheURL()
        try Inf6DiskJSON.save(cache, to: url)
    }

    private static func _allTargets(for manifest: Inf6LearningFamilyManifest) -> [(sourceID: String, url: String)] {
        var list: [(String, String)] = []
        list.append(contentsOf: _currentSourceTargets(for: manifest))
        for (i, u) in manifest.trendSources.enumerated() {
            list.append(("\(manifest.sourceFamily)/trend-\(i)", u))
        }
        for (i, u) in manifest.officialSources.enumerated() {
            list.append(("\(manifest.sourceFamily)/official-\(i)", u))
        }
        return list
    }

    private static func _currentSourceTargets(for manifest: Inf6LearningFamilyManifest) -> [(sourceID: String, url: String)] {
        var list: [(sourceID: String, url: String)] = []
        for entry in (manifest.currentSources ?? []) {
            let baseID = "\(manifest.sourceFamily)/\(entry.id)"
            list.append((baseID, entry.urlString))
            if let jaURL = _microsoftLearnJapaneseURL(entry.urlString) {
                list.append((baseID + "@ja-jp", jaURL))
            }
        }
        return list
    }

    private static func _microsoftLearnJapaneseURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().contains("learn.microsoft.com/en-us/") else { return nil }
        return trimmed.replacingOccurrences(of: "/en-us/", with: "/ja-jp/")
    }

    private static func _isMicrosoftLearnOutlineSource(_ source: Inf6MicrosoftLearnSourceDefinition) -> Bool {
        let id = source.id.lowercased()
        let url = source.urlString.lowercased()
        return id.contains("study-guide") || url.contains("/resources/study-guides/")
    }
}
