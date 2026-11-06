import Foundation
import JavaScriptCore

public enum LaTeXMathMLError: LocalizedError, Equatable {
    case empty
    case libraryUnavailable(String)
    case invalidExpression(String)

    public var errorDescription: String? {
        switch self {
        case .empty: return "数式認識結果が空です。"
        case .libraryUnavailable(let reason): return "数式変換ライブラリを利用できません: \(reason)"
        case .invalidExpression(let reason): return "数式を変換できません: \(reason)"
        }
    }
}

/// Converts TeX to presentation MathML using bundled Temml 0.14.0.
public struct LaTeXMathMLConverter {
    public init() {}

    public func convert(_ latex: String) throws -> String {
        guard !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LaTeXMathMLError.empty
        }
        guard let url = Bundle.main.url(forResource: "temml.min", withExtension: "js") else {
            throw LaTeXMathMLError.libraryUnavailable("temml.min.js がアプリに含まれていません")
        }
        let script = try String(contentsOf: url, encoding: .utf8)
        guard let context = JSContext() else {
            throw LaTeXMathMLError.libraryUnavailable("JavaScriptCore を初期化できません")
        }
        context.evaluateScript(script)
        if let exception = context.exception {
            throw LaTeXMathMLError.libraryUnavailable(exception.toString())
        }
        guard let temml = context.objectForKeyedSubscript("temml"), !temml.isUndefined else {
            throw LaTeXMathMLError.libraryUnavailable("Temml を初期化できません")
        }
        let result = temml.invokeMethod("renderToString", withArguments: [
            latex, ["throwOnError": true]
        ])
        if let exception = context.exception {
            throw LaTeXMathMLError.invalidExpression(exception.toString())
        }
        guard let result, !result.isUndefined, let rendered = result.toString(), rendered.hasPrefix("<math") else {
            throw LaTeXMathMLError.invalidExpression("MathML が生成されませんでした")
        }
        let mathML = rendered.replacingOccurrences(of: "<math", with: "<math xmlns=\"http://www.w3.org/1998/Math/MathML\"", range: rendered.startIndex..<rendered.index(rendered.startIndex, offsetBy: 5))
        try MathMLValidator().validate(mathML)
        return mathML
    }
}


public struct FormulaStructure: Codable, Sendable, Equatable {
    public struct Candidate: Codable, Sendable, Equatable {
        public let id: String
        public let label: String

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    public enum Kind: String, Codable, Sendable, Equatable {
        case symbol
        case sequence
        case superscript
        case subscripted
        case fraction
        case squareRoot
    }

    public struct Node: Codable, Sendable, Equatable {
        public let id: String
        public let kind: Kind
        public let candidateID: String?
        /// A handwritten structural operator selected by the user, such as
        /// `\\frac` or `\\sqrt`.  It is consumed exactly once by this node
        /// rather than being silently discarded from the recognition result.
        public let operatorCandidateID: String?
        public let children: [String]

        public init(id: String, kind: Kind, candidateID: String? = nil, operatorCandidateID: String? = nil, children: [String] = []) {
            self.id = id
            self.kind = kind
            self.candidateID = candidateID
            self.operatorCandidateID = operatorCandidateID
            self.children = children
        }
    }

    public let rootID: String
    public let candidates: [Candidate]
    public let nodes: [Node]

    public init(rootID: String, candidates: [Candidate], nodes: [Node]) {
        self.rootID = rootID
        self.candidates = candidates
        self.nodes = nodes
    }
}

public enum FormulaStructureError: LocalizedError, Equatable {
    case emptyCandidates
    case emptyNodes
    case duplicateCandidateID(String)
    case duplicateNodeID(String)
    case missingRoot(String)
    case unknownCandidate(nodeID: String, candidateID: String)
    case invalidCandidateLabel(candidateID: String, label: String)
    case invalidArity(nodeID: String, kind: FormulaStructure.Kind, expected: String, actual: Int)
    case unexpectedCandidate(nodeID: String, kind: FormulaStructure.Kind)
    case unexpectedOperatorCandidate(nodeID: String, kind: FormulaStructure.Kind)
    case missingCandidate(nodeID: String)
    case missingOperatorCandidate(nodeID: String, expectedLabel: String)
    case invalidOperatorCandidate(nodeID: String, candidateID: String, expectedLabel: String, actualLabel: String)
    case unknownChild(nodeID: String, childID: String)
    case cycle([String])
    case unconnectedNode(String)
    case unusedCandidate(String)
    case reusedCandidate(String)

    public var errorDescription: String? {
        switch self {
        case .emptyCandidates: return "数式構造化には、確定した記号候補が1件以上必要です。"
        case .emptyNodes: return "数式構造化には、構造ノードが1件以上必要です。"
        case .duplicateCandidateID(let id): return "記号候補IDが重複しています: \(id)"
        case .duplicateNodeID(let id): return "構造ノードIDが重複しています: \(id)"
        case .missingRoot(let id): return "ルート構造ノードが存在しません: \(id)"
        case .unknownCandidate(let nodeID, let candidateID): return "ノード \(nodeID) が未知の記号候補 \(candidateID) を参照しています。"
        case .invalidCandidateLabel(let candidateID, let label): return "記号候補 \(candidateID) のラベルは単一のLaTeX記号ではありません: \(label)"
        case .invalidArity(let nodeID, let kind, let expected, let actual): return "ノード \(nodeID)（\(kind.rawValue)）の子数が不正です。必要: \(expected)、実際: \(actual)。"
        case .unexpectedCandidate(let nodeID, let kind): return "ノード \(nodeID)（\(kind.rawValue)）は記号候補を直接参照できません。"
        case .unexpectedOperatorCandidate(let nodeID, let kind): return "ノード \(nodeID)（\(kind.rawValue)）は構造演算子候補を参照できません。"
        case .missingCandidate(let nodeID): return "記号ノード \(nodeID) に記号候補が指定されていません。"
        case .missingOperatorCandidate(let nodeID, let expectedLabel): return "ノード \(nodeID) に必要な構造演算子 \(expectedLabel) が指定されていません。"
        case .invalidOperatorCandidate(let nodeID, let candidateID, let expectedLabel, let actualLabel): return "ノード \(nodeID) の演算子候補 \(candidateID) は \(expectedLabel) である必要がありますが、\(actualLabel) です。"
        case .unknownChild(let nodeID, let childID): return "ノード \(nodeID) が未知の子ノード \(childID) を参照しています。"
        case .cycle(let path): return "数式構造に循環参照があります: \(path.joined(separator: " → "))"
        case .unconnectedNode(let id): return "ルートから到達できない構造ノードがあります: \(id)"
        case .unusedCandidate(let id): return "構造に接続されていない記号候補があります: \(id)"
        case .reusedCandidate(let id): return "記号候補が複数の記号ノードで使われています: \(id)"
        }
    }
}

public struct VerifiedFormulaStructure: Sendable, Equatable {
    public let latex: String
    public let mathML: String

    public init(latex: String, mathML: String) {
        self.latex = latex
        self.mathML = mathML
    }
}

public enum FormulaStructureEditingError: LocalizedError, Equatable {
    case missingNode(String)
    case nodeIsNotEditableSequence(String)
    case duplicateSelection(String)
    case selectionOutsideScope(nodeID: String, scopeID: String)
    case invalidSelectionCount(kind: FormulaStructure.Kind, expected: String, actual: Int)
    case operatorMustBeSymbol(String)

    public var errorDescription: String? {
        switch self {
        case .missingNode(let id): return "編集対象の構造ノードがありません: \(id)"
        case .nodeIsNotEditableSequence(let id): return "構造を追加できるのは横並びグループだけです: \(id)"
        case .duplicateSelection(let id): return "同じ構造要素を複数回選択しています: \(id)"
        case .selectionOutsideScope(let nodeID, let scopeID): return "選択した構造要素 \(nodeID) は現在の編集範囲 \(scopeID) にありません。"
        case .invalidSelectionCount(let kind, let expected, let actual): return "構造 \(kind.rawValue) の選択数が不正です。必要: \(expected)、実際: \(actual)。"
        case .operatorMustBeSymbol(let id): return "構造演算子は未構造化の記号候補で選択してください: \(id)"
        }
    }
}

/// Edits a FormulaStructure only through explicit sibling selections.
///
/// A draft may contain a structural operator such as `\\frac` before its
/// operands have been connected.  Final MathML validation therefore belongs
/// to `FormulaStructureComposer`, which is called only when the user confirms
/// the complete structure.
public struct FormulaStructureEditor {
    public init() {}

    /// Returns an editable sequence for the selected expression slot. A leaf
    /// is wrapped in a one-child sequence so additional handwritten siblings
    /// can be attached inside that slot without changing its rendered value.
    public func editableSequenceScope(
        _ structure: FormulaStructure,
        nodeID: String
    ) throws -> (structure: FormulaStructure, scopeID: String) {
        guard let node = structure.nodes.first(where: { $0.id == nodeID }) else {
            throw FormulaStructureEditingError.missingNode(nodeID)
        }
        if node.kind == .sequence {
            return (structure, nodeID)
        }
        let parents = structure.nodes.filter { $0.children.contains(nodeID) }
        guard parents.count == 1, let parent = parents.first,
              let childIndex = parent.children.firstIndex(of: nodeID) else {
            throw FormulaStructureEditingError.missingNode(nodeID)
        }
        let nodeIDs = Set(structure.nodes.map(\.id))
        var suffix = structure.nodes.count
        var scopeID = "scope-sequence-\(suffix)"
        while nodeIDs.contains(scopeID) {
            suffix += 1
            scopeID = "scope-sequence-\(suffix)"
        }
        var children = parent.children
        children[childIndex] = scopeID
        let updatedParent = FormulaStructure.Node(
            id: parent.id,
            kind: parent.kind,
            candidateID: parent.candidateID,
            operatorCandidateID: parent.operatorCandidateID,
            children: children
        )
        let updated = FormulaStructure(
            rootID: structure.rootID,
            candidates: structure.candidates,
            nodes: structure.nodes.filter { $0.id != parent.id } + [
                updatedParent,
                FormulaStructure.Node(id: scopeID, kind: .sequence, children: [nodeID])
            ]
        )
        return (updated, scopeID)
    }

    public func makeDraft(labels: [String]) throws -> FormulaStructure {
        let candidates = labels.enumerated().map { FormulaStructure.Candidate(id: "candidate-\($0.offset)", label: $0.element) }
        let symbols = labels.indices.map { FormulaStructure.Node(id: "symbol-\($0)", kind: .symbol, candidateID: "candidate-\($0)") }
        let draft = FormulaStructure(rootID: "root", candidates: candidates, nodes: symbols + [FormulaStructure.Node(id: "root", kind: .sequence, children: symbols.map(\.id))])
        return draft
    }

    public func replacingCandidate(
        _ structure: FormulaStructure,
        candidateID: String,
        label: String
    ) throws -> FormulaStructure {
        guard structure.candidates.contains(where: { $0.id == candidateID }) else {
            throw FormulaStructureError.unknownCandidate(nodeID: structure.rootID, candidateID: candidateID)
        }
        let updated = FormulaStructure(
            rootID: structure.rootID,
            candidates: structure.candidates.map { $0.id == candidateID ? .init(id: $0.id, label: label) : $0 },
            nodes: structure.nodes
        )
        return updated
    }

    public func parentID(of nodeID: String, in structure: FormulaStructure) -> String? {
        structure.nodes.first(where: { $0.children.contains(nodeID) })?.id
    }

    public func combine(
        _ structure: FormulaStructure,
        in scopeID: String,
        kind: FormulaStructure.Kind,
        selectedNodeIDs: [String]
    ) throws -> FormulaStructure {
        guard Set(selectedNodeIDs).count == selectedNodeIDs.count else {
            throw FormulaStructureEditingError.duplicateSelection(selectedNodeIDs.first ?? "")
        }
        guard let scope = structure.nodes.first(where: { $0.id == scopeID }) else {
            throw FormulaStructureEditingError.missingNode(scopeID)
        }
        guard scope.kind == .sequence else {
            throw FormulaStructureEditingError.nodeIsNotEditableSequence(scopeID)
        }
        for nodeID in selectedNodeIDs where !scope.children.contains(nodeID) {
            throw FormulaStructureEditingError.selectionOutsideScope(nodeID: nodeID, scopeID: scopeID)
        }

        let expectedCount: Int
        switch kind {
        case .sequence: expectedCount = 2
        case .superscript, .subscripted, .squareRoot: expectedCount = 2
        case .fraction: expectedCount = 3
        case .symbol: throw FormulaStructureEditingError.invalidSelectionCount(kind: kind, expected: "構造関係", actual: selectedNodeIDs.count)
        }
        guard selectedNodeIDs.count == expectedCount else {
            throw FormulaStructureEditingError.invalidSelectionCount(kind: kind, expected: "\(expectedCount)", actual: selectedNodeIDs.count)
        }

        let nodeByID = Dictionary(uniqueKeysWithValues: structure.nodes.map { ($0.id, $0) })
        let operatorNodeID: String?
        let childIDs: [String]
        let operatorCandidateID: String?
        switch kind {
        case .fraction, .squareRoot:
            let operatorID = selectedNodeIDs[0]
            guard let operatorNode = nodeByID[operatorID], operatorNode.kind == .symbol,
                  let candidateID = operatorNode.candidateID else {
                throw FormulaStructureEditingError.operatorMustBeSymbol(operatorID)
            }
            operatorNodeID = operatorID
            operatorCandidateID = candidateID
            childIDs = Array(selectedNodeIDs.dropFirst())
        default:
            operatorNodeID = nil
            operatorCandidateID = nil
            childIDs = selectedNodeIDs
        }

        var suffix = structure.nodes.count
        var newID = "structure-\(kind.rawValue)-\(suffix)"
        while nodeByID[newID] != nil {
            suffix += 1
            newID = "structure-\(kind.rawValue)-\(suffix)"
        }
        let newNode = FormulaStructure.Node(id: newID, kind: kind, operatorCandidateID: operatorCandidateID, children: childIDs)
        let firstSelectionOffset = scope.children.indices.filter { selectedNodeIDs.contains(scope.children[$0]) }.min() ?? 0
        var rewrittenChildren = scope.children.filter { !selectedNodeIDs.contains($0) }
        rewrittenChildren.insert(newID, at: min(firstSelectionOffset, rewrittenChildren.count))
        let rewrittenScope = FormulaStructure.Node(id: scope.id, kind: scope.kind, candidateID: scope.candidateID, operatorCandidateID: scope.operatorCandidateID, children: rewrittenChildren)
        var nodes = structure.nodes.filter { $0.id != scopeID && $0.id != operatorNodeID }
        nodes.append(rewrittenScope)
        nodes.append(newNode)
        return FormulaStructure(rootID: structure.rootID, candidates: structure.candidates, nodes: nodes)
    }
}

/// Produces a verified LaTeX/MathML artifact from only explicitly selected
/// relationships. It deliberately has no geometric or probability-based path.
public struct FormulaStructureComposer {
    public init() {}

    public func compose(_ structure: FormulaStructure) throws -> VerifiedFormulaStructure {
        guard !structure.candidates.isEmpty else { throw FormulaStructureError.emptyCandidates }
        guard !structure.nodes.isEmpty else { throw FormulaStructureError.emptyNodes }

        let candidateByID = try uniqueCandidates(structure.candidates)
        let nodeByID = try uniqueNodes(structure.nodes)
        guard nodeByID[structure.rootID] != nil else { throw FormulaStructureError.missingRoot(structure.rootID) }

        var active: [String] = []
        var visited = Set<String>()
        var candidateUses: [String: Int] = [:]

        func latex(for nodeID: String) throws -> String {
            guard let node = nodeByID[nodeID] else {
                let parent = active.last ?? structure.rootID
                throw FormulaStructureError.unknownChild(nodeID: parent, childID: nodeID)
            }
            if let cycleStart = active.firstIndex(of: nodeID) {
                throw FormulaStructureError.cycle(Array(active[cycleStart...]) + [nodeID])
            }
            active.append(nodeID)
            defer { _ = active.popLast() }
            visited.insert(nodeID)

            switch node.kind {
            case .symbol:
                guard node.children.isEmpty else {
                    throw FormulaStructureError.invalidArity(nodeID: node.id, kind: node.kind, expected: "0", actual: node.children.count)
                }
                if node.operatorCandidateID != nil {
                    throw FormulaStructureError.unexpectedOperatorCandidate(nodeID: node.id, kind: node.kind)
                }
                guard let candidateID = node.candidateID else { throw FormulaStructureError.missingCandidate(nodeID: node.id) }
                guard let candidate = candidateByID[candidateID] else {
                    throw FormulaStructureError.unknownCandidate(nodeID: node.id, candidateID: candidateID)
                }
                guard Self.isSingleLatexAtom(candidate.label) else {
                    throw FormulaStructureError.invalidCandidateLabel(candidateID: candidate.id, label: candidate.label)
                }
                candidateUses[candidateID, default: 0] += 1
                return candidate.label

            case .sequence:
                try assertNoCandidate(node)
                try assertNoOperatorCandidate(node)
                try assertArity(node, expected: "1個以上") { $0 >= 1 }
                return try node.children.map(latex(for:)).joined()

            case .superscript:
                try assertNoCandidate(node)
                try assertNoOperatorCandidate(node)
                try assertArity(node, expected: "2", equals: 2)
                return "{\(try latex(for: node.children[0]))}^{\(try latex(for: node.children[1]))}"

            case .subscripted:
                try assertNoCandidate(node)
                try assertNoOperatorCandidate(node)
                try assertArity(node, expected: "2", equals: 2)
                return "{\(try latex(for: node.children[0]))}_{\(try latex(for: node.children[1]))}"

            case .fraction:
                try assertNoCandidate(node)
                try assertArity(node, expected: "2", equals: 2)
                try consumeOperator(node, expectedLabel: "\\frac", candidateByID: candidateByID, candidateUses: &candidateUses)
                return "\\frac{\(try latex(for: node.children[0]))}{\(try latex(for: node.children[1]))}"

            case .squareRoot:
                try assertNoCandidate(node)
                try assertArity(node, expected: "1", equals: 1)
                try consumeOperator(node, expectedLabel: "\\sqrt", candidateByID: candidateByID, candidateUses: &candidateUses)
                return "\\sqrt{\(try latex(for: node.children[0]))}"
            }
        }

        let latex = try latex(for: structure.rootID)
        for nodeID in nodeByID.keys where !visited.contains(nodeID) {
            throw FormulaStructureError.unconnectedNode(nodeID)
        }
        for candidateID in candidateByID.keys {
            switch candidateUses[candidateID, default: 0] {
            case 0: throw FormulaStructureError.unusedCandidate(candidateID)
            case 1: break
            default: throw FormulaStructureError.reusedCandidate(candidateID)
            }
        }
        let mathML = try LaTeXMathMLConverter().convert(latex)
        return VerifiedFormulaStructure(latex: latex, mathML: mathML)
    }

    private func uniqueCandidates(_ candidates: [FormulaStructure.Candidate]) throws -> [String: FormulaStructure.Candidate] {
        var result: [String: FormulaStructure.Candidate] = [:]
        for candidate in candidates {
            guard !candidate.id.isEmpty, result[candidate.id] == nil else {
                throw FormulaStructureError.duplicateCandidateID(candidate.id)
            }
            result[candidate.id] = candidate
        }
        return result
    }

    private func uniqueNodes(_ nodes: [FormulaStructure.Node]) throws -> [String: FormulaStructure.Node] {
        var result: [String: FormulaStructure.Node] = [:]
        for node in nodes {
            guard !node.id.isEmpty, result[node.id] == nil else {
                throw FormulaStructureError.duplicateNodeID(node.id)
            }
            result[node.id] = node
        }
        return result
    }

    private func assertNoCandidate(_ node: FormulaStructure.Node) throws {
        if node.candidateID != nil { throw FormulaStructureError.unexpectedCandidate(nodeID: node.id, kind: node.kind) }
    }

    private func assertNoOperatorCandidate(_ node: FormulaStructure.Node) throws {
        if node.operatorCandidateID != nil { throw FormulaStructureError.unexpectedOperatorCandidate(nodeID: node.id, kind: node.kind) }
    }

    private func consumeOperator(
        _ node: FormulaStructure.Node,
        expectedLabel: String,
        candidateByID: [String: FormulaStructure.Candidate],
        candidateUses: inout [String: Int]
    ) throws {
        guard let candidateID = node.operatorCandidateID else {
            throw FormulaStructureError.missingOperatorCandidate(nodeID: node.id, expectedLabel: expectedLabel)
        }
        guard let candidate = candidateByID[candidateID] else {
            throw FormulaStructureError.unknownCandidate(nodeID: node.id, candidateID: candidateID)
        }
        guard candidate.label == expectedLabel else {
            throw FormulaStructureError.invalidOperatorCandidate(nodeID: node.id, candidateID: candidateID, expectedLabel: expectedLabel, actualLabel: candidate.label)
        }
        candidateUses[candidateID, default: 0] += 1
    }

    private func assertArity(_ node: FormulaStructure.Node, expected: String, equals: Int) throws {
        guard node.children.count == equals else {
            throw FormulaStructureError.invalidArity(nodeID: node.id, kind: node.kind, expected: expected, actual: node.children.count)
        }
    }

    private func assertArity(_ node: FormulaStructure.Node, expected: String, _ predicate: (Int) -> Bool) throws {
        guard predicate(node.children.count) else {
            throw FormulaStructureError.invalidArity(nodeID: node.id, kind: node.kind, expected: expected, actual: node.children.count)
        }
    }

    private static func isSingleLatexAtom(_ label: String) -> Bool {
        guard !label.isEmpty, label == label.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        if label.first == "\\" {
            return label.dropFirst().allSatisfy(\.isLetter) && label.count > 1
        }
        return label.count == 1 && !"{}^_\\".contains(label)
    }
}
