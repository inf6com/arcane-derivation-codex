//
//  Inf6EshikakuCorePaperView.swift
//  inf6
//
//  E資格 Core Paper — シラバス×論文ツリー（List Section として埋め込み）
//
//  設計方針:
//  • ボタン・別画面なし。E資格シラバス画面の List に Section として直接挿入される。
//  • 「知の蓄積度」= アプリ内の蓄積データ（図表カード生成済み・進捗状態）から算出。
//  • 優先度が高い項目で蓄積が不足している場合はアラームバッジを表示。
//  • シラバス大項目ツリー → 対応 Core Paper ツリーを一体表示。

import SwiftUI

// MARK: ── 公開 Section コンポーネント（_coreListBase から直接 Section として使用）──

// MARK: 1. アラームセクション

struct Inf6CorePaperAlertSection: View {

    let store: Inf6CorePaperStore
    @State private var isExpanded = true

    private var alarmNodes: [Inf6SyllabusCoverageNode] {
        Inf6SyllabusCoverageNode.buildAll(store: store)
            .filter { $0.isHighPriority && $0.accumulationLevel < 0.3 }
            .sorted { $0.coveringPapers.count > $1.coveringPapers.count }
    }

    var body: some View {
        if !alarmNodes.isEmpty {
            Section {
                if isExpanded {
                    ForEach(alarmNodes, id: \.sectionName) { node in
                        _AlarmRow(node: node, store: store)
                    }
                }
            } header: {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption.bold())
                        Text("優先度高・蓄積不足 (\(alarmNodes.count)件)")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: 2. シラバス×論文 ツリーセクション

struct Inf6CorePaperSyllabusTreeSection: View {

    let store: Inf6CorePaperStore
    @State private var expandedNodes: Set<String> = []
    @State private var selectedPaper: Inf6CorePaper? = nil
    @State private var showPaperDetail = false

    private var nodes: [Inf6SyllabusCoverageNode] {
        Inf6SyllabusCoverageNode.buildAll(store: store)
    }

    var body: some View {
        Section {
            // Overall accumulation bar
            _OverallAccumulationBar(store: store)
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                .listRowSeparator(.hidden)

            // Tree nodes
            ForEach(nodes, id: \.sectionName) { node in
                _SyllabusSectionRow(
                    node: node,
                    store: store,
                    isExpanded: expandedNodes.contains(node.sectionName),
                    onToggle: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if expandedNodes.contains(node.sectionName) {
                                expandedNodes.remove(node.sectionName)
                            } else {
                                expandedNodes.insert(node.sectionName)
                            }
                        }
                    },
                    onSelectPaper: { paper in
                        selectedPaper = paper
                        showPaperDetail = true
                    }
                )
            }
        } header: {
            Text("Core Paper × シラバス対応ツリー")
                .font(.caption.bold())
        }
        .sheet(isPresented: $showPaperDetail) {
            if let paper = selectedPaper {
                NavigationStack {
                    Inf6CorePaperDetailView(store: store, paper: paper)
                }
            }
        }
    }
}

// MARK: ── ツリーノードモデル ──

struct Inf6SyllabusCoverageNode {
    let sectionName: String
    let coveringPapers: [Inf6CorePaper]
    let isHighPriority: Bool   // E資格試験の出題比重が高いカテゴリ
    /// 知の蓄積度 0.0–1.0（完了済み論文の割合）
    let accumulationLevel: Double

    static func buildAll(store: Inf6CorePaperStore) -> [Inf6SyllabusCoverageNode] {
        do {
            return try Inf6SyllabusCoverageDefinition.loadDefinitions().map { def in
            let tagSet = Set(def.coveringTags.map { $0.lowercased() })
            let papers = store.papers.filter { paper in
                paper.tags.contains { tagSet.contains($0.lowercased()) }
            }
            let done = papers.filter { store.progress[$0.id]?.status == .done }.count
            let level = papers.isEmpty ? 0.0 : Double(done) / Double(papers.count)
            return Inf6SyllabusCoverageNode(
                sectionName: def.syllabusSection,
                coveringPapers: papers,
                isHighPriority: def.isHighPriority,
                accumulationLevel: level
            )
            }
        } catch {
            preconditionFailure(error.localizedDescription)
        }
    }
}

// MARK: ── Private Row Views ──

// Overall accumulation bar
private struct _OverallAccumulationBar: View {
    let store: Inf6CorePaperStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("全体蓄積度")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(store.doneCount) / \(store.totalCount) 論文")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("\(Int(store.overallProgress * 100))%")
                    .font(.caption.bold())
                    .foregroundStyle(_progressColor(store.overallProgress))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                        .frame(height: 8)
                    Capsule().fill(_progressColor(store.overallProgress))
                        .frame(width: geo.size.width * store.overallProgress, height: 8)
                        .animation(.easeInOut(duration: 0.4), value: store.overallProgress)
                }
            }
            .frame(height: 8)

            // Reading count
            if store.readingCount > 0 {
                Text("📖 学習中: \(store.readingCount)件")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func _progressColor(_ v: Double) -> Color {
        v >= 0.7 ? .green : v >= 0.35 ? .orange : .red
    }
}

// Alarm row
private struct _AlarmRow: View {
    let node: Inf6SyllabusCoverageNode
    let store: Inf6CorePaperStore

    private var notStartedCount: Int {
        node.coveringPapers.filter { (store.progress[$0.id]?.status ?? .notStarted) == .notStarted }.count
    }

    var body: some View {
        HStack(spacing: 10) {
            // Severity indicator
            Image(systemName: node.accumulationLevel == 0 ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(node.accumulationLevel == 0 ? .red : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.sectionName)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Text("未着手 \(notStartedCount) / \(node.coveringPapers.count) 論文")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Mini accumulation bar
            _MiniAccBar(level: node.accumulationLevel)
        }
        .padding(.vertical, 2)
    }
}

// Syllabus section row (tree node)
private struct _SyllabusSectionRow: View {
    let node: Inf6SyllabusCoverageNode
    let store: Inf6CorePaperStore
    let isExpanded: Bool
    let onToggle: () -> Void
    let onSelectPaper: (Inf6CorePaper) -> Void

    private var doneCount: Int {
        node.coveringPapers.filter { store.progress[$0.id]?.status == .done }.count
    }
    private var readingCount: Int {
        node.coveringPapers.filter { store.progress[$0.id]?.status == .reading }.count
    }
    private var hasAlarm: Bool {
        node.isHighPriority && node.accumulationLevel < 0.3
    }

    var body: some View {
        VStack(spacing: 0) {
            // Section header row (tree node)
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    // Expand/collapse chevron
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 14)

                    // Accumulation circle
                    _AccumulationCircle(level: node.accumulationLevel, diameter: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if hasAlarm {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            if node.isHighPriority {
                                Text("★")
                                    .font(.caption2)
                                    .foregroundStyle(.yellow)
                            }
                            Text(node.sectionName)
                                .font(.subheadline.weight(node.isHighPriority ? .semibold : .regular))
                                .foregroundStyle(.primary)
                        }

                        HStack(spacing: 8) {
                            if node.coveringPapers.isEmpty {
                                Text("論文なし")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("✅\(doneCount)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.green)
                                if readingCount > 0 {
                                    Text("📖\(readingCount)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.orange)
                                }
                                Text("計\(node.coveringPapers.count)件")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Spacer()

                    // Mini bar
                    if !node.coveringPapers.isEmpty {
                        _MiniAccBar(level: node.accumulationLevel)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)

            // Paper rows (when expanded)
            if isExpanded && !node.coveringPapers.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(node.coveringPapers.enumerated()), id: \.element.id) { idx, paper in
                        _PaperTreeRow(
                            paper: paper,
                            store: store,
                            isLast: idx == node.coveringPapers.count - 1,
                            onSelect: { onSelectPaper(paper) }
                        )
                    }
                }
                .padding(.leading, 24)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// Paper row inside tree
private struct _PaperTreeRow: View {
    let paper: Inf6CorePaper
    let store: Inf6CorePaperStore
    let isLast: Bool
    let onSelect: () -> Void

    private var prog: Inf6CorePaperProgress? { store.progress[paper.id] }
    private var status: Inf6CorePaperStatus { prog?.status ?? .notStarted }
    private var mastery: Int { prog?.masteryScore ?? 0 }
    private var accLevel: Double {
        // 知の蓄積度: status + mastery score を合成
        let statusScore: Double = {
            switch status {
            case .notStarted: return 0.0
            case .reading:    return 0.4
            case .done:       return 1.0
            }
        }()
        let masteryScore = mastery > 0 ? Double(mastery) / 5.0 * 0.4 : 0.0
        return min(1.0, statusScore + (status == .done ? 0 : masteryScore))
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                // Tree line
                VStack(spacing: 0) {
                    Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1)
                    if !isLast {
                        Color.clear
                    }
                }
                .frame(width: 1, height: isLast ? 20 : 36)

                // Connector tick
                HStack(spacing: 0) {
                    Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 10, height: 1)
                }

                // Status emoji
                Text(status.emoji)
                    .font(.body)

                // Title + knowledge bar
                VStack(alignment: .leading, spacing: 3) {
                    Text(paper.title)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    // Knowledge accumulation bar (細い)
                    HStack(spacing: 4) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.12))
                                Capsule().fill(_accColor(accLevel))
                                    .frame(width: max(0, geo.size.width * accLevel))
                                    .animation(.easeInOut(duration: 0.3), value: accLevel)
                            }
                        }
                        .frame(height: 4)

                        if mastery > 0 {
                            Text(String(repeating: "★", count: mastery))
                                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(8)))
                                .foregroundStyle(.yellow)
                        }
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.5))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func _accColor(_ v: Double) -> Color {
        v >= 0.8 ? .green : v >= 0.4 ? .orange : v > 0 ? .yellow : Color.secondary.opacity(0.2)
    }
}

// MARK: ── Visual Parts ──

struct _AccumulationCircle: View {
    let level: Double
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.15), lineWidth: 3)

            Circle()
                .trim(from: 0, to: level)
                .stroke(
                    _color,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: level)

            Text(level == 0 ? "－" : "\(Int(level * 100))%")
                .font(.system(size: diameter * 0.26, weight: .bold, design: .monospaced))
                .foregroundStyle(level == 0 ? Color.secondary : _color)
        }
        .frame(width: diameter, height: diameter)
    }

    private var _color: Color {
        level >= 0.7 ? .green : level >= 0.35 ? .orange : .red
    }
}

private struct _MiniAccBar: View {
    let level: Double

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(_color)
                    .frame(width: max(0, 40 * level))
                    .animation(.easeInOut(duration: 0.3), value: level)
            }
        }
        .frame(width: 40, height: 6)
    }

    private var _color: Color {
        level >= 0.7 ? .green : level >= 0.35 ? .orange : level > 0 ? .yellow : Color.secondary.opacity(0.2)
    }
}

// MARK: ── Paper Detail Sheet ──

struct Inf6CorePaperDetailView: View {
    let store: Inf6CorePaperStore
    let paper: Inf6CorePaper
    @Environment(\.dismiss) private var dismiss

    @State private var status: Inf6CorePaperStatus = .notStarted
    @State private var mastery: Int = 0
    @State private var keyPoints: String = ""
    @State private var manualAbstractInput: String = ""
    @State private var showManualInput: Bool = false

    private let abstractStore = Inf6CorePaperAbstractStore.shared

    private var prog: Inf6CorePaperProgress? { store.progress[paper.id] }
    private var related: [Inf6CorePaper] { store.relatedPapers(to: paper) }
    private var category: Inf6CorePaperCategory { Inf6CorePaperCategory.infer(from: paper.tags) }

    var body: some View {
        List {
            // Paper info
            Section("論文情報") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(paper.title)
                        .font(.headline)
                    Text(category.displayName)
                        .font(.caption.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1), in: Capsule())
                        .foregroundStyle(.blue)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(paper.tags, id: \.self) { tag in
                                Text(tag).font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Color.gray.opacity(0.12), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)

                if let pdfURL = paper.resolvedPDFURL {
                    Link(destination: pdfURL) {
                        Label("PDF を開く", systemImage: "doc.richtext")
                    }
                }
                if paper.provider == "arxiv", let absURL = paper.resolvedAbsURL {
                    Link(destination: absURL) {
                        Label("arXiv 概要", systemImage: "safari")
                    }
                }
            }

            // Abstract section
            _AbstractSection(paper: paper, abstractStore: abstractStore,
                             showManualInput: $showManualInput,
                             manualAbstractInput: $manualAbstractInput)

            // Progress & Accumulation
            Section("進捗・知の蓄積度") {
                // Accumulation visual
                HStack(spacing: 16) {
                    _AccumulationCircle(level: _accLevel, diameter: 56)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("知の蓄積度")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(_accLabel)
                            .font(.subheadline.bold())
                            .foregroundStyle(_accColor)
                        if mastery > 0 {
                            Text(String(repeating: "★", count: mastery) + String(repeating: "☆", count: 5 - mastery))
                                .foregroundStyle(.yellow)
                        }
                    }
                }
                .padding(.vertical, 4)

                Picker("ステータス", selection: $status) {
                    ForEach(Inf6CorePaperStatus.allCases) { st in
                        Text("\(st.emoji) \(st.displayName)").tag(st)
                    }
                }
                .onChange(of: status) { _, v in
                    store.updateProgress(paperId: paper.id) { $0.status = v }
                }

                // Mastery (到達度) = 知の蓄積度スコア
                VStack(alignment: .leading, spacing: 6) {
                    Text("到達度（知の蓄積）")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        ForEach(0...5, id: \.self) { i in
                            Button {
                                mastery = i
                                store.updateProgress(paperId: paper.id) { $0.masteryScore = i }
                            } label: {
                                if i == 0 {
                                    Text("未").font(.caption2).frame(width: 28, height: 28)
                                        .background(mastery == 0 ? Color.secondary.opacity(0.25) : Color.clear, in: Circle())
                                } else {
                                    Image(systemName: i <= mastery ? "star.fill" : "star")
                                        .foregroundStyle(i <= mastery ? .yellow : Color.secondary.opacity(0.35))
                                        .font(.title3)
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer()

                        Text(_masteryLabel(mastery))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("学習メモ").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $keyPoints)
                        .font(.callout).frame(minHeight: 64)
                        .onChange(of: keyPoints) { _, v in
                            store.updateProgress(paperId: paper.id) { $0.keyPoints = v }
                        }
                }
            }

            // Related papers
            if !related.isEmpty {
                Section("関連論文（同カテゴリ）") {
                    ForEach(related) { rel in
                        Button {
                            // Just show info inline — no nested navigation
                        } label: {
                            HStack(spacing: 8) {
                                Text((store.progress[rel.id]?.status ?? .notStarted).emoji)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(rel.title).font(.caption).lineLimit(2)
                                    if let kp = store.progress[rel.id]?.keyPoints, !kp.isEmpty {
                                        Text(kp).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Last studied
            if let last = prog?.lastStudiedAt {
                Section {
                    Label("最終学習: \(_dtStr(last))", systemImage: "clock")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(paper.id.replacingOccurrences(of: "_", with: " "))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完了") { dismiss() }
            }
        }
        .onAppear {
            if let p = prog {
                status    = p.status
                mastery   = p.masteryScore
                keyPoints = p.keyPoints
            }
        }
    }

    // ── Accumulation level (status + mastery composite) ──
    private var _accLevel: Double {
        let base: Double = { switch status {
            case .notStarted: return 0.0
            case .reading:    return 0.35
            case .done:       return 0.6
        }}()
        let bonus = mastery > 0 ? Double(mastery) / 5.0 * 0.4 : 0.0
        return min(1.0, base + bonus)
    }

    private var _accLabel: String {
        switch _accLevel {
        case 0.0:         return "未学習"
        case ..<0.2:      return "断片的"
        case ..<0.4:      return "入門"
        case ..<0.6:      return "理解中"
        case ..<0.8:      return "把握済み"
        default:          return "深く蓄積"
        }
    }

    private var _accColor: Color {
        _accLevel >= 0.7 ? .green : _accLevel >= 0.35 ? .orange : .red
    }

    private func _masteryLabel(_ n: Int) -> String {
        ["未評価", "概要把握", "基礎理解", "応用可能", "深い理解", "完全習得"][min(n, 5)]
    }

    private func _dtStr(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateStyle = .short; f.timeStyle = .short
        return f.string(from: d)
    }
}

// MARK: - Abstract Section (Detail View helper)

private struct _AbstractSection: View {
    let paper: Inf6CorePaper
    let abstractStore: Inf6CorePaperAbstractStore
    @Binding var showManualInput: Bool
    @Binding var manualAbstractInput: String

    private var abstractText: String? { abstractStore.abstract(for: paper.id) }
    private var isFetching: Bool      { abstractStore.isFetching(paper.id) }
    private var fetchError: String?   { abstractStore.fetchErrors[paper.id] }

    var body: some View {
        Section {
            if let text = abstractText {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    HStack {
                        Spacer()
                        Button("再取得") {
                            Task { await abstractStore.fetchAbstract(for: paper) }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            } else if isFetching {
                HStack(spacing: 8) {
                    ProgressView().tint(.pink).scaleEffect(1.25)
                    Text("要旨を取得中…")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let err = fetchError {
                        Text(err)
                            .font(.caption).foregroundStyle(.red)
                    }
                    HStack(spacing: 12) {
                        if paper.provider == "arxiv" {
                            Button {
                                Task { await abstractStore.fetchAbstract(for: paper) }
                            } label: {
                                Label("arXivから要旨を取得", systemImage: "arrow.down.circle")
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button {
                                Task { await abstractStore.fetchAbstract(for: paper) }
                            } label: {
                                Label("概要を登録", systemImage: "doc.text.magnifyingglass")
                            }
                            .buttonStyle(.bordered)
                        }
                        Button {
                            showManualInput.toggle()
                        } label: {
                            Label("手動入力", systemImage: "square.and.pencil")
                        }
                        .buttonStyle(.bordered)
                    }

                    if showManualInput {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("要旨テキストを貼り付け").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $manualAbstractInput)
                                .font(.callout).frame(minHeight: 80)
                            Button("保存") {
                                let t = manualAbstractInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !t.isEmpty {
                                    abstractStore.storeManual(paperId: paper.id, text: t)
                                    showManualInput = false
                                    manualAbstractInput = ""
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(manualAbstractInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "text.quote")
                    .font(.caption.bold())
                Text("論文要旨")
                    .font(.caption.bold())
            }
        }
    }
}

// MARK: ── Convenience Section Wrappers called from _coreListBase ──
// (Inf6CorePaperProgressSection, Inf6CorePaperOrderSection は削除し統合)

/// アラームセクションのエイリアス（_coreListBase から使用）
typealias Inf6CorePaperProgressSection = Inf6CorePaperAlertSection

/// ツリーセクションのエイリアス（_coreListBase から使用）
typealias Inf6CorePaperOrderSection    = Inf6CorePaperSyllabusTreeSection

// MARK: 3. 次に学ぶべき論文セクション

struct Inf6CorePaperNextStudySection: View {
    let store: Inf6CorePaperStore
    @State private var selectedPaper: Inf6CorePaper? = nil
    @State private var showDetail = false

    private var recommendedPapers: [Inf6CorePaper] {
        store.nextRecommendedPapers(count: 5)
    }

    var body: some View {
        if !recommendedPapers.isEmpty {
            Section {
                ForEach(recommendedPapers) { paper in
                    _NextStudyPaperRow(paper: paper, store: store)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedPaper = paper
                            showDetail = true
                        }
                }
            } header: {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption.bold())
                    Text("次に学ぶべき論文")
                        .font(.caption.bold())
                }
            }
            .sheet(isPresented: $showDetail) {
                if let paper = selectedPaper {
                    NavigationStack {
                        Inf6CorePaperDetailView(store: store, paper: paper)
                    }
                }
            }
        }
    }
}

private struct _NextStudyPaperRow: View {
    let paper: Inf6CorePaper
    let store: Inf6CorePaperStore

    private var reason: String { store.recommendationReason(for: paper) }
    private var status: Inf6CorePaperStatus { store.progress[paper.id]?.status ?? .notStarted }
    private var accLevel: Double {
        let prog = store.progress[paper.id]
        switch prog?.status ?? .notStarted {
        case .notStarted: return 0.0
        case .reading:    return 0.4 + Double(prog?.masteryScore ?? 0) / 5.0 * 0.4
        case .done:       return 1.0
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(status.emoji)
                .font(.body)

            VStack(alignment: .leading, spacing: 3) {
                Text(paper.title)
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Mini accumulation bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.12))
                        Capsule().fill(accLevel > 0 ? Color.orange : Color.secondary.opacity(0.2))
                            .frame(width: max(0, geo.size.width * accLevel))
                            .animation(.easeInOut(duration: 0.3), value: accLevel)
                    }
                }
                .frame(height: 4)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.secondary.opacity(0.5))
        }
        .padding(.vertical, 2)
    }
}

/// 旧 coverage セクションのエイリアス — 次に学ぶべき論文セクションに変更
typealias Inf6CorePaperCoverageSection = Inf6CorePaperNextStudySection

/// 次に学ぶべき論文セクションのガイドエイリアス
typealias Inf6CorePaperGuideSection = Inf6CorePaperNextStudySection
