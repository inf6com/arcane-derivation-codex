//
//  Inf6MMAQuizPlayerView.swift
//  inf6
//
//  正本仕様: SPEC.md
//
//  MMA クイズプレイヤー。
//  - sharedRoot/mma/<qualId>/quiz.json を読み込んで出題する。
//  - 回答を MasteryState に記録し、適応型再出題を行う。
//  - 習得状態の概要を上部に表示する。
//

import SwiftUI

// MARK: - MMA クイズプレイヤー

struct Inf6MMAQuizPlayerView: View {

    let qualificationId: String
    let qualificationTitle: String

    // MARK: - State

    @State private var quiz: Inf6MMAQuizStore.MMAQuiz?
    @State private var queue: [Inf6GeneratedQuestion] = []
    @State private var currentIndex: Int = 0
    @State private var selectedChoice: Int? = nil
    @State private var isAnswered: Bool = false
    @State private var masteryState: Inf6MasteryState = .init()
    @State private var errorMessage: String? = nil
    @State private var isLoading: Bool = true
    @State private var sessionCorrect: Int = 0
    @State private var sessionTotal: Int = 0
    @State private var auditReport: Inf6MMACoverageAuditReport? = nil
    @State private var coverageIndex: Inf6MMACoverageIndex = .init(targets: [])
    @State private var trendSignals: [Inf6TrendSignal] = []
    @State private var examDeadline: Inf6ExamDeadline? = nil
    @State private var selectedTab: Tab = .quiz
    @Environment(\.dismiss) private var dismiss

    enum Tab { case quiz, audit }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView(Inf6Lang.text("読み込み中…", "Loading…"))
                        .tint(.pink)
                        .scaleEffect(1.25)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = errorMessage {
                    ContentUnavailableView(
                        Inf6Lang.text("演習が見つかりません", "Exercise not found"),
                        systemImage: "exclamationmark.triangle",
                        description: Text(err)
                    )
                } else {
                    VStack(spacing: 0) {
                        // タブ切替
                        Picker("", selection: $selectedTab) {
                            Text(Inf6Lang.text("演習", "Exercise")).tag(Tab.quiz)
                            Text(Inf6Lang.text("監査", "Audit")).tag(Tab.audit)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        Divider().padding(.top, 8)

                        if selectedTab == .quiz {
                            if queue.isEmpty {
                                ContentUnavailableView(
                                    Inf6Lang.text("出題完了", "All done"),
                                    systemImage: "checkmark.seal.fill",
                                    description: Text(Inf6Lang.text(
                                        "すべての問題を終了しました。",
                                        "You have completed all questions."
                                    ))
                                )
                            } else {
                                masteryHeader
                                Divider()
                                questionCard
                            }
                        } else {
                            auditView
                        }
                    }
                }
            }
            .navigationTitle(qualificationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Inf6Lang.text("閉じる", "Close")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        _skipAndNext()
                    } label: {
                        Label(Inf6Lang.text("スキップ", "Skip"), systemImage: "arrow.right")
                    }
                    .disabled(queue.isEmpty || isAnswered)
                }
            }
        }
        .task { await _load() }
    }

    // MARK: - 習得状態ヘッダー

    private var masteryHeader: some View {
        let total = masteryState.atomStates.count
        let verified = masteryState.atomStates.values.filter { $0 == .verified }.count
        let wrong    = masteryState.atomStates.values.filter { $0 == .wrong }.count
        let progress = total > 0 ? Double(verified) / Double(total) : 0

        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Inf6Lang.text("論点習得率", "Topic mastery"))
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                ProgressView(value: progress)
                    .tint(Color.accentColor)
                    .frame(width: 120)
            }
            Spacer()
            _masteryChip(
                label: Inf6Lang.text("確認済", "Verified"),
                value: verified,
                color: Color.accentColor
            )
            _masteryChip(
                label: Inf6Lang.text("誤答", "Wrong"),
                value: wrong,
                color: Color.red
            )
            _masteryChip(
                label: Inf6Lang.text("セッション正答", "Session"),
                value: sessionTotal > 0 ? sessionCorrect : 0,
                color: Color.primary
            )
            if let deadlineText = _deadlineBadgeText() {
                _masteryTextChip(
                    label: Inf6Lang.text("試験日", "Deadline"),
                    value: deadlineText,
                    color: Color.orange
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
    }

    private func _masteryChip(label: String, value: Int, color: Color) -> some View {
        VStack(spacing: 0) {
            Text("\(value)")
                .font(.headline)
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Color.secondary)
        }
        .frame(minWidth: 44)
    }

    private func _masteryTextChip(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.headline)
                .foregroundStyle(color)
                .lineLimit(1)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Color.secondary)
        }
        .frame(minWidth: 70)
    }

    // MARK: - 問題カード

    private var questionCard: some View {
        let q = queue[currentIndex]
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // 問題型バッジ + Now on the Exam タグ
                HStack {
                    Text(_questionTypeLabel(q.questionType))
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Capsule())
                        .foregroundStyle(Color.accentColor)
                    if Inf6AdaptiveQuestionSelector.isNowOnExam(q, trendSignals: trendSignals) {
                        Text(Inf6Lang.text("今の出題圧", "NOW ON EXAM"))
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.15))
                            .clipShape(Capsule())
                            .foregroundStyle(Color.orange)
                    }
                    Spacer()
                    Text(Inf6Lang.text("\(currentIndex + 1) / \(queue.count)", "\(currentIndex + 1) / \(queue.count)"))
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }

                // 問題文
                Text(q.prompt)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                // 図表式画像
                _QuizEntityImageView(prompt: q.prompt)

                // 選択肢
                ForEach(Array(q.choices.enumerated()), id: \.offset) { idx, choice in
                    _choiceButton(q: q, idx: idx, choice: choice)
                }

                // 解説（回答後）
                if isAnswered {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Inf6Lang.text("解説", "Explanation"))
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                        Text(q.explanation)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        if !q.sourceURLs.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Inf6Lang.text("根拠", "Sources"))
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                                ForEach(q.sourceURLs.prefix(3), id: \.self) { url in
                                    if let u = URL(string: url) {
                                        Link(url, destination: u)
                                            .font(.caption)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                        Button(Inf6Lang.text("次の問題", "Next question")) {
                            _next()
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.primary.opacity(0.05))
                    )
                }
            }
            .padding(16)
        }
    }

    private func _choiceButton(q: Inf6GeneratedQuestion, idx: Int, choice: String) -> some View {
        let isSelected = selectedChoice == idx
        let isCorrect  = idx == q.correctIndex
        let bgColor: Color = {
            guard isAnswered else { return Color.primary.opacity(0.04) }
            if isCorrect { return Color.green.opacity(0.15) }
            if isSelected { return Color.red.opacity(0.12) }
            return Color.primary.opacity(0.04)
        }()
        let borderColor: Color = {
            guard isAnswered else { return isSelected ? Color.accentColor.opacity(0.5) : Color.clear }
            if isCorrect { return Color.green.opacity(0.6) }
            if isSelected { return Color.red.opacity(0.5) }
            return Color.clear
        }()

        return Button {
            guard !isAnswered else { return }
            selectedChoice = idx
            isAnswered = true
            _recordAnswer(q: q, chosenIndex: idx)
        } label: {
            HStack {
                Text(["A", "B", "C", "D", "E"][safe: idx] ?? "\(idx + 1)")
                    .font(.caption.bold())
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)
                Text(choice)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(Color.primary)
                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(bgColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(borderColor, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 監査ビュー

    private var auditView: some View {
        ScrollView {
            if let report = auditReport {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: report.isPass ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(report.isPass ? Color.accentColor : Color.orange)
                        Text(report.isPass
                             ? Inf6Lang.text("監査合格", "Audit passed")
                             : Inf6Lang.text("未カバー項目あり", "Uncovered items found"))
                            .font(.headline)
                    }
                    _auditSection(
                        title: Inf6Lang.text("coverageTargets なし", "No coverageTargets"),
                        items: report.questionsWithoutCoverage,
                        emptyLabel: Inf6Lang.text("なし（全問カバー済）", "None")
                    )
                    _auditSection(
                        title: Inf6Lang.text("根拠URL なし", "No source URLs"),
                        items: report.questionsWithoutSource,
                        emptyLabel: Inf6Lang.text("なし", "None")
                    )
                    _auditSection(
                        title: Inf6Lang.text("未被覆 論点 ID", "Uncovered topic IDs"),
                        items: report.uncoveredAtomIDs,
                        emptyLabel: Inf6Lang.text("なし（全論点被覆済）", "None")
                    )
                    _auditSection(
                        title: Inf6Lang.text("未被覆 関係 ID", "Uncovered relationship IDs"),
                        items: report.uncoveredEdgeIDs,
                        emptyLabel: Inf6Lang.text("なし（全関係被覆済）", "None")
                    )
                }
                .padding(16)
            } else {
                Text(Inf6Lang.text(
                    "core_knowledge.json が見つかりません。MMA 演習生成後に再度開いてください。",
                    "core_knowledge.json not found. Please generate the MMA exercise first."
                ))
                .foregroundStyle(Color.secondary)
                .padding(16)
            }
        }
    }

    private func _auditSection(title: String, items: [String], emptyLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Color.secondary)
            if items.isEmpty {
                Text(emptyLabel).font(.subheadline).foregroundStyle(Color.accentColor)
            } else {
                ForEach(items.prefix(10), id: \.self) { item in
                    Text(item).font(.caption).foregroundStyle(Color.primary)
                }
                if items.count > 10 {
                    Text(Inf6Lang.text("他 \(items.count - 10) 件", "and \(items.count - 10) more"))
                        .font(.caption).foregroundStyle(Color.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    // MARK: - ロジック

    private func _load() async {
        isLoading = true
        do {
            guard let loaded = try Inf6MMAQuizStore.load(qualificationId: qualificationId) else {
                errorMessage = Inf6Lang.text(
                    "quiz.json が見つかりません。先に MMA 演習を生成してください。",
                    "quiz.json not found. Please generate the MMA exercise first."
                )
                isLoading = false
                return
            }
            quiz         = loaded
            masteryState = loaded.masteryState
            trendSignals = Inf6ForecastAuthoringLoader.loadSignals(
                sourceFamily: _sourceFamily(qualificationId)
            )
            let currentDeadline = Inf6ExamDeadlineStore.load().first(where: { $0.examID == qualificationId })
            examDeadline = currentDeadline
            let core = try Inf6MMAStore.loadCoreKnowledge(qualificationId: qualificationId)
            let resolvedTargets = _resolvedCoverageTargets(
                questions: loaded.questions,
                core: core
            )
            coverageIndex = Inf6MMACoverageIndex(targets: resolvedTargets)
            queue        = Inf6AdaptiveQuestionSelector.prioritize(
                questions: loaded.questions,
                coverageIndex: coverageIndex,
                masteryState: loaded.masteryState,
                trendSignals: trendSignals,
                examDeadline: currentDeadline,
                limit: loaded.questions.count
            )
            currentIndex = 0

            // 監査レポートを非同期で生成
            if let core {
                auditReport = Inf6MMAAudit.audit(
                    atoms: core.atoms,
                    edges: core.edges,
                    targets: resolvedTargets,
                    questions: loaded.questions
                )
            }

        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func _recordAnswer(q: Inf6GeneratedQuestion, chosenIndex: Int) {
        let isCorrect = chosenIndex == q.correctIndex
        sessionTotal += 1
        if isCorrect { sessionCorrect += 1 }

        // 原子状態を更新
        for atomID in q.knowledgeAtomIDs {
            let current = masteryState.atomStates[atomID] ?? .unverified
            masteryState.atomStates[atomID] = _nextLevel(current: current, correct: isCorrect)
        }
        // 経脈状態を更新
        for edgeID in q.knowledgeEdgeIDs {
            let current = masteryState.edgeStates[edgeID] ?? .unverified
            masteryState.edgeStates[edgeID] = _nextLevel(current: current, correct: isCorrect)
        }
        masteryState.lastUpdatedAt = Date().timeIntervalSince1970

        // 永続化（非同期、失敗は無視しない → ログに出す）
        Task {
            do {
                try Inf6MMAQuizStore.updateMastery(
                    qualificationId: qualificationId,
                    mastery: masteryState
                )
            } catch {
                // 失敗は必ず表面化させる（CommonContract）
                print("[Inf6MMA] MasteryState save error: \(error)")
            }
        }
    }

    private func _nextLevel(current: Inf6MasteryLevel, correct: Bool) -> Inf6MasteryLevel {
        if correct {
            switch current {
            case .unverified, .wrong: return .inProgress
            case .inProgress:         return .verified
            case .verified:           return .verified
            }
        } else {
            return .wrong
        }
    }

    private func _next() {
        isAnswered     = false
        selectedChoice = nil
        if currentIndex + 1 < queue.count {
            currentIndex += 1
        } else {
            // 再度適応型で並べ直す（Trend 乗数も再適用）
            queue = Inf6AdaptiveQuestionSelector.prioritize(
                questions: quiz?.questions ?? [],
                coverageIndex: coverageIndex,
                masteryState: masteryState,
                trendSignals: trendSignals,
                examDeadline: examDeadline,
                limit: quiz?.questions.count ?? 0
            )
            currentIndex = 0
        }
    }

    private func _skipAndNext() {
        selectedChoice = nil
        isAnswered     = false
        if currentIndex + 1 < queue.count {
            currentIndex += 1
        }
    }

    private func _questionTypeLabel(_ type: Inf6QuestionType) -> String {
        switch type {
        case .definition:  return Inf6Lang.text("定義", "Definition")
        case .comparison:  return Inf6Lang.text("比較", "Comparison")
        case .prerequisite: return Inf6Lang.text("前提", "Prerequisite")
        case .order:       return Inf6Lang.text("手順", "Order")
        case .setting:     return Inf6Lang.text("設定値", "Setting")
        case .errorCause:  return Inf6Lang.text("エラー原因", "Error cause")
        case .renaming:    return Inf6Lang.text("更新名称", "Renaming")
        case .decision:    return Inf6Lang.text("実装判断", "Decision")
        }
    }

    private func _sourceFamily(_ qualificationId: String) -> String {
        if let manifest = Inf6LearningFamilyManifestStore.load(familyID: qualificationId) {
            return manifest.sourceFamily
        }
        return qualificationId.replacingOccurrences(of: "-", with: "_")
    }

    private func _deadlineBadgeText() -> String? {
        guard let deadline = examDeadline,
              let scheduledAt = _parseISO8601(deadline.scheduledAt) else { return nil }
        let daysRemaining = Int(ceil(scheduledAt.timeIntervalSinceNow / 86_400))
        if daysRemaining <= 0 {
            return Inf6Lang.text("期限超過", "Overdue")
        }
        return Inf6Lang.text("あと \(daysRemaining) 日", "\(daysRemaining)d left")
    }

    private func _parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private func _resolvedCoverageTargets(
        questions: [Inf6GeneratedQuestion],
        core: Inf6CoreKnowledgeSet?
    ) -> [Inf6CoverageTarget] {
        var atomIDs = Set(core?.atoms.map(\.id) ?? [])
        var edgeIDs = Set(core?.edges.map(\.id) ?? [])

        if core == nil {
            for q in questions {
                atomIDs.formUnion(q.knowledgeAtomIDs)
                edgeIDs.formUnion(q.knowledgeEdgeIDs)
            }
        }

        var seen: Set<String> = []
        var targets: [Inf6CoverageTarget] = []
        for q in questions {
            for refID in q.coverageTargetIDs where seen.insert(refID).inserted {
                if atomIDs.contains(refID) {
                    targets.append(.atom(id: refID, atomID: refID))
                } else if edgeIDs.contains(refID) {
                    targets.append(.edge(id: refID, edgeID: refID))
                }
            }
        }
        return targets
    }
}

// MARK: - Safe subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - 演習内エンティティ画像表示

private struct _QuizEntityImageView: View {
    let prompt: String
    @State private var image: UIImage?

    var body: some View {
        if let img = image {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                }
        }
    }

    init(prompt: String) {
        self.prompt = prompt
        let ref = Self._extractRef(prompt)
        if let ref {
            NSLog("[inf6-quiz] extracted ref='%@' from prompt", ref)
            _image = State(initialValue: Self._resolve(ref: ref))
        } else {
            _image = State(initialValue: nil)
        }
    }

    private static func _extractRef(_ prompt: String) -> String? {
        guard let range = prompt.range(of: #"\[図[：:][\s]*(.+?)\]"#, options: .regularExpression) else { return nil }
        var s = String(prompt[range])
        if let colonRange = s.range(of: "：") ?? s.range(of: ":") {
            s = String(s[colonRange.upperBound...])
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " \t]"))
        return s.isEmpty ? nil : s
    }

    private static func _resolve(ref: String) -> UIImage? {
        let refUp = ref.uppercased()
        let allEntityKeys = Inf6MetadataStore.listKeys(domain: .docEntities)
        let imagesBase = Inf6LibraryView._entityImagesBaseURL()

        NSLog("[inf6-quiz] resolve ref='%@', entityKeys=%d, base=%@", refUp, allEntityKeys.count, imagesBase.path)

        for entityKey in allEntityKeys {
            guard let index = Inf6MetadataStore.getCodable(Inf6DocEntityIndex.self, domain: .docEntities, key: entityKey) else { continue }
            for entity in index.entities {
                guard let path = entity.imagePath else { continue }
                let titleUp = entity.title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).uppercased()
                if _matches(titleUp, refUp) {
                    let url = imagesBase.appendingPathComponent(path)
                    if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
                        NSLog("[inf6-quiz] matched: title='%@' ref='%@' path=%@", titleUp, refUp, path)
                        return img
                    }
                }
            }
        }
        NSLog("[inf6-quiz] no match for ref='%@'", refUp)
        return nil
    }

    private static func _matches(_ entityTitle: String, _ ref: String) -> Bool {
        if entityTitle == ref { return true }
        if entityTitle.contains(ref) || ref.contains(entityTitle) { return true }
        let refShort = ref.components(separatedBy: ":").first?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ref
        if refShort != ref {
            if entityTitle == refShort || entityTitle.contains(refShort) { return true }
        }
        let romanToArabic: [(String, String)] = [
            ("VIII", "8"), ("VII", "7"), ("VI", "6"), ("IV", "4"),
            ("IX", "9"), ("III", "3"), ("II", "2"), ("I", "1"),
            ("V", "5"), ("X", "10")
        ]
        for (roman, arabic) in romanToArabic {
            if ref.hasSuffix(" \(roman)") {
                let arabicRef = String(ref.dropLast(roman.count + 1)) + " " + arabic
                if entityTitle == arabicRef || entityTitle.contains(arabicRef) || arabicRef.contains(entityTitle) { return true }
            }
        }
        return false
    }
}
