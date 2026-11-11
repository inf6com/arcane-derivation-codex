//
//  Inf6SemanticScopeVerifier.swift
//  inf6
//
//  公式シラバス由来の観測データを、真正な意味スコープとして表示できるか検証する。
//

import Foundation

enum Inf6SemanticScopeVerifier {
    static func verifyCurrentConceptSet(version: String) -> Inf6SemanticScopeVerificationReport {
        let concepts = Inf6MetadataStore
            .listAllCodable(Inf6CanonicalConcept.self, domain: .canonicalConcepts)
            .map(\.value)

        var issues: [Inf6SemanticScopeVerificationReport.Issue] = []
        for concept in concepts {
            issues.append(contentsOf: _issues(for: concept))
        }

        let report = Inf6SemanticScopeVerificationReport(
            version: version,
            issues: issues.sorted {
                if $0.code != $1.code { return $0.code < $1.code }
                return $0.conceptID < $1.conceptID
            }
        )
        Inf6MetadataStore.putCodable(report, domain: .settings, key: "semantic_scope_verification_report")
        Inf6MetadataStore.put(
            domain: .settings,
            key: "semantic_concept_set_quality",
            json: report.verified ? "semantic_scope_verified" : "source_evidence_observed"
        )
        return report
    }

    private static func _issues(
        for concept: Inf6CanonicalConcept
    ) -> [Inf6SemanticScopeVerificationReport.Issue] {
        let titleJA = (concept.displayTitleJA ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let titleEN = (concept.displayTitleEN ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let label = titleJA.isEmpty ? titleEN : titleJA
        var out: [Inf6SemanticScopeVerificationReport.Issue] = []

        if titleJA.isEmpty && titleEN.isEmpty {
            out.append(_issue(concept, "empty_label", "表示名が空です。"))
        }
        if _hasExtractionArtifact(label) || _hasExtractionArtifact(titleEN) {
            out.append(_issue(concept, "extraction_artifact", "抽出ノイズを含む可能性があります。"))
        }
        if _isTooBroad(label) || _isTooBroad(titleEN) {
            out.append(_issue(concept, "too_broad", "概念ではなく見出しまたはカテゴリの可能性があります。"))
        }
        if _hasUnbalancedParentheses(label) || _hasUnbalancedParentheses(titleEN) {
            out.append(_issue(concept, "broken_label", "括弧または表記が崩れています。"))
        }
        return out
    }

    private static func _issue(
        _ concept: Inf6CanonicalConcept,
        _ code: String,
        _ message: String
    ) -> Inf6SemanticScopeVerificationReport.Issue {
        Inf6SemanticScopeVerificationReport.Issue(
            conceptID: concept.canonicalID,
            code: code,
            message: message
        )
    }

    private static func _hasExtractionArtifact(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasSuffix(",") { return true }
        if trimmed.localizedCaseInsensitiveContains("learning)") { return true }
        if trimmed.localizedCaseInsensitiveContains("(meta") { return true }
        if trimmed.localizedCaseInsensitiveContains("(active") { return true }
        if trimmed.localizedCaseInsensitiveContains("(federated") { return true }
        if trimmed.contains("  ") { return true }
        return false
    }

    private static func _isTooBroad(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.widthInsensitive, .caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        guard !normalized.isEmpty else { return false }
        let broadLabels: Set<String> = [
            "training",
            "parallel",
            "domestic",
            "development",
            "開発",
            "基本的なアルゴリズム",
            "様々な学習方法",
            "深層学習の応用",
            "深層学習の基礎",
            "機械学習の基礎",
            "機械学習の課題"
        ]
        return broadLabels.contains(normalized)
    }

    private static func _hasUnbalancedParentheses(_ text: String) -> Bool {
        let open = text.filter { $0 == "(" || $0 == "（" }.count
        let close = text.filter { $0 == ")" || $0 == "）" }.count
        return open != close
    }
}
