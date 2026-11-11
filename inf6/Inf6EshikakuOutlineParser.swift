//
//  Inf6EshikakuOutlineParser.swift
//  inf6
//
//  Created by decopin on 2025/11/30.
//
import SwiftUI

enum Inf6EshikakuOutlineParser {
    // MARK: - Deterministic outline extraction (E資格)

    private static func normalizeLine(_ s: String) -> String {
        // Normalize full-width digits and punctuation that frequently appear in PDFs.
        var out = s
        let map: [String: String] = [
            "０":"0","１":"1","２":"2","３":"3","４":"4","５":"5","６":"6","７":"7","８":"8","９":"9",
            "（":"(","）":")",
            "．":".","：":":","　":" "
        ]
        for (k, v) in map {
            out = out.replacingOccurrences(of: k, with: v)
        }
        // Collapse repeated whitespace a bit.
        while out.contains("  ") {
            out = out.replacingOccurrences(of: "  ", with: " ")
        }
        return out.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    /// PDFテキスト抽出の「表レイアウト崩れ」で、1行に複数の見出しが連結されることがある。
    /// 例: "1. 数学的基礎 (1) 線形代数 ⅰ.行列演習 ... (2) 確率・統計 ⅰ..."
    /// その場合でも多段アウトラインを復元できるよう、見出しトークンで行を分割する。
    private static func explodeRunOnLine(_ raw: String) -> [String] {
        let t = normalizeLine(raw)
        guard !t.isEmpty else { return [] }

        func isWS(_ c: Character) -> Bool {
            c == " " || c == "\t" || c == "\n" || c == "\r"
        }
        func isDigit(_ c: Character) -> Bool {
            c >= "0" && c <= "9"
        }

        let romanMap: [Character: Int] = [
            "ⅰ": 1, "ⅱ": 2, "ⅲ": 3, "ⅳ": 4, "ⅴ": 5,
            "ⅵ": 6, "ⅶ": 7, "ⅷ": 8, "ⅸ": 9, "ⅹ": 10,
            "ⅺ": 11, "ⅻ": 12
        ]
        let asciiRomans: [String] = ["i.", "ii.", "iii.", "iv.", "v.", "vi.", "vii.", "viii.", "ix.", "x."]

        var starts: [String.Index] = []

        // Scan characters and record indices that look like headings.
        var i = t.startIndex
        while i < t.endIndex {
            let c = t[i]
            let prevIdx = (i == t.startIndex) ? nil : t.index(before: i)
            let prevIsWS = prevIdx == nil ? true : isWS(t[prevIdx!])

            // Level 1: (12) ...
            if c == "(" && prevIsWS {
                var j = t.index(after: i)
                var digits = ""
                while j < t.endIndex, digits.count < 2, isDigit(t[j]) {
                    digits.append(t[j])
                    j = t.index(after: j)
                }
                if !digits.isEmpty,
                   j < t.endIndex,
                   t[j] == ")" {
                    // Ensure it is really a heading: require a space after ")" when possible.
                    let k = t.index(after: j)
                    if k < t.endIndex {
                        if isWS(t[k]) {
                            starts.append(i)
                        }
                    } else {
                        starts.append(i)
                    }
                }
            }

            // Level 0: 12. ... (must appear at token boundary)
            if prevIsWS && isDigit(c) {
                var j = i
                var digits = ""
                while j < t.endIndex, digits.count < 2, isDigit(t[j]) {
                    digits.append(t[j])
                    j = t.index(after: j)
                }
                if !digits.isEmpty, j < t.endIndex, t[j] == "." {
                    // Require space after '.' when possible to reduce false positives.
                    let k = t.index(after: j)
                    if k < t.endIndex {
                        if isWS(t[k]) { starts.append(i) }
                    } else {
                        starts.append(i)
                    }
                }
            }

            // Level 2: ⅰ. ...
            if prevIsWS, romanMap[c] != nil {
                let j = t.index(after: i)
                if j < t.endIndex, t[j] == "." {
                    starts.append(i)
                }
            }

            i = t.index(after: i)
        }

        // Level 2 (ASCII): i. / ii. ... (token boundary)
        for p in asciiRomans {
            var searchStart = t.startIndex
            while searchStart < t.endIndex,
                  let r = t.range(of: p, range: searchStart..<t.endIndex) {
                let idx = r.lowerBound
                let prevIdx = (idx == t.startIndex) ? nil : t.index(before: idx)
                let prevIsWS = prevIdx == nil ? true : isWS(t[prevIdx!])
                if prevIsWS { starts.append(idx) }
                searchStart = r.upperBound
            }
        }

        // If we didn't find any additional headings, return as-is.
        if starts.isEmpty { return [t] }

        // Unique + sort starts.
        var uniq: [String.Index] = []
        uniq.reserveCapacity(starts.count + 1)
        var seen = Set<String>()
        for s in starts {
            let k = String(t.distance(from: t.startIndex, to: s))
            if seen.insert(k).inserted {
                uniq.append(s)
            }
        }
        uniq.sort { a, b in t.distance(from: t.startIndex, to: a) < t.distance(from: t.startIndex, to: b) }

        // Ensure we keep prefix chunk.
        if uniq.first != t.startIndex {
            uniq.insert(t.startIndex, at: 0)
        }

        var out: [String] = []
        out.reserveCapacity(uniq.count)
        for (idx, st) in uniq.enumerated() {
            let ed: String.Index = {
                if idx + 1 < uniq.count { return uniq[idx + 1] }
                return t.endIndex
            }()
            let seg = String(t[st..<ed]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !seg.isEmpty { out.append(seg) }
        }
        return out.isEmpty ? [t] : out
    }

    private static func parseLevel0(_ line: String) -> (num: Int, title: String)? {
        // e.g. "1. 数学的基礎" / "3. 深層学習の基礎"
        let t = normalizeLine(line)
        guard !t.isEmpty else { return nil }

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
        guard idx < t.endIndex, t[idx] == "." else { return nil }
        idx = t.index(after: idx)
        if idx < t.endIndex, t[idx] == " " { idx = t.index(after: idx) }
        let title = String(t[idx...]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard title.count >= 2 else { return nil }
        return (num, title)
    }

    private static func parseLevel1(_ line: String) -> (num: Int, title: String)? {
        // e.g. "(1) 線形代数" / "(7) 汎化性能向上のためのテクニック"
        let t = normalizeLine(line)
        guard t.hasPrefix("(") else { return nil }
        guard let close = t.firstIndex(of: ")") else { return nil }
        let inside = t[t.index(after: t.startIndex)..<close]
        let numStr = inside.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard let num = Int(numStr), num >= 1, num <= 99 else { return nil }
        let rest = String(t[t.index(after: close)...]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard rest.count >= 2 else { return nil }
        return (num, rest)
    }

    private static func parseLevel2(_ line: String) -> (num: Int, title: String)? {
        // e.g. "ⅰ. 行列演習" (roman) or "i. 行列演習" (ascii)
        let t0 = normalizeLine(line)
        guard !t0.isEmpty else { return nil }

        let romanMap: [Character: Int] = [
            "ⅰ": 1, "ⅱ": 2, "ⅲ": 3, "ⅳ": 4, "ⅴ": 5,
            "ⅵ": 6, "ⅶ": 7, "ⅷ": 8, "ⅸ": 9, "ⅹ": 10,
            "ⅺ": 11, "ⅻ": 12
        ]

        // Roman numeral form
        if let first = t0.first, let n = romanMap[first] {
            var idx = t0.index(after: t0.startIndex)
            guard idx < t0.endIndex, t0[idx] == "." else { return nil }
            idx = t0.index(after: idx)
            if idx < t0.endIndex, t0[idx] == " " { idx = t0.index(after: idx) }
            let title = String(t0[idx...]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard title.count >= 2 else { return nil }
            return (n, title)
        }

        // ASCII i/ii/iii form (very conservative)
        let lower = t0.lowercased()
        let asciiList: [(String, Int)] = [("i.", 1), ("ii.", 2), ("iii.", 3), ("iv.", 4), ("v.", 5), ("vi.", 6), ("vii.", 7), ("viii.", 8), ("ix.", 9), ("x.", 10)]
        for (p, n) in asciiList {
            if lower.hasPrefix(p) {
                let start = t0.index(t0.startIndex, offsetBy: p.count)
                let title = String(t0[start...]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                guard title.count >= 2 else { return nil }
                return (n, title)
            }
        }

        return nil
    }

    private static func isASCIIWord(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.unicodeScalars.allSatisfy { sc in
            (sc.value >= 0x30 && sc.value <= 0x39) || // 0-9
            (sc.value >= 0x41 && sc.value <= 0x5A) || // A-Z
            (sc.value >= 0x61 && sc.value <= 0x7A) || // a-z
            sc == "_" || sc == "-" || sc == "." || sc == "/"
        }
    }

    /// Split a single PDF-extracted line that may contain multiple roman-numbered subitems,
    /// e.g. "ⅰ.行列演習 行列・テンソルの積、勾配 ⅱ.固有値分解・特異値分解".
    /// Returns tuples of (romanIndex, chunkStringWithoutPrefix).
    private static func splitByRomanHeadings(_ line: String) -> [(roman: Int, chunk: String)] {
        let t = normalizeLine(line)
        guard !t.isEmpty else { return [] }

        let romanMap: [Character: Int] = [
            "ⅰ": 1, "ⅱ": 2, "ⅲ": 3, "ⅳ": 4, "ⅴ": 5,
            "ⅵ": 6, "ⅶ": 7, "ⅷ": 8, "ⅸ": 9, "ⅹ": 10,
            "ⅺ": 11, "ⅻ": 12
        ]

        // Collect start indices of roman markers that look like "ⅰ.".
        var starts: [(idx: String.Index, roman: Int)] = []
        var i = t.startIndex
        while i < t.endIndex {
            let c = t[i]
            if let r = romanMap[c] {
                let j = t.index(after: i)
                if j < t.endIndex, t[j] == "." {
                    starts.append((i, r))
                    i = j
                }
            }
            i = t.index(after: i)
        }

        guard !starts.isEmpty else { return [] }

        var out: [(roman: Int, chunk: String)] = []
        out.reserveCapacity(starts.count)

        for (k, st) in starts.enumerated() {
            let startIdx = st.idx
            let endIdx: String.Index = {
                if k + 1 < starts.count { return starts[k + 1].idx }
                return t.endIndex
            }()

            // Remove prefix "ⅰ." + optional space
            var bodyStart = t.index(after: startIdx) // after roman char
            if bodyStart < t.endIndex, t[bodyStart] == "." { bodyStart = t.index(after: bodyStart) }
            if bodyStart < t.endIndex, t[bodyStart] == " " { bodyStart = t.index(after: bodyStart) }

            let chunk = String(t[bodyStart..<endIdx]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !chunk.isEmpty {
                out.append((st.roman, chunk))
            }
        }
        return out
    }

    /// Heuristic: first separate a subitem title from its keyword blob.
    /// - Japanese titles typically have no spaces.
    /// - English titles like "Vision Transformer" include spaces; we keep up to 4 leading ASCII words as title.
    private static func splitTitleAndKeywords(_ chunk: String) -> (title: String, keywordsBlob: String) {
        let t = normalizeLine(chunk)
        guard !t.isEmpty else { return ("", "") }

        let toks = t.split(separator: " ", omittingEmptySubsequences: true).map { String($0) }
        guard toks.count >= 2 else { return (t, "") }

        // If leading tokens are ASCII words, allow multi-word English titles.
        var titleCount = 1
        if isASCIIWord(toks[0]) {
            var c = 1
            while c < toks.count && c < 4 && isASCIIWord(toks[c]) {
                titleCount = c + 1
                c += 1
            }
        }

        let title = toks.prefix(titleCount).joined(separator: " ").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let rest = toks.dropFirst(titleCount).joined(separator: " ").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return (title.isEmpty ? t : title, rest)
    }

    private static func extractKeywordTokens(_ keywordsBlob: String) -> [String] {
        let t = normalizeLine(keywordsBlob)
        guard !t.isEmpty else { return [] }

        // If list-like delimiters exist, split on them; otherwise fall back to whitespace splitting.
        if t.contains("、") || t.contains(",") {
            return t
                .replacingOccurrences(of: "（", with: "(")
                .replacingOccurrences(of: "）", with: ")")
                .split(whereSeparator: { ch in
                    ch == "、" || ch == "," || ch == "\n" || ch == "\t"
                })
                .map { String($0).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
                .filter { $0.count >= 2 }
        }

        return t
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map { String($0).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
    }

    private static func extractFineItemsFromLine(_ line: String) -> [String] {
        let t = normalizeLine(line)
        guard !t.isEmpty else { return [] }

        // Handle lines like: "細項目: 画像のデータ拡張、音声のデータ拡張"
        let markers = ["細項目:", "細項目：", "細項目"]
        for m in markers {
            if let r = t.range(of: m) {
                var rest = String(t[r.upperBound...]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                if rest.hasPrefix(":") { rest = String(rest.dropFirst()).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
                if rest.isEmpty { return [] }
                return rest
                    .split(whereSeparator: { $0 == "、" || $0 == "," || $0 == " " })
                    .map { String($0).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
                    .filter { $0.count >= 2 }
            }
        }

        // Bullet style: "・xxx"
        if t.hasPrefix("・") {
            let rest = t.dropFirst().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            return rest.isEmpty ? [] : [rest]
        }

        return []
    }

    static func extract(from fullText: String) -> [Inf6SyllabusOutlineItem] {
        let rawLines = fullText
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }

        // Some PDFs collapse multiple headings into one physical line (table layout).
        // Expand them so the deterministic parser can pick up (1)/(2)/ⅰ./... levels.
        var lines: [String] = []
        lines.reserveCapacity(rawLines.count)
        for raw in rawLines {
            lines.append(contentsOf: explodeRunOnLine(raw))
        }

        var out: [Inf6SyllabusOutlineItem] = []
        out.reserveCapacity(128)

        var l0: Int? = nil
        var l1: Int? = nil
        var l2: Int? = nil
        var fineCounter = 0

        var usedKeys = Set<String>()
        func push(key: String, depth: Int, title: String, summary: String? = nil) {
            let k = usedKeys.insert(key).inserted ? key : "\(key)_\(out.count)"
            out.append(.init(
                key: k,
                title: title,
                summary: summary,
                titleJa: title,
                titleEn: nil,
                summaryJa: summary,
                summaryEn: nil,
                depth: depth
            ))
        }

        for raw in lines {
            let line = normalizeLine(raw)
            guard !line.isEmpty else { continue }

            if let h0 = parseLevel0(line) {
                l0 = h0.num
                l1 = nil
                l2 = nil
                fineCounter = 0
                let key = String(format: "e_%02d", h0.num)
                push(key: key, depth: 0, title: h0.title)
                continue
            }

            if let h1 = parseLevel1(line), let n0 = l0 {
                l1 = h1.num
                l2 = nil
                fineCounter = 0
                let key = String(format: "e_%02d_%02d", n0, h1.num)
                push(key: key, depth: 1, title: h1.title)
                continue
            }

            // Roman-numbered subitems sometimes appear multiple times on one line due to table layout.
            // Example: "ⅰ.行列演習 行列・テンソルの積、勾配 ⅱ.固有値分解・特異値分解"
            if let n0 = l0, let n1 = l1 {
                let multi = splitByRomanHeadings(line)
                if !multi.isEmpty {
                    for (idx, seg) in multi.enumerated() {
                        l2 = seg.roman
                        fineCounter = 0

                        let (title, blob) = splitTitleAndKeywords(seg.chunk)
                        let key = String(format: "e_%02d_%02d_%02d", n0, n1, seg.roman)
                        push(key: key, depth: 2, title: title)

                        let kws = extractKeywordTokens(blob)
                        if !kws.isEmpty {
                            for kw in kws {
                                fineCounter += 1
                                let k2 = String(format: "e_%02d_%02d_%02d_kw%02d", n0, n1, seg.roman, fineCounter)
                                push(key: k2, depth: 3, title: kw)
                            }
                        }

                        // Keep l2 pointing at the last roman entry on the line.
                        if idx == multi.count - 1 {
                            l2 = seg.roman
                        }
                    }
                    continue
                }

                // Single roman item on its own line (legacy behavior)
                if let h2 = parseLevel2(line) {
                    l2 = h2.num
                    fineCounter = 0
                    let key = String(format: "e_%02d_%02d_%02d", n0, n1, h2.num)
                    push(key: key, depth: 2, title: h2.title)
                    continue
                }
            }

            // Fine items (細項目): only attach when we are inside roman-level section.
            if let n0 = l0, let n1 = l1, let n2 = l2 {
                let fine = extractFineItemsFromLine(line)
                if !fine.isEmpty {
                    for f in fine {
                        fineCounter += 1
                        let key = String(format: "e_%02d_%02d_%02d_kw%02d", n0, n1, n2, fineCounter)
                        push(key: key, depth: 3, title: f)
                    }
                }
            }
        }

        // De-dup by title (avoid noisy duplicates from PDF line-wrapping)
        var seenTitle = Set<String>()
        out = out.filter { item in
            let k = item.title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !k.isEmpty else { return false }
            return seenTitle.insert(k).inserted
        }

        return out
    }
}
