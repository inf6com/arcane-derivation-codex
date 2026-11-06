import CoreText
import CryptoKit
import Foundation

private struct LabelManifest: Decodable {
    struct Entry: Decodable {
        let index: Int
        let label: String
        let kind: String
        let unicodeScalar: String?
    }
    let schema: String
    let entries: [Entry]
}

private struct FontRecord: Encodable {
    let postScriptName: String
    let familyName: String
    let sourcePath: String
    let sourceSHA256: String
    let coveredUnicodeLabelCount: Int
}

private struct LabelCoverage: Encodable {
    let index: Int
    let label: String
    let kind: String
    let unicodeScalar: String?
    let supportingFontPostScriptNames: [String]
    let supportingFontCount: Int
}

private struct Catalog: Encodable {
    let schema: String
    let labelManifestSHA256: String
    let macPostScriptFaceCount: Int
    let uniqueFontFileCount: Int
    let fonts: [FontRecord]
    let labels: [LabelCoverage]
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func parseScalar(_ value: String, label: String) throws -> Unicode.Scalar {
    guard value.hasPrefix("U+"), let number = UInt32(value.dropFirst(2), radix: 16),
          let scalar = Unicode.Scalar(number) else {
        throw NSError(domain: "MacFontCatalog", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(label): invalid Unicode scalar \(value)"])
    }
    return scalar
}

private func fontHasGlyph(_ font: CTFont, scalar: Unicode.Scalar) -> Bool {
    let utf16 = Array(String(scalar).utf16)
    var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
    let converted = utf16.withUnsafeBufferPointer { characters in
        glyphs.withUnsafeMutableBufferPointer { glyphBuffer in
            CTFontGetGlyphsForCharacters(font, characters.baseAddress!, glyphBuffer.baseAddress!, characters.count)
        }
    }
    guard converted, let glyph = glyphs.first(where: { $0 != 0 }) else { return false }
    var glyphValue = glyph
    var bounds = CGRect.zero
    CTFontGetBoundingRectsForGlyphs(font, .default, &glyphValue, &bounds, 1)
    guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
          let path = CTFontCreatePathForGlyph(font, glyph, nil) else { return false }
    let outline = path.boundingBoxOfPath
    return outline.width.isFinite && outline.height.isFinite && outline.width > 0 && outline.height > 0
}

private func run() throws {
    let args = CommandLine.arguments
    guard args.count == 5, args[1] == "--manifest", args[3] == "--output" else {
        throw NSError(domain: "MacFontCatalog", code: 2, userInfo: [NSLocalizedDescriptionKey: "Usage: CatalogMacFontGlyphCoverage --manifest FILE --output FILE"])
    }
    let manifestURL = URL(fileURLWithPath: args[2])
    let outputURL = URL(fileURLWithPath: args[4])
    guard !FileManager.default.fileExists(atPath: outputURL.path) else {
        throw NSError(domain: "MacFontCatalog", code: 3, userInfo: [NSLocalizedDescriptionKey: "Output already exists: \(outputURL.path)"])
    }
    let manifestData = try Data(contentsOf: manifestURL)
    let manifest = try JSONDecoder().decode(LabelManifest.self, from: manifestData)
    guard manifest.schema == "firebird-symbol-rendering-kind-manifest-v1",
          manifest.entries.count == 229,
          Set(manifest.entries.map(\.label)).count == 229,
          manifest.entries.allSatisfy({ $0.kind == "math-structure" || $0.unicodeScalar != nil }) else {
        throw NSError(domain: "MacFontCatalog", code: 4, userInfo: [NSLocalizedDescriptionKey: "Input manifest is not a complete 229-label rendering-kind contract"])
    }

    let names = (CTFontManagerCopyAvailablePostScriptNames() as! [String]).sorted()
    guard !names.isEmpty, Set(names).count == names.count else {
        throw NSError(domain: "MacFontCatalog", code: 5, userInfo: [NSLocalizedDescriptionKey: "CoreText returned an empty or duplicate PostScript font inventory"])
    }
    var records: [FontRecord] = []
    var supporters: [String: [String]] = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.label, []) })
    var fileHashes: [String: String] = [:]
    var fontByName: [(String, CTFont)] = []
    for name in names {
        let font = CTFontCreateWithName(name as CFString, 64, nil)
        guard CTFontCopyPostScriptName(font) as String == name,
              let rawURL = CTFontCopyAttribute(font, kCTFontURLAttribute),
              let sourceURL = rawURL as? URL else {
            throw NSError(domain: "MacFontCatalog", code: 6, userInfo: [NSLocalizedDescriptionKey: "Cannot resolve exact installed font file for \(name)"])
        }
        let sourcePath = sourceURL.standardizedFileURL.path
        let sourceHash: String
        if let cached = fileHashes[sourcePath] {
            sourceHash = cached
        } else {
            let data = try Data(contentsOf: sourceURL)
            sourceHash = sha256(data)
            fileHashes[sourcePath] = sourceHash
        }
        fontByName.append((name, font))
        let family = CTFontCopyFamilyName(font) as String
        records.append(FontRecord(postScriptName: name, familyName: family, sourcePath: sourcePath,
                                  sourceSHA256: sourceHash, coveredUnicodeLabelCount: 0))
    }

    var finalRecords: [FontRecord] = []
    for (index, pair) in fontByName.enumerated() {
        let (name, font) = pair
        var covered = 0
        for entry in manifest.entries where entry.kind != "math-structure" {
            let scalar = try parseScalar(entry.unicodeScalar!, label: entry.label)
            if fontHasGlyph(font, scalar: scalar) {
                supporters[entry.label, default: []].append(name)
                covered += 1
            }
        }
        let prior = records[index]
        finalRecords.append(FontRecord(postScriptName: prior.postScriptName, familyName: prior.familyName,
                                       sourcePath: prior.sourcePath, sourceSHA256: prior.sourceSHA256,
                                       coveredUnicodeLabelCount: covered))
    }

    let labelCoverage = manifest.entries.map { entry in
        let fonts = supporters[entry.label, default: []]
        return LabelCoverage(index: entry.index, label: entry.label, kind: entry.kind,
                             unicodeScalar: entry.unicodeScalar,
                             supportingFontPostScriptNames: fonts,
                             supportingFontCount: fonts.count)
    }
    let catalog = Catalog(schema: "firebird-mac-font-glyph-coverage-v1",
                          labelManifestSHA256: sha256(manifestData), macPostScriptFaceCount: names.count,
                          uniqueFontFileCount: fileHashes.count, fonts: finalRecords, labels: labelCoverage)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let result = try encoder.encode(catalog)
    try result.write(to: outputURL, options: .atomic)
    let uncovered = labelCoverage.filter { $0.kind != "math-structure" && $0.supportingFontCount == 0 }
    print("Mac font faces: \(names.count); unique font files: \(fileHashes.count); Unicode labels: \(manifest.entries.filter { $0.kind != "math-structure" }.count); labels with no local glyph: \(uncovered.count)")
    if !uncovered.isEmpty {
        for entry in uncovered { print("No local glyph: \(entry.index) \(entry.label) \(entry.unicodeScalar ?? "")") }
    }
    print("Saved font paths and glyph coverage to \(outputURL.path)")
}

do {
    try run()
} catch {
    fputs("Mac font inventory failed: \(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
