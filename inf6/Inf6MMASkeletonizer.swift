//
//  Inf6MMASkeletonizer.swift
//  inf6
//
//  正本仕様: Design.md
//
//  MMA 工程 1: SyllabusSkeletonization（シラバス骨格化）
//  MMA 工程 2: CoreKnowledgeResolution（コアナレッジ判定）
//
//  - `Inf6MMASkeletonizer` : シラバステキストを KnowledgeSkeleton JSON に変換（OpenAI 呼び出し）
//  - `Inf6MMACoreKnowledgeResolver` : KnowledgeSkeleton から KnowledgeAtom[] / KnowledgeEdge[] を生成
//
//  知識源アダプタ（MicrosoftLearn / JDLA）は、入力テキストを正規化して共通パイプラインへ渡す。
//  本体パイプラインは知識源で分岐しない。
//

import Foundation

// MARK: - KnowledgeSkeleton（工程 1 出力 / 工程 2 入力）

/// シラバスを骨格化した中間物。章 / 節 / トピック / 要求能力 の木構造。
public struct Inf6KnowledgeSkeleton: Codable, Hashable {
    public struct SkeletonNode: Codable, Hashable, Identifiable {
        public var id: String
        public var level: NodeLevel
        public var title: String
        public var claims: [String]           // この節が含む主張（原子化前）
        public var evidenceURL: String?        // Learn URL または "pdf:<relPath>:<page>"
        public var children: [SkeletonNode]

        public enum NodeLevel: String, Codable, Hashable {
            case chapter = "chapter"
            case section = "section"
            case topic   = "topic"
            case ability = "ability"           // 要求能力
        }
    }

    /// 対象資格 ID（qualificationId / "jdla" など）。
    public var qualificationId: String
    /// 対象資格名。
    public var qualificationTitle: String
    /// シラバス骨格のルートノード群。
    public var nodes: [SkeletonNode]
    /// 生成日時（ISO-8601）。
    public var generatedAt: String
    /// 使用した知識源の URL / ファイルパス一覧。
    public var sourceURLs: [String]
}

// MARK: - CoreKnowledgeSet（工程 2 出力 / 工程 3 入力）

/// 目標達成に必要十分な原子 / 経脈の部分集合。
public struct Inf6CoreKnowledgeSet: Codable, Hashable {
    public var qualificationId: String
    public var goal: String                    // 例: "AI-102 合格"
    public var atoms: [Inf6KnowledgeAtom]
    public var edges: [Inf6KnowledgeEdge]
    public var generatedAt: String
    public var sourceURLs: [String]
}

// MARK: - 保存先

public enum Inf6MMAStore {
    /// shared root 配下の MMA ディレクトリ。
    public static func skeletonURL(qualificationId: String) throws -> URL {
        let dir = try _mmaDir(qualificationId: qualificationId)
        return dir.appendingPathComponent("skeleton.json")
    }

    public static func coreKnowledgeURL(qualificationId: String) throws -> URL {
        let dir = try _mmaDir(qualificationId: qualificationId)
        return dir.appendingPathComponent("core_knowledge.json")
    }

    /// core_knowledge.json を読み込む。存在しない場合は nil。
    public static func loadCoreKnowledge(qualificationId: String) throws -> Inf6CoreKnowledgeSet? {
        let url = try coreKnowledgeURL(qualificationId: qualificationId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Inf6CoreKnowledgeSet.self, from: data)
    }

    private static func _mmaDir(qualificationId: String) throws -> URL {
        let root = Inf6DataRoot.url()
        let dir = root.appendingPathComponent("mma/\(qualificationId)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - エラー

public enum Inf6MMAError: LocalizedError {
    case noSharedRoot
    case emptyInput
    case jsonParseFailure(String)
    case openAIFailure(Error)

    public var errorDescription: String? {
        switch self {
        case .noSharedRoot:         return "共有フォルダが設定されていません"
        case .emptyInput:           return "入力テキストが空です"
        case .jsonParseFailure(let d): return "JSON 解析失敗: \(d)"
        case .openAIFailure(let e): return "OpenAI エラー: \(e.localizedDescription)"
        }
    }
}

// MARK: - 工程 1: SyllabusSkeletonization

/// シラバステキスト（または URL 群の連結テキスト）を KnowledgeSkeleton JSON に変換する。
///
/// 知識源アダプタは入力テキストを正規化してこのクラスへ渡す。
/// 本体パイプラインは知識源で分岐しない。
public enum Inf6MMASkeletonizer {

    // MARK: - 公開 API

    /// シラバステキストを骨格化する。
    /// - Parameters:
    ///   - text: シラバス原文（テキスト抽出済）。空の場合はエラー。
    ///   - qualificationId: 資格 ID（保存先ディレクトリ名に使用）。
    ///   - qualificationTitle: 資格名（人間可読）。
    ///   - sourceURLs: 根拠 URL / ファイルパス一覧。
    ///   - client: OpenAIClient（呼び元から注入）。
    /// - Returns: KnowledgeSkeleton（保存前）。
    public static func skeletonize(
        text: String,
        qualificationId: String,
        qualificationTitle: String,
        sourceURLs: [String],
        client: OpenAIClient
    ) async throws -> Inf6KnowledgeSkeleton {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Inf6MMAError.emptyInput }

        let systemPrompt = _skeletonizerSystemPrompt()
        let userPrompt   = _skeletonizerUserPrompt(
            text: trimmed,
            qualificationId: qualificationId,
            qualificationTitle: qualificationTitle,
            sourceURLs: sourceURLs
        )

        let raw: String
        do {
            raw = try await client.generateText(
                messages: [
                    .init(role: .system, text: systemPrompt),
                    .init(role: .user,   text: userPrompt)
                ],
                options: .init(maxOutputTokens: 8000)
            )
        } catch {
            throw Inf6MMAError.openAIFailure(error)
        }

        return try _parseSkeleton(raw: raw, qualificationId: qualificationId,
                                  qualificationTitle: qualificationTitle, sourceURLs: sourceURLs)
    }

    // MARK: - プロンプト

    private static func _skeletonizerSystemPrompt() -> String {
        """
        You are an expert knowledge architect. Your task is to convert a certification syllabus \
        into a structured JSON skeleton following a strict schema.

        Output ONLY valid JSON with no markdown fences, no explanations outside the JSON.
        The schema is:
        {
          "qualificationId": "<string>",
          "qualificationTitle": "<string>",
          "generatedAt": "<ISO-8601>",
          "sourceURLs": ["<url>"],
          "nodes": [
            {
              "id": "<uuid>",
              "level": "chapter" | "section" | "topic" | "ability",
              "title": "<concise heading>",
              "claims": ["<declarative claim sentence>"],
              "evidenceURL": "<url or null>",
              "children": [...]
            }
          ]
        }

        Rules:
        - Each claim must be a single declarative sentence (subject + predicate).
        - Do NOT use section headings as claims. Extract the underlying assertions.
        - Every node must have at least one claim.
        - Preserve evidence URLs when available; use null otherwise.
        - Output must be parseable by JSONDecoder with no extra keys outside the schema.
        """
    }

    private static func _skeletonizerUserPrompt(
        text: String,
        qualificationId: String,
        qualificationTitle: String,
        sourceURLs: [String]
    ) -> String {
        let srcList = sourceURLs.prefix(20).joined(separator: "\n")
        let truncated = String(text.prefix(12000))
        return """
        Qualification ID: \(qualificationId)
        Qualification Title: \(qualificationTitle)
        Source URLs:
        \(srcList)

        Syllabus text (may be truncated):
        ---
        \(truncated)
        ---

        Produce the KnowledgeSkeleton JSON now.
        """
    }

    // MARK: - パース

    private static func _parseSkeleton(
        raw: String,
        qualificationId: String,
        qualificationTitle: String,
        sourceURLs: [String]
    ) throws -> Inf6KnowledgeSkeleton {
        let jsonString = _extractJSON(from: raw)
        guard let data = jsonString.data(using: .utf8) else {
            throw Inf6MMAError.jsonParseFailure("UTF-8 conversion failed")
        }
        do {
            var skeleton = try JSONDecoder().decode(Inf6KnowledgeSkeleton.self, from: data)
            // 呼び元の値で上書き（LLM 出力が間違える可能性を排除）
            skeleton.qualificationId    = qualificationId
            skeleton.qualificationTitle = qualificationTitle
            skeleton.sourceURLs         = sourceURLs
            skeleton.generatedAt        = ISO8601DateFormatter().string(from: Date())
            return skeleton
        } catch {
            throw Inf6MMAError.jsonParseFailure(error.localizedDescription)
        }
    }

    /// LLM 出力から JSON 部分を抽出する（```json ... ``` フェンスを除去）。
    private static func _extractJSON(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") { return trimmed }
        // ```json\n{...}\n``` 形式
        if let start = trimmed.range(of: "{"), let end = trimmed.range(of: "}", options: .backwards) {
            return String(trimmed[start.lowerBound...end.upperBound])
        }
        return trimmed
    }
}

// MARK: - 工程 2: CoreKnowledgeResolution

/// KnowledgeSkeleton から KnowledgeAtom[] / KnowledgeEdge[] を生成する。
public enum Inf6MMACoreKnowledgeResolver {

    // MARK: - 公開 API

    /// シラバス骨格を原子 / 経脈に分解する。
    /// - Parameters:
    ///   - skeleton: 工程 1 出力。
    ///   - goal: 達成目標（例: "AI-102 合格"）。
    ///   - client: OpenAIClient。
    /// - Returns: CoreKnowledgeSet（保存前）。
    public static func resolve(
        skeleton: Inf6KnowledgeSkeleton,
        goal: String,
        client: OpenAIClient
    ) async throws -> Inf6CoreKnowledgeSet {
        let skeletonJSON = (try? String(data: JSONEncoder().encode(skeleton), encoding: .utf8)) ?? "{}"
        let systemPrompt = _resolverSystemPrompt()
        let userPrompt   = _resolverUserPrompt(skeletonJSON: skeletonJSON, goal: goal)

        let raw: String
        do {
            raw = try await client.generateText(
                messages: [
                    .init(role: .system, text: systemPrompt),
                    .init(role: .user,   text: userPrompt)
                ],
                options: .init(maxOutputTokens: 12000)
            )
        } catch {
            throw Inf6MMAError.openAIFailure(error)
        }

        return try _parseCoreKnowledge(
            raw: raw,
            qualificationId: skeleton.qualificationId,
            goal: goal,
            sourceURLs: skeleton.sourceURLs
        )
    }

    // MARK: - プロンプト

    private static func _resolverSystemPrompt() -> String {
        """
        You are an expert knowledge engineer. Given a KnowledgeSkeleton JSON and a learning goal, \
        extract KnowledgeAtom[] and KnowledgeEdge[] following the schema below.

        Output ONLY valid JSON — no markdown fences, no prose outside the JSON.
        Schema:
        {
          "qualificationId": "<string>",
          "goal": "<string>",
          "generatedAt": "<ISO-8601>",
          "sourceURLs": ["<url>"],
          "atoms": [
            {
              "id": "<uuid>",
              "content": "<single declarative claim>",
              "sourceType": "microsoft_learn" | "jdla_syllabus" | "paper_pdf" | "other",
              "sourceURLOrPath": "<url or relative path>",
              "prerequisites": ["<atomId>"],
              "aliases": ["<string>"],
              "misconceptionNotes": "<string or null>",
              "domainTags": ["<string>"]
            }
          ],
          "edges": [
            {
              "id": "<uuid>",
              "fromAtomID": "<atomId>",
              "toAtomID": "<atomId>",
              "kind": "prereq"|"diff"|"order"|"boundary"|"failure"|"renaming"|"confusable"|"practical",
              "evidenceURL": "<url or null>",
              "note": "<string or null>"
            }
          ]
        }

        Rules:
        - Each atom: 1 claim = 1 atom. Never use section headings as atoms.
        - Each atom must have sourceURLOrPath pointing to the official evidence.
        - Cover all 8 edge kinds where relationships exist in the skeleton.
        - Include only atoms relevant to the stated goal (CoreKnowledgeSet).
        - Unified atom for renamed concepts: put old name in aliases[], current name in content.
        - Prerequisites: list atomIds that must be understood first.
        - Output must be a single JSON object matching the schema.
        """
    }

    private static func _resolverUserPrompt(skeletonJSON: String, goal: String) -> String {
        let truncated = String(skeletonJSON.prefix(14000))
        return """
        Goal: \(goal)

        KnowledgeSkeleton JSON:
        ---
        \(truncated)
        ---

        Produce the CoreKnowledgeSet JSON now.
        """
    }

    // MARK: - パース

    private static func _parseCoreKnowledge(
        raw: String,
        qualificationId: String,
        goal: String,
        sourceURLs: [String]
    ) throws -> Inf6CoreKnowledgeSet {
        let jsonString = _extractJSON(from: raw)
        guard let data = jsonString.data(using: .utf8) else {
            throw Inf6MMAError.jsonParseFailure("UTF-8 conversion failed")
        }
        do {
            var set = try JSONDecoder().decode(Inf6CoreKnowledgeSet.self, from: data)
            set.qualificationId = qualificationId
            set.goal            = goal
            set.generatedAt     = ISO8601DateFormatter().string(from: Date())
            set.sourceURLs      = sourceURLs
            return set
        } catch {
            throw Inf6MMAError.jsonParseFailure(error.localizedDescription)
        }
    }

    private static func _extractJSON(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") { return trimmed }
        if let start = trimmed.range(of: "{"), let end = trimmed.range(of: "}", options: .backwards) {
            return String(trimmed[start.lowerBound...end.upperBound])
        }
        return trimmed
    }
}

// MARK: - 知識源アダプタ（Microsoft Learn）

/// Microsoft Learn 用の入力正規化アダプタ。
/// 既存の `Inf6SyllabusDetail` が取得した URL 群とテキストを正規化してパイプラインへ渡す。
public enum Inf6MMAMicrosoftLearnAdapter {

    /// Microsoft Learn のシラバルパイプラインを実行する。
    /// - Parameters:
    ///   - moduleURLs: Learn モジュール URL 群（`learn.microsoft.com` のもの）。
    ///   - qualificationId: 資格 ID（例: "microsoft-ai-102"）。
    ///   - qualificationTitle: 資格名（例: "Microsoft AI-102"）。
    ///   - client: OpenAIClient。
    /// - Returns: (skeleton, coreKnowledgeSet)。呼び元で保存する。
    public static func runPipeline(
        moduleTexts: [(url: String, text: String)],
        qualificationId: String,
        qualificationTitle: String,
        goal: String,
        client: OpenAIClient
    ) async throws -> (skeleton: Inf6KnowledgeSkeleton, core: Inf6CoreKnowledgeSet) {
        let combinedText = moduleTexts.map { "## \($0.url)\n\($0.text)" }.joined(separator: "\n\n")
        let sourceURLs   = moduleTexts.map(\.url)

        let skeleton = try await Inf6MMASkeletonizer.skeletonize(
            text: combinedText,
            qualificationId: qualificationId,
            qualificationTitle: qualificationTitle,
            sourceURLs: sourceURLs,
            client: client
        )

        let core = try await Inf6MMACoreKnowledgeResolver.resolve(
            skeleton: skeleton,
            goal: goal,
            client: client
        )

        return (skeleton, core)
    }
}

// MARK: - 知識源アダプタ（JDLA）

/// JDLA G検定 / E資格 用の入力正規化アダプタ。
/// PDF テキスト抽出済みのページテキスト配列を正規化してパイプラインへ渡す。
public enum Inf6MMAJdlaSyllabusAdapter {

    /// JDLA シラバス PDF のパイプラインを実行する。
    /// - Parameters:
    ///   - pageTexts: ページインデックス → テキストの辞書。
    ///   - pdfRelPath: shared root 相対パス（例: "jdla/syllabus_pdfs/g2024.pdf"）。
    ///   - qualificationId: 資格 ID（例: "jdla-g-2024"）。
    ///   - qualificationTitle: 資格名。
    ///   - goal: 達成目標（例: "G検定 2024 合格"）。
    ///   - client: OpenAIClient。
    public static func runPipeline(
        pageTexts: [Int: String],
        pdfRelPath: String,
        qualificationId: String,
        qualificationTitle: String,
        goal: String,
        client: OpenAIClient
    ) async throws -> (skeleton: Inf6KnowledgeSkeleton, core: Inf6CoreKnowledgeSet) {
        let sortedPages  = pageTexts.sorted(by: { $0.key < $1.key })
        let combinedText = sortedPages.map { "## Page \($0.key)\n\($0.value)" }.joined(separator: "\n\n")
        let sourceURLs   = sortedPages.map { "pdf:\(pdfRelPath):\($0.key)" }

        let skeleton = try await Inf6MMASkeletonizer.skeletonize(
            text: combinedText,
            qualificationId: qualificationId,
            qualificationTitle: qualificationTitle,
            sourceURLs: sourceURLs,
            client: client
        )

        let core = try await Inf6MMACoreKnowledgeResolver.resolve(
            skeleton: skeleton,
            goal: goal,
            client: client
        )

        return (skeleton, core)
    }
}
