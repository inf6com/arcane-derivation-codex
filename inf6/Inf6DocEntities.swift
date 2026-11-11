//
//  Inf6DocEntities.swift
//  inf6
//
//  Created by decopin on 2025/12/27.
//

import Foundation
import SwiftUI

#if canImport(PDFKit)
import PDFKit

#endif
#if canImport(Vision) && canImport(UIKit)
import Vision
import UIKit
#endif


// MARK: - Knowledge cards path policy (shared)

/// Shared, single-source policy for where per-PDF knowledge sidecars live.
/// Keep folder names and PDF key rules centralized so multiple views do not drift.
public enum Inf6KnowledgeCardsPaths {

    /// Storage root folder name under the selected storage root.
    /// e.g. <storage-root> / inf6_knowledge_cards / <pdfKey>/...
    public static let rootFolderName: String = "inf6_knowledge_cards"

    /// 知識カードの置き場。生成も閲覧もここ1箇所を使う。
    ///
    /// 生成は Documents 直下へ書くのに、閲覧は共有ルート配下を見ていた。
    /// 実際には210件あるのに4件しか出てこない状態だった。
    public static func rootDirectoryURL() -> URL? {
        Inf6DataRoot.url().appendingPathComponent(rootFolderName, isDirectory: true)
    }

    /// Stable per-PDF key used for folder names and sidecar file name prefixes.
    /// Policy: use the on-disk filename (without extension) with whitespace trimmed.
    /// Returns nil if the URL does not yield a valid non-empty filename.
    public static func pdfKey(from pdfURL: URL) -> String? {
        let key = pdfURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    /// Stable ASCII folder key used by InlinePDFPagesView for per-PDF sidecars.
    /// Allowed output charset: [a-z0-9_].
    public static func normalizedPaperFolderKey(from raw: String) -> String {
        let s0 = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s0.isEmpty { return "" }

        var s = s0
        if s.lowercased().hasSuffix(".pdf") {
            s = String(s.dropLast(4))
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }

        var out = ""
        out.reserveCapacity(s.count)
        var previousWasUnderscore = false

        for ch in s {
            let scalars = ch.unicodeScalars
            let scalar = scalars.first
            let isSingleScalar = scalar != nil && scalars.count == 1
            let value = scalar?.value ?? 0

            let isDigit = isSingleScalar && value >= 0x30 && value <= 0x39
            let isUpper = isSingleScalar && value >= 0x41 && value <= 0x5A
            let isLower = isSingleScalar && value >= 0x61 && value <= 0x7A

            if isDigit || isLower {
                out.append(ch)
                previousWasUnderscore = false
            } else if isUpper, let lower = UnicodeScalar(value + 0x20) {
                out.append(Character(lower))
                previousWasUnderscore = false
            } else if !previousWasUnderscore {
                out.append("_")
                previousWasUnderscore = true
            }
        }

        return out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    public static func normalizedPaperFolderKey(from pdfURL: URL) -> String {
        normalizedPaperFolderKey(from: pdfURL.lastPathComponent)
    }
}

#if canImport(UIKit)
import UIKit
#endif



// MARK: - Doc-generation kinds (used by Inf6LibraryView)

/// Document-generation requests for OpenAI-backed content creation.
/// Kept in this shared entities file so large views can split safely without losing the enum.
public enum Inf6DocGenerationKind: Hashable {
    case paperAbstract
    case pageExplain
    case selectionAddendum(pageIndex: Int, selectedText: String, userPrompt: String)
}

struct Inf6AssetsPipelineStatus: Codable {
    var lastAttemptAt: TimeInterval
    var lastAttemptSucceeded: Bool
    var lastSuccessAt: TimeInterval?
    var state: Inf6AssetsPipelineRunState?

    init(
        lastAttemptAt: TimeInterval,
        lastAttemptSucceeded: Bool,
        lastSuccessAt: TimeInterval?,
        state: Inf6AssetsPipelineRunState?
    ) {
        self.lastAttemptAt = lastAttemptAt
        self.lastAttemptSucceeded = lastAttemptSucceeded
        self.lastSuccessAt = lastSuccessAt
        self.state = state
    }

    var resolvedState: Inf6AssetsPipelineRunState {
        if let state { return state }
        return lastAttemptSucceeded ? .finished : .failed
    }
}

// MARK: - Entity model (Figure / Table / Equation)

public enum Inf6DocEntityKind: String, Codable, Hashable {
    case figure
    case table
    case equation

    public var labelJa: String {
        switch self {
        case .figure: return "図"
        case .table: return "表"
        case .equation: return "式"
        }
    }

    public var labelEn: String {
        switch self {
        case .figure: return "Figure"
        case .table: return "Table"
        case .equation: return "Equation"
        }
    }

    public var systemImage: String {
        switch self {
        case .figure: return "photo.on.rectangle"
        case .table: return "tablecells"
        case .equation: return "function"
        }
    }
}

public enum Inf6DocEntityReferenceKind: String, Codable, Hashable {
    case caption
    case mention
}

public struct Inf6DocEntityReference: Codable, Hashable, Identifiable {
    public var id: UUID
    public var kind: Inf6DocEntityReferenceKind
    public var pageIndex: Int
    public var text: String
    public var surroundingText: String
    public var utf16Location: Int
    public var utf16Length: Int
}

public struct Inf6DocEntityPart: Codable, Hashable, Identifiable {
    public var id: UUID
    /// 再解析しても同じ画像上の意味単位を指す識別子。
    public var stableID: String
    public var text: String
    public var normalizedRect: CGRect
    public var pageIndex: Int
    public var paperText: String
    public var paperTextJapanese: String
    /// クロップ画像からローカル数式認識で取得し、検証済みのMathMLだけを保持する。
    public var paperFormulaMathML: String?
    public var paperFormulaExpression: String?
    public var paperTextUTF16Location: Int?
    public var paperTextUTF16Length: Int?
    public var paperTextSourceSegmentIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case id, stableID, text, normalizedRect, pageIndex, paperText, paperTextJapanese, paperFormulaMathML, paperFormulaExpression, paperTextUTF16Location, paperTextUTF16Length, paperTextSourceSegmentIDs
    }

    public init(id: UUID = UUID(), stableID: String = "", text: String, normalizedRect: CGRect, pageIndex: Int, paperText: String, paperTextUTF16Location: Int? = nil, paperTextUTF16Length: Int? = nil, paperTextSourceSegmentIDs: [String] = [], paperTextJapanese: String = "", paperFormulaMathML: String? = nil, paperFormulaExpression: String? = nil) {
        self.id = id
        self.stableID = stableID
        self.text = text
        self.normalizedRect = normalizedRect
        self.pageIndex = pageIndex
        self.paperText = paperText
        self.paperTextJapanese = paperTextJapanese
        self.paperFormulaMathML = paperFormulaMathML
        self.paperFormulaExpression = paperFormulaExpression
        self.paperTextUTF16Location = paperTextUTF16Location
        self.paperTextUTF16Length = paperTextUTF16Length
        self.paperTextSourceSegmentIDs = paperTextSourceSegmentIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        stableID = try container.decodeIfPresent(String.self, forKey: .stableID) ?? ""
        text = try container.decode(String.self, forKey: .text)
        normalizedRect = try container.decode(CGRect.self, forKey: .normalizedRect)
        pageIndex = try container.decode(Int.self, forKey: .pageIndex)
        paperText = try container.decode(String.self, forKey: .paperText)
        paperTextJapanese = try container.decodeIfPresent(String.self, forKey: .paperTextJapanese) ?? ""
        paperFormulaMathML = try container.decodeIfPresent(String.self, forKey: .paperFormulaMathML)
        paperFormulaExpression = try container.decodeIfPresent(String.self, forKey: .paperFormulaExpression)
        paperTextUTF16Location = try container.decodeIfPresent(Int.self, forKey: .paperTextUTF16Location)
        paperTextUTF16Length = try container.decodeIfPresent(Int.self, forKey: .paperTextUTF16Length)
        paperTextSourceSegmentIDs = try container.decodeIfPresent([String].self, forKey: .paperTextSourceSegmentIDs) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(stableID, forKey: .stableID)
        try container.encode(text, forKey: .text)
        try container.encode(normalizedRect, forKey: .normalizedRect)
        try container.encode(pageIndex, forKey: .pageIndex)
        try container.encode(paperText, forKey: .paperText)
        try container.encode(paperTextJapanese, forKey: .paperTextJapanese)
        try container.encodeIfPresent(paperFormulaMathML, forKey: .paperFormulaMathML)
        try container.encodeIfPresent(paperFormulaExpression, forKey: .paperFormulaExpression)
        try container.encodeIfPresent(paperTextUTF16Location, forKey: .paperTextUTF16Location)
        try container.encodeIfPresent(paperTextUTF16Length, forKey: .paperTextUTF16Length)
        try container.encode(paperTextSourceSegmentIDs, forKey: .paperTextSourceSegmentIDs)
    }
}

public struct Inf6PaperTextPage: Codable, Hashable, Identifiable {
    public var id: Int { pageIndex }
    public let pageIndex: Int
    public let text: String

    public init(pageIndex: Int, text: String) {
        self.pageIndex = pageIndex
        self.text = text
    }
}

public struct Inf6PaperTextIndex: Codable, Hashable {
    public let pdfKey: String
    public let pages: [Inf6PaperTextPage]

    public init(pdfKey: String, pages: [Inf6PaperTextPage]) {
        self.pdfKey = pdfKey
        self.pages = pages
    }
}

public struct Inf6DocEntity: Codable, Hashable, Identifiable {
    public var id: UUID
    public var kind: Inf6DocEntityKind
    public var pageIndex: Int
    public var title: String       // e.g., "Fig. 2", "Table 1", "Eq. (3)" or fallback
    public var titleJapanese: String
    public var snippet: String     // evidence text
    public var snippetJapanese: String
    public var explanation: String? // GPT result (MathJax-ready text)
    public var explanationJapanese: String?
    public var miniPDFFileName: String? // stored file name under details dir
    public var imagePath: String?       // relative path under entity_images/
    public var references: [Inf6DocEntityReference]?
    public var updatedAt: TimeInterval
    public var isCore: Bool
    /// LLMが論文内での中核性を0〜100で評価した値。未評価の既存エンティティはnil。
    public var coreImportanceScore: Int?
    public var parts: [Inf6DocEntityPart]
    /// エンティティ全体のクロップ画像を表す、検証済みのMathML。
    public var paperFormulaMathML: String?
    public var paperFormulaExpression: String?
    public var nodeDiagramSteps: [String]?
    public var nodeTableColumns: [String]?
    public var nodeTableRows: [[String]]?
    public var llmPyTorchCode: String?
    public var llmTensorFlowCode: String?
    public var llmCodeVerification: String?

    public init(
        id: UUID = UUID(),
        kind: Inf6DocEntityKind,
        pageIndex: Int,
        title: String,
        titleJapanese: String = "",
        snippet: String,
        snippetJapanese: String = "",
        explanation: String? = nil,
        explanationJapanese: String? = nil,
        miniPDFFileName: String? = nil,
        imagePath: String? = nil,
        references: [Inf6DocEntityReference]? = [],
        updatedAt: TimeInterval = Date().timeIntervalSince1970,
        isCore: Bool = false,
        coreImportanceScore: Int? = nil,
        parts: [Inf6DocEntityPart] = [],
        paperFormulaMathML: String? = nil,
        paperFormulaExpression: String? = nil,
        nodeDiagramSteps: [String]? = nil,
        nodeTableColumns: [String]? = nil,
        nodeTableRows: [[String]]? = nil,
        llmPyTorchCode: String? = nil,
        llmTensorFlowCode: String? = nil,
        llmCodeVerification: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.pageIndex = pageIndex
        self.title = title
        self.titleJapanese = titleJapanese
        self.snippet = snippet
        self.snippetJapanese = snippetJapanese
        self.explanation = explanation
        self.explanationJapanese = explanationJapanese
        self.miniPDFFileName = miniPDFFileName
        self.imagePath = imagePath
        self.references = references
        self.updatedAt = updatedAt
        self.isCore = isCore
        self.coreImportanceScore = coreImportanceScore
        self.parts = parts
        self.paperFormulaMathML = paperFormulaMathML
        self.paperFormulaExpression = paperFormulaExpression
        self.nodeDiagramSteps = nodeDiagramSteps
        self.nodeTableColumns = nodeTableColumns
        self.nodeTableRows = nodeTableRows
        self.llmPyTorchCode = llmPyTorchCode
        self.llmTensorFlowCode = llmTensorFlowCode
        self.llmCodeVerification = llmCodeVerification
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, pageIndex, title, titleJapanese, snippet, snippetJapanese, explanation, explanationJapanese, miniPDFFileName, imagePath, references, updatedAt, isCore, coreImportanceScore, parts, paperFormulaMathML, paperFormulaExpression, nodeDiagramSteps, nodeTableColumns, nodeTableRows, llmPyTorchCode, llmTensorFlowCode, llmCodeVerification
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Inf6DocEntityKind.self, forKey: .kind)
        pageIndex = try c.decode(Int.self, forKey: .pageIndex)
        title = try c.decode(String.self, forKey: .title)
        titleJapanese = try c.decodeIfPresent(String.self, forKey: .titleJapanese) ?? ""
        snippet = try c.decode(String.self, forKey: .snippet)
        snippetJapanese = try c.decodeIfPresent(String.self, forKey: .snippetJapanese) ?? ""
        explanation = try c.decodeIfPresent(String.self, forKey: .explanation)
        explanationJapanese = try c.decodeIfPresent(String.self, forKey: .explanationJapanese)
        miniPDFFileName = try c.decodeIfPresent(String.self, forKey: .miniPDFFileName)
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath)
        references = try c.decodeIfPresent([Inf6DocEntityReference].self, forKey: .references)
        updatedAt = try c.decodeIfPresent(TimeInterval.self, forKey: .updatedAt) ?? 0
        isCore = try c.decodeIfPresent(Bool.self, forKey: .isCore) ?? false
        coreImportanceScore = try c.decodeIfPresent(Int.self, forKey: .coreImportanceScore)
        parts = try c.decodeIfPresent([Inf6DocEntityPart].self, forKey: .parts) ?? []
        paperFormulaMathML = try c.decodeIfPresent(String.self, forKey: .paperFormulaMathML)
        paperFormulaExpression = try c.decodeIfPresent(String.self, forKey: .paperFormulaExpression)
        nodeDiagramSteps = try c.decodeIfPresent([String].self, forKey: .nodeDiagramSteps)
        nodeTableColumns = try c.decodeIfPresent([String].self, forKey: .nodeTableColumns)
        nodeTableRows = try c.decodeIfPresent([[String]].self, forKey: .nodeTableRows)
        llmPyTorchCode = try c.decodeIfPresent(String.self, forKey: .llmPyTorchCode)
        llmTensorFlowCode = try c.decodeIfPresent(String.self, forKey: .llmTensorFlowCode)
        llmCodeVerification = try c.decodeIfPresent(String.self, forKey: .llmCodeVerification)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(pageIndex, forKey: .pageIndex)
        try c.encode(title, forKey: .title)
        try c.encode(titleJapanese, forKey: .titleJapanese)
        try c.encode(snippet, forKey: .snippet)
        try c.encode(snippetJapanese, forKey: .snippetJapanese)
        try c.encodeIfPresent(explanation, forKey: .explanation)
        try c.encodeIfPresent(explanationJapanese, forKey: .explanationJapanese)
        try c.encodeIfPresent(miniPDFFileName, forKey: .miniPDFFileName)
        try c.encodeIfPresent(imagePath, forKey: .imagePath)
        try c.encodeIfPresent(references, forKey: .references)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(isCore, forKey: .isCore)
        try c.encodeIfPresent(coreImportanceScore, forKey: .coreImportanceScore)
        try c.encode(parts, forKey: .parts)
        try c.encodeIfPresent(paperFormulaMathML, forKey: .paperFormulaMathML)
        try c.encodeIfPresent(paperFormulaExpression, forKey: .paperFormulaExpression)
        try c.encodeIfPresent(nodeDiagramSteps, forKey: .nodeDiagramSteps)
        try c.encodeIfPresent(nodeTableColumns, forKey: .nodeTableColumns)
        try c.encodeIfPresent(nodeTableRows, forKey: .nodeTableRows)
        try c.encodeIfPresent(llmPyTorchCode, forKey: .llmPyTorchCode)
        try c.encodeIfPresent(llmTensorFlowCode, forKey: .llmTensorFlowCode)
        try c.encodeIfPresent(llmCodeVerification, forKey: .llmCodeVerification)
    }
}

public struct Inf6DocEntityIndex: Codable {
    public static let currentVersion = 9

    public var version: Int
    public var pdfKey: String
    public var entities: [Inf6DocEntity]

    public init(version: Int = Inf6DocEntityIndex.currentVersion, pdfKey: String, entities: [Inf6DocEntity]) {
        self.version = version
        self.pdfKey = pdfKey
        self.entities = entities
    }

    /// Resolve the persisted item index by the stable paper identity and its
    /// known display/PDF names. The metadata key is not guaranteed to equal
    /// the syllabus link's paper ID or the current display title.
    static func load(for paper: Inf6CorePaper) -> Inf6DocEntityIndex? {
        let preferredKeys = [
            paper.titleEn ?? paper.title,
            paper.title,
            paper.id,
            paper.resolvedPDFURL?.lastPathComponent ?? ""
        ].map { Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: $0) }
            .filter { !$0.isEmpty }
        let aliases = Set(preferredKeys)
        guard !aliases.isEmpty else { return nil }

        for key in preferredKeys {
            if let exact = Inf6MetadataStore.getCodable(Inf6DocEntityIndex.self, domain: .docEntities, key: key) {
                return exact
            }
        }
        let records = Inf6MetadataStore.listAllCodable(Inf6DocEntityIndex.self, domain: .docEntities)
        if let exact = records.first(where: { record in
            let keys = [record.key, record.value.pdfKey].map {
                Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: $0)
            }
            return keys.contains { aliases.contains($0) }
        }) {
            return exact.value
        }

        if let related = records.first(where: { record in
            let keys = [record.key, record.value.pdfKey].map {
                Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: $0)
            }
            return keys.contains { stored in
                aliases.contains { alias in
                    stored.hasSuffix("_\(alias)") || alias.hasSuffix("_\(stored)")
                }
            }
        }) {
            return related.value
        }

        guard let root = Inf6KnowledgeCardsPaths.rootDirectoryURL(),
              let folders = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey]
              ) else { return nil }
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
                continue
            }
            for file in files where file.lastPathComponent.hasSuffix(".entities.json") {
                guard let data = try? Data(contentsOf: file),
                      let index = try? JSONDecoder().decode(Inf6DocEntityIndex.self, from: data) else { continue }
                let keys = [folder.lastPathComponent, file.deletingPathExtension().deletingPathExtension().lastPathComponent, index.pdfKey]
                    .map { Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: $0) }
                if keys.contains(where: { stored in
                    aliases.contains { alias in
                        stored == alias || stored.hasSuffix("_\(alias)") || alias.hasSuffix("_\(stored)")
                    }
                }) {
                    return index
                }
            }
        }
        return nil
    }
}

// MARK: - Persistence (JSON sidecar + mini PDF files)

public enum Inf6DocEntityPersistence {

    public static func jsonFileURL(detailsDir: URL, pdfKey: String) -> URL {
        // policy: one JSON file per PDF
        // e.g. "paper.entities.json"
        let name = "\(pdfKey).entities.json"
        return detailsDir.appendingPathComponent(name)
    }

    public static func load(detailsDir: URL, pdfKey: String) -> Inf6DocEntityIndex? {
        // metadata file store first
        if let cached = Inf6MetadataStore.getCodable(Inf6DocEntityIndex.self, domain: .docEntities, key: pdfKey) {
            return cached
        }
        // JSON fallback
        let url = jsonFileURL(detailsDir: detailsDir, pdfKey: pdfKey)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let index = try JSONDecoder().decode(Inf6DocEntityIndex.self, from: data)
            // Migrate to metadata file store
            Inf6MetadataStore.putCodable(index, domain: .docEntities, key: pdfKey)
            return index
        } catch {
            return nil
        }
    }

    public static func save(_ index: Inf6DocEntityIndex, detailsDir: URL) {
        Inf6MetadataStore.putCodable(index, domain: .docEntities, key: index.pdfKey)
        // Also write JSON for backward compat
        let url = jsonFileURL(detailsDir: detailsDir, pdfKey: index.pdfKey)
        do {
            let data = try JSONEncoder().encode(index)
            try data.write(to: url, options: [.atomic])
        } catch {
            // best-effort
        }
    }

    public static func entityMiniPDFFileURL(detailsDir: URL, pdfKey: String, entityID: UUID) -> URL {
        // e.g. "paper.entity.<uuid>.pdf"
        let name = "\(pdfKey).entity.\(entityID.uuidString).pdf"
        return detailsDir.appendingPathComponent(name)
    }
}

// MARK: - Lightweight pre-scan (fast / local)

public enum Inf6DocEntityScanner {

#if canImport(PDFKit)
    public static func scan(doc: PDFDocument) -> [Inf6DocEntity] {
        var out: [Inf6DocEntity] = []
        let pageCount = doc.pageCount
        guard pageCount > 0 else { return out }
        var referencePageTexts = Array(repeating: "", count: pageCount)

        let eqRe  = try? NSRegularExpression(pattern: #"(?i)\b(eq(?:\.|uation)?)\s*(\(\s*\d+\s*\)|\d+)\b"#)

        for p in 0..<pageCount {
            guard let page = doc.page(at: p) else { continue }
            let raw = (page.string ?? "")
                .replacingOccurrences(of: "\u{00A0}", with: " ")
            var text = raw.replacingOccurrences(of: "\t", with: " ")
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

            #if canImport(Vision) && canImport(UIKit)
            let needsOCR = text.isEmpty || (
                text.count < 100 &&
                !text.localizedCaseInsensitiveContains("Figure ") &&
                !text.localizedCaseInsensitiveContains("Table ")
            )
            if needsOCR {
                let recognizedText = _recognizedPageText(page, pageIndex: p)
                if !recognizedText.isEmpty { text = recognizedText }
            }
            #endif
            referencePageTexts[p] = text

            let pageAssets = Inf6AssetsAbstractPipeline.detectItemsForPage(
                pageIndex: p,
                pageText: text
            ).filter { asset in
                let pattern = #"(?i)^\s*(figure|fig\.?|table|tab\.?)\s*[a-z]?\d+\s*[:：.]"#
                guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
                let title = asset.titleLine as NSString
                return regex.firstMatch(in: asset.titleLine, range: NSRange(location: 0, length: title.length)) != nil
            }
            var detectedAssets = pageAssets
            #if canImport(Vision) && canImport(UIKit)
            if detectedAssets.isEmpty && !needsOCR &&
                (text.localizedCaseInsensitiveContains("Figure ") ||
                 text.localizedCaseInsensitiveContains("Table ")) {
                let recognizedText = _recognizedPageText(page, pageIndex: p)
                if !recognizedText.isEmpty { referencePageTexts[p] = recognizedText }
                detectedAssets = Inf6AssetsAbstractPipeline.detectItemsForPage(
                    pageIndex: p,
                    pageText: recognizedText
                )
            }
            #endif
            for asset in detectedAssets {
                let kind: Inf6DocEntityKind
                switch asset.kind {
                case .figure:
                    kind = .figure
                case .table:
                    kind = .table
                case .equation:
                    continue
                }
                out.append(
                    Inf6DocEntity(
                        kind: kind,
                        pageIndex: p,
                        title: asset.titleLine,
                        snippet: String(asset.evidence.prefix(1400))
                    )
                )
            }
            let ns = text as NSString
            var seenEquationNumbers = Set<String>()

            // 経路A: 本文が "Equation 3" / "Eq. 3" のように語で参照している場合。
            if let eqRe {
                let matches = eqRe.matches(in: text, range: NSRange(location: 0, length: ns.length))
                for m in matches {
                    guard _containsEquationEvidence(in: text, match: m.range) else { continue }
                    let titleRaw = ns.substring(with: m.range)
                    guard let number = _equationNumber(in: titleRaw) else { continue }
                    if seenEquationNumbers.contains(number) { continue }
                    seenEquationNumbers.insert(number)

                    let range = m.range
                    let title = titleRaw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    if title.isEmpty { continue }

                    // snippet = around the matched area (fast and robust)
                    let radius = 260
                    let start = max(0, range.location - radius)
                    let end = min(ns.length, range.location + range.length + radius)
                    let snippet = ns.substring(with: NSRange(location: start, length: end - start))
                        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

                    out.append(
                        Inf6DocEntity(
                            kind: .equation,
                            pageIndex: p,
                            title: title,
                            snippet: String(snippet.prefix(1400))
                        )
                    )
                }
            }

            // 経路B: 別組みの数式に行末で "(1)" と採番するだけの、論文で最も一般的な形式。
            // 本文に "Equation 1" とは書かれないため経路Aでは1件も拾えず、
            // Scaled Dot-Product Attention の定義式のような中核数式を取りこぼしていた。
            let lines = text.components(separatedBy: .newlines)
            for (lineIndex, rawLine) in lines.enumerated() {
                let line = rawLine.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                guard !line.isEmpty,
                      let number = _trailingEquationNumber(in: line),
                      !seenEquationNumbers.contains(number),
                      _containsMathOperator(line)
                else { continue }
                seenEquationNumbers.insert(number)

                // 数式単体では変数の意味が読めないため、前後の行を根拠として添える。
                let contextStart = max(0, lineIndex - 2)
                let contextEnd = min(lines.count - 1, lineIndex + 2)
                let snippet = lines[contextStart...contextEnd]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

                out.append(
                    Inf6DocEntity(
                        kind: .equation,
                        pageIndex: p,
                        title: "Equation \(number)",
                        snippet: String(snippet.prefix(1400))
                    )
                )
            }

            // キャプションやテキスト抽出がないページも、PDFページ全体を
            // 同じEdge/Core MLレイアウト検出に通して候補を補う。検出件数に
            // 上限は設けず、本文由来の候補数を超える領域だけを追加する。
            #if canImport(UIKit)
            let mediaBox = page.bounds(for: .mediaBox)
            let layoutImage = page.thumbnail(
                of: CGSize(width: mediaBox.width * 2, height: mediaBox.height * 2),
                for: .mediaBox
            )
            if let cgImage = layoutImage.cgImage {
                do {
                    let detections = try Inf6DocLayoutDetector.shared.detect(image: cgImage)
                        .sorted { lhs, rhs in
                            if lhs.y != rhs.y { return lhs.y < rhs.y }
                            return lhs.x < rhs.x
                        }
                    for kind in [Inf6DocEntityKind.figure, .table, .equation] {
                        let layoutClass: Inf6DocLayoutClass
                        switch kind {
                        case .figure: layoutClass = .picture
                        case .table: layoutClass = .table
                        case .equation: layoutClass = .formula
                        }
                        let detectedCount = detections.filter { $0.classID == layoutClass }.count
                        let existingCount = out.filter { $0.pageIndex == p && $0.kind == kind }.count
                        guard detectedCount > existingCount else { continue }
                        for ordinal in existingCount..<detectedCount {
                            out.append(Inf6DocEntity(
                                kind: kind,
                                pageIndex: p,
                                title: "\(kind.labelEn) page \(p + 1) #\(ordinal + 1)",
                                snippet: String(text.prefix(1400))
                            ))
                        }
                    }
                } catch {
                    NSLog("[Inf6DocEntityScanner] layout detection failed p%d: %@", p + 1, error.localizedDescription)
                }
            }
            #endif
        }

        // stable order: by page then kind
        out.sort { a, b in
            if a.pageIndex != b.pageIndex { return a.pageIndex < b.pageIndex }
            return a.kind.rawValue < b.kind.rawValue
        }
        for index in out.indices {
            out[index].references = _references(
                for: out[index],
                pageTexts: referencePageTexts
            )
        }
        return out
    }

    private static let _mathOperatorTokens = ["=", "∑", "∏", "∫", "≤", "≥", "≈", "≠", "⊂", "⊆", "→", "←"]

    private static func _containsMathOperator(_ line: String) -> Bool {
        _mathOperatorTokens.contains { line.contains($0) }
    }

    /// "Equation 3" / "Eq. (3)" などから番号だけを取り出す。
    private static func _equationNumber(in text: String) -> String? {
        let pattern = #"(?i)\b(?:equation|eq\.?)\s*\(?\s*(\d+(?:\.\d+)?)\s*\)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    /// 別組み数式の行末採番 "... (1)" から番号を取り出す。
    /// 文献参照の "(2017)" を数式番号と誤認しないよう、4桁以上は年号とみなして除外する。
    private static func _trailingEquationNumber(in line: String) -> String? {
        let pattern = #"\(\s*(\d{1,3}(?:\.\d+)?)\s*\)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
              let range = Range(match.range(at: 1), in: line)
        else { return nil }
        return String(line[range])
    }

    private static func _containsEquationEvidence(in text: String, match: NSRange) -> Bool {
        let ns = text as NSString
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: match)
        guard contentsEnd > lineStart else { return false }
        let line = ns.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))

        // A reference such as "Equation 2010" is not an equation. Require a
        // mathematical operator on the same extracted line before persisting it.
        return _containsMathOperator(line)
    }

    private static func _references(
        for entity: Inf6DocEntity,
        pageTexts: [String]
    ) -> [Inf6DocEntityReference] {
        guard let canonical = _canonicalReference(entity.title) else { return [] }
        let pattern = "(?i)\\b\(canonical.kindPattern)\\s*\\(?\\s*\(NSRegularExpression.escapedPattern(for: canonical.number))\\s*\\)?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var references: [Inf6DocEntityReference] = []

        for (pageIndex, pageText) in pageTexts.enumerated() where !pageText.isEmpty {
            let lines = pageText.components(separatedBy: .newlines)
            var pageOffset = 0
            for (lineIndex, line) in lines.enumerated() {
                let nsLine = line as NSString
                let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
                guard !matches.isEmpty else {
                    pageOffset += nsLine.length + 1
                    continue
                }
                let from = max(0, lineIndex - 2)
                let to = min(lines.count - 1, lineIndex + 2)
                let context = lines[from...to].joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let captionPattern = "(?i)^\\s*\(canonical.kindPattern)\\s*\\(?\\s*\(NSRegularExpression.escapedPattern(for: canonical.number))\\s*\\)?\\s*[:：.]"
                let isCaption = (try? NSRegularExpression(pattern: captionPattern))?
                    .firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) != nil
                for match in matches {
                    references.append(Inf6DocEntityReference(
                        id: UUID(),
                        kind: isCaption ? .caption : .mention,
                        pageIndex: pageIndex,
                        text: trimmedLine,
                        surroundingText: context,
                        utf16Location: pageOffset + match.range.location,
                        utf16Length: match.range.length
                    ))
                }
                pageOffset += nsLine.length + 1
            }
        }
        return references
    }

    private static func _canonicalReference(_ title: String) -> (kindPattern: String, number: String)? {
        let pattern = #"(?i)\b(figure|fig\.?|table|tab\.?|equation|eq\.?)\s*\(?\s*([a-z]?\d+(?:\.\d+)?)\s*\)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..<title.endIndex, in: title)),
              let kindRange = Range(match.range(at: 1), in: title),
              let numberRange = Range(match.range(at: 2), in: title)
        else { return nil }
        let rawKind = String(title[kindRange]).lowercased()
        let kindPattern: String
        if rawKind.hasPrefix("fig") { kindPattern = "(?:figure|fig\\.?)" }
        else if rawKind.hasPrefix("tab") { kindPattern = "(?:table|tab\\.?)" }
        else { kindPattern = "(?:equation|eq\\.?)" }
        return (kindPattern, String(title[numberRange]))
    }

    #if canImport(Vision) && canImport(UIKit)
    private static func _recognizedPageText(_ page: PDFPage, pageIndex: Int) -> String {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return "" }
        let width: CGFloat = 1800
        let image = page.thumbnail(
            of: CGSize(width: width, height: width * bounds.height / bounds.width),
            for: .mediaBox
        )
        guard let cgImage = image.cgImage else { return "" }

        let request = VNRecognizeTextRequest()
        request.usesCPUOnly = true
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        do {
            Inf6EshikakuDrillPipeline.visionOCRLock.lock()
            defer { Inf6EshikakuDrillPipeline.visionOCRLock.unlock() }
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
        } catch {
            NSLog("[Inf6DocEntityScanner] Vision OCR failed p%d: %@", pageIndex + 1, error.localizedDescription)
            return ""
        }
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
    #endif
#endif
}

// MARK: - MiniPDF writer (text -> 1 page PDF, per-entity file)

public enum Inf6MiniPDFWriter {

    public static func writeTextMiniPDF(text: String, to url: URL) -> Bool {
        #if canImport(UIKit)
        return _writeUIKit(text: text, to: url)
        #else
        return false
        #endif
    }

    #if canImport(UIKit)
    private static func _writeUIKit(text: String, to url: URL) -> Bool {
        let margin: CGFloat = 24
        let pageWidth: CGFloat = 520
        let font = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph
        ]

        let maxRect = CGRect(x: 0, y: 0, width: pageWidth - 2 * margin, height: CGFloat.greatestFiniteMagnitude)
        let bounds = (text as NSString).boundingRect(
            with: maxRect.size,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs,
            context: nil
        )

        let pageHeight = max(140, ceil(bounds.height + 2 * margin))
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        do {
            let data = renderer.pdfData { ctx in
                ctx.beginPage()
                let drawRect = CGRect(x: margin, y: margin, width: pageWidth - 2 * margin, height: pageHeight - 2 * margin)
                (text as NSString).draw(in: drawRect, withAttributes: attrs)
            }
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }
    #endif


}
