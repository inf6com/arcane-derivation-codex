import SwiftUI
import UIKit
#if canImport(PencilKit)
import PencilKit
#endif

struct _Inf6SelectableText: UIViewRepresentable {
    let text: String
    let font: UIFont
    let color: UIColor
    var onSelectionChanged: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectionChanged: onSelectionChanged)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.isEditable = false
        view.isSelectable = true
        view.isUserInteractionEnabled = true
        view.isScrollEnabled = false
        // マウスでなぞって選べるようにする。iPad の作りのままだと
        // 長押しからしか選択が始まらない。
        #if targetEnvironment(macCatalyst)
        view.isFindInteractionEnabled = false
        #endif
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.onSelectionChanged = onSelectionChanged
        if view.text != text {
            view.text = text
        }
        view.font = font
        view.textColor = color
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onSelectionChanged: ((String) -> Void)?

        init(onSelectionChanged: ((String) -> Void)?) {
            self.onSelectionChanged = onSelectionChanged
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard let range = textView.selectedTextRange else { return }
            let selected = (textView.text(in: range) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            onSelectionChanged?(selected)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}

private struct _AddExerciseEntityImage: View {
    let entity: Inf6DocEntity
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                VStack(spacing: 6) {
                    Image(systemName: entity.kind.systemImage)
                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(28)))
                    Text("画像なし")
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
            } else {
                ProgressView().tint(.pink).scaleEffect(1.25)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: entity.imagePath ?? "") {
            guard let relativePath = entity.imagePath,
                  !relativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let url = await Inf6EntityImageStore.ensureLocalFile(relativePath: relativePath),
                  let data = try? Data(contentsOf: url),
                  let loaded = UIImage(data: data) else {
                failed = true
                return
            }
            image = loaded
        }
    }
}

private enum _PracticeQuestionFilter: String {
    case all
    case python
    case regular
}

private struct _SlideshowHistoryItem: Hashable {
    var paperKey: String
    var groupID: String
}

private struct _EntityImageDeletionRequest: Identifiable {
    let paperKey: String
    let docEntityID: UUID

    var id: String { "\(paperKey):\(docEntityID.uuidString)" }
}

private struct _SlideshowPosition {
    var current: Int
    var total: Int
    var indexLabel: String
}


struct Inf6IntensiveDrillView: View {

    let sourceFamily: String
    @Environment(\.dismiss) private var _dismiss
    @AppStorage("inf6.intensiveDrill.fontScale") private var _storedFontScale: Double = 1.0

    @MainActor
    private static var _loadedGroupsBySourceFamily: [String: [Inf6EshikakuDrillPipeline.DrillGroup]] = [:]
    @MainActor
    private static var _loadedGroupsRevision: Int = Inf6DataExchange.currentRevision()

    @State private var _groups: [Inf6EshikakuDrillPipeline.DrillGroup] = []
    @State private var _isLoading = true
    @State private var _generatingKeys: Set<String> = []
    @State private var _exploringOriginNodeIDs: Set<String> = []
    @State private var _genErrors: [String: String] = [:]
    @State private var _selectedByQ: [UUID: Int] = [:]
    @State private var _revealByQ: Set<UUID> = []

    /// 論文本文を演習と並べて読むための別ウィンドウ表示に使う。
    @Environment(\.openWindow) private var _openWindow

    /// 別ウィンドウ表示のためにPDFを取得中の項目。
    @State private var _openingPaperKeys: Set<String> = []

    // MARK: - 追加解説の記録
    @State private var _askingQuestionIDs: Set<UUID> = []
    /// ADD EXERCISE／Live BP反応の生成中ID。通常のAI解説とは独立させる。
    @State private var _liveBPGeneratingQuestionIDs: Set<UUID> = []
    /// paperKey → 記録。表示のたびにストアを読まないためのキャッシュ。
    @State private var _askNotesByPaperKey: [String: [Inf6DrillAskNote]] = [:]
    @State private var _selectedTerminologyByPaperKey: [String: String] = [:]
    @State private var _terminologyAskSelectionByQuestionID: [UUID: String] = [:]
    @State private var _liveBPReactionsByPaperKey: [String: [String: Inf6LiveBPReaction]] = [:]
    @State private var _liveBPGeneratedByPaperKey: [String: [Inf6LiveBPGeneratedExercise]] = [:]
    @State private var _addExerciseCandidates: [Inf6DocEntity] = []
    @State private var _isShowingAddExerciseCandidates = false
    @State private var _addExerciseSourceQuestionID: UUID?
    @State private var _addExerciseSourceEntryKey: String?
    @State private var _addExerciseInstruction = ""
    @State private var _selectedAddExerciseEntityID: UUID?
    @State private var _syllabusImportanceByNodeID: [String: Inf6SyllabusImportanceScore] = [:]
    @State private var _syllabusImportanceByDomainID: [String: Inf6SyllabusImportanceScore] = [:]
    @State private var _isEvaluatingSyllabusImportance = false
    @State private var _syllabusImportanceCompletedCount = 0
    @State private var _syllabusImportanceTotalCount = 0
    @State private var _slideshowProgressByPaperKey: [String: Inf6DrillSlideshowProgressBook] = [:]
    @State private var _slideshowCurrentIndexByPaperKey: [String: Int] = [:]
    @State private var _slideshowCurrentGroupIDByPaperKey: [String: String] = [:]
    @State private var _slideshowOverallIndexText = ""
    @State private var _slideshowLocalIndexText = ""
    @State private var _slideshowPlayingPaperKey: String?
    @State private var _slideshowPresentedPaperKey: String?
    @State private var _slideshowTask: Task<Void, Never>?
    @State private var _slideshowViewportToken = UUID()
    @State private var _slideshowBackStack: [_SlideshowHistoryItem] = []
    @State private var _slideshowForwardStack: [_SlideshowHistoryItem] = []
    @State private var _slideshowSequence: [_SlideshowHistoryItem] = []
    @State private var _listViewportToken = UUID()
    @State private var _terminologyAskPanelQuestionID: UUID? = nil
    @State private var _pendingEntityImageDeletion: _EntityImageDeletionRequest?
    @State private var _selectedEntryID: String?
    @State private var _detailQuestionFilterByEntryID: [String: _PracticeQuestionFilter] = [:]
    @State private var _loadRunID: UUID?
    @State private var _loadSelectionTask: Task<[Inf6EshikakuDrillPipeline.DrillGroup], Error>?
    @State private var _generationTasks: [String: Task<_GenerationOutcome, Never>] = [:]
    @State private var _pendingGenerationTask: Task<Void, Never>?
    @State private var _deletingQuizKeys: Set<String> = []
    /// 実行中かどうかを同期的に持つ。_pendingGenerationTask の代入は Task 生成の
    /// 後になるため、タスクが先に完了すると完了済みタスクが残り、以降の実行が
    /// 永久に弾かれてしまう。ガードはこのフラグで行う。
    @State private var _isGenerationRunning = false
    @State private var _generationCompletedCount = 0
    @State private var _generationTotalCount = 0
    @State private var _overviewCache: [String: String] = [:]
    @State private var _recutInProgress = false
    @State private var _recutTask: Task<Void, Never>?
    @State private var _recutCompletedCount = 0
    @State private var _recutTotalCount = 0
    @State private var _recutError: String?
    @State private var _entityImageRefreshID = UUID()
    @State private var _visualEntityCounts: [String: Int] = [:]
    @State private var _visualEntityCountTask: Task<Void, Never>?
    @State private var _cropTargetQID: UUID?
    @State private var _cropExpTop: Double = 0.08
    @State private var _cropExpBottom: Double = 0.08
    @State private var _cropExpLeft: Double = 0
    @State private var _cropExpRight: Double = 0
    @State private var _originExploreTask: Task<Void, Never>?
    @State private var _originExploreCompletedCount = 0
    @State private var _originExploreTotalCount = 0
    @State private var _selectedNodeIDs: Set<String> = []
    @State private var _selectedPaperLeafKeys: Set<String> = []
    @State private var _selectedPaperKeys: Set<String> = []
    @State private var _selectedPythonPaperKeys: Set<String> = []
    @FocusState private var _liveBPKeyboardFocused: Bool
    @State private var _hasInitializedDefaultExerciseSelection = false
    @State private var _selectedPythonPracticeFramework: _PythonPracticeFramework = .pytorch
    @State private var _collapsedDomainIDs: Set<String> = []
    @State private var _extraInstructions: [String: String] = [:]
    @State private var _miniPromptTarget: Inf6EshikakuDrillPipeline.OriginUnverifiedItem?
    @State private var _miniPromptDraft: String = ""
    private var _cropExpansion: Inf6EshikakuDrillPipeline.EntityCropExpansion {
        .init(top: _cropExpTop, bottom: _cropExpBottom, left: _cropExpLeft, right: _cropExpRight)
    }

    private struct _GenerationOutcome {
        let entryID: String
        let folderKey: String
        let quiz: Inf6PaperQuiz?
        let errorMessage: String?
        let wasCancelled: Bool
        let stopsBatch: Bool
    }

    private struct _GenerationRequest {
        let entry: Inf6EshikakuDrillPipeline.DrillEntry
        let generateBaseQuiz: Bool
        let generateCodePractice: Bool
    }

    private struct _AskTarget: Identifiable, Hashable {
        let questionID: UUID
        let paperKey: String
        let questionText: String
        let explanationText: String
        let paperTitle: String
        let selectedTerm: String?
        var id: UUID { questionID }
    }

    private struct _LiveBPGenerationResponse: Decodable {
        let question: String
        let explanation: String
        let kind: String
        let coverageTargetIDs: [String]?

        private enum CodingKeys: String, CodingKey {
            case question
            case explanation
            case kind
            case coverageTargetIDs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            question = try container.decode(String.self, forKey: .question)
            kind = try container.decode(String.self, forKey: .kind)
            coverageTargetIDs = try container.decodeIfPresent([String].self, forKey: .coverageTargetIDs)

            if let explanationText = try? container.decode(String.self, forKey: .explanation) {
                explanation = explanationText
            } else {
                let explanationLines = try container.decode([String].self, forKey: .explanation)
                explanation = explanationLines.joined(separator: "\n")
            }
        }
    }

    private static func _liveBPDecodeFailureDescription(_ error: DecodingError) -> String {
        switch error {
        case let .keyNotFound(key, context):
            return "keyNotFound key=\(key.stringValue) codingPath=\(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case let .typeMismatch(type, context):
            return "typeMismatch expected=\(type) codingPath=\(context.codingPath.map(\.stringValue).joined(separator: ".")) debug=\(context.debugDescription)"
        case let .valueNotFound(type, context):
            return "valueNotFound expected=\(type) codingPath=\(context.codingPath.map(\.stringValue).joined(separator: ".")) debug=\(context.debugDescription)"
        case let .dataCorrupted(context):
            return "dataCorrupted codingPath=\(context.codingPath.map(\.stringValue).joined(separator: ".")) debug=\(context.debugDescription)"
        @unknown default:
            return "unknownDecodingError"
        }
    }

    private enum _LiveBPGenerationMode {
        case additionalExercise
        case understandingPoint
    }

    private struct _SyllabusImportanceRequestDomain: Codable, Hashable {
        let id: String
        let domainPrefix: String
        let titleJa: String
        let titleEn: String
    }

    private struct _SyllabusImportanceRequestNode: Codable, Hashable {
        let id: String
        let domainID: String
        let domainPrefix: String
        let domainLabelJa: String
        let domainLabelEn: String
        let titleJa: String
        let titleEn: String
    }

    private struct _SyllabusImportanceResponse: Decodable {
        let domains: [_SyllabusImportanceResponseItem]
        let nodes: [_SyllabusImportanceResponseItem]
    }

    private struct _SyllabusImportanceResponseItem: Decodable {
        let id: String
        let examImportanceScore: Int
        let examImportanceReason: String
    }

    private struct _SyllabusNodeImportanceResponse: Decodable {
        let nodes: [_SyllabusImportanceResponseItem]
    }

    private enum _PythonPracticeFramework: String, CaseIterable, Identifiable {
        case pytorch
        case tensorflow

        var id: String { rawValue }

        var label: String {
            switch self {
            case .pytorch: return "PyTorch"
            case .tensorflow: return "TensorFlow"
            }
        }

        var targetIDPart: String { rawValue }
    }

    private enum _NodeRowItem: Identifiable {
        case entry(Inf6EshikakuDrillPipeline.DrillEntry)
        case unresolved(Inf6EshikakuDrillPipeline.OriginUnverifiedItem)

        var id: String {
            switch self {
            case .entry(let entry): return entry.id
            case .unresolved(let item): return item.id
            }
        }

        var nodeID: String {
            switch self {
            case .entry(let entry): return entry.syllabusNodeID ?? entry.id
            case .unresolved(let item): return item.nodeID
            }
        }
    }

    private var _langRaw: String {
        let lang = (Locale.preferredLanguages.first ?? Locale.current.identifier).lowercased()
        return lang.hasPrefix("ja") ? "ja" : "en"
    }

    private func L(_ ja: String, _ en: String) -> String {
        _langRaw == "ja" ? ja : en
    }

    private func _choicePrefix(_ index: Int) -> String {
        switch index {
        case 0: return "A"
        case 1: return "B"
        case 2: return "C"
        default: return "D"
        }
    }

    private var _pendingQuizEntries: [Inf6EshikakuDrillPipeline.DrillEntry] {
        var seenFolderKeys = Set<String>()
        return _groups.flatMap(\.entries).filter { entry in
            guard _needsBaseQuizGeneration(entry) || _needsPythonQuizGeneration(entry) else { return false }
            return seenFolderKeys.insert(entry.folderKey).inserted
        }
    }

    private var _pendingOriginItems: [Inf6EshikakuDrillPipeline.OriginUnverifiedItem] {
        _groups
            .flatMap(\.unverifiedOrigins)
    }

    private var _explorableItemsForSelectedNodes: [Inf6EshikakuDrillPipeline.OriginUnverifiedItem] {
        _pendingOriginItems.filter { _selectedNodeIDs.contains($0.nodeID) }
    }

    /// 全ドメイン横断のリーフノードID(起源探索の選択対象)。
    private var _allLeafNodeIDs: [String] {
        _groups.flatMap { group in _leafNodeGroups(group).map(\.id) }
    }

    /// 全ドメイン横断の論文キー(演習生成の選択対象)。
    private var _allPaperKeys: [String] {
        _groups.flatMap(\.entries).map { _paperKey($0) }
    }

    /// 全ドメイン横断の論文リーフキー。論文行の紫色○の選択対象。
    private var _allPaperLeafKeys: [String] {
        _groups.flatMap(\.entries)
            .filter { !_isTextbookField($0) }
            .map { _paperKey($0) }
    }

    private var _allPythonPaperKeys: [String] {
        _groups.flatMap(\.entries).filter(_isPythonNode).map { _paperKey($0) }
    }

    /// 初回表示時の選択状態を確定する。
    /// 演習は利用者が明示的に選択した論文だけを対象にするため、
    /// 初回表示で全件を自動選択してはいけない。
    @MainActor
    private func _initializeDefaultExerciseSelectionIfNeeded() {
        guard !_hasInitializedDefaultExerciseSelection else { return }
        let paperKeys = _allPaperKeys
        guard !paperKeys.isEmpty else { return }
        _hasInitializedDefaultExerciseSelection = true
    }

    /// 未解決ノード行にも `演習` 用の四角を表示している。
    /// これらはまだ論文行ではなく `_selectedPaperKeys` の対象外なので、
    /// 画面上に一つでも残っている間は「全演習」を選択済みと見なさない。
    private var _hasExercisePlaceholders: Bool {
        _groups.contains { !$0.unverifiedOrigins.isEmpty }
    }

    private var _generatedGroups: [Inf6EshikakuDrillPipeline.DrillGroup] {
        _groups.compactMap { group in
            let entries = group.entries.filter { entry in
                return entry.quiz?.questions.isEmpty == false
            }
            guard !entries.isEmpty else { return nil }
            var copy = group
            copy.entries = entries
            return copy
        }
    }

    private var _selectedQuizEntriesForSlideshow: [Inf6EshikakuDrillPipeline.DrillEntry] {
        var seen = Set<String>()
        let entries = _groups
            .enumerated()
            .flatMap { groupOffset, group in
                group.entries.enumerated().map { entryOffset, entry in
                    (groupOffset, entryOffset, entry)
                }
            }
            .filter { entry in
                guard entry.2.quiz?.questions.isEmpty == false else { return false }
                guard _isSelectedForPractice(entry.2) else { return false }
                return seen.insert(entry.2.folderKey).inserted
            }
        let ranked = entries.sorted { left, right in
            let leftScore = _slideshowExamPriorityScore(entry: left.2, groupOffset: left.0, entryOffset: left.1)
            let rightScore = _slideshowExamPriorityScore(entry: right.2, groupOffset: right.0, entryOffset: right.1)
            if leftScore != rightScore { return leftScore > rightScore }
            if left.0 != right.0 { return left.0 < right.0 }
            if left.1 != right.1 { return left.1 < right.1 }
            return left.2.folderKey < right.2.folderKey
        }
        return ranked.map(\.2)
    }

    private var _selectedPracticeQuestionCount: Int {
        _selectedQuizEntriesForSlideshow.reduce(0) { total, entry in
            guard let quiz = entry.quiz else { return total }
            return total + _displayQuestions(quiz, for: entry).count
        }
    }

    private var _hasSyllabusImportanceScores: Bool {
        !_syllabusImportanceByNodeID.isEmpty || !_syllabusImportanceByDomainID.isEmpty
    }

    private var _currentSlideshowEntry: Inf6EshikakuDrillPipeline.DrillEntry? {
        if let playingKey = _slideshowPlayingPaperKey {
            return _selectedQuizEntriesForSlideshow.first(where: { $0.folderKey == playingKey })
        }
        if let presentedKey = _slideshowPresentedPaperKey {
            return _selectedQuizEntriesForSlideshow.first(where: { $0.folderKey == presentedKey })
        }
        return _initialSlideshowEntry()
    }

    private var _fontScale: CGFloat {
        let v = CGFloat(_storedFontScale)
        guard v.isFinite else { return 1.0 }
        return min(max(v, 1.0), 2.20)
    }

    private static let _eshikakuCoverageDefinitions: [Inf6SyllabusCoverageDefinition] = {
        do {
            return try Inf6SyllabusCoverageDefinition.loadDefinitions()
        } catch {
            NSLog("[DrillView] failed to load eshikaku coverage priorities: %@", error.localizedDescription)
            return []
        }
    }()

    private static let _eshikakuPriorityRankBySection: [String: Int] = {
        Dictionary(
            uniqueKeysWithValues: _eshikakuCoverageDefinitions.enumerated().map { index, definition in
                (definition.syllabusSection, index)
            }
        )
    }()

    private func _slideshowExamPriorityScore(
        entry: Inf6EshikakuDrillPipeline.DrillEntry,
        groupOffset: Int,
        entryOffset: Int
    ) -> Int {
        if let syllabusScore = _slideshowSyllabusImportanceScore(entry: entry) {
            return 100_000_000 + (syllabusScore * 100_000) - (groupOffset * 100) - entryOffset
        }
        let domain = entry.domainLabelJa.trimmingCharacters(in: .whitespacesAndNewlines)
        if sourceFamily == "jdla_eshikaku" || sourceFamily == "eshikaku" {
            let domainRank = Self._eshikakuPriorityRankBySection[domain] ?? groupOffset
            let questionPenalty = min(entry.quiz?.questions.count ?? 0, 99)
            return 1_000_000 - (domainRank * 1_000) - (entryOffset * 10) - questionPenalty
        }
        return 1_000_000 - (groupOffset * 1_000) - entryOffset
    }

    private func _slideshowSyllabusImportanceScore(
        entry: Inf6EshikakuDrillPipeline.DrillEntry
    ) -> Int? {
        if let nodeID = entry.syllabusNodeID,
           let saved = _syllabusImportanceByNodeID[nodeID] {
            return saved.examImportanceScore
        }
        if let saved = _syllabusImportanceByDomainID[entry.domainPrefix] {
            return saved.examImportanceScore
        }
        return nil
    }

    private func _liveBPGroupPriorityScore(
        entry: Inf6EshikakuDrillPipeline.DrillEntry,
        group: _EntityGroup
    ) -> Int {
        _ = group
        if let syllabusScore = _slideshowSyllabusImportanceScore(entry: entry) {
            return syllabusScore
        }
        return 0
    }

    private func _font(_ base: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: base * _fontScale, weight: weight)
    }

    private var _entityImageMaxHeight: CGFloat {
        // 図表数式の表示枠は本文フォント倍率から切り離す。
        // フォント調整は文字だけの操作であり、画像まで拡大すると紙面の比率が崩れる。
        540
    }

    private var _dodgersBlue: Color {
        Color(red: 0.0, green: 90.0 / 255.0, blue: 156.0 / 255.0)
    }

    private var _dodgersBlueSecondary: Color {
        Color(red: 42.0 / 255.0, green: 117.0 / 255.0, blue: 181.0 / 255.0)
    }

    private var _dodgersRed: Color {
        Color(red: 213.0 / 255.0, green: 0.0, blue: 28.0 / 255.0)
    }

    private var _dodgersBlueError: Color {
        Color(red: 150.0 / 255.0, green: 36.0 / 255.0, blue: 76.0 / 255.0)
    }

    private var _paperNodePurple: Color {
        Color(red: 92.0 / 255.0, green: 48.0 / 255.0, blue: 168.0 / 255.0)
    }

    @ViewBuilder
    private var _drillScrollReader: some View {
        ScrollViewReader { proxy in
            ScrollView {
                _drillScrollContent
                    .padding(20)
                    .textSelection(.enabled)
            }
            .onChange(of: _listViewportToken) { _, _ in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo("drill-list-anchor", anchor: .top)
                }
            }
            .safeAreaInset(edge: .top, content: _safeAreaTopControls)
        }
        .focusable()
        .focused($_liveBPKeyboardFocused)
        .onAppear {
            _liveBPKeyboardFocused = true
        }
    }

    var body: some View {
        Group {
            _drillScrollReader
        }
        .navigationTitle("")
        .navigationBarBackButtonHidden(true)
        .tint(_dodgersBlue)
        .confirmationDialog(
            L("図表・数式画像を削除しますか？", "Delete this visual asset?"),
            isPresented: Binding(
                get: { _pendingEntityImageDeletion != nil },
                set: { isPresented in
                    if !isPresented { _pendingEntityImageDeletion = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(L("削除", "Delete"), role: .destructive) {
                guard let request = _pendingEntityImageDeletion,
                      let entry = _groups
                        .flatMap(\.entries)
                        .first(where: { $0.folderKey == request.paperKey }) else {
                    _pendingEntityImageDeletion = nil
                    return
                }
                _pendingEntityImageDeletion = nil
                _deleteEntityImage(entry: entry, docEntityID: request.docEntityID)
            }
            Button(L("キャンセル", "Cancel"), role: .cancel) {
                _pendingEntityImageDeletion = nil
            }
        } message: {
            Text(L(
                "この図表・数式画像と、関連する表示参照を削除します。",
                "This deletes the visual asset and its display references."
            ))
        }
        .onKeyPress(.leftArrow) {
            _handleManualSlideshowPrevious()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            _handleManualSlideshowNext()
            return .handled
        }
        .onKeyPress(.pageUp) {
            _handleManualSlideshowPrevious()
            return .handled
        }
        .onKeyPress(.pageDown) {
            _handleManualSlideshowNext()
            return .handled
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 8) {
                    Button {
                        _handleBackAction()
                    } label: {
                        Image(systemName: "chevron.backward")
                            .font(_font(18, weight: .semibold))
                            .foregroundStyle(_dodgersBlue)
                            .frame(width: 38, height: 38)
                            .background(_dodgersBlue.opacity(0.10))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(_slideshowPresentedPaperKey != nil ? "演習一覧へ戻る" : "前の画面へ戻る")
                    .help(_slideshowPresentedPaperKey != nil ? "演習一覧へ戻る" : "前の画面へ戻る")

                    _toolbarActions
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                    _fontScaleControl
                    _settingsMenu
                }
            }
        }
        .task { await _loadAll() }
        .onReceive(NotificationCenter.default.publisher(for: .inf6DataExchangeDidImport)) { _ in
            Task { await _loadAll(forceReload: true) }
        }
        .onDisappear {
            _originExploreTask?.cancel()
            _originExploreTask = nil
            _visualEntityCountTask?.cancel()
            _visualEntityCountTask = nil
            _stopSlideshow()
        }
        .fullScreenCover(item: $_miniPromptTarget) { item in
            _miniPromptEditor(item)
        }
        .sheet(isPresented: $_isShowingAddExerciseCandidates) {
            _addExerciseCandidateSheet
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var _addExerciseCandidateSheet: some View {
        NavigationStack {
            List(_addExerciseCandidates) { entity in
                Button {
                    _selectedAddExerciseEntityID = entity.id
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        _AddExerciseEntityImage(entity: entity)
                            .frame(maxWidth: .infinity)
                            .frame(height: 170)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entity.kind.labelEn)
                                .font(_font(13, weight: .bold))
                                .foregroundStyle(_dodgersBlue)
                            Text(entity.title)
                                .font(_font(18, weight: .semibold))
                                .foregroundStyle(_dodgersBlue)
                        }
                        HStack(spacing: 10) {
                            Text(L("ページ \(entity.pageIndex + 1)", "Page \(entity.pageIndex + 1)"))
                            Text(entity.coreImportanceScore.map { "LLM IMP \($0)" } ?? L("LLM IMP 未評価", "LLM IMP not scored"))
                                .fontWeight(.semibold)
                                .foregroundStyle(entity.coreImportanceScore == nil ? .secondary : _dodgersBlue)
                        }
                        .font(_font(14))
                        .foregroundStyle(_dodgersBlueSecondary)
                        if !entity.snippet.isEmpty {
                            Text(entity.snippet)
                                .font(_font(13))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(_selectedAddExerciseEntityID == entity.id ? _dodgersBlue.opacity(0.12) : .clear)
                    )
                }
                .buttonStyle(.plain)
            }
            .safeAreaInset(edge: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("追加指示（任意）", "Additional instruction (optional)"))
                        .font(_font(15, weight: .semibold))
                        .foregroundStyle(_dodgersBlue)
                    TextEditor(text: $_addExerciseInstruction)
                        .font(_font(15))
                        .frame(minHeight: 72, maxHeight: 110)
                        .padding(6)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(_dodgersBlue.opacity(0.35), lineWidth: 1)
                        }
                        .textSelection(.enabled)
                    Text(L("現在表示中の図表・数式を根拠に、別角度の理解ポイントと演習を生成します。", "Generates an exercise from the currently displayed visual evidence from another angle."))
                        .font(_font(13))
                        .foregroundStyle(_dodgersBlueSecondary)
                }
                .padding(12)
                .background(.regularMaterial)
            }
            .navigationTitle(L("図表・数式から追加演習", "Add exercise from visual evidence"))
            .safeAreaInset(edge: .top) {
                HStack {
                    Button(L("キャンセル", "Cancel")) {
                        _isShowingAddExerciseCandidates = false
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button {
                        guard let selectedID = _selectedAddExerciseEntityID,
                              let entity = _addExerciseCandidates.first(where: { $0.id == selectedID }) else { return }
                        _isShowingAddExerciseCandidates = false
                        _startAdditionalExercise(for: entity, instruction: _addExerciseInstruction)
                    } label: {
                        Text(L("演習を生成する", "Generate exercise"))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(_selectedAddExerciseEntityID == nil)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial)
            }
        }
    }

    @ViewBuilder
    private var _drillScrollContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Color.clear
                .frame(height: 0)
                .id("drill-list-anchor")

            if _isLoading {
                HStack(spacing: 14) {
                    ProgressView().tint(.pink).scaleEffect(1.25)
                        .controlSize(.large)
                        .scaleEffect(1.25)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("演習データを読み込み中", "Loading exercise data"))
                            .font(_font(17, weight: .bold))
                            .foregroundStyle(_dodgersBlue)
                            .textSelection(.enabled)
                        Text(L("シラバスノード、概要解説、演習問題の保存状態を確認しています。", "Checking syllabus nodes, overview explanations, and saved quizzes."))
                            .font(_font(14))
                            .foregroundStyle(_dodgersBlueSecondary)
                            .textSelection(.enabled)
                    }
                    Button(role: .cancel) {
                        _cancelLoadAll()
                    } label: {
                        Label(L("キャンセル", "Cancel"), systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, minHeight: 100)
            } else if _groups.isEmpty {
                _emptyState
            } else {
                _generationControls
                    .id("drill-slideshow-anchor")

                if _slideshowPresentedPaperKey != nil || _slideshowPlayingPaperKey != nil {
                    _topSlideshowControls
                    if _slideshowPresentedPaperKey != nil {
                        _topSlideshowViewer
                    }
                }

                _globalErrorViews
                _nodeIndex
            }
        }
    }

    @ViewBuilder
    private var _globalErrorViews: some View {
        ForEach(_globalErrors.sorted { $0.key < $1.key }, id: \.key) { entry in
            _Inf6SelectableText(
                text: entry.value,
                font: .systemFont(ofSize: 17 * _fontScale),
                color: UIColor(red: 150.0 / 255.0, green: 36.0 / 255.0, blue: 76.0 / 255.0, alpha: 1)
            )
            .padding(12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    @ViewBuilder
    private func _safeAreaTopControls() -> some View {
        _fixedTopControls
    }

    @ViewBuilder
    private func _miniPromptEditor(_ item: Inf6EshikakuDrillPipeline.OriginUnverifiedItem) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(item.titleJa.isEmpty ? item.titleEn : item.titleJa)
                    .font(_font(20, weight: .bold))
                    .foregroundStyle(_dodgersBlue)

                Text(L(
                    "起源探索のLLMへ追加で伝える指示を入力してください。例: 「その論文は起源ではない、別の論文を挙げ直せ」",
                    "Enter extra instructions for the origin-exploration LLM. e.g. \"That paper is not the origin, name a different one.\""
                ))
                .font(_font(14))
                .foregroundStyle(_dodgersBlueSecondary)

                TextEditor(text: $_miniPromptDraft)
                    .font(_font(15))
                    .frame(minHeight: 160)
                    .padding(8)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Spacer()
            }
            .padding(20)
            .navigationTitle(L("追加指示", "Extra Instruction"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("キャンセル", "Cancel")) {
                        _miniPromptTarget = nil
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("保存", "Save")) {
                        let trimmed = _miniPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            _extraInstructions.removeValue(forKey: item.nodeID)
                        } else {
                            _extraInstructions[item.nodeID] = trimmed
                        }
                        _miniPromptTarget = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    /// 画面全体に関わる失敗。ノード単位の失敗はノードの行に出す。
    private static let _globalErrorKeys: Set<String> = ["load", "ask", "open_paper", "liveBP", "syllabus_importance"]

    private var _globalErrors: [String: String] {
        _genErrors.filter { Self._globalErrorKeys.contains($0.key) }
    }

    @ViewBuilder
    private var _nodeIndex: some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            ForEach(_groups) { group in
                _nodeDomainSection(group)
            }
        }
    }

    /// 全ドメインを横断する選択。ドメイン見出しやノード行と同じ形にして、
    /// 一覧の先頭に置く。メニューの中にあると、何を選んでいるのかが
    /// 選択対象から離れてしまい分かりにくい。
    @ViewBuilder
    private var _allSelectionRow: some View {
        let allNodeIDs = _allLeafNodeIDs
        let allPaperLeafKeys = _allPaperLeafKeys
        let allKeys = _allPaperKeys
        let allPythonKeys = _allPythonPaperKeys
        let allNodesSelected = !allNodeIDs.isEmpty && allNodeIDs.allSatisfy { _selectedNodeIDs.contains($0) }
        let allPaperLeavesSelected = !allPaperLeafKeys.isEmpty
            && allPaperLeafKeys.allSatisfy { _selectedPaperLeafKeys.contains($0) }
        let selectedPaperLeafCount = allPaperLeafKeys.reduce(into: 0) { count, key in
            if _selectedPaperLeafKeys.contains(key) { count += 1 }
        }
        let hasAllPaperKeysSelected = !allKeys.isEmpty
            && allKeys.allSatisfy { _selectedPaperKeys.contains($0) }
        let allPapersSelected = hasAllPaperKeysSelected
        let hasAllPythonKeysSelected = !allPythonKeys.isEmpty
            && allPythonKeys.allSatisfy { _selectedPythonPaperKeys.contains($0) }

        HStack(spacing: 10) {
            Button {
                if allNodesSelected {
                    _selectedNodeIDs.subtract(allNodeIDs)
                } else {
                    _selectedNodeIDs.formUnion(allNodeIDs)
                }
            } label: {
                VStack(spacing: 1) {
                    Image(systemName: allNodesSelected ? "checkmark.circle.fill" : "circle")
                        .font(_font(13, weight: .semibold))
                        .foregroundStyle(allNodesSelected ? _dodgersBlue : Color.secondary)
                    Text(L("全ノード", "All nodes"))
                        .font(_font(8, weight: .semibold))
                        .foregroundStyle(allNodesSelected ? _dodgersBlue : Color.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(allNodeIDs.isEmpty || _isGenerationRunning)

            Button {
                if allPaperLeavesSelected {
                    _selectedPaperLeafKeys.subtract(allPaperLeafKeys)
                } else {
                    _selectedPaperLeafKeys.formUnion(allPaperLeafKeys)
                }
            } label: {
                VStack(spacing: 1) {
                    Image(systemName: allPaperLeavesSelected ? "checkmark.circle.fill" : "circle")
                        .font(_font(13, weight: .semibold))
                        .foregroundStyle(_paperNodePurple)
                    Text(L("論文リーフ", "Paper leaves"))
                        .font(_font(8, weight: .semibold))
                        .foregroundStyle(allPaperLeavesSelected ? _paperNodePurple : Color.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(allPaperLeafKeys.isEmpty || _isGenerationRunning)

            Text("\(selectedPaperLeafCount)/\(allPaperLeafKeys.count)")
            .font(_font(11, weight: .semibold))
            .foregroundStyle(_paperNodePurple)
            .accessibilityLabel(L(
                "選択中の論文リーフ \(selectedPaperLeafCount) / \(allPaperLeafKeys.count)",
                "Selected paper leaves \(selectedPaperLeafCount) / \(allPaperLeafKeys.count)"
            ))

            Button {
                if hasAllPaperKeysSelected {
                    _selectedPaperKeys.subtract(allKeys)
                } else {
                    _selectedPaperKeys.formUnion(allKeys)
                }
            } label: {
                VStack(spacing: 1) {
                    Image(systemName: allPapersSelected ? "checkmark.square.fill" : "square")
                        .font(_font(13, weight: .semibold))
                        .foregroundStyle(allPapersSelected ? _dodgersBlue : Color.secondary)
                    Text(L("全演習", "All"))
                        .font(_font(8, weight: .semibold))
                        .foregroundStyle(allPapersSelected ? _dodgersBlue : Color.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(allKeys.isEmpty || _isGenerationRunning)

            if !allPythonKeys.isEmpty {
                Button {
                    if hasAllPythonKeysSelected {
                        _selectedPythonPaperKeys.subtract(allPythonKeys)
                    } else {
                        _selectedPythonPaperKeys.formUnion(allPythonKeys)
                    }
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: hasAllPythonKeysSelected ? "checkmark.square.fill" : "square")
                            .font(_font(13, weight: .semibold))
                            .foregroundStyle(Color.green)
                        Text("py")
                            .font(_font(8, weight: .semibold))
                            .foregroundStyle(Color.green)
                    }
                }
                .buttonStyle(.plain)
                .disabled(_isGenerationRunning)
            }

            Text(L("ノード \(allNodeIDs.count) / 論文 \(allKeys.count)", "\(allNodeIDs.count) nodes / \(allKeys.count) papers"))
                .font(_font(12))
                .foregroundStyle(_dodgersBlueSecondary)

        }
    }

    private struct _LeafNodeGroup: Identifiable {
        let id: String
        let entries: [Inf6EshikakuDrillPipeline.DrillEntry]
        let unresolved: Inf6EshikakuDrillPipeline.OriginUnverifiedItem?
    }

    private func _paperKey(_ entry: Inf6EshikakuDrillPipeline.DrillEntry) -> String {
        "\(entry.syllabusNodeID ?? entry.id)|\(entry.paper.id)"
    }

    private func _entryAnchorID(_ entryID: String) -> String {
        "drill-entry-\(entryID)"
    }

    private func _leafAnchorID(_ nodeID: String) -> String {
        "drill-leaf-\(nodeID)"
    }

    private func _isPythonNode(_ entry: Inf6EshikakuDrillPipeline.DrillEntry) -> Bool {
        return entry.paper.tags.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "requires_python_code"
        }
    }

    private func _isPythonGenerationTarget(_ entry: Inf6EshikakuDrillPipeline.DrillEntry) -> Bool {
        guard !_isTextbookField(entry) else { return false }
        return _isPythonNode(entry)
    }

    private func _paperProviderLabel(_ entry: Inf6EshikakuDrillPipeline.DrillEntry) -> String? {
        guard !_isTextbookField(entry) else { return nil }
        let provider = entry.paper.provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.isEmpty else { return nil }
        switch provider.lowercased() {
        case "arxiv":
            return "arXiv"
        case "pubmed":
            return "PubMed"
        case "pdf_import":
            return "PDF"
        default:
            return provider
        }
    }

    private func _paperProviderBadge(_ provider: String, size: CGFloat = 14) -> some View {
        Text(provider)
            .font(.system(size: size * _fontScale, weight: .heavy, design: .serif))
            .italic()
            .foregroundStyle(_dodgersBlue)
            .padding(.horizontal, max(7, size * 0.65))
            .padding(.vertical, max(3, size * 0.24))
            .background {
                RoundedRectangle(cornerRadius: max(5, size * 0.36), style: .continuous)
                    .fill(_dodgersBlue.opacity(0.14))
            }
            .overlay {
                RoundedRectangle(cornerRadius: max(5, size * 0.36), style: .continuous)
                    .stroke(_dodgersBlue.opacity(0.46), lineWidth: 1.2)
            }
            .fixedSize()
            .textSelection(.enabled)
    }

    private func _isSelectedForPractice(_ entry: Inf6EshikakuDrillPipeline.DrillEntry) -> Bool {
        let key = _paperKey(entry)
        return _selectedPaperKeys.contains(key) || _selectedPythonPaperKeys.contains(key)
    }

    private func _needsBaseQuizGeneration(_ entry: Inf6EshikakuDrillPipeline.DrillEntry) -> Bool {
        guard let quiz = entry.quiz, !quiz.questions.isEmpty else { return true }
        return !quiz.questions.contains { $0.normalizedExerciseType == "regular" }
    }

    private func _needsPythonQuizGeneration(_ entry: Inf6EshikakuDrillPipeline.DrillEntry) -> Bool {
        guard let quiz = entry.quiz, !quiz.questions.isEmpty else { return _isPythonGenerationTarget(entry) }
        guard _isPythonGenerationTarget(entry) else { return false }
        let hasPyTorch = quiz.questions.contains { question in
            question.normalizedExerciseType == "py"
                && (question.coverageTargetIDs ?? []).contains { targetID in
                    targetID.lowercased().hasPrefix("code-practice-pytorch-")
                }
        }
        let hasTensorFlow = quiz.questions.contains { question in
            question.normalizedExerciseType == "py"
                && (question.coverageTargetIDs ?? []).contains { targetID in
                    targetID.lowercased().hasPrefix("code-practice-tensorflow-")
                }
        }
        return !hasPyTorch || !hasTensorFlow
    }

    private func _pythonFramework(for question: Inf6PaperQuizQuestion) -> _PythonPracticeFramework? {
        guard question.normalizedExerciseType == "py" else { return nil }
        let ids = (question.coverageTargetIDs ?? []).map { $0.lowercased() }.joined(separator: " ")
        if ids.contains("code-practice-tensorflow-") { return .tensorflow }
        if ids.contains("code-practice-pytorch-") { return .pytorch }
        return nil
    }

    private func _displayQuestions(
        _ quiz: Inf6PaperQuiz,
        for entry: Inf6EshikakuDrillPipeline.DrillEntry? = nil
    ) -> [Inf6PaperQuizQuestion] {
        guard let entry else { return quiz.questions }
        let key = _paperKey(entry)
        let regularSelected = _selectedPaperKeys.contains(key)
        let pythonSelected = _selectedPythonPaperKeys.contains(key)
        guard regularSelected || pythonSelected else { return [] }

        return quiz.questions.filter { question in
            if question.normalizedExerciseType == "py" {
                return pythonSelected && _pythonFramework(for: question) == _selectedPythonPracticeFramework
            }
            return regularSelected
        }
    }

    private func _liveBPQuestions(
        _ quiz: Inf6PaperQuiz,
        for entry: Inf6EshikakuDrillPipeline.DrillEntry
    ) -> [Inf6PaperQuizQuestion] {
        let generatedPaperKey = _liveBPGeneratedPaperKey(for: entry) ?? entry.folderKey
        // DrillEntry can be an older value captured by the slideshow view.
        // Resolve the quiz again from the same paper key that receives the
        // generated item so the newly appended question is visible in the
        // current render as well as after reopening the screen.
        let latestQuiz = Inf6MetadataStore.getCodable(
            Inf6PaperQuiz.self,
            domain: .quiz,
            key: generatedPaperKey
        ) ?? quiz
        let baseQuestions = _displayQuestions(latestQuiz, for: entry)
        let baseIDs = Set(baseQuestions.map(\.id))
        // The view-state cache is keyed by paper, while a drill entry is keyed
        // by syllabus leaf.  A newly generated understanding point can
        // therefore be persisted before the cache for generatedPaperKey has
        // been loaded.  Read the persisted book as the source of truth here;
        // otherwise the item disappears until an unrelated reload populates
        // the second cache key.
        let cachedExercises = _liveBPGeneratedByPaperKey[generatedPaperKey] ?? []
        let persistedExercises = Inf6LiveBPGeneratedExerciseStore.load(
            paperKey: generatedPaperKey
        ).exercises
        var generatedExercises = cachedExercises
        var knownGeneratedIDs = Set(cachedExercises.map(\.id))
        for exercise in persistedExercises where knownGeneratedIDs.insert(exercise.id).inserted {
            generatedExercises.append(exercise)
        }
        let generatedQuestions = generatedExercises
            .map { $0.asQuizQuestion() }
            .filter { !baseIDs.contains($0.id) }
        return baseQuestions + generatedQuestions
    }

    private func _detailQuestions(_ quiz: Inf6PaperQuiz, for entry: Inf6EshikakuDrillPipeline.DrillEntry) -> [Inf6PaperQuizQuestion] {
        // 詳細画面も Live BP と同じ表示元を使う。追加演習・追加理解ポイントは
        // 生成演習ストアから読み込まれるため、quiz.questions だけでは追加直後に欠落する。
        let questions = _liveBPQuestions(quiz, for: entry)
        switch _detailQuestionFilterByEntryID[entry.id] ?? .all {
        case .all:
            return questions
        case .python:
            return questions.filter { $0.normalizedExerciseType == "py" }
        case .regular:
            return questions.filter { $0.normalizedExerciseType == "regular" }
        }
    }

    private func _practiceCounts(_ quiz: Inf6PaperQuiz) -> (py: Int, regular: Int) {
        let py = quiz.questions.filter { $0.normalizedExerciseType == "py" }.count
        return (py: py, regular: max(quiz.questions.count - py, 0))
    }

    private func _leafNodeGroups(_ group: Inf6EshikakuDrillPipeline.DrillGroup) -> [_LeafNodeGroup] {
        var entriesByNode: [String: [Inf6EshikakuDrillPipeline.DrillEntry]] = [:]
        for entry in group.entries {
            entriesByNode[entry.syllabusNodeID ?? entry.id, default: []].append(entry)
        }
        var unresolvedByNode: [String: Inf6EshikakuDrillPipeline.OriginUnverifiedItem] = [:]
        for item in group.unverifiedOrigins {
            unresolvedByNode[item.nodeID] = item
        }
        let allNodeIDs = Set(entriesByNode.keys).union(unresolvedByNode.keys)
        return allNodeIDs.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { nid in
            _LeafNodeGroup(
                id: nid,
                entries: (entriesByNode[nid] ?? []).sorted { $0.paper.title < $1.paper.title },
                unresolved: unresolvedByNode[nid]
            )
        }
    }

    @ViewBuilder
    private func _nodeDomainSection(_ group: Inf6EshikakuDrillPipeline.DrillGroup) -> some View {
        let leaves = _leafNodeGroups(group)
        let collapsed = _collapsedDomainIDs.contains(group.id)
        let allSelected = !leaves.isEmpty && leaves.allSatisfy { _selectedNodeIDs.contains($0.id) }

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                // ドメイン配下をまとめて選ぶ丸。下段の行と同じ形にして左端に揃える。
                Button {
                    if allSelected {
                        for leaf in leaves { _selectedNodeIDs.remove(leaf.id) }
                    } else {
                        for leaf in leaves { _selectedNodeIDs.insert(leaf.id) }
                    }
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(allSelected ? _domainTint(group.id) : .secondary)
                        Text(allSelected ? L("全解除", "Deselect") : L("全選択", "Select"))
                            .font(_font(8, weight: .semibold))
                            .foregroundStyle(allSelected ? _domainTint(group.id) : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(leaves.isEmpty)

                // ドメイン配下の演習をまとめて選ぶ四角。全体の見出しには丸と
                // 四角の両方があるのに、ここには丸しか無かった。分野ごとに
                // まとめて生成したいときに、行を一つずつ押すしかなかった。
                let domainEntries = leaves.flatMap { $0.entries }
                if !domainEntries.isEmpty {
                    let hasAllDomainPapersSelected = domainEntries.allSatisfy { _selectedPaperKeys.contains(_paperKey($0)) }
                    let allPapersSelected = hasAllDomainPapersSelected
                    Button {
                        if hasAllDomainPapersSelected {
                            for entry in domainEntries { _selectedPaperKeys.remove(_paperKey(entry)) }
                        } else {
                            for entry in domainEntries { _selectedPaperKeys.insert(_paperKey(entry)) }
                        }
                    } label: {
                        VStack(spacing: 1) {
                            Image(systemName: allPapersSelected ? "checkmark.square.fill" : "square")
                                .foregroundStyle(allPapersSelected ? _domainTint(group.id) : .secondary)
                            Text(L("全演習", "All"))
                                .font(_font(8, weight: .semibold))
                                .foregroundStyle(allPapersSelected ? _domainTint(group.id) : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(L("この分野の演習をまとめて選ぶ", "Select every exercise in this domain"))

                    let domainPythonEntries = domainEntries.filter(_isPythonNode)
                    if !domainPythonEntries.isEmpty {
                        let hasAllDomainPythonSelected = domainPythonEntries.allSatisfy {
                            _selectedPythonPaperKeys.contains(_paperKey($0))
                        }
                        Button {
                            if hasAllDomainPythonSelected {
                                for entry in domainPythonEntries {
                                    _selectedPythonPaperKeys.remove(_paperKey(entry))
                                }
                            } else {
                                for entry in domainPythonEntries {
                                    _selectedPythonPaperKeys.insert(_paperKey(entry))
                                }
                            }
                        } label: {
                            VStack(spacing: 1) {
                                Image(systemName: hasAllDomainPythonSelected ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(Color.green)
                                Text("全py")
                                    .font(_font(8, weight: .semibold))
                                    .foregroundStyle(Color.green)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(L("この分野のPython演習をまとめて選ぶ", "Select every Python exercise in this domain"))
                    }
                }

                Button {
                    if collapsed { _collapsedDomainIDs.remove(group.id) } else { _collapsedDomainIDs.insert(group.id) }
                } label: {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .foregroundStyle(_dodgersBlueSecondary)
                }
                .buttonStyle(.plain)

                RoundedRectangle(cornerRadius: 2)
                    .fill(_domainTint(group.id))
                    .frame(width: 5, height: 30)
                Text(L(group.labelJa, group.labelEn))
                    .font(_font(24, weight: .bold))
                    .foregroundStyle(_dodgersBlue)
                    .textSelection(.enabled)

                if let score = _syllabusImportanceByDomainID[group.id]?.examImportanceScore {
                    _importanceAdjustMenu(
                        score: score,
                        help: L("このドメインのE資格重要度を調整", "Adjust this domain's exam importance"),
                        onDelta: { delta in _adjustDomainImportance(group, delta: delta) }
                    )
                }

                Spacer()
            }

            if !collapsed {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(leaves) { leaf in
                        _leafNodeRow(leaf, group: group)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func _leafNodeRow(_ leaf: _LeafNodeGroup, group: Inf6EshikakuDrillPipeline.DrillGroup) -> some View {
        let tint = _domainTint(group.id)
        let nodeSelected = _selectedNodeIDs.contains(leaf.id)
        let paperEntries = leaf.entries.filter { !_isTextbookField($0) }
        let explanationEntries = leaf.entries.filter(_isTextbookField)
        let paperLeafKeys = leaf.entries
            .filter { !_isTextbookField($0) }
            .map { _paperKey($0) }
        let paperNodeSelected = !paperLeafKeys.isEmpty
            && paperLeafKeys.allSatisfy { _selectedPaperLeafKeys.contains($0) }
        let originExploring = _exploringOriginNodeIDs.contains(leaf.id)
        let leafTitle = leaf.unresolved.map { $0.titleJa.isEmpty ? $0.titleEn : $0.titleJa }
            ?? leaf.entries.first?.syllabusTitle
            ?? leaf.id

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                // 起源探索チェックボックスは解決済み/未解決の両方で表示する。
                // 解決済みノードでも追加の起源論文を探索できる(既存論文は上書きされず、
                // 新たに見つかった論文が追加される)。
                Button {
                    if nodeSelected {
                        _selectedNodeIDs.remove(leaf.id)
                    } else {
                        _selectedNodeIDs.insert(leaf.id)
                    }
                } label: {
                    VStack(spacing: 1) {
                        if originExploring {
                            ProgressView().tint(.pink).scaleEffect(1.25)
                                .controlSize(.large)
                                .scaleEffect(1.2)
                                .frame(width: 28, height: 28)
                        } else {
                            Image(systemName: nodeSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(nodeSelected ? tint : .secondary)
                        }
                        Text(L("探索", "Explore"))
                            .font(_font(8, weight: .semibold))
                            .foregroundStyle(originExploring || nodeSelected ? tint : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(originExploring)

                if !paperLeafKeys.isEmpty {
                    Button {
                        if paperNodeSelected {
                            _selectedPaperLeafKeys.subtract(paperLeafKeys)
                        } else {
                            _selectedPaperLeafKeys.formUnion(paperLeafKeys)
                        }
                    } label: {
                        VStack(spacing: 1) {
                            Image(systemName: paperNodeSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(_paperNodePurple)
                            Text(L("論文", "Paper"))
                                .font(_font(8, weight: .semibold))
                                .foregroundStyle(_paperNodePurple)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(L("この論文ノード配下の論文リーフを選択", "Select paper leaves under this paper node"))
                }

                // 配下の論文をまとめて選ぶチェックボックス。下段の論文行と同じ四角で、
                // 探索の丸と並べて左端に置く。
                if !paperEntries.isEmpty {
                    let allPapersSelected = paperEntries.allSatisfy { _selectedPaperKeys.contains(_paperKey($0)) }
                    Button {
                        if allPapersSelected {
                            for entry in paperEntries { _selectedPaperKeys.remove(_paperKey(entry)) }
                        } else {
                            for entry in paperEntries { _selectedPaperKeys.insert(_paperKey(entry)) }
                        }
                    } label: {
                        VStack(spacing: 1) {
                            Image(systemName: allPapersSelected ? "checkmark.square.fill" : "square")
                                .foregroundStyle(allPapersSelected ? tint : .secondary)
                            Text(L("全演習", "All"))
                                .font(_font(8, weight: .semibold))
                                .foregroundStyle(allPapersSelected ? tint : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(L("この概念の演習をまとめて選ぶ", "Select every exercise under this concept"))
                }

                let pythonEntries = leaf.entries.filter(_isPythonNode)
                if pythonEntries.count > 1 {
                    let allPythonSelected = pythonEntries.allSatisfy { _selectedPythonPaperKeys.contains(_paperKey($0)) }
                    Button {
                        if allPythonSelected {
                            for entry in pythonEntries { _selectedPythonPaperKeys.remove(_paperKey(entry)) }
                        } else {
                            for entry in pythonEntries { _selectedPythonPaperKeys.insert(_paperKey(entry)) }
                        }
                    } label: {
                        VStack(spacing: 1) {
                            Image(systemName: allPythonSelected ? "checkmark.square.fill" : "square")
                                .foregroundStyle(Color.green)
                            Text("py")
                                .font(_font(8, weight: .semibold))
                                .foregroundStyle(Color.green)
                        }
                    }
                    .buttonStyle(.plain)
                }

                // ノード種別は独立した見出し行を作らず、ノード名の直前に文字バッジで示す。
                if !paperEntries.isEmpty {
                    Text(L("論文", "Paper"))
                        .font(_font(10, weight: .bold))
                        .foregroundStyle(_paperNodePurple)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(_paperNodePurple.opacity(0.12), in: Capsule())
                        .help(L("論文リーフを含むノード", "Node containing paper leaves"))
                }
                if !explanationEntries.isEmpty {
                    Text(L("解説", "Explanation"))
                        .font(_font(10, weight: .bold))
                        .foregroundStyle(_dodgersBlue)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(_dodgersBlue.opacity(0.12), in: Capsule())
                        .help(L("オリジナル解説リーフを含むノード", "Node containing original explanation leaves"))
                }
                if leaf.unresolved != nil && paperEntries.isEmpty && explanationEntries.isEmpty {
                    Text(L("解説", "Explanation"))
                        .font(_font(10, weight: .bold))
                        .foregroundStyle(_dodgersBlue)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(_dodgersBlue.opacity(0.12), in: Capsule())
                        .help(L("起源未解決の解説ノード", "Explanation node with unresolved origin"))
                }

                Text(leafTitle)
                    .font(_font(18, weight: .semibold))
                    .foregroundStyle(_dodgersBlue)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if let score = _syllabusImportanceByNodeID[leaf.id]?.examImportanceScore {
                    _importanceAdjustMenu(
                        score: score,
                        help: L("このノードのE資格重要度を調整", "Adjust this node's exam importance"),
                        onDelta: { delta in _adjustNodeImportance(leaf, delta: delta) }
                    )
                }

                Spacer(minLength: 8)
            }

            if let unresolved = leaf.unresolved {
                _originUnverifiedRow(unresolved)
            } else {
                if !paperEntries.isEmpty {
                    ForEach(paperEntries) { entry in
                        _paperSelectionRow(
                            entry,
                            domainID: group.id,
                            hideDuplicateTitle: entry.paper.title.trimmingCharacters(in: .whitespacesAndNewlines) == leafTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        if _selectedEntryID == entry.id, _entryHasDetail(entry) {
                            _selectedEntryDetail(entry: entry, group: group)
                        }
                    }
                }

                if !explanationEntries.isEmpty {
                    ForEach(explanationEntries) { entry in
                        _paperSelectionRow(entry, domainID: group.id)
                        if _selectedEntryID == entry.id, _entryHasDetail(entry) {
                            _selectedEntryDetail(entry: entry, group: group)
                        }
                    }
                }
            }
        }
        .id(_leafAnchorID(leaf.id))
    }

    @ViewBuilder
    private func _importanceAdjustMenu(
        score: Int,
        help: String,
        onDelta: @escaping (Int) -> Void
    ) -> some View {
        Menu {
            Button("+5") { onDelta(5) }
                .disabled(score >= 100)
            Button("+1") { onDelta(1) }
                .disabled(score >= 100)
            Button("-1") { onDelta(-1) }
                .disabled(score <= 0)
            Button("-5") { onDelta(-5) }
                .disabled(score <= 0)
        } label: {
            Text("IMP \(score)")
                .font(_font(11, weight: .bold))
                .foregroundStyle(_dodgersBlue)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(_dodgersBlue.opacity(0.10))
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .stroke(_dodgersBlue.opacity(0.30), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @MainActor
    private func _adjustDomainImportance(
        _ group: Inf6EshikakuDrillPipeline.DrillGroup,
        delta: Int
    ) {
        guard var book = Inf6SyllabusImportanceScoreStore.load(sourceFamily: sourceFamily) else { return }
        guard let index = book.domains.firstIndex(where: { $0.id == group.id }) else { return }
        book.domains[index].examImportanceScore = min(max(book.domains[index].examImportanceScore + delta, 0), 100)
        book.domains[index].examImportanceReason = _manualImportanceReason(book.domains[index].examImportanceReason)
        book.domains[index].evaluatedAt = Date().timeIntervalSince1970
        guard Inf6SyllabusImportanceScoreStore.save(book) else {
            _genErrors["syllabus_importance"] = "E資格ドメイン重要度を保存できませんでした。"
            return
        }
        _reloadSyllabusImportanceScores()
    }

    @MainActor
    private func _adjustNodeImportance(
        _ leaf: _LeafNodeGroup,
        delta: Int
    ) {
        guard var book = Inf6SyllabusImportanceScoreStore.load(sourceFamily: sourceFamily) else { return }
        guard let index = book.nodes.firstIndex(where: { $0.nodeID == leaf.id || $0.id == leaf.id }) else { return }
        book.nodes[index].examImportanceScore = min(max(book.nodes[index].examImportanceScore + delta, 0), 100)
        book.nodes[index].examImportanceReason = _manualImportanceReason(book.nodes[index].examImportanceReason)
        book.nodes[index].evaluatedAt = Date().timeIntervalSince1970
        guard Inf6SyllabusImportanceScoreStore.save(book) else {
            _genErrors["syllabus_importance"] = "E資格ノード重要度を保存できませんでした。"
            return
        }
        _reloadSyllabusImportanceScores()
    }

    private func _manualImportanceReason(_ previous: String) -> String {
        let trimmed = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("Manual: ") { return trimmed }
        if trimmed.isEmpty { return "Manual: adjusted by user." }
        return "Manual: \(trimmed)"
    }


    /// 解説項目の合成ノードかどうか。
    /// 合成レコードは provider で見分ける。
    private func _isTextbookField(_ entry: Inf6EshikakuDrillPipeline.DrillEntry) -> Bool {
        Inf6EshikakuDrillPipeline.isGeneratedExplanationProvider(entry.paper.provider)
    }

    private func _entryHasDetail(_ entry: Inf6EshikakuDrillPipeline.DrillEntry) -> Bool {
        entry.quiz?.questions.isEmpty == false
    }

    private func _visualEntityCount(for entry: Inf6EshikakuDrillPipeline.DrillEntry) -> Int {
        _visualEntityCounts[entry.folderKey] ?? 0
    }

    @MainActor
    private func _refreshVisualEntityCounts(
        for groups: [Inf6EshikakuDrillPipeline.DrillGroup]
    ) {
        _visualEntityCountTask?.cancel()
        let folderKeys = Array(Set(groups.flatMap(\.entries)
            .filter { !_isTextbookField($0) }
            .map(\.folderKey)))
        _visualEntityCounts = [:]
        _visualEntityCountTask = Task { [folderKeys] in
            let counts = await Task.detached(priority: .utility) {
                var result: [String: Int] = [:]
                for folderKey in folderKeys {
                    guard let index = Inf6MetadataStore.getCodable(
                        Inf6DocEntityIndex.self,
                        domain: .docEntities,
                        key: folderKey
                    ) else { continue }
                    result[folderKey] = index.entities.reduce(into: 0) { count, entity in
                        let imagePath = entity.imagePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if !imagePath.isEmpty { count += 1 }
                    }
                }
                return result
            }.value
            guard !Task.isCancelled else { return }
            _visualEntityCounts = counts
        }
    }

    @MainActor
    private func _toggleEntryDetail(_ entry: Inf6EshikakuDrillPipeline.DrillEntry) {
        guard _entryHasDetail(entry) else {
            if _selectedEntryID == entry.id { _selectedEntryID = nil }
            return
        }
        _detailQuestionFilterByEntryID[entry.id] = .all
        _selectedEntryID = (_selectedEntryID == entry.id) ? nil : entry.id
    }

    @MainActor
    private func _showEntryDetail(_ entry: Inf6EshikakuDrillPipeline.DrillEntry, filter: _PracticeQuestionFilter) {
        guard _entryHasDetail(entry) else { return }
        _detailQuestionFilterByEntryID[entry.id] = filter
        _selectedEntryID = entry.id
    }

    @ViewBuilder
    private func _paperSelectionRow(
        _ entry: Inf6EshikakuDrillPipeline.DrillEntry,
        domainID: String,
        hideDuplicateTitle: Bool = false
    ) -> some View {
        let tint = _domainTint(domainID)
        let key = _paperKey(entry)
        let paperSelected = _selectedPaperKeys.contains(key)
        let pythonNode = _isPythonNode(entry)
        let pythonSelected = _selectedPythonPaperKeys.contains(key)
        let detailSelected = _selectedEntryID == entry.id
        let year = entry.paper.year.map { " (\($0))" } ?? ""

        HStack(alignment: .center, spacing: 12) {
            if !_isTextbookField(entry) {
                let paperLeafSelected = _selectedPaperLeafKeys.contains(key)
                Button {
                    if paperLeafSelected {
                        _selectedPaperLeafKeys.remove(key)
                    } else {
                        _selectedPaperLeafKeys.insert(key)
                    }
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: paperLeafSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(_paperNodePurple)
                        Text(L("論文", "Paper"))
                            .font(_font(8, weight: .semibold))
                            .foregroundStyle(_paperNodePurple)
                    }
                }
                .buttonStyle(.plain)
                .help(L("この論文リーフを選択", "Select this paper leaf"))
            }

            Button {
                if paperSelected {
                    _selectedPaperKeys.remove(key)
                } else {
                    _selectedPaperKeys.insert(key)
                }
            } label: {
                VStack(spacing: 1) {
                    Image(systemName: paperSelected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(paperSelected ? tint : .secondary)
                    Text(L("演習", "Quiz"))
                        .font(_font(8, weight: .semibold))
                        .foregroundStyle(paperSelected ? tint : .secondary)
                }
            }
            .buttonStyle(.plain)

            if pythonNode {
                Button {
                    if pythonSelected {
                        _selectedPythonPaperKeys.remove(key)
                    } else {
                        _selectedPythonPaperKeys.insert(key)
                    }
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: pythonSelected ? "checkmark.square.fill" : "square")
                            .foregroundStyle(Color.green)
                        Text("py")
                            .font(_font(8, weight: .semibold))
                            .foregroundStyle(Color.green)
                    }
                }
                .buttonStyle(.plain)
            }

            Button {
                _toggleEntryDetail(entry)
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(detailSelected ? tint : tint.opacity(0.42))
                        .frame(width: detailSelected ? 5 : 3)

                    VStack(alignment: .leading, spacing: 4) {
                        if _isTextbookField(entry) {
                            Text(L("解説・演習", "Explanation and quiz"))
                                .font(_font(13))
                                .foregroundStyle(_dodgersBlueSecondary)
                        } else if !hideDuplicateTitle {
                            Text("\(entry.paper.title)\(year)")
                                .font(_font(15, weight: .medium))
                                .foregroundStyle(_dodgersBlueSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        } else {
                            Text(L("解説・演習", "Explanation and quiz"))
                                .font(_font(13))
                                .foregroundStyle(_dodgersBlueSecondary)
                        }
                    }

                    if !_isTextbookField(entry) {
                        let visualCount = _visualEntityCount(for: entry)
                        if visualCount > 0 {
                            Text(L("図表数式 \(visualCount)", "Visuals \(visualCount)"))
                                .font(_font(11, weight: .semibold))
                                .foregroundStyle(_dodgersBlue)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(_dodgersBlue.opacity(0.10), in: Capsule())
                                .accessibilityLabel(L(
                                    "図・表・数式 \(visualCount)件",
                                    "\(visualCount) figures, tables, and equations"
                                ))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !_generatingKeys.contains(entry.folderKey),
               !_deletingQuizKeys.contains(entry.folderKey) {
                let counts = entry.quiz.map(_practiceCounts) ?? (py: 0, regular: 0)
                HStack(spacing: 8) {
                    if counts.py > 0 {
                        Button {
                            if _entryHasDetail(entry) {
                                _showEntryDetail(entry, filter: .python)
                            }
                        } label: {
                            Text(L("\(counts.py) py演習", "\(counts.py) py exercises"))
                                .font(_font(13, weight: .bold))
                                .foregroundStyle(Color.green)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.green.opacity(0.10))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("py演習だけを表示", "Show Python exercises only"))
                        .help(L("py演習カードだけを表示", "Show Python exercise cards only"))
                    }
                    if counts.regular > 0 {
                        Button {
                            _showEntryDetail(entry, filter: .regular)
                        } label: {
                            Text(L("\(counts.regular) 演習", "\(counts.regular) exercises"))
                                .font(_font(13, weight: .bold))
                                .foregroundStyle(_dodgersBlue)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(_dodgersBlue.opacity(0.08))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("通常演習だけを表示", "Show regular exercises only"))
                        .help(L("通常演習カードだけを表示", "Show regular exercise cards only"))
                    }
                    if counts.py > 0 {
                        Button(role: .destructive) {
                            _deleteGeneratedQuizQuestions(entry, deletingCodeQuestions: true)
                        } label: {
                            Label(L("py", "py"), systemImage: "trash")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(Color.green)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("py演習を削除", "Delete Python exercises"))
                        .help(L("py演習だけを削除", "Delete Python exercises only"))
                    }
                    if counts.regular > 0 {
                        Button(role: .destructive) {
                            _deleteGeneratedQuizQuestions(entry, deletingCodeQuestions: false)
                        } label: {
                            Label(L("演習", "Exercises"), systemImage: "trash")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(_dodgersBlueSecondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("演習を削除", "Delete exercises"))
                        .help(L("通常演習だけを削除", "Delete non-Python exercises only"))
                    }
                }
                .disabled(!_generatingKeys.isEmpty || !_deletingQuizKeys.isEmpty || !_exploringOriginNodeIDs.isEmpty || _recutInProgress)
            }

            if _generatingKeys.contains(entry.folderKey) {
                HStack(spacing: 8) {
                    ProgressView().tint(.pink).scaleEffect(1.25)
                        .controlSize(.large)
                        .scaleEffect(1.2)
                        .frame(width: 28, height: 28)
                    Button(role: .cancel) {
                        _cancelGeneration(key: entry.folderKey)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.bordered)
                }
            }

            _openPaperButton(entry)

            if !_generatingKeys.contains(entry.folderKey), !_deletingQuizKeys.contains(entry.folderKey) {
                // 演習の削除と起源論文の削除は別物なので、どちらを消すのかを
                // 文言で明示して選ばせる。片方の操作でもう片方まで消さない。
                Menu {
                    Button(role: .destructive) {
                        _deleteOriginPaper(entry)
                    } label: {
                        // 解説項目には論文タイトルを表示しない。
                        Label(
                            _isTextbookField(entry)
                                ? L("分類を削除", "Delete classification")
                                : L("起源論文を削除", "Delete origin paper"),
                            systemImage: "trash"
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(_dodgersBlueSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("削除メニュー", "Delete menu"))
                .disabled(!_generatingKeys.isEmpty || !_deletingQuizKeys.isEmpty || !_exploringOriginNodeIDs.isEmpty || _recutInProgress)
            }
        }
        .padding(.leading, 28)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(detailSelected ? tint.opacity(0.08) : Color(uiColor: .secondarySystemBackground).opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(detailSelected ? tint.opacity(0.55) : tint.opacity(0.14), lineWidth: detailSelected ? 1.4 : 1)
                .allowsHitTesting(false)
        }
        .textSelection(.enabled)
        .id(_entryAnchorID(entry.id))
    }

    /// 生成済みの演習だけを削除する。起源論文はそのまま残るので、
    /// 再生成すれば同じ論文から演習を作り直せる。
    @MainActor
    private func _deleteGeneratedQuiz(_ entry: Inf6EshikakuDrillPipeline.DrillEntry) {
        Inf6EshikakuDrillPipeline.deleteGeneratedQuiz(
            folderKey: entry.folderKey,
            paperTitle: entry.paper.title,
            paperID: entry.paper.id
        )
        if _slideshowPlayingPaperKey == entry.folderKey {
            _stopSlideshow()
        }
        _detailQuestionFilterByEntryID.removeValue(forKey: entry.id)
        _selectedPythonPaperKeys.remove(_paperKey(entry))
        _askNotesByPaperKey[entry.folderKey] = []
        _slideshowProgressByPaperKey.removeValue(forKey: entry.folderKey)
        _slideshowCurrentIndexByPaperKey.removeValue(forKey: entry.folderKey)
        Inf6DrillSlideshowProgressStore.delete(paperKey: entry.folderKey)
        Task {
            await _loadAll(forceReload: true)
        }
    }

    @MainActor
    private func _deleteGeneratedQuizQuestions(
        _ entry: Inf6EshikakuDrillPipeline.DrillEntry,
        deletingCodeQuestions: Bool
    ) {
        guard !_deletingQuizKeys.contains(entry.folderKey) else { return }
        _deletingQuizKeys.insert(entry.folderKey)
        let folderKey = entry.folderKey
        let paperTitle = entry.paper.title
        let paperID = entry.paper.id
        let entryID = entry.id
        let paperKey = _paperKey(entry)
        if _slideshowPlayingPaperKey == entry.folderKey {
            _stopSlideshow()
        }
        Task {
            await Task.detached(priority: .userInitiated) {
                Inf6EshikakuDrillPipeline.deleteGeneratedQuizQuestions(
                    folderKey: folderKey,
                    paperTitle: paperTitle,
                    paperID: paperID,
                    deletingCodeQuestions: deletingCodeQuestions
                )
                Inf6DrillSlideshowProgressStore.delete(paperKey: folderKey)
            }.value
            await MainActor.run {
                _applyDeletedGeneratedQuizQuestions(
                    folderKey: folderKey,
                    entryID: entryID,
                    paperKey: paperKey,
                    deletingCodeQuestions: deletingCodeQuestions
                )
                _deletingQuizKeys.remove(folderKey)
            }
        }
    }

    @MainActor
    private func _applyDeletedGeneratedQuizQuestions(
        folderKey: String,
        entryID: String,
        paperKey: String,
        deletingCodeQuestions: Bool
    ) {
        for groupIndex in _groups.indices {
            for entryIndex in _groups[groupIndex].entries.indices
            where _groups[groupIndex].entries[entryIndex].folderKey == folderKey {
                if var quiz = _groups[groupIndex].entries[entryIndex].quiz {
                    quiz.questions.removeAll { question in
                        (question.normalizedExerciseType == "py") == deletingCodeQuestions
                    }
                    _groups[groupIndex].entries[entryIndex].quiz = quiz.questions.isEmpty ? nil : quiz
                }
            }
        }
        Self._loadedGroupsBySourceFamily[sourceFamily] = _groups
        _detailQuestionFilterByEntryID.removeValue(forKey: entryID)
        if deletingCodeQuestions {
            _selectedPythonPaperKeys.remove(paperKey)
        }
        _askNotesByPaperKey[folderKey] = Inf6DrillAskNoteStore.load(paperKey: folderKey).notes
        _slideshowProgressByPaperKey.removeValue(forKey: folderKey)
        _slideshowCurrentIndexByPaperKey.removeValue(forKey: folderKey)
    }

    @MainActor
    private func _deleteOriginPaper(_ entry: Inf6EshikakuDrillPipeline.DrillEntry) {
        guard let nodeID = entry.syllabusNodeID else { return }
        Inf6EshikakuDrillPipeline.deleteOriginRecord(
            sourceFamily: sourceFamily,
            nodeID: nodeID,
            paperID: entry.paper.id
        )
        if _slideshowPlayingPaperKey == entry.folderKey {
            _stopSlideshow()
        }
        _detailQuestionFilterByEntryID.removeValue(forKey: entry.id)
        _selectedPaperKeys.remove(_paperKey(entry))
        _selectedPythonPaperKeys.remove(_paperKey(entry))
        _slideshowProgressByPaperKey.removeValue(forKey: entry.folderKey)
        _slideshowCurrentIndexByPaperKey.removeValue(forKey: entry.folderKey)
        Inf6DrillSlideshowProgressStore.delete(paperKey: entry.folderKey)
        if _selectedEntryID == entry.id { _selectedEntryID = nil }
        Task {
            await _loadAll(forceReload: true)
        }
    }

    private func _orderedNodeItems(_ group: Inf6EshikakuDrillPipeline.DrillGroup) -> [_NodeRowItem] {
        (group.entries.map(_NodeRowItem.entry) + group.unverifiedOrigins.map(_NodeRowItem.unresolved))
            .sorted { lhs, rhs in
                if lhs.nodeID != rhs.nodeID {
                    return lhs.nodeID.localizedStandardCompare(rhs.nodeID) == .orderedAscending
                }
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
    }

    @ViewBuilder
    private func _originUnverifiedRow(_ item: Inf6EshikakuDrillPipeline.OriginUnverifiedItem) -> some View {
        let resolving = _exploringOriginNodeIDs.contains(item.nodeID)
        let selected = _selectedNodeIDs.contains(item.nodeID)
        HStack(alignment: .center, spacing: 12) {
            Button {
                if selected {
                    _selectedNodeIDs.remove(item.nodeID)
                } else {
                    _selectedNodeIDs.insert(item.nodeID)
                }
            } label: {
                VStack(spacing: 1) {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(selected ? _dodgersBlue : .secondary)
                    Text(L("演習", "Quiz"))
                        .font(_font(8, weight: .semibold))
                        .foregroundStyle(selected ? _dodgersBlue : .secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(resolving)

            RoundedRectangle(cornerRadius: 2)
                .fill(_dodgersBlue.opacity(0.42))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 7) {
                // 和名は _leafNodeRow のノード見出しで既に表示しているため、ここでは繰り返さない。
                // この行には英題と起源プレビューという補足情報だけを置く。
                // titleJa が空のときは見出し側が titleEn を表示するので、その場合も出さない。
                if !item.titleJa.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !item.titleEn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   item.titleEn != item.titleJa {
                    Text(item.titleEn)
                        .font(_font(15))
                        .foregroundStyle(_dodgersBlueSecondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                if !item.candidates.isEmpty {
                    Text(L(
                        "起源: \(item.candidates.joined(separator: " / "))",
                        "Origin: \(item.candidates.joined(separator: " / "))"
                    ))
                    .font(_font(14))
                    .foregroundStyle(_dodgersBlueSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

            }

            Spacer(minLength: 12)

            if resolving {
                ProgressView().tint(.pink).scaleEffect(1.25)
                    .controlSize(.large)
                    .scaleEffect(1.2)
                    .frame(width: 28, height: 28)
            } else {
                Button {
                    _miniPromptDraft = _extraInstructions[item.nodeID] ?? ""
                    _miniPromptTarget = item
                } label: {
                    Image(systemName: _extraInstructions[item.nodeID]?.isEmpty == false ? "text.bubble.fill" : "text.bubble")
                }
                .buttonStyle(.bordered)
                .help(L("追加指示", "Extra instruction"))
                .disabled(!_generatingKeys.isEmpty || !_exploringOriginNodeIDs.isEmpty || _recutInProgress)
            }
        }
        .padding(.leading, 28)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.34))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(_dodgersBlue.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .textSelection(.enabled)
    }

    @MainActor
    private func _exploreOriginAndGenerate(_ item: Inf6EshikakuDrillPipeline.OriginUnverifiedItem) {
        guard !_exploringOriginNodeIDs.contains(item.nodeID) else { return }
        _exploringOriginNodeIDs.insert(item.nodeID)
        _genErrors.removeValue(forKey: item.nodeID)
        let sf = sourceFamily
        let extra = _extraInstructions[item.nodeID]
        Task {
            do {
                let askModel: (String) async throws -> String = { prompt in
                    try Task.checkCancellation()
                    return try await Inf6LibraryView.askOpenAIText(prompt, lang: "ja", allowWebSearch: true)
                }
                let outcome = try await Inf6EshikakuDrillPipeline.exploreOriginHistory(
                    item: item,
                    sourceFamily: sf,
                    extraInstruction: extra,
                    askModel: askModel
                )
                await _loadAll(forceReload: true)
                _exploringOriginNodeIDs.remove(item.nodeID)
                if outcome.kind == "textbook_field",
                   let generatedPaperID = outcome.selectedPaperID,
                   let generatedEntry = _groups
                    .flatMap(\.entries)
                    .first(where: { $0.paper.id == generatedPaperID }) {
                    print("[DrillView] origin unresolved; generating original explanation paper=\(generatedEntry.folderKey) node=\(item.nodeID)")
                    _startGenerateForEntry(
                        generatedEntry,
                        generateBaseQuiz: true,
                        generateCodePractice: _selectedPythonPaperKeys.contains(_paperKey(generatedEntry))
                    )
                }
                if outcome.selectedPaperID == nil {
                    _genErrors[item.nodeID] = L(
                        "起源探索は完了しましたが選定論文IDがありません (kind=\(outcome.kind))。",
                        "Origin resolution completed but no paper ID was selected (kind=\(outcome.kind))."
                    )
                }
                // 論文が確定した状態を一覧に反映するだけで止める。生成は確定した論文の行から個別に行う。
            } catch {
                if Task.isCancelled {
                    _exploringOriginNodeIDs.remove(item.nodeID)
                    return
                }
                _exploringOriginNodeIDs.remove(item.nodeID)
                Inf6ErrorIntelligence.recordRuntimeEvent(
                    operation: "eshikaku_origin_explore",
                    context: "\(sf)|\(item.nodeID)",
                    error: error
                )
                _genErrors[item.nodeID] = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func _selectedEntryDetail(
        entry: Inf6EshikakuDrillPipeline.DrillEntry,
        group: Inf6EshikakuDrillPipeline.DrillGroup
    ) -> some View {
        if let quiz = entry.quiz, !quiz.questions.isEmpty {
            _entrySection(entry, domainID: group.id)
        } else if _generatingKeys.contains(entry.folderKey) {
            EmptyView()
        }
    }

    @MainActor
    private func _loadOverviewAsync(for entry: Inf6EshikakuDrillPipeline.DrillEntry) async {
        guard _overviewCache[entry.folderKey] == nil else { return }
        let folderKey = entry.folderKey
        let result: String = await Task.detached(priority: .utility) {
            // 置き場は Inf6KnowledgeCardsPaths が決める。ここで組み立て直すと、
            // 保存先を変えたときに古い場所だけを見続けることになる。
            guard let kcRoot = Inf6KnowledgeCardsPaths.rootDirectoryURL() else { return "" }
            let overviewName = Inf6EshikakuDrillPipeline.isGeneratedExplanationProvider(entry.paper.provider)
                ? "\(folderKey).original_explanation.txt"
                : "\(folderKey).abstract.txt"
            let abstractURL = kcRoot
                .appendingPathComponent(folderKey)
                .appendingPathComponent(overviewName)
            guard let data = Inf6SafeFileRead.dataIfReadable(at: abstractURL),
                  let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  Inf6AssetsAbstractPipeline.overviewMeetsCurrentContract(text)
            else { return "" }
            return text
        }.value
        guard !result.isEmpty else {
            _overviewCache.removeValue(forKey: folderKey)
            return
        }
        _overviewCache[folderKey] = result
    }

    private func _overviewSource(
        entry: Inf6EshikakuDrillPipeline.DrillEntry,
        quiz: Inf6PaperQuiz
    ) -> String {
        if let overview = _overviewCache[entry.folderKey], !overview.isEmpty {
            return overview
        }
        return _overviewFromCoverageTargets(quiz)
    }

    private func _overviewFromCoverageTargets(_ quiz: Inf6PaperQuiz) -> String {
        guard let targets = quiz.coverageTargets, !targets.isEmpty else { return "" }
        let byID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
        let ja = quiz.lang.lowercased().hasPrefix("ja")
        let sections: [(id: String, heading: String)] = [
            ("overview-paper", ja ? "要旨" : "Paper overview"),
            ("overview-core-theory", ja ? "数学的導出" : "Mathematical derivation"),
            ("overview-terminology", ja ? "実装" : "Implementation"),
            ("overview-exercise-focus", ja ? "実務上の検証" : "Practical validation")
        ]
        return sections.compactMap { section in
            guard let target = byID[section.id] else { return nil }
            let evidence = target.evidenceText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !evidence.isEmpty else { return nil }
            return "\(section.heading)\n\(evidence)"
        }
        .joined(separator: "\n\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func _reloadAskNotes(paperKey: String) {
        guard !paperKey.isEmpty else { return }
        _askNotesByPaperKey[paperKey] = Inf6DrillAskNoteStore.load(paperKey: paperKey).notes
    }

    private func _cleanAskAnswer(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "```", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func _runAsk(
        action: Inf6DrillExplainAction,
        target: _AskTarget,
        askedCount: Int,
        allowWebSearch: Bool = false,
        userComment: String = ""
    ) {
        let normalizedComment = userComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let commentLog = normalizedComment.replacingOccurrences(of: "\n", with: "\\n")
        print("[LiveBP][AI] explanation_requested action=\(action.rawValue) paper=\(target.paperKey) question=\(target.questionID.uuidString) userComment=\(commentLog.isEmpty ? "none" : commentLog)")
        _askingQuestionIDs.insert(target.questionID)
        let base = action.label(ja: _langRaw == "ja")
        let label = askedCount == 0 ? base : L("\(base) (\(askedCount + 1)回目)", "\(base) (#\(askedCount + 1))")
        Task {
            defer { _askingQuestionIDs.remove(target.questionID) }
            do {
                let deeper = askedCount == 0 ? "" : """

                これは\(askedCount + 1)回目の要求です。既に一度解説済みなので、
                前回より踏み込んだ内容を書いてください。同じ説明を繰り返さないでください。
                """
                let fullPrompt = """
                あなたはE資格の学習者を支援する論文読解チューターです。
                以下の演習項目について、次の指示に従って解説してください。

                指示: \(action.instruction)

                論文: \(target.paperTitle)
                観点: \(target.questionText)
                既存の解説: \(target.explanationText)
                \(target.selectedTerm.map { "選択語句: \($0)\n選択語句だけを対象に説明してください。設問全体や他の用語の一覧に話を広げないでください。" } ?? "")
                \(normalizedComment.isEmpty ? "" : """
                ユーザーの質問（最優先）: \(normalizedComment)
                この質問に直接答えてください。既存の解説を繰り返すのではなく、質問が求めている一点を最初に明確に答えてください。
                """)
                \(deeper)
                正しい内容だけを、具体的に、300字以内で述べてください。Markdown記号（**、__、```）は使わないでください。
                誤りや誤解の例は書かないでください。根拠のない推測も書かないでください。
                """
                let answer = try await Inf6LibraryView.askOpenAIText(
                    fullPrompt,
                    lang: "ja",
                    allowWebSearch: allowWebSearch
                )
                Inf6DrillAskNoteStore.append(
                    paperKey: target.paperKey,
                    note: Inf6DrillAskNote(
                        questionID: target.questionID,
                        prompt: label,
                        answer: _cleanAskAnswer(answer)
                    )
                )
                _reloadAskNotes(paperKey: target.paperKey)
            } catch {
                Inf6ErrorIntelligence.recordRuntimeEvent(
                    operation: "drill_ask_note",
                    context: "\(target.paperKey)|\(target.questionID.uuidString)",
                    error: error
                )
                _genErrors["ask"] = error.localizedDescription
            }
        }
    }

    /// 同じ根拠に紐づくポイントをまとめる。
    /// docEntityID が無い項目は、まとめずに単独の組として扱う。
    /// 並び順は元のポイント番号の昇順を保つ。
    private struct _EntityGroup: Identifiable {
        let id: String
        let leafID: String
        let localIndex: Int
        let points: [Inf6DrillStudyCard.Point]
        var representative: Inf6PaperQuizQuestion { points[0].question }
        var canCrop: Bool {
            representative.entityImagePath != nil && representative.docEntityID != nil
        }
        var isUnderstandingPointMissing: Bool {
            representative.question.isEmpty && representative.explanation.isEmpty
        }
    }

    private func _entityGroups(_ questions: [Inf6PaperQuizQuestion], folderKey: String) -> [_EntityGroup] {
        let modeKey: String = {
            let frameworks = Set(questions.compactMap { _pythonFramework(for: $0)?.rawValue })
            let hasCode = questions.contains { $0.normalizedExerciseType == "py" }
            let hasRegular = questions.contains { $0.normalizedExerciseType == "regular" }
            if hasCode && hasRegular { return "mixed" }
            if hasCode { return frameworks.sorted().joined(separator: "+") }
            return "regular"
        }()
        var appearance: [String] = []
        var byKey: [String: [Inf6PaperQuizQuestion]] = [:]
        let generatedIDs = Set(_liveBPGeneratedByPaperKey[folderKey, default: []].map(\.id))
        for question in questions {
            let key: String
            if generatedIDs.contains(question.id) {
                key = "live-generated:\(question.id.uuidString)"
            } else {
                key = question.docEntityID?.uuidString ?? "solo:\(question.id.uuidString)"
            }
            if byKey[key] == nil { appearance.append(key) }
            byKey[key, default: []].append(question)
        }

        // A generated point may have been written after the DrillEntry was
        // captured.  Include the persisted record in this grouping pass so
        // the empty visual placeholder is replaced in the same render.
        let persistedGenerated = Inf6LiveBPGeneratedExerciseStore.load(
            paperKey: folderKey
        ).exercises
        for generated in persistedGenerated {
            let generatedQuestion = generated.asQuizQuestion()
            let key = generatedQuestion.docEntityID.map { $0.uuidString }
                ?? "live-generated:\(generatedQuestion.id.uuidString)"
            let existingPoints = byKey[key, default: []]
            let hasNonEmptyPoint = existingPoints.contains {
                !$0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !$0.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if !hasNonEmptyPoint {
                byKey[key] = [generatedQuestion]
                if !appearance.contains(key) { appearance.append(key) }
            } else {
                let generatedKey = "live-generated:\(generatedQuestion.id.uuidString)"
                byKey[generatedKey] = [generatedQuestion]
                appearance.append(generatedKey)
            }
        }

        // 保存済みの全クロップ結果を表示母集団にする。演習ポイントがまだ
        // 無い図表数式も、画像カードとして表示し、追加生成の対象にする。
        if let index = Inf6MetadataStore.getCodable(
            Inf6DocEntityIndex.self, domain: .docEntities, key: folderKey
        ) {
            for entity in index.entities where entity.imagePath?.isEmpty == false {
                let key = entity.id.uuidString
                guard byKey[key] == nil else { continue }
                byKey[key] = [Inf6PaperQuizQuestion(
                    pageIndex: entity.pageIndex,
                    kind: entity.kind.rawValue,
                    exerciseType: "regular",
                    question: "",
                    choices: [],
                    correctIndex: 0,
                    explanation: "",
                    entityImagePath: entity.imagePath,
                    docEntityID: entity.id,
                    entityReferenceIDs: entity.references?.map(\.id)
                )]
                appearance.append(key)
            }
        }

        // 画像付きポイントは図・表・数式から作られる。並びも論文のとおりにする。
        //
        // これまでは作られた順に番号を振り、表示だけを図ごとにまとめ直して
        // いた。利用者に見えない順序を画面に出しており、Table 2 が 3, 14, 15
        // のように飛んでいた。ページの位置で並べ、その順に番号を振る。
        let pages = _entityPageIndexes(folderKey: folderKey)
        let order = appearance.enumerated().sorted { left, right in
            let leftPage = pages[left.element] ?? Int.max
            let rightPage = pages[right.element] ?? Int.max
            if leftPage != rightPage { return leftPage < rightPage }
            return left.offset < right.offset
        }.map(\.element)

        var number = 0
        let leafID = _groups
            .flatMap(\.entries)
            .first(where: { $0.folderKey == folderKey })?
            .syllabusNodeID ?? folderKey
        return order.enumerated().compactMap { localOffset, key in
            guard let questions = byKey[key], !questions.isEmpty else { return nil }
            let points = questions.map { question -> Inf6DrillStudyCard.Point in
                number += 1
                return Inf6DrillStudyCard.Point(number: number, question: question)
            }
            return _EntityGroup(
                id: "\(modeKey):\(key)",
                leafID: leafID,
                localIndex: localOffset + 1,
                points: points
            )
        }
    }

    private struct _SlideshowStats {
        let seenCount: Int
        let unseenCount: Int
        let completedLapCount: Int
        let totalShownCount: Int
        let totalCount: Int
    }

    private struct _SlideshowCandidate {
        let entry: Inf6EshikakuDrillPipeline.DrillEntry
        let groups: [_EntityGroup]
        let index: Int
        let priorityScore: Int
        let progress: Inf6DrillSlideshowProgressBook
        let entryOrder: Int
        let isUnseen: Bool
        let isLapUnseen: Bool
    }

    private func _loadSlideshowProgress(paperKey: String, groups: [_EntityGroup]) -> Inf6DrillSlideshowProgressBook {
        if let cached = _slideshowProgressByPaperKey[paperKey] {
            return _sanitizeSlideshowProgress(cached, groups: groups)
        }
        return _sanitizeSlideshowProgress(
            Inf6DrillSlideshowProgressStore.load(paperKey: paperKey),
            groups: groups
        )
    }

    private func _sanitizeSlideshowProgress(
        _ book: Inf6DrillSlideshowProgressBook,
        groups: [_EntityGroup]
    ) -> Inf6DrillSlideshowProgressBook {
        let validIDs = Set(groups.map(\.id))
        var sanitized = book
        // 旧初期値8秒の保存記録は、新しい初期値17秒へ移行する。
        let migratedSeconds = book.secondsPerSlide == 8 ? 17 : book.secondsPerSlide
        sanitized.secondsPerSlide = min(max(migratedSeconds, 1), 120)
        sanitized.seenGroupIDs = book.seenGroupIDs.filter { validIDs.contains($0) }
        sanitized.currentLapSeenGroupIDs = book.currentLapSeenGroupIDs.filter { validIDs.contains($0) }
        if let lastGroupID = sanitized.lastGroupID, !validIDs.contains(lastGroupID) {
            sanitized.lastGroupID = nil
        }
        return sanitized
    }

    private func _saveSlideshowProgress(
        paperKey: String,
        groups: [_EntityGroup],
        mutate: (inout Inf6DrillSlideshowProgressBook) -> Void
    ) -> Inf6DrillSlideshowProgressBook {
        var updated = _loadSlideshowProgress(paperKey: paperKey, groups: groups)
        mutate(&updated)
        updated.updatedAt = Date().timeIntervalSince1970
        updated = _sanitizeSlideshowProgress(updated, groups: groups)
        _slideshowProgressByPaperKey[paperKey] = updated
        Inf6DrillSlideshowProgressStore.save(updated)
        return updated
    }

    private func _resetSlideshowProgress(
        paperKey: String,
        groups: [_EntityGroup]
    ) {
        guard !paperKey.isEmpty else { return }
        let current = _loadSlideshowProgress(paperKey: paperKey, groups: groups)
        let reset = Inf6DrillSlideshowProgressBook(
            paperKey: paperKey,
            secondsPerSlide: current.secondsPerSlide,
            preferUnseenFirst: current.preferUnseenFirst,
            seenGroupIDs: [],
            currentLapSeenGroupIDs: [],
            completedLapCount: 0,
            totalShownCount: 0,
            lastGroupID: nil,
            updatedAt: Date().timeIntervalSince1970
        )
        _slideshowProgressByPaperKey[paperKey] = reset
        _slideshowCurrentIndexByPaperKey.removeValue(forKey: paperKey)
        _slideshowCurrentGroupIDByPaperKey.removeValue(forKey: paperKey)
        Inf6DrillSlideshowProgressStore.save(reset)
    }

    private func _resetSelectedSlideshowProgress() {
        for entry in _selectedQuizEntriesForSlideshow {
            guard let quiz = entry.quiz, !quiz.questions.isEmpty else { continue }
            let groups = _entityGroups(_liveBPQuestions(quiz, for: entry), folderKey: entry.folderKey)
            guard !groups.isEmpty else { continue }
            _resetSlideshowProgress(paperKey: entry.folderKey, groups: groups)
        }
    }

    private func _slideshowStats(
        paperKey: String,
        groups: [_EntityGroup]
    ) -> _SlideshowStats {
        let progress = _loadSlideshowProgress(paperKey: paperKey, groups: groups)
        let seen = Set(progress.seenGroupIDs)
        let seenCount = groups.filter { seen.contains($0.id) }.count
        return _SlideshowStats(
            seenCount: seenCount,
            unseenCount: max(groups.count - seenCount, 0),
            completedLapCount: progress.completedLapCount,
            totalShownCount: progress.totalShownCount,
            totalCount: groups.count
        )
    }

    private func _selectedSlideshowStats() -> _SlideshowStats {
        let entries = _selectedQuizEntriesForSlideshow
        var seenCount = 0
        var totalCount = 0
        var completedLapCount = 0
        var totalShownCount = 0

        for entry in entries {
            guard let quiz = entry.quiz, !quiz.questions.isEmpty else { continue }
            let groups = _entityGroups(_liveBPQuestions(quiz, for: entry), folderKey: entry.folderKey)
            let progress = _loadSlideshowProgress(paperKey: entry.folderKey, groups: groups)
            let seen = Set(progress.seenGroupIDs)
            seenCount += groups.filter { seen.contains($0.id) }.count
            totalCount += groups.count
            completedLapCount += progress.completedLapCount
            totalShownCount += progress.totalShownCount
        }

        return _SlideshowStats(
            seenCount: seenCount,
            unseenCount: max(totalCount - seenCount, 0),
            completedLapCount: completedLapCount,
            totalShownCount: totalShownCount,
            totalCount: totalCount
        )
    }

    private func _selectedSlideshowPosition() -> _SlideshowPosition {
        let sequence = _buildSlideshowSequence()
        guard !sequence.isEmpty else {
            return _SlideshowPosition(current: 0, total: 0, indexLabel: "")
        }
        let currentPaperKey = _slideshowPlayingPaperKey ?? _slideshowPresentedPaperKey
        let currentGroupID = currentPaperKey.flatMap { _slideshowCurrentGroupIDByPaperKey[$0] }
        let currentItem = currentPaperKey.flatMap { paperKey in
            currentGroupID.map { groupID in
                _SlideshowHistoryItem(paperKey: paperKey, groupID: groupID)
            }
        }
        let current = currentItem.flatMap { item in
            sequence.firstIndex(of: item).map { $0 + 1 }
        } ?? (sequence.isEmpty ? 0 : 1)

        let indexLabel: String = {
            guard let currentItem,
                  let entry = _selectedQuizEntriesForSlideshow.first(where: { $0.folderKey == currentItem.paperKey }),
                  let quiz = entry.quiz,
                  let group = _entityGroups(_liveBPQuestions(quiz, for: entry), folderKey: entry.folderKey)
                    .first(where: { $0.id == currentItem.groupID }) else { return "" }
            return _slideshowIndexLabel(entry: entry, group: group, overallPosition: current)
        }()
        return _SlideshowPosition(current: current, total: sequence.count, indexLabel: indexLabel)
    }

    private func _slideshowIndexLabel(
        entry: Inf6EshikakuDrillPipeline.DrillEntry,
        group: _EntityGroup,
        overallPosition: Int
    ) -> String {
        return "#\(overallPosition) \(_slideshowIndexPrefix(entry: entry, group: group)) #\(group.localIndex)"
    }

    private func _slideshowIndexPrefix(
        entry: Inf6EshikakuDrillPipeline.DrillEntry,
        group: _EntityGroup
    ) -> String {
        let domainName = entry.domainLabelJa.trimmingCharacters(in: .whitespacesAndNewlines)
        let nodeName = (entry.syllabusTitle ?? entry.domainLabelJa)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let leafName = entry.paper.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(domainName) / \(nodeName) / \(leafName)"
    }

    private func _jumpSlideshowToLocalIndex(_ requestedIndex: Int) {
        guard requestedIndex > 0,
              let entry = _currentSlideshowEntry,
              let quiz = entry.quiz, !quiz.questions.isEmpty else { return }
        let groups = _entityGroups(_liveBPQuestions(quiz, for: entry), folderKey: entry.folderKey)
        guard let index = groups.firstIndex(where: { $0.localIndex == requestedIndex }) else { return }
        _showSlideshowGroup(entry: entry, groups: groups, index: index, recordView: true)
    }


    private func _buildSlideshowSequence() -> [_SlideshowHistoryItem] {
        var sequence: [_SlideshowHistoryItem] = []
        var seen = Set<_SlideshowHistoryItem>()
        for entry in _selectedQuizEntriesForSlideshow {
            guard let quiz = entry.quiz, !quiz.questions.isEmpty else { continue }
            let groups = _entityGroups(_liveBPQuestions(quiz, for: entry), folderKey: entry.folderKey)
            for group in groups {
                let item = _SlideshowHistoryItem(paperKey: entry.folderKey, groupID: group.id)
                if seen.insert(item).inserted {
                    sequence.append(item)
                }
            }
        }
        return sequence
    }

    private func _jumpSlideshowToPosition(_ requestedPosition: Int) {
        let sequence = _buildSlideshowSequence()
        guard requestedPosition > 0,
              requestedPosition <= sequence.count else { return }
        let item = sequence[requestedPosition - 1]
        guard let entry = _selectedQuizEntriesForSlideshow.first(where: { $0.folderKey == item.paperKey }),
              let quiz = entry.quiz, !quiz.questions.isEmpty else { return }
        let groups = _entityGroups(_liveBPQuestions(quiz, for: entry), folderKey: entry.folderKey)
        guard let index = groups.firstIndex(where: { $0.id == item.groupID }) else { return }

        _selectSlideshowEntry(entry)
        if _slideshowTask != nil || _slideshowPlayingPaperKey != nil {
            _slideshowPlayingPaperKey = entry.folderKey
        }
        _showSlideshowGroup(entry: entry, groups: groups, index: index, recordView: true)
    }

    private func _moveSlideshowByPosition(_ delta: Int) {
        _slideshowSequence = _buildSlideshowSequence()
        let position = _selectedSlideshowPosition()
        guard position.total > 0 else { return }

        let current = position.current > 0 ? position.current : 1
        let target: Int
        if delta > 0 {
            guard current < position.total else { return }
            target = current + 1
        } else if delta < 0 {
            guard current > 1 else { return }
            target = current - 1
        } else {
            target = current
        }
        _jumpSlideshowToPosition(target)
    }

    private func _slideshowNodeIDs() -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for entry in _selectedQuizEntriesForSlideshow {
            let nodeID = entry.syllabusNodeID ?? entry.id
            guard seen.insert(nodeID).inserted else { continue }
            result.append(nodeID)
        }
        return result
    }

    private func _canMoveSlideshowNode(_ delta: Int) -> Bool {
        guard delta != 0,
              let currentEntry = _currentSlideshowEntry else { return false }
        let nodeIDs = _slideshowNodeIDs()
        guard let currentIndex = nodeIDs.firstIndex(of: currentEntry.syllabusNodeID ?? currentEntry.id) else {
            return false
        }
        let targetIndex = currentIndex + (delta > 0 ? 1 : -1)
        return nodeIDs.indices.contains(targetIndex)
    }

    private func _moveSlideshowToAdjacentNode(_ delta: Int, placeAtEnd: Bool = false) {
        guard delta != 0,
              let currentEntry = _currentSlideshowEntry else { return }
        let nodeIDs = _slideshowNodeIDs()
        guard let currentIndex = nodeIDs.firstIndex(of: currentEntry.syllabusNodeID ?? currentEntry.id) else { return }
        let targetIndex = currentIndex + (delta > 0 ? 1 : -1)
        guard nodeIDs.indices.contains(targetIndex) else { return }
        let targetNodeID = nodeIDs[targetIndex]
        guard let targetEntry = _selectedQuizEntriesForSlideshow.first(where: {
            ($0.syllabusNodeID ?? $0.id) == targetNodeID
        }),
              let quiz = targetEntry.quiz, !quiz.questions.isEmpty else { return }
        let groups = _entityGroups(_liveBPQuestions(quiz, for: targetEntry), folderKey: targetEntry.folderKey)
        guard !groups.isEmpty else { return }
        _selectSlideshowEntry(targetEntry)
        if _slideshowTask != nil || _slideshowPlayingPaperKey != nil {
            _slideshowPlayingPaperKey = targetEntry.folderKey
        }
        let targetGroupIndex = placeAtEnd ? groups.index(before: groups.endIndex) : groups.startIndex
        _showSlideshowGroup(entry: targetEntry, groups: groups, index: targetGroupIndex, recordView: true)
    }

    private func _initialSlideshowEntry() -> Inf6EshikakuDrillPipeline.DrillEntry? {
        if let candidate = _bestSlideshowCandidateAcrossSelection(preferOnlyUnseen: true) {
            return candidate.entry
        }
        let entries = _selectedQuizEntriesForSlideshow
        let candidates: [(entry: Inf6EshikakuDrillPipeline.DrillEntry, progress: Inf6DrillSlideshowProgressBook, unseenCount: Int)] = entries.compactMap { entry in
            guard let quiz = entry.quiz, !quiz.questions.isEmpty else { return nil }
            let groups = _entityGroups(_liveBPQuestions(quiz, for: entry), folderKey: entry.folderKey)
            guard !groups.isEmpty else { return nil }
            let progress = _loadSlideshowProgress(paperKey: entry.folderKey, groups: groups)
            let seen = Set(progress.seenGroupIDs)
            let unseenCount = groups.filter { !seen.contains($0.id) }.count
            return (entry, progress, unseenCount)
        }
        if let unseen = candidates
            .filter({ $0.progress.preferUnseenFirst && $0.unseenCount > 0 })
            .min(by: { left, right in
                if left.progress.totalShownCount != right.progress.totalShownCount {
                    return left.progress.totalShownCount < right.progress.totalShownCount
                }
                return entries.firstIndex { $0.folderKey == left.entry.folderKey } ?? Int.max
                    < entries.firstIndex { $0.folderKey == right.entry.folderKey } ?? Int.max
            }) {
            return unseen.entry
        }
        return entries.first
    }

    private func _bestSlideshowCandidateAcrossSelection(preferOnlyUnseen: Bool) -> _SlideshowCandidate? {
        let entries = _selectedQuizEntriesForSlideshow
        var candidates: [_SlideshowCandidate] = []

        for (entryOrder, entry) in entries.enumerated() {
            guard let quiz = entry.quiz, !quiz.questions.isEmpty else { continue }
            let groups = _entityGroups(_liveBPQuestions(quiz, for: entry), folderKey: entry.folderKey)
            guard !groups.isEmpty else { continue }
            let progress = _loadSlideshowProgress(paperKey: entry.folderKey, groups: groups)
            let seen = Set(progress.seenGroupIDs)
            let lapSeen = Set(progress.currentLapSeenGroupIDs)

            let lapUnseen = groups.indices.filter { !lapSeen.contains(groups[$0].id) }
            let lapUnseenSet = Set(lapUnseen)

            for index in groups.indices {
                let group = groups[index]
                candidates.append(
                    _SlideshowCandidate(
                        entry: entry,
                        groups: groups,
                        index: index,
                        priorityScore: _liveBPGroupPriorityScore(entry: entry, group: group),
                        progress: progress,
                        entryOrder: entryOrder,
                        isUnseen: !seen.contains(group.id),
                        isLapUnseen: lapUnseen.isEmpty || lapUnseenSet.contains(index)
                    )
                )
            }
        }

        return candidates.max { left, right in
            if preferOnlyUnseen {
                let leftUnseen = left.progress.preferUnseenFirst && left.isUnseen
                let rightUnseen = right.progress.preferUnseenFirst && right.isUnseen
                if leftUnseen != rightUnseen {
                    return !leftUnseen && rightUnseen
                }
            }
            if left.isLapUnseen != right.isLapUnseen {
                return !left.isLapUnseen && right.isLapUnseen
            }
            // Live BPの進行条件を最優先する。重要度は未閲覧候補を
            // 絞り込んだ後の順位付けにだけ使い、既読問題を再選択しない。
            if left.priorityScore != right.priorityScore {
                return left.priorityScore < right.priorityScore
            }
            if left.progress.totalShownCount != right.progress.totalShownCount {
                return left.progress.totalShownCount > right.progress.totalShownCount
            }
            if left.priorityScore != right.priorityScore {
                return left.priorityScore < right.priorityScore
            }
            if left.entryOrder != right.entryOrder {
                return left.entryOrder > right.entryOrder
            }
            return left.index > right.index
        }
    }

    private func _currentSlideshowIndex(
        paperKey: String,
        groups: [_EntityGroup]
    ) -> Int? {
        guard !groups.isEmpty else { return nil }
        if let groupID = _slideshowCurrentGroupIDByPaperKey[paperKey],
           let groupIndex = groups.firstIndex(where: { $0.id == groupID }) {
            return groupIndex
        }
        if let index = _slideshowCurrentIndexByPaperKey[paperKey], groups.indices.contains(index) {
            return index
        }
        let progress = _loadSlideshowProgress(paperKey: paperKey, groups: groups)
        if progress.preferUnseenFirst {
            let seen = Set(progress.seenGroupIDs)
            if let unseenIndex = groups.firstIndex(where: { !seen.contains($0.id) }) {
                return unseenIndex
            }
        }
        if let lastGroupID = progress.lastGroupID,
           let savedIndex = groups.firstIndex(where: { $0.id == lastGroupID }) {
            return savedIndex
        }
        return groups.startIndex
    }

    private func _recordSlideshowView(
        paperKey: String,
        group: _EntityGroup,
        groups: [_EntityGroup]
    ) {
        _ = _saveSlideshowProgress(paperKey: paperKey, groups: groups) { book in
            let seen = Set(book.seenGroupIDs).union([group.id])
            let lapSeen = Set(book.currentLapSeenGroupIDs).union([group.id])
            book.seenGroupIDs = Array(seen).sorted()
            book.totalShownCount += 1
            book.lastGroupID = group.id
            if lapSeen.count >= groups.count {
                book.completedLapCount += 1
                book.currentLapSeenGroupIDs = []
            } else {
                book.currentLapSeenGroupIDs = Array(lapSeen).sorted()
            }
        }
    }

    private func _holdSlideshowView(
        paperKey: String,
        group: _EntityGroup,
        groups: [_EntityGroup]
    ) {
        _ = _saveSlideshowProgress(paperKey: paperKey, groups: groups) { book in
            book.seenGroupIDs.removeAll { $0 == group.id }
            book.currentLapSeenGroupIDs.removeAll { $0 == group.id }
            if book.lastGroupID == group.id {
                book.lastGroupID = nil
            }
            book.totalShownCount = max(book.totalShownCount - 1, 0)
        }
    }

    private func _nextSlideshowIndex(
        paperKey: String,
        groups: [_EntityGroup]
    ) -> Int? {
        guard !groups.isEmpty else { return nil }
        let current = _currentSlideshowIndex(paperKey: paperKey, groups: groups) ?? groups.startIndex
        let progress = _loadSlideshowProgress(paperKey: paperKey, groups: groups)
        if progress.preferUnseenFirst {
            let seen = Set(progress.seenGroupIDs)
            let unseenIndexes = groups.indices.filter { !seen.contains(groups[$0].id) }
            if !unseenIndexes.isEmpty {
                if let afterCurrent = unseenIndexes.first(where: { $0 > current }) {
                    return afterCurrent
                }
                return unseenIndexes[0]
            }
        }
        let currentLapSeen = Set(progress.currentLapSeenGroupIDs)
        let lapUnseenIndexes = groups.indices.filter { !currentLapSeen.contains(groups[$0].id) }
        if !lapUnseenIndexes.isEmpty {
            if let afterCurrent = lapUnseenIndexes.first(where: { $0 > current }) {
                return afterCurrent
            }
            return lapUnseenIndexes[0]
        }
        let next = current + 1
        return next < groups.count ? next : groups.startIndex
    }

    private func _previousSlideshowIndex(
        paperKey: String,
        groups: [_EntityGroup]
    ) -> Int? {
        guard !groups.isEmpty else { return nil }
        let current = _currentSlideshowIndex(paperKey: paperKey, groups: groups) ?? groups.startIndex
        return current > groups.startIndex ? current - 1 : groups.index(before: groups.endIndex)
    }

    private func _showSlideshowGroup(
        entry: Inf6EshikakuDrillPipeline.DrillEntry,
        groups: [_EntityGroup],
        index: Int,
        recordView: Bool,
        rememberPrevious: Bool = true,
        clearForwardHistory: Bool = true
    ) {
        guard groups.indices.contains(index) else { return }
        if rememberPrevious,
           let current = _currentSlideshowHistoryItem(),
           current.paperKey != entry.folderKey || current.groupID != groups[index].id {
            _slideshowBackStack.append(current)
            if _slideshowBackStack.count > 200 {
                _slideshowBackStack.removeFirst(_slideshowBackStack.count - 200)
            }
        }
        if clearForwardHistory {
            _slideshowForwardStack.removeAll()
        }
        _slideshowCurrentIndexByPaperKey[entry.folderKey] = index
        _slideshowCurrentGroupIDByPaperKey[entry.folderKey] = groups[index].id
        _slideshowViewportToken = UUID()
        if recordView {
            _recordSlideshowView(paperKey: entry.folderKey, group: groups[index], groups: groups)
        }
    }

    private func _currentSlideshowHistoryItem() -> _SlideshowHistoryItem? {
        guard let entry = _currentSlideshowEntry,
              let quiz = entry.quiz, !quiz.questions.isEmpty else { return nil }
        let groups = _entityGroups(_liveBPQuestions(quiz, for: entry), folderKey: entry.folderKey)
        guard let index = _currentSlideshowIndex(paperKey: entry.folderKey, groups: groups),
              groups.indices.contains(index) else { return nil }
        return _SlideshowHistoryItem(paperKey: entry.folderKey, groupID: groups[index].id)
    }

    private func _restorePreviousSlideshowFromHistory() -> Bool {
        while let item = _slideshowBackStack.popLast() {
            if _currentSlideshowHistoryItem() == item {
                continue
            }
            guard let entry = _selectedQuizEntriesForSlideshow.first(where: { $0.folderKey == item.paperKey }),
                  let quiz = entry.quiz, !quiz.questions.isEmpty else { continue }
            let groups = _entityGroups(_liveBPQuestions(quiz, for: entry), folderKey: entry.folderKey)
            guard let index = groups.firstIndex(where: { $0.id == item.groupID }) else { continue }
            if let current = _currentSlideshowHistoryItem(),
               current.paperKey != item.paperKey || current.groupID != item.groupID {
                _slideshowForwardStack.append(current)
                if _slideshowForwardStack.count > 200 {
                    _slideshowForwardStack.removeFirst(_slideshowForwardStack.count - 200)
                }
            }
            _selectSlideshowEntry(entry)
            if _slideshowTask != nil || _slideshowPlayingPaperKey != nil {
                _slideshowPlayingPaperKey = entry.folderKey
            }
            _showSlideshowGroup(entry: entry, groups: groups, index: index, recordView: false, rememberPrevious: false, clearForwardHistory: false)
            return true
        }
        return false
    }

    private func _restoreNextSlideshowFromHistory() -> Bool {
        while let item = _slideshowForwardStack.popLast() {
            guard let entry = _selectedQuizEntriesForSlideshow.first(where: { $0.folderKey == item.paperKey }),
                  let quiz = entry.quiz, !quiz.questions.isEmpty else { continue }
            let groups = _entityGroups(_liveBPQuestions(quiz, for: entry), folderKey: entry.folderKey)
            guard let index = groups.firstIndex(where: { $0.id == item.groupID }) else { continue }
            if let current = _currentSlideshowHistoryItem(),
               current.paperKey != item.paperKey || current.groupID != item.groupID {
                _slideshowBackStack.append(current)
                if _slideshowBackStack.count > 200 {
                    _slideshowBackStack.removeFirst(_slideshowBackStack.count - 200)
                }
            }
            _selectSlideshowEntry(entry)
            if _slideshowTask != nil || _slideshowPlayingPaperKey != nil {
                _slideshowPlayingPaperKey = entry.folderKey
            }
            _showSlideshowGroup(entry: entry, groups: groups, index: index, recordView: false, rememberPrevious: false, clearForwardHistory: false)
            return true
        }
        return false
    }

    private func _advanceSlideshow(
        entry: Inf6EshikakuDrillPipeline.DrillEntry,
        groups: [_EntityGroup]
    ) {
        guard let next = _nextSlideshowIndex(paperKey: entry.folderKey, groups: groups) else { return }
        _showSlideshowGroup(entry: entry, groups: groups, index: next, recordView: true)
    }

    private func _selectedEntryIndex(for entry: Inf6EshikakuDrillPipeline.DrillEntry) -> Int? {
        _selectedQuizEntriesForSlideshow.firstIndex { $0.folderKey == entry.folderKey }
    }

    private func _selectSlideshowEntry(_ entry: Inf6EshikakuDrillPipeline.DrillEntry) {
        _slideshowPresentedPaperKey = entry.folderKey
    }

    private func _nextSelectedQuizEntry(after entry: Inf6EshikakuDrillPipeline.DrillEntry) -> Inf6EshikakuDrillPipeline.DrillEntry? {
        let entries = _selectedQuizEntriesForSlideshow
        guard !entries.isEmpty, let currentIndex = _selectedEntryIndex(for: entry) else { return nil }
        let nextIndex = currentIndex + 1
        return nextIndex < entries.count ? entries[nextIndex] : entries.first
    }

    private func _previousSelectedQuizEntry(before entry: Inf6EshikakuDrillPipeline.DrillEntry) -> Inf6EshikakuDrillPipeline.DrillEntry? {
        let entries = _selectedQuizEntriesForSlideshow
        guard !entries.isEmpty, let currentIndex = _selectedEntryIndex(for: entry) else { return nil }
        let previousIndex = currentIndex - 1
        return previousIndex >= 0 ? entries[previousIndex] : entries.last
    }

    private func _advanceSlideshowAcrossSelection(preferUnseen _: Bool = true) {
        _moveSlideshowByPosition(1)
    }

    private func _moveSlideshowBackwardAcrossSelection() {
        let presented = _slideshowPresentedPaperKey ?? "none"
        let playing = _slideshowPlayingPaperKey ?? "none"
        print("[LiveBP][NAV] previous_requested presented=\(presented) playing=\(playing)")
        if let entry = _currentSlideshowEntry,
           let quiz = entry.quiz,
           let currentIndex = _currentSlideshowIndex(
               paperKey: entry.folderKey,
               groups: _entityGroups(_liveBPQuestions(quiz, for: entry), folderKey: entry.folderKey)
           ),
           currentIndex == 0 {
            _moveSlideshowToAdjacentNode(-1, placeAtEnd: true)
            return
        }
        _moveSlideshowByPosition(-1)
    }

    private func _handleManualSlideshowPrevious() {
        guard _slideshowPresentedPaperKey != nil || _slideshowPlayingPaperKey != nil else { return }
        print("[LiveBP][NAV] manual direction=previous")
        _moveSlideshowBackwardAcrossSelection()
    }

    private func _handleManualSlideshowNext() {
        guard _slideshowPresentedPaperKey != nil || _slideshowPlayingPaperKey != nil else { return }
        print("[LiveBP][NAV] manual direction=next")
        _advanceSlideshowAcrossSelection(preferUnseen: false)
    }

    private func _startSlideshow(
        entry: Inf6EshikakuDrillPipeline.DrillEntry,
        groups: [_EntityGroup],
        startIndex: Int? = nil
    ) {
        guard !groups.isEmpty else { return }
        if _slideshowSequence.isEmpty {
            _slideshowSequence = _buildSlideshowSequence()
        }
        _stopSlideshow()
        _slideshowBackStack.removeAll()
        _slideshowForwardStack.removeAll()
        let startIndex = startIndex ?? _currentSlideshowIndex(paperKey: entry.folderKey, groups: groups) ?? groups.startIndex
        _selectSlideshowEntry(entry)
        _slideshowPlayingPaperKey = entry.folderKey
        _showSlideshowGroup(entry: entry, groups: groups, index: startIndex, recordView: true, rememberPrevious: false, clearForwardHistory: false)
        _startSlideshowTimer(entry: entry, groups: groups)
    }

    private func _startSlideshowTimer(
        entry: Inf6EshikakuDrillPipeline.DrillEntry,
        groups: [_EntityGroup]
    ) {
        _slideshowTask = Task {
            while !Task.isCancelled {
                let seconds = await MainActor.run {
                    _loadSlideshowProgress(paperKey: entry.folderKey, groups: groups).secondsPerSlide
                }
                let nanos = UInt64(max(seconds, 1) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    guard _slideshowPlayingPaperKey != nil else { return }
                    _advanceSlideshowAcrossSelection()
                }
            }
        }
    }

    private func _startSelectedSlideshow() {
        _listViewportToken = UUID()
        if let entry = _currentSlideshowEntry,
           let quiz = entry.quiz, !quiz.questions.isEmpty {
            let groups = _entityGroups(_liveBPQuestions(quiz, for: entry), folderKey: entry.folderKey)
            if !groups.isEmpty {
                let resumeIndex = _currentSlideshowIndex(paperKey: entry.folderKey, groups: groups)
                    ?? groups.startIndex
                _startSlideshow(entry: entry, groups: groups, startIndex: resumeIndex)
                return
            }
        }

        if let candidate = _bestSlideshowCandidateAcrossSelection(preferOnlyUnseen: true) {
            _startSlideshow(entry: candidate.entry, groups: candidate.groups, startIndex: candidate.index)
            return
        }
        guard let entry = _initialSlideshowEntry(),
              let quiz = entry.quiz, !quiz.questions.isEmpty else { return }
        let groups = _entityGroups(_liveBPQuestions(quiz, for: entry), folderKey: entry.folderKey)
        guard !groups.isEmpty else { return }
        _startSlideshow(entry: entry, groups: groups)
    }

    private func _stopSlideshow() {
        _slideshowTask?.cancel()
        _slideshowTask = nil
        _slideshowPlayingPaperKey = nil
    }

    private func _dismissSlideshow() {
        _stopSlideshow()
        _slideshowPresentedPaperKey = nil
        _slideshowBackStack.removeAll()
        _slideshowForwardStack.removeAll()
        _slideshowSequence.removeAll()
    }

    private func _handleBackAction() {
        if _slideshowPresentedPaperKey != nil || _slideshowPlayingPaperKey != nil {
            _dismissSlideshow()
            return
        }
        _dismiss()
    }

    private func _pauseSlideshow() {
        _slideshowTask?.cancel()
        _slideshowTask = nil
    }

    private func _resumeSlideshowTimerIfNeeded() {
        guard _slideshowTask == nil,
              let entry = _currentSlideshowEntry,
              let quiz = entry.quiz,
              !quiz.questions.isEmpty,
              _slideshowPlayingPaperKey == entry.folderKey else { return }
        let groups = _entityGroups(_liveBPQuestions(quiz, for: entry), folderKey: entry.folderKey)
        guard !groups.isEmpty else { return }
        _startSlideshowTimer(entry: entry, groups: groups)
    }

    /// 図・表・数式が論文の何ページ目にあるかを引く。
    ///
    /// 位置が取れないものは末尾へ回す。落とすと、そのポイントが消える。
    private func _entityPageIndexes(folderKey: String) -> [String: Int] {
        guard let kcRoot = Inf6KnowledgeCardsPaths.rootDirectoryURL() else { return [:] }
        let dir = kcRoot.appendingPathComponent(folderKey, isDirectory: true)
        guard let index = Inf6DocEntityPersistence.load(detailsDir: dir, pdfKey: folderKey) else { return [:] }

        var pages: [String: Int] = [:]
        for entity in index.entities {
            pages[entity.id.uuidString] = entity.pageIndex
        }
        return pages
    }

    /// 概要解説の表示用テキスト。「用語解説」以降を落とす。
    ///
    /// 「演習で問う観点」の理解点には命題と根拠がそのまま書かれており、項目より前に
    /// 見せると答えが分かってしまう。「用語解説」も手掛かりになるため、両方を後ろへ回す。
    /// 保存テキスト自体は coverageTargets() の解析と overviewMeetsCurrentContract() の
    /// 検証に必要なので削らず、表示だけを切る。
    private func _overviewForDisplay(_ overview: String) -> String {
        let lines = overview.components(separatedBy: .newlines)
        let cut = lines.endIndex
        let hiddenHeadings = Set([
            "要旨", "論文要旨（abstract）", "論文概要", "解説", "数学的導出", "実装", "実務上の検証",
            "Paper overview", "Abstract", "Mathematical derivation", "Implementation", "Practical validation"
        ])
        return lines[..<cut]
            .filter { !hiddenHeadings.contains($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func _overviewSectionBody(
        _ overview: String,
        headings: [String]
    ) -> String {
        let lines = overview.components(separatedBy: .newlines)
        guard let start = _headingLine(lines, headings, from: 0) else { return "" }
        let stopHeadings = [
            "要旨", "論文要旨（abstract）", "論文概要", "解説", "数学的導出", "実装", "実務上の検証",
            "Paper overview", "Abstract", "Mathematical derivation", "Implementation", "Practical validation"
        ]
        let end = _headingLine(lines, stopHeadings, from: start + 1) ?? lines.count
        guard start + 1 < end else { return "" }
        return lines[(start + 1)..<end]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func _explanationForDisplay(_ overview: String) -> String {
        let body = _overviewSectionBody(overview, headings: ["解説", "論文概要", "Paper overview", "Abstract"])
        if !body.isEmpty {
            return _removingTrailingDuplicateCoreTheory(from: body, overview: overview)
        }
        return _removingTrailingDuplicateCoreTheory(from: _overviewForDisplay(overview), overview: overview)
    }

    private func _removingTrailingDuplicateCoreTheory(from body: String, overview: String) -> String {
        let coreTheory = _coreTheoryForDisplay(overview)
        let bodyLines = body.components(separatedBy: .newlines)
        let coreLines = coreTheory.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !coreLines.isEmpty else { return body.trimmingCharacters(in: .whitespacesAndNewlines) }

        var bodyNonEmpty: [(offset: Int, text: String)] = []
        for (offset, line) in bodyLines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                bodyNonEmpty.append((offset, trimmed))
            }
        }
        guard bodyNonEmpty.count >= coreLines.count else {
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let suffix = bodyNonEmpty.suffix(coreLines.count).map(\.text)
        guard Array(suffix) == coreLines, let firstDuplicateLine = bodyNonEmpty.suffix(coreLines.count).first?.offset else {
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return bodyLines[..<firstDuplicateLine]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func _coreTheoryForDisplay(_ overview: String) -> String {
        let body = _overviewSectionBody(overview, headings: ["数学的導出", "Mathematical derivation"])
        // コア理論は箇条書きの集合として表示する。生成データに混在する
        // 段落間の空行は、Live BP の表示上の行間を不統一にするため除去する。
        return body
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }

    /// 旧形式の用語解説は表示しない。
    ///
    /// 見出しは表示側が付ける。本文にも残すと同じ語が二度並ぶ。
    private func _terminologyForDisplay(_ overview: String) -> String {
        return ""
    }

    /// 用語解説に付ける追加解説の保存キー。
    ///
    /// 追加解説は設問ごとに保存される。用語解説は設問ではないので id を持たない。
    /// 論文キーから毎回同じ id を作る。その場で作ると、再起動のたびに別の id に
    /// なり、前に足した解説が見えなくなる。
    private func _terminologyQuestionID(_ folderKey: String, sectionKey: String = "terminology") -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        var index = 0
        for byte in Array("\(sectionKey):\(folderKey)".utf8) {
            bytes[index] = bytes[index] &* 31 &+ byte
            index = (index + 1) % 16
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    @ViewBuilder
    private func _terminologyAskButton(
        entry: Inf6EshikakuDrillPipeline.DrillEntry,
        terminology: String,
        selectedTerm: String? = nil,
        sectionKey: String = "terminology",
        sectionTitle: String? = nil
    ) -> some View {
        let questionID = _terminologyQuestionID(entry.folderKey, sectionKey: sectionKey)
        let currentSelection = selectedTerm?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackSelection = currentSelection?.isEmpty == false ? currentSelection! : terminology
        let asking = _askingQuestionIDs.contains(questionID)
        Button {
            print("[LiveBP][UI] AI_EXPLANATION_TAPPED target=terminology paper=\(entry.folderKey) question=\(questionID.uuidString)")
            _terminologyAskSelectionByQuestionID[questionID] = fallbackSelection
            _terminologyAskPanelQuestionID = questionID
        } label: {
            HStack(spacing: 6) {
                Image(systemName: asking ? "hourglass" : "sparkles")
                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(14), weight: .semibold))
                if !asking {
                    Image(systemName: "chevron.down")
                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(9), weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.86))
                }
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.96), Color.cyan.opacity(0.84)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.24), lineWidth: 1)
            }
            .overlay(alignment: .topTrailing) {
                if asking {
                    ProgressView().tint(.pink).scaleEffect(1.25)
                        .controlSize(.mini)
                        .tint(.white)
                        .padding(.top, 2)
                        .padding(.trailing, 2)
                }
            }
            .shadow(color: Color.blue.opacity(0.18), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(asking)
        .popover(
            isPresented: Binding(
                get: { _terminologyAskPanelQuestionID == questionID },
                set: { isPresented in
                    if !isPresented, _terminologyAskPanelQuestionID == questionID {
                        _terminologyAskPanelQuestionID = nil
                        _terminologyAskSelectionByQuestionID.removeValue(forKey: questionID)
                    }
                }
            ),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            InlinePDFPagesView._ExplainActionsPanelView(
                pageIndex: 0,
                selectionText: _terminologyAskSelectionByQuestionID[questionID] ?? fallbackSelection,
                genLangRaw: _langRaw,
                isRunningExplain: asking,
                onRun: { draft, selectedText, commentText in
                    let action: Inf6DrillExplainAction
                    switch draft.kind {
                    case .summarize, .comment:
                        action = .deeper
                    case .explain:
                        action = .terms
                    }
                    _runAsk(
                        action: action,
                        target: _AskTarget(
                            questionID: questionID,
                            paperKey: entry.folderKey,
                            questionText: sectionTitle ?? L("用語解説", "Terminology"),
                            explanationText: terminology,
                            paperTitle: entry.paper.title,
                            selectedTerm: draft.target == .term ? selectedText : nil
                        ),
                        askedCount: (_askNotesByPaperKey[entry.folderKey] ?? [])
                            .filter { $0.questionID == questionID }.count,
                        allowWebSearch: draft.scope == .web,
                        userComment: commentText
                    )
                    _terminologyAskPanelQuestionID = nil
                    _terminologyAskSelectionByQuestionID.removeValue(forKey: questionID)
                },
                onClose: { _terminologyAskPanelQuestionID = nil }
            )
        }
        .accessibilityLabel(L("解説を追加", "Add explanation"))
        .accessibilityHint(L("解説アクションを開きます", "Open explanation actions"))
        .help(L("対象と操作を選んで解説を実行", "Choose the target and action before running"))
    }

    @ViewBuilder
    private func _terminologyAskNotes(
        entry: Inf6EshikakuDrillPipeline.DrillEntry,
        sectionKey: String = "terminology"
    ) -> some View {
        let questionID = _terminologyQuestionID(entry.folderKey, sectionKey: sectionKey)
        let notes = (_askNotesByPaperKey[entry.folderKey] ?? [])
            .filter { $0.questionID == questionID }
            .sorted { $0.createdAt < $1.createdAt }

        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                _Inf6SelectableText(
                    text: L("追加解説", "Additional explanations"),
                    font: .systemFont(ofSize: 12 * _fontScale, weight: .bold),
                    color: UIColor.secondaryLabel
                )

                ForEach(notes) { note in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "questionmark.circle")
                                .foregroundStyle(.secondary)
                            _Inf6SelectableText(
                                text: note.prompt,
                                font: .systemFont(ofSize: 15 * _fontScale, weight: .semibold),
                                color: UIColor.secondaryLabel
                            )
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                Inf6DrillAskNoteStore.delete(paperKey: entry.folderKey, noteID: note.id)
                                _reloadAskNotes(paperKey: entry.folderKey)
                            } label: {
                                Image(systemName: "trash").foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        _Inf6SelectableText(
                            text: note.answer,
                            font: .systemFont(ofSize: 16 * _fontScale),
                            color: UIColor.label
                        )
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .padding(.top, 2)
        }
    }

    /// 用語解説の1行を「用語」と「説明」に割る。
    ///
    /// 契約は "用語: 説明"。説明の中にも読点として使われるコロンが出るため、
    /// 最初のものだけで割る。割れない行は説明だけとして扱う。
    private func _terminologyRows(_ terminology: String) -> [(term: String, detail: String)] {
        terminology.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                guard let separator = line.range(of: ": ") ?? line.range(of: "：") else {
                    return (term: "", detail: line)
                }
                return (
                    term: String(line[line.startIndex..<separator.lowerBound]),
                    detail: String(line[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
                )
            }
    }

    /// 見出しだけの行を探す。見出しは行頭から単独で置かれる契約。
    private func _headingLine(_ lines: [String], _ headings: [String], from: Int) -> Int? {
        guard from < lines.count else { return nil }
        for index in from..<lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if headings.contains(trimmed) { return index }
        }
        return nil
    }

    private var _topSlideshowControls: some View {
        Group {
            if let entry = _currentSlideshowEntry,
               let quiz = entry.quiz, !quiz.questions.isEmpty {
                let groups = _entityGroups(_liveBPQuestions(quiz, for: entry), folderKey: entry.folderKey)
                let paperKey = entry.folderKey
                let progress = _loadSlideshowProgress(paperKey: paperKey, groups: groups)
                let position = _selectedSlideshowPosition()
                let isPresented = _slideshowPresentedPaperKey == paperKey
                let isPlaying = _slideshowTask != nil && _slideshowPlayingPaperKey == paperKey
                let isPaused = isPresented && !isPlaying
                let selectedCount = _selectedPracticeQuestionCount
                let currentGroup = _currentSlideshowIndex(paperKey: paperKey, groups: groups)
                    .flatMap { groups.indices.contains($0) ? groups[$0] : nil }
                let displayedIndexLabel = currentGroup.map {
                    _slideshowIndexLabel(entry: entry, group: $0, overallPosition: position.current)
                }
                    ?? position.indexLabel

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        Text("Live BP")
                            .font(_font(16, weight: .bold))
                            .foregroundStyle(_dodgersBlue)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(2)

                        Button {
                            if isPlaying {
                                _pauseSlideshow()
                            } else {
                                _startSlideshow(entry: entry, groups: groups)
                            }
                        } label: {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(_font(15, weight: .bold))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel(
                            isPlaying
                                ? "Live BPを一時停止"
                                : (isPaused
                                    ? "Live BPを再開"
                                    : "Live BPを開始")
                        )
                        .help(
                            isPlaying
                                ? "Live BPを一時停止"
                                : (isPaused
                                    ? "Live BPを再開"
                                    : "Live BPを開始")
                        )

                        Button {
                            _stopSlideshow()
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(_font(15, weight: .bold))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Live BPを停止")
                        .help("Live BPを停止")
                        .disabled(!isPlaying)

                        Button {
                            guard isPresented else { return }
                            _moveSlideshowBackwardAcrossSelection()
                        } label: {
                            Image(systemName: "chevron.backward")
                                .font(_font(15, weight: .bold))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedCount == 0 || !isPresented)

                        Button {
                            guard isPresented else { return }
                            _advanceSlideshowAcrossSelection(preferUnseen: false)
                        } label: {
                            Image(systemName: "chevron.forward")
                                .font(_font(15, weight: .bold))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedCount == 0 || !isPresented)

                        Button {
                            guard isPresented else { return }
                            _moveSlideshowToAdjacentNode(-1)
                        } label: {
                            Image(systemName: "arrow.left.to.line")
                                .font(_font(13, weight: .bold))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedCount == 0 || !isPresented || !_canMoveSlideshowNode(-1))
                        .accessibilityLabel(L("前のノードへスキップ", "Skip to previous node"))
                        .help(L("前のノードへスキップ", "Skip to previous node"))

                        Button {
                            guard isPresented else { return }
                            _moveSlideshowToAdjacentNode(1)
                        } label: {
                            Image(systemName: "arrow.right.to.line")
                                .font(_font(13, weight: .bold))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedCount == 0 || !isPresented || !_canMoveSlideshowNode(1))
                        .accessibilityLabel(L("次のノードへスキップ", "Skip to next node"))
                        .help(L("次のノードへスキップ", "Skip to next node"))

                        Text(L("表示 \(Int(progress.secondsPerSlide))秒", "\(Int(progress.secondsPerSlide)) sec"))
                            .font(_font(13))
                            .foregroundStyle(_dodgersBlue)
                            .fixedSize()

                        Stepper(
                            value: Binding(
                                get: { _loadSlideshowProgress(paperKey: paperKey, groups: groups).secondsPerSlide },
                                set: { newValue in
                                    _ = _saveSlideshowProgress(paperKey: paperKey, groups: groups) { book in
                                        book.secondsPerSlide = newValue
                                    }
                                }
                            ),
                            in: 1...120,
                            step: 1
                        ) {
                            EmptyView()
                        }
                        .labelsHidden()
                        .tint(_dodgersBlue)

                        _slideshowPositionView(
                            entry: entry,
                            group: currentGroup,
                            overallPosition: position.current,
                            fallbackLabel: displayedIndexLabel
                        )
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(L("表示位置", "Display position"))

                    }

                    HStack(alignment: .center, spacing: 10) {
                        Spacer(minLength: 0)

                        Toggle(
                            L("未閲覧を優先", "Prefer unseen"),
                            isOn: Binding(
                                get: { _loadSlideshowProgress(paperKey: paperKey, groups: groups).preferUnseenFirst },
                                set: { newValue in
                                    _ = _saveSlideshowProgress(paperKey: paperKey, groups: groups) { book in
                                        book.preferUnseenFirst = newValue
                                    }
                                }
                            )
                        )
                        .foregroundStyle(_dodgersBlue)
                        .toggleStyle(.switch)
                        .fixedSize()

                        Button {
                            _resetSelectedSlideshowProgress()
                        } label: {
                            Label(L("達成度をリセット", "Reset progress"), systemImage: "arrow.counterclockwise")
                                .foregroundStyle(_dodgersBlue)
                        }
                        .buttonStyle(.bordered)
                        .tint(_dodgersBlue)
                    }
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemBackground).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(_dodgersBlue.opacity(0.14), lineWidth: 1)
                }
            }
        }
    }

    @ViewBuilder
    private func _slideshowPositionView(
        entry: Inf6EshikakuDrillPipeline.DrillEntry,
        group: _EntityGroup?,
        overallPosition: Int,
        fallbackLabel: String
    ) -> some View {
        if let group {
            HStack(spacing: 3) {
                Text("#")
                    .font(_font(12, weight: .semibold))
                    .foregroundStyle(_dodgersBlue)
                TextField("#", text: $_slideshowOverallIndexText)
                    .font(_font(12, weight: .semibold))
                    .foregroundStyle(_dodgersBlue)
                    .frame(width: 64)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .submitLabel(.go)
                    .onSubmit {
                        guard let requestedIndex = Int(_slideshowOverallIndexText) else { return }
                        _jumpSlideshowToPosition(requestedIndex)
                    }
                Text(_slideshowIndexPrefix(entry: entry, group: group))
                    .font(_font(12, weight: .semibold))
                    .foregroundStyle(_dodgersBlue)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(0)
                Text("#")
                    .font(_font(12, weight: .semibold))
                    .foregroundStyle(_dodgersBlue)
                TextField("#", text: $_slideshowLocalIndexText)
                    .font(_font(12, weight: .semibold))
                    .foregroundStyle(_dodgersBlue)
                    .frame(width: 64)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .submitLabel(.go)
                    .onSubmit {
                        guard let requestedIndex = Int(_slideshowLocalIndexText) else { return }
                        _jumpSlideshowToLocalIndex(requestedIndex)
                    }
            }
            .onAppear {
                _slideshowOverallIndexText = String(overallPosition)
                _slideshowLocalIndexText = String(group.localIndex)
            }
            .onChange(of: overallPosition) { _, newValue in
                _slideshowOverallIndexText = String(newValue)
            }
            .onChange(of: group.id) { _, _ in
                _slideshowOverallIndexText = String(overallPosition)
                _slideshowLocalIndexText = String(group.localIndex)
            }
        } else {
            Text(fallbackLabel)
                .font(_font(12, weight: .semibold))
                .foregroundStyle(_dodgersBlue)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(0)
        }
    }

    private var _topSlideshowViewer: some View {
        Group {
            if let entry = _currentSlideshowEntry,
               let quiz = entry.quiz, !quiz.questions.isEmpty {
                let groups = _entityGroups(_liveBPQuestions(quiz, for: entry), folderKey: entry.folderKey)
                let overview = _overviewSource(entry: entry, quiz: quiz)
                let coreTheory = _coreTheoryForDisplay(overview)
                let terminology = _terminologyForDisplay(overview)
                if let currentIndex = _currentSlideshowIndex(paperKey: entry.folderKey, groups: groups),
                   groups.indices.contains(currentIndex) {
                    let currentGroup = groups[currentIndex]
                    let currentQuestion = currentGroup.representative
                    let currentTargetID = _liveBPTargetID(currentQuestion)
                    let isHeld = _liveBPReactionsByPaperKey[entry.folderKey]?[currentTargetID] == .hold
                    let isGeneratingAdditional = _liveBPGeneratingQuestionIDs.contains(currentQuestion.id)
                    let canGenerateAdditionalExercise = _liveBPGeneratedPaperKey(for: entry) != nil
                    let isPaperEntry = !_isTextbookField(entry)
                    let displayLeafTitle = L(entry.syllabusTitle ?? entry.paper.title, entry.syllabusTitle ?? entry.paper.title)
                    let displayPathTitle = "\(L(entry.domainLabelJa, entry.domainLabelEn)) / \(displayLeafTitle)"
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(displayPathTitle)
                                    .font(_font(18, weight: .bold))
                                    .foregroundStyle(_dodgersBlue)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)

                                if isPaperEntry {
                                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                                    if let provider = _paperProviderLabel(entry) {
                                        _paperProviderBadge(provider, size: 16)
                                    }
                                    if let year = entry.paper.year {
                                        Text(String(year))
                                            .font(_font(18, weight: .bold))
                                            .foregroundStyle(_dodgersBlue)
                                            .textSelection(.enabled)
                                    }
                                    _Inf6SelectableText(
                                        text: entry.paper.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                        font: .systemFont(ofSize: 18 * _fontScale, weight: .bold),
                                        color: UIColor(_dodgersBlue)
                                    )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }

                            if canGenerateAdditionalExercise {
                                Button {
                                    let generatedPaperKey = _liveBPGeneratedPaperKey(for: entry) ?? entry.folderKey
                                    print("[LiveBP][UI] ADD_EXP_TAPPED paper=\(generatedPaperKey) entryPaper=\(entry.folderKey) question=\(currentQuestion.id.uuidString)")
                                    _prepareAdditionalExerciseSelection(question: currentQuestion, entry: entry)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "plus")
                                            .font(_font(11, weight: .bold))
                                            .foregroundStyle(_dodgersBlue)
                                            .frame(width: 22, height: 22)
                                            .background(_dodgersBlue.opacity(0.14))
                                            .clipShape(Circle())

                                        ZStack(alignment: .bottomTrailing) {
                                            Text("ADD EXERCISE")
                                                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(13 * _fontScale), weight: .heavy, design: .serif))
                                                .italic()
                                                .foregroundStyle(_dodgersBlue)

                                            Capsule()
                                                .fill(_dodgersRed.opacity(0.95))
                                                .frame(width: 26, height: 2)
                                                .rotationEffect(.degrees(-9))
                                                .offset(x: 3, y: 1)
                                        }
                                        .fixedSize()
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 6)
                                    .background(Color.white.opacity(0.96))
                                    .clipShape(Capsule())
                                    .overlay {
                                        Capsule()
                                            .stroke(_dodgersBlue.opacity(0.55), lineWidth: 1.2)
                                    }
                                    .shadow(color: _dodgersBlue.opacity(0.18), radius: 8, x: 0, y: 3)
                                }
                                .buttonStyle(.plain)
                                .disabled(isGeneratingAdditional)
                                .accessibilityLabel("ADD EXERCISE")
                                .help("追加演習を生成")
                            }

                            Button {
                                _setLiveBPHold(
                                    !isHeld,
                                    group: currentGroup,
                                    entry: entry,
                                    groups: groups
                                )
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: isHeld ? "checkmark.square.fill" : "square")
                                        .font(_font(13, weight: .bold))
                                        .foregroundStyle(_dodgersBlue)
                                    Text("HOLD")
                                        .font(.system(size: Inf6ApplicationSystemFont.scaledSize(13 * _fontScale), weight: .heavy, design: .serif))
                                        .italic()
                                        .foregroundStyle(_dodgersBlue)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.white.opacity(0.96))
                                .clipShape(Capsule())
                                .overlay {
                                    Capsule()
                                        .stroke(_dodgersBlue.opacity(isHeld ? 0.95 : 0.55), lineWidth: isHeld ? 1.6 : 1.2)
                                }
                                .shadow(color: _dodgersBlue.opacity(0.18), radius: 8, x: 0, y: 3)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("HOLD")
                            .accessibilityValue(isHeld ? "checked" : "unchecked")
                            .help(isHeld ? "HOLDを解除" : "現在のカードを閲覧履歴に入れない")

                            if !coreTheory.isEmpty {
                                _terminologyAskButton(
                                    entry: entry,
                                    terminology: coreTheory,
                                    sectionKey: "core-theory",
                                    sectionTitle: L("コア理論", "Core theory")
                                )
                            }
                        }

                        if !coreTheory.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                _overviewBodyPanel(coreTheory)
                                _terminologyAskNotes(entry: entry, sectionKey: "core-theory")
                            }
                        }

                        _studyCard(group: currentGroup, entry: entry)

                        if !terminology.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .center, spacing: 10) {
                                    Text(L("用語解説", "Terminology"))
                                        .font(_font(14, weight: .bold))
                                        .foregroundStyle(_dodgersBlue)
                                    Spacer()
                                _terminologyAskButton(
                                    entry: entry,
                                    terminology: terminology,
                                    selectedTerm: _selectedTerminologyByPaperKey[entry.folderKey]
                                )
                                }

                                _terminologyPanel(terminology, paperKey: entry.folderKey)
                                _terminologyAskNotes(entry: entry)
                            }
                        }
                    }
                    .task(id: entry.folderKey) {
                        await _loadOverviewAsync(for: entry)
                        _reloadLiveBPState(paperKey: entry.folderKey)
                        if let generatedPaperKey = _liveBPGeneratedPaperKey(for: entry),
                           generatedPaperKey != entry.folderKey {
                            _reloadLiveBPState(paperKey: generatedPaperKey)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func _overviewPanel(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(_font(14, weight: .bold))
                .foregroundStyle(_dodgersBlue)
            _Inf6SelectableText(
                text: body,
                font: .systemFont(ofSize: 17 * _fontScale, weight: .regular),
                color: UIColor.label
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(_dodgersBlue.opacity(0.18), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func _overviewBodyPanel(_ body: String) -> some View {
        _Inf6SelectableText(
            text: body,
            font: .systemFont(ofSize: 17 * _fontScale, weight: .regular),
            color: UIColor.label
        )
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(_dodgersBlue.opacity(0.18), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func _terminologyPanel(_ terminology: String, paperKey: String) -> some View {
        _Inf6SelectableAttributedTextView(
            attributedText: _terminologyAttributedText(terminology),
            onSelectionChanged: { selected in
                _selectedTerminologyByPaperKey[paperKey] = selected
            }
        )
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(_dodgersBlue.opacity(0.18), lineWidth: 1)
        }
    }

    private func _terminologyAttributedText(_ terminology: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 8

        for (index, row) in _terminologyRows(terminology).enumerated() {
            let line = row.term.isEmpty ? row.detail : "\(row.term): \(row.detail)"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 17 * _fontScale),
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraph
            ]
            result.append(NSAttributedString(string: line, attributes: attributes))
            if index < _terminologyRows(terminology).count - 1 {
                result.append(NSAttributedString(string: "\n"))
            }
        }
        return result
    }

    private func _setLiveBPHold(
        _ held: Bool,
        group: _EntityGroup,
        entry: Inf6EshikakuDrillPipeline.DrillEntry,
        groups: [_EntityGroup]
    ) {
        let question = group.representative
        let targetID = _liveBPTargetID(question)
        let reaction: Inf6LiveBPReaction = held ? .hold : .releaseHold
        let record = Inf6LiveBPReactionRecord(
            paperKey: entry.folderKey,
            targetID: targetID,
            questionID: question.id,
            reaction: reaction
        )
        guard Inf6LiveBPReactionStore.append(record) else {
            _genErrors["liveBP"] = L("Live BPのHOLD状態を保存できませんでした。", "Could not save the Live BP HOLD state.")
            return
        }
        var reactions = _liveBPReactionsByPaperKey[entry.folderKey] ?? [:]
        reactions[targetID] = reaction
        _liveBPReactionsByPaperKey[entry.folderKey] = reactions
        if held {
            _holdSlideshowView(paperKey: entry.folderKey, group: group, groups: groups)
        }
    }

    private func _liveBPTargetID(_ question: Inf6PaperQuizQuestion) -> String {
        question.docEntityID.map { "doc-entity:\($0.uuidString.lowercased())" } ?? "question:\(question.id.uuidString.lowercased())"
    }

    private func _reloadLiveBPState(paperKey: String) {
        _liveBPReactionsByPaperKey[paperKey] = Inf6LiveBPReactionStore.load(paperKey: paperKey).records.reduce(into: [:]) {
            $0[$1.targetID] = $1.reaction
        }
        _liveBPGeneratedByPaperKey[paperKey] = Inf6LiveBPGeneratedExerciseStore.load(paperKey: paperKey).exercises
    }

    private func _liveBPGeneratedPaperKey(for entry: Inf6EshikakuDrillPipeline.DrillEntry) -> String? {
        if let originPaperKey = _liveBPOriginQuizPaperKey(for: entry) {
            return originPaperKey
        }
        if let quizPaperKey = entry.quiz?.paperKey.trimmingCharacters(in: .whitespacesAndNewlines),
           !quizPaperKey.isEmpty {
            return quizPaperKey
        }
        let folderKey = entry.folderKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folderKey.isEmpty else { return nil }
        return folderKey
    }

    private func _liveBPOriginQuizPaperKey(for entry: Inf6EshikakuDrillPipeline.DrillEntry) -> String? {
        guard let nodeID = entry.syllabusNodeID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !nodeID.isEmpty else { return nil }
        let prefix = "\(sourceFamily)|\(nodeID)|"
        let links = Inf6MetadataStore.listByPrefix(domain: .syllabusPaperLinks, prefix: prefix)
            .compactMap { row -> Inf6SyllabusPaperLink? in
                guard let data = row.json.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(Inf6SyllabusPaperLink.self, from: data)
            }
            .filter { link in
                let role = link.sourceRole?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let status = link.verificationStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return role == "origin"
                    && status == "source_verified"
                    && link.originRecordVersion == 1
            }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.paperID.localizedStandardCompare($1.paperID) == .orderedAscending
            }
        for link in links {
            guard let paper = Inf6MetadataStore.getCodable(
                Inf6CorePaper.self,
                domain: .papers,
                key: link.paperID
            ), paper.year != nil else { continue }
            let quizKey = Inf6KnowledgeCardsPaths.normalizedPaperFolderKey(from: link.paperID)
            guard let quiz = Inf6MetadataStore.getCodable(
                Inf6PaperQuiz.self,
                domain: .quiz,
                key: quizKey
            ), !quiz.questions.isEmpty else { continue }
            return quiz.paperKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? quizKey : quiz.paperKey
        }
        return nil
    }

    private func _prepareAdditionalExerciseSelection(
        question: Inf6PaperQuizQuestion,
        entry: Inf6EshikakuDrillPipeline.DrillEntry
    ) {
        guard let index = Inf6MetadataStore.getCodable(
            Inf6DocEntityIndex.self, domain: .docEntities, key: entry.folderKey
        ) else {
            print("[LiveBP][ADD_EXP] candidate_index_missing paper=\(entry.folderKey) question=\(question.id.uuidString)")
            _genErrors["liveBP"] = "論文リーフの図表・数式クロップ結果がありません: \(entry.folderKey)"
            return
        }
        let croppedEntityCount = index.entities.filter {
            $0.imagePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }.count
        let candidates = index.entities
            .filter { entity in
                entity.id == question.docEntityID
                    && entity.imagePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
            .sorted {
                if $0.pageIndex != $1.pageIndex { return $0.pageIndex < $1.pageIndex }
                if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
                if $0.title != $1.title { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                return $0.id.uuidString < $1.id.uuidString
            }
        guard !candidates.isEmpty else {
            print("[LiveBP][ADD_EXP] visual_candidates_empty paper=\(entry.folderKey) total=\(index.entities.count) cropped=\(croppedEntityCount) currentDocEntityID=\(question.docEntityID?.uuidString ?? "nil")")
            _genErrors["liveBP"] = "現在表示中の図表・数式を解決できません。"
            return
        }
        _addExerciseInstruction = ""
        _selectedAddExerciseEntityID = nil
        _addExerciseCandidates = candidates
        _addExerciseSourceQuestionID = question.id
        _addExerciseSourceEntryKey = entry.folderKey
        _isShowingAddExerciseCandidates = true
        print("[LiveBP][ADD_EXP] visual_candidates paper=\(entry.folderKey) count=\(candidates.count)")
    }

    private func _startAdditionalExercise(for entity: Inf6DocEntity, instruction: String) {
        guard let entryKey = _addExerciseSourceEntryKey,
              let questionID = _addExerciseSourceQuestionID,
              let entry = _groups.flatMap(\.entries).first(where: { $0.folderKey == entryKey }),
              let question = entry.quiz?.questions.first(where: { $0.id == questionID }) else {
            _genErrors["liveBP"] = "追加演習の対象リーフまたは元の演習を解決できません。"
            return
        }
        _runAdditionalLiveBPExercise(question: question, entry: entry, entity: entity, instruction: instruction)
    }

    private func _addUnderstandingPoint(
        entry: Inf6EshikakuDrillPipeline.DrillEntry,
        entity question: Inf6PaperQuizQuestion
    ) {
        print("[LiveBP][UI] ADD_UNDERSTANDING_POINT_TAPPED paper=\(entry.folderKey) question=\(question.id.uuidString) docEntityID=\(question.docEntityID.map(\.uuidString) ?? "nil")")
        guard let entityID = question.docEntityID,
              let index = Inf6MetadataStore.getCodable(
                  Inf6DocEntityIndex.self, domain: .docEntities, key: entry.folderKey
              ),
              let entity = index.entities.first(where: { $0.id == entityID }) else {
            _genErrors["liveBP"] = "理解ポイント追加の対象図表数式を解決できません。"
            return
        }
        let source = Inf6PaperQuizQuestion(
            id: question.id,
            pageIndex: question.pageIndex,
            kind: question.kind,
            exerciseType: "regular",
            question: "この図表・数式から理解ポイントを作成する",
            choices: [],
            correctIndex: 0,
            explanation: entity.snippet,
            entityImagePath: entity.imagePath,
            docEntityID: entity.id,
            entityReferenceIDs: entity.references?.map(\.id)
        )
        _runAdditionalLiveBPExercise(
            question: source,
            entry: entry,
            entity: entity,
            instruction: "",
            mode: .understandingPoint
        )
    }

    private func _runAdditionalLiveBPExercise(
        question: Inf6PaperQuizQuestion,
        entry: Inf6EshikakuDrillPipeline.DrillEntry,
        entity: Inf6DocEntity,
        instruction: String,
        mode: _LiveBPGenerationMode = .additionalExercise
    ) {
        _genErrors.removeValue(forKey: "liveBP")
        guard let generatedPaperKey = _liveBPGeneratedPaperKey(for: entry) else {
            let message = "追加演習の保存先paperKeyを解決できません: \(entry.folderKey)"
            print("[LiveBP][ADD_EXP] unresolved_paper_key entryPaper=\(entry.folderKey) question=\(question.id.uuidString)")
            _genErrors["liveBP"] = message
            return
        }
        guard !_liveBPGeneratingQuestionIDs.contains(question.id) else {
            print("[LiveBP][ADD_EXP] duplicate_ignored paper=\(generatedPaperKey) entryPaper=\(entry.folderKey) question=\(question.id.uuidString)")
            return
        }
        print("[LiveBP][ADD_EXP] generation_requested paper=\(generatedPaperKey) entryPaper=\(entry.folderKey) question=\(question.id.uuidString)")
        let resumeSlideshow = _slideshowTask != nil && _slideshowPlayingPaperKey == entry.folderKey
        if resumeSlideshow {
            _pauseSlideshow()
            print("[LiveBP][ADD_EXP] slideshow_timer_paused paper=\(generatedPaperKey) entryPaper=\(entry.folderKey) question=\(question.id.uuidString)")
        }
        _runLiveBPInstruction(
            .addExercise,
            question: question,
            entry: entry,
            generatedPaperKey: generatedPaperKey,
            visualEntity: entity,
            additionalInstruction: instruction,
            resumeSlideshow: resumeSlideshow,
            mode: mode
        )
    }

    private func _runLiveBPInstruction(
        _ reaction: Inf6LiveBPReaction,
        question: Inf6PaperQuizQuestion,
        entry: Inf6EshikakuDrillPipeline.DrillEntry,
        generatedPaperKey: String,
        visualEntity: Inf6DocEntity,
        additionalInstruction: String = "",
        resumeSlideshow: Bool = false,
        mode: _LiveBPGenerationMode = .additionalExercise
    ) {
        guard !_liveBPGeneratingQuestionIDs.contains(question.id) else {
            print("[LiveBP][AI] instruction_duplicate_ignored reaction=\(reaction.rawValue) paper=\(generatedPaperKey) entryPaper=\(entry.folderKey) question=\(question.id.uuidString)")
            return
        }
        _liveBPGeneratingQuestionIDs.insert(question.id)
        let operation: String
        switch mode {
        case .additionalExercise:
            operation = "additionalExercise"
        case .understandingPoint:
            operation = "understandingPoint"
        }
        print("[LiveBP][AI] instruction_started reaction=\(reaction.rawValue) operation=\(operation) paper=\(generatedPaperKey) entryPaper=\(entry.folderKey) question=\(question.id.uuidString)")
        let targetID = _liveBPTargetID(question)
        let visualTargetID = "doc-entity:\(visualEntity.id.uuidString.lowercased())"
        let prompt: String
        switch mode {
        case .additionalExercise:
            prompt = """
            Live Codeの追加演習を1問生成してください。返答はJSONオブジェクトだけにしてください。
            必須キー: question, explanation, kind
            判定: \(reaction.rawValue)
            指示: \(reaction.instruction)
            論文: \(entry.paper.title)
            問題: \(question.question)
            現在の解説: \(question.explanation)
            選択された根拠: \(visualEntity.kind.labelEn) \(visualEntity.title), page=\(visualEntity.pageIndex + 1)
            選択されたdocEntityID: \(visualEntity.id.uuidString)
            選択された根拠の抜粋: \(visualEntity.snippet)
            追加指示: \(additionalInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "なし" : additionalInstruction)

            questionとexplanationは、選択された図表・数式だけを根拠にして作成する。
            explanationは文字列で返し、複数の要点は改行で区切る。配列にはしない。
            元の問題の図表・数式やdocEntityIDを再利用してはいけない。
            kindは選択された根拠の種別（\(visualEntity.kind.rawValue)）にする。
            coverageTargetIDsは返さない。アプリが \(visualTargetID) を設定する。
            JSON以外の文章、Markdown、コードフェンスは禁止。
            """
        case .understandingPoint:
            prompt = """
            選択された図表・数式から、理解ポイントを1件生成してください。返答はJSONオブジェクトだけにしてください。
            必須キー: question, explanation, kind
            論文: \(entry.paper.title)
            対象: \(visualEntity.kind.labelEn) \(visualEntity.title), page=\(visualEntity.pageIndex + 1)
            対象docEntityID: \(visualEntity.id.uuidString)
            図表・数式の抜粋: \(visualEntity.snippet)
            追加指示: \(additionalInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "なし" : additionalInstruction)

            これは理解ポイントであり、選択式演習ではない。
            questionは疑問文ではなく、対象の理論上の要点を言い切る短い見出しにする。
            explanationは対象から読み取れる正しい内容だけを改行区切りの箇条書き文字列で書く。JSON配列にはしない。
            choices、correctIndex、A/B/C/D形式、誤答、誤り例、否定による対比、紛らわしい選択肢を絶対に出さない。
            「どれ」「選びなさい」「正解」「不正解」「誤り」「ではない」「ではなく」を使わない。
            kindは選択された根拠の種別（\(visualEntity.kind.rawValue)）にする。
            元の問題の図表・数式やdocEntityIDを再利用してはいけない。
            coverageTargetIDsは返さない。アプリが \(visualTargetID) を設定する。
            JSON以外の文章、Markdown、コードフェンスは禁止。
            """
        }
        Task { @MainActor in
            defer {
                _liveBPGeneratingQuestionIDs.remove(question.id)
                if resumeSlideshow {
                    _resumeSlideshowTimerIfNeeded()
                    print("[LiveBP][ADD_EXP] slideshow_timer_resumed paper=\(generatedPaperKey) entryPaper=\(entry.folderKey) question=\(question.id.uuidString)")
                }
            }
            do {
                let answer = try await Inf6LibraryView.askOpenAIText(prompt, lang: "ja")
                let cleaned = answer
                    .replacingOccurrences(of: "```json", with: "")
                    .replacingOccurrences(of: "```", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let responsePreview = String(cleaned.prefix(4000))
                    .replacingOccurrences(of: "\\n", with: "\\\\n")
                    .replacingOccurrences(of: "\\r", with: "\\\\r")
                let generated: _LiveBPGenerationResponse
                do {
                    generated = try JSONDecoder().decode(
                        _LiveBPGenerationResponse.self,
                        from: Data(cleaned.utf8)
                    )
                } catch let decodingError as DecodingError {
                    print("[LiveBP][AI] response_decode_failed operation=\(operation) paper=\(generatedPaperKey) entryPaper=\(entry.folderKey) question=\(question.id.uuidString) detail=\(Self._liveBPDecodeFailureDescription(decodingError)) response_prefix=\(responsePreview)")
                    throw decodingError
                }
                guard !generated.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !generated.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw NSError(domain: "Inf6LiveBP", code: 2, userInfo: [NSLocalizedDescriptionKey: "選択した図表・数式に基づく追加演習の内容が空です。"])
                }
                if case .understandingPoint = mode {
                    let generatedText = (generated.question + "\n" + generated.explanation).lowercased()
                    let forbiddenMarkers = [
                        "a.", "b.", "c.", "d.", "正解", "不正解", "誤答", "誤り", "ではない", "ではなく",
                        "どれ", "選びなさい", "選んでください", "which", "what is", "incorrect", "wrong answer"
                    ]
                    guard !forbiddenMarkers.contains(where: generatedText.contains) else {
                        throw NSError(domain: "Inf6LiveBP", code: 7, userInfo: [NSLocalizedDescriptionKey: "理解ポイントに選択肢または誤り例が含まれています。"])
                    }
                }
                let generatedKind = generated.kind.lowercased()
                guard generatedKind == visualEntity.kind.rawValue else {
                    throw NSError(domain: "Inf6LiveBP", code: 4, userInfo: [NSLocalizedDescriptionKey: "追加演習の種別が選択した図表・数式と一致しません。"])
                }
                let exercise = Inf6LiveBPGeneratedExercise(
                    paperKey: generatedPaperKey,
                    targetID: targetID,
                    sourceQuestionID: question.id,
                    reaction: reaction,
                    question: generated.question,
                    explanation: generated.explanation,
                    kind: generatedKind,
                    docEntityID: visualEntity.id,
                    coverageTargetIDs: [visualTargetID],
                    pageIndex: visualEntity.pageIndex,
                    entityImagePath: visualEntity.imagePath,
                    entityReferenceIDs: visualEntity.references?.map(\.id)
                )
                guard var quiz = Inf6MetadataStore.getCodable(
                    Inf6PaperQuiz.self,
                    domain: .quiz,
                    key: generatedPaperKey
                ) else {
                    throw NSError(domain: "Inf6LiveBP", code: 3, userInfo: [NSLocalizedDescriptionKey: "対象論文の通常演習JSONを読み込めませんでした。"])
                }

                let appendedQuestion = exercise.asQuizQuestion()
                // 空の理解ポイントは表示用の仮レコードであり、生成された問題と併存させない。
                // 実データの問題は question/explanation が空でないため削除対象にならない。
                let placeholderEntityID = visualEntity.id.uuidString.lowercased()
                quiz.questions.removeAll { existing in
                    existing.docEntityID?.uuidString.lowercased() == placeholderEntityID
                        && existing.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && existing.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                quiz.questions.append(appendedQuestion)
                guard Inf6MetadataStore.putCodable(quiz, domain: .quiz, key: generatedPaperKey) else {
                    throw NSError(domain: "Inf6LiveBP", code: 5, userInfo: [NSLocalizedDescriptionKey: "追加演習を通常演習JSONへ保存できませんでした。"])
                }
                guard Inf6LiveBPGeneratedExerciseStore.append(exercise) else {
                    throw NSError(domain: "Inf6LiveBP", code: 6, userInfo: [NSLocalizedDescriptionKey: "追加演習をLive BP生成演習ストアへ保存できませんでした。"])
                }
                _liveBPGeneratedByPaperKey[generatedPaperKey] = Inf6LiveBPGeneratedExerciseStore.load(
                    paperKey: generatedPaperKey
                ).exercises

                var refreshedGroups = _groups
                for groupIndex in refreshedGroups.indices {
                    for entryIndex in refreshedGroups[groupIndex].entries.indices
                    where refreshedGroups[groupIndex].entries[entryIndex].folderKey == entry.folderKey
                        || refreshedGroups[groupIndex].entries[entryIndex].quiz?.paperKey == generatedPaperKey {
                        refreshedGroups[groupIndex].entries[entryIndex].quiz = quiz
                    }
                }
                // ネストした要素の変更だけに依存せず、表示元の配列を再代入して
                // 現在のカードを直ちに再構築する。
                _groups = refreshedGroups
                _entityImageRefreshID = UUID()
                Self._loadedGroupsBySourceFamily[sourceFamily] = refreshedGroups
                let currentSequence = _slideshowSequence
                let currentItems = Set(currentSequence)
                let rebuiltSequence = _buildSlideshowSequence()
                _slideshowSequence = currentSequence + rebuiltSequence.filter { !currentItems.contains($0) }
                print("[LiveBP][AI] instruction_succeeded reaction=\(reaction.rawValue) operation=\(operation) paper=\(generatedPaperKey) entryPaper=\(entry.folderKey) question=\(question.id.uuidString) saved=1 ui_refreshed=1")
                if resumeSlideshow {
                    _advanceSlideshowAcrossSelection()
                }
            } catch {
                print("[LiveBP][AI] instruction_failed reaction=\(reaction.rawValue) operation=\(operation) paper=\(generatedPaperKey) entryPaper=\(entry.folderKey) question=\(question.id.uuidString) error=\(error.localizedDescription)")
                _genErrors["liveBP"] = error.localizedDescription
            }
        }
    }

    @MainActor
    private func _deleteEntityImage(
        entry: Inf6EshikakuDrillPipeline.DrillEntry,
        docEntityID: UUID?
    ) {
        guard let docEntityID else {
            _genErrors[entry.folderKey] = "図表数式のdocEntityIDを解決できません。"
            return
        }
        guard var index = Inf6MetadataStore.getCodable(
            Inf6DocEntityIndex.self,
            domain: .docEntities,
            key: entry.folderKey
        ) else {
            _genErrors[entry.folderKey] = "図表数式の保存済みインデックスを読み込めません。"
            return
        }
        guard let entityIndex = index.entities.firstIndex(where: { $0.id == docEntityID }) else {
            _genErrors[entry.folderKey] = "削除対象の図表数式が保存済みインデックスにありません。"
            return
        }

        let oldImagePath = index.entities[entityIndex].imagePath
        index.entities[entityIndex].imagePath = nil
        guard Inf6MetadataStore.putCodable(index, domain: .docEntities, key: entry.folderKey) else {
            _genErrors[entry.folderKey] = "図表数式の削除状態を保存できません。"
            return
        }
        if let oldImagePath, !oldImagePath.isEmpty {
            let imageURL = Inf6EntityImageStore.localBaseURL().appendingPathComponent(oldImagePath)
            do {
                try FileManager.default.removeItem(at: imageURL)
            } catch CocoaError.fileNoSuchFile {
                // 実体が既に無い場合も、保存済みメタデータの削除は完了している。
            } catch {
                _genErrors[entry.folderKey] = "図表数式画像を削除できません: \(error.localizedDescription)"
                return
            }
        }

        var persistedQuizKeys = Set<String>()
        for groupIndex in _groups.indices {
            for entryIndex in _groups[groupIndex].entries.indices {
                guard let quiz = _groups[groupIndex].entries[entryIndex].quiz,
                      quiz.questions.contains(where: { $0.docEntityID == docEntityID }) else { continue }
                var updatedQuiz = quiz
                for questionIndex in updatedQuiz.questions.indices
                where updatedQuiz.questions[questionIndex].docEntityID == docEntityID {
                    updatedQuiz.questions[questionIndex].entityImagePath = nil
                }
                _groups[groupIndex].entries[entryIndex].quiz = updatedQuiz
                let quizKey = updatedQuiz.paperKey
                if !quizKey.isEmpty, persistedQuizKeys.insert(quizKey).inserted {
                    guard Inf6MetadataStore.putCodable(updatedQuiz, domain: .quiz, key: quizKey) else {
                        _genErrors[entry.folderKey] = "図表数式削除後の演習JSONを保存できません。"
                        return
                    }
                }
            }
        }

        let generatedKeys = Set(_liveBPGeneratedByPaperKey.keys)
        for paperKey in generatedKeys {
            var book = Inf6LiveBPGeneratedExerciseStore.load(paperKey: paperKey)
            var changed = false
            for index in book.exercises.indices where book.exercises[index].docEntityID == docEntityID {
                book.exercises[index].entityImagePath = nil
                changed = true
            }
            if changed {
                guard Inf6MetadataStore.putCodable(
                    book,
                    domain: .liveBPGeneratedExercises,
                    key: paperKey
                ) else {
                    _genErrors[entry.folderKey] = "図表数式削除後のLive BP演習を保存できません。"
                    return
                }
                _liveBPGeneratedByPaperKey[paperKey] = book.exercises
            }
        }

        _cropTargetQID = nil
        _genErrors.removeValue(forKey: entry.folderKey)
        Self._loadedGroupsBySourceFamily[sourceFamily] = _groups
        print("[LiveBP][CROP] deleted entity image paper=\(entry.folderKey) docEntityID=\(docEntityID.uuidString)")
    }

    @ViewBuilder
    private func _studyCard(
        group: _EntityGroup,
        entry: Inf6EshikakuDrillPipeline.DrillEntry
    ) -> some View {
        Inf6DrillStudyCard(
            points: group.points,
            langRaw: _langRaw,
            fontScale: _fontScale,
            entityImageMaxHeight: _entityImageMaxHeight,
            tint: _dodgersBlue,
            textTint: _dodgersBlue,
            secondaryTextTint: _dodgersBlueSecondary,
            onImageTap: group.canCrop ? {
                withAnimation(.easeInOut(duration: 0.2)) {
                    _cropTargetQID = (_cropTargetQID == group.representative.id) ? nil : group.representative.id
                    _cropExpTop = 0; _cropExpBottom = 0; _cropExpLeft = 0; _cropExpRight = 0
                }
            } : nil,
            askNotesFor: { questionID in
                (_askNotesByPaperKey[entry.folderKey] ?? [])
                    .filter { $0.questionID == questionID }
                    .sorted { $0.createdAt < $1.createdAt }
            },
            onExplainDraft: { questionID, draft, selectionText in
                guard let q = group.points.first(where: { $0.question.id == questionID })?.question
                else { return }
                let action: Inf6DrillExplainAction
                switch draft.kind {
                case .summarize, .comment:
                    action = .deeper
                case .explain:
                    action = .terms
                }
                _runAsk(
                    action: action,
                    target: _AskTarget(
                        questionID: q.id,
                        paperKey: entry.folderKey,
                        questionText: q.question,
                        explanationText: q.explanation,
                        paperTitle: entry.paper.title,
                        selectedTerm: draft.target == .term ? selectionText : nil
                    ),
                    askedCount: (_askNotesByPaperKey[entry.folderKey] ?? [])
                        .filter { $0.questionID == q.id }.count,
                    allowWebSearch: draft.scope == .web
                )
            },
            onDeleteAskNote: { _, noteID in
                Inf6DrillAskNoteStore.delete(paperKey: entry.folderKey, noteID: noteID)
                _reloadAskNotes(paperKey: entry.folderKey)
            },
            isAsking: { _askingQuestionIDs.contains($0) },
            isLiveBPGenerated: group.id.contains(":live-generated:"),
            onAddUnderstandingPoint: group.isUnderstandingPointMissing ? {
                _addUnderstandingPoint(entry: entry, entity: group.representative)
            } : nil,
            onDeleteEntityImage: group.representative.entityImagePath != nil ? {
                guard let docEntityID = group.representative.docEntityID,
                      _pendingEntityImageDeletion == nil else { return }
                _pendingEntityImageDeletion = _EntityImageDeletionRequest(
                    paperKey: entry.folderKey,
                    docEntityID: docEntityID
                )
            } : nil
        )
        .id("qqc-\(group.id)-\(_entityImageRefreshID)")
        .task(id: entry.folderKey) {
            _reloadAskNotes(paperKey: entry.folderKey)
            _reloadLiveBPState(paperKey: entry.folderKey)
        }

        if _cropTargetQID == group.representative.id,
           let eid = group.representative.docEntityID {
            _inlineCropPanel(entry: entry, docEntityID: eid.uuidString)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder
    private func _entrySection(_ entry: Inf6EshikakuDrillPipeline.DrillEntry, domainID: String) -> some View {
        let title = L(entry.paper.title, entry.paper.titleEn ?? entry.paper.title)

        if let quiz = entry.quiz, !quiz.questions.isEmpty {
            let entityGroups = _entityGroups(_detailQuestions(quiz, for: entry), folderKey: entry.folderKey)
            VStack(alignment: .leading, spacing: 12) {
                _entryHeader(title: title, entry: entry, tint: _domainTint(domainID))

                let overview = _overviewSource(entry: entry, quiz: quiz)
                if !overview.isEmpty {
                    let explanation = _explanationForDisplay(overview)
                        let derivation = _coreTheoryForDisplay(overview)
                        let implementation = _overviewSectionBody(overview, headings: ["実装", "Implementation"])
                        let validation = _overviewSectionBody(overview, headings: ["実務上の検証", "Practical validation"])
                        VStack(alignment: .leading, spacing: 10) {
                        if !explanation.isEmpty {
                            _overviewPanel(title: L("解説", "Explanation"), body: explanation)
                        }
                        if !derivation.isEmpty {
                            _overviewPanel(title: L("数学的導出", "Mathematical derivation"), body: derivation)
                        }
                        if !implementation.isEmpty {
                            _overviewPanel(title: L("実装", "Implementation"), body: implementation)
                        }
                        if !validation.isEmpty {
                            _overviewPanel(title: L("実務上の検証", "Practical validation"), body: validation)
                        }
                    }
                }

                LazyVStack(alignment: .leading, spacing: 10) {
                    // 同じ図表数式に紐づくポイントは1枚のカードにまとめる。
                    // 図を毎回出し直さず、その図に関する理解点を一箇所で読めるようにする。
                    ForEach(entityGroups, id: \.id) { group in
                        _studyCard(group: group, entry: entry)
                    }

                    // 用語解説は演習を解く手掛かりになるため、演習をすべて終えた後に置く。
                    // 長い一覧の末尾になるので、他の節と同じ見出しを付けて識別できるようにする。
                    let terminology = _terminologyForDisplay(overview)
                    if !terminology.isEmpty {
                        Divider()
                            .padding(.top, 4)
                        HStack(alignment: .center, spacing: 10) {
                            Text(L("用語解説", "Terminology"))
                                .font(_font(14, weight: .bold))
                                .foregroundStyle(_dodgersBlue)
                            Spacer()
                            _terminologyAskButton(
                                entry: entry,
                                terminology: terminology,
                                selectedTerm: _selectedTerminologyByPaperKey[entry.folderKey]
                            )
                        }

                        _terminologyPanel(terminology, paperKey: entry.folderKey)
                        _terminologyAskNotes(entry: entry)
                    }
                }
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemBackground).opacity(0.42))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(_domainTint(domainID).opacity(0.22), lineWidth: 1.2)
                    .allowsHitTesting(false)
            }
            .textSelection(.enabled)
            .task { await _loadOverviewAsync(for: entry) }
        }
    }

    @ViewBuilder
    private func _entryHeader(title: String, entry: Inf6EshikakuDrillPipeline.DrillEntry, tint: Color) -> some View {
        let isPaperLeaf = !_isTextbookField(entry)
        let leafTitle = isPaperLeaf
            ? L(entry.syllabusTitle ?? title, entry.syllabusTitle ?? title)
            : title
        let pathTitle = "\(L(entry.domainLabelJa, entry.domainLabelEn)) / \(leafTitle)"

        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint.opacity(0.85))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 6) {
                Text(pathTitle)
                    .font(_font(20, weight: .semibold))
                    .foregroundStyle(_dodgersBlue)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if isPaperLeaf {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let provider = _paperProviderLabel(entry) {
                            _paperProviderBadge(provider, size: 15)
                        }
                        if let year = entry.paper.year {
                            Text(String(year))
                                .font(_font(20, weight: .semibold))
                                .foregroundStyle(_dodgersBlue)
                                .textSelection(.enabled)
                        }
                        Text(title)
                            .font(_font(20, weight: .semibold))
                            .foregroundStyle(_dodgersBlue)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }

            Spacer(minLength: 8)

            _openPaperButton(entry)
        }
        .textSelection(.enabled)
    }




    /// 生成状態は既存の固定ヘッダー行内に収める。
    /// 生成開始時に新しい行を挿入すると safeAreaInset の高さが変わり、
    /// ScrollView の表示位置が上へずれるため、独立した進捗バーは置かない。
    @ViewBuilder
    private var _generationInlineStatus: some View {
        if !_generatingKeys.isEmpty {
            HStack(spacing: 8) {
                ProgressView().tint(.pink).scaleEffect(1.25)
                    .controlSize(.large)
                    .scaleEffect(1.25)
                    .frame(width: 28, height: 28)
                Text(L("生成中", "Generating"))
                    .font(_font(13, weight: .semibold))
                    .foregroundStyle(_dodgersBlue)
                if _generationTotalCount > 0 {
                    Text(L(
                        "\(_generationCompletedCount) / \(_generationTotalCount)",
                        "\(_generationCompletedCount) / \(_generationTotalCount)"
                    ))
                    .font(_font(13, weight: .semibold))
                    .foregroundStyle(_dodgersBlueSecondary)
                }
                Button(role: .cancel) {
                    _cancelGeneration()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(_dodgersBlueError)
            }
            .frame(height: 28)
        }
    }

    /// 論文を別ウィンドウで開くボタン。行と見出しの2箇所で使うため部品化する。
    /// アイコンだけでは何のボタンか分からないので、必ず文字を添える。
    @ViewBuilder
    private func _openPaperButton(_ entry: Inf6EshikakuDrillPipeline.DrillEntry) -> some View {
        if entry.pdfURL != nil || entry.downloadURL != nil {
            let isOpening = _openingPaperKeys.contains(entry.folderKey)
            Button {
                _openPaperInNewWindow(entry)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isOpening ? "hourglass" : "macwindow.on.rectangle")
                    Text(L("論文", "Paper"))
                        .font(_font(12, weight: .semibold))
                }
                .foregroundStyle(_dodgersBlue)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(_dodgersBlue.opacity(0.12))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isOpening)
            .help(L("論文を別ウィンドウで開く", "Open paper in a separate window"))
            .accessibilityLabel(L("論文を別ウィンドウで開く", "Open paper in a separate window"))
        }
    }

    @MainActor
    private func _openPaperInNewWindow(_ entry: Inf6EshikakuDrillPipeline.DrillEntry) {
        guard !_openingPaperKeys.contains(entry.folderKey) else { return }
        _openingPaperKeys.insert(entry.folderKey)
        Task(priority: .userInitiated) {
            do {
                let localPDF = try await Inf6EshikakuDrillPipeline.ensureLocalPDFForOpening(entry: entry)
                _ = await MainActor.run {
                    _openReadablePDFWindow(localPDF, context: entry.folderKey)
                    _openingPaperKeys.remove(entry.folderKey)
                }
            } catch {
                Inf6ErrorIntelligence.recordRuntimeEvent(
                    operation: "drill_open_paper_window",
                    context: entry.folderKey,
                    error: error
                )
                _ = await MainActor.run {
                    _openingPaperKeys.remove(entry.folderKey)
                }
            }
        }
    }

    @MainActor
    private func _openReadablePDFWindow(_ url: URL, context: String) {
        let result = Inf6InlinePDFDocumentLoader.load(from: url)
        guard result.document != nil else {
            let message = result.errorMessage ?? "[IntensiveDrill] PDF document could not be loaded: \(url.path)"
            Inf6ErrorIntelligence.recordRuntimeEvent(
                operation: "drill_open_paper_window_preflight",
                context: context,
                error: NSError(domain: "Inf6IntensiveDrillView", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: message
                ])
            )
            return
        }
        _openWindow(id: "paper", value: url)
    }

    private func _domainTint(_ id: String) -> Color {
        _dodgersBlue
    }

    @ViewBuilder
    private var _fixedTopControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !_isLoading, !_groups.isEmpty {
                _allSelectionRow
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
            }
            _operationProgressStatus
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var _operationProgressStatus: some View {
        if _originExploreTask != nil || _isEvaluatingSyllabusImportance || !_generatingKeys.isEmpty || _recutInProgress {
            HStack(spacing: 10) {
                if _originExploreTask != nil {
                    ProgressView().tint(.pink).scaleEffect(1.25)
                        .controlSize(.large)
                        .scaleEffect(1.2)
                        .frame(width: 28, height: 28)
                    Text(L(
                        "起源探索中 \(_originExploreCompletedCount)/\(_originExploreTotalCount)",
                        "Resolving \(_originExploreCompletedCount)/\(_originExploreTotalCount)"
                    ))
                    .font(_font(13))
                    .foregroundStyle(_dodgersBlueSecondary)
                    Button(role: .cancel) {
                        _cancelOriginExplore()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.bordered)
                }

                if _isEvaluatingSyllabusImportance {
                    ProgressView().tint(.pink).scaleEffect(1.25)
                        .controlSize(.large)
                        .scaleEffect(1.2)
                        .frame(width: 28, height: 28)
                    Text(L(
                        "重要度採点中 \(_syllabusImportanceCompletedCount)/\(_syllabusImportanceTotalCount)",
                        "Scoring \(_syllabusImportanceCompletedCount)/\(_syllabusImportanceTotalCount)"
                    ))
                    .font(_font(13))
                    .foregroundStyle(_dodgersBlueSecondary)
                }

                _generationInlineStatus

                if _recutInProgress {
                    ProgressView().tint(.pink).scaleEffect(1.25)
                        .controlSize(.large)
                        .scaleEffect(1.2)
                        .frame(width: 28, height: 28)
                    Text(L(
                        "クロップ中 \(_recutCompletedCount)/\(_recutTotalCount)",
                        "Cropping \(_recutCompletedCount)/\(_recutTotalCount)"
                    ))
                    .font(_font(13))
                    .foregroundStyle(_dodgersBlueSecondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func _codexSyllabusChapterOptions() -> [Inf6CodexChapterOption] {
        let paperByNodeID: [String: Inf6EshikakuDrillPipeline.DrillEntry] = _groups
            .flatMap { $0.entries }
            .reduce(into: [:]) { result, entry in
                let nodeID = entry.syllabusNodeID ?? entry.id
                if result[nodeID] == nil { result[nodeID] = entry }
            }

        guard let cacheURL = try? Inf6Storage.syllabusOutlineCacheURL(),
              let cache = Inf6DiskJSON.load([String: [Inf6SyllabusOutlineItem]].self, from: cacheURL) else {
            return []
        }

        let sourceCacheMarker: String
        switch sourceFamily.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "jdla_eshikaku", "eshikaku":
            sourceCacheMarker = "eshikaku_outline"
        case "jdla_gkentei":
            sourceCacheMarker = "gkentei_outline"
        case "microsoft_ai_102":
            sourceCacheMarker = "microsoft_learn_outline"
        default:
            return []
        }

        var seen = Set<String>()
        return cache
            .filter { $0.key.lowercased().contains(sourceCacheMarker) }
            .values
            .flatMap { $0 }
            .compactMap { item in
                let title = item.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !item.key.isEmpty, !title.isEmpty, seen.insert(item.key).inserted else { return nil }
                return Inf6CodexChapterOption(
                    id: item.key,
                    title: title,
                    paperID: paperByNodeID[item.key]?.paper.id,
                    depth: item.effectiveDepth
                )
            }
    }

    @ViewBuilder
    private var _toolbarActions: some View {
        let selectedUnresolvedCount = _explorableItemsForSelectedNodes.filter { _genErrors[$0.nodeID] == nil }.count
        let selectedBasePendingCount = _selectedPendingQuizRequests(
            includeBaseQuiz: true,
            includeCodePractice: false
        ).count
        let selectedPythonCount = _allPythonPaperKeys.reduce(into: 0) { count, key in
            if _selectedPythonPaperKeys.contains(key) { count += 1 }
        }
        let selectedQuizCount = _selectedPracticeQuestionCount
        let isBusy = !_generatingKeys.isEmpty || !_exploringOriginNodeIDs.isEmpty || _recutInProgress || _isEvaluatingSyllabusImportance

        HStack(spacing: 8) {
            Menu {
                Button {
                    _startOriginExploreAll()
                } label: {
                    // 実行アクションにはチェックマークを使わない。チェックマークは
                    // 「選択済み」を意味するため、実行項目に付けると選択トグルと混同する。
                    // 対応するチェックボックスとの対応は、丸/四角の形で示す。
                    Label(
                        L("起源解決 (\(selectedUnresolvedCount))", "Resolve Origins (\(selectedUnresolvedCount))"),
                        systemImage: "magnifyingglass"
                    )
                }
                .disabled(_originExploreTask != nil || selectedUnresolvedCount == 0 || isBusy)

                Button {
                    _startGenerateSelected(includeBaseQuiz: true, includeCodePractice: false)
                } label: {
                    Label(
                        L("通常演習生成 (\(selectedBasePendingCount))", "Generate Regular Exercises (\(selectedBasePendingCount))"),
                        systemImage: "wand.and.stars"
                    )
                }
                .disabled(selectedBasePendingCount == 0 || isBusy)

                Button {
                    _startGenerateSelected(includeBaseQuiz: false, includeCodePractice: true)
                } label: {
                    Label(
                        L("Python演習生成 (\(selectedPythonCount))", "Generate Python Exercises (\(selectedPythonCount))"),
                        systemImage: "chevron.left.forwardslash.chevron.right"
                    )
                }
                .disabled(selectedPythonCount == 0 || isBusy)

                Button {
                    _startEvaluateSyllabusImportance()
                } label: {
                    Label(
                        _hasSyllabusImportanceScores
                            ? L("重要度採点 (済)", "Score Importance (done)")
                            : L("重要度採点", "Score Importance"),
                        systemImage: "chart.bar.doc.horizontal"
                    )
                }
                .disabled(_isEvaluatingSyllabusImportance || _hasSyllabusImportanceScores || _groups.isEmpty || isBusy)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "ellipsis.circle")
                    Text(L("操作メニュー", "Actions"))
                        .font(_font(14, weight: .semibold))
                }
                // 地色が青系なので、文字と図柄も同じ青で揃える。
                .foregroundStyle(_dodgersBlue)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(_dodgersBlue.opacity(0.12))
                .clipShape(Capsule())
            }

            Button {
                _startSelectedSlideshow()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(_font(12, weight: .bold))
                        .foregroundStyle(selectedQuizCount == 0 ? _dodgersBlue.opacity(0.42) : _dodgersBlue)
                        .frame(width: 24, height: 24)
                        .background(_dodgersBlue.opacity(selectedQuizCount == 0 ? 0.08 : 0.14))
                        .clipShape(Circle())

                    ZStack(alignment: .bottomTrailing) {
                        Text("Live BP")
                            .font(.system(size: Inf6ApplicationSystemFont.scaledSize(17 * _fontScale), weight: .heavy, design: .serif))
                            .italic()
                            .foregroundStyle(selectedQuizCount == 0 ? _dodgersBlue.opacity(0.42) : _dodgersBlue)

                        Capsule()
                            .fill(_dodgersRed.opacity(selectedQuizCount == 0 ? 0.28 : 0.95))
                            .frame(width: 44, height: 3)
                            .rotationEffect(.degrees(-9))
                            .offset(x: 7, y: 2)
                    }
                    .fixedSize()

                    Text("\(selectedQuizCount)")
                        .font(_font(12, weight: .bold))
                        .foregroundStyle(selectedQuizCount == 0 ? _dodgersBlue.opacity(0.42) : .white)
                        .frame(minWidth: 24, minHeight: 22)
                        .padding(.horizontal, 4)
                        .background(_dodgersBlue.opacity(selectedQuizCount == 0 ? 0.08 : 1.0))
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.white.opacity(selectedQuizCount == 0 ? 0.54 : 0.96))
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .stroke(_dodgersBlue.opacity(selectedQuizCount == 0 ? 0.18 : 0.55), lineWidth: 1.2)
                }
                .shadow(
                    color: selectedQuizCount == 0 ? .clear : _dodgersBlue.opacity(0.18),
                    radius: 10,
                    x: 0,
                    y: 4
                )
            }
            .buttonStyle(.plain)
            .disabled(selectedQuizCount == 0 || isBusy)
            .accessibilityLabel(L("Live BP開始", "Start Live BP"))
            .help(L("選択した生成済み演習を実戦形式で開始", "Start selected generated exercises in Live BP"))

            if !_allPythonPaperKeys.isEmpty {
                _pythonFrameworkToggle
            }
        }
    }

    private var _pythonFrameworkToggle: some View {
        HStack(spacing: 0) {
            ForEach(_PythonPracticeFramework.allCases) { framework in
                _pythonFrameworkButton(framework)
            }
        }
        .padding(3)
        .background(_dodgersBlue.opacity(0.08))
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(_dodgersBlue.opacity(0.35), lineWidth: 1)
        }
    }

    private func _pythonFrameworkButton(_ framework: _PythonPracticeFramework) -> some View {
        let selected = framework == _selectedPythonPracticeFramework
        let label = framework.label
        let foreground: Color = selected ? .white : _dodgersBlue
        let background: Color = selected ? _dodgersBlue : .clear

        return Button {
            _selectedPythonPracticeFramework = framework
        } label: {
            Text(label)
                .font(_font(13, weight: .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, 12)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: 30)
                .background(background)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var _generationControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Spacer()

                if !_revealByQ.isEmpty {
                    Button(role: .destructive) {
                        _selectedByQ = [:]
                        _revealByQ = []
                    } label: {
                        Label(L("リセット", "Reset"), systemImage: "gobackward")
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let err = _recutError {
                let failureCount = err.split(separator: "\n").count
                DisclosureGroup {
                    ScrollView {
                        Text(err)
                            .font(_font(13))
                            .foregroundStyle(_dodgersBlueError)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    .frame(maxHeight: 180)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(L("再クロップ失敗 \(failureCount)件", "Recrop failures: \(failureCount)"))
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            _recutError = nil
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("再クロップエラーを閉じる", "Close recrop errors"))
                    }
                    .font(_font(13, weight: .semibold))
                    .foregroundStyle(_dodgersBlueError)
                }
                .padding(8)
                .background(_dodgersBlueError.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private func _inlineCropPanel(entry: Inf6EshikakuDrillPipeline.DrillEntry, docEntityID: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("クロップ調整", "Crop Adjustment"))
                .font(_font(13, weight: .bold))
                .foregroundStyle(_dodgersBlue)

            HStack(spacing: 12) {
                _cropSlider(label: L("上", "T"), value: $_cropExpTop)
                _cropSlider(label: L("下", "B"), value: $_cropExpBottom)
                _cropSlider(label: L("左", "L"), value: $_cropExpLeft)
                _cropSlider(label: L("右", "R"), value: $_cropExpRight)
            }

            HStack(spacing: 8) {
                Button {
                    _recutSingleEntity(entry: entry, docEntityID: docEntityID)
                } label: {
                    Label(
                        _recutInProgress ? L("処理中…", "…") : L("再クロップ", "Recrop"),
                        systemImage: "crop"
                    )
                    .font(_font(13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(_recutInProgress)

                if _recutInProgress {
                    Button(role: .cancel) {
                        _recutTask?.cancel()
                    } label: {
                        Label(L("キャンセル", "Cancel"), systemImage: "xmark.circle")
                            .font(_font(13, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                }

                if _cropExpTop != 0 || _cropExpBottom != 0 || _cropExpLeft != 0 || _cropExpRight != 0 {
                    Button {
                        _cropExpTop = 0; _cropExpBottom = 0; _cropExpLeft = 0; _cropExpRight = 0
                    } label: {
                        Image(systemName: "gobackward")
                            .font(_font(13))
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button {
                    _cropTargetQID = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(_font(15))
                        .foregroundStyle(_dodgersBlueSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(_dodgersBlue.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(_dodgersBlue.opacity(0.15), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func _cropSlider(label: String, value: Binding<Double>) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(_font(11, weight: .medium))
                .foregroundStyle(_dodgersBlueSecondary)
            Slider(value: value, in: 0...1.0, step: 0.05)
                .frame(minWidth: 50)
            Text(String(format: "%.0f%%", value.wrappedValue * 100))
                .font(_font(10))
                .monospacedDigit()
                .foregroundStyle(_dodgersBlueSecondary)
        }
    }

    @ViewBuilder
    private var _emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let loadError = _genErrors["load"] {
                _Inf6SelectableText(
                    text: loadError,
                    font: .systemFont(ofSize: 16 * _fontScale),
                    color: UIColor(red: 150.0 / 255.0, green: 36.0 / 255.0, blue: 76.0 / 255.0, alpha: 1)
                )
            } else {
                Text(L(
                    "シラバスと論文の対応データが0件です。シラバスノード、論文メタデータ、対応リンクを確認してください。",
                    "No syllabus-to-paper mappings were found. Check syllabus nodes, paper metadata, and linkage records."
                ))
                .font(_font(16))
                .foregroundStyle(_dodgersBlueSecondary)
                .textSelection(.enabled)
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private var _fontScaleControl: some View {
        HStack(spacing: 6) {
            Image(systemName: "textformat.size.smaller")
                .font(.body)
                .foregroundStyle(_dodgersBlue.opacity(0.70))

            Slider(
                value: Binding(
                    get: { Double(_fontScale) },
                    set: { _storedFontScale = min(max($0, 1.0), 2.20) }
                ),
                in: 1.0...2.20,
                step: 0.05
            )
            .frame(width: 190)

            Image(systemName: "textformat.size.larger")
                .font(.body)
                .foregroundStyle(_dodgersBlue.opacity(0.70))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .foregroundStyle(_dodgersBlue.opacity(0.10))
        }
    }

    @ViewBuilder
    private var _settingsMenu: some View {
        let selectedPaperLeafCount = _allPaperLeafKeys.reduce(into: 0) { count, key in
            if _selectedPaperLeafKeys.contains(key) { count += 1 }
        }

        Menu {
            Button {
                _recutAllEntityImages()
            } label: {
                Label(
                    L(
                        "論文リーフの図表数式クロップ（\(selectedPaperLeafCount)件）",
                        "Crop figures, tables, and equations for paper leaves (\(selectedPaperLeafCount))"
                    ),
                    systemImage: "crop"
                )
            }
            .disabled(_recutInProgress || selectedPaperLeafCount == 0)

            Button(role: .destructive) {
                _resetSyllabusImportanceScores(for: _selectedNodeIDs)
            } label: {
                Label(
                    L("IMP値をリセット", "Reset IMP Values"),
                    systemImage: "trash"
                )
            }
            .disabled(_isEvaluatingSyllabusImportance || !_hasSyllabusImportanceScores || _selectedNodeIDs.isEmpty)

            Button(role: .destructive) {
                Inf6EshikakuDrillPipeline.resetOriginResolution(
                    sourceFamily: sourceFamily,
                    nodeIDs: _selectedNodeIDs
                )
                Task { await _loadAll(forceReload: true) }
            } label: {
                Label(
                    L("起源解決をリセット", "Reset Origin Resolution"),
                    systemImage: "arrow.counterclockwise"
                )
            }
            .disabled(_originExploreTask != nil || _selectedNodeIDs.isEmpty)
        } label: {
            Image(systemName: "gearshape.fill")
                .font(_font(16, weight: .semibold))
                .foregroundStyle(_dodgersBlue)
                .frame(width: 34, height: 34)
                .background(_dodgersBlue.opacity(0.10))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("設定", "Settings"))
        .help(L("設定", "Settings"))
    }

    @MainActor
    private func _loadAll(forceReload: Bool = false) async {
        _reloadSyllabusImportanceScores()
        _loadSelectionTask?.cancel()
        _loadSelectionTask = nil
        let runID = UUID()
        _loadRunID = runID
        defer {
            if _loadRunID == runID {
                _isLoading = false
                _loadRunID = nil
                _loadSelectionTask = nil
            }
        }

        let sf = sourceFamily
        let currentRevision = Inf6DataExchange.currentRevision()
        if Self._loadedGroupsRevision != currentRevision {
            Self._loadedGroupsBySourceFamily.removeAll()
            Self._loadedGroupsRevision = currentRevision
        }
        if !forceReload, let cached = Self._loadedGroupsBySourceFamily[sf] {
            _groups = cached
            _refreshVisualEntityCounts(for: cached)
            _initializeDefaultExerciseSelectionIfNeeded()
            if let playing = _slideshowPlayingPaperKey,
               !cached.flatMap(\.entries).contains(where: { $0.folderKey == playing }) {
                _stopSlideshow()
            }
            NSLog("[DrillView] reused cached groups for %@: %d entries", sf, cached.flatMap(\.entries).count)
            return
        }

        // 既にリストが表示されている状態でのforceReloadは、ローディング画面に差し替えない。
        // 差し替えるとノード一覧全体が作り直され、スクロール位置が失われるため、裏で静かに更新する。
        if !(forceReload && !_groups.isEmpty) {
            _isLoading = true
        }
        do {
            let loadTask = Task.detached(priority: .userInitiated) {
                try Inf6EshikakuDrillPipeline.selectOriginPapers(sourceFamily: sf, forcePapersReload: forceReload)
            }
            _loadSelectionTask = loadTask
            let result = try await withTaskCancellationHandler {
                try await loadTask.value
            } onCancel: {
                loadTask.cancel()
            }
            guard _loadRunID == runID, !Task.isCancelled else { return }
            if let playing = _slideshowPlayingPaperKey,
               !result.flatMap(\.entries).contains(where: { $0.folderKey == playing }) {
                _stopSlideshow()
            }
            _groups = result
            _refreshVisualEntityCounts(for: result)
            Self._loadedGroupsBySourceFamily[sf] = result
            _initializeDefaultExerciseSelectionIfNeeded()
        } catch is CancellationError {
            return
        } catch {
            guard _loadRunID == runID, !Task.isCancelled else { return }
            Inf6ErrorIntelligence.record(
                operation: "eshikaku_drill_load",
                context: sf,
                error: error
            )
            _groups = []
            _genErrors["load"] = error.localizedDescription
        }
        guard _loadRunID == runID, !Task.isCancelled else { return }
        NSLog("[DrillView] %d entries loaded",
              _groups.flatMap(\.entries).count)
    }

    @MainActor
    private func _reloadSyllabusImportanceScores() {
        guard let book = Inf6SyllabusImportanceScoreStore.load(sourceFamily: sourceFamily) else {
            _syllabusImportanceByNodeID = [:]
            _syllabusImportanceByDomainID = [:]
            return
        }
        _syllabusImportanceByNodeID = Dictionary(uniqueKeysWithValues: book.nodes.compactMap { item in
            guard let nodeID = item.nodeID, !nodeID.isEmpty else { return nil }
            return (nodeID, item)
        })
        _syllabusImportanceByDomainID = Dictionary(uniqueKeysWithValues: book.domains.map { ($0.id, $0) })
    }

    @MainActor
    private func _startEvaluateSyllabusImportance() {
        guard !_isEvaluatingSyllabusImportance else { return }
        guard !_hasSyllabusImportanceScores else { return }
        let request = _syllabusImportanceRequest()
        guard !request.domains.isEmpty, !request.nodes.isEmpty else {
            _genErrors["syllabus_importance"] = L(
                "E資格シラバスのドメイン/ノードが読み込まれていないため、重要度採点を実行できません。",
                "Syllabus domains/nodes are not loaded, so importance scoring cannot run."
            )
            return
        }
        let sf = sourceFamily
        _isEvaluatingSyllabusImportance = true
        _syllabusImportanceCompletedCount = 0
        _syllabusImportanceTotalCount = request.nodes.count
        _genErrors.removeValue(forKey: "syllabus_importance")
        Task { @MainActor in
            defer {
                _isEvaluatingSyllabusImportance = false
                _syllabusImportanceCompletedCount = 0
                _syllabusImportanceTotalCount = 0
            }
            do {
                let book = try await _evaluateSyllabusImportanceWithLLM(
                    sourceFamily: sf,
                    domains: request.domains,
                    nodes: request.nodes,
                    onProgress: { completed in
                        Task { @MainActor in
                            _syllabusImportanceCompletedCount = completed
                        }
                    }
                )
                guard Inf6SyllabusImportanceScoreStore.save(book) else {
                    throw NSError(domain: "Inf6SyllabusImportance", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: "E資格シラバス重要度を保存できませんでした。"
                    ])
                }
                _reloadSyllabusImportanceScores()
            } catch {
                Inf6ErrorIntelligence.recordRuntimeEvent(
                    operation: "eshikaku_syllabus_importance",
                    context: sf,
                    error: error
                )
                _genErrors["syllabus_importance"] = error.localizedDescription
            }
        }
    }

    @MainActor
    private func _resetSyllabusImportanceScores(for nodeIDs: Set<String>) {
        guard !_isEvaluatingSyllabusImportance else { return }
        guard var book = Inf6SyllabusImportanceScoreStore.load(sourceFamily: sourceFamily) else { return }
        let selected = nodeIDs
        book.nodes.removeAll { score in
            guard let nodeID = score.nodeID else { return false }
            return selected.contains(nodeID) || selected.contains(score.id)
        }
        guard Inf6SyllabusImportanceScoreStore.save(book) else {
            _genErrors["syllabus_importance"] = "IMP値を保存できませんでした。"
            return
        }
        _syllabusImportanceByNodeID = Dictionary(
            uniqueKeysWithValues: book.nodes.compactMap { score in
                guard let nodeID = score.nodeID else { return nil }
                return (nodeID, score)
            }
        )
        _syllabusImportanceByDomainID = Dictionary(
            uniqueKeysWithValues: book.domains.map { ($0.id, $0) }
        )
        _syllabusImportanceCompletedCount = 0
        _syllabusImportanceTotalCount = 0
        _genErrors.removeValue(forKey: "syllabus_importance")
    }

    private func _syllabusImportanceRequest() -> (
        domains: [_SyllabusImportanceRequestDomain],
        nodes: [_SyllabusImportanceRequestNode]
    ) {
        var domainsByID: [String: _SyllabusImportanceRequestDomain] = [:]
        var nodesByID: [String: _SyllabusImportanceRequestNode] = [:]
        for group in _groups {
            domainsByID[group.id] = _SyllabusImportanceRequestDomain(
                id: group.id,
                domainPrefix: group.id,
                titleJa: group.labelJa,
                titleEn: group.labelEn
            )
            for leaf in _leafNodeGroups(group) {
                let firstEntry = leaf.entries.first
                let unresolved = leaf.unresolved
                let titleJa = unresolved?.titleJa
                    ?? firstEntry?.syllabusTitle
                    ?? leaf.id
                let titleEn = unresolved?.titleEn ?? ""
                nodesByID[leaf.id] = _SyllabusImportanceRequestNode(
                    id: leaf.id,
                    domainID: group.id,
                    domainPrefix: firstEntry?.domainPrefix ?? unresolved?.domainPrefix ?? group.id,
                    domainLabelJa: firstEntry?.domainLabelJa ?? unresolved?.domainLabelJa ?? group.labelJa,
                    domainLabelEn: firstEntry?.domainLabelEn ?? unresolved?.domainLabelEn ?? group.labelEn,
                    titleJa: titleJa,
                    titleEn: titleEn
                )
            }
        }
        return (
            domainsByID.values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending },
            nodesByID.values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        )
    }

    private struct _SyllabusImportancePayload: Encodable {
        let domains: [_SyllabusImportanceRequestDomain]
        let nodes: [_SyllabusImportanceRequestNode]
    }

    private func _evaluateSyllabusImportanceWithLLM(
        sourceFamily: String,
        domains: [_SyllabusImportanceRequestDomain],
        nodes: [_SyllabusImportanceRequestNode],
        onProgress: @escaping @Sendable (Int) -> Void
    ) async throws -> Inf6SyllabusImportanceScoreBook {
        let domainResponses = try await _evaluateSyllabusDomainsWithLLM(domains)
        var nodeResponses: [_SyllabusImportanceResponseItem] = []
        var completed = 0
        for chunk in stride(from: 0, to: nodes.count, by: 40).map({ Array(nodes[$0..<min($0 + 40, nodes.count)]) }) {
            let responses = try await _evaluateSyllabusNodesWithLLM(chunk)
            try _validateSyllabusNodeImportanceResponse(responses, nodes: chunk)
            nodeResponses.append(contentsOf: responses.nodes)
            completed += chunk.count
            onProgress(completed)
        }
        let decoded = _SyllabusImportanceResponse(domains: domainResponses.domains, nodes: nodeResponses)
        try _validateSyllabusImportanceResponse(decoded, domains: domains, nodes: nodes)
        let domainByID = Dictionary(uniqueKeysWithValues: domains.map { ($0.id, $0) })
        let nodeByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let now = Date().timeIntervalSince1970
        let domainScores = decoded.domains.map { response in
            let source = domainByID[response.id]!
            return Inf6SyllabusImportanceScore(
                id: source.id,
                scope: "domain",
                domainPrefix: source.domainPrefix,
                domainLabelJa: source.titleJa,
                domainLabelEn: source.titleEn,
                titleJa: source.titleJa,
                titleEn: source.titleEn,
                examImportanceScore: response.examImportanceScore,
                examImportanceReason: response.examImportanceReason,
                evaluatedAt: now
            )
        }
        let nodeScores = decoded.nodes.map { response in
            let source = nodeByID[response.id]!
            return Inf6SyllabusImportanceScore(
                id: source.id,
                scope: "node",
                domainPrefix: source.domainPrefix,
                domainLabelJa: source.domainLabelJa,
                domainLabelEn: source.domainLabelEn,
                nodeID: source.id,
                titleJa: source.titleJa,
                titleEn: source.titleEn,
                examImportanceScore: response.examImportanceScore,
                examImportanceReason: response.examImportanceReason,
                evaluatedAt: now
            )
        }
        return Inf6SyllabusImportanceScoreBook(
            sourceFamily: sourceFamily,
            domains: domainScores,
            nodes: nodeScores,
            createdAt: now
        )
    }

    private func _evaluateSyllabusDomainsWithLLM(
        _ domains: [_SyllabusImportanceRequestDomain]
    ) async throws -> _SyllabusImportanceResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payloadData = try encoder.encode(_SyllabusImportancePayload(domains: domains, nodes: []))
        guard let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            throw NSError(domain: "Inf6SyllabusImportance", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "E資格シラバス重要度のdomain入力JSONを生成できませんでした。"
            ])
        }
        let systemInstruction = """
        You are scoring JLDA E資格 syllabus domains for exam importance.
        Return one JSON object only. Do not include Markdown.
        """
        let userPrompt = """
        E資格試験上のドメイン重要度を0から100の整数で採点してください。
        判断軸は、E資格で問われる中心性、頻出性、他項目への前提性、誤答しやすさです。

        出力JSONの形:
        {"domains":[{"id":"...","examImportanceScore":0,"examImportanceReason":"60字以内"}],"nodes":[]}

        入力にある全domain idを、過不足なく1回ずつ返してください。
        unknown idは禁止です。

        入力:
        \(payloadJSON)
        """
        let answer = try await Inf6LibraryView.askOpenAIJSONObject(
            systemInstruction: systemInstruction,
            userPrompt: userPrompt
        )
        let decoded = try JSONDecoder().decode(_SyllabusImportanceResponse.self, from: Data(answer.utf8))
        try _validateSyllabusImportanceResponse(decoded, domains: domains, nodes: [])
        return decoded
    }

    private func _evaluateSyllabusNodesWithLLM(
        _ nodes: [_SyllabusImportanceRequestNode]
    ) async throws -> _SyllabusNodeImportanceResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payloadData = try encoder.encode(_SyllabusImportancePayload(domains: [], nodes: nodes))
        guard let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            throw NSError(domain: "Inf6SyllabusImportance", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "E資格シラバス重要度のnode入力JSONを生成できませんでした。"
            ])
        }
        let systemInstruction = """
        You are scoring JLDA E資格 syllabus nodes for exam importance.
        Return one JSON object only. Do not include Markdown.
        """
        let userPrompt = """
        E資格試験上のノード重要度を0から100の整数で採点してください。
        論文名や実装フレームワーク名だけで高得点にしないでください。
        判断軸は、E資格で問われる中心性、頻出性、他項目への前提性、誤答しやすさです。

        出力JSONの形:
        {"nodes":[{"id":"...","examImportanceScore":0,"examImportanceReason":"60字以内"}]}

        入力にある全node idを、過不足なく1回ずつ返してください。
        unknown idは禁止です。

        入力:
        \(payloadJSON)
        """
        let answer = try await Inf6LibraryView.askOpenAIJSONObject(
            systemInstruction: systemInstruction,
            userPrompt: userPrompt
        )
        return try JSONDecoder().decode(_SyllabusNodeImportanceResponse.self, from: Data(answer.utf8))
    }

    private func _validateSyllabusImportanceResponse(
        _ response: _SyllabusImportanceResponse,
        domains: [_SyllabusImportanceRequestDomain],
        nodes: [_SyllabusImportanceRequestNode]
    ) throws {
        let expectedDomainIDs = Set(domains.map(\.id))
        let expectedNodeIDs = Set(nodes.map(\.id))
        let actualDomainIDs = response.domains.map(\.id)
        let actualNodeIDs = response.nodes.map(\.id)
        guard Set(actualDomainIDs) == expectedDomainIDs,
              actualDomainIDs.count == expectedDomainIDs.count else {
            throw NSError(domain: "Inf6SyllabusImportance", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "LLMのdomain採点結果が入力ドメインと一致しません。"
            ])
        }
        guard Set(actualNodeIDs) == expectedNodeIDs,
              actualNodeIDs.count == expectedNodeIDs.count else {
            throw NSError(domain: "Inf6SyllabusImportance", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "LLMのnode採点結果が入力ノードと一致しません。"
            ])
        }
        let allItems = response.domains + response.nodes
        guard allItems.allSatisfy({ (0...100).contains($0.examImportanceScore) }) else {
            throw NSError(domain: "Inf6SyllabusImportance", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "LLMの重要度スコアが0から100の範囲外です。"
            ])
        }
        guard allItems.allSatisfy({ !$0.examImportanceReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw NSError(domain: "Inf6SyllabusImportance", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "LLMの重要度理由が空です。"
            ])
        }
    }

    private func _validateSyllabusNodeImportanceResponse(
        _ response: _SyllabusNodeImportanceResponse,
        nodes: [_SyllabusImportanceRequestNode]
    ) throws {
        let expectedNodeIDs = Set(nodes.map(\.id))
        let actualNodeIDs = response.nodes.map(\.id)
        guard Set(actualNodeIDs) == expectedNodeIDs,
              actualNodeIDs.count == expectedNodeIDs.count else {
            throw NSError(domain: "Inf6SyllabusImportance", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "LLMのnode分割採点結果が入力ノードと一致しません。"
            ])
        }
        guard response.nodes.allSatisfy({ (0...100).contains($0.examImportanceScore) }) else {
            throw NSError(domain: "Inf6SyllabusImportance", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "LLMのnode分割重要度スコアが0から100の範囲外です。"
            ])
        }
        guard response.nodes.allSatisfy({ !$0.examImportanceReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw NSError(domain: "Inf6SyllabusImportance", code: 9, userInfo: [
                NSLocalizedDescriptionKey: "LLMのnode分割重要度理由が空です。"
            ])
        }
    }

    @MainActor
    private func _startOriginExploreAll() {
        guard _originExploreTask == nil else { return }
        let items = _explorableItemsForSelectedNodes.filter { _genErrors[$0.nodeID] == nil }
        guard !items.isEmpty else { return }
        _originExploreCompletedCount = 0
        _originExploreTotalCount = items.count
        let sf = sourceFamily
        let extraByNode = _extraInstructions
        _originExploreTask = Task {
            let askModel: (String) async throws -> String = { prompt in
                try Task.checkCancellation()
                return try await Inf6LibraryView.askOpenAIText(prompt, lang: "ja", allowWebSearch: true)
            }
            for item in items {
                if Task.isCancelled { break }
                _ = await MainActor.run {
                    _exploringOriginNodeIDs.insert(item.nodeID)
                }
                do {
                    _ = try await Inf6EshikakuDrillPipeline.exploreOriginHistory(
                        item: item,
                        sourceFamily: sf,
                        extraInstruction: extraByNode[item.nodeID],
                        askModel: askModel
                    )
                } catch {
                    if Task.isCancelled { break }
                    Inf6ErrorIntelligence.recordRuntimeEvent(
                        operation: "eshikaku_origin_explore_auto",
                        context: "\(sf)|\(item.nodeID)",
                        error: error
                    )
                    await MainActor.run {
                        _genErrors[item.nodeID] = error.localizedDescription
                    }
                }
                await MainActor.run {
                    _exploringOriginNodeIDs.remove(item.nodeID)
                    _originExploreCompletedCount += 1
                }
            }
            if !Task.isCancelled {
                await _loadAll(forceReload: true)
            }
            await MainActor.run {
                _originExploreTask = nil
                _exploringOriginNodeIDs.removeAll()
                _originExploreCompletedCount = 0
                _originExploreTotalCount = 0
            }
        }
    }

    @MainActor
    private func _cancelOriginExplore() {
        _originExploreTask?.cancel()
        _originExploreTask = nil
        _exploringOriginNodeIDs.removeAll()
        _originExploreCompletedCount = 0
        _originExploreTotalCount = 0
    }

    @MainActor
    private func _cancelLoadAll() {
        _loadSelectionTask?.cancel()
        _loadSelectionTask = nil
        _loadRunID = nil
        _isLoading = false
    }

    private func _selectedPendingQuizRequests(
        includeBaseQuiz: Bool,
        includeCodePractice: Bool
    ) -> [_GenerationRequest] {
        var seenFolderKeys = Set<String>()
        return _groups.flatMap(\.entries).compactMap { entry in
            let key = _paperKey(entry)
            let needsBase = includeBaseQuiz
                && _selectedPaperKeys.contains(key)
                && _needsBaseQuizGeneration(entry)
            let selectedPython = includeCodePractice
                && _selectedPythonPaperKeys.contains(key)
                && _isPythonGenerationTarget(entry)
            guard needsBase || selectedPython else { return nil }
            guard seenFolderKeys.insert(entry.folderKey).inserted else { return nil }
            return _GenerationRequest(
                entry: entry,
                generateBaseQuiz: needsBase,
                generateCodePractice: selectedPython
            )
        }
    }

    @MainActor
    private func _startGenerateSelected(
        includeBaseQuiz: Bool,
        includeCodePractice: Bool
    ) {
        guard !_isGenerationRunning else { return }
        _isGenerationRunning = true
        _genErrors.removeAll()
        let requests = _selectedPendingQuizRequests(
            includeBaseQuiz: includeBaseQuiz,
            includeCodePractice: includeCodePractice
        )
        let regularRequestCount = requests.filter(\.generateBaseQuiz).count
        let pythonRequestCount = requests.filter(\.generateCodePractice).count
        NSLog("[DrillView] generate requested: total=%d regular=%d python=%d",
              requests.count, regularRequestCount, pythonRequestCount)
        guard !requests.isEmpty else {
            _isGenerationRunning = false
            return
        }
        _generationCompletedCount = 0
        _generationTotalCount = requests.count
        let sf = sourceFamily
        let task = Task {
            await withTaskGroup(of: _GenerationOutcome.self) { group in
                var iterator = requests.makeIterator()
                var activeCount = 0
                var stopSubmitting = false

                func submit(_ request: _GenerationRequest) {
                    activeCount += 1
                    group.addTask {
                        if Task.isCancelled {
                            let entry = request.entry
                            return _GenerationOutcome(entryID: entry.id, folderKey: entry.folderKey, quiz: nil, errorMessage: nil, wasCancelled: true, stopsBatch: false)
                        }
                        let entry = request.entry
                        let entryTask = Task {
                            await Self._runGeneration(
                                entry: entry,
                                sourceFamily: sf,
                                generateBaseQuiz: request.generateBaseQuiz,
                                generateCodePractice: request.generateCodePractice
                            )
                        }
                        await MainActor.run {
                            _generationTasks[entry.folderKey] = entryTask
                            _generatingKeys.insert(entry.folderKey)
                            _genErrors.removeValue(forKey: entry.folderKey)
                        }
                        return await entryTask.value
                    }
                }

                while activeCount < 3, let entry = iterator.next() {
                    submit(entry)
                }

                for await outcome in group {
                    activeCount -= 1
                    await MainActor.run {
                        _applyGenerationOutcome(outcome)
                        _generationCompletedCount += 1
                        if outcome.stopsBatch {
                            let keys = _generationTasks.keys.filter { $0 != outcome.folderKey }
                            for key in keys {
                                _generationTasks[key]?.cancel()
                                _generationTasks.removeValue(forKey: key)
                                _generatingKeys.remove(key)
                            }
                        }
                    }
                    if outcome.stopsBatch {
                        stopSubmitting = true
                        group.cancelAll()
                    }
                    if !stopSubmitting, !Task.isCancelled, let next = iterator.next() {
                        submit(next)
                    }
                }
            }
            await MainActor.run {
                _pendingGenerationTask = nil
                _isGenerationRunning = false
                if _generatingKeys.isEmpty {
                    _generationCompletedCount = 0
                    _generationTotalCount = 0
                }
            }
        }
        _pendingGenerationTask = task
    }

    @MainActor
    private func _startGenerateForEntry(
        _ entry: Inf6EshikakuDrillPipeline.DrillEntry,
        generateBaseQuiz requestedBaseQuiz: Bool? = nil,
        generateCodePractice requestedCodePractice: Bool? = nil
    ) {
        guard _generationTasks[entry.folderKey] == nil else { return }
        _generationCompletedCount = 0
        _generationTotalCount = 1
        _generatingKeys.insert(entry.folderKey)
        _genErrors.removeValue(forKey: entry.folderKey)
        let sf = sourceFamily
        let key = _paperKey(entry)
        let generateBaseQuiz = requestedBaseQuiz ?? (_selectedPaperKeys.contains(key) && _needsBaseQuizGeneration(entry))
        let generateCodePractice = requestedCodePractice ?? (_selectedPythonPaperKeys.contains(key) && _needsPythonQuizGeneration(entry))
        let entryTask = Task {
            await Self._runGeneration(
                entry: entry,
                sourceFamily: sf,
                generateBaseQuiz: generateBaseQuiz,
                generateCodePractice: generateCodePractice
            )
        }
        _generationTasks[entry.folderKey] = entryTask
        Task {
            let outcome = await entryTask.value
            await MainActor.run {
                _applyGenerationOutcome(outcome)
                if !outcome.wasCancelled { _generationCompletedCount = 1 }
                if _generatingKeys.isEmpty {
                    _generationCompletedCount = 0
                    _generationTotalCount = 0
                }
            }
        }
    }

    @MainActor
    private func _cancelGeneration(key: String? = nil) {
        if let key {
            _generationTasks[key]?.cancel()
            _generationTasks.removeValue(forKey: key)
            _generatingKeys.remove(key)
            if _generatingKeys.isEmpty {
                _generationCompletedCount = 0
                _generationTotalCount = 0
            }
            return
        }
        _pendingGenerationTask?.cancel()
        _pendingGenerationTask = nil
        _isGenerationRunning = false
        _exploringOriginNodeIDs.removeAll()
        for task in _generationTasks.values {
            task.cancel()
        }
        _generationTasks.removeAll()
        _generatingKeys.removeAll()
        _generationCompletedCount = 0
        _generationTotalCount = 0
    }

    @MainActor
    private func _recutAllEntityImages() {
        guard !_recutInProgress else { return }
        _genErrors.removeValue(forKey: "liveBP")
        let selectedEntries = _groups.flatMap(\.entries).filter { entry in
            !_isTextbookField(entry) && _selectedPaperLeafKeys.contains(_paperKey(entry))
        }
        _recutInProgress = true
        _recutError = nil
        var seenFolderKeys = Set<String>()
        let selectedPaperEntries = selectedEntries.filter { entry in
            seenFolderKeys.insert(entry.folderKey).inserted
        }
        _recutCompletedCount = 0
        _recutTotalCount = selectedPaperEntries.count
        let expansion = _cropExpansion
        NSLog(
            "[LiveBP][CROP] requested paperLeaves=%d matchedEntries=%d uniquePDFs=%d",
            _selectedPaperLeafKeys.count,
            selectedEntries.count,
            selectedPaperEntries.count
        )
        _recutTask = Task.detached(priority: .userInitiated) {
            var errors: [String] = []
            for entry in selectedPaperEntries {
                NSLog("[LiveBP][CROP] processing paper=%@", entry.folderKey)
                do {
                    try await Inf6EshikakuDrillPipeline.recutEntityImages(
                        entry: entry,
                        expansion: expansion,
                        entityFilter: [.figure, .table, .equation]
                    )
                    NSLog("[LiveBP][CROP] processing_succeeded paper=%@", entry.folderKey)
                } catch {
                    NSLog(
                        "[LiveBP][CROP] processing_failed paper=%@ error=%@",
                        entry.folderKey,
                        error.localizedDescription
                    )
                    errors.append("\(entry.paper.title): \(error.localizedDescription)")
                }
                _ = await MainActor.run {
                    _recutCompletedCount += 1
                }
            }
            let recutErrors = errors
            _ = await MainActor.run {
                _recutTask = nil
                _recutInProgress = false
                _recutCompletedCount = 0
                _recutTotalCount = 0
                _entityImageRefreshID = UUID()
                _refreshVisualEntityCounts(for: _groups)
                if !recutErrors.isEmpty {
                    _recutError = recutErrors.joined(separator: "\n")
                }
                NSLog(
                    "[LiveBP][CROP] finished success=%d failed=%d",
                    selectedPaperEntries.count - recutErrors.count,
                    recutErrors.count
                )
            }
        }
    }

    @MainActor
    private func _recutSingleEntity(entry: Inf6EshikakuDrillPipeline.DrillEntry, docEntityID: String) {
        guard !_recutInProgress else { return }
        _recutInProgress = true
        _recutCompletedCount = 0
        _recutTotalCount = 1
        _recutError = nil
        let expansion = _cropExpansion
        _recutTask = Task.detached(priority: .userInitiated) {
            do {
                let imagePath = try await Inf6EshikakuDrillPipeline.recutSingleEntityImage(
                    entry: entry,
                    docEntityID: docEntityID,
                    expansion: expansion
                )
                await MainActor.run {
                    for groupIndex in _groups.indices {
                        guard let entryIndex = _groups[groupIndex].entries.firstIndex(where: { $0.id == entry.id }),
                              var quiz = _groups[groupIndex].entries[entryIndex].quiz else { continue }
                        for questionIndex in quiz.questions.indices
                        where quiz.questions[questionIndex].docEntityID?.uuidString == docEntityID {
                            quiz.questions[questionIndex].entityImagePath = imagePath
                        }
                        _groups[groupIndex].entries[entryIndex].quiz = quiz
                    }
                }
            } catch {
                await MainActor.run {
                    if !(error is CancellationError || Task.isCancelled) {
                        _recutError = error.localizedDescription
                    }
                }
            }
            await MainActor.run {
                _recutTask = nil
                _recutInProgress = false
                _recutCompletedCount = 0
                _recutTotalCount = 0
                _entityImageRefreshID = UUID()
                _refreshVisualEntityCounts(for: _groups)
            }
        }
    }

    @MainActor
    private func _applyGenerationOutcome(_ outcome: _GenerationOutcome) {
        _generatingKeys.remove(outcome.folderKey)
        _generationTasks.removeValue(forKey: outcome.folderKey)
        guard !outcome.wasCancelled else { return }
        if let quiz = outcome.quiz {
            for gi in _groups.indices {
                for ei in _groups[gi].entries.indices
                where _groups[gi].entries[ei].folderKey == outcome.folderKey {
                    _groups[gi].entries[ei].quiz = quiz
                }
            }
        }
        if let errorMessage = outcome.errorMessage {
            _genErrors[outcome.folderKey] = errorMessage
        }
        Self._loadedGroupsBySourceFamily[sourceFamily] = _groups
    }

    private static func _runGeneration(
        entry: Inf6EshikakuDrillPipeline.DrillEntry,
        sourceFamily: String,
        generateBaseQuiz: Bool,
        generateCodePractice: Bool,
        progress: Inf6EshikakuDrillPipeline.ProgressReporter? = nil
    ) async -> _GenerationOutcome {
        let ledgerID: String
        do {
            ledgerID = try await Inf6EshikakuDrillPipeline.startExecutionLedger(entry: entry)
        } catch {
            return _GenerationOutcome(
                entryID: entry.id,
                folderKey: entry.folderKey,
                quiz: nil,
                errorMessage: [
                    entry.paper.title,
                    "工程: start_execution_ledger",
                    "原因分類: pdfPersistence",
                    "原因: \(error.localizedDescription)"
                ].joined(separator: "\n"),
                wasCancelled: false,
                stopsBatch: false
            )
        }
        do {
            try Task.checkCancellation()
            let askModel: (String) async throws -> String = { prompt in
                try Task.checkCancellation()
                return try await Inf6LibraryView.askOpenAIText(prompt, lang: "ja")
            }

            let quiz = try await Inf6EshikakuDrillPipeline.ensureKCAndQuiz(
                entry: entry,
                askModel: askModel,
                progress: progress,
                generateBaseQuiz: generateBaseQuiz,
                generateCodePractice: generateCodePractice,
                forceCodePracticeRegeneration: generateCodePractice
            )
            try Task.checkCancellation()
            await Inf6EshikakuDrillPipeline.finishExecutionLedger(id: ledgerID, entry: entry, quiz: quiz)
            NSLog("[DrillView] generation finished: %@ (%d questions)",
                  entry.folderKey, quiz?.questions.count ?? 0)
            return _GenerationOutcome(entryID: entry.id, folderKey: entry.folderKey, quiz: quiz, errorMessage: nil, wasCancelled: false, stopsBatch: false)
        } catch let error where Inf6EshikakuDrillPipeline.isCancellation(error) {
            NSLog("[DrillView] generation cancelled: %@", entry.folderKey)
            await Inf6EshikakuDrillPipeline.failExecutionLedger(id: ledgerID, entry: entry, status: "cancelled", error: CancellationError())
            return _GenerationOutcome(entryID: entry.id, folderKey: entry.folderKey, quiz: nil, errorMessage: nil, wasCancelled: true, stopsBatch: false)
        } catch {
            // 画面のエラー欄は一覧の先頭にあり、スクロール位置によっては見えない。
            // 失敗は必ずログにも出す。
            NSLog("[DrillView] generation FAILED: %@ error=%@", entry.folderKey, error.localizedDescription)
            let stopsBatch = Inf6EshikakuDrillPipeline.shouldStopBatchAfterFailure(error)
            await Inf6EshikakuDrillPipeline.failExecutionLedger(
                id: ledgerID,
                entry: entry,
                status: stopsBatch ? "rate_limited" : "failed",
                error: error
            )
            Inf6ErrorIntelligence.recordRuntimeEvent(
                operation: "eshikaku_drill_generate",
                context: "\(sourceFamily)|\(entry.syllabusNodeID ?? "")|\(entry.paper.id)",
                error: error
            )
            let message = Inf6EshikakuDrillPipeline.displayMessage(
                entry: entry,
                error: error
            )
            return _GenerationOutcome(
                entryID: entry.id,
                folderKey: entry.folderKey,
                quiz: nil,
                errorMessage: message,
                wasCancelled: false,
                stopsBatch: stopsBatch
            )
        }
    }
}
