import Foundation

public enum PaperSearchSource: String, CaseIterable, Codable, Sendable {
    case arxiv = "ArXiv"
    case semanticScholar = "Semantic Scholar"
    case crossref = "Crossref"

    public var searchURL: URL {
        switch self {
        case .arxiv: return URL(string: "https://arxiv.org/search/")!
        case .semanticScholar: return URL(string: "https://www.semanticscholar.org/search")!
        case .crossref: return URL(string: "https://search.crossref.org/")!
        }
    }
}

public struct PaperSearchConfiguration: Codable, Equatable, Sendable {
    public var sources: [PaperSearchSource]

    public init(sources: [PaperSearchSource] = [.arxiv]) {
        self.sources = sources
    }
}

public struct PaperSearchConfigurationStore {
    private let root: WorkspaceStore

    public init(root: WorkspaceStore) {
        self.root = root
    }

    public func load() throws -> PaperSearchConfiguration? {
        try root.load(PaperSearchConfiguration.self, named: "search.json", in: "papers")
    }

    public func save(_ configuration: PaperSearchConfiguration) throws {
        try root.save(configuration, named: "search.json", in: "papers")
    }
}
