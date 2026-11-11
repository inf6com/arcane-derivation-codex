//
//  Inf6CanonicalConcept.swift
//  inf6
//
//  工学的契約（全体集合契約）:
//    - U（知の全体集合）の各要素は canonical ID を持つ。
//    - 同一概念が複数シラバスで異なるラベルを持つ場合、ラベル差は alias として
//      扱い、ノードは1つに統合する。
//    - U = D₁ ∪ D₂ ∪ … ∪ D_n （n はその時点で取り込まれているドメイン数）
//
//  本ファイルは canonical 概念 (= U の要素) の永続化と alias 解決を担う。
//
//  ストレージ:
//    - metadata file store: `Inf6MetadataStore.Domain.canonicalConcepts`
//        key = canonical_id, value = Inf6CanonicalConcept JSON
//    - metadata file store: `Inf6MetadataStore.Domain.canonicalAliases`
//        key = normalized alias 文字列, value = canonical_id（素文字列）
//
//  v1 範囲:
//    - title 文字列ベースの完全一致 alias 解決
//    - register / resolve / addAlias / listAll / concepts(forDomain:)
//
//  v1 が扱わない範囲:
//    - 同義語の自動検出（→ コーパス分析契約）
//    - bilingual 自動マッピング（"Attention" ↔ "アテンション"）
//    - canonical concept のマージ（複数 canonical を1つに統合する移管処理）
//

import Foundation

// MARK: - Model

public struct Inf6CanonicalConcept: Codable, Hashable {
    public let canonicalID: String              // 例: "concept:正則化"
    public var displayTitleJA: String?          // 日本語表示用 title
    public var displayTitleEN: String?          // 英語表示用 title
    public var aliases: Set<String>             // 正規化済 alias 集合（resolve 用）
    public var classificationID: String?        // 既知の分類 ID（最初に観測したもの）
    public var sourceDomains: Set<String>       // この概念が属するドメイン集合 (各 D_i の所属示)
    public var createdAt: TimeInterval
    public var updatedAt: TimeInterval

    public init(
        canonicalID: String,
        displayTitleJA: String? = nil,
        displayTitleEN: String? = nil,
        aliases: Set<String> = [],
        classificationID: String? = nil,
        sourceDomains: Set<String> = [],
        createdAt: TimeInterval = Date().timeIntervalSince1970,
        updatedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.canonicalID = canonicalID
        self.displayTitleJA = displayTitleJA
        self.displayTitleEN = displayTitleEN
        self.aliases = aliases
        self.classificationID = classificationID
        self.sourceDomains = sourceDomains
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 表示用 title。優先度: JA → EN → canonical_id の末尾。
    public var displayTitle: String {
        if let t = displayTitleJA, !t.isEmpty { return t }
        if let t = displayTitleEN, !t.isEmpty { return t }
        if let last = canonicalID.split(separator: ":").last { return String(last) }
        return canonicalID
    }
}

// MARK: - Registry

public enum Inf6CanonicalConceptRegistry {

    /// 与えられた title 文字列に対応する canonical_id を返す。
    /// alias 索引 (`canonicalAliases`) を経由した完全一致で解決する。
    public static func resolve(title rawTitle: String) -> String? {
        let key = _normalize(rawTitle)
        guard !key.isEmpty else { return nil }
        return Inf6MetadataStore.get(domain: .canonicalAliases, key: key)
    }

    /// canonical_id で概念を取得する。
    public static func get(_ canonicalID: String) -> Inf6CanonicalConcept? {
        return Inf6MetadataStore.getCodable(Inf6CanonicalConcept.self, domain: .canonicalConcepts, key: canonicalID)
    }

    /// 概念を新規登録 or 既存にマージする。canonical_id を返す。
    /// 既存があれば alias と sourceDomains を和集合化する。
    @discardableResult
    public static func register(
        title: String,
        titleEN: String? = nil,
        classificationID: String? = nil,
        domain: String
    ) -> String {
        let normalized = _normalize(title)
        precondition(!normalized.isEmpty, "register requires a non-empty title")

        // 既存 canonical を探す: まず alias 索引、なければ titleEN による alias 索引
        var existingID: String? = Inf6MetadataStore.get(domain: .canonicalAliases, key: normalized)
        if existingID == nil, let en = titleEN {
            let enKey = _normalize(en)
            if !enKey.isEmpty {
                existingID = Inf6MetadataStore.get(domain: .canonicalAliases, key: enKey)
            }
        }

        let canonicalID = existingID ?? _generateCanonicalID(fromTitle: title)
        var concept = get(canonicalID) ?? Inf6CanonicalConcept(canonicalID: canonicalID)

        // displayTitle の更新（既存に nil の場合だけ）
        if concept.displayTitleJA?.isEmpty ?? true, _containsJapanese(title) {
            concept.displayTitleJA = title
        } else if concept.displayTitleJA == nil, !_containsJapanese(title), titleEN == nil {
            // JA がなく入力が英語のみの場合は EN として扱う
        }
        if let en = titleEN, !en.isEmpty, concept.displayTitleEN?.isEmpty ?? true {
            concept.displayTitleEN = en
        } else if concept.displayTitleEN == nil, !_containsJapanese(title) {
            concept.displayTitleEN = title
        }

        // alias 和集合
        concept.aliases.insert(normalized)
        if let en = titleEN { concept.aliases.insert(_normalize(en)) }

        // 分類 ID（初出のみ採用）
        if concept.classificationID == nil, let c = classificationID, !c.isEmpty {
            concept.classificationID = c
        }

        // ドメイン和集合
        if !domain.isEmpty { concept.sourceDomains.insert(domain) }

        concept.updatedAt = Date().timeIntervalSince1970
        Inf6MetadataStore.putCodable(concept, domain: .canonicalConcepts, key: canonicalID)

        // alias 索引の更新（normalized title → canonical_id）
        for alias in concept.aliases {
            Inf6MetadataStore.put(domain: .canonicalAliases, key: alias, json: canonicalID)
        }

        return canonicalID
    }

    /// 既存 canonical に手動で alias を追加する（同義語の手動マッピング用）。
    public static func addAlias(canonicalID: String, alias: String) {
        guard var concept = get(canonicalID) else { return }
        let key = _normalize(alias)
        guard !key.isEmpty else { return }
        concept.aliases.insert(key)
        concept.updatedAt = Date().timeIntervalSince1970
        Inf6MetadataStore.putCodable(concept, domain: .canonicalConcepts, key: canonicalID)
        Inf6MetadataStore.put(domain: .canonicalAliases, key: key, json: canonicalID)
    }

    /// 全 canonical 概念を返す（U の現在のスナップショット）。
    public static func listAll() -> [Inf6CanonicalConcept] {
        return Inf6MetadataStore.listAllCodable(Inf6CanonicalConcept.self, domain: .canonicalConcepts).map { $0.value }
    }

    /// 指定ドメインに属する概念のみを返す（D_i のスナップショット）。
    public static func concepts(forDomain domain: String) -> [Inf6CanonicalConcept] {
        return listAll().filter { $0.sourceDomains.contains(domain) }
    }

    // MARK: - Private helpers

    /// canonical ID 生成: "concept:" + 正規化 title（ASCII safe slug）
    /// 同じ title を 2 回 register しても同じ ID になる安定性が必要。
    private static func _generateCanonicalID(fromTitle title: String) -> String {
        let slug = _normalize(title)
        return "concept:\(slug)"
    }

    /// alias 索引キー・canonical_id スラグ両方で使う正規化。
    /// - trim
    /// - lowercase
    /// - 連続空白を単一空白に
    private static func _normalize(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return "" }
        var out = ""
        out.reserveCapacity(trimmed.count)
        var lastWasSpace = false
        for ch in trimmed {
            if ch == " " || ch == "\t" || ch == "\n" {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(ch)
                lastWasSpace = false
            }
        }
        return out
    }

    private static func _containsJapanese(_ s: String) -> Bool {
        return s.range(of: #"[ぁ-んァ-ヶ一-龥々]"#, options: .regularExpression) != nil
    }
}
