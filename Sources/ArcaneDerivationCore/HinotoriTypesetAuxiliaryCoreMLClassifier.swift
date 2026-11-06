import CoreML
import CryptoKit
import Foundation

public struct HinotoriTypesetCandidate: Codable, Equatable, Sendable {
    public let classIndex: Int
    public let label: String
    public let rank: Int
    public let score: Float
    public let headCheckpointSHA256: String
}

/// Independent typeset-glyph candidate lane over the same normalized ink raster.
/// Its scores never modify the handwritten Fold-07 ranking.
public final class HinotoriTypesetAuxiliaryCoreMLClassifier {
    public static let headCheckpointSHA256 = "ddd749e1a41fc7571f8c6d9f6d312c56bf4bad81210c065c8f263f032c174dd2"
    public static let baseCheckpointSHA256 = "4857351fa5b233439a69d5cd9da363789a0e9a12cef2a68b5a4e75b543a8cb57"
    private static let classCount = 222

    private let model: MLModel
    private let labels: [(classIndex: Int, label: String)]

    public init(bundle: Bundle = .main) throws {
        guard let modelURL = bundle.url(forResource: "HinotoriTypesetAuxiliaryHead", withExtension: "mlmodelc"),
              let manifestURL = bundle.url(forResource: "HinotoriTypesetAuxiliaryHead.manifest", withExtension: "json"),
              let vocabularyURL = bundle.url(forResource: "HinotoriTypesetVocabulary", withExtension: "json") else {
            throw ClassifierError.missingArtifact
        }
        let manifest = try Self.decode(Manifest.self, from: manifestURL)
        let vocabulary = try Self.decode(Vocabulary.self, from: vocabularyURL)
        let baseVocabularyURL = bundle.url(forResource: "HinotoriFold7Vocabulary", withExtension: "json")
        guard let baseVocabularyURL else { throw ClassifierError.missingArtifact }
        let baseVocabulary = try Self.decode(BaseVocabulary.self, from: baseVocabularyURL)
        guard manifest.schema == "hinotori-typeset-auxiliary-coreml-v1",
              manifest.modelName == "HinotoriTypesetAuxiliaryHead",
              manifest.task == "supplemental candidate ranking for verified standalone typeset glyph classes",
              !manifest.primaryClassifierChanged,
              manifest.headCheckpointSHA256 == Self.headCheckpointSHA256,
              manifest.baseCheckpointSHA256 == Self.baseCheckpointSHA256,
              manifest.frozenRasterEncoder.checkpointSHA256 == Self.baseCheckpointSHA256,
              manifest.frozenRasterEncoder.selectedEpoch == 40,
              manifest.input.name == "inkRaster", manifest.input.dtype == "float16",
              manifest.input.shape == [1, 1, 64, 64],
              manifest.output.name == "typesetLogits", manifest.output.dtype == "float16",
              manifest.output.shape == [1, Self.classCount],
              manifest.output.ranking == "descending auxiliary-head logits; scores are not merged with Fold-07 or ViT scores",
              manifest.vocabulary.file == "HinotoriTypesetVocabulary.json",
              manifest.vocabulary.sha256 == (try Self.sha256(vocabularyURL)),
              manifest.vocabulary.supportedLabels == Self.classCount,
              manifest.vocabulary.baseLabels == baseVocabulary.labels.count,
              vocabulary.schema == "hinotori-typeset-supported-vocabulary-v1",
              vocabulary.baseVocabularySHA256 == (try Self.sha256(baseVocabularyURL)),
              baseVocabulary.version == "symbol229-v1",
              baseVocabulary.labels.count == 229,
              Set(baseVocabulary.labels).count == baseVocabulary.labels.count,
              vocabulary.labels.count == Self.classCount,
              Set(vocabulary.labels).count == Self.classCount,
              vocabulary.labels.allSatisfy(baseVocabulary.labels.contains),
              Self.isSHA256(manifest.coreMLModelSHA256),
              Self.isSHA256(manifest.coreMLWeightsSHA256),
              try Self.sha256(modelURL.appendingPathComponent("weights/weight.bin")) == manifest.coreMLWeightsSHA256 else {
            throw ClassifierError.invalidArtifact("manifest、チェックポイント、入力仕様、語彙またはハッシュが一致しません")
        }
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            model = try MLModel(contentsOf: modelURL, configuration: configuration)
        } catch {
            throw ClassifierError.modelLoadFailed(error.localizedDescription)
        }
        try Self.validateInterface(model)
        let classIndexByLabel = Dictionary(uniqueKeysWithValues: baseVocabulary.labels.enumerated().map { ($0.element, $0.offset) })
        labels = try vocabulary.labels.map { label in
            guard let classIndex = classIndexByLabel[label] else {
                throw ClassifierError.invalidArtifact("活字語彙の記号が229記号語彙にありません: \(label)")
            }
            return (classIndex, label)
        }
    }

    public func classify(
        callerDesignatedSymbolStrokeGroup strokes: [[CGPoint]],
        sourceCoordinateSpace: HinotoriStrokeSetInput.SourceCoordinateSpace,
        topK: Int = 5
    ) throws -> [HinotoriTypesetCandidate] {
        guard !strokes.isEmpty else { throw ClassifierError.emptySymbol }
        guard (1...Self.classCount).contains(topK) else { throw ClassifierError.invalidTopK(topK) }
        let raster = try HinotoriStrokeSetInput.buildRasterOnly(
            sourceCoordinateSpace: sourceCoordinateSpace,
            callerDesignatedSymbolStrokeGroup: strokes
        ).inkRaster
        let input = try Self.float16Raster(raster)
        let output: MLFeatureProvider
        do {
            output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "inkRaster": MLFeatureValue(multiArray: input)
            ]))
        } catch {
            throw ClassifierError.predictionFailed(error.localizedDescription)
        }
        guard let logits = output.featureValue(for: "typesetLogits")?.multiArrayValue,
              logits.dataType == .float16,
              logits.shape.map(\.intValue) == [1, Self.classCount] else {
            throw ClassifierError.invalidOutput("typesetLogitsはfloat16 [1,222]である必要があります")
        }
        let values = (0..<Self.classCount).map { logits[[0, $0] as [NSNumber]].floatValue }
        guard values.allSatisfy(\.isFinite) else { throw ClassifierError.invalidOutput("typesetLogitsに有限でない値があります") }
        return values.indices.sorted {
            values[$0] == values[$1] ? labels[$0].classIndex < labels[$1].classIndex : values[$0] > values[$1]
        }.prefix(topK).enumerated().map { rank, outputIndex in
            HinotoriTypesetCandidate(
                classIndex: labels[outputIndex].classIndex,
                label: labels[outputIndex].label,
                rank: rank + 1,
                score: values[outputIndex],
                headCheckpointSHA256: Self.headCheckpointSHA256
            )
        }
    }

    public enum ClassifierError: LocalizedError {
        case missingArtifact
        case invalidArtifact(String)
        case modelLoadFailed(String)
        case emptySymbol
        case invalidTopK(Int)
        case predictionFailed(String)
        case invalidOutput(String)

        public var errorDescription: String? {
            switch self {
            case .missingArtifact: return "火の鳥活字候補モデル、manifest、語彙のいずれかがアプリ内にありません"
            case .invalidArtifact(let reason): return "火の鳥活字候補資産の検証に失敗しました: \(reason)"
            case .modelLoadFailed(let reason): return "火の鳥活字候補Core MLモデルを読み込めません: \(reason)"
            case .emptySymbol: return "活字候補を求める記号ストロークがありません"
            case .invalidTopK(let value): return "活字候補数\(value)は1...222の範囲外です"
            case .predictionFailed(let reason): return "火の鳥活字候補推論に失敗しました: \(reason)"
            case .invalidOutput(let reason): return "火の鳥活字候補出力が契約と一致しません: \(reason)"
            }
        }
    }

    private struct Manifest: Decodable {
        struct Encoder: Decodable { let checkpointSHA256: String; let selectedEpoch: Int }
        struct Tensor: Decodable { let name: String; let dtype: String; let shape: [Int]; let ranking: String? }
        struct VocabularyInfo: Decodable { let file: String; let sha256: String; let supportedLabels: Int; let baseLabels: Int }
        let schema: String
        let modelName: String
        let task: String
        let primaryClassifierChanged: Bool
        let headCheckpointSHA256: String
        let baseCheckpointSHA256: String
        let frozenRasterEncoder: Encoder
        let input: Tensor
        let output: Tensor
        let vocabulary: VocabularyInfo
        let coreMLModelSHA256: String
        let coreMLWeightsSHA256: String
    }

    private struct Vocabulary: Decodable { let schema: String; let baseVocabularySHA256: String; let labels: [String] }
    private struct BaseVocabulary: Decodable { let version: String; let labels: [String] }

    private static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        do { return try JSONDecoder().decode(type, from: Data(contentsOf: url, options: .mappedIfSafe)) }
        catch { throw ClassifierError.invalidArtifact("\(url.lastPathComponent): \(error.localizedDescription)") }
    }

    private static func sha256(_ url: URL) throws -> String {
        do { return SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined() }
        catch { throw ClassifierError.invalidArtifact("\(url.lastPathComponent): \(error.localizedDescription)") }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func validateInterface(_ model: MLModel) throws {
        let input = model.modelDescription.inputDescriptionsByName["inkRaster"]
        let output = model.modelDescription.outputDescriptionsByName["typesetLogits"]
        guard model.modelDescription.inputDescriptionsByName.count == 1,
              model.modelDescription.outputDescriptionsByName.count == 1,
              input?.type == .multiArray, input?.multiArrayConstraint?.shape.map(\.intValue) == [1, 1, 64, 64],
              input?.multiArrayConstraint?.dataType == .float16,
              output?.type == .multiArray, output?.multiArrayConstraint?.shape.map(\.intValue) == [1, Self.classCount],
              output?.multiArrayConstraint?.dataType == .float16 else {
            throw ClassifierError.invalidArtifact("Core ML入出力名、shapeまたはfloat16型がmanifestと一致しません")
        }
    }

    private static func float16Raster(_ source: MLMultiArray) throws -> MLMultiArray {
        guard source.dataType == .float32, source.shape.map(\.intValue) == [1, 1, 64, 64] else {
            throw ClassifierError.invalidArtifact("Raster builder出力がfloat32 [1,1,64,64]ではありません")
        }
        let destination: MLMultiArray
        do { destination = try MLMultiArray(shape: source.shape, dataType: .float16) }
        catch { throw ClassifierError.invalidArtifact("float16 raster確保に失敗しました: \(error.localizedDescription)") }
        let sourceValues = source.dataPointer.bindMemory(to: Float32.self, capacity: source.count)
        let destinationValues = destination.dataPointer.bindMemory(to: UInt16.self, capacity: destination.count)
        for index in 0..<source.count {
            let value = sourceValues[index]
            let half = Float16(value)
            guard value.isFinite, half.isFinite else { throw ClassifierError.invalidArtifact("rasterにfloat16で表現できない値があります") }
            destinationValues[index] = half.bitPattern
        }
        return destination
    }
}
