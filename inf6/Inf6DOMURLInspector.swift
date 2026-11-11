//
//   Inf6DOMURLInspector.swift
//  inf6
//
//  Created by decopin on 2025/11/27.
//

import Foundation

/// DOM (outerHTML) から URL 候補を抽出する軽量インスペクタ。
/// - 意図: WebKit でレンダリング後の outerHTML から href/src を拾い、到達可能性チェックへ渡す。
/// - 依存を増やさないため、HTML パーサは使わず「十分に実用な」文字列スキャンで実装する。
// NOTE: `Inf6DOMURLInspector` is defined elsewhere in the target.
// This file adds scoped extraction logic via an extension to avoid type redeclaration.
extension Inf6DOMURLInspector {

    struct Scope {
        /// セクションを切り出すためのキーワード（例: "シラバス", "syllabus"）
        let keywords: [String]

        /// キーワードを含む「区切りタグ」〜次の同レベル(同名タグ)までの範囲に限定する。
        /// - まず見出し(h1..h6)を優先して探索し、無ければキーワードを含む“任意タグ”の区切りにフォールバックする。
        /// - いずれも見つからなければ空配列（fail-closed）。
        let limitToHeadingSection: Bool

        init(keywords: [String], limitToHeadingSection: Bool = true) {
            self.keywords = keywords
            self.limitToHeadingSection = limitToHeadingSection
        }

        static var none: Scope { .init(keywords: [], limitToHeadingSection: false) }
    }

    // MARK: - Public


    /// 新規: scope を指定して候補抽出。
    /// - 仕様: scope.keywords が指定されている場合、まず見出し(h1..h6)で本文にキーワードを含む
    ///         見出しブロック〜次の同レベル見出しまでの範囲の URL のみを抽出する。
    ///         見出しが見つからない場合は「キーワードを含む任意タグ」〜次の同名タグまでを範囲として抽出する。
    ///         さらに、抽出後のURL自体（percent-decoding後を含む）が keywords を含むものだけを残す。
    ///         区切りが見つからなければ空配列を返す（fail-closed）。
    func extractCandidates(baseURL: URL, html: String, scope: Scope) -> [URL] {
        let htmlChars = html.count
        let scopeKeywordsLower = scope.keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        _log("extractCandidates: start baseURL=\(baseURL.absoluteString) htmlChars=\(htmlChars) scopeKeywords=\(scope.keywords)")

        let targetHTML: String
        if scope.limitToHeadingSection, !scopeKeywordsLower.isEmpty {
            if let sliced = sliceHTMLByHeadingSection(html: html, keywords: scope.keywords) {
                targetHTML = sliced
            } else if let sliced = sliceHTMLByKeywordTagSection(html: html, keywords: scope.keywords) {
                targetHTML = sliced
            } else {
                _log("extractCandidates: section not found for keywords=\(scope.keywords); returning 0 candidates (fail-closed)")
                return []
            }
        } else {
            targetHTML = html
        }

        let raw: [String]
        if !scopeKeywordsLower.isEmpty {
            // Scoped mode: ONLY accept links whose *tag text* (or file name) contains the keyword.
            // This prevents scanning/validating every URL on the page.
            raw = extractHrefURLStringsFromAnchorsContainingKeywords(
                fromHTML: targetHTML,
                keywordsLower: scopeKeywordsLower
            )
            _log("extractCandidates: scoped keywordAnchors urls=\(raw.count)")
        } else {
            raw = extractRawURLStrings(fromHTML: targetHTML)
        }
        var out: [URL] = []
        out.reserveCapacity(min(256, raw.count))

        var resolvedCount = 0
        var keywordRejectedCount = 0

        var seen = Set<String>()
        for s in raw {
            guard let u = resolveURL(candidate: s, baseURL: baseURL) else { continue }
            resolvedCount += 1

            // Scoped mode: raw URLs were already narrowed by anchor text / file name.
            // Here we only reject obvious non-document links (keep PDF-ish URLs).
            if !scopeKeywordsLower.isEmpty {
                let abs = u.absoluteString.lowercased()
                let decoded = (u.absoluteString.removingPercentEncoding ?? u.absoluteString).lowercased()
                let combined = abs + "\n" + decoded
                let isPDF = u.pathExtension.lowercased() == "pdf" || combined.contains(".pdf")
                if !isPDF {
                    keywordRejectedCount += 1
                    continue
                }
            }

            let key = u.absoluteString
            if seen.insert(key).inserted {
                out.append(u)
            }
        }

        if !scopeKeywordsLower.isEmpty {
            _log("extractCandidates: done candidates=\(out.count) resolved=\(resolvedCount) rejectedByKeyword=\(keywordRejectedCount)")
        } else {
            _log("extractCandidates: done candidates=\(out.count)")
        }
        return out
    }

    // MARK: - Section slicing ("キーワードを含む見出し"〜"次の同レベル見出し")

    /// HTML の見出し(h1..h6)で、本文に keywords を含む最初の見出しを探し、
    /// その見出し終了〜次の同レベル見出し開始までの範囲を切り出して返す。
    /// 見つからない場合は nil。
    private func sliceHTMLByHeadingSection(html: String, keywords: [String]) -> String? {
        let lowerKeywords = keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !lowerKeywords.isEmpty else { return nil }

        @inline(__always)
        func _preview(_ s: String, max: Int = 80) -> String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count <= max { return t }
            return String(t.prefix(max)) + "…"
        }

        // <h1 ...> ... </h1> 〜 <h6 ...> ... </h6>
        let pattern = "(?is)<h([1-6])\\b[^>]*>(.*?)</h\\1>"
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }

        let ns = html as NSString
        let allRange = NSRange(location: 0, length: ns.length)
        let matches = re.matches(in: html, options: [], range: allRange)
        guard !matches.isEmpty else {
            _log("sliceHTMLByHeadingSection: no <h1..h6> headings found (keywords=\(keywords))")
            return nil
        }

        // 1) キーワードを含む最初の heading を探す
        var targetMatch: NSTextCheckingResult?
        var targetLevel: String = ""
        var targetInnerText: String = ""
        for m in matches {
            if m.numberOfRanges < 3 { continue }
            let level = ns.substring(with: m.range(at: 1))
            let inner = ns.substring(with: m.range(at: 2))
            let innerText = stripTags(inner).lowercased()
            if lowerKeywords.contains(where: { innerText.contains($0) }) {
                targetMatch = m
                targetLevel = level
                targetInnerText = innerText
                break
            }
        }
        guard let hit = targetMatch, !targetLevel.isEmpty else {
            _log("sliceHTMLByHeadingSection: keyword heading not found (keywords=\(keywords), headings=\(matches.count))")
            return nil
        }

        _log("sliceHTMLByHeadingSection: FOUND heading level=h\(targetLevel) text='\(_preview(targetInnerText))' (keywords=\(keywords), headings=\(matches.count))")

        // 見出しタグの直後から開始
        let start = hit.range.location + hit.range.length

        // 2) 次の同レベル heading を探す（hit の後ろで最初に出る <hN ...>）
        let nextPattern = "(?is)<h" + NSRegularExpression.escapedPattern(for: targetLevel) + "\\b"
        guard let reNext = try? NSRegularExpression(pattern: nextPattern, options: []) else {
            // 失敗時は末尾まで
            let slice = ns.substring(from: min(start, ns.length))
            _log("sliceHTMLByHeadingSection: next-heading regex failed; slicing to end sliceChars=\(slice.count)")
            return slice
        }

        let searchRange = NSRange(location: min(start, ns.length), length: max(0, ns.length - start))
        if let next = reNext.firstMatch(in: html, options: [], range: searchRange) {
            let end = next.range.location
            if end > start {
                let slice = ns.substring(with: NSRange(location: start, length: end - start))
                _log("sliceHTMLByHeadingSection: sliced range start=\(start) end=\(end) sliceChars=\(slice.count)")
                return slice
            } else {
                let slice = ns.substring(from: min(start, ns.length))
                _log("sliceHTMLByHeadingSection: next heading at/before start; slicing to end sliceChars=\(slice.count)")
                return slice
            }
        } else {
            // 次がなければ末尾まで
            let slice = ns.substring(from: min(start, ns.length))
            _log("sliceHTMLByHeadingSection: no next same-level heading; slicing to end sliceChars=\(slice.count)")
            return slice
        }
    }

    /// 見出し(h1..h6)が見つからない場合のフォールバック。
    /// キーワードを含む“任意タグ”を起点に、その閉じタグ直後〜次の同名タグまでを切り出す。
    /// DOM パーサ無しのため、厳密な sibling 判定はできないが、実用上のノイズ抑止として十分に効く。
    private func sliceHTMLByKeywordTagSection(html: String, keywords: [String]) -> String? {
        let lowerKeywords = keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !lowerKeywords.isEmpty else { return nil }

        let lower = html.lowercased()
        var hitIndex: String.Index? = nil
        var hitKeyword: String = ""
        for k in lowerKeywords {
            if let r = lower.range(of: k) {
                if hitIndex == nil || r.lowerBound < hitIndex! {
                    hitIndex = r.lowerBound
                    hitKeyword = k
                }
            }
        }
        guard let kwIndex = hitIndex else {
            _log("sliceHTMLByKeywordTagSection: keyword not found in HTML (keywords=\(keywords))")
            return nil
        }

        // 直前の '<' を探し、開始タグを推定する（閉じタグやコメントは除外）
        var i = kwIndex
        var openTagStart: String.Index? = nil
        while i > lower.startIndex {
            i = lower.index(before: i)
            if lower[i] == "<" {
                let next = lower.index(after: i)
                if next < lower.endIndex {
                    if lower[next] == "/" { continue }
                    if lower[next] == "!" { continue }
                }
                openTagStart = i
                break
            }
        }
        guard let tagStart = openTagStart else {
            _log("sliceHTMLByKeywordTagSection: could not locate opening tag before keyword='\(hitKeyword)'")
            return nil
        }

        // タグ名を抽出
        var nameStart = lower.index(after: tagStart)
        while nameStart < lower.endIndex, lower[nameStart].isWhitespace { nameStart = lower.index(after: nameStart) }
        var nameEnd = nameStart
        while nameEnd < lower.endIndex {
            let c = lower[nameEnd]
            if !(c.isLetter || c.isNumber) { break }
            nameEnd = lower.index(after: nameEnd)
        }
        let tagName = String(lower[nameStart..<nameEnd])
        guard !tagName.isEmpty else {
            _log("sliceHTMLByKeywordTagSection: empty tagName before keyword='\(hitKeyword)'")
            return nil
        }

        // 開始タグの終端 '>' を探す
        guard let tagEnd = lower[tagStart...].firstIndex(of: ">") else {
            _log("sliceHTMLByKeywordTagSection: unterminated start tag <\(tagName)... (keyword='\(hitKeyword)')")
            return nil
        }

        // 自己終端タグ or void tag は、開始タグ直後から開始する
        let startTagText = String(lower[tagStart...tagEnd])
        let isSelfClosing = startTagText.hasSuffix("/>")
        let voidTags: Set<String> = ["meta","link","img","br","hr","input","source","area","base","col","embed","param","track","wbr"]
        let isVoid = voidTags.contains(tagName)

        var startAfter: String.Index = lower.index(after: tagEnd)
        if !isSelfClosing && !isVoid {
            // 閉じタグを探して、その直後から開始
            let closeNeedle = "</\(tagName)"
            if let closeStart = lower.range(of: closeNeedle, range: startAfter..<lower.endIndex)?.lowerBound,
               let closeGt = lower[closeStart...].firstIndex(of: ">") {
                startAfter = lower.index(after: closeGt)
            }
        }

        // 次の同名開始タグを探し、そこまでをスライス
        let nextNeedle = "<\(tagName)"
        let endIndex: String.Index
        if let next = lower.range(of: nextNeedle, range: startAfter..<lower.endIndex)?.lowerBound {
            endIndex = next
        } else {
            endIndex = lower.endIndex
        }

        let slice = String(html[startAfter..<endIndex])
        _log("sliceHTMLByKeywordTagSection: FOUND tag=<\(tagName)> keyword='\(hitKeyword)' sliceChars=\(slice.count)")
        return slice
    }

    // MARK: - URL extraction

    /// Scoped extraction: only keep <a href="...">...</a> where the anchor *text* contains a keyword,
    /// or the decoded href's lastPathComponent contains a keyword.
    ///
    /// Rationale: for syllabus discovery, we want to skip everything until the user-visible tag indicates
    /// "シラバス" / "syllabus" rather than scanning every URL on the page.
    private func extractHrefURLStringsFromAnchorsContainingKeywords(
        fromHTML html: String,
        keywordsLower: [String]
    ) -> [String] {
        guard !keywordsLower.isEmpty else { return [] }

        // <a ... href='...'> ... </a>
        let pattern = "(?is)<a\\b[^>]*\\bhref\\s*=\\s*(['\"])(.*?)\\1[^>]*>(.*?)</a>"
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }

        let ns = html as NSString
        let allRange = NSRange(location: 0, length: ns.length)
        let matches = re.matches(in: html, options: [], range: allRange)
        guard !matches.isEmpty else { return [] }

        var out: [String] = []
        out.reserveCapacity(min(256, matches.count))

        for m in matches {
            if m.numberOfRanges < 4 { continue }
            let href = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if href.isEmpty { continue }

            // Anchor text check
            let inner = ns.substring(with: m.range(at: 3))
            let text = stripTags(inner).lowercased()
            let textHit = keywordsLower.contains(where: { text.contains($0) })

            // File-name check (decoded). Do NOT attempt to salvage malformed / relative href strings here.
            let decodedHref = (href.removingPercentEncoding ?? href).lowercased()
            let fileNameHit: Bool = {
                guard let u = URL(string: decodedHref) else { return false }
                let name = u.lastPathComponent.lowercased()
                guard !name.isEmpty else { return false }
                return keywordsLower.contains(where: { name.contains($0) })
            }()

            guard textHit || fileNameHit else { continue }
            out.append(href)
        }

        return out
    }

    /// href / src の値を抽出（HTML 全体 or スライス済み部分に対して）
    private func extractRawURLStrings(fromHTML html: String) -> [String] {
        // href="..." or href='...'
        // src="..." or src='...'
        let pattern = "(?is)\\b(?:href|src)\\s*=\\s*(['\"])(.*?)\\1"
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }

        let ns = html as NSString
        let allRange = NSRange(location: 0, length: ns.length)
        let matches = re.matches(in: html, options: [], range: allRange)
        guard !matches.isEmpty else { return [] }

        var out: [String] = []
        out.reserveCapacity(matches.count)
        for m in matches {
            if m.numberOfRanges < 3 { continue }
            let raw = ns.substring(with: m.range(at: 2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { continue }
            out.append(raw)
        }
        return out
    }

    private func resolveURL(candidate: String, baseURL: URL) -> URL? {
        let s = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // ignore anchors / javascript / mail / data
        let lower = s.lowercased()
        if lower.hasPrefix("#") { return nil }
        if lower.hasPrefix("javascript:") { return nil }
        if lower.hasPrefix("mailto:") { return nil }
        if lower.hasPrefix("tel:") { return nil }
        if lower.hasPrefix("data:") { return nil }

        // Absolute / relative
        if let u = URL(string: s), u.scheme != nil {
            return u
        }
        return URL(string: s, relativeTo: baseURL)?.absoluteURL
    }

    private func stripTags(_ html: String) -> String {
        let pattern = "(?is)<[^>]+>"
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return html }
        let ns = html as NSString
        let allRange = NSRange(location: 0, length: ns.length)
        return re.stringByReplacingMatches(in: html, options: [], range: allRange, withTemplate: " ")
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\t", with: " ")
    }

    private func _log(_ message: String) {
        // 既存ログ体裁に寄せる（prefix は呼び出し側が付けることが多いのでここでは固定しない）
        print("[Inf6DOMURLInspector] \(message)")
    }
}
