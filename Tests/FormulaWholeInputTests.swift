import XCTest
import Foundation
@testable import inf6
#if canImport(PencilKit)
import PencilKit
import UIKit
#endif

/// Fixed-point parity fixture for `Inf6FormulaWholeInput`. The expected
/// values are not hand-derived: they come from running the real training-side
/// parser, `ModelConversion/formula_whole_input.load_formula_input`, on two
/// fixed InkML fixtures (`wholeformula-fixture-a.inkml`,
/// `wholeformula-fixture-b.inkml`) and copying its output verbatim. A
/// mismatch here means the Swift and Python normalization have drifted, not
/// that PencilKit and InkML agree end to end — see `parityStatus` on both
/// sides, which stays `UNVERIFIED_WITH_PENCILKIT` regardless of this test.
final class FormulaWholeInputTests: XCTestCase {
    private let tolerance = 1e-9

    func testMatchesPythonReferenceOnMultiTraceFixture() throws {
        // wholeformula-fixture-a.inkml: two traces, non-degenerate x and y span.
        let input = try Inf6FormulaWholeInput.make(fromRawTraces: [
            [(x: 10, y: 20, t: 0), (x: 15, y: 25, t: 12), (x: 20, y: 15, t: 30)],
            [(x: 30, y: 10, t: 55), (x: 35, y: 10, t: 61), (x: 35, y: 5, t: 70)],
        ])

        XCTAssertEqual(input.specVersion, "inf6-formula-input-v1")
        XCTAssertEqual(input.traceOrder, [0, 1])
        assertBounds(input.sourceBounds, minX: 10, minY: 5, maxX: 35, maxY: 25)

        let expected: [[(x: Double, y: Double, t: Double?)]] = [
            [(0.0, 0.7, 0.0), (0.2, 0.9, 12.0), (0.4, 0.5, 30.0)],
            [(0.8, 0.3, 55.0), (1.0, 0.3, 61.0), (1.0, 0.1, 70.0)],
        ]
        assertTraces(input.traces, match: expected)

        XCTAssertEqual(input.coordinateSpec.origin, "source-bounds-min")
        XCTAssertEqual(input.coordinateSpec.axis, "x-right,y-down")
        XCTAssertEqual(input.coordinateSpec.scale, "isotropic-bounds-to-[0,1]-square-with-centered-padding")
        XCTAssertEqual(input.coordinateSpec.parityStatus, "UNVERIFIED_WITH_PENCILKIT")
    }

    func testDegenerateAxisFallsBackToCenterLikePythonReference() throws {
        // wholeformula-fixture-b.inkml: one horizontal trace, y span is zero.
        let input = try Inf6FormulaWholeInput.make(fromRawTraces: [
            [(x: 0, y: 50, t: nil), (x: 10, y: 50, t: nil), (x: 20, y: 50, t: nil)],
        ])

        assertBounds(input.sourceBounds, minX: 0, minY: 50, maxX: 20, maxY: 50)
        let expected: [[(x: Double, y: Double, t: Double?)]] = [
            [(0.0, 0.5, nil), (0.5, 0.5, nil), (1.0, 0.5, nil)],
        ]
        assertTraces(input.traces, match: expected)
    }

    func testIsotropicPaddingPreservesWideVersusTallAspectRatio() throws {
        let wide = try Inf6FormulaWholeInput.make(fromRawTraces: [
            [(x: 0, y: 0, t: nil), (x: 100, y: 10, t: nil)],
            [(x: 0, y: 10, t: nil), (x: 100, y: 0, t: nil)],
        ])
        let tall = try Inf6FormulaWholeInput.make(fromRawTraces: [
            [(x: 0, y: 0, t: nil), (x: 10, y: 100, t: nil)],
            [(x: 10, y: 0, t: nil), (x: 0, y: 100, t: nil)],
        ])

        XCTAssertNotEqual(wide.traces, tall.traces)
        XCTAssertEqual(wide.traces[0][0].y, 0.45, accuracy: tolerance)
        XCTAssertEqual(tall.traces[0][0].x, 0.45, accuracy: tolerance)
        XCTAssertEqual(wide.coordinateSpec.scale, "isotropic-bounds-to-[0,1]-square-with-centered-padding")
    }

    func testRejectsEmptyDrawingInsteadOfSilentlyProducingAnInput() {
        XCTAssertThrowsError(try Inf6FormulaWholeInput.make(fromRawTraces: []))
    }

    func testRejectsEmptyTraceInsteadOfSilentlyDroppingIt() {
        XCTAssertThrowsError(try Inf6FormulaWholeInput.make(fromRawTraces: [[(x: 0, y: 0, t: nil)], []]))
    }

    func test128PointTensorMatchesPythonGeneratedFixtureElementByElement() throws {
        let data = try Data(contentsOf: sharedFixtureURL())
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let contract = try XCTUnwrap(root["modelInputContract"] as? [String: Any])
        XCTAssertEqual(contract["version"] as? String, Inf6FormulaWholeInput.modelInputContractVersion)
        XCTAssertEqual(contract["dtype"] as? String, Inf6FormulaWholeInput.modelFeatureDType)
        XCTAssertEqual(contract["shape"] as? String, "[trace,128,2]")
        XCTAssertEqual(contract["pointsPerTrace"] as? Int, Inf6FormulaWholeInput.modelPointsPerTrace)
        XCTAssertEqual(contract["featureDimension"] as? Int, Inf6FormulaWholeInput.modelFeatureDimension)
        XCTAssertEqual(contract["maxTraces"] as? Int, Inf6FormulaWholeInput.maxModelTraces)

        for name in ["wholeformula-fixture-a", "wholeformula-fixture-b"] {
            let fixture = try XCTUnwrap(root[name] as? [String: Any])
            let inputObject = try XCTUnwrap(fixture["formulaInput"])
            let inputData = try JSONSerialization.data(withJSONObject: inputObject)
            let input = try JSONDecoder().decode(Inf6FormulaWholeInput.FormulaInput.self, from: inputData)
            let expectedObject = try XCTUnwrap(fixture["modelTensor"])
            let expectedData = try JSONSerialization.data(withJSONObject: expectedObject)
            let expected = try JSONDecoder().decode([[[Float]]].self, from: expectedData)
            let actual = try Inf6FormulaWholeInput.modelTensorFeatures(from: input)

            XCTAssertEqual(actual.count, expected.count, "\(name): trace order/count differs")
            XCTAssertEqual(actual.map(\.count), Array(repeating: Inf6FormulaWholeInput.modelPointsPerTrace, count: expected.count), "\(name): point shape differs")
            for (traceIndex, pair) in zip(actual.indices, zip(actual, expected)) {
                XCTAssertEqual(pair.0.count, pair.1.count, "\(name): trace \(traceIndex) point count differs")
                for (pointIndex, pointPair) in zip(pair.0.indices, zip(pair.0, pair.1)) {
                    XCTAssertEqual(pointPair.0.count, Inf6FormulaWholeInput.modelFeatureDimension, "\(name): feature dimension differs")
                    for coordinateIndex in 0..<Inf6FormulaWholeInput.modelFeatureDimension {
                        XCTAssertEqual(
                            pointPair.0[coordinateIndex], pointPair.1[coordinateIndex], accuracy: 0.000001,
                            "\(name): trace \(traceIndex), point \(pointIndex), coordinate \(coordinateIndex) differs"
                        )
                        XCTAssertGreaterThanOrEqual(pointPair.0[coordinateIndex], 0, "\(name): value below normalized range")
                        XCTAssertLessThanOrEqual(pointPair.0[coordinateIndex], 1, "\(name): value above normalized range")
                    }
                }
            }
        }
    }

    func testTraceGeometryMatchesPythonGeneratedFixtureElementByElement() throws {
        let data = try Data(contentsOf: sharedFixtureURL())
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let contract = try XCTUnwrap(root["traceGeometryContract"] as? [String: Any])
        XCTAssertEqual(contract["version"] as? String, Inf6FormulaWholeInput.traceGeometryContractVersion)
        XCTAssertEqual(contract["dtype"] as? String, Inf6FormulaWholeInput.modelFeatureDType)
        XCTAssertEqual(contract["shape"] as? String, "[trace,9]")
        XCTAssertEqual(contract["featureDimension"] as? Int, Inf6FormulaWholeInput.traceGeometryFeatureDimension)

        for name in ["wholeformula-fixture-a", "wholeformula-fixture-b"] {
            let fixture = try XCTUnwrap(root[name] as? [String: Any])
            let inputObject = try XCTUnwrap(fixture["formulaInput"])
            let inputData = try JSONSerialization.data(withJSONObject: inputObject)
            let input = try JSONDecoder().decode(Inf6FormulaWholeInput.FormulaInput.self, from: inputData)
            let expectedObject = try XCTUnwrap(fixture["traceGeometry"])
            let expectedData = try JSONSerialization.data(withJSONObject: expectedObject)
            let expected = try JSONDecoder().decode([[Float]].self, from: expectedData)
            let actual = try Inf6FormulaWholeInput.traceGeometryFeatures(from: input)
            XCTAssertEqual(actual.count, expected.count, "\(name): trace count differs")
            for (actualTrace, expectedTrace) in zip(actual, expected) {
                XCTAssertEqual(actualTrace.count, Inf6FormulaWholeInput.traceGeometryFeatureDimension)
                XCTAssertEqual(actualTrace.count, expectedTrace.count)
                for (actualValue, expectedValue) in zip(actualTrace, expectedTrace) {
                    XCTAssertEqual(actualValue, expectedValue, accuracy: .ulpOfOne, "\(name): geometry differs")
                    XCTAssertGreaterThanOrEqual(actualValue, 0)
                    XCTAssertLessThanOrEqual(actualValue, 1)
                }
            }
        }
    }

    #if canImport(PencilKit)
    func testPencilKitStrokeTransformAndRelativeTimeArePreserved() throws {
        let firstPath = PKStrokePath(
            controlPoints: [
                PKStrokePoint(location: CGPoint(x: 1, y: 2), timeOffset: 0.0, size: CGSize(width: 1, height: 1), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
                PKStrokePoint(location: CGPoint(x: 3, y: 5), timeOffset: 0.25, size: CGSize(width: 1, height: 1), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
            ],
            creationDate: Date(timeIntervalSince1970: 100)
        )
        let secondPath = PKStrokePath(
            controlPoints: [
                PKStrokePoint(location: CGPoint(x: 0, y: 1), timeOffset: 0.0, size: CGSize(width: 1, height: 1), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
                PKStrokePoint(location: CGPoint(x: 2, y: 4), timeOffset: 0.5, size: CGSize(width: 1, height: 1), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
            ],
            creationDate: Date(timeIntervalSince1970: 100)
        )
        let transform = CGAffineTransform(a: 2, b: 0, c: 0, d: 3, tx: 10, ty: 20)
        let ink = PKInk(.pen, color: .black)
        let input = try Inf6FormulaWholeInput.make(from: [
            PKStroke(ink: ink, path: firstPath, transform: transform, mask: nil),
            PKStroke(ink: ink, path: secondPath, transform: .identity, mask: nil),
        ])

        XCTAssertEqual(input.traceOrder, [0, 1])
        XCTAssertEqual(input.traces.count, 2)
        XCTAssertEqual(input.traces[0].count, 2)
        XCTAssertEqual(input.traces[1].count, 2)
        assertBounds(input.sourceBounds, minX: 0, minY: 1, maxX: 16, maxY: 35)

        // First stroke points are transformed before the shared bbox is computed:
        // (1,2)->(12,26), (3,5)->(16,35). T remains each stroke's own offset.
        XCTAssertEqual(input.traces[0][0].x, 21.0 / 34.0, accuracy: tolerance)
        XCTAssertEqual(input.traces[0][0].y, 25.0 / 34.0, accuracy: tolerance)
        XCTAssertEqual(input.traces[0][0].t, 0.0)
        XCTAssertEqual(input.traces[0][1].x, 25.0 / 34.0, accuracy: tolerance)
        XCTAssertEqual(input.traces[0][1].y, 1.0, accuracy: tolerance)
        XCTAssertEqual(input.traces[0][1].t, 0.25)
        XCTAssertEqual(input.traces[1][0].x, 9.0 / 34.0, accuracy: tolerance)
        XCTAssertEqual(input.traces[1][0].y, 0.0, accuracy: tolerance)
        XCTAssertEqual(input.traces[1][1].x, 11.0 / 34.0, accuracy: tolerance)
        XCTAssertEqual(input.traces[1][1].y, 3.0 / 34.0, accuracy: tolerance)
        XCTAssertEqual(input.traces[1][1].t, 0.5)

        let features = Inf6FormulaWholeInput.modelFeatures(from: input)
        XCTAssertEqual(features.count, 2)
        XCTAssertEqual(features.map(\.count), [2, 2])
        XCTAssertEqual(features.flatMap { $0 }.allSatisfy { $0.count == Inf6FormulaWholeInput.modelFeatureDimension }, true)
        XCTAssertEqual(Inf6FormulaWholeInput.modelFeatureDType, "float32")
        XCTAssertEqual(features[0][0][0], Float(21.0 / 34.0), accuracy: .ulpOfOne)
        XCTAssertEqual(features[0][0][1], Float(25.0 / 34.0), accuracy: .ulpOfOne)

        let tensorFeatures = try Inf6FormulaWholeInput.modelTensorFeatures(from: input)
        XCTAssertEqual(Inf6FormulaWholeInput.modelInputContractVersion, "inf6-formula-whole-trace-v3-128pt")
        XCTAssertEqual(tensorFeatures.map(\.count), [Inf6FormulaWholeInput.modelPointsPerTrace, Inf6FormulaWholeInput.modelPointsPerTrace])
        XCTAssertEqual(tensorFeatures.flatMap { $0 }.allSatisfy { $0.count == Inf6FormulaWholeInput.modelFeatureDimension }, true)
        XCTAssertEqual(tensorFeatures[0].first![0], features[0].first![0], accuracy: .ulpOfOne)
        XCTAssertEqual(tensorFeatures[0].last![1], features[0].last![1], accuracy: .ulpOfOne)
    }
    #endif

    // MARK: - Helpers

    private func assertBounds(_ bounds: Inf6FormulaWholeInput.Bounds, minX: Double, minY: Double, maxX: Double, maxY: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(bounds.minX, minX, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(bounds.minY, minY, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(bounds.maxX, maxX, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(bounds.maxY, maxY, accuracy: tolerance, file: file, line: line)
    }

    private func sharedFixtureURL(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ModelConversion/formula-whole-input-fixtures/formula-whole-input-fixture.json")
    }

    private func assertTraces(_ actual: [[Inf6FormulaWholeInput.Point]], match expected: [[(x: Double, y: Double, t: Double?)]], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (trace, expectedTrace) in zip(actual, expected) {
            XCTAssertEqual(trace.count, expectedTrace.count, file: file, line: line)
            for (point, expectedPoint) in zip(trace, expectedTrace) {
                XCTAssertEqual(point.x, expectedPoint.x, accuracy: tolerance, file: file, line: line)
                XCTAssertEqual(point.y, expectedPoint.y, accuracy: tolerance, file: file, line: line)
                XCTAssertEqual(point.t, expectedPoint.t, file: file, line: line)
            }
        }
    }
}
