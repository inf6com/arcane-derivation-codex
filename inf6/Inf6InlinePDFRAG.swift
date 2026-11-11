import Foundation

extension InlinePDFPagesView {
    struct _InlineRAGChunk {
        let pageIndex: Int
        let text: String
    }

    struct _InlineRAGHit {
        let pageIndex: Int
        let text: String
        let lexicalScore: Int
        let vectorScore: Float
        let finalScore: Float
    }

    static func _ragTokens(_ text: String) -> [String] {
        let lowered = text.lowercased()
        let parts = lowered.split { ch in
            !(ch.isLetter || ch.isNumber)
        }
        var uniq = Set<String>()
        var out: [String] = []
        out.reserveCapacity(parts.count)
        for p in parts {
            let t = String(p).trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 2 else { continue }
            if uniq.insert(t).inserted {
                out.append(t)
            }
        }
        return out
    }

    static func _buildRAGEvidenceText(
        query: String,
        focusPageIndex: Int,
        chunks: [_InlineRAGChunk],
        topK: Int = 4,
        lexicalTopK: Int = 24
    ) async throws -> String {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw NSError(
                domain: "inf6.rag",
                code: -1001,
                userInfo: [NSLocalizedDescriptionKey: "RAG query is empty."]
            )
        }
        guard !chunks.isEmpty else {
            throw NSError(
                domain: "inf6.rag",
                code: -1002,
                userInfo: [NSLocalizedDescriptionKey: "No paper text chunks available for RAG."]
            )
        }

        let qTokens = _ragTokens(trimmedQuery)
        let queryEmbedding = try await Inf6EmbeddingService.embedQuery(trimmedQuery)
        let qv = queryEmbedding.vector

        struct _LexicalChunk {
            let chunk: _InlineRAGChunk
            let lexicalScore: Int
            let pageDistance: Int
        }

        var lexical: [_LexicalChunk] = []
        lexical.reserveCapacity(chunks.count)
        for c in chunks {
            let lower = c.text.lowercased()
            var ls = 0
            if qTokens.isEmpty {
                ls = 0
            } else {
                for tok in qTokens where lower.contains(tok) { ls += 1 }
            }
            let dist = abs(c.pageIndex - focusPageIndex)
            lexical.append(_LexicalChunk(chunk: c, lexicalScore: ls, pageDistance: dist))
        }

        lexical.sort { a, b in
            if a.lexicalScore != b.lexicalScore { return a.lexicalScore > b.lexicalScore }
            if a.pageDistance != b.pageDistance { return a.pageDistance < b.pageDistance }
            return a.chunk.pageIndex < b.chunk.pageIndex
        }

        let cappedLexical = Array(lexical.prefix(max(8, min(lexicalTopK, lexical.count))))
        var hits: [_InlineRAGHit] = []
        hits.reserveCapacity(cappedLexical.count)

        for item in cappedLexical {
            let pv = try await Inf6EmbeddingService.embedPassage(item.chunk.text).vector
            let cosine = Inf6VectorMath.cosine(qv, pv)
            let lexicalBoost = Float(item.lexicalScore) * 0.01
            let proximityBoost: Float = (item.pageDistance == 0) ? 0.03 : (item.pageDistance == 1 ? 0.015 : 0.0)
            let final = cosine + lexicalBoost + proximityBoost
            hits.append(
                _InlineRAGHit(
                    pageIndex: item.chunk.pageIndex,
                    text: item.chunk.text,
                    lexicalScore: item.lexicalScore,
                    vectorScore: cosine,
                    finalScore: final
                )
            )
        }

        hits.sort { a, b in
            if a.finalScore != b.finalScore { return a.finalScore > b.finalScore }
            return a.pageIndex < b.pageIndex
        }

        let top = Array(hits.prefix(max(1, min(topK, hits.count))))
        guard !top.isEmpty else {
            throw NSError(
                domain: "inf6.rag",
                code: -1003,
                userInfo: [NSLocalizedDescriptionKey: "RAG retrieval produced no hits."]
            )
        }

        var sections: [String] = []
        sections.reserveCapacity(top.count + 1)
        sections.append("[Paper-wide RAG context]")
        for (i, h) in top.enumerated() {
            let score = String(format: "%.4f", h.finalScore)
            sections.append(
                "(\(i + 1)) page \(h.pageIndex + 1), score=\(score), lexical=\(h.lexicalScore)\n\(h.text)"
            )
        }
        return sections.joined(separator: "\n\n")
    }
}
