import CoreML
import Foundation

struct Piece {
    let text: String
    let id: Int
    let score: Double
}

struct VectorRecord: Codable {
    let text: String
    let tokenIDs: [Int]
    let values: [Double]
}

struct VectorArtifact: Codable {
    let model: String
    let dimension: Int
    let records: [VectorRecord]
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let modelURL = root.appendingPathComponent("Models/Inf6TextEmbedding.mlmodelc")
let tokenizerURL = root.appendingPathComponent("Models/Inf6TextEmbeddingTokenizer/tokenizer.json")
let model = try MLModel(contentsOf: modelURL)
let tokenizerData = try Data(contentsOf: tokenizerURL)
let tokenizerObject = try JSONSerialization.jsonObject(with: tokenizerData) as! [String: Any]
let modelObject = tokenizerObject["model"] as! [String: Any]
let vocabulary = modelObject["vocab"] as! [[Any]]

var piecesByFirstCharacter: [Character: [Piece]] = [:]
for (id, item) in vocabulary.enumerated() {
    guard item.count == 2, let text = item[0] as? String, let score = item[1] as? NSNumber else { continue }
    guard let first = text.first else { continue }
    piecesByFirstCharacter[first, default: []].append(Piece(text: text, id: id, score: score.doubleValue))
}

func tokenize(_ text: String) throws -> [Int] {
    // The tokenizer uses SentencePiece-compatible Metaspace preprocessing.
    let metaspaceText = "▁" + text.replacingOccurrences(of: " ", with: "▁")
    let characters = Array(metaspaceText)
    let count = characters.count
    let negativeInfinity = -Double.greatestFiniteMagnitude
    var bestScore = Array(repeating: negativeInfinity, count: count + 1)
    var bestPrevious = Array(repeating: -1, count: count + 1)
    var bestPieceID = Array(repeating: -1, count: count + 1)
    bestScore[0] = 0

    for position in 0..<count where bestScore[position] > negativeInfinity {
        guard let candidates = piecesByFirstCharacter[characters[position]] else { continue }
        for piece in candidates {
            let pieceCharacters = Array(piece.text)
            let end = position + pieceCharacters.count
            guard end <= count else { continue }
            guard Array(characters[position..<end]) == pieceCharacters else { continue }
            let score = bestScore[position] + piece.score
            if score > bestScore[end] {
                bestScore[end] = score
                bestPrevious[end] = position
                bestPieceID[end] = piece.id
            }
        }
    }

    guard bestPrevious[count] >= 0 else {
        throw NSError(domain: "GenerateArcaneDerivationIcon", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Tokenizer could not segment \(text)"
        ])
    }
    var tokenIDs: [Int] = []
    var cursor = count
    while cursor > 0 {
        tokenIDs.append(bestPieceID[cursor])
        cursor = bestPrevious[cursor]
    }
    return [0] + tokenIDs.reversed() + [2]
}

func embedding(for text: String) throws -> VectorRecord {
    let tokenIDs = try tokenize(text)
    let inputIDs = try MLMultiArray(shape: [1, 256], dataType: .int32)
    let attentionMask = try MLMultiArray(shape: [1, 256], dataType: .int32)
    for index in 0..<256 {
        inputIDs[index] = NSNumber(value: index < tokenIDs.count ? tokenIDs[index] : 1)
        attentionMask[index] = NSNumber(value: index < tokenIDs.count ? 1 : 0)
    }
    let features = try MLDictionaryFeatureProvider(dictionary: [
        "input_ids": MLFeatureValue(multiArray: inputIDs),
        "attention_mask": MLFeatureValue(multiArray: attentionMask)
    ])
    let prediction = try model.prediction(from: features)
    guard let output = prediction.featureValue(for: "embeddings")?.multiArrayValue else {
        throw NSError(domain: "GenerateArcaneDerivationIcon", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Core ML output embeddings is missing"
        ])
    }
    let values = (0..<output.count).map { output[$0].doubleValue }
    return VectorRecord(text: text, tokenIDs: tokenIDs, values: values)
}

let records = try [embedding(for: "Arcane"), embedding(for: "Derivation")]
guard records.allSatisfy({ $0.values.count == 384 }) else {
    throw NSError(domain: "GenerateArcaneDerivationIcon", code: 3, userInfo: [
        NSLocalizedDescriptionKey: "Expected two 384-dimensional vectors"
    ])
}

let artifact = VectorArtifact(model: "Inf6TextEmbedding.mlmodelc", dimension: 384, records: records)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let vectorURL = root.appendingPathComponent("Design/ArcaneDerivation-vectors.json")
try encoder.encode(artifact).write(to: vectorURL, options: .atomic)

// Render each measured component in model order. Positive values extend
// upward and negative values extend downward from the shared baseline.
func hex(_ value: Double) -> String {
    String(format: "%02X", Int(max(0, min(255, value.rounded()))))
}

func neonColor(value: Double, maximum: Double) -> String {
    let amount = max(0, min(1, abs(value) / maximum))
    let start: (Double, Double, Double)
    let end: (Double, Double, Double)
    if value >= 0 {
        start = (0, 226, 255)
        end = (126, 77, 255)
    } else {
        start = (255, 62, 207)
        end = (255, 224, 78)
    }
    return "#\(hex(start.0 + (end.0 - start.0) * amount))\(hex(start.1 + (end.1 - start.1) * amount))\(hex(start.2 + (end.2 - start.2) * amount))"
}

func continuousField(for values: [Double], maximumHeight: Double, maximum: Double) -> String {
    let startX = 96.0
    let endX = 928.0
    let startY = 300.0
    let endY = 724.0
    let spacing = (endX - startX) / Double(values.count - 1)
    return values.enumerated().map { index, value in
        let progress = Double(index) / Double(values.count - 1)
        let x = startX + Double(index) * spacing
        let baseline = startY + (endY - startY) * progress + 24 * sin(progress * Double.pi * 2)
        let height = maximumHeight * (0.10 + 0.90 * sqrt(abs(value) / maximum))
        let y = value >= 0 ? baseline - height : baseline + height
        let color = neonColor(value: value, maximum: maximum)
        let opacity = 0.42 + 0.58 * abs(value) / maximum
        return String(format: "<line x1=\"%.3f\" y1=\"%.3f\" x2=\"%.3f\" y2=\"%.3f\" stroke=\"%@\" stroke-width=\"2.8\" stroke-linecap=\"round\" opacity=\"%.3f\"/>", x, baseline, x, y, color, opacity)
    }.joined()
}

func baselinePath() -> String {
    var points = "M 96 300"
    for index in 1...48 {
        let progress = Double(index) / 48.0
        let x = 96 + 832 * progress
        let y = 300 + 424 * progress + 24 * sin(progress * Double.pi * 2)
        points += String(format: " L %.3f %.3f", x, y)
    }
    return points
}

let glyphs: [Character: [String]] = [
    "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
    "C": ["01111", "10000", "10000", "10000", "10000", "10000", "01111"],
    "D": ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
    "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
    "I": ["11111", "00100", "00100", "00100", "00100", "00100", "11111"],
    "N": ["10001", "11001", "11001", "10101", "10011", "10011", "10001"],
    "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
    "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
    "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
    "V": ["10001", "10001", "10001", "10001", "10001", "01010", "00100"]
]

func glyphLines(_ word: String, originX: Double, originY: Double, scale: Double, maximum: Double, values: [Double]) -> String {
    let letters = Array(word)
    var result = ""
    for (letterIndex, letter) in letters.enumerated() {
        guard let pattern = glyphs[letter] else { continue }
        let letterX = originX + Double(letterIndex) * scale * 6
        let grid = pattern.map { Array($0).map { $0 == "1" } }
        func color(_ row: Int, _ column: Int) -> String {
            let sourceValue = values[(letterIndex * 11 + row * 5 + column) % values.count]
            return neonColor(value: sourceValue == 0 ? maximum : sourceValue, maximum: maximum)
        }
        for row in 0..<grid.count {
            var column = 0
            while column < grid[row].count {
                guard grid[row][column] else { column += 1; continue }
                let start = column
                while column + 1 < grid[row].count && grid[row][column + 1] { column += 1 }
                let end = column
                let x1 = letterX + Double(start) * scale + scale * 0.08
                let x2 = letterX + Double(end + 1) * scale - scale * 0.08
                let y = originY + Double(row) * scale
                result += String(format: "<line x1=\"%.3f\" y1=\"%.3f\" x2=\"%.3f\" y2=\"%.3f\" stroke=\"%@\" stroke-width=\"%.3f\" stroke-linecap=\"round\" opacity=\"0.98\"/>", x1, y, x2, y, color(row, start), max(3.0, scale * 0.28))
                column += 1
            }
        }
        for column in 0..<5 {
            var row = 0
            while row < grid.count {
                guard grid[row][column] else { row += 1; continue }
                let start = row
                while row + 1 < grid.count && grid[row + 1][column] { row += 1 }
                let end = row
                let x = letterX + (Double(column) + 0.5) * scale
                let y1 = originY + Double(start) * scale
                let y2 = originY + Double(end) * scale
                result += String(format: "<line x1=\"%.3f\" y1=\"%.3f\" x2=\"%.3f\" y2=\"%.3f\" stroke=\"%@\" stroke-width=\"%.3f\" stroke-linecap=\"round\" opacity=\"0.98\"/>", x, y1, x, y2, color(start, column), max(3.0, scale * 0.28))
                row += 1
            }
        }
    }
    return result
}

let maximum = max(records.flatMap { $0.values }.map { abs($0) }.max() ?? 1, 0.000001)
let fieldValues = records[0].values + records[1].values
let arcaneGlyph = glyphLines("ARCANE", originX: 126, originY: 188, scale: 15, maximum: maximum, values: records[0].values)
let derivationGlyph = glyphLines("DERIVATION", originX: 548, originY: 584, scale: 8, maximum: maximum, values: records[1].values)

let svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-labelledby="title desc">
  <title id="title">Arcane Derivation</title>
  <desc id="desc">A single continuous luminous field containing the measured embedding components in model order. Positive components rise and negative components fall. The names emerge from the same line field.</desc>
  <defs>
    <filter id="neon" x="-30%" y="-30%" width="160%" height="160%">
      <feGaussianBlur stdDeviation="2.5" result="blur"/>
      <feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
  </defs>
  <rect width="1024" height="1024" rx="224" fill="#005A9C"/>
  <g filter="url(#neon)" stroke-linecap="round">
    <path d="\(baselinePath())" fill="none" stroke="#C8F8FF" stroke-width="2" opacity="0.24"/>
    <g opacity="0.98">\(continuousField(for: fieldValues, maximumHeight: 176, maximum: maximum))</g>
    <g>\(arcaneGlyph)\(derivationGlyph)</g>
  </g>
</svg>
"""
let iconURL = root.appendingPathComponent("Design/ArcaneDerivationTablet-icon-exact.svg")
try Data(svg.utf8).write(to: iconURL, options: .atomic)

print("VECTOR_ARTIFACT: \(vectorURL.path)")
print("ICON_ARTIFACT: \(iconURL.path)")
for record in records {
    print("\(record.text): tokens=\(record.tokenIDs) dimensions=\(record.values.count)")
}
