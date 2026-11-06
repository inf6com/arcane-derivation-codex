import CoreML
import CoreGraphics
import Foundation

public enum YOLOCoreMLDetectorError: LocalizedError {
    case modelUnavailable(String)
    case inputMissing(String)
    case outputMissing(String)
    case outputNotMultiArray(String)
    case ambiguousOutput([String])

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let reason): return "YOLOモデルを読み込めません: \(reason)"
        case .inputMissing(let name): return "YOLOモデルの入力がありません: \(name)"
        case .outputMissing(let name): return "YOLOモデルの出力がありません: \(name)"
        case .outputNotMultiArray(let name): return "YOLOモデルの出力が検出配列ではありません: \(name)"
        case .ambiguousOutput(let names): return "YOLO検出出力を一意に選択できません: \(names.joined(separator: ", "))"
        }
    }
}

public struct YOLOCoreMLDetector {
    public static let bundledDocumentLayoutModelName = "yolo11n_doc_layout"
    public static let documentLayoutLabels = [
        "Caption", "Footnote", "Formula", "List-item", "Page-footer", "Page-header",
        "Picture", "Section-header", "Table", "Text", "Title"
    ]

    private let modelURL: URL
    private let decoder: YOLODetectionDecoder

    public init(modelURL: URL, labels: [String], confidenceThreshold: Double = 0.25, iouThreshold: Double = 0.45) throws {
        self.modelURL = modelURL
        self.decoder = try YOLODetectionDecoder(labels: labels, confidenceThreshold: confidenceThreshold, iouThreshold: iouThreshold)
    }

    public init(
        bundledDocumentLayoutWithConfidenceThreshold confidenceThreshold: Double = 0.25,
        iouThreshold: Double = 0.45
    ) throws {
        guard let modelURL = Bundle.main.url(
            forResource: Self.bundledDocumentLayoutModelName,
            withExtension: "mlmodelc"
        ) ?? Bundle.main.url(
            forResource: Self.bundledDocumentLayoutModelName,
            withExtension: "mlpackage"
        ) else {
            throw YOLOCoreMLDetectorError.modelUnavailable(
                "アプリ内の \(Self.bundledDocumentLayoutModelName) モデルが見つかりません"
            )
        }
        try self.init(
            modelURL: modelURL,
            labels: Self.documentLayoutLabels,
            confidenceThreshold: confidenceThreshold,
            iouThreshold: iouThreshold
        )
    }

    public func detect(inputs: [String: MLFeatureValue], outputName: String? = nil) throws -> [YOLODetection] {
        let model: MLModel
        do {
            model = try MLModel(contentsOf: modelURL)
        } catch {
            throw YOLOCoreMLDetectorError.modelUnavailable(error.localizedDescription)
        }

        for name in model.modelDescription.inputDescriptionsByName.keys where inputs[name] == nil {
            throw YOLOCoreMLDetectorError.inputMissing(name)
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: inputs)
        let output = try model.prediction(from: provider)
        let selectedName: String
        if let outputName {
            guard output.featureNames.contains(outputName) else {
                throw YOLOCoreMLDetectorError.outputMissing(outputName)
            }
            selectedName = outputName
        } else {
            let arrayNames = output.featureNames.filter { output.featureValue(for: $0)?.type == .multiArray }
            guard arrayNames.count == 1, let onlyName = arrayNames.first else {
                throw YOLOCoreMLDetectorError.ambiguousOutput(output.featureNames.sorted())
            }
            selectedName = onlyName
        }

        guard let value = output.featureValue(for: selectedName), value.type == .multiArray,
              let array = value.multiArrayValue else {
            throw YOLOCoreMLDetectorError.outputNotMultiArray(selectedName)
        }
        return try decoder.decode(array)
    }

    public func detect(image: CGImage, confidenceThreshold: Double? = nil) throws -> [YOLODetection] {
        let inputSize = 1280
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else {
            throw YOLOCoreMLDetectorError.inputMissing("画像サイズ")
        }

        let scale = min(CGFloat(inputSize) / width, CGFloat(inputSize) / height)
        let resizedWidth = width * scale
        let resizedHeight = height * scale
        let padX = (CGFloat(inputSize) - resizedWidth) / 2
        let padY = (CGFloat(inputSize) - resizedHeight) / 2
        let pixelBuffer = try makeLetterboxedPixelBuffer(
            image: image,
            size: inputSize,
            resizedWidth: resizedWidth,
            resizedHeight: resizedHeight,
            padX: padX,
            padY: padY
        )

        let detections = try detect(
            inputs: ["image": MLFeatureValue(pixelBuffer: pixelBuffer)],
            outputName: "var_1224"
        )
        guard let confidenceThreshold else { return detections }
        return detections.filter { Double($0.confidence) >= confidenceThreshold }
    }

    private func makeLetterboxedPixelBuffer(
        image: CGImage,
        size: Int,
        resizedWidth: CGFloat,
        resizedHeight: CGFloat,
        padX: CGFloat,
        padY: CGFloat
    ) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            size,
            size,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &result
        ) == kCVReturnSuccess, let pixelBuffer = result else {
            throw YOLOCoreMLDetectorError.inputMissing("ピクセルバッファ")
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw YOLOCoreMLDetectorError.inputMissing("描画コンテキスト")
        }

        context.setFillColor(red: 114 / 255, green: 114 / 255, blue: 114 / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.draw(
            image,
            in: CGRect(x: padX, y: CGFloat(size) - padY - resizedHeight, width: resizedWidth, height: resizedHeight)
        )
        return pixelBuffer
    }
}
