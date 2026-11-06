import Foundation

public enum InterfaceLanguage: String, Codable, CaseIterable, Sendable {
    case japanese = "ja"
    case english = "en"
}

/// The source of a verified formula. Grid geometry is only a handwriting
/// feature; structured and paper formulas remain valid without it.
public enum Inf6FormulaInputMethod: String, Codable, CaseIterable, Sendable {
    case paper
    case symbolPalette
    case handwriting
    case mixed
}

/// Distinguishes a user-started derivation from one grounded in a paper entity.
/// A user-started derivation must not manufacture a paper identifier or source evidence.
public enum DerivationOrigin: String, Codable, CaseIterable, Sendable {
    case paperEvidence
    case userAuthored
}

public struct DerivationStep: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var expression: String
    public var reason: String
    public var recalledFinalForm: Bool
    public var verifiedUnderstanding: Bool

    public init(id: UUID = UUID(), expression: String, reason: String, recalledFinalForm: Bool = false, verifiedUnderstanding: Bool = false) {
        self.id = id
        self.expression = expression
        self.reason = reason
        self.recalledFinalForm = recalledFinalForm
        self.verifiedUnderstanding = verifiedUnderstanding
    }

    private enum CodingKeys: String, CodingKey {
        case id, expression, reason, recalledFinalForm, verifiedUnderstanding
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        expression = try values.decode(String.self, forKey: .expression)
        reason = try values.decode(String.self, forKey: .reason)
        recalledFinalForm = try values.decodeIfPresent(Bool.self, forKey: .recalledFinalForm) ?? false
        verifiedUnderstanding = try values.decodeIfPresent(Bool.self, forKey: .verifiedUnderstanding) ?? false
    }
}

public struct FormulaChatMessage: Codable, Identifiable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    public let id: UUID
    public let role: Role
    public var text: String
    public let createdAt: Date
    public let sourceStepID: UUID?

    public init(id: UUID = UUID(), role: Role, text: String, createdAt: Date = .now, sourceStepID: UUID? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.sourceStepID = sourceStepID
    }
}

public struct DerivationDocument: Codable, Sendable {
    public var derivationID: UUID?
    public var origin: DerivationOrigin?
    public var steps: [DerivationStep]
    public var chatMessages: [FormulaChatMessage]
    public var sourceEvidenceID: UUID?
    public var sourceTitle: String?
    public var sourceLocator: String?
    public var updatedAt: Date
    public var pencilDrawingData: Data?
    public var handwritingEvidence: Data?
    public var mathML: String?
    public var mathMLVerified: Bool?
    public var aiExplanation: String?
    public var recognizedExpression: String?
    public var recognizedTokenIDs: [Int]?
    public var recognizedSymbols: [String]?
    public var recognizedGridCellIndices: [Int]?
    public var recognizedSymbolStrokeIndices: [[Int]]?
    public var spatialAnalysis: Inf6SpatialRelationAnalysis?
    public var positionSensitiveClassification: Inf6PositionSensitiveClassification?
    public var similarityExpansion: Inf6SymbolSimilarityExpansion?
    public var grid9: Inf6FormulaGrid9?
    public var paperEquationSpaceID: String?
    public var paperEquationID: String?
    public var paperEquationSpace: PaperEquationSpace?
    public var inputMethod: Inf6FormulaInputMethod?
    public var formulaStructure: FormulaStructure?
    public var paperSupplement: PaperSupplement?

    public init(derivationID: UUID? = nil, origin: DerivationOrigin? = nil, steps: [DerivationStep] = [], chatMessages: [FormulaChatMessage] = [], sourceEvidenceID: UUID? = nil, sourceTitle: String? = nil, sourceLocator: String? = nil, updatedAt: Date = .now, pencilDrawingData: Data? = nil, mathML: String? = nil, mathMLVerified: Bool? = nil, aiExplanation: String? = nil, recognizedExpression: String? = nil, recognizedTokenIDs: [Int]? = nil, recognizedSymbols: [String]? = nil, recognizedGridCellIndices: [Int]? = nil, recognizedSymbolStrokeIndices: [[Int]]? = nil, spatialAnalysis: Inf6SpatialRelationAnalysis? = nil, positionSensitiveClassification: Inf6PositionSensitiveClassification? = nil, similarityExpansion: Inf6SymbolSimilarityExpansion? = nil, grid9: Inf6FormulaGrid9? = nil, paperEquationSpaceID: String? = nil, paperEquationID: String? = nil, paperEquationSpace: PaperEquationSpace? = nil, inputMethod: Inf6FormulaInputMethod? = nil, formulaStructure: FormulaStructure? = nil, paperSupplement: PaperSupplement? = nil) {
        self.derivationID = derivationID
        self.origin = origin
        self.steps = steps
        self.chatMessages = chatMessages
        self.sourceEvidenceID = sourceEvidenceID
        self.sourceTitle = sourceTitle
        self.sourceLocator = sourceLocator
        self.updatedAt = updatedAt
        self.pencilDrawingData = pencilDrawingData
        self.handwritingEvidence = nil
        self.mathML = mathML
        self.mathMLVerified = mathMLVerified
        self.aiExplanation = aiExplanation
        self.recognizedExpression = recognizedExpression
        self.recognizedTokenIDs = recognizedTokenIDs
        self.recognizedSymbols = recognizedSymbols
        self.recognizedGridCellIndices = recognizedGridCellIndices
        self.recognizedSymbolStrokeIndices = recognizedSymbolStrokeIndices
        self.spatialAnalysis = spatialAnalysis
        self.positionSensitiveClassification = positionSensitiveClassification
        self.similarityExpansion = similarityExpansion
        self.grid9 = grid9
        self.paperEquationSpaceID = paperEquationSpaceID
        self.paperEquationID = paperEquationID
        self.paperEquationSpace = paperEquationSpace
        self.inputMethod = inputMethod
        self.formulaStructure = formulaStructure
        self.paperSupplement = paperSupplement
    }
}

public struct PaperSupplement: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let sourceEvidenceID: UUID
    public let sourceTitle: String
    public let sourceLocator: String?
    public let mathML: String?
    public let derivationSteps: [DerivationStep]
    public let dialogue: [FormulaChatMessage]
    public let updatedAt: Date

    public init(id: UUID = UUID(), sourceEvidenceID: UUID, sourceTitle: String, sourceLocator: String? = nil, mathML: String? = nil, derivationSteps: [DerivationStep] = [], dialogue: [FormulaChatMessage] = [], updatedAt: Date = .now) {
        self.id = id
        self.sourceEvidenceID = sourceEvidenceID
        self.sourceTitle = sourceTitle
        self.sourceLocator = sourceLocator
        self.mathML = mathML
        self.derivationSteps = derivationSteps
        self.dialogue = dialogue
        self.updatedAt = updatedAt
    }
}

/// The replaceable runtime context that maps generic recognition candidates to
/// the equations and symbols of the selected paper.
public struct PaperEquationSpace: Codable, Identifiable, Sendable {
    public let id: String
    public var paperTitle: String
    public var version: String
    public var pages: [PaperEquationPage]
    public var equations: [PaperEquation]

    public init(
        id: String,
        paperTitle: String,
        version: String,
        pages: [PaperEquationPage],
        equations: [PaperEquation]
    ) {
        self.id = id
        self.paperTitle = paperTitle
        self.version = version
        self.pages = pages
        self.equations = equations
    }

    public func validated() throws -> PaperEquationSpace {
        let pageIDs = Set(pages.map(\.id))
        guard pageIDs.count == pages.count else {
            throw PaperEquationSpaceError.duplicatePageID
        }

        let equationIDs = Set(equations.map(\.id))
        guard equationIDs.count == equations.count else {
            throw PaperEquationSpaceError.duplicateEquationID
        }

        for page in pages {
            guard page.equationIDs.allSatisfy(equationIDs.contains) else {
                throw PaperEquationSpaceError.missingEquationReference(page.id)
            }
        }

        for equation in equations {
            guard pageIDs.contains(equation.pageID) else {
                throw PaperEquationSpaceError.missingPageReference(equation.id)
            }
            try equation.validateReferences()
        }

        return self
    }
}

public struct PaperEquationPage: Codable, Identifiable, Sendable {
    public let id: String
    public var pageIndex: Int
    public var equationIDs: [String]

    public init(id: String, pageIndex: Int, equationIDs: [String]) {
        self.id = id
        self.pageIndex = pageIndex
        self.equationIDs = equationIDs
    }
}

public struct PaperEquation: Codable, Identifiable, Sendable {
    public let id: String
    public let pageID: String
    public var sourceLocator: String?
    public var latex: String?
    public var mathML: String?
    public var symbols: [PaperEquationSymbol]
    public var relations: [PaperEquationRelation]
    public var definitions: [PaperEquationDefinition]
    public var dimensions: [String: String]

    public init(
        id: String,
        pageID: String,
        sourceLocator: String? = nil,
        latex: String? = nil,
        mathML: String? = nil,
        symbols: [PaperEquationSymbol] = [],
        relations: [PaperEquationRelation] = [],
        definitions: [PaperEquationDefinition] = [],
        dimensions: [String: String] = [:]
    ) {
        self.id = id
        self.pageID = pageID
        self.sourceLocator = sourceLocator
        self.latex = latex
        self.mathML = mathML
        self.symbols = symbols
        self.relations = relations
        self.definitions = definitions
        self.dimensions = dimensions
    }

    fileprivate func validateReferences() throws {
        let symbolIDs = Set(symbols.map(\.id))
        guard symbolIDs.count == symbols.count else {
            throw PaperEquationSpaceError.duplicateSymbolID(id)
        }

        for relation in relations {
            guard symbolIDs.contains(relation.sourceSymbolID),
                  symbolIDs.contains(relation.targetSymbolID) else {
                throw PaperEquationSpaceError.missingSymbolReference(id)
            }
        }
    }
}

public struct PaperEquationSymbol: Codable, Identifiable, Sendable {
    public let id: String
    public var token: String
    public var role: String
    public var definition: String?
    public var allowedGridCells: [Int]

    public init(
        id: String,
        token: String,
        role: String,
        definition: String? = nil,
        allowedGridCells: [Int] = []
    ) {
        self.id = id
        self.token = token
        self.role = role
        self.definition = definition
        self.allowedGridCells = allowedGridCells
    }
}

public struct PaperEquationRelation: Codable, Hashable, Sendable {
    public var sourceSymbolID: String
    public var targetSymbolID: String
    public var kind: String

    public init(sourceSymbolID: String, targetSymbolID: String, kind: String) {
        self.sourceSymbolID = sourceSymbolID
        self.targetSymbolID = targetSymbolID
        self.kind = kind
    }
}

public struct PaperEquationDefinition: Codable, Hashable, Sendable {
    public var symbolID: String
    public var meaning: String

    public init(symbolID: String, meaning: String) {
        self.symbolID = symbolID
        self.meaning = meaning
    }
}

public enum PaperEquationSpaceError: LocalizedError, Sendable {
    case duplicatePageID
    case duplicateEquationID
    case missingEquationReference(String)
    case missingPageReference(String)
    case duplicateSymbolID(String)
    case missingSymbolReference(String)

    public var errorDescription: String? {
        switch self {
        case .duplicatePageID:
            return "論文数式空間に重複したページIDがあります。"
        case .duplicateEquationID:
            return "論文数式空間に重複した数式IDがあります。"
        case .missingEquationReference(let pageID):
            return "ページID \(pageID) が未登録の数式を参照しています。"
        case .missingPageReference(let equationID):
            return "数式ID \(equationID) のページ参照が未登録です。"
        case .duplicateSymbolID(let equationID):
            return "数式ID \(equationID) に重複した記号IDがあります。"
        case .missingSymbolReference(let equationID):
            return "数式ID \(equationID) の関係が未登録の記号を参照しています。"
        }
    }
}

public enum DerivationError: LocalizedError {
    case rootUnavailable
    case derivationIdentityVerificationFailed
    case derivationRevisionVerificationFailed
    case pencilDrawingVerificationFailed
    case handwritingEvidenceVerificationFailed
    case formulaStructureVerificationFailed
    case spatialAnalysisVerificationFailed
    case positionSensitiveClassificationVerificationFailed
    case similarityExpansionVerificationFailed
    case documentContentVerificationFailed
    case paperSupplementVerificationFailed
    case invalidPencilDrawingData

    public var errorDescription: String? {
        switch self {
        case .rootUnavailable: return "保存先が設定されていません。"
        case .derivationIdentityVerificationFailed: return "導出の起点または識別子を保存後に検証できませんでした。"
        case .derivationRevisionVerificationFailed: return "導出の更新時刻を保存後に検証できませんでした。"
        case .pencilDrawingVerificationFailed: return "手書きストロークを保存後に検証できませんでした。"
        case .handwritingEvidenceVerificationFailed: return "手書き認識の証拠を保存後に検証できませんでした。"
        case .formulaStructureVerificationFailed: return "数式構造を保存後に検証できませんでした。"
        case .spatialAnalysisVerificationFailed: return "位置関係候補を保存後に検証できませんでした。"
        case .positionSensitiveClassificationVerificationFailed: return "位置依存記号分類を保存後に検証できませんでした。"
        case .similarityExpansionVerificationFailed: return "類似記号候補を保存後に検証できませんでした。"
        case .documentContentVerificationFailed: return "導出ドキュメント全体を保存後に照合できませんでした。"
        case .paperSupplementVerificationFailed: return "論文補足と導出文書の内容が一致しません。"
        case .invalidPencilDrawingData: return "保存済み手書きストロークを復元できないか、空です。"
        }
    }
}
