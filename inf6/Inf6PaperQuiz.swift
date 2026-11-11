//
//  Inf6PaperQuiz.swift
//  inf6
//
//  Created by decopin on 2026/01/06.
//

import Foundation
import SwiftUI

// MARK: - Public source types (used by InlinePDFPagesView patch)

public struct Inf6PaperQuizMathCardSource: Hashable, Codable, Sendable {
    public let cardID: String
    public let explanation: String

    public init(cardID: String, explanation: String) {
        self.cardID = cardID
        self.explanation = explanation
    }
}

public enum Inf6PaperQuizCoverageTargetKind: String, Codable, Sendable {
    case abstract
    case pageNote = "page_note"
    case mathCard = "math_card"
    case figure
    case table
    case equation
    case code
}

public struct Inf6PaperQuizCoverageTarget: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var kind: Inf6PaperQuizCoverageTargetKind
    public var pageIndex: Int?
    public var title: String
    public var evidenceText: String

    public init(
        id: String,
        kind: Inf6PaperQuizCoverageTargetKind,
        pageIndex: Int?,
        title: String,
        evidenceText: String
    ) {
        self.id = id
        self.kind = kind
        self.pageIndex = pageIndex
        self.title = title
        self.evidenceText = evidenceText
    }
}

// MARK: - Quiz model

public struct Inf6PaperQuiz: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: TimeInterval

    /// Stable paper identity (caller-provided). e.g. PDF filename key
    public var paperKey: String
    public var paperTitle: String

    /// "ja" / "en"
    public var lang: String

    public var questions: [Inf6PaperQuizQuestion]
    public var coverageTargets: [Inf6PaperQuizCoverageTarget]?

    public init(
        id: UUID = UUID(),
        createdAt: TimeInterval = Date().timeIntervalSince1970,
        paperKey: String,
        paperTitle: String,
        lang: String,
        questions: [Inf6PaperQuizQuestion],
        coverageTargets: [Inf6PaperQuizCoverageTarget]? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.paperKey = paperKey
        self.paperTitle = paperTitle
        self.lang = lang
        self.questions = questions
        self.coverageTargets = coverageTargets
    }
}

public struct Inf6PaperQuizCodePracticeOptions: Hashable, Sendable {
    public let framework: String
    public let frameworks: [String]
    public let syllabusTitle: String
    public let questionCount: Int

    public init(framework: String = "PyTorch", syllabusTitle: String, questionCount: Int = 5) {
        let normalized = framework.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "PyTorch"
            : framework.trimmingCharacters(in: .whitespacesAndNewlines)
        self.framework = normalized
        self.frameworks = [normalized]
        self.syllabusTitle = syllabusTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.questionCount = min(max(questionCount, 1), 8)
    }

    public init(frameworks: [String], syllabusTitle: String, questionCount: Int = 5) {
        var seen = Set<String>()
        let normalized = frameworks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0.lowercased()).inserted }
        let resolved = normalized.isEmpty ? ["PyTorch"] : normalized
        self.framework = resolved[0]
        self.frameworks = resolved
        self.syllabusTitle = syllabusTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.questionCount = min(max(questionCount, 1), 8)
    }
}

public struct Inf6PaperQuizQuestion: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: TimeInterval

    /// Optional: where this question is grounded (0-based page index).
    public var pageIndex: Int?

    /// "equation" / "figure" / "table" / "code"
    /// 論文演習では図表数式を主根拠とし、実装演習では Python code を主根拠にする。
    public var kind: String

    /// "regular" or "py". This is the exercise track; `kind` remains the evidence kind.
    public var exerciseType: String?

    /// Stored track classification, normalized for records written before `exerciseType` existed.
    /// `kind` is evidence classification and must not be used to choose the exercise track.
    public var normalizedExerciseType: String {
        if let exerciseType {
            return exerciseType.lowercased() == "py" ? "py" : "regular"
        }
        return kind.lowercased() == "code" ? "py" : "regular"
    }

    public var question: String
    public var choices: [String]

    /// 0..<choices.count
    public var correctIndex: Int

    /// Rationale grounded in provided notes only.
    public var explanation: String
    public var coverageTargetIDs: [String]?

    // MARK: - MMA 正本契約への橋渡し（いずれも optional、既存 JSON 互換維持）

    /// MMA 8 問題型。未指定の既存レコードは nil のまま。
    /// 正本仕様: Design.md
    public var questionType: Inf6QuestionType?

    /// この問題が確認する `Inf6KnowledgeAtom.id` 群。
    public var knowledgeAtomIDs: [String]?

    /// この問題が確認する `Inf6KnowledgeEdge.id` 群。
    public var knowledgeEdgeIDs: [String]?

    /// 公式根拠 URL 群（Learn URL / シラバス PDF 位置など）。
    public var sourceURLs: [String]?

    /// 図・表・数式の画像パス（entity_images/ 内の相対パスまたは絶対パス）
    public var entityImagePath: String?
    public var docEntityID: UUID?
    public var entityReferenceIDs: [UUID]?

    public init(
        id: UUID = UUID(),
        createdAt: TimeInterval = Date().timeIntervalSince1970,
        pageIndex: Int?,
        kind: String,
        exerciseType: String? = nil,
        question: String,
        choices: [String],
        correctIndex: Int,
        explanation: String,
        coverageTargetIDs: [String]? = nil,
        questionType: Inf6QuestionType? = nil,
        knowledgeAtomIDs: [String]? = nil,
        knowledgeEdgeIDs: [String]? = nil,
        sourceURLs: [String]? = nil,
        entityImagePath: String? = nil,
        docEntityID: UUID? = nil,
        entityReferenceIDs: [UUID]? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.pageIndex = pageIndex
        self.kind = kind
        self.exerciseType = exerciseType ?? (kind.lowercased() == "code" ? "py" : "regular")
        self.question = question
        self.choices = choices
        self.correctIndex = correctIndex
        self.explanation = explanation
        self.coverageTargetIDs = coverageTargetIDs
        self.questionType = questionType
        self.knowledgeAtomIDs = knowledgeAtomIDs
        self.knowledgeEdgeIDs = knowledgeEdgeIDs
        self.sourceURLs = sourceURLs
        self.entityImagePath = entityImagePath
        self.docEntityID = docEntityID
        self.entityReferenceIDs = entityReferenceIDs
    }
}

// MARK: - MMA 契約へのアダプタ

extension Inf6PaperQuizCoverageTarget {
    /// 既存 PDF 由来 CoverageTarget を MMA 正本 `Inf6CoverageTarget` に昇格する。
    ///
    /// 既存の `page_note` / `math_card` / `abstract` は、
    /// まだ `Inf6KnowledgeAtom` 化されていない `proto-atom` として `.atom` kind に写像する。
    /// `refID` は自身の `id` を流用し、将来原子 ID に差し替え可能にする。
    public func toCanonicalCoverageTarget() -> Inf6CoverageTarget {
        Inf6CoverageTarget(
            id: self.id,
            kind: .atom,
            refID: self.id,
            label: self.title
        )
    }
}

extension Inf6PaperQuizQuestion {
    /// 既存論文クイズ問題を MMA 正本 `Inf6GeneratedQuestion` に変換する。
    /// 非破壊: 既存フィールドは保持し、足りないものだけ補う。
    public func toGeneratedQuestion(
        defaultQuestionType: Inf6QuestionType = .definition,
        extraSourceURLs: [String] = []
    ) -> Inf6GeneratedQuestion {
        let ctIDs = coverageTargetIDs ?? []
        let atomIDs = knowledgeAtomIDs ?? []
        let edgeIDs = knowledgeEdgeIDs ?? []
        let urls = (sourceURLs ?? []) + extraSourceURLs
        return Inf6GeneratedQuestion(
            id: id.uuidString,
            createdAt: createdAt,
            prompt: question,
            choices: choices,
            correctIndex: correctIndex,
            explanation: explanation,
            questionType: questionType ?? defaultQuestionType,
            coverageTargetIDs: ctIDs,
            sourceURLs: urls,
            knowledgeAtomIDs: atomIDs,
            knowledgeEdgeIDs: edgeIDs
        )
    }
}

extension Inf6PaperQuiz {
    /// 論文クイズ全体を MMA 監査用の `(targets, questions)` に変換する。
    public func toMMABundle(
        defaultQuestionType: Inf6QuestionType = .definition
    ) -> (targets: [Inf6CoverageTarget], questions: [Inf6GeneratedQuestion]) {
        let targets = (coverageTargets ?? []).map { $0.toCanonicalCoverageTarget() }
        let questions = questions.map { $0.toGeneratedQuestion(defaultQuestionType: defaultQuestionType) }
        return (targets, questions)
    }
}

// MARK: - Errors

public enum Inf6PaperQuizError: Error, LocalizedError {
    case storageUnavailable(String)
    case io(String)
    case decode(String)
    case invalidSource(String)
    case modelResponseNotJSON(String)
    case modelJSONDecodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .storageUnavailable(let s): return s
        case .io(let s): return s
        case .decode(let s): return s
        case .invalidSource(let s): return s
        case .modelResponseNotJSON(let s): return s
        case .modelJSONDecodeFailed(let s): return s
        }
    }
}

extension Inf6PaperQuiz {
    public func validateVisualEvidenceContract() throws {
        let visualKinds = Set(["figure", "table", "equation"])
        let targetsByID = Dictionary(uniqueKeysWithValues: (coverageTargets ?? []).map { ($0.id, $0) })
        for (index, question) in questions.enumerated() {
            if question.kind.lowercased() == "code" {
                let targetIDs = question.coverageTargetIDs ?? []
                let codeIDs = targetIDs.filter { $0.hasPrefix("code-practice-") }
                guard codeIDs.count == 1,
                      let codeTarget = targetsByID[codeIDs[0]],
                      codeTarget.kind == .code,
                      !question.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !question.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      question.explanationSatisfiesPythonImplementationContract(targetID: codeIDs[0]),
                      question.docEntityID == nil,
                      question.entityImagePath == nil else {
                    throw Inf6PaperQuizError.decode("[Quiz] Q\(index + 1) violates the code practice contract")
                }
                continue
            }
            guard visualKinds.contains(question.kind.lowercased()) else {
                throw Inf6PaperQuizError.decode("[Quiz] Q\(index + 1) is not grounded in a figure/table/equation/code")
            }
            let targetIDs = question.coverageTargetIDs ?? []
            let understandingIDs = targetIDs.filter { $0.hasPrefix("understanding-point-") }
            let entityIDs = targetIDs.filter { $0.hasPrefix("doc-entity:") }
            guard understandingIDs.count == 1, entityIDs.count == 1,
                  let understandingTarget = targetsByID[understandingIDs[0]],
                  let entityTarget = targetsByID[entityIDs[0]],
                  entityTarget.kind.rawValue == question.kind.lowercased(),
                  question.docEntityID?.uuidString.lowercased() == String(entityIDs[0].dropFirst("doc-entity:".count)),
                  let imagePath = question.entityImagePath,
                  !imagePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Inf6PaperQuizError.decode("[Quiz] Q\(index + 1) violates the visual evidence binding contract")
            }
            if !Self.visualEvidenceAligns(question: question, understandingTarget: understandingTarget, entityTarget: entityTarget) {
                // docEntityID・kind・page・imagePath の結合が正しければ保存を拒否しない。
                // 図中ラベルの文字一致は、日本語解説・OCR揺れ・数式表記で偽陰性になるため、
                // 問題全体を破棄する根拠にはしない。画像と根拠の対応は上記の結合契約で判定する。
                NSLog("[Quiz] Q%d visual text alignment is weak; entity binding is authoritative", index + 1)
            }
        }
    }

    private static func visualEvidenceAligns(
        question: Inf6PaperQuizQuestion,
        understandingTarget: Inf6PaperQuizCoverageTarget,
        entityTarget: Inf6PaperQuizCoverageTarget
    ) -> Bool {
        guard entityTarget.kind == .figure else { return true }
        guard entityTarget.evidenceText.localizedCaseInsensitiveContains("DIAGRAM:") else { return true }
        let entityTerms = visualAlignmentTerms(from: entityTarget.evidenceText)
        guard !entityTerms.isEmpty else { return false }

        let narrative = [
            question.question,
            question.explanation,
            understandingTarget.evidenceText
        ]
            .joined(separator: "\n")
            .lowercased()
        let matched = entityTerms.filter { narrative.localizedCaseInsensitiveContains($0) }
        let required = min(2, max(1, entityTerms.count / 3))
        return matched.count >= required
    }

    private static func visualAlignmentTerms(from text: String) -> Set<String> {
        let lines = text.components(separatedBy: .newlines)
        var fragments: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)

            if key == "nodes" {
                for node in value.components(separatedBy: "|") {
                    for part in node.components(separatedBy: ";") {
                        let kv = part.components(separatedBy: "=")
                        guard kv.count == 2 else { continue }
                        if kv[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "label" {
                            fragments.append(kv[1])
                        }
                    }
                }
            } else if ["layers", "annotation", "contrast"].contains(key) {
                fragments.append(value)
            }
        }

        return Set(
            fragments
                .flatMap { visualTokens(in: $0) }
                .filter { token in
                    token.count >= 2 &&
                    !["role", "input", "output", "step", "score", "label", "id", "yes", "no"].contains(token)
                }
                .prefix(12)
        )
    }

    private static func visualTokens(in text: String) -> [String] {
        let separators = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "_"))
            .inverted
        return text
            .lowercased()
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

extension Inf6PaperQuizQuestion {
    public func explanationSatisfiesPythonImplementationContract(targetID: String? = nil) -> Bool {
        guard kind.lowercased() == "code" else { return true }
        let ids = targetID.map { [$0] } ?? (coverageTargetIDs ?? [])
        guard let codeID = ids.first(where: { $0.hasPrefix("code-practice-") })?.lowercased() else { return false }
        let codeBlocks = explanation.extractMarkdownCodeBlocks()
        guard !codeBlocks.isEmpty else { return false }
        let code = codeBlocks.joined(separator: "\n").lowercased()
        let prose = explanation.removingMarkdownCodeBlocks().lowercased()
        guard explanation.pythonCodePracticeProseIsConcrete else { return false }
        if (code + "\n" + prose).mentionsAnchorProposalPractice {
            guard prose.contains("従来")
                    || prose.contains("置き換")
                    || prose.contains("候補")
                    || prose.contains("traditional")
                    || prose.contains("conventional")
                    || prose.contains("replace") else {
                return false
            }
        }
        if code.contains("conv2d") && (code.contains(", 4") || code.contains("filters=4")) {
            guard prose.contains("4"),
                  prose.contains("距離")
                    || prose.contains("l,t,r,b")
                    || prose.contains("l, t, r, b")
                    || prose.contains("left")
                    || prose.contains("right")
                    || prose.contains("top")
                    || prose.contains("bottom") else {
                return false
            }
        }
        if codeID.hasPrefix("code-practice-pytorch-") {
            return [
                "torch",
                "nn.",
                "dataloader",
                ".backward(",
                ".step(",
                ".train(",
                ".eval(",
                ".to("
            ].contains { code.contains($0) }
        }
        if codeID.hasPrefix("code-practice-tensorflow-") {
            return [
                "tf.",
                "keras",
                "gradienttape",
                "training="
            ].contains { code.contains($0) }
        }
        return false
    }
}

private extension String {
    var pythonCodePracticeProseIsConcrete: Bool {
        let prose = removingMarkdownCodeBlocks().lowercased()
        let lines = prose.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let bulletCount = lines.filter { $0.hasPrefix("-") || $0.hasPrefix("・") }.count
        guard bulletCount >= 2 else { return false }
        let hasInputOrLocation = [
            "入力",
            "位置",
            "画素",
            "pixel",
            "tensor",
            "特徴",
            "feature",
            "shape"
        ].contains { prose.contains($0) }
        let hasOutputOrEffect = [
            "出力",
            "予測",
            "返す",
            "分類",
            "距離",
            "loss",
            "勾配",
            "更新",
            "embedding"
        ].contains { prose.contains($0) }
        let hasImplementationReason = [
            "なぜ",
            "ため",
            "意味",
            "役割",
            "読む",
            "表す",
            "represents",
            "means",
            "because"
        ].contains { prose.contains($0) }
        return hasInputOrLocation && hasOutputOrEffect && hasImplementationReason
    }

    var mentionsAnchorProposalPractice: Bool {
        let lower = lowercased()
        return lower.contains("anchor")
            || lower.contains("proposal")
            || lower.contains("アンカー")
            || lower.contains("プロポーザル")
    }

    func removingMarkdownCodeBlocks() -> String {
        let parts = components(separatedBy: "```")
        guard parts.count >= 3 else { return self }
        return parts.indices
            .filter { $0.isMultiple(of: 2) }
            .map { parts[$0] }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func extractMarkdownCodeBlocks() -> [String] {
        let parts = components(separatedBy: "```")
        guard parts.count >= 3 else { return [] }
        return stride(from: 1, to: parts.count, by: 2).compactMap { index in
            var block = parts[index]
            if let newline = block.firstIndex(of: "\n") {
                let language = block[..<newline].trimmingCharacters(in: .whitespacesAndNewlines)
                if !language.isEmpty && !language.contains(" ") {
                    block = String(block[block.index(after: newline)...])
                }
            }
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

// MARK: - Source bundle (disk load for saved notes)

public struct Inf6PaperQuizSourceStats: Hashable, Sendable {
    public var hasAbstract: Bool
    public var assetNoteBlocks: Int
    public var assetNoteItems: Int
    public var genericNoteBlocks: Int
    public var mathCardExplanations: Int
    public var coverageTargetCount: Int

    public init(
        hasAbstract: Bool,
        assetNoteBlocks: Int,
        assetNoteItems: Int,
        genericNoteBlocks: Int,
        mathCardExplanations: Int,
        coverageTargetCount: Int
    ) {
        self.hasAbstract = hasAbstract
        self.assetNoteBlocks = assetNoteBlocks
        self.assetNoteItems = assetNoteItems
        self.genericNoteBlocks = genericNoteBlocks
        self.mathCardExplanations = mathCardExplanations
        self.coverageTargetCount = coverageTargetCount
    }

    public var quizRelevantItemCount: Int {
        assetNoteItems + mathCardExplanations
    }
}

public struct Inf6PaperQuizSourceBundle: Hashable, Sendable {
    public var abstractText: String
    /// pageIndex -> note text list
    public var pageNotes: [Int: [String]]
    /// pageIndex -> math card sources (provided from UI, may be partial)
    public var mathCards: [Int: [Inf6PaperQuizMathCardSource]]
    public var entityCoverageTargets: [Inf6PaperQuizCoverageTarget]

    public init(
        abstractText: String,
        pageNotes: [Int: [String]],
        mathCards: [Int: [Inf6PaperQuizMathCardSource]],
        entityCoverageTargets: [Inf6PaperQuizCoverageTarget] = []
    ) {
        self.abstractText = abstractText
        self.pageNotes = pageNotes
        self.mathCards = mathCards
        self.entityCoverageTargets = entityCoverageTargets
    }

    public var hasAnyContent: Bool {
        let absOK = !abstractText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let notesOK = pageNotes.values.contains(where: { $0.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) })
        let mathOK = mathCards.values.contains(where: { $0.contains(where: { !$0.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) })
        return absOK || notesOK || mathOK || !entityCoverageTargets.isEmpty
    }

    public var stats: Inf6PaperQuizSourceStats {
        let hasAbstract = !abstractText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        var assetNoteBlocks = 0
        var assetNoteItems = 0
        var genericNoteBlocks = 0

        for notes in pageNotes.values {
            for note in notes {
                let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if Self._isAssetFocusedNote(trimmed) {
                    assetNoteBlocks += 1
                    assetNoteItems += Self._countEnumeratedAssetUnits(in: trimmed)
                } else {
                    genericNoteBlocks += 1
                }
            }
        }

        let mathCardExplanations = mathCards.values.reduce(0) { partial, cards in
            partial + cards.reduce(0) { inner, card in
                inner + (card.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1)
            }
        }

        let coverageTargetCount: Int = {
            if !entityCoverageTargets.isEmpty { return entityCoverageTargets.count }
            let assetAndMath = assetNoteItems + mathCardExplanations
            if assetAndMath > 0 { return assetAndMath }
            if genericNoteBlocks > 0 { return genericNoteBlocks }
            return hasAbstract ? 1 : 0
        }()

        return Inf6PaperQuizSourceStats(
            hasAbstract: hasAbstract,
            assetNoteBlocks: assetNoteBlocks,
            assetNoteItems: assetNoteItems,
            genericNoteBlocks: genericNoteBlocks,
            mathCardExplanations: mathCardExplanations,
            coverageTargetCount: coverageTargetCount
        )
    }

    public func resolvedQuestionCount() -> Int {
        coverageTargets().filter { $0.id.hasPrefix("understanding-point-") }.count
    }

    public func coverageTargets() -> [Inf6PaperQuizCoverageTarget] {
        var targets: [Inf6PaperQuizCoverageTarget] = []
        var seen: Set<String> = []

        func append(_ target: Inf6PaperQuizCoverageTarget) {
            let trimmedEvidence = target.evidenceText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedEvidence.isEmpty else { return }
            guard seen.insert(target.id).inserted else { return }
            targets.append(
                Inf6PaperQuizCoverageTarget(
                    id: target.id,
                    kind: target.kind,
                    pageIndex: target.pageIndex,
                    title: target.title,
                    evidenceText: trimmedEvidence
                )
            )
        }

        let overview = abstractText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !overview.isEmpty {
            let headingSets = [
                ["要旨", "数学的導出", "実装", "実務上の検証"],
                ["論文要旨（abstract）", "数学的導出", "実装", "実務上の検証"],
                ["解説", "数学的導出", "実装", "実務上の検証"],
                ["論文概要", "数学的導出", "実装", "実務上の検証"],
                ["Paper overview", "Mathematical derivation", "Implementation", "Practical validation"]
            ]
            let headings = headingSets.first { set in set.allSatisfy { overview.localizedCaseInsensitiveContains($0) } }
            if let headings {
                for (index, heading) in headings.enumerated() {
                    guard let startRange = overview.range(of: heading, options: .caseInsensitive) else { continue }
                    let bodyStart = startRange.upperBound
                    let bodyEnd: String.Index = {
                        guard index + 1 < headings.count,
                              let next = overview.range(of: headings[index + 1], options: .caseInsensitive, range: bodyStart..<overview.endIndex)
                        else { return overview.endIndex }
                        return next.lowerBound
                    }()
                    let evidence = overview[bodyStart..<bodyEnd].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !evidence.isEmpty else { continue }
                    let ids = ["overview-paper", "overview-core-theory", "overview-terminology", "overview-exercise-focus"]
                    append(Inf6PaperQuizCoverageTarget(
                        id: ids[index], kind: .abstract, pageIndex: nil,
                        title: heading, evidenceText: evidence
                    ))
                }
            } else {
                append(Inf6PaperQuizCoverageTarget(
                    id: "overview-core-theory", kind: .abstract, pageIndex: nil,
                    title: "Core theory", evidenceText: overview
                ))
            }
        }

        var hasDedicatedTargets = false

        for target in entityCoverageTargets {
            append(target)
            hasDedicatedTargets = true
        }

        if entityCoverageTargets.isEmpty {
            for pageIndex in pageNotes.keys.sorted() {
                let notes = pageNotes[pageIndex, default: []]
                for (noteIndex, noteRaw) in notes.enumerated() {
                    let note = noteRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !note.isEmpty else { continue }
                    guard Self._isAssetFocusedNote(note) else { continue }
                    let units = Self._enumeratedAssetUnits(in: note)
                    for (unitIndex, unitRaw) in units.enumerated() {
                        let unit = unitRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !unit.isEmpty else { continue }
                        append(
                            Inf6PaperQuizCoverageTarget(
                                id: "page-note-p\(pageIndex)-n\(noteIndex + 1)-u\(unitIndex + 1)",
                                kind: .pageNote,
                                pageIndex: pageIndex,
                                title: Self._coverageTitle(from: unit, fallback: "Page \(pageIndex + 1) note \(noteIndex + 1)"),
                                evidenceText: unit
                            )
                        )
                        hasDedicatedTargets = true
                    }
                }
            }

            for pageIndex in mathCards.keys.sorted() {
                let cards = mathCards[pageIndex, default: []]
                for (cardIndex, card) in cards.enumerated() {
                    let explanation = card.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !explanation.isEmpty else { continue }
                    append(
                        Inf6PaperQuizCoverageTarget(
                            id: "math-card-p\(pageIndex)-\(Self._slug(card.cardID, fallback: "card-\(cardIndex + 1)"))",
                            kind: .mathCard,
                            pageIndex: pageIndex,
                            title: Self._coverageTitle(from: explanation, fallback: "Math card \(cardIndex + 1)"),
                            evidenceText: explanation
                        )
                    )
                    hasDedicatedTargets = true
                }
            }
        }

        if !hasDedicatedTargets {
            for pageIndex in pageNotes.keys.sorted() {
                let notes = pageNotes[pageIndex, default: []]
                for (noteIndex, noteRaw) in notes.enumerated() {
                    let note = noteRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !note.isEmpty else { continue }
                    append(
                        Inf6PaperQuizCoverageTarget(
                            id: "page-note-p\(pageIndex)-n\(noteIndex + 1)",
                            kind: .pageNote,
                            pageIndex: pageIndex,
                            title: Self._coverageTitle(from: note, fallback: "Page \(pageIndex + 1) note \(noteIndex + 1)"),
                            evidenceText: note
                        )
                    )
                }
            }
        }

        return targets
    }

    // Storage layout matches InlinePDFPagesView:
    // baseDir/<paperKey>.abstract.txt for papers.
    // baseDir/<paperKey>.original_explanation.txt for explanation items.
    // baseDir/mini/p{page}.notes.json
    public static func loadFromDisk(
        baseDir: URL,
        paperKey: String,
        overviewFileName: String? = nil
    ) throws -> (abstractText: String, pageNotes: [Int: [String]]) {
        let paperKey = paperKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if paperKey.isEmpty {
            throw Inf6PaperQuizError.invalidSource("[Quiz] paperKey is empty for baseDir: \(baseDir.path)")
        }
        let overviewName = overviewFileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let abstractURL = baseDir.appendingPathComponent(
            overviewName?.isEmpty == false ? overviewName! : "\(paperKey).abstract.txt"
        )
        let miniDir = baseDir.appendingPathComponent("mini", isDirectory: true)

        let abstractText: String = {
            guard let data = coordinatedRead(url: abstractURL) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }()

        var pageNotes: [Int: [String]] = [:]

        let fm = FileManager.default
        if fm.fileExists(atPath: miniDir.path) {
            let files: [URL]
            do {
                files = try fm.contentsOfDirectory(at: miniDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            } catch {
                throw Inf6PaperQuizError.io("[Quiz] cannot list mini dir: \(error)")
            }

            for u in files {
                let name = u.lastPathComponent
                // p{N}.notes.json
                guard name.hasPrefix("p"), name.hasSuffix(".notes.json") else { continue }
                let pageStr = name
                    .replacingOccurrences(of: "p", with: "")
                    .replacingOccurrences(of: ".notes.json", with: "")
                guard let storedPage = Int(pageStr), storedPage >= 1 else { continue }
                let page = storedPage - 1

                guard let data = coordinatedRead(url: u), !data.isEmpty else { continue }

                do {
                    let decoded = try JSONDecoder().decode([_ExtraNoteDisk].self, from: data)
                    let texts = decoded.map { $0.text }
                    let trimmed = texts
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if !trimmed.isEmpty {
                        pageNotes[page] = trimmed
                    }
                } catch {
                    throw Inf6PaperQuizError.decode("[Quiz] notes decode failed: \(name) error=\(error)")
                }
            }
        }

        return (abstractText: abstractText, pageNotes: pageNotes)
    }

    private struct _ExtraNoteDisk: Codable, Hashable, Sendable {
        var id: UUID
        var text: String
        var rtf: Data?
        var createdAt: TimeInterval
    }

    fileprivate static func _isAssetFocusedNote(_ note: String) -> Bool {
        let firstNonEmpty = note
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""

        let headings: Set<String> = ["図", "表", "式", "Figures", "Tables", "Equations"]
        if headings.contains(firstNonEmpty) { return true }

        return note.contains("x-axis") || note.contains("y-axis")
            || note.contains("横軸") || note.contains("縦軸")
            || note.contains("equationText:")
    }

    fileprivate static func _countEnumeratedAssetUnits(in note: String) -> Int {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        if trimmed.contains("（なし）") || trimmed.contains("(none)") {
            return 0
        }

        let pattern = #"^\s*(?:\d+[\.\)]|[\(（]?\d+[\)）])\s+"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)

        var numberedCount = 0
        for lineSub in lines {
            let line = String(lineSub)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if regex?.firstMatch(in: line, options: [], range: range) != nil {
                numberedCount += 1
            }
        }

        if numberedCount > 0 { return numberedCount }
        return 1
    }

    fileprivate static func _enumeratedAssetUnits(in note: String) -> [String] {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let pattern = #"^\s*(?:\d+[\.\)]|[\(（]?\d+[\)）])\s+"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var groups: [[String]] = []
        var current: [String] = []
        var sawNumbered = false

        for line in lines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            let isNumbered = regex?.firstMatch(in: line, options: [], range: range) != nil
            if isNumbered {
                sawNumbered = true
                if !current.isEmpty {
                    groups.append(current)
                    current = []
                }
                current.append(line)
            } else if !current.isEmpty {
                current.append(line)
            }
        }

        if !current.isEmpty {
            groups.append(current)
        }

        if !sawNumbered {
            return [trimmed]
        }

        return groups
            .map { $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    fileprivate static func _coverageTitle(from text: String, fallback: String) -> String {
        let first = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
        let cleaned = first
            .replacingOccurrences(of: #"^\s*(?:\d+[\.\)]|[\(（]?\d+[\)）])\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = cleaned.isEmpty ? fallback : cleaned
        return String(resolved.prefix(96))
    }

    fileprivate static func _slug(_ raw: String, fallback: String) -> String {
        let mapped = raw.unicodeScalars.map { scalar -> Character in
            let value = scalar.value
            let isASCIIAlphaNum = (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
            return isASCIIAlphaNum ? Character(scalar) : "_"
        }
        let joined = String(mapped)
            .replacingOccurrences(of: "__", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return joined.isEmpty ? fallback : joined
    }

    private static func coordinatedRead(url: URL) -> Data? {
        var out: Data? = nil
        var coordError: NSError? = nil

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            // メモリマップでは読まない。
            //
            // iCloud のファイルは実体がローカルに無いことがあり、マップした領域へ
            // 触れた時点で取得しに行く。取得に失敗すると不正アクセスになり、
            // JSONDecoder がページに触れた瞬間にプロセスごと落ちる。これは例外では
            // ないため try? では捕まらない。明示的に読み切れば、失敗は例外として
            // 表面化し、この関数が nil を返して呼び出し側が読み飛ばせる。
            do {
                let handle = try FileHandle(forReadingFrom: readURL)
                defer { try? handle.close() }
                out = try handle.readToEnd()
            } catch {
                NSLog("[Quiz] read failed: %@ error=%@", readURL.lastPathComponent, String(describing: error))
                out = nil
            }
        }

        if coordError != nil {
            // Must surface: caller will treat as missing content (not a silent fallback).
            // Returning nil indicates a read failure.
            return nil
        }
        return out
    }
}

// MARK: - Quiz store (read/write JSON)

public struct Inf6PaperQuizStore {
    public static func quizURL(baseDir: URL) -> URL {
        baseDir.appendingPathComponent("paper.quiz.json")
    }

    public static func load(baseDir: URL, paperKey: String? = nil) throws -> Inf6PaperQuiz? {
        // metadata file store first
        if let pk = paperKey ?? _inferPaperKey(baseDir: baseDir),
           let cached: Inf6PaperQuiz = Inf6MetadataStore.getCodable(Inf6PaperQuiz.self, domain: .quiz, key: pk) {
            try cached.validateVisualEvidenceContract()
            return cached
        }

        // JSON fallback
        let url = quizURL(baseDir: baseDir)

        var data: Data? = nil
        var coordError: NSError? = nil
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            data = Inf6SafeFileRead.dataIfReadable(at: readURL)
        }

        if let coordError {
            throw Inf6PaperQuizError.io("[Quiz] read coordination failed: \(coordError)")
        }

        guard let data, !data.isEmpty else { return nil }

        do {
            let quiz = try JSONDecoder().decode(Inf6PaperQuiz.self, from: data)
            try quiz.validateVisualEvidenceContract()
            // Migrate to metadata file store
            guard let pk = paperKey ?? _inferPaperKey(baseDir: baseDir),
                  Inf6MetadataStore.putCodable(quiz, domain: .quiz, key: pk) else {
                throw Inf6PaperQuizError.io("[Quiz] metadata migration write failed")
            }
            return quiz
        } catch let error as Inf6PaperQuizError {
            throw error
        } catch {
            throw Inf6PaperQuizError.decode("[Quiz] quiz decode failed: \(error)")
        }
    }

    public static func save(baseDir: URL, quiz: Inf6PaperQuiz, paperKey: String? = nil) throws {
        try quiz.validateVisualEvidenceContract()
        // metadata file store
        guard let pk = paperKey ?? _inferPaperKey(baseDir: baseDir),
              Inf6MetadataStore.putCodable(quiz, domain: .quiz, key: pk) else {
            throw Inf6PaperQuizError.io("[Quiz] metadata write failed")
        }

        // JSON backward compat
        let url = quizURL(baseDir: baseDir)

        let data: Data
        do {
            data = try JSONEncoder().encode(quiz)
        } catch {
            throw Inf6PaperQuizError.encode("[Quiz] quiz encode failed: \(error)")
        }

        var coordError: NSError? = nil
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { writeURL in
            do {
                try data.write(to: writeURL, options: [.atomic])
            } catch {
                // surface
            }
        }

        if let coordError {
            throw Inf6PaperQuizError.io("[Quiz] write coordination failed: \(coordError)")
        }
    }

    /// Infer paperKey from baseDir (last path component is the normalized paper folder key).
    private static func _inferPaperKey(baseDir: URL) -> String? {
        let key = baseDir.lastPathComponent
        return key.isEmpty ? nil : key
    }
}

private extension Inf6PaperQuizError {
    static func encode(_ s: String) -> Inf6PaperQuizError { .decode(s) }
}

// MARK: - Generator

/// iCloud 上のファイルを安全に読むための共通処理。
///
/// `Data(contentsOf:options:.mappedIfSafe)` を使ってはならない。
/// iCloud のファイルは実体がローカルに無いことがあり、マップした領域へ
/// 触れた時点で取得しに行く。取得に失敗すると不正メモリアクセスになり、
/// 中身を読んだ瞬間にプロセスごと落ちる。これは Swift の例外ではないため
/// `try?` でも `do/catch` でも捕まえられない。
///
/// 明示的に読み切れば、失敗は例外として表面化し、呼び出し側が扱える。
public enum Inf6SafeFileRead {

    public static func data(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.readToEnd() ?? Data()
    }

    /// 読めない場合に nil を返す版。読み飛ばしてよい場面で使う。
    public static func dataIfReadable(at url: URL) -> Data? {
        do {
            return try data(at: url)
        } catch {
            NSLog("[SafeRead] failed: %@ error=%@", url.lastPathComponent, String(describing: error))
            return nil
        }
    }
}

public struct Inf6PaperQuizGenerator {
    /// 解説から「対比・否定」の文を落とす。
    ///
    /// 演習は正しい内容を理解するためのものなので、「〜ではない」「〜と混同しやすい」
    /// といった誤りとの対比は不要であり、要点をぼかす。プロンプトで禁止しても
    /// 出力されることがあるため、保存前に決定的に取り除く。
    /// すべての文が対象になる場合だけは、内容を失わないよう原文を返す。
    static func sanitizedExplanation(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let contrastPatterns = [
            "ではない", "ではありません", "ではなく", "ではなくて",
            "わけではない", "ものではない", "混同", "誤り", "誤解", "間違い",
            "とは限らない", "してはいけない",
        ]

        // 箇条書きなら行単位、散文なら文単位で落とす。
        if trimmed.contains("\n") {
            var kept: [String] = []
            var dropped = false
            for line in trimmed.components(separatedBy: .newlines) {
                let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !s.isEmpty else { continue }
                if contrastPatterns.contains(where: { s.contains($0) }) {
                    dropped = true
                    continue
                }
                kept.append(s)
            }
            guard dropped, !kept.isEmpty else { return trimmed }
            return kept.joined(separator: "\n")
        }

        var kept: [String] = []
        var dropped = false
        for sentence in trimmed.components(separatedBy: "。") {
            let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { continue }
            if contrastPatterns.contains(where: { s.contains($0) }) {
                dropped = true
                continue
            }
            kept.append(s)
        }
        guard dropped, !kept.isEmpty else { return trimmed }
        return kept.joined(separator: "。") + "。"
    }

    public static func generate(
        paperKey: String,
        paperTitle: String,
        lang: String,
        sources: Inf6PaperQuizSourceBundle,
        codePractice: Inf6PaperQuizCodePracticeOptions? = nil,
        askModel: @escaping (String) async throws -> String
    ) async throws -> Inf6PaperQuiz {

        var coverageTargets = sources.coverageTargets()
        let understandingPointTargets = coverageTargets.filter { $0.id.hasPrefix("understanding-point-") }
        let entityTargets = coverageTargets.filter { $0.id.hasPrefix("doc-entity:") }
        guard !understandingPointTargets.isEmpty else {
            throw Inf6PaperQuizError.invalidSource("[Quiz] structured understanding points are missing from the overview")
        }
        guard !entityTargets.isEmpty else {
            throw Inf6PaperQuizError.invalidSource("[Quiz] core figure/table/equation evidence is missing")
        }
        let qCount = understandingPointTargets.count
        guard sources.hasAnyContent else {
            throw Inf6PaperQuizError.invalidSource("[Quiz] no sources: abstract/notes/math-card explanations are empty")
        }

        let prompt = buildPrompt(
            paperKey: paperKey,
            paperTitle: paperTitle,
            lang: lang,
            questionCount: qCount,
            sources: sources
        )

        let raw = try await askModel(prompt)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.first == "{" || trimmed.first == "[" else {
            throw Inf6PaperQuizError.modelResponseNotJSON("[Quiz] model response is not JSON (first char=\(trimmed.first.map(String.init) ?? "nil"))")
        }

        // Decode strict JSON
        let data = Data(trimmed.utf8)
        do {
            let decoded = try JSONDecoder().decode(_QuizResponse.self, from: data)

            // Validate
            guard !decoded.questions.isEmpty else {
                throw Inf6PaperQuizError.modelJSONDecodeFailed("[Quiz] decoded JSON has zero questions")
            }
            if decoded.questions.count != understandingPointTargets.count {
                NSLog("[Quiz] question count mismatch: expected %d, got %d for %@ — will attempt retry", understandingPointTargets.count, decoded.questions.count, paperKey)
            }
            let validCoverageTargetIDs = Set(coverageTargets.map(\.id))
            let understandingPointTargetIDs = Set(understandingPointTargets.map(\.id))
            let entityTargetIDs = Set(entityTargets.map(\.id))
            var coveredUnderstandingPointIDs = Set<String>()
            var validQuestions: [Inf6PaperQuizQuestion] = []
            for (i, q) in decoded.questions.enumerated() {
                if q.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    NSLog("[Quiz] Q%d skipped: question is empty", i)
                    continue
                }
                if q.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    NSLog("[Quiz] Q%d skipped: explanation is empty", i)
                    continue
                }
                let understandingPointID = q.understandingPointID.trimmingCharacters(in: .whitespacesAndNewlines)
                let entityTargetID = q.docEntityID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard validCoverageTargetIDs.contains(understandingPointID),
                      understandingPointTargetIDs.contains(understandingPointID) else {
                    NSLog("[Quiz] Q%d skipped: invalid understandingPointID %@", i, understandingPointID)
                    continue
                }
                guard validCoverageTargetIDs.contains(entityTargetID),
                      entityTargetIDs.contains(entityTargetID),
                      let entityTarget = coverageTargets.first(where: { $0.id == entityTargetID }),
                      ["figure", "table", "equation"].contains(q.kind.lowercased()),
                      q.kind.lowercased() == entityTarget.kind.rawValue else {
                    NSLog("[Quiz] Q%d skipped: invalid docEntityID or kind mismatch %@", i, entityTargetID)
                    continue
                }
                guard coveredUnderstandingPointIDs.insert(understandingPointID).inserted else {
                    NSLog("[Quiz] Q%d skipped: duplicated understanding point", i)
                    continue
                }
            validQuestions.append(Inf6PaperQuizQuestion(
                pageIndex: q.pageIndex,
                kind: q.kind,
                question: q.question,
                choices: q.choices,
                correctIndex: q.correctIndex,
                explanation: sanitizedExplanation(q.explanation),
                coverageTargetIDs: [understandingPointID, entityTargetID]
            ))
            }
            guard !validQuestions.isEmpty else {
                throw Inf6PaperQuizError.modelJSONDecodeFailed("[Quiz] all \(decoded.questions.count) questions failed validation")
            }
            if validQuestions.count < decoded.questions.count {
                NSLog("[Quiz] %d/%d questions passed validation for %@", validQuestions.count, decoded.questions.count, paperKey)
            }

            if coveredUnderstandingPointIDs != understandingPointTargetIDs {
                let missingIDs = understandingPointTargetIDs.subtracting(coveredUnderstandingPointIDs)
                NSLog("[Quiz] coverage gap: %d missing understanding points, regenerating missing coverage for %@", missingIDs.count, paperKey)
                var unresolvedIDs = missingIDs
                let maxCoverageRegenerationPasses = 3
                for pass in 1...maxCoverageRegenerationPasses where coveredUnderstandingPointIDs != understandingPointTargetIDs {
                    let passTargets = understandingPointTargets.filter { unresolvedIDs.contains($0.id) }
                    guard !passTargets.isEmpty else { break }
                    let retryPrompt = buildPrompt(
                        paperKey: paperKey,
                        paperTitle: paperTitle,
                        lang: lang,
                        questionCount: passTargets.count,
                        sources: sources,
                        requiredUnderstandingPointIDs: passTargets.map(\.id)
                    )
                    let retryRaw: String
                    do {
                        retryRaw = try await askModel(retryPrompt)
                    } catch {
                        throw Inf6PaperQuizError.modelJSONDecodeFailed(
                            "[Quiz] coverage regeneration request failed: pass \(pass), missing \(unresolvedIDs.sorted().joined(separator: ",")): \(error.localizedDescription)"
                        )
                    }
                    let retryTrimmed = retryRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard retryTrimmed.first == "{" || retryTrimmed.first == "[" else {
                        throw Inf6PaperQuizError.modelResponseNotJSON(
                            "[Quiz] coverage regeneration response is not JSON: pass \(pass), first char=\(retryTrimmed.first.map(String.init) ?? "nil"), missing \(unresolvedIDs.sorted().joined(separator: ","))"
                        )
                    }
                    let retryDecoded: _QuizResponse
                    do {
                        let retryData = Data(retryTrimmed.utf8)
                        retryDecoded = try JSONDecoder().decode(_QuizResponse.self, from: retryData)
                    } catch {
                        throw Inf6PaperQuizError.modelJSONDecodeFailed(
                            "[Quiz] coverage regeneration JSON decode failed: pass \(pass), missing \(unresolvedIDs.sorted().joined(separator: ",")): \(error.localizedDescription)"
                        )
                    }
                    for q in retryDecoded.questions {
                        guard !q.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              !q.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        let upID = q.understandingPointID.trimmingCharacters(in: .whitespacesAndNewlines)
                        let etID = q.docEntityID.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard unresolvedIDs.contains(upID),
                              entityTargetIDs.contains(etID),
                              let entityTarget = coverageTargets.first(where: { $0.id == etID }),
                              ["figure", "table", "equation"].contains(q.kind.lowercased()),
                              q.kind.lowercased() == entityTarget.kind.rawValue,
                              coveredUnderstandingPointIDs.insert(upID).inserted else { continue }
                        validQuestions.append(Inf6PaperQuizQuestion(
                            pageIndex: q.pageIndex,
                            kind: q.kind,
                            question: q.question,
                            choices: q.choices,
                            correctIndex: q.correctIndex,
                            explanation: sanitizedExplanation(q.explanation),
                            coverageTargetIDs: [upID, etID]
                        ))
                    }
                    unresolvedIDs = understandingPointTargetIDs.subtracting(coveredUnderstandingPointIDs)
                    NSLog("[Quiz] after coverage regeneration: %d/%d understanding points covered for %@", coveredUnderstandingPointIDs.count, understandingPointTargetIDs.count, paperKey)
                }
                if coveredUnderstandingPointIDs != understandingPointTargetIDs {
                    let finalMissingIDs = understandingPointTargetIDs.subtracting(coveredUnderstandingPointIDs)
                    throw Inf6PaperQuizError.modelJSONDecodeFailed(
                        "[Quiz] understanding-point coverage mismatch: expected \(understandingPointTargets.count), got \(validQuestions.count), missing \(finalMissingIDs.sorted().joined(separator: ","))"
                    )
                }
            }

            if let codePractice {
                let codeTargets = buildCodePracticeTargets(
                    options: codePractice,
                    sources: sources,
                    understandingPointTargets: understandingPointTargets
                )
                if !codeTargets.isEmpty {
                    let codeQuestions = try await generateCodePracticeQuestions(
                        paperKey: paperKey,
                        paperTitle: paperTitle,
                        lang: lang,
                        sources: sources,
                        options: codePractice,
                        codeTargets: codeTargets,
                        askModel: askModel
                    )
                    coverageTargets.append(contentsOf: codeTargets)
                    validQuestions.append(contentsOf: codeQuestions)
                }
            }

            let quiz = Inf6PaperQuiz(
                paperKey: paperKey,
                paperTitle: paperTitle,
                lang: lang,
                questions: validQuestions,
                coverageTargets: coverageTargets
            )
            return quiz
        } catch let e as Inf6PaperQuizError {
            throw e
        } catch {
            throw Inf6PaperQuizError.modelJSONDecodeFailed("[Quiz] JSON decode failed: \(error)")
        }
    }

    public static func generateCodePracticeOnly(
        paperKey: String,
        paperTitle: String,
        lang: String,
        sources: Inf6PaperQuizSourceBundle,
        options: Inf6PaperQuizCodePracticeOptions,
        askModel: @escaping (String) async throws -> String
    ) async throws -> Inf6PaperQuiz {
        let coverageTargets = sources.coverageTargets()
        let understandingPointTargets = coverageTargets.filter { $0.id.hasPrefix("understanding-point-") }
        guard !understandingPointTargets.isEmpty else {
            throw Inf6PaperQuizError.invalidSource("[Quiz] structured understanding points are missing from the overview")
        }
        guard sources.hasAnyContent else {
            throw Inf6PaperQuizError.invalidSource("[Quiz] no sources: abstract/notes/math-card explanations are empty")
        }
        let codeTargets = buildCodePracticeTargets(
            options: options,
            sources: sources,
            understandingPointTargets: understandingPointTargets
        )
        guard !codeTargets.isEmpty else {
            throw Inf6PaperQuizError.invalidSource("[Quiz] no code practice targets were generated")
        }
        let codeQuestions = try await generateCodePracticeQuestions(
            paperKey: paperKey,
            paperTitle: paperTitle,
            lang: lang,
            sources: sources,
            options: options,
            codeTargets: codeTargets,
            askModel: askModel
        )
        return Inf6PaperQuiz(
            paperKey: paperKey,
            paperTitle: paperTitle,
            lang: lang,
            questions: codeQuestions,
            coverageTargets: codeTargets
        )
    }

    private static func buildCodePracticeTargets(
        options: Inf6PaperQuizCodePracticeOptions,
        sources: Inf6PaperQuizSourceBundle,
        understandingPointTargets: [Inf6PaperQuizCoverageTarget]
    ) -> [Inf6PaperQuizCoverageTarget] {
        let syllabus = options.syllabusTitle.isEmpty ? "E資格 Python実装" : options.syllabusTitle
        let overview = sources.abstractText.trimmingCharacters(in: .whitespacesAndNewlines)
        let focus = understandingPointTargets
            .prefix(options.questionCount)
            .map { "\($0.title)\n\($0.evidenceText)" }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return options.frameworks.flatMap { framework in
            let slug = codePracticeFrameworkSlug(framework)
            let evidence = [
                "framework: \(framework)",
                "syllabus: \(syllabus)",
                overview.isEmpty ? "" : "overview:\n\(overview)",
                focus.isEmpty ? "" : "understanding_points:\n\(focus)"
            ]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if evidence.isEmpty { return [Inf6PaperQuizCoverageTarget]() }
            return (1...options.questionCount).map { index in
                Inf6PaperQuizCoverageTarget(
                    id: "code-practice-\(slug)-\(index)",
                    kind: .code,
                    pageIndex: nil,
                    title: "\(framework) implementation practice \(index)",
                    evidenceText: evidence
                )
            }
        }
    }

    public static func codePracticeFrameworkSlug(_ framework: String) -> String {
        let normalized = framework.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("tensorflow") || normalized.contains("tensor flow") { return "tensorflow" }
        if normalized.contains("pytorch") || normalized.contains("torch") { return "pytorch" }
        return normalized
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }
            .reduce(into: "") { $0.append($1) }
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func generateCodePracticeQuestions(
        paperKey: String,
        paperTitle: String,
        lang: String,
        sources: Inf6PaperQuizSourceBundle,
        options: Inf6PaperQuizCodePracticeOptions,
        codeTargets: [Inf6PaperQuizCoverageTarget],
        askModel: @escaping (String) async throws -> String
    ) async throws -> [Inf6PaperQuizQuestion] {
        let prompt = buildCodePracticePrompt(
            paperTitle: paperTitle,
            lang: lang,
            sources: sources,
            options: options,
            codeTargets: codeTargets
        )
        let raw = try await askModel(prompt)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[" else {
            throw Inf6PaperQuizError.modelResponseNotJSON("[Quiz] code practice response is not JSON (first char=\(trimmed.first.map(String.init) ?? "nil"))")
        }
        let decoded: _CodePracticeResponse
        do {
            decoded = try JSONDecoder().decode(_CodePracticeResponse.self, from: Data(trimmed.utf8))
        } catch {
            throw Inf6PaperQuizError.modelJSONDecodeFailed("[Quiz] code practice JSON decode failed: \(error)")
        }

        let allowedIDs = Set(codeTargets.map(\.id))
        var seen = Set<String>()
        var questions: [Inf6PaperQuizQuestion] = []
        for (index, item) in decoded.questions.enumerated() {
            let targetID = item.codeTargetID.trimmingCharacters(in: .whitespacesAndNewlines)
            let question = item.question.trimmingCharacters(in: .whitespacesAndNewlines)
            let explanation = item.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard allowedIDs.contains(targetID),
                  seen.insert(targetID).inserted,
                  item.kind.lowercased() == "code",
                  !question.isEmpty,
                  !explanation.isEmpty else {
                NSLog("[Quiz] code practice Q%d skipped: invalid target/kind/body", index + 1)
                continue
            }
            questions.append(Inf6PaperQuizQuestion(
                pageIndex: nil,
                kind: "code",
                question: question,
                choices: [],
                correctIndex: 0,
                explanation: sanitizedExplanation(explanation),
                coverageTargetIDs: [targetID],
                questionType: .decision
            ))
        }
        guard questions.count == codeTargets.count else {
            let missing = allowedIDs.subtracting(seen).sorted().joined(separator: ",")
            throw Inf6PaperQuizError.modelJSONDecodeFailed("[Quiz] code practice coverage mismatch for \(paperKey): expected \(codeTargets.count), got \(questions.count), missing \(missing)")
        }
        return questions
    }

    private static func buildCodePracticePrompt(
        paperTitle: String,
        lang: String,
        sources: Inf6PaperQuizSourceBundle,
        options: Inf6PaperQuizCodePracticeOptions,
        codeTargets: [Inf6PaperQuizCoverageTarget]
    ) -> String {
        let isEN = (lang == "en")
        let maxChars = 12_000
        let evidence = sources.coverageTargets()
            .filter { target in
                target.id == "overview-core-theory"
                    || target.id == "overview-terminology"
                    || target.id == "overview-exercise-focus"
                    || target.id.hasPrefix("understanding-point-")
            }
            .map { "[\($0.id)] \($0.title)\n\($0.evidenceText)" }
            .joined(separator: "\n\n")
            .prefix(maxChars)
        let targetIDs = codeTargets.map(\.id).joined(separator: "\n")
        let schema = """
{
  "questions": [
    {
      "kind": "code",
      "question": "string",
      "explanation": "string",
      "codeTargetID": "code-practice-framework-N"
    }
  ]
}
"""
        let frameworks = options.frameworks.joined(separator: " and ")
        if isEN {
            return """
You are creating implementation practice for E-Certification learners.

TASK:
- Add exactly \(codeTargets.count) Python implementation practice items.
- Generate all allowed framework targets. The framework is encoded in each codeTargetID and evidence block.
- These are study cards, not multiple-choice questions. Emit no choices and no correctIndex.
- Each item must be understandable by looking at it: include a compact code fragment and the exact points to read from it.
- Explain the library name and the implementation point that must be remembered for this syllabus node. PyTorch cards must show the relevant use of torch / nn.Module / DataLoader / backward() / optimizer.step() / train() / eval() / to(device). TensorFlow cards must show the relevant use of tf. / tf.keras / keras / GradientTape / training=.
- The bullets must explain why the highlighted implementation line expresses the concept: what older or alternative method it replaces when the evidence says so, what the input tensor/location represents, what the output tensor/value represents, and why the library call has that argument or shape. If anchors or proposals appear in the evidence, explicitly state the conventional method and what is replaced.
- Do not emit placeholder-only study notes such as encoder(x), projector(h), criterion(...), loader, or model(x). If a placeholder is useful, the same code block must also show the concrete library call or class that makes the implementation point test-relevant.
        - Focus on exam-relevant implementation judgement: tensor shapes, nn.Module/forward, loss, backward, optimizer.step, DataLoader, train/eval mode, no_grad, device placement, and common layer wiring when relevant.
        - For Transformer or Vision Transformer evidence, include a runnable minimal PyTorch/TensorFlow pattern: token or patch embedding, positional information, self-attention/encoder block, output head, tensor shapes, loss, and one training/inference step. State where Self-Attention is located in the paper figure and what Q/K/V represent.
- Use only the evidence below and ordinary framework semantics needed to express that evidence as code.
- Do not create production utilities, long scripts, or irrelevant boilerplate.
- `question` is a declarative heading under 25 words.
- `explanation` must be a short code block plus 2 to 5 bullet lines. Each bullet must state what to read from the code.
- Every item must have kind "code" and exactly one codeTargetID from the allowed list.

OUTPUT STRICT JSON ONLY:
\(schema)

PAPER:
\(paperTitle)

SYLLABUS:
\(options.syllabusTitle)

FRAMEWORKS:
\(frameworks)

EVIDENCE:
\(evidence)

ALLOWED codeTargetID:
\(targetIDs)
"""
        }
        return """
あなたはE資格向けの Python 実装演習を作る専門家です。

【タスク】
- Python 実装演習をちょうど \(codeTargets.count) 件追加する。
- PyTorch と TensorFlow の両方の許可ターゲットを生成する。framework は codeTargetID と Evidence 内に明示されているものに従う。
- 選択式ではない。choices と correctIndex は出力しない。
- 見るだけで対象 framework の要点が分かるカードにする。短いコード断片と、そこから読むべき点を必ず入れる。
- そのノードで必ず覚えるライブラリ名と使い方のポイントを解説する。PyTorch は torch / nn.Module / DataLoader / backward() / optimizer.step() / train() / eval() / to(device) の該当箇所を、TensorFlow は tf. / tf.keras / keras / GradientTape / training= の該当箇所をコード内で示す。
- 箇条書きでは、その重要行が概念をどう表すかを説明する。根拠に従来手法や対比がある場合は「従来」という語を使って何を置き換えているか、入力 tensor や位置が何を表すか、出力 tensor や値が何を表すか、そのライブラリ呼び出しの引数や shape がなぜそうなるかを必ず書く。
- encoder(x)、projector(h)、criterion(...)、loader、model(x) のようなプレースホルダだけの学習メモは禁止。必要なら、同じコードブロック内で試験上覚えるべき具体的なライブラリ呼び出しまたはクラスも示す。
        - E資格に出る実装判断に絞る。tensor shape、nn.Module/forward、loss、backward、optimizer.step、DataLoader、train/eval、no_grad、device、層の接続を必要に応じて扱う。
        - Transformer または Vision Transformer の根拠では、token/patch embedding、位置情報、self-attention/encoder block、出力ヘッド、tensor shape、loss、学習/推論の最小実例を含める。論文図のどこにSelf-Attentionがあるか、Q/K/Vが何を表すかをコードと対応づける。
- 根拠は下の Evidence と、それをコードで表すために必要な通常のフレームワーク意味論だけに限定する。
- 長いスクリプト、production用ユーティリティ、試験に不要な周辺処理は禁止。
- question は疑問文ではなく、何を見るカードかを言い切る見出しにする。60字以内。
- explanation は短いコードブロックと2〜5個の箇条書きにする。各箇条書きはコードから読むべき点だけを書く。
- kind は必ず "code"。codeTargetID は許可リストから1件だけ選ぶ。

【出力】JSONのみ:
\(schema)

【論文/項目】
\(paperTitle)

【シラバス】
\(options.syllabusTitle)

【Framework】
\(frameworks)

【Evidence】
\(evidence)

【使用可能 codeTargetID】
\(targetIDs)
"""
    }

    private struct _CodePracticeResponse: Codable {
        var questions: [_CodePracticeQ]
    }

    private struct _CodePracticeQ: Codable {
        var kind: String
        var question: String
        var explanation: String
        var codeTargetID: String

        private enum CodingKeys: String, CodingKey {
            case kind
            case question
            case explanation
            case codeTargetID
        }

        private enum AltKeys: String, CodingKey {
            case codeTargetID = "code_target_id"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let a = try? decoder.container(keyedBy: AltKeys.self)
            kind = try c.decode(String.self, forKey: .kind)
            question = try c.decode(String.self, forKey: .question)
            explanation = try c.decode(String.self, forKey: .explanation)
            codeTargetID = (try? c.decode(String.self, forKey: .codeTargetID))
                ?? (try? a?.decode(String.self, forKey: .codeTargetID)) ?? ""
        }
    }

    private struct _QuizResponse: Codable {
        var questions: [_QuizQ]
    }

    private struct _QuizQ: Codable {
        var pageIndex: Int?
        var kind: String
        var question: String
        var choices: [String]
        var correctIndex: Int
        var explanation: String
        var understandingPointID: String
        var docEntityID: String

        private enum CodingKeys: String, CodingKey {
            case pageIndex
            case kind
            case question
            case choices
            case correctIndex = "correctIndex"
            case explanation
            case understandingPointID = "understandingPointID"
            case docEntityID = "docEntityID"
        }

        private enum AltKeys: String, CodingKey {
            case correctIndex = "correct_index"
            case understandingPointID = "understanding_point_id"
            case docEntityID = "doc_entity_id"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let a = try? decoder.container(keyedBy: AltKeys.self)
            pageIndex = try? c.decode(Int.self, forKey: .pageIndex)
            kind = try c.decode(String.self, forKey: .kind)
            question = try c.decode(String.self, forKey: .question)
            // 演習カードは選択肢を持たないため、choices/correctIndex は任意。
            choices = (try? c.decode([String].self, forKey: .choices)) ?? []
            correctIndex = (try? c.decode(Int.self, forKey: .correctIndex))
                ?? (try? a?.decode(Int.self, forKey: .correctIndex)) ?? 0
            explanation = try c.decode(String.self, forKey: .explanation)
            understandingPointID = (try? c.decode(String.self, forKey: .understandingPointID))
                ?? (try? a?.decode(String.self, forKey: .understandingPointID)) ?? ""
            docEntityID = (try? c.decode(String.self, forKey: .docEntityID))
                ?? (try? a?.decode(String.self, forKey: .docEntityID)) ?? ""
        }
    }

    private static func buildPrompt(
        paperKey: String,
        paperTitle: String,
        lang: String,
        questionCount: Int,
        sources: Inf6PaperQuizSourceBundle,
        requiredUnderstandingPointIDs: [String]? = nil
    ) -> String {

        let maxChars = 14_000
        let coverageTargets = sources.coverageTargets()
        let orderedCoverageTargets = coverageTargets.sorted { lhs, rhs in
            let lhsEntity = lhs.id.hasPrefix("doc-entity:")
            let rhsEntity = rhs.id.hasPrefix("doc-entity:")
            if lhsEntity != rhsEntity { return lhsEntity }
            let lhsPoint = lhs.id.hasPrefix("understanding-point-")
            let rhsPoint = rhs.id.hasPrefix("understanding-point-")
            if lhsPoint != rhsPoint { return lhsPoint }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }

        var evidence = ""
        evidence.reserveCapacity(min(maxChars, 16_000))

        func appendBlock(_ s: String) {
            if evidence.count >= maxChars { return }
            let remain = maxChars - evidence.count
            if s.count <= remain {
                evidence += s
            } else {
                evidence += String(s.prefix(remain))
            }
        }

        appendBlock("[PAPER]\nkey=\(paperKey)\ntitle=\(paperTitle)\n\n")

        for target in orderedCoverageTargets {
            let pagePart = target.pageIndex.map { " pageIndex=\($0)" } ?? ""
            appendBlock("[COVERAGE_TARGET id=\(target.id) kind=\(target.kind.rawValue)\(pagePart)]\n")
            appendBlock("title=\(target.title)\n")
            appendBlock("\(target.evidenceText)\n\n")
        }

        let abs = sources.abstractText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !abs.isEmpty {
            appendBlock("[ABSTRACT]\n\(abs)\n\n")
        }

        let pages = sources.pageNotes.keys.sorted()
        for p in pages {
            let notes = sources.pageNotes[p, default: []]
            guard !notes.isEmpty else { continue }
            let hasAssetFocused = notes.contains { Inf6PaperQuizSourceBundle._isAssetFocusedNote($0) }
            appendBlock("[\(hasAssetFocused ? "ASSET_PAGE_NOTES" : "PAGE_NOTES") pageIndex=\(p)]\n")
            for n in notes {
                if n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                appendBlock("- \(n)\n")
            }
            appendBlock("\n")
        }

        let mathPages = sources.mathCards.keys.sorted()
        for p in mathPages {
            let cards = sources.mathCards[p, default: []]
            guard !cards.isEmpty else { continue }
            appendBlock("[EQUATION_CARD_NOTES pageIndex=\(p)]\n")
            for c in cards {
                let t = c.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { continue }
                appendBlock("- (cardID=\(c.cardID)) \(t)\n")
            }
            appendBlock("\n")
        }

        let isEN = (lang == "en")
        let coverageCount = coverageTargets.filter { $0.id.hasPrefix("doc-entity:") }.count
        let requiredUPIDs: String = {
            if let explicit = requiredUnderstandingPointIDs {
                return explicit
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                    .joined(separator: "\n")
            }
            return coverageTargets
                .filter { $0.id.hasPrefix("understanding-point-") }
                .map(\.id)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .joined(separator: "\n")
        }()
        let allowedDocEntityIDs = coverageTargets
            .filter { $0.id.hasPrefix("doc-entity:") }
            .map { "\($0.id) kind=\($0.kind.rawValue)" }
            .joined(separator: "\n")

        let schema = """
{
  "questions": [
    {
      "pageIndex": 0,
      "kind": "equation|figure|table",
      "question": "string",
      "explanation": "string",
      "understandingPointID": "understanding-point-N",
      "docEntityID": "doc-entity:uuid"
    }
  ]
}
"""

        if isEN {
            let coverageInstruction: String = {
                guard coverageCount > 0 else {
                    return "- Figure/table/equation evidence is required; do not generate questions without it."
                }
                return """
- There are \(coverageCount) figure/table/equation explanation units in the evidence.
- For each understanding point, select the single figure/table/equation unit that most directly evidences that core-theory point.
- Prioritize E-certification style questions: read axes, compare metrics, interpret tables, and explain variables/objectives/relationships in equations.
"""
            }()

            return """
You are an exam-focused tutor for reading academic papers.

TASK:
- Create exactly \(questionCount) study items for this paper. These are not multiple-choice questions: emit no choices and no correctIndex.
- Use ONLY the evidence below (abstract, saved page notes, saved figure/table notes, saved equation-card explanations).
- Create exactly one question for each understanding-point target. The question count is the number of understanding points.
- Emit questions in ascending understanding-point number and include every understanding-point ID exactly once.
- Every question must cite exactly one understanding-point ID and assess that point's part of the core theory.
- `question` is not a question: it is a heading that states the point. One declarative sentence, at most 25 words.
- Interrogative form is forbidden — no "What is ...?", "Which of ...?", or "Explain ...". State the point outright.
- Name concretely which part of which figure, table, or equation the point concerns — but state the point, do not explain it.
- This is study practice, not a selection exam. There is no answer-choice format. Do not emit choices or correctIndex.
- The explanation must contain only the correct content for that point. State plainly what is true.
- Write no contrastive or negative sentences at all. Phrasings like "it is not X", "rather than X", "often confused with X", or "X is wrong" are forbidden — they blur the point and teach nothing.
- The explanation is a bullet list: one point per line, each line starting with "- ", two to five items. Do not write prose.
- List only what an E-Cert candidate absolutely must know. Omit details that do not affect answering, incidental experimental numbers, and background.
- Several items may draw on the same figure, table, or equation, but each must cover a different aspect. Never restate the same composition in other words. Differentiate by differing roles, differences between paired elements, data flow, conditions, or why the design is as it is.
- Each line states its point outright in at most 20 words. No preamble, no restatement, no closing summary.
- Do not pad with abstractions. Phrasings like "the flow is shown", "it realizes X", or "it has such a structure" are forbidden. Write the concrete values, symbols, relationships, and conditions read off the figure, table, or equation.
- Never paste the understanding-point text verbatim. Rewrite it as a well-formed question, and never use the words "understanding point" or "focus" in the stem.
- Every question must be grounded in exactly one figure/table/equation target and test the assigned core-theory understanding point through that evidence.
- Every question must cite exactly one doc-entity ID. Questions grounded only in overview or prose are forbidden.
- The selected doc-entity must encode the same proposition as the selected understanding-point. Its title, labels, variables, arrows, annotation, or contrast must be directly used by the question and explanation.
- Do not pair a generic diagram with an unrelated understanding point. If no doc-entity directly supports the understanding point, choose the closest concrete figure/table/equation and write only the part supported by that evidence.
- The figure/table/equation must not be used for a label, symbol, caption-number, or visual-recall question.
- Do NOT ask meta-questions about the figure/table itself (its "purpose", "intent", "what it shows", "why it was included"). Ask about the theory the evidence encodes: quantitative relationships, causes, conditions, trade-offs, and what follows when a parameter changes.
- Never hedge the stem with phrases like "though not directly readable from Table N". The stem must be consistent with the evidence, not disclaim it.
- Do NOT use outside knowledge. If a question cannot be grounded in evidence, do not invent it.
- Copy understandingPointID and docEntityID exactly from the COVERAGE_TARGET ids. Never combine them into one field and never invent an ID.
\(coverageInstruction)

OUTPUT:
- Return STRICT JSON ONLY (no markdown, no code fences).
- Must conform to this schema:
\(schema)

EVIDENCE (max \(maxChars) chars; may be truncated):
\(evidence)

REQUIRED UNDERSTANDING POINT IDS (one question for every line, in this order):
\(requiredUPIDs)

ALLOWED DOC ENTITY IDS (choose exactly one per question):
\(allowedDocEntityIDs)
"""
        } else {
            let coverageInstruction: String = {
                guard coverageCount > 0 else {
                    return "- 図表・数式の根拠は必須であり、存在しない場合は問題を生成しない。"
                }
                return """
- Evidence 内には、図表・式の解説ユニットが \(coverageCount) 件ある。
- 各understanding-pointについて、その中核理論を最も直接的に裏付ける図表・数式を1件選ぶ。
- 問い方は E資格レベルを優先し、軸・指標・比較・表の行列要素・数式の変数/目的関数/関係性を問う。
"""
            }()

            return """
あなたはE資格向けの「論文読解チューター」です。

【タスク】
- この論文について、演習項目をちょうど \(questionCount) 件作成する。選択式ではないため、choices と correctIndex は出力しない。
- 根拠は下の Evidence（要旨／保存済みページ解説／保存済み図表解説／保存済み数式カード解説）のみ。
- understanding-point ごとにちょうど1問を作る。問題数は understanding-point の件数と一致させる。
- understanding-point番号の昇順で出力し、すべてのIDを重複なく1回ずつ含める。
- 各問題は対応する understanding-point IDを1件だけ参照し、その理解点が表す中核理論を理解しているか判定する。
- question は設問ではなく、その理解点の要点を示す見出し文にする。60字以内の平叙文1文。
- 疑問形を禁止する。「〜は何か。」「〜はどれか。」「〜を説明してください」のような設問形式にしてはならない。要点をそのまま言い切ること。
- question には、図・表・数式のどの箇所の何を扱うのかを具体的に書く。ただし説明はせず、要点の提示にとどめる。
- これは選抜試験ではなく学習用の演習である。選択肢による出題形式を取らない。choices と correctIndex は出力しない。
- explanation には、その理解点の正しい内容だけを書く。何が正しいかを言い切ること。
- 対比・否定の文を一切書かないこと。「〜ではない」「〜ではなく」「〜と混同しやすい」「〜は誤り」といった、正しくないものに言及する文は禁止する。こうした文は要点をぼかすだけで、学習の役に立たない。
- explanation は箇条書きにする。1行1ポイントとし、各行を「・」で始める。項目は2〜5個。散文で書いてはならない。
- 挙げるのは、E資格の受験者が絶対に知っていなければならないポイントだけに限る。知らなくても解答に支障のない細部、実験条件の些末な数値、背景説明は書かない。
- 同じ図・表・数式を扱う項目が複数あってよいが、その場合は必ず異なる側面を書くこと。構成要素の列挙を言い換えただけの項目を並べてはならない。役割の違い、対になる要素の相違点、データの流れ、成立条件、なぜその設計なのかといった切り口で書き分ける。
- 各行は40字以内で言い切る。前置き・言い換え・まとめの行を入れない。
- 抽象的な言い回しで字数を埋めてはならない。「〜の流れが示されている」「〜を実現している」「〜という構造になっている」のような、具体を欠いた記述を禁止する。図・表・数式から読み取れる具体的な値、記号、関係、条件を書くこと。
- 理解点の文をそのまま貼り付けてはならない。設問として読める日本語に整えたうえで統合する。「観点」「理解点」という語自体を問題文に書かない。
- 各問題は図・表・数式のいずれか1件を主根拠とし、その根拠を通して対応する中核理論の理解点を問う。
- 各問題は doc-entity IDをちょうど1件参照する。概要や本文だけを根拠にした問題は禁止する。
- 選んだ doc-entity は、選んだ understanding-point と同じ命題を表していなければならない。title、ラベル、変数、矢印、annotation、contrast のいずれかを question と explanation で直接使う。
- 汎用的な図を無関係な理解点に割り当ててはならない。直接支える doc-entity が無い場合は、最も近い具体的な図・表・数式を選び、その根拠で言える範囲だけを書く。
- 図番号、記号名、キャプション、見た目だけを記憶しているか問う問題は禁止する。
- 図表・数式そのものの「意図」「目的」「何を示しているか」「なぜ載せたか」を問うメタ質問は禁止する。その図表・数式が符号化している理論の中身、すなわち量的関係、因果、成立条件、トレードオフ、パラメータを変えたときに何が起きるかを問うこと。
  例: 「この表の比較意図はどれか」は禁止。「系列長 n が表現次元 d を上回るとき、Self-Attention と Recurrent の1層あたり計算量の大小関係はどうなるか」は可。
- 「Table N から直接は読み取れないが」のような前置きを問題文に付けてはならない。設問は根拠と矛盾しない形で成立させること。
- Evidenceに根拠が取れない内容は作らない（外部知識禁止）。
- understandingPointID と docEntityID は COVERAGE_TARGET のidをそのまま別々のフィールドへ転記する。結合・省略・新規作成は禁止する。
- 全問題の kind は参照するdoc-entityに一致する figure/table/equation のいずれかとする。
- 図表数式番号を問題文に書く場合、参照した COVERAGE_TARGET の title 冒頭の番号をそのまま転記し、別番号を生成しないこと。
\(coverageInstruction)

【出力】
- JSONのみ（markdown禁止、コードフェンス禁止）。
- 次のスキーマに厳密準拠:
\(schema)

【Evidence】(最大 \(maxChars) 文字。末尾が切れている可能性あり)
\(evidence)

【必須understandingPointID】（各行につき1問、この順序で全件出力）
\(requiredUPIDs)

【使用可能docEntityID】（各問題で必ず1件選択）
\(allowedDocEntityIDs)
"""
        }
    }
}

// MARK: - Sheet UI (called from InlinePDFPagesView)

public struct Inf6PaperQuizSheet: View {
    let paperTitle: String
    let paperKey: String
    let baseDir: URL
    let genLangRaw: String
    let pageNotesProvider: () -> [Int: [String]]
    let mathCardsProvider: () -> [Int: [Inf6PaperQuizMathCardSource]]
    let askModel: (String) async throws -> String

    @Environment(\.dismiss) private var dismiss

    @State private var quiz: Inf6PaperQuiz? = nil
    @State private var loadError: String? = nil
    @State private var isGenerating: Bool = false
    @State private var genError: String? = nil
    @State private var selectedByQ: [UUID: Int] = [:]
    @State private var revealByQ: Set<UUID> = []

    @State private var sourceStats: Inf6PaperQuizSourceStats? = nil

    // MARK: - Presentation sizing (iPad/macOS sheet)

    #if os(iOS) || os(macOS)
    @State private var detent: PresentationDetent = .fraction(0.92)
    private let smallDetent: PresentationDetent = .fraction(0.45)
    private let largeDetent: PresentationDetent = .fraction(0.92)
    #endif

    @inline(__always)
    func L(_ ja: String, _ en: String) -> String {
        switch genLangRaw {
        case "ja": return ja
        case "en": return en
        default:
            let lang = (Locale.preferredLanguages.first ?? Locale.current.identifier).lowercased()
            return lang.hasPrefix("ja") ? ja : en
        }
    }

    private var lang: String { (genLangRaw == "en") ? "en" : "ja" }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {

                    VStack(alignment: .leading, spacing: 6) {
                        Text(paperTitle)
                            .font(.title2)
                            .lineLimit(2)
                        Text(L("保存先: paper.quiz.json", "Store: paper.quiz.json"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let loadError {
                        Text(loadError)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    HStack(spacing: 10) {
                        Spacer()

                        Button {
                            Task { await loadQuiz() }
                        } label: {
                            Label(L("再読込", "Reload"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isGenerating)
                    }

                    if let sourceStats {
                        Text(sourceStatsDescription(sourceStats))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        Button {
                            Task { await generateQuiz() }
                        } label: {
                            Label(L("生成", "Generate"), systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isGenerating)

                        if quiz != nil {
                            Button(role: .destructive) {
                                // wipe local progress (not storage)
                                selectedByQ = [:]
                                revealByQ = []
                            } label: {
                                Label(L("回答リセット", "Reset"), systemImage: "gobackward")
                            }
                            .buttonStyle(.bordered)
                            .disabled(isGenerating)
                        }

                        Spacer()

                        if isGenerating {
                            ProgressView().tint(.pink).scaleEffect(1.25)
                                .padding(.trailing, 4)
                            Text(L("生成中…", "Generating…"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let genError {
                        Text(genError)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    if let quiz {
                        Divider()
                        ForEach(quiz.questions) { q in
                            QuizQuestionCard(
                                q: q,
                                langRaw: genLangRaw,
                                selectedIndex: Binding(
                                    get: { selectedByQ[q.id] },
                                    set: { selectedByQ[q.id] = $0 }
                                ),
                                isRevealed: Binding(
                                    get: { revealByQ.contains(q.id) },
                                    set: { newVal in
                                        if newVal { revealByQ.insert(q.id) } else { revealByQ.remove(q.id) }
                                    }
                                )
                            )
                        }
                    } else {
                        Text(L(
                            "まだ演習がありません。保存済みの要旨・図表を含むページ解説・数式カード解説から生成します。",
                            "No exercises yet. They will be generated from saved abstract, page notes including figures/tables, and equation-card explanations."
                        ))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                    }
                }
                .padding(20)
            }
            .navigationTitle(L("演習", "Exercise"))
            .toolbar {
                #if os(iOS) || os(macOS)
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 8) {
                        Button {
                            detent = smallDetent
                        } label: {
                            Label(L("小", "Smaller"), systemImage: "minus")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            detent = largeDetent
                        } label: {
                            Label(L("大", "Larger"), systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                #endif

                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("閉じる", "Close")) { dismiss() }
                }
            }
            .task {
                await loadQuiz()
            }
        }
        #if os(iOS) || os(macOS)
        .presentationDetents([smallDetent, largeDetent], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: largeDetent))
        .interactiveDismissDisabled(true)
        #endif
    }

    @MainActor
    private func loadQuiz() async {
        loadError = nil
        genError = nil
        await refreshSourceStats()
        let loaded: Inf6PaperQuiz?
        do {
            loaded = try Inf6PaperQuizStore.load(baseDir: baseDir)
        } catch {
            quiz = nil
            loadError = "⚠︎ \(error.localizedDescription)"
            return
        }

        quiz = loaded

        do {
            if let loaded {
                try Inf6WatchConnectivityPhone.shared.send(quiz: loaded)
            } else {
                try Inf6WatchConnectivityPhone.shared.clearQuiz()
            }
        } catch {
            loadError = "⚠︎ Watch sync failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func generateQuiz() async {
        genError = nil
        loadError = nil
        isGenerating = true
        defer { isGenerating = false }

        do {
            let disk = try Inf6PaperQuizSourceBundle.loadFromDisk(baseDir: baseDir, paperKey: paperKey)
            let pageNotes = pageNotesProvider()
            let math = mathCardsProvider()
            let sources = Inf6PaperQuizSourceBundle(
                abstractText: disk.abstractText,
                pageNotes: pageNotes,
                mathCards: math
            )
            sourceStats = sources.stats

            let newQuiz = try await Inf6PaperQuizGenerator.generate(
                paperKey: paperKey,
                paperTitle: paperTitle,
                lang: lang,
                sources: sources,
                askModel: askModel
            )

            var enriched = newQuiz
            _attachEntityImages(to: &enriched)
            try Inf6PaperQuizStore.save(baseDir: baseDir, quiz: enriched)
            quiz = enriched
            selectedByQ = [:]
            revealByQ = []
            do {
                try Inf6WatchConnectivityPhone.shared.send(quiz: newQuiz)
            } catch {
                genError = "⚠︎ Watch sync failed: \(error.localizedDescription)"
            }
        } catch {
            genError = "⚠︎ \(error.localizedDescription)"
        }
    }

    private func _attachEntityImages(to quiz: inout Inf6PaperQuiz) {
        guard let index = Inf6MetadataStore.getCodable(Inf6DocEntityIndex.self, domain: .docEntities, key: paperKey) else { return }
        let entities = index.entities.filter { $0.imagePath != nil }
        guard !entities.isEmpty else { return }

        for i in quiz.questions.indices {
            let q = quiz.questions[i]
            guard q.entityImagePath == nil else { continue }
            let kind: Inf6DocEntityKind? = {
                switch q.kind.lowercased() {
                case "figure": return .figure
                case "table": return .table
                case "equation": return .equation
                default: return nil
                }
            }()
            guard let kind else { continue }
            let targetTitles = Set((q.coverageTargetIDs ?? []).compactMap { targetID in
                quiz.coverageTargets?.first(where: { $0.id == targetID })?.title
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            })
            let matches = entities.filter {
                $0.kind == kind
                    && targetTitles.contains($0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
            guard matches.count == 1, let entity = matches.first else { continue }
            quiz.questions[i].docEntityID = entity.id
            quiz.questions[i].entityImagePath = entity.imagePath
            quiz.questions[i].pageIndex = entity.pageIndex
        }
    }

    @MainActor
    private func refreshSourceStats() async {
        do {
            let disk = try Inf6PaperQuizSourceBundle.loadFromDisk(baseDir: baseDir, paperKey: paperKey)
            let pageNotes = pageNotesProvider()
            let math = mathCardsProvider()
            let sources = Inf6PaperQuizSourceBundle(
                abstractText: disk.abstractText,
                pageNotes: pageNotes,
                mathCards: math
            )
            sourceStats = sources.stats
        } catch {
            sourceStats = nil
            loadError = "⚠︎ \(error.localizedDescription)"
        }
    }

    private func sourceStatsDescription(_ stats: Inf6PaperQuizSourceStats) -> String {
        return L(
            "問題数は概要解説に構造化された理解点の件数で決まります。図表ノート \(stats.assetNoteItems) 件と数式カード \(stats.mathCardExplanations) 件は理解点の根拠として使用されます。",
            "The question count is determined by the structured understanding points in the overview. The \(stats.assetNoteItems) figure/table notes and \(stats.mathCardExplanations) equation cards are used as evidence for those points."
        )
    }
}

extension InlinePDFPagesView {
    @MainActor
    func _generateAndPersistQuizFromCurrentSources() async throws {
        guard let baseDir = _paperBaseDir() else {
            throw Inf6PaperQuizError.storageUnavailable("[Quiz] paper directory is unavailable.")
        }

        let paperKey = _pdfBaseName(from: _activeURL).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paperKey.isEmpty else {
            throw Inf6PaperQuizError.invalidSource("[Quiz] paperKey is empty for auto generation.")
        }

        let paperTitleTrimmed = pdfTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let paperTitle = paperTitleTrimmed.isEmpty ? paperKey : paperTitleTrimmed
        let lang = (genLangRaw == "en") ? "en" : "ja"

        let disk = try Inf6PaperQuizSourceBundle.loadFromDisk(baseDir: baseDir, paperKey: paperKey)
        let sources = Inf6PaperQuizSourceBundle(
            abstractText: disk.abstractText,
            pageNotes: _currentQuizPageNotes(),
            mathCards: _currentQuizMathCardSources()
        )
        guard sources.hasAnyContent else {
            throw Inf6PaperQuizError.invalidSource("[Quiz] no sources available for automatic regeneration.")
        }

        let newQuiz = try await Inf6PaperQuizGenerator.generate(
            paperKey: paperKey,
            paperTitle: paperTitle,
            lang: lang,
            sources: sources,
            askModel: { prompt in
                let promptRef = (lang == "en")
                    ? Inf6PromptCatalog.quizPromptBridgeEn
                    : Inf6PromptCatalog.quizPromptBridgeJa
                let rendered = try Inf6PromptGovernance.renderSystemUserPrompt(
                    ref: promptRef,
                    variables: ["task_prompt": prompt]
                )
                return try await Inf6LibraryView.askOpenAIText(
                    systemInstruction: rendered.systemInstruction,
                    userPrompt: rendered.userPrompt,
                    lang: lang
                )
            }
        )

        try Inf6PaperQuizStore.save(baseDir: baseDir, quiz: newQuiz)
        try Inf6WatchConnectivityPhone.shared.send(quiz: newQuiz)
        _autoQuizLastError = nil
    }

    @MainActor
    func _scheduleAutoQuizRegeneration() {
        _inFlightAutoQuizRegenerationTask?.cancel()
        _inFlightAutoQuizRegenerationTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 800_000_000)
                try Task.checkCancellation()
                try await _generateAndPersistQuizFromCurrentSources()
            } catch is CancellationError {
                return
            } catch {
                _autoQuizLastError = L(
                    "演習自動生成に失敗しました: \(error.localizedDescription)",
                    "Automatic exercise generation failed: \(error.localizedDescription)"
                )
            }
        }
    }
}

// MARK: - Question UI

struct _Inf6PinchZoomImage: UIViewRepresentable {
    let image: UIImage
    let onTap: (() -> Void)?
    @Binding var zoomScale: CGFloat

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        var onTap: (() -> Void)?
        var zoomScale: Binding<CGFloat>

        init(onTap: (() -> Void)?, zoomScale: Binding<CGFloat>) {
            self.onTap = onTap
            self.zoomScale = zoomScale
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let value = scrollView.zoomScale
            guard abs(zoomScale.wrappedValue - value) > 0.01 else { return }
            DispatchQueue.main.async { self.zoomScale.wrappedValue = value }
        }

        @objc func tapped() { onTap?() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap, zoomScale: $zoomScale) }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 8
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.clipsToBounds = true

        let imageView = context.coordinator.imageView
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.addGestureRecognizer(UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.tapped)
        ))
        scrollView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView.image = image
        context.coordinator.onTap = onTap
        context.coordinator.zoomScale = $zoomScale
        let resolved = min(max(zoomScale, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
        if abs(scrollView.zoomScale - resolved) > 0.01 {
            scrollView.setZoomScale(resolved, animated: false)
        }
    }
}

struct QuizQuestionCard: View {
    let q: Inf6PaperQuizQuestion
    let langRaw: String

    @Binding var selectedIndex: Int?
    @Binding var isRevealed: Bool
    var fontScale: CGFloat = 1.0
    var entityImageMaxHeight: CGFloat = 200
    var tint: Color? = nil
    var textTint: Color? = nil
    var secondaryTextTint: Color? = nil
    var onImageTap: (() -> Void)? = nil
    @State private var _imageZoomScale: CGFloat = 1
    @State private var _loadedImage: UIImage? = nil
    @State private var _imageLoadAttempted = false

    @inline(__always)
    func L(_ ja: String, _ en: String) -> String {
        switch langRaw {
        case "ja": return ja
        case "en": return en
        default:
            let lang = (Locale.preferredLanguages.first ?? Locale.current.identifier).lowercased()
            return lang.hasPrefix("ja") ? ja : en
        }
    }

    private var _safeFontScale: CGFloat {
        guard fontScale.isFinite else { return 1.0 }
        return min(max(fontScale, 0.85), 2.20)
    }

    private func _font(_ base: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: base * _safeFontScale, weight: weight)
    }

    private var _safeEntityImageMaxHeight: CGFloat {
        guard entityImageMaxHeight.isFinite else { return 200 }
        return min(max(entityImageMaxHeight, 200), 720)
    }

    private var _textTint: Color {
        textTint ?? .primary
    }

    private var _secondaryTextTint: Color {
        secondaryTextTint ?? .secondary
    }

    private func _loadEntityImageAsync() async -> UIImage? {
        guard let rel = q.entityImagePath else { return nil }
        let base = Inf6Storage.homeDirectory()
            .deletingLastPathComponent()
            .appendingPathComponent("entity_images")
        let url = base.appendingPathComponent(rel)
        return await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return nil as UIImage? }
            return UIImage(data: data)
        }.value
    }

    private func _initialImageHeight(_ image: UIImage) -> CGFloat {
        Inf6EntityImageReadabilitySizer.initialHeight(
            image: image,
            bodyPointSize: 17 * _safeFontScale,
            entityImageMaxHeight: _safeEntityImageMaxHeight,
            maxRenderableHeight: 5_760,
            maxZoomScale: 8
        )
    }

    private var _kindTint: Color {
        switch q.kind.lowercased() {
        case "figure": return .blue
        case "table": return .orange
        case "equation": return .purple
        case "code": return .green
        default: return tint ?? .accentColor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(kindLabel(q.kind))
                            .font(_font(12))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(_kindTint.opacity(0.12))
                            .clipShape(Capsule())
                            .foregroundStyle(_kindTint)
                        if let p = q.pageIndex {
                            Text(L("ページ \(p + 1)", "Page \(p + 1)"))
                                .font(_font(12))
                                .foregroundStyle(_secondaryTextTint)
                        }
                    }
                    if let img = _loadedImage {
                        VStack(spacing: 8) {
                            _Inf6PinchZoomImage(image: img, onTap: onImageTap, zoomScale: $_imageZoomScale)
                                .frame(maxWidth: .infinity)
                                .frame(height: _initialImageHeight(img) * _imageZoomScale)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(onImageTap != nil ? (tint ?? .accentColor).opacity(0.5) : Color.secondary.opacity(0.2), lineWidth: onImageTap != nil ? 2 : 1)
                                }
                            HStack(spacing: 10) {
                                Button {
                                    _imageZoomScale = max(1, _imageZoomScale - 0.5)
                                } label: {
                                    Image(systemName: "minus.magnifyingglass")
                                }
                                .buttonStyle(.bordered)
                                .disabled(_imageZoomScale <= 1)
                                .accessibilityLabel(L("縮小", "Zoom out"))

                                Slider(value: $_imageZoomScale, in: 1...8, step: 0.1)
                                    .accessibilityLabel(L("画像倍率", "Image zoom"))

                                Button {
                                    _imageZoomScale = min(8, _imageZoomScale + 0.5)
                                } label: {
                                    Image(systemName: "plus.magnifyingglass")
                                }
                                .buttonStyle(.bordered)
                                .disabled(_imageZoomScale >= 8)
                                .accessibilityLabel(L("拡大", "Zoom in"))

                                Button("\(Int((_imageZoomScale * 100).rounded()))%") {
                                    _imageZoomScale = 1
                                }
                                .buttonStyle(.bordered)
                                .accessibilityLabel(L("倍率を100%に戻す", "Reset zoom to 100 percent"))
                            }
                        }
                    }
                    Text(q.question)
                        .font(_font(17))
                        .foregroundStyle(_textTint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    isRevealed.toggle()
                } label: {
                    Label(isRevealed ? L("隠す", "Hide") : L("答え", "Reveal"),
                          systemImage: isRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(q.choices.enumerated()), id: \.offset) { (i, c) in
                    let picked = (selectedIndex == i)
                    let isCorrect = i == q.correctIndex
                    let choiceFill: Color = {
                        guard isRevealed else {
                            return picked ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04)
                        }
                        if isCorrect { return Color.green.opacity(0.15) }
                        if picked { return Color.red.opacity(0.12) }
                        return Color.primary.opacity(0.04)
                    }()
                    let choiceStroke: Color = {
                        guard isRevealed else {
                            return picked ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.10)
                        }
                        if isCorrect { return Color.green.opacity(0.65) }
                        if picked { return Color.red.opacity(0.55) }
                        return Color.secondary.opacity(0.10)
                    }()

                    Button {
                        selectedIndex = i
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Text(choicePrefix(i))
                                .font(_font(16))
                                .monospacedDigit()
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(_kindTint.opacity(0.14)))
                                .foregroundStyle(_kindTint)
                            Text(c)
                                .font(_font(17))
                                .foregroundStyle(_textTint)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            if isRevealed && isCorrect {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else if isRevealed && picked {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                            } else if picked {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(10)
                        .background(choiceFill)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(choiceStroke, lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }
            }

            if isRevealed {
                let ok = (selectedIndex == q.correctIndex)
                VStack(alignment: .leading, spacing: 6) {
                    Text(ok ? L("正解", "Correct") : L("不正解", "Incorrect"))
                        .font(_font(12))
                        .foregroundStyle(ok ? .green : .red)
                    Text(L("答え: ", "Answer: ") + choicePrefix(q.correctIndex))
                        .font(_font(16))
                        .foregroundStyle(_textTint)
                    if q.kind.lowercased() == "code" {
                        Inf6CodePracticeExplanationView(
                            text: q.explanation,
                            fontScale: _safeFontScale,
                            tint: _kindTint,
                            textTint: _secondaryTextTint
                        )
                    } else {
                        Text(q.explanation)
                            .font(_font(17))
                            .foregroundStyle(_secondaryTextTint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .background((ok ? Color.green : Color.red).opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(12)
        .textSelection(.enabled)
        .background(_kindTint.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(_kindTint.opacity(0.18), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .task(id: q.entityImagePath) {
            guard !_imageLoadAttempted else { return }
            _imageLoadAttempted = true
            _loadedImage = await _loadEntityImageAsync()
        }
    }

    private func kindLabel(_ k: String) -> String {
        let t = k.lowercased()
        switch t {
        case "equation": return L("数式", "Equation")
        case "figure": return L("図", "Figure")
        case "table": return L("表", "Table")
        case "code": return L("Python", "Python")
        default: return L("本文", "Text")
        }
    }

    private func choicePrefix(_ i: Int) -> String {
        switch i {
        case 0: return "A"
        case 1: return "B"
        case 2: return "C"
        default: return "D"
        }
    }
}
