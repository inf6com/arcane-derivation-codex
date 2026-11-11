//
//  Inf6EshikakuOutlineExtractor.swift
//  inf6
//
//  Created by decopin on 2025/12/01.
//

import Foundation

enum Inf6EshikakuOutlineExtractor {
    static func extract(from fullText: String) -> [Inf6SyllabusOutlineItem] {
        return extractEshikakuOutlineFromText(fullText)
    }

    private static func extractEshikakuOutlineFromText(_ fullText: String) -> [Inf6SyllabusOutlineItem] {
        let rawLines = fullText
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }

        // Some PDFs collapse multiple headings into one physical line (table layout).
        // Expand them so the deterministic parser can pick up (1)/(2)/ⅰ./... levels.
        var lines: [String] = []
        lines.reserveCapacity(rawLines.count)
        for raw in rawLines {
            lines.append(contentsOf: _explodeEshikakuRunOnLine(raw))
        }

        var out: [Inf6SyllabusOutlineItem] = []
        out.reserveCapacity(128)

        var l0: Int? = nil
        var l1: Int? = nil
        var l2: Int? = nil
        var fineCounter = 0

        var usedKeys = Set<String>()
        func push(key: String, depth: Int, title: String, summary: String? = nil) {
            let title = _normalizeEshikakuConceptTitle(title)
            guard !title.isEmpty, !_isNonConceptEshikakuTitle(title) else { return }
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
            let line = _normalizeEshikakuLine(raw)
            guard !line.isEmpty else { continue }

            if let h0 = _parseEshikakuLevel0(line) {
                l0 = h0.num
                l1 = nil
                l2 = nil
                fineCounter = 0
                let key = String(format: "e_%02d", h0.num)
                push(key: key, depth: 0, title: h0.title)
                continue
            }

            if let n0 = l0, let h1 = (_parseEshikakuLevel1(line) ?? _parseEshikakuLevel1Alt(line)) {
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
                let multi = _splitByRomanHeadings(line)
                if !multi.isEmpty {
                    for (idx, seg) in multi.enumerated() {
                        l2 = seg.roman
                        fineCounter = 0

                        let (title, blob) = _splitTitleAndKeywords(seg.chunk)
                        let key = String(format: "e_%02d_%02d_%02d", n0, n1, seg.roman)
                        push(key: key, depth: 2, title: title)

                        let kws = _extractKeywordTokens(blob)
                        if !kws.isEmpty {
                            for kw in kws {
                                fineCounter += 1
                                let k2 = String(format: "e_%02d_%02d_%02d_kw%02d", n0, n1, seg.roman, fineCounter)
                                push(key: k2, depth: 3, title: kw)
                            }
                        } else {
                            // If no obvious keyword blob, still allow later "細項目:" lines to add keywords.
                        }

                        // Keep l2 pointing at the last roman entry on the line.
                        if idx == multi.count - 1 {
                            l2 = seg.roman
                        }
                    }
                    continue
                }

                // Single roman item on its own line (legacy behavior)
                if let h2 = _parseEshikakuLevel2(line) {
                    l2 = h2.num
                    fineCounter = 0
                    let key = String(format: "e_%02d_%02d_%02d", n0, n1, h2.num)
                    push(key: key, depth: 2, title: h2.title)
                    continue
                }
            }

            // Fine items (細項目): only attach when we are inside roman-level section.
            if let n0 = l0, let n1 = l1, let n2 = l2 {
                let fine = _extractFineItemsFromLine(line)
                if !fine.isEmpty {
                    for f in fine {
                        fineCounter += 1
                        let key = String(format: "e_%02d_%02d_%02d_kw%02d", n0, n1, n2, fineCounter)
                        push(key: key, depth: 3, title: f)
                    }
                }
            }
        }

        // Avoid only *adjacent* duplicates coming from PDF line-wrapping.
        out = _dedupAdjacentEshikakuOutline(out)

        // Roll up extracted keyword items into parent summaries so the UI shows the keywords even when collapsed.
        out = _applyEshikakuKeywordRollup(out)

        return out
    }

    // MARK: - Deterministic outline extraction (E資格)
    private static func _normalizeEshikakuLine(_ s: String) -> String {
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

    private static func _normalizeEshikakuConceptTitle(_ title: String) -> String {
        return _normalizeEshikakuLine(title)
            .replacingOccurrences(of: #"^[0-9]+[.)]\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func _isNonConceptEshikakuTitle(_ title: String) -> Bool {
        let t = _normalizeEshikakuLine(title)
        return t.hasPrefix("※") || t.contains("出題対象外")
    }

    /// PDFテキスト抽出の「表レイアウト崩れ」で、1行に複数の見出しが連結されることがある。
    /// 例: "1. 数学的基礎 (1) 線形代数 ⅰ.行列演習 ... (2) 確率・統計 ⅰ..."
    /// その場合でも多段アウトラインを復元できるよう、見出しトークンで行を分割する。
    private static func _explodeEshikakuRunOnLine(_ raw: String) -> [String] {
        let t = _normalizeEshikakuLine(raw)
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
                        if isWS(t[k]) || !isDigit(t[k]) {
                            starts.append(i)
                        }
                    } else {
                        starts.append(i)
                    }
                }
            }

            // Level 0: 12. ... / 12) ... / 12 ...  (must appear at token boundary)
            if prevIsWS && isDigit(c) {
                var j = i
                var digits = ""
                while j < t.endIndex, digits.count < 2, isDigit(t[j]) {
                    digits.append(t[j])
                    j = t.index(after: j)
                }
                if !digits.isEmpty, j < t.endIndex {
                    let d = t[j]
                    if d == "." || d == ")" {
                        // Require space after delimiter when possible to reduce false positives.
                        let k = t.index(after: j)
                        if k < t.endIndex {
                            if isWS(t[k]) || !isDigit(t[k]) { starts.append(i) }
                        } else {
                            starts.append(i)
                        }
                    } else if isWS(d) {
                        // "1 数学的基礎" style
                        var k = j
                        while k < t.endIndex, isWS(t[k]) {
                            k = t.index(after: k)
                        }
                        if k < t.endIndex, !isDigit(t[k]) {
                            starts.append(i)
                        }
                    }
                }
            }

            // Level 2: ⅰ. / ⅰ) ...
            if prevIsWS, romanMap[c] != nil {
                let j = t.index(after: i)
                if j < t.endIndex, (t[j] == "." || t[j] == ")") {
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

    private static func _parseEshikakuLevel0(_ line: String) -> (num: Int, title: String)? {
        // e.g. "1. 数学的基礎" / "1 数学的基礎" / "1) 数学的基礎"
        let t = _normalizeEshikakuLine(line)
        guard !t.isEmpty else { return nil }

        @inline(__always) func isWS(_ c: Character) -> Bool { c == " " || c == "\t" }
        @inline(__always) func isDigit(_ c: Character) -> Bool { c >= "0" && c <= "9" }

        var numStr = ""
        var idx = t.startIndex
        while idx < t.endIndex, numStr.count < 2, isDigit(t[idx]) {
            numStr.append(t[idx])
            idx = t.index(after: idx)
        }
        guard let num = Int(numStr), num >= 1, num <= 99 else { return nil }
        guard idx < t.endIndex else { return nil }

        let d = t[idx]
        if d == "." || d == ")" {
            idx = t.index(after: idx)
        } else if isWS(d) {
            // keep idx; consume whitespace below
        } else {
            return nil
        }

        while idx < t.endIndex, isWS(t[idx]) {
            idx = t.index(after: idx)
        }
        let title = String(t[idx...]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard title.count >= 2 else { return nil }
        // avoid false positives like "1 2 3"
        if title.allSatisfy({ ($0 >= "0" && $0 <= "9") || $0 == " " }) { return nil }
        return (num, title)
    }

    private static func _parseEshikakuLevel1(_ line: String) -> (num: Int, title: String)? {
        // e.g. "(1) 線形代数" / "(7) 汎化性能向上のためのテクニック"
        let t = _normalizeEshikakuLine(line)
        guard t.hasPrefix("(") else { return nil }
        guard let close = t.firstIndex(of: ")") else { return nil }
        let inside = t[t.index(after: t.startIndex)..<close]
        let numStr = inside.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard let num = Int(numStr), num >= 1, num <= 99 else { return nil }
        let rest = String(t[t.index(after: close)...]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard rest.count >= 2 else { return nil }
        return (num, rest)
    }

    private static func _parseEshikakuLevel1Alt(_ line: String) -> (num: Int, title: String)? {
        // e.g. "1) 線形代数" (sometimes PDFs drop the parentheses)
        let t = _normalizeEshikakuLine(line)
        guard !t.isEmpty else { return nil }

        @inline(__always) func isWS(_ c: Character) -> Bool { c == " " || c == "\t" }
        @inline(__always) func isDigit(_ c: Character) -> Bool { c >= "0" && c <= "9" }

        var numStr = ""
        var idx = t.startIndex
        while idx < t.endIndex, numStr.count < 2, isDigit(t[idx]) {
            numStr.append(t[idx])
            idx = t.index(after: idx)
        }
        guard let num = Int(numStr), num >= 1, num <= 99 else { return nil }
        guard idx < t.endIndex, t[idx] == ")" else { return nil }
        idx = t.index(after: idx)
        while idx < t.endIndex, isWS(t[idx]) {
            idx = t.index(after: idx)
        }
        let rest = String(t[idx...]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard rest.count >= 2 else { return nil }
        return (num, rest)
    }

    private static func _parseEshikakuLevel2(_ line: String) -> (num: Int, title: String)? {
        // e.g. "ⅰ. 行列演習" (roman) or "i. 行列演習" (ascii)
        let t0 = _normalizeEshikakuLine(line)
        guard !t0.isEmpty else { return nil }

        let romanMap: [Character: Int] = [
            "ⅰ": 1, "ⅱ": 2, "ⅲ": 3, "ⅳ": 4, "ⅴ": 5,
            "ⅵ": 6, "ⅶ": 7, "ⅷ": 8, "ⅸ": 9, "ⅹ": 10,
            "ⅺ": 11, "ⅻ": 12
        ]

        // Roman numeral form
        if let first = t0.first, let n = romanMap[first] {
            var idx = t0.index(after: t0.startIndex)
            guard idx < t0.endIndex, (t0[idx] == "." || t0[idx] == ")") else { return nil }
            idx = t0.index(after: idx)
            if idx < t0.endIndex, t0[idx] == " " { idx = t0.index(after: idx) }
            let title = String(t0[idx...]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard title.count >= 2 else { return nil }
            return (n, title)
        }

        // ASCII i/ii/iii form (very conservative)
        let lower = t0.lowercased()
        let asciiList: [(String, Int)] = [
            ("i.", 1), ("i)", 1),
            ("ii.", 2), ("ii)", 2),
            ("iii.", 3), ("iii)", 3),
            ("iv.", 4), ("iv)", 4),
            ("v.", 5), ("v)", 5),
            ("vi.", 6), ("vi)", 6),
            ("vii.", 7), ("vii)", 7),
            ("viii.", 8), ("viii)", 8),
            ("ix.", 9), ("ix)", 9),
            ("x.", 10), ("x)", 10)
        ]
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

    private static func _isASCIIWord(_ s: String) -> Bool {
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
    private static func _splitByRomanHeadings(_ line: String) -> [(roman: Int, chunk: String)] {
        let t = _normalizeEshikakuLine(line)
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
                if j < t.endIndex, (t[j] == "." || t[j] == ")") {
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

            // Remove prefix "ⅰ."/"ⅰ)" + optional space
            var bodyStart = t.index(after: startIdx) // after roman char
            if bodyStart < t.endIndex, (t[bodyStart] == "." || t[bodyStart] == ")") { bodyStart = t.index(after: bodyStart) }
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
    private static func _splitTitleAndKeywords(_ chunk: String) -> (title: String, keywordsBlob: String) {
        let t = _normalizeEshikakuLine(chunk)
        guard !t.isEmpty else { return ("", "") }

        let toks = t.split(separator: " ", omittingEmptySubsequences: true).map { String($0) }
        guard toks.count >= 2 else { return (t, "") }

        // If leading tokens are ASCII words, allow multi-word English titles.
        var titleCount = 1
        if _isASCIIWord(toks[0]) {
            var c = 1
            while c < toks.count && c < 4 && _isASCIIWord(toks[c]) {
                titleCount = c + 1
                c += 1
            }
        }

        let title = toks.prefix(titleCount).joined(separator: " ").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let rest = toks.dropFirst(titleCount).joined(separator: " ").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return (title.isEmpty ? t : title, rest)
    }

    private static func _extractKeywordTokens(_ keywordsBlob: String) -> [String] {
        let t = _normalizeEshikakuLine(keywordsBlob)
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

    private static func _extractFineItemsFromLine(_ line: String) -> [String] {
        let t = _normalizeEshikakuLine(line)
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

    private static func _dedupAdjacentEshikakuOutline(_ items: [Inf6SyllabusOutlineItem]) -> [Inf6SyllabusOutlineItem] {
        guard !items.isEmpty else { return items }
        var out: [Inf6SyllabusOutlineItem] = []
        out.reserveCapacity(items.count)

        var prevTitle = ""
        var prevDepth = -1

        for it in items {
            let title = it.title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let depth = it.effectiveDepth
            if !out.isEmpty, title == prevTitle, depth == prevDepth {
                continue
            }
            out.append(it)
            prevTitle = title
            prevDepth = depth
        }
        return out
    }

    private static func _applyEshikakuKeywordRollup(_ items: [Inf6SyllabusOutlineItem]) -> [Inf6SyllabusOutlineItem] {
        // Keywords are represented as depth=3 items with keys like: e_01_02_03_kw01
        // Roll them up to summaries on depth 0-2 parents to make the UI practical.
        var kwByL2: [String: [String]] = [:]
        var kwByL1: [String: [String]] = [:]
        var kwByL0: [String: [String]] = [:]

        for it in items {
            guard it.effectiveDepth >= 3 else { continue }
            let k = it.key
            guard let r = k.range(of: "_kw") else { continue }
            let parent = String(k[..<r.lowerBound])

            let kw = it.title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !kw.isEmpty else { continue }

            kwByL2[parent, default: []].append(kw)

            // parent: e_01_02_03 -> l1: e_01_02, l0: e_01
            let comps = parent.split(separator: "_").map { String($0) }
            if comps.count >= 3 {
                let l0 = comps.prefix(2).joined(separator: "_")
                kwByL0[l0, default: []].append(kw)
            }
            if comps.count >= 4 {
                let l1 = comps.prefix(3).joined(separator: "_")
                kwByL1[l1, default: []].append(kw)
            }
        }

        func joined(_ arr: [String], limit: Int) -> String {
            let uniq = Array(arr.reduce(into: [String]()) { acc, s in
                if !acc.contains(s) { acc.append(s) }
            }.prefix(limit))
            return uniq.joined(separator: " / ")
        }

        return items.map { it in
            let existing = (it.summaryJa ?? it.summary ?? "").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !existing.isEmpty { return it }

            let d = it.effectiveDepth
            var rolled: String = ""
            if d == 2 {
                if let kws = kwByL2[it.key], !kws.isEmpty {
                    rolled = joined(kws, limit: 10)
                }
            } else if d == 1 {
                if let kws = kwByL1[it.key], !kws.isEmpty {
                    rolled = joined(kws, limit: 12)
                }
            } else if d == 0 {
                if let kws = kwByL0[it.key], !kws.isEmpty {
                    rolled = joined(kws, limit: 14)
                }
            }

            if rolled.isEmpty { return it }

            return .init(
                key: it.key,
                title: it.title,
                summary: rolled,
                titleJa: it.titleJa,
                titleEn: it.titleEn,
                summaryJa: rolled,
                summaryEn: it.summaryEn,
                depth: it.depth
            )
        }
    }


    // MARK: - Paper search helpers (E資格アウトライン -> 論文検索)

    /// アウトライン項目から、論文サイト検索に使うクエリ文字列を生成する。
    /// - Note: 語彙のマッピング（例: "行列演習" -> "matrix calculus"）などはここでは行わず、
    ///         まずは確実に動く「タイトル + 代表キーワード」の組み合わせにする。
    static func paperSearchQuery(for item: Inf6SyllabusOutlineItem) -> String {
        return _buildPaperSearchQuery(item)
    }

    enum PaperSearchProvider: String, CaseIterable, Hashable {
        case arxiv
        case semanticScholar
        case openReview
        case googleScholar
    }

    /// 指定した論文サイトの検索URLを生成する（UI側はこれを開くだけで検索が開始できる）。
    static func paperSearchURLs(
        for item: Inf6SyllabusOutlineItem,
        providers: [PaperSearchProvider] = [.arxiv, .semanticScholar, .openReview, .googleScholar]
    ) -> [URL] {
        let q = _buildPaperSearchQuery(item)
        guard !q.isEmpty else { return [] }

        var out: [URL] = []
        out.reserveCapacity(providers.count)

        for p in providers {
            switch p {
            case .arxiv:
                if let u = _arxivSearchURL(query: q) { out.append(u) }
            case .semanticScholar:
                if let u = _semanticScholarSearchURL(query: q) { out.append(u) }
            case .openReview:
                if let u = _openReviewSearchURL(query: q) { out.append(u) }
            case .googleScholar:
                if let u = _googleScholarSearchURL(query: q) { out.append(u) }
            }
        }

        return out
    }

    private static func _buildPaperSearchQuery(_ item: Inf6SyllabusOutlineItem) -> String {
        // Prefer explicit localized fields when available.
        let title = _normalizeEshikakuLine(item.titleJa?.isEmpty == false ? item.titleJa! : item.title)
        var blob = ""

        // If rollup ran, parents will have summary keywords; for depth=3 keywords, title itself is useful.
        if let sj = item.summaryJa, !sj.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blob = sj
        } else if let s = item.summary, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blob = s
        }
        blob = _normalizeEshikakuLine(blob)

        // Tokenize keyword blob (supports both " / " rollup and Japanese commas).
        let kwTokens: [String] = blob
            .replacingOccurrences(of: "/", with: "、")
            .split(whereSeparator: { ch in
                ch == "、" || ch == "," || ch == "\n" || ch == "\t"
            })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }

        // Combine: title + top keywords (dedup, preserve order)
        var seen = Set<String>()
        var parts: [String] = []
        parts.reserveCapacity(1 + kwTokens.count)

        func add(_ s: String) {
            let t = _normalizeEshikakuLine(s)
            guard !t.isEmpty else { return }
            if seen.insert(t).inserted { parts.append(t) }
        }

        add(title)
        for kw in kwTokens.prefix(8) { add(kw) }

        // Keep conservative length for URL/search providers.
        let q = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return q
    }

    private static func _arxivSearchURL(query: String) -> URL? {
        var c = URLComponents(string: "https://arxiv.org/search/")
        c?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "searchtype", value: "all"),
            URLQueryItem(name: "source", value: "header")
        ]
        return c?.url
    }

    private static func _semanticScholarSearchURL(query: String) -> URL? {
        var c = URLComponents(string: "https://www.semanticscholar.org/search")
        c?.queryItems = [URLQueryItem(name: "q", value: query)]
        return c?.url
    }

    private static func _openReviewSearchURL(query: String) -> URL? {
        // OpenReview's general search UI.
        var c = URLComponents(string: "https://openreview.net/search")
        c?.queryItems = [URLQueryItem(name: "term", value: query)]
        return c?.url
    }

    private static func _googleScholarSearchURL(query: String) -> URL? {
        var c = URLComponents(string: "https://scholar.google.com/scholar")
        c?.queryItems = [URLQueryItem(name: "q", value: query)]
        return c?.url
    }

}
