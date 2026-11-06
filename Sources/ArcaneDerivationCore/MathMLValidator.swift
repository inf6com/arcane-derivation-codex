import Foundation

public enum MathMLError: LocalizedError {
    case empty
    case malformed(String)
    case missingMathRoot
    case forbiddenElement(String)

    public var errorDescription: String? {
        switch self {
        case .empty: return "MathMLが入力されていません。"
        case .malformed(let message): return "MathMLが不正です: \(message)"
        case .missingMathRoot: return "ルート要素 math が必要です。"
        case .forbiddenElement(let element): return "MathMLに許可されない要素です: \(element)"
        }
    }
}

public final class MathMLValidator: NSObject, XMLParserDelegate {
    private var parserError: String?
    private var rootName: String?
    private var depth = 0
    private var forbiddenElementName: String?
    private var unknownElementName: String?

    public func validate(_ source: String) throws {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MathMLError.empty }
        guard let data = source.data(using: .utf8) else { throw MathMLError.malformed("UTF-8として読めません") }
        parserError = nil
        rootName = nil
        depth = 0
        forbiddenElementName = nil
        unknownElementName = nil
        let parser = XMLParser(data: data)
        parser.delegate = self
        let parsed = parser.parse()
        if let forbiddenElementName { throw MathMLError.forbiddenElement(forbiddenElementName) }
        if rootName != "math", unknownElementName == rootName {
            throw MathMLError.missingMathRoot
        }
        if let unknownElementName { throw MathMLError.forbiddenElement(unknownElementName) }
        guard parsed else { throw MathMLError.malformed(parserError ?? "XML構文エラー") }
        guard rootName == "math", depth == 0 else { throw MathMLError.missingMathRoot }
    }

    public func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if depth == 0 { rootName = elementName }
        if ["script", "iframe", "object", "embed", "style"].contains(elementName.lowercased()) {
            forbiddenElementName = elementName
            parser.abortParsing()
            return
        }
        if !Self.allowedElements.contains(elementName.lowercased()) {
            unknownElementName = elementName
            parser.abortParsing()
            return
        }
        depth += 1
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { depth -= 1 }
    public func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { parserError = parseError.localizedDescription }

    private static let allowedElements: Set<String> = [
        // MathML root and presentation elements.
        "math", "mrow", "mi", "mn", "mo", "mtext", "mspace", "mglyph", "maligngroup", "malignmark",
        "mfrac", "msqrt", "mroot", "msup", "msub", "msubsup", "munder", "mover", "munderover", "mpadded",
        "mmultiscripts", "mprescripts", "none", "mtable", "mtr", "mlabeledtr", "mtd", "mstyle",
        "menclose", "mfenced", "maction", "semantics", "annotation", "annotation-xml",
        // Content MathML elements used for semantic verification.
        "apply", "reln", "fn", "interval", "list", "set", "vector", "matrix", "matrixrow",
        "piecewise", "piece", "otherwise", "ci", "cn", "csymbol", "cerror", "share",
        "plus", "minus", "times", "divide", "quotient", "rem", "dividend", "power", "root",
        "sqrt", "abs", "conjugate", "factorial", "floor", "ceiling", "exp", "ln", "log",
        "sin", "cos", "tan", "sec", "csc", "cot", "sinh", "cosh", "tanh", "arcsin", "arccos", "arctan",
        "diff", "partialdiff", "int", "sum", "product", "limit", "lowlimit", "uplimit",
        "eq", "neq", "lt", "leq", "gt", "geq", "approx", "equivalent", "and", "or", "xor", "not", "implies",
        "in", "notin", "subset", "prsubset", "notsubset", "union", "intersect", "setdiff", "cartesianproduct",
        "forall", "exists", "lambda", "declare", "domainofapplication", "domainofapplication", "ident",
        "true", "false", "notanumber", "infinity", "emptyset", "imaginaryi", "eulergamma", "pi", "exponentiale",
        "real", "imaginary", "integers", "reals", "rationals", "naturalnumbers", "complexes",
        "annotation-xml"
    ]
}
