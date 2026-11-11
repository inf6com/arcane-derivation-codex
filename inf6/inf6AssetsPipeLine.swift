//
//  inf6AssetsPipeLine.swift
//  inf6
//
//  Created by decopin on 2026/01/02.
//


//  Paper-level abstract generator + page-level “Figures/Tables/Equations” note generator.
//
//
//

import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(UIKit)
import UIKit
#endif
import CoreGraphics

// MARK: - Public models

public enum Inf6AssetsKind: String, Codable, Hashable {
    case figure
    case table
    case equation
}

/// A single detected “asset candidate” on a specific page.
/// This is metadata for UI (list/selection) and for prompt grounding.
public struct Inf6AssetsItem: Identifiable, Codable, Hashable {
    public let id: UUID
    public let kind: Inf6AssetsKind
    /// 0-based page index
    public let pageIndex: Int

    /// Caption-like headline (for figure/table) or a short label (for equation)
    public let titleLine: String

    /// Nearby evidence text from the same page (best-effort)
    public let evidence: String

    /// For equation: extracted equation-ish block (best-effort)
    public let equationText: String?

    public init(
        id: UUID = UUID(),
        kind: Inf6AssetsKind,
        pageIndex: Int,
        titleLine: String,
        evidence: String,
        equationText: String?
    ) {
        self.id = id
        self.kind = kind
        self.pageIndex = pageIndex
        self.titleLine = titleLine
        self.evidence = evidence
        self.equationText = equationText
    }
}

/// Result for a single page: ready-to-append markdown note + the detected items.
public struct Inf6AssetsPageNoteResult: Codable, Hashable {
    public let pageIndex: Int

    /// Markdown that can be appended into the page’s note/explanation store.
    /// It contains ONLY page-level sections (## 図 / ## 表 / ## 式) and NEVER the paper abstract.
    public let noteMarkdown: String

    /// Detected items used to ground the prompt (and for UI list).
    public let items: [Inf6AssetsItem]

    /// Structured note payloads to be rendered directly in the PDF detail pane.
    public let renderedNotes: [Inf6AssetsRenderedNote]

    public init(
        pageIndex: Int,
        noteMarkdown: String,
        items: [Inf6AssetsItem],
        renderedNotes: [Inf6AssetsRenderedNote] = []
    ) {
        self.pageIndex = pageIndex
        self.noteMarkdown = noteMarkdown
        self.items = items
        self.renderedNotes = renderedNotes
    }
}

public struct Inf6AssetsRenderedNote: Identifiable, Codable, Hashable {
    public let id: UUID
    public let kind: Inf6AssetsKind
    public let title: String
    public let text: String
    public let structuredTable: Inf6StructuredTable?

    public init(
        id: UUID = UUID(),
        kind: Inf6AssetsKind,
        title: String,
        text: String,
        structuredTable: Inf6StructuredTable? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.structuredTable = structuredTable
    }
}

private struct _Inf6StructuredTableJSONColumn: Decodable {
    let nameEN: String
    let nameJA: String
    let explanationEN: String
    let explanationJA: String
    /// "max" (higher is better), "min" (lower is better), or "none" (no optimization direction).
    let optimization: String?

    enum CodingKeys: String, CodingKey {
        case nameEN = "name_en"
        case nameJA = "name_ja"
        case explanationEN = "explanation_en"
        case explanationJA = "explanation_ja"
        case optimization
    }
}

private struct _Inf6StructuredTableJSONRow: Decodable {
    let nameEN: String
    let nameJA: String
    let explanationEN: String
    let explanationJA: String
    let values: [String]

    enum CodingKeys: String, CodingKey {
        case nameEN = "name_en"
        case nameJA = "name_ja"
        case explanationEN = "explanation_en"
        case explanationJA = "explanation_ja"
        case values
    }
}

private struct _Inf6StructuredTableJSONPayload: Decodable {
    let columns: [_Inf6StructuredTableJSONColumn]
    let rows: [_Inf6StructuredTableJSONRow]
    let readingPointsEN: [String]?
    let readingPointsJA: [String]?

    enum CodingKeys: String, CodingKey {
        case columns
        case rows
        case readingPointsEN = "reading_points_en"
        case readingPointsJA = "reading_points_ja"
    }
}

/// Generated mini-PDF entry (currently used for equations).
public struct Inf6AssetsMiniPDFEntry: Identifiable, Codable, Hashable {
    public let id: UUID

    /// 0-based page index
    public let pageIndex: Int

    /// The originating detected item id.
    public let sourceItemID: UUID

    /// Kind for this mini PDF (expected to be `.equation`).
    public let kind: Inf6AssetsKind

    /// File URL of the generated mini PDF.
    public let url: URL

    public init(
        id: UUID = UUID(),
        pageIndex: Int,
        sourceItemID: UUID,
        kind: Inf6AssetsKind,
        url: URL
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.sourceItemID = sourceItemID
        self.kind = kind
        self.url = url
    }
}

/// Result bundle for a single page: page note + mini PDFs (equations are added manually).
public struct Inf6AssetsPageBundleResult: Codable, Hashable {
    public let pageResult: Inf6AssetsPageNoteResult
    public let miniPDFs: [Inf6AssetsMiniPDFEntry]

    public init(pageResult: Inf6AssetsPageNoteResult, miniPDFs: [Inf6AssetsMiniPDFEntry]) {
        self.pageResult = pageResult
        self.miniPDFs = miniPDFs
    }
}

// MARK: - Pipeline

public enum Inf6AssetsAbstractPipeline {

    // MARK: Language

    public enum Lang {
        case ja
        case en

        public static func normalize(_ raw: String) -> Lang {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if s == "en" { return .en }
            if s == "ja" { return .ja }
            // default policy: Japanese
            return .ja
        }
    }

    // MARK: Manual equation mini-PDF

    /// Create a single equation mini-PDF MANUALLY for a detected equation item.
    /// The caller must provide the exact destination URL; this pipeline does not guess any storage location.
    ///
    /// - Parameters:
    ///   - genLang: "ja" or "en" (defaults to Japanese if unknown)
    ///   - pageIndex: 0-based page index where the equation lives
    ///   - sourceItem: The detected item (must be `.equation` and on the same pageIndex)
    ///   - outURL: Destination file URL for the mini PDF
    /// - Returns: A `Inf6AssetsMiniPDFEntry` that can be attached/displayed at the same position (page + item).
    @MainActor
    public static func createEquationMiniPDF(
        genLang: String,
        pageIndex: Int,
        sourceItem: Inf6AssetsItem,
        outURL: URL
    ) throws -> Inf6AssetsMiniPDFEntry {
        let lang = Lang.normalize(genLang)

        guard pageIndex >= 0 else {
            throw NSError(domain: "inf6.assets", code: -140, userInfo: [
                NSLocalizedDescriptionKey: "pageIndex out of range"
            ])
        }

        guard sourceItem.kind == .equation else {
            throw NSError(domain: "inf6.assets", code: -141, userInfo: [
                NSLocalizedDescriptionKey: "sourceItem is not an equation"
            ])
        }

        guard sourceItem.pageIndex == pageIndex else {
            throw NSError(domain: "inf6.assets", code: -142, userInfo: [
                NSLocalizedDescriptionKey: "sourceItem.pageIndex does not match pageIndex"
            ])
        }

        let eq = (sourceItem.equationText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !eq.isEmpty else {
            throw NSError(domain: "inf6.assets", code: -143, userInfo: [
                NSLocalizedDescriptionKey: "Equation item is missing equationText."
            ])
        }

        // Ensure destination directory exists (no implicit storage policy; only honors the given URL).
        let fm = FileManager.default
        let parent = outURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw NSError(domain: "inf6.assets", code: -144, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create destination directory: \(error.localizedDescription)"
            ])
        }

        let title = (lang == .ja)
            ? "数式ミニPDF p\(pageIndex + 1): \(sourceItem.titleLine)"
            : "Equation mini PDF p\(pageIndex + 1): \(sourceItem.titleLine)"

        try _writeMiniPDFText(outURL: outURL, title: title, body: eq)

        return Inf6AssetsMiniPDFEntry(
            pageIndex: pageIndex,
            sourceItemID: sourceItem.id,
            kind: .equation,
            url: outURL
        )
    }

    // MARK: Paper-level

    /// Generate a paper-level abstract (single blob).
    /// NOTE: This function does NOT generate any per-page figures/tables/equations notes.
    @MainActor
    public static func generatePaperAbstract(
        pdfURL: URL,
        paperTitle: String,
        genLang: String,
        entityEvidence: String = "",
        askModel: (String) async throws -> String
    ) async throws -> String {
        #if canImport(PDFKit)
        guard let doc = PDFDocument(url: pdfURL), doc.pageCount > 0 else {
            throw NSError(domain: "inf6.assets", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to open PDFDocument."
            ])
        }

        let lang = Lang.normalize(genLang)
        let normalizedPaperTitle = paperTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPaperTitle.isEmpty else {
            throw NSError(domain: "inf6.assets", code: -5, userInfo: [
                NSLocalizedDescriptionKey: "Paper title is missing; overview generation cannot continue."
            ])
        }
        let abstractEvidence = extractLikelyAbstractSnippet(doc: doc)
        if abstractEvidence.isEmpty {
            throw NSError(domain: "inf6.assets", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "No extractable abstract evidence (maybe scanned PDF)."
            ])
        }

        let prompt = buildPaperAbstractPrompt(
            lang: lang,
            paperTitle: normalizedPaperTitle,
            abstractEvidence: abstractEvidence,
            entityEvidence: entityEvidence.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let raw = try await askModel(prompt)
        let out = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty {
            throw NSError(domain: "inf6.assets", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "Empty model response."
            ])
        }
        guard overviewMeetsCurrentContract(out) else {
            throw NSError(domain: "inf6.assets", code: -4, userInfo: [
                NSLocalizedDescriptionKey: "Generated overview does not contain the required practical sections."
            ])
        }
        let titleLine = (lang == .ja)
            ? "論文名: \(normalizedPaperTitle)"
            : "Paper title: \(normalizedPaperTitle)"
        return "\(titleLine)\n\n\(out)"
        #else
        throw NSError(domain: "inf6.assets", code: -99, userInfo: [
            NSLocalizedDescriptionKey: "PDFKit is unavailable."
        ])
        #endif
    }

    public static func overviewMeetsCurrentContract(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 600 else { return false }
        let japaneseHeadings = ["解説", "数学的導出", "実装", "実務上の検証"]
        let englishHeadings = ["Explanation", "Mathematical derivation", "Implementation", "Practical validation"]
        let japaneseValid = japaneseHeadings.allSatisfy { normalized.contains($0) }
        let englishValid = englishHeadings.allSatisfy { normalized.localizedCaseInsensitiveContains($0) }
        return japaneseValid || englishValid
    }

    // MARK: Page-level

    /// Generate page-level note (Figures/Tables/Equations) for ONE page.
    /// This output is meant to be appended to the page’s note/explanation store.
    /// It NEVER includes the paper abstract.
    @MainActor
    public static func generatePageAssetsNote(
        pdfURL: URL,
        pageIndex: Int,
        genLang: String,
        askModel: (String) async throws -> String
    ) async throws -> Inf6AssetsPageNoteResult {
        #if canImport(PDFKit)
        guard let doc = PDFDocument(url: pdfURL), doc.pageCount > 0 else {
            throw NSError(domain: "inf6.assets", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to open PDFDocument."
            ])
        }
        guard pageIndex >= 0, pageIndex < doc.pageCount else {
            throw NSError(domain: "inf6.assets", code: -10, userInfo: [
                NSLocalizedDescriptionKey: "pageIndex out of range"
            ])
        }
        guard let page = doc.page(at: pageIndex) else {
            throw NSError(domain: "inf6.assets", code: -11, userInfo: [
                NSLocalizedDescriptionKey: "Failed to open PDFPage."
            ])
        }

        let lang = Lang.normalize(genLang)
        let pageTextRaw = page.string ?? ""
        let pageText = normalizeSpaces(pageTextRaw)

        // If page text is empty, we still return a deterministic “none” note (no model call).
        if pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Inf6AssetsPageNoteResult(
                pageIndex: pageIndex,
                noteMarkdown: "",
                items: [],
                renderedNotes: []
            )
        }

        let isTwoColumn = detectIsTwoColumnDocument(doc: doc)
        let items = try detectItemsForPDFPage(
            pageIndex: pageIndex,
            page: page,
            pageText: pageText,
            isTwoColumnDocument: isTwoColumn
        )

        // If no detected items, avoid spending tokens; return a deterministic “none”.
        if items.isEmpty {
            return Inf6AssetsPageNoteResult(
                pageIndex: pageIndex,
                noteMarkdown: "",
                items: [],
                renderedNotes: []
            )
        }
        let renderedNotes = try await generateDetailedPageRenderedNotes(
            lang: lang,
            pageIndex: pageIndex,
            pageEvidence: String(pageText.prefix(3500)),
            items: items,
            askModel: askModel
        )
        let note = renderedNotesToMarkdown(lang: lang, renderedNotes: renderedNotes)

        return Inf6AssetsPageNoteResult(
            pageIndex: pageIndex,
            noteMarkdown: note,
            items: items,
            renderedNotes: renderedNotes
        )
        #else
        throw NSError(domain: "inf6.assets", code: -99, userInfo: [
            NSLocalizedDescriptionKey: "PDFKit is unavailable."
        ])
        #endif
    }

    /// Generate page-level assets notes for ALL pages.
    /// - Returns: An array of per-page bundles, in page order.
    ///
    /// Important:
    /// - The mini-PDF is generated from extracted equation-like TEXT (best-effort). It does not crop/render the original PDF graphics.
    /// - Failures are NOT swallowed: the first failure stops the batch with an error.
    @MainActor
    public static func generateAllPagesAssetsBundle(
        pdfURL: URL,
        genLang: String,
        askModel: (String) async throws -> String
    ) async throws -> [Inf6AssetsPageBundleResult] {
        #if canImport(PDFKit)
        guard let doc = PDFDocument(url: pdfURL), doc.pageCount > 0 else {
            throw NSError(domain: "inf6.assets", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to open PDFDocument."
            ])
        }
        let lang = Lang.normalize(genLang)
        var out: [Inf6AssetsPageBundleResult] = []
        out.reserveCapacity(doc.pageCount)

        // Stable cache directory (do NOT clear previous entries automatically).
        // (removed)

        // Document-level 2-column detection (sample first 5–10 pages).
        let isTwoColumn = detectIsTwoColumnDocument(doc: doc)

        for pageIndex in 0..<doc.pageCount {
            guard let page = doc.page(at: pageIndex) else {
                throw NSError(domain: "inf6.assets", code: -11, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to open PDFPage."
                ])
            }

            let pageTextRaw = page.string ?? ""
            let pageText = normalizeSpaces(pageTextRaw)

            // If page text is empty, return deterministic none note (no model call).
            if pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let pageResult = Inf6AssetsPageNoteResult(
                    pageIndex: pageIndex,
                    noteMarkdown: "",
                    items: [],
                    renderedNotes: []
                )
                out.append(Inf6AssetsPageBundleResult(pageResult: pageResult, miniPDFs: []))
                continue
            }

            let items = try detectItemsForPDFPage(
                pageIndex: pageIndex,
                page: page,
                pageText: pageText,
                isTwoColumnDocument: isTwoColumn
            )
            guard !items.isEmpty else {
                out.append(Inf6AssetsPageBundleResult(
                    pageResult: Inf6AssetsPageNoteResult(
                        pageIndex: pageIndex,
                        noteMarkdown: "",
                        items: [],
                        renderedNotes: []
                    ),
                    miniPDFs: []
                ))
                continue
            }

            let renderedNotes = try await generateDetailedPageRenderedNotes(
                lang: lang,
                pageIndex: pageIndex,
                pageEvidence: String(pageText.prefix(4000)),
                items: items,
                askModel: askModel
            )
            let note = renderedNotesToMarkdown(lang: lang, renderedNotes: renderedNotes)
            let pageResult = Inf6AssetsPageNoteResult(
                pageIndex: pageIndex,
                noteMarkdown: note,
                items: items,
                renderedNotes: renderedNotes
            )
            out.append(Inf6AssetsPageBundleResult(pageResult: pageResult, miniPDFs: []))
        }

        return out
        #else
        throw NSError(domain: "inf6.assets", code: -99, userInfo: [
            NSLocalizedDescriptionKey: "PDFKit is unavailable."
        ])
        #endif
    }
}

// MARK: - Prompt building

extension Inf6AssetsAbstractPipeline {
    @MainActor
    static func generateDetailedPageRenderedNotes(
        lang: Lang,
        pageIndex: Int,
        pageEvidence: String,
        items: [Inf6AssetsItem],
        askModel: (String) async throws -> String
    ) async throws -> [Inf6AssetsRenderedNote] {
        let figures = items.filter { $0.kind == .figure }
        let tables = items.filter { $0.kind == .table }
        if figures.isEmpty, tables.isEmpty {
            return []
        }

        func safeTitle(_ it: Inf6AssetsItem) -> String {
            let t = it.titleLine.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "(untitled)" : t
        }

        var renderedNotes: [Inf6AssetsRenderedNote] = []
        renderedNotes.reserveCapacity(figures.count + tables.count)

        for it in figures {
            let prompt = buildFigureDetailPrompt(lang: lang, pageIndex: pageIndex, pageEvidence: pageEvidence, item: it)
            let raw = try await askModel(prompt)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw NSError(domain: "inf6.assets", code: -127, userInfo: [
                    NSLocalizedDescriptionKey: "Empty model response."
                ])
            }
            let title = safeTitle(it)
            let text: String
            switch lang {
            case .ja:
                text = [
                    "名称: \(title)",
                    "ポイント:",
                    trimmed
                ].joined(separator: "\n")
            case .en:
                text = [
                    "name: \(title)",
                    "points:",
                    trimmed
                ].joined(separator: "\n")
            }
            renderedNotes.append(Inf6AssetsRenderedNote(kind: .figure, title: title, text: text))
        }

        for it in tables {
            let title = safeTitle(it)
            let maxRetries = 3
            var lastError: Error?
            for attempt in 1...maxRetries {
                do {
                    let prompt = buildTableDetailPrompt(lang: lang, pageIndex: pageIndex, pageEvidence: pageEvidence, item: it)
                    let raw = try await askModel(prompt)
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        throw NSError(domain: "inf6.assets", code: -128, userInfo: [
                            NSLocalizedDescriptionKey: "Empty table model response: \(title)"
                        ])
                    }
                    let table = try parseStructuredTableJSON(raw: trimmed, title: title, lang: lang)
                    renderedNotes.append(Inf6AssetsRenderedNote(
                        kind: .table,
                        title: title,
                        text: plainTextFromStructuredTable(table, lang: lang),
                        structuredTable: table
                    ))
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    let desc = error.localizedDescription
                    print("[Assets] Table parse attempt \(attempt)/\(maxRetries) failed for '\(title)': \(desc)")
                    if desc.contains("insufficient_quota") || desc.contains("invalid_api_key") || desc.contains("exceeded") {
                        break
                    }
                    if attempt < maxRetries {
                        try await Task.sleep(nanoseconds: UInt64(500_000_000 * attempt))
                    }
                }
            }
            if let err = lastError {
                print("[Assets] Skipping table '\(title)' after \(maxRetries) retries: \(err.localizedDescription)")
            }
        }

        return renderedNotes
    }

    @MainActor
    static func generateDetailedPageNoteMarkdown(
        lang: Lang,
        pageIndex: Int,
        pageEvidence: String,
        items: [Inf6AssetsItem],
        askModel: (String) async throws -> String
    ) async throws -> String {
        let renderedNotes = try await generateDetailedPageRenderedNotes(
            lang: lang,
            pageIndex: pageIndex,
            pageEvidence: pageEvidence,
            items: items,
            askModel: askModel
        )
        return renderedNotesToMarkdown(lang: lang, renderedNotes: renderedNotes)
    }
    
    // MARK: - AI-driven page note (detection + description in one call)

    /// Builds a prompt that asks the model to find ALL figures and tables on the page
    /// and describe them — no regex pre-filtering required.
    static func buildAIDrivenPageNotePrompt(lang: Lang, pageIndex: Int, pageEvidence: String) -> String {
        let pNum = pageIndex + 1
        switch lang {
        case .ja:
            return """
            あなたは査読論文の図・表の解説者です。
            以下の【ページテキスト（p\(pNum)）】を読み、このページに存在する「図（Figure/Fig./図）」と「表（Table/Tab./表）」を自ら探し出して解説してください。
            推測・一般論は禁止。このページのテキストに書かれていることだけを根拠にしてください。

            【出力形式】
            ─ 以下の2つの見出しを必ず出力すること ─
            図
            （図がある場合）
            名称: <Figure N. のキャプション全文>
            ポイント:
            - <箇条書き 2〜4個・各60字以内>
            - グラフなら縦軸・横軸の意味と単位を必ず書く
            （このページに図がなければ「（なし）」とだけ書く）

            表
            （表がある場合）
            名称: <Table N. のキャプション全文>
            再構成表:
            |列1|列2|...|
            |---|---|---|
            |行1|値|値|
            列の意味:
            - <列ごとの箇条書き・各120字以内>
            行の意味:
            - <行ごとの箇条書き・各120字以内>
            - 表は、本文テキストから回収できる列名・行名・数値・記号だけで再構成する
            - 本文テキストに無い値や見出しを捏造してはならない
            （このページに表がなければ「（なし）」とだけ書く）

            【ページテキスト（p\(pNum)）】
            \(pageEvidence)
            """
        case .en:
            return """
            You detect and explain ALL figures and tables found in the page text of a peer-reviewed paper.
            Use ONLY the page text below. No speculation or general statements.

            [Output format — output BOTH headings always]
            Figures
            (if figures exist)
            name: <Figure N. full caption>
            points:
            - <2–4 bullets, max ~18 words each>
            - For graphs: state x-axis and y-axis meaning and units
            (if no figures on this page, write "(none)")

            Tables
            (if tables exist)
            name: <Table N. full caption>
            Reconstructed table:
            |col1|col2|...|
            |---|---|---|
            |row1|value|value|
            Column meanings:
            - <bullet per column, max ~18 words>
            Row meanings:
            - <bullet per row, max ~18 words>
            - Reconstruct using ONLY headers, row labels, values, numbers, and symbols recoverable from the page text
            - Do NOT invent missing headers or values
            (if no tables on this page, write "(none)")

            [Page text (p\(pNum))]
            \(pageEvidence)
            """
        }
    }

    /// Returns true when the note contains only "none" placeholders — meaning AI found nothing.
    static func isAllNone(_ note: String, lang: Lang) -> Bool {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        // Remove heading lines and none markers; if nothing substantive remains → all-none.
        let headings: Set<String> = (lang == .ja)
            ? ["図", "表", "（なし）"]
            : ["Figures", "Tables", "(none)"]
        let remaining = trimmed.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !headings.contains($0) }
        return remaining.isEmpty
    }

    static func buildFigureDetailPrompt(lang: Lang, pageIndex: Int, pageEvidence: String, item: Inf6AssetsItem) -> String {
        switch lang {
        case .ja:
            return """
            あなたは査読論文の図の専門解説者です。
            以下の【このページのテキスト】と【図アイテム】だけを根拠に、図の詳細な解説と見るべきポイントを記述してください。
            推測や一般論は禁止。根拠は必ず引用内の語句・数値に対応づけて書いてください。

            【出力形式】
            必ず以下の2セクション構成で出力してください。

            【詳細解説】
            • （1項目 最大80字、4〜6項目）
            　- 図が何を示しているか（実験設定・比較対象・データ範囲）
            　- 横軸の意味と単位を明記
            　- 縦軸の意味と単位を明記
            　- 凡例・色・記号が何を表すかを説明
            　- 図中の主要な数値・ピーク・傾向を具体的に記述

            【見るべきポイント】
            • （1項目 最大80字、2〜3項目）
            　- この図から読み取れる最も重要な発見・比較・パターン
            　- 本文の主張とこの図の関係
            　- 見落としやすい細部や注意点

            【図アイテム】
            title: \(item.titleLine)
            evidence: \(item.evidence)

            【このページのテキスト】
            \(pageEvidence)
            """
        case .en:
            return """
            You are a detailed figure explainer for peer-reviewed papers.
            Use ONLY the page text and the provided figure item. No speculation.

            [Output format]
            Output exactly two sections:

            [Detailed description]
            • (4–6 bullets, max ~25 words each)
              - What the figure shows (experimental setup, comparisons, data range)
              - X-axis: label and unit
              - Y-axis: label and unit
              - What the legend, colors, or symbols represent
              - Key values, peaks, and trends visible in the figure

            [Key observation points]
            • (2–3 bullets, max ~25 words each)
              - Most important finding, comparison, or pattern
              - How this figure supports the paper's main claim
              - Any subtle detail or caveat worth noting

            [Figure item]
            title: \(item.titleLine)
            evidence: \(item.evidence)

            [Page text]
            \(pageEvidence)
            """
        }
    }
    
    static func buildTableDetailPrompt(lang: Lang, pageIndex: Int, pageEvidence: String, item: Inf6AssetsItem) -> String {
        switch lang {
        case .ja:
            return """
            あなたは査読論文の表の『詳細解説』担当です。
            以下の【表アイテム】だけを根拠に、表が何を比較/集計しているかを再構成してください。
            推測や一般論は禁止。根拠は必ず引用内の語句・数値に対応づけて書いてください。

            【出力条件】
            - 出力は JSON オブジェクトのみ
            - 次の shape を厳密に守ること
              {
                "reading_points_ja": ["この表の読み方ポイント1（日本語）", "ポイント2"],
                "reading_points_en": ["Reading point 1 (English)", "point 2"],
                "columns": [
                  {
                    "name_en": "...",
                    "name_ja": "...",
                    "explanation_en": "...",
                    "explanation_ja": "...",
                    "optimization": "max" | "min" | "none"
                  }
                ],
                "rows": [
                  {
                    "name_en": "...",
                    "name_ja": "...",
                    "explanation_en": "...",
                    "explanation_ja": "...",
                    "values": ["...", "..."]
                  }
                ]
              }
            - columns[*].optimization は、その列の最良値の方向を示す:
              - "max": 大きいほど良い（例: 精度 / Accuracy / AP / F1 / BLEU / Recall / FPS など）
              - "min": 小さいほど良い（例: 誤差率 / Error / Loss / Perplexity / Latency / FLOPs / #Params / メモリ使用量 など）
              - "none": 比較に意味がない / 単なる識別子 / 単位付き混合表現（例: モデル名列、"320/16" のような複合値、設定値）
            - 行見出し列（columns[0]）の optimization は "none" にすること
            - reading_points_ja / reading_points_en は「この表をどう読むか」のポイントを2〜4項目で記述すること
            - 表から読み取れる最も重要な傾向・比較軸・注目すべき数値を必ず含めること
            - columns には、左端の行見出し列も含めること
            - rows[*].values の個数は、columns の総数 - 1 と完全一致させること
            - 表は、本文テキストから回収できる列名・行名・数値・記号だけで再構成する
            - 表アイテム evidence やページテキストに無い値や見出しを捏造してはならない
            - evidence やページテキストから回収できないセル値は "—"（emダッシュ）で埋めること。空文字列 "" にしてはならない
            - 回収できない列や行は追加しない
            - 対象は title に書かれた表だけ
            - title が Table 4 / 表4 なら Table 5 / 表5 など別番号の表を columns / rows / reading_points に含めてはならない
            - 複数段ヘッダは見た目をそのまま真似せず、1行の列名へ平坦化すること
            - 例: 「BLEU」配下の「EN-DE」は「BLEU EN-DE」のように1列名へ結合すること
            - セル結合の見た目を再現するための空列や「—」だけの飾り列を追加してはならない
            - name_en は原表のラベルを保持すること
            - name_ja は和名化したラベルにすること
            - explanation_en / explanation_ja は、それぞれ英語/日本語で簡潔に説明すること
            - values の文字列に ** を付けてはならない（強調表示はアプリ側で機械的に行う）
            - JSON 以外の文章、Markdown、コードフェンスは禁止

            【表アイテム】
            title: \(item.titleLine)
            evidence: \(item.evidence)

            【このページのテキスト】
            \(pageEvidence)
            """
        case .en:
            return """
            You are responsible for a DETAILED explanation of a TABLE in a peer-reviewed paper.
            Using ONLY the [Table item] below, reconstruct what the table compares/aggregates.
            No speculation or generic statements. Every claim MUST be tied to exact words/numbers found in the evidence.

            [Output requirements]
            - Output JSON only
            - Use this exact shape:
              {
                "reading_points_en": ["Reading point 1", "point 2"],
                "reading_points_ja": ["読み方ポイント1", "ポイント2"],
                "columns": [
                  {
                    "name_en": "...",
                    "name_ja": "...",
                    "explanation_en": "...",
                    "explanation_ja": "...",
                    "optimization": "max" | "min" | "none"
                  }
                ],
                "rows": [
                  {
                    "name_en": "...",
                    "name_ja": "...",
                    "explanation_en": "...",
                    "explanation_ja": "...",
                    "values": ["...", "..."]
                  }
                ]
              }
            - columns[*].optimization indicates the direction of "best" for that column:
              - "max": higher is better (e.g. Accuracy / AP / F1 / BLEU / Recall / FPS)
              - "min": lower is better (e.g. Error / Loss / Perplexity / Latency / FLOPs / #Params / Memory)
              - "none": no meaningful comparison / identifier column / mixed-unit composite values (e.g. model name, "320/16", config strings)
            - The row-header column (columns[0]) MUST have optimization = "none"
            - reading_points_en / reading_points_ja: 2–4 bullets on how to read this table
            - Include the key trend, comparison axis, and most notable value(s) found in the evidence
            - Include the left-most row-header column inside columns
            - For every row, values.count must equal columns.count - 1
            - Reconstruct the table using ONLY column names, row names, values, numbers, and symbols recoverable from the page text
            - If a cell value is NOT recoverable from the evidence, use "—" (em dash) as the placeholder — never leave it as an empty string ""
            - Do NOT invent or fabricate numeric values; use "—" for truly missing data
            - Do NOT add rows/columns that cannot be recovered from evidence
            - Reconstruct only the table named in title
            - If title is Table 4, do not include Table 5 content in columns, rows, or reading_points
            - Flatten multi-level headers into a single header row
            - Example: merge "BLEU" + "EN-DE" into one column name such as "BLEU EN-DE"
            - Do NOT add decorative empty columns or placeholder-only columns to mimic merged cells
            - name_en must preserve the original table label
            - name_ja must be a Japanese explanatory label
            - explanation_en / explanation_ja must be concise and evidence-grounded
            - Do NOT wrap any value with "**" — emphasis is applied mechanically by the app
            - No Markdown, no code fences, no prose outside the JSON object

            [Table item]
            title: \(item.titleLine)
            evidence: \(item.evidence)

            [Page text]
            \(pageEvidence)
            """
        }
    }

    static func renderedNotesToMarkdown(lang: Lang, renderedNotes: [Inf6AssetsRenderedNote]) -> String {
        if renderedNotes.isEmpty { return "" }

        func sectionTitle(_ kind: Inf6AssetsKind) -> String {
            switch (lang, kind) {
            case (.ja, .figure):
                return "図"
            case (.ja, .table):
                return "表"
            case (.en, .figure):
                return "Figures"
            case (.en, .table):
                return "Tables"
            case (_, .equation):
                return (lang == .ja) ? "式" : "Equations"
            }
        }

        let grouped = Dictionary(grouping: renderedNotes, by: \.kind)
        var sections: [String] = []

        for kind in [Inf6AssetsKind.figure, .table] {
            guard let notes = grouped[kind], !notes.isEmpty else { continue }
            var lines: [String] = [sectionTitle(kind)]
            for (index, note) in notes.enumerated() {
                switch lang {
                case .ja:
                    lines.append("名称: \(note.title)")
                case .en:
                    lines.append("name: \(note.title)")
                }
                lines.append(note.text)
                if index != notes.count - 1 {
                    lines.append("")
                }
            }
            sections.append(lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return sections.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func plainTextFromStructuredTable(_ table: Inf6StructuredTable, lang: Lang) -> String {
        let originalTableTitle = (lang == .ja) ? "元の表:" : "Original table:"
        let localizedTableTitle = (lang == .ja) ? "和名表:" : "Explained-label table:"
        let columnTitle = (lang == .ja) ? "列の解説:" : "Column explanations:"
        let rowTitle = (lang == .ja) ? "行の解説:" : "Row explanations:"

        let originalTableLines = markdownLines(from: table)
        let localizedTableLines = markdownLines(
            columns: table.structuredColumns?.map(\.labelJA) ?? table.columns,
            rows: table.structuredRows?.map { Inf6StructuredTableRow(label: $0.labelJA, values: $0.values) } ?? table.rows
        )

        let columnLines: [String]
        if let structuredColumns = table.structuredColumns, !structuredColumns.isEmpty {
            columnLines = structuredColumns.map { column in
                "- \(column.labelEN) / \(column.labelJA)\n  EN: \(column.explanationEN)\n  JA: \(column.explanationJA)"
            }
        } else {
            columnLines = table.columnMeanings.map { "- \($0.label): \($0.meaning)" }
        }

        let rowLines: [String]
        if let structuredRows = table.structuredRows, !structuredRows.isEmpty {
            rowLines = structuredRows.map { row in
                "- \(row.labelEN) / \(row.labelJA)\n  EN: \(row.explanationEN)\n  JA: \(row.explanationJA)"
            }
        } else {
            rowLines = table.rowMeanings.map { "- \($0.label): \($0.meaning)" }
        }

        var parts: [String] = []
        parts += [originalTableTitle] + originalTableLines
        parts += ["", localizedTableTitle] + localizedTableLines
        parts += ["", columnTitle] + columnLines
        parts += ["", rowTitle] + rowLines

        // 見方のポイント
        if lang == .ja, let pts = table.readingPointsJA, !pts.isEmpty {
            parts += ["", "見方のポイント:"] + pts.map { "- \($0)" }
        } else if lang == .en, let pts = table.readingPointsEN, !pts.isEmpty {
            parts += ["", "Reading points:"] + pts.map { "- \($0)" }
        } else if let pts = table.readingPointsEN ?? table.readingPointsJA, !pts.isEmpty {
            parts += ["", (lang == .ja ? "見方のポイント:" : "Reading points:")] + pts.map { "- \($0)" }
        }

        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func markdownLines(from table: Inf6StructuredTable) -> [String] {
        markdownLines(columns: table.columns, rows: table.rows)
    }

    static func markdownLines(columns: [String], rows: [Inf6StructuredTableRow]) -> [String] {
        let header = "|" + columns.joined(separator: "|") + "|"
        let separator = "|" + columns.map { _ in "---" }.joined(separator: "|") + "|"
        let rowLines = rows.map { row in
            "|" + ([row.label] + row.values).joined(separator: "|") + "|"
        }
        return [header, separator] + rowLines
    }

    static func parseStructuredTableJSON(raw: String, title: String, lang: Lang) throws -> Inf6StructuredTable {
        let data = Data(raw.utf8)
        let payload = try JSONDecoder().decode(_Inf6StructuredTableJSONPayload.self, from: data)

        let columns = try payload.columns.enumerated().map { index, column -> Inf6StructuredTableColumnDescriptor in
            let key = "column_\(index)"
            let nameEN = column.nameEN.trimmingCharacters(in: .whitespacesAndNewlines)
            let nameJA = column.nameJA.trimmingCharacters(in: .whitespacesAndNewlines)
            let explanationEN = column.explanationEN.trimmingCharacters(in: .whitespacesAndNewlines)
            let explanationJA = column.explanationJA.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !nameEN.isEmpty, !nameJA.isEmpty, !explanationEN.isEmpty, !explanationJA.isEmpty else {
                throw NSError(domain: "inf6.assets", code: -161, userInfo: [
                    NSLocalizedDescriptionKey: "Structured table JSON has an empty column property at index \(index)."
                ])
            }
            // index 0 = row-header column → always .none
            let opt: Inf6StructuredTableOptimization
            if index == 0 {
                opt = .none
            } else if let raw = column.optimization?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                      let parsed = Inf6StructuredTableOptimization(rawValue: raw) {
                opt = parsed
            } else {
                opt = .none
            }
            return Inf6StructuredTableColumnDescriptor(
                key: key,
                labelEN: nameEN,
                labelJA: nameJA,
                explanationEN: explanationEN,
                explanationJA: explanationJA,
                optimization: opt
            )
        }

        guard columns.count >= 2 else {
            throw NSError(domain: "inf6.assets", code: -162, userInfo: [
                NSLocalizedDescriptionKey: "Structured table JSON requires at least 2 columns (got \(columns.count))."
            ])
        }

        let rows = try payload.rows.enumerated().map { index, row -> Inf6StructuredTableRowDescriptor in
            let key = "row_\(index)"
            let nameEN = row.nameEN.trimmingCharacters(in: .whitespacesAndNewlines)
            let nameJA = row.nameJA.trimmingCharacters(in: .whitespacesAndNewlines)
            let explanationEN = row.explanationEN.trimmingCharacters(in: .whitespacesAndNewlines)
            let explanationJA = row.explanationJA.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !nameEN.isEmpty, !nameJA.isEmpty, !explanationEN.isEmpty, !explanationJA.isEmpty else {
                throw NSError(domain: "inf6.assets", code: -163, userInfo: [
                    NSLocalizedDescriptionKey: "Structured table JSON has an empty row property at index \(index)."
                ])
            }
            guard let normalizedValues = normalizeStructuredTableJSONValues(
                row.values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                expectedCount: columns.count - 1
            ) else {
                throw NSError(domain: "inf6.assets", code: -164, userInfo: [
                    NSLocalizedDescriptionKey: "Structured table JSON row has mismatched values count. expected=\(columns.count - 1) actual=\(row.values.count) row=\(nameEN)"
                ])
            }
            return Inf6StructuredTableRowDescriptor(
                key: key,
                labelEN: nameEN,
                labelJA: nameJA,
                explanationEN: explanationEN,
                explanationJA: explanationJA,
                values: normalizedValues
            )
        }

        // Mechanically bold the best numeric value per value-column based on each
        // column's optimization direction (max / min / none).
        // value-columns are columns[1...], because columns[0] is the row-header.
        let valueColumnOptimizations: [Inf6StructuredTableOptimization] = columns.dropFirst().map { $0.optimization }
        let highlightedRows: [Inf6StructuredTableRowDescriptor] = _applyBestValueHighlight(
            rows: rows,
            valueColumnOptimizations: valueColumnOptimizations
        )

        let legacyColumns = columns.map(\.labelEN)
        let legacyRows = highlightedRows.map { Inf6StructuredTableRow(label: $0.labelEN, values: $0.values) }
        let legacyColumnMeanings = columns.map {
            Inf6StructuredTableMeaning(label: $0.labelEN, meaning: lang == .ja ? $0.explanationJA : $0.explanationEN)
        }
        let legacyRowMeanings = highlightedRows.map {
            Inf6StructuredTableMeaning(label: $0.labelEN, meaning: lang == .ja ? $0.explanationJA : $0.explanationEN)
        }

        let readingPointsEN = payload.readingPointsEN?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let readingPointsJA = payload.readingPointsJA?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return Inf6StructuredTable(
            title: title,
            columns: legacyColumns,
            rows: legacyRows,
            columnMeanings: legacyColumnMeanings,
            rowMeanings: legacyRowMeanings,
            structuredColumns: columns,
            structuredRows: highlightedRows,
            readingPointsEN: readingPointsEN?.isEmpty == false ? readingPointsEN : nil,
            readingPointsJA: readingPointsJA?.isEmpty == false ? readingPointsJA : nil
        )
    }

    /// For each value-column, find the BEST numeric value per its optimization
    /// direction (max / min / none) and wrap matching cells with `**...**`.
    /// Cells whose value can't be parsed as a single number (e.g. "320/16", "—",
    /// non-numeric) are skipped — neither bolded nor counted.
    /// Columns with optimization == .none are not highlighted.
    /// Existing `**...**` wrappers are stripped first to avoid double-bold.
    static func _applyBestValueHighlight(
        rows: [Inf6StructuredTableRowDescriptor],
        valueColumnOptimizations: [Inf6StructuredTableOptimization]
    ) -> [Inf6StructuredTableRowDescriptor] {
        let valueColumnCount = valueColumnOptimizations.count
        guard valueColumnCount > 0, !rows.isEmpty else { return rows }

        // 1. Strip any pre-existing bold markup from values
        let stripped: [[String]] = rows.map { row in
            row.values.map { _stripBoldMarkup($0) }
        }

        // 2. For each value column, find the best numeric value per direction
        //    (need ≥ 2 valid numbers to declare a "best")
        var bestPerColumn: [Double?] = Array(repeating: nil, count: valueColumnCount)
        for col in 0..<valueColumnCount {
            let opt = valueColumnOptimizations[col]
            guard opt != .none else { continue }
            var values: [Double] = []
            for row in stripped {
                guard col < row.count else { continue }
                if let n = _parseSingleNumber(row[col]) {
                    values.append(n)
                }
            }
            guard values.count >= 2 else { continue }
            switch opt {
            case .max: bestPerColumn[col] = values.max()
            case .min: bestPerColumn[col] = values.min()
            case .none: break // unreachable; filtered above
            }
        }

        // 3. Rebuild rows, wrapping cells whose value equals the column best
        var out: [Inf6StructuredTableRowDescriptor] = []
        out.reserveCapacity(rows.count)
        for (i, row) in rows.enumerated() {
            var newValues: [String] = stripped[i]
            for col in 0..<valueColumnCount {
                guard col < newValues.count else { continue }
                guard let bestVal = bestPerColumn[col] else { continue }
                if let n = _parseSingleNumber(newValues[col]), n == bestVal {
                    newValues[col] = "**" + newValues[col] + "**"
                }
            }
            out.append(Inf6StructuredTableRowDescriptor(
                key: row.key,
                labelEN: row.labelEN,
                labelJA: row.labelJA,
                explanationEN: row.explanationEN,
                explanationJA: row.explanationJA,
                values: newValues
            ))
        }
        return out
    }

    /// Parse a cell as a single decimal number. Returns nil for non-numeric,
    /// multi-value (e.g. "320/16"), units-attached (e.g. "166M"), or placeholders.
    static func _parseSingleNumber(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s == "—" || s == "-" { return nil }
        // Reject if contains anything other than a single number representation
        // Allowed: digits, one optional leading minus, one optional decimal point.
        let pattern = #"^-?\d+(?:\.\d+)?$"#
        guard s.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return Double(s)
    }

    /// Strip leading/trailing `**` markdown bold markers.
    static func _stripBoldMarkup(_ raw: String) -> String {
        var s = raw
        while s.hasPrefix("**") { s = String(s.dropFirst(2)) }
        while s.hasSuffix("**") { s = String(s.dropLast(2)) }
        return s
    }

    static func normalizeStructuredTableJSONValues(_ values: [String], expectedCount: Int) -> [String]? {
        guard expectedCount >= 1 else { return nil }
        // Replace empty / whitespace-only values with "—"
        let filled = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "—" : $0 }
        if filled.count == expectedCount { return filled }
        if filled.count < expectedCount {
            return filled + Array(repeating: "—", count: expectedCount - filled.count)
        }

        // 過剰な場合: まずプレースホルダーを末尾から除去
        var adjusted = values
        while adjusted.count > expectedCount,
              let idx = adjusted.lastIndex(where: { isPlaceholderTableCell($0) }) {
            adjusted.remove(at: idx)
        }
        if adjusted.count == expectedCount { return adjusted }

        // 次にプレースホルダーを先頭から除去
        adjusted = values
        while adjusted.count > expectedCount,
              let idx = adjusted.firstIndex(where: { isPlaceholderTableCell($0) }) {
            adjusted.remove(at: idx)
        }
        if adjusted.count == expectedCount { return adjusted }

        // それでも多い場合は先頭 expectedCount 件に切り捨て（GPT の列過剰出力を許容）
        return Array(values.prefix(expectedCount))
    }

    static func parseStructuredTable(raw: String, title: String, lang: Lang) throws -> Inf6StructuredTable {
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        let tableHeading = (lang == .ja) ? "再構成表:" : "Reconstructed table:"
        let columnHeading = (lang == .ja) ? "列の意味:" : "Column meanings:"
        let rowHeading = (lang == .ja) ? "行の意味:" : "Row meanings:"

        func findHeading(_ heading: String, from start: Int = 0) -> Int? {
            for idx in start..<lines.count {
                if lines[idx].trimmingCharacters(in: .whitespacesAndNewlines) == heading {
                    return idx
                }
            }
            return nil
        }

        guard let tableIndex = findHeading(tableHeading),
              let columnIndex = findHeading(columnHeading, from: tableIndex + 1),
              let rowIndex = findHeading(rowHeading, from: columnIndex + 1)
        else {
            throw NSError(domain: "inf6.assets", code: -151, userInfo: [
                NSLocalizedDescriptionKey: "Structured table headings are missing."
            ])
        }

        let rawTableLines = lines[(tableIndex + 1)..<columnIndex]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let rawColumnLines = lines[(columnIndex + 1)..<rowIndex]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let rawRowLines = lines[(rowIndex + 1)..<lines.count]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let parsedTable = try parseMarkdownTable(rawTableLines)
        let expectedColumnLabels: [String] = {
            guard let first = parsedTable.columns.first else { return parsedTable.columns }
            if isGenericRowHeaderLabel(first) {
                return Array(parsedTable.columns.dropFirst())
            }
            return parsedTable.columns
        }()
        let columnMeanings = try parseTableMeanings(rawColumnLines, expectedLabels: expectedColumnLabels, sectionName: columnHeading)
        let rowMeanings = try parseTableMeanings(rawRowLines, expectedLabels: parsedTable.rows.map(\.label), sectionName: rowHeading)

        return Inf6StructuredTable(
            title: title,
            columns: parsedTable.columns,
            rows: parsedTable.rows,
            columnMeanings: columnMeanings,
            rowMeanings: rowMeanings
        )
    }

    static func parseMarkdownTable(_ lines: [String]) throws -> (columns: [String], rows: [Inf6StructuredTableRow]) {
        let tableLines = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.contains("|") }

        guard tableLines.count >= 3 else {
            throw NSError(domain: "inf6.assets", code: -152, userInfo: [
                NSLocalizedDescriptionKey: "Structured table requires header, separator, and at least one row."
            ])
        }

        let headerCells = parseMarkdownPipeRow(tableLines[0])
        guard headerCells.count >= 2 else {
            throw NSError(domain: "inf6.assets", code: -153, userInfo: [
                NSLocalizedDescriptionKey: "Structured table header has too few columns."
            ])
        }

        let separatorCells = parseMarkdownPipeRow(tableLines[1])
        guard separatorCells.count == headerCells.count,
              separatorCells.allSatisfy({ cell in
                  let normalized = cell.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
                  return normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              })
        else {
            throw NSError(domain: "inf6.assets", code: -154, userInfo: [
                NSLocalizedDescriptionKey: "Structured table separator row is invalid."
            ])
        }

        var rows: [Inf6StructuredTableRow] = []
        for rawLine in tableLines.dropFirst(2) {
            guard let cells = normalizeStructuredTableRowCells(parseMarkdownPipeRow(rawLine), expectedCount: headerCells.count) else {
                throw NSError(domain: "inf6.assets", code: -155, userInfo: [
                    NSLocalizedDescriptionKey: "Structured table row has mismatched column count. expected=\(headerCells.count) actual=\(parseMarkdownPipeRow(rawLine).count) row=\(rawLine)"
                ])
            }
            let rowLabel = cells[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rowLabel.isEmpty else {
                throw NSError(domain: "inf6.assets", code: -156, userInfo: [
                    NSLocalizedDescriptionKey: "Structured table row label is empty."
                ])
            }
            rows.append(Inf6StructuredTableRow(label: rowLabel, values: Array(cells.dropFirst())))
        }

        return (columns: headerCells, rows: rows)
    }

    static func normalizeStructuredTableRowCells(_ cells: [String], expectedCount: Int) -> [String]? {
        guard expectedCount >= 2 else { return nil }
        if cells.isEmpty { return nil }
        if cells.count == expectedCount { return cells }

        if cells.count < expectedCount {
            return cells + Array(repeating: "", count: expectedCount - cells.count)
        }

        let overflow = cells.count - expectedCount

        if overflow > 0,
           cells.prefix(overflow).allSatisfy({ isPlaceholderTableCell($0) }) {
            let dropped = Array(cells.dropFirst(overflow))
            if dropped.count == expectedCount { return dropped }
        }

        if overflow > 0 {
            var adjusted = cells
            var remainingOverflow = overflow
            var index = 1
            while remainingOverflow > 0 && index < adjusted.count {
                if isPlaceholderTableCell(adjusted[index]) {
                    adjusted.remove(at: index)
                    remainingOverflow -= 1
                    continue
                }
                index += 1
            }
            if remainingOverflow == 0 && adjusted.count == expectedCount {
                return adjusted
            }
        }

        if overflow > 0 {
            let prefixOverflowCells = Array(cells.prefix(overflow + 1))
            if let first = prefixOverflowCells.first?.trimmingCharacters(in: .whitespacesAndNewlines),
               !first.isEmpty,
               prefixOverflowCells.dropFirst().allSatisfy({ isPlaceholderTableCell($0) || isNumericLikeTableCell($0) }) {
                let rightAligned = [first] + Array(cells.suffix(expectedCount - 1))
                if rightAligned.count == expectedCount { return rightAligned }
            }
        }

        if overflow > 0 {
            let labelSource = Array(cells.prefix(overflow + 1))
            let nonPlaceholder = labelSource
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !isPlaceholderTableCell($0) }
            let mergedLabel = sanitizeMergedStructuredTableLabel(nonPlaceholder.isEmpty ? labelSource : nonPlaceholder)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let merged = [mergedLabel] + Array(cells.dropFirst(overflow + 1))
            if merged.count == expectedCount { return merged }
        }

        if expectedCount >= 2, cells.count > expectedCount {
            let rightAligned = [cells[0]] + Array(cells.suffix(expectedCount - 1))
            if rightAligned.count == expectedCount { return rightAligned }
        }

        return nil
    }

    static func parseMarkdownPipeRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("|") {
            trimmed.removeFirst()
        }
        if trimmed.hasSuffix("|") {
            trimmed.removeLast()
        }
        return trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func parseTableMeanings(
        _ lines: [String],
        expectedLabels: [String],
        sectionName: String
    ) throws -> [Inf6StructuredTableMeaning] {
        var meanings: [Inf6StructuredTableMeaning] = []
        meanings.reserveCapacity(lines.count)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("-") else {
                throw NSError(domain: "inf6.assets", code: -157, userInfo: [
                    NSLocalizedDescriptionKey: "\(sectionName) contains a non-bullet line."
                ])
            }
            let content = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let split = content.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
                throw NSError(domain: "inf6.assets", code: -158, userInfo: [
                    NSLocalizedDescriptionKey: "\(sectionName) bullet is missing a label separator."
                ])
            }
            let label = String(content[..<split]).trimmingCharacters(in: .whitespacesAndNewlines)
            let meaning = String(content[content.index(after: split)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, !meaning.isEmpty else {
                throw NSError(domain: "inf6.assets", code: -159, userInfo: [
                    NSLocalizedDescriptionKey: "\(sectionName) bullet has an empty label or meaning."
                ])
            }
            meanings.append(Inf6StructuredTableMeaning(label: label, meaning: meaning))
        }

        let actualVariants = Set(meanings.flatMap { meaningLabelVariants($0.label) }.filter { !$0.isEmpty })
        let missingRawLabels = expectedLabels.filter { raw in
            let variants = meaningLabelVariants(raw)
            return variants.isDisjoint(with: actualVariants)
        }
        guard missingRawLabels.isEmpty else {
            let missing = missingRawLabels.joined(separator: ", ")
            throw NSError(domain: "inf6.assets", code: -160, userInfo: [
                NSLocalizedDescriptionKey: "\(sectionName) is missing required labels: \(missing)"
            ])
        }

        return meanings
    }

    static func normalizeMeaningLabel(_ s: String) -> String {
        normalizeSpaces(s)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func meaningLabelVariants(_ s: String) -> Set<String> {
        let normalized = normalizeMeaningLabel(s)
        guard !normalized.isEmpty else { return [] }

        var variants: Set<String> = [normalized]

        if normalized.contains("|") {
            let left = normalized
                .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !left.isEmpty {
                variants.insert(left)
            }
        }

        let tokens = normalized.split(separator: " ").map(String.init)
        if let first = tokens.first {
            if first.hasPrefix("("), first.hasSuffix(")") {
                variants.insert(first)
            }
            if tokens.count > 1, tokens.dropFirst().allSatisfy({ isNumericLikeTableCell($0) || isPlaceholderTableCell($0) }) {
                variants.insert(first)
            }
        }

        return variants
    }

    static func isPlaceholderTableCell(_ s: String) -> Bool {
        let normalized = normalizeMeaningLabel(s)
        return normalized.isEmpty || ["-", "—", "–", "— —", "--", "---", "n/a", "na"].contains(normalized)
    }

    static func isNumericLikeTableCell(_ s: String) -> Bool {
        let normalized = normalizeMeaningLabel(s)
        guard !normalized.isEmpty else { return false }
        let stripped = normalized.unicodeScalars.filter { scalar in
            !CharacterSet(charactersIn: "0123456789.,·×x*/^+-–—%()[]{}<>~= ").contains(scalar)
        }
        return stripped.isEmpty && normalized.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
    }

    static func sanitizeMergedStructuredTableLabel(_ cells: [String]) -> String {
        let normalizedCells = cells
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = normalizedCells.first else { return "" }
        if first.hasPrefix("("), first.hasSuffix(")"),
           normalizedCells.dropFirst().allSatisfy({ isNumericLikeTableCell($0) || isPlaceholderTableCell($0) }) {
            return first
        }
        return normalizedCells.joined(separator: " ")
    }

    static func isGenericRowHeaderLabel(_ s: String) -> Bool {
        let normalized = normalizeMeaningLabel(s)
        return [
            "行", "行名", "項目", "項目名", "row", "rows", "row label", "row labels",
            "item", "items", "label", "labels"
        ].contains(normalized)
    }
}
#if canImport(PDFKit)
private extension Inf6AssetsAbstractPipeline {

    static func _generateEquationMiniPDFsIfNeeded(
        lang: Lang,
        pageIndex: Int,
        items: [Inf6AssetsItem]
    ) throws -> ([Inf6AssetsMiniPDFEntry], [UUID: String]) {
        let equations = items.filter { $0.kind == .equation }
        if equations.isEmpty { return ([], [:]) }

        let miniDir = try _equationMiniStorageDir()
        return try _generateEquationMiniPDFs(lang: lang, pageIndex: pageIndex, items: items, miniDir: miniDir)
    }

    static func _generateEquationMiniPDFs(
        lang: Lang,
        pageIndex: Int,
        items: [Inf6AssetsItem],
        miniDir: URL?
    ) throws -> ([Inf6AssetsMiniPDFEntry], [UUID: String]) {
        guard let miniDir else {
            throw NSError(domain: "inf6.assets", code: -120, userInfo: [
                NSLocalizedDescriptionKey: "Equation mini-PDF directory is unavailable."
            ])
        }

        var miniPDFs: [Inf6AssetsMiniPDFEntry] = []
        miniPDFs.reserveCapacity(items.count)

        var nameByID: [UUID: String] = [:]
        nameByID.reserveCapacity(items.count)

        for it in items where it.kind == .equation {
            guard let eq = it.equationText?.trimmingCharacters(in: .whitespacesAndNewlines), !eq.isEmpty else {
                throw NSError(domain: "inf6.assets", code: -126, userInfo: [
                    NSLocalizedDescriptionKey: "Detected equation item has no extractable equationText; cannot generate equation mini PDF."
                ])
            }

            let filename = "equation_mini_\(UUID().uuidString).pdf"
            let outURL = miniDir.appendingPathComponent(filename)

            try _writeMiniPDFText(
                outURL: outURL,
                title: (lang == .ja) ? "数式（抽出テキスト） p\(pageIndex + 1)" : "Equation (extracted text) p\(pageIndex + 1)",
                body: eq
            )

            miniPDFs.append(Inf6AssetsMiniPDFEntry(
                pageIndex: pageIndex,
                sourceItemID: it.id,
                kind: .equation,
                url: outURL
            ))

            nameByID[it.id] = filename
        }

        return (miniPDFs, nameByID)
    }

    static func buildPaperAbstractPrompt(
        lang: Lang,
        paperTitle: String,
        abstractEvidence: String,
        entityEvidence: String = ""
    ) -> String {
        let hasEntityEvidence = !entityEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch lang {
        case .ja:
            let entityBlock = hasEntityEvidence ? """


            【本文から抽出済みの中核図表・数式】
            論文の重要な根拠は、要旨だけでなくこれらの図・表・数式にあります。本文の主張と図表数式の具体的な対応を最優先にしてください。
            \(entityEvidence)
            """ : ""
            return """
            あなたは専門資格試験向けの査読論文解説者です。
            論文名は「\(paperTitle)」です。本文では論文名を再掲せず、正本の論文名は呼び出し側が付加します。
            以下の【引用テキスト】\(hasEntityEvidence ? "と【本文から抽出済みの中核図表・数式】" : "")だけを根拠に、論文の中核理論を学習・演習できる概要解説を作成してください。
            推測や一般論は禁止。引用内の語句・数値に対応づけて書いてください。

            【出力条件】
            - 日本語で書く
            - Markdown記号やコードブロックを使わず、次の4見出しをこの順序で必ず出力する
            - 「論文概要」: 背景、目的、手法、主要結果、結論を日本語で説明する。原論文の英文をそのまま引き写してはならない。原論文の Abstract を取得できた場合は、呼び出し側がこの節を「要旨」+ 原文の和訳へ差し替える
            - 「数学的導出」: 記号の定義から機械学習・深層学習で実際に使う式まで、微分・勾配・期待値・行列演算の導出を途中式付きで書く
            - 「実装」: TransformerまたはVision Transformerなら、図表の部品名・矢印・テンソルshapeを対応づけ、Self-Attentionが図のどこで何を計算するかと、入力から出力までの実利用手順を書く。Python項目では実際に動くPyTorchまたはTensorFlowコードを書く
            - 「実務上の検証」: 正則化なら目的関数、勾配、係数、学習時と推論時の挙動、適用限界を、その他の項目でもshape、損失、評価指標、失敗条件、使い分けを具体的に書く
            - 用語の羅列、理解点、ポイント、コア理論という見出しは出力してはいけない
            - 定型的な試験対策文、誤解や誤りの例を書いてはならない
            - 誤解や誤りの例を書いてはならない。理解すべき正しい内容を、それ自体として過不足なく説明することに集中する
            - 同じ図・表・数式から理解点を複数出してよい。中核を担う図表数式ほど、理解すべき点を集中して挙げること
            - ただし、複数出す場合は必ず異なる側面を扱うこと。構成要素の列挙を言い換えただけの理解点を並べてはならない
              悪い例:「encoderとdecoderを両方もつ / stacked self-attentionを用いる」と「encoderにstacked self-attentionを使う / decoderにも使う」は同じことの言い換えであり重複
              良い例: 同じ図1から「encoderとdecoderの役割の違い」「decoder側だけがマスク付き注意を使う理由」「encoder出力がdecoderのどこに入るか」を別々の理解点として挙げる
            - 側面の切り口: 各部の役割の違い、対になる要素の相違点、データの流れ、成立条件、パラメータを変えたときの帰結、なぜその設計なのか
            - 理解点同士は学習目標が重複しないようにする。問題数はこの理解点数から決定される
            - 理解点は日本語の文として完結させる。英語の節や句をそのまま貼り付けて助動詞だけ日本語にした文(例:「〜はeach position separately and identically appliedである」)は禁止する。専門用語、数式、固有名詞は原語のままでよい
            - 根拠には引用中の具体的な語句・数値・数式を書く。「根拠は式そのもの」「根拠は引用文」のような、何を指すか特定できない記述は禁止する
            - 数式・図・表への言及が引用内にある場合は、中核理論との対応と読み取るべき量を含める
            - 引用内にない数値、用語、実験条件、理論を追加しない
            \(entityBlock)

            【引用テキスト】
            \(abstractEvidence)
            """
        case .en:
            let entityBlock = hasEntityEvidence ? """


            [Core figures/tables/equations already extracted from the paper body]
            A paper's core theory usually lives in these figures/tables/equations, not in the abstract. Prioritize this list as the primary source for "Exercise focus" understanding points. For each item, judge whether it is something an E-Cert (JDLA) candidate must absolutely know, and verbalize it as an understanding point if so. Prefer covering these over generic background only found in the abstract.
            \(entityEvidence)
            """ : ""
            return """
            You explain peer-reviewed papers for professional certification study and exercises.
            The paper title is "\(paperTitle)". Do not repeat the title in the body; the caller adds the canonical title.
            Using ONLY the quoted evidence below\(hasEntityEvidence ? " and the extracted core figures/tables/equations" : ""), explain the paper's core theory for learning and assessment.
            No speculation; anchor every claim to words/numbers in the quote.

            [Output requirements]
            - 600–900 words
            - No Markdown symbols or code fences
            - Output these four headings in order: Paper overview, Mathematical derivation, Implementation, Practical validation
            - Paper overview: motivation, goal, method, key results, and conclusion
            - Mathematical derivation: define symbols and derive the equations used in machine learning/deep learning, showing intermediate steps
            - Implementation: explain the actual implementation, tensor shapes, data flow, and executable PyTorch or TensorFlow usage when applicable
            - Practical validation: explain metrics, shape checks, training/inference behavior, selection criteria, failure conditions, and limitations
            - Do not output terminology lists, understanding points, points, or a Core theory section
            - Do not write misconceptions or examples of errors. Concentrate on stating the correct content to be understood, completely and on its own terms
            - Explain different roles, paired-element differences, data flow, conditions, parameter effects, and design reasons in the relevant practical section
            - Evidence must cite the specific words, numbers, or expression from the quote. Contentless evidence such as "the equation itself" or "the quoted text" is forbidden
            - If the quote mentions equations, figures, or tables, explain their concrete role and which quantities must be read
            - For mathematics fundamentals, derive the equations used in machine learning/deep learning from defined symbols, showing the intermediate differentiation, expectation, or matrix steps
            - For regularization topics, state the objective, gradient effect, hyperparameter meaning, training/inference behavior, and practical limitation of L1/L2, weight decay, dropout, and early stopping when supported by the evidence
            - For Transformer or Vision Transformer topics, map figure/table labels, arrows, and tensor shapes to the evidence; state exactly where Self-Attention occurs, what it computes, and how to use the model from input embedding to output
            - Do not add numbers, terms, experimental conditions, or theories absent from the quote
            \(entityBlock)

            [Quoted evidence]
            \(abstractEvidence)
            """
        }
    }

    static func buildPageNotePrompt(lang: Lang, pageIndex: Int, pageEvidence: String, items: [Inf6AssetsItem]) -> String {
        let itemsBlock = formatItemsForPrompt(lang: lang, items: items)

        switch lang {
        case .ja:
            return """
            あなたは査読論文の『ページ単位』の図表・式の解説者です。
            以下の【このページのテキスト】と【検出アイテム一覧】だけを根拠に、
            このページ（p\(pageIndex + 1)）の 図・表・式 の解説を作成してください。
            推測や一般論は禁止。引用内の語句・数値に対応づけて書いてください。
            数式を書く場合は必ず LaTeX で $...$ / $$...$$ で囲んでください。

            【出力】
            - 見出しを必ず分ける：『図』『表』『式』
            - 各見出しの中で、このページに存在するものだけを番号つきで列挙し、各項目 160〜320字で解説
            - グラフの横軸、縦軸がどのような意味で何が単位かを明記する
            - 表の行と列の各要素の説明を列挙する
            - 検出アイテムに無いものは書かない（推測で追加しない）
            - もし該当が無い種別は、その見出しの直下に『（なし）』とだけ書く
            - 要旨（abstract）を書かない。ページノートのみ。

            【このページのテキスト】
            \(pageEvidence)

            ---
            \(itemsBlock)
            """
        case .en:
            return """
            You explain figures/tables/equations at the PAGE level for peer-reviewed papers.
            Using ONLY the page text and the provided detected items, explain assets found on this page (p\(pageIndex + 1)).
            No speculation; anchor every claim to the evidence.
            Any equations must be in LaTeX wrapped with $...$ / $$...$$.

            [Output]
            - Must separate sections: 'Figures', 'Tables', 'Equations'
            - Enumerate ONLY items that appear in the detected list (do not invent)
            - Clearly specify what the x-axis and y-axis represent and what units they use.
            - List and describe each element in the table’s rows and columns.
            - If none for a section, output '(none)'
            - Do NOT write the paper abstract here.

            [This page text]
            \(pageEvidence)

            ---
            \(itemsBlock)
            """
        }
    }

    static func formatItemsForPrompt(lang: Lang, items: [Inf6AssetsItem]) -> String {
        func kindName(_ k: Inf6AssetsKind) -> String {
            switch (lang, k) {
            case (.ja, .figure): return "図"
            case (.ja, .table): return "表"
            case (.ja, .equation): return "式"
            case (.en, .figure): return "Figure"
            case (.en, .table): return "Table"
            case (.en, .equation): return "Equation"
            }
        }

        var lines: [String] = []
        lines.append((lang == .ja) ? "【検出アイテム一覧（Figure/Table/Equation）】" : "[Detected items (Figure/Table/Equation)]")

        for (i, it) in items.enumerated() {
            let head = "\(i + 1). \(kindName(it.kind))  p\(it.pageIndex + 1) — \(it.titleLine)".replacingOccurrences(of: "\n", with: " ")
            lines.append(head)

            if let eq = it.equationText, !eq.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("   - equationText: \(eq)")
            }
            if !it.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("   - evidence: \(it.evidence)")
            }
        }

        return lines.joined(separator: "\n")
    }

    static func emptyPageNote(lang: Lang) -> String {
        switch lang {
        case .ja:
            return """
            図
            （なし）

            表
            （なし）

            式
            （なし）
            """
        case .en:
            return """
            Figures
            (none)

            Tables
            (none)

            Equations
            (none)
            """
        }
    }

    /// Thin wrapper used by the AI-driven pipeline.
    static func sanitizePageNote(_ s: String) -> String {
        stripAccidentalAbstractSection(s)
    }

    /// Defensive cleanup: if the model accidentally outputs an abstract section, strip it.
    /// We keep it simple and conservative.
    static func stripAccidentalAbstractSection(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return trimmed }

        // Common accidental headings
        let keys = [
            "要旨", "要旨", "Abstract", "Abstract",
            "【要旨】", "[Abstract]"
        ]

        for k in keys {
            if let r = trimmed.range(of: k) {
                // If it contains an abstract heading, drop everything from that heading until the next '## 図/表/式' or '## Figures/Tables/Equations'.
                let after = trimmed[r.upperBound..<trimmed.endIndex]

                let nextKeys = ["図", "表", "式", "Figures", "Tables", "Equations"]
                var cut: String.Index? = nil
                for nk in nextKeys {
                    if let rr = after.range(of: nk) {
                        if cut == nil || rr.lowerBound < cut! { cut = rr.lowerBound }
                    }
                }

                if let cut {
                    let rest = after[cut..<after.endIndex]
                    return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    // No page sections found; return original (we can't safely sanitize)
                    return trimmed
                }
            }
        }

        return trimmed
    }
}

// MARK: - Extraction (best-effort heuristics)

extension Inf6AssetsAbstractPipeline {

    static func extractLikelyAbstractSnippet(doc: PDFDocument) -> String {
        let maxPages = min(4, doc.pageCount)
        var raw = ""
        for i in 0..<maxPages {
            raw += "\n" + (doc.page(at: i)?.string ?? "")
        }
        let text = normalizeSpaces(raw)
        guard !text.isEmpty else { return "" }

        func slice(from startKeys: [String], until endKeys: [String]) -> String? {
            var startRange: Range<String.Index>? = nil
            for k in startKeys {
                if let r = text.range(of: k, options: [.caseInsensitive]) {
                    startRange = r
                    break
                }
            }
            guard let startRange else { return nil }

            let after = startRange.upperBound
            var endIndex: String.Index = text.endIndex
            for k in endKeys {
                if let r = text.range(of: k, options: [.caseInsensitive], range: after..<text.endIndex) {
                    if r.lowerBound < endIndex { endIndex = r.lowerBound }
                }
            }

            let body = text[after..<endIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":：-–— "))

            let s = String(body)
            return s.isEmpty ? nil : s
        }

        if let s = slice(from: ["Abstract"], until: ["Introduction", "1 Introduction", "1. Introduction"]) {
            return String(s.prefix(4500))
        }
        if let s = slice(from: ["概要", "要旨"], until: ["はじめに", "序論", "1 はじめに", "1. はじめに"]) {
            return String(s.prefix(4500))
        }

        // Fallback: first ~2 pages
        var fb = ""
        let pages = min(2, doc.pageCount)
        for i in 0..<pages {
            fb += "\n" + (doc.page(at: i)?.string ?? "")
        }
        return String(normalizeSpaces(fb).trimmingCharacters(in: .whitespacesAndNewlines).prefix(4500))
    }

    static func detectItemsForPage(pageIndex: Int, pageText: String) -> [Inf6AssetsItem] {
        let lines = splitToLines(pageText)
        if lines.isEmpty { return [] }

        var figures: [Inf6AssetsItem] = []
        var tables: [Inf6AssetsItem] = []

        // Duplicate guard (per page): PDF text extraction can repeat the same caption blocks.
        // We dedupe by (kind + normalized titleLine) while preserving first-seen order.
        var seen: Set<String> = []
        seen.reserveCapacity(24)

        func dedupKey(kind: Inf6AssetsKind, titleLine: String) -> String {
            // Normalize without introducing any fallback behavior.
            let t = normalizeSpaces(titleLine)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return kind.rawValue + "|" + t
        }

        func canAppend(kind: Inf6AssetsKind, titleLine: String) -> Bool {
            let k = dedupKey(kind: kind, titleLine: titleLine)
            if seen.contains(k) { return false }
            seen.insert(k)
            return true
        }

        // Captions (Figure/Table)
        for idx in 0..<lines.count {
            let line = lines[idx]
            let linePlusNext: String = {
                guard (idx + 1) < lines.count else { return line }
                return line + " " + lines[idx + 1]
            }()

            // Figure caption detection: first try the current line; if not found, try a joined line (handles PDF line-break splits like "Figure" + "7:").
            if let start = figureCaptionStartUTF16(line) {
                    let titleLine = extractCaptionTitle(from: line, startUTF16: start, maxChars: 220)
                    if canAppend(kind: .figure, titleLine: titleLine) {
                        figures.append(Inf6AssetsItem(
                            kind: .figure,
                            pageIndex: pageIndex,
                            titleLine: titleLine,
                            evidence: nearbyEvidence(lines: lines, center: idx, radius: 3, maxChars: 700),
                            equationText: nil
                        ))
                    }
            } else if let start = figureCaptionStartUTF16(linePlusNext) {
                    let titleLine = extractCaptionTitle(from: linePlusNext, startUTF16: start, maxChars: 220)
                    if canAppend(kind: .figure, titleLine: titleLine) {
                        figures.append(Inf6AssetsItem(
                            kind: .figure,
                            pageIndex: pageIndex,
                            titleLine: titleLine,
                            evidence: nearbyEvidence(lines: lines, center: idx, radius: 3, maxChars: 700),
                            equationText: nil
                        ))
                    }
                }
            // Table caption detection: first try the current line; if not found, try a joined line (handles PDF line-break splits like "Table" + "7:").
            if let start = tableCaptionStartUTF16(line) {
                    let titleLine = extractCaptionTitle(from: line, startUTF16: start, maxChars: 220)
                    if canAppend(kind: .table, titleLine: titleLine) {
                        tables.append(Inf6AssetsItem(
                            kind: .table,
                            pageIndex: pageIndex,
                            titleLine: titleLine,
                            evidence: nearbyEvidence(lines: lines, center: idx, radius: 3, maxChars: 700),
                            equationText: nil
                        ))
                    }
            } else if let start = tableCaptionStartUTF16(linePlusNext) {
                    let titleLine = extractCaptionTitle(from: linePlusNext, startUTF16: start, maxChars: 220)
                    if canAppend(kind: .table, titleLine: titleLine) {
                        tables.append(Inf6AssetsItem(
                            kind: .table,
                            pageIndex: pageIndex,
                            titleLine: titleLine,
                            evidence: nearbyEvidence(lines: lines, center: idx, radius: 3, maxChars: 700),
                            equationText: nil
                        ))
                    }
            }
        }

        // Stable ordering: figure -> table, each in reading order
        return (figures + tables)
    }

    #if canImport(PDFKit)
    /// Document-level 2-column detection.
    /// Samples first 5–10 pages. For each sampled page, divides the center vertical
    /// strip (gutter region) into N horizontal slices and counts what fraction of
    /// slices contain text. If the aggregate "text-present in center" ratio is
    /// ≤ 50%, the document is judged as 2-column.
    static func detectIsTwoColumnDocument(doc: PDFDocument) -> Bool {
        let totalPages = doc.pageCount
        guard totalPages > 0 else { return false }
        let sampleCount = min(10, totalPages)
        let sliceCount = 20            // vertical slices per page
        let centerStripWFrac: CGFloat = 0.04
        var totalSlices = 0
        var slicesWithText = 0

        for i in 0..<sampleCount {
            guard let p = doc.page(at: i) else { continue }
            let b = p.bounds(for: .cropBox)
            guard b.width > 0, b.height > 0 else { continue }
            let stripW = b.width * centerStripWFrac
            let stripX = b.midX - stripW / 2
            let sliceH = b.height / CGFloat(sliceCount)
            for s in 0..<sliceCount {
                let r = CGRect(
                    x: stripX,
                    y: b.minY + sliceH * CGFloat(s),
                    width: stripW,
                    height: sliceH
                )
                let t = (p.selection(for: r)?.string ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                totalSlices += 1
                if !t.isEmpty {
                    slicesWithText += 1
                }
            }
        }
        guard totalSlices > 0 else { return false }
        let textRate = Double(slicesWithText) / Double(totalSlices)
        return textRate <= 0.50
    }

    static func detectItemsForPDFPage(
        pageIndex: Int,
        page: PDFPage,
        pageText: String,
        isTwoColumnDocument: Bool = false
    ) throws -> [Inf6AssetsItem] {
        let pageBounds = page.bounds(for: .cropBox)
        let normalizedPageText = normalizeSpaces(pageText)
        guard pageBounds.width > 0, pageBounds.height > 0 else {
            throw NSError(domain: "inf6.assets", code: -170, userInfo: [
                NSLocalizedDescriptionKey: "Invalid PDF page geometry at page \(pageIndex + 1)."
            ])
        }

        // Build region texts based on document-level 2-column judgment.
        // (See detectIsTwoColumnDocument() — sampled from first 5–10 pages.)
        let regionTexts: [String]
        if isTwoColumnDocument {
            let gutterW = pageBounds.width * 0.025
            let halfWidth = pageBounds.width / 2
            let leftRect = CGRect(
                x: pageBounds.minX,
                y: pageBounds.minY,
                width: max(1, halfWidth - gutterW),
                height: pageBounds.height
            )
            let rightRect = CGRect(
                x: pageBounds.minX + halfWidth + gutterW,
                y: pageBounds.minY,
                width: max(1, halfWidth - gutterW),
                height: pageBounds.height
            )
            let leftText = normalizeSpaces(page.selection(for: leftRect)?.string ?? "")
            let rightText = normalizeSpaces(page.selection(for: rightRect)?.string ?? "")
            regionTexts = [leftText, rightText]
        } else {
            regionTexts = [normalizedPageText]
        }

        var merged: [Inf6AssetsItem] = []
        var seen = Set<String>()
        seen.reserveCapacity(24)

        func key(_ item: Inf6AssetsItem) -> String {
            // Dedup by Figure/Table number when possible, so the same table
            // detected from left/right column halves doesn't appear twice.
            let title = normalizeSpaces(item.titleLine)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            // Extract "table N" or "figure N" (also "fig N" / "tab N" / "表N" / "図N")
            let patterns = [
                #"^(?:table|tab\.?)\s*(\d+)"#,
                #"^(?:figure|fig\.?)\s*(\d+)"#,
                #"^表\s*(\d+)"#,
                #"^図\s*(\d+)"#
            ]
            for pat in patterns {
                if let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]),
                   let m = re.firstMatch(in: title, options: [], range: NSRange(title.startIndex..., in: title)),
                   m.numberOfRanges >= 2,
                   let r = Range(m.range(at: 1), in: title) {
                    let num = String(title[r])
                    return item.kind.rawValue + "|#" + num
                }
            }
            return item.kind.rawValue + "|" + title
        }

        for regionText in regionTexts {
            let trimmed = regionText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            for item in detectItemsForPage(pageIndex: pageIndex, pageText: trimmed) {
                let k = key(item)
                guard seen.insert(k).inserted else { continue }
                merged.append(item)
            }
        }

        return merged
    }
    #endif

    static func isFigureCaption(_ s: String) -> Bool {
        return figureCaptionStartUTF16(s) != nil
    }

    static func isTableCaption(_ s: String) -> Bool {
        return tableCaptionStartUTF16(s) != nil
    }

    static func figureCaptionStartUTF16(_ s: String) -> Int? {
        return captionStartUTF16(s, kind: .figure)
    }

    static func tableCaptionStartUTF16(_ s: String) -> Int? {
        return captionStartUTF16(s, kind: .table)
    }

    static func captionStartUTF16(_ s: String, kind: Inf6AssetsKind) -> Int? {
        // Normalize a few common PDF whitespace variants without changing string length.
        let normalized = s
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{2007}", with: " ")

        let pattern: String
        switch kind {
        case .figure:
            // Match captions like "Figure 1:", "Fig.1:", "Fig 1:", "図1：",
            // and also appendix-style numbering like "Figure A.1" / "Figure A1".
            // Accept roman numerals and optional letter prefixes.
            pattern = "^\\s*(figure|fig\\.?|図)\\s*(?:[a-z]\\s*(?:\\.|\\-)?\\s*)?(?:\\d{1,3}|[ivxlcdm]{1,8})(?:\\s*(?:\\.|\\-)?\\s*\\d{1,3})?\\s*(?:[:：\\.\\-–—\\|]|$)"
        case .table:
            // Match captions like "Table 1:", "Tab.1:", "Tab 1:", "表1：",
            // and also appendix-style numbering like "Table A.1" / "Table A1".
            // Accept roman numerals and optional letter prefixes.
            pattern = "^\\s*(table|tab\\.?|表)\\s*(?:[a-z]\\s*(?:\\.|\\-)?\\s*)?(?:\\d{1,3}|[ivxlcdm]{1,8})(?:\\s*(?:\\.|\\-)?\\s*\\d{1,3})?\\s*(?:[:：\\.\\-–—\\|]|$)"
        case .equation:
            return nil
        }

        do {
            let re = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let ns = normalized as NSString
            let full = NSRange(location: 0, length: ns.length)
            if let m = re.firstMatch(in: normalized, options: [], range: full) {
                let k = m.range(at: 1)
                guard k.location != NSNotFound else { return nil }
                return k.location
            }

            let unpunctuatedCaptionPattern: String
            switch kind {
            case .figure:
                unpunctuatedCaptionPattern = "^\\s*(figure|fig\\.?|図)\\s*(?:[a-z]\\s*(?:\\.|\\-)?\\s*)?(?:\\d{1,3}|[ivxlcdm]{1,8})(?:\\s*(?:\\.|\\-)?\\s*\\d{1,3})?\\s+(?=\\S)"
            case .table:
                unpunctuatedCaptionPattern = "^\\s*(table|tab\\.?|表)\\s*(?:[a-z]\\s*(?:\\.|\\-)?\\s*)?(?:\\d{1,3}|[ivxlcdm]{1,8})(?:\\s*(?:\\.|\\-)?\\s*\\d{1,3})?\\s+(?=\\S)"
            case .equation:
                return nil
            }
            let unpunctuatedRE = try NSRegularExpression(pattern: unpunctuatedCaptionPattern, options: [.caseInsensitive])
            guard let m = unpunctuatedRE.firstMatch(in: normalized, options: [], range: full) else { return nil }
            let k = m.range(at: 1)
            guard k.location != NSNotFound else { return nil }
            return k.location
        } catch {
            // If the regex cannot be compiled, treat as no match.
            return nil
        }
    }

    static func extractCaptionTitle(from s: String, startUTF16: Int, maxChars: Int) -> String {
        let ns = s as NSString
        let start = max(0, min(startUTF16, ns.length))
        let rest = ns.substring(from: start)
        let trimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maxChars))
    }


    static func nearbyEvidence(lines: [String], center: Int, radius: Int, maxChars: Int) -> String {
        let lo = max(0, center - radius)
        let hi = min(lines.count - 1, center + radius)
        let chunk = lines[lo...hi].joined(separator: "\n")
        return String(chunk.prefix(maxChars))
    }

    static func splitToLines(_ text: String) -> [String] {
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func normalizeSpaces(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\t", with: " ")
        while out.contains("  ") {
            out = out.replacingOccurrences(of: "  ", with: " ")
        }
        return out
    }
    static func _equationMiniStorageDir() throws -> URL {
        let fm = FileManager.default
        let dir = Inf6DataRoot.url().appendingPathComponent("inf6_equation_mini_pdfs", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw NSError(domain: "inf6.assets", code: -122, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create equation mini-PDF directory: \(error.localizedDescription)"
            ])
        }
        return dir
    }

    static func _writeMiniPDFText(outURL: URL, title: String, body: String) throws {
        #if canImport(UIKit)
        let raw = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw NSError(domain: "inf6.assets", code: -126, userInfo: [
                NSLocalizedDescriptionKey: "Equation body text is empty."
            ])
        }

        let pageWidth: CGFloat = 595
        let margin: CGFloat = 24
        let contentWidth = pageWidth - margin * 2

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: UIColor.label
        ]
        let titleSize = (title as NSString).size(withAttributes: titleAttrs)

        let bodyAttrs: [NSAttributedString.Key: Any] = {
            let p = NSMutableParagraphStyle()
            p.lineBreakMode = .byWordWrapping
            p.alignment = .left
            return [
                .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: UIColor.label,
                .paragraphStyle: p
            ]
        }()

        let bodyMaxSize = CGSize(width: contentWidth, height: .greatestFiniteMagnitude)
        let bodyBounds = (raw as NSString).boundingRect(
            with: bodyMaxSize,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: bodyAttrs,
            context: nil
        ).integral

        let minHeight: CGFloat = 240
        let maxHeight: CGFloat = 1400
        let neededHeight = margin + titleSize.height + 12 + bodyBounds.height + margin
        let pageHeight = max(minHeight, min(maxHeight, neededHeight))
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        do {
            try renderer.writePDF(to: outURL, withActions: { ctx in
                ctx.beginPage()

                (title as NSString).draw(at: CGPoint(x: margin, y: margin), withAttributes: titleAttrs)

                let bodyRect = CGRect(
                    x: margin,
                    y: margin + titleSize.height + 12,
                    width: contentWidth,
                    height: pageRect.height - (margin * 2 + titleSize.height + 12)
                )

                (raw as NSString).draw(
                    with: bodyRect,
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: bodyAttrs,
                    context: nil
                )
            })
        } catch {
            throw NSError(domain: "inf6.assets", code: -127, userInfo: [
                NSLocalizedDescriptionKey: "Failed to write equation mini PDF: \(error.localizedDescription)"
            ])
        }
        #else
        throw NSError(domain: "inf6.assets", code: -125, userInfo: [
            NSLocalizedDescriptionKey: "UIKit is unavailable. Equation mini PDF generation requires UIKit (UIGraphicsPDFRenderer)."
        ])
        #endif
    }
}
#endif
