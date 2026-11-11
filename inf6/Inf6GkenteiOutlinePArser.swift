//
//  Inf6GkenteiOutlinePArser.swift
//  inf6
//
//  Created by decopin on 2025/11/30.
//

import SwiftUI


// MARK: - Movable outline parsers (split targets)
// These are intentionally file-level so you can move each block into its own Swift file later:
// - Inf6GkenteiOutlineParser.swift
// - Inf6EshikakuOutlineParser.swift

enum Inf6GkenteiOutlineParser {
    // MARK: - Deterministic outline extraction (preferred for JDLA/G検定 PDFs)
    private static func parseNumberedHeading(_ line: String) -> (num: Int, title: String)? {
        let t = line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        // e.g. "1. 人工知能の定義" / "23. Attention"
        // Keep it intentionally conservative to avoid false positives.
        var numStr = ""
        var idx = t.startIndex
        while idx < t.endIndex, numStr.count < 2 {
            let c = t[idx]
            if c >= "0" && c <= "9" {
                numStr.append(c)
                idx = t.index(after: idx)
                continue
            }
            break
        }
        guard let num = Int(numStr), num >= 1, num <= 99 else { return nil }
        guard idx < t.endIndex else { return nil }
        if t[idx] != "." { return nil }
        idx = t.index(after: idx)
        if idx < t.endIndex, t[idx] == " " { idx = t.index(after: idx) }
        let title = String(t[idx...]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard title.count >= 2 else { return nil }
        return (num, title)
    }

    static func extract(from fullText: String) -> [Inf6SyllabusOutlineItem] {
        let lines = fullText
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }

        var out: [Inf6SyllabusOutlineItem] = []
        out.reserveCapacity(64)

        var used = Set<String>()
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if let h = parseNumberedHeading(line) {
                let num = h.num
                let title = h.title
                if isRevisionHistoryHeading(title) {
                    i += 1
                    continue
                }

                var bullets: [String] = []
                bullets.reserveCapacity(2)

                var j = i + 1
                while j < lines.count {
                    let t = lines[j].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    if let _ = parseNumberedHeading(t) { break }
                    if t.hasPrefix("・") {
                        let b = t.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        if !b.isEmpty { bullets.append(b) }
                        if bullets.count >= 2 { break }
                    }
                    // Stop at the first empty line once we collected something.
                    if t.isEmpty, !bullets.isEmpty { break }
                    j += 1
                }

                let key0 = String(format: "gkentei_%02d", num)
                let key = used.insert(key0).inserted ? key0 : "\(key0)_\(out.count)"

                let summaryJa: String? = bullets.isEmpty ? nil : bullets.joined(separator: " ")

                out.append(.init(
                    key: key,
                    title: title,
                    summary: summaryJa,
                    titleJa: title,
                    titleEn: nil,
                    summaryJa: summaryJa,
                    summaryEn: nil,
                    depth: 0
                ))

                i = max(j, i + 1)
                continue
            }
            i += 1
        }

        // De-dup by title if extraction got noisy.
        var seenTitle = Set<String>()
        out = out.filter { item in
            let k = item.title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !k.isEmpty else { return false }
            return seenTitle.insert(k).inserted
        }

        return out
    }

    private static func isRevisionHistoryHeading(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutNumberPrefix = t.replacingOccurrences(
            of: #"^[0-9]+[.)]?\s*"#,
            with: "",
            options: .regularExpression
        )
        return t.contains("シラバス") && t.contains("新規作成")
            || withoutNumberPrefix.hasPrefix("以下のキーワード")
    }
}
