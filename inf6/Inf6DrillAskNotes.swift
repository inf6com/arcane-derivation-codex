//
//  Inf6DrillAskNotes.swift
//  inf6
//
//  集中特訓の各演習項目に対する Ask（追加解説）の記録。
//
//  論文取り込みの Ask と同じく、ユーザーの求めに応じて追加解説を生成し、
//  その質問と回答を設問単位で保存・表示する。保存先は論文キー単位の1レコードで、
//  設問IDごとに追記していく。
//

import Foundation

public struct Inf6DrillAskNote: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var questionID: UUID
    public var prompt: String
    public var answer: String
    public var createdAt: TimeInterval

    public init(
        id: UUID = UUID(),
        questionID: UUID,
        prompt: String,
        answer: String,
        createdAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.questionID = questionID
        self.prompt = prompt
        self.answer = answer
        self.createdAt = createdAt
    }
}

public struct Inf6DrillAskNoteBook: Codable, Sendable {
    public var paperKey: String
    public var notes: [Inf6DrillAskNote]

    public init(paperKey: String, notes: [Inf6DrillAskNote] = []) {
        self.paperKey = paperKey
        self.notes = notes
    }
}

public enum Inf6DrillAskNoteStore {

    public static func load(paperKey: String) -> Inf6DrillAskNoteBook {
        guard !paperKey.isEmpty else { return Inf6DrillAskNoteBook(paperKey: paperKey) }
        return Inf6MetadataStore.getCodable(
            Inf6DrillAskNoteBook.self,
            domain: .drillAskNotes,
            key: paperKey
        ) ?? Inf6DrillAskNoteBook(paperKey: paperKey)
    }

    public static func notes(paperKey: String, questionID: UUID) -> [Inf6DrillAskNote] {
        load(paperKey: paperKey)
            .notes
            .filter { $0.questionID == questionID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    public static func append(paperKey: String, note: Inf6DrillAskNote) -> Bool {
        guard !paperKey.isEmpty else { return false }
        var book = load(paperKey: paperKey)
        book.notes.append(note)
        return Inf6MetadataStore.putCodable(book, domain: .drillAskNotes, key: paperKey)
    }

    @discardableResult
    public static func delete(paperKey: String, noteID: UUID) -> Bool {
        guard !paperKey.isEmpty else { return false }
        var book = load(paperKey: paperKey)
        let before = book.notes.count
        book.notes.removeAll { $0.id == noteID }
        guard book.notes.count != before else { return false }
        return Inf6MetadataStore.putCodable(book, domain: .drillAskNotes, key: paperKey)
    }

    @discardableResult
    public static func delete(paperKey: String, questionIDs: Set<UUID>) -> Bool {
        guard !paperKey.isEmpty, !questionIDs.isEmpty else { return false }
        var book = load(paperKey: paperKey)
        let before = book.notes.count
        book.notes.removeAll { questionIDs.contains($0.questionID) }
        guard book.notes.count != before else { return false }
        if book.notes.isEmpty {
            Inf6MetadataStore.delete(domain: .drillAskNotes, key: paperKey)
            return true
        }
        return Inf6MetadataStore.putCodable(book, domain: .drillAskNotes, key: paperKey)
    }

    /// 演習を作り直したときに、その論文の Ask 記録も併せて破棄する。
    public static func deleteAll(paperKey: String) {
        guard !paperKey.isEmpty else { return }
        Inf6MetadataStore.delete(domain: .drillAskNotes, key: paperKey)
    }
}

public struct Inf6DrillSlideshowProgressBook: Codable, Hashable, Sendable {
    public var paperKey: String
    public var secondsPerSlide: Double
    public var preferUnseenFirst: Bool
    public var seenGroupIDs: [String]
    public var currentLapSeenGroupIDs: [String]
    public var completedLapCount: Int
    public var totalShownCount: Int
    public var lastGroupID: String?
    public var updatedAt: TimeInterval

    public init(
        paperKey: String,
        secondsPerSlide: Double = 17,
        preferUnseenFirst: Bool = true,
        seenGroupIDs: [String] = [],
        currentLapSeenGroupIDs: [String] = [],
        completedLapCount: Int = 0,
        totalShownCount: Int = 0,
        lastGroupID: String? = nil,
        updatedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.paperKey = paperKey
        self.secondsPerSlide = secondsPerSlide
        self.preferUnseenFirst = preferUnseenFirst
        self.seenGroupIDs = seenGroupIDs
        self.currentLapSeenGroupIDs = currentLapSeenGroupIDs
        self.completedLapCount = completedLapCount
        self.totalShownCount = totalShownCount
        self.lastGroupID = lastGroupID
        self.updatedAt = updatedAt
    }
}

public enum Inf6DrillSlideshowProgressStore {

    public static func load(paperKey: String) -> Inf6DrillSlideshowProgressBook {
        guard !paperKey.isEmpty else { return Inf6DrillSlideshowProgressBook(paperKey: paperKey) }
        return Inf6MetadataStore.getCodable(
            Inf6DrillSlideshowProgressBook.self,
            domain: .drillSlideshowProgress,
            key: paperKey
        ) ?? Inf6DrillSlideshowProgressBook(paperKey: paperKey)
    }

    @discardableResult
    public static func save(_ book: Inf6DrillSlideshowProgressBook) -> Bool {
        guard !book.paperKey.isEmpty else { return false }
        return Inf6MetadataStore.putCodable(book, domain: .drillSlideshowProgress, key: book.paperKey)
    }

    public static func delete(paperKey: String) {
        guard !paperKey.isEmpty else { return }
        Inf6MetadataStore.delete(domain: .drillSlideshowProgress, key: paperKey)
    }
}

// MARK: - Live BP feedback

/// Live BP の一回の反応。targetID は docEntityID を優先し、無い場合だけ questionID。
public enum Inf6LiveBPReaction: String, Codable, Hashable, Sendable {
    case addExercise
    case hold
    case releaseHold

    public var labelJa: String {
        switch self {
        case .addExercise: return "ADD EXERCISE"
        case .hold: return "HOLD"
        case .releaseHold: return "HOLD"
        }
    }

    public var labelEn: String {
        switch self {
        case .addExercise: return "ADD EXERCISE"
        case .hold: return "HOLD"
        case .releaseHold: return "HOLD"
        }
    }

    public var iconName: String {
        switch self {
        case .addExercise: return "plus"
        case .hold: return "checkmark.square.fill"
        case .releaseHold: return "square"
        }
    }

    public var visualMark: String {
        switch self {
        case .addExercise: return "+"
        case .hold: return "H"
        case .releaseHold: return "H"
        }
    }


    public var instruction: String {
        switch self {
        case .addExercise: return "現在の理解ポイントと同じcoverageTargetIDsに対して、別角度の追加演習を1問生成する。"
        case .hold: return "現在の理解ポイントを閲覧履歴から除外し、再表示対象として保持する。"
        case .releaseHold: return "保持状態を解除する。"
        }
    }
}

public struct Inf6LiveBPReactionRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var paperKey: String
    public var targetID: String
    public var questionID: UUID
    public var reaction: Inf6LiveBPReaction
    public var createdAt: TimeInterval

    public init(
        id: UUID = UUID(), paperKey: String, targetID: String, questionID: UUID,
        reaction: Inf6LiveBPReaction, createdAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.paperKey = paperKey
        self.targetID = targetID
        self.questionID = questionID
        self.reaction = reaction
        self.createdAt = createdAt
    }
}

public struct Inf6LiveBPReactionBook: Codable, Sendable {
    public var paperKey: String
    public var records: [Inf6LiveBPReactionRecord]

    public init(paperKey: String, records: [Inf6LiveBPReactionRecord] = []) {
        self.paperKey = paperKey
        self.records = records
    }
}

public enum Inf6LiveBPReactionStore {
    public static func load(paperKey: String) -> Inf6LiveBPReactionBook {
        Inf6MetadataStore.getCodable(Inf6LiveBPReactionBook.self, domain: .liveBPReactions, key: paperKey)
            ?? Inf6LiveBPReactionBook(paperKey: paperKey)
    }

    public static func reaction(paperKey: String, targetID: String) -> Inf6LiveBPReaction? {
        load(paperKey: paperKey).records.last(where: { $0.targetID == targetID })?.reaction
    }

    @discardableResult
    public static func append(_ record: Inf6LiveBPReactionRecord) -> Bool {
        guard !record.paperKey.isEmpty, !record.targetID.isEmpty else { return false }
        var book = load(paperKey: record.paperKey)
        book.records.append(record)
        return Inf6MetadataStore.putCodable(book, domain: .liveBPReactions, key: record.paperKey)
    }
}

public struct Inf6LiveBPGeneratedExercise: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var paperKey: String
    public var targetID: String
    public var sourceQuestionID: UUID
    public var reaction: Inf6LiveBPReaction
    public var question: String
    public var explanation: String
    public var kind: String
    public var docEntityID: UUID?
    public var coverageTargetIDs: [String]
    public var pageIndex: Int?
    public var entityImagePath: String?
    public var entityReferenceIDs: [UUID]?
    public var createdAt: TimeInterval

    public init(
        id: UUID = UUID(), paperKey: String, targetID: String, sourceQuestionID: UUID,
        reaction: Inf6LiveBPReaction, question: String, explanation: String,
        kind: String, docEntityID: UUID?, coverageTargetIDs: [String],
        pageIndex: Int? = nil, entityImagePath: String? = nil,
        entityReferenceIDs: [UUID]? = nil,
        createdAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.paperKey = paperKey
        self.targetID = targetID
        self.sourceQuestionID = sourceQuestionID
        self.reaction = reaction
        self.question = question
        self.explanation = explanation
        self.kind = kind
        self.docEntityID = docEntityID
        self.coverageTargetIDs = coverageTargetIDs
        self.pageIndex = pageIndex
        self.entityImagePath = entityImagePath
        self.entityReferenceIDs = entityReferenceIDs
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, paperKey, targetID, sourceQuestionID, reaction, question, explanation,
             kind, docEntityID, coverageTargetIDs, pageIndex, entityImagePath,
             entityReferenceIDs, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        paperKey = try c.decode(String.self, forKey: .paperKey)
        targetID = try c.decode(String.self, forKey: .targetID)
        sourceQuestionID = try c.decode(UUID.self, forKey: .sourceQuestionID)
        reaction = try c.decode(Inf6LiveBPReaction.self, forKey: .reaction)
        question = try c.decode(String.self, forKey: .question)
        explanation = try c.decode(String.self, forKey: .explanation)
        kind = try c.decode(String.self, forKey: .kind)
        docEntityID = try c.decodeIfPresent(UUID.self, forKey: .docEntityID)
        coverageTargetIDs = try c.decodeIfPresent([String].self, forKey: .coverageTargetIDs) ?? []
        pageIndex = try c.decodeIfPresent(Int.self, forKey: .pageIndex)
        entityImagePath = try c.decodeIfPresent(String.self, forKey: .entityImagePath)
        entityReferenceIDs = try c.decodeIfPresent([UUID].self, forKey: .entityReferenceIDs)
        createdAt = try c.decodeIfPresent(TimeInterval.self, forKey: .createdAt) ?? 0
    }

    public func asQuizQuestion() -> Inf6PaperQuizQuestion {
        Inf6PaperQuizQuestion(
            id: id,
            pageIndex: pageIndex,
            kind: kind,
            question: question,
            choices: [],
            correctIndex: -1,
            explanation: explanation,
            coverageTargetIDs: coverageTargetIDs,
            entityImagePath: entityImagePath,
            docEntityID: docEntityID,
            entityReferenceIDs: entityReferenceIDs
        )
    }
}

public struct Inf6LiveBPGeneratedExerciseBook: Codable, Sendable {
    public var paperKey: String
    public var exercises: [Inf6LiveBPGeneratedExercise]

    public init(paperKey: String, exercises: [Inf6LiveBPGeneratedExercise] = []) {
        self.paperKey = paperKey
        self.exercises = exercises
    }
}

public enum Inf6LiveBPGeneratedExerciseStore {
    public static func load(paperKey: String) -> Inf6LiveBPGeneratedExerciseBook {
        Inf6MetadataStore.getCodable(
            Inf6LiveBPGeneratedExerciseBook.self,
            domain: .liveBPGeneratedExercises,
            key: paperKey
        ) ?? Inf6LiveBPGeneratedExerciseBook(paperKey: paperKey)
    }

    @discardableResult
    public static func append(_ exercise: Inf6LiveBPGeneratedExercise) -> Bool {
        guard !exercise.paperKey.isEmpty else { return false }
        var book = load(paperKey: exercise.paperKey)
        book.exercises.append(exercise)
        return Inf6MetadataStore.putCodable(book, domain: .liveBPGeneratedExercises, key: exercise.paperKey)
    }
}

// MARK: - E資格シラバス重要度

public struct Inf6SyllabusImportanceScore: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var scope: String
    public var domainPrefix: String
    public var domainLabelJa: String
    public var domainLabelEn: String
    public var nodeID: String?
    public var titleJa: String
    public var titleEn: String
    public var examImportanceScore: Int
    public var examImportanceReason: String
    public var evaluatedAt: TimeInterval

    public init(
        id: String,
        scope: String,
        domainPrefix: String,
        domainLabelJa: String,
        domainLabelEn: String,
        nodeID: String? = nil,
        titleJa: String,
        titleEn: String,
        examImportanceScore: Int,
        examImportanceReason: String,
        evaluatedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.scope = scope
        self.domainPrefix = domainPrefix
        self.domainLabelJa = domainLabelJa
        self.domainLabelEn = domainLabelEn
        self.nodeID = nodeID
        self.titleJa = titleJa
        self.titleEn = titleEn
        self.examImportanceScore = min(max(examImportanceScore, 0), 100)
        self.examImportanceReason = examImportanceReason
        self.evaluatedAt = evaluatedAt
    }
}

public struct Inf6SyllabusImportanceScoreBook: Codable, Sendable {
    public var sourceFamily: String
    public var domains: [Inf6SyllabusImportanceScore]
    public var nodes: [Inf6SyllabusImportanceScore]
    public var createdAt: TimeInterval

    public init(
        sourceFamily: String,
        domains: [Inf6SyllabusImportanceScore],
        nodes: [Inf6SyllabusImportanceScore],
        createdAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.sourceFamily = sourceFamily
        self.domains = domains
        self.nodes = nodes
        self.createdAt = createdAt
    }
}

public enum Inf6SyllabusImportanceScoreStore {
    public static func load(sourceFamily: String) -> Inf6SyllabusImportanceScoreBook? {
        let key = sourceFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return Inf6MetadataStore.getCodable(
            Inf6SyllabusImportanceScoreBook.self,
            domain: .syllabusImportanceScores,
            key: key
        )
    }

    @discardableResult
    public static func save(_ book: Inf6SyllabusImportanceScoreBook) -> Bool {
        let key = book.sourceFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        return Inf6MetadataStore.putCodable(book, domain: .syllabusImportanceScores, key: key)
    }

    public static func delete(sourceFamily: String) {
        let key = sourceFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Inf6MetadataStore.delete(domain: .syllabusImportanceScores, key: key)
    }
}
