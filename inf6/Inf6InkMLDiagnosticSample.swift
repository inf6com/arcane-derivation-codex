import PencilKit
import UIKit

/// One real InkML stroke copied from MathWriting-2024 valid sample
/// d96a9353dc9648f2. It is used only to compare the training stroke with the
/// same PencilKit surface; it is not a replacement for the training corpus.
enum InkMLDiagnosticSample {
    static func drawing() -> PKDrawing {
        let points: [CGPoint] = [
            CGPoint(x: 580, y: 146), CGPoint(x: 552, y: 205),
            CGPoint(x: 526, y: 252), CGPoint(x: 480, y: 318),
            CGPoint(x: 425, y: 380), CGPoint(x: 397, y: 425),
            CGPoint(x: 398, y: 435), CGPoint(x: 445, y: 446),
            CGPoint(x: 514, y: 444), CGPoint(x: 592, y: 448),
            CGPoint(x: 637, y: 457), CGPoint(x: 640, y: 453),
            CGPoint(x: 629, y: 407), CGPoint(x: 625, y: 359),
            CGPoint(x: 620, y: 309), CGPoint(x: 611, y: 265),
            CGPoint(x: 604, y: 231), CGPoint(x: 597, y: 194),
            CGPoint(x: 594, y: 182), CGPoint(x: 597, y: 173)
        ]
        let controlPoints = points.enumerated().map { index, point in
            PKStrokePoint(
                location: point,
                timeOffset: TimeInterval(index) * 0.05,
                size: CGSize(width: 3, height: 3),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        let path = PKStrokePath(controlPoints: controlPoints, creationDate: .now)
        let stroke = PKStroke(ink: PKInk(.pen, color: .systemBlue), path: path)
        return PKDrawing(strokes: [stroke])
    }
}
