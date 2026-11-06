import CoreGraphics
import Foundation

public struct YOLODocumentRegion: Equatable, Sendable {
    public let kind: CropKind
    public let normalizedRect: CGRect
    public let componentLabels: [String]

    public init(kind: CropKind, normalizedRect: CGRect, componentLabels: [String]) {
        self.kind = kind
        self.normalizedRect = normalizedRect
        self.componentLabels = componentLabels
    }
}

public struct YOLODocumentRegionAssembler: Sendable {
    public var maximumVerticalGap: CGFloat
    public var minimumHorizontalOverlap: CGFloat

    public init(maximumVerticalGap: CGFloat = 0.08, minimumHorizontalOverlap: CGFloat = 0.25) {
        self.maximumVerticalGap = maximumVerticalGap
        self.minimumHorizontalOverlap = minimumHorizontalOverlap
    }

    public func assemble(_ detections: [YOLODetection]) -> [YOLODocumentRegion] {
        var unused = Set(detections.map(\.id))
        var regions: [YOLODocumentRegion] = []

        for body in detections.sorted(by: { $0.normalizedRect.minY < $1.normalizedRect.minY }) {
            guard unused.contains(body.id), let kind = cropKind(for: body.label) else { continue }
            var rect = body.normalizedRect
            var labels = [body.label]
            unused.remove(body.id)

            let related = detections.filter { candidate in
                guard unused.contains(candidate.id), isContextLabel(candidate.label) else { return false }
                return horizontalOverlap(body.normalizedRect, candidate.normalizedRect) >= minimumHorizontalOverlap
                    && verticalGap(body.normalizedRect, candidate.normalizedRect) <= maximumVerticalGap
            }
            for candidate in related {
                rect = rect.union(candidate.normalizedRect)
                labels.append(candidate.label)
                unused.remove(candidate.id)
            }
            regions.append(YOLODocumentRegion(kind: kind, normalizedRect: rect, componentLabels: labels))
        }
        return regions
    }

    private func cropKind(for label: String) -> CropKind? {
        switch label.lowercased() {
        case "picture": return .figure
        case "table": return .table
        case "formula": return .equation
        default: return nil
        }
    }

    private func isContextLabel(_ label: String) -> Bool {
        ["caption", "title"].contains(label.lowercased())
    }

    private func horizontalOverlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let overlap = max(0, min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX))
        return overlap / max(1, min(lhs.width, rhs.width))
    }

    private func verticalGap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        if lhs.intersects(rhs) { return 0 }
        return max(0, max(lhs.minY, rhs.minY) - min(lhs.maxY, rhs.maxY))
    }
}
