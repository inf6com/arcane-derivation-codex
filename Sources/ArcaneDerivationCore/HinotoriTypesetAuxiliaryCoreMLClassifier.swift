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

/// Typeset-glyph classification branch over the same normalized ink raster.
/// It returns raw logits; the product-level Hinotori ensemble calibrates and
/// combines these scores with the handwritten classifier output.
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
        let baseVocabularyURL = bundle.url(forResource: "HinotoriVocabulary", withExtension: "json")
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
              manifest.output.ranking == "descending raw typeset logits; calibrated and probability-fused with the handwritten classifier by HinotoriSymbolCandidateEnsemble",
              manifest.vocabulary.file == "HinotoriTypesetVocabulary.json",
              manifest.vocabulary.sha256 == (try Self.sha256(vocabularyURL)),
              manifest.vocabulary.supportedLabels == Self.classCount,
              manifest.vocabulary.baseLabels == baseVocabulary.labels.count,
              vocabulary.schema == "hinotori-typeset-supported-vocabulary-v1",
              vocabulary.baseVocabularySHA256 == (try Self.sha256(baseVocabularyURL)),
              baseVocabulary.version == "hinotori-v1",
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

/// The product-level candidate model. It calibrates the unchanged Fold7
/// handwritten logits and the typeset-glyph logits on the shared 229-label
/// vocabulary, then returns one ranked candidate list for downstream
/// visual-similarity and position stages.
public struct HinotoriSymbolCandidateEnsemble {
    public static let modelName = "火の鳥・孤立記号アンサンブル"
    public let calibrationSHA256: String
    private let fold7Temperature: Double
    private let typesetTemperature: Double
    private let fold7Weight: Double
    private let typesetWeight: Double
    private let fold7LogitScale: Double
    private let supportedIndices: Set<Int>

    public init(bundle: Bundle = .main) throws {
        guard let calibrationURL = bundle.url(forResource: "HinotoriCandidateEnsemble", withExtension: "json"),
              let fold7VocabularyURL = bundle.url(forResource: "HinotoriFold7Vocabulary", withExtension: "json"),
              let typesetVocabularyURL = bundle.url(forResource: "HinotoriTypesetVocabulary", withExtension: "json"),
              let fold7ManifestURL = bundle.url(forResource: "HinotoriFold7CoreML.manifest", withExtension: "json") else {
            throw EnsembleError.missingCalibration
        }
        let calibration: Calibration
        let fold7Manifest: Fold7Manifest
        let typesetVocabulary: TypesetVocabulary
        do {
            calibration = try JSONDecoder().decode(Calibration.self, from: Data(contentsOf: calibrationURL, options: .mappedIfSafe))
            fold7Manifest = try JSONDecoder().decode(Fold7Manifest.self, from: Data(contentsOf: fold7ManifestURL, options: .mappedIfSafe))
            typesetVocabulary = try JSONDecoder().decode(TypesetVocabulary.self, from: Data(contentsOf: typesetVocabularyURL, options: .mappedIfSafe))
        } catch {
            throw EnsembleError.invalidCalibration(error.localizedDescription)
        }
        let vocabularySHA256 = Self.sha256(fold7VocabularyURL)
        guard let calibrationSHA256 = Self.sha256(calibrationURL) else {
            throw EnsembleError.invalidCalibration("校正ファイルのSHA-256を計算できません")
        }
        let supported = calibration.fusion.typesetSupportedClassIndices
        guard calibration.schema == "hinotori-isolated-symbol-ensemble-calibration-v1",
              calibration.modelName == Self.modelName,
              calibration.task == "229-class isolated handwritten-symbol candidate ranking",
              calibration.fusion.fold7CheckpointSHA256 == HinotoriFold7CoreMLClassifier.checkpointSHA256,
              calibration.fusion.typesetBaseCheckpointSHA256 == HinotoriTypesetAuxiliaryCoreMLClassifier.baseCheckpointSHA256,
              calibration.fusion.typesetHeadCheckpointSHA256 == HinotoriTypesetAuxiliaryCoreMLClassifier.headCheckpointSHA256,
              calibration.fusion.vocabularySHA256 == vocabularySHA256,
              calibration.fusion.fold7LogitScale.isFinite,
              calibration.fusion.fold7LogitScale == fold7Manifest.classifierLogitScale,
              calibration.fusion.fold7Temperature.isFinite, calibration.fusion.fold7Temperature > 0,
              calibration.fusion.typesetTemperature.isFinite, calibration.fusion.typesetTemperature > 0,
              calibration.fusion.fold7Weight.isFinite, calibration.fusion.typesetWeight.isFinite,
              calibration.fusion.fold7Weight >= 0, calibration.fusion.typesetWeight >= 0,
              abs(calibration.fusion.fold7Weight + calibration.fusion.typesetWeight - 1) < 1e-9,
              supported.count == 222, Set(supported).count == supported.count,
              Set(supported) == Set(typesetVocabulary.supportedVocabularyIndices),
              supported.allSatisfy((0..<HinotoriFold7CoreMLClassifier.classCount).contains),
              calibration.developmentValidation.outerTestOpened == false else {
            throw EnsembleError.invalidCalibration("チェックポイント、語彙、校正値または検証条件が一致しません")
        }
        fold7Temperature = calibration.fusion.fold7Temperature
        typesetTemperature = calibration.fusion.typesetTemperature
        fold7Weight = calibration.fusion.fold7Weight
        typesetWeight = calibration.fusion.typesetWeight
        fold7LogitScale = calibration.fusion.fold7LogitScale
        supportedIndices = Set(supported)
        self.calibrationSHA256 = calibrationSHA256
    }

    public func rank(
        fold7Logits: [Float],
        typesetCandidates: [HinotoriTypesetCandidate],
        vocabulary: HinotoriVocabulary,
        topK: Int = 5
    ) throws -> [HinotoriCandidate] {
        guard fold7Logits.count == HinotoriFold7CoreMLClassifier.classCount,
              vocabulary.labels.count == HinotoriFold7CoreMLClassifier.classCount,
              (1...HinotoriFold7CoreMLClassifier.classCount).contains(topK),
              fold7Logits.allSatisfy(\.isFinite),
              typesetCandidates.count == supportedIndices.count,
              Set(typesetCandidates.map(\.classIndex)) == supportedIndices,
              typesetCandidates.allSatisfy({ (0..<vocabulary.labels.count).contains($0.classIndex) }),
              typesetCandidates.allSatisfy({ $0.headCheckpointSHA256 == HinotoriTypesetAuxiliaryCoreMLClassifier.headCheckpointSHA256 && $0.score.isFinite && vocabulary.labels[$0.classIndex] == $0.label }) else {
            throw EnsembleError.invalidScores("Fold7または活字モデルの229語彙対応・全クラス出力が不正です")
        }

        let scaledFold7Logits = fold7Logits.map(Double.init)
        let fold7Probabilities = try Self.softmax(scaledFold7Logits, temperature: fold7Temperature)
        let typesetByIndex = Dictionary(uniqueKeysWithValues: typesetCandidates.map { ($0.classIndex, Double($0.score)) })
        let typesetClassIndices = supportedIndices.sorted()
        let typesetLogits = try typesetClassIndices.map { classIndex -> Double in
            guard let logit = typesetByIndex[classIndex] else {
                throw EnsembleError.invalidScores("活字枝の校正対象クラス (classIndex) のlogitがありません")
            }
            return logit
        }
        let typesetProbabilities = try Self.softmax(typesetLogits, temperature: typesetTemperature)
        var probabilityByIndex = Array(repeating: 0.0, count: vocabulary.labels.count)
        for classIndex in probabilityByIndex.indices {
            probabilityByIndex[classIndex] = fold7Weight * fold7Probabilities[classIndex]
        }
        for (localIndex, classIndex) in typesetClassIndices.enumerated() {
            probabilityByIndex[classIndex] += typesetWeight * typesetProbabilities[localIndex]
        }
        guard probabilityByIndex.allSatisfy({ $0.isFinite && $0 >= 0 }),
              abs(probabilityByIndex.reduce(0, +) - 1) < 1e-6 else {
            throw EnsembleError.invalidScores("融合確率の正規化に失敗しました")
        }
        return probabilityByIndex.indices.sorted {
            probabilityByIndex[$0] == probabilityByIndex[$1] ? $0 < $1 : probabilityByIndex[$0] > probabilityByIndex[$1]
        }.prefix(topK).map { classIndex in
            HinotoriCandidate(
                classIndex: classIndex,
                label: vocabulary.labels[classIndex],
                logit: fold7Logits[classIndex],
                ensembleProbability: Float(probabilityByIndex[classIndex])
            )
        }
    }

    private static func softmax(_ logits: [Double], temperature: Double) throws -> [Double] {
        let scaled = logits.map { $0 / temperature }
        guard let maximum = scaled.max() else {
            throw EnsembleError.invalidScores("softmaxへ空のスコアが渡されました")
        }
        let exponentials = scaled.map { exp($0 - maximum) }
        let total = exponentials.reduce(0, +)
        guard total.isFinite, total > 0 else {
            throw EnsembleError.invalidScores("softmaxの正規化係数が有限の正数ではありません")
        }
        return exponentials.map { $0 / total }
    }

    private static func sha256(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Calibration: Decodable {
        struct Fusion: Decodable {
            let fold7CheckpointSHA256: String
            let typesetBaseCheckpointSHA256: String
            let typesetHeadCheckpointSHA256: String
            let fold7Temperature: Double
            let typesetTemperature: Double
            let fold7Weight: Double
            let typesetWeight: Double
            let vocabularySHA256: String
            let typesetSupportedClassIndices: [Int]
            let fold7LogitScale: Double
        }
        struct DevelopmentValidation: Decodable {
            let outerTestOpened: Bool
        }
        let schema: String
        let modelName: String
        let task: String
        let fusion: Fusion
        let developmentValidation: DevelopmentValidation
    }
    private struct Fold7Manifest: Decodable { let classifierLogitScale: Double }
    private struct TypesetVocabulary: Decodable { let supportedVocabularyIndices: [Int] }

    public enum EnsembleError: LocalizedError {
        case missingCalibration
        case invalidCalibration(String)
        case invalidScores(String)
        public var errorDescription: String? {
            switch self {
            case .missingCalibration: return "火の鳥統合校正資産がアプリ内にありません"
            case .invalidCalibration(let reason): return "火の鳥統合校正資産が不正です: \(reason)"
            case .invalidScores(let reason): return "火の鳥統合スコアを検証できません: \(reason)"
            }
        }
    }
}
