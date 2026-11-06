import CoreML
import Foundation

public struct YOLODetection: Equatable, Sendable {
    public let id: UUID
    public let label: String
    public let confidence: Double
    public let normalizedRect: CGRect

    public init(id: UUID = UUID(), label: String, confidence: Double, normalizedRect: CGRect) {
        self.id = id
        self.label = label
        self.confidence = confidence
        self.normalizedRect = normalizedRect
    }
}

public enum YOLODecoderError: LocalizedError {
    case unsupportedShape([Int])
    case invalidCoordinate(String)
    case invalidClassCount

    public var errorDescription: String? {
        switch self {
        case .unsupportedShape(let shape): return "YOLO出力のshapeに対応していません: \(shape)"
        case .invalidCoordinate(let name): return "YOLO出力の\(name)が正規化範囲外です。"
        case .invalidClassCount: return "YOLOクラス名が空です。"
        }
    }
}

public struct YOLODetectionDecoder {
    public let labels: [String]
    public let confidenceThreshold: Double
    public let iouThreshold: Double

    public init(labels: [String], confidenceThreshold: Double = 0.25, iouThreshold: Double = 0.45) throws {
        guard !labels.isEmpty else { throw YOLODecoderError.invalidClassCount }
        self.labels = labels
        self.confidenceThreshold = confidenceThreshold
        self.iouThreshold = iouThreshold
    }

    /// Decodes YOLO output with shape [1, 4 + classCount, candidateCount]
    /// or [1, candidateCount, 4 + classCount]. Each candidate stores normalized
    /// centerX, centerY, width, height, then class scores.
    public func decode(_ output: MLMultiArray) throws -> [YOLODetection] {
        let shape = output.shape.map { $0.intValue }
        let channelCount = 4 + labels.count
        guard shape.count == 3, shape[0] == 1,
              (shape[1] == channelCount || shape[2] == channelCount),
              shape[1] > 0, shape[2] > 0 else {
            throw YOLODecoderError.unsupportedShape(shape)
        }

        let channelsFirst = shape[1] == channelCount
        let candidateCount = channelsFirst ? shape[2] : shape[1]
        var detections: [YOLODetection] = []
        for candidate in 0..<candidateCount {
            let centerX = number(output, channel: 0, candidate: candidate, candidateCount: candidateCount, channelCount: channelCount, channelsFirst: channelsFirst)
            let centerY = number(output, channel: 1, candidate: candidate, candidateCount: candidateCount, channelCount: channelCount, channelsFirst: channelsFirst)
            let width = number(output, channel: 2, candidate: candidate, candidateCount: candidateCount, channelCount: channelCount, channelsFirst: channelsFirst)
            let height = number(output, channel: 3, candidate: candidate, candidateCount: candidateCount, channelCount: channelCount, channelsFirst: channelsFirst)
            guard (0...1).contains(centerX), (0...1).contains(centerY), width > 0, height > 0, width <= 1, height <= 1 else {
                throw YOLODecoderError.invalidCoordinate("候補\(candidate)の座標")
            }

            let scores = labels.indices.map { number(output, channel: 4 + $0, candidate: candidate, candidateCount: candidateCount, channelCount: channelCount, channelsFirst: channelsFirst) }
            guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }) else { continue }
            let confidence = scores[best]
            guard confidence >= confidenceThreshold else { continue }

            let rect = CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            detections.append(YOLODetection(label: labels[best], confidence: confidence, normalizedRect: rect))
        }
        return nonMaximumSuppression(detections)
    }

    private func number(_ output: MLMultiArray, channel: Int, candidate: Int, candidateCount: Int, channelCount: Int, channelsFirst: Bool) -> Double {
        let offset = channelsFirst ? channel * candidateCount + candidate : candidate * channelCount + channel
        return output[offset].doubleValue
    }

    private func nonMaximumSuppression(_ detections: [YOLODetection]) -> [YOLODetection] {
        var result: [YOLODetection] = []
        for detection in detections.sorted(by: { $0.confidence > $1.confidence }) {
            let overlaps = result.contains { existing in
                existing.label == detection.label && intersectionOverUnion(existing.normalizedRect, detection.normalizedRect) > iouThreshold
            }
            if !overlaps { result.append(detection) }
        }
        return result
    }

    private func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
        return unionArea > 0 ? Double(intersectionArea / unionArea) : 0
    }
}
