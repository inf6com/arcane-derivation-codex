import Foundation

func fixtureError(_ message: String) -> Never {
    fputs("Swift formula tensor parity failed: \(message)\n", stderr)
    exit(2)
}

@main
struct VerifySwiftFormulaTensor {
static func main() {
guard CommandLine.arguments.count == 2 else {
    fixtureError("usage: verify_swift_formula_tensor <fixture.json>")
}

let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
let fixtureData: Data
do {
    fixtureData = try Data(contentsOf: fixtureURL)
} catch {
    fixtureError("cannot read fixture: \(error)")
}

let root: [String: Any]
do {
    guard let parsed = try JSONSerialization.jsonObject(with: fixtureData) as? [String: Any] else {
        fixtureError("fixture root is not an object")
    }
    root = parsed
} catch {
    fixtureError("cannot parse fixture JSON: \(error)")
}

guard let contract = root["modelInputContract"] as? [String: Any] else {
    fixtureError("fixture has no modelInputContract")
}
guard contract["version"] as? String == Inf6FormulaWholeInput.modelInputContractVersion,
      contract["dtype"] as? String == Inf6FormulaWholeInput.modelFeatureDType,
      contract["shape"] as? String == "[trace,128,2]",
      contract["pointsPerTrace"] as? Int == Inf6FormulaWholeInput.modelPointsPerTrace,
      contract["featureDimension"] as? Int == Inf6FormulaWholeInput.modelFeatureDimension,
      contract["maxTraces"] as? Int == Inf6FormulaWholeInput.maxModelTraces else {
    fixtureError("fixture/model contract mismatch")
}

var comparedValues = 0
var maxAbsoluteDifference: Float = 0
for name in ["wholeformula-fixture-a", "wholeformula-fixture-b"] {
    guard let fixture = root[name] as? [String: Any], let inputObject = fixture["formulaInput"], let expectedObject = fixture["modelTensor"] else {
        fixtureError("missing fixture case \(name)")
    }
    do {
        let inputData = try JSONSerialization.data(withJSONObject: inputObject)
        let expectedData = try JSONSerialization.data(withJSONObject: expectedObject)
        let input = try JSONDecoder().decode(Inf6FormulaWholeInput.FormulaInput.self, from: inputData)
        let expected = try JSONDecoder().decode([[[Float]]].self, from: expectedData)
        let actual = try Inf6FormulaWholeInput.modelTensorFeatures(from: input)
        guard actual.count == expected.count else { fixtureError("\(name): trace count") }
        for (traceIndex, pair) in zip(actual.indices, zip(actual, expected)) {
            guard pair.0.count == Inf6FormulaWholeInput.modelPointsPerTrace, pair.0.count == pair.1.count else {
                fixtureError("\(name): trace \(traceIndex) shape")
            }
            for (pointIndex, pointPair) in zip(pair.0.indices, zip(pair.0, pair.1)) {
                guard pointPair.0.count == Inf6FormulaWholeInput.modelFeatureDimension, pointPair.0.count == pointPair.1.count else {
                    fixtureError("\(name): trace \(traceIndex) point \(pointIndex) feature shape")
                }
                for coordinateIndex in 0..<Inf6FormulaWholeInput.modelFeatureDimension {
                    let actualValue = pointPair.0[coordinateIndex]
                    let expectedValue = pointPair.1[coordinateIndex]
                    let difference = abs(actualValue - expectedValue)
                    maxAbsoluteDifference = max(maxAbsoluteDifference, difference)
                    guard difference <= 0.000001 else {
                        fixtureError("\(name): trace \(traceIndex), point \(pointIndex), coordinate \(coordinateIndex), difference \(difference)")
                    }
                    guard (0...1).contains(actualValue) else {
                        fixtureError("\(name): normalized range")
                    }
                    comparedValues += 1
                }
            }
        }
    } catch {
        fixtureError("\(name): \(error)")
    }
}

print("{\"status\":\"PASS\",\"contract\":\"\(Inf6FormulaWholeInput.modelInputContractVersion)\",\"comparedValues\":\(comparedValues),\"maxAbsoluteDifference\":\(maxAbsoluteDifference)}")
}
}
