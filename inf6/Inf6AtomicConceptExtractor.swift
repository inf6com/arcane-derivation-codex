//
//  Inf6AtomicConceptExtractor.swift
//  inf6
//
//  工学的契約：
//    - 「シラバスから抽出された原始 outline 行は、そのままでは U の要素ではない。」
//    - 「結合・並列表記（『正規化・正則化』『データの収集・加工・分析・学習』等）は
//       原子概念に分割してから U に登録する。」
//
//  本ファイルは outline parser 由来の title 文字列を、原子概念（atomic concept）の
//  配列に分割する責務を持つ。canonical ID 採番 / alias 解決 は別レイヤの責務。
//
//  v1 範囲:
//    - 強分離記号（・、／/＆&＋+）で分割
//    - 包囲括弧の剥がし（"(GAN・VAE)" → "GAN・VAE" → ["GAN", "VAE"]）
//    - 共有 prefix 展開（"データの収集・加工" → ["データの収集", "データの加工"]）
//
//  v1 が扱わない範囲（後続課題）:
//    - "と" / "and" / "or" のような語境界による分割
//    - 同義語・略語の解決（→ canonical registry）
//    - GPT による semantic 分解
//

import Foundation

enum Inf6AtomicConceptExtractor {

    /// 強分離記号: 並列概念を明示的に区切る文字。
    /// "." や ":" は数値・形式記法に混入するため含めない。
    private static let _strongSeparators: Set<Character> = [
        "・", "、", "／", "/", "＆", "&", "＋", "+",
    ]

    /// 包囲括弧ペア（先頭/末尾を同時に持つ場合に剥がす）。
    private static let _wrappingBracketPairs: [(Character, Character)] = [
        ("(", ")"), ("（", "）"), ("[", "]"), ("【", "】"), ("「", "」"), ("『", "』"),
    ]

    // MARK: - Public API

    /// 与えられた title 文字列を原子概念配列に分割する。
    /// 分離記号がない場合は単一要素配列を返す（元の入力をそのまま 1 つの概念として扱う）。
    /// 入力が空白/空文字なら空配列を返す。
    static func extract(from rawTitle: String) -> [String] {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }

        // 1) 文中の括弧内に並列概念がある場合は、括弧外の基底概念と
        //    括弧内の原子概念を分ける。
        if let parenthetical = _extractParentheticalComposite(trimmed) {
            return parenthetical
        }

        // 2) 包囲括弧を剥がす
        let stripped = _stripWrappingBrackets(trimmed)

        // 3) 分離記号がなければ単一概念として返す
        let hasSeparator = stripped.contains { _strongSeparators.contains($0) }
        if !hasSeparator { return [stripped] }

        // 4) 強分離記号で素朴に分割
        let parts = _splitOnStrongSeparators(stripped)
        if parts.isEmpty { return [stripped] }
        if parts.count == 1 { return parts }

        // 5) 共有 prefix の展開を試みる
        return _expandSharedPrefix(parts: parts)
    }

    /// 複数の title をまとめて分割し、平坦化した原子概念配列を返す。
    /// 順序は入力順を保持する。
    static func extractAll(from rawTitles: [String]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(rawTitles.count * 2)
        for t in rawTitles {
            out.append(contentsOf: extract(from: t))
        }
        return out
    }

    /// この title 文字列が分離可能か（分離記号を含むか）を判定する。
    /// 呼び出し側で「結合表記の検出」用途に使う想定。
    static func isComposite(_ rawTitle: String) -> Bool {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = _stripWrappingBrackets(trimmed)
        return stripped.contains { _strongSeparators.contains($0) }
    }

    // MARK: - Internal helpers

    private static func _stripWrappingBrackets(_ s: String) -> String {
        for (open, close) in _wrappingBracketPairs {
            if s.hasPrefix(String(open)) && s.hasSuffix(String(close)) && s.count >= 2 {
                let inner = s.dropFirst().dropLast()
                return String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return s
    }

    private static func _extractParentheticalComposite(_ s: String) -> [String]? {
        for (open, close) in _wrappingBracketPairs {
            guard let openIndex = s.firstIndex(of: open),
                  let closeIndex = s.lastIndex(of: close),
                  openIndex < closeIndex
            else { continue }

            let inner = String(s[s.index(after: openIndex)..<closeIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard inner.contains(where: { _strongSeparators.contains($0) }) else { continue }

            let head = String(s[..<openIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let tailStart = s.index(after: closeIndex)
            let tail = String(s[tailStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard tail.isEmpty else { continue }

            let innerParts = _splitOnStrongSeparators(inner)
            var out: [String] = []
            if !head.isEmpty { out.append(head) }
            out.append(contentsOf: innerParts)
            return out.isEmpty ? nil : out
        }
        return nil
    }

    private static func _splitOnStrongSeparators(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for ch in s {
            if _strongSeparators.contains(ch) {
                let t = _stripLooseBoundaryBrackets(current.trimmingCharacters(in: .whitespacesAndNewlines))
                if !t.isEmpty { parts.append(t) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        let lastT = _stripLooseBoundaryBrackets(current.trimmingCharacters(in: .whitespacesAndNewlines))
        if !lastT.isEmpty { parts.append(lastT) }
        return parts
    }

    private static func _stripLooseBoundaryBrackets(_ s: String) -> String {
        var out = s
        let opens = Set(_wrappingBracketPairs.map(\.0))
        let closes = Set(_wrappingBracketPairs.map(\.1))
        while let first = out.first, opens.contains(first) {
            out.removeFirst()
            out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while let last = out.last, closes.contains(last) {
            out.removeLast()
            out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }

    /// 共有 prefix 展開:
    ///   入力 parts = ["データの収集", "加工", "分析", "学習"]
    ///     → 先頭 part に "...の" がある場合、prefix = "データの"
    ///     → 後続 parts のうち prefix を持たないものに prefix を補う
    ///   結果 = ["データの収集", "データの加工", "データの分析", "データの学習"]
    ///
    /// 安全策:
    ///   - 先頭 part に "の" がない、または prefix 候補が短すぎる場合は展開せず元の parts を返す
    ///   - 後続 parts 自体に "の" を含む場合（独立した概念の可能性が高い）は展開しない
    ///   - 後続 parts が長すぎる（先頭 part の suffix 部分より明らかに長い）場合は独立扱い
    private static func _expandSharedPrefix(parts: [String]) -> [String] {
        guard parts.count >= 2 else { return parts }
        let first = parts[0]

        // 最後の "の" を探す
        guard let lastNoRange = first.range(of: "の", options: .backwards) else {
            return parts
        }
        let prefix = String(first[..<lastNoRange.upperBound])  // "...の" まで含む
        let firstSuffix = String(first[lastNoRange.upperBound...])
        if prefix.count < 2 || firstSuffix.isEmpty {
            return parts
        }

        // 後続 parts が独立概念かどうかをチェック
        // - 自分自身に "の" を含む（句が独立している）
        // - 先頭 part の suffix の 1.6 倍より長い（独立概念の可能性大）
        for tail in parts.dropFirst() {
            if tail.contains("の") { return parts }
            if tail.count > Int(Double(firstSuffix.count) * 1.6 + 0.5) {
                return parts
            }
        }

        // 展開実行
        var expanded: [String] = [first]
        for tail in parts.dropFirst() {
            if tail.hasPrefix(prefix) {
                expanded.append(tail)
            } else {
                expanded.append(prefix + tail)
            }
        }
        return expanded
    }
}
