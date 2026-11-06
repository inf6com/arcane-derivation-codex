import SwiftUI
import UIKit
import PencilKit

struct FormulaChatView: View {
    let language: InterfaceLanguage
    let rootPath: String
    let sourceTitle: String?
    let sourceLocator: String?
    let sourceEvidenceID: UUID?
    let sourceImageRelativePath: String?

    @State private var document = DerivationDocument()
    @State private var expression = ""
    @State private var reason = ""
    @State private var mathML: String?
    @State private var errorMessage: String?
    @State private var isSending = false
    @State private var editorSelection = NSRange(location: 0, length: 0)
    @State private var pendingRecognition: PendingRecognition?
    @State private var selectedCandidateIndices: [Int: Int] = [:]
    @State private var selectedPrimaryCandidateRanks: [Int: Int] = [:]
    @State private var editorDrawing = PKDrawing()
    @State private var fingerWritingMode = false
    @State private var drawingStartText = ""
    @State private var drawingStartSelection = NSRange(location: 0, length: 0)
    @State private var recognitionRevision = UUID()
    @State private var recognitionTask: Task<Void, Never>?
    @State private var isRecognizing = false

    private struct PendingRecognition {
        let drawingData: Data
        let result: Inf6HandwrittenMathMLResult
        let sourceText: String
        let sourceSelection: NSRange
    }

    private struct ConfirmedHandwritingEvidence: Codable {
        struct ModelProvenance: Codable {
            let name: String
            let checkpointSHA256: String
            let epoch: Int
        }

        let schema: String
        let segmenter: ModelProvenance
        let classifier: ModelProvenance
        let segmentationThreshold: Float
        let sourceStrokeGroups: [[Int]]
        let modelCandidates: [[Inf6SpatialRelationAnalysis.Candidate]]
        let displayedCandidateLabels: [[String]]
        let selectedLabels: [String]
        let selectedClassIndices: [Int]
        let selectedModelRanks: [Int?]
        let selectedPrimaryLabels: [String]
        let similarityExpansion: Inf6SymbolSimilarityExpansion
        let fold7SimilarityCandidates: [[[HinotoriFold7SimilarityCandidate]]]
        let typesetCandidates: [[HinotoriTypesetCandidate]]
        let positionClassification: Inf6PositionSensitiveClassification
        let spatialAnalysis: Inf6SpatialRelationAnalysis
    }

    private struct SegmenterEvidenceManifest: Decodable {
        let checkpointSHA256: String
        let selectedEpoch: Int
        let validationThreshold: Float
    }

    private struct ClassifierEvidenceManifest: Decodable {
        struct Checkpoint: Decodable { let sha256: String; let epoch: Int }
        let checkpoint: Checkpoint
    }

    init(language: InterfaceLanguage, rootPath: String, sourceTitle: String? = nil, sourceLocator: String? = nil, sourceEvidenceID: UUID? = nil, sourceImageRelativePath: String? = nil) {
        self.language = language
        self.rootPath = rootPath
        self.sourceTitle = sourceTitle
        self.sourceLocator = sourceLocator
        self.sourceEvidenceID = sourceEvidenceID
        self.sourceImageRelativePath = sourceImageRelativePath
    }

    private var isJapanese: Bool { language == .japanese }

    private var sourceImage: UIImage? {
        guard let sourceImageRelativePath else { return nil }
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        let url = root.appendingPathComponent(sourceImageRelativePath).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    sourceAndFormula
                    derivationSteps
                    chat
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .onChange(of: document.chatMessages.count) { _, _ in
                if let id = document.chatMessages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
        .task { load() }
        .onDisappear {
            recognitionRevision = UUID()
            recognitionTask?.cancel()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(isJapanese ? "数式チャット" : "Formula chat")
                .font(.largeTitle.bold())
            Text(isJapanese ? "数式を選び、導出・計算・根拠を一つの流れで確認します。" : "Select a formula and work through its derivation, calculation, and evidence.")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let sourceTitle {
                Text(sourceLocator.map { "\(sourceTitle) / \($0)" } ?? sourceTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let image = sourceImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(isJapanese ? "選択した原典クロップ" : "Selected source crop")
            }
        }
        .padding(.horizontal)
    }

    private var sourceAndFormula: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isJapanese ? "導出対象" : "Derivation target").font(.headline)
            FormulaComposerInput(
                text: $expression,
                selectedRange: $editorSelection,
                drawing: $editorDrawing,
                fingerWritingMode: fingerWritingMode,
                placeholder: isJapanese ? "文章や数式を入力。Apple Pencilで直接書けます。" : "Type text or a formula; write directly with Apple Pencil.",
                onDrawingStarted: beginDrawingCapture
            ) { drawing in
                recognizeDrawing(drawing, sourceText: drawingStartText, sourceSelection: drawingStartSelection)
            }
            .frame(minHeight: 110, maxHeight: 220)
            Button {
                fingerWritingMode.toggle()
            } label: {
                Label(
                    fingerWritingMode ? (isJapanese ? "文字入力に戻る" : "Return to text input") : (isJapanese ? "指で書く" : "Write with finger"),
                    systemImage: fingerWritingMode ? "keyboard" : "hand.draw"
                )
            }
            .accessibilityHint(isJapanese ? "同じ編集欄で指による手書き入力を切り替えます" : "Toggles finger handwriting in the same editor")
            HStack {
                Button(isJapanese ? "正式組版" : "Typeset") { typeset() }
                    .buttonStyle(.borderedProminent)
                    .disabled(expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(isJapanese ? "AIに質問" : "Ask AI") { sendQuestion() }
                    .buttonStyle(.bordered)
                    .disabled(isSending || expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let mathML {
                MathMLView(source: mathML)
                    .frame(minHeight: 80)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            if isRecognizing {
                ProgressView(isJapanese ? "火の鳥が記号候補を解析中" : "Hinotori is analyzing symbol candidates")
                    .accessibilityIdentifier("hinotori.recognition.progress")
            }
            if let pendingRecognition {
                candidateConfirmation(pendingRecognition)
            }
        }
        .padding(.horizontal)
    }

    private func candidateConfirmation(_ pending: PendingRecognition) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isJapanese ? "記号候補を選択して確定" : "Choose and confirm each symbol")
                .font(.headline)
            ForEach(Array(pending.result.candidateLabels.enumerated()), id: \.offset) { groupIndex, labels in
                let modelLabels = pending.result.spatialAnalysis?.symbols
                    .first(where: { $0.id == "symbol-\(groupIndex)" })?.candidates.map(\.label) ?? []
                let typesetCandidates = pending.result.typesetCandidates.indices.contains(groupIndex)
                    ? pending.result.typesetCandidates[groupIndex]
                    : []
                let typesetLabels = Set(typesetCandidates.map(\.label))
                let primaryLabels = Array(modelLabels.prefix(5))
                let selectedRank = selectedPrimaryCandidateRanks[groupIndex]
                let fold7Suggestions = selectedRank.flatMap { rank -> [HinotoriFold7SimilarityCandidate]? in
                    guard pending.result.fold7SimilarityCandidates.indices.contains(groupIndex),
                          pending.result.fold7SimilarityCandidates[groupIndex].indices.contains(rank) else { return nil }
                    return pending.result.fold7SimilarityCandidates[groupIndex][rank]
                } ?? []
                var visibleLabels = primaryLabels
                if selectedRank != nil {
                    for candidate in fold7Suggestions where !visibleLabels.contains(candidate.label) {
                        visibleLabels.append(candidate.label)
                    }
                    for label in labels where typesetLabels.contains(label) {
                        if !visibleLabels.contains(label) { visibleLabels.append(label) }
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(isJapanese ? "記号 \(groupIndex + 1)" : "Symbol \(groupIndex + 1)")
                        .font(.caption.weight(.semibold))
                    if selectedRank != nil && fold7Suggestions.isEmpty {
                        Text(isJapanese ? "この上位候補に該当する87類似群はありません" : "No 87-group match for this Fold7 candidate")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if selectedRank != nil {
                        Text(isJapanese ? "Fold7上位候補の選択後に87類似群・活字候補を表示" : "87-group and typeset alternatives follow the Fold7 selection")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(Array(visibleLabels.enumerated()), id: \.offset) { _, label in
                                let choiceIndex = labels.firstIndex(of: label) ?? -1
                                let fold7Candidate = fold7Suggestions.first(where: { $0.label == label })
                                let isFold7Similar = fold7Candidate != nil
                                let isSimilar = isFold7Similar
                                let modelRank = modelLabels.firstIndex(of: label).map { $0 + 1 }
                                let typesetRank = typesetCandidates.first(where: { $0.label == label })?.rank
                                Button {
                                    guard choiceIndex >= 0 else { return }
                                    if let modelRank, modelRank <= 5 {
                                        selectedPrimaryCandidateRanks[groupIndex] = modelRank - 1
                                        selectedCandidateIndices[groupIndex] = choiceIndex
                                    } else if selectedPrimaryCandidateRanks[groupIndex] != nil {
                                        selectedCandidateIndices[groupIndex] = choiceIndex
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        if let modelRank {
                                            Text("TOP\(modelRank)")
                                                .font(.caption2.bold())
                                                .foregroundStyle(Color.cyan)
                                        }
                                        if let fold7Candidate {
                                            Text("87群 · \(String(format: "%.3f", fold7Candidate.cosineSimilarity))")
                                                .font(.caption2.bold())
                                                .foregroundStyle(Color.purple)
                                        } else if isSimilar {
                                            Text(isJapanese ? "類似" : "SIM")
                                                .font(.caption2.bold())
                                                .foregroundStyle(Color.purple)
                                        }
                                        if let typesetRank {
                                            Text(isJapanese ? "活字TOP\(typesetRank)" : "TYPE\(typesetRank)")
                                                .font(.caption2.bold())
                                                .foregroundStyle(Color.green)
                                        }
                                        Text(label).font(.title3.weight(.semibold))
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .foregroundStyle(selectedCandidateIndices[groupIndex] == choiceIndex ? Color.white : Color.primary)
                                    .background(selectedCandidateIndices[groupIndex] == choiceIndex ? Color.accentColor : Color.clear, in: Capsule())
                                    .overlay(Capsule().stroke(typesetRank != nil && modelRank == nil && !isSimilar ? Color.green : (isSimilar && modelRank == nil ? Color.purple : Color.cyan), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(candidateAccessibilityLabel(label: label, modelRank: modelRank, isSimilar: isSimilar, typesetRank: typesetRank))
                            }
                        }
                    }
                }
            }
            Button(isJapanese ? "選択した記号を編集欄へ確定" : "Confirm selected symbols in the editor") {
                confirmRecognition(pending)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedCandidateIndices.count != pending.result.candidateLabels.count || selectedPrimaryCandidateRanks.count != pending.result.candidateLabels.count)
            Button(isJapanese ? "この認識候補を破棄" : "Discard these recognition candidates", role: .cancel) {
                recognitionRevision = UUID()
                recognitionTask?.cancel()
                pendingRecognition = nil
                selectedCandidateIndices = [:]
                selectedPrimaryCandidateRanks = [:]
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func candidateAccessibilityLabel(label: String, modelRank: Int?, isSimilar: Bool, typesetRank: Int?) -> String {
        var sources: [String] = []
        if let modelRank { sources.append(isJapanese ? "手書きTOP\(modelRank)" : "Handwriting Top \(modelRank)") }
        if isSimilar { sources.append(isJapanese ? "類似記号" : "Visual similarity") }
        if let typesetRank { sources.append(isJapanese ? "活字TOP\(typesetRank)" : "Typeset Top \(typesetRank)") }
        return isJapanese ? "\(sources.joined(separator: "、"))候補 \(label)" : "\(sources.joined(separator: ", ")) candidate \(label)"
    }

    private func confirmRecognition(_ pending: PendingRecognition) {
        guard expression == pending.sourceText,
              editorSelection.location == pending.sourceSelection.location,
              editorSelection.length == pending.sourceSelection.length else {
            errorMessage = isJapanese
                ? "認識中に編集欄が変わりました。ストロークをもう一度書いて候補を更新してください。"
                : "The editor changed during recognition. Write the strokes again to refresh candidates."
            return
        }
        let selected = pending.result.candidateLabels.enumerated().compactMap { groupIndex, labels -> String? in
            guard let choiceIndex = selectedCandidateIndices[groupIndex], labels.indices.contains(choiceIndex) else { return nil }
            return labels[choiceIndex]
        }
        guard selected.count == pending.result.candidateLabels.count else { return }
        do {
            let vocabulary = try HinotoriVocabulary.load(bundle: .main)
            let selectedClassIndices = try selected.map { label -> Int in
                guard let index = vocabulary.labels.firstIndex(of: label) else {
                    throw Inf6HandwrittenFormulaError.recognitionFailed("確定候補が火の鳥語彙にありません: \(label)")
                }
                return index
            }
            guard let spatial = pending.result.spatialAnalysis,
                  let similarity = pending.result.similarityExpansion,
                  let position = pending.result.positionSensitiveClassification,
                  let segmenterURL = Bundle.main.url(forResource: "HinotoriFormulaSegmenter.manifest", withExtension: "json"),
                  let classifierURL = Bundle.main.url(forResource: "HinotoriFold7CoreML.manifest", withExtension: "json") else {
                throw Inf6HandwrittenFormulaError.recognitionFailed("確定候補のモデルmanifestまたは類似・位置判定根拠がありません")
            }
            let segmenter = try JSONDecoder().decode(SegmenterEvidenceManifest.self, from: Data(contentsOf: segmenterURL))
            let classifier = try JSONDecoder().decode(ClassifierEvidenceManifest.self, from: Data(contentsOf: classifierURL))
            guard segmenter.checkpointSHA256 == HinotoriFormulaFold7Engine.checkpointSHA256,
                  segmenter.selectedEpoch == HinotoriFormulaFold7Engine.selectedEpoch,
                  segmenter.validationThreshold == HinotoriFormulaFold7Engine.validationThreshold,
                  classifier.checkpoint.sha256 == HinotoriFold7CoreMLClassifier.checkpointSHA256,
                  classifier.checkpoint.epoch == HinotoriFold7CoreMLClassifier.selectedEpoch,
                  spatial.symbols.count == selected.count,
                  pending.result.symbolStrokeIndices.count == selected.count,
                  pending.result.typesetCandidates.count == selected.count,
                  pending.result.typesetCandidates.allSatisfy({ candidates in
                      candidates.count == 5 && candidates.allSatisfy {
                          $0.headCheckpointSHA256 == HinotoriTypesetAuxiliaryCoreMLClassifier.headCheckpointSHA256
                              && $0.rank > 0 && $0.score.isFinite
                      }
                  }),
                  similarity.symbols.count == selected.count,
                  position.symbols.count == selected.count else {
                throw Inf6HandwrittenFormulaError.recognitionFailed("保存対象のモデル版・閾値・記号群数が認識結果と一致しません")
            }
            let selectedPrimaryLabels = try pending.result.candidateLabels.indices.map { groupIndex -> String in
                guard let rank = selectedPrimaryCandidateRanks[groupIndex],
                      spatial.symbols.indices.contains(groupIndex),
                      spatial.symbols[groupIndex].candidates.indices.contains(rank) else {
                    throw Inf6HandwrittenFormulaError.recognitionFailed("Fold7 Top-5の選択記録が記号候補群と一致しません")
                }
                return spatial.symbols[groupIndex].candidates[rank].label
            }
            let evidence = ConfirmedHandwritingEvidence(
                schema: "firebird-chat-handwriting-confirmation-v3",
                segmenter: .init(name: "HinotoriFormulaSegmenter", checkpointSHA256: segmenter.checkpointSHA256, epoch: segmenter.selectedEpoch),
                classifier: .init(name: "HinotoriFold7Classifier", checkpointSHA256: classifier.checkpoint.sha256, epoch: classifier.checkpoint.epoch),
                segmentationThreshold: segmenter.validationThreshold,
                sourceStrokeGroups: pending.result.symbolStrokeIndices,
                modelCandidates: spatial.symbols.map(\.candidates),
                displayedCandidateLabels: pending.result.candidateLabels,
                typesetCandidates: pending.result.typesetCandidates,
                selectedLabels: selected,
                selectedClassIndices: selectedClassIndices,
                selectedPrimaryLabels: selectedPrimaryLabels,
                selectedModelRanks: zip(selected, spatial.symbols).map { label, symbol in
                    symbol.candidates.firstIndex(where: { $0.label == label }).map { $0 + 1 }
                },
                similarityExpansion: similarity,
                fold7SimilarityCandidates: pending.result.fold7SimilarityCandidates,
                positionClassification: position,
                spatialAnalysis: spatial
            )
            try commitRecognition(
                pending,
                selected: selected,
                selectedClassIndices: selectedClassIndices,
                evidenceData: JSONEncoder().encode(evidence)
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func commitRecognition(
        _ pending: PendingRecognition,
        selected: [String],
        selectedClassIndices: [Int],
        evidenceData: Data
    ) throws {
        let insertion = selected.joined(separator: " ")
        let safeLocation = min(max(0, editorSelection.location), (expression as NSString).length)
        let safeLength = min(max(0, editorSelection.length), (expression as NSString).length - safeLocation)
        let replacementRange = NSRange(location: safeLocation, length: safeLength)
        let updatedExpression = (expression as NSString).replacingCharacters(in: replacementRange, with: insertion)
        let insertedLength = (insertion as NSString).length
        let previousDocument = document
        let previousExpression = expression
        let previousSelection = editorSelection
        let previousMathML = mathML
        do {
            let verifiedMathML = try LaTeXMathMLConverter().convert(updatedExpression)
            expression = updatedExpression
            editorSelection = NSRange(location: safeLocation + insertedLength, length: 0)
            mathML = verifiedMathML
            document.pencilDrawingData = pending.drawingData
            document.recognizedExpression = insertion
            document.recognizedTokenIDs = selectedClassIndices
            document.recognizedSymbols = selected
            document.recognizedGridCellIndices = pending.result.symbolGridCellIndices
            document.recognizedSymbolStrokeIndices = pending.result.symbolStrokeIndices
            document.spatialAnalysis = pending.result.spatialAnalysis
            document.positionSensitiveClassification = pending.result.positionSensitiveClassification
            document.similarityExpansion = pending.result.similarityExpansion
            document.handwritingEvidence = evidenceData
            document.grid9 = pending.result.grid9
            document.inputMethod = .handwriting
            document.mathML = verifiedMathML
            document.mathMLVerified = true
            document.updatedAt = .now
            try persist()
            editorDrawing = PKDrawing()
            pendingRecognition = nil
            selectedCandidateIndices = [:]
            selectedPrimaryCandidateRanks = [:]
        } catch {
            document = previousDocument
            expression = previousExpression
            editorSelection = previousSelection
            mathML = previousMathML
            throw error
        }
    }

    private func beginDrawingCapture() {
        guard editorDrawing.strokes.isEmpty else { return }
        drawingStartText = expression
        drawingStartSelection = editorSelection
    }

    private func recognizeDrawing(_ drawing: PKDrawing, sourceText: String, sourceSelection: NSRange) {
        recognitionRevision = UUID()
        let revision = recognitionRevision
        recognitionTask?.cancel()
        pendingRecognition = nil
        selectedCandidateIndices = [:]
        selectedPrimaryCandidateRanks = [:]
        errorMessage = nil
        guard !drawing.strokes.isEmpty else { isRecognizing = false; return }
        editorDrawing = drawing
        isRecognizing = true
        let drawingData = drawing.dataRepresentation()
        recognitionTask = Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let restoredDrawing = try PKDrawing(data: drawingData)
                    return try TexTellerFormulaRecognition.recognize(
                        drawing: restoredDrawing,
                        bundle: .main,
                        cancellationCheck: { Task.isCancelled }
                    )
                }.value
                guard !Task.isCancelled, revision == recognitionRevision else { return }
                guard result.candidateLabels.count == result.symbolStrokeIndices.count,
                      result.candidateLabels.allSatisfy({ !$0.isEmpty }),
                      result.typesetCandidates.count == result.candidateLabels.count,
                      result.typesetCandidates.allSatisfy({ candidates in
                          candidates.count == 5 && candidates.allSatisfy {
                              $0.headCheckpointSHA256 == HinotoriTypesetAuxiliaryCoreMLClassifier.headCheckpointSHA256
                                  && $0.rank > 0 && $0.score.isFinite
                          }
                      }) else {
                    throw Inf6HandwrittenFormulaError.recognitionFailed("分割群と記号候補の対応が不正です")
                }
                pendingRecognition = PendingRecognition(
                    drawingData: drawingData,
                    result: result,
                    sourceText: sourceText,
                    sourceSelection: sourceSelection
                )
                isRecognizing = false
            } catch {
                guard revision == recognitionRevision else { return }
                isRecognizing = false
                let wasCancelled = (error as? Inf6HandwrittenFormulaError).map {
                    if case .cancelled = $0 { return true }
                    return false
                } ?? false
                if !(error is CancellationError), !wasCancelled {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private var derivationSteps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isJapanese ? "導出" : "Derivation").font(.headline)
            TextField(isJapanese ? "この変形を行う理由" : "Why this transformation is valid", text: $reason, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            Button(isJapanese ? "導出段階を保存" : "Save derivation step") { saveStep() }
                .buttonStyle(.borderedProminent)
                .disabled(expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ForEach(document.steps) { step in
                VStack(alignment: .leading, spacing: 4) {
                    Text(step.expression).font(.body.monospaced()).textSelection(.enabled)
                    Text(step.reason).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.horizontal)
    }

    private var chat: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(document.chatMessages) { message in
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.role == .user ? (isJapanese ? "あなた" : "You") : "AI")
                        .font(.caption.bold())
                        .foregroundStyle(message.role == .user ? Color.blue : Color.purple)
                    Text(message.text).textSelection(.enabled)
                }
                .id(message.id)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(message.role == .user ? Color.blue.opacity(0.08) : Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.horizontal)
    }

    private func load() {
        do {
            let identifier = sourceEvidenceID?.uuidString ?? "formula"
            let loadedDocument = try DerivationStore(root: URL(fileURLWithPath: rootPath), identifier: identifier).load()
            document = loadedDocument
            if document.sourceEvidenceID == nil, let sourceEvidenceID {
                document.sourceEvidenceID = sourceEvidenceID
                document.sourceTitle = sourceTitle
                document.sourceLocator = sourceLocator
                do {
                    try persist()
                } catch {
                    document = loadedDocument
                    throw error
                }
            }
        }
        catch { errorMessage = error.localizedDescription }
    }

    private func persist() throws {
        var persistedDocument = document
        let identifier = persistedDocument.sourceEvidenceID?.uuidString ?? sourceEvidenceID?.uuidString ?? "formula"
        let store = DerivationStore(root: URL(fileURLWithPath: rootPath), identifier: identifier)
        if let evidenceID = persistedDocument.sourceEvidenceID ?? sourceEvidenceID,
           let title = persistedDocument.sourceTitle ?? sourceTitle {
            persistedDocument.sourceEvidenceID = evidenceID
            persistedDocument.sourceTitle = title
            persistedDocument.sourceLocator = persistedDocument.sourceLocator ?? sourceLocator
            persistedDocument.paperSupplement = PaperSupplement(
                id: evidenceID,
                sourceEvidenceID: evidenceID,
                sourceTitle: title,
                sourceLocator: persistedDocument.sourceLocator,
                mathML: persistedDocument.mathML,
                derivationSteps: persistedDocument.steps,
                dialogue: persistedDocument.chatMessages,
                updatedAt: persistedDocument.updatedAt
            )
        } else {
            persistedDocument.paperSupplement = nil
        }
        try store.save(persistedDocument)
        document = persistedDocument
    }

    private func typeset() {
        let previousDocument = document
        let previousMathML = mathML
        do {
            let verifiedMathML = try LaTeXMathMLConverter().convert(expression)
            document.mathML = verifiedMathML
            document.mathMLVerified = true
            document.updatedAt = .now
            try persist()
            mathML = verifiedMathML
            errorMessage = nil
        } catch {
            document = previousDocument
            mathML = previousMathML
            errorMessage = error.localizedDescription
        }
    }

    private func saveStep() {
        let previousDocument = document
        let previousReason = reason
        document.steps.append(DerivationStep(expression: expression, reason: reason))
        document.updatedAt = .now
        reason = ""
        do { try persist() }
        catch { document = previousDocument; reason = previousReason; errorMessage = error.localizedDescription }
    }

    private func sendQuestion() {
        let composerText = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !composerText.isEmpty, !isSending else { return }
        let source = sourceTitle.map { "出典: \($0)\(sourceLocator.map { " / \($0)" } ?? "")\n" } ?? ""
        let prompt = "\(source)\(composerText)"
        let sourceStepID = document.steps.last?.id
        let userMessage = FormulaChatMessage(role: .user, text: composerText, sourceStepID: sourceStepID)
        document.chatMessages.append(userMessage)
        do {
            try persist()
            expression = ""
            editorSelection = NSRange(location: 0, length: 0)
        } catch {
            document.chatMessages.removeAll { $0.id == userMessage.id }
            errorMessage = error.localizedDescription
            return
        }
        isSending = true
        Task {
            do {
                let workspace = try WorkspaceStore(root: URL(fileURLWithPath: rootPath))
                guard let configuration = try AIProviderConfigurationStore(root: workspace).load() else {
                    throw AIProviderError.unavailable
                }
                let key = configuration.provider.needsAPIKey ? APIKeychain.load(for: configuration.provider) : nil
                let response = try await AIProviderClient(configuration: configuration, apiKey: key).generate(prompt: prompt)
                let responseMessage = FormulaChatMessage(role: .assistant, text: response, sourceStepID: sourceStepID)
                let previousUpdatedAt = document.updatedAt
                document.chatMessages.append(responseMessage)
                document.updatedAt = .now
                do {
                    try persist()
                } catch {
                    document.chatMessages.removeAll { $0.id == responseMessage.id }
                    document.updatedAt = previousUpdatedAt
                    throw error
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isSending = false
        }
    }

}

/// A single text editor that accepts keyboard text and Pencil strokes in the
/// same bounds. Pencil input is captured as handwriting; finger input remains
/// available for caret placement, selection, and scrolling.
private struct FormulaComposerInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    @Binding var drawing: PKDrawing
    var fingerWritingMode: Bool
    var placeholder: String
    let onDrawingStarted: () -> Void
    let onDrawingChanged: (PKDrawing) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> FormulaComposerContainerView {
        let view = FormulaComposerContainerView()
        view.textView.delegate = context.coordinator
        view.canvasView.delegate = context.coordinator
        view.textView.accessibilityLabel = "数式・文章編集欄"
        view.canvasView.accessibilityLabel = "編集欄への手書き数式入力"
        view.textView.font = UIFont.preferredFont(forTextStyle: .body)
        view.textView.adjustsFontForContentSizeCategory = true
        view.textView.backgroundColor = .secondarySystemBackground
        view.textView.textColor = .label
        view.textView.isScrollEnabled = true
        view.textView.alwaysBounceVertical = false
        view.textView.textContainerInset = UIEdgeInsets(top: 12, left: 9, bottom: 12, right: 9)
        view.textView.layer.cornerRadius = 10
        view.textView.layer.borderWidth = 1
        view.textView.layer.borderColor = UIColor.separator.cgColor
        view.canvasView.backgroundColor = .clear
        view.canvasView.isOpaque = false
        view.canvasView.isScrollEnabled = false
        view.canvasView.drawingPolicy = fingerWritingMode ? .anyInput : .pencilOnly
        view.canvasView.acceptsFingerInput = fingerWritingMode
        view.canvasView.tool = PKInkingTool(.pen, color: .systemCyan, width: 2.5)
        view.canvasView.drawing = drawing
        view.textView.text = text
        view.placeholderLabel.text = placeholder
        view.placeholderLabel.isHidden = !text.isEmpty
        view.textView.selectedRange = selectedRange
        return view
    }

    func updateUIView(_ view: FormulaComposerContainerView, context: Context) {
        context.coordinator.parent = self
        view.canvasView.drawingPolicy = fingerWritingMode ? .anyInput : .pencilOnly
        view.canvasView.acceptsFingerInput = fingerWritingMode
        view.placeholderLabel.text = placeholder
        view.placeholderLabel.isHidden = !text.isEmpty
        if view.textView.text != text {
            view.textView.text = text
            view.textView.selectedRange = clamped(selectedRange, to: (text as NSString).length)
        } else if view.textView.selectedRange != clamped(selectedRange, to: (text as NSString).length) {
            view.textView.selectedRange = clamped(selectedRange, to: (text as NSString).length)
        }
        if view.canvasView.drawing.dataRepresentation() != drawing.dataRepresentation() {
            context.coordinator.debounceWorkItem?.cancel()
            view.canvasView.drawing = drawing
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: FormulaComposerContainerView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: min(max(proposal.height ?? 150, 110), 220))
    }

    private func clamped(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }

    final class Coordinator: NSObject, UITextViewDelegate, PKCanvasViewDelegate {
        var parent: FormulaComposerInput
        var debounceWorkItem: DispatchWorkItem?

        init(_ parent: FormulaComposerInput) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.selectedRange = textView.selectedRange
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.selectedRange = textView.selectedRange
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            debounceWorkItem?.cancel()
            guard !canvasView.drawing.strokes.isEmpty else { return }
            let drawing = canvasView.drawing
            let parent = parent
            let work = DispatchWorkItem { parent.onDrawingChanged(drawing) }
            debounceWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(650), execute: work)
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            parent.onDrawingStarted()
        }
    }
}

private final class FormulaComposerContainerView: UIView {
    let textView = UITextView()
    let canvasView = PencilOnlyFormulaCanvasView()
    let placeholderLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(textView)
        addSubview(placeholderLabel)
        addSubview(canvasView)
        backgroundColor = .clear
        configurePlaceholder()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addSubview(textView)
        addSubview(placeholderLabel)
        addSubview(canvasView)
        backgroundColor = .clear
        configurePlaceholder()
    }

    private func configurePlaceholder() {
        placeholderLabel.font = UIFont.preferredFont(forTextStyle: .body)
        placeholderLabel.textColor = .secondaryLabel
        placeholderLabel.numberOfLines = 0
        placeholderLabel.isUserInteractionEnabled = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = bounds
        placeholderLabel.frame = CGRect(x: 18, y: 19, width: max(0, bounds.width - 36), height: 24)
        canvasView.frame = bounds
    }
}

private final class PencilOnlyFormulaCanvasView: PKCanvasView {
    var acceptsFingerInput = false

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let touches = event?.allTouches ?? []
        let isPencilInput = touches.contains { $0.type == .pencil }
        let isFingerInput = acceptsFingerInput && touches.contains { $0.type == .direct }
        guard isPencilInput || isFingerInput else { return nil }
        return super.hitTest(point, with: event)
    }
}
