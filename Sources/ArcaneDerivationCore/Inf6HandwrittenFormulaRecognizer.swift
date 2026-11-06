import Foundation
import OSLog
import CoreML
#if canImport(PencilKit)
import PencilKit
#endif

public struct Inf6HandwrittenFormulaResult: Sendable, Equatable {
    public let latex: String
    public let mathML: String
    public let tokenIDs: [Int]
    public let symbolLabels: [String]
    public let symbolStrokeIndices: [[Int]]
    public let pointCount: Int
    public let candidateRanks: [Int]
    public let candidateLabels: [[String]]
    public let isProvisional: Bool

    public init(latex: String, mathML: String, tokenIDs: [Int], symbolLabels: [String] = [], symbolStrokeIndices: [[Int]] = [], pointCount: Int, candidateRanks: [Int] = [], candidateLabels: [[String]] = [], isProvisional: Bool = false) {
        self.latex = latex
        self.mathML = mathML
        self.tokenIDs = tokenIDs
        self.symbolLabels = symbolLabels
        self.symbolStrokeIndices = symbolStrokeIndices
        self.pointCount = pointCount
        self.candidateRanks = candidateRanks
        self.candidateLabels = candidateLabels
        self.isProvisional = isProvisional
    }
}

public enum Inf6HandwrittenFormulaError: LocalizedError {
    case cancelled
    case modelUnavailable(String)
    case vocabularyUnavailable
    case invalidModelInterface(String)
    case invalidInput(String)
    case recognitionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "手書き数式認識をキャンセルしました。"
        case .modelUnavailable(let value): return "手書き数式モデルを読み込めませんでした: \(value)"
        case .vocabularyUnavailable: return "手書き数式モデルの語彙を読み込めませんでした。"
        case .invalidModelInterface(let value): return "手書き数式モデルの入出力定義が契約と一致しません: \(value)"
        case .invalidInput(let value): return "手書き数式入力が契約外です: \(value)"
        case .recognitionFailed(let value): return "手書き数式認識に失敗しました: \(value)"
        }
    }
}

/// Stable interchange format shared by InkML conversion and PencilKit input.
/// Feature extraction must receive this value and never consume either source
/// format directly.
public struct Inf6CanonicalSample: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public let x: Double
        public let y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public struct Bounds: Codable, Equatable, Sendable {
        public let minX: Double
        public let minY: Double
        public let maxX: Double
        public let maxY: Double

        public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
            self.minX = minX
            self.minY = minY
            self.maxX = maxX
            self.maxY = maxY
        }
    }

    public static let formatIdentifier = "inf6-canonical-sample-v1"
    public let format: String
    public let traces: [[Point]]
    public let strokeOrder: [Int]
    public let sourceBounds: Bounds
    public let rowPosition: [Double]

    public init(traces: [[Point]], strokeOrder: [Int], sourceBounds: Bounds, rowPosition: [Double]) throws {
        guard !traces.isEmpty, traces.allSatisfy({ !$0.isEmpty }) else {
            throw Inf6HandwrittenFormulaError.invalidInput("CanonicalSampleに空のストロークがあります")
        }
        guard strokeOrder == Array(traces.indices) else {
            throw Inf6HandwrittenFormulaError.invalidInput("CanonicalSampleのストローク順が不正です")
        }
        guard rowPosition.count == 4, rowPosition.allSatisfy({ $0.isFinite }) else {
            throw Inf6HandwrittenFormulaError.invalidInput("CanonicalSampleの行位置が4要素ではありません")
        }
        guard traces.flatMap({ $0 }).allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw Inf6HandwrittenFormulaError.invalidInput("CanonicalSampleに有限でない座標があります")
        }
        self.format = Self.formatIdentifier
        self.traces = traces
        self.strokeOrder = strokeOrder
        self.sourceBounds = sourceBounds
        self.rowPosition = rowPosition
    }
}

/// Independent glyph classifier. The bundled Core ML model and
/// `Inf6GlyphFeatures` share the `inf6-glyph-shape-v2` feature contract
/// (see `HandwrittenSymbolModel.json`). Each spatially grouped glyph is
/// classified only from its own stroke geometry (shape only: position and
/// relations are decided outside this classifier).
public final class Inf6NonAutoregressiveSymbolRecognizer {
#if HMER_FEATURE_DIAGNOSTICS
    private static let diagnosticsLogger = Logger(subsystem: "com.inf6.inf6", category: "HMERFeature")
#endif

    private let vocabulary: [String]
    private let coreMLModel: MLModel

    public init(bundle: Bundle = .main) throws {
        guard let metadataURL = bundle.url(forResource: "HandwrittenSymbolModel", withExtension: "json") else {
            throw Inf6HandwrittenFormulaError.modelUnavailable("HandwrittenSymbolModel.json")
        }
        let metadata: SymbolModelMetadata
        do {
            metadata = try JSONDecoder().decode(SymbolModelMetadata.self, from: Data(contentsOf: metadataURL))
        } catch {
            throw Inf6HandwrittenFormulaError.modelUnavailable("HandwrittenSymbolModel.json: \(error.localizedDescription)")
        }
        // The Core ML model, this feature extractor and the training-side
        // extractor must name the same contract. A mismatch stops recognition
        // instead of feeding differently defined numbers into the model.
        guard metadata.featureVersion == Inf6GlyphFeatures.featureVersion,
              metadata.featureDimension == Inf6GlyphFeatures.featureDimension,
              !metadata.vocabulary.isEmpty,
              Set(metadata.vocabulary).count == metadata.vocabulary.count else {
            throw Inf6HandwrittenFormulaError.invalidModelInterface("学習・推論の特徴量仕様または語彙が一致しません")
        }
        guard let coreMLURL = bundle.url(forResource: "HandwrittenSymbolClassifier", withExtension: "mlmodelc")
            ?? bundle.url(forResource: "HandwrittenSymbolClassifier", withExtension: "mlpackage") else {
            throw Inf6HandwrittenFormulaError.modelUnavailable("HandwrittenSymbolClassifier")
        }
        let loadedCoreMLModel: MLModel
        do {
            let configuration = MLModelConfiguration()
            #if targetEnvironment(simulator)
            // The iOS 26 simulator's MPSGraph path returned all-zero logits
            // for this model. Keep that simulator-only workaround scoped to
            // Simulator; physical devices must be allowed to use the ANE.
            configuration.computeUnits = .cpuOnly
            #else
            configuration.computeUnits = .cpuAndNeuralEngine
            #endif
            loadedCoreMLModel = try MLModel(contentsOf: coreMLURL, configuration: configuration)
        } catch {
            throw Inf6HandwrittenFormulaError.modelUnavailable("HandwrittenSymbolClassifier: \(error.localizedDescription)")
        }
        guard loadedCoreMLModel.modelDescription.inputDescriptionsByName["glyphFeatures"]?.type == .multiArray,
              loadedCoreMLModel.modelDescription.outputDescriptionsByName["symbolScores"]?.type == .multiArray else {
            throw Inf6HandwrittenFormulaError.invalidModelInterface("記号Core MLモデルの入出力定義が一致しません")
        }
        vocabulary = metadata.vocabulary
        coreMLModel = loadedCoreMLModel
    }

    private struct SymbolModelMetadata: Decodable {
        let featureVersion: String
        let featureDimension: Int
        let vocabulary: [String]
    }

    public func recognize(
        strokes: [PKStroke],
        strokeGroups: [[Int]],
        cancellationCheck: @Sendable () -> Bool = { false }
    ) throws -> Inf6HandwrittenFormulaResult {
        try Self.throwIfCancelled(cancellationCheck)
        guard !strokes.isEmpty else {
            throw Inf6HandwrittenFormulaError.invalidInput("ストロークがありません")
        }
        let groups = strokeGroups
        guard !groups.isEmpty,
              groups.allSatisfy({ !$0.isEmpty && $0.allSatisfy(strokes.indices.contains) }) else {
            throw Inf6HandwrittenFormulaError.invalidInput("位置関係のストローク対応が不正です")
        }
        var expressions: [String] = []
        var candidateRanks: [Int] = []
        var candidateLabels: [[String]] = []
        expressions.reserveCapacity(groups.count)
        for group in groups {
            try Self.throwIfCancelled(cancellationCheck)
            let features = try Self.features(
                for: group.map { strokes[$0] },
                in: strokes,
                cancellationCheck: cancellationCheck
            )
            let classification = try classify(features, strokeCount: group.count, cancellationCheck: cancellationCheck)
            expressions.append(classification.label)
            candidateRanks.append(classification.rank)
            candidateLabels.append(classification.labels)
        }
        // Keep command boundaries intact: `\\chi` followed by `z` must not
        // become the invalid command `\\chiz`.
        let expression = expressions.joined(separator: " ")
        let mathML = try LaTeXMathMLConverter().convert(expression)
        let provisionalLabels: Set<String> = ["x", "X", "Z", "z"]
        // A single ambiguous glyph is provisional. Once a second glyph/cell
        // exists, the complete input must be recognized as an expression;
        // do not let an earlier x/X/Z/z keep the whole result provisional.
        let isProvisional = groups.count == 1
            && groups[0].count == 1
            && provisionalLabels.contains(expressions[0])
        return Inf6HandwrittenFormulaResult(
            latex: expression,
            mathML: mathML,
            tokenIDs: expressions.compactMap { vocabulary.firstIndex(of: $0) },
            symbolLabels: expressions,
            symbolStrokeIndices: groups,
            pointCount: strokes.reduce(0) { $0 + $1.path.count },
            candidateRanks: candidateRanks,
            candidateLabels: candidateLabels,
            isProvisional: isProvisional
        )
    }

    static func containsMeaningfulToken(in labels: [String]) -> Bool {
        labels.contains { label in
            label.unicodeScalars.contains { scalar in
                CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
            }
        }
    }

    static func containsSupportedFormulaTokenSequence(in labels: [String]) -> Bool {
        guard !labels.isEmpty else { return false }
        // A standalone operator or delimiter is a valid recognized symbol and
        // is rendered as MathML <mo>. It may be a unary sign, opening
        // delimiter, or the first token of a later derivation, so symbol
        // recognition must not reject it merely because no operand has been
        // written yet.
        if labels.count == 1, Self.standaloneMathMLTokens.contains(labels[0]) {
            return true
        }
        guard containsMeaningfulToken(in: labels) else { return false }
        for (index, label) in labels.enumerated() where label == "." {
            let previous = index > 0 ? labels[index - 1] : nil
            let next = index + 1 < labels.count ? labels[index + 1] : nil
            let adjacentToDigit = [previous, next].compactMap { $0 }.contains { token in
                token.count == 1 && token.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
            }
            guard adjacentToDigit else { return false }
        }
        return true
    }

    private static let standaloneMathMLTokens: Set<String> = [
        "-", "−", "+", "*", "/", "×", "÷", "=", "<", ">",
        "(", ")", ",", ":"
    ]

    private struct Classification {
        let label: String
        let rank: Int
        let labels: [String]
    }

    private func classify(_ features: [Double], strokeCount: Int, cancellationCheck: @Sendable () -> Bool) throws -> Classification {
        try Self.throwIfCancelled(cancellationCheck)
        guard features.count == Inf6GlyphFeatures.featureDimension else {
            throw Inf6HandwrittenFormulaError.invalidModelInterface("特徴量次元が\(features.count)件で、モデルの\(Inf6GlyphFeatures.featureDimension)件と一致しません")
        }
        let input = try MLMultiArray(shape: [1, NSNumber(value: Inf6GlyphFeatures.featureDimension)], dataType: .float32)
        for (index, value) in features.enumerated() { input[index] = NSNumber(value: value) }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["glyphFeatures": MLFeatureValue(multiArray: input)])
        let output = try coreMLModel.prediction(from: provider)
        guard let scores = output.featureValue(for: "symbolScores")?.multiArrayValue,
              scores.count == vocabulary.count else {
            throw Inf6HandwrittenFormulaError.invalidModelInterface("記号Core MLモデルの出力数が語彙数と一致しません")
        }
        var scored = vocabulary.indices.map { index in
            (index: index, label: vocabulary[index], score: scores[index].doubleValue)
        }
        guard scored.contains(where: { $0.score.isFinite && $0.score != 0 }) else {
            throw Inf6HandwrittenFormulaError.recognitionFailed("記号モデルが有効なスコアを返しませんでした")
        }
        scored.sort { $0.score > $1.score }
        guard let best = scored.first else {
            throw Inf6HandwrittenFormulaError.recognitionFailed("Core MLから候補記号を生成できませんでした")
        }
        let labels = scored.prefix(5).map(\.label)
        return Classification(label: best.label, rank: 1, labels: labels)
    }

    private static func features(
        for strokes: [PKStroke],
        in allStrokes: [PKStroke],
        cancellationCheck: @Sendable () -> Bool
    ) throws -> [Double] {
        try throwIfCancelled(cancellationCheck)
        let sample = try canonicalSample(for: strokes, allStrokes: allStrokes, cancellationCheck: cancellationCheck)
        return try featureVector(for: sample, cancellationCheck: cancellationCheck)
    }

    /// `inf6-glyph-shape-v2` features of one glyph. The definition lives in
    /// `Inf6GlyphFeatures` and is compared element by element against the
    /// training-side reference implementation.
    public static func featureVector(
        for sample: Inf6CanonicalSample,
        cancellationCheck: @Sendable () -> Bool = { false }
    ) throws -> [Double] {
        try throwIfCancelled(cancellationCheck)
        return try Inf6GlyphFeatures.features(for: sample)
    }

    /// Converts PencilKit strokes to the same serialized input contract used
    /// by the training-side InkML converter.
    public static func canonicalSample(
        for strokes: [PKStroke],
        allStrokes: [PKStroke],
        cancellationCheck: @Sendable () -> Bool
    ) throws -> Inf6CanonicalSample {
        let traces = strokes.map { Self.points(of: $0) }
        guard !traces.isEmpty, traces.allSatisfy({ !$0.isEmpty }) else {
            throw Inf6HandwrittenFormulaError.invalidInput("CanonicalSampleに空のストロークがあります")
        }
        guard traces.flatMap({ $0 }).allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw Inf6HandwrittenFormulaError.invalidInput("CanonicalSampleに有限でない座標があります")
        }
        let rowPoints = allStrokes.flatMap { Self.points(of: $0) }
        let glyphPoints = traces.flatMap { $0 }
        guard !rowPoints.isEmpty, !glyphPoints.isEmpty else {
            throw Inf6HandwrittenFormulaError.invalidInput("CanonicalSampleの行・記号範囲を計算できません")
        }
        let rowMinX = rowPoints.map(\.x).min()!
        let rowMinY = rowPoints.map(\.y).min()!
        let rowMaxX = rowPoints.map(\.x).max()!
        let rowMaxY = rowPoints.map(\.y).max()!
        let glyphMinX = glyphPoints.map(\.x).min()!
        let glyphMinY = glyphPoints.map(\.y).min()!
        let glyphMaxX = glyphPoints.map(\.x).max()!
        let glyphMaxY = glyphPoints.map(\.y).max()!
        try throwIfCancelled(cancellationCheck)
        let rowWidth = max(rowMaxX - rowMinX, 1)
        let rowHeight = max(rowMaxY - rowMinY, 1)
        return try Inf6CanonicalSample(
            traces: traces.map { trace in
                trace.map { Inf6CanonicalSample.Point(x: Double($0.x), y: Double($0.y)) }
            },
            strokeOrder: Array(strokes.indices),
            sourceBounds: Inf6CanonicalSample.Bounds(
                minX: Double(glyphMinX),
                minY: Double(glyphMinY),
                maxX: Double(glyphMaxX),
                maxY: Double(glyphMaxY)
            ),
            rowPosition: [
                Double((((glyphMinX + glyphMaxX) / 2) - rowMinX) / rowWidth),
                Double((((glyphMinY + glyphMaxY) / 2) - rowMinY) / rowHeight),
                Double((glyphMaxX - glyphMinX) / rowWidth),
                Double((glyphMaxY - glyphMinY) / rowHeight),
            ]
        )
    }

    /// Control points of a stroke in the drawing's coordinate space. `PKStroke.path`
    /// is expressed in the stroke's own space; `transform` maps it into the canvas,
    /// which is the space in which the row bounding box is defined.
    static func points(of stroke: PKStroke) -> [CGPoint] {
        stroke.path.map { $0.location.applying(stroke.transform) }
    }

    private static func throwIfCancelled(_ cancellationCheck: @Sendable () -> Bool) throws {
        if cancellationCheck() {
            throw Inf6HandwrittenFormulaError.cancelled
        }
    }
}

extension PKStroke {
    /// Bounding box of the stroke's transformed control points.
    ///
    /// The InkML-side training code measures glyph and row extents from point
    /// coordinates only. `renderBounds` adds the ink width and spline overshoot, which
    /// changes the ratios of thin strokes such as minus signs and fraction bars, so it
    /// must not be used for recognition geometry.
    var inf6PointBounds: CGRect {
        let points = Inf6NonAutoregressiveSymbolRecognizer.points(of: self)
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
