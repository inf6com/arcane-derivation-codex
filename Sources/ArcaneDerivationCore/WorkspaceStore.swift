import Foundation

public struct WorkspaceStore {
    public let root: URL
    private let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) throws {
        self.root = root.standardizedFileURL
        self.fileManager = fileManager
        var directory: ObjCBool = false
        guard fileManager.fileExists(atPath: self.root.path, isDirectory: &directory), directory.boolValue else {
            throw WorkspaceError.rootUnavailable
        }
    }

    public func save<T: Encodable>(_ value: T, named name: String, in directoryName: String) throws {
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder.workspace.encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    public func load<T: Decodable>(_ type: T.Type, named name: String, in directoryName: String) throws -> T? {
        let url = root.appendingPathComponent(directoryName, isDirectory: true).appendingPathComponent(name)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder.workspace.decode(type, from: Data(contentsOf: url))
    }
}

public enum WorkspaceError: LocalizedError {
    case rootUnavailable
    public var errorDescription: String? { "保存先を設定してください。" }
}

extension JSONEncoder {
    static var workspace: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var workspace: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
