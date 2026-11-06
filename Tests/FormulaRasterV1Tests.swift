import Foundation
import XCTest
@testable import inf6

final class FormulaRasterV1Tests: XCTestCase {
    func testMatchesPythonPGMFixturePixelForPixel() throws {
        let input = try Inf6FormulaWholeInput.make(fromRawTraces: [
            [(x: 10, y: 20, t: 0), (x: 15, y: 25, t: 12), (x: 20, y: 15, t: 30)],
            [(x: 30, y: 10, t: 55), (x: 35, y: 10, t: 61), (x: 35, y: 5, t: 70)],
        ])

        let expected = try Data(contentsOf: pythonFixtureURL())
        let actual = try FormulaRasterV1.pgm(from: input)

        let header = Data("P5\n512 512\n255\n".utf8)
        XCTAssertEqual(expected.prefix(header.count), header)
        XCTAssertEqual(expected.count, header.count + FormulaRasterV1.size * FormulaRasterV1.size)
        XCTAssertEqual(actual.count, expected.count, "PGM byte count differs")
        XCTAssertEqual(actual, expected, "Swift raster must match the Python fixture in every PGM byte")
    }

    func testRejectsDegenerateRasterInputWithConcreteCause() throws {
        let input = try Inf6FormulaWholeInput.make(fromRawTraces: [
            [(x: 0, y: 10, t: nil), (x: 10, y: 10, t: nil)],
        ])

        XCTAssertThrowsError(try FormulaRasterV1.pgm(from: input)) { error in
            XCTAssertEqual(error.localizedDescription, "数式ラスター化にはx軸・y軸の両方に有限な入力範囲が必要です。")
        }
    }

    private func pythonFixtureURL(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("runs/agent-control/cycle349-raster-python-fixture.pgm")
    }
}
