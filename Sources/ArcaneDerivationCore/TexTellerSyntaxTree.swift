import Foundation

public enum TexTellerSyntaxTreeError: LocalizedError, Equatable {
    case empty
    case unexpectedEnd
    case unexpectedToken(String)
    case unsupportedCommand(String)

    public var errorDescription: String? {
        switch self {
        case .empty: return "復号された数式が空です。"
        case .unexpectedEnd: return "数式構造が途中で終わっています。"
        case .unexpectedToken(let value): return "数式構造に予期しない記号があります: \(value)"
        case .unsupportedCommand(let value): return "認識結果の数式コマンド「\\\(value)」は未登録です。未知数ではありません。数式の認識結果を確認してください。"
        }
    }
}

/// Builds a new expression by applying a selected MathML structure to the
/// current expression. The returned source is converted and validated by the
/// existing MathML converter before it reaches the UI or persistence layer.
public enum Inf6MathMLStructureComposer {
    public static func apply(itemID: String, itemExpression: String, to baseExpression: String?) -> String {
        let base = baseExpression?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !base.isEmpty else { return itemExpression }
        switch itemID {
        case "sqrt": return "\\sqrt{\(base)}"
        case "frac": return "\\frac{\(base)}{b}"
        case "superscript": return "{\(base)}^{2}"
        case "subscript": return "{\(base)}_{i}"
        case "hat": return "\\hat{\(base)}"
        case "overline": return "\\overline{\(base)}"
        case "vector": return "\\vec{\(base)}"
        case "bold-vector": return "\\mathbf{\(base)}"
        case "dot": return "\\dot{\(base)}"
        case "tilde": return "\\tilde{\(base)}"
        case "parentheses": return "\\left(\(base)\\right)"
        case "absolute": return "\\left|\(base)\\right|"
        default: return "\(base)+\(itemExpression)"
        }
    }
}

/// Deterministic structural representation between decoded TexTeller text and MathML.
public indirect enum TexTellerSyntaxNode: Equatable, Sendable {
    case sequence([TexTellerSyntaxNode])
    case atom(String)
    case command(String)
    case accented(TexTellerSyntaxNode, String)
    case fraction(TexTellerSyntaxNode, TexTellerSyntaxNode)
    case squareRoot(TexTellerSyntaxNode)
    case subscripted(TexTellerSyntaxNode, TexTellerSyntaxNode)
    case superscripted(TexTellerSyntaxNode, TexTellerSyntaxNode)
    case subscriptSuperscripted(TexTellerSyntaxNode, TexTellerSyntaxNode, TexTellerSyntaxNode)
}

public struct TexTellerSyntaxTree: Equatable, Sendable {
    public let root: TexTellerSyntaxNode

    public init(expression: String) throws {
        let tokens = Self.tokenize(Self.normalizeExpression(expression))
        guard !tokens.isEmpty else { throw TexTellerSyntaxTreeError.empty }
        var parser = Parser(tokens: tokens)
        root = .sequence(try parser.sequence(until: nil))
        guard parser.isAtEnd else { throw TexTellerSyntaxTreeError.unexpectedToken(parser.current) }
    }

    /// Removes only a matching outer display delimiter from model output.
    public static func normalizeExpression(_ expression: String) -> String {
        var value = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        for (opening, closing) in [("\\\\(", "\\\\)"), ("\\(", "\\)"), ("\\[", "\\]"), ("$", "$")] {
            if value.hasPrefix(opening), value.hasSuffix(closing), value.count >= opening.count + closing.count {
                value.removeFirst(opening.count)
                value.removeLast(closing.count)
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return value
    }

    public func mathML() throws -> String {
        let body = try Self.render(root)
        let mathML = "<math xmlns=\"http://www.w3.org/1998/Math/MathML\"><mrow>\(body)</mrow></math>"
        try MathMLValidator().validate(mathML)
        return mathML
    }

    private struct Parser {
        let tokens: [String]
        var position = 0
        var isAtEnd: Bool { position >= tokens.count }
        var current: String { isAtEnd ? "<終端>" : tokens[position] }

        mutating func sequence(until terminator: String?) throws -> [TexTellerSyntaxNode] {
            var result: [TexTellerSyntaxNode] = []
            while !isAtEnd && current != terminator {
                if current == "}" { throw TexTellerSyntaxTreeError.unexpectedToken(current) }
                let base = try atom()
                var sub: TexTellerSyntaxNode?
                var sup: TexTellerSyntaxNode?
                while current == "_" || current == "^" {
                    let marker = current
                    position += 1
                    let value = try argument()
                    if marker == "_" { sub = value } else { sup = value }
                }
                if let sub, let sup { result.append(.subscriptSuperscripted(base, sub, sup)) }
                else if let sub { result.append(.subscripted(base, sub)) }
                else if let sup { result.append(.superscripted(base, sup)) }
                else { result.append(base) }
            }
            if let terminator {
                guard current == terminator else { throw TexTellerSyntaxTreeError.unexpectedEnd }
                position += 1
            }
            return result
        }

        mutating func atom() throws -> TexTellerSyntaxNode {
            let token = current
            position += 1
            if token == "{" { return .sequence(try sequence(until: "}")) }
            if token.hasPrefix("\\") {
                let name = String(token.dropFirst())
                switch name {
                case "frac": return .fraction(try argument(), try argument())
                case "sqrt": return .squareRoot(try argument())
                case "hat": return .accented(try argument(), "^")
                case "left", "right":
                    guard !isAtEnd else { throw TexTellerSyntaxTreeError.unexpectedEnd }
                    let delimiter = current
                    position += 1
                    return .atom(delimiter)
                case "alpha", "beta", "gamma", "delta", "epsilon", "theta", "lambda", "mu", "pi", "sigma", "phi", "omega", "infty", "cdot", "times", "leq", "geq", "neq", "sum": return .command(name)
                default: throw TexTellerSyntaxTreeError.unsupportedCommand(name)
                }
            }
            guard token != "^" && token != "_" else { throw TexTellerSyntaxTreeError.unexpectedToken(token) }
            return .atom(token)
        }

        mutating func argument() throws -> TexTellerSyntaxNode {
            guard !isAtEnd else { throw TexTellerSyntaxTreeError.unexpectedEnd }
            if current == "{" { position += 1; return .sequence(try sequence(until: "}")) }
            return try atom()
        }
    }

    private static func tokenize(_ source: String) -> [String] {
        var result: [String] = []
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            index = source.index(after: index)
            if character.isWhitespace { continue }
            if character == "\\" {
                var command = ""
                while index < source.endIndex, source[index].isLetter {
                    command.append(source[index]); index = source.index(after: index)
                }
                result.append("\\" + command)
            } else { result.append(String(character)) }
        }
        return result
    }

    private static func render(_ node: TexTellerSyntaxNode) throws -> String {
        switch node {
        case .sequence(let nodes): return try nodes.map(render).joined()
        case .atom(let value):
            guard value.count == 1, let scalar = value.unicodeScalars.first else { throw TexTellerSyntaxTreeError.unexpectedToken(value) }
            if CharacterSet.decimalDigits.contains(scalar) { return "<mn>\(escape(value))</mn>" }
            if CharacterSet.letters.contains(scalar) { return "<mi>\(escape(value))</mi>" }
            if "=+-−*/×÷<>(),.:".contains(value) { return "<mo>\(escape(value))</mo>" }
            throw TexTellerSyntaxTreeError.unexpectedToken(value)
        case .command(let name):
            let symbols = ["alpha":"α", "beta":"β", "gamma":"γ", "delta":"δ", "epsilon":"ε", "theta":"θ", "lambda":"λ", "mu":"μ", "pi":"π", "sigma":"σ", "phi":"φ", "omega":"ω", "infty":"∞", "cdot":"⋅", "times":"×", "leq":"≤", "geq":"≥", "neq":"≠", "sum":"∑"]
            guard let symbol = symbols[name] else { throw TexTellerSyntaxTreeError.unsupportedCommand(name) }
            return "<mo>\(symbol)</mo>"
        case .accented(let value, let mark): return "<mover accent=\"true\">\(try render(value))<mo>\(escape(mark))</mo></mover>"
        case .fraction(let numerator, let denominator): return "<mfrac>\(try render(numerator))\(try render(denominator))</mfrac>"
        case .squareRoot(let value): return "<msqrt>\(try render(value))</msqrt>"
        case .subscripted(let base, let index): return "<msub>\(try render(base))\(try render(index))</msub>"
        case .superscripted(let base, let exponent): return "<msup>\(try render(base))\(try render(exponent))</msup>"
        case .subscriptSuperscripted(let base, let index, let exponent): return "<msubsup>\(try render(base))\(try render(index))\(try render(exponent))</msubsup>"
        }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
