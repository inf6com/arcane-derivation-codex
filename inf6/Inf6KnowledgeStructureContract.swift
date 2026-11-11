//
//  Inf6KnowledgeStructureContract.swift
//  inf6
//
//  工学的契約（知識構造）:
//    - 知そのもの K は直接保存しない。保存対象は観測済み構造 O のみ。
//    - Concept は概念、KnowledgeSet は観測ドメイン集合、Relation は明示関係、
//      Evidence はその関係・所属を主張できる根拠である。
//    - source outline の parent_node_id は「知識上の親子」ではない。
//      使用する場合は sourceOutlineContains として根拠付きで記録する。
//    - 根拠の無い Relation / Membership は無効。描画対象にも永続化対象にもならない。
//

import Foundation

public enum Inf6KnowledgeRelationKind: String, Codable, Hashable, Sendable {
    case sourceOutlineContains
    case prerequisite
    case related
    case sameAs
    case cites
    case derivedFrom
}

public struct Inf6KnowledgeDomainDefinition: Codable, Hashable, Sendable {
    public let domainID: String
    public let sourceFamily: String
    public let sourceKind: Inf6KnowledgeSourceKind
    public let displayTitleJA: String
    public let displayTitleEN: String

    public init(
        domainID: String,
        sourceFamily: String,
        sourceKind: Inf6KnowledgeSourceKind,
        displayTitleJA: String,
        displayTitleEN: String
    ) throws {
        let trimmedDomainID = domainID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSourceFamily = sourceFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitleJA = displayTitleJA.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitleEN = displayTitleEN.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDomainID.isEmpty else {
            throw Inf6KnowledgeStructureError.invalidDomainDefinition("domainID is empty")
        }
        guard !trimmedSourceFamily.isEmpty else {
            throw Inf6KnowledgeStructureError.invalidDomainDefinition("sourceFamily is empty")
        }
        guard !trimmedTitleJA.isEmpty else {
            throw Inf6KnowledgeStructureError.invalidDomainDefinition("displayTitleJA is empty: \(trimmedDomainID)")
        }
        guard !trimmedTitleEN.isEmpty else {
            throw Inf6KnowledgeStructureError.invalidDomainDefinition("displayTitleEN is empty: \(trimmedDomainID)")
        }
        self.domainID = trimmedDomainID
        self.sourceFamily = trimmedSourceFamily
        self.sourceKind = sourceKind
        self.displayTitleJA = trimmedTitleJA
        self.displayTitleEN = trimmedTitleEN
    }
}

public struct Inf6KnowledgeEvidence: Codable, Hashable, Sendable {
    public let evidenceID: String
    public let sourceKind: Inf6KnowledgeSourceKind
    public let sourceID: String
    public let locator: String
    public let observedAt: TimeInterval

    public init(
        evidenceID: String,
        sourceKind: Inf6KnowledgeSourceKind,
        sourceID: String,
        locator: String,
        observedAt: TimeInterval = Date().timeIntervalSince1970
    ) throws {
        let trimmedEvidenceID = evidenceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSourceID = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocator = locator.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEvidenceID.isEmpty else {
            throw Inf6KnowledgeStructureError.invalidEvidence("evidenceID is empty")
        }
        guard !trimmedSourceID.isEmpty else {
            throw Inf6KnowledgeStructureError.invalidEvidence("sourceID is empty")
        }
        guard !trimmedLocator.isEmpty else {
            throw Inf6KnowledgeStructureError.invalidEvidence("locator is empty")
        }
        self.evidenceID = trimmedEvidenceID
        self.sourceKind = sourceKind
        self.sourceID = trimmedSourceID
        self.locator = trimmedLocator
        self.observedAt = observedAt
    }
}

public struct Inf6KnowledgeMembership: Codable, Hashable, Sendable {
    public let setID: String
    public let conceptID: String
    public let evidenceIDs: Set<String>

    public init(setID: String, conceptID: String, evidenceIDs: Set<String>) throws {
        let trimmedSetID = setID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedConceptID = conceptID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSetID.isEmpty else {
            throw Inf6KnowledgeStructureError.invalidMembership("setID is empty")
        }
        guard !trimmedConceptID.isEmpty else {
            throw Inf6KnowledgeStructureError.invalidMembership("conceptID is empty")
        }
        guard !evidenceIDs.isEmpty else {
            throw Inf6KnowledgeStructureError.invalidMembership("membership requires evidence")
        }
        self.setID = trimmedSetID
        self.conceptID = trimmedConceptID
        self.evidenceIDs = evidenceIDs
    }
}

public struct Inf6KnowledgeRelation: Codable, Hashable, Sendable {
    public let relationID: String
    public let fromConceptID: String
    public let toConceptID: String
    public let kind: Inf6KnowledgeRelationKind
    public let evidenceIDs: Set<String>

    public init(
        relationID: String,
        fromConceptID: String,
        toConceptID: String,
        kind: Inf6KnowledgeRelationKind,
        evidenceIDs: Set<String>
    ) throws {
        let trimmedRelationID = relationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFrom = fromConceptID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTo = toConceptID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRelationID.isEmpty else {
            throw Inf6KnowledgeStructureError.invalidRelation("relationID is empty")
        }
        guard !trimmedFrom.isEmpty else {
            throw Inf6KnowledgeStructureError.invalidRelation("fromConceptID is empty")
        }
        guard !trimmedTo.isEmpty else {
            throw Inf6KnowledgeStructureError.invalidRelation("toConceptID is empty")
        }
        guard trimmedFrom != trimmedTo else {
            throw Inf6KnowledgeStructureError.invalidRelation("self relation is not allowed: \(trimmedFrom)")
        }
        guard !evidenceIDs.isEmpty else {
            throw Inf6KnowledgeStructureError.invalidRelation("relation requires evidence")
        }
        self.relationID = trimmedRelationID
        self.fromConceptID = trimmedFrom
        self.toConceptID = trimmedTo
        self.kind = kind
        self.evidenceIDs = evidenceIDs
    }
}

public struct Inf6SemanticScopeVerificationReport: Codable, Hashable, Sendable {
    public struct Issue: Codable, Hashable, Sendable {
        public let conceptID: String
        public let code: String
        public let message: String

        public init(conceptID: String, code: String, message: String) {
            self.conceptID = conceptID
            self.code = code
            self.message = message
        }
    }

    public let version: String
    public let verified: Bool
    public let issueCount: Int
    public let issues: [Issue]
    public let checkedAt: TimeInterval

    public init(version: String, issues: [Issue], checkedAt: TimeInterval = Date().timeIntervalSince1970) {
        self.version = version
        self.verified = issues.isEmpty
        self.issueCount = issues.count
        self.issues = issues
        self.checkedAt = checkedAt
    }
}

public enum Inf6KnowledgeStructureError: Error, CustomStringConvertible {
    case invalidDomainDefinition(String)
    case invalidEvidence(String)
    case invalidMembership(String)
    case invalidRelation(String)

    public var description: String {
        switch self {
        case .invalidDomainDefinition(let message):
            return "invalid domain definition: \(message)"
        case .invalidEvidence(let message):
            return "invalid evidence: \(message)"
        case .invalidMembership(let message):
            return "invalid membership: \(message)"
        case .invalidRelation(let message):
            return "invalid relation: \(message)"
        }
    }
}
