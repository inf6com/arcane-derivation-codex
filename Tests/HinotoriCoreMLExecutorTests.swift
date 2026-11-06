import CoreML
import CryptoKit
import Foundation
import XCTest
@testable import inf6

final class HinotoriCoreMLExecutorTests: XCTestCase {
    func testRejectedHinotoriModelIsNotBundledAndFailureIsExplicit() {
        let bundle = Bundle(for: HinotoriCoreMLExecutor.self)
        XCTAssertNil(bundle.url(forResource: "HinotoriAffinity", withExtension: "mlmodelc"))
        XCTAssertNil(bundle.url(forResource: "HinotoriRetrieval", withExtension: "mlmodelc"))
        XCTAssertThrowsError(try HinotoriCoreMLExecutor(bundle: bundle)) { error in
            XCTAssertEqual(
                error as? HinotoriCoreMLError,
                .invalidModelContract("HinotoriAffinity.mlmodelcまたはHinotoriRetrieval.mlmodelcがBundle内にありません")
            )
        }
    }

    func testCanonicalGroupMatches32PointCenteredIsotropicContract() throws {
        let group = try HinotoriCoreMLExecutor.canonicalGroup([
            HinotoriStroke(points: [CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 0)]),
            HinotoriStroke(points: [CGPoint(x: 2, y: 2)]),
        ])
        XCTAssertEqual(group.count, 2)
        XCTAssertEqual(group[0].count, 32)
        XCTAssertEqual(group[0].first!, [-0.5, -0.25])
        XCTAssertEqual(group[0].last!, [0.5, -0.25])
        XCTAssertEqual(group[1][0], [0, 0.25])
        XCTAssertEqual(group[1][31], [0, 0.25])
    }

    func testCanonicalGroupDropsDuplicateConsecutivePointsByArcLength() throws {
        let group = try HinotoriCoreMLExecutor.canonicalGroup([
            HinotoriStroke(points: [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 0)]),
        ], pointCount: 3)
        XCTAssertEqual(group[0], [[-0.5, 0], [0, 0], [0.5, 0]])
    }

    func testConnectedComponentsUsesStrictPositiveAffinityOnly() throws {
        let affinity = try MLMultiArray(shape: [80, 80], dataType: .float32)
        for index in 0..<affinity.count { affinity[index] = 0 }
        affinity[[0, 1]] = 0.1
        affinity[[1, 0]] = 0.1
        XCTAssertEqual(try HinotoriCoreMLExecutor.decodeConnectedComponents(affinity: affinity, validCount: 3), [[0, 1], [2]])
    }

    func testRejectsMoreThanEightyStrokesBeforeCoreMLPrediction() throws {
        let strokes = (0...80).map { _ in HinotoriStroke(points: [CGPoint(x: 0, y: 0)]) }
        XCTAssertEqual(strokes.count, 81)
        XCTAssertThrowsError(try HinotoriCoreMLExecutor.validateFormulaInput(strokes)) { error in
            XCTAssertEqual(error as? HinotoriCoreMLError, .tooManyFormulaStrokes(actual: 81))
        }
    }

    func testLoadsManifestHashedLittleEndianAnchorBank() throws {
        let fixture = try writeAnchorFixture(classIndices: Array(0..<229))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let bank = try HinotoriAnchorBank.load(manifestURL: fixture.manifest)

        XCTAssertEqual(bank.anchorCount, 229)
        XCTAssertEqual(bank.maxStrokes, 1)
        XCTAssertEqual(bank.points.shape.map(\.intValue), [229, 1, 32, 2])
        let points = bank.points.dataPointer.bindMemory(to: Float32.self, capacity: bank.points.count)
        XCTAssertEqual(points[0], 1.5)
    }

    func testRejectsAnchorClassesWithoutAll229Classes() throws {
        let fixture = try writeAnchorFixture(classIndices: Array(repeating: 0, count: 229))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        XCTAssertThrowsError(try HinotoriAnchorBank.load(manifestURL: fixture.manifest)) { error in
            guard case let HinotoriCoreMLError.invalidAnchorBank(reason) = error else {
                return XCTFail("予期しないエラー: \(error)")
            }
            XCTAssertTrue(reason.contains("229クラス全てを被覆"))
        }
    }

    func testRejectsAnchorArrayWhenSHA256DoesNotMatchManifest() throws {
        let fixture = try writeAnchorFixture(classIndices: Array(0..<229))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Data(repeating: 0, count: 229 * 32 * 2 * MemoryLayout<UInt32>.size)
            .write(to: fixture.directory.appendingPathComponent("HinotoriAnchorPoints.f32le"))

        XCTAssertThrowsError(try HinotoriAnchorBank.load(manifestURL: fixture.manifest)) { error in
            guard case let HinotoriCoreMLError.invalidAnchorBank(reason) = error else {
                return XCTFail("予期しないエラー: \(error)")
            }
            XCTAssertTrue(reason.contains("SHA-256"))
        }
    }

    func testLoadsManifestHashedVocabulary() throws {
        let fixture = try writeVocabularyFixture(labels: labels(count: 229))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let vocabulary = try HinotoriVocabulary.load(manifestURL: fixture.manifest)

        XCTAssertEqual(try vocabulary.label(for: 0), "symbol-0")
        XCTAssertEqual(try vocabulary.label(for: 228), "symbol-228")
    }

    func testRejectsVocabularyHashMismatch() throws {
        let fixture = try writeVocabularyFixture(labels: labels(count: 229))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Data("{\"labels\":[]}".utf8).write(to: fixture.vocabulary)

        assertInvalidVocabulary(try HinotoriVocabulary.load(manifestURL: fixture.manifest), contains: "SHA-256")
    }

    func testRejectsDuplicateVocabularyLabels() throws {
        var duplicateLabels = labels(count: 229)
        duplicateLabels[228] = duplicateLabels[0]
        let fixture = try writeVocabularyFixture(labels: duplicateLabels)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        assertInvalidVocabulary(try HinotoriVocabulary.load(manifestURL: fixture.manifest), contains: "重複")
    }

    func testRejectsVocabularyWithFewerOrMoreThan229Labels() throws {
        let fewer = try writeVocabularyFixture(labels: labels(count: 228))
        defer { try? FileManager.default.removeItem(at: fewer.directory) }
        assertInvalidVocabulary(try HinotoriVocabulary.load(manifestURL: fewer.manifest), contains: "229件")

        let more = try writeVocabularyFixture(labels: labels(count: 230))
        defer { try? FileManager.default.removeItem(at: more.directory) }
        assertInvalidVocabulary(try HinotoriVocabulary.load(manifestURL: more.manifest), contains: "229件")
    }

    private func writeAnchorFixture(classIndices: [Int]) throws -> (directory: URL, manifest: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var points = Data()
        for index in 0..<(229 * 32 * 2) {
            appendFloat32(index == 0 ? 1.5 : 0, to: &points)
        }
        var valid = Data()
        for _ in 0..<229 { appendFloat32(1, to: &valid) }
        var classes = Data()
        for classIndex in classIndices { appendInt64(Int64(classIndex), to: &classes) }

        let pointPath = directory.appendingPathComponent("HinotoriAnchorPoints.f32le")
        let validPath = directory.appendingPathComponent("HinotoriAnchorStrokeValid.f32le")
        let classesPath = directory.appendingPathComponent("HinotoriAnchorClasses.i64le")
        try points.write(to: pointPath)
        try valid.write(to: validPath)
        try classes.write(to: classesPath)
        let manifest: [String: Any] = [
            "format": "hinotori-retrieval-coreml-v1",
            "anchorBank": [
                "count": 229,
                "maxStrokes": 1,
                "pointCount": 32,
                "pointDimension": 2,
                "classes": 229,
                "arrays": [
                    "anchorPoints": descriptor(path: pointPath.lastPathComponent, data: points, dtype: "float32-le", shape: [229, 1, 32, 2]),
                    "anchorStrokeValid": descriptor(path: validPath.lastPathComponent, data: valid, dtype: "float32-le", shape: [229, 1]),
                    "anchorClasses": descriptor(path: classesPath.lastPathComponent, data: classes, dtype: "int64-le", shape: [229]),
                ],
            ],
        ]
        let manifestPath = directory.appendingPathComponent("HinotoriCoreML.manifest.json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestPath)
        return (directory, manifestPath)
    }

    private func descriptor(path: String, data: Data, dtype: String, shape: [Int]) -> [String: Any] {
        ["path": path, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), "dtype": dtype, "shape": shape]
    }

    private func writeVocabularyFixture(labels: [String]) throws -> (directory: URL, manifest: URL, vocabulary: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let vocabulary = directory.appendingPathComponent("HinotoriVocabulary.json")
        let vocabularyData = try JSONSerialization.data(withJSONObject: ["labels": labels], options: [.sortedKeys])
        try vocabularyData.write(to: vocabulary)
        let manifest: [String: Any] = [
            "format": "hinotori-retrieval-coreml-v1",
            "vocabulary": [
                "path": vocabulary.lastPathComponent,
                "sha256": SHA256.hash(data: vocabularyData).map { String(format: "%02x", $0) }.joined(),
                "classes": 229,
            ],
        ]
        let manifestURL = directory.appendingPathComponent("HinotoriCoreML.manifest.json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL)
        return (directory, manifestURL, vocabulary)
    }

    private func labels(count: Int) -> [String] {
        (0..<count).map { "symbol-\($0)" }
    }

    private func assertInvalidVocabulary<T>(_ expression: @autoclosure () throws -> T, contains expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case let HinotoriCoreMLError.invalidVocabulary(reason) = error else {
                return XCTFail("予期しないエラー: \(error)", file: file, line: line)
            }
            XCTAssertTrue(reason.contains(expected), "\(reason)", file: file, line: line)
        }
    }

    private func appendFloat32(_ value: Float32, to data: inout Data) {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }

    private func appendInt64(_ value: Int64, to data: inout Data) {
        var bits = UInt64(bitPattern: value).littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
}

final class FormulaStructureComposerTests: XCTestCase {
    func testExplicitStructuresProduceStrictLatexAndValidatedMathML() throws {
        let structure = FormulaStructure(
            rootID: "root",
            candidates: [
                .init(id: "a", label: "a"), .init(id: "b", label: "b"),
                .init(id: "x", label: "x"), .init(id: "two", label: "2"),
                .init(id: "y", label: "y"), .init(id: "i", label: "i"),
                .init(id: "z", label: "z"),
                .init(id: "fracOperator", label: "\\frac"),
                .init(id: "sqrtOperator", label: "\\sqrt"),
            ],
            nodes: [
                .init(id: "root", kind: .sequence, children: ["fraction", "sup", "sub", "sqrt"]),
                .init(id: "fraction", kind: .fraction, operatorCandidateID: "fracOperator", children: ["a", "b"]),
                .init(id: "sup", kind: .superscript, children: ["x", "two"]),
                .init(id: "sub", kind: .subscripted, children: ["y", "i"]),
                .init(id: "sqrt", kind: .squareRoot, operatorCandidateID: "sqrtOperator", children: ["z"]),
                .init(id: "a", kind: .symbol, candidateID: "a"),
                .init(id: "b", kind: .symbol, candidateID: "b"),
                .init(id: "x", kind: .symbol, candidateID: "x"),
                .init(id: "two", kind: .symbol, candidateID: "two"),
                .init(id: "y", kind: .symbol, candidateID: "y"),
                .init(id: "i", kind: .symbol, candidateID: "i"),
                .init(id: "z", kind: .symbol, candidateID: "z"),
            ]
        )

        let result = try FormulaStructureComposer().compose(structure)

        XCTAssertEqual(result.latex, "\\frac{a}{b}{x}^{2}{y}_{i}\\sqrt{z}")
        XCTAssertTrue(result.mathML.contains("<mfrac>"))
        XCTAssertTrue(result.mathML.contains("<msup>"))
        XCTAssertTrue(result.mathML.contains("<msub>"))
        XCTAssertTrue(result.mathML.contains("<msqrt>"))
        XCTAssertNoThrow(try MathMLValidator().validate(result.mathML))
    }

    func testRejectsUnknownReferenceCycleAndUnconnectedNode() {
        assertError(
            FormulaStructure(rootID: "root", candidates: [.init(id: "x", label: "x")], nodes: [
                .init(id: "root", kind: .sequence, children: ["missing"]),
            ]),
            equals: .unknownChild(nodeID: "root", childID: "missing")
        )
        assertError(
            FormulaStructure(rootID: "root", candidates: [.init(id: "x", label: "x")], nodes: [
                .init(id: "root", kind: .sequence, children: ["loop"]),
                .init(id: "loop", kind: .sequence, children: ["root"]),
            ]),
            equals: .cycle(["root", "loop", "root"])
        )
        assertError(
            FormulaStructure(rootID: "x", candidates: [.init(id: "x", label: "x"), .init(id: "y", label: "y")], nodes: [
                .init(id: "x", kind: .symbol, candidateID: "x"),
                .init(id: "y", kind: .symbol, candidateID: "y"),
            ]),
            equals: .unconnectedNode("y")
        )
    }

    func testRejectsInvalidArityCandidateReuseAndUnusedCandidate() {
        assertError(
            FormulaStructure(rootID: "fraction", candidates: [.init(id: "x", label: "x")], nodes: [
                .init(id: "fraction", kind: .fraction, children: ["x"]),
                .init(id: "x", kind: .symbol, candidateID: "x"),
            ]),
            equals: .invalidArity(nodeID: "fraction", kind: .fraction, expected: "2", actual: 1)
        )
        assertError(
            FormulaStructure(rootID: "root", candidates: [.init(id: "x", label: "x")], nodes: [
                .init(id: "root", kind: .sequence, children: ["left", "right"]),
                .init(id: "left", kind: .symbol, candidateID: "x"),
                .init(id: "right", kind: .symbol, candidateID: "x"),
            ]),
            equals: .reusedCandidate("x")
        )
        assertError(
            FormulaStructure(rootID: "x", candidates: [.init(id: "x", label: "x"), .init(id: "y", label: "y")], nodes: [
                .init(id: "x", kind: .symbol, candidateID: "x"),
            ]),
            equals: .unusedCandidate("y")
        )
    }

    func testRejectsCompoundCandidateLabelInsteadOfInterpretingItAsStructure() {
        assertError(
            FormulaStructure(rootID: "x", candidates: [.init(id: "x", label: "x^2")], nodes: [
                .init(id: "x", kind: .symbol, candidateID: "x"),
            ]),
            equals: .invalidCandidateLabel(candidateID: "x", label: "x^2")
        )
    }

    func testRejectsMissingOrMislabeledStructuralOperator() {
        assertError(
            FormulaStructure(rootID: "sqrt", candidates: [.init(id: "x", label: "x")], nodes: [
                .init(id: "sqrt", kind: .squareRoot, children: ["x"]),
                .init(id: "x", kind: .symbol, candidateID: "x"),
            ]),
            equals: .missingOperatorCandidate(nodeID: "sqrt", expectedLabel: "\\sqrt")
        )
        assertError(
            FormulaStructure(rootID: "fraction", candidates: [.init(id: "minus", label: "-"), .init(id: "a", label: "a"), .init(id: "b", label: "b")], nodes: [
                .init(id: "fraction", kind: .fraction, operatorCandidateID: "minus", children: ["a", "b"]),
                .init(id: "a", kind: .symbol, candidateID: "a"),
                .init(id: "b", kind: .symbol, candidateID: "b"),
            ]),
            equals: .invalidOperatorCandidate(nodeID: "fraction", candidateID: "minus", expectedLabel: "\\frac", actualLabel: "-")
        )
    }

    func testEditorBuildsNestedFractionSquareRootAndSubscriptBeforeFinalVerification() throws {
        let editor = FormulaStructureEditor()
        var draft = try editor.makeDraft(labels: ["\\frac", "a", "b", "c", "\\sqrt", "d", "i"])

        XCTAssertThrowsError(try FormulaStructureComposer().compose(draft))

        draft = try editor.combine(
            draft,
            in: draft.rootID,
            kind: .sequence,
            selectedNodeIDs: ["symbol-1", "symbol-2"]
        )
        let numeratorID = try XCTUnwrap(rootChildren(of: draft).first(where: { $0.hasPrefix("structure-sequence-") }))
        draft = try editor.combine(
            draft,
            in: draft.rootID,
            kind: .fraction,
            selectedNodeIDs: ["symbol-0", numeratorID, "symbol-3"]
        )
        draft = try editor.combine(
            draft,
            in: draft.rootID,
            kind: .squareRoot,
            selectedNodeIDs: ["symbol-4", "symbol-5"]
        )
        let squareRootID = try XCTUnwrap(rootChildren(of: draft).first(where: { $0.hasPrefix("structure-squareRoot-") }))
        draft = try editor.combine(
            draft,
            in: draft.rootID,
            kind: .subscripted,
            selectedNodeIDs: [squareRootID, "symbol-6"]
        )

        let result = try FormulaStructureComposer().compose(draft)
        XCTAssertEqual(result.latex, "\\frac{ab}{c}{\\sqrt{d}}_{i}")
        XCTAssertTrue(result.mathML.contains("<mfrac>"))
        XCTAssertTrue(result.mathML.contains("<msqrt>"))
        XCTAssertTrue(result.mathML.contains("<msub>"))
    }

    func testEditorRejectsDuplicateSiblingSelection() throws {
        let draft = try FormulaStructureEditor().makeDraft(labels: ["a", "b"])
        XCTAssertThrowsError(
            try FormulaStructureEditor().combine(
                draft,
                in: draft.rootID,
                kind: .sequence,
                selectedNodeIDs: ["symbol-0", "symbol-0"]
            )
        ) { error in
            XCTAssertEqual(error as? FormulaStructureEditingError, .duplicateSelection("symbol-0"))
        }
    }

    private func rootChildren(of structure: FormulaStructure) -> [String] {
        structure.nodes.first(where: { $0.id == structure.rootID })?.children ?? []
    }

    private func assertError(_ structure: FormulaStructure, equals expected: FormulaStructureError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try FormulaStructureComposer().compose(structure), file: file, line: line) { error in
            XCTAssertEqual(error as? FormulaStructureError, expected, file: file, line: line)
        }
    }
}

final class Inf6SpatialRelationAnalyzerTests: XCTestCase {
    func testPreservesSourceCoordinatesCandidateLogitsAndUserConfirmedProposals() throws {
        let strokes = [
            HinotoriStroke(points: [CGPoint(x: 10, y: 50), CGPoint(x: 20, y: 70)]),
            HinotoriStroke(points: [CGPoint(x: 24, y: 20), CGPoint(x: 28, y: 30)]),
            HinotoriStroke(points: [CGPoint(x: 12, y: 40), CGPoint(x: 50, y: 40)]),
        ]
        let analysis = try Inf6SpatialRelationAnalyzer.analyze(
            groups: [[0], [1], [2]],
            candidates: [
                [.init(classIndex: 10, label: "x", logit: 2.0)],
                [.init(classIndex: 11, label: "i", logit: 1.5)],
                [.init(classIndex: 12, label: "-", logit: 0.8), .init(classIndex: 13, label: "\\frac", logit: 0.4)],
            ],
            strokes: strokes
        )

        XCTAssertEqual(analysis.coordinateSpace.specificationVersion, "hinotori-spatial-v1")
        XCTAssertEqual(analysis.coordinateSpace.origin, "PencilKit-canvas-top-left")
        XCTAssertEqual(analysis.symbols[2].strokeIndices, [2])
        XCTAssertEqual(analysis.symbols[2].candidates.map(\.label), ["-", "\\frac"])
        XCTAssertEqual(analysis.symbols[2].candidates.map(\.logit), [0.8, 0.4])
        XCTAssertEqual(analysis.symbols[0].sourceBounds.minX, 10)
        XCTAssertTrue(analysis.proposals.contains(where: { $0.kind == .superscriptCandidate && $0.sourceSymbolID == "symbol-0" && $0.targetSymbolID == "symbol-1" }))
        XCTAssertEqual(analysis.proposals.first(where: { $0.kind == .fractionBarCandidate && $0.sourceSymbolID == "symbol-2" }).flatMap { Inf6SpatialRelationAnalyzer.rank(of: $0, in: analysis) }, 0)
        XCTAssertEqual(analysis.proposals.first(where: { $0.kind == .minusCandidate && $0.sourceSymbolID == "symbol-2" }).flatMap { Inf6SpatialRelationAnalyzer.rank(of: $0, in: analysis) }, 1)
        XCTAssertEqual(analysis.proposals.first(where: { $0.kind == .underlineCandidate && $0.sourceSymbolID == "symbol-2" }).flatMap { Inf6SpatialRelationAnalyzer.rank(of: $0, in: analysis) }, 2)
        XCTAssertNoThrow(try Inf6SpatialRelationAnalyzer.validate(
            analysis,
            symbolLabels: ["x", "i", "-"],
            symbolStrokeIndices: [[0], [1], [2]]
        ))
        XCTAssertThrowsError(try Inf6SpatialRelationAnalyzer.validate(
            analysis,
            symbolLabels: ["x", "i", "="],
            symbolStrokeIndices: [[0], [1], [2]]
        ))
    }

    func testRejectsGroupAndCandidateContractMismatch() {
        XCTAssertThrowsError(
            try Inf6SpatialRelationAnalyzer.analyze(
                groups: [[0]],
                candidates: [],
                strokes: [HinotoriStroke(points: [CGPoint(x: 0, y: 0)])]
            )
        ) { error in
            XCTAssertEqual(error as? Inf6SpatialRelationError, .groupCandidateCountMismatch(groups: 1, candidates: 0))
        }
    }

    func testLineRoleRankChangesToUnderlineWhenOnlySymbolsAreStrictlyAbove() throws {
        let analysis = try Inf6SpatialRelationAnalyzer.analyze(
            groups: [[0], [1]],
            candidates: [
                [.init(classIndex: 10, label: "x", logit: 2.0)],
                [.init(classIndex: 12, label: "-", logit: 0.8)],
            ],
            strokes: [
                HinotoriStroke(points: [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 20)]),
                HinotoriStroke(points: [CGPoint(x: 8, y: 40), CGPoint(x: 32, y: 40)]),
            ]
        )

        XCTAssertEqual(analysis.proposals.first(where: { $0.kind == .underlineCandidate && $0.sourceSymbolID == "symbol-1" }).flatMap { Inf6SpatialRelationAnalyzer.rank(of: $0, in: analysis) }, 0)
        XCTAssertEqual(analysis.proposals.first(where: { $0.kind == .minusCandidate && $0.sourceSymbolID == "symbol-1" }).flatMap { Inf6SpatialRelationAnalyzer.rank(of: $0, in: analysis) }, 1)
        XCTAssertEqual(analysis.proposals.first(where: { $0.kind == .fractionBarCandidate && $0.sourceSymbolID == "symbol-1" }).flatMap { Inf6SpatialRelationAnalyzer.rank(of: $0, in: analysis) }, 2)
    }

    func testPositionSensitiveClassifierReordersOnlyExistingHorizontalBarCandidates() throws {
        let analysis = try Inf6SpatialRelationAnalyzer.analyze(
            groups: [[0], [1], [2]],
            candidates: [
                [.init(classIndex: 1, label: "a", logit: 1)],
                [.init(classIndex: 2, label: "b", logit: 1)],
                [.init(classIndex: 3, label: "-", logit: 3), .init(classIndex: 4, label: "\\frac", logit: 2)],
            ],
            strokes: [
                HinotoriStroke(points: [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 20)]),
                HinotoriStroke(points: [CGPoint(x: 10, y: 60), CGPoint(x: 20, y: 70)]),
                HinotoriStroke(points: [CGPoint(x: 5, y: 40), CGPoint(x: 30, y: 40)]),
            ]
        )
        let classification = Inf6PositionSensitiveSymbolClassifier.classify(
            analysis: analysis,
            subset: .init(
                schema: "hinotori-position-sensitive-subset-v1",
                sourceVocabulary: "test",
                sourceVocabularyContract: "hinotori-v1",
                groups: [.init(id: "horizontal-bar", labels: ["-", "\\frac", "\\underline", "\\overline"], positionEvidence: [], candidateInterpretations: [])]
            )
        )

        XCTAssertEqual(classification.symbols[2].originalCandidateClassIndices, [3, 4])
        XCTAssertEqual(classification.symbols[2].reorderedCandidateClassIndices, [4, 3])
        XCTAssertFalse(classification.symbols[2].confirmed)
    }

    func testPositionSensitiveClassifierDoesNotPromoteFamilyCandidateAboveUnrelatedTopOne() throws {
        let analysis = try Inf6SpatialRelationAnalyzer.analyze(
            groups: [[0], [1], [2]],
            candidates: [
                [.init(classIndex: 10, label: "a", logit: 4), .init(classIndex: 12, label: "-", logit: 3), .init(classIndex: 11, label: "\\frac", logit: 2)],
                [.init(classIndex: 20, label: "x", logit: 1)],
                [.init(classIndex: 21, label: "y", logit: 1)],
            ],
            strokes: [
                HinotoriStroke(points: [CGPoint(x: 5, y: 40), CGPoint(x: 95, y: 40)]),
                HinotoriStroke(points: [CGPoint(x: 20, y: 10), CGPoint(x: 35, y: 25)]),
                HinotoriStroke(points: [CGPoint(x: 65, y: 60), CGPoint(x: 80, y: 75)]),
            ]
        )
        let classification = Inf6PositionSensitiveSymbolClassifier.classify(
            analysis: analysis,
            subset: .init(
                schema: "hinotori-position-sensitive-subset-v1",
                sourceVocabulary: "test",
                sourceVocabularyContract: "hinotori-v1",
                groups: [.init(id: "horizontal-bar", labels: ["-", "\\frac", "\\underline", "\\overline"], positionEvidence: [], candidateInterpretations: [])]
            )
        )

        XCTAssertEqual(classification.symbols[0].reorderedCandidateClassIndices, [10, 11, 12])
        XCTAssertEqual(classification.symbols[0].candidateChoiceClassIndices, [10, 11, 12])
    }

    func testPositionSensitiveClassifierUsesExistingDotCandidateWhenMarkIsAboveBase() throws {
        let analysis = try Inf6SpatialRelationAnalyzer.analyze(
            groups: [[0], [1]],
            candidates: [
                [.init(classIndex: 1, label: ".", logit: 3), .init(classIndex: 2, label: "\\dot", logit: 2)],
                [.init(classIndex: 3, label: "x", logit: 1)],
            ],
            strokes: [
                HinotoriStroke(points: [CGPoint(x: 12, y: 10)]),
                HinotoriStroke(points: [CGPoint(x: 10, y: 30), CGPoint(x: 20, y: 50)]),
            ]
        )
        let classification = Inf6PositionSensitiveSymbolClassifier.classify(
            analysis: analysis,
            subset: .init(
                schema: "hinotori-position-sensitive-subset-v1",
                sourceVocabulary: "test",
                sourceVocabularyContract: "hinotori-v1",
                groups: [.init(id: "dot-mark", labels: [".", "\\dot", "\\cdot", "\\vdots"], positionEvidence: [], candidateInterpretations: [])]
            )
        )

        XCTAssertEqual(classification.symbols[0].reorderedCandidateClassIndices, [2, 1])
        XCTAssertFalse(classification.symbols[0].confirmed)
    }

    func testPositionSensitiveClassifierPrefersColonForVerticallyAlignedDotPair() throws {
        let analysis = try Inf6SpatialRelationAnalyzer.analyze(
            groups: [[0], [1], [2]],
            candidates: [
                [.init(classIndex: 1, label: ",", logit: 3), .init(classIndex: 2, label: ":", logit: 2), .init(classIndex: 3, label: ";", logit: 1)],
                [.init(classIndex: 4, label: ".", logit: 1)],
                [.init(classIndex: 5, label: "x", logit: 1)],
            ],
            strokes: [
                HinotoriStroke(points: [CGPoint(x: 50, y: 50)]),
                HinotoriStroke(points: [CGPoint(x: 50, y: 30)]),
                HinotoriStroke(points: [CGPoint(x: 10, y: 40), CGPoint(x: 40, y: 60)]),
            ]
        )
        let classification = Inf6PositionSensitiveSymbolClassifier.classify(
            analysis: analysis,
            subset: .init(schema: "hinotori-position-sensitive-subset-v1", sourceVocabulary: "test", sourceVocabularyContract: "hinotori-v1", groups: [.init(id: "punctuation-mark", labels: [",", ":", ";"], positionEvidence: [], candidateInterpretations: [])])
        )

        XCTAssertEqual(classification.symbols[0].reorderedCandidateClassIndices, [2, 3, 1])
    }

    func testPositionSensitiveClassifierPrefersDisplaySetOperatorWithLimits() throws {
        let analysis = try Inf6SpatialRelationAnalyzer.analyze(
            groups: [[0], [1], [2], [3], [4]],
            candidates: [
                [.init(classIndex: 1, label: "\\cup", logit: 3), .init(classIndex: 2, label: "\\bigcup", logit: 2)],
                [.init(classIndex: 3, label: "n", logit: 1)],
                [.init(classIndex: 4, label: "i", logit: 1)],
                [.init(classIndex: 5, label: "A", logit: 1)],
                [.init(classIndex: 6, label: "B", logit: 1)],
            ],
            strokes: [
                HinotoriStroke(points: [CGPoint(x: 40, y: 40), CGPoint(x: 70, y: 90)]),
                HinotoriStroke(points: [CGPoint(x: 45, y: 10), CGPoint(x: 60, y: 25)]),
                HinotoriStroke(points: [CGPoint(x: 45, y: 105), CGPoint(x: 60, y: 120)]),
                HinotoriStroke(points: [CGPoint(x: 5, y: 55), CGPoint(x: 30, y: 75)]),
                HinotoriStroke(points: [CGPoint(x: 85, y: 55), CGPoint(x: 110, y: 75)]),
            ]
        )
        let classification = Inf6PositionSensitiveSymbolClassifier.classify(
            analysis: analysis,
            subset: .init(schema: "hinotori-position-sensitive-subset-v1", sourceVocabulary: "test", sourceVocabularyContract: "hinotori-v1", groups: [.init(id: "scalable-set-operator", labels: ["\\bigcup", "\\cup"], positionEvidence: [], candidateInterpretations: [])])
        )

        XCTAssertEqual(classification.symbols[0].reorderedCandidateClassIndices, [2, 1])
    }

    func testPositionSensitiveClassifierPrefersRootForCoveredRadicand() throws {
        let analysis = try Inf6SpatialRelationAnalyzer.analyze(
            groups: [[0], [1]],
            candidates: [
                [.init(classIndex: 1, label: "=", logit: 4), .init(classIndex: 2, label: "\\sum", logit: 3), .init(classIndex: 3, label: "\\int", logit: 2), .init(classIndex: 4, label: "\\sqrt", logit: 1)],
                [.init(classIndex: 5, label: "x", logit: 1)],
            ],
            strokes: [
                HinotoriStroke(points: [CGPoint(x: 10, y: 30), CGPoint(x: 90, y: 70)]),
                HinotoriStroke(points: [CGPoint(x: 35, y: 35), CGPoint(x: 80, y: 65)]),
            ]
        )
        let classification = Inf6PositionSensitiveSymbolClassifier.classify(
            analysis: analysis,
            subset: .init(schema: "hinotori-position-sensitive-subset-v1", sourceVocabulary: "test", sourceVocabularyContract: "hinotori-v1", groups: [.init(id: "operand-scope-operator", labels: ["=", "\\sqrt", "\\int", "\\sum"], positionEvidence: [], candidateInterpretations: [])])
        )

        XCTAssertEqual(classification.symbols[0].reorderedCandidateClassIndices, [4, 1, 2, 3])
    }

    func testPositionRuleSupplementsRemainSeparateFromModelCandidates() throws {
        let analysis = try Inf6SpatialRelationAnalyzer.analyze(
            groups: [[0], [1], [2]],
            candidates: [
                [.init(classIndex: 0, label: "-", logit: 3)],
                [.init(classIndex: 4, label: "a", logit: 1)],
                [.init(classIndex: 5, label: "b", logit: 1)],
            ],
            strokes: [
                HinotoriStroke(points: [CGPoint(x: 10, y: 40), CGPoint(x: 80, y: 40)]),
                HinotoriStroke(points: [CGPoint(x: 25, y: 10), CGPoint(x: 45, y: 25)]),
                HinotoriStroke(points: [CGPoint(x: 25, y: 60), CGPoint(x: 45, y: 75)]),
            ]
        )
        var labels = (0..<229).map { "test-\($0)" }
        labels[0] = "-"
        labels[1] = "\\frac"
        labels[2] = "\\underline"
        labels[3] = "\\overline"
        labels[4] = "a"
        labels[5] = "b"
        let vocabulary = try HinotoriVocabulary(labels: labels)
        let classification = Inf6PositionSensitiveSymbolClassifier.classify(
            analysis: analysis,
            subset: .init(schema: "hinotori-position-sensitive-subset-v1", sourceVocabulary: "test", sourceVocabularyContract: "hinotori-v1", groups: [.init(id: "horizontal-bar", labels: ["-", "\\frac", "\\underline", "\\overline"], positionEvidence: [], candidateInterpretations: [])]),
            vocabulary: vocabulary
        )

        XCTAssertEqual(classification.symbols[0].originalCandidateClassIndices, [0])
        XCTAssertEqual(classification.symbols[0].reorderedCandidateClassIndices, [0])
        XCTAssertEqual(classification.symbols[0].ruleSupplements?.map(\.label), ["\\frac", "\\underline", "\\overline"])
        XCTAssertTrue(classification.symbols[0].ruleSupplements?.allSatisfy { $0.origin == "position-rule-supplement" } == true)
    }
}
