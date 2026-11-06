import Foundation

/// Feature contract `inf6-glyph-shape-v2`.
///
/// This mirrors `inf6-training/inf6_glyph_features.py` operation for operation
/// (same loop order and tie rules) so that the Python reference and the app can
/// be compared element by element on a shared fixture.
///
/// Input is an `Inf6CanonicalSample`: ordered strokes of finite x/y points in the
/// source coordinate system (InkML units or PencilKit view points, y downward in
/// both). The vector describes shape only: no raster grid and no position. Position
/// was measured to push composed x^2 drawings out of the training distribution, so
/// spatial relations are decided outside this classifier.
public enum Inf6GlyphFeatures {
    public static let featureVersion = "inf6-glyph-shape-v2"
    public static let pointsPerStroke = 12
    public static let maxStrokeSlots = 4
    public static let strokeBlock = 2 * pointsPerStroke + 2
    public static let featureDimension = maxStrokeSlots * strokeBlock + maxStrokeSlots + 2

    typealias P = (x: Double, y: Double)

    public static func features(for sample: Inf6CanonicalSample) throws -> [Double] {
        let strokes: [[P]] = sample.traces.map { $0.map { (x: $0.x, y: $0.y) } }
        let vector = try shapeFeatures(strokes)
        guard vector.count == featureDimension else {
            throw Inf6HandwrittenFormulaError.invalidModelInterface("特徴量次元\(vector.count)が契約の\(featureDimension)と一致しません")
        }
        return vector
    }

    static func shapeFeatures(_ input: [[P]]) throws -> [Double] {
        guard !input.isEmpty, input.allSatisfy({ !$0.isEmpty }) else {
            throw Inf6HandwrittenFormulaError.invalidInput("空のストロークがあります")
        }
        guard input.allSatisfy({ $0.allSatisfy { $0.x.isFinite && $0.y.isFinite } }) else {
            throw Inf6HandwrittenFormulaError.invalidInput("有限でない座標があります")
        }
        var strokes = input
        if strokes.count > maxStrokeSlots {
            let head = Array(strokes[0..<(maxStrokeSlots - 1)])
            let tail = strokes[(maxStrokeSlots - 1)...].flatMap { $0 }
            strokes = head + [tail]
        }
        let all = strokes.flatMap { $0 }
        let xs = all.map { $0.x }
        let ys = all.map { $0.y }
        let x0 = xs.min()!, x1 = xs.max()!
        let y0 = ys.min()!, y1 = ys.max()!
        let w = x1 - x0, h = y1 - y0
        var scale = max(w, h)
        if scale <= 0 { scale = 1 }
        let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2
        let lengths = strokes.map(polylineLength)
        var total = lengths.reduce(0, +)
        if total <= 0 { total = 1 }
        var out: [Double] = []
        out.reserveCapacity(featureDimension)
        for k in 0..<maxStrokeSlots {
            if k < strokes.count {
                for p in resample(strokes[k], count: pointsPerStroke) {
                    out.append((p.x - cx) / scale)
                    out.append((p.y - cy) / scale)
                }
                out.append(lengths[k] / total)
                out.append(1)
            } else {
                out.append(contentsOf: [Double](repeating: 0, count: strokeBlock))
            }
        }
        for k in 0..<maxStrokeSlots { out.append(k == strokes.count - 1 ? 1 : 0) }
        out.append(w / scale)
        out.append(h / scale)
        return out
    }

    static func polylineLength(_ points: [P]) -> Double {
        guard points.count > 1 else { return 0 }
        var sum = 0.0
        for i in 1..<points.count {
            sum += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
        }
        return sum
    }

    /// `count` points at equal arc-length spacing, end points included.
    static func resample(_ points: [P], count: Int) -> [P] {
        if points.count == 1 { return [P](repeating: points[0], count: count) }
        var dist = [0.0]
        for i in 1..<points.count {
            dist.append(dist[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
        }
        let total = dist[dist.count - 1]
        if total <= 0 { return [P](repeating: points[0], count: count) }
        var out: [P] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let target = total * Double(i) / Double(count - 1)
            let upper = dist.firstIndex(where: { $0 >= target }) ?? (dist.count - 1)
            if upper == 0 { out.append(points[0]); continue }
            let lower = upper - 1
            let span = dist[upper] - dist[lower]
            let ratio = span > 0 ? (target - dist[lower]) / span : 0
            out.append((x: points[lower].x + (points[upper].x - points[lower].x) * ratio,
                        y: points[lower].y + (points[upper].y - points[lower].y) * ratio))
        }
        return out
    }
}
