import CoreML
import Foundation
import OSLog

public struct TexTellerGeneratedChunk: Sendable, Equatable {
    public let tokenIDs: [Int32]
    public let endedWithEOS: Bool
    public let continuationRequired: Bool

    public init(tokenIDs: [Int32], endedWithEOS: Bool, continuationRequired: Bool) {
        self.tokenIDs = tokenIDs
        self.endedWithEOS = endedWithEOS
        self.continuationRequired = continuationRequired
    }
}

public struct TexTellerMathMLResult: Sendable, Equatable {
    public let tokenIDs: [Int32]
    public let decodedExpression: String
    public let mathML: String

    public init(tokenIDs: [Int32], decodedExpression: String, mathML: String) {
        self.tokenIDs = tokenIDs
        self.decodedExpression = decodedExpression
        self.mathML = mathML
    }
}

public enum TexTellerExecutionError: LocalizedError {
    case modelUnavailable(String)
    case invalidEncoderShape([Int])
    case invalidEncoderType
    case encoderUnavailable
    case invalidPixelShape([Int])
    case invalidPixelType
    case invalidModelInterface(String)
    case missingFeature(String)
    case invalidOutput(String)
    case invalidToken(Int32)
    case emptyGeneration
    case generationLimit

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let reason): return "数式認識モデルを読み込めません: \(reason)"
        case .invalidEncoderShape(let shape): return "数式認識の特徴量shapeが不正です: \(shape)"
        case .invalidEncoderType: return "数式認識の特徴量はFloat16またはFloat32である必要があります。"
        case .encoderUnavailable: return "数式認識Encoderがアプリ内にありません。"
        case .invalidPixelShape(let shape): return "数式認識画像のshapeが不正です: \(shape)"
        case .invalidPixelType: return "数式認識画像はFloat16またはFloat32である必要があります。"
        case .invalidModelInterface(let reason): return "数式認識デコーダの入出力契約が不正です: \(reason)"
        case .missingFeature(let name): return "数式認識モデルの入出力がありません: \(name)"
        case .invalidOutput(let name): return "数式認識モデルの出力を読めません: \(name)"
        case .invalidToken(let token): return "数式認識トークンが語彙範囲外です: \(token)"
        case .emptyGeneration: return "印刷数式用の認識モデルがEOSのみを返しました。手書き数式を認識するモデルは未接続です。"
        case .generationLimit: return "数式認識の継続上限に達しました。導出を分割して保存してください。"
        }
    }
}

/// Runs the converted TexTeller Transformer decoder one token at a time.
///
/// The model has a fixed 1024-slot self-attention cache because Core ML does
/// not accept the variable cache shapes emitted by the source Transformer.
/// `activeLength` is the number of valid slots. When the window is full, the
/// manager resets the physical cache and primes it with the last 1023 tokens;
/// the generated sequence itself remains unbounded and is returned to the
/// caller for parser/MathML continuation.
public final class TexTellerExecutionManager {
    public static let cacheLength = 1024
    public static let encoderTokenCount = 785
    public static let encoderHiddenSize = 768
    public static let layerCount = 12
    public static let headCount = 16
    public static let headDimension = 64
    public static let vocabularySize = 15_000
    private static let logger = Logger(subsystem: "com.inf6.inf6", category: "TexTellerCoreML")

    private let initialModel: MLModel
    private let recurrentModel: MLModel
    private var encoderModel: MLModel?
    private var selfKeys: [MLMultiArray]
    private var selfValues: [MLMultiArray]
    private var encoderKeys: [MLMultiArray]
    private var encoderValues: [MLMultiArray]
    private var activeLength = 0

    public init(initialModelURL: URL, recurrentModelURL: URL) throws {
        Self.logger.info("loading decoder models")
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            initialModel = try MLModel(contentsOf: initialModelURL, configuration: configuration)
            recurrentModel = try MLModel(contentsOf: recurrentModelURL, configuration: configuration)
        } catch {
            throw TexTellerExecutionError.modelUnavailable(error.localizedDescription)
        }
        encoderModel = nil
        try Self.validateInterface(initialModel.modelDescription, requiresEncoderCache: false)
        try Self.validateInterface(recurrentModel.modelDescription, requiresEncoderCache: true)
        self.selfKeys = try (0..<Self.layerCount).map { _ in try Self.makeArray([1, Self.headCount, Self.cacheLength, Self.headDimension], type: .float16) }
        self.selfValues = try (0..<Self.layerCount).map { _ in try Self.makeArray([1, Self.headCount, Self.cacheLength, Self.headDimension], type: .float16) }
        self.encoderKeys = try (0..<Self.layerCount).map { _ in try Self.makeArray([1, Self.headCount, Self.encoderTokenCount, Self.headDimension], type: .float16) }
        self.encoderValues = try (0..<Self.layerCount).map { _ in try Self.makeArray([1, Self.headCount, Self.encoderTokenCount, Self.headDimension], type: .float16) }
        Self.logger.info("decoder models loaded and KV cache allocated")
    }

    public convenience init(bundledIn bundle: Bundle = .main) throws {
        Self.logger.info("resolving bundled TexTeller models")
        guard let encoderURL = bundle.url(forResource: "TexTellerEncoder", withExtension: "mlmodelc")
                ?? bundle.url(forResource: "TexTellerEncoder", withExtension: "mlpackage") else {
            throw TexTellerExecutionError.encoderUnavailable
        }
        guard let initialURL = bundle.url(forResource: "TexTellerDecoderInit", withExtension: "mlmodelc")
                ?? bundle.url(forResource: "TexTellerDecoderInit", withExtension: "mlpackage"),
              let recurrentURL = bundle.url(forResource: "TexTellerDecoderKV", withExtension: "mlmodelc")
                ?? bundle.url(forResource: "TexTellerDecoderKV", withExtension: "mlpackage") else {
            throw TexTellerExecutionError.modelUnavailable("TexTellerDecoderInitまたはTexTellerDecoderKVがアプリ内にありません。")
        }
        try self.init(initialModelURL: initialURL, recurrentModelURL: recurrentURL)
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            encoderModel = try MLModel(contentsOf: encoderURL, configuration: configuration)
            try Self.validateEncoderInterface(encoderModel!.modelDescription)
            Self.logger.info("encoder model loaded")
        } catch {
            throw TexTellerExecutionError.modelUnavailable(error.localizedDescription)
        }
    }

    /// Encodes a normalized `[1, 1, 448, 448]` crop and runs the same
    /// one-token Transformer execution path used by `generate`.
    public func generate(
        pixelValues: MLMultiArray,
        startTokenID: Int32,
        eosTokenID: Int32,
        maximumTokens: Int = 8_192
    ) throws -> [Int32] {
        guard let encoderModel else { throw TexTellerExecutionError.encoderUnavailable }
        let shape = pixelValues.shape.map(\.intValue)
        guard shape == [1, 1, 448, 448] else { throw TexTellerExecutionError.invalidPixelShape(shape) }
        guard pixelValues.dataType == .float16 || pixelValues.dataType == .float32 else {
            throw TexTellerExecutionError.invalidPixelType
        }
        let output = try encoderModel.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "pixel_values": MLFeatureValue(multiArray: pixelValues)
        ]))
        Self.logger.info("encoder prediction completed")
        guard let hiddenStates = output.featureValue(for: "last_hidden_state")?.multiArrayValue else {
            throw TexTellerExecutionError.invalidOutput("last_hidden_state")
        }
        return try generate(
            encoderHiddenStates: hiddenStates,
            startTokenID: startTokenID,
            eosTokenID: eosTokenID,
            maximumTokens: maximumTokens
        )
    }

    public func generateMathML(
        pixelValues: MLMultiArray,
        startTokenID: Int32,
        eosTokenID: Int32,
        maximumTokens: Int = 8_192,
        vocabulary: TexTellerVocabulary
    ) throws -> TexTellerMathMLResult {
        let tokenIDs = try generate(
            pixelValues: pixelValues,
            startTokenID: startTokenID,
            eosTokenID: eosTokenID,
            maximumTokens: maximumTokens
        )
        Self.logger.info("generated token IDs: \(tokenIDs.map(String.init).joined(separator: ","), privacy: .public)")
        let decodedExpression = try vocabulary.decode(tokenIDs)
        Self.logger.info("decoded expression: \(decodedExpression, privacy: .public)")
        guard !decodedExpression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TexTellerExecutionError.emptyGeneration
        }
        let expression = TexTellerSyntaxTree.normalizeExpression(decodedExpression)
        let mathML = try LaTeXMathMLConverter().convert(expression)
        return TexTellerMathMLResult(tokenIDs: tokenIDs, decodedExpression: expression, mathML: mathML)
    }

    /// Generates one unbounded token stream. A new physical cache window is
    /// created automatically; no token is silently discarded at a boundary.
    public func generate(
        encoderHiddenStates: MLMultiArray,
        startTokenID: Int32,
        eosTokenID: Int32,
        maximumTokens: Int = 8_192
    ) throws -> [Int32] {
        guard maximumTokens > 0 else { throw TexTellerExecutionError.generationLimit }
        try validateEncoder(encoderHiddenStates)
        resetCache()
        Self.logger.info("generation started; maximumTokens=\(maximumTokens, privacy: .public)")

        var sequence = [startTokenID]
        var predicted = try step(tokenID: startTokenID, encoderHiddenStates: encoderHiddenStates)
        while sequence.count < maximumTokens {
            try Task.checkCancellation()
            sequence.append(predicted)
            if predicted == eosTokenID {
                Self.logger.info("generation completed; tokens=\(sequence.count, privacy: .public)")
                return sequence
            }
            if sequence.count.isMultiple(of: 32) {
                Self.logger.info("generation progress; tokens=\(sequence.count, privacy: .public)")
            }

            if activeLength >= Self.cacheLength {
                let context = Array(sequence.suffix(Self.cacheLength - 1))
                resetCache()
                for token in context {
                    predicted = try step(tokenID: token, encoderHiddenStates: encoderHiddenStates)
                }
                continue
            }
            predicted = try step(tokenID: predicted, encoderHiddenStates: encoderHiddenStates)
        }
        Self.logger.error("generation reached maximumTokens without EOS; tokens=\(sequence.count, privacy: .public)")
        throw TexTellerExecutionError.generationLimit
    }

    /// Produces a bounded visible segment and tells the caller when the next
    /// segment must be requested. This is useful when the UI must display and
    /// save partial MathML before more tokens are generated.
    public func generateChunk(
        encoderHiddenStates: MLMultiArray,
        startTokenID: Int32,
        eosTokenID: Int32,
        maximumTokens: Int = 1024
    ) throws -> TexTellerGeneratedChunk {
        guard (1...Self.cacheLength).contains(maximumTokens) else { throw TexTellerExecutionError.generationLimit }
        try validateEncoder(encoderHiddenStates)
        resetCache()
        var tokens = [startTokenID]
        while tokens.count < maximumTokens {
            let input = tokens.last ?? startTokenID
            let next = try step(tokenID: input, encoderHiddenStates: encoderHiddenStates)
            tokens.append(next)
            if next == eosTokenID {
                return TexTellerGeneratedChunk(tokenIDs: tokens, endedWithEOS: true, continuationRequired: false)
            }
            if activeLength == Self.cacheLength { break }
        }
        return TexTellerGeneratedChunk(tokenIDs: tokens, endedWithEOS: false, continuationRequired: true)
    }

    private func step(tokenID: Int32, encoderHiddenStates: MLMultiArray) throws -> Int32 {
        try Task.checkCancellation()
        guard tokenID >= 0 && tokenID < Int32(Self.vocabularySize) else {
            throw TexTellerExecutionError.invalidToken(tokenID)
        }
        let inputIDs = try Self.makeArray([1, 1], type: .int32)
        inputIDs[0] = NSNumber(value: tokenID)
        let attentionMask = try Self.makeArray([1, Self.cacheLength + 1], type: .int32)
        for index in 0..<activeLength { attentionMask[index] = 1 }
        attentionMask[Self.cacheLength] = 1
        let positionIDs = try Self.makeArray([1, 1], type: .int32)
        positionIDs[0] = NSNumber(value: activeLength)

        let activeModel = activeLength == 0 ? initialModel : recurrentModel
        var inputs: [String: MLFeatureValue] = [
            "input_ids": MLFeatureValue(multiArray: inputIDs),
            "encoder_hidden_states": MLFeatureValue(multiArray: encoderHiddenStates),
            "attention_mask": MLFeatureValue(multiArray: attentionMask),
            "position_ids": MLFeatureValue(multiArray: positionIDs)
        ]
        for layer in 0..<Self.layerCount {
            inputs["past_key_values_\(layer)_decoder_key"] = MLFeatureValue(multiArray: selfKeys[layer])
            inputs["past_key_values_\(layer)_decoder_value"] = MLFeatureValue(multiArray: selfValues[layer])
            if activeLength > 0 {
                inputs["past_key_values_\(layer)_encoder_key"] = MLFeatureValue(multiArray: encoderKeys[layer])
                inputs["past_key_values_\(layer)_encoder_value"] = MLFeatureValue(multiArray: encoderValues[layer])
            }
        }

        let output = try activeModel.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
        guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
            throw TexTellerExecutionError.invalidOutput("logits")
        }
        guard logits.shape.map(\.intValue) == [1, 1, Self.vocabularySize] else {
            throw TexTellerExecutionError.invalidOutput("logitsのshape")
        }
        let nextToken = argmax(logits)
        for layer in 0..<Self.layerCount {
            guard let key = output.featureValue(for: "present_\(layer)_decoder_key")?.multiArrayValue,
                  let value = output.featureValue(for: "present_\(layer)_decoder_value")?.multiArrayValue,
                  let encoderKey = output.featureValue(for: "present_\(layer)_encoder_key")?.multiArrayValue,
                  let encoderValue = output.featureValue(for: "present_\(layer)_encoder_value")?.multiArrayValue else {
                throw TexTellerExecutionError.invalidOutput("present_\(layer)")
            }
            guard key.shape.map(\.intValue) == [1, Self.headCount, Self.cacheLength + 1, Self.headDimension],
                  value.shape.map(\.intValue) == [1, Self.headCount, Self.cacheLength + 1, Self.headDimension],
                  encoderKey.shape.map(\.intValue) == [1, Self.headCount, Self.encoderTokenCount, Self.headDimension],
                  encoderValue.shape.map(\.intValue) == [1, Self.headCount, Self.encoderTokenCount, Self.headDimension] else {
                throw TexTellerExecutionError.invalidOutput("present_\(layer)のshape")
            }
            updateSelfCache(key: key, value: value, layer: layer)
            self.encoderKeys[layer] = try Self.copyArray(encoderKey)
            self.encoderValues[layer] = try Self.copyArray(encoderValue)
        }
        activeLength += 1
        return nextToken
    }

    private func updateSelfCache(key: MLMultiArray, value: MLMultiArray, layer: Int) {
        let destinationKey = selfKeys[layer]
        let destinationValue = selfValues[layer]
        let sourceCurrentIndex = Self.cacheLength
        if activeLength < Self.cacheLength {
            for head in 0..<Self.headCount {
                for dimension in 0..<Self.headDimension {
                    destinationKey[offset(head: head, token: activeLength, dimension: dimension)] = key[offset(head: head, token: sourceCurrentIndex, dimension: dimension)]
                    destinationValue[offset(head: head, token: activeLength, dimension: dimension)] = value[offset(head: head, token: sourceCurrentIndex, dimension: dimension)]
                }
            }
        }
    }

    private func resetCache() {
        activeLength = 0
        for array in selfKeys + selfValues + encoderKeys + encoderValues {
            for index in 0..<array.count { array[index] = 0 }
        }
    }

    private func argmax(_ logits: MLMultiArray) -> Int32 {
        var bestIndex = 0
        var bestValue = -Double.infinity
        for index in 0..<Self.vocabularySize {
            let value = logits[index].doubleValue
            if value > bestValue { bestValue = value; bestIndex = index }
        }
        return Int32(bestIndex)
    }

    private func offset(head: Int, token: Int, dimension: Int) -> Int {
        head * Self.cacheLength * Self.headDimension + token * Self.headDimension + dimension
    }

    private func validateEncoder(_ value: MLMultiArray) throws {
        let shape = value.shape.map(\.intValue)
        guard shape == [1, Self.encoderTokenCount, Self.encoderHiddenSize] else { throw TexTellerExecutionError.invalidEncoderShape(shape) }
        guard value.dataType == .float16 || value.dataType == .float32 else { throw TexTellerExecutionError.invalidEncoderType }
    }

    private static func validateInterface(_ description: MLModelDescription, requiresEncoderCache: Bool) throws {
        let inputs = description.inputDescriptionsByName
        let outputs = description.outputDescriptionsByName
        let required = ["input_ids", "encoder_hidden_states", "attention_mask", "position_ids"]
        for name in required where inputs[name] == nil { throw TexTellerExecutionError.invalidModelInterface("入力 \(name) がありません") }
        for layer in 0..<Self.layerCount {
            for part in ["decoder_key", "decoder_value", "encoder_key", "encoder_value"] {
                let input = "past_key_values_\(layer)_\(part)"
                let output = "present_\(layer)_\(part)"
                let required = part.hasPrefix("encoder_") ? requiresEncoderCache : true
                if outputs[output] == nil || (required && inputs[input] == nil) {
                    throw TexTellerExecutionError.invalidModelInterface("KV \(layer) の \(part) がありません")
                }
            }
        }
        guard outputs["logits"] != nil else { throw TexTellerExecutionError.invalidModelInterface("logitsがありません") }
    }

    private static func validateEncoderInterface(_ description: MLModelDescription) throws {
        guard let input = description.inputDescriptionsByName["pixel_values"],
              let output = description.outputDescriptionsByName["last_hidden_state"] else {
            throw TexTellerExecutionError.invalidModelInterface("Encoderの入出力名が不正です")
        }
        guard input.multiArrayConstraint?.shape.map(\.intValue) == [1, 1, 448, 448],
              output.multiArrayConstraint?.shape.map(\.intValue) == [1, 785, 768] else {
            throw TexTellerExecutionError.invalidModelInterface("Encoderのshapeが不正です")
        }
    }

    private static func makeArray(_ shape: [Int], type: MLMultiArrayDataType) throws -> MLMultiArray {
        try MLMultiArray(shape: shape.map(NSNumber.init(value:)), dataType: type)
    }

    private static func copyArray(_ source: MLMultiArray) throws -> MLMultiArray {
        let copy = try makeArray(source.shape.map(\.intValue), type: source.dataType)
        for index in 0..<source.count { copy[index] = source[index] }
        return copy
    }
}
