import CoreML
import Foundation

public struct CoreMLPrediction: Sendable {
    public let values: [String: String]

    public init(values: [String: String]) {
        self.values = values
    }
}

public enum CoreMLPredictionError: LocalizedError {
    case inputMissing(String)
    case modelUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .inputMissing(let name): return "Core MLモデルの入力がありません: \(name)"
        case .modelUnavailable(let reason): return "Core MLモデルを読み込めません: \(reason)"
        }
    }
}

public struct CoreMLModelRunner {
    public init() {}

    public func predict(modelURL: URL, inputs: [String: MLFeatureValue]) throws -> CoreMLPrediction {
        let model: MLModel
        do {
            model = try MLModel(contentsOf: modelURL)
        } catch {
            throw CoreMLPredictionError.modelUnavailable(error.localizedDescription)
        }
        for name in model.modelDescription.inputDescriptionsByName.keys where inputs[name] == nil {
            throw CoreMLPredictionError.inputMissing(name)
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: inputs)
        let output = try model.prediction(from: provider)
        let values = Dictionary(uniqueKeysWithValues: output.featureNames.sorted().map { name in
            (name, describe(output.featureValue(for: name)))
        })
        return CoreMLPrediction(values: values)
    }

    private func describe(_ value: MLFeatureValue?) -> String {
        guard let value else { return "nil" }
        switch value.type {
        case .double: return String(value.doubleValue)
        case .int64: return String(value.int64Value)
        case .string: return value.stringValue
        case .multiArray: return "MLMultiArray shape=\(value.multiArrayValue?.shape ?? [])"
        case .dictionary: return "dictionary(\(value.dictionaryValue.count))"
        case .image: return "image"
        case .sequence: return "sequence"
        default: return "type=\(value.type.rawValue)"
        }
    }
}
