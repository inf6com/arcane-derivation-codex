import Foundation

public struct SyllabusRepository {
    private let root: WorkspaceStore

    public init(root: WorkspaceStore) {
        self.root = root
    }

    public func current(domain: String) throws -> SyllabusSnapshot? {
        try root.load(SyllabusSnapshot.self, named: fileName(for: domain), in: "syllabus")
    }

    public func refreshStatus(domain: String) throws -> SyllabusRefreshStatus? {
        try root.load(SyllabusRefreshStatus.self, named: statusFileName(for: domain), in: "syllabus")
    }

    public func revisionHistory(domain: String) throws -> [SyllabusRevisionChange] {
        try root.load([SyllabusRevisionChange].self, named: historyFileName(for: domain), in: "syllabus") ?? []
    }

    public func recordRefreshFailure(domain: String, error: Error) throws {
        let previous = try refreshStatus(domain: domain)
        let status = SyllabusRefreshStatus(
            domainName: domain,
            lastAttemptedAt: .now,
            lastSucceededAt: previous?.lastSucceededAt,
            lastFailure: error.localizedDescription,
            sourceURL: previous?.sourceURL
        )
        try root.save(status, named: statusFileName(for: domain), in: "syllabus")
    }

    public func recordRefreshSuccess(domain: String, at date: Date, sourceURL: URL? = nil) throws {
        let status = SyllabusRefreshStatus(domainName: domain, lastAttemptedAt: date, lastSucceededAt: date, sourceURL: sourceURL)
        try root.save(status, named: statusFileName(for: domain), in: "syllabus")
    }

    @discardableResult
    public func record(_ snapshot: SyllabusSnapshot, domain: String) throws -> SyllabusRevisionChange? {
        let current = try root.load(SyllabusSnapshot.self, named: fileName(for: domain), in: "syllabus")
        guard current?.revision != snapshot.revision || current?.contentHash != snapshot.contentHash else {
            return nil
        }

        let summary = current == nil ? "初回取得" : "版または内容ハッシュが変更されました"
        let change = SyllabusRevisionChange(
            previousRevision: current?.revision,
            currentRevision: snapshot.revision,
            sourceURL: snapshot.sourceURL,
            previousContentHash: current?.contentHash,
            currentContentHash: snapshot.contentHash,
            effectiveDate: snapshot.effectiveDate,
            changeSummary: summary
        )
        var history = try revisionHistory(domain: domain)
        history.append(change)
        try root.save(snapshot, named: fileName(for: domain), in: "syllabus")
        try root.save(history, named: historyFileName(for: domain), in: "syllabus")
        return change
    }

    private func fileName(for domain: String) -> String {
        "\(fileStem(for: domain)).json"
    }

    private func statusFileName(for domain: String) -> String {
        "refresh-status-\(fileStem(for: domain)).json"
    }

    private func historyFileName(for domain: String) -> String {
        "revision-history-\(fileStem(for: domain)).json"
    }

    private func fileStem(for domain: String) -> String {
        if domain == "E資格" { return "e-qualification" }
        let stem = domain.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" ? String(scalar) : "-"
        }.joined()
        return stem.trimmingCharacters(in: CharacterSet(charactersIn: "-_")).isEmpty ? "domain" : stem
    }
}

public struct SyllabusUpdateService {
    private let verifier: OfficialSourceVerifier
    private let repository: SyllabusRepository

    public init(root: WorkspaceStore, verifier: OfficialSourceVerifier = OfficialSourceVerifier()) {
        self.verifier = verifier
        self.repository = SyllabusRepository(root: root)
    }

    @discardableResult
    public func refresh(domain: String, sourceURL: URL) async throws -> SyllabusRefreshResult {
        let source = try await verifier.verify(url: sourceURL)
        guard let revision = source.revision else { throw SourceVerificationError.revisionUnavailable }
        let snapshot = SyllabusSnapshot(
            domainName: source.name,
            revision: revision,
            sourceURL: sourceURL,
            verified: true,
            contentHash: source.contentHash,
            content: source.content,
            evidence: [KnowledgeEvidence(kind: .officialSyllabus, source: sourceURL.absoluteString, locator: revision)]
        )
        let change = try repository.record(snapshot, domain: domain)
        try repository.recordRefreshSuccess(domain: domain, at: snapshot.checkedAt, sourceURL: snapshot.sourceURL)
        return SyllabusRefreshResult(snapshot: snapshot, revisionChanged: change != nil)
    }

}

public struct SyllabusRefreshResult {
    public let snapshot: SyllabusSnapshot
    public let revisionChanged: Bool

    public init(snapshot: SyllabusSnapshot, revisionChanged: Bool) {
        self.snapshot = snapshot
        self.revisionChanged = revisionChanged
    }
}
