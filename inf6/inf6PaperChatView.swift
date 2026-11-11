//
//  Inf6PaperChatView.swift
//  inf6
//
//  Paper survey chat (arXiv/PubMed abstract-only).
//

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - UI-localization helper
// NOTE: UI専用。ViewModel 側は別の軽量ヘルパを持つ（ViewModelがUIファイルに依存しないため）。
private func _inf6LangText(_ ja: String, _ en: String) -> String {
    let code = Locale.current.language.languageCode?.identifier ?? ""
    if code.lowercased().hasPrefix("ja") { return ja }
    return en
}

private var _inf6PaperChatScreenBackground: Color {
    #if canImport(UIKit)
    return Color(UIColor.systemBackground)
    #else
    return Color.white
    #endif
}

/// A lightweight chip button style that works even when `.bordered` / `.borderedProminent` are unavailable.
struct Inf6ChipButtonStyle: ButtonStyle {
    let prominent: Bool
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(_foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(_background(configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(_stroke, lineWidth: prominent ? 0 : 1)
            )
            .opacity(configuration.isPressed ? 0.75 : 1.0)
    }

    private var _foreground: Color {
        prominent ? Color.white : tint
    }

    private func _background(_ pressed: Bool) -> Color {
        if prominent {
            return tint.opacity(pressed ? 0.75 : 0.95)
        }
        return tint.opacity(pressed ? 0.10 : 0.14)
    }

    private var _stroke: Color {
        prominent ? Color.clear : tint.opacity(0.30)
    }
}

// MARK: - View

struct Inf6PaperChatView: View {

    @StateObject private var vm: Inf6PaperChatViewModel

    @MainActor
    init() {
        _vm = StateObject(wrappedValue: Inf6PaperChatViewModel())
    }

    @MainActor
    init(vm: Inf6PaperChatViewModel) {
        _vm = StateObject(wrappedValue: vm)
    }

    private var resultsSourceLabelInView: String {
        let latest = vm.latestResultsSourceLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !latest.isEmpty {
            return latest
        }
        switch vm.selectedSource.rawValue {
        case "pubmed":
            return "PubMed"
        case "acl":
            return "ACL"
        case "isca":
            return "ISCA"
        case "auto":
            return _inf6LangText("自動", "Auto")
        default:
            return "arXiv"
        }
    }

    private var stageIndex: Int {
        stageOrder.firstIndex(of: vm.stage.rawValue) ?? 0
    }

    private var stageOrder: [String] {
        if vm.workflowStageRawOrder.isEmpty {
            return [
                "choosePersona",
                "askGoal",
                "chooseTimeBudget",
                "chooseContext",
                "chooseTrack",
                "chooseOrientation",
                "askKeywords",
                "askConstraints",
                "chooseSource",
                "confirmQuery",
                "readyToSearch"
            ]
        }
        return vm.workflowStageRawOrder
    }

    private var stagePromptText: String {
        switch vm.stage.rawValue {
        case "choosePersona":
            return _inf6LangText("あなたの立場を選択", "Choose your role")
        case "askGoal":
            return _inf6LangText("今回の目的を選択", "Choose your goal")
        case "chooseTimeBudget":
            return _inf6LangText("利用時間を選択", "Choose time budget")
        case "chooseContext":
            return _inf6LangText("利用シーンを選択", "Choose your context")
        case "askKeywords":
            if vm.goalID == "goal.understand_paper" {
                return _inf6LangText("対象論文のID/URL/タイトルを入力", "Enter target paper ID/URL/title")
            }
            return _inf6LangText("キーワードを選択", "Choose keywords")
        case "askConstraints":
            return _inf6LangText("優先条件を選択", "Choose constraints")
        case "chooseTrack":
            return _inf6LangText("分野を選択", "Choose track")
        case "chooseOrientation":
            return _inf6LangText("読み方の軸を選択", "Choose reading orientation")
        case "chooseSource":
            return _inf6LangText("検索ソースを選択", "Choose source")
        case "confirmQuery":
            return _inf6LangText("検索式を確定", "Confirm query")
        case "readyToSearch":
            return _inf6LangText("検索", "Search")
        default:
            return _inf6LangText("選択", "Select")
        }
    }

    private var stageAccentColor: Color {
        switch vm.stage.rawValue {
        case "choosePersona": return .teal
        case "askGoal": return .blue
        case "chooseTimeBudget": return .green
        case "chooseContext": return .green
        case "askKeywords": return .indigo
        case "askConstraints": return .mint
        case "chooseTrack": return .cyan
        case "chooseOrientation": return .gray
        case "chooseSource": return .gray
        case "confirmQuery": return .blue
        case "readyToSearch": return .red
        default: return .accentColor
        }
    }

    private var manualWaitingTitleText: String {
        if vm.stage.rawValue == "askKeywords", vm.goalID == "goal.understand_paper" {
            return _inf6LangText("対象論文の入力待ち", "Waiting for target paper input")
        }
        return _inf6LangText("入力待ち", "Waiting for input")
    }

    private var manualWaitingDescriptionText: String {
        switch vm.stage.rawValue {
        case "askKeywords":
            if vm.goalID == "goal.understand_paper" {
                return _inf6LangText(
                    "下の入力欄に arXiv ID / URL / 論文タイトルを入力し、「検索」を押してください。",
                    "Enter arXiv ID / URL / paper title in the input field below, then tap Search."
                )
            }
            return _inf6LangText(
                "下の入力欄にキーワードを入力し、「検索」を押してください。",
                "Enter a keyword in the input field below, then tap Search."
            )
        case "askConstraints":
            return _inf6LangText(
                "下の入力欄に優先条件を入力し、「検索」を押してください。",
                "Enter your priority constraint in the input field below, then tap Search."
            )
        case "readyToSearch":
            return _inf6LangText(
                "検索式を手修正する場合のみ、下の入力欄に入力してください。実行は上の「検索を開始」です。",
                "Only edit the query below when needed. Run from the upper \"Start search\" action."
            )
        default:
            return _inf6LangText(
                "下の入力欄に入力して「検索」を押してください。",
                "Enter text in the input field below, then tap Search."
            )
        }
    }

    private var manualSubmitButtonText: String {
        if vm.stage.rawValue == "readyToSearch" {
            return _inf6LangText("検索を開始", "Start search")
        }
        return _inf6LangText("検索", "Search")
    }

    private var quickReplyColumns: [GridItem] {
        switch vm.stage.rawValue {
        case "choosePersona", "confirmQuery", "readyToSearch":
            return [GridItem(.flexible(), spacing: 8)]
        default:
            return [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ]
        }
    }

    @ToolbarContentBuilder
    private var paperChatToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { vm.goBack() } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(!vm.canGoBack)
            .help(_inf6LangText("1ステップ前に戻ります", "Go back one step"))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if vm.isBusy {
                VStack(spacing: 12) {
                    ProgressView().tint(.pink).scaleEffect(1.25)
                    Text(_inf6LangText("検索中…", "Searching…"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 24)

            } else if let e = vm.lastError, !e.isEmpty {
                ScrollView {
                    Text(e)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 12)
                }

            } else if !vm.latestResults.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let classificationError = vm.latestResultClassificationError,
                           !classificationError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(classificationError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Inf6PaperChatResultsList(
                            results: vm.latestResults,
                            sourceLabel: resultsSourceLabelInView,
                            clusterLabelByID: vm.latestResultClusterLabelByID,
                            clusterRankByID: vm.latestResultClusterRankByID,
                            featureKeywordsByID: vm.latestResultFeatureKeywordsByID
                        )
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 10)
                }

            } else {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(stagePromptText)
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)

                        HStack(spacing: 5) {
                            ForEach(stageOrder.indices, id: \.self) { idx in
                                Capsule(style: .continuous)
                                    .fill(idx <= stageIndex ? stageAccentColor : Color.secondary.opacity(0.18))
                                    .frame(height: 4)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Group {
                        if vm.quickReplies.isEmpty && vm.allowsManualInput {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(manualWaitingTitleText)
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(stageAccentColor)

                                Text(manualWaitingDescriptionText)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(stageAccentColor.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(stageAccentColor.opacity(0.24), lineWidth: 1)
                            )
                            .padding(.horizontal, 12)
                        } else {
                            ScrollView(.vertical, showsIndicators: false) {
                                LazyVGrid(columns: quickReplyColumns, spacing: 8) {
                                ForEach(vm.quickReplies) { t in
                                    Button { vm.selectQuickReply(t) } label: {
                                        Text(t.label)
                                            .font(.callout)
                                            .multilineTextAlignment(.center)
                                                .lineLimit(3)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .frame(maxWidth: .infinity, minHeight: 46)
                                        }
                                        .buttonStyle(
                                            Inf6ChipButtonStyle(
                                                prominent: vm.isDefaultTrackChipID(t.id),
                                                tint: vm.quickReplyTint(t)
                                            )
                                        )
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(stageAccentColor.opacity(0.05))
                    )
                    .padding(.horizontal, 12)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

            if vm.allowsManualInput {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text(_inf6LangText("入力欄", "Input"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(stageAccentColor)

                    HStack(spacing: 8) {
                        TextField(vm.manualInputPlaceholderText, text: $vm.inputText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                vm.send()
                            }

                        Button {
                            vm.send()
                        } label: {
                            Text(manualSubmitButtonText)
                                .font(.callout.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isBusy)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(_inf6PaperChatScreenBackground)
            }
        }
        .background(_inf6PaperChatScreenBackground)
        .navigationTitle(_inf6LangText("論文チャット", "Paper Chat"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { paperChatToolbarContent }
    }
}

// MARK: - Bubbles

struct Inf6PaperChatBubble: View {
    let message: Inf6PaperChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }

            VStack(alignment: .leading, spacing: 4) {
                Text(roleLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(message.text)
                    .font(.body)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if message.role != .user { Spacer(minLength: 40) }
        }
    }

    private var roleLabel: String {
        switch message.role {
        case .user: return _inf6LangText("あなた", "You")
        case .assistant: return "inf6"
        case .system: return _inf6LangText("システム", "system")
        }
    }

    private var background: Color {
        switch message.role {
        case .user: return Color.accentColor.opacity(0.18)
        case .assistant: return Color.secondary.opacity(0.10)
        case .system: return Color.gray.opacity(0.10)
        }
    }
}

// MARK: - Results list

struct Inf6PaperChatResultsList: View {
    let results: [Inf6PaperSearchResult]
    let sourceLabel: String
    let clusterLabelByID: [String: String]
    let clusterRankByID: [String: Int]
    let featureKeywordsByID: [String: [String]]

    private var sortedResults: [Inf6PaperSearchResult] {
        if clusterRankByID.isEmpty { return results }
        return results.sorted { lhs, rhs in
            let lr = clusterRankByID[lhs.id] ?? Int.max
            let rr = clusterRankByID[rhs.id] ?? Int.max
            if lr != rr { return lr < rr }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private var groupedResults: [(label: String, items: [Inf6PaperSearchResult])] {
        let uncategorized = _inf6LangText("未分類", "Uncategorized")
        var order: [String] = []
        var buckets: [String: [Inf6PaperSearchResult]] = [:]

        for result in sortedResults {
            let label = clusterLabelByID[result.id] ?? uncategorized
            if buckets[label] == nil {
                order.append(label)
                buckets[label] = []
            }
            buckets[label, default: []].append(result)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(_inf6LangText("候補一覧（\(sourceLabel)）", "Candidates (\(sourceLabel))"))
                .font(.headline)

            ForEach(groupedResults, id: \.label) { group in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text(group.label)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.purple)
                            .textSelection(.enabled)

                        Spacer()

                        Text(
                            _inf6LangText(
                                "\(group.items.count)件",
                                "\(group.items.count) items"
                            )
                        )
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.blue)
                    }

                    Divider()

                    ForEach(group.items) { r in
                        let abstractPreview = {
                            let abstract = r.abstractText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !abstract.isEmpty { return abstract }
                            return r.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        }()
                        let featureKeywords = featureKeywordsByID[r.id] ?? []

                        VStack(alignment: .leading, spacing: 6) {
                            Text(r.title)
                                .font(.title3.weight(.semibold))
                                .textSelection(.enabled)

                            if !featureKeywords.isEmpty {
                                HStack(alignment: .center, spacing: 6) {
                                    ForEach(featureKeywords, id: \.self) { keyword in
                                        Text(keyword)
                                            .font(.callout.weight(.semibold))
                                            .foregroundStyle(.green)
                                            .lineLimit(1)
                                            .textSelection(.enabled)
                                    }
                                }
                            }

                            if !abstractPreview.isEmpty {
                                Text(abstractPreview)
                                    .font(.callout)
                                    .foregroundStyle(.blue)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                            }

                            if let pdf = r.pdfURL {
                                HStack(spacing: 12) {
                                    Inf6PaperSaveButton(result: r, pdfURL: pdf)
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.blue.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.blue.opacity(0.14), lineWidth: 1)
                        )
                    }
                }
            }
        }
        .padding(.bottom, 6)
    }
}
