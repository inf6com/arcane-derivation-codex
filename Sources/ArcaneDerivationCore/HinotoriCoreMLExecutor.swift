import CoreGraphics
import CoreML
import CryptoKit
import Foundation

/// Hinotori Core ML v1.  This contract has no raster, Grid9, or legacy glyph
/// recognizer path: strokes are normalized to the same 32-point trajectories
/// used by the retrieval model.
public enum HinotoriCoreMLError: LocalizedError, Equatable {
    case emptyFormula
    case tooManyFormulaStrokes(actual: Int)
    case emptyStroke(index: Int)
    case nonFinitePoint(stroke: Int)
    case tooManyGroupStrokes(actual: Int, maximum: Int)
    case invalidAnchorBank(String)
    case invalidVocabulary(String)
    case invalidModelContract(String)
    case predictionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyFormula: return "記号認識には少なくとも1本のストロークが必要です。"
        case .tooManyFormulaStrokes(let actual): return "ストローク数\(actual)がHinotoriモデル上限80を超えています。"
        case .emptyStroke(let index): return "ストローク\(index + 1)に点がありません。"
        case .nonFinitePoint(let stroke): return "ストローク\(stroke + 1)に有限でない座標があります。"
        case .tooManyGroupStrokes(let actual, let maximum): return "推定記号のストローク数\(actual)がanchor bank上限\(maximum)を超えています。"
        case .invalidAnchorBank(let reason): return "Hinotori anchor bankが不正です: \(reason)"
        case .invalidVocabulary(let reason): return "Hinotori vocabularyが不正です: \(reason)"
        case .invalidModelContract(let reason): return "Hinotori Core ML契約が一致しません: \(reason)"
        case .predictionFailed(let reason): return "Hinotori Core ML推論に失敗しました: \(reason)"
        }
    }
}

public struct HinotoriStroke: Sendable, Equatable {
    public let points: [CGPoint]

    public init(points: [CGPoint]) {
        self.points = points
    }
}

public struct HinotoriCandidate: Sendable, Equatable {
    public let classIndex: Int
    public let label: String
    /// Unmodified Fold7 classifier logit. Similarity and position candidates
    /// have no such logit; ensemble candidates retain the Fold7 value here.
    public let logit: Float
    /// Probability after calibrated Fold7/typeset score fusion; nil for a
    /// candidate that has not passed through the ensemble stage.
    public let ensembleProbability: Float?

    public init(classIndex: Int, label: String, logit: Float, ensembleProbability: Float? = nil) {
        self.classIndex = classIndex
        self.label = label
        self.logit = logit
        self.ensembleProbability = ensembleProbability
    }
}

public struct HinotoriRecognition: Sendable, Equatable {
    public let groups: [[Int]]
    public let candidates: [[HinotoriCandidate]]
    /// Full unmodified 229-way Fold7 logits per symbol, aligned to vocabulary.
    public let classLogits: [[Float]]
    /// Per symbol, cosine distance from its query embedding to each class prototype.
    /// Indexing follows the fixed Hinotori vocabulary (0..<229).
    public let classFeatureDistances: [[Float]]
    /// Fold7-only similarity candidates, indexed by symbol group and then by
    /// the selected exact Top-5 rank. Each candidate retains its group IDs and
    /// cosine similarity for downstream confirmation and saved evidence.
    public let fold7SimilarityCandidates: [[[HinotoriFold7SimilarityCandidate]]]
}

/// Replaceable shape-recognition stage for the handwritten-formula pipeline.
/// Implementations must return source-stroke groups and ranked candidates in
/// the application's active vocabulary; position and formula-structure
/// interpretation remain downstream responsibilities.
public protocol HinotoriSymbolRecognitionEngine {
    func recognize(_ strokes: [HinotoriStroke], topK: Int) throws -> HinotoriRecognition
}

public struct HinotoriAnchorBank {
    public let points: MLMultiArray
    public let strokeValid: MLMultiArray
    public let classIndices: [Int]
    public let anchorCount: Int
    public let maxStrokes: Int

    public init(points: MLMultiArray, strokeValid: MLMultiArray, classIndices: [Int]) throws {
        guard points.dataType == .float32, strokeValid.dataType == .float32 else {
            throw HinotoriCoreMLError.invalidAnchorBank("pointsとstrokeValidはfloat32である必要があります")
        }
        let pointShape = points.shape.map(\.intValue)
        let validShape = strokeValid.shape.map(\.intValue)
        guard pointShape.count == 4, pointShape[2] == HinotoriCoreMLExecutor.pointsPerStroke, pointShape[3] == 2,
              validShape == [pointShape[0], pointShape[1]], pointShape[0] >= HinotoriCoreMLExecutor.classCount, pointShape[1] >= 1 else {
            throw HinotoriCoreMLError.invalidAnchorBank("points=[anchor,stroke,32,2]とstrokeValid=[anchor,stroke]が必要です")
        }
        guard classIndices.count == pointShape[0],
              classIndices.allSatisfy({ (0..<HinotoriCoreMLExecutor.classCount).contains($0) }),
              Set(classIndices) == Set(0..<HinotoriCoreMLExecutor.classCount) else {
            throw HinotoriCoreMLError.invalidAnchorBank("classIndicesは各anchorに対応し、229クラスをすべて含む必要があります")
        }
        self.points = points
        self.strokeValid = strokeValid
        self.classIndices = classIndices
        self.anchorCount = pointShape[0]
        self.maxStrokes = pointShape[1]
    }

    /// Loads the exact converter artifact from an application bundle.  The
    /// manifest and every raw little-endian array are validated before Core ML
    /// receives an anchor tensor.
    public static func load(
        bundle: Bundle,
        manifestResource: String = "HinotoriCoreML.manifest",
        manifestExtension: String? = "json"
    ) throws -> HinotoriAnchorBank {
        guard let manifestURL = bundle.url(forResource: manifestResource, withExtension: manifestExtension) else {
            throw HinotoriCoreMLError.invalidAnchorBank("Bundle内に\(manifestResource).\(manifestExtension ?? "")がありません")
        }
        return try load(manifestURL: manifestURL)
    }

    /// Exposed for artifact verification tests.  Production callers should
    /// normally use `load(bundle:manifestResource:manifestExtension:)`.
    public static func load(manifestURL: URL) throws -> HinotoriAnchorBank {
        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
        } catch {
            throw HinotoriCoreMLError.invalidAnchorBank("manifestを読めません: \(error.localizedDescription)")
        }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        } catch {
            throw HinotoriCoreMLError.invalidAnchorBank("manifest JSONが不正です: \(error.localizedDescription)")
        }
        guard manifest.format == "hinotori-retrieval-coreml-v1" else {
            throw HinotoriCoreMLError.invalidAnchorBank("manifest formatがhinotori-retrieval-coreml-v1ではありません")
        }
        let bank = manifest.anchorBank
        guard bank.classes == HinotoriCoreMLExecutor.classCount,
              bank.pointCount == HinotoriCoreMLExecutor.pointsPerStroke,
              bank.pointDimension == HinotoriCoreMLExecutor.coordinateDimension,
              bank.count >= HinotoriCoreMLExecutor.classCount,
              bank.maxStrokes >= 1 else {
            throw HinotoriCoreMLError.invalidAnchorBank("anchorBankのcount/classes/pointCount/pointDimension/maxStrokesが契約と一致しません")
        }
        guard let pointsSpec = bank.arrays["anchorPoints"],
              let validSpec = bank.arrays["anchorStrokeValid"],
              let classesSpec = bank.arrays["anchorClasses"] else {
            throw HinotoriCoreMLError.invalidAnchorBank("manifest anchorBank.arraysに必要な配列がありません")
        }
        try validate(spec: pointsSpec, dtype: "float32-le", shape: [bank.count, bank.maxStrokes, bank.pointCount, bank.pointDimension], name: "anchorPoints")
        try validate(spec: validSpec, dtype: "float32-le", shape: [bank.count, bank.maxStrokes], name: "anchorStrokeValid")
        try validate(spec: classesSpec, dtype: "int64-le", shape: [bank.count], name: "anchorClasses")

        let root = manifestURL.deletingLastPathComponent().standardizedFileURL
        let pointsData = try loadData(root: root, spec: pointsSpec, elementByteCount: MemoryLayout<UInt32>.size, name: "anchorPoints")
        let validData = try loadData(root: root, spec: validSpec, elementByteCount: MemoryLayout<UInt32>.size, name: "anchorStrokeValid")
        let classesData = try loadData(root: root, spec: classesSpec, elementByteCount: MemoryLayout<UInt64>.size, name: "anchorClasses")
        let classIndices = try decodeClasses(classesData, expectedCount: bank.count)

        let points = try makeArray(shape: pointsSpec.shape)
        let valid = try makeArray(shape: validSpec.shape)
        try copyLittleEndianFloat32(pointsData, into: points, name: "anchorPoints")
        try copyLittleEndianFloat32(validData, into: valid, name: "anchorStrokeValid")
        return try HinotoriAnchorBank(points: points, strokeValid: valid, classIndices: classIndices)
    }

    private struct Manifest: Decodable {
        let format: String
        let anchorBank: AnchorBankManifest
    }

    private struct AnchorBankManifest: Decodable {
        let count: Int
        let maxStrokes: Int
        let pointCount: Int
        let pointDimension: Int
        let classes: Int
        let arrays: [String: ArraySpec]
    }

    private struct ArraySpec: Decodable {
        let path: String
        let sha256: String
        let dtype: String
        let shape: [Int]
    }

    private static func validate(spec: ArraySpec, dtype: String, shape: [Int], name: String) throws {
        guard spec.dtype == dtype, spec.shape == shape else {
            throw HinotoriCoreMLError.invalidAnchorBank("\(name)のdtypeまたはshapeがmanifest契約と一致しません")
        }
        guard spec.shape.allSatisfy({ $0 > 0 }), spec.sha256.count == 64,
              spec.sha256.allSatisfy({ $0.isHexDigit }) else {
            throw HinotoriCoreMLError.invalidAnchorBank("\(name)のshapeまたはSHA-256形式が不正です")
        }
    }

    private static func loadData(root: URL, spec: ArraySpec, elementByteCount: Int, name: String) throws -> Data {
        guard !spec.path.isEmpty, !spec.path.hasPrefix("/"), !spec.path.split(separator: "/").contains("..") else {
            throw HinotoriCoreMLError.invalidAnchorBank("\(name)のpathがBundle外を指しています")
        }
        let fileURL = root.appendingPathComponent(spec.path).standardizedFileURL
        guard fileURL.path.hasPrefix(root.path + "/") else {
            throw HinotoriCoreMLError.invalidAnchorBank("\(name)のpathがBundle外を指しています")
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            throw HinotoriCoreMLError.invalidAnchorBank("\(name)を読めません: \(error.localizedDescription)")
        }
        let elementCount: Int
        do {
            elementCount = try spec.shape.reduce(1) { partial, dimension in
                let (product, overflow) = partial.multipliedReportingOverflow(by: dimension)
                guard !overflow else { throw HinotoriCoreMLError.invalidAnchorBank("\(name)のshapeが大きすぎます") }
                return product
            }
        } catch let error as HinotoriCoreMLError {
            throw error
        }
        let (expectedByteCount, byteCountOverflow) = elementCount.multipliedReportingOverflow(by: elementByteCount)
        guard !byteCountOverflow else {
            throw HinotoriCoreMLError.invalidAnchorBank("\(name)のbyte countが大きすぎます")
        }
        guard data.count == expectedByteCount else {
            throw HinotoriCoreMLError.invalidAnchorBank("\(name)のbyte countがmanifest shapeと一致しません")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == spec.sha256.lowercased() else {
            throw HinotoriCoreMLError.invalidAnchorBank("\(name)のSHA-256がmanifestと一致しません")
        }
        return data
    }

    private static func decodeClasses(_ data: Data, expectedCount: Int) throws -> [Int] {
        guard data.count == expectedCount * MemoryLayout<UInt64>.size else {
            throw HinotoriCoreMLError.invalidAnchorBank("anchorClassesのbyte countが不正です")
        }
        var observed = Set<Int64>()
        var classIndices: [Int] = []
        classIndices.reserveCapacity(expectedCount)
        for offset in stride(from: 0, to: data.count, by: MemoryLayout<UInt64>.size) {
            let raw = data[offset..<(offset + MemoryLayout<UInt64>.size)].enumerated().reduce(UInt64(0)) {
                $0 | (UInt64($1.element) << UInt64($1.offset * 8))
            }
            let value = Int64(bitPattern: raw)
            guard (0..<Int64(HinotoriCoreMLExecutor.classCount)).contains(value) else {
                throw HinotoriCoreMLError.invalidAnchorBank("anchorClassesに0...228外の値があります")
            }
            observed.insert(value)
            classIndices.append(Int(value))
        }
        guard observed.count == HinotoriCoreMLExecutor.classCount else {
            throw HinotoriCoreMLError.invalidAnchorBank("anchorClassesが229クラス全てを被覆していません")
        }
        return classIndices
    }

    private static func makeArray(shape: [Int]) throws -> MLMultiArray {
        try MLMultiArray(shape: shape.map(NSNumber.init(value:)), dataType: .float32)
    }

    private static func copyLittleEndianFloat32(_ data: Data, into array: MLMultiArray, name: String) throws {
        guard data.count == array.count * MemoryLayout<UInt32>.size else {
            throw HinotoriCoreMLError.invalidAnchorBank("\(name)のbyte countがMLMultiArrayと一致しません")
        }
        let output = array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)
        for index in 0..<array.count {
            let offset = index * MemoryLayout<UInt32>.size
            let bits = data[offset..<(offset + MemoryLayout<UInt32>.size)].enumerated().reduce(UInt32(0)) {
                $0 | (UInt32($1.element) << UInt32($1.offset * 8))
            }
            output[index] = Float32(bitPattern: bits)
        }
    }
}

/// Immutable class-index-to-label mapping emitted with the Core ML artifact.
/// It names Hinotori candidates only; it does not synthesize LaTeX or MathML.
public struct HinotoriVocabulary: Sendable, Equatable {
    public let labels: [String]

    public init(labels: [String]) throws {
        guard labels.count == HinotoriCoreMLExecutor.classCount else {
            throw HinotoriCoreMLError.invalidVocabulary("labelsは229件である必要があります")
        }
        guard Set(labels).count == HinotoriCoreMLExecutor.classCount else {
            throw HinotoriCoreMLError.invalidVocabulary("labelsに重複があります")
        }
        self.labels = labels
    }

    public func label(for classIndex: Int) throws -> String {
        guard labels.indices.contains(classIndex) else {
            throw HinotoriCoreMLError.invalidVocabulary("class index \(classIndex)は0...228の範囲外です")
        }
        return labels[classIndex]
    }

    public static func load(
        bundle: Bundle,
        manifestResource: String = "HinotoriCoreML.manifest",
        manifestExtension: String? = "json"
    ) throws -> HinotoriVocabulary {
        guard let manifestURL = bundle.url(forResource: manifestResource, withExtension: manifestExtension) else {
            throw HinotoriCoreMLError.invalidVocabulary("Bundle内に\(manifestResource).\(manifestExtension ?? "")がありません")
        }
        return try load(manifestURL: manifestURL)
    }

    /// Loads the vocabulary paired with the active Fold-07 classifier.
    /// This manifest is deliberately distinct from the retrieval-model
    /// manifest consumed by `load(bundle:)`.
    public static func loadFold7(bundle: Bundle) throws -> HinotoriVocabulary {
        guard let manifestURL = bundle.url(forResource: "HinotoriFold7CoreML.manifest", withExtension: "json"),
              let vocabularyURL = bundle.url(forResource: "HinotoriFold7Vocabulary", withExtension: "json") else {
            throw HinotoriCoreMLError.invalidVocabulary("Bundle内にFold-07 manifestまたは語彙ファイルがありません")
        }
        let manifest: Fold7Manifest
        do {
            manifest = try JSONDecoder().decode(Fold7Manifest.self, from: Data(contentsOf: manifestURL, options: .mappedIfSafe))
        } catch {
            throw HinotoriCoreMLError.invalidVocabulary("Fold-07 manifestを読み込めません: \(error.localizedDescription)")
        }
        guard manifest.schema == "hinotori-fold7-spatial-pyramid-coreml-v1",
              manifest.productModelName == "火の鳥",
              manifest.checkpoint.epoch == HinotoriFold7CoreMLClassifier.selectedEpoch,
              manifest.checkpoint.sha256 == HinotoriFold7CoreMLClassifier.checkpointSHA256,
              manifest.vocabulary.file == "HinotoriFold7Vocabulary.json",
              manifest.vocabulary.labels == HinotoriFold7CoreMLClassifier.classCount,
              manifest.vocabulary.sha256.count == 64,
              manifest.vocabulary.sha256.allSatisfy({ $0.isHexDigit }) else {
            throw HinotoriCoreMLError.invalidVocabulary("Fold-07 manifestのcheckpointまたは語彙契約が一致しません")
        }
        let data: Data
        do {
            data = try Data(contentsOf: vocabularyURL, options: .mappedIfSafe)
        } catch {
            throw HinotoriCoreMLError.invalidVocabulary("Fold-07語彙を読み込めません: \(error.localizedDescription)")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == manifest.vocabulary.sha256.lowercased() else {
            throw HinotoriCoreMLError.invalidVocabulary("Fold-07語彙のSHA-256がmanifestと一致しません")
        }
        let document: Fold7VocabularyDocument
        do {
            document = try JSONDecoder().decode(Fold7VocabularyDocument.self, from: data)
        } catch {
            throw HinotoriCoreMLError.invalidVocabulary("Fold-07語彙JSONが不正です: \(error.localizedDescription)")
        }
        guard document.version == "symbol229-v1" else {
            throw HinotoriCoreMLError.invalidVocabulary("Fold-07語彙の版がsymbol229-v1ではありません")
        }
        return try HinotoriVocabulary(labels: document.labels)
    }

    /// Exposed for artifact verification tests.  Production callers should
    /// normally use `load(bundle:manifestResource:manifestExtension:)`.
    public static func load(manifestURL: URL) throws -> HinotoriVocabulary {
        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
        } catch {
            throw HinotoriCoreMLError.invalidVocabulary("manifestを読めません: \(error.localizedDescription)")
        }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        } catch {
            throw HinotoriCoreMLError.invalidVocabulary("manifest JSONが不正です: \(error.localizedDescription)")
        }
        guard manifest.format == "hinotori-retrieval-coreml-v1", manifest.vocabulary.classes == HinotoriCoreMLExecutor.classCount else {
            throw HinotoriCoreMLError.invalidVocabulary("manifest vocabulary契約がHinotoriと一致しません")
        }
        let spec = manifest.vocabulary
        guard spec.sha256.count == 64, spec.sha256.allSatisfy({ $0.isHexDigit }),
              !spec.path.isEmpty, !spec.path.hasPrefix("/"), !spec.path.split(separator: "/").contains("..") else {
            throw HinotoriCoreMLError.invalidVocabulary("vocabularyのpathまたはSHA-256形式が不正です")
        }
        let root = manifestURL.deletingLastPathComponent().standardizedFileURL
        let vocabularyURL = root.appendingPathComponent(spec.path).standardizedFileURL
        guard vocabularyURL.path.hasPrefix(root.path + "/") else {
            throw HinotoriCoreMLError.invalidVocabulary("vocabularyのpathがBundle外を指しています")
        }
        let vocabularyData: Data
        do {
            vocabularyData = try Data(contentsOf: vocabularyURL, options: .mappedIfSafe)
        } catch {
            throw HinotoriCoreMLError.invalidVocabulary("vocabularyを読めません: \(error.localizedDescription)")
        }
        let digest = SHA256.hash(data: vocabularyData).map { String(format: "%02x", $0) }.joined()
        guard digest == spec.sha256.lowercased() else {
            throw HinotoriCoreMLError.invalidVocabulary("vocabularyのSHA-256がmanifestと一致しません")
        }
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: vocabularyData)
        } catch {
            throw HinotoriCoreMLError.invalidVocabulary("vocabulary JSONが不正です: \(error.localizedDescription)")
        }
        return try HinotoriVocabulary(labels: document.labels)
    }

    private struct Manifest: Decodable {
        let format: String
        let vocabulary: Specification
    }

    private struct Specification: Decodable {
        let path: String
        let sha256: String
        let classes: Int
    }

    private struct Document: Decodable {
        let labels: [String]
    }

    private struct Fold7Manifest: Decodable {
        struct Checkpoint: Decodable {
            let epoch: Int
            let sha256: String
        }
        struct Vocabulary: Decodable {
            let file: String
            let sha256: String
            let labels: Int
        }
        let schema: String
        let productModelName: String
        let checkpoint: Checkpoint
        let vocabulary: Vocabulary
    }

    private struct Fold7VocabularyDocument: Decodable {
        let version: String
        let labels: [String]
    }
}

public final class HinotoriCoreMLExecutor: HinotoriSymbolRecognitionEngine {
    public static let maxFormulaStrokes = 80
    public static let pointsPerStroke = 32
    public static let coordinateDimension = 2
    public static let classCount = 229

    private let affinityModel: MLModel
    private let retrievalModel: MLModel
    private let anchorBank: HinotoriAnchorBank
    private let vocabulary: HinotoriVocabulary
    private let prototypeLock = NSLock()
    private var classPrototypes: [[Float]]?

    public init(affinityModelURL: URL, retrievalModelURL: URL, anchorBank: HinotoriAnchorBank, vocabulary: HinotoriVocabulary) throws {
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            affinityModel = try MLModel(contentsOf: affinityModelURL, configuration: configuration)
            retrievalModel = try MLModel(contentsOf: retrievalModelURL, configuration: configuration)
        } catch {
            throw HinotoriCoreMLError.predictionFailed(error.localizedDescription)
        }
        self.anchorBank = anchorBank
        self.vocabulary = vocabulary
        try Self.validateAffinityModel(affinityModel)
        try Self.validateRetrievalModel(retrievalModel, anchorBank: anchorBank)
    }

    public init(affinityModel: MLModel, retrievalModel: MLModel, anchorBank: HinotoriAnchorBank, vocabulary: HinotoriVocabulary) throws {
        self.affinityModel = affinityModel
        self.retrievalModel = retrievalModel
        self.anchorBank = anchorBank
        self.vocabulary = vocabulary
        try Self.validateAffinityModel(affinityModel)
        try Self.validateRetrievalModel(retrievalModel, anchorBank: anchorBank)
    }

    /// Loads the exact model pair, anchor bank, and vocabulary shipped with the
    /// application.  Every artifact is validated before the first inference.
    public convenience init(bundle: Bundle = .main) throws {
        guard let affinityURL = bundle.url(forResource: "HinotoriAffinity", withExtension: "mlmodelc"),
              let retrievalURL = bundle.url(forResource: "HinotoriRetrieval", withExtension: "mlmodelc") else {
            throw HinotoriCoreMLError.invalidModelContract("HinotoriAffinity.mlmodelcまたはHinotoriRetrieval.mlmodelcがBundle内にありません")
        }
        try self.init(
            affinityModelURL: affinityURL,
            retrievalModelURL: retrievalURL,
            anchorBank: try HinotoriAnchorBank.load(bundle: bundle),
            vocabulary: try HinotoriVocabulary.load(bundle: bundle)
        )
    }

    public func recognize(_ strokes: [HinotoriStroke], topK: Int = 5) throws -> HinotoriRecognition {
        try Self.validateFormulaInput(strokes)
        guard (1...Self.classCount).contains(topK) else { throw HinotoriCoreMLError.invalidModelContract("topKは1...229で指定する必要があります") }
        let affinityInput = try makeAffinityInput(strokes)
        let affinityOutput: MLMultiArray
        do {
            let output = try affinityModel.prediction(from: MLDictionaryFeatureProvider(dictionary: affinityInput))
            guard let value = output.featureValue(for: "affinityLogits")?.multiArrayValue else {
                throw HinotoriCoreMLError.invalidModelContract("affinityLogits出力がありません")
            }
            affinityOutput = value
        } catch let error as HinotoriCoreMLError {
            throw error
        } catch {
            throw HinotoriCoreMLError.predictionFailed(error.localizedDescription)
        }
        let groups = try Self.decodeConnectedComponents(affinity: affinityOutput, validCount: strokes.count)
        let retrieved = try groups.map { group in
            let query = try Self.canonicalGroup(Array(group.map { strokes[$0] }), pointCount: Self.pointsPerStroke)
            guard query.count <= anchorBank.maxStrokes else {
                throw HinotoriCoreMLError.tooManyGroupStrokes(actual: query.count, maximum: anchorBank.maxStrokes)
            }
            return try retrieve(query: query, topK: topK)
        }
        return HinotoriRecognition(
            groups: groups,
            candidates: retrieved.map { $0.candidates },
            classLogits: retrieved.map { $0.classLogits },
            classFeatureDistances: retrieved.map { $0.classFeatureDistances },
            fold7SimilarityCandidates: []
        )
    }

    public static func decodeConnectedComponents(affinity: MLMultiArray, validCount: Int) throws -> [[Int]] {
        let shape = affinity.shape.map(\.intValue)
        guard affinity.dataType == .float32, shape == [maxFormulaStrokes, maxFormulaStrokes] else {
            throw HinotoriCoreMLError.invalidModelContract("affinityLogitsはfloat32[80,80]である必要があります")
        }
        guard validCount > 0 && validCount <= maxFormulaStrokes else {
            throw HinotoriCoreMLError.invalidModelContract("有効ストローク数が1...80ではありません")
        }
        var parent = Array(0..<validCount)
        func root(_ value: Int) -> Int {
            var value = value
            while parent[value] != value {
                parent[value] = parent[parent[value]]
                value = parent[value]
            }
            return value
        }
        func unite(_ left: Int, _ right: Int) {
            let leftRoot = root(left)
            let rightRoot = root(right)
            if leftRoot != rightRoot { parent[rightRoot] = leftRoot }
        }
        for left in 0..<validCount {
            for right in (left + 1)..<validCount where value(affinity, [left, right]).isFinite {
                if value(affinity, [left, right]) > 0 { unite(left, right) }
            }
        }
        var grouped: [Int: [Int]] = [:]
        for index in 0..<validCount { grouped[root(index), default: []].append(index) }
        return grouped.keys.sorted().compactMap { grouped[$0] }
    }

    public static func canonicalGroup(_ strokes: [HinotoriStroke], pointCount: Int = pointsPerStroke) throws -> [[[Float]]] {
        guard !strokes.isEmpty, pointCount > 0 else { throw HinotoriCoreMLError.emptyFormula }
        try validate(strokes)
        let points = strokes.flatMap(\.points)
        let minX = points.map(\.x).min()!
        let maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!
        let maxY = points.map(\.y).max()!
        let extent = max(maxX - minX, maxY - minY)
        if extent == 0 {
            return strokes.map { _ in Array(repeating: [0, 0], count: pointCount) }
        }
        let center = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        return try strokes.map { stroke in
            let normalized = stroke.points.map { point in CGPoint(x: (point.x - center.x) / extent, y: (point.y - center.y) / extent) }
            return try resample(normalized, count: pointCount).map { [Float($0.x), Float($0.y)] }
        }
    }

    /// Checks the same formula-input constraints that `recognize(_:topK:)` enforces before Core ML prediction.
    public static func validateFormulaInput(_ strokes: [HinotoriStroke]) throws {
        guard !strokes.isEmpty else { throw HinotoriCoreMLError.emptyFormula }
        guard strokes.count <= maxFormulaStrokes else {
            throw HinotoriCoreMLError.tooManyFormulaStrokes(actual: strokes.count)
        }
        try validate(strokes)
    }

    private func makeAffinityInput(_ strokes: [HinotoriStroke]) throws -> [String: MLFeatureValue] {
        let points = try Self.makeArray(shape: [1, Self.maxFormulaStrokes, Self.pointsPerStroke, 2])
        let valid = try Self.makeArray(shape: [1, Self.maxFormulaStrokes])
        for (strokeIndex, stroke) in strokes.enumerated() {
            let canonical = try Self.canonicalGroup([stroke])[0]
            for pointIndex in 0..<Self.pointsPerStroke {
                Self.set(points, [0, strokeIndex, pointIndex, 0], canonical[pointIndex][0])
                Self.set(points, [0, strokeIndex, pointIndex, 1], canonical[pointIndex][1])
            }
            Self.set(valid, [0, strokeIndex], 1)
        }
        return ["tracePoints": MLFeatureValue(multiArray: points), "traceValid": MLFeatureValue(multiArray: valid)]
    }

    private func retrieve(query: [[[Float]]], topK: Int) throws -> (candidates: [HinotoriCandidate], classLogits: [Float], classFeatureDistances: [Float]) {
        let queryPoints = try Self.makeArray(shape: [1, anchorBank.maxStrokes, Self.pointsPerStroke, 2])
        let queryValid = try Self.makeArray(shape: [1, anchorBank.maxStrokes])
        for strokeIndex in query.indices {
            for pointIndex in 0..<Self.pointsPerStroke {
                Self.set(queryPoints, [0, strokeIndex, pointIndex, 0], query[strokeIndex][pointIndex][0])
                Self.set(queryPoints, [0, strokeIndex, pointIndex, 1], query[strokeIndex][pointIndex][1])
            }
            Self.set(queryValid, [0, strokeIndex], 1)
        }
        do {
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "queryPoints": MLFeatureValue(multiArray: queryPoints),
                "queryStrokeValid": MLFeatureValue(multiArray: queryValid),
                "anchorPoints": MLFeatureValue(multiArray: anchorBank.points),
                "anchorStrokeValid": MLFeatureValue(multiArray: anchorBank.strokeValid),
            ])
            let output = try retrievalModel.prediction(from: provider)
            guard let logits = output.featureValue(for: "classLogits")?.multiArrayValue else {
                throw HinotoriCoreMLError.invalidModelContract("classLogits出力がありません")
            }
            guard logits.dataType == .float32, logits.shape.map(\.intValue) == [1, Self.classCount] else {
                throw HinotoriCoreMLError.invalidModelContract("classLogitsはfloat32[1,229]である必要があります")
            }
            guard let queryEmbedding = output.featureValue(for: "queryEmbedding")?.multiArrayValue,
                  let anchorEmbeddings = output.featureValue(for: "anchorEmbeddings")?.multiArrayValue else {
                throw HinotoriCoreMLError.invalidModelContract("queryEmbeddingまたはanchorEmbeddings出力がありません")
            }
            guard queryEmbedding.dataType == .float32,
                  queryEmbedding.shape.map(\.intValue) == [1, Self.embeddingDimension],
                  anchorEmbeddings.dataType == .float32,
                  anchorEmbeddings.shape.map(\.intValue) == [anchorBank.anchorCount, Self.embeddingDimension] else {
                throw HinotoriCoreMLError.invalidModelContract("埋め込み出力shapeはfloat32[1,128]およびfloat32[anchorCount,128]である必要があります")
            }
            let distances = try featureDistances(query: queryEmbedding, anchors: anchorEmbeddings)
            let candidates = try (0..<Self.classCount).map {
                HinotoriCandidate(
                    classIndex: $0,
                    label: try vocabulary.label(for: $0),
                    logit: Self.value(logits, [0, $0])
                )
            }
            return (Array(candidates
                .sorted { $0.logit == $1.logit ? $0.classIndex < $1.classIndex : $0.logit > $1.logit }
                .prefix(topK)), candidates.map(\.logit), distances)
        } catch let error as HinotoriCoreMLError {
            throw error
        } catch {
            throw HinotoriCoreMLError.predictionFailed(error.localizedDescription)
        }
    }

    private static func validateAffinityModel(_ model: MLModel) throws {
        try require(model, input: "tracePoints", shape: [1, maxFormulaStrokes, pointsPerStroke, 2])
        try require(model, input: "traceValid", shape: [1, maxFormulaStrokes])
        try require(model, output: "affinityLogits", shape: [maxFormulaStrokes, maxFormulaStrokes])
    }

    private static func validateRetrievalModel(_ model: MLModel, anchorBank: HinotoriAnchorBank) throws {
        try require(model, input: "queryPoints", shape: [1, anchorBank.maxStrokes, pointsPerStroke, 2])
        try require(model, input: "queryStrokeValid", shape: [1, anchorBank.maxStrokes])
        try require(model, input: "anchorPoints", shape: [anchorBank.anchorCount, anchorBank.maxStrokes, pointsPerStroke, 2])
        try require(model, input: "anchorStrokeValid", shape: [anchorBank.anchorCount, anchorBank.maxStrokes])
        try require(model, output: "classLogits", shape: [1, classCount])
        try require(model, output: "queryEmbedding", shape: [1, embeddingDimension])
        try require(model, output: "anchorEmbeddings", shape: [anchorBank.anchorCount, embeddingDimension])
    }

    private static let embeddingDimension = 128

    private func featureDistances(query: MLMultiArray, anchors: MLMultiArray) throws -> [Float] {
        let queryVector = (0..<Self.embeddingDimension).map { Self.value(query, [0, $0]) }
        guard queryVector.allSatisfy(\.isFinite) else {
            throw HinotoriCoreMLError.invalidModelContract("queryEmbeddingに有限でない特徴量があります")
        }
        let queryNorm = sqrt(queryVector.reduce(Float.zero) { $0 + $1 * $1 })
        guard queryNorm.isFinite, queryNorm > Float.leastNonzeroMagnitude else {
            throw HinotoriCoreMLError.invalidModelContract("queryEmbeddingのL2ノルムが0または非有限です")
        }
        let normalizedQuery = queryVector.map { $0 / queryNorm }
        let prototypes = try cachedClassPrototypes(from: anchors)
        let distances = prototypes.map { prototype in
            let cosine = zip(normalizedQuery, prototype).reduce(Float.zero) { $0 + $1.0 * $1.1 }
            guard cosine.isFinite else { return Float.nan }
            return 1 - min(1, max(-1, cosine))
        }
        guard distances.count == Self.classCount, distances.allSatisfy(\.isFinite) else {
            throw HinotoriCoreMLError.invalidModelContract("クラス特徴距離が229件の有限値でありません")
        }
        return distances
    }

    private func cachedClassPrototypes(from anchors: MLMultiArray) throws -> [[Float]] {
        prototypeLock.lock()
        defer { prototypeLock.unlock() }
        if let classPrototypes { return classPrototypes }

        var sums = Array(repeating: Array(repeating: Float.zero, count: Self.embeddingDimension), count: Self.classCount)
        var counts = Array(repeating: 0, count: Self.classCount)
        for anchorIndex in 0..<anchorBank.anchorCount {
            let classIndex = anchorBank.classIndices[anchorIndex]
            counts[classIndex] += 1
            var anchorVector: [Float] = []
            anchorVector.reserveCapacity(Self.embeddingDimension)
            for dimension in 0..<Self.embeddingDimension {
                let value = Self.value(anchors, [anchorIndex, dimension])
                guard value.isFinite else {
                    throw HinotoriCoreMLError.invalidModelContract("anchorEmbeddingsに有限でない特徴量があります")
                }
                anchorVector.append(value)
            }
            let anchorNorm = sqrt(anchorVector.reduce(Float.zero) { $0 + $1 * $1 })
            guard anchorNorm.isFinite, anchorNorm > Float.leastNonzeroMagnitude else {
                throw HinotoriCoreMLError.invalidModelContract("anchor \(anchorIndex)の特徴ベクトルが正規化できません")
            }
            for dimension in 0..<Self.embeddingDimension {
                sums[classIndex][dimension] += anchorVector[dimension] / anchorNorm
            }
        }
        var prototypes: [[Float]] = []
        prototypes.reserveCapacity(Self.classCount)
        for classIndex in 0..<Self.classCount {
            guard counts[classIndex] > 0 else {
                throw HinotoriCoreMLError.invalidModelContract("anchor class \(classIndex)に特徴プロトタイプがありません")
            }
            let mean = sums[classIndex].map { $0 / Float(counts[classIndex]) }
            let norm = sqrt(mean.reduce(Float.zero) { $0 + $1 * $1 })
            guard norm.isFinite, norm > Float.leastNonzeroMagnitude else {
                throw HinotoriCoreMLError.invalidModelContract("anchor class \(classIndex)の特徴プロトタイプが正規化できません")
            }
            prototypes.append(mean.map { $0 / norm })
        }
        classPrototypes = prototypes
        return prototypes
    }

    private static func require(_ model: MLModel, input name: String, shape: [Int]) throws {
        guard let description = model.modelDescription.inputDescriptionsByName[name], description.type == .multiArray,
              description.multiArrayConstraint?.dataType == .float32,
              description.multiArrayConstraint?.shape.map(\.intValue) == shape else {
            throw HinotoriCoreMLError.invalidModelContract("入力\(name)はfloat32\(shape)である必要があります")
        }
    }

    private static func require(_ model: MLModel, output name: String, shape: [Int]) throws {
        guard let description = model.modelDescription.outputDescriptionsByName[name], description.type == .multiArray,
              description.multiArrayConstraint?.dataType == .float32,
              description.multiArrayConstraint?.shape.map(\.intValue) == shape else {
            throw HinotoriCoreMLError.invalidModelContract("出力\(name)はfloat32\(shape)である必要があります")
        }
    }

    private static func validate(_ strokes: [HinotoriStroke]) throws {
        for (index, stroke) in strokes.enumerated() {
            guard !stroke.points.isEmpty else { throw HinotoriCoreMLError.emptyStroke(index: index) }
            guard stroke.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw HinotoriCoreMLError.nonFinitePoint(stroke: index) }
        }
    }

    private static func resample(_ points: [CGPoint], count: Int) throws -> [CGPoint] {
        guard let first = points.first else { throw HinotoriCoreMLError.emptyFormula }
        if points.count == 1 { return Array(repeating: first, count: count) }
        var distinct = [first]
        for point in points.dropFirst() where point != distinct.last! { distinct.append(point) }
        guard distinct.count > 1 else { return Array(repeating: first, count: count) }
        var cumulative: [CGFloat] = [0]
        for index in 1..<distinct.count {
            let dx = distinct[index].x - distinct[index - 1].x
            let dy = distinct[index].y - distinct[index - 1].y
            cumulative.append(cumulative.last! + hypot(dx, dy))
        }
        guard let total = cumulative.last, total > 0 else { return Array(repeating: first, count: count) }
        return (0..<count).map { index in
            let target = total * CGFloat(index) / CGFloat(max(count - 1, 1))
            let upper = cumulative.firstIndex(where: { $0 >= target }) ?? (distinct.count - 1)
            guard upper > 0 else { return distinct[0] }
            let lower = upper - 1
            let ratio = (target - cumulative[lower]) / (cumulative[upper] - cumulative[lower])
            return CGPoint(x: distinct[lower].x + (distinct[upper].x - distinct[lower].x) * ratio, y: distinct[lower].y + (distinct[upper].y - distinct[lower].y) * ratio)
        }
    }

    private static func makeArray(shape: [Int]) throws -> MLMultiArray {
        try MLMultiArray(shape: shape.map(NSNumber.init(value:)), dataType: .float32)
    }

    private static func value(_ array: MLMultiArray, _ indices: [Int]) -> Float {
        let offset = zip(indices, array.strides.map(\.intValue)).reduce(0) { $0 + $1.0 * $1.1 }
        return array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)[offset]
    }

    private static func set(_ array: MLMultiArray, _ indices: [Int], _ value: Float) {
        let offset = zip(indices, array.strides.map(\.intValue)).reduce(0) { $0 + $1.0 * $1.1 }
        array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)[offset] = value
    }
}
