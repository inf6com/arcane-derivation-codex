//
//  Inf6PaperEmbedding.swift
//  inf6
//
//  Future: on-device embedding + profile embedding.
//

import Foundation
#if canImport(CoreML)
import CoreML
#endif
#if canImport(Tokenizers)
import Tokenizers
#endif

protocol Inf6EmbeddingProvider {
    /// Returns a fixed-dimension embedding vector.
    func embed(_ text: String) async throws -> [Float]
}

enum Inf6EmbeddingError: LocalizedError {
    case invalidInput
    case modelUnavailable
    case inferenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "Invalid input."
        case .modelUnavailable:
            return "Embedding model is unavailable."
        case .inferenceFailed(let s):
            return "Embedding inference failed: \(s)"
        }
    }
}

enum Inf6EmbeddingBackend: String, Codable {
    case coreML
    case deterministic
}

enum Inf6EmbeddingRole: String, Codable {
    case query
    case passage
}

struct Inf6EmbeddingOutput {
    let vector: [Float]
    let backend: Inf6EmbeddingBackend
}

enum Inf6EmbeddingService {
    static func embed(_ text: String) async throws -> Inf6EmbeddingOutput {
        try await embedPassage(text)
    }

    static func embedQuery(_ text: String) async throws -> Inf6EmbeddingOutput {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Inf6EmbeddingError.invalidInput }
        return try await _embedPrepared(_prepareE5Input(trimmed, role: .query))
    }

    static func embedPassage(_ text: String) async throws -> Inf6EmbeddingOutput {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Inf6EmbeddingError.invalidInput }
        return try await _embedPrepared(_prepareE5Input(trimmed, role: .passage))
    }

    private static func _embedPrepared(_ prepared: String) async throws -> Inf6EmbeddingOutput {
        // Engineering contract: fallback is prohibited. Embedding must be CoreML/ANE.
        let v = try await Inf6CoreMLEmbeddingProvider().embed(prepared)
        return Inf6EmbeddingOutput(vector: v, backend: .coreML)
    }

    private static func _prepareE5Input(_ text: String, role: Inf6EmbeddingRole) -> String {
        let lowered = text.lowercased()
        if lowered.hasPrefix("query:") || lowered.hasPrefix("passage:") {
            return text
        }
        switch role {
        case .query:
            return "query: \(text)"
        case .passage:
            return "passage: \(text)"
        }
    }
}

/// CoreML/ANE embedding provider.
/// It tries to load a bundled `.mlmodelc` text-embedding model.
/// If unavailable, it throws `modelUnavailable`.
struct Inf6CoreMLEmbeddingProvider: Inf6EmbeddingProvider {
    func embed(_ text: String) async throws -> [Float] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw Inf6EmbeddingError.invalidInput }

        #if canImport(CoreML)
        guard let model = _Inf6CoreMLModelCache.shared.model() else {
            throw Inf6EmbeddingError.modelUnavailable
        }

        let inputDescriptions = model.modelDescription.inputDescriptionsByName
        let provider: MLDictionaryFeatureProvider

        if let textInputName = _textInputFeatureName(inputDescriptions) {
            provider = try MLDictionaryFeatureProvider(dictionary: [textInputName: t])
        } else if let idsName = _tokenIDsInputFeatureName(inputDescriptions),
                  let maskName = _attentionMaskInputFeatureName(inputDescriptions) {
            #if canImport(Tokenizers)
            let seqLength = _modelSequenceLength(inputDescriptions, preferredInputName: idsName)
            let tokenized = try await _Inf6TokenizerCache.shared.tokenizeForE5(
                text: t,
                maxLength: seqLength
            )

            let inputIDs = try _makeInt32Array(
                values: tokenized.inputIDs,
                rows: 1,
                cols: seqLength
            )
            let attentionMask = try _makeInt32Array(
                values: tokenized.attentionMask,
                rows: 1,
                cols: seqLength
            )

            provider = try MLDictionaryFeatureProvider(dictionary: [
                idsName: MLFeatureValue(multiArray: inputIDs),
                maskName: MLFeatureValue(multiArray: attentionMask),
            ])
            #else
            throw Inf6EmbeddingError.inferenceFailed("Tokenizers package is unavailable.")
            #endif
        } else {
            throw Inf6EmbeddingError.inferenceFailed("No compatible CoreML input features.")
        }

        let out = try await model.prediction(from: provider)

        if let v = _firstMultiArray(out) {
            let flat = _flatten(v)
            if !flat.isEmpty {
                return Inf6VectorMath.normalizeL2(flat)
            }
        }

        throw Inf6EmbeddingError.inferenceFailed("No MLMultiArray output found.")
        #else
        throw Inf6EmbeddingError.modelUnavailable
        #endif
    }
}

/// Deterministic local fallback (no external model required).
/// Uses hashed token/character n-gram features and L2 normalization.
struct Inf6DeterministicEmbeddingProvider: Inf6EmbeddingProvider {
    private let dimension: Int

    init(dimension: Int = 384) {
        self.dimension = max(64, min(dimension, 2048))
    }

    func embed(_ text: String) async throws -> [Float] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw Inf6EmbeddingError.invalidInput }

        let lower = t.lowercased()
        var vec = Array(repeating: Float(0), count: dimension)

        let tokens = lower
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
            .filter { !$0.isEmpty }

        for tok in tokens {
            let h = _fnv1a64(tok)
            let i = Int(h % UInt64(dimension))
            vec[i] += 1.0
        }

        let chars = Array(lower)
        if chars.count >= 3 {
            for i in 0..<(chars.count - 2) {
                let tri = String(chars[i...i+2])
                let h = _fnv1a64(tri)
                let idx = Int(h % UInt64(dimension))
                vec[idx] += 0.35
            }
        }

        if vec.allSatisfy({ $0 == 0 }) {
            throw Inf6EmbeddingError.inferenceFailed("Deterministic embedding produced an all-zero vector.")
        }

        return Inf6VectorMath.normalizeL2(vec)
    }
}

private func _fnv1a64(_ s: String) -> UInt64 {
    var hash: UInt64 = 0xcbf29ce484222325
    let prime: UInt64 = 0x100000001b3
    for b in s.utf8 {
        hash ^= UInt64(b)
        hash = hash &* prime
    }
    return hash
}

#if canImport(CoreML)
private struct _Inf6CoreMLModelCache {
    static let shared = _Inf6CoreMLModelCache()
    private static var _cachedModel: MLModel? = nil
    private static var _didAttemptLoad: Bool = false
    private static let _lock = NSLock()

    func model() -> MLModel? {
        Self._lock.lock()
        defer { Self._lock.unlock() }

        if Self._didAttemptLoad {
            return Self._cachedModel
        }
        Self._didAttemptLoad = true

        let fm = FileManager.default
        var candidateURLs: [URL] = []

        let names = [
            "Inf6TextEmbedding",
            "inf6_text_embedding",
            "TextEmbedding",
            "PaperEmbedding"
        ]

        for name in names {
            if let u = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
                candidateURLs.append(u)
            }
        }

        for u in candidateURLs {
            if !fm.fileExists(atPath: u.path) { continue }
            do {
                let cfg = MLModelConfiguration()
                cfg.computeUnits = .cpuAndNeuralEngine
                let m = try MLModel(contentsOf: u, configuration: cfg)
                Self._cachedModel = m
                return m
            } catch {
                continue
            }
        }

        Self._cachedModel = nil
        return nil
    }
}

private func _firstMultiArray(_ provider: MLFeatureProvider) -> MLMultiArray? {
    for name in provider.featureNames {
        guard let f = provider.featureValue(for: name) else { continue }
        if let v = f.multiArrayValue {
            return v
        }
    }
    return nil
}

private func _flatten(_ arr: MLMultiArray) -> [Float] {
    let n = arr.count
    if n <= 0 { return [] }

    var out: [Float] = []
    out.reserveCapacity(n)

    switch arr.dataType {
    case .double:
        let p = arr.dataPointer.bindMemory(to: Double.self, capacity: n)
        for i in 0..<n { out.append(Float(p[i])) }
    case .float32:
        let p = arr.dataPointer.bindMemory(to: Float.self, capacity: n)
        for i in 0..<n { out.append(p[i]) }
    case .float16:
        // Float16 direct decode is not exposed uniformly across SDKs.
        // Fall back to NSNumber-based path.
        for i in 0..<n { out.append(arr[i].floatValue) }
    default:
        for i in 0..<n { out.append(arr[i].floatValue) }
    }
    return out
}

private func _textInputFeatureName(_ inputDescriptions: [String: MLFeatureDescription]) -> String? {
    for (name, desc) in inputDescriptions {
        if desc.type == .string {
            return name
        }
    }
    return nil
}

private func _tokenIDsInputFeatureName(_ inputDescriptions: [String: MLFeatureDescription]) -> String? {
    for key in ["input_ids", "inputIds", "token_ids", "tokenIds"] {
        if inputDescriptions[key] != nil {
            return key
        }
    }
    for (name, desc) in inputDescriptions {
        guard desc.type == .multiArray else { continue }
        let lowered = name.lowercased()
        if lowered.contains("input") && lowered.contains("id") {
            return name
        }
    }
    return nil
}

private func _attentionMaskInputFeatureName(_ inputDescriptions: [String: MLFeatureDescription]) -> String? {
    for key in ["attention_mask", "attentionMask", "mask"] {
        if inputDescriptions[key] != nil {
            return key
        }
    }
    for (name, desc) in inputDescriptions {
        guard desc.type == .multiArray else { continue }
        let lowered = name.lowercased()
        if lowered.contains("attention") && lowered.contains("mask") {
            return name
        }
    }
    return nil
}

private func _modelSequenceLength(
    _ inputDescriptions: [String: MLFeatureDescription],
    preferredInputName: String
) -> Int {
    if let desc = inputDescriptions[preferredInputName],
       let shape = desc.multiArrayConstraint?.shape,
       shape.count >= 2 {
        let len = shape[shape.count - 1].intValue
        if len > 0 { return len }
    }
    return 256
}

private func _makeInt32Array(values: [Int32], rows: Int, cols: Int) throws -> MLMultiArray {
    let total = max(0, rows * cols)
    guard values.count == total else {
        throw Inf6EmbeddingError.inferenceFailed(
            "Input vector length mismatch. expected=\(total) actual=\(values.count)"
        )
    }

    let arr = try MLMultiArray(
        shape: [NSNumber(value: rows), NSNumber(value: cols)],
        dataType: .int32
    )
    let ptr = arr.dataPointer.bindMemory(to: Int32.self, capacity: total)
    for i in 0..<total {
        ptr[i] = values[i]
    }
    return arr
}

#if canImport(Tokenizers)
private struct _Inf6TokenizerBatch {
    let inputIDs: [Int32]
    let attentionMask: [Int32]
}

private struct _Inf6TokenizerCache {
    static let shared = _Inf6TokenizerCache()
    private static var _cachedTokenizer: (any Tokenizer)?
    private static var _didAttemptLoad: Bool = false
    private static let _stateQueue = DispatchQueue(label: "com.inf6.tokenizer.cache.state")

    func tokenizeForE5(text: String, maxLength: Int) async throws -> _Inf6TokenizerBatch {
        let tokenizer = try await _tokenizer()
        var ids = tokenizer.encode(text: text, addSpecialTokens: true)
        let width = max(8, maxLength)

        if ids.count > width {
            ids = Array(ids.prefix(width))
        }

        let padID = tokenizer.convertTokenToId("<pad>") ?? 1
        var input = Array(repeating: Int32(padID), count: width)
        var mask = Array(repeating: Int32(0), count: width)

        let n = min(ids.count, width)
        for i in 0..<n {
            input[i] = Int32(ids[i])
            mask[i] = 1
        }

        return _Inf6TokenizerBatch(inputIDs: input, attentionMask: mask)
    }

    private func _tokenizer() async throws -> any Tokenizer {
        if let tok = Self._stateQueue.sync(execute: { Self._cachedTokenizer }) {
            return tok
        }
        let shouldAttemptLoad = Self._stateQueue.sync { () -> Bool in
            if Self._didAttemptLoad { return false }
            Self._didAttemptLoad = true
            return true
        }
        if !shouldAttemptLoad {
            throw Inf6EmbeddingError.modelUnavailable
        }

        guard let folder = try _tokenizerModelFolder() else {
            throw Inf6EmbeddingError.modelUnavailable
        }

        let tok = try await AutoTokenizer.from(modelFolder: folder)

        Self._stateQueue.sync {
            Self._cachedTokenizer = tok
        }
        return tok
    }

    private func _tokenizerModelFolder() throws -> URL? {
        let fm = FileManager.default
        let bundle = Bundle.main
        if let dir = bundle.url(forResource: "Inf6TextEmbeddingTokenizer", withExtension: nil),
           _hasTokenizerFiles(in: dir) {
            return dir
        }

        let tokenizerURL = bundle.url(forResource: "tokenizer", withExtension: "json", subdirectory: "Inf6TextEmbeddingTokenizer")
            ?? bundle.url(forResource: "tokenizer", withExtension: "json")
            ?? bundle.url(forResource: "inf6_e5_tokenizer", withExtension: "json")

        let configURL = bundle.url(forResource: "tokenizer_config", withExtension: "json", subdirectory: "Inf6TextEmbeddingTokenizer")
            ?? bundle.url(forResource: "tokenizer_config", withExtension: "json")
            ?? bundle.url(forResource: "inf6_e5_tokenizer_config", withExtension: "json")

        guard let tokenizerURL, let configURL else { return nil }

        let dir = Inf6DataRoot.url()
            .appendingPathComponent("tokenizer", isDirectory: true)
            .appendingPathComponent("multilingual-e5-small", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let dstTokenizer = dir.appendingPathComponent("tokenizer.json", isDirectory: false)
        let dstConfig = dir.appendingPathComponent("tokenizer_config.json", isDirectory: false)
        if !fm.fileExists(atPath: dstTokenizer.path) {
            try fm.copyItem(at: tokenizerURL, to: dstTokenizer)
        }
        if !fm.fileExists(atPath: dstConfig.path) {
            try fm.copyItem(at: configURL, to: dstConfig)
        }

        if _hasTokenizerFiles(in: dir) {
            return dir
        }
        return nil
    }

    private func _hasTokenizerFiles(in dir: URL) -> Bool {
        let fm = FileManager.default
        let tok = dir.appendingPathComponent("tokenizer.json", isDirectory: false)
        let cfg = dir.appendingPathComponent("tokenizer_config.json", isDirectory: false)
        return fm.fileExists(atPath: tok.path) && fm.fileExists(atPath: cfg.path)
    }
}
#endif
#endif
