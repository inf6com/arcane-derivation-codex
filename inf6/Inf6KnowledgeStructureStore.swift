//
//  Inf6KnowledgeStructureStore.swift
//  inf6
//
//  観測済み知識構造 O の永続化。
//  保存するのは、根拠・集合所属・明示関係だけであり、PDF/HTML 本体は保存しない。
//

import Foundation

enum Inf6KnowledgeStructureStore {
    static func persist(_ set: Inf6UniversalConceptSet) {
        let fingerprint = _fingerprint(set)
        let fingerprintKey = "knowledge_structure_fingerprint"
        if Inf6MetadataStore.get(domain: .settings, key: fingerprintKey) == fingerprint {
            return
        }

        Inf6MetadataStore.deleteByPrefix(domain: .knowledgeEvidence, prefix: "")
        Inf6MetadataStore.deleteByPrefix(domain: .knowledgeMemberships, prefix: "")
        Inf6MetadataStore.deleteByPrefix(domain: .knowledgeRelations, prefix: "")

        for evidence in set.evidenceByID.values {
            Inf6MetadataStore.putCodable(
                evidence,
                domain: .knowledgeEvidence,
                key: evidence.evidenceID
            )
        }

        for membership in set.memberships {
            Inf6MetadataStore.putCodable(
                membership,
                domain: .knowledgeMemberships,
                key: _membershipKey(membership)
            )
        }

        for relation in set.relations {
            Inf6MetadataStore.putCodable(
                relation,
                domain: .knowledgeRelations,
                key: relation.relationID
            )
        }

        Inf6MetadataStore.put(domain: .settings, key: fingerprintKey, json: fingerprint)
    }

    static func listEvidence() -> [Inf6KnowledgeEvidence] {
        Inf6MetadataStore
            .listAllCodable(Inf6KnowledgeEvidence.self, domain: .knowledgeEvidence)
            .map(\.value)
    }

    static func listMemberships() -> [Inf6KnowledgeMembership] {
        Inf6MetadataStore
            .listAllCodable(Inf6KnowledgeMembership.self, domain: .knowledgeMemberships)
            .map(\.value)
    }

    static func listRelations() -> [Inf6KnowledgeRelation] {
        Inf6MetadataStore
            .listAllCodable(Inf6KnowledgeRelation.self, domain: .knowledgeRelations)
            .map(\.value)
    }

    private static func _membershipKey(_ membership: Inf6KnowledgeMembership) -> String {
        "\(membership.setID)|\(membership.conceptID)"
    }

    private static func _fingerprint(_ set: Inf6UniversalConceptSet) -> String {
        let evidencePart = set.evidenceByID.keys.sorted().joined(separator: "\n")
        let membershipPart = set.memberships
            .map { _membershipKey($0) + "|" + $0.evidenceIDs.sorted().joined(separator: ",") }
            .sorted()
            .joined(separator: "\n")
        let relationPart = set.relations
            .map { "\($0.relationID)|\($0.fromConceptID)|\($0.kind.rawValue)|\($0.toConceptID)|\($0.evidenceIDs.sorted().joined(separator: ","))" }
            .sorted()
            .joined(separator: "\n")
        return [evidencePart, membershipPart, relationPart].joined(separator: "\n---\n")
    }
}
