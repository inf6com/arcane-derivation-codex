import CoreML
import Foundation

let modelURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Models/Inf6TextEmbedding.mlmodelc")
let model = try MLModel(contentsOf: modelURL)
let description = model.modelDescription

print("MODEL: \(modelURL.path)")
print("INPUTS")
for (name, feature) in description.inputDescriptionsByName.sorted(by: { $0.key < $1.key }) {
    print("- \(name): type=\(feature.type.rawValue) shape=\(feature.multiArrayConstraint?.shape ?? []) dtype=\(feature.multiArrayConstraint?.dataType.rawValue ?? -1)")
}
print("OUTPUTS")
for (name, feature) in description.outputDescriptionsByName.sorted(by: { $0.key < $1.key }) {
    print("- \(name): type=\(feature.type.rawValue) shape=\(feature.multiArrayConstraint?.shape ?? []) dtype=\(feature.multiArrayConstraint?.dataType.rawValue ?? -1)")
}

let inputIDs = try MLMultiArray(shape: [1, 256], dataType: .int32)
let attentionMask = try MLMultiArray(shape: [1, 256], dataType: .int32)
inputIDs[0] = 0
attentionMask[0] = 1
let features = try MLDictionaryFeatureProvider(dictionary: [
    "input_ids": MLFeatureValue(multiArray: inputIDs),
    "attention_mask": MLFeatureValue(multiArray: attentionMask)
])
let prediction = try model.prediction(from: features)
guard let output = prediction.featureValue(for: "embeddings")?.multiArrayValue else {
    throw NSError(domain: "InspectTextEmbedding", code: 1, userInfo: [NSLocalizedDescriptionKey: "embeddings output is missing"])
}
print("PREDICTION: embeddings count=\(output.count) first=\(output[0])")
