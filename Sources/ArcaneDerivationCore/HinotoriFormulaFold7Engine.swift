import CoreML
import Foundation

/// Formula-level stroke grouping followed by Fold-07 isolated-symbol ranking.
/// The grouping is provisional: each average-linkage cluster remains editable
/// and is classified independently by the Fold-07 model.
public final class HinotoriFormulaFold7Engine: HinotoriSymbolRecognitionEngine {
    public static let selectedEpoch = 33
    public static let checkpointSHA256 = "13f61174735b435e7e8203666b32a05b7a0e2431aa56e525a83c303589035d55"
    public static let validationThreshold: Float = -1.0
    public static let partitionThreshold: Float = -1.0
    private static let maximumStrokes = 80
    private static let pointCount = 32

    private let groupingModel: MLModel
    private let groupingThreshold: Float
    private let classifier: HinotoriFold7CoreMLClassifier

    public func similarCandidates(forClassIndex classIndex: Int, classCosineSimilarities: [Float]) throws -> HinotoriFold7SimilarityExpansion {
        try classifier.similarCandidates(forClassIndex: classIndex, classCosineSimilarities: classCosineSimilarities)
    }

    public init(bundle: Bundle = .main) throws {
        guard let modelURL = bundle.url(forResource: "HinotoriFormulaSegmenter", withExtension: "mlmodelc"),
              let manifestURL = bundle.url(forResource: "HinotoriFormulaSegmenter.manifest", withExtension: "json") else {
            throw EngineError.missingArtifact("HinotoriFormulaSegmenter.mlmodelc または manifest")
        }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw EngineError.invalidArtifact("分割器manifestを読み込めません: \(error.localizedDescription)")
        }
        guard manifest.format == "hinotori-formula-frame-pair-segmenter-coreml-v2",
              manifest.modelName == "HinotoriFormulaSegmenter",
              manifest.selectedEpoch == Self.selectedEpoch,
              manifest.checkpointSHA256 == Self.checkpointSHA256,
              manifest.validationThreshold == Self.validationThreshold,
              manifest.input.formulaPoints.shape == [1, Self.maximumStrokes, Self.pointCount, 2],
              manifest.input.strokeValid.shape == [1, Self.maximumStrokes],
              manifest.output.affinityLogits.shape == [1, Self.maximumStrokes, Self.maximumStrokes],
              manifest.decode.algorithm == "average-linkage",
              manifest.decode.positivePairLogitThreshold == Self.partitionThreshold,
              manifest.decode.userMustConfirmCandidates,
              manifest.validationThreshold.isFinite,
              manifest.decode.positivePairLogitThreshold.isFinite,
              manifest.checkpointSHA256.count == 64 else {
            throw EngineError.invalidArtifact("分割器のshape・epoch・閾値・確認契約が一致しません")
        }
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            groupingModel = try MLModel(contentsOf: modelURL, configuration: configuration)
            classifier = try HinotoriFold7CoreMLClassifier(bundle: bundle)
        } catch {
            throw EngineError.modelLoadFailed(error.localizedDescription)
        }
        try Self.validateInterface(groupingModel)
        groupingThreshold = Self.partitionThreshold
    }

    public func recognize(_ strokes: [HinotoriStroke], topK: Int) throws -> HinotoriRecognition {
        guard !strokes.isEmpty else { throw EngineError.emptyFormula }
        guard strokes.count <= Self.maximumStrokes else {
            throw EngineError.tooManyStrokes(actual: strokes.count, maximum: Self.maximumStrokes)
        }
        guard (1...5).contains(topK) else { throw EngineError.invalidTopK(topK) }
        let tensors = try Self.makeInput(strokes)
        let output: MLFeatureProvider
        do {
            output = try groupingModel.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "formulaPoints": MLFeatureValue(multiArray: tensors.points),
                "strokeValid": MLFeatureValue(multiArray: tensors.valid),
            ]))
        } catch {
            throw EngineError.predictionFailed(error.localizedDescription)
        }
        guard let logits = output.featureValue(for: "affinityLogits")?.multiArrayValue,
              logits.shape.map(\.intValue) == [1, Self.maximumStrokes, Self.maximumStrokes] else {
            throw EngineError.invalidOutput("affinityLogitsのshapeが[1,80,80]ではありません")
        }
        let components = try Self.averageLinkageClusters(
            logits: logits,
            strokeCount: strokes.count,
            threshold: groupingThreshold
        )
        let ordered = components.sorted { lhs, rhs in
            let leftX = lhs.flatMap { strokes[$0].points }.map(\.x).min() ?? .infinity
            let rightX = rhs.flatMap { strokes[$0].points }.map(\.x).min() ?? .infinity
            if leftX != rightX { return leftX < rightX }
            let leftY = lhs.flatMap { strokes[$0].points }.map(\.y).min() ?? .infinity
            let rightY = rhs.flatMap { strokes[$0].points }.map(\.y).min() ?? .infinity
            return leftY == rightY ? lhs[0] < rhs[0] : leftY < rightY
        }

        var candidates: [[HinotoriCandidate]] = []
        var classLogits: [[Float]] = []
        var featureDistances: [[Float]] = []
        var similarityCandidates: [[[HinotoriFold7SimilarityCandidate]]] = []
        candidates.reserveCapacity(ordered.count)
        classLogits.reserveCapacity(ordered.count)
        featureDistances.reserveCapacity(ordered.count)
        similarityCandidates.reserveCapacity(ordered.count)
        for group in ordered {
            let prediction = try classifier.classify(
                callerDesignatedSymbolStrokeGroup: group.map { strokes[$0].points },
                sourceCoordinateSpace: .chatTextViewLocalPoints
            )
            candidates.append(prediction.candidates.prefix(topK).map {
                HinotoriCandidate(classIndex: $0.classIndex, label: $0.label, logit: $0.logit)
            })
            classLogits.append(prediction.classLogits)
            featureDistances.append(prediction.classCosineSimilarities.map { 1 - $0 })
            similarityCandidates.append(try prediction.candidates.prefix(topK).map { selected in
                try classifier.similarCandidates(for: selected, from: prediction).candidates
            })
        }
        return HinotoriRecognition(
            groups: ordered,
            candidates: candidates,
            classLogits: classLogits,
            classFeatureDistances: featureDistances,
            fold7SimilarityCandidates: similarityCandidates
        )
    }

    private static func makeInput(_ strokes: [HinotoriStroke]) throws -> (points: MLMultiArray, valid: MLMultiArray) {
        let all = strokes.flatMap(\.points)
        guard let first = all.first else { throw EngineError.emptyFormula }
        var minX = Float(first.x), maxX = Float(first.x)
        var minY = Float(first.y), maxY = Float(first.y)
        for (strokeIndex, stroke) in strokes.enumerated() {
            guard !stroke.points.isEmpty else { throw EngineError.emptyStroke(index: strokeIndex) }
            for (pointIndex, point) in stroke.points.enumerated() {
                let x = Float(point.x), y = Float(point.y)
                guard point.x.isFinite, point.y.isFinite, x.isFinite, y.isFinite else {
                    throw EngineError.invalidCoordinate(stroke: strokeIndex, point: pointIndex)
                }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let extent = max(maxX - minX, maxY - minY)
        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2
        guard extent.isFinite, centerX.isFinite, centerY.isFinite else { throw EngineError.invalidGeometry }

        let normalized: [[[Float]]]
        if extent == 0 {
            normalized = strokes.map { _ in Array(repeating: [0, 0], count: Self.pointCount) }
        } else {
            normalized = try strokes.enumerated().map { strokeIndex, stroke in
                let points = stroke.points.map { [((Float($0.x) - centerX) / extent), ((Float($0.y) - centerY) / extent)] }
                guard points.allSatisfy({ $0[0].isFinite && $0[1].isFinite }) else {
                    throw EngineError.invalidGeometry
                }
                return try resample(points, strokeIndex: strokeIndex)
            }
        }
        let points = try Self.array(shape: [1, Self.maximumStrokes, Self.pointCount, 2])
        let valid = try Self.array(shape: [1, Self.maximumStrokes])
        for strokeIndex in 0..<Self.maximumStrokes {
            valid[[0, strokeIndex] as [NSNumber]] = 0
            for pointIndex in 0..<Self.pointCount {
                points[[0, strokeIndex, pointIndex, 0] as [NSNumber]] = 0
                points[[0, strokeIndex, pointIndex, 1] as [NSNumber]] = 0
            }
        }
        for strokeIndex in normalized.indices {
            for pointIndex in 0..<Self.pointCount {
                points[[0, strokeIndex, pointIndex, 0] as [NSNumber]] = NSNumber(value: normalized[strokeIndex][pointIndex][0])
                points[[0, strokeIndex, pointIndex, 1] as [NSNumber]] = NSNumber(value: normalized[strokeIndex][pointIndex][1])
            }
            valid[[0, strokeIndex] as [NSNumber]] = 1
        }
        return (points, valid)
    }

    private static func resample(_ source: [[Float]], strokeIndex: Int) throws -> [[Float]] {
        guard let first = source.first else { throw EngineError.emptyStroke(index: strokeIndex) }
        guard source.count > 1 else { return Array(repeating: first, count: Self.pointCount) }
        var distinct = [source[0]]
        for point in source.dropFirst() {
            let previous = distinct[distinct.count - 1]
            let dx = point[0] - previous[0]
            let dy = point[1] - previous[1]
            let length = (dx * dx + dy * dy).squareRoot()
            guard length.isFinite else { throw EngineError.invalidGeometry }
            if length > 0 { distinct.append(point) }
        }
        guard distinct.count > 1 else { return Array(repeating: first, count: Self.pointCount) }
        var cumulative: [Float] = [0]
        for index in 1..<distinct.count {
            let dx = distinct[index][0] - distinct[index - 1][0]
            let dy = distinct[index][1] - distinct[index - 1][1]
            let distance = (dx * dx + dy * dy).squareRoot()
            guard distance.isFinite else { throw EngineError.invalidGeometry }
            cumulative.append(cumulative[cumulative.count - 1] + distance)
        }
        guard let total = cumulative.last, total.isFinite, total > 0 else {
            return Array(repeating: first, count: Self.pointCount)
        }
        return try (0..<Self.pointCount).map { sampleIndex in
            let target = total * Float(sampleIndex) / Float(Self.pointCount - 1)
            var upper = 1
            while upper < cumulative.count - 1 && cumulative[upper] <= target { upper += 1 }
            let lower = upper - 1
            let span = cumulative[upper] - cumulative[lower]
            guard span.isFinite, span > 0 else { throw EngineError.invalidGeometry }
            let ratio = (target - cumulative[lower]) / span
            return [
                distinct[lower][0] + ratio * (distinct[upper][0] - distinct[lower][0]),
                distinct[lower][1] + ratio * (distinct[upper][1] - distinct[lower][1]),
            ]
        }
    }

    private static func averageLinkageClusters(logits: MLMultiArray, strokeCount: Int, threshold: Float) throws -> [[Int]] {
        var affinity = Array(repeating: Array(repeating: Float.zero, count: strokeCount), count: strokeCount)
        for left in 0..<strokeCount {
            for right in (left + 1)..<strokeCount {
                let forward = logits[[0, left, right] as [NSNumber]].floatValue
                let reverse = logits[[0, right, left] as [NSNumber]].floatValue
                guard forward.isFinite, reverse.isFinite else {
                    throw EngineError.invalidOutput("affinityLogitsに有限でない値があります")
                }
                let score = (forward + reverse) * 0.5
                guard score.isFinite else {
                    throw EngineError.invalidOutput("対称化したaffinityLogitsが有限ではありません")
                }
                affinity[left][right] = score
                affinity[right][left] = score
            }
        }

        var clusters = (0..<strokeCount).map { [$0] }
        while clusters.count > 1 {
            var bestScore = -Float.infinity
            var bestPair: (left: Int, right: Int)?
            for left in 0..<(clusters.count - 1) {
                for right in (left + 1)..<clusters.count {
                    var total: Float = 0
                    for leftStroke in clusters[left] {
                        for rightStroke in clusters[right] {
                            total += affinity[leftStroke][rightStroke]
                        }
                    }
                    let pairCount = clusters[left].count * clusters[right].count
                    let mean = total / Float(pairCount)
                    guard mean.isFinite else {
                        throw EngineError.invalidOutput("平均リンク類似度が有限ではありません")
                    }
                    if mean > bestScore {
                        bestScore = mean
                        bestPair = (left, right)
                    }
                }
            }
            guard let bestPair, bestScore > threshold else { break }
            clusters[bestPair.left].append(contentsOf: clusters[bestPair.right])
            clusters[bestPair.left].sort()
            clusters.remove(at: bestPair.right)
        }
        return clusters
    }

    private static func array(shape: [Int]) throws -> MLMultiArray {
        do { return try MLMultiArray(shape: shape.map(NSNumber.init(value:)), dataType: .float32) }
        catch { throw EngineError.inputAllocation(error.localizedDescription) }
    }

    private static func validateInterface(_ model: MLModel) throws {
        let inputs = model.modelDescription.inputDescriptionsByName
        let outputs = model.modelDescription.outputDescriptionsByName
        guard inputs.count == 2,
              inputs["formulaPoints"]?.type == .multiArray,
              inputs["formulaPoints"]?.multiArrayConstraint?.shape.map(\.intValue) == [1, Self.maximumStrokes, Self.pointCount, 2],
              inputs["strokeValid"]?.type == .multiArray,
              inputs["strokeValid"]?.multiArrayConstraint?.shape.map(\.intValue) == [1, Self.maximumStrokes],
              outputs.count == 1,
              outputs["affinityLogits"]?.type == .multiArray,
              outputs["affinityLogits"]?.multiArrayConstraint?.shape.map(\.intValue) == [1, Self.maximumStrokes, Self.maximumStrokes] else {
            throw EngineError.invalidArtifact("Core ML分割器の入出力名またはshapeが不一致です")
        }
    }

    private struct Manifest: Decodable {
        struct Tensor: Decodable { let shape: [Int] }
        struct Inputs: Decodable { let formulaPoints: Tensor; let strokeValid: Tensor }
        struct Outputs: Decodable { let affinityLogits: Tensor }
        struct Decode: Decodable {
            let algorithm: String
            let positivePairLogitThreshold: Float
            let userMustConfirmCandidates: Bool
        }
        let format: String
        let modelName: String
        let selectedEpoch: Int
        let validationThreshold: Float
        let checkpointSHA256: String
        let input: Inputs
        let output: Outputs
        let decode: Decode
    }

    public enum EngineError: LocalizedError {
        case missingArtifact(String), invalidArtifact(String), modelLoadFailed(String), predictionFailed(String)
        case emptyFormula, tooManyStrokes(actual: Int, maximum: Int), emptyStroke(index: Int)
        case invalidCoordinate(stroke: Int, point: Int), invalidGeometry, inputAllocation(String)
        case invalidOutput(String), invalidTopK(Int)

        public var errorDescription: String? {
            switch self {
            case .missingArtifact(let name): return "火の鳥の分割モデル資産がありません: \(name)"
            case .invalidArtifact(let reason): return "火の鳥の分割モデル契約が不正です: \(reason)"
            case .modelLoadFailed(let reason): return "火の鳥モデルを読み込めません: \(reason)"
            case .predictionFailed(let reason): return "火の鳥のストローク分割に失敗しました: \(reason)"
            case .emptyFormula: return "数式入力にストロークがありません"
            case .tooManyStrokes(let actual, let maximum): return "ストローク数\(actual)が分割モデル上限\(maximum)を超えています"
            case .emptyStroke(let index): return "ストローク\(index + 1)に座標点がありません"
            case .invalidCoordinate(let stroke, let point): return "ストローク\(stroke + 1)の点\(point + 1)に無効な座標があります"
            case .invalidGeometry: return "数式全体の正規化または再サンプリングに失敗しました"
            case .inputAllocation(let reason): return "分割モデル入力を確保できません: \(reason)"
            case .invalidOutput(let reason): return "火の鳥分割モデルの出力が不正です: \(reason)"
            case .invalidTopK(let value): return "Fold7候補数\(value)は1〜5の範囲ではありません"
            }
        }
    }
}
