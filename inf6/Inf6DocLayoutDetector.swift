//
//  Inf6DocLayoutDetector.swift
//  inf6
//
//  YOLO11n DocLayNet — オンデバイス文書レイアウト解析。
//  Figure / Table / Formula の bbox をCore MLで検出。
//

import Foundation
import CoreML
import CoreImage
import UIKit

enum Inf6DocLayoutClass: Int, CaseIterable {
    case caption = 0
    case footnote = 1
    case formula = 2
    case listItem = 3
    case pageFooter = 4
    case pageHeader = 5
    case picture = 6
    case sectionHeader = 7
    case table = 8
    case text = 9
    case title = 10

    var label: String {
        switch self {
        case .caption: "Caption"
        case .footnote: "Footnote"
        case .formula: "Formula"
        case .listItem: "List-item"
        case .pageFooter: "Page-footer"
        case .pageHeader: "Page-header"
        case .picture: "Picture"
        case .sectionHeader: "Section-header"
        case .table: "Table"
        case .text: "Text"
        case .title: "Title"
        }
    }
}

struct Inf6DocLayoutDetection {
    let classID: Inf6DocLayoutClass
    let confidence: Float
    /// bbox in normalized coordinates [0,1] relative to original image
    let x: Float
    let y: Float
    let width: Float
    let height: Float
}

final class Inf6DocLayoutDetector {

    static let shared = Inf6DocLayoutDetector()

    private let modelInputSize: CGFloat = 1280
    private var _model: MLModel?

    private init() {}

    private func _loadModel() throws -> MLModel {
        if let m = _model { return m }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        guard let url = Bundle.main.url(forResource: "yolo11n_doc_layout", withExtension: "mlmodelc")
                ?? Bundle.main.url(forResource: "yolo11n_doc_layout", withExtension: "mlpackage") else {
            throw NSError(domain: "Inf6DocLayout", code: 1, userInfo: [NSLocalizedDescriptionKey: "yolo11n_doc_layout model not found in bundle"])
        }
        let m = try MLModel(contentsOf: url, configuration: config)
        _model = m
        return m
    }

    /// Detect document layout elements in a CGImage.
    /// Returns detections for the specified classes (default: Picture, Table, Formula).
    func detect(
        image: CGImage,
        classes: Set<Inf6DocLayoutClass> = [.picture, .table, .formula],
        confidenceThreshold: Float = 0.25,
        iouThreshold: Float = 0.45
    ) throws -> [Inf6DocLayoutDetection] {
        let model = try _loadModel()

        let originalW = CGFloat(image.width)
        let originalH = CGFloat(image.height)

        // Letterbox: resize maintaining aspect ratio, pad to 1280x1280
        let scale = min(modelInputSize / originalW, modelInputSize / originalH)
        let newW = originalW * scale
        let newH = originalH * scale
        let padX = (modelInputSize - newW) / 2
        let padY = (modelInputSize - newH) / 2

        let pixelBuffer = try _createPixelBuffer(image: image, targetSize: Int(modelInputSize), newW: newW, newH: newH, padX: padX, padY: padY)

        let input = try MLDictionaryFeatureProvider(dictionary: ["image": pixelBuffer])
        let output = try model.prediction(from: input)

        guard let multiArray = output.featureValue(for: "var_1224")?.multiArrayValue else {
            throw NSError(domain: "Inf6DocLayout", code: 2, userInfo: [NSLocalizedDescriptionKey: "Model output missing"])
        }

        // multiArray shape: [1, 15, 33600]
        // 15 = 4 (cx, cy, w, h) + 11 (class scores)
        let numDetections = multiArray.shape[2].intValue
        let numChannels = multiArray.shape[1].intValue
        let ptr = multiArray.dataPointer.bindMemory(to: Float.self, capacity: numChannels * numDetections)

        var candidates: [Inf6DocLayoutDetection] = []

        for i in 0..<numDetections {
            // Data layout: [1, 15, 33600] — channel-first
            let cx = ptr[0 * numDetections + i]
            let cy = ptr[1 * numDetections + i]
            let w  = ptr[2 * numDetections + i]
            let h  = ptr[3 * numDetections + i]

            var bestClassID = 0
            var bestScore: Float = 0
            for c in 0..<11 {
                let score = ptr[(4 + c) * numDetections + i]
                if score > bestScore {
                    bestScore = score
                    bestClassID = c
                }
            }

            guard bestScore >= confidenceThreshold,
                  let cls = Inf6DocLayoutClass(rawValue: bestClassID),
                  classes.contains(cls) else { continue }

            // Convert from letterboxed coords to normalized original image coords
            let nx = (CGFloat(cx) - padX) / newW
            let ny = (CGFloat(cy) - padY) / newH
            let nw = CGFloat(w) / newW
            let nh = CGFloat(h) / newH

            candidates.append(Inf6DocLayoutDetection(
                classID: cls,
                confidence: bestScore,
                x: Float(nx - nw / 2),
                y: Float(ny - nh / 2),
                width: Float(nw),
                height: Float(nh)
            ))
        }

        return _nms(candidates, iouThreshold: iouThreshold)
    }

    // MARK: - Private

    private func _createPixelBuffer(image: CGImage, targetSize: Int, newW: CGFloat, newH: CGFloat, padX: CGFloat, padY: CGFloat) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, targetSize, targetSize, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let pixelBuffer = pb else {
            throw NSError(domain: "Inf6DocLayout", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create pixel buffer"])
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: targetSize,
            height: targetSize,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw NSError(domain: "Inf6DocLayout", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGContext"])
        }

        // Fill with gray (114/255 — YOLO letterbox convention)
        ctx.setFillColor(red: 114/255, green: 114/255, blue: 114/255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: targetSize, height: targetSize))

        // Draw image in letterbox position (flip Y for CGContext)
        let drawRect = CGRect(x: padX, y: CGFloat(targetSize) - padY - newH, width: newW, height: newH)
        ctx.draw(image, in: drawRect)

        return pixelBuffer
    }

    private func _nms(_ detections: [Inf6DocLayoutDetection], iouThreshold: Float) -> [Inf6DocLayoutDetection] {
        let sorted = detections.sorted { $0.confidence > $1.confidence }
        var selected: [Inf6DocLayoutDetection] = []

        for det in sorted {
            let dominated = selected.contains { existing in
                _iou(det, existing) > iouThreshold
            }
            if !dominated { selected.append(det) }
        }
        return selected
    }

    private func _iou(_ a: Inf6DocLayoutDetection, _ b: Inf6DocLayoutDetection) -> Float {
        let ax1 = a.x, ay1 = a.y, ax2 = a.x + a.width, ay2 = a.y + a.height
        let bx1 = b.x, by1 = b.y, bx2 = b.x + b.width, by2 = b.y + b.height
        let ix1 = max(ax1, bx1), iy1 = max(ay1, by1)
        let ix2 = min(ax2, bx2), iy2 = min(ay2, by2)
        let iw = max(0, ix2 - ix1), ih = max(0, iy2 - iy1)
        let inter = iw * ih
        let aArea = a.width * a.height
        let bArea = b.width * b.height
        let union = aArea + bArea - inter
        return union > 0 ? inter / union : 0
    }
}
