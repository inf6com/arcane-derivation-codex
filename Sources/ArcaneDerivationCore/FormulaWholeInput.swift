import CoreGraphics
import Foundation
#if canImport(PencilKit)
import PencilKit
#endif

/// `FormulaInput v1` — the whole-formula input contract shared by the
/// training-side InkML parser (`ModelConversion/formula_whole_input.py`) and
/// the app's `PKDrawing`.
///
/// This is a full replacement for the earlier per-glyph pipeline
/// (`Inf6GlyphFeatures`, `Inf6FormulaGrid9`, `Inf6NonAutoregressiveSymbolRecognizer`):
/// per `ModelConversion/HandwrittenFormulaRecognitionDesign.md` and
/// `Design/InlineFormulaInputDesign.md`, the
/// whole-formula model takes every `PKStroke` as one ordered set of traces and
/// learns segmentation, order, and structure itself. This file does not
/// group strokes, assign cells, or classify individual glyphs.
public enum Inf6FormulaWholeInput {
    public static let specVersion = "inf6-formula-input-v1"
    public static let modelFeatureDType = "float32"
    public static let modelFeatureDimension = 2
    /// Must match `ModelConversion.formula_whole_model.POINTS_PER_TRACE`.
    /// Earlier 32- and 64-point models are intentionally not compatible.
    public static let modelPointsPerTrace = 128
    public static let maxModelTraces = 80
    public static let modelInputContractVersion = "inf6-formula-whole-trace-v3-128pt"
    /// v4 candidate side tensor. v3 remains the only runtime model contract
    /// until a separately trained candidate passes the exact-match gate.
    public static let traceGeometryContractVersion = "inf6-formula-whole-trace-geometry-v4-9f"
    public static let traceGeometryFeatureDimension = 9

    public struct Point: Codable, Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let t: Double?

        public init(x: Double, y: Double, t: Double?) {
            self.x = x
            self.y = y
            self.t = t
        }
    }

    public struct Bounds: Codable, Equatable, Sendable {
        public let minX: Double
        public let minY: Double
        public let maxX: Double
        public let maxY: Double
    }

    public struct CoordinateSpec: Codable, Equatable, Sendable {
        public let origin: String
        public let axis: String
        public let unit: String
        public let scale: String
        public let timeUnit: String?
        /// Mirrors the Python side's own `parityStatus` field verbatim. Both
        /// sides report the same string so a downstream comparison never has
        /// to guess whether parity has actually been measured; it has not.
        public let parityStatus: String
    }

    public struct FormulaInput: Codable, Equatable, Sendable {
        public let traces: [[Point]]
        public let traceOrder: [Int]
        public let sourceBounds: Bounds
        public let coordinateSpec: CoordinateSpec
        public let specVersion: String
    }

    /// Returns the exact ragged model input: one trace axis, one point axis,
    /// and two float32 features per point (`x`, `y`). T is retained in the
    /// evidence record but is intentionally excluded from model features until
    /// InkML/PencilKit time semantics are proven equivalent.
    public static func modelFeatures(from input: FormulaInput) -> [[[Float]]] {
        input.traces.map { trace in
            trace.map { point in [Float(point.x), Float(point.y)] }
        }
    }

    /// Produces the v4 per-trace geometry side tensor in write order. The
    /// values are minX, minY, maxX, maxY, arithmetic point-centroid X/Y,
    /// extent X/Y, and normalized trace-write progress. It consumes only the
    /// normalized FormulaInput coordinates; stroke time is deliberately not
    /// admitted because InkML/PencilKit time parity is unverified.
    public static func traceGeometryFeatures(from input: FormulaInput) throws -> [[Float]] {
        guard !input.traces.isEmpty else { throw FormulaWholeInputError.emptyDrawing }
        guard input.traces.count <= maxModelTraces else {
            throw FormulaWholeInputError.tooManyTraces(actual: input.traces.count)
        }
        let denominator = Double(max(input.traces.count - 1, 1))
        return try input.traces.enumerated().map { index, trace in
            guard !trace.isEmpty else { throw FormulaWholeInputError.emptyTrace }
            let xs = trace.map(\.x)
            let ys = trace.map(\.y)
            let minX = xs.min()!
            let maxX = xs.max()!
            let minY = ys.min()!
            let maxY = ys.max()!
            let centroidX = xs.reduce(0, +) / Double(xs.count)
            let centroidY = ys.reduce(0, +) / Double(ys.count)
            return [
                Float(minX), Float(minY), Float(maxX), Float(maxY),
                Float(centroidX), Float(centroidY), Float(maxX - minX), Float(maxY - minY),
                Float(Double(index) / denominator),
            ]
        }
    }

    /// Converts the normalized ragged evidence input into the fixed tensor
    /// contract required by the selected 128-point whole-formula model.
    /// The app has no embedded model for this contract yet; this function is
    /// deliberately limited to producing the exact input artifact and never
    /// substitutes an earlier point-count model or a legacy recognizer.
    public static func modelTensorFeatures(from input: FormulaInput) throws -> [[[Float]]] {
        guard input.traces.count <= maxModelTraces else {
            throw FormulaWholeInputError.tooManyTraces(actual: input.traces.count)
        }
        return modelFeatures(from: input).map { resampleModelTrace($0, count: modelPointsPerTrace) }
    }

    public enum FormulaWholeInputError: LocalizedError {
        case emptyDrawing
        case emptyTrace
        case nonFiniteCoordinate
        case tooManyTraces(actual: Int)

        public var errorDescription: String? {
            switch self {
            case .emptyDrawing: return "チャット編集欄から数式認識へ渡されたストロークがありません"
            case .emptyTrace: return "空のストロークがあります"
            case .nonFiniteCoordinate: return "有限でない座標があります"
            case .tooManyTraces(let actual): return "ストローク数\(actual)が数式モデル上限\(maxModelTraces)を超えています"
            }
        }
    }

    private static func resampleModelTrace(_ points: [[Float]], count: Int) -> [[Float]] {
        precondition(count >= 2, "model point count must be at least two")
        precondition(points.allSatisfy { $0.count == modelFeatureDimension }, "invalid model feature dimension")
        guard let first = points.first else { preconditionFailure("input traces cannot be empty") }
        if points.count == 1 { return Array(repeating: first, count: count) }

        var distances: [Float] = [0]
        distances.reserveCapacity(points.count)
        for index in 1..<points.count {
            let dx = points[index][0] - points[index - 1][0]
            let dy = points[index][1] - points[index - 1][1]
            distances.append(distances[distances.count - 1] + sqrt(dx * dx + dy * dy))
        }
        guard let total = distances.last, total > 0 else { return Array(repeating: first, count: count) }

        return (0..<count).map { index in
            let target = total * Float(index) / Float(count - 1)
            let upper = distances.firstIndex(where: { $0 >= target }) ?? (points.count - 1)
            guard upper > 0 else { return first }
            let lower = upper - 1
            let span = distances[upper] - distances[lower]
            let ratio = span > 0 ? (target - distances[lower]) / span : 0
            return [
                points[lower][0] + (points[upper][0] - points[lower][0]) * ratio,
                points[lower][1] + (points[upper][1] - points[lower][1]) * ratio,
            ]
        }
    }

    /// Builds `FormulaInput v1` from every `PKStroke` in the drawing, in the
    /// order they were written. Never sorts, groups, or drops a stroke.
    #if canImport(PencilKit)
    public static func make(from drawing: PKDrawing) throws -> FormulaInput {
        try make(from: drawing.strokes)
    }

    public static func make(from strokes: [PKStroke]) throws -> FormulaInput {
        guard !strokes.isEmpty else { throw FormulaWholeInputError.emptyDrawing }
        let traces: [[(x: Double, y: Double, t: Double?)]] = strokes.map { stroke in
            stroke.path.map { strokePoint in
                let location = strokePoint.location.applying(stroke.transform)
                return (x: Double(location.x), y: Double(location.y), t: Double(strokePoint.timeOffset))
            }
        }
        return try make(fromRawTraces: traces)
    }
    #endif

    /// Core normalization, factored out of the PencilKit-specific entry point
    /// so it can be exercised directly from a fixed-point fixture (no
    /// `PKStroke` construction required) and compared element by element
    /// against `formula_whole_input.load_formula_input`.
    static func make(fromRawTraces traces: [[(x: Double, y: Double, t: Double?)]]) throws -> FormulaInput {
        guard !traces.isEmpty else { throw FormulaWholeInputError.emptyDrawing }
        guard traces.allSatisfy({ !$0.isEmpty }) else { throw FormulaWholeInputError.emptyTrace }
        guard traces.allSatisfy({ $0.allSatisfy { $0.x.isFinite && $0.y.isFinite } }) else {
            throw FormulaWholeInputError.nonFiniteCoordinate
        }

        let allPoints = traces.flatMap { $0 }
        let xMin = allPoints.map { $0.x }.min()!
        let xMax = allPoints.map { $0.x }.max()!
        let yMin = allPoints.map { $0.y }.min()!
        let yMax = allPoints.map { $0.y }.max()!

        let xSpan = xMax - xMin
        let ySpan = yMax - yMin
        let squareSpan = max(xSpan, ySpan)
        // Match formula_whole_input.py: one isotropic scale plus centered
        // padding preserves the source aspect ratio. A constant axis is
        // represented at the center instead of dividing by zero.
        let xPadding = squareSpan == 0 ? 0 : (squareSpan - xSpan) / (2 * squareSpan)
        let yPadding = squareSpan == 0 ? 0 : (squareSpan - ySpan) / (2 * squareSpan)
        func normalized(_ value: Double, _ lower: Double, _ padding: Double) -> Double {
            return squareSpan == 0 ? 0.5 : (value - lower) / squareSpan + padding
        }

        let normalizedTraces = traces.map { trace in
            trace.map { point in
                Point(
                    x: normalized(point.x, xMin, xPadding),
                    y: normalized(point.y, yMin, yPadding),
                    t: point.t
                )
            }
        }

        return FormulaInput(
            traces: normalizedTraces,
            traceOrder: Array(traces.indices),
            sourceBounds: Bounds(minX: xMin, minY: yMin, maxX: xMax, maxY: yMax),
            coordinateSpec: CoordinateSpec(
                origin: "source-bounds-min",
                axis: "x-right,y-down",
                unit: "PencilKit view points",
                scale: "isotropic-bounds-to-[0,1]-square-with-centered-padding",
                // `PKStrokePoint.timeOffset` is seconds since that stroke's
                // own first point, not since the drawing started, and
                // InkML's T channel semantics for MathWriting-2024 have not
                // been inspected. The value is carried through unnormalized
                // (matching the Python side, which never rescales T either)
                // but must not be treated as parity-verified.
                timeUnit: "PKStrokePoint.timeOffset seconds (stroke-relative; UNVERIFIED_WITH_INKML)",
                parityStatus: "UNVERIFIED_WITH_PENCILKIT"
            ),
            specVersion: specVersion
        )
    }
}
