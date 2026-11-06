import CoreGraphics
import Foundation
#if canImport(PencilKit)
import PencilKit
#endif

public struct Inf6FormulaGrid9: Codable, Equatable, Sendable {
    public enum SpatialRelation: Equatable, Sendable {
        case superscript
        case `subscript`
    }

    public struct Cell: Codable, Equatable, Sendable {
        public let index: Int
        public let row: Int
        public let column: Int
        public let strokeCount: Int
        public let strokeIndices: [Int]
        public let normalizedBounds: CGRect

        private enum CodingKeys: String, CodingKey {
            case index, row, column, strokeCount, strokeIndices, normalizedBounds
        }

        public init(
            index: Int,
            row: Int,
            column: Int,
            strokeCount: Int,
            strokeIndices: [Int] = [],
            normalizedBounds: CGRect
        ) {
            self.index = index
            self.row = row
            self.column = column
            self.strokeCount = strokeCount
            self.strokeIndices = strokeIndices
            self.normalizedBounds = normalizedBounds
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            index = try values.decode(Int.self, forKey: .index)
            row = try values.decode(Int.self, forKey: .row)
            column = try values.decode(Int.self, forKey: .column)
            strokeCount = try values.decode(Int.self, forKey: .strokeCount)
            strokeIndices = try values.decodeIfPresent([Int].self, forKey: .strokeIndices) ?? []
            normalizedBounds = try values.decode(CGRect.self, forKey: .normalizedBounds)
        }
    }

    public let cells: [Cell]

    public var occupiedCellIndices: [Int] {
        cells.filter { $0.strokeCount > 0 }.map(\.index)
    }

    public var isStructurallyValid: Bool {
        guard cells.count == 9 else { return false }
        guard Set(cells.map(\.index)) == Set(1...9) else { return false }
        return cells.allSatisfy { cell in
            cell.row == (cell.index - 1) / 3
                && cell.column == (cell.index - 1) % 3
                && cell.strokeCount == cell.strokeIndices.count
                && cell.strokeCount >= 0
                && cell.normalizedBounds.minX >= 0
                && cell.normalizedBounds.minY >= 0
                && cell.normalizedBounds.maxX <= 1
                && cell.normalizedBounds.maxY <= 1
        }
    }

    /// Returns the MathML-relevant relation for two occupied positions.
    /// The first cell is the base candidate and the second is the attached candidate.
    public func relation(from base: Cell, to attached: Cell) -> SpatialRelation? {
        guard base.index != attached.index else { return nil }
        let horizontalDistance = attached.column - base.column
        guard abs(horizontalDistance) <= 1 else { return nil }
        if attached.row < base.row, horizontalDistance >= 0 {
            return .superscript
        }
        if attached.row > base.row, horizontalDistance >= 0 {
            return .`subscript`
        }
        return nil
    }

    public init(cells: [Cell]) { self.cells = cells }

#if canImport(PencilKit)
    public static func analyze(
        drawing: PKDrawing,
        centerFraction: CGFloat = 0.44,
        surfaceSize: CGSize? = nil
    ) throws -> Inf6FormulaGrid9 {
        guard (0.20...0.70).contains(centerFraction) else {
            throw NSError(domain: "Inf6FormulaGrid9", code: 3, userInfo: [NSLocalizedDescriptionKey: "中央セルの大きさが範囲外です。"])
        }
        let strokes = drawing.strokes
        guard !strokes.isEmpty else { throw NSError(domain: "Inf6FormulaGrid9", code: 1, userInfo: [NSLocalizedDescriptionKey: "手書き入力がありません。"]) }
        let allPoints = strokes.flatMap { Inf6NonAutoregressiveSymbolRecognizer.points(of: $0) }
        guard let minX = allPoints.map(\.x).min(), let maxX = allPoints.map(\.x).max(),
              let minY = allPoints.map(\.y).min(), let maxY = allPoints.map(\.y).max(),
              maxX > minX || maxY > minY else {
            throw NSError(domain: "Inf6FormulaGrid9", code: 2, userInfo: [NSLocalizedDescriptionKey: "手書き入力の領域が不正です。"])
        }
        let width = maxX - minX
        let height = maxY - minY
        let coordinateWidth = surfaceSize.map(\.width).flatMap { $0 > 0 ? $0 : nil } ?? width
        let coordinateHeight = surfaceSize.map(\.height).flatMap { $0 > 0 ? $0 : nil } ?? height
        let margin = (1 - centerFraction) / 2
        let edges: [CGFloat] = [0, margin, 1 - margin, 1]
        var strokeIndices = Array(repeating: [Int](), count: 9)
        for (strokeIndex, stroke) in strokes.enumerated() {
            let box = stroke.inf6PointBounds
            let center = CGPoint(x: box.midX, y: box.midY)
            // A vertical or horizontal glyph is valid input. If its extent is
            // zero on one axis, place it on the center axis rather than
            // rejecting it as a malformed drawing. A point with zero extent
            // on both axes remains invalid above.
            let normalizedX: CGFloat
            let normalizedY: CGFloat
            if surfaceSize == nil {
                // A vertical glyph has no measured width and a horizontal
                // glyph has no measured height. A degenerate axis is the
                // center axis, not the first grid column or row.
                normalizedX = width > 0 ? CGFloat((center.x - minX) / width) : 0.5
                normalizedY = height > 0 ? CGFloat((center.y - minY) / height) : 0.5
            } else {
                normalizedX = CGFloat(center.x / coordinateWidth)
                normalizedY = CGFloat(center.y / coordinateHeight)
            }
            let column = min(2, max(0, edges.dropLast().lastIndex(where: { normalizedX >= $0 }) ?? 0))
            let row = min(2, max(0, edges.dropLast().lastIndex(where: { normalizedY >= $0 }) ?? 0))
            strokeIndices[row * 3 + column].append(strokeIndex)
        }
        let cells = (0..<9).map { index -> Cell in
            let row = index / 3
            let column = index % 3
            return Cell(
                index: index + 1,
                row: row,
                column: column,
                strokeCount: strokeIndices[index].count,
                strokeIndices: strokeIndices[index],
                normalizedBounds: CGRect(x: edges[column], y: edges[row], width: edges[column + 1] - edges[column], height: edges[row + 1] - edges[row])
            )
        }
        return Inf6FormulaGrid9(cells: cells)
    }
#endif
}
