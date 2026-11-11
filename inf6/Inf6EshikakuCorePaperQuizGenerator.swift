//
//  Inf6EshikakuCorePaperQuizGenerator.swift
//  inf6
//
//  Generates Inf6PaperQuiz from Inf6StructuredTable/Inf6ExtraNote sidecar data.
//

import Foundation

// MARK: - Private sidecar file model

private struct _NotesFile: Codable {
    var version: Int
    var notesByPage: [Int: [Inf6ExtraNote]]
    var savedAt: TimeInterval
}

// MARK: - Generator

enum Inf6EshikakuCorePaperQuizGenerator {

    // MARK: - Find sidecar notes

    /// iCloud Documents ディレクトリ以下の .extraNotes.json ファイルをスキャンし、
    /// 指定された Core Paper に対応するメモを返す。
    static func findSidecarNotes(for paper: Inf6CorePaper) -> [Int: [Inf6ExtraNote]] {
        let baseDir = Inf6DataRoot.url()

        // Safe filename fragment from arxiv_id (dots/dashes → underscores, lowercased)
        let arxivSafe: String? = paper.arxivId.map {
            $0.lowercased()
                .replacingOccurrences(of: ".", with: "_")
                .replacingOccurrences(of: "-", with: "_")
        }
        let paperIdLower = paper.id.lowercased()

        let candidates = _findExtraNoteFiles(under: baseDir, maxDepth: 4)

        for fileURL in candidates {
            let filename = fileURL.lastPathComponent.lowercased()

            // Match by arxiv_id safe name or paper.id
            let matches: Bool = {
                if let safe = arxivSafe, filename.contains(safe) { return true }
                if filename.contains(paperIdLower) { return true }
                return false
            }()
            guard matches else { continue }

            guard let data = try? Data(contentsOf: fileURL),
                  let parsed = try? JSONDecoder().decode(_NotesFile.self, from: data)
            else { continue }

            // Verify at least one note has a structuredTable
            let hasTable = parsed.notesByPage.values.contains { notes in
                notes.contains { $0.structuredTable != nil }
            }
            guard hasTable else { continue }

            return parsed.notesByPage
        }

        return [:]
    }

    // MARK: - Generate quiz

    static func generateQuiz(
        paper: Inf6CorePaper,
        notes: [Int: [Inf6ExtraNote]],
        lang: String
    ) -> Inf6PaperQuiz? {
        var questions: [Inf6PaperQuizQuestion] = []

        let sortedPages = notes.keys.sorted()
        for pageIndex in sortedPages {
            guard let pageNotes = notes[pageIndex] else { continue }
            for note in pageNotes {
                guard let table = note.structuredTable else { continue }
                let tableQuestions = _questionsFromTable(table, pageIndex: pageIndex, lang: lang)
                questions.append(contentsOf: tableQuestions)
                if questions.count >= 10 { break }
            }
            if questions.count >= 10 { break }
        }

        guard !questions.isEmpty else { return nil }

        let capped = Array(questions.prefix(10))
        return Inf6PaperQuiz(
            id: UUID(),
            createdAt: Date().timeIntervalSince1970,
            paperKey: paper.id,
            paperTitle: paper.title,
            lang: lang,
            questions: capped
        )
    }

    // MARK: - Private helpers

    private static func _findExtraNoteFiles(under dir: URL, maxDepth: Int) -> [URL] {
        guard maxDepth > 0 else { return [] }
        var results: [URL] = []
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        for url in contents {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDir {
                results.append(contentsOf: _findExtraNoteFiles(under: url, maxDepth: maxDepth - 1))
            } else if url.lastPathComponent.hasSuffix(".extraNotes.json") {
                results.append(url)
            }
        }
        return results
    }

    private static func _questionsFromTable(
        _ table: Inf6StructuredTable,
        pageIndex: Int,
        lang: String
    ) -> [Inf6PaperQuizQuestion] {
        var qs: [Inf6PaperQuizQuestion] = []

        // 1. Reading point question
        let points = lang == "ja" ? (table.readingPointsJA ?? []) : (table.readingPointsEN ?? [])
        if !points.isEmpty {
            let correct = points[0]
            var wrongs = Array(points.dropFirst().prefix(2))

            // Pad wrongs with column names if needed
            let colNames = table.structuredColumns?.map { lang == "ja" ? $0.labelJA : $0.labelEN }
                ?? table.columns
            for col in colNames {
                if wrongs.count >= 3 { break }
                if col != correct && !wrongs.contains(col) {
                    wrongs.append(col)
                }
            }
            if wrongs.count >= 1 {
                let choices = _shuffle([correct] + Array(wrongs.prefix(3)))
                let correctIdx = choices.firstIndex(of: correct) ?? 0
                qs.append(Inf6PaperQuizQuestion(
                    id: UUID(),
                    createdAt: Date().timeIntervalSince1970,
                    pageIndex: pageIndex,
                    kind: "table",
                    question: "この表（\(table.title)）の重要な読み方ポイントとして正しいものはどれですか？",
                    choices: choices,
                    correctIndex: correctIdx,
                    explanation: correct
                ))
            }
        }

        // 2. Meaning question
        let meanings = table.columnMeanings + table.rowMeanings
        if meanings.count >= 2 {
            let m = meanings[0]
            let wrongs = meanings.dropFirst().prefix(3).map { $0.meaning }
            let choices = _shuffle([m.meaning] + Array(wrongs))
            let correctIdx = choices.firstIndex(of: m.meaning) ?? 0
            qs.append(Inf6PaperQuizQuestion(
                id: UUID(),
                createdAt: Date().timeIntervalSince1970,
                pageIndex: pageIndex,
                kind: "table",
                question: "表「\(table.title)」において、\(m.label) が意味するものは？",
                choices: choices,
                correctIndex: correctIdx,
                explanation: m.meaning
            ))
        }

        // 3. Cell question
        if !table.rows.isEmpty && !table.columns.isEmpty {
            let row = table.rows[0]
            let colDescriptors = table.structuredColumns
            let rowDescriptors = table.structuredRows

            let colLabel = colDescriptors?.first?.labelJA ?? (table.columns.first ?? "col0")
            let rowLabel = rowDescriptors?.first?.labelJA ?? row.label

            if let correct = row.values.first, !correct.isEmpty {
                // Gather other cell values from same column
                var wrongs: [String] = []
                for otherRow in table.rows.dropFirst() {
                    if let v = otherRow.values.first, !v.isEmpty, v != correct {
                        wrongs.append(v)
                        if wrongs.count >= 3 { break }
                    }
                }
                if !wrongs.isEmpty {
                    let choices = _shuffle([correct] + Array(wrongs.prefix(3)))
                    let correctIdx = choices.firstIndex(of: correct) ?? 0
                    qs.append(Inf6PaperQuizQuestion(
                        id: UUID(),
                        createdAt: Date().timeIntervalSince1970,
                        pageIndex: pageIndex,
                        kind: "table",
                        question: "表「\(table.title)」で、\(rowLabel)/\(colLabel) の値は？",
                        choices: choices,
                        correctIndex: correctIdx,
                        explanation: correct
                    ))
                }
            }
        }

        return Array(qs.prefix(3))
    }

    private static func _shuffle(_ arr: [String]) -> [String] {
        var result = arr
        result.shuffle()
        return result
    }
}
