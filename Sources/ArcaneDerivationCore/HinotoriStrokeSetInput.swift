import CoreGraphics
import CoreML
import Foundation

/// The fixed input tensors for the fold-07 Hinotori stroke-set Core ML model.
///
/// The caller must provide exactly one already-segmented symbol stroke group.
/// This builder never infers symbol boundaries, joins groups, or truncates
/// strokes. Stroke order is retained in the 11 slots; unused slots are zero.
public struct HinotoriStrokeSetInput {
    /// Coordinate sources whose axes are X-right/Y-down with uniform X/Y units.
    /// Per-group translation and uniform scale are removed during canonicalization.
    public enum SourceCoordinateSpace: String, Sendable, Equatable {
        case mathWritingInkML
        case chatTextViewLocalPoints
    }

    public let inkRaster: MLMultiArray
    public let strokePoints: MLMultiArray
    public let reversedStrokePoints: MLMultiArray
    public let strokeValid: MLMultiArray
    public let sourceCoordinateSpace: SourceCoordinateSpace

    public struct RasterOnly {
        public let inkRaster: MLMultiArray
        public let sourceCoordinateSpace: SourceCoordinateSpace
    }

    private init(
        inkRaster: MLMultiArray,
        strokePoints: MLMultiArray,
        reversedStrokePoints: MLMultiArray,
        strokeValid: MLMultiArray,
        sourceCoordinateSpace: SourceCoordinateSpace
    ) {
        self.inkRaster = inkRaster
        self.strokePoints = strokePoints
        self.reversedStrokePoints = reversedStrokePoints
        self.strokeValid = strokeValid
        self.sourceCoordinateSpace = sourceCoordinateSpace
    }

    /// Builds the four named float32 tensors from one caller-designated symbol.
    ///
    /// `callerDesignatedSymbolStrokeGroup` is a single symbol group supplied
    /// by an upstream owner. Segmentation is intentionally outside this API.
    /// The coordinate source must have X-right/Y-down axes and uniform X/Y units;
    /// its source identity is retained on the result. Empty groups, empty strokes,
    /// non-finite/unrepresentable coordinates, and groups above the model's
    /// 11-stroke input limit fail explicitly.
    public static func build(
        sourceCoordinateSpace: SourceCoordinateSpace,
        callerDesignatedSymbolStrokeGroup strokes: [[CGPoint]]
    ) throws -> HinotoriStrokeSetInput {
        guard !strokes.isEmpty else { throw InputError.emptySymbolGroup }
        guard strokes.count <= strokeCount else {
            throw InputError.tooManyStrokes(actual: strokes.count, maximum: strokeCount)
        }

        let floatStrokes = try strokes.enumerated().map { strokeIndex, stroke -> [[Float]] in
            guard !stroke.isEmpty else { throw InputError.emptyStroke(index: strokeIndex) }
            return try stroke.enumerated().map { pointIndex, point in
                let x = Float(point.x)
                let y = Float(point.y)
                guard point.x.isFinite, point.y.isFinite, x.isFinite, y.isFinite else {
                    throw InputError.invalidCoordinate(stroke: strokeIndex, point: pointIndex)
                }
                return [x, y]
            }
        }

        let canonical = try canonicalGroup(floatStrokes)
        let raster = try rasterize(canonical)
        let rasterArray = try makeArray(shape: rasterShape)
        let pointsArray = try makeArray(shape: strokePointsShape)
        let reversedArray = try makeArray(shape: strokePointsShape)
        let validArray = try makeArray(shape: strokeValidShape)

        for y in 0..<rasterSize {
            for x in 0..<rasterSize {
                set(raster[y * rasterSize + x], in: rasterArray, at: [0, 0, y, x])
            }
        }
        for strokeIndex in canonical.indices {
            let samples = canonical[strokeIndex]
            for pointIndex in 0..<pointCount {
                let point = samples[pointIndex]
                let reversed = samples[pointCount - pointIndex - 1]
                set(point[0], in: pointsArray, at: [0, strokeIndex, pointIndex, 0])
                set(point[1], in: pointsArray, at: [0, strokeIndex, pointIndex, 1])
                set(reversed[0], in: reversedArray, at: [0, strokeIndex, pointIndex, 0])
                set(reversed[1], in: reversedArray, at: [0, strokeIndex, pointIndex, 1])
            }
            set(1, in: validArray, at: [0, strokeIndex])
        }

        return HinotoriStrokeSetInput(
            inkRaster: rasterArray,
            strokePoints: pointsArray,
            reversedStrokePoints: reversedArray,
            strokeValid: validArray,
            sourceCoordinateSpace: sourceCoordinateSpace
        )
    }

    /// Builds the 64×64 raster expected by Fold-07. The caller supplies one
    /// already-segmented symbol; this operation does not infer symbol boundaries.
    public static func buildRasterOnly(
        sourceCoordinateSpace: SourceCoordinateSpace,
        callerDesignatedSymbolStrokeGroup strokes: [[CGPoint]]
    ) throws -> RasterOnly {
        guard !strokes.isEmpty else { throw InputError.emptySymbolGroup }
        let floatStrokes = try strokes.enumerated().map { strokeIndex, stroke -> [[Float]] in
            guard !stroke.isEmpty else { throw InputError.emptyStroke(index: strokeIndex) }
            return try stroke.enumerated().map { pointIndex, point in
                let x = Float(point.x)
                let y = Float(point.y)
                guard point.x.isFinite, point.y.isFinite, x.isFinite, y.isFinite else {
                    throw InputError.invalidCoordinate(stroke: strokeIndex, point: pointIndex)
                }
                return [x, y]
            }
        }
        let raster = try rasterize(canonicalGroup(floatStrokes))
        let array = try makeArray(shape: rasterShape)
        for y in 0..<rasterSize {
            for x in 0..<rasterSize {
                set(raster[y * rasterSize + x], in: array, at: [0, 0, y, x])
            }
        }
        return RasterOnly(inkRaster: array, sourceCoordinateSpace: sourceCoordinateSpace)
    }

    public enum InputError: LocalizedError {
        case emptySymbolGroup
        case emptyStroke(index: Int)
        case tooManyStrokes(actual: Int, maximum: Int)
        case invalidCoordinate(stroke: Int, point: Int)
        case invalidCanonicalGeometry
        case canonicalCoordinateOutOfRange
        case tensorAllocation(String)

        public var errorDescription: String? {
            switch self {
            case .emptySymbolGroup:
                return "Hinotori入力には、呼び出し側が指定した一記号分のストロークが必要です"
            case .emptyStroke(let index):
                return "Hinotori入力のストローク\(index)に座標点がありません"
            case .tooManyStrokes(let actual, let maximum):
                return "Hinotoriの一記号入力は最大\(maximum)ストロークですが、\(actual)本あります。切り捨ては行いません"
            case .invalidCoordinate(let stroke, let point):
                return "Hinotori入力のストローク\(stroke)、点\(point)にfloat32で表現できない座標があります"
            case .invalidCanonicalGeometry:
                return "Hinotoriの正規化または再サンプリングで有限な座標を生成できません"
            case .canonicalCoordinateOutOfRange:
                return "Hinotoriの正規化座標が学習済み範囲[-0.5001, 0.5001]を外れました"
            case .tensorAllocation(let reason):
                return "Hinotori float32入力テンソルを確保できません: \(reason)"
            }
        }
    }

    private static let rasterSize = 64
    private static let strokeCount = 11
    private static let pointCount = 128
    private static let rasterShape = [1, 1, rasterSize, rasterSize]
    private static let strokePointsShape = [1, strokeCount, pointCount, 2]
    private static let strokeValidShape = [1, strokeCount]

    /// Mirrors hinotori_inkml.canonical_group_tensor using float32 arithmetic.
    private static func canonicalGroup(_ strokes: [[[Float]]]) throws -> [[[Float]]] {
        let allPoints = strokes.flatMap { $0 }
        guard let first = allPoints.first else { throw InputError.emptySymbolGroup }
        var minimum = first
        var maximum = first
        for point in allPoints.dropFirst() {
            minimum[0] = min(minimum[0], point[0])
            minimum[1] = min(minimum[1], point[1])
            maximum[0] = max(maximum[0], point[0])
            maximum[1] = max(maximum[1], point[1])
        }

        let extent = max(maximum[0] - minimum[0], maximum[1] - minimum[1])
        guard extent.isFinite else { throw InputError.invalidCanonicalGeometry }
        if extent == 0 {
            return strokes.map { stroke in
                Array(repeating: [Float.zero, Float.zero], count: pointCount)
            }
        }

        let centerX = (minimum[0] + maximum[0]) / 2
        let centerY = (minimum[1] + maximum[1]) / 2
        guard centerX.isFinite, centerY.isFinite, extent > 0 else {
            throw InputError.invalidCanonicalGeometry
        }

        return try strokes.map { stroke in
            let normalized = stroke.map { point in
                [(point[0] - centerX) / extent, (point[1] - centerY) / extent]
            }
            guard normalized.allSatisfy({ $0[0].isFinite && $0[1].isFinite }) else {
                throw InputError.invalidCanonicalGeometry
            }
            let sampled = try resampleStroke(normalized)
            guard sampled.allSatisfy({
                $0[0].isFinite && $0[1].isFinite && abs($0[0]) <= 0.5001 && abs($0[1]) <= 0.5001
            }) else {
                throw InputError.canonicalCoordinateOutOfRange
            }
            return sampled
        }
    }

    /// Arc-length resampling with consecutive zero-length segments removed.
    private static func resampleStroke(_ points: [[Float]]) throws -> [[Float]] {
        guard let first = points.first else { throw InputError.invalidCanonicalGeometry }
        if points.count == 1 { return Array(repeating: first, count: pointCount) }

        var lengths: [Float] = []
        lengths.reserveCapacity(points.count - 1)
        for index in 1..<points.count {
            let dx = points[index][0] - points[index - 1][0]
            let dy = points[index][1] - points[index - 1][1]
            let length = (dx * dx + dy * dy).squareRoot()
            guard length.isFinite else { throw InputError.invalidCanonicalGeometry }
            lengths.append(length)
        }

        var distinct = [points[0]]
        for index in lengths.indices where lengths[index] > 0 {
            distinct.append(points[index + 1])
        }
        if distinct.count == 1 { return Array(repeating: distinct[0], count: pointCount) }

        var cumulative: [Float] = [0]
        cumulative.reserveCapacity(distinct.count)
        for index in 1..<distinct.count {
            let dx = distinct[index][0] - distinct[index - 1][0]
            let dy = distinct[index][1] - distinct[index - 1][1]
            let length = (dx * dx + dy * dy).squareRoot()
            let next = cumulative[cumulative.count - 1] + length
            guard length.isFinite, next.isFinite else { throw InputError.invalidCanonicalGeometry }
            cumulative.append(next)
        }
        guard let total = cumulative.last, total.isFinite else { throw InputError.invalidCanonicalGeometry }
        if total == 0 { return Array(repeating: distinct[0], count: pointCount) }

        let step = total / Float(pointCount - 1)
        var result: [[Float]] = []
        result.reserveCapacity(pointCount)
        for sampleIndex in 0..<pointCount {
            let target = sampleIndex == pointCount - 1 ? total : Float(sampleIndex) * step
            var low = 0
            var high = cumulative.count
            // torch.searchsorted(..., right: true): equal boundaries select
            // the segment after the boundary, then clamp to a valid segment.
            while low < high {
                let middle = low + (high - low) / 2
                if cumulative[middle] <= target {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            let upper = min(max(low, 1), distinct.count - 1)
            let lower = upper - 1
            let segment = cumulative[upper] - cumulative[lower]
            guard segment > 0, segment.isFinite else { throw InputError.invalidCanonicalGeometry }
            let weight = (target - cumulative[lower]) / segment
            let x = distinct[lower][0] + weight * (distinct[upper][0] - distinct[lower][0])
            let y = distinct[lower][1] + weight * (distinct[upper][1] - distinct[lower][1])
            guard weight.isFinite, x.isFinite, y.isFinite else { throw InputError.invalidCanonicalGeometry }
            result.append([x, y])
        }
        return result
    }

    /// Mirrors hinotori_raster_classifier.rasterize_group and its 3x3 max-pool.
    private static func rasterize(_ points: [[[Float]]]) throws -> [Float] {
        var centerline = Array(repeating: false, count: rasterSize * rasterSize)
        for stroke in points {
            guard !stroke.isEmpty else { throw InputError.invalidCanonicalGeometry }
            let pixels = try stroke.map { point -> (x: Int, y: Int) in
                guard point[0].isFinite, point[1].isFinite,
                      abs(point[0]) <= 0.5001, abs(point[1]) <= 0.5001 else {
                    throw InputError.canonicalCoordinateOutOfRange
                }
                // torch.round uses round-to-nearest, ties-to-even.
                let xValue = ((point[0] + 0.5) * Float(rasterSize - 3) + 1)
                    .rounded(.toNearestOrEven)
                let yValue = ((point[1] + 0.5) * Float(rasterSize - 3) + 1)
                    .rounded(.toNearestOrEven)
                guard xValue.isFinite, yValue.isFinite,
                      xValue >= 0, xValue < Float(rasterSize),
                      yValue >= 0, yValue < Float(rasterSize) else {
                    throw InputError.invalidCanonicalGeometry
                }
                return (Int(xValue), Int(yValue))
            }

            if pixels.count == 1 {
                centerline[pixels[0].y * rasterSize + pixels[0].x] = true
                continue
            }
            for index in 0..<(pixels.count - 1) {
                var start = pixels[index]
                var end = pixels[index + 1]
                if start.x > end.x || (start.x == end.x && start.y > end.y) {
                    swap(&start, &end)
                }
                let dx = end.x - start.x
                let dy = end.y - start.y
                let steps = max(max(abs(dx), abs(dy)), 1)
                for stepIndex in 0...steps {
                    let t = Double(stepIndex) / Double(steps)
                    let x = Int((Double(start.x) + Double(dx) * t).rounded(.toNearestOrEven))
                    let y = Int((Double(start.y) + Double(dy) * t).rounded(.toNearestOrEven))
                    guard (0..<rasterSize).contains(x), (0..<rasterSize).contains(y) else {
                        throw InputError.invalidCanonicalGeometry
                    }
                    centerline[y * rasterSize + x] = true
                }
            }
        }

        var dilated = Array(repeating: Float.zero, count: rasterSize * rasterSize)
        for y in 0..<rasterSize {
            for x in 0..<rasterSize where centerline[y * rasterSize + x] {
                for neighborY in max(0, y - 1)...min(rasterSize - 1, y + 1) {
                    for neighborX in max(0, x - 1)...min(rasterSize - 1, x + 1) {
                        dilated[neighborY * rasterSize + neighborX] = 1
                    }
                }
            }
        }
        return dilated
    }

    private static func makeArray(shape: [Int]) throws -> MLMultiArray {
        do {
            let array = try MLMultiArray(shape: shape.map(NSNumber.init(value:)), dataType: .float32)
            guard array.dataType == .float32, array.shape.map(\.intValue) == shape else {
                throw InputError.tensorAllocation("Core MLが要求shapeまたはdtypeの配列を返しませんでした")
            }
            return array
        } catch let error as InputError {
            throw error
        } catch {
            throw InputError.tensorAllocation(error.localizedDescription)
        }
    }

    private static func set(_ value: Float, in array: MLMultiArray, at indices: [Int]) {
        let strides = array.strides.map(\.intValue)
        let offset = zip(indices, strides).reduce(0) { partial, pair in
            partial + pair.0 * pair.1
        }
        array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)[offset] = value
    }
}
