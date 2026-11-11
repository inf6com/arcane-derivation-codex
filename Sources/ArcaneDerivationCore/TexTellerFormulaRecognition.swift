import CoreML
import CryptoKit
import Foundation
import OSLog
import UIKit
#if canImport(PencilKit)
import PencilKit
#endif

public struct Inf6HandwrittenMathMLResult: Sendable, Equatable {
    public let tokenIDs: [Int32]
    public let decodedExpression: String
    public let mathML: String
    public let grid9: Inf6FormulaGrid9
    public let symbolLabels: [String]
    public let symbolGridCellIndices: [Int]
    /// Exact source stroke indices of each Hinotori candidate group.  Grid
    /// cells are display metadata only and must never replace this mapping.
    public let symbolStrokeIndices: [[Int]]
    /// Rank in the calibrated Hinotori ensemble output; nil means the selected
    /// label was added by the visual-similarity or position stage.
    public let candidateRanks: [Int?]
    public let candidateLabels: [[String]]
    public let candidateModelName: String?
    public let candidateCalibrationSHA256: String?
    /// Original Fold7 branch Top-5 order retained for audit; the visible rank
    /// is the calibrated ensemble rank.
    public let fold7Top5ClassIndices: [[Int]]
    /// Unmodified Fold7 logits aligned with `fold7Top5ClassIndices`.
    public let fold7Top5Logits: [[Float]]
    /// For each symbol and fused ensemble Top-5 rank, Fold7 87-group members
    /// ranked by this stroke group's prototype cosine score.
    public let fold7SimilarityCandidates: [[[HinotoriFold7SimilarityCandidate]]]
    /// Raw typeset-branch Top-5 retained as branch evidence. The full 222-class
    /// output is calibrated and fused with Fold7 before candidate selection.
    public let typesetCandidates: [[HinotoriTypesetCandidate]]
    /// Geometry-preserving proposals emitted after Hinotori recognition.
    /// They never confirm a formula relation without an explicit user action.
    public let spatialAnalysis: Inf6SpatialRelationAnalysis?
    /// Candidate ordering derived from the position-sensitive Hinotori subset.
    /// It preserves model candidates and never confirms a label.
    public let positionSensitiveClassification: Inf6PositionSensitiveClassification?
    /// Similar-looking labels proposed without consulting coordinates, before
    /// the downstream position-sensitive classification runs.
    public let similarityExpansion: HinotoriVisualSubsetExpansion?
    public let isProvisional: Bool

    public init(tokenIDs: [Int32], decodedExpression: String, mathML: String, grid9: Inf6FormulaGrid9, symbolLabels: [String] = [], symbolGridCellIndices: [Int] = [], symbolStrokeIndices: [[Int]] = [], candidateRanks: [Int?] = [], candidateLabels: [[String]] = [], candidateModelName: String? = nil, candidateCalibrationSHA256: String? = nil, fold7Top5ClassIndices: [[Int]] = [], fold7Top5Logits: [[Float]] = [], fold7SimilarityCandidates: [[[HinotoriFold7SimilarityCandidate]]] = [], typesetCandidates: [[HinotoriTypesetCandidate]] = [], spatialAnalysis: Inf6SpatialRelationAnalysis? = nil, positionSensitiveClassification: Inf6PositionSensitiveClassification? = nil, similarityExpansion: HinotoriVisualSubsetExpansion? = nil, isProvisional: Bool = false) {
        self.tokenIDs = tokenIDs
        self.decodedExpression = decodedExpression
        self.mathML = mathML
        self.grid9 = grid9
        self.symbolLabels = symbolLabels
        self.symbolGridCellIndices = symbolGridCellIndices
        self.symbolStrokeIndices = symbolStrokeIndices
        self.candidateRanks = candidateRanks
        self.candidateLabels = candidateLabels
        self.candidateModelName = candidateModelName
        self.candidateCalibrationSHA256 = candidateCalibrationSHA256
        self.fold7Top5ClassIndices = fold7Top5ClassIndices
        self.fold7Top5Logits = fold7Top5Logits
        self.fold7SimilarityCandidates = fold7SimilarityCandidates
        self.typesetCandidates = typesetCandidates
        self.spatialAnalysis = spatialAnalysis
        self.positionSensitiveClassification = positionSensitiveClassification
        self.similarityExpansion = similarityExpansion
        self.isProvisional = isProvisional
    }
}

public struct Inf6PositionSensitiveClassification: Codable, Equatable, Sendable {
    public struct Symbol: Codable, Equatable, Sendable {
        /// A candidate introduced by a spatial rule. It has no model logit and
        /// must remain visibly distinct from a Hinotori model candidate.
        public struct RuleSupplement: Codable, Equatable, Sendable {
            public let classIndex: Int
            public let label: String
            public let origin: String
            public let evidence: String
        }

        public let sourceSymbolID: String
        public let originalCandidateClassIndices: [Int]
        public let reorderedCandidateClassIndices: [Int]
        /// Combined model and similarity choices after the separate spatial
        /// stage. The learned model's logits remain attached only to the
        /// original model candidates in `spatialAnalysis`.
        public let candidateChoiceClassIndices: [Int]?
        /// Nil is accepted when reopening artifacts saved before rule
        /// supplements were introduced. New recognition results always record
        /// the explicit, possibly empty list.
        public let ruleSupplements: [RuleSupplement]?
        public let matchedGroupID: String?
        public let evidence: String
        public let confirmed: Bool
    }

    public let subsetSchema: String
    public let sourceVocabularyContract: String
    public let ruleVersion: String
    public let symbols: [Symbol]
}

public struct HinotoriPositionSensitiveSubset: Codable, Equatable, Sendable {
    public struct Group: Codable, Equatable, Sendable {
        public let id: String
        public let labels: [String]
        public let positionEvidence: [String]
        public let candidateInterpretations: [String]
    }

    public let schema: String
    public let sourceVocabulary: String
    public let sourceVocabularyContract: String
    public let groups: [Group]

    public static func load(bundle: Bundle) throws -> HinotoriPositionSensitiveSubset {
        guard let url = bundle.url(forResource: "HinotoriPositionSensitiveSubset", withExtension: "json") else {
            throw Inf6PositionSensitiveClassifierError.definitionUnavailable
        }
        do {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url, options: .mappedIfSafe))
        } catch {
            throw Inf6PositionSensitiveClassifierError.invalidDefinition(error.localizedDescription)
        }
    }

    public func validate(vocabulary: HinotoriVocabulary) throws {
        guard schema == "hinotori-position-sensitive-subset-v1", sourceVocabularyContract == "hinotori-v1" else {
            throw Inf6PositionSensitiveClassifierError.invalidDefinition("schema or vocabulary contract")
        }
        let labels = groups.flatMap(\.labels)
        guard labels.count == 35, Set(labels).count == labels.count, Set(labels).isSubset(of: Set(vocabulary.labels)) else {
            throw Inf6PositionSensitiveClassifierError.invalidDefinition("labels are not the defined 35-class subset of Hinotori")
        }
    }
}

/// Complete ViT-generated visual partition. Membership is coordinate- and
/// distance-independent; the original handwriting-model ranking is retained.
public struct HinotoriVisualSimilaritySubsetCatalog: Codable, Equatable, Sendable {
    public struct Vocabulary: Codable, Equatable, Sendable {
        public let sha256: String
        public let labelCount: Int
    }
    public struct Subset: Codable, Equatable, Sendable {
        public let subsetKey: String
        public let members: [String]
    }
    public struct ViTProvenance: Codable, Equatable, Sendable {
        public let sha256: String
        public let epoch: Int
    }

    public let schema: String
    public let vocabulary: Vocabulary
    public let vit: ViTProvenance
    public let subsets: [Subset]

    public static func load(bundle: Bundle) throws -> HinotoriVisualSimilaritySubsetCatalog {
        guard let url = bundle.url(forResource: "HinotoriVisualSimilaritySubsets", withExtension: "json"),
              let vocabularyURL = bundle.url(forResource: "HinotoriVocabulary", withExtension: "json") else {
            throw HinotoriVisualSubsetCandidateExpanderError.definitionUnavailable
        }
        do {
            let catalog = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url, options: .mappedIfSafe))
            let vocabularyData = try Data(contentsOf: vocabularyURL, options: .mappedIfSafe)
            let vocabularySHA256 = SHA256.hash(data: vocabularyData).map { String(format: "%02x", $0) }.joined()
            guard catalog.vocabulary.sha256 == vocabularySHA256 else {
                throw HinotoriVisualSubsetCandidateExpanderError.invalidDefinition("部分集合と分類器の語彙SHA-256が一致しません")
            }
            return catalog
        } catch let error as HinotoriVisualSubsetCandidateExpanderError {
            throw error
        } catch {
            throw HinotoriVisualSubsetCandidateExpanderError.invalidDefinition(error.localizedDescription)
        }
    }

    public func validate(vocabulary: HinotoriVocabulary) throws {
        let members = subsets.flatMap(\.members)
        guard schema == "hinotori-vit-visual-similarity-subsets-v1",
              vocabulary.labels.count == HinotoriCoreMLExecutor.classCount,
              !subsets.isEmpty,
              subsets.allSatisfy({ !$0.subsetKey.isEmpty && !$0.members.isEmpty && Set($0.members).count == $0.members.count && $0.members.contains($0.subsetKey) }),
              members.count == HinotoriCoreMLExecutor.classCount,
              Set(members).count == members.count,
              Set(members) == Set(vocabulary.labels) else {
            throw HinotoriVisualSubsetCandidateExpanderError.invalidDefinition("ViT部分集合が229記号を重複なく完全分割していません")
        }
    }
}

public struct HinotoriVisualSubsetExpansion: Codable, Equatable, Sendable {
    public struct Symbol: Codable, Equatable, Sendable {
        public struct Supplement: Codable, Equatable, Sendable {
            public let classIndex: Int
            public let label: String
            public let matchedModelClassIndices: [Int]
            public let subsetKey: String
            public let origin: String
            public let evidence: String
        }

        public let sourceSymbolID: String
        public let modelCandidateClassIndices: [Int]
        public let supplements: [Supplement]
    }

    public let catalogSchema: String
    public let vocabularySHA256: String
    public let vitCheckpointSHA256: String
    public let ruleVersion: String
    public let symbols: [Symbol]
}

public enum HinotoriVisualSubsetCandidateExpanderError: LocalizedError, Equatable {
    case definitionUnavailable
    case invalidDefinition(String)
    case invalidCandidates(String)

    public var errorDescription: String? {
        switch self {
        case .definitionUnavailable: return "記号類似グループ定義をBundleから読み込めません。"
        case .invalidDefinition(let reason): return "記号類似グループ定義が不正です: \(reason)"
        case .invalidCandidates(let reason): return "記号類似候補を検証できません: \(reason)"
        }
    }
}

/// Expands model candidates through ViT visual subsets before position rules.
/// Membership reads neither stroke coordinates nor handwriting feature distance.
/// Added alternatives retain no fabricated model score.
public enum HinotoriVisualSubsetCandidateExpander {
    public static let ruleVersion = "hinotori-visual-subset-expansion-v1"

    public static func expand(
        candidates: [[HinotoriCandidate]],
        catalog: HinotoriVisualSimilaritySubsetCatalog,
        vocabulary: HinotoriVocabulary
    ) throws -> HinotoriVisualSubsetExpansion {
        try catalog.validate(vocabulary: vocabulary)
        guard !candidates.isEmpty else {
            throw HinotoriVisualSubsetCandidateExpanderError.invalidCandidates("候補記号がありません")
        }
        let subsetByLabel = Dictionary(uniqueKeysWithValues: catalog.subsets.flatMap { subset in
            subset.members.map { ($0, subset) }
        })
        let records = try candidates.enumerated().map { symbolIndex, modelCandidates -> HinotoriVisualSubsetExpansion.Symbol in
            guard !modelCandidates.isEmpty,
                  Set(modelCandidates.map(\.classIndex)).count == modelCandidates.count,
                  modelCandidates.allSatisfy({ vocabulary.labels.indices.contains($0.classIndex) && vocabulary.labels[$0.classIndex] == $0.label }) else {
                throw HinotoriVisualSubsetCandidateExpanderError.invalidCandidates("symbol-\(symbolIndex)のモデル候補が語彙またはclass indexと一致しません")
            }
            let modelClassIndices = Set(modelCandidates.map(\.classIndex))
            var supplementsByClass: [Int: HinotoriVisualSubsetExpansion.Symbol.Supplement] = [:]
            for modelCandidate in modelCandidates {
                guard let subset = subsetByLabel[modelCandidate.label] else {
                    throw HinotoriVisualSubsetCandidateExpanderError.invalidDefinition("分類候補に対応するViT部分集合がありません: \(modelCandidate.label)")
                }
                for label in subset.members {
                    guard let classIndex = vocabulary.labels.firstIndex(of: label) else {
                        throw HinotoriVisualSubsetCandidateExpanderError.invalidDefinition("ViT部分集合の記号が語彙にありません: \(label)")
                    }
                    guard !modelClassIndices.contains(classIndex) else { continue }
                    if let previous = supplementsByClass[classIndex] {
                        supplementsByClass[classIndex] = HinotoriVisualSubsetExpansion.Symbol.Supplement(
                            classIndex: classIndex,
                            label: label,
                            matchedModelClassIndices: Array(Set(previous.matchedModelClassIndices + [modelCandidate.classIndex])).sorted(),
                            subsetKey: previous.subsetKey,
                            origin: previous.origin,
                            evidence: previous.evidence
                        )
                    } else {
                        supplementsByClass[classIndex] = HinotoriVisualSubsetExpansion.Symbol.Supplement(
                            classIndex: classIndex,
                            label: label,
                            matchedModelClassIndices: [modelCandidate.classIndex],
                            subsetKey: subset.subsetKey,
                            origin: "hinotori-visual-subset",
                            evidence: "ViT visual subset \(subset.subsetKey); coordinate-independent membership; no model score assigned; user confirmation required"
                        )
                    }
                }
            }
            let supplements = supplementsByClass.values.sorted { $0.classIndex < $1.classIndex }
            return .init(
                sourceSymbolID: "symbol-\(symbolIndex)",
                modelCandidateClassIndices: modelCandidates.map(\.classIndex),
                supplements: supplements
            )
        }
        return .init(
            catalogSchema: catalog.schema,
            vocabularySHA256: catalog.vocabulary.sha256,
            vitCheckpointSHA256: catalog.vit.sha256,
            ruleVersion: ruleVersion,
            symbols: records
        )
    }
}

public enum Inf6PositionSensitiveClassifierError: LocalizedError, Equatable {
    case definitionUnavailable
    case invalidDefinition(String)

    public var errorDescription: String? {
        switch self {
        case .definitionUnavailable: return "位置依存記号分類の定義ファイルをBundleから読み込めません。"
        case let .invalidDefinition(reason): return "位置依存記号分類の定義が不正です: \(reason)"
        }
    }
}

/// Post-recognition geometry that remains in PencilKit's original coordinate
/// system.  It contains candidate evidence, not training labels or a claimed
/// final parse.
public struct Inf6SpatialRelationAnalysis: Codable, Equatable, Sendable {
    public struct Bounds: Codable, Equatable, Sendable {
        public let minX: Double
        public let minY: Double
        public let maxX: Double
        public let maxY: Double

        public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
            self.minX = minX
            self.minY = minY
            self.maxX = maxX
            self.maxY = maxY
        }

        public var width: Double { maxX - minX }
        public var height: Double { maxY - minY }
        public var centerX: Double { (minX + maxX) / 2 }
        public var centerY: Double { (minY + maxY) / 2 }
    }

    public struct CoordinateSpace: Codable, Equatable, Sendable {
        public let specificationVersion: String
        public let origin: String
        public let xAxis: String
        public let yAxis: String
        public let unit: String
        public let formulaBounds: Bounds

        public init(formulaBounds: Bounds) {
            specificationVersion = "hinotori-spatial-v1"
            origin = "PencilKit-canvas-top-left"
            xAxis = "right"
            yAxis = "down"
            unit = "PencilKit-points"
            self.formulaBounds = formulaBounds
        }
    }

    public struct Candidate: Codable, Equatable, Sendable {
        public let classIndex: Int
        public let label: String
        public let logit: Float
        public let ensembleProbability: Float?
    }

    public struct Symbol: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        public let strokeIndices: [Int]
        public let candidates: [Candidate]
        public let sourceBounds: Bounds
        /// Nil when the formula bounds have no non-zero extent on either axis.
        public let relativeBounds: Bounds?
    }

    public enum ProposalKind: String, Codable, Sendable, Equatable {
        case minusCandidate
        case fractionBarCandidate
        case underlineCandidate
        case superscriptCandidate
        case subscriptCandidate
    }

    public struct Proposal: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        public let kind: ProposalKind
        public let sourceSymbolID: String
        public let targetSymbolID: String?
        public let evidence: String

        public init(id: String, kind: ProposalKind, sourceSymbolID: String, targetSymbolID: String? = nil, evidence: String) {
            self.id = id
            self.kind = kind
            self.sourceSymbolID = sourceSymbolID
            self.targetSymbolID = targetSymbolID
            self.evidence = evidence
        }
    }

    public let coordinateSpace: CoordinateSpace
    public let symbols: [Symbol]
    public let proposals: [Proposal]
}

public enum Inf6SpatialRelationError: LocalizedError, Equatable {
    case emptyGroups
    case groupCandidateCountMismatch(groups: Int, candidates: Int)
    case emptyGroup(index: Int)
    case emptyCandidateGroup(index: Int)
    case invalidStrokeIndex(group: Int, stroke: Int)
    case invalidPoint(group: Int)
    case persistedAnalysisMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .emptyGroups: return "位置関係判定には記号群が1件以上必要です。"
        case let .groupCandidateCountMismatch(groups, candidates): return "記号群数\(groups)と候補群数\(candidates)が一致しません。"
        case let .emptyGroup(index): return "記号群\(index + 1)に画がありません。"
        case let .emptyCandidateGroup(index): return "記号群\(index + 1)に認識候補がありません。"
        case let .invalidStrokeIndex(group, stroke): return "記号群\(group + 1)が存在しない画\(stroke + 1)を参照しています。"
        case let .invalidPoint(group): return "記号群\(group + 1)に有限な元座標がありません。"
        case let .persistedAnalysisMismatch(reason): return "保存済み位置関係候補が認識結果と一致しません: \(reason)"
        }
    }
}

/// Constructs user-confirmed spatial relation candidates without learned or
/// hand-tuned thresholds.  A candidate is never a completed formula relation.
public enum Inf6SpatialRelationAnalyzer {
    public static func validate(
        _ analysis: Inf6SpatialRelationAnalysis,
        symbolLabels: [String],
        symbolStrokeIndices: [[Int]]
    ) throws {
        guard analysis.coordinateSpace.specificationVersion == "hinotori-spatial-v1",
              analysis.coordinateSpace.origin == "PencilKit-canvas-top-left",
              analysis.coordinateSpace.xAxis == "right",
              analysis.coordinateSpace.yAxis == "down",
              analysis.coordinateSpace.unit == "PencilKit-points" else {
            throw Inf6SpatialRelationError.persistedAnalysisMismatch("座標仕様")
        }
        guard analysis.symbols.count == symbolLabels.count,
              symbolLabels.count == symbolStrokeIndices.count else {
            throw Inf6SpatialRelationError.persistedAnalysisMismatch("記号数または画対応数")
        }
        for index in symbolLabels.indices {
            let symbol = analysis.symbols[index]
            guard symbol.id == "symbol-\(index)",
                  symbol.strokeIndices == symbolStrokeIndices[index],
                  symbol.candidates.contains(where: { $0.label == symbolLabels[index] }) else {
                throw Inf6SpatialRelationError.persistedAnalysisMismatch("記号\(index + 1)")
            }
        }
    }

    public static func analyze(
        groups: [[Int]],
        candidates: [[HinotoriCandidate]],
        strokes: [HinotoriStroke]
    ) throws -> Inf6SpatialRelationAnalysis {
        guard !groups.isEmpty else { throw Inf6SpatialRelationError.emptyGroups }
        guard groups.count == candidates.count else {
            throw Inf6SpatialRelationError.groupCandidateCountMismatch(groups: groups.count, candidates: candidates.count)
        }
        var rawSymbols: [(strokeIndices: [Int], candidates: [Inf6SpatialRelationAnalysis.Candidate], bounds: Inf6SpatialRelationAnalysis.Bounds)] = []
        rawSymbols.reserveCapacity(groups.count)
        for (groupIndex, group) in groups.enumerated() {
            guard !group.isEmpty else { throw Inf6SpatialRelationError.emptyGroup(index: groupIndex) }
            guard !candidates[groupIndex].isEmpty else { throw Inf6SpatialRelationError.emptyCandidateGroup(index: groupIndex) }
            for strokeIndex in group where !strokes.indices.contains(strokeIndex) {
                throw Inf6SpatialRelationError.invalidStrokeIndex(group: groupIndex, stroke: strokeIndex)
            }
            let points = group.flatMap { strokes[$0].points }
            guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(),
                  [minX, maxX, minY, maxY].allSatisfy(\.isFinite) else {
                throw Inf6SpatialRelationError.invalidPoint(group: groupIndex)
            }
            rawSymbols.append((
                strokeIndices: group,
                candidates: candidates[groupIndex].map { .init(classIndex: $0.classIndex, label: $0.label, logit: $0.logit, ensembleProbability: $0.ensembleProbability) },
                bounds: .init(minX: Double(minX), minY: Double(minY), maxX: Double(maxX), maxY: Double(maxY))
            ))
        }
        guard let first = rawSymbols.first else { throw Inf6SpatialRelationError.emptyGroups }
        let formulaBounds = rawSymbols.dropFirst().reduce(first.bounds) { partial, symbol in
            .init(minX: min(partial.minX, symbol.bounds.minX), minY: min(partial.minY, symbol.bounds.minY), maxX: max(partial.maxX, symbol.bounds.maxX), maxY: max(partial.maxY, symbol.bounds.maxY))
        }
        let canNormalize = formulaBounds.width > 0 && formulaBounds.height > 0
        let symbols = rawSymbols.enumerated().map { index, symbol in
            Inf6SpatialRelationAnalysis.Symbol(
                id: "symbol-\(index)",
                strokeIndices: symbol.strokeIndices,
                candidates: symbol.candidates,
                sourceBounds: symbol.bounds,
                relativeBounds: canNormalize ? normalized(symbol.bounds, in: formulaBounds) : nil
            )
        }
        var proposals: [Inf6SpatialRelationAnalysis.Proposal] = []
        for symbol in symbols where symbol.candidates.contains(where: { $0.label == "-" }) && symbol.sourceBounds.width > symbol.sourceBounds.height {
            appendLineRoleProposals(for: symbol, among: symbols, to: &proposals)
        }
        for base in symbols {
            for target in symbols where target.id != base.id && target.sourceBounds.centerX > base.sourceBounds.centerX {
                if target.sourceBounds.centerY < base.sourceBounds.centerY {
                    proposals.append(.init(
                        id: "\(base.id):\(target.id):superscript",
                        kind: .superscriptCandidate,
                        sourceSymbolID: base.id,
                        targetSymbolID: target.id,
                        evidence: pairEvidence(base: base, target: target, vertical: "above")
                    ))
                } else if target.sourceBounds.centerY > base.sourceBounds.centerY {
                    proposals.append(.init(
                        id: "\(base.id):\(target.id):subscript",
                        kind: .subscriptCandidate,
                        sourceSymbolID: base.id,
                        targetSymbolID: target.id,
                        evidence: pairEvidence(base: base, target: target, vertical: "below")
                    ))
                }
            }
        }
        return Inf6SpatialRelationAnalysis(
            coordinateSpace: .init(formulaBounds: formulaBounds),
            symbols: symbols,
            proposals: proposals
        )
    }

    /// Returns the zero-based recommendation rank derived from persisted source
    /// coordinates. It does not alter a Hinotori label or confirm a relation.
    public static func rank(
        of proposal: Inf6SpatialRelationAnalysis.Proposal,
        in analysis: Inf6SpatialRelationAnalysis
    ) -> Int? {
        switch proposal.kind {
        case .minusCandidate, .fractionBarCandidate, .underlineCandidate:
            guard let line = analysis.symbols.first(where: { $0.id == proposal.sourceSymbolID }) else {
                return nil
            }
            return lineRoleKinds(for: line, among: analysis.symbols).firstIndex(of: proposal.kind)
        case .superscriptCandidate, .subscriptCandidate:
            return 0
        }
    }

    private static func appendLineRoleProposals(
        for line: Inf6SpatialRelationAnalysis.Symbol,
        among symbols: [Inf6SpatialRelationAnalysis.Symbol],
        to proposals: inout [Inf6SpatialRelationAnalysis.Proposal]
    ) {
        let orderedKinds = lineRoleKinds(for: line, among: symbols)
        let others = symbols.filter { $0.id != line.id }
        let hasSymbolStrictlyAbove = others.contains { $0.sourceBounds.maxY < line.sourceBounds.minY }
        let hasSymbolStrictlyBelow = others.contains { $0.sourceBounds.minY > line.sourceBounds.maxY }
        let evidence = "horizontal-source-bounds width=\(line.sourceBounds.width) height=\(line.sourceBounds.height); label '-' is a recognition candidate; strictlyAbove=\(hasSymbolStrictlyAbove) strictlyBelow=\(hasSymbolStrictlyBelow)"
        for kind in orderedKinds {
            let suffix: String
            switch kind {
            case .minusCandidate: suffix = "minus"
            case .fractionBarCandidate: suffix = "fraction-bar"
            case .underlineCandidate: suffix = "underline"
            case .superscriptCandidate, .subscriptCandidate:
                preconditionFailure("Line-role ranking received a script proposal.")
            }
            proposals.append(.init(
                id: "\(line.id):\(suffix)",
                kind: kind,
                sourceSymbolID: line.id,
                evidence: evidence
            ))
        }
    }

    private static func lineRoleKinds(
        for line: Inf6SpatialRelationAnalysis.Symbol,
        among symbols: [Inf6SpatialRelationAnalysis.Symbol]
    ) -> [Inf6SpatialRelationAnalysis.ProposalKind] {
        let others = symbols.filter { $0.id != line.id }
        let hasSymbolStrictlyAbove = others.contains { $0.sourceBounds.maxY < line.sourceBounds.minY }
        let hasSymbolStrictlyBelow = others.contains { $0.sourceBounds.minY > line.sourceBounds.maxY }
        switch (hasSymbolStrictlyAbove, hasSymbolStrictlyBelow) {
        case (true, true):
            return [.fractionBarCandidate, .minusCandidate, .underlineCandidate]
        case (true, false):
            return [.underlineCandidate, .minusCandidate, .fractionBarCandidate]
        default:
            return [.minusCandidate, .fractionBarCandidate, .underlineCandidate]
        }
    }

    private static func normalized(_ bounds: Inf6SpatialRelationAnalysis.Bounds, in formulaBounds: Inf6SpatialRelationAnalysis.Bounds) -> Inf6SpatialRelationAnalysis.Bounds {
        .init(
            minX: (bounds.minX - formulaBounds.minX) / formulaBounds.width,
            minY: (bounds.minY - formulaBounds.minY) / formulaBounds.height,
            maxX: (bounds.maxX - formulaBounds.minX) / formulaBounds.width,
            maxY: (bounds.maxY - formulaBounds.minY) / formulaBounds.height
        )
    }

    private static func pairEvidence(base: Inf6SpatialRelationAnalysis.Symbol, target: Inf6SpatialRelationAnalysis.Symbol, vertical: String) -> String {
        let widthRatio = base.sourceBounds.width > 0 ? target.sourceBounds.width / base.sourceBounds.width : nil
        let heightRatio = base.sourceBounds.height > 0 ? target.sourceBounds.height / base.sourceBounds.height : nil
        let widthDescription = widthRatio.map { String($0) } ?? "undefined"
        let heightDescription = heightRatio.map { String($0) } ?? "undefined"
        return "target is right-and-\(vertical); widthRatio=\(widthDescription) heightRatio=\(heightDescription); user confirmation required"
    }
}

/// Reorders model candidates using source coordinates and the subset contract.
/// Explicitly identified rule supplements carry no model logit; neither
/// reordering nor supplementation confirms a formula relation.
public enum Inf6PositionSensitiveSymbolClassifier {
    public static let ruleVersion = "hinotori-position-rules-v1"

    public static func classify(
        analysis: Inf6SpatialRelationAnalysis,
        subset: HinotoriPositionSensitiveSubset,
        similarityExpansion: HinotoriVisualSubsetExpansion? = nil,
        vocabulary: HinotoriVocabulary? = nil
    ) -> Inf6PositionSensitiveClassification {
        let symbols = analysis.symbols.map { symbol in
            let similarity = similarityExpansion?.symbols.first(where: { $0.sourceSymbolID == symbol.id })
            let similarityCandidates = similarity?.supplements ?? []
            let group = subset.groups.first { group in
                symbol.candidates.contains { candidate in group.labels.contains(candidate.label) }
            }
            let original = symbol.candidates.map(\.classIndex)
            guard let group else {
                return Inf6PositionSensitiveClassification.Symbol(
                    sourceSymbolID: symbol.id,
                    originalCandidateClassIndices: original,
                    reorderedCandidateClassIndices: original,
                    candidateChoiceClassIndices: symbol.candidates.map(\.classIndex) + similarityCandidates.map(\.classIndex),
                    ruleSupplements: [],
                    matchedGroupID: nil,
                    evidence: "outside-position-sensitive-subset; Hinotori order retained",
                    confirmed: false
                )
            }
            let preference = preferredLabels(for: symbol, groupID: group.id, among: analysis.symbols)
            let reordered = reorder(symbol.candidates, eligibleLabels: Set(group.labels), preferredLabels: preference).map(\.classIndex)
            let candidateLabelsByClass = Dictionary(uniqueKeysWithValues: symbol.candidates.map { ($0.classIndex, $0.label) })
                .merging(Dictionary(uniqueKeysWithValues: similarityCandidates.map { ($0.classIndex, $0.label) }), uniquingKeysWith: { first, _ in first })
            let orderedSimilarityIndices = reorder(
                similarityCandidates.map(\.classIndex),
                labelsByClassIndex: candidateLabelsByClass,
                eligibleLabels: Set(group.labels),
                preferredLabels: preference
            )
            let orderedChoices = reordered + orderedSimilarityIndices
            return Inf6PositionSensitiveClassification.Symbol(
                sourceSymbolID: symbol.id,
                originalCandidateClassIndices: original,
                reorderedCandidateClassIndices: reordered,
                candidateChoiceClassIndices: orderedChoices,
                ruleSupplements: [],
                matchedGroupID: group.id,
                evidence: evidence(for: symbol, groupID: group.id, among: analysis.symbols, preference: preference),
                confirmed: false
            )
        }
        return .init(
            subsetSchema: subset.schema,
            sourceVocabularyContract: subset.sourceVocabularyContract,
            ruleVersion: ruleVersion,
            symbols: symbols
        )
    }

    /// Reconstructs the visible candidate sequence from the separately saved
    /// model, similarity, and position artifacts, validating their identities.
    public static func candidateLabels(
        analysis: Inf6SpatialRelationAnalysis,
        classification: Inf6PositionSensitiveClassification,
        similarityExpansion: HinotoriVisualSubsetExpansion
    ) throws -> [[String]] {
        guard classification.ruleVersion == ruleVersion,
              similarityExpansion.catalogSchema == "hinotori-vit-visual-similarity-subsets-v1",
              similarityExpansion.vocabularySHA256.count == 64,
              similarityExpansion.vitCheckpointSHA256.count == 64,
              similarityExpansion.vocabularySHA256.allSatisfy(\.isHexDigit),
              similarityExpansion.vitCheckpointSHA256.allSatisfy(\.isHexDigit),
              similarityExpansion.ruleVersion == HinotoriVisualSubsetCandidateExpander.ruleVersion,
              analysis.symbols.count == classification.symbols.count,
              analysis.symbols.count == similarityExpansion.symbols.count,
              analysis.symbols.map(\.id) == classification.symbols.map(\.sourceSymbolID),
              analysis.symbols.map(\.id) == similarityExpansion.symbols.map(\.sourceSymbolID) else {
            throw HinotoriVisualSubsetCandidateExpanderError.invalidCandidates("モデル・類似・位置成果物の記号IDまたは版が一致しません")
        }
        return try zip(zip(analysis.symbols, classification.symbols), similarityExpansion.symbols).map { (pair, similarity) in
            let (symbol, position) = pair
            let modelIndices = symbol.candidates.map(\.classIndex)
            guard similarity.modelCandidateClassIndices == modelIndices,
                  Set(similarity.supplements.map(\.classIndex)).count == similarity.supplements.count,
                  similarity.supplements.allSatisfy({ supplement in
                      supplement.origin == "hinotori-visual-subset"
                          && !modelIndices.contains(supplement.classIndex)
                          && (0..<HinotoriCoreMLExecutor.classCount).contains(supplement.classIndex)
                          && !supplement.label.isEmpty
                          && !supplement.subsetKey.isEmpty
                          && !supplement.matchedModelClassIndices.isEmpty
                          && Set(modelIndices).isSuperset(of: Set(supplement.matchedModelClassIndices))
                  }),
                  let choices = position.candidateChoiceClassIndices,
                  Set(choices).count == choices.count,
                  Set(choices) == Set(modelIndices + similarity.supplements.map(\.classIndex)) else {
                throw HinotoriVisualSubsetCandidateExpanderError.invalidCandidates("\(symbol.id)の候補由来または位置判定後の候補集合が不正です")
            }
            let labelsByClassIndex = Dictionary(uniqueKeysWithValues: symbol.candidates.map { ($0.classIndex, $0.label) })
                .merging(Dictionary(uniqueKeysWithValues: similarity.supplements.map { ($0.classIndex, $0.label) }), uniquingKeysWith: { first, _ in first })
            return try choices.map { classIndex in
                guard let label = labelsByClassIndex[classIndex] else {
                    throw HinotoriVisualSubsetCandidateExpanderError.invalidCandidates("\(symbol.id)の候補class index \(classIndex)を復元できません")
                }
                return label
            }
        }
    }

    private static func preferredLabels(
        for symbol: Inf6SpatialRelationAnalysis.Symbol,
        groupID: String,
        among symbols: [Inf6SpatialRelationAnalysis.Symbol]
    ) -> [String] {
        let others = symbols.filter { $0.id != symbol.id }
        let above = others.contains { $0.sourceBounds.maxY < symbol.sourceBounds.minY }
        let below = others.contains { $0.sourceBounds.minY > symbol.sourceBounds.maxY }
        switch groupID {
        case "horizontal-bar":
            switch (above, below) {
            case (true, true): return ["\\frac", "-", "\\underline", "\\overline"]
            case (true, false): return ["\\underline", "-", "\\frac", "\\overline"]
            case (false, true): return ["\\overline", "-", "\\frac", "\\underline"]
            case (false, false): return []
            }
        case "dot-mark":
            if below { return ["\\dot", ".", "\\cdot", "\\vdots"] }
            let hasLeft = others.contains { $0.sourceBounds.maxX < symbol.sourceBounds.minX && verticallyOverlaps($0.sourceBounds, symbol.sourceBounds) }
            let hasRight = others.contains { $0.sourceBounds.minX > symbol.sourceBounds.maxX && verticallyOverlaps($0.sourceBounds, symbol.sourceBounds) }
            return hasLeft && hasRight ? ["\\cdot", ".", "\\dot", "\\vdots"] : []
        case "punctuation-mark":
            let verticallyAlignedAbove = others.contains {
                $0.sourceBounds.maxY < symbol.sourceBounds.minY && horizontallyOverlaps($0.sourceBounds, symbol.sourceBounds)
            }
            let verticallyAlignedBelow = others.contains {
                $0.sourceBounds.minY > symbol.sourceBounds.maxY && horizontallyOverlaps($0.sourceBounds, symbol.sourceBounds)
            }
            let baselineNeighbors = others.filter {
                ($0.sourceBounds.maxX < symbol.sourceBounds.minX || $0.sourceBounds.minX > symbol.sourceBounds.maxX)
                    && verticallyOverlaps($0.sourceBounds, symbol.sourceBounds)
            }
            let isBelowBaseline = baselineNeighbors.map(\.sourceBounds.centerY).min().map { symbol.sourceBounds.centerY > $0 } ?? false
            if verticallyAlignedAbove && isBelowBaseline { return [";", ":", ","] }
            if verticallyAlignedAbove || verticallyAlignedBelow { return [":", ";", ","] }
            if isBelowBaseline { return [",", ";", ":"] }
            return []
        case "postfix-or-accent-mark":
            let baseBelow = others.contains { $0.sourceBounds.minY > symbol.sourceBounds.maxY && horizontallyOverlaps($0.sourceBounds, symbol.sourceBounds) }
            let baseLowerLeft = others.contains { $0.sourceBounds.maxX < symbol.sourceBounds.minX && $0.sourceBounds.minY > symbol.sourceBounds.maxY }
            if baseLowerLeft { return ["\\prime", "\\hat", "\\tilde", "\\vec"] }
            if baseBelow { return ["\\hat", "\\tilde", "\\vec", "\\prime"] }
            return []
        case "scalable-set-operator":
            let hasUpperLimit = others.contains {
                $0.sourceBounds.maxY < symbol.sourceBounds.minY && horizontallyOverlaps($0.sourceBounds, symbol.sourceBounds)
            }
            let hasLowerLimit = others.contains {
                $0.sourceBounds.minY > symbol.sourceBounds.maxY && horizontallyOverlaps($0.sourceBounds, symbol.sourceBounds)
            }
            let hasLeftOperand = others.contains {
                $0.sourceBounds.maxX < symbol.sourceBounds.minX && verticallyOverlaps($0.sourceBounds, symbol.sourceBounds)
            }
            let hasRightOperand = others.contains {
                $0.sourceBounds.minX > symbol.sourceBounds.maxX && verticallyOverlaps($0.sourceBounds, symbol.sourceBounds)
            }
            if hasUpperLimit && hasLowerLimit {
                return ["\\bigcap", "\\cap", "\\bigcup", "\\cup", "\\bigoplus", "\\oplus", "\\bigvee", "\\vee", "\\bigwedge", "\\wedge", "\\prod"]
            }
            if hasLeftOperand && hasRightOperand {
                return ["\\cap", "\\bigcap", "\\cup", "\\bigcup", "\\oplus", "\\bigoplus", "\\vee", "\\bigvee", "\\wedge", "\\bigwedge", "\\prod"]
            }
            return []
        case "operand-scope-operator":
            let hasCoveredRadicand = others.contains {
                $0.sourceBounds.minX >= symbol.sourceBounds.minX
                    && $0.sourceBounds.maxX <= symbol.sourceBounds.maxX
                    && verticallyOverlaps($0.sourceBounds, symbol.sourceBounds)
            }
            let hasLeftOperand = others.contains {
                $0.sourceBounds.maxX < symbol.sourceBounds.minX && verticallyOverlaps($0.sourceBounds, symbol.sourceBounds)
            }
            let hasRightOperand = others.contains {
                $0.sourceBounds.minX > symbol.sourceBounds.maxX && verticallyOverlaps($0.sourceBounds, symbol.sourceBounds)
            }
            let hasUpperLimit = others.contains {
                $0.sourceBounds.maxY < symbol.sourceBounds.minY && horizontallyOverlaps($0.sourceBounds, symbol.sourceBounds)
            }
            let hasLowerLimit = others.contains {
                $0.sourceBounds.minY > symbol.sourceBounds.maxY && horizontallyOverlaps($0.sourceBounds, symbol.sourceBounds)
            }
            if hasCoveredRadicand { return ["\\sqrt", "=", "\\sum", "\\int", "\\iint", "\\oint"] }
            if hasLeftOperand && hasRightOperand { return ["=", "\\sqrt", "\\sum", "\\int", "\\iint", "\\oint"] }
            if hasUpperLimit && hasLowerLimit && hasRightOperand {
                return ["\\sum", "\\int", "\\iint", "\\oint", "=", "\\sqrt"]
            }
            return []
        case "letter-digit-confusable":
            let neighborLabels = others.flatMap { $0.candidates.prefix(1).map(\.label) }
            if neighborLabels.contains(where: { $0.count == 1 && $0.first?.isNumber == true }) {
                return ["0", "O", "o"]
            }
            if neighborLabels.contains(where: { $0.count == 1 && $0.first?.isUppercase == true }) {
                return ["O", "o", "0"]
            }
            if neighborLabels.contains(where: { $0.count == 1 && $0.first?.isLowercase == true }) {
                return ["o", "O", "0"]
            }
            return []
        default:
            return []
        }
    }

    private static func evidence(
        for symbol: Inf6SpatialRelationAnalysis.Symbol,
        groupID: String,
        among symbols: [Inf6SpatialRelationAnalysis.Symbol],
        preference: [String]
    ) -> String {
        guard !preference.isEmpty else {
            return "group=\(groupID); no position rule with sufficient evidence; Hinotori order retained"
        }
        return "group=\(groupID); preferred-existing-labels=\(preference.joined(separator: ",")); source-coordinate rule; user confirmation required"
    }

    private static func reorder(
        _ candidates: [Inf6SpatialRelationAnalysis.Candidate],
        eligibleLabels: Set<String>,
        preferredLabels: [String]
    ) -> [Inf6SpatialRelationAnalysis.Candidate] {
        guard !preferredLabels.isEmpty else { return candidates }
        let eligibleSlots = candidates.indices.filter { eligibleLabels.contains(candidates[$0].label) }
        guard eligibleSlots.count > 1 else { return candidates }
        let orderedEligible = eligibleSlots.map { candidates[$0] }.enumerated().sorted { lhs, rhs in
            let left = preferredLabels.firstIndex(of: lhs.element.label)
            let right = preferredLabels.firstIndex(of: rhs.element.label)
            switch (left, right) {
            case let (.some(left), .some(right)): return left == right ? lhs.offset < rhs.offset : left < right
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs.offset < rhs.offset
            }
        }.map(\.element)
        var result = candidates
        for (slot, candidate) in zip(eligibleSlots, orderedEligible) {
            result[slot] = candidate
        }
        return result
    }

    private static func reorder(
        _ classIndices: [Int],
        labelsByClassIndex: [Int: String],
        eligibleLabels: Set<String>,
        preferredLabels: [String]
    ) -> [Int] {
        guard !preferredLabels.isEmpty else { return classIndices }
        let eligibleSlots = classIndices.indices.filter { slot in
            guard let label = labelsByClassIndex[classIndices[slot]] else { return false }
            return eligibleLabels.contains(label)
        }
        guard eligibleSlots.count > 1 else { return classIndices }
        let orderedEligible = eligibleSlots.map { classIndices[$0] }.enumerated().sorted { lhs, rhs in
            let left = labelsByClassIndex[lhs.element].flatMap(preferredLabels.firstIndex(of:))
            let right = labelsByClassIndex[rhs.element].flatMap(preferredLabels.firstIndex(of:))
            switch (left, right) {
            case let (.some(left), .some(right)): return left == right ? lhs.offset < rhs.offset : left < right
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs.offset < rhs.offset
            }
        }.map(\.element)
        var result = classIndices
        for (slot, classIndex) in zip(eligibleSlots, orderedEligible) {
            result[slot] = classIndex
        }
        return result
    }

    private static func horizontallyOverlaps(_ lhs: Inf6SpatialRelationAnalysis.Bounds, _ rhs: Inf6SpatialRelationAnalysis.Bounds) -> Bool {
        lhs.minX <= rhs.maxX && rhs.minX <= lhs.maxX
    }

    private static func verticallyOverlaps(_ lhs: Inf6SpatialRelationAnalysis.Bounds, _ rhs: Inf6SpatialRelationAnalysis.Bounds) -> Bool {
        lhs.minY <= rhs.maxY && rhs.minY <= lhs.maxY
    }
}

public enum TexTellerFormulaRecognitionError: LocalizedError {
    case imageUnavailable
    case invalidImage
    case modelUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .imageUnavailable: return "数式画像を読み込めません。"
        case .invalidImage: return "数式画像の形式が不正です。"
        case let .modelUnavailable(reason): return "数式画像モデルを読み込めません: \(reason)"
        }
    }
}

/// Recognition for a paper's raster formula crop; it does not consume Pencil strokes.
public enum TexTellerFormulaRecognition {
    public static let imageSize = 448
    private static let imageMean: Float = 0.9545467
    private static let imageStd: Float = 0.15394445
    private static let logger = Logger(subsystem: "com.inf6.inf6", category: "TexTellerCoreML")

    public static func makePixelValues(from image: UIImage) throws -> MLMultiArray {
        guard let cgImage = image.cgImage else { throw TexTellerFormulaRecognitionError.invalidImage }
        let width = imageSize
        let height = imageSize
        let sourceWidth = cgImage.width
        let sourceHeight = cgImage.height
        var sourcePixels = [UInt8](repeating: 255, count: sourceWidth * sourceHeight)
        guard let sourceContext = CGContext(data: &sourcePixels, width: sourceWidth, height: sourceHeight, bitsPerComponent: 8, bytesPerRow: sourceWidth, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw TexTellerFormulaRecognitionError.invalidImage }
        sourceContext.translateBy(x: 0, y: CGFloat(sourceHeight))
        sourceContext.scaleBy(x: 1, y: -1)
        sourceContext.setFillColor(gray: 1, alpha: 1)
        sourceContext.fill(CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
        sourceContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
        var minX = sourceWidth
        var minY = sourceHeight
        var maxX = -1
        var maxY = -1
        var inkCount = 0
        for y in 0..<sourceHeight {
            for x in 0..<sourceWidth where sourcePixels[y * sourceWidth + x] < 240 {
                inkCount += 1; minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        let cropRect = maxX >= minX && maxY >= minY ? CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1) : CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
        logger.info("TexTeller ink bounds: count=\(inkCount, privacy: .public), x=\(minX, privacy: .public)..\(maxX, privacy: .public), y=\(minY, privacy: .public)..\(maxY, privacy: .public)")
        guard let sourceImage = sourceContext.makeImage(), let croppedImage = sourceImage.cropping(to: cropRect) else { throw TexTellerFormulaRecognitionError.invalidImage }
        var pixels = [UInt8](repeating: 255, count: width * height)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw TexTellerFormulaRecognitionError.invalidImage }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = min(CGFloat(width) / cropRect.width, CGFloat(height) / cropRect.height)
        guard scale.isFinite, scale > 0 else { throw TexTellerFormulaRecognitionError.invalidImage }
        let drawSize = CGSize(width: cropRect.width * scale, height: cropRect.height * scale)
        context.interpolationQuality = .high
        context.draw(croppedImage, in: CGRect(x: 0, y: 0, width: drawSize.width, height: drawSize.height))
        let values = try MLMultiArray(shape: [1, 1, NSNumber(value: height), NSNumber(value: width)], dataType: .float32)
        for index in 0..<(width * height) { values[index] = NSNumber(value: (Float(pixels[index]) / 255 - imageMean) / imageStd) }
        return values
    }

    public static func recognize(imageData: Data, bundle: Bundle = .main) throws -> TexTellerMathMLResult {
        guard let image = UIImage(data: imageData) else { throw TexTellerFormulaRecognitionError.imageUnavailable }
        let pixels = try makePixelValues(from: image)
        logger.info("paper formula crop accepted; shape=1x1x448x448")
        let manager = try TexTellerExecutionManager(bundledIn: bundle)
        let vocabulary = try TexTellerVocabulary(bundle: bundle)
        return try manager.generateMathML(pixelValues: pixels, startTokenID: 2, eosTokenID: 2, maximumTokens: 1_024, vocabulary: vocabulary)
    }
}

#if canImport(PencilKit)
/// Pencil input is classified as grouped symbols by the shipped Hinotori
/// trajectory model.  It intentionally returns provisional candidates: no
/// unsupported formula grammar is fabricated from the candidate groups.
public enum Inf6HandwrittenFormulaRecognition {
    /// Hinotori groups are produced in stroke-index order.  That order is not
    /// the mathematical reading order, so preserve the actual canvas geometry
    /// before exposing candidates to the composition UI.
    public static func orderGroupsLeftToRight(
        groups: [[Int]],
        candidates: [[HinotoriCandidate]],
        classLogits: [[Float]],
        classFeatureDistances: [[Float]],
        fold7SimilarityCandidates: [[[HinotoriFold7SimilarityCandidate]]] = [],
        strokes: [HinotoriStroke]
    ) throws -> (groups: [[Int]], candidates: [[HinotoriCandidate]], classLogits: [[Float]], classFeatureDistances: [[Float]], fold7SimilarityCandidates: [[[HinotoriFold7SimilarityCandidate]]]) {
        guard groups.count == candidates.count,
              groups.count == classLogits.count,
              groups.count == classFeatureDistances.count,
              !groups.isEmpty,
              groups.allSatisfy({ !$0.isEmpty }),
              candidates.allSatisfy({ !$0.isEmpty }),
              (fold7SimilarityCandidates.isEmpty || fold7SimilarityCandidates.count == groups.count),
              fold7SimilarityCandidates.isEmpty || zip(candidates, fold7SimilarityCandidates).allSatisfy({ pair in pair.0.count == pair.1.count }) else {
            throw Inf6HandwrittenFormulaError.recognitionFailed("Hinotoriの候補群対応が不正です")
        }
        let ordered = try groups.enumerated().map { index, group -> (index: Int, group: [Int], candidates: [HinotoriCandidate], logits: [Float], distances: [Float], similarities: [[HinotoriFold7SimilarityCandidate]], minX: CGFloat, minY: CGFloat) in
            guard group.allSatisfy(strokes.indices.contains) else {
                throw Inf6HandwrittenFormulaError.recognitionFailed("Hinotoriの候補群が入力ストロークを参照していません")
            }
            let points = group.flatMap { strokes[$0].points }
            guard let minX = points.map(\.x).min(), let minY = points.map(\.y).min(), minX.isFinite, minY.isFinite else {
                throw Inf6HandwrittenFormulaError.recognitionFailed("Hinotoriの候補群に有効な座標がありません")
            }
            guard classFeatureDistances[index].count == HinotoriCoreMLExecutor.classCount,
                  classFeatureDistances[index].allSatisfy({ $0.isFinite && (0...2).contains($0) }) else {
                throw Inf6HandwrittenFormulaError.recognitionFailed("Hinotoriのクラス特徴距離が229件の有限値ではありません")
            }
            guard classLogits[index].count == HinotoriCoreMLExecutor.classCount,
                  classLogits[index].allSatisfy(\.isFinite) else {
                throw Inf6HandwrittenFormulaError.recognitionFailed("Fold7の未加工分類ロジットが229件の有限値ではありません")
            }
            return (index, group, candidates[index], classLogits[index], classFeatureDistances[index], fold7SimilarityCandidates.isEmpty ? [] : fold7SimilarityCandidates[index], minX, minY)
        }.sorted {
            if $0.minX != $1.minX { return $0.minX < $1.minX }
            if $0.minY != $1.minY { return $0.minY < $1.minY }
            return $0.index < $1.index
        }
        return (ordered.map { $0.group }, ordered.map { $0.candidates }, ordered.map { $0.logits }, ordered.map { $0.distances }, ordered.map { $0.similarities })
    }

    public static func recognize(drawing: PKDrawing, centerFraction: CGFloat = 0.44, surfaceSize: CGSize? = nil, bundle: Bundle = .main, symbolRecognizer: (any HinotoriSymbolRecognitionEngine)? = nil, cancellationCheck: @Sendable () -> Bool = { false }) throws -> Inf6HandwrittenMathMLResult {
        if cancellationCheck() { throw Inf6HandwrittenFormulaError.cancelled }
        let grid9 = try Inf6FormulaGrid9.analyze(drawing: drawing, centerFraction: centerFraction, surfaceSize: surfaceSize)
        let strokes = drawing.strokes.map { HinotoriStroke(points: Inf6NonAutoregressiveSymbolRecognizer.points(of: $0)) }
        try HinotoriCoreMLExecutor.validateFormulaInput(strokes)
        if cancellationCheck() { throw Inf6HandwrittenFormulaError.cancelled }
        let activeSymbolRecognizer: any HinotoriSymbolRecognitionEngine
        if let symbolRecognizer {
            activeSymbolRecognizer = symbolRecognizer
        } else {
            activeSymbolRecognizer = try HinotoriFormulaFold7Engine(bundle: bundle)
        }
        let recognition = try activeSymbolRecognizer.recognize(strokes, topK: 5)
        if cancellationCheck() { throw Inf6HandwrittenFormulaError.cancelled }
        guard recognition.groups.count == recognition.candidates.count,
              !recognition.groups.isEmpty,
              recognition.candidates.allSatisfy({ !$0.isEmpty }) else {
            throw Inf6HandwrittenFormulaError.recognitionFailed("形状認識モデルが有効な記号候補群を返しませんでした")
        }
        let orderedRecognition = try orderGroupsLeftToRight(
            groups: recognition.groups,
            candidates: recognition.candidates,
            classLogits: recognition.classLogits,
            classFeatureDistances: recognition.classFeatureDistances,
            fold7SimilarityCandidates: recognition.fold7SimilarityCandidates,
            strokes: strokes
        )
        let groupCells = orderedRecognition.groups.map { group in
            grid9.cells.first(where: { cell in
                !cell.strokeIndices.isEmpty && Set(group).isSubset(of: Set(cell.strokeIndices))
            })?.index ?? 5
        }
        let vocabulary = try HinotoriVocabulary.loadFold7(bundle: bundle)
        let similarityCatalog = try HinotoriVisualSimilaritySubsetCatalog.load(bundle: bundle)
        let typesetClassifier = try HinotoriTypesetAuxiliaryCoreMLClassifier(bundle: bundle)
        let candidateEnsemble = try HinotoriSymbolCandidateEnsemble(bundle: bundle)
        let allTypesetCandidates = try orderedRecognition.groups.enumerated().map { index, group -> [HinotoriTypesetCandidate] in
            if cancellationCheck() { throw Inf6HandwrittenFormulaError.cancelled }
            let groupStrokes = try group.map { strokeIndex -> [CGPoint] in
                guard strokes.indices.contains(strokeIndex) else {
                    throw Inf6HandwrittenFormulaError.recognitionFailed("活字候補が元ストローク範囲外を参照しています")
                }
                return strokes[strokeIndex].points
            }
            let candidates = try typesetClassifier.classify(
                callerDesignatedSymbolStrokeGroup: groupStrokes,
                sourceCoordinateSpace: .chatTextViewLocalPoints,
                topK: 222
            )
            guard candidates.count == 222,
                  candidates.allSatisfy({ $0.headCheckpointSHA256 == HinotoriTypesetAuxiliaryCoreMLClassifier.headCheckpointSHA256 }),
                  Set(candidates.map(\.classIndex)).count == 222 else {
                throw Inf6HandwrittenFormulaError.recognitionFailed("記号\(index + 1)の活字モデル全クラス出力が不正です")
            }
            return candidates
        }
        let ensembleCandidates = try orderedRecognition.groups.indices.map { index in
            try candidateEnsemble.rank(
                fold7Logits: orderedRecognition.classLogits[index],
                typesetCandidates: allTypesetCandidates[index],
                vocabulary: vocabulary,
                topK: 5
            )
        }
        guard let fold7Engine = activeSymbolRecognizer as? HinotoriFormulaFold7Engine else {
            throw Inf6HandwrittenFormulaError.recognitionFailed("火の鳥の87群コサイン展開器が認識エンジンに接続されていません")
        }
        let fusedFold7SimilarityCandidates = try orderedRecognition.groups.indices.map { groupIndex in
            try ensembleCandidates[groupIndex].map { candidate in
                try fold7Engine.similarCandidates(
                    forClassIndex: candidate.classIndex,
                    classCosineSimilarities: orderedRecognition.classFeatureDistances[groupIndex].map { 1 - $0 }
                ).candidates
            }
        }
        let typesetCandidates = allTypesetCandidates.map { Array($0.prefix(5)) }
        let similarityExpansion = try HinotoriVisualSubsetCandidateExpander.expand(
            candidates: ensembleCandidates,
            catalog: similarityCatalog,
            vocabulary: vocabulary
        )
        let spatialAnalysis = try Inf6SpatialRelationAnalyzer.analyze(
            groups: orderedRecognition.groups,
            candidates: ensembleCandidates,
            strokes: strokes
        )
        let subset = try HinotoriPositionSensitiveSubset.load(bundle: bundle)
        try subset.validate(vocabulary: vocabulary)
        let positionSensitiveClassification = Inf6PositionSensitiveSymbolClassifier.classify(
            analysis: spatialAnalysis,
            subset: subset,
            similarityExpansion: similarityExpansion,
            vocabulary: vocabulary
        )
        guard positionSensitiveClassification.symbols.count == ensembleCandidates.count else {
            throw Inf6HandwrittenFormulaError.recognitionFailed("位置依存記号分類の記号数がHinotori候補数と一致しません")
        }
        let reorderedCandidates = try zip(spatialAnalysis.symbols, positionSensitiveClassification.symbols).map { symbol, classification in
            guard symbol.id == classification.sourceSymbolID else {
                throw Inf6HandwrittenFormulaError.recognitionFailed("位置依存記号分類の記号IDがHinotori候補と一致しません")
            }
            let byClassIndex = Dictionary(uniqueKeysWithValues: symbol.candidates.map { ($0.classIndex, $0) })
            return try classification.reorderedCandidateClassIndices.map { classIndex in
                guard let candidate = byClassIndex[classIndex] else {
                    throw Inf6HandwrittenFormulaError.recognitionFailed("位置依存記号分類が存在しないHinotori候補を参照しています")
                }
                return candidate
            }
        }
        let selectableCandidates = try zip(spatialAnalysis.symbols, positionSensitiveClassification.symbols).map { symbol, classification -> [String] in
            let modelByClassIndex = Dictionary(uniqueKeysWithValues: symbol.candidates.map { ($0.classIndex, $0.label) })
            let similarityByClassIndex = Dictionary(uniqueKeysWithValues: (similarityExpansion.symbols.first(where: { $0.sourceSymbolID == symbol.id })?.supplements ?? []).map { ($0.classIndex, $0.label) })
            guard let candidateChoiceClassIndices = classification.candidateChoiceClassIndices else {
                throw Inf6HandwrittenFormulaError.recognitionFailed("類似・位置判定が統合候補順を返しませんでした")
            }
            return try candidateChoiceClassIndices.map { classIndex in
                guard let label = modelByClassIndex[classIndex] ?? similarityByClassIndex[classIndex] else {
                    throw Inf6HandwrittenFormulaError.recognitionFailed("類似・位置判定後の候補がモデル出力または類似候補にありません")
                }
                return label
            }
        }
        let candidateLabelsWithFold7Similarities = try selectableCandidates.enumerated().map { index, existing -> [String] in
            guard fusedFold7SimilarityCandidates.indices.contains(index),
                  fusedFold7SimilarityCandidates[index].count == ensembleCandidates[index].count else {
                throw Inf6HandwrittenFormulaError.recognitionFailed("火の鳥Top-5順位と87群コサイン候補の対応が不正です")
            }
            var labels = existing
            for candidate in fusedFold7SimilarityCandidates[index].flatMap({ $0 }) where !labels.contains(candidate.label) {
                labels.append(candidate.label)
            }
            return labels
        }
        return Inf6HandwrittenMathMLResult(
            tokenIDs: reorderedCandidates.map { Int32($0[0].classIndex) },
            decodedExpression: "",
            mathML: "",
            grid9: grid9,
            symbolLabels: reorderedCandidates.map { $0[0].label },
            symbolGridCellIndices: groupCells,
            symbolStrokeIndices: orderedRecognition.groups,
            candidateRanks: try zip(ensembleCandidates, reorderedCandidates).map { original, reordered in
                guard let rank = original.firstIndex(where: { $0.classIndex == reordered[0].classIndex }) else {
                    throw Inf6HandwrittenFormulaError.recognitionFailed("位置依存記号分類後の先頭候補が元のHinotori候補にありません")
                }
                return rank
            },
            candidateLabels: candidateLabelsWithFold7Similarities,
            candidateModelName: HinotoriSymbolCandidateEnsemble.modelName,
            candidateCalibrationSHA256: candidateEnsemble.calibrationSHA256,
            fold7Top5ClassIndices: orderedRecognition.candidates.map { $0.map(\.classIndex) },
            fold7Top5Logits: orderedRecognition.candidates.map { $0.map(\.logit) },
            fold7SimilarityCandidates: fusedFold7SimilarityCandidates,
            typesetCandidates: typesetCandidates,
            spatialAnalysis: spatialAnalysis,
            positionSensitiveClassification: positionSensitiveClassification,
            similarityExpansion: similarityExpansion,
            isProvisional: true
        )
    }
}
#endif
