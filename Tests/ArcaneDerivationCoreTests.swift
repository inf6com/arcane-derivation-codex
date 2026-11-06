import XCTest
import PencilKit
import CoreML
@testable import inf6

final class ArcaneDerivationCoreTests: XCTestCase {
    func testCanonicalSampleUsesStableInterchangeContract() throws {
        let sample = try Inf6CanonicalSample(
            traces: [[
                Inf6CanonicalSample.Point(x: 397, y: 146),
                Inf6CanonicalSample.Point(x: 640, y: 457),
            ]],
            strokeOrder: [0],
            sourceBounds: Inf6CanonicalSample.Bounds(minX: 397, minY: 146, maxX: 640, maxY: 457),
            rowPosition: [0.5, 0.5, 1, 1]
        )
        let restored = try JSONDecoder().decode(
            Inf6CanonicalSample.self,
            from: JSONEncoder().encode(sample)
        )
        XCTAssertEqual(restored, sample)
        XCTAssertEqual(restored.format, Inf6CanonicalSample.formatIdentifier)
        XCTAssertEqual(restored.traces.count, 1)
        XCTAssertEqual(restored.rowPosition.count, 4)
    }

    func testDerivationDocumentPersistsVerifiedMathML() throws {
        let step = DerivationStep(
            expression: "C_{ij}=\\sum_{k=1}^{n}A_{ik}B_{kj}",
            reason: "行列積を成分ごとに展開",
            verifiedUnderstanding: true
        )
        let document = DerivationDocument(
            steps: [step],
            sourceEvidenceID: UUID(),
            sourceTitle: "Attention Is All You Need",
            sourceLocator: "p. 4",
            mathML: try LaTeXMathMLConverter().convert(step.expression),
            mathMLVerified: true,
            recognizedExpression: step.expression,
            recognizedSymbols: ["C", "i", "j", "A", "B"]
        )

        let data = try JSONEncoder().encode(document)
        let restored = try JSONDecoder().decode(DerivationDocument.self, from: data)
        XCTAssertEqual(restored.steps, document.steps)
        XCTAssertEqual(restored.sourceEvidenceID, document.sourceEvidenceID)
        XCTAssertEqual(restored.mathML, document.mathML)
        XCTAssertEqual(restored.mathMLVerified, true)
    }

    func testGeneratedFrameworkCodePersistsExplicitUnverifiedState() throws {
        let entity = Inf6DocEntity(
            kind: .equation,
            pageIndex: 4,
            title: "Eq. (3)",
            snippet: "y = Wx",
            llmPyTorchCode: "import torch\ny = x @ W.T",
            llmTensorFlowCode: "import tensorflow as tf\ny = tf.linalg.matmul(x, W, transpose_b=True)",
            llmCodeVerification: "未実行検証"
        )

        let restored = try JSONDecoder().decode(
            Inf6DocEntity.self,
            from: JSONEncoder().encode(entity)
        )
        XCTAssertEqual(restored.id, entity.id)
        XCTAssertEqual(restored.llmPyTorchCode, entity.llmPyTorchCode)
        XCTAssertEqual(restored.llmTensorFlowCode, entity.llmTensorFlowCode)
        XCTAssertEqual(restored.llmCodeVerification, "未実行検証")
    }

    func testStructuredPaletteFormulaDoesNotRequireGridGeometry() throws {
        let expression = "\\sqrt{\\frac{a}{b}}"
        let document = DerivationDocument(
            mathML: try LaTeXMathMLConverter().convert(expression),
            mathMLVerified: true,
            recognizedExpression: expression,
            recognizedSymbols: [expression],
            inputMethod: .symbolPalette
        )

        let restored = try JSONDecoder().decode(
            DerivationDocument.self,
            from: JSONEncoder().encode(document)
        )
        XCTAssertEqual(restored.inputMethod, .symbolPalette)
        XCTAssertNil(restored.grid9)
        XCTAssertNil(restored.recognizedGridCellIndices)
        XCTAssertEqual(restored.mathML, document.mathML)
    }

    func testHandwrittenFormulaDocumentPreservesGridAndPaperReferences() throws {
        let expression = "\\top"
        let mathML = try LaTeXMathMLConverter().convert(expression)
        let cells = (0..<9).map { index in
            let row = index / 3
            let column = index % 3
            return Inf6FormulaGrid9.Cell(
                index: index + 1,
                row: row,
                column: column,
                strokeCount: index == 4 ? 1 : 0,
                strokeIndices: index == 4 ? [0] : [],
                normalizedBounds: CGRect(
                    x: CGFloat(column) / 3,
                    y: CGFloat(row) / 3,
                    width: 1 / 3,
                    height: 1 / 3
                )
            )
        }
        let document = DerivationDocument(
            mathML: mathML,
            mathMLVerified: true,
            recognizedExpression: expression,
            recognizedSymbols: [expression],
            recognizedGridCellIndices: [5],
            grid9: Inf6FormulaGrid9(cells: cells),
            paperEquationSpaceID: "paper",
            paperEquationID: "equation",
            inputMethod: .handwriting
        )

        let restored = try JSONDecoder().decode(
            DerivationDocument.self,
            from: JSONEncoder().encode(document)
        )
        XCTAssertEqual(restored.mathMLVerified, true)
        XCTAssertEqual(restored.recognizedExpression, expression)
        XCTAssertEqual(restored.recognizedGridCellIndices, [5])
        XCTAssertEqual(restored.grid9?.cells.count, 9)
        XCTAssertEqual(restored.paperEquationSpaceID, "paper")
        XCTAssertEqual(restored.paperEquationID, "equation")
        XCTAssertEqual(restored.inputMethod, .handwriting)
    }

    func testStructuredPaletteSupportsMatrixAndCases() throws {
        let converter = LaTeXMathMLConverter()
        let matrix = try converter.convert("\\begin{matrix}a&b\\\\c&d\\end{matrix}")
        let cases = try converter.convert("\\begin{cases}x&x>0\\\\0&x\\le0\\end{cases}")
        XCTAssertTrue(matrix.contains("<mtable>"))
        XCTAssertTrue(matrix.contains("<mtr>"))
        XCTAssertTrue(cases.contains("<mtable>"))
        XCTAssertTrue(cases.contains(">{</mo>"))
    }

    func testTemmlPreservesGroupedArgumentsAndRejectsDuplicateScripts() throws {
        let converter = LaTeXMathMLConverter()
        let fraction = try converter.convert("\\frac{a+b}{c}")
        XCTAssertTrue(fraction.contains("<mfrac><mrow><mi>a</mi><mo>+</mo><mi>b</mi></mrow><mi>c</mi></mfrac>"))
        let exponent = try converter.convert("x^{a+b}")
        XCTAssertTrue(exponent.contains("<msup><mi>x</mi><mrow"))
        XCTAssertTrue(exponent.contains("<mi>a</mi><mo>+</mo><mi>b</mi></mrow></msup>"))
        XCTAssertThrowsError(try converter.convert("x^2^3"))
        XCTAssertThrowsError(try converter.convert("x_1_2"))
    }

    func testSpatialPositionMapsUpperRightToMathMLSuperscript() throws {
        let base = Inf6FormulaGrid9.Cell(
            index: 5, row: 1, column: 1, strokeCount: 1, strokeIndices: [0],
            normalizedBounds: CGRect(x: 1.0 / 3.0, y: 1.0 / 3.0, width: 1.0 / 3.0, height: 1.0 / 3.0)
        )
        let exponent = Inf6FormulaGrid9.Cell(
            index: 3, row: 0, column: 2, strokeCount: 1, strokeIndices: [1],
            normalizedBounds: CGRect(x: 2.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 1.0 / 3.0)
        )
        let grid = Inf6FormulaGrid9(cells: [base, exponent])

        XCTAssertEqual(grid.relation(from: base, to: exponent), .superscript)
        let mathML = try LaTeXMathMLConverter().convert("X^{2}")
        XCTAssertTrue(mathML.contains("<msup><mi>X</mi><mn class=\"tml-med-pad\">2</mn></msup>"))
    }

    func testPaletteStructureWrapsExistingExpressionAsMathML() throws {
        let expression = Inf6MathMLStructureComposer.apply(
            itemID: "sqrt",
            itemExpression: "\\sqrt{x}",
            to: "X^2"
        )
        XCTAssertEqual(expression, "\\sqrt{X^2}")
        let mathML = try LaTeXMathMLConverter().convert(expression)
        XCTAssertTrue(mathML.contains("<msqrt>"))
        XCTAssertTrue(mathML.contains("<msup><mi>X</mi><mn class=\"tml-med-pad\">2</mn></msup>"))
    }

    func testMathMLValidatorRejectsUnknownElements() {
        XCTAssertThrowsError(try MathMLValidator().validate(
            "<math xmlns=\"http://www.w3.org/1998/Math/MathML\"><unknown>x</unknown></math>"
        ))
    }

    func testDerivationStoreSavesAndReloadsDocumentBelowUserSettingRoot() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let identifier = UUID().uuidString
        let store = DerivationStore(root: root, identifier: identifier)
        let updatedAt = Date(timeIntervalSinceReferenceDate: 731_234_567.1234567)
        try store.save(DerivationDocument(
            sourceTitle: "Selected equation",
            sourceLocator: "p. 4",
            updatedAt: updatedAt
        ))

        let restored = try store.load()
        XCTAssertEqual(restored.sourceTitle, "Selected equation")
        XCTAssertEqual(restored.sourceLocator, "p. 4")
        XCTAssertEqual(restored.updatedAt, updatedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("derivations/\(identifier).json").path))
    }

    func testDerivationStoreSavesAndReloadsFormulaStructure() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let structure = FormulaStructure(
            rootID: "root",
            candidates: [
                .init(id: "fraction", label: "\\frac"),
                .init(id: "a", label: "a"),
                .init(id: "b", label: "b"),
            ],
            nodes: [
                .init(id: "root", kind: .fraction, operatorCandidateID: "fraction", children: ["a", "b"]),
                .init(id: "a", kind: .symbol, candidateID: "a"),
                .init(id: "b", kind: .symbol, candidateID: "b"),
            ]
        )
        _ = try FormulaStructureComposer().compose(structure)
        let spatialAnalysis = try Inf6SpatialRelationAnalyzer.analyze(
            groups: [[0], [1]],
            candidates: [
                [.init(classIndex: 0, label: "a", logit: 1)],
                [.init(classIndex: 1, label: "b", logit: 1)],
            ],
            strokes: [
                .init(points: [CGPoint(x: 10, y: 20), CGPoint(x: 20, y: 30)]),
                .init(points: [CGPoint(x: 25, y: 5), CGPoint(x: 30, y: 12)]),
            ]
        )

        let store = DerivationStore(root: root, identifier: UUID().uuidString)
        try store.save(DerivationDocument(spatialAnalysis: spatialAnalysis, formulaStructure: structure))

        let restored = try store.load()
        XCTAssertEqual(restored.formulaStructure, structure)
        XCTAssertEqual(restored.spatialAnalysis, spatialAnalysis)
    }

    func testNestedFormulaCanBeSavedReloadedAndEdited() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = FormulaStructureEditor()
        var draft = try editor.makeDraft(labels: ["\\frac", "a", "b", "c"])
        draft = try editor.combine(draft, in: draft.rootID, kind: .sequence, selectedNodeIDs: ["symbol-1", "symbol-2"])
        let rootNode = try XCTUnwrap(draft.nodes.first(where: { $0.id == draft.rootID }))
        let numerator = try XCTUnwrap(rootNode.children.first(where: { $0.hasPrefix("structure-sequence-") }))
        draft = try editor.combine(draft, in: draft.rootID, kind: .fraction, selectedNodeIDs: ["symbol-0", numerator, "symbol-3"])
        let before = try FormulaStructureComposer().compose(draft)
        XCTAssertEqual(before.latex, "\\frac{ab}{c}")

        let store = DerivationStore(root: root, identifier: UUID().uuidString)
        try store.save(DerivationDocument(formulaStructure: draft))
        var restored = try XCTUnwrap(store.load().formulaStructure)
        XCTAssertEqual(try FormulaStructureComposer().compose(restored).latex, before.latex)
        restored = try editor.replacingCandidate(restored, candidateID: "candidate-1", label: "x")
        XCTAssertEqual(try FormulaStructureComposer().compose(restored).latex, "\\frac{xb}{c}")
        try store.save(DerivationDocument(formulaStructure: restored))
        let reloaded = try XCTUnwrap(store.load().formulaStructure)
        XCTAssertEqual(try FormulaStructureComposer().compose(reloaded).latex, "\\frac{xb}{c}")
    }

    func testNestedSubexpressionScopeCanBeEnteredAndEditedWithoutChangingMeaning() throws {
        let editor = FormulaStructureEditor()
        var draft = try editor.makeDraft(labels: ["\\frac", "\\frac", "a", "+", "b", "c", "d"])
        draft = try editor.combine(draft, in: draft.rootID, kind: .sequence, selectedNodeIDs: ["symbol-2", "symbol-3", "symbol-4"])
        let rootChildren = try XCTUnwrap(draft.nodes.first(where: { $0.id == draft.rootID })).children
        let numerator = try XCTUnwrap(rootChildren.first(where: { $0.hasPrefix("structure-sequence-") }))
        draft = try editor.combine(draft, in: draft.rootID, kind: .fraction, selectedNodeIDs: ["symbol-1", numerator, "symbol-5"])
        let innerFraction = try XCTUnwrap(draft.nodes.first(where: { $0.kind == .fraction }))
        draft = try editor.combine(draft, in: draft.rootID, kind: .fraction, selectedNodeIDs: ["symbol-0", innerFraction.id, "symbol-6"])
        let expected = "\\frac{\\frac{a+b}{c}}{d}"
        XCTAssertEqual(try FormulaStructureComposer().compose(draft).latex, expected)

        let scope = try editor.editableSequenceScope(draft, nodeID: innerFraction.id)
        XCTAssertEqual(scope.scopeID, innerFraction.id)
        let innerNumeratorSequence = try XCTUnwrap(scope.structure.nodes.first(where: { $0.id == innerFraction.children[0] }))
        let nestedOperandID = try XCTUnwrap(innerNumeratorSequence.children.first)
        let nestedScope = try editor.editableSequenceScope(scope.structure, nodeID: nestedOperandID)
        XCTAssertTrue(nestedScope.scopeID.hasPrefix("scope-sequence-"))
        XCTAssertEqual(try FormulaStructureComposer().compose(nestedScope.structure).latex, expected)

        let nestedNode = try XCTUnwrap(nestedScope.structure.nodes.first(where: { $0.id == nestedScope.scopeID }))
        XCTAssertEqual(nestedNode.kind, .sequence)
        XCTAssertEqual(nestedNode.children, [nestedOperandID])
    }

    func testDerivationStoreSavesAndReloadsNonemptyPencilDrawing() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let identifier = UUID().uuidString
        let drawing = PKDrawing(strokes: [makeStroke(points: [
            CGPoint(x: 10, y: 10),
            CGPoint(x: 20, y: 20),
        ])])
        let store = DerivationStore(root: root, identifier: identifier)
        try store.save(DerivationDocument(pencilDrawingData: drawing.dataRepresentation()))

        let restored = try store.load()
        let restoredDrawing = try PKDrawing(data: try XCTUnwrap(restored.pencilDrawingData))
        XCTAssertEqual(restoredDrawing.strokes.count, 1)
    }

    func testFailedDrawingSavePreservesPriorMathAndEvidence() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DerivationStore(root: root, identifier: UUID().uuidString)
        let drawing = PKDrawing(strokes: [makeStroke(points: [
            CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 20),
        ])])
        var original = DerivationDocument(pencilDrawingData: drawing.dataRepresentation(), mathML: "<math><mi>x</mi></math>")
        original.handwritingEvidence = Data("original-evidence".utf8)
        try store.save(original)

        var invalid = original
        invalid.pencilDrawingData = Data("invalid".utf8)
        invalid.mathML = "<math><mi>y</mi></math>"
        invalid.handwritingEvidence = Data("new-evidence".utf8)
        XCTAssertThrowsError(try store.save(invalid))

        let restored = try store.load()
        XCTAssertEqual(restored.mathML, original.mathML)
        XCTAssertEqual(restored.handwritingEvidence, original.handwritingEvidence)
        XCTAssertEqual(restored.pencilDrawingData, original.pencilDrawingData)
    }

    func testDerivationStoreRejectsInvalidPencilDrawingOnReload() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let identifier = UUID().uuidString
        let derivations = root.appendingPathComponent("derivations", isDirectory: true)
        try FileManager.default.createDirectory(at: derivations, withIntermediateDirectories: true)
        let document = DerivationDocument(pencilDrawingData: Data("not-a-pencil-drawing".utf8))
        try JSONEncoder().encode(document)
            .write(to: derivations.appendingPathComponent("\(identifier).json"), options: .atomic)

        XCTAssertThrowsError(try DerivationStore(root: root, identifier: identifier).load()) { error in
            XCTAssertEqual(error.localizedDescription, DerivationError.invalidPencilDrawingData.localizedDescription)
        }
    }

    func testDerivationStoreSavesAndReloadsPaperSupplement() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let evidenceID = UUID()
        let supplement = PaperSupplement(
            sourceEvidenceID: evidenceID,
            sourceTitle: "Attention Is All You Need",
            sourceLocator: "p. 4",
            mathML: try LaTeXMathMLConverter().convert("QK^T"),
            derivationSteps: [DerivationStep(expression: "QK^T", reason: "QueryとKeyの積")]
        )
        let store = DerivationStore(root: root, identifier: evidenceID.uuidString)
        try store.saveSupplement(supplement)

        let restored = try XCTUnwrap(store.loadSupplement(sourceEvidenceID: evidenceID))
        XCTAssertEqual(restored.sourceEvidenceID, evidenceID)
        XCTAssertEqual(restored.sourceTitle, supplement.sourceTitle)
        XCTAssertEqual(restored.derivationSteps, supplement.derivationSteps)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("supplements/\(evidenceID.uuidString).json").path))
    }

    func testDerivationStoreFailsWhenUserSettingRootIsUnavailable() {
        XCTAssertThrowsError(try DerivationStore(root: nil).save(DerivationDocument())) { error in
            XCTAssertEqual(error.localizedDescription, DerivationError.rootUnavailable.localizedDescription)
        }
    }

    func testDerivationStoreSurfacesMalformedPersistedJSON() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let identifier = UUID().uuidString
        let derivations = root.appendingPathComponent("derivations", isDirectory: true)
        try FileManager.default.createDirectory(at: derivations, withIntermediateDirectories: true)
        try Data("{\"sourceTitle\":\"broken\"".utf8)
            .write(to: derivations.appendingPathComponent("\(identifier).json"), options: .atomic)

        XCTAssertThrowsError(try DerivationStore(root: root, identifier: identifier).load()) { error in
            XCTAssertTrue(error is DecodingError, "破損した保存JSONはDecodingErrorとして表面化する必要があります")
        }
    }

    func testDerivationStoreSurfacesMalformedSupplementJSON() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let evidenceID = UUID()
        let supplements = root.appendingPathComponent("supplements", isDirectory: true)
        try FileManager.default.createDirectory(at: supplements, withIntermediateDirectories: true)
        try Data("{\"sourceTitle\":\"broken\"".utf8)
            .write(to: supplements.appendingPathComponent("\(evidenceID.uuidString).json"), options: .atomic)

        XCTAssertThrowsError(try DerivationStore(root: root).loadSupplement(sourceEvidenceID: evidenceID)) { error in
            XCTAssertTrue(error is DecodingError, "破損した補足成果物JSONはDecodingErrorとして表面化する必要があります")
        }
    }

    func testMathMLValidationRejectsWrongRoot() {
        XCTAssertThrowsError(try MathMLValidator().validate("<div>x</div>")) { error in
            XCTAssertEqual(error.localizedDescription, MathMLError.missingMathRoot.localizedDescription)
        }
    }

    func testMathMLValidationRejectsExecutableElements() {
        XCTAssertThrowsError(try MathMLValidator().validate("<math><script>alert(1)</script></math>")) { error in
            XCTAssertEqual(error.localizedDescription, MathMLError.forbiddenElement("script").localizedDescription)
        }
    }

    func testMathMLValidationRejectsMalformedSavedValue() {
        XCTAssertThrowsError(try MathMLValidator().validate("<math><mrow><mi>x</math>")) { error in
            guard case MathMLError.malformed = error else {
                return XCTFail("保存済みMathMLの構文エラーをMathMLError.malformedとして返す必要があります")
            }
        }
    }

    func testRecognizedLatexConvertsToValidatedMathML() throws {
        let mathML = try LaTeXMathMLConverter().convert("C_{ij}=\\sum_{k=1}^{n}A_{ik}B_{kj}")
        XCTAssertTrue(mathML.contains("<msub>"))
        XCTAssertTrue(mathML.contains("∑"))
        XCTAssertNoThrow(try MathMLValidator().validate(mathML))
    }

    func testTexTellerSyntaxTreeConvertsHatToValidatedMathML() throws {
        let mathML = try TexTellerSyntaxTree(expression: "\\hat{v}").mathML()
        XCTAssertTrue(mathML.contains("<mover accent=\"true\">") )
        XCTAssertTrue(mathML.contains("<mi>v</mi>"))
        XCTAssertNoThrow(try MathMLValidator().validate(mathML))
    }

    func testLatexConverterRejectsUnsupportedCommand() {
        XCTAssertThrowsError(try LaTeXMathMLConverter().convert("\\unknown{x}")) { error in
            guard case LaTeXMathMLError.invalidExpression = error else {
                return XCTFail("未知コマンドは数式変換エラーになる必要があります: \(error)")
            }
        }
    }

    func testPaperEquationSpaceRejectsMissingReferences() {
        let space = PaperEquationSpace(
            id: "attention",
            paperTitle: "Attention Is All You Need",
            version: "2017",
            pages: [PaperEquationPage(id: "p4", pageIndex: 4, equationIDs: ["missing"])],
            equations: []
        )

        XCTAssertThrowsError(try space.validated()) { error in
            XCTAssertEqual(error.localizedDescription, PaperEquationSpaceError.missingEquationReference("p4").localizedDescription)
        }
    }

    func testPaperEquationSpaceRejectsEquationWithMissingPage() {
        let equation = PaperEquation(
            id: "eq1",
            pageID: "missing-page",
            sourceLocator: "attention#page=4",
            latex: "x",
            mathML: "<math xmlns=\"http://www.w3.org/1998/Math/MathML\"><mi>x</mi></math>"
        )
        let space = PaperEquationSpace(
            id: "attention",
            paperTitle: "Attention Is All You Need",
            version: "2017",
            pages: [PaperEquationPage(id: "p4", pageIndex: 4, equationIDs: ["eq1"])],
            equations: [equation]
        )

        XCTAssertThrowsError(try space.validated()) { error in
            XCTAssertEqual(error.localizedDescription, PaperEquationSpaceError.missingPageReference("eq1").localizedDescription)
        }
    }

    func testHandwrittenRecognitionRejectsPunctuationOnlyCandidates() {
        XCTAssertFalse(Inf6NonAutoregressiveSymbolRecognizer.containsMeaningfulToken(in: [".", "."]))
        XCTAssertFalse(Inf6NonAutoregressiveSymbolRecognizer.containsMeaningfulToken(in: ["+"]))
        XCTAssertTrue(Inf6NonAutoregressiveSymbolRecognizer.containsMeaningfulToken(in: ["x"]))
        XCTAssertTrue(Inf6NonAutoregressiveSymbolRecognizer.containsMeaningfulToken(in: ["\\sum"]))
    }

    func testHandwrittenRecognitionAcceptsOnlyDigitAdjacentDecimalPoints() {
        XCTAssertFalse(Inf6NonAutoregressiveSymbolRecognizer.containsSupportedFormulaTokenSequence(in: [".", "*", "\\top"]))
        XCTAssertFalse(Inf6NonAutoregressiveSymbolRecognizer.containsSupportedFormulaTokenSequence(in: ["x", ".", "y"]))
        XCTAssertTrue(Inf6NonAutoregressiveSymbolRecognizer.containsSupportedFormulaTokenSequence(in: ["1", ".", "2"]))
        XCTAssertTrue(Inf6NonAutoregressiveSymbolRecognizer.containsSupportedFormulaTokenSequence(in: [".", "1", "+", "x"]))
        XCTAssertTrue(Inf6NonAutoregressiveSymbolRecognizer.containsSupportedFormulaTokenSequence(in: ["x", ".", "2"]))
    }

    func testHandwrittenRecognitionAcceptsStandaloneMinus() throws {
        XCTAssertTrue(Inf6NonAutoregressiveSymbolRecognizer.containsSupportedFormulaTokenSequence(in: ["-"]))
        let mathML = try LaTeXMathMLConverter().convert("-")
        XCTAssertTrue(mathML.contains(">−</mo>"))
    }

    func testHandwrittenRecognitionAcceptsStandaloneOperatorsAndDelimiters() {
        for label in ["+", "=", "(", ")", "×", "÷"] {
            XCTAssertTrue(
                Inf6NonAutoregressiveSymbolRecognizer.containsSupportedFormulaTokenSequence(in: [label]),
                "(label) must remain an input symbol even before an operand is written"
            )
        }
    }

    func testHandwrittenRecognitionCancellationPreventsAnyModelResult() throws {
        let stroke = makeStroke(points: [
            CGPoint(x: 10, y: 10),
            CGPoint(x: 40, y: 40),
        ])

        XCTAssertThrowsError(
            try Inf6HandwrittenFormulaRecognition.recognize(
                drawing: PKDrawing(strokes: [stroke]),
                cancellationCheck: { true }
            )
        ) { error in
            guard case Inf6HandwrittenFormulaError.cancelled = error else {
                return XCTFail("Expected cancellation, got: \(error)")
            }
        }
    }

    func testHinotoriCandidateGroupsAreOrderedByCanvasPositionNotStrokeIndex() throws {
        let strokes = [
            HinotoriStroke(points: [CGPoint(x: 200, y: 30), CGPoint(x: 230, y: 55)]),
            HinotoriStroke(points: [CGPoint(x: 20, y: 35), CGPoint(x: 45, y: 60)]),
        ]
        let right = HinotoriCandidate(classIndex: 10, label: "x", logit: 1)
        let left = HinotoriCandidate(classIndex: 172, label: "\\sqrt", logit: 1)

        let ordered = try Inf6HandwrittenFormulaRecognition.orderGroupsLeftToRight(
            groups: [[0], [1]],
            candidates: [[right], [left]],
            classFeatureDistances: [Array(repeating: 0.8, count: 229), Array(repeating: 0.7, count: 229)],
            strokes: strokes
        )

        XCTAssertEqual(ordered.groups, [[1], [0]])
        XCTAssertEqual(ordered.candidates.map { $0[0].label }, ["\\sqrt", "x"])
    }

    func testLeftToRightSymbolSequenceWithRootProducesValidatedMathML() throws {
        let mathML = try LaTeXMathMLConverter().convert("\\sqrt x")
        XCTAssertTrue(mathML.contains("<msqrt><mi>x</mi></msqrt>"))
    }

    func testHandwrittenRecognitionRemainsProvisionalUntilStructureConfirmed() throws {
        let stroke = makeStroke(points: [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 40)])
        let result = try Inf6HandwrittenFormulaRecognition.recognize(drawing: PKDrawing(strokes: [stroke]))
        XCTAssertTrue(result.isProvisional)
    }

    func testFormulaGrid9AcceptsSingleAxisStrokeAndAssignsOneCell() throws {
        let stroke = makeStroke(points: [
            CGPoint(x: 20, y: 10),
            CGPoint(x: 20, y: 90)
        ])
        let grid = try Inf6FormulaGrid9.analyze(drawing: PKDrawing(strokes: [stroke]), centerFraction: 0.44)

        XCTAssertTrue(grid.isStructurallyValid)
        XCTAssertEqual(grid.occupiedCellIndices, [5])
        XCTAssertEqual(grid.cells.first(where: { $0.index == 5 })?.strokeIndices, [0])
    }

    func testFormulaGrid9UsesTheFullPadSurfaceWhenProvided() throws {
        let stroke = makeStroke(points: [
            CGPoint(x: 10, y: 45),
            CGPoint(x: 10, y: 75)
        ])
        let grid = try Inf6FormulaGrid9.analyze(
            drawing: PKDrawing(strokes: [stroke]),
            centerFraction: 0.44,
            surfaceSize: CGSize(width: 100, height: 100)
        )

        XCTAssertTrue(grid.isStructurallyValid)
        XCTAssertEqual(grid.occupiedCellIndices, [4])
        XCTAssertEqual(grid.cells.first(where: { $0.index == 4 })?.strokeIndices, [0])
    }

    func testPencilKitCanonicalSampleMatchesInkMLPointBBoxContract() throws {
        let first = makeStroke(points: [
            CGPoint(x: 10, y: 20),
            CGPoint(x: 20, y: 40),
        ])
        let second = makeStroke(points: [
            CGPoint(x: 30, y: 10),
            CGPoint(x: 40, y: 30),
        ])

        let actual = try Inf6NonAutoregressiveSymbolRecognizer.canonicalSample(
            for: [first],
            allStrokes: [first, second],
            cancellationCheck: { false }
        )
        let expected = try Inf6CanonicalSample(
            traces: [[
                Inf6CanonicalSample.Point(x: 10, y: 20),
                Inf6CanonicalSample.Point(x: 20, y: 40),
            ]],
            strokeOrder: [0],
            sourceBounds: Inf6CanonicalSample.Bounds(minX: 10, minY: 20, maxX: 20, maxY: 40),
            rowPosition: [0.16666666666666666, 0.6666666666666666, 0.3333333333333333, 0.6666666666666666]
        )

        XCTAssertEqual(actual.format, expected.format)
        XCTAssertEqual(actual.traces, expected.traces)
        XCTAssertEqual(actual.strokeOrder, expected.strokeOrder)
        XCTAssertEqual(actual.sourceBounds, expected.sourceBounds)
        XCTAssertEqual(actual.rowPosition[0], expected.rowPosition[0], accuracy: 1e-12)
        XCTAssertEqual(actual.rowPosition[1], expected.rowPosition[1], accuracy: 1e-12)
        XCTAssertEqual(actual.rowPosition[2], expected.rowPosition[2], accuracy: 1e-12)
        XCTAssertEqual(actual.rowPosition[3], expected.rowPosition[3], accuracy: 1e-12)
    }


    // MARK: - inf6-glyph-shape-v2 (Python reference parity)

    func testGlyphFeaturesMatchPythonReferenceElementByElement() throws {
        XCTAssertEqual(Inf6GlyphFeatures.featureVersion, "inf6-glyph-shape-v2")
        XCTAssertEqual(Inf6GlyphFeatures.featureDimension, 110)
        for fixture in Self.glyphFeatureFixtureCases {
            let points = fixture.traces.flatMap { $0 }
            let sample = try Inf6CanonicalSample(
                traces: fixture.traces.map { $0.map { Inf6CanonicalSample.Point(x: $0[0], y: $0[1]) } },
                strokeOrder: Array(fixture.traces.indices),
                sourceBounds: Inf6CanonicalSample.Bounds(
                    minX: points.map { $0[0] }.min()!, minY: points.map { $0[1] }.min()!,
                    maxX: points.map { $0[0] }.max()!, maxY: points.map { $0[1] }.max()!
                ),
                rowPosition: fixture.rowPosition
            )
            let actual = try Inf6NonAutoregressiveSymbolRecognizer.featureVector(for: sample)
            XCTAssertEqual(actual.count, fixture.features.count, fixture.name)
            for (index, pair) in zip(actual, fixture.features).enumerated() {
                XCTAssertEqual(pair.0, pair.1, accuracy: 1e-9, "\(fixture.name) element \(index)")
            }
        }
    }

    func testCanonicalSampleAppliesStrokeTransformAndIgnoresInkWidth() throws {
        let base = makeStroke(points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 20)])
        let moved = PKStroke(ink: base.ink, path: base.path, transform: CGAffineTransform(translationX: 100, y: 50))
        let sample = try Inf6NonAutoregressiveSymbolRecognizer.canonicalSample(
            for: [moved], allStrokes: [moved], cancellationCheck: { false }
        )
        XCTAssertEqual(sample.traces[0].first, Inf6CanonicalSample.Point(x: 100, y: 50))
        XCTAssertEqual(sample.traces[0].last, Inf6CanonicalSample.Point(x: 110, y: 70))
        XCTAssertEqual(moved.inf6PointBounds, CGRect(x: 100, y: 50, width: 10, height: 20))
        // A horizontal bar has no extent in y: ink width must not turn it into a box.
        let bar = makeStroke(points: [CGPoint(x: 0, y: 5), CGPoint(x: 30, y: 5)])
        XCTAssertEqual(bar.inf6PointBounds.height, 0, accuracy: 1e-9)
    }

    func testRowPositionIsRelativeToTheWholeDrawing() throws {
        // x-like glyph in the centre and a small mark at its upper right: the row is both strokes.
        let x1 = makeStroke(points: [CGPoint(x: 40, y: 40), CGPoint(x: 60, y: 80)])
        let x2 = makeStroke(points: [CGPoint(x: 60, y: 40), CGPoint(x: 40, y: 80)])
        let two = makeStroke(points: [CGPoint(x: 70, y: 20), CGPoint(x: 80, y: 30)])
        let sample = try Inf6NonAutoregressiveSymbolRecognizer.canonicalSample(
            for: [x1, x2], allStrokes: [x1, x2, two], cancellationCheck: { false }
        )
        // row: x 40...80, y 20...80  -> glyph centre (50, 60), size 20 x 40
        XCTAssertEqual(sample.rowPosition[0], (50.0 - 40.0) / 40.0, accuracy: 1e-12)
        XCTAssertEqual(sample.rowPosition[1], (60.0 - 20.0) / 60.0, accuracy: 1e-12)
        XCTAssertEqual(sample.rowPosition[2], 20.0 / 40.0, accuracy: 1e-12)
        XCTAssertEqual(sample.rowPosition[3], 40.0 / 60.0, accuracy: 1e-12)
    }

    func testGlyphFeaturesAreShapeOnlyAndIgnoreWhereTheGlyphIsDrawn() throws {
        // The same glyph at another place and size must give the same vector: position is decided elsewhere.
        let base: [[Inf6CanonicalSample.Point]] = [
            [.init(x: 0, y: 0), .init(x: 10, y: 20), .init(x: 20, y: 40)],
            [.init(x: 20, y: 0), .init(x: 10, y: 20), .init(x: 0, y: 40)]
        ]
        func vector(_ traces: [[Inf6CanonicalSample.Point]], row: [Double]) throws -> [Double] {
            let xs = traces.flatMap { $0 }.map(\.x), ys = traces.flatMap { $0 }.map(\.y)
            let sample = try Inf6CanonicalSample(
                traces: traces, strokeOrder: Array(traces.indices),
                sourceBounds: .init(minX: xs.min()!, minY: ys.min()!, maxX: xs.max()!, maxY: ys.max()!),
                rowPosition: row
            )
            return try Inf6GlyphFeatures.features(for: sample)
        }
        let moved = base.map { $0.map { Inf6CanonicalSample.Point(x: $0.x * 3 + 500, y: $0.y * 3 - 70) } }
        let a = try vector(base, row: [0.5, 0.5, 1, 1])
        let b = try vector(moved, row: [0.9, 0.1, 0.05, 0.05])
        XCTAssertEqual(a.count, Inf6GlyphFeatures.featureDimension)
        for (index, pair) in zip(a, b).enumerated() {
            XCTAssertEqual(pair.0, pair.1, accuracy: 1e-9, "element \(index)")
        }
    }

    // Generated by inf6-training/make_parity_fixture.py from inf6_glyph_features.py -- do not edit by hand.
    private static let glyphFeatureFixtureCases: [(name: String, traces: [[[Double]]], rowPosition: [Double], features: [Double])] = [
        (name: "x-two-strokes", traces: [[[1134.0, 280.0], [1103.0, 304.0], [1065.0, 340.0], [1044.0, 358.0], [1044.0, 358.0]], [[1038.0, 273.0], [1047.0, 298.0], [1064.0, 336.0], [1072.0, 350.0]]], rowPosition: [0.6374207188160677, 0.6183333333333333, 0.1014799154334038, 0.2833333333333333], features: [0.5, -0.3697916666666667, 0.41073790059983634, -0.3006855251955732, 0.321475801199675, -0.23157938372447914, 0.2322137017995113, -0.16247324225338566, 0.14574745527720742, -0.09010504535033743, 0.06379713558063808, -0.012467900374640331, -0.018153184115931253, 0.06516924460105737, -0.10010350381250059, 0.14280638957675448, -0.18205382350906993, 0.22044353455245158, -0.2660802293317535, 0.2957771013319803, -0.3517901146658768, 0.3692427173326565, -0.4375, 0.4427083333333333, 0.5856956573800148, 1.0, -0.5, -0.4427083333333333, -0.4729523226362673, -0.36757589621185655, -0.445904645272537, -0.2924434590903798, -0.4188569679088043, -0.21731102196890303, -0.38884003046200394, -0.14337526416997193, -0.356230881967889, -0.07048422635959402, -0.32362173347377166, 0.0024068114507832896, -0.2910125849796567, 0.07529784926116061, -0.2584034364855394, 0.1481888870715379, -0.22506943984171102, 0.22071181361033906, -0.185451386587521, 0.2900434068051698, -0.14583333333333334, 0.359375, 0.4143043426199852, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.8854166666666666]),
        (name: "two-one-stroke", traces: [[[593.54, 53.57], [637.5, 29.6], [626.55, 73.45], [612.52, 92.49], [630.51, 94.51]]], rowPosition: [0.5938629865066049, 0.12036865333976192, 0.051941300186686246, 0.24073730667952378], features: [-0.33862270836542935, -0.13071945771067642, -0.1701385765612589, -0.2225885350388374, -0.0016544447570884147, -0.31445761236699826, 0.16682968704708032, -0.4063266896951591, 0.3353138188512508, -0.4981957670233202, 0.2930423973686691, -0.31747062673900245, 0.24654899424612106, -0.13128471560441413, 0.20005559112357302, 0.054901195530174196, 0.12985674137958123, 0.22993059130247795, 0.01601719253178155, 0.3844213261607912, 0.04023038337855079, 0.47858679208874705, 0.23093514096441242, 0.5, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.6772454167308587, 1.0]),
        (name: "plus-two-strokes", traces: [[[701.0, 141.0], [727.0, 140.0], [749.0, 137.0]], [[738.0, 108.0], [731.0, 127.0], [727.0, 147.0], [727.0, 147.0]]], rowPosition: [0.5877437325905293, 0.24282296650717702, 0.04456824512534819, 0.09330143540669857], features: [-0.5, 0.28125, -0.40873636604967345, 0.27773986023267955, -0.3174727320993493, 0.2742297204653597, -0.2262090981490227, 0.2707195806980393, -0.13494546419869616, 0.26720944093071886, -0.04368183024837199, 0.263699301163399, 0.047531896269769426, 0.2596168626298798, 0.13802551701581459, 0.2472768234372372, 0.22851913776186214, 0.23493678424459455, 0.3190127585079073, 0.22259674505195193, 0.40950637925395483, 0.2102567058593093, 0.5, 0.19791666666666666, 0.542638219690383, 1.0, 0.2708333333333333, -0.40625, 0.24422152749534595, -0.3340179555826068, 0.21760972165735856, -0.2617859111652135, 0.19099791581937117, -0.18955386674781996, 0.16438610998138614, -0.11732182233042672, 0.13777430414339875, -0.04508977791303348, 0.11715008595320597, 0.028832903567303465, 0.10205340209589764, 0.10431632285384278, 0.0869567182385893, 0.17979974214038208, 0.07186003438128334, 0.25528316142692137, 0.056763350523975, 0.3307665807134607, 0.041666666666666664, 0.40625, 0.457361780309617, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.8125]),
        (name: "five-strokes-merge-tail-with-dot-and-duplicates", traces: [[[0.0, 0.0], [5.0, 0.0], [5.0, 0.0], [9.0, 3.0]], [[3.0, 3.0]], [[1.0, 1.0], [1.0, 8.0]], [[2.0, 2.0], [8.0, 2.5], [8.0, 9.0]], [[6.0, 6.0], [7.0, 1.0]]], rowPosition: [0.425, 0.4642857142857143, 0.45, 0.6428571428571429], features: [-0.5, -0.5, -0.398989898989899, -0.5, -0.29797979797979796, -0.5, -0.196969696969697, -0.5, -0.09595959595959593, -0.5, 0.005050505050505095, -0.5, 0.09595959595959593, -0.4696969696969697, 0.17676767676767677, -0.4090909090909091, 0.25757575757575757, -0.3484848484848485, 0.33838383838383834, -0.28787878787878785, 0.4191919191919193, -0.2272727272727272, 0.5, -0.16666666666666666, 0.2616063756266837, 1.0, -0.16666666666666666, -0.16666666666666666, -0.16666666666666666, -0.16666666666666666, -0.16666666666666666, -0.16666666666666666, -0.16666666666666666, -0.16666666666666666, -0.16666666666666666, -0.16666666666666666, -0.16666666666666666, -0.16666666666666666, -0.16666666666666666, -0.16666666666666666, -0.16666666666666666, -0.16666666666666666, -0.16666666666666666, -0.16666666666666666, -0.16666666666666666, -0.16666666666666666, -0.16666666666666666, -0.16666666666666666, -0.16666666666666666, -0.16666666666666666, 0.0, 1.0, -0.3888888888888889, -0.3888888888888889, -0.3888888888888889, -0.3181818181818182, -0.3888888888888889, -0.24747474747474751, -0.3888888888888889, -0.17676767676767677, -0.3888888888888889, -0.10606060606060606, -0.3888888888888889, -0.03535353535353537, -0.3888888888888889, 0.03535353535353537, -0.3888888888888889, 0.10606060606060602, -0.3888888888888889, 0.17676767676767677, -0.3888888888888889, 0.24747474747474751, -0.3888888888888889, 0.3181818181818181, -0.3888888888888889, 0.3888888888888889, 0.1831244629386786, 1.0, -0.2777777777777778, -0.2777777777777778, -0.06412070175991384, -0.25997302144295575, 0.1495363742579501, -0.2421682651081338, 0.3631934502758141, -0.2243635087733118, 0.3888888888888889, -0.033609069389352854, 0.3888888888888889, 0.18078858796875766, 0.3888888888888889, 0.39518624532686786, 0.3281026765664051, 0.4088206815162743, 0.20917625395963185, 0.2304310476061145, 0.19368409789027138, 0.031579510548643164, 0.23573093783402457, -0.178654689170123, 0.2777777777777778, -0.3888888888888889, 0.5552691614346377, 1.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0]),
        (name: "horizontal-bar", traces: [[[0.0, 5.0], [30.0, 5.0]]], rowPosition: [0.5, 0.125, 1.0, 0.0], features: [-0.5, 0.0, -0.4090909090909091, 0.0, -0.31818181818181823, 0.0, -0.22727272727272727, 0.0, -0.13636363636363638, 0.0, -0.04545454545454544, 0.0, 0.04545454545454544, 0.0, 0.13636363636363633, 0.0, 0.2272727272727272, 0.0, 0.31818181818181823, 0.0, 0.4090909090909091, 0.0, 0.5, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]),
    ]

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeStroke(points: [CGPoint]) -> PKStroke {
        let controlPoints = points.enumerated().map { index, point in
            PKStrokePoint(
                location: point,
                timeOffset: TimeInterval(index) * 0.1,
                size: CGSize(width: 3, height: 3),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        let path = PKStrokePath(controlPoints: controlPoints, creationDate: .now)
        return PKStroke(ink: PKInk(.pen, color: .black), path: path)
    }
}
