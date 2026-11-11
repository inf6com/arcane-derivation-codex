//
//  Inf6MMAComposer.swift
//  inf6
//
//  正本仕様: SPEC.md
//
//  MMA 工程 3: CoverageQuestionComposition（経脈網羅作問）
//
//  - `Inf6MMAComposer` : CoreKnowledgeSet → GeneratedQuestion[]（OpenAI 呼び出し）
//  - `Inf6MMAQuizStore` : MMA 問題集の永続化（sharedRoot/mma/<qualId>/quiz.json）
//  - `Inf6MMAFullPipeline` : 工程 1〜3 を一括実行する統合 API
//

import Foundation

// MARK: - 工程 3: CoverageQuestionComposition

/// CoreKnowledgeSet から coverageTargets 付き問題群を生成する。
public enum Inf6MMAComposer {

    // MARK: - 公開 API

    /// 問題群を生成する。
    /// - Parameters:
    ///   - core: 工程 2 出力（KnowledgeAtom[] / KnowledgeEdge[]）。
    ///   - masteryState: 既存の習得状態（nil なら全原子 unverified と扱う）。
    ///   - questionCount: 目標問題数（実際の出力は前後する場合がある）。
    ///   - lang: "ja" | "en"。
    ///   - client: OpenAIClient。
    /// - Returns: GeneratedQuestion[]（coverageTargets 必須）。
    public static func compose(
        core: Inf6CoreKnowledgeSet,
        masteryState: Inf6MasteryState?,
        questionCount: Int,
        lang: String,
        client: OpenAIClient
    ) async throws -> [Inf6GeneratedQuestion] {
        let coreJSON = (try? String(data: _encode(core), encoding: .utf8)) ?? "{}"
        let stateJSON = masteryState.flatMap { try? String(data: _encode($0), encoding: .utf8) } ?? "null"
        let weakTargetSummary = _weakTargetSummary(core: core, masteryState: masteryState, lang: lang)

        let systemPrompt = _composerSystemPrompt(lang: lang)
        let userPrompt   = _composerUserPrompt(
            coreJSON: coreJSON,
            stateJSON: stateJSON,
            weakTargetSummary: weakTargetSummary,
            questionCount: questionCount,
            lang: lang
        )

        let raw: String
        do {
            raw = try await client.generateText(
                messages: [
                    .init(role: .system, text: systemPrompt),
                    .init(role: .user,   text: userPrompt)
                ],
                options: .init(maxOutputTokens: 14000)
            )
        } catch {
            throw Inf6MMAError.openAIFailure(error)
        }

        return try _parseQuestions(raw: raw)
    }

    // MARK: - プロンプト

    private static func _composerSystemPrompt(lang: String) -> String {
        let langNote = lang == "ja"
            ? "問題文・選択肢・解説はすべて日本語で出力する。"
            : "Output question, choices, and explanation in English."
        return """
        You are an expert question author for professional certification exams.
        \(langNote)

        Given a CoreKnowledgeSet JSON (atoms + edges) and optional MasteryState, \
        generate exam questions that collectively cover all atoms and important edges.

        Output ONLY a valid JSON array — no markdown, no prose outside JSON.
        Each element follows this schema:
        {
          "id": "<uuid>",
          "createdAt": <unix-seconds as number>,
          "prompt": "<question text>",
          "choices": ["<A>", "<B>", "<C>", "<D>"],
          "correctIndex": <0-based integer>,
          "explanation": "<why correct + why others wrong, cite sourceURLs>",
          "questionType": "definition"|"comparison"|"prerequisite"|"order"|"setting"|"error_cause"|"renaming"|"decision",
          "coverageTargetIDs": ["<atomId or edgeId>"],
          "knowledgeAtomIDs": ["<atomId>"],
          "knowledgeEdgeIDs": ["<edgeId>"],
          "sourceURLs": ["<url>"]
        }

        Rules:
        - Every question MUST have at least 1 coverageTargetID (atom or edge).
        - Every question MUST have at least 1 sourceURL from the atom/edge evidence.
        - Include at least 1 question of each of the 8 questionTypes if enough atoms/edges exist.
        - If MasteryState is provided, prioritize atoms/edges with state "unverified" or "wrong".
        - For certification domains such as Microsoft Learn and AI-102, prefer scenario-based implementation questions over glossary-like definition questions.
        - Use concrete operational context: portal selection, service selection, setting, prerequisite, failure cause, order, naming update, or design decision.
        - Distractors must stay in the same product neighborhood and must be realistically confusable to a practitioner.
        - If weak targets are supplied, spend a clear majority of the questions on those weak targets until they are sufficiently covered.
        - Do not generate vague academic prompts; write exam-grade questions similar in density to professional certification items.
        - Do NOT produce questions without coverageTargetIDs — this violates the contract.
        - Distractors must be plausible; use misconceptionNotes when available.
        - Output: a single JSON array of question objects.
        """
    }

    private static func _composerUserPrompt(
        coreJSON: String,
        stateJSON: String,
        weakTargetSummary: String,
        questionCount: Int,
        lang: String
    ) -> String {
        let truncatedCore = String(coreJSON.prefix(14000))
        return """
        Target question count: \(questionCount)
        Language: \(lang)
        MasteryState: \(stateJSON)
        Weak targets to prioritize:
        \(weakTargetSummary)

        CoreKnowledgeSet JSON:
        ---
        \(truncatedCore)
        ---

        Generate the question array now. Every question must include coverageTargetIDs.
        coverageTargetIDs must use the exact atom or edge IDs already present in the CoreKnowledgeSet.
        """
    }

    private static func _weakTargetSummary(
        core: Inf6CoreKnowledgeSet,
        masteryState: Inf6MasteryState?,
        lang: String
    ) -> String {
        guard let masteryState else {
            return lang == "ja"
                ? "既存の MasteryState はありません。すべての原子・経脈を未確認として扱ってください。"
                : "No existing mastery state. Treat all atoms and edges as unverified."
        }

        func priority(_ level: Inf6MasteryLevel) -> Int {
            switch level {
            case .wrong: return 0
            case .unverified: return 1
            case .inProgress: return 2
            case .verified: return 3
            }
        }

        let atomLines = core.atoms
            .filter { masteryState.atomLevel($0.id) != .verified }
            .sorted {
                let left = priority(masteryState.atomLevel($0.id))
                let right = priority(masteryState.atomLevel($1.id))
                if left != right { return left < right }
                return $0.id < $1.id
            }
            .prefix(18)
            .map { atom in
                let level = masteryState.atomLevel(atom.id).rawValue
                return "- [\(level)] atom \(atom.id): \(atom.content)"
            }

        let atomsByID = Dictionary(uniqueKeysWithValues: core.atoms.map { ($0.id, $0.content) })
        let edgeLines = core.edges
            .filter { masteryState.edgeLevel($0.id) != .verified }
            .sorted {
                let left = priority(masteryState.edgeLevel($0.id))
                let right = priority(masteryState.edgeLevel($1.id))
                if left != right { return left < right }
                return $0.id < $1.id
            }
            .prefix(18)
            .map { edge in
                let level = masteryState.edgeLevel(edge.id).rawValue
                let from = atomsByID[edge.fromAtomID] ?? edge.fromAtomID
                let to = atomsByID[edge.toAtomID] ?? edge.toAtomID
                return "- [\(level)] edge \(edge.id): \(edge.kind.rawValue) | \(from) -> \(to)"
            }

        let lines = atomLines + edgeLines
        if lines.isEmpty {
            return lang == "ja"
                ? "既存の弱点はありません。全範囲を均等に被覆してください。"
                : "No weak targets remain. Cover the full range evenly."
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - パース

    private static func _parseQuestions(raw: String) throws -> [Inf6GeneratedQuestion] {
        let jsonString = _extractJSONArray(from: raw)
        guard let data = jsonString.data(using: .utf8) else {
            throw Inf6MMAError.jsonParseFailure("UTF-8 conversion failed")
        }
        do {
            return try JSONDecoder().decode([Inf6GeneratedQuestion].self, from: data)
        } catch {
            throw Inf6MMAError.jsonParseFailure(error.localizedDescription)
        }
    }

    private static func _extractJSONArray(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") { return trimmed }
        if let start = trimmed.range(of: "["), let end = trimmed.range(of: "]", options: .backwards) {
            return String(trimmed[start.lowerBound...end.upperBound])
        }
        return trimmed
    }

    private static func _encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }
}

// MARK: - MMA クイズ永続化

/// MMA 問題集を sharedRoot/mma/<qualId>/quiz.json に保存 / 読み込みする。
public enum Inf6MMAQuizStore {

    public struct MMAQuiz: Codable, Hashable {
        public var qualificationId: String
        public var goal: String
        public var generatedAt: String
        public var questions: [Inf6GeneratedQuestion]
        public var masteryState: Inf6MasteryState
        public var sourceURLs: [String]
    }

    public static func quizURL(qualificationId: String) throws -> URL {
        let dir = try _mmaDir(qualificationId: qualificationId)
        return dir.appendingPathComponent("quiz.json")
    }

    public static func load(qualificationId: String) throws -> MMAQuiz? {
        // metadata file store first
        if let cached = Inf6MetadataStore.getCodable(MMAQuiz.self, domain: .mmaQuestions, key: qualificationId) {
            return cached
        }
        // JSON fallback
        let url = try quizURL(qualificationId: qualificationId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let quiz = try JSONDecoder().decode(MMAQuiz.self, from: data)
        // Migrate
        Inf6MetadataStore.putCodable(quiz, domain: .mmaQuestions, key: qualificationId)
        return quiz
    }

    public static func save(_ quiz: MMAQuiz, qualificationId: String) throws {
        // metadata file store
        Inf6MetadataStore.putCodable(quiz, domain: .mmaQuestions, key: qualificationId)
        // JSON backward compat
        let url = try quizURL(qualificationId: qualificationId)
        let data = try JSONEncoder().encode(quiz)
        try data.write(to: url, options: .atomic)
    }

    /// MasteryState のみを更新して保存する。
    public static func updateMastery(
        qualificationId: String,
        mastery: Inf6MasteryState
    ) throws {
        guard var quiz = try load(qualificationId: qualificationId) else { return }
        quiz.masteryState = mastery
        try save(quiz, qualificationId: qualificationId)
    }

    private static func _mmaDir(qualificationId: String) throws -> URL {
        let root = Inf6DataRoot.url()
        let dir = root.appendingPathComponent("mma/\(qualificationId)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - 統合パイプライン

/// MMA 工程 1〜3 を一括実行する。
///
/// 呼び元（SyllabusDetailView など）は、知識源アダプタでテキストを正規化し、
/// この API を 1 回呼ぶだけで問題集まで生成できる。
public enum Inf6MMAFullPipeline {

    public struct Result {
        public var skeleton: Inf6KnowledgeSkeleton
        public var core: Inf6CoreKnowledgeSet
        public var questions: [Inf6GeneratedQuestion]
        public var quiz: Inf6MMAQuizStore.MMAQuiz
    }

    /// Microsoft Learn 向け統合実行。
    public static func runMicrosoftLearn(
        moduleTexts: [(url: String, text: String)],
        qualificationId: String,
        qualificationTitle: String,
        goal: String,
        questionCount: Int,
        lang: String,
        client: OpenAIClient
    ) async throws -> Result {
        let (skeleton, core) = try await Inf6MMAMicrosoftLearnAdapter.runPipeline(
            moduleTexts: moduleTexts,
            qualificationId: qualificationId,
            qualificationTitle: qualificationTitle,
            goal: goal,
            client: client
        )
        return try await _finalize(
            skeleton: skeleton, core: core,
            qualificationId: qualificationId, goal: goal,
            questionCount: questionCount, lang: lang, client: client
        )
    }

    /// JDLA シラバス PDF 向け統合実行。
    public static func runJdla(
        pageTexts: [Int: String],
        pdfRelPath: String,
        qualificationId: String,
        qualificationTitle: String,
        goal: String,
        questionCount: Int,
        lang: String,
        client: OpenAIClient
    ) async throws -> Result {
        let (skeleton, core) = try await Inf6MMAJdlaSyllabusAdapter.runPipeline(
            pageTexts: pageTexts,
            pdfRelPath: pdfRelPath,
            qualificationId: qualificationId,
            qualificationTitle: qualificationTitle,
            goal: goal,
            client: client
        )
        return try await _finalize(
            skeleton: skeleton, core: core,
            qualificationId: qualificationId, goal: goal,
            questionCount: questionCount, lang: lang, client: client
        )
    }

    // MARK: - 内部: 工程 3 + 保存

    private static func _finalize(
        skeleton: Inf6KnowledgeSkeleton,
        core: Inf6CoreKnowledgeSet,
        qualificationId: String,
        goal: String,
        questionCount: Int,
        lang: String,
        client: OpenAIClient
    ) async throws -> Result {
        // 既存の MasteryState があれば読み込んで適応型出題に使う
        let existingMastery = (try? Inf6MMAQuizStore.load(qualificationId: qualificationId))?.masteryState

        let questions = try await Inf6MMAComposer.compose(
            core: core,
            masteryState: existingMastery,
            questionCount: questionCount,
            lang: lang,
            client: client
        )

        // 初期 MasteryState：全原子・全経脈を unverified で初期化
        let initialAtomStates = Dictionary(
            uniqueKeysWithValues: core.atoms.map { ($0.id, Inf6MasteryLevel.unverified) }
        )
        let initialEdgeStates = Dictionary(
            uniqueKeysWithValues: core.edges.map { ($0.id, Inf6MasteryLevel.unverified) }
        )
        let mastery = existingMastery ?? Inf6MasteryState(
            atomStates: initialAtomStates,
            edgeStates: initialEdgeStates
        )

        let quiz = Inf6MMAQuizStore.MMAQuiz(
            qualificationId: qualificationId,
            goal: goal,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            questions: questions,
            masteryState: mastery,
            sourceURLs: core.sourceURLs
        )

        // 骨格 / コアナレッジ / クイズを保存
        if let skeletonData = try? JSONEncoder().encode(skeleton) {
            let url = try Inf6MMAStore.skeletonURL(qualificationId: qualificationId)
            try skeletonData.write(to: url, options: .atomic)
        }
        if let coreData = try? JSONEncoder().encode(core) {
            let url = try Inf6MMAStore.coreKnowledgeURL(qualificationId: qualificationId)
            try coreData.write(to: url, options: .atomic)
        }
        try Inf6MMAQuizStore.save(quiz, qualificationId: qualificationId)

        return Result(skeleton: skeleton, core: core, questions: questions, quiz: quiz)
    }
}
