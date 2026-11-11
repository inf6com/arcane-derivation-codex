import CoreML
import CryptoKit
import Foundation

public struct HinotoriFold7Candidate: Sendable, Equatable {
    public let classIndex: Int
    public let label: String
    public let displayGlyph: String?
    public let logit: Float
    public let cosineSimilarity: Float
}

public struct HinotoriFold7SimilarityCandidate: Codable, Sendable, Equatable {
    public let classIndex: Int
    public let label: String
    public let displayGlyph: String?
    public let cosineSimilarity: Float
    public let groupIDs: [Int]
}

public struct HinotoriFold7SimilaritySuggestion: Codable, Sendable, Equatable {
    public let groupID: Int
    public let cosineSimilarity: Float
    public let candidates: [HinotoriFold7SimilarityCandidate]
}

public struct HinotoriFold7SimilarityExpansion: Codable, Sendable, Equatable {
    public let selectedLabel: String
    public let candidates: [HinotoriFold7SimilarityCandidate]
    public let groups: [HinotoriFold7SimilaritySuggestion]
}

public struct HinotoriFold7Prediction: Sendable, Equatable {
    /// Exact classifier ranking, ordered by its unmodified logits.
    public let candidates: [HinotoriFold7Candidate]
    /// All 229 unmodified classifier logits, aligned with vocabulary indices.
    public let classLogits: [Float]
    /// Cosine similarity to each of the ordered 229 normalized class prototypes.
    /// Group expansion is requested only after the user selects an exact candidate.
    public let classCosineSimilarities: [Float]
    public let queryEmbedding: [Float]
    public let checkpointSHA256: String
    public let sourceCoordinateSpace: HinotoriStrokeSetInput.SourceCoordinateSpace
}

/// Fold-07 epoch-26 isolated-symbol classifier. Input must already be one symbol;
/// segmentation and formula-structure recognition are outside this API.
public final class HinotoriFold7CoreMLClassifier {
    public static let classCount = 229
    public static let embeddingDimension = 128
    public static let selectedEpoch = 26
    public static let checkpointSHA256 = "c535d54e9d255937f390e71e884f146167532c4f46289af4a4d29268bcdbc44a"

    private let model: MLModel
    private let labels: [String]
    private let glyphByLabel: [String: String]
    private let classIndexByLabel: [String: Int]
    private let groups: [SimilarityGroup]
    private let classifierLogitScale: Float

    public init(bundle: Bundle = .main) throws {
        guard let modelURL = bundle.url(forResource: "HinotoriFold7Classifier", withExtension: "mlmodelc"),
              let manifestURL = bundle.url(forResource: "HinotoriFold7CoreML.manifest", withExtension: "json"),
              let vocabularyURL = bundle.url(forResource: "HinotoriFold7Vocabulary", withExtension: "json"),
              let groupsURL = bundle.url(forResource: "HinotoriPrototypeCosineSimilarityGroups", withExtension: "json") else {
            throw ClassifierError.missingResource
        }

        let manifest = try Self.decode(Manifest.self, from: manifestURL)
        let vocabulary = try Self.decode(Vocabulary.self, from: vocabularyURL)
        let similarity = try Self.decode(SimilarityDocument.self, from: groupsURL)
        guard manifest.schema == "hinotori-fold7-spatial-pyramid-coreml-v1",
              manifest.productModelName == "火の鳥",
              manifest.task == "229-way isolated handwritten symbol classification",
              manifest.architecture == "HinotoriSpatialPyramidAngularMargin",
              manifest.classifierLogitScale.isFinite, manifest.classifierLogitScale > 0,
              manifest.checkpoint.epoch == Self.selectedEpoch,
              manifest.checkpoint.sha256 == Self.checkpointSHA256,
              manifest.vocabulary.sha256 == (try Self.sha256(vocabularyURL)),
              manifest.similarity.sha256 == (try Self.sha256(groupsURL)),
              vocabulary.version == "symbol229-v1",
              vocabulary.labels.count == Self.classCount,
              Set(vocabulary.labels).count == Self.classCount,
              manifest.vocabulary.labels == Self.classCount,
              similarity.schema == "hinotori-fold7-prototype-cosine-groups-v1",
              similarity.groups.count == 87 else {
            throw ClassifierError.invalidArtifact("Fold-07 checkpoint provenance, 229-label vocabulary, or 87-group catalog does not match")
        }
        guard similarity.groups.allSatisfy({ group in
            group.labels.count == group.displayGlyphs.count &&
            group.labels.count >= 2 &&
            Set(group.labels).count == group.labels.count &&
            group.labels.allSatisfy(vocabulary.labels.contains)
        }) else {
            throw ClassifierError.invalidArtifact("similarity catalog contains unknown labels or malformed members")
        }

        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            model = try MLModel(contentsOf: modelURL, configuration: configuration)
        } catch {
            throw ClassifierError.modelLoadFailed(error.localizedDescription)
        }
        try Self.validateInterface(model)
        labels = vocabulary.labels
        classIndexByLabel = Dictionary(uniqueKeysWithValues: vocabulary.labels.enumerated().map { ($0.element, $0.offset) })
        groups = similarity.groups
        classifierLogitScale = manifest.classifierLogitScale
        var glyphs: [String: String] = [:]
        for group in similarity.groups {
            for (label, glyph) in zip(group.labels, group.displayGlyphs) {
                if let existing = glyphs[label], existing != glyph {
                    throw ClassifierError.invalidArtifact("similarity catalog maps \(label) to conflicting display glyphs")
                }
                glyphs[label] = glyph
            }
        }
        glyphByLabel = glyphs
    }

    public func classify(
        callerDesignatedSymbolStrokeGroup strokes: [[CGPoint]],
        sourceCoordinateSpace: HinotoriStrokeSetInput.SourceCoordinateSpace
    ) throws -> HinotoriFold7Prediction {
        let input = try HinotoriStrokeSetInput.buildRasterOnly(
            sourceCoordinateSpace: sourceCoordinateSpace,
            callerDesignatedSymbolStrokeGroup: strokes
        )
        let output: MLFeatureProvider
        do {
            output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "inkRaster": MLFeatureValue(multiArray: input.inkRaster)
            ]))
        } catch {
            throw ClassifierError.predictionFailed(error.localizedDescription)
        }
        guard let logitsArray = output.featureValue(for: "classLogits")?.multiArrayValue,
              let embeddingArray = output.featureValue(for: "queryEmbedding")?.multiArrayValue else {
            throw ClassifierError.invalidOutput("classLogits or queryEmbedding is missing")
        }
        let logits = try Self.readFloat32(logitsArray, expectedShape: [1, Self.classCount], name: "classLogits")
        let embedding = try Self.readFloat32(embeddingArray, expectedShape: [1, Self.embeddingDimension], name: "queryEmbedding")
        let norm = sqrt(embedding.reduce(Float.zero) { $0 + $1 * $1 })
        guard norm.isFinite, abs(norm - 1) <= 0.02 else {
            throw ClassifierError.invalidOutput("queryEmbedding is not a finite unit vector")
        }
        let ranked = logits.indices.sorted { logits[$0] == logits[$1] ? $0 < $1 : logits[$0] > logits[$1] }
        let classCosines = try logits.enumerated().map { index, logit in
            try Self.cosine(logit, scale: classifierLogitScale, classIndex: index)
        }
        let candidates = ranked.prefix(5).map { index in
            HinotoriFold7Candidate(
                classIndex: index,
                label: labels[index],
                displayGlyph: glyphByLabel[labels[index]],
                logit: logits[index],
                cosineSimilarity: classCosines[index]
            )
        }

        return HinotoriFold7Prediction(
            candidates: candidates,
            classLogits: logits,
            classCosineSimilarities: classCosines,
            queryEmbedding: embedding,
            checkpointSHA256: "c535d54e9d255937f390e71e884f146167532c4f46289af4a4d29268bcdbc44a",
            sourceCoordinateSpace: input.sourceCoordinateSpace
        )
    }

    /// Expands only the catalog groups containing a user-selected exact Top-5
    /// result. Their other members are ranked by this input's prototype cosine.
    public func similarCandidates(
        for selected: HinotoriFold7Candidate,
        from prediction: HinotoriFold7Prediction
    ) throws -> HinotoriFold7SimilarityExpansion {
        guard prediction.checkpointSHA256 == "c535d54e9d255937f390e71e884f146167532c4f46289af4a4d29268bcdbc44a",
              prediction.classCosineSimilarities.count == Self.classCount,
              prediction.candidates.contains(where: { $0.classIndex == selected.classIndex && $0.label == selected.label }),
              labels.indices.contains(selected.classIndex), labels[selected.classIndex] == selected.label else {
            throw ClassifierError.selectionNotInPrediction
        }
        return try similarCandidates(forClassIndex: selected.classIndex, classCosineSimilarities: prediction.classCosineSimilarities)
    }

    /// Expands any class selected by the fused ensemble. Membership comes from
    /// the 87-group catalog; this query's Fold7 prototype cosine only orders
    /// the members and never changes ensemble probabilities.
    public func similarCandidates(
        forClassIndex classIndex: Int,
        classCosineSimilarities: [Float]
    ) throws -> HinotoriFold7SimilarityExpansion {
        guard labels.indices.contains(classIndex),
              classCosineSimilarities.count == Self.classCount,
              classCosineSimilarities.allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else {
            throw ClassifierError.invalidSimilarityScores
        }
        let selectedLabel = labels[classIndex]
        let matchedGroups = groups.filter { $0.labels.contains(selectedLabel) }
        var memberships: [String: Set<Int>] = [:]
        for group in matchedGroups {
            for label in group.labels where label != selectedLabel {
                memberships[label, default: []].insert(group.groupID)
            }
        }
        var prioritized: [HinotoriFold7SimilarityCandidate] = []
        prioritized.reserveCapacity(memberships.count)
        for (label, groupIDs) in memberships {
            guard let classIndex = classIndexByLabel[label] else {
                throw ClassifierError.invalidArtifact("matched similarity candidate is absent from the ordered vocabulary")
            }
            prioritized.append(HinotoriFold7SimilarityCandidate(
                classIndex: classIndex,
                label: label,
                displayGlyph: glyphByLabel[label],
                cosineSimilarity: classCosineSimilarities[classIndex],
                groupIDs: groupIDs.sorted()
            ))
        }
        prioritized.sort {
            $0.cosineSimilarity == $1.cosineSimilarity
                ? $0.classIndex < $1.classIndex
                : $0.cosineSimilarity > $1.cosineSimilarity
        }
        var suggestions: [HinotoriFold7SimilaritySuggestion] = []
        suggestions.reserveCapacity(matchedGroups.count)
        for group in matchedGroups {
            var groupCandidates: [HinotoriFold7SimilarityCandidate] = []
            var groupScore = -Float.infinity
            for label in group.labels where label != selectedLabel {
                guard let classIndex = classIndexByLabel[label] else {
                    throw ClassifierError.invalidArtifact("similarity group contains a label absent from the vocabulary")
                }
                let score = classCosineSimilarities[classIndex]
                groupScore = max(groupScore, score)
                groupCandidates.append(HinotoriFold7SimilarityCandidate(
                    classIndex: classIndex,
                    label: label,
                    displayGlyph: glyphByLabel[label],
                    cosineSimilarity: score,
                    groupIDs: [group.groupID]
                ))
            }
            groupCandidates.sort {
                $0.cosineSimilarity == $1.cosineSimilarity
                    ? $0.classIndex < $1.classIndex
                    : $0.cosineSimilarity > $1.cosineSimilarity
            }
            suggestions.append(HinotoriFold7SimilaritySuggestion(
                groupID: group.groupID,
                cosineSimilarity: groupScore,
                candidates: groupCandidates
            ))
        }
        suggestions.sort {
            $0.cosineSimilarity == $1.cosineSimilarity
                ? $0.groupID < $1.groupID
                : $0.cosineSimilarity > $1.cosineSimilarity
        }
        return HinotoriFold7SimilarityExpansion(selectedLabel: selectedLabel, candidates: prioritized, groups: suggestions)
    }

    public enum ClassifierError: LocalizedError {
        case missingResource
        case invalidArtifact(String)
        case modelLoadFailed(String)
        case selectionNotInPrediction
        case invalidSimilarityScores
        case predictionFailed(String)
        case invalidOutput(String)

        public var errorDescription: String? {
            switch self {
            case .missingResource: return "Hinotori Fold-07 Core ML model or its manifest, vocabulary, and similarity catalog is missing from the app bundle"
            case .invalidArtifact(let reason): return "Hinotori Fold-07 artifact validation failed: \(reason)"
            case .modelLoadFailed(let reason): return "Hinotori Fold-07 Core ML model load failed: \(reason)"
            case .selectionNotInPrediction: return "The selected class is not one of this Fold-07 Top-5 prediction's candidates"
            case .invalidSimilarityScores: return "Fold-07 class index or 229-class cosine vector is invalid"
            case .predictionFailed(let reason): return "Hinotori Fold-07 prediction failed: \(reason)"
            case .invalidOutput(let reason): return "Hinotori Fold-07 output violates the model contract: \(reason)"
            }
        }
    }

    private struct Manifest: Decodable {
        struct Checkpoint: Decodable { let sha256: String; let epoch: Int }
        struct VocabularyInfo: Decodable { let sha256: String; let labels: Int }
        struct SimilarityInfo: Decodable { let sha256: String }
        let schema: String
        let productModelName: String
        let task: String
        let architecture: String
        let classifierLogitScale: Float
        let checkpoint: Checkpoint
        let vocabulary: VocabularyInfo
        let similarity: SimilarityInfo
    }
    private struct Vocabulary: Decodable { let version: String; let labels: [String] }
    private struct SimilarityDocument: Decodable { let schema: String; let groups: [SimilarityGroup] }
    private struct SimilarityGroup: Decodable { let groupID: Int; let labels: [String]; let displayGlyphs: [String] }

    private static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        do { return try JSONDecoder().decode(type, from: Data(contentsOf: url, options: .mappedIfSafe)) }
        catch { throw ClassifierError.invalidArtifact("\(url.lastPathComponent): \(error.localizedDescription)") }
    }

    private static func sha256(_ url: URL) throws -> String {
        do { return SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined() }
        catch { throw ClassifierError.invalidArtifact("\(url.lastPathComponent): \(error.localizedDescription)") }
    }

    private static func validateInterface(_ model: MLModel) throws {
        let input = model.modelDescription.inputDescriptionsByName["inkRaster"]
        let logits = model.modelDescription.outputDescriptionsByName["classLogits"]
        let embedding = model.modelDescription.outputDescriptionsByName["queryEmbedding"]
        guard model.modelDescription.inputDescriptionsByName.count == 1,
              model.modelDescription.outputDescriptionsByName.count == 2,
              input?.type == .multiArray, input?.multiArrayConstraint?.shape.map(\.intValue) == [1, 1, 64, 64],
              input?.multiArrayConstraint?.dataType == .float32,
              logits?.type == .multiArray, logits?.multiArrayConstraint?.shape.map(\.intValue) == [1, Self.classCount],
              logits?.multiArrayConstraint?.dataType == .float32,
              embedding?.type == .multiArray, embedding?.multiArrayConstraint?.shape.map(\.intValue) == [1, Self.embeddingDimension],
              embedding?.multiArrayConstraint?.dataType == .float32 else {
            throw ClassifierError.invalidArtifact("Core ML tensor names, shapes, or float32 dtypes differ from the Fold-07 contract")
        }
    }

    private static func readFloat32(_ array: MLMultiArray, expectedShape: [Int], name: String) throws -> [Float] {
        guard array.dataType == .float32, array.shape.map(\.intValue) == expectedShape else {
            throw ClassifierError.invalidOutput("\(name) must be float32 with shape \(expectedShape)")
        }
        let pointer = array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)
        let strides = array.strides.map(\.intValue)
        let values = (0..<expectedShape.reduce(1, *)).map { flat -> Float in
            var remainder = flat
            var offset = 0
            for axis in expectedShape.indices.reversed() {
                let coordinate = remainder % expectedShape[axis]
                remainder /= expectedShape[axis]
                offset += coordinate * strides[axis]
            }
            return pointer[offset]
        }
        guard values.allSatisfy(\.isFinite) else { throw ClassifierError.invalidOutput("\(name) contains a non-finite value") }
        return values
    }

    private static func cosine(_ logit: Float, scale: Float, classIndex: Int) throws -> Float {
        let value = logit / scale
        guard value.isFinite, (-1.001...1.001).contains(value) else {
            throw ClassifierError.invalidOutput("class \(classIndex) logit/scale is outside the cosine range")
        }
        return min(1, max(-1, value))
    }
}
