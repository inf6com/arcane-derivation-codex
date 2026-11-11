//
//  Inf6ProperNouns.swift
//  inf6 / CrowCat
//
//  アプリ固有の表示名・キー・リソース名など「固有名詞」を一箇所に集約。
//  依存は最小限（Foundation + Inf6Lang があればローカライズ補助）。
//

import Foundation

public enum Inf6ProperNouns {
    
    // MARK: - Unified Compass YAML (branding + local schools)
    /// Compass が読む統合 YAML のベース名（拡張子なし）
    /// inf6: "compass.default"
    /// CrowCat: "crowcat.compass.default" 等に差し替え
    public static let compassDefaultYAMLBaseName: String = "compass.default"
    
    // MARK: - Organizations / Qualifications (JDLA etc.)
    
    public struct Organization: Hashable, Codable {
        public let key: String
        public let labelJa: String
        public let labelEn: String
        
        public init(key: String, labelJa: String, labelEn: String) {
            self.key = key
            self.labelJa = labelJa
            self.labelEn = labelEn
        }
        
        public var displayName: String {
#if canImport(SwiftUI)
            return Inf6Lang.text(labelJa, labelEn)
#else
            return labelJa
#endif
        }
    }
    
    public struct Qualification: Hashable, Codable {
        public let key: String
        public let labelJa: String
        public let labelEn: String
        public let homeURLString: String?
        public let routeTokens: [String]
        
        public init(key: String, labelJa: String, labelEn: String, homeURLString: String? = nil, routeTokens: [String]) {
            self.key = key
            self.labelJa = labelJa
            self.labelEn = labelEn
            self.homeURLString = homeURLString
            self.routeTokens = routeTokens
        }
        
        public var displayName: String {
#if canImport(SwiftUI)
            return Inf6Lang.text(labelJa, labelEn)
#else
            return labelJa
#endif
        }
    }
    
    private static var _learningFamilyManifests: [Inf6LearningFamilyManifest] {
        Inf6LearningFamilyManifestStore.loadAll()
    }

    public static var defaultOrganizations: [Organization] {
        var seen = Set<String>()
        var out: [Organization] = []
        for manifest in _learningFamilyManifests {
            let key = _organizationKey(for: manifest)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(
                Organization(
                    key: key,
                    labelJa: manifest.providerDisplayNameJa,
                    labelEn: manifest.providerDisplayNameEn
                )
            )
        }
        return out
    }
    
    public static var defaultQualifications: [Qualification] {
        _learningFamilyManifests.map { manifest in
            Qualification(
                key: manifest.familyID,
                labelJa: manifest.displayNameJa,
                labelEn: manifest.displayNameEn,
                homeURLString: manifest.officialSources.first,
                routeTokens: _routeTokens(for: manifest)
            )
        }
    }
    
    // MARK: - Compass menu display names
    // NOTE: These labels are defined here to avoid config-type dependencies.
    
    /// Compass の「シラバスソース」選択で表示する Stanford 側の名称。
    public static var syllabusSourceRemoteDisplayName: String {
        return Inf6Lang.text("Stanford ExploreCourses", "Stanford ExploreCourses")
    }

    /// Compass の「シラバスソース」選択で表示する 資格・団体 側の名称。
    public static var syllabusSourceLocalDisplayName: String {
        return Inf6Lang.text("資格・団体", "Qualifications")
    }

    /// Compass のローカル既定ルート表示名。
    public static var localDefaultRootDisplayName: String {
        return Inf6Lang.text("資格", "Qualifications")
    }

    /// Compass のローカル「その他」ルート表示名。
    public static var localOtherRootDisplayName: String {
        return Inf6Lang.text("その他", "Other")
    }
    
    /// “固有名詞に依存する判定” はここに閉じ込める
    public static func detectQualificationRoute(from haystack: String) -> Qualification? {
        let lower = haystack.localizedLowercase
        for q in defaultQualifications {
            if q.routeTokens.contains(where: { lower.contains($0.localizedLowercase) }) {
                return q
            }
        }
        return nil
    }
    
    private static func _organizationKey(for manifest: Inf6LearningFamilyManifest) -> String {
        if manifest.usesMicrosoftLearnProvider { return "microsoft" }
        if manifest.usesJDLAHTMLProvider { return "jdla" }
        if let primaryProvider = manifest.providers.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           !primaryProvider.isEmpty {
            return primaryProvider.localizedLowercase.replacingOccurrences(of: " ", with: "-")
        }
        return "other"
    }

    private static func _routeTokens(for manifest: Inf6LearningFamilyManifest) -> [String] {
        var tokens: [String] = [
            manifest.familyID,
            manifest.displayNameJa,
            manifest.displayNameEn
        ]
        let compactID = manifest.familyID.replacingOccurrences(of: "-", with: "")
        if compactID != manifest.familyID {
            tokens.append(compactID)
        }
        if let routeTokens = manifest.routeTokens {
            tokens.append(contentsOf: routeTokens)
        }
        return Array(Set(tokens))
    }

    
}



// MARK: - Unified Compass default config (pure‑data)

public enum Inf6CompassDefaultConfig {


    // --- Branding (same keys as Inf6CompassBranding) ---
    public static let branding: Inf6CompassBranding = .init(
        appKey: "inf6.com",
        heroSystemImage: "compass.drawing",
        heroTitleJa: "inf6 コンパス",
        heroTitleEn: "inf6 Compass",
        heroSubtitleJa: "ナレッジ・オペレーショナライゼーション・ループの入口。収集・整理・問題化へ進みます。",
        heroSubtitleEn: "Entry to the knowledge operationalization loop: collect, organize, and turn knowledge into questions.",
        navigationTitleJa: "ナレッジ・オペレーショナライゼーション",
        navigationTitleEn: "Knowledge Operationalization",
        logPrefix: "[Inf6Compass]",
        // UI labels (menu strings)
        syllabusSourceRemoteLabelJa: "Stanford explorecourses",
        syllabusSourceRemoteLabelEn: "Stanford explorecourses",
        syllabusSourceLocalLabelJa: "資格・団体",
        syllabusSourceLocalLabelEn: "Qualifications"
    )
    
    
    
    
    // --- Local syllabi (proper‑nouns level only) ---
    public static let version: Int = 1

    public static var schools: [Inf6CompassLocalSchool] {
        let manifests = Inf6LearningFamilyManifestStore.loadAll()
        let grouped = Dictionary(grouping: manifests, by: _organizationKey(for:))
        return grouped.keys.sorted().compactMap { orgKey in
            guard let orgManifests = grouped[orgKey], let first = orgManifests.first else { return nil }
            let departments = orgManifests
                .sorted { $0.displayNameJa.localizedCaseInsensitiveCompare($1.displayNameJa) == .orderedAscending }
                .flatMap { _departments(for: $0) }
            let faculty = Inf6CompassLocalFaculty(
                key: "\(orgKey)-qualifications",
                labelJa: _facultyLabelJa(for: orgKey, providerNameJa: first.providerDisplayNameJa),
                labelEn: _facultyLabelEn(for: orgKey, providerNameEn: first.providerDisplayNameEn),
                departments: departments
            )
            return Inf6CompassLocalSchool(
                key: orgKey,
                labelJa: first.providerDisplayNameJa,
                labelEn: first.providerDisplayNameEn,
                homeURLString: first.officialSources.first,
                faculties: [faculty],
                category: _schoolCategory(for: orgKey)
            )
        }
    }

    private static func _organizationKey(for manifest: Inf6LearningFamilyManifest) -> String {
        if manifest.usesMicrosoftLearnProvider { return "microsoft" }
        if manifest.usesJDLAHTMLProvider { return "jdla" }
        if let primaryProvider = manifest.providers.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           !primaryProvider.isEmpty {
            return primaryProvider.localizedLowercase.replacingOccurrences(of: " ", with: "-")
        }
        return "other"
    }

    private static func _schoolCategory(for organizationKey: String) -> Inf6SchoolCategory {
        organizationKey == "microsoft" ? .it : .ai
    }

    private static func _facultyLabelJa(for organizationKey: String, providerNameJa: String) -> String {
        switch organizationKey {
        case "microsoft":
            return "Microsoft AI 資格"
        case "jdla":
            return "JDLA 資格試験"
        default:
            return "\(providerNameJa) 資格"
        }
    }

    private static func _facultyLabelEn(for organizationKey: String, providerNameEn: String) -> String {
        switch organizationKey {
        case "microsoft":
            return "Microsoft AI Certifications"
        case "jdla":
            return "JDLA Qualifications"
        default:
            return "\(providerNameEn) Qualifications"
        }
    }

    private static func _departments(for manifest: Inf6LearningFamilyManifest) -> [Inf6CompassLocalDepartment] {
        let derived = manifest.entryActions.map { action in
            return Inf6CompassLocalDepartment(
                key: _departmentKey(for: manifest, action: action),
                labelJa: manifest.displayNameJa,
                labelEn: manifest.displayNameEn,
                homeURLString: _departmentHomeURL(for: manifest, action: action),
                familyID: manifest.familyID,
                actionPhase: action.phase.rawValue,
                actionLabelJa: action.labelJa,
                actionLabelEn: action.labelJa,
                actionDescriptionJa: action.descriptionJa,
                actionDescriptionEn: action.descriptionJa
            )
        }
        if !derived.isEmpty {
            return derived
        }
        return [
            Inf6CompassLocalDepartment(
                key: manifest.familyID,
                labelJa: manifest.displayNameJa,
                labelEn: manifest.displayNameEn,
                homeURLString: manifest.officialSources.first,
                familyID: manifest.familyID
            )
        ]
    }

    private static func _departmentKey(
        for manifest: Inf6LearningFamilyManifest,
        action: Inf6LearningFamilyAction
    ) -> String {
        "\(manifest.familyID)::\(action.phase.rawValue)"
    }

    private static func _departmentHomeURL(
        for manifest: Inf6LearningFamilyManifest,
        action: Inf6LearningFamilyAction
    ) -> String? {
        if action.phase == .compose {
            return manifest.officialSources.dropFirst().first ?? manifest.officialSources.first
        }
        return manifest.officialSources.first
    }

}
