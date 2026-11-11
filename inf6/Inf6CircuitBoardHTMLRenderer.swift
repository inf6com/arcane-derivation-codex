//
//  Inf6CircuitBoardHTMLRenderer.swift
//  inf6
//
//  Server-side (Swift-side) circuit-board renderer.
//  Generates a COMPLETE static HTML document with embedded SVG. No D3, no
//  client-side layout, no JSON injection. The WebView only loads the file and
//  forwards taps via window.webkit.messageHandlers.
//
//  Architecture:
//    domains[]  →  layout()  →  SVG string  →  HTML wrapper  →  file URL
//
//  All node positions, ring states, and labels are computed in Swift.
//  Updates re-generate the HTML; the WebView is then asked to reload the file.
//

import Foundation
import CoreGraphics
import QuartzCore  // for CACurrentMediaTime

enum Inf6CircuitBoardHTMLRenderer {

    // MARK: - Tunables

    // Concept labels are measured from their text. A concept is not forced into a
    // fixed-size node unless the view is showing a top-level set label.
    private static let nodeRx: CGFloat = 130          // horizontal radius
    private static let nodeRy: CGFloat = 48           // vertical radius
    private static let nodeFontSize: CGFloat = 24
    private static let nodeLineHeight: CGFloat = 30
    private static let nodeMaxLines: Int = 2
    private static let nodeCharWidth: CGFloat = 25    // approx px per Japanese char at fontSize=24
    private static let homeNodeRx: CGFloat = 175
    private static let homeNodeRy: CGFloat = 56
    private static let canvasWidth: CGFloat = 1400
    private static let topMargin: CGFloat = 80
    private static let bottomMargin: CGFloat = 80
    /// Helix amplitude (the X swing of the sine wave). Constrained so that
    /// even the widest node, when at the helix peak, doesn't enter the paper lanes.
    private static let nodeFieldHalfWidth: CGFloat = 280
    /// Hard cap on a single node's horizontal radius. Long labels wrap to more
    /// lines instead of widening the ellipse beyond this.
    private static let nodeMaxRx: CGFloat = 130
    /// Width of each side paper lane (left / right). Paper labels are truncated
    /// horizontally to fit within this width.
    private static let paperLaneWidth: CGFloat = 460
    /// Inset from the canvas edge to the start of each paper lane.
    private static let paperLaneInset: CGFloat = 8
    /// Gap between the inner edge of a paper lane and the helix node region.
    private static let helixToPaperGap: CGFloat = 16

    private static let paperFontSize: CGFloat = 18
    private static let paperRowHeight: CGFloat = 28

    /// Bump this whenever the rendering algorithm changes, so the SSR HTML
    /// cache (keyed by fingerprint) is invalidated even when underlying data
    /// hasn't changed.
    static let rendererVersion: String = "v54-domain-scored-hot-basic"

    // Neutral visual palette. Knowledge nodes themselves do not carry color.
    private static let bgColor = "#f8fafc"
    private static let textColor = "#0f172a"
    private static let mutedColor = "#64748b"
    private static let defaultNodeColor = "#475569"
    private static let neutralNodeFill = "#e8eef7"
    private static let neutralNodeStroke = "#475569"
    private static let neutralEdgeStroke = "#64748b"

    // MARK: - Public entry

    /// Render the circuit board to a complete HTML document.
    /// - Parameters:
    ///   - domains: same domain dict array previously sent to the JS layer
    ///   - lang: "ja" or "en"
    static func renderHTML(domains: [[String: Any]], lang: String, focusRawID: String? = nil) -> String {
        let t0 = CACurrentMediaTime()
        let isJA = (lang != "en")
        let universalSet = Inf6UniversalConceptSet.build(fromDomainDictionaries: domains)
        Inf6KnowledgeStructureStore.persist(universalSet)
        let clusters = _buildClusterModel(universalSet: universalSet, isJA: isJA, focusRawID: focusRawID)
        let t1 = CACurrentMediaTime()

        let clusterBottom = (clusters.map { $0.clusterBottom }.max() ?? 0) + bottomMargin
        let canvasH = max(clusterBottom, 360)

        let svg = _renderClustersSVG(clusters: clusters, width: canvasWidth, height: canvasH)
        let html = _wrapHTML(svg: svg, width: canvasWidth, height: canvasH)
        let t2 = CACurrentMediaTime()
        let nodeCount = clusters.reduce(0) { $0 + $1.nodes.count }
        print(String(format: "[CircuitBoard][SSR] build=%.1fms svg=%.1fms total=%.1fms subsets=%d nodes=%d",
                     (t1 - t0) * 1000, (t2 - t1) * 1000, (t2 - t0) * 1000,
                     universalSet.domainSubsets.count, nodeCount))
        return html
    }

    /// Render only the application home surface.
    /// Home is the currently held family subsets under AI. It must not load
    /// domain outlines, papers, achievements, or generated artifacts.
    static func renderHomeHTML(manifests: [Inf6LearningFamilyManifest], lang: String) -> String {
        let isJA = (lang != "en")
        let rootTitle = "AI"
        let rootMeasure = _measureHomeClusterLabel(rootTitle)
        let rootID = "home:ai"
        var nodes: [_NodeM] = [
            _NodeM(
                id: rootID,
                rawID: rootID,
                parentRawIDs: [],
                title: rootTitle,
                color: neutralNodeStroke,
                achievement: "not_started",
                classID: "ai-foundations",
                depth: 0,
                lines: rootMeasure.lines,
                x: 0, y: 0,
                rx: rootMeasure.rx, ry: rootMeasure.ry,
                strand: 0,
                sourceDomains: []
            )
        ]
        for manifest in manifests.sorted(by: { a, b in
            _domainDisplayTitle(sourceFamily: a.sourceFamily, title: isJA ? a.displayNameJa : a.displayNameEn, isJapanese: isJA)
                .localizedStandardCompare(_domainDisplayTitle(sourceFamily: b.sourceFamily, title: isJA ? b.displayNameJa : b.displayNameEn, isJapanese: isJA)) == .orderedAscending
        }) {
            let title = _domainDisplayTitle(
                sourceFamily: manifest.sourceFamily,
                title: isJA ? manifest.displayNameJa : manifest.displayNameEn,
                isJapanese: isJA
            )
            let rawID = "domain:\(manifest.sourceFamily)"
            let measure = _measureHomeClusterLabel(title)
            nodes.append(_NodeM(
                id: "\(manifest.sourceFamily)|\(rawID)",
                rawID: rawID,
                parentRawIDs: [rootID],
                title: title,
                color: neutralNodeStroke,
                achievement: "not_started",
                classID: "ai-foundations",
                depth: 1,
                lines: measure.lines,
                x: 0, y: 0,
                rx: measure.rx, ry: measure.ry,
                strand: 0,
                sourceDomains: [manifest.sourceFamily]
            ))
        }
        let clusters = _layoutClusters([
            _Cluster(sourceFamily: "home", displayTitle: "", nodes: nodes, isOverview: true)
        ])
        let clusterBottom = (clusters.map { $0.clusterBottom }.max() ?? 0) + bottomMargin
        let canvasH = max(clusterBottom, 360)
        let svg = _renderClustersSVG(clusters: clusters, width: canvasWidth, height: canvasH)
        return _wrapHTML(svg: svg, width: canvasWidth, height: canvasH)
    }

    /// Collect paper labels from domain dicts and lay them out in two side
    /// lanes (far-left / far-right) so they never overlap the helix in the
    /// center band. Papers are sorted by year descending.
    private static func _collectPapers(domains: [[String: Any]], isJA: Bool, helixBottom: CGFloat) -> [_PaperM] {
        struct _RawPaper {
            let id: String
            let title: String
            let year: Int?
            let color: String
        }
        var raws: [_RawPaper] = []
        for domain in domains {
            guard let papers = domain["papers"] as? [[String: Any]] else { continue }
            for p in papers {
                let titleJA = (p["paper_title_ja"] as? String) ?? ""
                let titleEN = (p["paper_title_en"] as? String) ?? (p["paper_title"] as? String) ?? ""
                let title = isJA ? (titleJA.isEmpty ? titleEN : titleJA)
                                 : (titleEN.isEmpty ? titleJA : titleEN)
                if title.isEmpty { continue }
                let yearRaw: Int? = {
                    if let v = p["source_year"] as? Int, v > 0 { return v }
                    if let v = p["source_year"] as? Double, v > 0 { return Int(v) }
                    return nil
                }()
                let pid = (p["paper_id"] as? String) ?? UUID().uuidString
                let firstNodeID = ((p["syllabus_node_ids"] as? [String])?.first) ?? ""
                let color = _scienceColorFor(classID: firstNodeID, title: title)
                raws.append(_RawPaper(id: pid, title: title, year: yearRaw, color: color))
            }
        }
        // Sort by year desc; nil years go to the end.
        raws.sort { (a, b) in
            switch (a.year, b.year) {
            case let (ya?, yb?): return ya > yb
            case (.some, .none): return true
            case (.none, .some): return false
            default: return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }

        // Two-lane layout: left (side=-1) and right (side=+1).
        // Each lane is `paperLaneWidth` wide. The helix region between the two
        // lanes is wide enough for the widest node (bounded by nodeMaxRx).
        let leftStartX: CGFloat = paperLaneInset
        let rightStartX: CGFloat = canvasWidth - paperLaneInset - paperLaneWidth
        var leftY: CGFloat = topMargin
        var rightY: CGFloat = topMargin
        var out: [_PaperM] = []
        out.reserveCapacity(raws.count)
        for (i, r) in raws.enumerated() {
            let side = (i % 2 == 0) ? -1 : 1
            let x: CGFloat = side < 0 ? leftStartX : rightStartX
            let y: CGFloat
            if side < 0 {
                y = leftY
                leftY += paperRowHeight
            } else {
                y = rightY
                rightY += paperRowHeight
            }
            // Pre-truncate the title so the SVG text never extends beyond the lane.
            // Year prefix (e.g. "2024 ") is added at render time; subtract its budget.
            let yearPrefixBudget: CGFloat = r.year != nil ? (paperFontSize * 0.55 * 5) : 0
            let titleBudget = paperLaneWidth - yearPrefixBudget - 6
            let truncatedTitle = _truncatePaperTitleToWidth(r.title, budget: titleBudget)
            out.append(_PaperM(
                id: r.id,
                title: truncatedTitle,
                year: r.year,
                color: r.color,
                side: side,
                x: x,
                y: y
            ))
        }
        _ = helixBottom  // future use: pad paper start so they begin alongside helix
        return out
    }

    /// Build the DNA double helix model from the observed concept set.
    /// Node order: classification rank → locale-aware title (deterministic).
    /// Each node = one canonical concept ∈ O.
    /// Adjacent nodes alternate strand (0 = blue, 1 = red).
    private static func _buildHelixModel(
        universalSet: Inf6UniversalConceptSet,
        isJA: Bool
    ) -> _Model {
        // 1. Collect concepts and sort deterministically.
        let concepts = Array(universalSet.conceptsByID.values)
        let sorted = concepts.sorted { a, b in
            let ra = _classOrderRank(a.classificationID ?? "")
            let rb = _classOrderRank(b.classificationID ?? "")
            if ra != rb { return ra < rb }
            return a.displayTitle(isJapanese: isJA)
                .localizedStandardCompare(b.displayTitle(isJapanese: isJA)) == .orderedAscending
        }

        // 2. Construct _NodeM[] (positions filled in step 3).
        var rawNodes: [_NodeM] = []
        rawNodes.reserveCapacity(sorted.count)
        for c in sorted {
            let title = c.displayTitle(isJapanese: isJA)
            let m = _measureLabel(title)
            let color = _scienceColorFor(classID: c.classificationID ?? "", title: title)
            // achievement = max across domains for this concept
            let aggregatedAchievement = c.achievementsByDomain.values
                .reduce(into: "not_started") { acc, v in acc = _joinAchievement(acc, v) }
            rawNodes.append(_NodeM(
                id: c.canonicalID,
                rawID: c.canonicalID,
                parentRawIDs: [],
                title: title,
                color: color,
                achievement: aggregatedAchievement,
                classID: c.classificationID ?? "",
                depth: 0,
                lines: m.lines,
                x: 0, y: 0,
                rx: m.rx, ry: m.ry,
                strand: 0,
                sourceDomains: c.sourceDomains
            ))
        }

        // 3. DNA helix layout: one node per Y row, alternating strands.
        //    Strand A (idx even) and Strand B (idx odd) trace antiphase sine waves.
        //    Start both at x=center (different Y) — vertical separation at start.
        //
        //    Amplitude is constrained so that even at the helix peak, a node of
        //    maximum rx (nodeMaxRx) stops before the paper lane:
        //      centerX + amplitude + nodeMaxRx + helixToPaperGap ≤ rightLaneStart
        //      → amplitude ≤ (rightLaneStart - centerX) - nodeMaxRx - helixToPaperGap
        let centerX = canvasWidth / 2
        let rightLaneStart = canvasWidth - paperLaneInset - paperLaneWidth
        let amplitudeCap = (rightLaneStart - centerX) - nodeMaxRx - helixToPaperGap
        let amplitude = min(nodeFieldHalfWidth * 0.55, max(40, amplitudeCap))
        let stepsPerTurn = 5.0
        let angleStep = 2 * Double.pi / stepsPerTurn
        let startY = topMargin

        func helixX(idx: Int) -> CGFloat {
            let strand = idx % 2
            let step = Double(idx / 2)
            let phase = step * angleStep + (strand == 1 ? Double.pi : 0)
            return centerX + amplitude * CGFloat(sin(phase))
        }

        var nodesOut: [_NodeM] = []
        nodesOut.reserveCapacity(rawNodes.count)
        // Look-back window covers one full helix turn so same-strand 2-prior
        // collisions are caught.
        let lookBack = Int(stepsPerTurn * 2) + 4
        var y: CGFloat = startY
        for (idx, raw) in rawNodes.enumerated() {
            var node = raw
            node.strand = idx % 2
            node.x = helixX(idx: idx)
            // Minimum Y so this node doesn't overlap any recent placed node.
            var minY: CGFloat = (idx == 0) ? startY : (nodesOut.last!.y + 1)
            let windowStart = max(0, nodesOut.count - lookBack)
            for prev in nodesOut[windowStart..<nodesOut.count] {
                let dx = abs(node.x - prev.x)
                let cRx = node.rx + prev.rx
                let cRy = node.ry + prev.ry
                let dxFrac = min(dx / cRx, 0.999)
                let dyMin = cRy * CGFloat(sqrt(1.0 - Double(dxFrac * dxFrac)))
                let requiredY = prev.y + dyMin + 6
                if requiredY > minY { minY = requiredY }
            }
            node.y = max(y, minY)
            y = node.y
            nodesOut.append(node)
        }

        return _Model(nodes: nodesOut, papers: [])
    }

    // MARK: - Model

    private struct _NodeM {
        let id: String         // composite id (used for tap)
        let rawID: String      // raw node id for tap callback
        var parentRawIDs: Set<String>  // UNION of parents across syllabi (DAG)
        let title: String
        let color: String
        var achievement: String        // joined across syllabi (max)
        let classID: String
        let depth: Int
        let lines: [String]    // pre-wrapped label
        var x: CGFloat
        var y: CGFloat
        var rx: CGFloat        // ellipse horizontal radius
        var ry: CGFloat        // ellipse vertical radius
        var strand: Int        // 0 = strand A, 1 = strand B
        var sourceDomains: Set<String>  // sourceFamily of every syllabus that contains this concept
        var edgeKindByParentRawID: [String: String] = [:]
        var hotScore: Double = 0
        var basicScore: Double = 0
    }

    /// Knowledge order: foundations → core → applied → systems → AI services →
    /// responsible AI. Used only as a tiebreak between ROOTS of separate trees;
    /// inside a tree, traversal follows the actual parent-child structure.
    private static let _classOrder: [String: Int] = [
        "mathematics-statistics":       0,
        "ai-foundations":               1,
        "machine-learning":             2,
        "deep-learning":                3,
        "reinforcement-learning":       4,
        "graph-learning":               5,
        "systems-implementation":       6,
        "azure-ai-services":            7,
        "responsible-ai-governance":    8,
    ]
    private static func _classOrderRank(_ classID: String) -> Int {
        return _classOrder[classID.lowercased()] ?? 99
    }

    /// Set-theoretic merge of nodes that represent the SAME concept across syllabi.
    /// Identity = lowercased trimmed title. For the merged node:
    ///   parentRawIDs = UNION of all source nodes' parents
    ///   achievement   = JOIN (max) across sources
    ///   rawID         = first source's rawID (used as the merged node's identity)
    /// All other syllabi reference the first rawID via a remap dictionary so
    /// children pointing at any of the merged rawIDs still resolve correctly.
    private static func _mergeSameConceptNodes(_ nodes: [_NodeM]) -> [_NodeM] {
        if nodes.isEmpty { return [] }

        // Pass 1: assign a canonical rawID per concept-title.
        var canonicalRawIDByTitle: [String: String] = [:]
        var rawIDRemap: [String: String] = [:]
        for n in nodes {
            let key = n.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let canon = canonicalRawIDByTitle[key] {
                rawIDRemap[n.rawID] = canon
            } else {
                canonicalRawIDByTitle[key] = n.rawID
                rawIDRemap[n.rawID] = n.rawID
            }
        }

        // Pass 2: collect/union into one node per concept-title.
        var merged: [String: _NodeM] = [:]    // key = canonical rawID
        var order: [String] = []              // preserves first-seen order
        for n in nodes {
            let key = n.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let canon = canonicalRawIDByTitle[key]!
            // Remap this node's parents to canonical IDs.
            let remappedParents = Set(n.parentRawIDs.compactMap { rawIDRemap[$0] ?? $0 })
            if var existing = merged[canon] {
                existing.parentRawIDs.formUnion(remappedParents)
                existing.achievement = _joinAchievement(existing.achievement, n.achievement)
                existing.sourceDomains.formUnion(n.sourceDomains)
                merged[canon] = existing
            } else {
                var fresh = n
                // Rewrite rawID to canonical (which equals n.rawID for the first occurrence)
                // and replace parents with remapped union.
                fresh.parentRawIDs = remappedParents
                merged[canon] = fresh
                order.append(canon)
            }
        }
        return order.compactMap { merged[$0] }
    }

    /// Lattice join over achievement states. Higher state wins.
    private static func _joinAchievement(_ a: String, _ b: String) -> String {
        let rank: [String: Int] = [
            "not_started": 0, "started": 1, "collecting": 2, "annotating": 3,
            "in_progress": 4, "explained": 5, "questioned": 6, "passed": 7,
            "completed": 8, "verified": 9
        ]
        let ra = rank[a.lowercased()] ?? 0
        let rb = rank[b.lowercased()] ?? 0
        return ra >= rb ? a : b
    }

    /// Depth-first traversal of the knowledge DAG.
    /// - Roots: nodes whose parent set is empty OR whose parents are all absent.
    /// - Children: visited in classification → title order for determinism.
    /// - Visited-set prevents revisiting a concept reachable from multiple parents.
    private static func _knowledgeTreeOrder(_ nodes: [_NodeM]) -> [_NodeM] {
        if nodes.isEmpty { return [] }
        let byRawID: [String: _NodeM] = Dictionary(uniqueKeysWithValues: nodes.map { ($0.rawID, $0) })
        var childrenOf: [String: [_NodeM]] = [:]
        var roots: [_NodeM] = []
        for n in nodes {
            let presentParents = n.parentRawIDs.filter { byRawID[$0] != nil }
            if presentParents.isEmpty {
                roots.append(n)
            } else {
                for pid in presentParents {
                    childrenOf[pid, default: []].append(n)
                }
            }
        }
        func sortSiblings(_ arr: inout [_NodeM]) {
            arr.sort { a, b in
                let ra = _classOrderRank(a.classID)
                let rb = _classOrderRank(b.classID)
                if ra != rb { return ra < rb }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
        sortSiblings(&roots)
        for k in childrenOf.keys {
            sortSiblings(&childrenOf[k]!)
        }

        var out: [_NodeM] = []
        out.reserveCapacity(nodes.count)
        var visited = Set<String>()
        var stack: [_NodeM] = roots.reversed()
        while let top = stack.popLast() {
            if visited.contains(top.rawID) { continue }
            visited.insert(top.rawID)
            out.append(top)
            if let kids = childrenOf[top.rawID] {
                for k in kids.reversed() { stack.append(k) }
            }
        }
        if out.count < nodes.count {
            for n in nodes where !visited.contains(n.rawID) {
                out.append(n)
            }
        }
        return out
    }

    private struct _PaperM {
        let id: String
        let title: String
        let year: Int?
        let color: String
        let side: Int          // -1 left, +1 right
        let x: CGFloat
        let y: CGFloat
    }

    private struct _Model {
        let nodes: [_NodeM]
        let papers: [_PaperM]
    }

    // MARK: - Layout

    /// Per-character visual width (px) at the current font size. ASCII chars are
    /// about half the width of CJK glyphs.
    private static func _charPxWidth(_ ch: Character) -> CGFloat {
        let scalars = ch.unicodeScalars
        guard let first = scalars.first else { return nodeCharWidth }
        let v = first.value
        // Basic ASCII (digits, latin letters, punctuation) → narrow
        if v < 0x80 { return nodeCharWidth * 0.55 }
        // Half-width katakana
        if (0xFF61...0xFF9F).contains(v) { return nodeCharWidth * 0.6 }
        // Everything else (CJK, full-width latin, kana, kanji) → full width
        return nodeCharWidth
    }

    private static func _lineWidth(_ s: String) -> CGFloat {
        var w: CGFloat = 0
        for ch in s { w += _charPxWidth(ch) }
        return w
    }

    /// Truncate a paper title with an ellipsis so its rendered width fits
    /// within the given pixel budget. Uses the paperFontSize-tuned char widths.
    private static func _truncatePaperTitleToWidth(_ title: String, budget: CGFloat) -> String {
        // Paper labels use a different fontSize than node labels; scale char widths.
        let scale = paperFontSize / nodeCharWidth   // approximate
        var width: CGFloat = 0
        var out = ""
        let ellipsisW = _charPxWidth("…") * scale
        for ch in title {
            let w = _charPxWidth(ch) * scale
            if width + w > budget - ellipsisW {
                out += "…"
                return out
            }
            out.append(ch)
            width += w
        }
        return out
    }

    /// Measure label and return ellipse sized tightly around the actual text.
    ///
    /// Strategy:
    /// 1. ALWAYS try a single line first. The ellipse will grow horizontally to
    ///    accommodate up to `singleLineMaxWidth` (much larger than nodeRx*2).
    ///    Wrapping is avoided unless the text is REALLY long.
    /// 2. Only when the text exceeds `singleLineMaxWidth` do we fall back to
    ///    multi-line wrapping (word-boundary for English, char-chunking for JA).
    ///    The wrap budget is `wrapWidth` (≈ nodeRx*2*0.9).
    private static func _measureLabel(_ text: String) -> (lines: [String], rx: CGFloat, ry: CGFloat) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ([""], nodeRx * 0.4, nodeRy * 0.6)
        }

        // Single-line budget is constrained by nodeMaxRx so the ellipse can never
        // bleed into the side paper lanes. Text wider than this gets wrapped.
        // An ellipse with rx=R holds horizontal text up to ~ 2*R*0.85.
        let singleLineMaxWidth: CGFloat = nodeMaxRx * 2.0 * 0.85 - 8
        let oneLineW = _lineWidth(trimmed)
        if oneLineW <= singleLineMaxWidth {
            return ([trimmed], _fitRx(forLineWidth: oneLineW), _fitRy(lineCount: 1))
        }

        // Too wide for a single line → wrap with natural break points.
        // Wrap width is constrained by nodeMaxRx so the ellipse never bleeds
        // into the side paper lanes. Allow more lines if needed instead of
        // widening the ellipse.
        let totalW = oneLineW
        // Max wrap width is the same single-line budget — wider than that the
        // ellipse can't physically hold without crossing into paper lanes.
        let wrapWidthCap: CGFloat = singleLineMaxWidth
        // Each line's average needed width if perfectly distributed.
        let evenWidth = totalW / CGFloat(nodeMaxLines)
        var wrapWidth: CGFloat = min(wrapWidthCap, max(wrapWidthCap * 0.6, evenWidth + nodeCharWidth))
        var lines: [String] = []
        // Absolute cap = the lane-bounded budget. We never exceed it.
        let absoluteCap = wrapWidthCap
        var attempts = 0
        while attempts < 6 {
            lines = _wrapNatural(trimmed, usableWidth: wrapWidth, maxLines: nodeMaxLines)
            // Check if the wrap covered all input (no truncation = no "…" at end
            // AND the joined-by-content length matches).
            let joined = lines.joined()
            let originalNoSpaces = trimmed.replacingOccurrences(of: " ", with: "")
            let joinedNoSpaces = joined.replacingOccurrences(of: " ", with: "")
                                       .replacingOccurrences(of: "…", with: "")
            if joinedNoSpaces.count >= originalNoSpaces.count {
                break  // full text preserved
            }
            // Grow the budget and retry.
            wrapWidth = min(absoluteCap, wrapWidth * 1.25 + nodeCharWidth)
            if wrapWidth >= absoluteCap { break }
            attempts += 1
        }
        let widest = lines.map(_lineWidth).max() ?? 0
        return (lines, _fitRx(forLineWidth: widest), _fitRy(lineCount: lines.count))
    }

    private static func _measureHomeClusterLabel(_ text: String) -> (lines: [String], rx: CGFloat, ry: CGFloat) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ([""], homeNodeRx, homeNodeRy)
        }
        let usableWidth = homeNodeRx * 2 * 0.82
        let lines = _wrapNatural(trimmed, usableWidth: usableWidth, maxLines: nodeMaxLines)
        return (lines, homeNodeRx, homeNodeRy)
    }

    /// Wrap respecting natural break points:
    /// 1. "・" (middle dot) — strong break (no whitespace consumed; "・" stays at line END)
    /// 2. " " (ASCII space) — strong break (space is consumed)
    /// 3. Boundary between ASCII letters/digits and CJK characters
    /// 4. Between two CJK characters (fallback)
    /// Never breaks inside an ASCII word.
    private static func _wrapNatural(_ text: String, usableWidth: CGFloat, maxLines: Int) -> [String] {
        let chars = Array(text)
        if chars.isEmpty { return [""] }

        // Break opportunities = list of indices i where a line MAY end with chars[..<i]
        // and the next line starts with chars[i...]. We rank them so we prefer
        // strong breaks (・, space, script boundary).
        struct BreakOp { let endExclusive: Int; let nextStart: Int; let rank: Int }
        var ops: [BreakOp] = []
        ops.reserveCapacity(chars.count)
        for i in 0..<chars.count - 1 {
            let a = chars[i]
            let b = chars[i + 1]
            if a == "・" {
                ops.append(BreakOp(endExclusive: i + 1, nextStart: i + 1, rank: 0))  // strongest
            } else if a == " " {
                ops.append(BreakOp(endExclusive: i, nextStart: i + 1, rank: 0))
            } else if _isASCIILetterOrDigit(a) != _isASCIILetterOrDigit(b),
                      !_isASCIILetterOrDigit(a) || !_isASCIILetterOrDigit(b) {
                // script transition (ascii↔cjk)
                ops.append(BreakOp(endExclusive: i + 1, nextStart: i + 1, rank: 1))
            } else if _isKatakana(a) != _isKatakana(b),
                      !_isASCIILetterOrDigit(a) && !_isASCIILetterOrDigit(b) {
                // katakana↔non-katakana boundary (e.g. 漢字 / カタカナ)
                ops.append(BreakOp(endExclusive: i + 1, nextStart: i + 1, rank: 1))
            } else if !_isASCIILetterOrDigit(a) && !_isASCIILetterOrDigit(b) {
                // CJK-to-CJK (within same script)
                ops.append(BreakOp(endExclusive: i + 1, nextStart: i + 1, rank: 2))
            }
            // ASCII-to-ASCII inside a word → no break
        }

        // Greedy: pick the best break <= usableWidth for each line.
        var lines: [String] = []
        var cursor = 0
        while cursor < chars.count, lines.count < maxLines {
            // Try to fit the entire remainder on this line first.
            let remainder = String(chars[cursor...])
            if _lineWidth(remainder) <= usableWidth {
                lines.append(remainder)
                cursor = chars.count
                break
            }
            // Find candidate breaks within budget.
            var bestOp: BreakOp? = nil
            for op in ops where op.endExclusive > cursor && op.endExclusive <= chars.count {
                let line = String(chars[cursor..<op.endExclusive])
                if _lineWidth(line) > usableWidth { continue }
                // Choose the break with smallest rank (strongest); tie-break by
                // longest line (preserves more chars).
                if let curr = bestOp {
                    if op.rank < curr.rank || (op.rank == curr.rank && op.endExclusive > curr.endExclusive) {
                        bestOp = op
                    }
                } else {
                    bestOp = op
                }
            }
            if let chosen = bestOp {
                lines.append(String(chars[cursor..<chosen.endExclusive]))
                cursor = chosen.nextStart
            } else {
                // No valid break within budget — force a hard break by characters.
                var line = ""
                var width: CGFloat = 0
                var i = cursor
                while i < chars.count {
                    let w = _charPxWidth(chars[i])
                    if width + w > usableWidth, !line.isEmpty { break }
                    line.append(chars[i])
                    width += w
                    i += 1
                }
                lines.append(line)
                cursor = i
            }
        }
        // If cursor didn't reach end, ellipsize last line.
        if cursor < chars.count, var last = lines.last {
            let rest = String(chars[cursor...])
            last = _ellipsizeToWidth(last + rest, usableWidth: usableWidth)
            lines[lines.count - 1] = last
        }
        return lines.isEmpty ? [""] : lines
    }

    private static func _isASCIILetterOrDigit(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        return (0x30...0x39).contains(v) || (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
    }

    /// Katakana detection: full-width katakana block plus half-width katakana
    /// and the prolonged-sound mark.
    /// - U+30A0…30FF: katakana block (includes ー U+30FC)
    /// - U+FF65…FF9F: half-width katakana
    private static func _isKatakana(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        return (0x30A0...0x30FF).contains(v) || (0xFF65...0xFF9F).contains(v)
    }

    /// Tight horizontal radius for a label whose widest line has the given width.
    /// Adds a small horizontal padding inside the ellipse so text doesn't touch the border.
    private static func _fitRx(forLineWidth lineW: CGFloat) -> CGFloat {
        // An ellipse with rx=R holds horizontal text up to ~ 2*R*0.85.
        // Inverse: R = lineW / 1.7  (i.e. 2*0.85 = 1.7)
        // Cap at nodeMaxRx so wide labels can't bleed into the paper lanes;
        // _measureLabel re-wraps text into more lines to fit when capped.
        let minRx: CGFloat = nodeFontSize * 1.6
        let fitted = max(minRx, lineW / 1.7 + 6)
        return min(fitted, nodeMaxRx)
    }

    /// Tight vertical radius based on line count and lineHeight.
    private static func _fitRy(lineCount: Int) -> CGFloat {
        let textHeight = CGFloat(lineCount) * nodeLineHeight
        // Ellipse ry must contain textHeight vertically: 2*ry*0.85 ≥ textHeight  → ry ≥ textHeight/1.7
        // Add small vertical padding.
        let minRy: CGFloat = nodeFontSize * 1.0
        return max(minRy, textHeight / 1.7 + 6)
    }

    /// Greedy word-boundary wrap. Never splits in the middle of a word.
    /// If a single word is wider than `usableWidth`, that word still occupies
    /// its own line (no mid-word break).
    private static func _wrapByWords(_ text: String, usableWidth: CGFloat, maxLines: Int) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        if words.isEmpty { return [""] }
        var lines: [String] = []
        var current = ""
        for w in words {
            if current.isEmpty {
                current = w
                continue
            }
            let candidate = current + " " + w
            if _lineWidth(candidate) <= usableWidth {
                current = candidate
            } else {
                lines.append(current)
                if lines.count >= maxLines {
                    // Out of lines: re-append remainder of words to last line and ellipsize.
                    var tail = w
                    let remainingIndex = words.firstIndex(of: w).map { words.index(after: $0) } ?? words.endIndex
                    for rest in words[remainingIndex...] {
                        tail += " " + rest
                    }
                    let lastLine = _ellipsizeToWidth(tail, usableWidth: usableWidth)
                    // Replace the last line we appended with the truncated tail? Actually
                    // the spec is: prior lines stay, append truncated as final line if room,
                    // else replace last line.
                    if lines.count > maxLines - 1 {
                        lines[lines.count - 1] = _ellipsizeToWidth(lines[lines.count - 1] + " " + tail, usableWidth: usableWidth)
                    } else {
                        lines.append(lastLine)
                    }
                    return lines
                }
                current = w
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.isEmpty ? [""] : lines
    }

    /// Character-by-character wrap for languages without spaces (Japanese).
    private static func _wrapByChars(_ text: String, usableWidth: CGFloat, maxLines: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        var currentWidth: CGFloat = 0
        for ch in text {
            let w = _charPxWidth(ch)
            if currentWidth + w > usableWidth, !current.isEmpty {
                lines.append(current)
                if lines.count >= maxLines {
                    // Truncate remainder with ellipsis on the LAST emitted line.
                    lines[lines.count - 1] = _ellipsizeToWidth(lines[lines.count - 1] + String(ch), usableWidth: usableWidth)
                    return lines
                }
                current = String(ch)
                currentWidth = w
            } else {
                current.append(ch)
                currentWidth += w
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.isEmpty ? [""] : lines
    }

    /// Drop characters from the end of `text` until it fits, then add "…".
    private static func _ellipsizeToWidth(_ text: String, usableWidth: CGFloat) -> String {
        let ellipsisW = _charPxWidth("…")
        var chars = Array(text)
        var width: CGFloat = 0
        for c in chars { width += _charPxWidth(c) }
        while width + ellipsisW > usableWidth, !chars.isEmpty {
            let removed = chars.removeLast()
            width -= _charPxWidth(removed)
        }
        return String(chars) + "…"
    }

    // MARK: - Per-domain cluster model

    /// Holds a single domain's cluster (header + top-level nodes).
    private struct _Cluster {
        let sourceFamily: String
        let displayTitle: String
        var nodes: [_NodeM]
        var isOverview: Bool = false
        var headerY: CGFloat = 0
        var headerX: CGFloat = 0
        var clusterTop: CGFloat = 0
        var clusterBottom: CGFloat = 0
    }

    /// Build a navigable set tree.
    /// - focusRawID == nil: O root and currently held domain subsets D_i.
    /// - focusRawID == "domain:<id>": selected D_i and its top concept nodes.
    /// - focusRawID == canonical_id: selected canonical concept and its children.
    private static func _buildClusterModel(universalSet: Inf6UniversalConceptSet, isJA: Bool, focusRawID: String?) -> [_Cluster] {
        var clusters: [_Cluster] = []
        var domainOverviewNodes: [_NodeM] = []

        let rootTitle = "AI"
        let rootMeasure = _measureHomeClusterLabel(rootTitle)
        let rootID = "home:ai"
        domainOverviewNodes.append(_NodeM(
            id: rootID,
            rawID: rootID,
            parentRawIDs: [],
            title: rootTitle,
            color: _scienceColorFor(classID: "ai-foundations", title: rootTitle),
            achievement: "not_started",
            classID: "ai-foundations",
            depth: 0,
            lines: rootMeasure.lines,
            x: 0, y: 0,
            rx: rootMeasure.rx, ry: rootMeasure.ry,
            strand: 0,
            sourceDomains: []
        ))

        if let focusRawID, !focusRawID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let focus = _focusedTreeNodes(universalSet: universalSet, isJA: isJA, focusRawID: focusRawID, rootID: rootID)
            if !focus.isEmpty {
                domainOverviewNodes.append(contentsOf: focus)
                clusters.append(_Cluster(
                    sourceFamily: "home",
                    displayTitle: "",
                    nodes: domainOverviewNodes,
                    isOverview: true
                ))
                return _layoutClusters(clusters)
            }
        }

        for subset in universalSet.domainSubsets {
            let sourceFamily = subset.sourceFamily
            let displayTitle = _domainDisplayTitle(sourceFamily: sourceFamily, title: subset.displayTitle(isJapanese: isJA), isJapanese: isJA)
            let domainRawID = "domain:\(subset.domainID)"
            let domainMeasure = _measureHomeClusterLabel(displayTitle)
            domainOverviewNodes.append(_NodeM(
                id: "\(sourceFamily)|\(domainRawID)",
                rawID: domainRawID,
                parentRawIDs: [rootID],
                title: displayTitle,
                color: _scienceColorFor(classID: "ai-foundations", title: displayTitle),
                achievement: "not_started",
                classID: "ai-foundations",
                depth: 1,
                lines: domainMeasure.lines,
                x: 0, y: 0,
                rx: domainMeasure.rx, ry: domainMeasure.ry,
                strand: 0,
                sourceDomains: [subset.domainID]
            ))
        }

        if !domainOverviewNodes.isEmpty {
            clusters.append(_Cluster(
                sourceFamily: "home",
                displayTitle: "",
                nodes: domainOverviewNodes,
                isOverview: true
            ))
        }

        return _layoutClusters(clusters)
    }

    private static func _focusedTreeNodes(
        universalSet: Inf6UniversalConceptSet,
        isJA: Bool,
        focusRawID: String,
        rootID: String
    ) -> [_NodeM] {
        let normalized = focusRawID.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("domain:") {
            let domainID = String(normalized.dropFirst("domain:".count))
            guard let subset = universalSet.domainSubsets.first(where: { $0.domainID == domainID }) else { return [] }
            let displayTitle = _domainDisplayTitle(
                sourceFamily: subset.sourceFamily,
                title: subset.displayTitle(isJapanese: isJA),
                isJapanese: isJA
            )
            let domainRawID = "domain:\(subset.domainID)"
            var out: [_NodeM] = []
            let domainMeasure = _measureHomeClusterLabel(displayTitle)
            out.append(_NodeM(
                id: "\(subset.sourceFamily)|\(domainRawID)",
                rawID: domainRawID,
                parentRawIDs: [rootID],
                title: displayTitle,
                color: _domainColor(subset.sourceFamily),
                achievement: "not_started",
                classID: "ai-foundations",
                depth: 1,
                lines: domainMeasure.lines,
                x: 0, y: 0,
                rx: domainMeasure.rx, ry: domainMeasure.ry,
                strand: 0,
                sourceDomains: [subset.domainID]
            ))
            for canonicalID in _domainRootConceptIDs(subset: subset, universalSet: universalSet, isJA: isJA) {
                guard let concept = universalSet.conceptsByID[canonicalID] else { continue }
                out.append(_homeConceptNode(
                    concept: concept,
                    parentRawID: domainRawID,
                    edgeKind: "membership",
                    isJA: isJA
                ))
            }
            return out
        }

        guard let concept = universalSet.conceptsByID[normalized] else { return [] }
        let incoming = universalSet.relations
            .filter { $0.toConceptID == normalized }
            .sorted {
                let la = universalSet.conceptsByID[$0.fromConceptID]?.displayTitle(isJapanese: isJA) ?? $0.fromConceptID
                let lb = universalSet.conceptsByID[$1.fromConceptID]?.displayTitle(isJapanese: isJA) ?? $1.fromConceptID
                return la.localizedStandardCompare(lb) == .orderedAscending
            }
        let outgoing = universalSet.relations
            .filter { $0.fromConceptID == normalized }
            .sorted {
                let la = universalSet.conceptsByID[$0.toConceptID]?.displayTitle(isJapanese: isJA) ?? $0.toConceptID
                let lb = universalSet.conceptsByID[$1.toConceptID]?.displayTitle(isJapanese: isJA) ?? $1.toConceptID
                return la.localizedStandardCompare(lb) == .orderedAscending
            }
        guard !incoming.isEmpty || !outgoing.isEmpty else { return [] }

        var out: [_NodeM] = []
        var focusParentIDs = Set<String>()
        var focusEdgeKinds: [String: String] = [:]
        var seenParents = Set<String>()
        for relation in incoming where !seenParents.contains(relation.fromConceptID) {
            seenParents.insert(relation.fromConceptID)
            guard let parent = universalSet.conceptsByID[relation.fromConceptID] else { continue }
            out.append(_homeConceptNode(
                concept: parent,
                parentRawID: rootID,
                edgeKind: "focus",
                isJA: isJA
            ))
            focusParentIDs.insert(parent.canonicalID)
            focusEdgeKinds[parent.canonicalID] = relation.kind.rawValue
        }
        if focusParentIDs.isEmpty {
            focusParentIDs.insert(rootID)
            focusEdgeKinds[rootID] = "focus"
        }

        let title = concept.displayTitle(isJapanese: isJA)
        let measure = _measureLabel(title)
        let color = _scienceColorFor(classID: concept.classificationID ?? "", title: title)
        let score = concept.score(domainID: nil)
        let achievement = concept.achievementsByDomain.values.reduce(into: "not_started") { acc, v in
            acc = _joinAchievement(acc, v)
        }
        var focusNode = _NodeM(
            id: concept.canonicalID,
            rawID: concept.canonicalID,
            parentRawIDs: focusParentIDs,
            title: title,
            color: color,
            achievement: achievement,
            classID: concept.classificationID ?? "",
            depth: 2,
            lines: measure.lines,
            x: 0, y: 0,
            rx: measure.rx, ry: measure.ry,
            strand: 0,
            sourceDomains: concept.sourceDomains
        )
        focusNode.edgeKindByParentRawID = focusEdgeKinds
        focusNode.hotScore = score.hotScore
        focusNode.basicScore = score.basicScore
        out.append(focusNode)

        var seenChildren = Set<String>()
        for relation in outgoing where !seenChildren.contains(relation.toConceptID) {
            seenChildren.insert(relation.toConceptID)
            guard let child = universalSet.conceptsByID[relation.toConceptID] else { continue }
            out.append(_homeConceptNode(
                concept: child,
                parentRawID: normalized,
                edgeKind: relation.kind.rawValue,
                isJA: isJA
            ))
        }
        return out
    }

    private static func _domainRootConceptIDs(
        subset: Inf6UniversalConceptSet.DomainSubset,
        universalSet: Inf6UniversalConceptSet,
        isJA: Bool
    ) -> [String] {
        let explicit = subset.topCanonicalIDs.filter { universalSet.conceptsByID[$0] != nil }
        if !explicit.isEmpty {
            return _sortConceptIDs(explicit, universalSet: universalSet, isJA: isJA)
        }
        let childIDs = Set(_relationChildrenByParent(universalSet: universalSet, domainID: subset.domainID).values.flatMap { $0.map(\.toConceptID) })
        let roots = subset.canonicalIDs.filter { !childIDs.contains($0) && universalSet.conceptsByID[$0] != nil }
        return _sortConceptIDs(Array(roots), universalSet: universalSet, isJA: isJA)
    }

    private static func _relationChildrenByParent(
        universalSet: Inf6UniversalConceptSet,
        domainID: String
    ) -> [String: [Inf6KnowledgeRelation]] {
        let domainRelations = universalSet.relations.filter { relation in
            relation.kind == .sourceOutlineContains
            && relation.evidenceIDs.contains { evidenceID in
                universalSet.evidenceByID[evidenceID]?.sourceID == domainID
            }
        }
        var out: [String: [Inf6KnowledgeRelation]] = [:]
        for relation in domainRelations {
            var children = out[relation.fromConceptID] ?? []
            if !children.contains(relation) {
                children.append(relation)
                out[relation.fromConceptID] = children
            }
        }
        return out
    }

    private static func _sortConceptIDs(
        _ ids: [String],
        universalSet: Inf6UniversalConceptSet,
        isJA: Bool
    ) -> [String] {
        ids.sorted { a, b in
            let ca = universalSet.conceptsByID[a]
            let cb = universalSet.conceptsByID[b]
            let ra = _classOrderRank(ca?.classificationID ?? "")
            let rb = _classOrderRank(cb?.classificationID ?? "")
            if ra != rb { return ra < rb }
            let ta = ca?.displayTitle(isJapanese: isJA) ?? a
            let tb = cb?.displayTitle(isJapanese: isJA) ?? b
            return ta.localizedStandardCompare(tb) == .orderedAscending
        }
    }

    private static func _homeConceptNode(
        concept: Inf6UniversalConceptSet.Concept,
        parentRawID: String,
        edgeKind: String,
        isJA: Bool
    ) -> _NodeM {
        let title = concept.displayTitle(isJapanese: isJA)
        let measure = _measureLabel(title)
        let color = _scienceColorFor(classID: concept.classificationID ?? "", title: title)
        let score = concept.score(domainID: _domainIDFromParentRawID(parentRawID))
        let achievement = concept.achievementsByDomain.values.reduce(into: "not_started") { acc, v in
            acc = _joinAchievement(acc, v)
        }
        var node = _NodeM(
            id: concept.canonicalID,
            rawID: concept.canonicalID,
            parentRawIDs: [parentRawID],
            title: title,
            color: color,
            achievement: achievement,
            classID: concept.classificationID ?? "",
            depth: 2,
            lines: measure.lines,
            x: 0, y: 0,
            rx: measure.rx, ry: measure.ry,
            strand: 0,
            sourceDomains: concept.sourceDomains
        )
        node.edgeKindByParentRawID[parentRawID] = edgeKind
        node.hotScore = score.hotScore
        node.basicScore = score.basicScore
        return node
    }

    private static func _domainIDFromParentRawID(_ rawID: String) -> String? {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("domain:") else { return nil }
        let id = String(trimmed.dropFirst("domain:".count))
        return id.isEmpty ? nil : id
    }

    private static func _layoutClusters(_ clusters: [_Cluster]) -> [_Cluster] {
        // Each cluster occupies a horizontal band with a header strip on top
        // and a grid of node ellipses below. Clusters are stacked top→bottom.
        let canvasMidX = canvasWidth / 2
        let headerHeight: CGFloat = 50
        let clusterPaddingTop: CGFloat = 18
        let clusterPaddingBottom: CGFloat = 38
        let nodeColGap: CGFloat = 32
        let nodeRowGap: CGFloat = 30
        let usableWidth = canvasWidth - 40
        let maxColumns = max(1, Int(floor((usableWidth + nodeColGap) / (homeNodeRx * 2 + nodeColGap))))

        var cursorY: CGFloat = topMargin
        var positionedClusters: [_Cluster] = []

        for var cluster in clusters {
            cluster.clusterTop = cursorY
            cluster.headerX = canvasMidX
            cluster.headerY = cluster.isOverview ? cursorY : cursorY + headerHeight / 2

            if !cluster.isOverview {
                cursorY += headerHeight + clusterPaddingTop
            }

            var positioned: [_NodeM] = []
            positioned.reserveCapacity(cluster.nodes.count)
            if cluster.isOverview {
                let roots = cluster.nodes.filter { $0.parentRawIDs.isEmpty }
                let directDomains = cluster.nodes
                    .filter { $0.rawID.hasPrefix("domain:") }
                    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                let conceptNodes = cluster.nodes
                    .filter { !$0.parentRawIDs.isEmpty && !$0.rawID.hasPrefix("domain:") }
                    .sorted {
                        _compareKnowledgeVertical($0, $1)
                    }

                var layers: [[_NodeM]] = []
                if !roots.isEmpty { layers.append(roots) }
                if !directDomains.isEmpty { layers.append(directDomains) }
                var cursor = 0
                while cursor < conceptNodes.count {
                    let end = min(cursor + maxColumns, conceptNodes.count)
                    layers.append(Array(conceptNodes[cursor..<end]))
                    cursor = end
                }

                var rowY = cursorY + 72
                for (layerIndex, layer) in layers.enumerated() {
                    var indexInLayer = 0
                    while indexInLayer < layer.count {
                        let remainingInLayer = layer.count - indexInLayer
                        let columns = min(maxColumns, remainingInLayer)
                        let rowNodes = Array(layer[indexInLayer..<(indexInLayer + columns)])
                        let rowWidth = _rowWidth(nodes: rowNodes, gap: nodeColGap)
                        var xCursor = canvasMidX - rowWidth / 2
                        var maxRy: CGFloat = 0
                        for nn0 in rowNodes {
                            var nn = nn0
                            let isRoot = layerIndex == 0
                            if isRoot {
                                nn.rx = max(nn.rx, 170)
                                nn.ry = max(nn.ry, 64)
                            }
                            nn.x = xCursor + nn.rx
                            nn.y = rowY
                            positioned.append(nn)
                            xCursor += nn.rx * 2 + nodeColGap
                            maxRy = max(maxRy, nn.ry)
                        }
                        indexInLayer += columns
                        if indexInLayer < layer.count {
                            rowY += maxRy * 2 + nodeRowGap
                        }
                    }
                    if layerIndex < layers.count - 1 {
                        rowY += homeNodeRy * 2 + 50
                    }
                }
                cursorY = rowY + homeNodeRy
            } else {
                var rowIndex = 0
                var indexInRow = 0
                while indexInRow < cluster.nodes.count {
                    let remaining = cluster.nodes.count - indexInRow
                    let columns = min(maxColumns, remaining)
                    let rowWidth = CGFloat(columns) * homeNodeRx * 2 + CGFloat(max(0, columns - 1)) * nodeColGap
                    let rowY = cursorY + homeNodeRy
                    var xCursor = canvasMidX - rowWidth / 2
                    for col in 0..<columns {
                        var nn = cluster.nodes[indexInRow + col]
                        nn.x = xCursor + homeNodeRx
                        nn.y = rowY
                        nn.rx = homeNodeRx
                        nn.ry = homeNodeRy
                        positioned.append(nn)
                        xCursor += homeNodeRx * 2 + nodeColGap
                    }
                    indexInRow += columns
                    rowIndex += 1
                    if indexInRow < cluster.nodes.count {
                        cursorY += homeNodeRy * 2 + nodeRowGap
                    }
                }
                if rowIndex > 0 { cursorY += homeNodeRy * 2 }
            }
            cluster.nodes = positioned
            cursorY += clusterPaddingBottom
            cluster.clusterBottom = cursorY
            positionedClusters.append(cluster)
        }

        return positionedClusters
    }

    private static func _verticalKnowledgeRank(_ node: _NodeM) -> Int {
        if node.rawID == "home:ai" { return -200 }
        if node.rawID.hasPrefix("domain:") { return -100 }
        let classRank = _classOrderRank(node.classID)
        if classRank != 99 {
            return 100 - classRank
        }
        return 50
    }

    private static func _compareKnowledgeVertical(_ a: _NodeM, _ b: _NodeM) -> Bool {
        if a.hotScore != b.hotScore {
            return a.hotScore > b.hotScore
        }
        if a.basicScore != b.basicScore {
            return a.basicScore < b.basicScore
        }
        let ra = _verticalKnowledgeRank(a)
        let rb = _verticalKnowledgeRank(b)
        if ra != rb { return ra < rb }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }

    private static func _rowWidth(nodes: [_NodeM], gap: CGFloat) -> CGFloat {
        guard !nodes.isEmpty else { return 0 }
        let nodeWidth = nodes.reduce(CGFloat(0)) { partial, node in
            partial + max(node.rx, 1) * 2
        }
        return nodeWidth + CGFloat(nodes.count - 1) * gap
    }

    private static func _domainDisplayTitle(sourceFamily: String, title: String, isJapanese: Bool) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch sourceFamily {
        case "jdla_eshikaku":
            return isJapanese ? "JDLA E資格" : "JDLA E Qualification"
        case "jdla_gkentei":
            return isJapanese ? "JDLA G検定" : "JDLA G Test"
        case "microsoft_ai_102":
            return "Microsoft Learn AI-102"
        case "microsoft_ai_103":
            return "Microsoft Learn AI-103"
        default:
            return trimmed
        }
    }

    private static func _rowTotalWidth(rowItems: [Int], nodes: [_NodeM], colGap: CGFloat) -> CGFloat {
        if rowItems.isEmpty { return 0 }
        var sum: CGFloat = 0
        for (i, idx) in rowItems.enumerated() {
            if i > 0 { sum += colGap }
            sum += nodes[idx].rx * 2
        }
        return sum
    }

    // MARK: - (Legacy) helix model — retained but no longer the home layout

    private static func _buildModel(domains: [[String: Any]], isJA: Bool) -> _Model {
        // ---- Step 1: collect & measure raw nodes ----
        var rawNodes: [_NodeM] = []
        for domain in domains {
            if let nodes = domain["nodes"] as? [[String: Any]] {
                for n in nodes {
                    let kind = (n["kind"] as? String) ?? "node"
                    if kind == "paper" || kind == "domain" || kind == "syllabus_version" { continue }
                    let titleJA = (n["title_ja"] as? String) ?? ""
                    let titleEN = (n["title_en"] as? String) ?? ""
                    let title = isJA ? (titleJA.isEmpty ? titleEN : titleJA)
                                     : (titleEN.isEmpty ? titleJA : titleEN)
                    if _isSyllabusMaintenanceNode(title: title, id: (n["node_id"] as? String) ?? "") { continue }
                    if title.isEmpty { continue }

                    let rawID = (n["node_id"] as? String) ?? UUID().uuidString
                    let achievement = (n["achievement"] as? String) ?? "not_started"
                    let classificationID = (n["classification_id"] as? String) ?? ""
                    let color = _scienceColorFor(classID: classificationID, title: title)
                    let depth = (n["depth"] as? Int) ?? ((n["depth"] as? Double).map { Int($0) } ?? 0)
                    var parentRawIDs = Set<String>()
                    if let v = n["parent_node_id"] as? String, !v.isEmpty {
                        parentRawIDs.insert(v)
                    }
                    let domainID = (domain["source_family"] as? String) ?? ""

                    // Atomize the title (split combined concepts like "正規化・正則化"
                    // into individual atomic concepts). One outline row may produce
                    // 1+ rawNodes. Each atom inherits parent/achievement/etc. from
                    // the original row; their canonical merge happens later.
                    let atoms = Inf6AtomicConceptExtractor.extract(from: title)
                    for (atomIndex, atomTitle) in atoms.enumerated() {
                        // Re-derive color from the atom title so classification ranks
                        // by the atom's own keywords (more accurate than the composite).
                        let atomColor = _scienceColorFor(classID: classificationID, title: atomTitle)
                        // rawID: keep the original for the first atom (for parent
                        // linkage stability) and synthesize per-atom IDs for the rest.
                        let atomRawID = atomIndex == 0 ? rawID : "\(rawID)::atom\(atomIndex)"
                        let atomID = "\((domain["source_family"] as? String) ?? "x")|\(atomRawID)"
                        let m = _measureLabel(atomTitle)
                        rawNodes.append(_NodeM(
                            id: atomID,
                            rawID: atomRawID,
                            parentRawIDs: parentRawIDs,
                            title: atomTitle,
                            color: atomColor,
                            achievement: achievement,
                            classID: classificationID,
                            depth: depth,
                            lines: m.lines,
                            x: 0, y: 0,
                            rx: m.rx, ry: m.ry,
                            strand: 0,
                            sourceDomains: domainID.isEmpty ? [] : [domainID]
                        ))
                    }
                    _ = color  // (legacy: composite color no longer used; per-atom color above)
                }
            }
        }

        // ---- Step 1.4: filter out qualification meta-nodes ----
        // AGENTS.md 契約: 「シラバスは『資格』そのものではなく、概念集合の定義」.
        // Nodes whose title matches a manifest display name (e.g. "AI-102 認定試験",
        // "G検定", "E資格") are qualification labels, NOT concept nodes.
        let qualificationTitles: Set<String> = Set(domains.flatMap { d -> [String] in
            var names: [String] = []
            if let s = d["display_name_ja"] as? String { names.append(s) }
            if let s = d["display_name_en"] as? String { names.append(s) }
            if let s = d["provider_display_name_ja"] as? String { names.append(s) }
            if let s = d["provider_display_name_en"] as? String { names.append(s) }
            // Also infer from the domain title for the root concept (which is
            // emitted at depth 0 with the same display string).
            if let s = d["domain_title_ja"] as? String { names.append(s) }
            if let s = d["domain_title_en"] as? String { names.append(s) }
            return names
        }.compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
          .map { $0.lowercased() })
        rawNodes = rawNodes.filter { n in
            let key = n.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !qualificationTitles.contains(key)
        }

        // ---- Step 1.45: register each atomic concept into the Canonical Registry ----
        // AGENTS.md 知識空間契約: 「概念ノードは O の要素として canonical ID を持つ」.
        // The registry is populated lazily — only during SSR generation (cache miss),
        // never during startup display path.
        // Each node's rawID is replaced by its canonical_id so the subsequent merge
        // step uses canonical identity instead of original rawID per-syllabus.
        rawNodes = rawNodes.map { n -> _NodeM in
            // determine domain (use first source domain if multiple — typically only 1 at this step)
            let dom = n.sourceDomains.first ?? ""
            let canonicalID = Inf6CanonicalConceptRegistry.register(
                title: n.title,
                titleEN: nil,
                classificationID: n.classID.isEmpty ? nil : n.classID,
                domain: dom
            )
            // Replace rawID with canonical_id so identical concepts across syllabi
            // collapse to the same key during _mergeSameConceptNodes.
            // The rawID is `let`; rebuild via struct copy
            return _NodeM(
                id: n.id,
                rawID: canonicalID,
                parentRawIDs: n.parentRawIDs,
                title: n.title,
                color: n.color,
                achievement: n.achievement,
                classID: n.classID,
                depth: n.depth,
                lines: n.lines,
                x: n.x, y: n.y,
                rx: n.rx, ry: n.ry,
                strand: n.strand,
                sourceDomains: n.sourceDomains
            )
        }

        // ---- Step 1.5: SET-THEORETIC MERGE of same-concept nodes ----
        // AGENTS.md 契約: 「一つの概念ノードは一つだけ定義する」.
        // When the same concept title appears across multiple syllabi, merge
        // them into ONE node whose parentRawIDs is the UNION of all syllabi's
        // parents for that concept, and whose achievement is the MAX across
        // syllabi (treated as a join in the achievement lattice).
        rawNodes = _mergeSameConceptNodes(rawNodes)

        // ---- Step 1.6: the ORDER IS the structure ----
        // DFS traversal of the merged knowledge DAG. Visited-set prevents
        // revisiting a concept reachable from multiple parents.
        rawNodes = _knowledgeTreeOrder(rawNodes)

        // ---- Step 2: DOUBLE HELIX (DNA) layout ----
        // One node per Y row, alternating strands. The two strands wind around
        // a vertical axis; viewed from the side they trace two antiphase sine
        // curves that interleave.
        //
        // At the START (idx 0 and idx 1):
        //   - Both at x ≈ centerX (axis crossing)
        //   - Strand A on top (idx 0), Strand B directly below (idx 1)
        //   → vertical separation, not horizontal.
        //
        // Strand assignment by index parity:
        //   strand = idx % 2     (0 = A, 1 = B)
        // Phase progresses every TWO indices (one full step per A+B pair):
        //   step  = idx / 2
        //   phase = step * angleStep + (strand == 1 ? π : 0)
        //   x     = centerX + amp * sin(phase)
        // At step=0, sin(0)=0 (A) and sin(π)=0 (B) → both at center axis. ✓
        //
        // Y advances per node (each gets its own row) using ellipse-overlap math.
        let centerX = canvasWidth / 2
        let amplitude = nodeFieldHalfWidth * 0.55
        let stepsPerTurn = 5.0                       // 5 helix steps per full turn
        let angleStep = 2 * Double.pi / stepsPerTurn
        let startY = topMargin
        var nodesOut: [_NodeM] = []
        var papersOut: [_PaperM] = []
        nodesOut.reserveCapacity(rawNodes.count)

        func helixX(idx: Int) -> CGFloat {
            let strand = idx % 2
            let step = Double(idx / 2)
            let phase = step * angleStep + (strand == 1 ? Double.pi : 0)
            return centerX + amplitude * CGFloat(sin(phase))
        }

        // Track the last few placed nodes so we can ensure the new node doesn't
        // overlap ANY of them (not just the immediately preceding one).
        // Look-back window must cover one full helix turn (so the same-strand
        // node two steps prior is included).
        let lookBack = Int(stepsPerTurn * 2) + 4   // generous safety margin
        var y: CGFloat = startY
        for (idx, raw) in rawNodes.enumerated() {
            var node = raw
            node.strand = idx % 2
            node.x = helixX(idx: idx)

            // Compute the minimum Y such that this node doesn't overlap any of
            // the recent nodes already placed.
            var minY: CGFloat = (idx == 0) ? startY : (nodesOut.last!.y + 1)
            let windowStart = max(0, nodesOut.count - lookBack)
            for prev in nodesOut[windowStart..<nodesOut.count] {
                let dx = abs(node.x - prev.x)
                let cRx = node.rx + prev.rx
                let cRy = node.ry + prev.ry
                let dxFrac = min(dx / cRx, 0.999)
                let dyMin = cRy * CGFloat(sqrt(1.0 - Double(dxFrac * dxFrac)))
                let requiredY = prev.y + dyMin + 6
                if requiredY > minY { minY = requiredY }
            }

            node.y = max(y, minY)
            y = node.y
            nodesOut.append(node)
        }

        // ---- Collect papers ----
        struct _RawPaper {
            let id: String
            let title: String
            let year: Int
            let color: String
        }
        var raws: [_RawPaper] = []
        for domain in domains {
            if let papers = domain["papers"] as? [[String: Any]] {
                for p in papers {
                    let titleJA = (p["paper_title_ja"] as? String) ?? ""
                    let titleEN = (p["paper_title_en"] as? String) ?? (p["paper_title"] as? String) ?? ""
                    let title = isJA ? (titleJA.isEmpty ? titleEN : titleJA)
                                     : (titleEN.isEmpty ? titleJA : titleEN)
                    if title.isEmpty { continue }
                    let year = (p["source_year"] as? Int) ?? ((p["source_year"] as? Double).map { Int($0) } ?? 0)
                    let pid = (p["paper_id"] as? String) ?? UUID().uuidString
                    // pick color: use first syllabus node id if available, otherwise default
                    let firstNodeID = ((p["syllabus_node_ids"] as? [String])?.first) ?? ""
                    let color = _scienceColorFor(classID: firstNodeID, title: title)
                    raws.append(_RawPaper(id: pid, title: title, year: year, color: color))
                }
            }
        }
        raws.sort { $0.year > $1.year }

        // Two columns alternating
        let leftStartX: CGFloat = 20
        let rightStartX: CGFloat = canvasWidth - 380
        var leftY: CGFloat = topMargin
        var rightY: CGFloat = topMargin
        for (i, r) in raws.enumerated() {
            let side = (i % 2 == 0) ? -1 : 1
            let x: CGFloat = side < 0 ? leftStartX : rightStartX
            let y: CGFloat
            if side < 0 {
                y = leftY
                leftY += paperRowHeight
            } else {
                y = rightY
                rightY += paperRowHeight
            }
            papersOut.append(_PaperM(
                id: r.id,
                title: r.title,
                year: r.year > 0 ? r.year : nil,
                color: r.color,
                side: side,
                x: x,
                y: y
            ))
        }

        return _Model(nodes: nodesOut, papers: papersOut)
    }

    // ---- Color & filter helpers (ports of circuit_board.html JS) ----

    private struct _ClsRule {
        let color: String
        let terms: [String]
    }
    private static let _classificationRules: [_ClsRule] = [
        _ClsRule(color: "#1d4ed8", terms: ["mathematics-statistics", "数学", "統計", "確率", "線形代数", "linear-algebra", "probability", "statistics", "matrix"]),
        _ClsRule(color: "#0f766e", terms: ["machine-learning", "機械学習", "教師あり", "教師なし", "最適化", "正則化", "正規化", "活性化", "損失", "誤差", "モデルの解釈性", "モデルの軽量化", "メタ学習", "optimization", "normalization", "regularization"]),
        _ClsRule(color: "#6d28d9", terms: ["deep-learning", "深層学習", "ディープラーニング", "ニューラル", "cnn", "rnn", "transformer", "attention", "画像認識", "物体検出", "セグメンテーション", "自然言語", "生成モデル", "gan", "vae", "拡散", "音声処理", "マルチモーダル", "全結合", "畳み込み", "正規化層", "プーリング", "スキップ結合", "回帰結合", "オートエンコーダ", "データ生成", "転移学習", "ファインチューニング"]),
        _ClsRule(color: "#b45309", terms: ["reinforcement-learning", "強化学習", "reinforcement", "dqn", "ppo", "a3c", "sac", "td3"]),
        _ClsRule(color: "#0369a1", terms: ["graph-learning", "グラフ", "graph", "gnn", "gcn", "gat"]),
        _ClsRule(color: "#9f1239", terms: ["responsible-ai-governance", "説明可能", "xai", "ガバナンス", "倫理", "著作権", "個人情報", "公平性", "透明性", "安全", "セキュリティ", "悪用", "民主主義", "環境保護", "労働", "プライバシー", "特許", "契約", "ガイドライン", "重要な価値"]),
        _ClsRule(color: "#374151", terms: ["systems-implementation", "実装", "pytorch", "圧縮", "分散", "エッジ", "モデルの選択", "評価", "データ", "プロジェクト", "収集", "加工", "分析"]),
        _ClsRule(color: "#0284c7", terms: ["azure-ai-services", "ai-102", "azure", "microsoft-learn", "speech", "vision", "language", "search", "document"]),
        _ClsRule(color: "#92400e", terms: ["ai-foundations", "人工知能", "探索", "推論", "知識表現", "エキスパートシステム"])
    ]

    private static func _scienceColorFor(classID: String, title: String) -> String {
        let haystack = (classID + " " + title).lowercased()
        for rule in _classificationRules {
            for term in rule.terms {
                if haystack.contains(term.lowercased()) { return rule.color }
            }
        }
        return defaultNodeColor
    }

    private static func _isSyllabusMaintenanceNode(title: String, id: String) -> Bool {
        let text = (title + " " + id).lowercased()
        let patterns = ["シラバス", "キーワード内容を見直し", "キーワードの一部見直し", "新規作成", "syllabus 2024", "review the following", "review some of the following", "newly created"]
        for p in patterns {
            if text.contains(p.lowercased()) { return true }
        }
        return false
    }

    // MARK: - SVG

    private static func _renderSVG(model: _Model, width: CGFloat, height: CGFloat) -> String {
        var out = ""
        out.reserveCapacity(64 * 1024)

        // width="100%" + viewBox + preserveAspectRatio → SVG scales horizontally to
        // fit the viewport. Wider screens enlarge the whole board (and thus the text)
        // up to the natural canvas size; narrower screens shrink it.
        out.append("<svg xmlns=\"http://www.w3.org/2000/svg\" id=\"board\" width=\"100%\" viewBox=\"0 0 \(_n(width)) \(_n(height))\" preserveAspectRatio=\"xMidYMin meet\">")
        // background
        out.append("<rect width=\"\(_n(width))\" height=\"\(_n(height))\" fill=\"\(bgColor)\"/>")
        // Double-helix backbone. Strand membership is layout geometry only;
        // scientific meaning is carried by each node's classification color.
        let strandA = model.nodes.enumerated().filter { $0.offset % 2 == 0 }.map { $0.element }
        let strandB = model.nodes.enumerated().filter { $0.offset % 2 == 1 }.map { $0.element }

        // Base-pair connectors.
        let pairCount = min(strandA.count, strandB.count)
        for k in 0..<pairCount {
            let a = strandA[k]
            let b = strandB[k]
            out.append("<line x1=\"\(_n(a.x))\" y1=\"\(_n(a.y))\" x2=\"\(_n(b.x))\" y2=\"\(_n(b.y))\" stroke=\"#cbd5e1\" stroke-width=\"1.2\" stroke-opacity=\"0.45\"/>")
        }

        // Curve helper.
        func smoothPath(_ pts: [(CGFloat, CGFloat)]) -> String {
            if pts.isEmpty { return "" }
            var d = "M\(_n(pts[0].0)),\(_n(pts[0].1))"
            for i in 0..<pts.count - 1 {
                let p0 = i > 0 ? pts[i - 1] : pts[i]
                let p1 = pts[i]
                let p2 = pts[i + 1]
                let p3 = i + 2 < pts.count ? pts[i + 2] : pts[i + 1]
                let t: CGFloat = 0.20
                let c1x = p1.0 + (p2.0 - p0.0) * t
                let c1y = p1.1 + (p2.1 - p0.1) * t
                let c2x = p2.0 - (p3.0 - p1.0) * t
                let c2y = p2.1 - (p3.1 - p1.1) * t
                d += " C\(_n(c1x)),\(_n(c1y)) \(_n(c2x)),\(_n(c2y)) \(_n(p2.0)),\(_n(p2.1))"
            }
            return d
        }

        if strandA.count >= 2 {
            let dA = smoothPath(strandA.map { ($0.x, $0.y) })
            out.append("<path d=\"\(dA)\" fill=\"none\" stroke=\"#94a3b8\" stroke-width=\"2.2\" stroke-opacity=\"0.42\"/>")
        }
        if strandB.count >= 2 {
            let dB = smoothPath(strandB.map { ($0.x, $0.y) })
            out.append("<path d=\"\(dB)\" fill=\"none\" stroke=\"#94a3b8\" stroke-width=\"2.2\" stroke-opacity=\"0.42\"/>")
        }
        // Nodes use science classification color. The helix strand position does
        // not encode a domain, class, or relation type.
        for n in model.nodes {
            let tap = _escape(n.rawID)
            let nodeStroke = n.color.isEmpty ? defaultNodeColor : n.color
            let nodeFill = _tint(nodeStroke, 0.88)
            out.append("<g class=\"concept-node\" data-id=\"\(_escape(n.id))\" data-raw=\"\(tap)\" style=\"cursor:pointer\">")
            // shadow
            out.append("<ellipse cx=\"\(_n(n.x + 1.4))\" cy=\"\(_n(n.y + 2.4))\" rx=\"\(_n(n.rx))\" ry=\"\(_n(n.ry))\" fill=\"#0f172a\" fill-opacity=\"0.10\"/>")
            // main: classification-tinted fill and stroke.
            out.append("<ellipse cx=\"\(_n(n.x))\" cy=\"\(_n(n.y))\" rx=\"\(_n(n.rx))\" ry=\"\(_n(n.ry))\" fill=\"\(nodeFill)\" stroke=\"\(nodeStroke)\" stroke-width=\"1.6\" stroke-opacity=\"0.78\"/>")
            // Multi-line label, vertically centered on the ellipse center (n.y).
            // We bypass dominant-baseline (inconsistent across SVG engines) and
            // compute the baseline of each line manually.
            //   Total text block height = lineCount * lineHeight
            //   Center the block on n.y, then each line's BASELINE sits at:
            //     y_line(i) = n.y - blockH/2 + lineHeight*(i+1) - descent
            //   where descent ≈ font-size * 0.25 (typical for sans-serif).
            let lines = n.lines
            let blockH = CGFloat(lines.count) * nodeLineHeight
            let descent = nodeFontSize * 0.25
            let topPad = n.y - blockH / 2.0
            out.append("<text text-anchor=\"middle\" fill=\"\(textColor)\" font-size=\"\(_n(nodeFontSize))\" font-weight=\"700\" pointer-events=\"none\">")
            for (i, line) in lines.enumerated() {
                let baselineY = topPad + nodeLineHeight * CGFloat(i + 1) - descent
                out.append("<tspan x=\"\(_n(n.x))\" y=\"\(_n(baselineY))\">\(_escape(line))</tspan>")
            }
            out.append("</text>")
            out.append("</g>")
        }
        // paper labels — p.title is already pre-truncated to lane width in
        // _collectPapers(), so DO NOT apply a second char-count truncation here.
        for p in model.papers {
            let tap = _escape(p.id)
            let yearStr = p.year.map { "\($0) " } ?? ""
            out.append("<g class=\"paper-label\" data-id=\"\(tap)\" style=\"cursor:pointer\">")
            out.append("<text x=\"\(_n(p.x))\" y=\"\(_n(p.y))\" text-anchor=\"start\" dominant-baseline=\"central\" fill=\"\(p.color)\" font-size=\"\(_n(paperFontSize))\" font-weight=\"500\">\(_escape(yearStr + p.title))</text>")
            out.append("</g>")
        }

        out.append("</svg>")
        return out
    }

    /// Render per-domain clusters. Each cluster has a header strip with the
    /// domain display name, then a grid of top-level concept ellipses below.
    private static func _renderClustersSVG(clusters: [_Cluster], width: CGFloat, height: CGFloat) -> String {
        var out = ""
        out.reserveCapacity(64 * 1024)
        out.append("<svg xmlns=\"http://www.w3.org/2000/svg\" id=\"board\" width=\"100%\" viewBox=\"0 0 \(_n(width)) \(_n(height))\" preserveAspectRatio=\"xMidYMin meet\">")
        out.append("<rect width=\"\(_n(width))\" height=\"\(_n(height))\" fill=\"\(bgColor)\"/>")

        let allNodes = clusters.flatMap { $0.nodes }
        var nodeByRawID: [String: _NodeM] = [:]
        for node in allNodes where nodeByRawID[node.rawID] == nil {
            nodeByRawID[node.rawID] = node
        }

        for (cIdx, cluster) in clusters.enumerated() {
            let stripeColor = _strandColor(cIdx % 2)
            let stripeFill = _tint(stripeColor, 0.93)

            // Cluster band background (subtle tint)
            let bandTop = cluster.clusterTop
            let bandBottom = cluster.clusterBottom
            let bandH = bandBottom - bandTop
            if !cluster.isOverview {
                out.append("<rect x=\"20\" y=\"\(_n(bandTop))\" width=\"\(_n(width - 40))\" height=\"\(_n(bandH))\" rx=\"18\" ry=\"18\" fill=\"\(stripeFill)\" fill-opacity=\"0.55\"/>")
            }

            // Cluster header text (domain display name)
            let headerFont: CGFloat = 22
            if !cluster.displayTitle.isEmpty {
                out.append("<text x=\"\(_n(cluster.headerX))\" y=\"\(_n(cluster.headerY + headerFont * 0.32))\" text-anchor=\"middle\" font-size=\"\(_n(headerFont))\" font-weight=\"700\" fill=\"\(textColor)\">\(_escape(cluster.displayTitle))</text>")
            }
        }

        for (cIdx, cluster) in clusters.enumerated() {
            let stripeColor = _strandColor(cIdx % 2)
            // Nodes
            for n in cluster.nodes {
                let tap = _escape(n.rawID)
                let strokeColor = cluster.isOverview ? _homeNodeColor(n) : stripeColor
                let fillColor = _tint(strokeColor, cluster.isOverview ? (n.rawID == "home:ai" ? 0.78 : 0.84) : 0.78)
                let strokeWidth: CGFloat = cluster.isOverview ? (n.rawID == "home:ai" ? 4.0 : 3.2) : 0
                if cluster.isOverview {
                    out.append("<g class=\"home-subset-node\" data-id=\"\(_escape(n.id))\" data-raw=\"\(tap)\">")
                } else {
                    out.append("<g class=\"concept-node\" data-id=\"\(_escape(n.id))\" data-raw=\"\(tap)\" style=\"cursor:pointer\">")
                }
                out.append("<ellipse cx=\"\(_n(n.x + 3))\" cy=\"\(_n(n.y + 5))\" rx=\"\(_n(n.rx))\" ry=\"\(_n(n.ry))\" fill=\"#0f172a\" fill-opacity=\"0.15\"/>")
                out.append("<ellipse cx=\"\(_n(n.x))\" cy=\"\(_n(n.y))\" rx=\"\(_n(n.rx))\" ry=\"\(_n(n.ry))\" fill=\"\(fillColor)\" stroke=\"\(strokeColor)\" stroke-width=\"\(_n(strokeWidth))\"/>")
                // Vertically-centered multi-line label
                let lines = n.lines
                let fontSize: CGFloat = cluster.isOverview ? (n.rawID == "home:ai" ? 36 : 27) : nodeFontSize
                let lineHeight: CGFloat = fontSize + 8
                let blockH = CGFloat(lines.count) * lineHeight
                let descent = fontSize * 0.25
                let topPad = n.y - blockH / 2.0
                out.append("<text text-anchor=\"middle\" fill=\"\(textColor)\" font-size=\"\(_n(fontSize))\" font-weight=\"800\" pointer-events=\"none\">")
                for (i, line) in lines.enumerated() {
                    let baselineY = topPad + lineHeight * CGFloat(i + 1) - descent
                    out.append("<tspan x=\"\(_n(n.x))\" y=\"\(_n(baselineY))\">\(_escape(line))</tspan>")
                }
                out.append("</text>")
                out.append("</g>")
            }
        }
        out.append("</svg>")
        return out
    }

    private static func _wrapHTML(svg: String, width: CGFloat, height: CGFloat) -> String {
        // Minimal HTML. No D3, no external scripts. Only a tiny click handler
        // that posts the tapped id back to Swift via webkit message handlers.
        // Body uses flex to horizontally center the SVG within the viewport.
        return """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <title>inf6 Knowledge Map</title>
        <style>
          html,body { margin:0; padding:0; background:\(bgColor); }
          body { display:flex; justify-content:center; align-items:flex-start; }
          /* Modern sans-serif stack: SF Pro on Apple, Hiragino Sans for Japanese,
             Inter/Helvetica Neue fallback. Avoids the default Mincho (serif). */
          svg, svg text, svg tspan {
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text",
                         "Hiragino Sans", "ヒラギノ角ゴシック", "Helvetica Neue",
                         "Arial", sans-serif;
            font-feature-settings: "palt" 1;
            -webkit-font-smoothing: antialiased;
          }
          svg { display:block; }
        </style>
        </head><body>
        \(svg)
        <script>
        (function(){
          document.addEventListener('click', function(ev){
            var node = ev.target.closest('.concept-node,.home-subset-node');
            if (node && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nodeTap) {
              window.webkit.messageHandlers.nodeTap.postMessage(node.getAttribute('data-raw'));
              return;
            }
            var paper = ev.target.closest('.paper-label');
            if (paper && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.paperTap) {
              window.webkit.messageHandlers.paperTap.postMessage(paper.getAttribute('data-id'));
            }
          }, false);
        })();
        </script>
        </body></html>
        """
    }

    // MARK: - Helpers

    private static func _n(_ v: CGFloat) -> String {
        // 1-decimal formatting; trim trailing ".0"
        let s = String(format: "%.1f", Double(v))
        if s.hasSuffix(".0") { return String(s.dropLast(2)) }
        return s
    }

    private static func _escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    private static func _fitLabel(_ s: String, maxChars: Int) -> String {
        if s.count <= maxChars { return s }
        let prefix = s.prefix(max(1, maxChars - 1))
        return String(prefix) + "…"
    }

    /// Wrap a label into multiple lines using a fixed character budget per line.
    /// If the text exceeds `maxLines * maxCharsPerLine`, the last line is suffixed with "…".
    /// Japanese text generally has no spaces, so we just chunk by character count.
    private static func _wrapLabel(_ s: String, maxLines: Int, maxCharsPerLine: Int) -> [String] {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [""] }
        let chars = Array(trimmed)
        var lines: [String] = []
        var i = 0
        while i < chars.count && lines.count < maxLines {
            let end = min(i + maxCharsPerLine, chars.count)
            lines.append(String(chars[i..<end]))
            i = end
        }
        // If we ran out of lines but still have characters, add ellipsis to the last line.
        if i < chars.count, var last = lines.last {
            // Replace last char with "…" to keep within width budget.
            if last.count >= maxCharsPerLine {
                last = String(last.dropLast()) + "…"
            } else {
                last += "…"
            }
            lines[lines.count - 1] = last
        }
        return lines.isEmpty ? [""] : lines
    }

    /// Alternating accent color for non-home cluster backgrounds.
    private static func _strandColor(_ strand: Int) -> String {
        return strand == 0 ? "#2563eb" : "#ec4899"
    }

    /// Distinct color per syllabus/qualification, used for the multi-syllabus dots
    /// under merged concept nodes.
    private static func _domainColor(_ sourceFamily: String) -> String {
        switch sourceFamily.lowercased() {
        case "jdla_eshikaku":  return "#7c3aed"  // violet
        case "jdla_gkentei":   return "#0d9488"  // teal
        case "microsoft_ai_102", "microsoft_ai_103": return "#0284c7" // sky blue
        default: return "#64748b"                 // slate
        }
    }

    private static func _homeNodeColor(_ node: _NodeM) -> String {
        if node.rawID == "home:ai" { return "#2563eb" }
        if node.rawID.hasPrefix("domain:") {
            return neutralNodeStroke
        }
        return neutralNodeStroke
    }

    private static func _achievementColor(_ state: String) -> String {
        switch state.lowercased() {
        case "verified", "completed", "passed":
            return "#16a34a"
        case "in_progress", "started":
            return "#eab308"
        case "wrong", "failed":
            return "#dc2626"
        default:
            return "#cbd5e1"
        }
    }

    /// Lightens a hex color toward white by `amount` (0..1). amount=0 → original,
    /// amount=1 → white. Defaults to passing the color through for invalid input.
    private static func _tint(_ hex: String, _ amount: Double) -> String {
        guard let rgb = _hexToRGB(hex) else { return hex }
        let a = max(0, min(1, amount))
        let r = Int(Double(rgb.r) + (255 - Double(rgb.r)) * a)
        let g = Int(Double(rgb.g) + (255 - Double(rgb.g)) * a)
        let b = Int(Double(rgb.b) + (255 - Double(rgb.b)) * a)
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    private static func _hexToRGB(_ hex: String) -> (r: Int, g: Int, b: Int)? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        return ((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff)
    }
}
