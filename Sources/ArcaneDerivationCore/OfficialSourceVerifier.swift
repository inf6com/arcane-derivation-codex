import Foundation
import CryptoKit

public struct OfficialSourceVerifier {
    public init() {}

    public func verify(url: URL) async throws -> OfficialSourceResult {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "jdla.org" || host == "www.jdla.org" else {
            throw SourceVerificationError.notOfficialSource
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SourceVerificationError.unreachable
        }
        guard !data.isEmpty else { throw SourceVerificationError.empty }
        let text = String(decoding: data, as: UTF8.self)
        guard text.localizedCaseInsensitiveContains("E資格"),
              text.localizedCaseInsensitiveContains("シラバス") else { throw SourceVerificationError.notSyllabus }
        let revision = latestRevision(in: text)
        guard let revision else { throw SourceVerificationError.revisionUnavailable }
        return OfficialSourceResult(
            name: "E資格の試験出題範囲（シラバス）",
            revision: revision,
            contentHash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            content: text
        )
    }

    private func latestRevision(in text: String) -> String? {
        let characters = Array(text)
        var revisions: [String] = []
        var index = 0
        while index + 6 < characters.count {
            guard characters[index] == "E" else { index += 1; continue }
            var cursor = index + 1
            var year = ""
            while cursor < characters.count, year.count < 4, characters[cursor].isNumber {
                year.append(characters[cursor]); cursor += 1
            }
            guard year.count == 4, year.hasPrefix("20"), cursor < characters.count, characters[cursor] == "#" else {
                index += 1
                continue
            }
            cursor += 1
            var number = ""
            while cursor < characters.count, characters[cursor].isNumber {
                number.append(characters[cursor]); cursor += 1
            }
            if !number.isEmpty { revisions.append("E\(year)#\(number)") }
            index = max(cursor, index + 1)
        }
        return revisions.max { lhs, rhs in
            let left = lhs.dropFirst().split(separator: "#").compactMap { Int($0) }
            let right = rhs.dropFirst().split(separator: "#").compactMap { Int($0) }
            return left.lexicographicallyPrecedes(right)
        }
    }
}

public struct OfficialSourceResult: Sendable {
    public let name: String
    public let revision: String?
    public let contentHash: String
    public let content: String

    public init(name: String, revision: String?, contentHash: String, content: String) {
        self.name = name
        self.revision = revision
        self.contentHash = contentHash
        self.content = content
    }
}

public enum SourceVerificationError: LocalizedError {
    case notOfficialSource
    case unreachable
    case empty
    case notSyllabus
    case revisionUnavailable
    public var errorDescription: String? {
        switch self {
        case .notOfficialSource: return "JDLA公式ページのURLを指定してください。"
        case .unreachable: return "公式資料を取得できません。URLとネットワークを確認してください。"
        case .empty: return "取得した公式資料が空です。"
        case .notSyllabus: return "取得内容がE資格シラバスとして確認できません。"
        case .revisionUnavailable: return "取得内容からシラバスのバージョンを確認できません。"
        }
    }
}
