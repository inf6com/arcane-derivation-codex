import Foundation

public enum TexTellerVocabularyError: LocalizedError {
    case resourceMissing(String)
    case malformed(String)
    case unknownToken(Int32)

    public var errorDescription: String? {
        switch self {
        case .resourceMissing(let name): return "TexTeller語彙表がありません: \(name)"
        case .malformed(let reason): return "TexTeller語彙表を読み込めません: \(reason)"
        case .unknownToken(let id): return "TexTeller語彙表にないトークンです: \(id)"
        }
    }
}

/// Decodes the token IDs emitted by TexTeller's ByteLevel-BPE tokenizer.
/// The vocabulary is data shipped with the adopted model; no token is guessed.
public struct TexTellerVocabulary: Sendable {
    private let pieces: [Int32: String]
    private let specialIDs: Set<Int32>

    public init(bundle: Bundle = .main) throws {
        guard let vocabURL = bundle.url(forResource: "vocab", withExtension: "json", subdirectory: "TexTellerTokenizer"),
              let configURL = bundle.url(forResource: "tokenizer_config", withExtension: "json", subdirectory: "TexTellerTokenizer") else {
            throw TexTellerVocabularyError.resourceMissing("TexTellerTokenizer/vocab.json または tokenizer_config.json")
        }
        do {
            let vocab = try JSONDecoder().decode([String: Int32].self, from: Data(contentsOf: vocabURL))
            let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
            var decoded = Dictionary(uniqueKeysWithValues: vocab.map { ($0.value, $0.key) })
            var specials = Set<Int32>()
            if let added = config?["added_tokens_decoder"] as? [String: [String: Any]] {
                for (idText, token) in added {
                    guard let id = Int32(idText), let content = token["content"] as? String else { continue }
                    decoded[id] = content
                    if token["special"] as? Bool == true { specials.insert(id) }
                }
            }
            pieces = decoded
            specialIDs = specials
        } catch {
            throw TexTellerVocabularyError.malformed(error.localizedDescription)
        }
    }

    public func decode(_ tokenIDs: [Int32]) throws -> String {
        var byteBuffer: [UInt8] = []
        for id in tokenIDs where !specialIDs.contains(id) {
            guard let piece = pieces[id] else { throw TexTellerVocabularyError.unknownToken(id) }
            for scalar in piece.unicodeScalars {
                if let byte = Self.byteForByteLevelScalar(scalar) {
                    byteBuffer.append(byte)
                } else {
                    byteBuffer.append(contentsOf: String(scalar).utf8)
                }
            }
        }
        guard let decoded = String(bytes: byteBuffer, encoding: .utf8) else {
            throw TexTellerVocabularyError.malformed("ByteLevel復号結果がUTF-8ではありません")
        }
        return decoded
    }

    private static func byteForByteLevelScalar(_ scalar: UnicodeScalar) -> UInt8? {
        let value = Int(scalar.value)
        if value < 256, value < 128 || (value >= 161 && value <= 172) || (value >= 174 && value <= 255) {
            return UInt8(value)
        }
        var bytes = Array(33...126) + Array(161...172) + Array(174...255)
        var codePoints = bytes
        var next = 0
        for byte in 0..<256 where !bytes.contains(byte) {
            bytes.append(byte)
            codePoints.append(256 + next)
            next += 1
        }
        guard let index = codePoints.firstIndex(of: value) else { return nil }
        return UInt8(bytes[index])
    }
}
