import CoreML
import CryptoKit
import Foundation

public struct HinotoriStrokeSetClassification: Sendable, Equatable {
    public let originalStrokeIndices: [Int]
    public let sourceCoordinateSpace: HinotoriStrokeSetInput.SourceCoordinateSpace
    public let candidates: [HinotoriCandidate]
    /// Cosine distance for every vocabulary class, in vocabulary index order.
    public let classFeatureDistances: [Float]
    public let queryEmbedding: [Float]
}

/// Runs the bundled fold-07 isolated-symbol model. The caller supplies one
/// explicitly segmented symbol; this class does not group formula strokes.
public final class HinotoriStrokeSetCoreMLClassifier {
    public static let classCount = 229
    public static let embeddingDimension = 128

    private let model: MLModel
    private let vocabulary: [String]
    private let classPrototypes: [[Float]]

    public init(bundle: Bundle = .main) throws {
        guard let modelURL = bundle.url(forResource: "HinotoriStrokeSetClassifier", withExtension: "mlmodelc") else {
            throw ClassifierError.missingBundleResource("HinotoriStrokeSetClassifier.mlmodelc")
        }
        guard let modelManifestURL = bundle.url(forResource: "HinotoriRasterCoreML.manifest", withExtension: "json"),
              let prototypeManifestURL = bundle.url(forResource: "HinotoriClassPrototypes.manifest", withExtension: "json"),
              let prototypeDataURL = bundle.url(forResource: "HinotoriClassPrototypes", withExtension: "f32le"),
              let vocabularyURL = bundle.url(forResource: "HinotoriVocabulary", withExtension: "json") else {
            throw ClassifierError.missingBundleResource("Hinotori model manifest, prototype bank, or vocabulary")
        }

        let modelManifest = try Self.decode(ModelManifest.self, from: modelManifestURL)
        let prototypeManifest = try Self.decode(PrototypeManifest.self, from: prototypeManifestURL)
        let vocabularyDocument = try Self.decode(VocabularyDocument.self, from: vocabularyURL)
        let vocabularySHA256 = try Self.sha256(of: vocabularyURL)
        guard modelManifest.format == "hinotori-raster-symbol-coreml-v2",
              modelManifest.task == "isolated_symbol_exact_classification",
              modelManifest.classCount == Self.classCount,
              modelManifest.modelPackage == "HinotoriStrokeSetClassifier.mlpackage",
              modelManifest.checkpointSHA256 == prototypeManifest.checkpointSHA256,
              modelManifest.output.classLogits.vocabularyFileSHA256 == vocabularySHA256,
              modelManifest.output.classLogits.checkpointVocabularySHA256 == vocabularySHA256,
              modelManifest.output.classLogits.serializedVocabularySHA256 == vocabularySHA256,
              modelManifest.output.classLogits.shape == [1, Self.classCount],
              modelManifest.output.queryEmbedding.shape == [1, Self.embeddingDimension] else {
            throw ClassifierError.invalidArtifact("Core ML manifest task, vocabulary size, checkpoint, or output shapes disagree")
        }
        guard prototypeManifest.format == "hinotori-fit-class-embedding-prototypes-v1",
              prototypeManifest.task == "isolated_symbol_exact_class_similarity",
              prototypeManifest.dtype == "float32-little-endian",
              prototypeManifest.shape == [Self.classCount, Self.embeddingDimension],
              prototypeManifest.classCount == Self.classCount,
              prototypeManifest.embeddingDimension == Self.embeddingDimension,
              prototypeManifest.outerTestRead == false,
              prototypeManifest.validationUsedToConstructPrototypes == false,
              vocabularyDocument.version == "hinotori-v1",
              vocabularyDocument.labels.count == Self.classCount,
              prototypeManifest.classLabelsByIndex == vocabularyDocument.labels else {
            throw ClassifierError.invalidArtifact("Fit-only prototype provenance, shape, or vocabulary does not match the model")
        }
        guard try Self.sha256(of: prototypeDataURL) == prototypeManifest.prototypeSHA256 else {
            throw ClassifierError.invalidArtifact("Fit-only prototype asset SHA-256 does not match its manifest")
        }
        let prototypes = try Self.decodePrototypes(Data(contentsOf: prototypeDataURL, options: .mappedIfSafe))

        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            model = try MLModel(contentsOf: modelURL, configuration: configuration)
        } catch {
            throw ClassifierError.modelLoadFailed(error.localizedDescription)
        }
        try Self.validateModelInterface(model)
        vocabulary = vocabularyDocument.labels
        classPrototypes = prototypes
    }

    public func classify(
        strokes: [HinotoriStroke],
        originalStrokeIndices: [Int],
        sourceCoordinateSpace: HinotoriStrokeSetInput.SourceCoordinateSpace,
        topK: Int = 5
    ) throws -> HinotoriStrokeSetClassification {
        guard !strokes.isEmpty else { throw ClassifierError.emptySymbol }
        guard strokes.count == originalStrokeIndices.count,
              originalStrokeIndices.allSatisfy({ $0 >= 0 }),
              Set(originalStrokeIndices).count == originalStrokeIndices.count else {
            throw ClassifierError.invalidStrokeIdentity
        }
        guard (1...Self.classCount).contains(topK) else {
            throw ClassifierError.invalidTopK(topK)
        }

        let input = try HinotoriStrokeSetInput.build(
            sourceCoordinateSpace: sourceCoordinateSpace,
            callerDesignatedSymbolStrokeGroup: strokes.map(\.points)
        )
        let provider: MLDictionaryFeatureProvider
        do {
            provider = try MLDictionaryFeatureProvider(dictionary: [
                "inkRaster": MLFeatureValue(multiArray: try Self.float16Input(input.inkRaster)),
                "strokePoints": MLFeatureValue(multiArray: try Self.float16Input(input.strokePoints)),
                "reversedStrokePoints": MLFeatureValue(multiArray: try Self.float16Input(input.reversedStrokePoints)),
                "strokeValid": MLFeatureValue(multiArray: try Self.float16Input(input.strokeValid)),
            ])
        } catch {
            throw ClassifierError.inputProviderFailed(error.localizedDescription)
        }

        let output: MLFeatureProvider
        do {
            output = try model.prediction(from: provider)
        } catch {
            throw ClassifierError.predictionFailed(error.localizedDescription)
        }
        guard let logits = output.featureValue(for: "classLogits")?.multiArrayValue,
              let embeddingArray = output.featureValue(for: "queryEmbedding")?.multiArrayValue else {
            throw ClassifierError.invalidModelOutput("classLogits または queryEmbedding がありません")
        }
        let values = try Self.readVector(logits, expectedShape: [1, Self.classCount], name: "classLogits")
        let embedding = try Self.readVector(embeddingArray, expectedShape: [1, Self.embeddingDimension], name: "queryEmbedding")
        let norm = sqrt(embedding.reduce(Float.zero) { $0 + $1 * $1 })
        guard norm.isFinite, abs(norm - 1) <= 0.02 else {
            throw ClassifierError.invalidModelOutput("queryEmbeddingのL2ノルムが学習契約の単位長から外れています")
        }

        let distances = try classPrototypes.map { prototype -> Float in
            let cosine = zip(embedding, prototype).reduce(Float.zero) { $0 + $1.0 * $1.1 }
            guard cosine.isFinite, (-1.0001...1.0001).contains(cosine) else {
                throw ClassifierError.invalidModelOutput("queryEmbeddingとfit prototypeのcosine値が範囲外です")
            }
            // Clamp only float-rounding excursions at the mathematical cosine bounds.
            return 1 - min(1, max(-1, cosine))
        }
        guard distances.count == Self.classCount, distances.allSatisfy({ $0.isFinite && (0...2).contains($0) }) else {
            throw ClassifierError.invalidModelOutput("229クラスの類似距離が有限な[0,2]値ではありません")
        }
        let candidates = values.indices
            .sorted { values[$0] == values[$1] ? $0 < $1 : values[$0] > values[$1] }
            .prefix(topK)
            .map { HinotoriCandidate(classIndex: $0, label: vocabulary[$0], logit: values[$0]) }

        return HinotoriStrokeSetClassification(
            originalStrokeIndices: originalStrokeIndices,
            sourceCoordinateSpace: input.sourceCoordinateSpace,
            candidates: candidates,
            classFeatureDistances: distances,
            queryEmbedding: embedding
        )
    }

    public enum ClassifierError: LocalizedError {
        case missingBundleResource(String)
        case invalidArtifact(String)
        case modelLoadFailed(String)
        case emptySymbol
        case invalidStrokeIdentity
        case invalidTopK(Int)
        case inputProviderFailed(String)
        case predictionFailed(String)
        case invalidModelOutput(String)

        public var errorDescription: String? {
            switch self {
            case .missingBundleResource(let name): return "Bundle内にHinotori資産がありません: \(name)"
            case .invalidArtifact(let reason): return "Hinotori資産の検証に失敗しました: \(reason)"
            case .modelLoadFailed(let reason): return "Hinotori Core MLモデルを読み込めません: \(reason)"
            case .emptySymbol: return "分類する記号ストロークがありません"
            case .invalidStrokeIdentity: return "元ストロークIDとストローク群の対応が不正です"
            case .invalidTopK(let value): return "候補数\(value)は1...229の範囲ではありません"
            case .inputProviderFailed(let reason): return "Hinotori Core ML入力を構成できません: \(reason)"
            case .predictionFailed(let reason): return "Hinotori Core ML推論に失敗しました: \(reason)"
            case .invalidModelOutput(let reason): return "Hinotori Core ML出力が契約と一致しません: \(reason)"
            }
        }
    }

    private struct ModelManifest: Decodable {
        struct Output: Decodable {
            struct Tensor: Decodable {
                let shape: [Int]
                let vocabularyFileSHA256: String?
                let checkpointVocabularySHA256: String?
                let serializedVocabularySHA256: String?
            }
            let classLogits: Tensor
            let queryEmbedding: Tensor
        }
        let format: String
        let task: String
        let classCount: Int
        let modelPackage: String
        let checkpointSHA256: String
        let output: Output
    }

    private struct PrototypeManifest: Decodable {
        let format: String
        let task: String
        let checkpointSHA256: String
        let prototypeSHA256: String
        let dtype: String
        let shape: [Int]
        let embeddingDimension: Int
        let classCount: Int
        let classLabelsByIndex: [String]
        let validationUsedToConstructPrototypes: Bool
        let outerTestRead: Bool
    }

    private struct VocabularyDocument: Decodable {
        let version: String
        let labels: [String]
    }

    private static func validateModelInterface(_ model: MLModel) throws {
        let expectedInputs: [String: [Int]] = [
            "inkRaster": [1, 1, 64, 64],
            "strokePoints": [1, 11, 128, 2],
            "reversedStrokePoints": [1, 11, 128, 2],
            "strokeValid": [1, 11],
        ]
        let expectedOutputs: [String: [Int]] = [
            "classLogits": [1, Self.classCount],
            "queryEmbedding": [1, Self.embeddingDimension],
        ]
        try validateFeatures(expectedInputs, against: model.modelDescription.inputDescriptionsByName, role: "input")
        try validateFeatures(expectedOutputs, against: model.modelDescription.outputDescriptionsByName, role: "output")
    }

    private static func validateFeatures(
        _ expected: [String: [Int]],
        against features: [String: MLFeatureDescription],
        role: String
    ) throws {
        for (name, shape) in expected {
            guard let feature = features[name], feature.type == .multiArray,
                  let constraint = feature.multiArrayConstraint,
                  constraint.shape.map(\.intValue) == shape,
                  constraint.dataType == .float16 else {
                throw ClassifierError.invalidArtifact("Core ML \(role) \(name) must be float16 multiArray with shape \(shape)")
            }
        }
    }

    private static func readVector(_ array: MLMultiArray, expectedShape: [Int], name: String) throws -> [Float] {
        guard array.dataType == .float16, array.shape.map(\.intValue) == expectedShape else {
            throw ClassifierError.invalidModelOutput("\(name) must be float16[\(expectedShape.map(String.init).joined(separator: ","))]")
        }
        let count = expectedShape.reduce(1, *)
        let strides = array.strides.map(\.intValue)
        let pointer = array.dataPointer.bindMemory(to: UInt16.self, capacity: array.count)
        let values = (0..<count).map { flatIndex -> Float in
            var remainder = flatIndex
            var offset = 0
            for axis in expectedShape.indices.reversed() {
                let coordinate = remainder % expectedShape[axis]
                remainder /= expectedShape[axis]
                offset += coordinate * strides[axis]
            }
            return Float(Float16(bitPattern: pointer[offset]))
        }
        guard values.allSatisfy(\.isFinite) else {
            throw ClassifierError.invalidModelOutput("\(name)に有限でない要素があります")
        }
        return values
    }

    private static func float16Input(_ source: MLMultiArray) throws -> MLMultiArray {
        guard source.dataType == .float32 else {
            throw ClassifierError.invalidArtifact("input builder tensor must be float32 before Core ML conversion")
        }
        let shape = source.shape.map(\.intValue)
        let destination: MLMultiArray
        do {
            destination = try MLMultiArray(shape: source.shape, dataType: .float16)
        } catch {
            throw ClassifierError.inputProviderFailed("float16 tensorを確保できません: \(error.localizedDescription)")
        }
        let elementCount = source.count
        let sourcePointer = source.dataPointer.bindMemory(to: Float32.self, capacity: elementCount)
        let destinationPointer = destination.dataPointer.bindMemory(to: UInt16.self, capacity: elementCount)
        let sourceStrides = source.strides.map(\.intValue)
        let destinationStrides = destination.strides.map(\.intValue)
        for flatIndex in 0..<elementCount {
            var remainder = flatIndex
            var sourceOffset = 0
            var destinationOffset = 0
            for axis in shape.indices.reversed() {
                let coordinate = remainder % shape[axis]
                remainder /= shape[axis]
                sourceOffset += coordinate * sourceStrides[axis]
                destinationOffset += coordinate * destinationStrides[axis]
            }
            let value = sourcePointer[sourceOffset]
            let half = Float16(value)
            guard value.isFinite, half.isFinite else {
                throw ClassifierError.invalidArtifact("input tensorにfloat16で表現できない値があります")
            }
            destinationPointer[destinationOffset] = half.bitPattern
        }
        return destination
    }

    private static func decodePrototypes(_ data: Data) throws -> [[Float]] {
        let expectedBytes = Self.classCount * Self.embeddingDimension * MemoryLayout<UInt32>.size
        guard data.count == expectedBytes else {
            throw ClassifierError.invalidArtifact("prototype byte数が\(expectedBytes)ではありません")
        }
        var prototypes: [[Float]] = []
        prototypes.reserveCapacity(Self.classCount)
        for classIndex in 0..<Self.classCount {
            let start = classIndex * Self.embeddingDimension
            let vector = (0..<Self.embeddingDimension).map { dimension -> Float in
                let byteOffset = (start + dimension) * 4
                let bits = UInt32(data[byteOffset])
                    | UInt32(data[byteOffset + 1]) << 8
                    | UInt32(data[byteOffset + 2]) << 16
                    | UInt32(data[byteOffset + 3]) << 24
                return Float(bitPattern: bits)
            }
            let norm = sqrt(vector.reduce(Float.zero) { $0 + $1 * $1 })
            guard vector.allSatisfy(\.isFinite), norm.isFinite, abs(norm - 1) <= 0.001 else {
                throw ClassifierError.invalidArtifact("class prototype \(classIndex)が有限な単位ベクトルではありません")
            }
            prototypes.append(vector)
        }
        return prototypes
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: url, options: .mappedIfSafe))
        } catch {
            throw ClassifierError.invalidArtifact("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func sha256(of url: URL) throws -> String {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } catch {
            throw ClassifierError.invalidArtifact("\(url.lastPathComponent)を読めません: \(error.localizedDescription)")
        }
    }
}
