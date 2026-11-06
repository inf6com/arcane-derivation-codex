import Foundation

public enum NumericExpressionError: LocalizedError {
    case invalid
    public var errorDescription: String? { "数値と四則演算だけで入力してください。" }
}

public enum NumericExpressionEvaluator {
    public static func evaluate(_ source: String) throws -> Double {
        let normalized = source.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: "−", with: "-")
        let tokens = normalized.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined()
        var parser = Parser(characters: Array(tokens))
        let value = try parser.expression()
        guard parser.index == parser.characters.count else { throw NumericExpressionError.invalid }
        return value
    }

    private struct Parser {
        let characters: [Character]
        var index = 0
        mutating func expression() throws -> Double {
            var value = try term()
            while index < characters.count, characters[index] == "+" || characters[index] == "-" {
                let op = characters[index]; index += 1; let rhs = try term(); value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }
        mutating func term() throws -> Double {
            var value = try factor()
            while index < characters.count, characters[index] == "*" || characters[index] == "/" {
                let op = characters[index]; index += 1; let rhs = try factor(); guard op != "/" || rhs != 0 else { throw NumericExpressionError.invalid }; value = op == "*" ? value * rhs : value / rhs
            }
            return value
        }
        mutating func factor() throws -> Double {
            if index < characters.count, characters[index] == "(" { index += 1; let value = try expression(); guard index < characters.count, characters[index] == ")" else { throw NumericExpressionError.invalid }; index += 1; return value }
            var text = ""
            while index < characters.count, characters[index].isNumber || characters[index] == "." { text.append(characters[index]); index += 1 }
            guard let value = Double(text) else { throw NumericExpressionError.invalid }; return value
        }
    }
}
