//
//  Inf6MicrosoftLearnOutlineParser.swift
//  inf6
//
//  Microsoft Learn provider 用シラバスパーサ。工学的契約：
//    - Microsoft Learn は概念集合 (= シラバス) の取得元である。
//    - そのため、Microsoft Learn のドキュメントから概念ノード階層を抽出する
//      メカニズムがアプリ側に必須である。
//
//  入力：Microsoft Learn の「Study guide for Exam ◯◯◯」ページから取得したテキスト。
//        Markdown 風（HTML → text 変換後）または markdown 原文を受け付ける。
//  出力：[Inf6SyllabusOutlineItem]（Domain → Skill → Topic の3階層）
//
//  パース対象セクション： "Skills measured" 以降。
//  Domain 行例：  "Plan and manage an Azure AI solution (15–20%)"
//  Skill 行例：   "- Select the appropriate Azure AI service"
//  Topic 行例：   "  - Select the appropriate service for a computer vision solution"
//

import Foundation

enum Inf6MicrosoftLearnOutlineParser {

    /// 与えられた study guide 本文テキストから outline items を抽出する。
    /// 入力テキストは Microsoft Learn のページから text 化されたもの。
    static func extract(from fullText: String) -> [Inf6SyllabusOutlineItem] {
        let preparedText = _prepareInputText(fullText)
        let lines = preparedText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }

        // 1) "Skills measured" 以降だけを対象にする（前置きの説明を除外）。
        let startIndex = _findSkillsMeasuredStart(lines: lines) ?? 0

        var out: [Inf6SyllabusOutlineItem] = []
        out.reserveCapacity(64)
        var usedKeys = Set<String>()

        // パース中の親階層キー（多階層用）
        var currentDomainKey: String? = nil
        var currentSkillKey: String? = nil

        var i = startIndex
        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { i += 1; continue }

            // 終了マーカ：次の H1 / 別セクションに入ったら break
            if _isSectionTerminator(trimmed, startIndex: startIndex, currentIndex: i) {
                break
            }

            // Domain 検出：Microsoft Learn の試験範囲は H3 + 割合で示される。
            // Audience profile / Skills at a glance などの説明見出しは概念構造ではない。
            if let domain = _parseDomainHeading(trimmed) {
                let key = _stableKey(prefix: "ml.dom", title: domain, used: &usedKeys)
                let item = Inf6SyllabusOutlineItem(
                    key: key,
                    title: domain,
                    summary: nil,
                    titleJa: nil,
                    titleEn: domain,
                    summaryJa: nil,
                    summaryEn: nil,
                    depth: 0
                )
                out.append(item)
                currentDomainKey = key
                currentSkillKey = nil
                i += 1
                continue
            }

            if let skill = _parseSkillHeading(trimmed), currentDomainKey != nil {
                let key = _stableKey(prefix: "ml.skill", title: skill, used: &usedKeys)
                let item = Inf6SyllabusOutlineItem(
                    key: key,
                    title: skill,
                    summary: nil,
                    titleJa: nil,
                    titleEn: skill,
                    summaryJa: nil,
                    summaryEn: nil,
                    depth: 1
                )
                out.append(item)
                currentSkillKey = key
                i += 1
                continue
            }

            // Skill / Topic 検出（インデント深さで階層判定）
            if let (depth, title) = _parseBulletItem(raw) {
                guard currentDomainKey != nil else {
                    i += 1
                    continue
                }
                // depth は raw のインデント量から判定（0 = Skill, 1+ = Topic）
                if depth == 0, currentSkillKey == nil {
                    let key = _stableKey(prefix: "ml.skill", title: title, used: &usedKeys)
                    let parent = currentDomainKey ?? ""
                    let parentTitlePart = parent.isEmpty ? "" : " (parent=\(parent))"
                    _ = parentTitlePart  // future: store parent linkage if model supports
                    let item = Inf6SyllabusOutlineItem(
                        key: key,
                        title: title,
                        summary: nil,
                        titleJa: nil,
                        titleEn: title,
                        summaryJa: nil,
                        summaryEn: nil,
                        depth: 1
                    )
                    out.append(item)
                    currentSkillKey = key
                } else {
                    let key = _stableKey(prefix: "ml.topic", title: title, used: &usedKeys)
                    _ = currentSkillKey  // future: store parent linkage if model supports
                    let item = Inf6SyllabusOutlineItem(
                        key: key,
                        title: title,
                        summary: nil,
                        titleJa: nil,
                        titleEn: title,
                        summaryJa: nil,
                        summaryEn: nil,
                        depth: 2
                    )
                    out.append(item)
                }
                i += 1
                continue
            }

            // それ以外の行はスキップ（前置き / footnote / 区切り線 etc.）
            i += 1
        }

        return out
    }

    // MARK: - Private parsing helpers

    private static func _prepareInputText(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"<[a-zA-Z][^>]*>"#, options: .regularExpression) != nil else {
            return raw
        }

        var body = trimmed
        body = body.replacingOccurrences(of: #"(?is)<script[\s\S]*?</script>"#, with: "\n", options: .regularExpression)
        body = body.replacingOccurrences(of: #"(?is)<style[\s\S]*?</style>"#, with: "\n", options: .regularExpression)
        body = body.replacingOccurrences(of: #"(?is)<nav[\s\S]*?</nav>"#, with: "\n", options: .regularExpression)
        body = body.replacingOccurrences(of: #"(?is)<main[^>]*>"#, with: "\n", options: .regularExpression)
        body = body.replacingOccurrences(of: #"(?is)</main>"#, with: "\n", options: .regularExpression)
        body = body.replacingOccurrences(of: #"(?is)<article[^>]*>"#, with: "\n", options: .regularExpression)
        body = body.replacingOccurrences(of: #"(?is)</article>"#, with: "\n", options: .regularExpression)

        let blockReplacements: [(String, String)] = [
            (#"(?is)<h1[^>]*>"#, "\n# "),
            (#"(?is)<h2[^>]*>"#, "\n## "),
            (#"(?is)<h3[^>]*>"#, "\n### "),
            (#"(?is)<h4[^>]*>"#, "\n#### "),
            (#"(?is)</h[1-4]>"#, "\n"),
            (#"(?is)<li[^>]*>"#, "\n- "),
            (#"(?is)</li>"#, "\n"),
            (#"(?is)</p>"#, "\n"),
            (#"(?is)<br\s*/?>"#, "\n"),
            (#"(?is)</div>"#, "\n"),
            (#"(?is)</section>"#, "\n")
        ]
        for (pattern, replacement) in blockReplacements {
            body = body.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }

        body = body.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        body = _decodeHTMLEntities(body)
        body = body.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        body = body.replacingOccurrences(of: #"\n\s+"#, with: "\n", options: .regularExpression)
        body = body.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return body
    }

    private static func _decodeHTMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#160;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    /// "Skills measured" セクションの開始行 index を探す。見つからなければ nil。
    private static func _findSkillsMeasuredStart(lines: [String]) -> Int? {
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if t == "skills measured"
                || t.hasPrefix("# skills measured")
                || t.hasPrefix("## skills measured")
                || t.contains("skills measured at the time of the exam")
                || t.contains("測定されたスキル")
                || t.contains("評価されるスキル") {
                return i + 1   // start AFTER the heading
            }
        }
        return nil
    }

    /// 大幅に違うセクションに入ったかを判定する（H1 や 別主題見出し）。
    private static func _isSectionTerminator(_ trimmed: String, startIndex: Int, currentIndex: Int) -> Bool {
        // skills セクション開始直後に何でも terminator 扱いしないよう、開始から少し進んでから判定
        guard currentIndex > startIndex + 2 else { return false }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("# ")
            || lower.hasPrefix("## study resources")
            || lower.hasPrefix("## change log")
            || lower.hasPrefix("## 学習リソース")
            || lower.hasPrefix("## 変更ログ")
            || lower.hasPrefix("references") {
            return true
        }
        return false
    }

    /// Domain 行の検出。
    /// - "## ◯◯◯ (15–20%)" のように Markdown 見出し
    /// - もしくは "◯◯◯ (15-20%)" / "◯◯◯ (15%)" 単独行
    /// - 末尾の (NN–MM%) は title から除去する。
    private static func _parseDomainHeading(_ trimmed: String) -> String? {
        var t = trimmed
        // Markdown 見出し記号を剥がす
        while t.hasPrefix("#") {
            t.removeFirst()
            t = t.trimmingCharacters(in: .whitespaces)
        }
        if t.isEmpty { return nil }

        // 末尾の "(15%)" / "(15-20%)" / "(15–20%)" / "(15 ~ 20%)" / "(15 から 20%)" を剥がす
        let percentRegex = try? NSRegularExpression(
            pattern: #"\s*\(\s*\d+(?:\s*(?:[–\-~〜]|から|to)\s*\d+)?\s*[％%]\s*\)\s*$"#,
            options: []
        )
        var cleanedTitle = t
        var hasPercent = false
        if let re = percentRegex {
            let nsr = NSRange(t.startIndex..<t.endIndex, in: t)
            if let m = re.firstMatch(in: t, options: [], range: nsr), let r = Range(m.range, in: t) {
                hasPercent = true
                cleanedTitle = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }

        if trimmed.hasPrefix("-") || trimmed.hasPrefix("*") || trimmed.hasPrefix("•") {
            return nil
        }
        if trimmed.hasPrefix("###"), hasPercent, !cleanedTitle.isEmpty {
            return cleanedTitle
        }
        return nil
    }

    private static func _parseSkillHeading(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix("####") else { return nil }
        var t = trimmed
        while t.hasPrefix("#") {
            t.removeFirst()
            t = t.trimmingCharacters(in: .whitespaces)
        }
        return t.isEmpty ? nil : t
    }

    /// 箇条書き行のパース。
    /// 戻り値： (depth, 抽出した title)
    /// - depth 0 = 第1階層の bullet（Skill）
    /// - depth ≥ 1 = ネスト bullet（Topic）
    /// インデント幅は半角スペース2/4個、または tab 1つで1段とみなす。
    private static func _parseBulletItem(_ rawLine: String) -> (depth: Int, title: String)? {
        // 先頭の空白／タブの量を計測
        var leadingSpaces = 0
        for ch in rawLine {
            if ch == " " { leadingSpaces += 1 }
            else if ch == "\t" { leadingSpaces += 4 }
            else { break }
        }
        let rest = rawLine.dropFirst(_countWhitespaceChars(rawLine)).description
        let r = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.isEmpty { return nil }

        // bullet マーカ判定
        let bulletPrefixes = ["- ", "* ", "• ", "– ", "— "]
        var matched: String? = nil
        for p in bulletPrefixes {
            if r.hasPrefix(p) { matched = p; break }
        }
        guard let m = matched else { return nil }
        let title = String(r.dropFirst(m.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return nil }

        // インデント幅を depth に変換（2 space = 1 depth、4 space = 2 depth, …）
        let depth = max(0, leadingSpaces / 2)
        return (depth, title)
    }

    private static func _countWhitespaceChars(_ s: String) -> Int {
        var n = 0
        for ch in s {
            if ch == " " || ch == "\t" { n += 1 } else { break }
        }
        return n
    }

    /// 重複を避けつつ stable key を生成する。
    /// key 体系： "<prefix>:<slug>"  例 "ml.dom:plan-and-manage-an-azure-ai-solution"
    private static func _stableKey(prefix: String, title: String, used: inout Set<String>) -> String {
        let slug = _slugify(title)
        var candidate = "\(prefix):\(slug)"
        var counter = 2
        while used.contains(candidate) {
            candidate = "\(prefix):\(slug)-\(counter)"
            counter += 1
        }
        used.insert(candidate)
        return candidate
    }

    private static func _slugify(_ raw: String) -> String {
        let lowered = raw.lowercased()
        var out = ""
        out.reserveCapacity(lowered.count)
        var previousWasDash = false
        for ch in lowered {
            let scalars = ch.unicodeScalars
            guard let first = scalars.first, scalars.count == 1 else {
                // 多バイト/合成文字はそのまま保持（ハイフン化しない）
                out.append(ch)
                previousWasDash = false
                continue
            }
            let v = first.value
            if (0x30...0x39).contains(v) || (0x61...0x7A).contains(v) {
                out.append(ch)
                previousWasDash = false
            } else if !previousWasDash {
                out.append("-")
                previousWasDash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
