//
//  inf6PaperTaxonomy.swift
//  inf6
//
//  Created by decopin on 2025/11/21.
//

import Foundation
#if canImport(Yams)
import Yams
#endif
import SwiftUI



/// Sources settings sheet (used where a standalone sheet is needed).
/// The actual toggles UI is shared via `Inf6SourcesToggleSection`.
struct Inf6SourcesSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Inf6SourcesToggleSection()
            }
            .navigationTitle(Inf6Lang.text("検索サイト", "Sources"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("閉じる", "Close")) { dismiss() }
                }
            }
        }
    }
}




// MARK: - Compatibility shim
// inf6 has an app-wide `Inf6Lang` defined elsewhere. This file only needs a
// stable way to detect Japanese mode, so provide it as an extension.
extension Inf6Lang {
    static var isJapanese: Bool {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
        return preferred.hasPrefix("ja")
    }
}

// MARK: - Taxonomy Localization for Stanford Schools/Departments

enum Inf6TaxonomyLocalization {
     struct Entry {
        let base: String
        let ja: String
        let en: String
    }

     static var entries: [String: Entry] = [:]
     static var didLoad = false



    /// ルートが配列の場合や `items:` 配列の場合も許容する。
     static func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true

        let fm = FileManager.default
        let dir = Inf6Storage.manifestsDirectory()

        // Load order:
        //  1) Xcode-bundled defaults (used as base)
        //  2) User-editable manifests in Inf6Storage.manifestsDirectory() (override bundled defaults)
        var candidates: [URL] = []

        // 1) Bundle resources
        let bundle = Bundle.main
        if let url = bundle.url(forResource: "stanford_taxonomy_labels", withExtension: "json") {
            candidates.append(url)
        }
        if let url = bundle.url(forResource: "stanford_taxonomy_labels", withExtension: "yaml") {
            candidates.append(url)
        }
        if let url = bundle.url(forResource: "stanford_taxonomy_labels", withExtension: "yml") {
            candidates.append(url)
        }

        // 2) User manifests (override)
        candidates.append(dir.appendingPathComponent("stanford_taxonomy_labels.json"))
        candidates.append(dir.appendingPathComponent("stanford_taxonomy_labels.yaml"))
        candidates.append(dir.appendingPathComponent("stanford_taxonomy_labels.yml"))

        for url in candidates {
            guard fm.fileExists(atPath: url.path) else { continue }
            if url.pathExtension.lowercased() == "json" {
                if let map = loadFromJSON(url: url) {
                    entries.merge(map) { _, new in new }
                    print("[Inf6TaxonomyLocalization] loaded \(map.count) entries from \(url.lastPathComponent)")
                } else {
                    print("[Inf6TaxonomyLocalization] failed to load labels from \(url.lastPathComponent) (JSON parser returned nil)")
                }
            } else {
                #if canImport(Yams)
                if let map = loadFromYAML(url: url) {
                    entries.merge(map) { _, new in new }
                    print("[Inf6TaxonomyLocalization] loaded \(map.count) entries from \(url.lastPathComponent)")
                } else {
                    print("[Inf6TaxonomyLocalization] failed to load labels from \(url.lastPathComponent) (YAML parser returned nil)")
                }
                #else
                print("[Inf6TaxonomyLocalization] Yams not available; cannot load labels from \(url.lastPathComponent)")
                #endif
            }
        }

        if entries.isEmpty {
            // stanford_taxonomy_labels.* が見つからないか、読み込みに失敗した場合は
            // ExploreCourses が返す英語名をそのまま使う。
            print("[Inf6TaxonomyLocalization] no taxonomy labels file found; using fallback names only.")
        } else {
            print("[Inf6TaxonomyLocalization] total loaded label entries: \(entries.count)")
        }
    }

     static func loadFromJSON(url: URL) -> [String: Entry]? {
        do {
            let data = try Data(contentsOf: url)
            let obj = try JSONSerialization.jsonObject(with: data, options: [])
            return parseRoot(obj)
        } catch {
            print("[Inf6TaxonomyLocalization] JSON load failed: \(error)")
            return nil
        }
    }

    #if canImport(Yams)
     static func loadFromYAML(url: URL) -> [String: Entry]? {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard let any = try Yams.load(yaml: text) else {
                return nil
            }
            return parseRoot(any)
        } catch {
            print("[Inf6TaxonomyLocalization] YAML load failed: \(error)")
            return nil
        }
    }
    #endif

     static func parseRoot(_ any: Any) -> [String: Entry]? {
        var result: [String: Entry] = [:]

        func addItems(_ arr: [[String: Any]]) {
            for m in arr {
                // primary key: key / code / name のどれか
                let primaryRawKey = (
                    (m["key"] as? String) ??
                    (m["code"] as? String) ??
                    (m["name"] as? String) ??
                    ""
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !primaryRawKey.isEmpty else { continue }

                let base = (m["label"] as? String ?? "")
                let ja = (m["label_ja"] as? String ?? "")
                let en = (m["label_en"] as? String ?? "")
                let entry = Entry(base: base, ja: ja, en: en)

                func register(_ raw: String) {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    let key = trimmed.lowercased()
                    // 後勝ち（既存の仕様と同じ）
                    result[key] = entry
                }

                // メインキー
                register(primaryRawKey)

                // code/name が別途あれば別名としても登録しておく
                if let code = m["code"] as? String {
                    register(code)
                }
                if let name = m["name"] as? String {
                    register(name)
                }
            }
        }

        if let dict = any as? [String: Any] {
            if let schools = dict["schools"] as? [[String: Any]] {
                addItems(schools)
            }
            if let depts = dict["departments"] as? [[String: Any]] {
                addItems(depts)
            }
            if let items = dict["items"] as? [[String: Any]] {
                addItems(items)
            }
        } else if let arr = any as? [[String: Any]] {
            addItems(arr)
        }

        return result.isEmpty ? nil : result
    }

    /// 日本語モードなら「label_ja → label_en → label/fallback」、
    /// それ以外は「label_en → label_ja → label/fallback」の順に選択する。
    static func localizedLabel(for key: String, fallback base: String) -> String {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return base }
        loadIfNeeded()

        let lookupKey = trimmedKey.lowercased()

        guard let entry = entries[lookupKey] else {
            // ローカライズテーブルにエントリが無い場合は、ExploreCourses の英語名そのままを返す
            return base
        }

        let baseLabel = entry.base.isEmpty ? base : entry.base

        if Inf6Lang.isJapanese {
            if !entry.ja.isEmpty {
                return entry.ja
            }
            if !entry.en.isEmpty {
                return entry.en
            }
            return baseLabel
        } else {
            if !entry.en.isEmpty {
                return entry.en
            }
            if !entry.ja.isEmpty {
                return entry.ja
            }
            return baseLabel
        }
    }

    /// stanford_taxonomy_labels.* を更新したあとに呼び出して、
    /// 次回の localizedLabel 呼び出し時に最新の内容を読み込ませるためのフック。
    static func invalidateCache() {
        entries.removeAll()
        didLoad = false
    }

    /// ExploreCourses から取得したスクール・学科一覧をもとに、
    /// `stanford_taxonomy_labels.yaml` のスケルトンファイルを manifests ディレクトリに生成する。
    /// すでにファイルが存在する場合は上書きせず、そのまま何もしない。
    static func writeSkeletonIfNeeded(for schools: [ECSchool]) {
        let fm = FileManager.default
        let dest = Inf6Storage.manifestsDirectory().appendingPathComponent("stanford_taxonomy_labels.yaml")

        // すでにユーザーが作成済みなら変更しない
        if fm.fileExists(atPath: dest.path) {
            return
        }

        var lines: [String] = []
        lines.append("# Auto-generated skeleton by inf6")
        lines.append("# Stanford schools/departments labels. Fill label_ja/label_en as needed.")
        lines.append("schools:")

        for school in schools {
            let rawKey = school.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawKey.isEmpty else { continue }
            let key = rawKey.replacingOccurrences(of: "\"", with: "\\\"")
            let label = rawKey.replacingOccurrences(of: "\"", with: "\\\"")

            lines.append("  - key: \"\(key)\"")
            lines.append("    label: \"\(label)\"")
            lines.append("    label_ja: \"\"")
            lines.append("    label_en: \"\(label)\"")
        }

        lines.append("")
        lines.append("departments:")

        for school in schools {
            for dept in school.departments {
                let rawKey = dept.code.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rawKey.isEmpty else { continue }
                let baseLabel = (dept.name.isEmpty ? dept.code : dept.name)
                let key = rawKey.replacingOccurrences(of: "\"", with: "\\\"")
                let label = baseLabel.replacingOccurrences(of: "\"", with: "\\\"")

                lines.append("  - key: \"\(key)\"")
                lines.append("    label: \"\(label)\"")
                lines.append("    label_ja: \"\"")
                lines.append("    label_en: \"\(label)\"")
            }
        }

        let text = lines.joined(separator: "\n")

        do {
            try text.write(to: dest, atomically: true, encoding: .utf8)
            print("[Inf6TaxonomyLocalization] wrote skeleton: \(dest.path)")
            invalidateCache()
        } catch {
            print("[Inf6TaxonomyLocalization] failed to write skeleton: \(error)")
        }
    }
}




// MARK: - GPT Utility for Stanford Taxonomy YAML Generation
enum Inf6TaxonomyGPT {

    /// Stanford の学科コード・ラベル一覧を日本語に翻訳するためのプロンプトを生成する。
    /// GPT には「CODE  : 日本語ラベル」形式のプレーンテキストのみを返すよう指示する。
    static func buildDepartmentPrompt(schools: [ECSchool]) -> String {
        var lines: [String] = []
        lines.append("あなたはスタンフォード大学の学科コード・ラベルの日本語翻訳アシスタントです。")
        lines.append("出力は必ずプレーンテキストで、1行ごとに「CODE  : 日本語ラベル」の形式で出力してください。")
        lines.append("YAML、JSON、マークダウン、コードフェンス、説明文、コメントは絶対に含めないでください。")
        lines.append("")
        lines.append("【出力例】")
        lines.append("CS  : コンピュータサイエンス")
        lines.append("MATH: 数学")
        lines.append("")
        lines.append("【ルール】")
        lines.append("- 左側のコード（例: CS, MATH）は絶対に変更しないでください。")
        lines.append("- コロンの右側だけを自然な日本語に翻訳してください。")
        lines.append("- 行数・順序は必ず維持してください。")
        lines.append("- 余計な行、コメント、説明は絶対に追加しないでください。")
        lines.append("")
        lines.append("=== DEPARTMENTS ===")
        for school in schools {
            for dept in school.departments {
                let baseLabel = dept.name.isEmpty ? dept.code : dept.name
                lines.append("\(dept.code)  : \(baseLabel)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Stanford のスクール名一覧を日本語に翻訳するためのプロンプトを生成する。
    /// GPT には「英語スクール名  : 日本語ラベル」の形式のプレーンテキストのみを返すよう指示する。
    static func buildSchoolPrompt(schools: [ECSchool]) -> String {
        var lines: [String] = []
        lines.append("あなたはスタンフォード大学のスクール名の日本語翻訳アシスタントです。")
        lines.append("出力は必ずプレーンテキストで、1行ごとに「英語スクール名  : 日本語ラベル」の形式で出力してください。")
        lines.append("YAML、JSON、マークダウン、コードフェンス、説明文、コメントは絶対に含めないでください。")
        lines.append("")
        lines.append("【出力例】")
        lines.append("School of Engineering  : 工学部")
        lines.append("School of Humanities & Sciences  : 人文・科学部")
        lines.append("")
        lines.append("【ルール】")
        lines.append("- 左側のスクール名（例: School of Engineering）は絶対に変更しないでください。")
        lines.append("- コロンの右側だけを自然な日本語に翻訳してください。")
        lines.append("- 行数・順序は必ず維持してください。")
        lines.append("- 余計な行、コメント、説明は絶対に追加しないでください。")
        lines.append("")
        lines.append("=== SCHOOLS ===")
        for school in schools {
            let baseLabel = school.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !baseLabel.isEmpty else { continue }
            lines.append("\(baseLabel)  : \(baseLabel)")
        }
        return lines.joined(separator: "\n")
    }

    /// GPTに「コード:日本語ラベル」形式で出力させた結果から stanford_taxonomy_labels.yaml を生成し保存する
    /// - Parameters:
    ///   - schools: ExploreCourses から取得したスクール一覧
    ///   - model: 使用するモデル名
    /// - Returns: 保存した YAML ファイルの URL
    @discardableResult
    static func generateAndSaveLabelsYAML(
        schools: [ECSchool],
        model: String = "gpt-4o-mini"
    ) async throws -> URL {
        // Labels are ordinary translations; do not spend LLM credits on them.
        var departmentLines: [String] = []
        var schoolLines: [String] = []
        for school in schools {
            let schoolName = school.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !schoolName.isEmpty {
                let translated = try await Inf6SystemTranslationCoordinator.shared.translate(
                    schoolName,
                    source: "en",
                    target: "ja"
                )
                schoolLines.append("\(schoolName)  : \(translated)")
            }
            for dept in school.departments {
                let label = (dept.name.isEmpty ? dept.code : dept.name)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !dept.code.isEmpty, !label.isEmpty else { continue }
                let translated = try await Inf6SystemTranslationCoordinator.shared.translate(
                    label,
                    source: "en",
                    target: "ja"
                )
                departmentLines.append("\(dept.code)  : \(translated)")
            }
        }
        let deptText = departmentLines.joined(separator: "\n")
        let schoolText = schoolLines.joined(separator: "\n")

        let dir = Inf6Storage.manifestsDirectory()
        let dest = dir.appendingPathComponent("stanford_taxonomy_labels.yaml")

        #if canImport(Yams)
        // 2. プレーンテキストを stanford_taxonomy_labels.yaml 互換の YAML (schools/departments セクション) に変換
        let normalized: String
        do {
            let candidate = try buildYAMLFromTranslations(
                deptText: deptText,
                schoolsText: schoolText,
                schools: schools
            )
            // 3. 既存ファイルがあればマージして、schools/departments を統合
            normalized = try mergeNormalizedLabelsWithExisting(candidate, at: dest)
        } catch {
            print("[Inf6TaxonomyGPT] validation/merge failed; stanford_taxonomy_labels.yaml not updated: \(error)")
            throw error
        }

        // 4. 正規化された YAML を保存
        try normalized.write(to: dest, atomically: true, encoding: .utf8)
        // Ensure subsequent lookups pick up the newly written labels file.
        Inf6TaxonomyLocalization.invalidateCache()
        #else
        // Yams が使えないビルドでは、少なくとも GPT の生テキストを参考用として保存しておく
        let fallbackDest = dir.appendingPathComponent("stanford_taxonomy_labels_raw.txt")
        let combinedText = """
        === Departments ===
        \(deptText)

        === Schools ===
        \(schoolText)
        """
        try combinedText.write(to: fallbackDest, atomically: true, encoding: .utf8)
        #endif

        return dest
    }

    /// GPT から返ってきた「CODE  : 日本語ラベル」形式のプレーンテキストをパースして
    /// [コード: 日本語ラベル] のマップに変換する。
     static func parseDepartmentTranslations(_ text: String) -> [String: String] {
        var result: [String: String] = [:]

        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            // 期待形式: "CS  : コンピュータサイエンス"
            guard let colonRange = line.range(of: ":") else { continue }

            let codePart = line[..<colonRange.lowerBound]
            let labelPart = line[colonRange.upperBound...]

            let code = codePart.trimmingCharacters(in: .whitespacesAndNewlines)
            let jaLabel = labelPart.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !code.isEmpty, !jaLabel.isEmpty else { continue }

            result[code] = jaLabel
        }

        return result
    }

    /// Stanford のスクール名用に、GPT 出力の行順を保持したまま
    /// [英語スクール名: 日本語ラベル] を構築する。
    ///
    /// - Parameters:
    ///   - text: GPT から返ってきた「英語スクール名  : 日本語ラベル」形式のテキスト
    ///   - schools: ExploreCourses から取得したスクール一覧（入力順）
     static func parseSchoolTranslations(
        _ text: String,
        schools: [ECSchool]
    ) -> [String: String] {
        // 1. GPT 出力から「日本語ラベル」だけを行順で取り出す
        var labelsJA: [String] = []

        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            // 空行やコメント/区切り行はスキップ
            if line.isEmpty { continue }
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("===") { continue }

            guard let colonRange = line.range(of: ":") else { continue }
            let labelPart = line[colonRange.upperBound...]
            let ja = labelPart.trimmingCharacters(in: .whitespacesAndNewlines)
            if ja.isEmpty { continue }
            labelsJA.append(ja)
        }

        // 2. ExploreCourses から来たスクール順に、日本語ラベルを割り当てる
        var result: [String: String] = [:]
        let count = min(schools.count, labelsJA.count)
        if count == 0 { return result }

        for i in 0..<count {
            let rawName = schools[i].name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawName.isEmpty else { continue }
            result[rawName] = labelsJA[i]
        }

        return result
    }

#if canImport(Yams)

    /// GPT から返ってきた「コード: 日本語ラベル」テキスト（学科用）と
    /// 「英語スクール名: 日本語ラベル」テキスト（スクール用）から、
    /// stanford_taxonomy_labels.yaml 用の YAML (schools/departments セクション) を構築する。
     static func buildYAMLFromTranslations(
        deptText: String,
        schoolsText: String,
        schools: [ECSchool]
    ) throws -> String {
        let deptTranslations = parseDepartmentTranslations(deptText)
        let schoolTranslations = parseSchoolTranslations(schoolsText, schools: schools)

        if deptTranslations.isEmpty && schoolTranslations.isEmpty {
            throw NSError(
                domain: "Inf6TaxonomyGPT",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "No valid school/department translations found in GPT output"]
            )
        }

        // コード -> 英語ベースラベルのマップを ExploreCourses 側から構築（departments 用）
        var deptBaseLabels: [String: String] = [:]
        for school in schools {
            for dept in school.departments {
                let code = dept.code.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !code.isEmpty else { continue }
                let base = dept.name.isEmpty ? dept.code : dept.name
                deptBaseLabels[code.uppercased()] = base
            }
        }

        // スクール名 -> 英語ベースラベルのマップ（schools 用）
        var schoolBaseLabels: [String: String] = [:]
        for school in schools {
            let raw = school.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            schoolBaseLabels[raw] = raw
        }

        // departments セクション
        var departmentsArray: [[String: Any]] = []
        departmentsArray.reserveCapacity(deptTranslations.count)

        for (code, jaLabel) in deptTranslations.sorted(by: { $0.key < $1.key }) {
            let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedCode.isEmpty else { continue }

            let upperCode = normalizedCode.uppercased()
            let baseLabel = deptBaseLabels[upperCode] ?? upperCode

            departmentsArray.append([
                "key": upperCode,
                "label": baseLabel,
                "label_ja": jaLabel,
                "label_en": baseLabel
            ])
        }

        // schools セクション
        var schoolsArray: [[String: Any]] = []
        schoolsArray.reserveCapacity(schoolTranslations.count)

        for (englishName, jaLabel) in schoolTranslations.sorted(by: { $0.key < $1.key }) {
            let normalizedName = englishName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty else { continue }

            let baseLabel = schoolBaseLabels[normalizedName] ?? normalizedName

            schoolsArray.append([
                "key": normalizedName,
                "label": baseLabel,
                "label_ja": jaLabel,
                "label_en": baseLabel
            ])
        }

        if departmentsArray.isEmpty && schoolsArray.isEmpty {
            throw NSError(
                domain: "Inf6TaxonomyGPT",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "Translations produced no valid YAML entries for schools/departments"]
            )
        }

        var obj: [String: Any] = [:]
        if !schoolsArray.isEmpty {
            obj["schools"] = schoolsArray
        }
        if !departmentsArray.isEmpty {
            obj["departments"] = departmentsArray
        }

        return try Yams.dump(object: obj)
    }
    /// stanford_taxonomy_labels.* YAML をマップ形式に変換する。
    /// - Returns: schools/departments を key => 辞書 で持つマップ。
     static func parseLabelsYAML(_ text: String) throws -> (schools: [String: [String: Any]], departments: [String: [String: Any]]) {
        let any = try Yams.load(yaml: text)

        func sanitizeItems(_ arr: [[String: Any]]) -> [String: [String: Any]] {
            var out: [String: [String: Any]] = [:]
            for item in arr {
                let m = item
                // key / code / name のいずれかをキーとして解釈する
                let rawKey = (
                    (m["key"] as? String) ??
                    (m["code"] as? String) ??
                    (m["name"] as? String) ??
                    ""
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rawKey.isEmpty else { continue }

                let key = rawKey
                let baseLabel = (m["label"] as? String ?? key)
                let ja = (m["label_ja"] as? String ?? "")
                let en = (m["label_en"] as? String ?? baseLabel)

                out[key] = [
                    "key": key,
                    "label": baseLabel,
                    "label_ja": ja,
                    "label_en": en
                ]
            }
            return out
        }

        var schoolsMap: [String: [String: Any]] = [:]
        var deptsMap: [String: [String: Any]] = [:]

        if let dict = any as? [String: Any] {
            if let schools = dict["schools"] as? [[String: Any]] {
                schoolsMap = sanitizeItems(schools)
            }
            if let deps = dict["departments"] as? [[String: Any]] {
                deptsMap = sanitizeItems(deps)
            }
            // 柔軟性確保のため、items: 配列 形式も許容しておく
            if let items = dict["items"] as? [[String: Any]] {
                let extra = sanitizeItems(items)
                for (k, v) in extra where schoolsMap[k] == nil && deptsMap[k] == nil {
                    deptsMap[k] = v
                }
            }
        } else if let arr = any as? [[String: Any]] {
            // ルートが配列の場合は departments 扱いとする
            deptsMap = sanitizeItems(arr)
        }

        return (schoolsMap, deptsMap)
    }

    /// 既存の stanford_taxonomy_labels.yaml がある場合、新しい正規化済みラベルとマージする。
    /// - 新規 GPT 出力に含まれる key は必ず反映する。
    /// - label_ja / label_en について、新規側が空文字の場合は既存の値を優先して保持する。
     static func mergeNormalizedLabelsWithExisting(_ normalized: String, at dest: URL) throws -> String {
        // 既存ファイルが無ければそのまま返す
        let fm = FileManager.default
        guard fm.fileExists(atPath: dest.path) else {
            return normalized
        }

        let oldText = (try? String(contentsOf: dest, encoding: .utf8)) ?? ""
        if oldText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return normalized
        }

        let newMaps = try parseLabelsYAML(normalized)
        let oldMaps = (try? parseLabelsYAML(oldText)) ?? (schools: [:], departments: [:])

        func mergeMaps(_ old: [String: [String: Any]], _ new: [String: [String: Any]]) -> [[String: Any]] {
            var merged = old

            for (key, newItem) in new {
                var base = merged[key] ?? ["key": key]

                func mergeField(_ field: String) {
                    let newVal = (newItem[field] as? String ?? "")
                    let oldVal = (base[field] as? String ?? "")
                    let value = newVal.isEmpty ? oldVal : newVal
                    base[field] = value
                }

                mergeField("label")
                mergeField("label_ja")
                mergeField("label_en")

                merged[key] = base
            }

            // ソートして安定出力
            return merged.values.sorted { lhs, rhs in
                let lk = (lhs["key"] as? String ?? "")
                let rk = (rhs["key"] as? String ?? "")
                return lk < rk
            }
        }

        let mergedSchools = mergeMaps(oldMaps.schools, newMaps.schools)
        let mergedDepts = mergeMaps(oldMaps.departments, newMaps.departments)

        if mergedSchools.isEmpty && mergedDepts.isEmpty {
            throw NSError(
                domain: "Inf6TaxonomyGPT",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Merged stanford_taxonomy_labels YAML contains no valid entries"]
            )
        }

        let obj: [String: Any] = [
            "schools": mergedSchools,
            "departments": mergedDepts
        ]
        return try Yams.dump(object: obj)
    }

    /// stanford_taxonomy_labels.yaml 用の YAML を検証・正規化する。
    /// - 入力が schools/departments 配列を持たない場合や、key が空の要素のみの場合はエラーを投げる。
     static func normalizeLabelsYAML(_ text: String) throws -> String {
        let parsed = try parseLabelsYAML(text)

        if parsed.schools.isEmpty && parsed.departments.isEmpty {
            throw NSError(
                domain: "Inf6TaxonomyGPT",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "stanford_taxonomy_labels YAML contains no valid schools/departments entries"]
            )
        }

        func sortedArray(from map: [String: [String: Any]]) -> [[String: Any]] {
            return map.values.sorted { lhs, rhs in
                let lk = (lhs["key"] as? String ?? "")
                let rk = (rhs["key"] as? String ?? "")
                return lk < rk
            }
        }

        let schoolsOut = sortedArray(from: parsed.schools)
        let deptsOut = sortedArray(from: parsed.departments)

        let obj: [String: Any] = [
            "schools": schoolsOut,
            "departments": deptsOut
        ]

        return try Yams.dump(object: obj)
    }
#endif

    // callChatCompletion function removed
}


// MARK: - GPT Utility for Syllabus Localization & Paper Suggestions

enum Inf6SyllabusGPT {

    /// 講義タイトルと概要を日本語に翻訳する。
    /// - Returns: (日本語タイトル, 日本語概要)。失敗時は英語にフォールバックする。
    static func translateTitleAndDetail(
        syllabus: Inf6StanfordSyllabus,
        model: String = "gpt-4o-mini"
    ) async throws -> (String, String) {
        let title = try await Inf6SystemTranslationCoordinator.shared.translate(
            syllabus.title,
            source: "en",
            target: "ja"
        )
        let detail = try await Inf6SystemTranslationCoordinator.shared.translate(
            syllabus.detail,
            source: "en",
            target: "ja"
        )
        return (
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? syllabus.title : title,
            detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? syllabus.detail : detail
        )
    }

    /// 講義タイトルだけを日本語に翻訳する薄いラッパ。
    /// - Returns: 日本語タイトル（失敗時は英語タイトルを返す）
    static func translateTitleOnly(
        syllabus: Inf6StanfordSyllabus,
        model: String = "gpt-4o-mini"
    ) async throws -> String {
        let (titleJA, _) = try await translateTitleAndDetail(
            syllabus: syllabus,
            model: model
        )
        return titleJA
    }

    /// 複数の講義タイトルをまとめて日本語に翻訳する（チャンク分割対応）。
    /// - Returns: [syllabus.id: 日本語タイトル]
    static func translateTitlesBatch(
        syllabi: [Inf6StanfordSyllabus],
        model: String = "gpt-4o-mini",
        onPartial: (@Sendable ([String: String]) async -> Void)? = nil
    ) async throws -> [String: String] {
        guard !syllabi.isEmpty else { return [:] }

        // 1回のプロンプトで送る講義数を制限する（タイムアウト回避のため分割）
        let maxBatchSize = 80
        var merged: [String: String] = [:]

        var index = 0
        while index < syllabi.count {
            let end = min(index + maxBatchSize, syllabi.count)
            let chunk = Array(syllabi[index..<end])

            do {
                let partial = try await translateTitlesBatchChunk(
                    syllabi: chunk,
                    model: model
                )
                // チャンクごとの結果を呼び出し元に即時通知（必要な場合）
                if let onPartial = onPartial {
                    await onPartial(partial)
                }
                // 既にあるIDは上書きせず、最初の結果を優先する
                for (id, titleJA) in partial {
                    if merged[id] == nil {
                        merged[id] = titleJA
                    } else {
                        print("[Inf6SyllabusGPT] duplicate syllabus id detected across chunks: \(id); keeping first translated title")
                    }
                }
            } catch {
                // 1チャンク失敗しても、他のチャンクは処理を続ける
                print("[Inf6SyllabusGPT] translateTitlesBatch chunk failed: \(error)")
            }

            index = end
        }

        return merged
    }

    /// 単一チャンク分の講義タイトルをまとめて日本語に翻訳する内部ヘルパー。
    /// - Returns: [syllabus.id: 日本語タイトル]
    static func translateTitlesBatchChunk(
        syllabi: [Inf6StanfordSyllabus],
        model: String
    ) async throws -> [String: String] {
        guard !syllabi.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for syllabus in syllabi {
            try Task.checkCancellation()
            let translated = try await translateTitleAndDetail(syllabus: syllabus, model: model)
            result[syllabus.id] = translated.0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? syllabus.title
                : translated.0
        }
        return result
    }

    /// バッチ翻訳のテキスト出力を `id -> 日本語タイトル` マップに変換する。
    /// - Parameters:
    ///   - text: GPT から返ってきたプレーンテキスト。
    ///   - fallbackMap: 有効な ID の集合と英語タイトル（検証用）。
     static func parseBatchTitleTranslations(
        _ text: String,
        fallbackMap: [String: String]
    ) throws -> [String: String] {
        var result: [String: String] = [:]

        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            // タブ区切り "id\tタイトル"
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }

            let id = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let titleJA = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)

            guard !id.isEmpty, !titleJA.isEmpty else { continue }
            guard fallbackMap[id] != nil else { continue }

            result[id] = titleJA
        }

        // 一つもパースできない場合はエラーとみなす（呼び出し元で英語タイトルにフォールバックさせる）
        if result.isEmpty {
            throw NSError(
                domain: "Inf6SyllabusGPT",
                code: -30,
                userInfo: [NSLocalizedDescriptionKey: "No valid batch title translations found in GPT output"]
            )
        }

        return result
    }

    /// GPT から返ってきた TITLE_JA / DETAIL_JA 行をパースする。
     static func parseTitleDetailTranslation(
        _ text: String,
        fallbackTitle: String,
        fallbackDetail: String
    ) -> (String, String) {
        var title: String?
        var detail: String?

        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("TITLE_JA:") {
                let value = line.dropFirst("TITLE_JA:".count)
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    title = trimmed
                }
            } else if line.hasPrefix("DETAIL_JA:") {
                let value = line.dropFirst("DETAIL_JA:".count)
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    detail = trimmed
                }
            }
        }

        let finalTitle = title ?? fallbackTitle
        let finalDetail = detail ?? fallbackDetail
        return (finalTitle, finalDetail)
    }

    /// Stanford シラバス情報から論文収集用の YAML マニフェストを生成するためのプロンプトを構築する。
    static func buildPapersPrompt(
        syllabus: Inf6StanfordSyllabus,
        schoolName: String,
        departmentName: String
    ) -> String {
        var lines: [String] = []
        lines.append("あなたは大学講義シラバスにもとづいて研究論文の候補リストを作成するアシスタントです。")
        lines.append("次の講義に関連する、代表的でオープンアクセスの研究論文（主に arXiv / OpenReview / ACL / PMLR / CVF など）を提案してください。")
        lines.append("")
        lines.append("【講義情報】")
        lines.append("大学: \(schoolName)")
        lines.append("学科: \(departmentName)")
        if !syllabus.code.isEmpty {
            lines.append("講義コード: \(syllabus.code)")
        }
        lines.append("講義タイトル: \(syllabus.title)")
        if !syllabus.detail.isEmpty {
            lines.append("講義概要: \(syllabus.detail)")
        }
        lines.append("")
        lines.append("【出力フォーマット】")
        lines.append("必ず次の YAML だけを UTF-8 テキストで出力してください。マークダウンのコードフェンスや説明文は一切含めないでください。")
        lines.append("")
        lines.append("papers:")
        lines.append("  - title: \"論文タイトル\"")
        lines.append("    provider: \"arxiv\"        # arxiv / openreview / acl / pmlr / cvf / direct / other")
        lines.append("    arxiv_id: \"1234.56789\"   # provider が arxiv の場合は必須")
        lines.append("    openreview_id: \"\"        # openreview の場合")
        lines.append("    acl_id: \"\"               # ACL Anthology の場合")
        lines.append("    pdf_url: \"\"              # direct の場合のみ URL を指定")
        lines.append("    tags: [\"タグ1\", \"タグ2\"]")
        lines.append("")
        lines.append("ルール:")
        lines.append("- 最大で 15 本程度までに絞ってください。")
        lines.append("- provider と ID / URL の組み合わせが矛盾しないよう注意してください。")
        lines.append("- YAML 構造以外のテキストは絶対に出力しないでください。")

        return lines.joined(separator: "\n")
    }

    /// 講義タイトルと概要から、関連論文の YAML マニフェストを GPT で生成する。
    static func generatePapersYAML(
        for syllabus: Inf6StanfordSyllabus,
        schoolName: String,
        departmentName: String,
        model: String = "gpt-4o-mini"
    ) async throws -> String {
        let prompt = buildPapersPrompt(
            syllabus: syllabus,
            schoolName: schoolName,
            departmentName: departmentName
        )
        let apiKey = try OpenAIKeyStore.load()
        let cfg = try OpenAIClient.Config.default(model: model)
        let sessCfg = URLSessionConfiguration.ephemeral
        sessCfg.timeoutIntervalForRequest = cfg.timeoutSeconds
        sessCfg.timeoutIntervalForResource = cfg.timeoutSeconds
        let session = URLSession(configuration: sessCfg)
        let client = OpenAIClient(apiKey: apiKey, config: cfg, session: session)

        let rendered = try Inf6PromptGovernance.renderSystemUserPrompt(
            ref: Inf6PromptCatalog.taxonomyGeneratePapersYAML,
            variables: [
                "task_prompt": prompt
            ]
        )
        return try await client.generateText(
            messages: [
                OpenAIClient.InputMessage(role: .system, text: rendered.systemInstruction),
                OpenAIClient.InputMessage(role: .user, text: rendered.userPrompt)
            ],
            options: .init()
        )
    }

    // MARK: - Persistent storage for syllabus title translations

    /// stanford_syllabus_titles.json の保存先 URL
     static func titlesFileURL() -> URL {
        Inf6Storage.manifestsDirectory().appendingPathComponent("stanford_syllabus_titles.json")
    }

    /// 永続化された「シラバスID -> 日本語タイトル」のマップを読み込む。
    /// ファイルが存在しない場合や読み込みに失敗した場合は空マップを返す。
    static func loadTitleTranslations() -> [String: String] {
        let url = titlesFileURL()
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return [:]
        }

        do {
            let data = try Data(contentsOf: url)
            if data.isEmpty {
                return [:]
            }
            let obj = try JSONSerialization.jsonObject(with: data, options: [])
            if let map = obj as? [String: String] {
                return map
            } else {
                print("[Inf6SyllabusGPT] loadTitleTranslations: unexpected JSON root; expected [String: String]")
                return [:]
            }
        } catch {
            print("[Inf6SyllabusGPT] loadTitleTranslations failed: \(error)")
            return [:]
        }
    }

    /// 新しいタイトル翻訳を既存の JSON にマージして永続化する。
    /// 同じ ID がすでに存在する場合は、新しいタイトルで上書きする（差分更新）。
    static func mergeTitleTranslations(_ newEntries: [String: String]) {
        guard !newEntries.isEmpty else { return }

        let url = titlesFileURL()
        var current = loadTitleTranslations()
        var changed = false

        for (id, titleJA) in newEntries {
            if current[id] != titleJA {
                current[id] = titleJA
                changed = true
            }
        }

        guard changed else { return }

        do {
            let data = try JSONSerialization.data(withJSONObject: current, options: [.prettyPrinted])
            try data.write(to: url, options: [.atomic])
            print("[Inf6SyllabusGPT] mergeTitleTranslations: wrote \(current.count) entries to \(url.lastPathComponent)")
        } catch {
            print("[Inf6SyllabusGPT] mergeTitleTranslations failed: \(error)")
        }
    }
}
