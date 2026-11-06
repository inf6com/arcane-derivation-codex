import CoreText
import CryptoKit
import Foundation

private struct LabelManifest: Decodable {
    struct Entry: Decodable {
        let index: Int
        let label: String
        let kind: String
        let unicodeScalar: String?
        let renderInput: String
    }
    let schema: String
    let vocabularySHA256: String
    let entries: [Entry]
}

private struct CoverageCatalog: Decodable {
    struct Font: Decodable {
        let postScriptName: String
        let familyName: String
        let sourcePath: String
        let sourceSHA256: String
        let coveredUnicodeLabelCount: Int
    }
    struct Label: Decodable {
        let index: Int
        let label: String
        let kind: String
        let unicodeScalar: String?
        let supportingFontPostScriptNames: [String]
        let supportingFontCount: Int
    }
    let schema: String
    let labelManifestSHA256: String
    let macPostScriptFaceCount: Int
    let uniqueFontFileCount: Int
    let fonts: [Font]
    let labels: [Label]
}

private struct CorpusRow: Encodable {
    let imageIndex: Int
    let vocabularyIndex: Int
    let label: String
    let kind: String
    let unicodeScalar: String
    let postScriptName: String
    let familyName: String
    let fontFileSHA256: String
}

private struct OmittedLabel: Encodable {
    let vocabularyIndex: Int
    let label: String
    let kind: String
    let reason: String
}

private struct CorpusManifest: Encodable {
    let schema: String
    let vocabularySHA256: String
    let labelKindManifestSHA256: String
    let fontCoverageManifestSHA256: String
    let width: Int
    let height: Int
    let pixelEncoding: String
    let pixelLayout: String
    let normalization: String
    let fontFaceCount: Int
    let uniqueFontFileCount: Int
    let renderedImageCount: Int
    let renderedUnicodeLabelCount: Int
    let omittedLabels: [OmittedLabel]
    let rows: [CorpusRow]
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func parseScalar(_ value: String, label: String) throws -> Unicode.Scalar {
    guard value.hasPrefix("U+"), let number = UInt32(value.dropFirst(2), radix: 16),
          let scalar = Unicode.Scalar(number) else {
        throw NSError(domain: "MacGlyphCorpus", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(label): invalid Unicode scalar \(value)"])
    }
    return scalar
}

private func glyph(for scalar: Unicode.Scalar, label: String, font: CTFont) throws -> CGGlyph {
    let utf16 = Array(String(scalar).utf16)
    var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
    let converted = utf16.withUnsafeBufferPointer { characters in
        glyphs.withUnsafeMutableBufferPointer { glyphBuffer in
            CTFontGetGlyphsForCharacters(font, characters.baseAddress!, glyphBuffer.baseAddress!, characters.count)
        }
    }
    guard converted, let glyph = glyphs.first(where: { $0 != 0 }) else {
        throw NSError(domain: "MacGlyphCorpus", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(label): glyph disappeared from its catalogued font"])
    }
    return glyph
}

private func render(_ glyph: CGGlyph, label: String, font: CTFont, size: Int) throws -> [UInt8] {
    guard let path = CTFontCreatePathForGlyph(font, glyph, nil) else {
        throw NSError(domain: "MacGlyphCorpus", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(label): catalogued glyph has no outline"])
    }
    let bounds = path.boundingBoxOfPath
    guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
        throw NSError(domain: "MacGlyphCorpus", code: 4, userInfo: [NSLocalizedDescriptionKey: "\(label): glyph outline has empty bounds"])
    }
    let inset = 4.0
    let scale = min((Double(size) - 2 * inset) / bounds.width, (Double(size) - 2 * inset) / bounds.height)
    let tx = (Double(size) - bounds.width * scale) / 2 - bounds.minX * scale
    let ty = (Double(size) - bounds.height * scale) / 2 - bounds.minY * scale
    var pixels = [UInt8](repeating: 0, count: size * size)
    let colorSpace = CGColorSpaceCreateDeviceGray()
    let context = pixels.withUnsafeMutableBufferPointer { buffer in
        CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
                  bytesPerRow: size, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue)
    }
    guard let context else {
        throw NSError(domain: "MacGlyphCorpus", code: 5, userInfo: [NSLocalizedDescriptionKey: "Cannot create grayscale raster context"])
    }
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.setFillColor(gray: 1, alpha: 1)
    context.translateBy(x: tx, y: ty)
    context.scaleBy(x: scale, y: scale)
    context.addPath(path)
    context.fillPath()
    guard pixels.contains(where: { $0 > 0 }) else {
        throw NSError(domain: "MacGlyphCorpus", code: 6, userInfo: [NSLocalizedDescriptionKey: "\(label): rendered raster is empty"])
    }
    return pixels
}

private func run() throws {
    let args = CommandLine.arguments
    guard args.count == 7, args[1] == "--labels", args[3] == "--coverage", args[5] == "--output-prefix" else {
        throw NSError(domain: "MacGlyphCorpus", code: 7, userInfo: [NSLocalizedDescriptionKey: "Usage: RenderFirebirdMacFontGlyphCorpus --labels FILE --coverage FILE --output-prefix PREFIX"])
    }
    let labelURL = URL(fileURLWithPath: args[2])
    let coverageURL = URL(fileURLWithPath: args[4])
    let prefix = URL(fileURLWithPath: args[6])
    let rawURL = URL(fileURLWithPath: prefix.path + ".u8")
    let manifestURL = URL(fileURLWithPath: prefix.path + ".json")
    guard !FileManager.default.fileExists(atPath: rawURL.path), !FileManager.default.fileExists(atPath: manifestURL.path) else {
        throw NSError(domain: "MacGlyphCorpus", code: 8, userInfo: [NSLocalizedDescriptionKey: "One or more corpus output files already exist"])
    }
    let labelData = try Data(contentsOf: labelURL)
    let coverageData = try Data(contentsOf: coverageURL)
    let labelManifest = try JSONDecoder().decode(LabelManifest.self, from: labelData)
    let coverage = try JSONDecoder().decode(CoverageCatalog.self, from: coverageData)
    guard labelManifest.schema == "firebird-symbol-rendering-kind-manifest-v1", labelManifest.entries.count == 229,
          coverage.schema == "firebird-mac-font-glyph-coverage-v1", coverage.labels.count == 229,
          coverage.macPostScriptFaceCount == coverage.fonts.count,
          coverage.labelManifestSHA256 == sha256(labelData),
          Set(labelManifest.entries.map(\.label)) == Set(coverage.labels.map(\.label)) else {
        throw NSError(domain: "MacGlyphCorpus", code: 9, userInfo: [NSLocalizedDescriptionKey: "Label and Mac font coverage manifests do not match"])
    }
    let fonts = Dictionary(uniqueKeysWithValues: coverage.fonts.map { ($0.postScriptName, $0) })
    var allPixels = Data()
    var rows: [CorpusRow] = []
    let size = 64
    let unicodeEntries = labelManifest.entries.filter { $0.kind != "math-structure" }
    let expectedImages = coverage.labels.filter { $0.kind != "math-structure" }.reduce(0) { $0 + $1.supportingFontCount }
    allPixels.reserveCapacity(expectedImages * size * size)
    rows.reserveCapacity(expectedImages)

    for entry in unicodeEntries {
        guard let map = coverage.labels.first(where: { $0.label == entry.label }), map.kind == entry.kind,
              map.supportingFontCount == map.supportingFontPostScriptNames.count,
              !map.supportingFontPostScriptNames.isEmpty else {
            throw NSError(domain: "MacGlyphCorpus", code: 10, userInfo: [NSLocalizedDescriptionKey: "\(entry.label): no verified Mac font source"])
        }
        let scalar = try parseScalar(entry.unicodeScalar!, label: entry.label)
        for postScriptName in map.supportingFontPostScriptNames.sorted() {
            guard let fontRecord = fonts[postScriptName] else {
                throw NSError(domain: "MacGlyphCorpus", code: 11, userInfo: [NSLocalizedDescriptionKey: "\(entry.label): catalogued font \(postScriptName) is missing"])
            }
            let font = CTFontCreateWithName(postScriptName as CFString, 1000, nil)
            guard CTFontCopyPostScriptName(font) as String == postScriptName,
                  let glyphURL = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL,
                  glyphURL.standardizedFileURL.path == fontRecord.sourcePath else {
                throw NSError(domain: "MacGlyphCorpus", code: 12, userInfo: [NSLocalizedDescriptionKey: "\(postScriptName): font identity or source file changed after catalog"])
            }
            let glyph = try glyph(for: scalar, label: entry.label, font: font)
            let pixels = try render(glyph, label: entry.label, font: font, size: size)
            allPixels.append(contentsOf: pixels)
            rows.append(CorpusRow(imageIndex: rows.count, vocabularyIndex: entry.index, label: entry.label,
                                  kind: entry.kind, unicodeScalar: entry.unicodeScalar!, postScriptName: postScriptName,
                                  familyName: fontRecord.familyName, fontFileSHA256: fontRecord.sourceSHA256))
        }
    }
    guard rows.count == expectedImages, allPixels.count == expectedImages * size * size else {
        throw NSError(domain: "MacGlyphCorpus", code: 13, userInfo: [NSLocalizedDescriptionKey: "Rendered image count does not match the measured coverage matrix"])
    }
    let omitted = labelManifest.entries.filter { $0.kind == "math-structure" }.map {
        OmittedLabel(vocabularyIndex: $0.index, label: $0.label, kind: $0.kind,
                     reason: "No standalone Unicode glyph; retained as a formula-structure singleton, not coerced into glyph classification")
    }
    let result = CorpusManifest(schema: "firebird-mac-font-glyph-raster-v1", vocabularySHA256: labelManifest.vocabularySHA256,
                                labelKindManifestSHA256: sha256(labelData), fontCoverageManifestSHA256: sha256(coverageData),
                                width: size, height: size, pixelEncoding: "UInt8 grayscale", pixelLayout: "row-major; one image per manifest row",
                                normalization: "CoreText glyph outline bounding box; aspect preserved; centered in 64x64 with 4px inset; antialiased; white ink on zero background",
                                fontFaceCount: coverage.macPostScriptFaceCount, uniqueFontFileCount: coverage.uniqueFontFileCount,
                                renderedImageCount: rows.count, renderedUnicodeLabelCount: unicodeEntries.count, omittedLabels: omitted, rows: rows)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let manifestBytes = try encoder.encode(result)
    try FileManager.default.createDirectory(at: prefix.deletingLastPathComponent(), withIntermediateDirectories: true)
    let rawTemporary = URL(fileURLWithPath: rawURL.path + ".partial")
    let manifestTemporary = URL(fileURLWithPath: manifestURL.path + ".partial")
    do {
        try allPixels.write(to: rawTemporary, options: .atomic)
        try manifestBytes.write(to: manifestTemporary, options: .atomic)
        try FileManager.default.moveItem(at: rawTemporary, to: rawURL)
        try FileManager.default.moveItem(at: manifestTemporary, to: manifestURL)
    } catch {
        try? FileManager.default.removeItem(at: rawTemporary)
        try? FileManager.default.removeItem(at: manifestTemporary)
        throw error
    }
    print("活字画像 \(rows.count) 枚 / \(unicodeEntries.count) Unicodeラベル / \(coverage.macPostScriptFaceCount) フォント面を出力しました。\n構造単独項目 \(omitted.count) 件は、字形へ偽装せず独立保持しました。\n画像: \(rawURL.path)\n台帳: \(manifestURL.path)")
}

do {
    try run()
} catch {
    fputs("Mac活字画像コーパス生成失敗: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
