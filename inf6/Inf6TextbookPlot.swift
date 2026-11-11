//
//  Inf6TextbookPlot.swift
//  inf6
//
//  解説項目の図（グラフ）を描く。
//

import Foundation
import UIKit

/// 関数の形そのものが理解の対象になる概念のために、グラフを描く。
///
/// 解説項目の根拠は、これまで文字を画像にしたものだけだった。シグモイド
/// 関数のように「どんな形か」が本体である概念では、式を並べても理解に届か
/// ない。形を見せる必要がある。
///
/// 曲線の点はこちらで計算する。モデルに数値を並べさせると、桁を誤っても
/// それらしく見えてしまい、間違ったグラフを根拠にしてしまう。
public enum Inf6TextbookPlot {

    public struct Series: Codable {
        public var label: String
        /// x の式。例: "1/(1+exp(-x))"
        public var expression: String
    }

    public struct Spec: Codable {
        public var xMin: Double
        public var xMax: Double
        public var series: [Series]

        /// 数の書き方が揺れても受け取る。
        ///
        /// -6 と "-6" と -6.0 のどれで来ても同じ意味である。型が合わないだけで
        /// 図が一つも作られないのでは、生成そのものが落ちる。
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func number(_ key: CodingKeys) throws -> Double {
                if let v = try? c.decode(Double.self, forKey: key) { return v }
                if let v = try? c.decode(Int.self, forKey: key) { return Double(v) }
                if let v = try? c.decode(String.self, forKey: key), let d = Double(v) { return d }
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "数として読めません")
            }
            xMin = try number(.xMin)
            xMax = try number(.xMax)
            series = (try? c.decode([Series].self, forKey: .series)) ?? []
        }

        public init(xMin: Double, xMax: Double, series: [Series]) {
            self.xMin = xMin; self.xMax = xMax; self.series = series
        }
    }

    // MARK: - 描画

    public static func render(_ spec: Spec, size: CGSize = CGSize(width: 1200, height: 760)) -> UIImage? {
        guard spec.xMax > spec.xMin, !spec.series.isEmpty else { return nil }

        let sampleCount = 480
        var curves: [(label: String, points: [CGPoint])] = []
        var yMin = Double.greatestFiniteMagnitude
        var yMax = -Double.greatestFiniteMagnitude

        for series in spec.series {
            guard let node = _Expression.parse(series.expression) else { continue }
            var points: [CGPoint] = []
            for index in 0...sampleCount {
                let x = spec.xMin + (spec.xMax - spec.xMin) * Double(index) / Double(sampleCount)
                guard let y = node.value(x: x), y.isFinite else { continue }
                yMin = min(yMin, y)
                yMax = max(yMax, y)
                points.append(CGPoint(x: x, y: y))
            }
            if !points.isEmpty { curves.append((series.label, points)) }
        }
        guard !curves.isEmpty, yMin < .greatestFiniteMagnitude else { return nil }

        // 値が一定の関数でも潰れないように、幅がなければ広げる。
        if yMax - yMin < 1e-9 { yMin -= 1; yMax += 1 }
        let margin = (yMax - yMin) * 0.08
        yMin -= margin
        yMax += margin

        let inset = CGSize(width: 96, height: 64)
        let plotRect = CGRect(
            x: inset.width,
            y: inset.height,
            width: size.width - inset.width * 2,
            height: size.height - inset.height * 2
        )

        func project(_ point: CGPoint) -> CGPoint {
            let tx = (Double(point.x) - spec.xMin) / (spec.xMax - spec.xMin)
            let ty = (Double(point.y) - yMin) / (yMax - yMin)
            return CGPoint(
                x: plotRect.minX + plotRect.width * tx,
                y: plotRect.maxY - plotRect.height * ty
            )
        }

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let cg = context.cgContext
            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            _drawGrid(cg, plotRect: plotRect, spec: spec, yMin: yMin, yMax: yMax, project: project)

            let palette: [UIColor] = [
                UIColor(red: 0.00, green: 0.35, blue: 0.61, alpha: 1),   // ドジャースブルー
                UIColor(red: 0.85, green: 0.33, blue: 0.10, alpha: 1),
                UIColor(red: 0.30, green: 0.55, blue: 0.20, alpha: 1),
                UIColor(red: 0.45, green: 0.25, blue: 0.65, alpha: 1),
            ]

            for (index, curve) in curves.enumerated() {
                let color = palette[index % palette.count]
                color.setStroke()
                cg.setLineWidth(4)
                cg.setLineJoin(.round)

                let path = UIBezierPath()
                for (n, point) in curve.points.enumerated() {
                    let p = project(point)
                    if n == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                path.stroke()

                let label = curve.label as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 26, weight: .semibold),
                    .foregroundColor: color,
                ]
                label.draw(
                    at: CGPoint(x: plotRect.minX + 16, y: plotRect.minY + 12 + CGFloat(index) * 36),
                    withAttributes: attributes
                )
            }
        }
    }

    private static func _drawGrid(
        _ cg: CGContext,
        plotRect: CGRect,
        spec: Spec,
        yMin: Double,
        yMax: Double,
        project: (CGPoint) -> CGPoint
    ) {
        UIColor(white: 0.88, alpha: 1).setStroke()
        cg.setLineWidth(1)

        let steps = 8
        for index in 0...steps {
            let x = spec.xMin + (spec.xMax - spec.xMin) * Double(index) / Double(steps)
            let top = project(CGPoint(x: x, y: yMax))
            let bottom = project(CGPoint(x: x, y: yMin))
            cg.move(to: top); cg.addLine(to: bottom); cg.strokePath()

            let text = String(format: "%g", x) as NSString
            text.draw(
                at: CGPoint(x: bottom.x - 18, y: plotRect.maxY + 10),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 20),
                    .foregroundColor: UIColor(white: 0.35, alpha: 1),
                ]
            )
        }
        for index in 0...steps {
            let y = yMin + (yMax - yMin) * Double(index) / Double(steps)
            let left = project(CGPoint(x: spec.xMin, y: y))
            let right = project(CGPoint(x: spec.xMax, y: y))
            cg.move(to: left); cg.addLine(to: right); cg.strokePath()

            let text = String(format: "%g", y) as NSString
            text.draw(
                at: CGPoint(x: plotRect.minX - 76, y: left.y - 12),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 20),
                    .foregroundColor: UIColor(white: 0.35, alpha: 1),
                ]
            )
        }

        // 原点の軸は濃く引く。関数の対称性や符号の変わり目が読める。
        UIColor(white: 0.45, alpha: 1).setStroke()
        cg.setLineWidth(2)
        if spec.xMin < 0 && spec.xMax > 0 {
            let top = project(CGPoint(x: 0, y: yMax))
            let bottom = project(CGPoint(x: 0, y: yMin))
            cg.move(to: top); cg.addLine(to: bottom); cg.strokePath()
        }
        if yMin < 0 && yMax > 0 {
            let left = project(CGPoint(x: spec.xMin, y: 0))
            let right = project(CGPoint(x: spec.xMax, y: 0))
            cg.move(to: left); cg.addLine(to: right); cg.strokePath()
        }
    }
}

// MARK: - 式の評価

/// x の式を読んで値を出す。
///
/// モデルに座標を並べさせず、式だけを出させてこちらで計算する。数値を
/// 並べさせると、桁を誤ってもそれらしく見え、誤ったグラフを根拠にして
/// しまう。扱うのは四則演算、べき乗、括弧、および E資格で必要になる
/// 範囲の関数に限る。
enum _Expression {

    indirect enum Node {
        case constant(Double)
        case variable
        case unaryMinus(Node)
        case binary(String, Node, Node)
        case call(String, [Node])

        func value(x: Double) -> Double? {
            switch self {
            case .constant(let v): return v
            case .variable: return x
            case .unaryMinus(let n): return n.value(x: x).map { -$0 }
            case .binary(let op, let l, let r):
                guard let a = l.value(x: x), let b = r.value(x: x) else { return nil }
                switch op {
                case "+": return a + b
                case "-": return a - b
                case "*": return a * b
                case "/": return b == 0 ? nil : a / b
                case "^": return pow(a, b)
                default: return nil
                }
            case .call(let name, let args):
                let values = args.compactMap { $0.value(x: x) }
                guard values.count == args.count else { return nil }
                switch (name, values.count) {
                case ("exp", 1):   return exp(values[0])
                case ("log", 1):   return values[0] > 0 ? log(values[0]) : nil
                case ("sqrt", 1):  return values[0] >= 0 ? sqrt(values[0]) : nil
                case ("abs", 1):   return abs(values[0])
                case ("tanh", 1):  return tanh(values[0])
                case ("sin", 1):   return sin(values[0])
                case ("cos", 1):   return cos(values[0])
                case ("max", 2):   return Swift.max(values[0], values[1])
                case ("min", 2):   return Swift.min(values[0], values[1])
                default: return nil
                }
            }
        }
    }

    static func parse(_ text: String) -> Node? {
        var parser = _Parser(Array(text.replacingOccurrences(of: " ", with: "")))
        guard let node = parser.expression(), parser.atEnd else { return nil }
        return node
    }

    private struct _Parser {
        let characters: [Character]
        var index = 0
        init(_ characters: [Character]) { self.characters = characters }

        var atEnd: Bool { index >= characters.count }
        private func peek() -> Character? { index < characters.count ? characters[index] : nil }

        mutating func expression() -> Node? {
            guard var left = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                index += 1
                guard let right = term() else { return nil }
                left = .binary(String(c), left, right)
            }
            return left
        }

        private mutating func term() -> Node? {
            guard var left = power() else { return nil }
            while let c = peek(), c == "*" || c == "/" {
                index += 1
                guard let right = power() else { return nil }
                left = .binary(String(c), left, right)
            }
            return left
        }

        private mutating func power() -> Node? {
            guard let base = unary() else { return nil }
            if peek() == "^" {
                index += 1
                guard let exponent = power() else { return nil }
                return .binary("^", base, exponent)
            }
            return base
        }

        private mutating func unary() -> Node? {
            if peek() == "-" { index += 1; return unary().map { Node.unaryMinus($0) } }
            if peek() == "+" { index += 1; return unary() }
            return primary()
        }

        private mutating func primary() -> Node? {
            guard let c = peek() else { return nil }

            if c == "(" {
                index += 1
                guard let node = expression(), peek() == ")" else { return nil }
                index += 1
                return node
            }
            if c.isNumber || c == "." {
                var text = ""
                while let d = peek(), d.isNumber || d == "." { text.append(d); index += 1 }
                return Double(text).map { Node.constant($0) }
            }
            if c.isLetter {
                var name = ""
                while let d = peek(), d.isLetter || d.isNumber { name.append(d); index += 1 }
                if peek() == "(" {
                    index += 1
                    var args: [Node] = []
                    while true {
                        guard let arg = expression() else { return nil }
                        args.append(arg)
                        if peek() == "," { index += 1; continue }
                        break
                    }
                    guard peek() == ")" else { return nil }
                    index += 1
                    return .call(name.lowercased(), args)
                }
                switch name.lowercased() {
                case "x": return .variable
                case "e": return .constant(M_E)
                case "pi": return .constant(Double.pi)
                default: return nil
                }
            }
            return nil
        }
    }
}
