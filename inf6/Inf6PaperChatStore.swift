//
//  Inf6PaperChatStore.swift
//  inf6
//
//  ViewModel for PaperChat
//

import Foundation
import SwiftUI

// NOTE: ViewModelはUIファイルに依存しないため、ローカライズは最小ヘルパで保持する。
private func _pcLangText(_ ja: String, _ en: String) -> String {
    let code = Locale.current.language.languageCode?.identifier ?? ""
    if code.lowercased().hasPrefix("ja") { return ja }
    return en
}

@MainActor
final class Inf6PaperChatViewModel: ObservableObject {

    @Published var messages: [Inf6PaperChatMessage] = []
    @Published var inputText: String = ""
    @Published var isBusy: Bool = false
    @Published var lastError: String? = nil

    // MARK: - Profile-first state machine

    enum Source: String, Codable {
        case auto
        case arxiv
        case pubmed
        case acl
        case isca
    }

    enum Track: String, Codable {
        case aiInfo
        case bioMed
        case mathStat
        case physicsEess
        case econFin
        case other
    }

    enum UsageMode: String, Codable {
        case study
        case research
        case work
    }

    enum UserPersona: String, Codable {
        case student
        case researcher
        case engineer
    }

    enum ContextKind: String, Codable {
        case qualification
        case lecture
        case selfStudy
        case researchPrep
        case workPrep
        case none
    }

    enum Orientation: String, Codable {
        case foundation
        case applied
        case theory
        case implementation
    }

    enum AssessmentPreference: String, Codable {
        case undecided
        case enabled
        case skipped
    }

    enum TimeBudget: String, Codable {
        case quick15
        case focused30
        case deep60
        case extensive
    }

    enum Stage: String, Codable {
        case choosePersona
        case askGoal
        case chooseTimeBudget
        case chooseContext
        case askKeywords
        case askConstraints
        case chooseTrack
        case chooseOrientation
        case chooseSource
        case confirmQuery
        case readyToSearch
    }

    enum RouteActionKind: String, Hashable {
        case persona
        case goal
        case timeBudget
        case context
        case keyword
        case constraint
        case track
        case orientation
        case source
        case confirm
        case search
        case queryManual
    }

    @Published var stage: Stage = .choosePersona

    // Profile fields (user-authored; no implicit translation)
    @Published var selectedMode: UsageMode = .study
    @Published var selectedPersona: UserPersona = .student
    @Published var selectedContext: ContextKind = .none
    @Published var selectedSource: Source = .auto
    @Published var selectedTrack: Track = .aiInfo
    @Published var selectedOrientation: Orientation = .foundation
    @Published var assessmentPreference: AssessmentPreference = .undecided
    @Published var selectedTimeBudget: TimeBudget = .focused30

    // Display strings (localized)
    @Published var goalText: String = ""
    @Published var domainKey: String = ""
    @Published var keywordsText: String = ""
    @Published var constraintsText: String = ""
    @Published var arxivQueryText: String = ""

    // Stable IDs (language-safe)
    @Published private(set) var goalID: String = ""
    @Published private(set) var taskID: String = ""
    @Published private(set) var domainID: String = ""

    // Quick replies shown as tap buttons (UI-driven chat)
    @Published var quickReplies: [Inf6PaperChatQuickReply] = []

    private let _defaultTrackUserDefaultsKey = "inf6_paperchat_default_track"
    private let _recentSearchUserDefaultsKey = "inf6_paperchat_recent_search_v1"
    private let _profileSnapshotUserDefaultsKey = "inf6_paperchat_profile_snapshot_v5"
    private let _latestResultsUserDefaultsKey = "inf6_paperchat_latest_results_v1"

    private struct _RecentSearchSnapshot: Codable, Hashable {
        let createdAt: Date
        let query: String
        let topTitles: [String]
    }

    private struct _ProfileSnapshot: Codable, Hashable {
        let createdAt: Date
        let selectedModeRaw: String
        let selectedPersonaRaw: String?
        let selectedContextRaw: String
        let selectedTrackRaw: String
        let selectedSourceRaw: String
        let selectedOrientationRaw: String
        let assessmentPreferenceRaw: String
        let selectedTimeBudgetRaw: String?
        let stageRaw: String
        let goalID: String
        let taskID: String
        let domainID: String
        let keywordsText: String
        let constraintsText: String
        let arxivQueryText: String
    }

    private struct _PersistedResult: Codable, Hashable {
        let id: String
        let title: String
        let subtitle: String
        let landingURLString: String
        let pdfURLString: String
    }

    // Latest search results (shown as a list under assistant response)
    @Published var latestResults: [Inf6PaperSearchResult] = []
    @Published var latestVectorScoresByID: [String: Float] = [:]
    @Published var latestVectorRerankSummary: String = ""
    @Published var latestResultsSourceLabel: String = "arXiv"
    @Published var latestCurrentPositionSummary: String = ""
    @Published var latestFrontierSummary: String = ""
    @Published var latestFrontierBandByID: [String: String] = [:]
    @Published var latestCorpusBuildSummary: String = ""
    @Published var latestProfileKeySummary: String = ""
    @Published var latestProfileKeyPreview: String = ""
    @Published var latestResultClusterLabelByID: [String: String] = [:]
    @Published var latestResultClusterRankByID: [String: Int] = [:]
    @Published var latestResultFeatureKeywordsByID: [String: [String]] = [:]
    @Published var latestResultClassificationSummary: String = ""
    @Published var latestResultClassificationError: String? = nil

    private var _didAttemptCorpusBootstrapThisLaunch: Bool = false

    // MARK: - Snapshot IO

    private func _loadRecentSearchSnapshotOrNil() -> _RecentSearchSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: _recentSearchUserDefaultsKey) else { return nil }
        do { return try JSONDecoder().decode(_RecentSearchSnapshot.self, from: data) }
        catch { return nil }
    }

    private func _persistRecentSearchSnapshot(query: String, results: [Inf6PaperSearchResult]) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }

        let titles = results.prefix(8).map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let snap = _RecentSearchSnapshot(createdAt: Date(), query: q, topTitles: titles)

        do {
            let data = try JSONEncoder().encode(snap)
            UserDefaults.standard.set(data, forKey: _recentSearchUserDefaultsKey)
        } catch {
            // persistence failure -> restoration simply won't happen
        }
    }

    private func _loadProfileSnapshotOrNil() -> _ProfileSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: _profileSnapshotUserDefaultsKey) else { return nil }
        do { return try JSONDecoder().decode(_ProfileSnapshot.self, from: data) }
        catch { return nil }
    }

    private func _persistProfileSnapshot() {
        let snap = _ProfileSnapshot(
            createdAt: Date(),
            selectedModeRaw: selectedMode.rawValue,
            selectedPersonaRaw: selectedPersona.rawValue,
            selectedContextRaw: selectedContext.rawValue,
            selectedTrackRaw: selectedTrack.rawValue,
            selectedSourceRaw: selectedSource.rawValue,
            selectedOrientationRaw: selectedOrientation.rawValue,
            assessmentPreferenceRaw: assessmentPreference.rawValue,
            selectedTimeBudgetRaw: selectedTimeBudget.rawValue,
            stageRaw: stage.rawValue,
            goalID: goalID,
            taskID: taskID,
            domainID: domainID,
            keywordsText: keywordsText,
            constraintsText: constraintsText,
            arxivQueryText: arxivQueryText
        )

        do {
            let data = try JSONEncoder().encode(snap)
            UserDefaults.standard.set(data, forKey: _profileSnapshotUserDefaultsKey)
        } catch {
            // persistence failure -> restoration simply won't happen
        }
    }

    private func _loadLatestResultsOrNil() -> [Inf6PaperSearchResult]? {
        guard let data = UserDefaults.standard.data(forKey: _latestResultsUserDefaultsKey) else { return nil }
        do {
            let xs = try JSONDecoder().decode([_PersistedResult].self, from: data)
            return xs.map { p in
                Inf6PaperSearchResult(
                    id: p.id,
                    title: p.title,
                    subtitle: p.subtitle,
                    landingURL: URL(string: p.landingURLString),
                    pdfURL: URL(string: p.pdfURLString)
                )
            }
        } catch {
            return nil
        }
    }

    private func _persistLatestResults(_ results: [Inf6PaperSearchResult]) {
        let xs: [_PersistedResult] = results.prefix(24).map { r in
            _PersistedResult(
                id: r.id,
                title: r.title,
                subtitle: r.subtitle,
                landingURLString: r.landingURL?.absoluteString ?? "",
                pdfURLString: r.pdfURL?.absoluteString ?? ""
            )
        }

        do {
            let data = try JSONEncoder().encode(xs)
            UserDefaults.standard.set(data, forKey: _latestResultsUserDefaultsKey)
        } catch {
            // persistence failure -> restoration simply won't happen
        }
    }

    // MARK: - Labels / IDs

    private func _setGoal(id: String) {
        goalID = id
        goalText = _labelForGoal(id)
    }

    private func _setTask(id: String) {
        taskID = id
    }

    private func _setDomain(id: String) {
        domainID = id
        domainKey = _labelForDomain(id)
    }

    private func _labelForMode(_ mode: UsageMode) -> String {
        switch mode {
        case .study:
            return _pcLangText("学習", "Learning")
        case .research:
            return _pcLangText("研究", "Research")
        case .work:
            return _pcLangText("仕事", "Work")
        }
    }

    private func _labelForPersona(_ persona: UserPersona) -> String {
        switch persona {
        case .student:
            return _pcLangText("学生", "Student")
        case .researcher:
            return _pcLangText("研究者", "Researcher")
        case .engineer:
            return _pcLangText("エンジニア", "Engineer")
        }
    }

    private func _applyPersonaDefaults(_ persona: UserPersona) {
        selectedPersona = persona
        switch persona {
        case .student:
            selectedMode = .study
            selectedContext = .none
            selectedOrientation = .foundation
            selectedTimeBudget = .focused30
        case .researcher:
            selectedMode = .research
            selectedContext = .none
            selectedOrientation = .theory
            selectedTimeBudget = .deep60
        case .engineer:
            selectedMode = .work
            selectedContext = .none
            selectedOrientation = .implementation
            selectedTimeBudget = .focused30
        }
    }

    private func _labelForContext(_ context: ContextKind) -> String {
        switch context {
        case .qualification:
            return _pcLangText("資格対策", "Qualification")
        case .lecture:
            return _pcLangText("授業 / 講義", "Lecture / Course")
        case .selfStudy:
            return _pcLangText("独学", "Self-study")
        case .researchPrep:
            return _pcLangText("研究準備", "Research prep")
        case .workPrep:
            return _pcLangText("業務準備", "Work prep")
        case .none:
            return _pcLangText("特に限定なし", "No specific context")
        }
    }

    private func _labelForOrientation(_ orientation: Orientation) -> String {
        switch orientation {
        case .foundation:
            return _pcLangText("基礎", "Foundation")
        case .applied:
            return _pcLangText("応用", "Applied")
        case .theory:
            return _pcLangText("理論", "Theory")
        case .implementation:
            return _pcLangText("実装", "Implementation")
        }
    }

    private func _labelForTimeBudget(_ budget: TimeBudget) -> String {
        switch budget {
        case .quick15:
            return _pcLangText("15分（短時間）", "15 min (quick)")
        case .focused30:
            return _pcLangText("30分（標準）", "30 min (focused)")
        case .deep60:
            return _pcLangText("60分（深掘り）", "60 min (deep)")
        case .extensive:
            return _pcLangText("90分以上（広く探索）", "90+ min (extensive)")
        }
    }

    private func _labelForSource(_ source: Source) -> String {
        switch source {
        case .auto:
            return _pcLangText("自動", "Auto")
        case .arxiv:
            return "arXiv"
        case .pubmed:
            return "PubMed"
        case .acl:
            return "ACL"
        case .isca:
            return "ISCA"
        }
    }

    private func _resolvedSourceFromAuto() -> Source {
        guard selectedSource == .auto else { return selectedSource }

        let text = "\(keywordsText) \(constraintsText) \(goalText)".lowercased()
        let medicalHints = [
            "bio", "biomedical", "clinical", "medicine", "medic", "health", "病", "医", "臨床", "生命", "生体", "薬"
        ]
        let speechHints = [
            "speech", "asr", "acoustic", "音声", "話者", "認識", "方言", "発話", "phoneme", "prosody"
        ]
        let nlpHints = [
            "nlp", "dialogue", "language model", "自然言語", "対話", "言語", "llm", "translation"
        ]
        if selectedTrack == .bioMed || medicalHints.contains(where: { text.contains($0) }) {
            return .pubmed
        }
        if speechHints.contains(where: { text.contains($0) }) {
            return .isca
        }
        if nlpHints.contains(where: { text.contains($0) }) {
            return .acl
        }
        return .auto
    }

    private func _labelForGoal(_ id: String) -> String {
        switch id {
        case "goal.find_papers":
            return _pcLangText("読む論文を探したい", "Find papers to read")
        case "goal.understand_paper":
            return _pcLangText("この論文を理解したい", "Understand this paper")
        case "goal.compare_papers":
            return _pcLangText("複数の論文を比べたい", "Compare papers")
        case "goal.implement":
            return _pcLangText("実装・再現に役立つ論文を探したい", "Find papers useful for implementation / reproduction")
        case "goal.find_gaps":
            return _pcLangText("研究の抜けや次の論点を見つけたい", "Find gaps and next research points")
        default:
            return ""
        }
    }

    private func _labelForTask(_ id: String) -> String {
        switch id {
        case "task.find_intro":
            return _pcLangText("入門として読む論文を探す", "Find introductory papers")
        case "task.find_representative":
            return _pcLangText("代表論文を探す", "Find representative papers")
        case "task.read_abstract":
            return _pcLangText("要旨をつかむ", "Understand the abstract")
        case "task.read_figure":
            return _pcLangText("図を理解する", "Understand figures")
        case "task.read_formula":
            return _pcLangText("数式を理解する", "Understand formulas")
        case "task.compare_method":
            return _pcLangText("手法を比較する", "Compare methods")
        case "task.compare_metric":
            return _pcLangText("評価指標を比較する", "Compare evaluation metrics")
        case "task.compare_assumption":
            return _pcLangText("仮定の違いを比較する", "Compare assumptions")
        case "task.find_repro":
            return _pcLangText("再現しやすい論文を探す", "Find reproducible papers")
        case "task.find_benchmark":
            return _pcLangText("ベンチマーク論文を探す", "Find benchmark papers")
        case "task.find_gap":
            return _pcLangText("未検証条件を探す", "Find untested conditions")
        case "task.find_conflict":
            return _pcLangText("矛盾する結果を探す", "Find conflicting results")
        default:
            return ""
        }
    }

    private func _labelForDomain(_ id: String) -> String {
        switch id {
        case "domain.ml":
            return _pcLangText("機械学習", "Machine Learning")
        case "domain.lang":
            return _pcLangText("言語", "Language")
        case "domain.vision":
            return _pcLangText("画像", "Vision")
        case "domain.retrieval":
            return _pcLangText("検索", "Retrieval")
        case "domain.other":
            return _pcLangText("その他", "Other")
        default:
            return ""
        }
    }

    // MARK: - Quick Replies

    private func _qr(_ id: String, _ ja: String, _ en: String) -> Inf6PaperChatQuickReply {
        Inf6PaperChatQuickReply(id: id, label: _pcLangText(ja, en))
    }

    private func _qrRaw(_ id: String, _ label: String) -> Inf6PaperChatQuickReply {
        Inf6PaperChatQuickReply(id: id, label: label)
    }

    private func _refreshQuickRepliesForStage() {
        switch stage {
        case .choosePersona:
            quickReplies = [
                _qr("persona.student", "学生", "Student"),
                _qr("persona.researcher", "研究者", "Researcher"),
                _qr("persona.engineer", "エンジニア", "Engineer")
            ]

        case .askGoal:
            switch selectedPersona {
            case .student:
                quickReplies = [
                    _qr("goal.understand_paper", "この論文を理解したい", "Understand this paper"),
                    _qr("goal.find_papers", "読む論文を探したい", "Find papers to read"),
                    _qr("goal.compare_papers", "複数の論文を比べたい", "Compare papers"),
                    _qr("goal.implement", "実装・再現に役立つ論文を探したい", "Find papers useful for implementation / reproduction")
                ]
            case .researcher:
                quickReplies = [
                    _qr("goal.find_gaps", "研究の抜けや次の論点を見つけたい", "Find gaps and next research points"),
                    _qr("goal.compare_papers", "複数の論文を比べたい", "Compare papers"),
                    _qr("goal.find_papers", "読む論文を探したい", "Find papers to read"),
                    _qr("goal.understand_paper", "この論文を理解したい", "Understand this paper")
                ]
            case .engineer:
                quickReplies = [
                    _qr("goal.implement", "実装・再現に役立つ論文を探したい", "Find papers useful for implementation / reproduction"),
                    _qr("goal.find_papers", "読む論文を探したい", "Find papers to read"),
                    _qr("goal.compare_papers", "複数の論文を比べたい", "Compare papers"),
                    _qr("goal.understand_paper", "この論文を理解したい", "Understand this paper")
                ]
            }

        case .chooseTimeBudget:
            quickReplies = [
                _qr("time.quick15", "15分（短時間）", "15 min (quick)"),
                _qr("time.focused30", "30分（標準）", "30 min (focused)"),
                _qr("time.deep60", "60分（深掘り）", "60 min (deep)"),
                _qr("time.extensive", "90分以上（広く探索）", "90+ min (extensive)")
            ]

        case .chooseContext:
            switch selectedPersona {
            case .student:
                quickReplies = [
                    _qr("context.qualification", "資格対策", "Qualification"),
                    _qr("context.lecture", "授業 / 講義", "Lecture / Course"),
                    _qr("context.selfStudy", "独学", "Self-study"),
                    _qr("context.none", "特に限定なし", "No specific context")
                ]
            case .researcher:
                quickReplies = [
                    _qr("context.researchPrep", "研究準備", "Research prep"),
                    _qr("context.lecture", "授業 / 講義", "Lecture / Course"),
                    _qr("context.selfStudy", "独学", "Self-study"),
                    _qr("context.none", "特に限定なし", "No specific context")
                ]
            case .engineer:
                quickReplies = [
                    _qr("context.workPrep", "業務準備", "Work prep"),
                    _qr("context.selfStudy", "独学", "Self-study"),
                    _qr("context.lecture", "授業 / 講義", "Lecture / Course"),
                    _qr("context.none", "特に限定なし", "No specific context")
                ]
            }

        case .askKeywords:
            if _isUnderstandPaperGoal() {
                quickReplies = []
            } else {
                quickReplies = _keywordSuggestions(for: domainKey, track: selectedTrack, goal: goalText).map { s in
                    if s == "なし" {
                        return _qr("kw.none", "なし", "None")
                    }
                    return _qrRaw("kw:\(s)", s)
                }
            }

        case .askConstraints:
            quickReplies = _constraintSuggestions(track: selectedTrack, goal: goalText).map { s in
                if s == "なし" {
                    return _qr("cs.none", "なし", "None")
                }
                return _qrRaw("cs:\(s)", s)
            }

        case .chooseTrack:
            quickReplies = [
                _qr("track.aiInfo", "AI/情報", "AI / Info"),
                _qr("track.bioMed", "医学・生命", "Bio / Medical"),
                _qr("track.mathStat", "数理・統計", "Math / Stats"),
                _qr("track.physicsEess", "物理・電気", "Physics / EESS"),
                _qr("track.econFin", "経済・金融", "Econ / Finance"),
                _qr("track.other", "その他", "Other")
            ]

        case .chooseOrientation:
            quickReplies = [
                _qr("orientation.foundation", "基礎（前提から）", "Foundation (from basics)"),
                _qr("orientation.applied", "応用（実務寄り）", "Applied (practical)"),
                _qr("orientation.theory", "理論（数理重視）", "Theory (math-heavy)"),
                _qr("orientation.implementation", "実装（再現重視）", "Implementation (repro-focused)")
            ]

        case .chooseSource:
            quickReplies = [
                _qr("source.auto", "自動（推奨）", "Auto (recommended)"),
                _qr("source.arxiv", "arXiv", "arXiv"),
                _qr("source.pubmed", "PubMed", "PubMed"),
                _qr("source.acl", "ACL", "ACL"),
                _qr("source.isca", "ISCA", "ISCA")
            ]

        case .confirmQuery:
            quickReplies = [_qr("confirm.auto", "検索式を確定", "Confirm query")]

        case .readyToSearch:
            quickReplies = [_qr("action.search", "検索を開始", "Start search")]
        }
    }

    // MARK: - UI Texts (exposed to UI layer)

    private var _workflowStages: [Stage] {
        if _isUnderstandPaperGoal() {
            return [
                .choosePersona,
                .askGoal,
                .chooseTimeBudget,
                .chooseContext,
                .askKeywords,
                .chooseSource,
                .confirmQuery,
                .readyToSearch
            ]
        }
        return [
            .choosePersona,
            .askGoal,
            .chooseTimeBudget,
            .chooseContext,
            .chooseTrack,
            .chooseOrientation,
            .askKeywords,
            .askConstraints,
            .chooseSource,
            .confirmQuery,
            .readyToSearch
        ]
    }

    var workflowStageRawOrder: [String] {
        _workflowStages.map { $0.rawValue }
    }

    var workflowProgressText: String {
        let steps = _workflowStages
        guard let idx = steps.firstIndex(of: stage) else {
            return _pcLangText("ワークフロー", "Workflow")
        }
        return _pcLangText("ステップ \(idx + 1)/\(steps.count)", "Step \(idx + 1)/\(steps.count)")
    }

    var stageHeaderText: String {
        switch stage {
        case .choosePersona: return _pcLangText("立場を選択", "Choose your role")
        case .askGoal: return _pcLangText("目的を選択", "Choose goal")
        case .chooseTimeBudget: return _pcLangText("時間予算を選択", "Choose time budget")
        case .chooseContext: return _pcLangText("利用文脈を選択", "Choose context")
        case .askKeywords: return _pcLangText("キーワードを設定", "Set keywords")
        case .askConstraints: return _pcLangText("制約を設定", "Set constraints")
        case .chooseTrack: return _pcLangText("系を選択", "Choose track")
        case .chooseOrientation: return _pcLangText("読み方の軸を選択", "Choose reading orientation")
        case .chooseSource: return _pcLangText("検索ソースを選択", "Choose search source")
        case .confirmQuery: return _pcLangText("検索式を確定", "Confirm query")
        case .readyToSearch: return _pcLangText("検索実行", "Run search")
        }
    }

    var stageHintText: String {
        switch stage {
        case .choosePersona:
            return _pcLangText("まず、あなたの立場を選択してください", "First, choose your role")
        case .askGoal:
            return _pcLangText("最短で到達したいゴールを1つ選択してください", "Pick the single goal you need to reach first")
        case .chooseTimeBudget:
            return _pcLangText("今回使える時間を選択してください（検索件数の上限に反映します）", "Choose available time for this run (affects result volume)")
        case .chooseContext:
            return _pcLangText("利用文脈を選択してください（推薦の重み付けに使います）", "Choose context (used for ranking preference)")
        case .askKeywords:
            if _isUnderstandPaperGoal() {
                return _pcLangText(
                    "対象論文の arXiv ID / URL / タイトルを入力してください",
                    "Enter target paper arXiv ID / URL / title"
                )
            }
            return _pcLangText("軸になる語を1つ選択（または入力）してください", "Select or type one core keyword")
        case .askConstraints:
            return _pcLangText("優先条件を1つ選択（または入力）してください", "Select or type one priority constraint")
        case .chooseTrack:
            return _pcLangText("分野系統を選択してください", "Choose your field track")
        case .chooseOrientation:
            return _pcLangText("読むときの軸（基礎/応用/理論/実装）を選択してください", "Choose reading orientation (foundation/applied/theory/implementation)")
        case .chooseSource:
            return _pcLangText("自動推奨を使うか、検索先を固定するかを選択します", "Use automatic source routing or pin a source")
        case .confirmQuery:
            return _pcLangText("検索式を確認して確定してください", "Review and confirm the query")
        case .readyToSearch:
            return _pcLangText("『検索』で実行します", "Tap 'Search' to run")
        }
    }

    var profileSummaryText: String {
        var parts: [String] = []
        parts.append(_labelForPersona(selectedPersona))
        if !goalText.isEmpty {
            parts.append(goalText)
        }
        if selectedContext != .none {
            parts.append(_labelForContext(selectedContext))
        }
        parts.append(_pcLangText("時間", "Time") + ": " + _labelForTimeBudget(selectedTimeBudget))
        if !_isUnderstandPaperGoal() {
            parts.append(_pcLangText("系", "Track") + ": " + _trackLabel(selectedTrack))
        }
        parts.append(_pcLangText("読み方", "Orientation") + ": " + _labelForOrientation(selectedOrientation))
        parts.append(_pcLangText("ソース", "Source") + ": " + _labelForSource(selectedSource))

        return _pcLangText("現在: \(parts.joined(separator: " / "))", "Now: \(parts.joined(separator: " / "))")
    }

    var generatedProfileText: String {
        var lines: [String] = []
        lines.append("persona: \(_labelForPersona(selectedPersona))")
        lines.append("mode: \(_labelForMode(selectedMode))")
        lines.append("time_budget: \(_labelForTimeBudget(selectedTimeBudget))")
        lines.append("context: \(_labelForContext(selectedContext))")
        if !_isUnderstandPaperGoal() {
            lines.append("track: \(_trackLabel(selectedTrack))")
        }
        lines.append("orientation: \(_labelForOrientation(selectedOrientation))")
        lines.append("source: \(_labelForSource(selectedSource))")

        if !goalText.isEmpty {
            lines.append("goal: \(goalText)")
        }

        let taskText = _labelForTask(taskID)
        if !taskText.isEmpty {
            lines.append("task: \(taskText)")
        }

        if !domainKey.isEmpty {
            lines.append("domain: \(domainKey)")
        }
        if !keywordsText.isEmpty {
            lines.append("keywords: \(keywordsText)")
        }
        if !constraintsText.isEmpty {
            lines.append("constraints: \(constraintsText)")
        }
        if assessmentPreference == .enabled {
            lines.append("assessment: enabled")
        } else if assessmentPreference == .skipped {
            lines.append("assessment: skipped")
        }

        return lines.joined(separator: "\n")
    }

    var compactStageDescriptionText: String {
        workflowProgressText
    }

    var canGoBack: Bool {
        guard let idx = _workflowStages.firstIndex(of: stage) else { return false }
        return idx > 0
    }

    var shouldShowMessages: Bool {
        return stage == .readyToSearch || isBusy || !latestResults.isEmpty || lastError != nil
    }

    var allowsManualInput: Bool {
        switch stage {
        case .askKeywords, .askConstraints, .readyToSearch:
            return true
        default:
            return false
        }
    }

    var manualInputPlaceholderText: String {
        switch stage {
        case .askKeywords:
            if _isUnderstandPaperGoal() {
                return _pcLangText(
                    "例: 2506.11874v1 / https://arxiv.org/abs/2506.11874 / 論文タイトル",
                    "e.g. 2506.11874v1 / https://arxiv.org/abs/2506.11874 / paper title"
                )
            }
            return _pcLangText("キーワードを入力して検索", "Type a keyword and search")
        case .askConstraints:
            return _pcLangText("制約（優先条件）を入力して検索", "Type a constraint and search")
        case .readyToSearch:
            return _pcLangText("検索式を入力して検索（任意）", "Type query override and search (optional)")
        default:
            return _pcLangText("このステップはチップを選択", "Use quick replies at this stage")
        }
    }

    // MARK: - Default Track Persistence (label-only)

    private func _trackLabel(_ t: Track) -> String {
        switch t {
        case .aiInfo: return "AI/情報"
        case .bioMed: return "医学・生命"
        case .mathStat: return "数理・統計"
        case .physicsEess: return "物理・電気"
        case .econFin: return "経済・金融"
        case .other: return "その他"
        }
    }

    private func _trackFromLabel(_ s: String) -> Track? {
        switch s {
        case "AI/情報": return .aiInfo
        case "医学・生命": return .bioMed
        case "数理・統計": return .mathStat
        case "物理・電気": return .physicsEess
        case "経済・金融": return .econFin
        case "その他": return .other
        default: return nil
        }
    }

    private func _loadDefaultTrackOrNil() -> Track? {
        let raw = (UserDefaults.standard.string(forKey: _defaultTrackUserDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return _trackFromLabel(raw)
    }

    private func _persistDefaultTrack(_ t: Track) {
        UserDefaults.standard.set(_trackLabel(t), forKey: _defaultTrackUserDefaultsKey)
    }

    func isDefaultTrackChipID(_ id: String) -> Bool {
        guard stage == .chooseTrack else { return false }
        switch selectedTrack {
        case .aiInfo: return id == "track.aiInfo"
        case .bioMed: return id == "track.bioMed"
        case .mathStat: return id == "track.mathStat"
        case .physicsEess: return id == "track.physicsEess"
        case .econFin: return id == "track.econFin"
        case .other: return id == "track.other"
        }
    }

    // MARK: - Init

    private func _appendInitialAssistantPrompt() {
        messages.append(
            Inf6PaperChatMessage(
                role: .assistant,
                text: _pcLangText(
                    "まず、立場（学生 / 研究者 / エンジニア）を選択してください。\nこのあと、目的 → 時間 → 文脈 →（必要に応じて）分野/読み方/キーワード/制約/検索先の順で設定し、最後に検索を実行します。",
                    "First, choose your role (Student / Researcher / Engineer).\nThen configure goal → time budget → context → (as needed) track/orientation/keywords/constraints/source, and finally run search."
                )
            )
        )
    }

    init(restoreLatestResultsOnLaunch: Bool = false) {
        _appendInitialAssistantPrompt()

        if let t = _loadDefaultTrackOrNil() {
            selectedTrack = t
        }

        if let p = _loadProfileSnapshotOrNil() {
            if let m = UsageMode(rawValue: p.selectedModeRaw) {
                selectedMode = m
            }
            if let rp = p.selectedPersonaRaw, let persona = UserPersona(rawValue: rp) {
                selectedPersona = persona
            }
            if let c = ContextKind(rawValue: p.selectedContextRaw) {
                selectedContext = c
            }
            if let t = Track(rawValue: p.selectedTrackRaw) {
                selectedTrack = t
            }
            if let s = Source(rawValue: p.selectedSourceRaw) {
                selectedSource = s
            }
            if let o = Orientation(rawValue: p.selectedOrientationRaw) {
                selectedOrientation = o
            }
            if let a = AssessmentPreference(rawValue: p.assessmentPreferenceRaw) {
                assessmentPreference = a
            }
            if let b = p.selectedTimeBudgetRaw, let tb = TimeBudget(rawValue: b) {
                selectedTimeBudget = tb
            }

            if !p.goalID.isEmpty {
                _setGoal(id: p.goalID)
            } else {
                goalID = ""
                goalText = ""
            }

            taskID = p.taskID

            if !p.domainID.isEmpty {
                _setDomain(id: p.domainID)
            } else {
                domainID = ""
                domainKey = ""
            }

            keywordsText = p.keywordsText
            constraintsText = p.constraintsText
            arxivQueryText = p.arxivQueryText

            // Always restart from persona selection for deterministic entry.
            stage = .choosePersona
        }

        _refreshQuickRepliesForStage()

        if restoreLatestResultsOnLaunch {
            if let restored = _loadLatestResultsOrNil(), !restored.isEmpty {
                latestResults = restored
            }
        }

        if let snap = _loadRecentSearchSnapshotOrNil() {
            let d = DateFormatter()
            d.locale = Locale(identifier: "ja_JP")
            d.dateStyle = .short
            d.timeStyle = .short

            let when = d.string(from: snap.createdAt)
            let top = snap.topTitles.prefix(5).enumerated().map { idx, t in
                "\(idx + 1). \(t)"
            }.joined(separator: "\n")

            messages.append(
                Inf6PaperChatMessage(
                    role: .assistant,
                    text: """
                    \(_pcLangText("直近の検索（端末内キャッシュ）", "Recent search (local cache)"))
                    \(_pcLangText("時刻", "Time")): \(when)
                    \(_pcLangText("検索式", "Query")): \(snap.query)

                    \(_pcLangText("上位タイトル", "Top titles")):
                    \(top.isEmpty ? _pcLangText("(なし)", "(none)") : top)
                    """
                )
            )
        }

        _refreshQuickRepliesForStage()
    }

    // MARK: - Actions

    private var _routePolicy: [Stage: Set<RouteActionKind>] {
        [
            .choosePersona: [.persona],
            .askGoal: [.goal],
            .chooseTimeBudget: [.timeBudget],
            .chooseContext: [.context],
            .askKeywords: [.keyword],
            .askConstraints: [.constraint],
            .chooseTrack: [.track],
            .chooseOrientation: [.orientation],
            .chooseSource: [.source],
            .confirmQuery: [.confirm],
            .readyToSearch: [.search, .queryManual]
        ]
    }

    private func _quickReplyActionKind(for id: String) -> RouteActionKind? {
        if id.hasPrefix("persona.") { return .persona }
        if id.hasPrefix("goal.") { return .goal }
        if id.hasPrefix("time.") { return .timeBudget }
        if id.hasPrefix("context.") { return .context }
        if id.hasPrefix("kw.") || id.hasPrefix("kw:") { return .keyword }
        if id.hasPrefix("cs.") || id.hasPrefix("cs:") { return .constraint }
        if id.hasPrefix("track.") { return .track }
        if id.hasPrefix("orientation.") { return .orientation }
        if id.hasPrefix("source.") { return .source }
        if id == "confirm.auto" { return .confirm }
        if id == "action.search" { return .search }
        if id == "query.manual" { return .queryManual }
        return nil
    }

    private func _manualActionKind(for stage: Stage) -> RouteActionKind? {
        switch stage {
        case .askKeywords:
            return .keyword
        case .askConstraints:
            return .constraint
        case .readyToSearch:
            return .queryManual
        default:
            return nil
        }
    }

    private func _isActionAllowed(_ kind: RouteActionKind, at stage: Stage) -> Bool {
        guard let allowed = _routePolicy[stage] else { return false }
        return allowed.contains(kind)
    }

    private func _surfaceRouteViolation(
        reasonJA: String,
        reasonEN: String
    ) {
        let message = _pcLangText(reasonJA, reasonEN)
        lastError = message
        messages.append(
            Inf6PaperChatMessage(
                role: .assistant,
                text: message
            )
        )
    }

    func selectQuickReply(_ reply: Inf6PaperChatQuickReply) {
        let label = reply.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            _surfaceRouteViolation(
                reasonJA: "選択チップのラベルが空です。画面を再読み込みしてください。",
                reasonEN: "The selected chip label is empty. Please reload the screen."
            )
            return
        }
        guard let actionKind = _quickReplyActionKind(for: reply.id) else {
            _surfaceRouteViolation(
                reasonJA: "チップIDを解釈できませんでした。ID=\(reply.id)",
                reasonEN: "Failed to resolve quick-reply id. id=\(reply.id)"
            )
            return
        }
        guard _isActionAllowed(actionKind, at: stage) else {
            _surfaceRouteViolation(
                reasonJA: "現在ステージ（\(stage.rawValue)）では、この操作（\(actionKind.rawValue)）は無効です。",
                reasonEN: "Action \(actionKind.rawValue) is not allowed at current stage \(stage.rawValue)."
            )
            return
        }

        lastError = nil
        isBusy = false
        latestResults = []
        latestVectorScoresByID = [:]
        latestVectorRerankSummary = ""
        latestCurrentPositionSummary = ""
        latestFrontierSummary = ""
        latestFrontierBandByID = [:]
        latestResultClusterLabelByID = [:]
        latestResultClusterRankByID = [:]
        latestResultFeatureKeywordsByID = [:]
        latestResultClassificationSummary = ""
        latestResultClassificationError = nil
        messages.append(Inf6PaperChatMessage(role: .user, text: label))
        _advance(withID: reply.id, label: label)
        _persistProfileSnapshot()
    }

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        inputText = ""

        guard !isBusy else {
            messages.append(
                Inf6PaperChatMessage(
                    role: .assistant,
                    text: _pcLangText(
                        "検索中は入力を受け付けません。完了後に再送してください。",
                        "Input is disabled while searching. Please try again after it completes."
                    )
                )
            )
            return
        }

        lastError = nil
        latestResults = []
        latestVectorScoresByID = [:]
        latestVectorRerankSummary = ""
        latestCurrentPositionSummary = ""
        latestFrontierSummary = ""
        latestFrontierBandByID = [:]
        latestResultClusterLabelByID = [:]
        latestResultClusterRankByID = [:]
        latestResultFeatureKeywordsByID = [:]
        latestResultClassificationSummary = ""
        latestResultClassificationError = nil
        messages.append(Inf6PaperChatMessage(role: .user, text: text))

        guard let manualKind = _manualActionKind(for: stage) else {
            _surfaceRouteViolation(
                reasonJA: "現在ステージ（\(stage.rawValue)）では手入力を受け付けません。",
                reasonEN: "Manual input is not accepted at current stage \(stage.rawValue)."
            )
            return
        }
        guard _isActionAllowed(manualKind, at: stage) else {
            _surfaceRouteViolation(
                reasonJA: "現在ステージ（\(stage.rawValue)）では、この入力操作（\(manualKind.rawValue)）は無効です。",
                reasonEN: "Manual action \(manualKind.rawValue) is not allowed at current stage \(stage.rawValue)."
            )
            return
        }

        switch stage {
        case .askKeywords:
            _advance(withID: "kw.manual", label: text)
        case .askConstraints:
            _advance(withID: "cs.manual", label: text)
        case .readyToSearch:
            _advance(withID: "query.manual", label: text)
        default:
            messages.append(
                Inf6PaperChatMessage(
                    role: .assistant,
                    text: _pcLangText(
                        "このステップは下の候補チップを選択してください。",
                        "Please choose one of the quick reply chips for this step."
                    )
                )
            )
        }

        _persistProfileSnapshot()
    }

    // MARK: - Suggestions

    private func _keywordSuggestions(for domain: String, track: Track, goal: String) -> [String] {
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)

        let wantsImplementation = g.contains("実装") || g.contains("再現") || g.contains("設計")
        let wantsSurvey = g.contains("探") || g.contains("比較") || g.contains("抜け")
        let wantsBasics = g.contains("基礎") || g.contains("理解")
        let wantsEval = g.contains("評価") || g.contains("比較")

        switch domain {
        case "機械学習", "Machine Learning":
            if wantsImplementation { return ["on-device CoreML ANE", "optimization", "training stability", "model compression", "deployment", "なし"] }
            if wantsEval { return ["benchmark", "evaluation", "ablation", "reproducibility", "metrics", "なし"] }
            if wantsBasics { return ["optimization", "generalization", "representation learning", "regularization", "probability", "なし"] }
            if wantsSurvey { return ["survey", "benchmark", "representation learning", "transformer", "diffusion", "なし"] }
            return ["transformer", "diffusion", "reinforcement learning", "optimization", "representation learning", "なし"]

        case "言語", "Language":
            if wantsImplementation { return ["RAG", "retrieval", "prompting", "tool use", "evaluation", "なし"] }
            if wantsEval { return ["evaluation", "benchmark", "hallucination", "faithfulness", "robustness", "なし"] }
            if wantsBasics { return ["language model", "tokenization", "attention", "pretraining", "instruction tuning", "なし"] }
            if wantsSurvey { return ["survey", "LLM", "RAG", "instruction tuning", "evaluation", "なし"] }
            return ["LLM", "retrieval", "prompting", "instruction tuning", "evaluation", "なし"]

        case "画像", "Vision":
            if wantsImplementation { return ["ViT", "diffusion", "self-supervised", "object detection", "segmentation", "なし"] }
            if wantsEval { return ["benchmark", "evaluation", "robustness", "OOD", "metrics", "なし"] }
            if wantsBasics { return ["CNN", "ViT", "representation", "self-supervised", "augmentation", "なし"] }
            if wantsSurvey { return ["survey", "ViT", "diffusion", "object detection", "segmentation", "なし"] }
            return ["object detection", "segmentation", "ViT", "diffusion", "self-supervised", "なし"]

        case "検索", "Retrieval":
            if wantsImplementation { return ["embedding", "vector search", "approximate nearest neighbor", "hybrid retrieval", "RAG", "なし"] }
            if wantsEval { return ["benchmark", "evaluation", "metrics", "reproducibility", "ablation", "なし"] }
            if wantsBasics { return ["BM25", "embedding", "similarity", "approximate nearest neighbor", "index", "なし"] }
            if wantsSurvey { return ["survey", "embedding", "vector search", "hybrid retrieval", "RAG", "なし"] }
            return ["embedding", "vector search", "RAG", "approximate nearest neighbor", "hybrid retrieval", "なし"]

        default:
            switch track {
            case .bioMed: return ["biomedical", "clinical", "dataset", "evaluation", "survey", "なし"]
            case .mathStat: return ["estimation", "hypothesis testing", "bayesian", "optimization", "theory", "なし"]
            case .physicsEess: return ["signal", "measurement", "hardware", "simulation", "experiment", "なし"]
            case .econFin: return ["causal", "forecast", "identification", "estimation", "dataset", "なし"]
            default: return ["survey", "benchmark", "implementation", "theory", "なし"]
            }
        }
    }

    private func _constraintSuggestions(track: Track, goal: String) -> [String] {
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantsImplementation = g.contains("実装") || g.contains("再現") || g.contains("設計")
        let wantsBasics = g.contains("基礎") || g.contains("理解")
        let wantsEval = g.contains("評価") || g.contains("比較")

        var base: [String] = [
            "再現性重視",
            "最新（直近数年）",
            "古典（基礎から）",
            "なし"
        ]

        if wantsImplementation { base.insert(contentsOf: ["端末内（CoreML/ANE）", "実装重視"], at: 0) }
        if wantsBasics { base.insert("数学/前提から", at: 0) }
        if wantsEval { base.insert(contentsOf: ["ベンチマーク重視", "比較（SOTA/既存）"], at: 0) }

        switch track {
        case .bioMed: base.insert("臨床/医療（用語）", at: 0)
        case .econFin: base.insert("因果/同定を優先", at: 0)
        case .physicsEess: base.insert("計測条件/ハード制約", at: 0)
        case .mathStat: base.insert("仮定の強さを優先", at: 0)
        default: break
        }

        var seen = Set<String>()
        var out: [String] = []
        for x in base where !seen.contains(x) {
            seen.insert(x)
            out.append(x)
        }
        return out
    }

    private func _defaultTaskID(forGoal id: String) -> String {
        switch id {
        case "goal.find_papers":
            return "task.find_representative"
        case "goal.understand_paper":
            return "task.read_abstract"
        case "goal.compare_papers":
            return "task.compare_method"
        case "goal.implement":
            return "task.find_repro"
        case "goal.find_gaps":
            return "task.find_gap"
        default:
            return ""
        }
    }

    private func _domainID(forTrack track: Track) -> String {
        switch track {
        case .aiInfo:
            return "domain.ml"
        case .bioMed:
            return "domain.other"
        case .mathStat:
            return "domain.ml"
        case .physicsEess:
            return "domain.other"
        case .econFin:
            return "domain.other"
        case .other:
            return "domain.other"
        }
    }

    private func _recomputeModeFromProfile() {
        switch selectedPersona {
        case .student:
            selectedMode = .study
        case .researcher:
            selectedMode = .research
        case .engineer:
            selectedMode = .work
        }
    }

    private struct _TrackInference {
        let track: Track
        let confident: Bool
    }

    private func _inferTrackFromProfile() -> _TrackInference {
        var scores: [Track: Int] = [
            .aiInfo: 0,
            .bioMed: 0,
            .mathStat: 0,
            .physicsEess: 0,
            .econFin: 0,
            .other: 0
        ]

        let blob = "\(goalText) \(keywordsText) \(constraintsText) \(arxivQueryText)".lowercased()

        func bump(_ track: Track, _ value: Int) {
            scores[track, default: 0] += value
        }

        let aiTerms = ["llm", "machine learning", "deep learning", "rag", "transformer", "ai", "生成", "機械学習", "推論", "埋め込み"]
        let bioTerms = ["bio", "biomedical", "clinical", "medicine", "health", "cancer", "genome", "医", "臨床", "生命", "病理", "薬理"]
        let mathTerms = ["bayesian", "probability", "optimization", "estimation", "statistics", "hypothesis", "数理", "統計", "最適化", "確率"]
        let physicsTerms = ["signal", "hardware", "measurement", "semiconductor", "physics", "electrical", "計測", "電気", "物理", "回路"]
        let econTerms = ["finance", "economics", "causal", "market", "forecast", "portfolio", "経済", "金融", "因果", "市場"]

        for t in aiTerms where blob.contains(t) { bump(.aiInfo, 2) }
        for t in bioTerms where blob.contains(t) { bump(.bioMed, 2) }
        for t in mathTerms where blob.contains(t) { bump(.mathStat, 2) }
        for t in physicsTerms where blob.contains(t) { bump(.physicsEess, 2) }
        for t in econTerms where blob.contains(t) { bump(.econFin, 2) }

        switch selectedContext {
        case .qualification, .lecture, .selfStudy:
            bump(.aiInfo, 1)
        case .researchPrep:
            bump(.aiInfo, 1)
            bump(.bioMed, 1)
            bump(.mathStat, 1)
        case .workPrep:
            bump(.econFin, 1)
            bump(.physicsEess, 1)
        case .none:
            break
        }

        if blob.isEmpty, let saved = _loadDefaultTrackOrNil() {
            bump(saved, 1)
        }

        let sorted = scores.sorted { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key.rawValue < rhs.key.rawValue
            }
            return lhs.value > rhs.value
        }

        guard let top = sorted.first else {
            return _TrackInference(track: .aiInfo, confident: false)
        }
        let second = sorted.dropFirst().first?.value ?? 0
        let isConfident = top.value >= 3 && (top.value - second) >= 2
        return _TrackInference(track: top.key, confident: isConfident)
    }

    private func _searchMaxResults() -> Int {
        switch selectedTimeBudget {
        case .quick15:
            return 8
        case .focused30:
            return 16
        case .deep60:
            return 28
        case .extensive:
            return 40
        }
    }

    private func _displayResultLimit() -> Int {
        12
    }

    private func _isUnderstandPaperGoal() -> Bool {
        goalID == "goal.understand_paper"
    }

    private func _extractArxivIDCandidate(from raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }

        if let u = URL(string: s), !u.lastPathComponent.isEmpty {
            s = u.lastPathComponent
        }

        s = s
            .replacingOccurrences(of: ".pdf", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "arXiv:", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s
    }

    private func _looksLikeArxivID(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let dot = t.firstIndex(of: ".") else { return false }

        let lhs = t[..<dot]
        let rhs = t[t.index(after: dot)...]
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        guard lhs.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return false }

        var i = rhs.startIndex
        var digits = 0
        while i < rhs.endIndex {
            let ch = rhs[i]
            guard ch >= "0" && ch <= "9" else { break }
            digits += 1
            i = rhs.index(after: i)
        }
        guard digits >= 1 else { return false }

        if i < rhs.endIndex {
            guard rhs[i] == "v" else { return false }
            let tail = rhs[rhs.index(after: i)...]
            guard !tail.isEmpty else { return false }
            guard tail.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return false }
        }
        return true
    }

    private func _looksLikePubMedID(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 4 else { return false }
        return t.allSatisfy { $0 >= "0" && $0 <= "9" }
    }

    private func _quotedArxivAllQuery(_ raw: String) -> String {
        let escaped = raw
            .replacingOccurrences(of: "\"", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !escaped.isEmpty else { return "" }
        return "all:(\"\(escaped)\")"
    }

    private func _buildDefaultQueryText() -> String {
        let kws = keywordsText.trimmingCharacters(in: .whitespacesAndNewlines)
        let cst = constraintsText.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSource = _resolvedSourceFromAuto()

        if _isUnderstandPaperGoal() {
            guard !kws.isEmpty else { return "" }

            switch resolvedSource {
            case .arxiv:
                let idCandidate = _extractArxivIDCandidate(from: kws)
                if _looksLikeArxivID(idCandidate) {
                    return "id:\(idCandidate)"
                }
                return _quotedArxivAllQuery(kws)

            case .pubmed:
                if _looksLikePubMedID(kws) {
                    return "\(kws)[PMID]"
                }
                return kws
            case .auto:
                return kws
            case .acl, .isca:
                return kws
            }
        }

        if kws.isEmpty {
            switch resolvedSource {
            case .pubmed:
                switch selectedTrack {
                case .bioMed:
                    return "biomedical OR clinical"
                case .mathStat:
                    return "biostatistics OR causal inference"
                default:
                    return "machine learning OR artificial intelligence"
                }
            case .acl:
                return "large language model dialogue state tracking retrieval"
            case .isca:
                return "speech recognition acoustic model dialect adaptation"
            case .auto:
                switch selectedTrack {
                case .aiInfo:
                    return "machine learning large language model retrieval"
                case .bioMed:
                    return "biomedical machine learning clinical ai"
                case .mathStat:
                    return "statistics optimization causal inference"
                case .physicsEess:
                    return "speech signal processing acoustic model"
                case .econFin:
                    return "econometrics forecasting machine learning"
                case .other:
                    return "artificial intelligence survey benchmark"
                }
            case .arxiv:
                switch selectedTrack {
                case .aiInfo:
                    return "cat:cs.AI OR cat:cs.LG OR cat:stat.ML"
                case .bioMed:
                    return "cat:q-bio.BM OR cat:q-bio.QM OR cat:q-bio.NC"
                case .mathStat:
                    return "cat:math.ST OR cat:stat.TH OR cat:stat.ML"
                case .physicsEess:
                    return "cat:physics.app-ph OR cat:eess.SP OR cat:eess.SY"
                case .econFin:
                    return "cat:q-fin.EC OR cat:q-fin.ST OR cat:econ.EM"
                case .other:
                    return "cat:cs.AI OR cat:cs.LG OR cat:stat.ML"
                }
            }
        }

        let tokens = kws.split(whereSeparator: { $0.isWhitespace }).map(String.init).prefix(10)
        let keywordClause = tokens.map { "\"\($0)\"" }.joined(separator: " OR ")
        switch resolvedSource {
        case .pubmed:
            if cst.isEmpty {
                return keywordClause
            }
            return "(\(keywordClause)) AND \(cst)"
        case .acl, .isca:
            if cst.isEmpty {
                return tokens.joined(separator: " ")
            }
            return "\(tokens.joined(separator: " ")) \(cst)"
        case .auto:
            if cst.isEmpty {
                return tokens.joined(separator: " ")
            }
            return "\(tokens.joined(separator: " ")) \(cst)"
        case .arxiv:
            if cst.isEmpty {
                return "all:(\(keywordClause))"
            }
            return "all:(\(keywordClause)) \(cst)"
        }
    }

    // MARK: - State Machine

    private func _advance(withID id: String, label: String) {
        switch stage {
        case .choosePersona:
            switch id {
            case "persona.student":
                _applyPersonaDefaults(.student)
            case "persona.researcher":
                _applyPersonaDefaults(.researcher)
            case "persona.engineer":
                _applyPersonaDefaults(.engineer)
            default:
                _applyPersonaDefaults(.student)
            }
            stage = .askGoal
            _refreshQuickRepliesForStage()
            messages.append(
                Inf6PaperChatMessage(
                    role: .assistant,
                    text: _pcLangText(
                        "次に、今回の目的を選択してください。",
                        "Next, choose your goal for this session."
                    )
                )
            )

        case .askGoal:
            let normalizedGoalID: String
            switch id {
            case "goal.find_papers", "goal.understand_paper", "goal.compare_papers", "goal.implement", "goal.find_gaps":
                normalizedGoalID = id
            default:
                normalizedGoalID = "goal.find_papers"
            }

            _setGoal(id: normalizedGoalID)
            _setTask(id: _defaultTaskID(forGoal: normalizedGoalID))
            _recomputeModeFromProfile()
            selectedSource = .auto
            keywordsText = ""
            constraintsText = ""
            arxivQueryText = ""
            stage = .chooseTimeBudget
            _refreshQuickRepliesForStage()
            messages.append(
                Inf6PaperChatMessage(
                    role: .assistant,
                    text: _pcLangText(
                        "次に、今回使える時間を選択してください。",
                        "Next, choose how much time you can spend in this run."
                    )
                )
            )

        case .chooseTimeBudget:
            switch id {
            case "time.quick15": selectedTimeBudget = .quick15
            case "time.focused30": selectedTimeBudget = .focused30
            case "time.deep60": selectedTimeBudget = .deep60
            case "time.extensive": selectedTimeBudget = .extensive
            default: selectedTimeBudget = .focused30
            }
            stage = .chooseContext
            _refreshQuickRepliesForStage()
            messages.append(
                Inf6PaperChatMessage(
                    role: .assistant,
                    text: _pcLangText(
                        "次に、今回の利用文脈を選択してください。",
                        "Next, choose the context for this session."
                    )
                )
            )

        case .chooseContext:
            switch id {
            case "context.qualification": selectedContext = .qualification
            case "context.lecture": selectedContext = .lecture
            case "context.selfStudy": selectedContext = .selfStudy
            case "context.researchPrep": selectedContext = .researchPrep
            case "context.workPrep": selectedContext = .workPrep
            case "context.none": selectedContext = .none
            default: selectedContext = .none
            }
            assessmentPreference = (selectedContext == .qualification) ? .enabled : .skipped
            _recomputeModeFromProfile()
            if _isUnderstandPaperGoal() {
                stage = .askKeywords
                _refreshQuickRepliesForStage()
                messages.append(
                    Inf6PaperChatMessage(
                        role: .assistant,
                        text: _pcLangText(
                            "対象論文の arXiv ID / URL / タイトルを入力してください。",
                            "Enter target paper arXiv ID / URL / title."
                        )
                    )
                )
            } else {
                stage = .chooseTrack
                _refreshQuickRepliesForStage()
                messages.append(
                    Inf6PaperChatMessage(
                        role: .assistant,
                        text: _pcLangText(
                            "次に、分野（系）を選択してください。",
                            "Next, choose your field track."
                        )
                    )
                )
            }

        case .askKeywords:
            if id == "kw.none" {
                keywordsText = ""
            } else {
                keywordsText = label
            }
            if _isUnderstandPaperGoal() {
                let normalized = keywordsText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else {
                    messages.append(
                        Inf6PaperChatMessage(
                            role: .assistant,
                            text: _pcLangText(
                                "対象論文の ID / URL / タイトルが空です。入力して続行してください。",
                                "Target paper ID / URL / title is empty. Please enter one."
                            )
                        )
                    )
                    _refreshQuickRepliesForStage()
                    return
                }
                arxivQueryText = _buildDefaultQueryText()
                stage = .chooseSource
                _refreshQuickRepliesForStage()
                messages.append(
                    Inf6PaperChatMessage(
                        role: .assistant,
                        text: """
                        \(_pcLangText("対象論文向けの検索式を生成しました。次に検索ソースを選択してください。", "Built query for the target paper. Next, choose search source."))
                        \(_pcLangText("検索式:", "Query:"))
                        \(arxivQueryText)
                        """
                    )
                )
            } else {
                stage = .askConstraints
                _refreshQuickRepliesForStage()
                messages.append(
                    Inf6PaperChatMessage(
                        role: .assistant,
                        text: _pcLangText(
                            "次に、優先したい制約を選択（または入力）してください。",
                            "Next, select or type the constraint you want to prioritize."
                        )
                    )
                )
            }

        case .askConstraints:
            if id == "cs.none" {
                constraintsText = ""
            } else {
                constraintsText = label
            }

            stage = .chooseSource
            _refreshQuickRepliesForStage()
            messages.append(
                Inf6PaperChatMessage(
                    role: .assistant,
                    text: _pcLangText(
                        "次に、検索ソースを選択してください。",
                        "Next, choose search source."
                    )
                )
            )

        case .chooseTrack:
            switch id {
            case "track.aiInfo": selectedTrack = .aiInfo
            case "track.bioMed": selectedTrack = .bioMed
            case "track.mathStat": selectedTrack = .mathStat
            case "track.physicsEess": selectedTrack = .physicsEess
            case "track.econFin": selectedTrack = .econFin
            case "track.other": selectedTrack = .other
            default: selectedTrack = .aiInfo
            }
            _persistDefaultTrack(selectedTrack)
            _setDomain(id: _domainID(forTrack: selectedTrack))
            selectedSource = .auto
            stage = .chooseOrientation
            _refreshQuickRepliesForStage()
            messages.append(
                Inf6PaperChatMessage(
                    role: .assistant,
                    text: _pcLangText(
                        "次に、読むときの軸（基礎/応用/理論/実装）を選択してください。",
                        "Next, choose reading orientation (foundation/applied/theory/implementation)."
                    )
                )
            )

        case .chooseOrientation:
            switch id {
            case "orientation.foundation": selectedOrientation = .foundation
            case "orientation.applied": selectedOrientation = .applied
            case "orientation.theory": selectedOrientation = .theory
            case "orientation.implementation": selectedOrientation = .implementation
            default: selectedOrientation = .foundation
            }
            stage = .askKeywords
            _refreshQuickRepliesForStage()
            messages.append(
                Inf6PaperChatMessage(
                    role: .assistant,
                    text: _pcLangText(
                        "次に、検索の軸となるキーワードを選択（または入力）してください。",
                        "Next, select or type the core search keyword."
                    )
                )
            )

        case .chooseSource:
            switch id {
            case "source.auto": selectedSource = .auto
            case "source.arxiv": selectedSource = .arxiv
            case "source.pubmed": selectedSource = .pubmed
            case "source.acl": selectedSource = .acl
            case "source.isca": selectedSource = .isca
            default: selectedSource = .auto
            }
            stage = .confirmQuery
            _refreshQuickRepliesForStage()

            let taskText = _labelForTask(taskID)
            messages.append(
                Inf6PaperChatMessage(
                    role: .assistant,
                    text: """
                    \(_pcLangText("ここまでのプロファイル:", "Profile so far:"))
                    - \(_pcLangText("目的", "Goal")): \(goalText)
                    - \(_pcLangText("文脈", "Context")): \(_labelForContext(selectedContext))
                    - \(_pcLangText("系", "Track")): \(_trackLabel(selectedTrack))
                    - \(_pcLangText("ソース", "Source")): \(_labelForSource(selectedSource))
                    - \(_pcLangText("タスク", "Task")): \(taskText.isEmpty ? _pcLangText("(未設定)", "(unset)") : taskText)
                    - \(_pcLangText("キーワード", "Keyword")): \(keywordsText.isEmpty ? _pcLangText("(なし)", "(none)") : keywordsText)
                    - \(_pcLangText("制約", "Constraint")): \(constraintsText.isEmpty ? _pcLangText("(なし)", "(none)") : constraintsText)

                    \(_pcLangText("検索式を生成して確定してください。", "Generate and confirm the search query."))
                    """
                )
            )

        case .confirmQuery:
            if id == "confirm.auto" {
                arxivQueryText = _buildDefaultQueryText()
                stage = .readyToSearch
                _refreshQuickRepliesForStage()
                messages.append(
                    Inf6PaperChatMessage(
                        role: .assistant,
                        text: """
                        \(_pcLangText("検索式を確定しました。内容を確認し、『検索を開始』を押してください。", "Query confirmed. Review it, then press 'Start search'."))
                        \(_pcLangText("使用する検索式:", "Query:"))
                        \(arxivQueryText)
                        """
                    )
                )
            } else {
                _refreshQuickRepliesForStage()
                messages.append(
                    Inf6PaperChatMessage(
                        role: .assistant,
                        text: _pcLangText("検索式はボタンで確定してください。", "Confirm the query using the button.")
                    )
                )
            }

        case .readyToSearch:
            if id == "action.search" {
                Task { await self._runSurvey() }
            } else {
                arxivQueryText = label
                _persistProfileSnapshot()
                messages.append(
                    Inf6PaperChatMessage(
                        role: .assistant,
                        text: """
                        \(_pcLangText("検索式を更新し、検索を実行します。", "Query updated. Running search now."))
                        \(arxivQueryText)
                        """
                    )
                )
                Task { await self._runSurvey() }
            }
        }

        _persistProfileSnapshot()
    }

    // MARK: - Colors

    private func _currentTrackTint() -> Color {
        switch selectedTrack {
        case .aiInfo: return Color.accentColor
        case .bioMed: return Color.pink
        case .mathStat: return Color.indigo
        case .physicsEess: return Color.orange
        case .econFin: return Color.green
        case .other: return Color.gray
        }
    }

    func quickReplyTint(_ reply: Inf6PaperChatQuickReply) -> Color {
        switch reply.id {
        case "persona.student": return Color.accentColor
        case "persona.researcher": return Color.purple
        case "persona.engineer": return Color.green
        case "action.search": return Color.accentColor
        case "confirm.auto": return Color.accentColor
        case "source.auto": return Color.accentColor
        case "source.arxiv": return Color.accentColor
        case "source.pubmed": return Color.pink
        default: break
        }

        if stage == .chooseTrack {
            switch reply.id {
            case "track.aiInfo": return Color.accentColor
            case "track.bioMed": return Color.pink
            case "track.mathStat": return Color.indigo
            case "track.physicsEess": return Color.orange
            case "track.econFin": return Color.green
            case "track.other": return Color.gray
            default: return Color.secondary
            }
        }
        return _currentTrackTint()
    }

    // MARK: - Query Building (domainID-based)

    private func _arxivCategoryClause(forDomainID domainID: String) -> String {
        switch domainID {
        case "domain.lang":
            return "cat:cs.CL"
        case "domain.vision":
            return "cat:cs.CV"
        case "domain.retrieval":
            return "cat:cs.IR"
        case "domain.ml":
            return "cat:cs.LG OR cat:stat.ML OR cat:cs.AI"
        default:
            return "cat:cs.AI OR cat:cs.LG OR cat:stat.ML"
        }
    }

    private func _profileSearchAugmentString() -> String {
        var tokens: [String] = []

        switch goalID {
        case "goal.find_papers":
            tokens.append("survey")
        case "goal.compare_papers":
            tokens.append("comparison")
        case "goal.implement":
            tokens.append(contentsOf: ["implementation", "reproducibility"])
        case "goal.find_gaps":
            tokens.append(contentsOf: ["survey", "benchmark"])
        default:
            break
        }

        switch taskID {
        case "task.find_intro":
            tokens.append("survey")
        case "task.find_representative":
            tokens.append("benchmark")
        case "task.read_figure":
            tokens.append("architecture")
        case "task.read_formula":
            tokens.append("optimization")
        case "task.compare_method":
            tokens.append("method")
        case "task.compare_metric":
            tokens.append("evaluation")
        case "task.compare_assumption":
            tokens.append("assumption")
        case "task.find_repro":
            tokens.append(contentsOf: ["implementation", "reproducibility"])
        case "task.find_benchmark":
            tokens.append("benchmark")
        case "task.find_gap":
            tokens.append("survey")
        case "task.find_conflict":
            tokens.append("evaluation")
        default:
            break
        }

        if constraintsText.contains("再現") {
            tokens.append("reproducibility")
        }
        if constraintsText.contains("ベンチ") {
            tokens.append("benchmark")
        }

        var seen = Set<String>()
        let deduped = tokens.filter { seen.insert($0).inserted }
        return deduped.joined(separator: " ")
    }

    private enum _ProfileKeyBackend: String {
        case gpt
    }

    private struct _ProfileKeyBuildResult {
        let text: String
        let queryAugment: String
        let backend: _ProfileKeyBackend
        let detail: String
    }

    private struct _DistilledProfileKey {
        let profileKey: String
        let queryTerms: String
        let excludeTerms: String
    }

    private func _recentDialogueExcerpt(maxTurns: Int = 8, maxChars: Int = 2400) -> String {
        guard maxTurns > 0, maxChars > 0 else { return "" }
        var out: [String] = []
        out.reserveCapacity(maxTurns)

        for m in messages.reversed() {
            guard out.count < maxTurns else { break }
            let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }

            let role: String
            switch m.role {
            case .user: role = "user"
            case .assistant: role = "assistant"
            case .system: role = "system"
            }
            out.append("\(role): \(t)")
        }

        if out.isEmpty { return "" }
        let joined = out.reversed().joined(separator: "\n")
        if joined.count <= maxChars { return joined }
        return String(joined.suffix(maxChars))
    }

    private func _countRecentUserTurns(maxTurns: Int = 12) -> Int {
        var n = 0
        for m in messages.reversed() {
            guard n < maxTurns else { break }
            guard m.role == .user else { continue }
            let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            n += 1
        }
        return n
    }

    private func _extractTag(_ tag: String, from text: String) -> String? {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard let r1 = text.range(of: open), let r2 = text.range(of: close), r1.upperBound <= r2.lowerBound else {
            return nil
        }
        let body = text[r1.upperBound..<r2.lowerBound]
        let s = String(body).trimmingCharacters(in: .whitespacesAndNewlines)
        return s
    }

    private func _parseDistilledProfileKey(_ text: String) throws -> _DistilledProfileKey {
        let profile = _extractTag("profile_key", from: text)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !profile.isEmpty else {
            throw NSError(
                domain: "inf6.paperchat.profilekey",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "GPT profile key parse failed (profile_key is empty)."]
            )
        }
        let queryTerms = _extractTag("query_terms", from: text)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let excludeTerms = _extractTag("exclude_terms", from: text)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return _DistilledProfileKey(
            profileKey: profile,
            queryTerms: queryTerms,
            excludeTerms: excludeTerms
        )
    }

    private func _mergeSearchQuery(base: String, augment: String) -> String {
        let b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = augment.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return "\(b) \(a)"
    }

    private func _resolveOpenAIProfileKeyClientOrThrow() throws -> (client: OpenAIClient, model: String) {
        let key = try OpenAIKeyStore.load()
        let model = Inf6OpenAIModelResolver.resolvedModel()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw NSError(
                domain: "inf6.paperchat.profilekey",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI model is not configured."]
            )
        }

        let cfg = try OpenAIClient.Config.default(model: model)
        return (OpenAIClient(apiKey: key, config: cfg), model)
    }

    private func _buildProfileSearchKeyText(query: String, effectiveQuery: String) async throws -> _ProfileKeyBuildResult {
        let userTurnCount = _countRecentUserTurns()
        guard userTurnCount > 0 else {
            throw NSError(
                domain: "inf6.paperchat.profilekey",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: _pcLangText("対話が不足しています。検索意図を1つ入力してください。", "Dialogue is insufficient. Please enter your search intent.")]
            )
        }

        let dialogue = _recentDialogueExcerpt()
        guard !dialogue.isEmpty else {
            throw NSError(
                domain: "inf6.paperchat.profilekey",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: _pcLangText("対話ログを取得できませんでした。", "Dialogue log is unavailable.")]
            )
        }

        let resolved = try _resolveOpenAIProfileKeyClientOrThrow()
        let client = resolved.client
        let model = resolved.model

        let renderedProfileKey = try Inf6PromptGovernance.renderSystemUserPrompt(
            ref: Inf6PromptCatalog.paperChatProfileKey,
            variables: [
                "profile_text": generatedProfileText,
                "raw_query": query,
                "effective_query": effectiveQuery,
                "dialogue": dialogue
            ]
        )

        let output = try await client.generateText(
            messages: [
                OpenAIClient.InputMessage(role: .system, text: renderedProfileKey.systemInstruction),
                OpenAIClient.InputMessage(role: .user, text: renderedProfileKey.userPrompt)
            ],
            options: .init(maxOutputTokens: 260, modelOverride: nil)
        )
        let parsed = try _parseDistilledProfileKey(output)
        let merged = """
        \(generatedProfileText)
        query: \(effectiveQuery)
        dialogue_profile_key:
        \(parsed.profileKey)
        """
        var summary = _pcLangText(
            "GPTキー生成: model=\(model), userTurns=\(userTurnCount)",
            "GPT key generated: model=\(model), userTurns=\(userTurnCount)"
        )
        if !parsed.excludeTerms.isEmpty {
            summary += _pcLangText(
                ", 除外候補=\(parsed.excludeTerms)",
                ", exclude=\(parsed.excludeTerms)"
            )
        }
        return _ProfileKeyBuildResult(
            text: merged,
            queryAugment: parsed.queryTerms,
            backend: .gpt,
            detail: summary
        )
    }

    private enum _FrontierBand: String {
        case bridge
        case core
        case frontier
    }

    private func _currentPositionSummaryText() -> String {
        let persona = _labelForPersona(selectedPersona)
        if _isUnderstandPaperGoal() {
            return _pcLangText(
                "現在地: \(persona) / 対象論文理解",
                "Current position: \(persona) / Target-paper understanding"
            )
        }
        let track = _trackLabel(selectedTrack)
        return _pcLangText(
            "現在地: \(persona) / \(track)",
            "Current position: \(persona) / \(track)"
        )
    }

    private func _frontierBandLabel(_ band: _FrontierBand) -> String {
        switch band {
        case .bridge:
            return _pcLangText("橋渡し", "Bridge")
        case .core:
            return _pcLangText("境界中核", "Core Frontier")
        case .frontier:
            return _pcLangText("前線", "Frontier")
        }
    }

    private func _frontierPlanFromRankedResults(
        _ ranked: [Inf6PaperSearchResult],
        scoresByID: [String: Float]
    ) -> (ordered: [Inf6PaperSearchResult], bandByID: [String: String], knownExcluded: Int, summary: String) {
        guard !ranked.isEmpty else {
            return ([], [:], 0, "")
        }

        var scored: [(result: Inf6PaperSearchResult, score: Float)] = []
        var unscored: [Inf6PaperSearchResult] = []
        scored.reserveCapacity(ranked.count)
        unscored.reserveCapacity(ranked.count)

        for r in ranked {
            if let s = scoresByID[r.id] {
                scored.append((r, s))
            } else {
                unscored.append(r)
            }
        }

        guard !scored.isEmpty else {
            // Vector score unavailable: keep retrieval/rerank order as-is.
            return (
                Array(ranked.prefix(_displayResultLimit())),
                [:],
                0,
                _pcLangText("境界推定: ベクトル得点が不足のため順序のみ適用", "Frontier estimate: score unavailable, using ranked order")
            )
        }

        let minScore = scored.map(\.score).min() ?? 0
        let maxScore = scored.map(\.score).max() ?? 1
        let span = max(0.0001, maxScore - minScore)

        func familiarity(_ s: Float) -> Float {
            let x = (s - minScore) / span
            return max(0, min(1, x))
        }

        // High familiarity is treated as likely-known and excluded from immediate reading queue.
        let knownThreshold: Float = 0.84

        var knownExcluded = 0
        var bridge: [(Inf6PaperSearchResult, Float)] = []
        var core: [(Inf6PaperSearchResult, Float)] = []
        var frontier: [(Inf6PaperSearchResult, Float)] = []

        for p in scored {
            let f = familiarity(p.score)
            if f >= knownThreshold {
                knownExcluded += 1
                continue
            }
            if f >= 0.58 {
                bridge.append((p.result, f))
            } else if f >= 0.34 {
                core.append((p.result, f))
            } else {
                frontier.append((p.result, f))
            }
        }

        bridge.sort { $0.1 > $1.1 }     // closest to known boundary first
        core.sort { $0.1 > $1.1 }       // then middle frontier
        frontier.sort { $0.1 < $1.1 }   // then far frontier (novelty-heavy)

        var bandByID: [String: String] = [:]
        var ordered: [Inf6PaperSearchResult] = []

        for p in bridge {
            ordered.append(p.0)
            bandByID[p.0.id] = _FrontierBand.bridge.rawValue
        }
        for p in core {
            ordered.append(p.0)
            bandByID[p.0.id] = _FrontierBand.core.rawValue
        }
        for p in frontier {
            ordered.append(p.0)
            bandByID[p.0.id] = _FrontierBand.frontier.rawValue
        }
        for r in unscored {
            ordered.append(r)
            bandByID[r.id] = _FrontierBand.frontier.rawValue
        }

        if ordered.isEmpty {
            ordered = ranked
        }

        ordered = Array(ordered.prefix(_displayResultLimit()))

        let bridgeCount = ordered.filter { bandByID[$0.id] == _FrontierBand.bridge.rawValue }.count
        let coreCount = ordered.filter { bandByID[$0.id] == _FrontierBand.core.rawValue }.count
        let frontierCount = ordered.filter { bandByID[$0.id] == _FrontierBand.frontier.rawValue }.count

        let summary = _pcLangText(
            "境界計画: \( _frontierBandLabel(.bridge) ) \(bridgeCount)件 / \( _frontierBandLabel(.core) ) \(coreCount)件 / \( _frontierBandLabel(.frontier) ) \(frontierCount)件 / 既知除外 \(knownExcluded)件",
            "Frontier plan: \( _frontierBandLabel(.bridge) ) \(bridgeCount), \( _frontierBandLabel(.core) ) \(coreCount), \( _frontierBandLabel(.frontier) ) \(frontierCount), known-excluded \(knownExcluded)"
        )

        return (ordered, bandByID, knownExcluded, summary)
    }

    private struct _SurveyResultEmbeddingRow {
        let id: String
        let title: String
        let abstractText: String
        let vector: [Float]
    }

    private struct _SurveyResultClassificationOutcome {
        let labelByID: [String: String]
        let rankByID: [String: Int]
        let featureKeywordsByID: [String: [String]]
        let summary: String
    }

    private struct _SurveyClusterLabelItem: Codable {
        let clusterID: String
        let label: String

        private enum CodingKeys: String, CodingKey {
            case clusterID = "cluster_id"
            case label
        }
    }

    private struct _SurveyClusterLabelResponse: Codable {
        let items: [_SurveyClusterLabelItem]
    }

    private struct _SurveyFeatureKeywordItem: Codable {
        let docID: String
        let keywords: [String]

        private enum CodingKeys: String, CodingKey {
            case docID = "doc_id"
            case keywords
        }
    }

    private struct _SurveyFeatureKeywordResponse: Codable {
        let items: [_SurveyFeatureKeywordItem]
    }

    private var _surveyUseJapaneseOutput: Bool {
        _pcLangText("ja", "en") == "ja"
    }

    private func _surveyContainsJapaneseCharacters(_ text: String) -> Bool {
        text.range(of: #"[ぁ-んァ-ヶ一-龯]"#, options: .regularExpression) != nil
    }

    private func _surveySplitCamelCase(_ text: String) -> String {
        if text.isEmpty { return text }
        let firstPass = text.replacingOccurrences(
            of: "([a-z0-9])([A-Z])",
            with: "$1 $2",
            options: .regularExpression
        )
        let secondPass = firstPass.replacingOccurrences(
            of: "([A-Z])([A-Z][a-z])",
            with: "$1 $2",
            options: .regularExpression
        )
        return secondPass
    }

    private func _surveyNormalizedKeyword(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        let deCamelized = _surveySplitCamelCase(trimmed)
        let lower = deCamelized.lowercased()
        let parts = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let cleaned = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if cleaned.isEmpty { return lower }
        return cleaned.joined(separator: " ")
    }

    private func _surveyDecodeClusterLabelResponseOrThrow(_ raw: String) throws -> _SurveyClusterLabelResponse {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "inf6.paperchat.classification",
                code: -110,
                userInfo: [NSLocalizedDescriptionKey: _pcLangText("分類レスポンスが空です。", "Classification response is empty.")]
            )
        }

        let candidates: [String] = {
            if trimmed.first == "{", trimmed.last == "}" { return [trimmed] }
            if let s = trimmed.firstIndex(of: "{"), let e = trimmed.lastIndex(of: "}"), s < e {
                return [String(trimmed[s...e])]
            }
            return [trimmed]
        }()

        for c in candidates {
            guard let data = c.data(using: .utf8) else { continue }
            if let parsed = try? JSONDecoder().decode(_SurveyClusterLabelResponse.self, from: data) {
                return parsed
            }
        }

        throw NSError(
            domain: "inf6.paperchat.classification",
            code: -111,
            userInfo: [NSLocalizedDescriptionKey: _pcLangText("分類レスポンスのJSON解析に失敗しました。", "Failed to parse classification JSON.")]
        )
    }

    private func _surveyDecodeFeatureKeywordResponseOrThrow(_ raw: String) throws -> _SurveyFeatureKeywordResponse {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "inf6.paperchat.classification",
                code: -112,
                userInfo: [NSLocalizedDescriptionKey: _pcLangText("特徴語レスポンスが空です。", "Feature keyword response is empty.")]
            )
        }

        let candidates: [String] = {
            if trimmed.first == "{", trimmed.last == "}" { return [trimmed] }
            if let s = trimmed.firstIndex(of: "{"), let e = trimmed.lastIndex(of: "}"), s < e {
                return [String(trimmed[s...e])]
            }
            return [trimmed]
        }()

        for c in candidates {
            guard let data = c.data(using: .utf8) else { continue }
            if let parsed = try? JSONDecoder().decode(_SurveyFeatureKeywordResponse.self, from: data) {
                return parsed
            }
        }

        throw NSError(
            domain: "inf6.paperchat.classification",
            code: -113,
            userInfo: [NSLocalizedDescriptionKey: _pcLangText("特徴語レスポンスのJSON解析に失敗しました。", "Failed to parse feature keyword JSON.")]
        )
    }

    private func _surveyClusterCount(totalCount: Int) -> Int {
        if totalCount <= 1 { return 1 }
        if totalCount <= 6 { return 2 }
        if totalCount <= 12 { return 3 }
        return min(6, max(3, Int(round(sqrt(Double(totalCount))))))
    }

    private func _surveyKMeansClusterByID(rows: [_SurveyResultEmbeddingRow], clusterCount: Int) throws -> [String: Int] {
        guard !rows.isEmpty else { return [:] }
        let dimension = rows[0].vector.count
        guard dimension > 0 else {
            throw NSError(
                domain: "inf6.paperchat.classification",
                code: -114,
                userInfo: [NSLocalizedDescriptionKey: _pcLangText("埋め込み次元が不正です。", "Invalid embedding dimension.")]
            )
        }
        guard rows.allSatisfy({ $0.vector.count == dimension }) else {
            throw NSError(
                domain: "inf6.paperchat.classification",
                code: -115,
                userInfo: [NSLocalizedDescriptionKey: _pcLangText("埋め込み次元が一致しません。", "Embedding dimensions are inconsistent.")]
            )
        }

        let k = max(1, min(clusterCount, rows.count))
        var centerIndices: [Int] = [0]
        centerIndices.reserveCapacity(k)

        while centerIndices.count < k {
            let selected = Set(centerIndices)
            var bestCandidate = -1
            var bestDistance = -Float.greatestFiniteMagnitude

            for i in rows.indices where !selected.contains(i) {
                var minDistanceToCenters = Float.greatestFiniteMagnitude
                for c in centerIndices {
                    let sim = Inf6VectorMath.cosine(rows[i].vector, rows[c].vector)
                    let distance = 1 - sim
                    if distance < minDistanceToCenters {
                        minDistanceToCenters = distance
                    }
                }
                if minDistanceToCenters > bestDistance {
                    bestDistance = minDistanceToCenters
                    bestCandidate = i
                }
            }

            guard bestCandidate >= 0 else { break }
            centerIndices.append(bestCandidate)
        }

        while centerIndices.count < k {
            centerIndices.append(0)
        }

        var centers = centerIndices.map { rows[$0].vector }
        var assignments = Array(repeating: 0, count: rows.count)
        var changed = true
        var iterations = 0
        let maxIterations = 16

        while changed && iterations < maxIterations {
            changed = false
            iterations += 1

            for i in rows.indices {
                var bestCluster = 0
                var bestScore = -Float.greatestFiniteMagnitude
                for c in centers.indices {
                    let score = Inf6VectorMath.cosine(rows[i].vector, centers[c])
                    if score > bestScore {
                        bestScore = score
                        bestCluster = c
                    }
                }
                if assignments[i] != bestCluster {
                    assignments[i] = bestCluster
                    changed = true
                }
            }

            var sums = Array(repeating: Array(repeating: Float(0), count: dimension), count: centers.count)
            var counts = Array(repeating: 0, count: centers.count)

            for i in rows.indices {
                let c = assignments[i]
                counts[c] += 1
                for d in 0..<dimension {
                    sums[c][d] += rows[i].vector[d]
                }
            }

            for c in centers.indices {
                guard counts[c] > 0 else { continue }
                let inv = Float(1.0 / Double(counts[c]))
                var avg = sums[c].map { $0 * inv }
                avg = Inf6VectorMath.normalizeL2(avg)
                centers[c] = avg
            }
        }

        var clusterByID: [String: Int] = [:]
        clusterByID.reserveCapacity(rows.count)
        for (idx, row) in rows.enumerated() {
            clusterByID[row.id] = assignments[idx]
        }
        return clusterByID
    }

    private func _surveyClassifyClusterLabelsByLLMOrThrow(
        rowsByCluster: [Int: [_SurveyResultEmbeddingRow]],
        apiKey: String,
        model: String
    ) async throws -> [Int: String] {
        if rowsByCluster.isEmpty { return [:] }

        let sortedClusterIDs = rowsByCluster.keys.sorted()
        var payload: [[String: Any]] = []
        payload.reserveCapacity(sortedClusterIDs.count)

        for cid in sortedClusterIDs {
            let rows = rowsByCluster[cid] ?? []
            let papers = rows.prefix(8).map { row -> [String: Any] in
                var obj: [String: Any] = ["title": row.title]
                if !row.abstractText.isEmpty {
                    obj["abstract"] = String(row.abstractText.prefix(420))
                }
                return obj
            }
            payload.append([
                "cluster_id": "C\(cid)",
                "size": rows.count,
                "papers": papers
            ])
        }

        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let payloadText = String(data: payloadData, encoding: .utf8) else {
            throw NSError(
                domain: "inf6.paperchat.classification",
                code: -116,
                userInfo: [NSLocalizedDescriptionKey: _pcLangText("分類入力のJSON化に失敗しました。", "Failed to encode classification input.")]
            )
        }

        let outputLanguage = _surveyUseJapaneseOutput ? "日本語" : "English"
        let renderedCluster = try Inf6PromptGovernance.renderSystemUserPrompt(
            ref: Inf6PromptCatalog.paperChatSurveyClusterLabel,
            variables: [
                "output_language": outputLanguage,
                "payload_json": payloadText
            ]
        )

        let client = OpenAIClient(
            apiKey: apiKey,
            config: try OpenAIClient.Config.default(model: model)
        )
        let raw = try await client.generateText(
            messages: [
                OpenAIClient.InputMessage(role: .system, text: renderedCluster.systemInstruction),
                OpenAIClient.InputMessage(role: .user, text: renderedCluster.userPrompt)
            ],
            options: .init(maxOutputTokens: 1200)
        )

        let response = try _surveyDecodeClusterLabelResponseOrThrow(raw)
        var clusterTokenToID: [String: Int] = [:]
        clusterTokenToID.reserveCapacity(sortedClusterIDs.count)
        for cid in sortedClusterIDs {
            clusterTokenToID["C\(cid)"] = cid
        }

        var labelByCluster: [Int: String] = [:]
        labelByCluster.reserveCapacity(sortedClusterIDs.count)

        for item in response.items {
            let token = item.clusterID.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, !label.isEmpty else { continue }
            guard let cid = clusterTokenToID[token] else { continue }
            labelByCluster[cid] = label
        }

        for cid in sortedClusterIDs where labelByCluster[cid] == nil {
            throw NSError(
                domain: "inf6.paperchat.classification",
                code: -117,
                userInfo: [NSLocalizedDescriptionKey: _pcLangText("分類ラベルが不足しています。", "Classification labels are incomplete.")]
            )
        }
        return labelByCluster
    }

    private func _surveyNormalizeFeatureKeywords(_ keywords: [String], maxCount: Int) -> [String] {
        let limit = max(1, maxCount)
        var out: [String] = []
        out.reserveCapacity(limit)
        var seen: Set<String> = []

        for raw in keywords {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if _surveyUseJapaneseOutput && !_surveyContainsJapaneseCharacters(trimmed) { continue }

            let normalizedKey = _surveyNormalizedKeyword(trimmed)
            if normalizedKey.isEmpty { continue }
            if !seen.insert(normalizedKey).inserted { continue }

            out.append(trimmed)
            if out.count >= limit { break }
        }
        return out
    }

    private func _surveyExtractFeatureKeywordsByLLMOrThrow(
        rows: [_SurveyResultEmbeddingRow],
        apiKey: String,
        model: String
    ) async throws -> [String: [String]] {
        if rows.isEmpty { return [:] }

        let outputLanguage = _surveyUseJapaneseOutput ? "日本語" : "English"
        let client = OpenAIClient(
            apiKey: apiKey,
            config: try OpenAIClient.Config.default(model: model)
        )

        var keywordsByID: [String: [String]] = [:]
        keywordsByID.reserveCapacity(rows.count)

        let batchSize = 12
        var start = 0
        while start < rows.count {
            let end = min(start + batchSize, rows.count)
            let batch = Array(rows[start..<end])
            var payload: [[String: Any]] = []
            payload.reserveCapacity(batch.count)

            for row in batch {
                var one: [String: Any] = [
                    "doc_id": row.id,
                    "title": row.title
                ]
                if !row.abstractText.isEmpty {
                    one["abstract"] = String(row.abstractText.prefix(520))
                }
                payload.append(one)
            }

            let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            guard let payloadText = String(data: payloadData, encoding: .utf8) else {
                throw NSError(
                    domain: "inf6.paperchat.classification",
                    code: -118,
                    userInfo: [NSLocalizedDescriptionKey: _pcLangText("特徴語入力のJSON化に失敗しました。", "Failed to encode feature keyword input.")]
                )
            }

            let renderedKeywords = try Inf6PromptGovernance.renderSystemUserPrompt(
                ref: Inf6PromptCatalog.paperChatSurveyFeatureKeywords,
                variables: [
                    "output_language": outputLanguage,
                    "payload_json": payloadText
                ]
            )

            let raw = try await client.generateText(
                messages: [
                    OpenAIClient.InputMessage(role: .system, text: renderedKeywords.systemInstruction),
                    OpenAIClient.InputMessage(role: .user, text: renderedKeywords.userPrompt)
                ],
                options: .init(maxOutputTokens: 1600)
            )

            let response = try _surveyDecodeFeatureKeywordResponseOrThrow(raw)
            var returnedIDs: Set<String> = []
            returnedIDs.reserveCapacity(batch.count)

            for item in response.items {
                let docID = item.docID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !docID.isEmpty else { continue }
                let normalized = _surveyNormalizeFeatureKeywords(item.keywords, maxCount: 5)
                keywordsByID[docID] = normalized
                returnedIDs.insert(docID)
            }

            for row in batch where !returnedIDs.contains(row.id) {
                keywordsByID[row.id] = []
            }

            start = end
        }

        var documentFrequency: [String: Int] = [:]
        documentFrequency.reserveCapacity(rows.count * 4)

        for keywords in keywordsByID.values {
            let unique = Set(
                keywords
                    .map { _surveyNormalizedKeyword($0) }
                    .filter { !$0.isEmpty }
            )
            for key in unique {
                documentFrequency[key, default: 0] += 1
            }
        }

        let corpusCount = max(rows.count, 1)
        let genericThreshold = max(3, Int(ceil(Double(corpusCount) * 0.35)))
        var prunedByID: [String: [String]] = [:]
        prunedByID.reserveCapacity(rows.count)

        for row in rows {
            let raw = keywordsByID[row.id] ?? []
            let filtered = raw.filter { kw in
                let key = _surveyNormalizedKeyword(kw)
                if key.isEmpty { return false }
                return (documentFrequency[key] ?? 0) < genericThreshold
            }
            prunedByID[row.id] = filtered
        }

        return prunedByID
    }

    private func _classifySearchResultsByLLMOrThrow(
        results: [Inf6PaperSearchResult]
    ) async throws -> _SurveyResultClassificationOutcome {
        if results.isEmpty {
            return _SurveyResultClassificationOutcome(
                labelByID: [:],
                rankByID: [:],
                featureKeywordsByID: [:],
                summary: ""
            )
        }

        let key = try OpenAIKeyStore.load().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw NSError(
                domain: "inf6.paperchat.classification",
                code: -119,
                userInfo: [NSLocalizedDescriptionKey: _pcLangText("分類には OpenAI API キー設定が必要です。", "OpenAI API key is required for classification.")]
            )
        }

        let model = Inf6OpenAIModelResolver.resolvedModel().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw NSError(
                domain: "inf6.paperchat.classification",
                code: -120,
                userInfo: [NSLocalizedDescriptionKey: _pcLangText("分類に使用する OpenAI モデルが未設定です。", "OpenAI model for classification is not configured.")]
            )
        }

        var rows: [_SurveyResultEmbeddingRow] = []
        rows.reserveCapacity(results.count)
        var others: [Inf6PaperSearchResult] = []
        others.reserveCapacity(results.count)

        for r in results {
            let abstract = r.abstractText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? r.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
                : r.abstractText.trimmingCharacters(in: .whitespacesAndNewlines)
            let featureText = [r.title, abstract]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if featureText.isEmpty {
                others.append(r)
                continue
            }
            do {
                let emb = try await Inf6EmbeddingService.embedPassage(featureText)
                if emb.vector.isEmpty {
                    others.append(r)
                    continue
                }
                rows.append(
                    _SurveyResultEmbeddingRow(
                        id: r.id,
                        title: r.title,
                        abstractText: abstract,
                        vector: emb.vector
                    )
                )
            } catch {
                others.append(r)
            }
        }

        let othersLabel = _pcLangText("その他", "Others")
        if rows.isEmpty {
            var labelByID: [String: String] = [:]
            var rankByID: [String: Int] = [:]
            var featureKeywordsByID: [String: [String]] = [:]
            for (idx, r) in results.enumerated() {
                labelByID[r.id] = othersLabel
                rankByID[r.id] = idx
                featureKeywordsByID[r.id] = []
            }
            return _SurveyResultClassificationOutcome(
                labelByID: labelByID,
                rankByID: rankByID,
                featureKeywordsByID: featureKeywordsByID,
                summary: _pcLangText("分類: すべてその他", "Classification: all in Others")
            )
        }

        let clusterCount = _surveyClusterCount(totalCount: rows.count)
        let clusterByID = try _surveyKMeansClusterByID(rows: rows, clusterCount: clusterCount)

        var rowsByCluster: [Int: [_SurveyResultEmbeddingRow]] = [:]
        rowsByCluster.reserveCapacity(clusterCount)
        for row in rows {
            let cid = clusterByID[row.id] ?? 0
            rowsByCluster[cid, default: []].append(row)
        }

        let labelByCluster = try await _surveyClassifyClusterLabelsByLLMOrThrow(
            rowsByCluster: rowsByCluster,
            apiKey: key,
            model: model
        )
        let keywordsByID = try await _surveyExtractFeatureKeywordsByLLMOrThrow(
            rows: rows,
            apiKey: key,
            model: model
        )

        var labelCount: [String: Int] = [:]
        labelCount.reserveCapacity(rowsByCluster.count)
        for row in rows {
            let cid = clusterByID[row.id] ?? 0
            let label = labelByCluster[cid] ?? _pcLangText("未分類", "Uncategorized")
            labelCount[label, default: 0] += 1
        }

        let orderedLabels = labelCount.keys.sorted { lhs, rhs in
            let lc = labelCount[lhs] ?? 0
            let rc = labelCount[rhs] ?? 0
            if lc != rc { return lc > rc }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }

        var labelOrder: [String: Int] = [:]
        labelOrder.reserveCapacity(orderedLabels.count)
        for (idx, label) in orderedLabels.enumerated() {
            labelOrder[label] = idx
        }

        let sortedRows = rows.sorted { lhs, rhs in
            let lcid = clusterByID[lhs.id] ?? 0
            let rcid = clusterByID[rhs.id] ?? 0
            let ll = labelByCluster[lcid] ?? _pcLangText("未分類", "Uncategorized")
            let rl = labelByCluster[rcid] ?? _pcLangText("未分類", "Uncategorized")
            let lo = labelOrder[ll] ?? Int.max
            let ro = labelOrder[rl] ?? Int.max
            if lo != ro { return lo < ro }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        var labelByID: [String: String] = [:]
        var rankByID: [String: Int] = [:]
        var featureByID: [String: [String]] = [:]
        labelByID.reserveCapacity(results.count)
        rankByID.reserveCapacity(results.count)
        featureByID.reserveCapacity(results.count)

        var nextRank = 0
        for row in sortedRows {
            let cid = clusterByID[row.id] ?? 0
            labelByID[row.id] = labelByCluster[cid] ?? _pcLangText("未分類", "Uncategorized")
            rankByID[row.id] = nextRank
            featureByID[row.id] = keywordsByID[row.id] ?? []
            nextRank += 1
        }

        if !others.isEmpty {
            let sortedOthers = others.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            for r in sortedOthers {
                labelByID[r.id] = othersLabel
                rankByID[r.id] = nextRank
                featureByID[r.id] = []
                nextRank += 1
            }
        }

        let summary = _pcLangText(
            "LLM分類: \(orderedLabels.count)分類 / \(rows.count)件（その他 \(others.count)件）",
            "LLM classification: \(orderedLabels.count) groups / \(rows.count) items (Others \(others.count))"
        )
        return _SurveyResultClassificationOutcome(
            labelByID: labelByID,
            rankByID: rankByID,
            featureKeywordsByID: featureByID,
            summary: summary
        )
    }

    // MARK: - Search

    private func _ensureCorpusVectorSpaceReady() async throws {
        if _didAttemptCorpusBootstrapThisLaunch { return }
        _didAttemptCorpusBootstrapThisLaunch = true

        let ready = try Inf6PaperCorpusBuilder.isCorpusReady()
        if ready {
            let snap = try Inf6PaperVectorSearchEngine.indexSnapshot()
            let arxiv = snap.sourceCounts["arxiv"] ?? 0
            let pubmed = snap.sourceCounts["pubmed"] ?? 0
            let acl = snap.sourceCounts["acl"] ?? 0
            let isca = snap.sourceCounts["isca"] ?? 0
            latestCorpusBuildSummary = _pcLangText(
                "コーパス確認: arXiv=\(arxiv), PubMed=\(pubmed), ACL=\(acl), ISCA=\(isca), total=\(snap.totalPapers)",
                "Corpus check: arXiv=\(arxiv), PubMed=\(pubmed), ACL=\(acl), ISCA=\(isca), total=\(snap.totalPapers)"
            )
            return
        }

        let report = try await Inf6PaperCorpusBuilder.buildDefaultCorpus()
        latestCorpusBuildSummary = report.summaryText
    }

    private func _runSurvey() async {
        isBusy = true
        defer { isBusy = false }

        do {
            latestVectorScoresByID = [:]
            latestVectorRerankSummary = ""
            latestCurrentPositionSummary = ""
            latestFrontierSummary = ""
            latestFrontierBandByID = [:]
            latestProfileKeySummary = ""
            latestProfileKeyPreview = ""
            latestResultClusterLabelByID = [:]
            latestResultClusterRankByID = [:]
            latestResultFeatureKeywordsByID = [:]
            latestResultClassificationSummary = ""
            latestResultClassificationError = nil
            let query = arxivQueryText.trimmingCharacters(in: .whitespacesAndNewlines)
            let isUnderstandMode = _isUnderstandPaperGoal()
            guard !query.isEmpty else {
                messages.append(
                    Inf6PaperChatMessage(
                        role: .assistant,
                        text: _pcLangText(
                            "検索式が空です。検索式を入力してから『検索』してください。",
                            "Query is empty. Enter a query, then tap Search."
                        )
                    )
                )
                return
            }
            if isUnderstandMode {
                let focus = keywordsText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !focus.isEmpty else {
                    messages.append(
                        Inf6PaperChatMessage(
                            role: .assistant,
                            text: _pcLangText(
                                "対象論文の ID / URL / タイトルが未入力です。入力後に検索してください。",
                                "Target paper ID / URL / title is empty. Enter it before searching."
                            )
                        )
                    )
                    return
                }
            }

            try await _ensureCorpusVectorSpaceReady()

            let augment = _profileSearchAugmentString().trimmingCharacters(in: .whitespacesAndNewlines)
            let baseQuery: String
            if isUnderstandMode || augment.isEmpty {
                baseQuery = query
            } else {
                baseQuery = "\(query) \(augment)"
            }
            let keyBuild: _ProfileKeyBuildResult
            if isUnderstandMode {
                keyBuild = _ProfileKeyBuildResult(
                    text: _currentPositionSummaryText(),
                    queryAugment: "",
                    backend: .gpt,
                    detail: _pcLangText(
                        "対象論文モード: 検索拡張なし",
                        "Target-paper mode: no query augmentation"
                    )
                )
            } else {
                keyBuild = try await _buildProfileSearchKeyText(query: query, effectiveQuery: baseQuery)
            }
            latestProfileKeySummary = keyBuild.detail
            let profileText = keyBuild.text
            let preview = profileText.trimmingCharacters(in: .whitespacesAndNewlines)
            latestProfileKeyPreview = String(preview.prefix(260))

            let effectiveQuery: String
            if isUnderstandMode {
                effectiveQuery = baseQuery
            } else {
                effectiveQuery = _mergeSearchQuery(base: baseQuery, augment: keyBuild.queryAugment)
            }

            let resolvedSource = _resolvedSourceFromAuto()
            switch resolvedSource {
            case .arxiv:
                latestResultsSourceLabel = "arXiv (local vector)"
            case .pubmed:
                latestResultsSourceLabel = "PubMed (local vector)"
            case .acl:
                latestResultsSourceLabel = "ACL (local vector)"
            case .isca:
                latestResultsSourceLabel = "ISCA (local vector)"
            case .auto:
                latestResultsSourceLabel = _pcLangText("自動（全ローカルベクター）", "Auto (all local vectors)")
            }
            let maxResults = _searchMaxResults()
            let localSourceRaw: String? = (resolvedSource == .auto) ? nil : resolvedSource.rawValue
            let localHits = try await Inf6PaperVectorSearchEngine.searchLocalByVector(
                queryText: profileText + "\n" + effectiveQuery,
                sourceRaw: localSourceRaw,
                topK: maxResults
            )
            var rankedResults = localHits.map { $0.result }
            latestVectorScoresByID = Dictionary(uniqueKeysWithValues: localHits.map { ($0.result.id, $0.score) })
            latestVectorRerankSummary = _pcLangText(
                "一次検索: ローカルベクターのみ / source=\(localSourceRaw ?? "all") / topK=\(maxResults)",
                "Primary search: local vectors only / source=\(localSourceRaw ?? "all") / topK=\(maxResults)"
            )

            latestCurrentPositionSummary = _currentPositionSummaryText()

            if isUnderstandMode {
                latestFrontierBandByID = [:]
                latestFrontierSummary = _pcLangText(
                    "対象論文モード: フロンティア分割なし",
                    "Target-paper mode: frontier split disabled"
                )
            } else {
                let frontierPlan = _frontierPlanFromRankedResults(rankedResults, scoresByID: latestVectorScoresByID)
                rankedResults = frontierPlan.ordered
                latestFrontierBandByID = frontierPlan.bandByID
                latestFrontierSummary = frontierPlan.summary
            }

            if rankedResults.isEmpty {
                messages.append(
                    Inf6PaperChatMessage(
                        role: .assistant,
                        text: """
\(_pcLangText("候補が見つかりませんでした。", "No candidates found."))

\(_pcLangText("使用した検索式:", "Query:"))
\(effectiveQuery)

\(_pcLangText("対処:", "Try:"))
- cat:cs.LG / cat:cs.CL / cat:stat.ML
- all:(\"keyword1\" OR \"keyword2\")
- \(_pcLangText("条件を緩めてから絞る", "broaden first, then narrow"))
"""
                    )
                )
                return
            }

            do {
                let classified = try await _classifySearchResultsByLLMOrThrow(results: rankedResults)
                latestResultClusterLabelByID = classified.labelByID
                latestResultClusterRankByID = classified.rankByID
                latestResultFeatureKeywordsByID = classified.featureKeywordsByID
                latestResultClassificationSummary = classified.summary
                latestResultClassificationError = nil

                if !classified.rankByID.isEmpty {
                    rankedResults = rankedResults.sorted { lhs, rhs in
                        let lr = classified.rankByID[lhs.id] ?? Int.max
                        let rr = classified.rankByID[rhs.id] ?? Int.max
                        if lr != rr { return lr < rr }
                        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                    }
                }
            } catch {
                latestResultClusterLabelByID = [:]
                latestResultClusterRankByID = [:]
                latestResultFeatureKeywordsByID = [:]
                latestResultClassificationSummary = ""
                latestResultClassificationError = _pcLangText(
                    "分類エラー: \(error.localizedDescription)",
                    "Classification error: \(error.localizedDescription)"
                )
            }

            var headLines: [String] = []
            headLines.append(_pcLangText("要旨ベースで候補を拾いました。", "Picked candidates by abstract."))
            headLines.append(_pcLangText("検索ソース:", "Source:") + " " + latestResultsSourceLabel)
            if !latestCorpusBuildSummary.isEmpty {
                headLines.append(latestCorpusBuildSummary)
            }
            if !latestCurrentPositionSummary.isEmpty {
                headLines.append(latestCurrentPositionSummary)
            }
            headLines.append(_pcLangText("使用した検索式:", "Query:"))
            headLines.append(effectiveQuery)
            if !latestVectorRerankSummary.isEmpty {
                headLines.append(latestVectorRerankSummary)
            }
            if !latestProfileKeySummary.isEmpty {
                headLines.append(latestProfileKeySummary)
            }
            if !latestFrontierSummary.isEmpty {
                headLines.append(latestFrontierSummary)
            }
            if !latestResultClassificationSummary.isEmpty {
                headLines.append(latestResultClassificationSummary)
            }
            headLines.append(_pcLangText("次は『タイトル→要旨』を見て、読む/保留/捨てるを決めてください。", "Next, review title → abstract and decide read/hold/drop."))
            let head = headLines.joined(separator: "\n")

            let bullets = rankedResults.prefix(5).enumerated().map { idx, r in
                "\(idx + 1). \(r.title)"
            }.joined(separator: "\n")

            messages.append(
                Inf6PaperChatMessage(
                    role: .assistant,
                    text: """
\(head)
\(_pcLangText("上位候補:", "Top candidates:"))
\(bullets)
"""
                )
            )

            if selectedContext == .qualification && assessmentPreference == .enabled {
                messages.append(
                    Inf6PaperChatMessage(
                        role: .assistant,
                        text: _pcLangText(
                            "資格対策モードのため、次の段階で到達度評価を差し込みます。",
                            "Qualification mode is enabled, so an assessment step will be inserted next."
                        )
                    )
                )
            }

            latestResults = rankedResults

            _persistLatestResults(rankedResults)
            _persistProfileSnapshot()
            _persistRecentSearchSnapshot(query: effectiveQuery, results: rankedResults)

        } catch {
            lastError = error.localizedDescription
            messages.append(
                Inf6PaperChatMessage(
                    role: .assistant,
                    text: _pcLangText(
                        "検索に失敗しました: \(error.localizedDescription)",
                        "Search failed: \(error.localizedDescription)"
                    )
                )
            )
        }
    }

    func resetProfile() {
        isBusy = false
        lastError = nil
        latestResults = []
        latestVectorScoresByID = [:]
        latestVectorRerankSummary = ""
        latestCurrentPositionSummary = ""
        latestFrontierSummary = ""
        latestFrontierBandByID = [:]
        latestProfileKeySummary = ""
        latestProfileKeyPreview = ""
        latestResultClusterLabelByID = [:]
        latestResultClusterRankByID = [:]
        latestResultFeatureKeywordsByID = [:]
        latestResultClassificationSummary = ""
        latestResultClassificationError = nil
        inputText = ""

        selectedMode = .study
        selectedPersona = .student
        selectedContext = .none
        selectedSource = .auto
        selectedOrientation = .foundation
        assessmentPreference = .undecided
        selectedTimeBudget = .focused30

        if let t = _loadDefaultTrackOrNil() {
            selectedTrack = t
        } else {
            selectedTrack = .aiInfo
        }

        goalID = ""
        taskID = ""
        domainID = ""
        goalText = ""
        domainKey = ""
        keywordsText = ""
        constraintsText = ""
        arxivQueryText = ""

        stage = .choosePersona
        _refreshQuickRepliesForStage()

        messages = []
        _appendInitialAssistantPrompt()

        _persistProfileSnapshot()
    }

    func goBack() {
        guard let idx = _workflowStages.firstIndex(of: stage), idx > 0 else { return }

        isBusy = false
        lastError = nil
        latestResults = []
        latestVectorScoresByID = [:]
        latestVectorRerankSummary = ""
        latestCurrentPositionSummary = ""
        latestFrontierSummary = ""
        latestFrontierBandByID = [:]
        latestProfileKeySummary = ""
        latestProfileKeyPreview = ""
        latestResultClusterLabelByID = [:]
        latestResultClusterRankByID = [:]
        latestResultFeatureKeywordsByID = [:]
        latestResultClassificationSummary = ""
        latestResultClassificationError = nil

        stage = _workflowStages[idx - 1]
        _refreshQuickRepliesForStage()
        _persistProfileSnapshot()
    }
}
