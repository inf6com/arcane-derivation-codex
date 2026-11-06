import AppKit
import CoreText
import CryptoKit
import Foundation

private struct Vocabulary: Decodable {
    let version: String
    let labels: [String]
}

private struct GlyphMap: Decodable {
    struct Entry: Decodable {
        let label: String
        let unicodeScalar: String
    }
    let schema: String
    let sourceVocabularyContract: String
    let entries: [Entry]
}

private struct RenderManifest: Encodable {
    let schema: String
    let vocabularySHA256: String
    let glyphMapSHA256: String
    let fontSHA256: String
    let fontPostScriptName: String
    let rasterSize: Int
    let labels: [String]
    let inputValues: String
    let renderingContract: String
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func render(_ scalar: Unicode.Scalar, label: String, font: CTFont, size: Int) throws -> [UInt8] {
    let units = Array(String(scalar).utf16)
    var glyphs = Array(repeating: CGGlyph.zero, count: units.count)
    let converted = units.withUnsafeBufferPointer { source in
        glyphs.withUnsafeMutableBufferPointer { destination in
            CTFontGetGlyphsForCharacters(font, source.baseAddress!, destination.baseAddress!, units.count)
        }
    }
    guard converted, glyphs.filter({ $0 != 0 }).count == 1,
          let glyph = glyphs.first(where: { $0 != 0 }),
          let path = CTFontCreatePathForGlyph(font, glyph, nil) else {
        throw NSError(domain: "TypesetRaster", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "\(label): フォントに単一の字形輪郭がありません"])
    }
    let bounds = path.boundingBoxOfPath
    guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
        throw NSError(domain: "TypesetRaster", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "\(label): 字形輪郭が空または不正です"])
    }
    let padding = 4.0
    let scale = (Double(size) - 2 * padding) / max(bounds.width, bounds.height)
    let tx = (Double(size) - bounds.width * scale) / 2 - bounds.minX * scale
    let ty = (Double(size) - bounds.height * scale) / 2 - bounds.minY * scale
    var pixels = Array(repeating: UInt8.zero, count: size * size)
    let colorSpace = CGColorSpaceCreateDeviceGray()
    guard let context = pixels.withUnsafeMutableBufferPointer({ buffer in
        CGContext(data: buffer.baseAddress, width: size, height: size,
                  bitsPerComponent: 8, bytesPerRow: size, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
    }) else {
        throw NSError(domain: "TypesetRaster", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "\(label): raster contextを作成できません"])
    }
    context.setAllowsAntialiasing(false)
    context.setShouldAntialias(false)
    context.setFillColor(gray: 1, alpha: 1)
    context.translateBy(x: tx, y: ty)
    context.scaleBy(x: scale, y: scale)
    context.addPath(path)
    context.fillPath()
    let binary = pixels.map { $0 >= 128 ? UInt8(1) : UInt8(0) }
    guard binary.contains(1) else {
        throw NSError(domain: "TypesetRaster", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "\(label): 字形画像が空です"])
    }
    return binary
}

private func run() throws {
    let args = CommandLine.arguments
    guard args.count == 9,
          args[1] == "--vocabulary", args[3] == "--glyph-map",
          args[5] == "--font", args[7] == "--output" else {
        throw NSError(domain: "TypesetRaster", code: 5,
                      userInfo: [NSLocalizedDescriptionKey: "Usage: RenderTypesetSymbolImages --vocabulary file --glyph-map file --font file --output prefix"])
    }
    let vocabularyURL = URL(fileURLWithPath: args[2])
    let mapURL = URL(fileURLWithPath: args[4])
    let fontURL = URL(fileURLWithPath: args[6])
    let outputPrefix = URL(fileURLWithPath: args[8])
    let outputDirectory = outputPrefix.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let rawURL = URL(fileURLWithPath: outputPrefix.path + ".u8")
    let manifestURL = URL(fileURLWithPath: outputPrefix.path + ".json")
    guard !FileManager.default.fileExists(atPath: rawURL.path),
          !FileManager.default.fileExists(atPath: manifestURL.path) else {
        throw NSError(domain: "TypesetRaster", code: 6,
                      userInfo: [NSLocalizedDescriptionKey: "出力成果物が既に存在します"])
    }
    let vocabularyData = try Data(contentsOf: vocabularyURL)
    let mapData = try Data(contentsOf: mapURL)
    let fontData = try Data(contentsOf: fontURL)
    let vocabulary = try JSONDecoder().decode(Vocabulary.self, from: vocabularyData)
    let glyphMap = try JSONDecoder().decode(GlyphMap.self, from: mapData)
    guard vocabulary.version == "symbol229-v1", vocabulary.labels.count == 229,
          Set(vocabulary.labels).count == 229,
          glyphMap.schema == "hinotori-typeset-glyph-map-v1",
          glyphMap.sourceVocabularyContract == vocabulary.version,
          glyphMap.entries.count == 229,
          Set(glyphMap.entries.map(\.label)) == Set(vocabulary.labels) else {
        throw NSError(domain: "TypesetRaster", code: 7,
                      userInfo: [NSLocalizedDescriptionKey: "229語彙と字形対応表の契約が一致しません"])
    }
    let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontURLAttribute: fontURL] as CFDictionary)
    let font = CTFontCreateWithFontDescriptor(descriptor, 1000, nil)
    let size = 64
    var bytes = Data()
    bytes.reserveCapacity(vocabulary.labels.count * size * size)
    for label in vocabulary.labels {
        guard let entry = glyphMap.entries.first(where: { $0.label == label }),
              entry.unicodeScalar.hasPrefix("U+"),
              let value = UInt32(entry.unicodeScalar.dropFirst(2), radix: 16),
              let scalar = Unicode.Scalar(value) else {
            throw NSError(domain: "TypesetRaster", code: 8,
                          userInfo: [NSLocalizedDescriptionKey: "\(label): Unicode字形対応が不正です"])
        }
        bytes.append(contentsOf: try render(scalar, label: label, font: font, size: size))
    }
    let manifest = RenderManifest(
        schema: "hinotori-typeset-glyph-raster-v1",
        vocabularySHA256: sha256(vocabularyData), glyphMapSHA256: sha256(mapData),
        fontSHA256: sha256(fontData), fontPostScriptName: CTFontCopyPostScriptName(font) as String,
        rasterSize: size, labels: vocabulary.labels, inputValues: "row-major UInt8: 0 background, 1 ink",
        renderingContract: "Render one mapped Unicode glyph outline from the named font; preserve aspect ratio, subtract its own outline bounding-box origin, scale longest extent to 56px, center in 64x64; binary fill, antialiasing off. No distance or ranking is computed.")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try bytes.write(to: rawURL, options: .atomic)
    try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    print("229活字字形を64x64画像にし、\(rawURL.path)へ保存しました。")
}

do {
    try run()
} catch {
    fputs("活字画像生成失敗: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
