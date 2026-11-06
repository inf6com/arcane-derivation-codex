import Foundation

public enum KnowledgeSourceKind: String, Codable, Sendable {
    case officialSyllabus
    case originPaper
    case paperCrop
    case originalExplanation
}

public struct KnowledgeEvidence: Codable, Hashable, Sendable {
    public let id: UUID
    public let kind: KnowledgeSourceKind
    public let source: String
    public let locator: String
    public let observedAt: Date

    public init(kind: KnowledgeSourceKind, source: String, locator: String, observedAt: Date = .now) {
        self.id = UUID()
        self.kind = kind
        self.source = source
        self.locator = locator
        self.observedAt = observedAt
    }
}

public struct SyllabusSnapshot: Codable, Hashable, Sendable {
    public let domainName: String
    public let revision: String
    public let sourceURL: URL?
    public let effectiveDate: Date?
    public let verified: Bool
    public let checkedAt: Date
    public let contentHash: String?
    public let content: String?
    public let evidence: [KnowledgeEvidence]

    public init(domainName: String, revision: String, sourceURL: URL, effectiveDate: Date? = nil, verified: Bool = false, checkedAt: Date = .now, contentHash: String? = nil, content: String? = nil, evidence: [KnowledgeEvidence] = []) {
        self.domainName = domainName
        self.revision = revision
        self.sourceURL = sourceURL
        self.effectiveDate = effectiveDate
        self.verified = verified
        self.checkedAt = checkedAt
        self.contentHash = contentHash
        self.content = content
        self.evidence = evidence
    }
}

public struct SyllabusRevisionChange: Codable, Hashable, Sendable {
    public let previousRevision: String?
    public let currentRevision: String
    public let changedAt: Date
    public let sourceURL: URL?
    public let previousContentHash: String?
    public let currentContentHash: String?
    public let effectiveDate: Date?
    public let changeSummary: String?

    public init(previousRevision: String?, currentRevision: String, changedAt: Date = .now, sourceURL: URL? = nil, previousContentHash: String? = nil, currentContentHash: String? = nil, effectiveDate: Date? = nil, changeSummary: String? = nil) {
        self.previousRevision = previousRevision
        self.currentRevision = currentRevision
        self.changedAt = changedAt
        self.sourceURL = sourceURL
        self.previousContentHash = previousContentHash
        self.currentContentHash = currentContentHash
        self.effectiveDate = effectiveDate
        self.changeSummary = changeSummary
    }
}

public struct SyllabusRefreshStatus: Codable, Hashable, Sendable {
    public let domainName: String
    public let lastAttemptedAt: Date
    public let lastSucceededAt: Date?
    public let lastFailure: String?
    public let sourceURL: URL?

    public init(domainName: String, lastAttemptedAt: Date = .now, lastSucceededAt: Date? = nil, lastFailure: String? = nil, sourceURL: URL? = nil) {
        self.domainName = domainName
        self.lastAttemptedAt = lastAttemptedAt
        self.lastSucceededAt = lastSucceededAt
        self.lastFailure = lastFailure
        self.sourceURL = sourceURL
    }
}

public enum CropKind: String, Codable, CaseIterable, Sendable {
    case figure
    case table
    case equation
}

public struct PaperCrop: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let kind: CropKind
    public let page: Int
    public let title: String
    public let imageRelativePath: String
    public let evidence: KnowledgeEvidence

    public init(kind: CropKind, page: Int, title: String, imageRelativePath: String, evidence: KnowledgeEvidence) {
        self.id = UUID()
        self.kind = kind
        self.page = page
        self.title = title
        self.imageRelativePath = imageRelativePath
        self.evidence = evidence
    }

    public var deduplicationKey: String { "\(kind.rawValue)|\(page)|\(title.trimmingCharacters(in: .whitespacesAndNewlines))" }
}

public struct PaperRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let domainID: String?
    public let chapterID: String?
    public let title: String
    public let sourceURL: URL
    public let pdfRelativePath: String?
    public let originVerified: Bool
    public let originVerificationFailure: String?
    public let crops: [PaperCrop]

    public init(id: UUID = UUID(), domainID: String? = nil, chapterID: String? = nil, title: String, sourceURL: URL, pdfRelativePath: String? = nil, originVerified: Bool, originVerificationFailure: String? = nil, crops: [PaperCrop] = []) {
        self.id = id
        self.domainID = domainID
        self.chapterID = chapterID
        self.title = title
        self.sourceURL = sourceURL
        self.pdfRelativePath = pdfRelativePath
        self.originVerified = originVerified
        self.originVerificationFailure = originVerificationFailure
        self.crops = crops
    }
}
