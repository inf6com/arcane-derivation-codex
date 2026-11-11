

//
//  Inf6AutoPapers.swift
//  inf6
//
//  Created by decopin on 2025/11/30.
//



import Foundation
import SwiftUI

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

#if canImport(PDFKit)
import PDFKit
#endif



#if canImport(UIKit)
import UIKit
#endif




#if canImport(QuickLook)
import QuickLook
#endif

#if canImport(UIKit)
struct _Inf6SelectableTextView: UIViewRepresentable {
    final class _IntrinsicTextView: UITextView {
        override var intrinsicContentSize: CGSize {
            let w = bounds.width
            guard w > 1 else {
                return CGSize(width: UIView.noIntrinsicMetric, height: 1)
            }
            let size = sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
            return CGSize(width: UIView.noIntrinsicMetric, height: ceil(size.height))
        }

    }

    let text: String
    let font: UIFont
    let color: UIColor
    let lineLimit: Int

    func makeUIView(context: Context) -> UITextView {
        let tv = _IntrinsicTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.widthTracksTextView = true
        tv.textContainer.heightTracksTextView = false
        tv.setContentHuggingPriority(.required, for: .vertical)
        tv.setContentCompressionResistancePriority(.required, for: .vertical)
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        uiView.textContainer.maximumNumberOfLines = max(0, lineLimit)
        uiView.textContainer.lineBreakMode = .byTruncatingTail
        uiView.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
    }
}
#endif

#if canImport(UIKit)
struct _Inf6SelectableAttributedTextView: UIViewRepresentable {
    final class _IntrinsicAttributedTextView: UITextView {
        override var intrinsicContentSize: CGSize {
            let w = bounds.width
            guard w > 1 else {
                return CGSize(width: UIView.noIntrinsicMetric, height: 1)
            }
            let size = sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
            return CGSize(width: UIView.noIntrinsicMetric, height: ceil(size.height))
        }

    }

    let attributedText: NSAttributedString
    var onSelectionChanged: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: _Inf6SelectableAttributedTextView

        init(parent: _Inf6SelectableAttributedTextView) {
            self.parent = parent
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let range = textView.selectedRange
            guard range.length > 0, let text = textView.text else { return }
            let nsText = text as NSString
            guard NSMaxRange(range) <= nsText.length else { return }
            parent.onSelectionChanged?(nsText.substring(with: range))
        }
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = _IntrinsicAttributedTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.delegate = context.coordinator
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.widthTracksTextView = true
        tv.textContainer.heightTracksTextView = false
        tv.setContentHuggingPriority(.required, for: .vertical)
        tv.setContentCompressionResistancePriority(.required, for: .vertical)
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        // NSAttributedString の演算子比較は、同一内容でもインスタンス差で
        // 不一致になり得る。毎回 setAttributedText すると TextKit の再レイアウトが
        // SwiftUI の updateUIView を誘発し、メインスレッドの更新ループになる。
        if !(uiView.attributedText?.isEqual(to: attributedText) ?? false) {
            uiView.attributedText = attributedText
        }
    }
}
#endif

struct _Inf6PapersDestinationRowCard: View {
    let folderName: String
    let isCurrent: Bool
    let sourceText: String
    let platformText: String
    let pathText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(folderName)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .textSelection(.enabled)
                if isCurrent {
                    Text(Inf6Lang.text("現在", "Current"))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(0.14))
                        .clipShape(Capsule())
                }
                Spacer()
            }

            Text(sourceText + "    " + platformText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text(pathText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isCurrent ? Color.blue.opacity(0.10) : Color.secondary.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isCurrent ? Color.blue.opacity(0.72) : Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }
}





// MARK: - Source type (single canonical enum)
// Use the canonical `Inf6SyllabusSource` for the picker selection.
// If the symbol is ever ambiguous due to another module/type with the same name,
// qualify it with the app module name (commonly `inf6`).

struct Inf6AutoPapersLocalBodyView: View {
    let branding: Inf6CompassBranding

    @Binding var selectedSource: Inf6SyllabusSource

    @Binding var selectedSyllabusRoot: Inf6SyllabusRoot
    @Binding var selectedDepartmentCode: String

    @Binding var syllabi: [Inf6StanfordSyllabus]
    @Binding var schools: [ECSchool]
    @Binding var filtered: [Inf6StanfordSyllabus]
    @Binding var searchText: String

    @Binding var statusMessage: String
    @Binding var translatedTitles: [String: String]

    /// nil = すべての学校カテゴリを表示、non-nil = 指定カテゴリの学校のみ表示。
    let categoryFilter: Inf6SchoolCategory?
    let onOpenPaperChat: () -> Void
    let displayTitle: (Inf6StanfordSyllabus) -> String
    let onReload: (_ forceNetwork: Bool) -> Void
    let onApplyFilter: () -> Void
    @Environment(\.horizontalSizeClass) private var _horizontalSizeClass
    @ScaledMetric(relativeTo: .title2) private var _syllabusTileIconSize: CGFloat = 18
    @ScaledMetric(relativeTo: .title2) private var _syllabusTileIconFrame: CGFloat = 36
    @ScaledMetric(relativeTo: .body) private var _qualificationCardPadding: CGFloat = 18

    @State private var _expandedKnowledgeNodeIDs: Set<String> = []
    @State private var _sourceCollectionStatusByFamilyID: [String: String] = [:]

    var body: some View {
        let visibleSchools: [Inf6CompassLocalSchool] = {
            if let cat = categoryFilter {
                return Inf6CompassDefaultConfig.schools.filter { $0.category == cat }
            }
            return Inf6CompassDefaultConfig.schools
        }()

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(visibleSchools, id: \.key) { school in
                    let groups = _qualificationGroups(for: school)
                    if !groups.isEmpty {
                        ForEach(groups) { group in
                            _knowledgeTreeCard(group)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    /// ドメインごとの知識構造ツリーを直接表示する。
    @ViewBuilder
    private func _knowledgeTreeCard(_ group: _QualificationGroup) -> some View {
        let manifest = Inf6LearningFamilyManifestStore.load(familyID: group.id)
        let structure = _loadStructure(groupID: group.id, manifest: manifest)

        VStack(alignment: .leading, spacing: 0) {
            if let structure, let manifest {
                Inf6KnowledgeStructureTreeView(
                    structure: structure,
                    accentColor: group.accent,
                    selectableNodeIDs: [],
                    selectedNodeIDs: [],
                    expandedNodeIDs: $_expandedKnowledgeNodeIDs,
                    onToggleSelection: { _ in }
                )

                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        _collectOfficialSources(manifest: manifest)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.down.doc")
                                .font(.body.weight(.semibold))
                            Text(Inf6Lang.text("公式ソースを収集する", "Collect official sources"))
                                .font(.body.weight(.semibold))
                            Spacer()
                            Text("\(_sourceRequestCount(manifest))")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(group.accent.opacity(0.10), in: Capsule())
                        }
                        .foregroundStyle(group.accent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)

                    if let status = _sourceCollectionStatusByFamilyID[manifest.familyID] {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(status.hasPrefix("失敗") ? Color.red : Color.secondary)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // ツリー下部に詳細画面への導線
                if let action = group.actions.first {
                    NavigationLink {
                        _qualificationDestinationView(for: action)
                    } label: {
                        HStack {
                            Text(Inf6Lang.text("詳細を開く", "Open details"))
                                .font(.body.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.body)
                        }
                        .foregroundStyle(group.accent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                // マニフェストが見つからない場合（エラー表面化）
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Color.orange)
                    Text(group.title)
                        .font(.title3.weight(.bold))
                }
                .padding(16)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    private func _collectOfficialSources(manifest: Inf6LearningFamilyManifest) {
        _sourceCollectionStatusByFamilyID[manifest.familyID] = Inf6Lang.text("公式ソースを収集中です。", "Collecting official sources.")
        Task {
            do {
                let corpusSummary = await Inf6CorpusFetchCoordinator.refreshDomain(manifest: manifest)
                if corpusSummary.failed > 0 {
                    let details = corpusSummary.outcomes
                        .filter { !$0.success }
                        .map { "\($0.sourceID): \($0.error ?? "unknown error")" }
                        .joined(separator: "\n")
                    throw NSError(domain: "Inf6OfficialSourceCollection", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: details.isEmpty ? "公式ソース収集に失敗しました。" : details
                    ])
                }
                let snapshot = try await Inf6OfficialSourceCollector.collectAndSave(manifest: manifest)
                await MainActor.run {
                    Inf6GraphBoardView.invalidateRenderedCache()
                    _sourceCollectionStatusByFamilyID[manifest.familyID] = Inf6Lang.text(
                        "収集完了: コーパス \(corpusSummary.succeeded) 件 / スナップショット \(snapshot.sources.count) 件 / \(snapshot.collectedAt)",
                        "Collected: corpus \(corpusSummary.succeeded) sources / snapshots \(snapshot.sources.count) / \(snapshot.collectedAt)"
                    )
                }
            } catch {
                await MainActor.run {
                    _sourceCollectionStatusByFamilyID[manifest.familyID] = Inf6Lang.text(
                        "失敗: \(error.localizedDescription)",
                        "Failed: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func _sourceRequestCount(_ manifest: Inf6LearningFamilyManifest) -> Int {
        let current = (manifest.currentSources ?? []).reduce(0) { count, source in
            let hasJapaneseMirror = source.urlString.lowercased().contains("learn.microsoft.com/en-us/")
            return count + (hasJapaneseMirror ? 2 : 1)
        }
        return current + manifest.trendSources.count + manifest.officialSources.count
    }

    private func _loadStructure(
        groupID: String,
        manifest: Inf6LearningFamilyManifest?
    ) -> Inf6KnowledgeDomainStructure? {
        guard let manifest else { return nil }
        let paperStore: Inf6CorePaperStore? = Inf6CorePaperStore.shared
        let versionID = _resolvedKnowledgeStructureVersionID(for: manifest)
        return try? Inf6KnowledgeDomainStructureStore.loadOrSeed(
            manifest: manifest,
            syllabusVersionID: versionID,
            domainTitleJa: manifest.displayNameJa,
            outlineItems: [],
            paperStore: paperStore
        )
    }

    private func _resolvedKnowledgeStructureVersionID(for manifest: Inf6LearningFamilyManifest) -> String {
        if let examName = _examName(for: manifest),
           let info = Inf6SyllabusUpdateChecker.shared.examScheduleInfo(for: examName) {
            let versionID = info.preferredKnowledgeStructureID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !versionID.isEmpty {
                return versionID
            }
        }
        return ""
    }

    private func _examName(for manifest: Inf6LearningFamilyManifest) -> String? {
        switch manifest.familyID {
        case "e-shikaku":
            return "E資格"
        case "g-kentei":
            return "G検定"
        case "ai-102":
            return "AI-102"
        case "ai-103":
            return "AI-103"
        default:
            return nil
        }
    }

    @ViewBuilder
    private var _productEntrySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Inf6Lang.text("論文・PDF", "Papers & PDFs"))
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.14))
                        Image(systemName: "doc.text.image")
                            .font(.system(size: _syllabusTileIconSize, weight: .semibold))
                            .foregroundStyle(Color.blue)
                    }
                    .frame(width: _syllabusTileIconFrame, height: _syllabusTileIconFrame)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(Inf6Lang.text("PDF ごとに読む・蓄積する", "Read and accumulate per PDF"))
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.primary)
                        Text(
                            Inf6Lang.text(
                                "収集済み PDF を開き、解説・知識カード・演習を PDF 単位で蓄積します。",
                                "Open collected PDFs and accumulate explanations, knowledge cards, and exercises per PDF."
                            )
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    Text(Inf6Lang.text("3 導線", "3 flows"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.10), in: Capsule())
                }

                NavigationLink {
                    Inf6LibraryView()
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Inf6Lang.text("PDF ライブラリを開く", "Open PDF Library"))
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.leading)
                            Text(
                                Inf6Lang.text(
                                    "収集済み PDF を開いて、PDF ごとの解説・知識カード・演習を確認します。",
                                    "Open collected PDFs and review per-PDF explanations, knowledge cards, and exercises."
                                )
                            )
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.90))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 12)

                        Image(systemName: "arrow.right")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.blue, Color.blue.opacity(0.78)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                }
                .buttonStyle(.plain)

                LazyVGrid(columns: [
                    GridItem(.flexible(minimum: 140), spacing: 12),
                    GridItem(.flexible(minimum: 140), spacing: 12)
                ], spacing: 12) {
                    NavigationLink {
                        Inf6PaperCollectionBodyView(
                            onOpenPaperChat: onOpenPaperChat
                        )
                        .navigationTitle(Inf6Lang.text("論文収集", "Paper Collection"))
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        _productEntryTile(
                            accent: .green,
                            iconName: "arrow.down.doc",
                            title: Inf6Lang.text("論文・資料を収集する", "Collect Papers & Materials"),
                            subtitle: Inf6Lang.text(
                                "arXiv / PubMed などから論文と資料を集めます。",
                                "Collect papers and materials from arXiv, PubMed, and other sources."
                            )
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        onOpenPaperChat()
                    } label: {
                        _productEntryTile(
                            accent: .orange,
                            iconName: "bubble.left.and.text.bubble.right",
                            title: Inf6Lang.text("PaperChat を開く", "Open PaperChat"),
                            subtitle: Inf6Lang.text(
                                "論文探索と要点整理を会話で進めます。",
                                "Explore papers and organize key points through conversation."
                            )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(_qualificationCardPadding)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.blue.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.03), radius: 10, x: 0, y: 6)
        }
    }

    @ViewBuilder
    private func _productEntryTile(
        accent: Color,
        iconName: String,
        title: String,
        subtitle: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(14), weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
            }

            Spacer(minLength: 6)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(accent.opacity(0.14), lineWidth: 1)
        )
    }

    /// サブアクション共通タイル
    @ViewBuilder
    private func _secondaryTile(action: _QualificationAction, accent: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: action.iconName)
                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(14), weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(action.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Text(action.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
            }
            Spacer(minLength: 6)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(uiColor: .secondarySystemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(accent.opacity(0.14), lineWidth: 1))
    }

    /// E資格専用: 学習管理・シラバス連動アチーブメント導線タイル
    @ViewBuilder
    private func _learningManagementTile(accent: Color) -> some View {
        let tileAccent = Color.indigo
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: Inf6ApplicationSystemFont.scaledSize(14), weight: .semibold))
                .foregroundStyle(tileAccent)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(Inf6Lang.text("学習管理・アチーブメント", "Learning Management"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Text(Inf6Lang.text(
                    "シラバス連動の知の蓄積度・進捗・アラートを確認します。",
                    "Check syllabus-linked knowledge accumulation, progress, and alerts."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
            }
            Spacer(minLength: 6)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(uiColor: .secondarySystemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(tileAccent.opacity(0.22), lineWidth: 1))
    }

    @ViewBuilder
    private func _qualificationGroupCard(_ group: _QualificationGroup) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(group.accent.opacity(0.14))
                    Image(systemName: group.iconName)
                        .font(.system(size: _syllabusTileIconSize, weight: .semibold))
                        .foregroundStyle(group.accent)
                }
                .frame(width: _syllabusTileIconFrame, height: _syllabusTileIconFrame)

                VStack(alignment: .leading, spacing: 6) {
                    Text(group.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(group.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Text("\(group.actions.count) 導線")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(group.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(group.accent.opacity(0.10), in: Capsule())
            }

            if let primaryAction = group.actions.first {
                NavigationLink {
                    _qualificationDestinationView(for: primaryAction)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(primaryAction.title)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.leading)
                            Text(primaryAction.subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.90))
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 12)

                        Image(systemName: "arrow.right")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [group.accent, group.accent.opacity(0.78)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded {
                    _recordSelectedExam(group.id)
                })
            }

            let secondaryActions = Array(group.actions.dropFirst())
            let isEshikaku = group.id.localizedCaseInsensitiveContains("shikaku")
                || group.id.localizedCaseInsensitiveContains("e-cert")

            if !secondaryActions.isEmpty || isEshikaku {
                LazyVGrid(columns: [
                    GridItem(.flexible(minimum: 140), spacing: 12),
                    GridItem(.flexible(minimum: 140), spacing: 12)
                ], spacing: 12) {
                    ForEach(secondaryActions) { action in
                        NavigationLink {
                            _qualificationDestinationView(for: action)
                        } label: {
                            _secondaryTile(action: action, accent: group.accent)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded {
                            _recordSelectedExam(group.id)
                        })
                    }

                    // E資格専用: 学習管理・シラバス連動アチーブメントへの導線
                    if isEshikaku, let primaryAction = group.actions.first {
                        NavigationLink {
                            _qualificationDestinationView(for: primaryAction)
                        } label: {
                            _learningManagementTile(accent: group.accent)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded {
                            _recordSelectedExam(group.id)
                        })
                    }
                }
            }
        }
        .padding(_qualificationCardPadding)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(group.accent.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.03), radius: 10, x: 0, y: 6)
    }

    private func _schoolSectionHeader(_ key: String) -> String {
        switch key {
        case "microsoft": return "Microsoft Learn"
        case "jdla":      return "JDLA"
        default:          return key
        }
    }

    private struct _QualificationAction: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let iconName: String
        let opensLibrary: Bool
        let syllabus: Inf6StanfordSyllabus
    }

    private struct _QualificationGroup: Identifiable {
        let id: String
        let title: String
        let summary: String
        let accent: Color
        let iconName: String
        var actions: [_QualificationAction]
    }

    private func _qualificationGroups(for school: Inf6CompassLocalSchool) -> [_QualificationGroup] {
        let schoolLabel = Inf6Lang.text(school.labelJa, school.labelEn)
        let syllabusByID = Dictionary(
            uniqueKeysWithValues: filtered
                .filter { $0.level == schoolLabel }
                .map { ($0.id, $0) }
        )

        var groups: [_QualificationGroup] = []

        func groupIndex(for id: String) -> Int? {
            groups.firstIndex(where: { $0.id == id })
        }

        for faculty in school.faculties {
            for department in faculty.departments {
                guard let syllabus = syllabusByID[department.key] else { continue }

                let groupID = _qualificationGroupID(for: department)
                let manifest = Inf6LearningFamilyManifestStore.load(familyID: groupID)
                let groupTitle = _qualificationGroupTitle(manifest: manifest, syllabus: syllabus)
                let accent = _qualificationAccent(manifest: manifest)
                let groupIcon = _qualificationGroupIconName(manifest: manifest, department: department)
                let action = _qualificationAction(manifest: manifest, department: department, syllabus: syllabus)

                if let idx = groupIndex(for: groupID) {
                    var existing = groups[idx]
                    existing.actions.append(action)
                    groups[idx] = existing
                } else {
                    groups.append(
                        _QualificationGroup(
                            id: groupID,
                            title: groupTitle,
                            summary: _qualificationSummary(manifest: manifest, fallbackAction: action),
                            accent: accent,
                            iconName: groupIcon,
                            actions: [action]
                        )
                    )
                }
            }
        }

        return groups.sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func _qualificationGroupID(for department: Inf6CompassLocalDepartment) -> String {
        department.familyID ?? department.key
    }

    private func _qualificationGroupTitle(
        manifest: Inf6LearningFamilyManifest?,
        syllabus: Inf6StanfordSyllabus
    ) -> String {
        guard let manifest else { return syllabus.title }
        return manifest.displayNameJa
    }

    private func _qualificationSummary(
        manifest: Inf6LearningFamilyManifest?,
        fallbackAction: _QualificationAction
    ) -> String {
        guard let manifest else {
            return Inf6Lang.text(
                "次の行動を選んで、学習を前へ進めます。",
                "Choose the next action and move the study flow forward."
            )
        }

        if manifest.supportsPaperSearchProviders || manifest.allowsPDFImportProvider {
            return Inf6Lang.text(
                "論文を集め、収集済み PDF を開き、PDF ごとに解説・知識カード・演習を蓄積します。",
                "Collect papers, open saved PDFs, and accumulate explanations, cards, and exercises per PDF."
            )
        }
        if manifest.usesMicrosoftLearnProvider {
            return Inf6Lang.text(
                "公式情報を整理し、問題集の確認と測定へ進めます。",
                "Organize official knowledge, then confirm the quiz set and proceed to measurement."
            )
        }
        if manifest.usesJDLAHTMLProvider {
            return Inf6Lang.text(
                "生成済みの問題集を確認し、測定へ進めます。",
                "Confirm the generated quiz set and proceed to measurement."
            )
        }

        let descriptions = manifest.entryActions
            .map(\.descriptionJa)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !descriptions.isEmpty {
            return descriptions.joined(separator: " ")
        }
        return fallbackAction.subtitle
    }

    private func _qualificationAction(
        manifest: Inf6LearningFamilyManifest?,
        department: Inf6CompassLocalDepartment,
        syllabus: Inf6StanfordSyllabus
    ) -> _QualificationAction {
        let defaultTitle = syllabus.title
        let defaultSubtitle = syllabus.detail.isEmpty
            ? Inf6Lang.text("この資格導線を開きます。", "Open this qualification flow.")
            : syllabus.detail
        let opensLibrary = _qualificationActionOpensLibrary(manifest: manifest, department: department)

        return _QualificationAction(
            id: department.key,
            title: (department.actionLabelJa ?? defaultTitle).trimmingCharacters(in: .whitespacesAndNewlines),
            subtitle: (department.actionDescriptionJa ?? defaultSubtitle).trimmingCharacters(in: .whitespacesAndNewlines),
            iconName: _qualificationActionIconName(manifest: manifest, department: department),
            opensLibrary: opensLibrary,
            syllabus: syllabus
        )
    }

    @ViewBuilder
    private func _qualificationDestinationView(for action: _QualificationAction) -> some View {
        if action.opensLibrary {
            Inf6LibraryView()
        } else {
            Inf6AutoPapersView.SyllabusDetailView(
                syllabus: action.syllabus,
                branding: branding,
                schools: schools,
                departmentCode: selectedDepartmentCode,
                onTranslated: { titleJA, _ in
                    translatedTitles[action.syllabus.id] = titleJA
                }
            )
        }
    }

    private func _qualificationActionOpensLibrary(
        manifest: Inf6LearningFamilyManifest?,
        department: Inf6CompassLocalDepartment
    ) -> Bool {
        guard department.actionPhase == Inf6LearningFamilyActionPhase.organize.rawValue else {
            return false
        }
        guard let manifest else { return false }
        return manifest.supportsPaperSearchProviders || manifest.allowsPDFImportProvider
    }

    private func _recordSelectedExam(_ examID: String) {
        let normalized = examID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        var current = Inf6SelectedExamsStore.load() ?? []
        guard !current.contains(normalized) else { return }
        current.append(normalized)
        Inf6SelectedExamsStore.save(current)
    }

    private func _qualificationAccent(manifest: Inf6LearningFamilyManifest?) -> Color {
        guard let manifest else { return .accentColor }
        return _colorFromHex(manifest.accentColorHex) ?? .accentColor
    }

    private func _qualificationGroupIconName(
        manifest: Inf6LearningFamilyManifest?,
        department: Inf6CompassLocalDepartment
    ) -> String {
        if manifest?.usesMicrosoftLearnProvider == true {
            return "book.closed"
        }
        if manifest?.supportsPaperSearchProviders == true || manifest?.allowsPDFImportProvider == true {
            return "doc.text.image"
        }
        if manifest?.usesJDLAHTMLProvider == true {
            return "brain.head.profile"
        }
        return _qualificationActionIconName(manifest: manifest, department: department)
    }

    private func _qualificationActionIconName(
        manifest: Inf6LearningFamilyManifest?,
        department: Inf6CompassLocalDepartment
    ) -> String {
        switch department.actionPhase {
        case "collect":
            return "doc.text.magnifyingglass"
        case "organize":
            if manifest?.usesMicrosoftLearnProvider == true {
                return "text.document"
            }
            if manifest?.supportsPaperSearchProviders == true || manifest?.allowsPDFImportProvider == true {
                return "books.vertical"
            }
            return "list.bullet.rectangle"
        case "compose":
            if manifest?.usesMicrosoftLearnProvider == true {
                return "checklist"
            }
            if manifest?.supportsPaperSearchProviders == true || manifest?.allowsPDFImportProvider == true {
                return "doc.text.magnifyingglass"
            }
            return "list.bullet.rectangle"
        case "measure":
            return "checkmark.circle"
        default:
            return "arrow.right.circle"
        }
    }

    private func _colorFromHex(_ hex: String) -> Color? {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }
        let raw = String(trimmed.dropFirst())
        guard raw.count == 6, let value = UInt64(raw, radix: 16) else { return nil }
        let red = Double((value & 0xFF0000) >> 16) / 255.0
        let green = Double((value & 0x00FF00) >> 8) / 255.0
        let blue = Double(value & 0x0000FF) / 255.0
        return Color(red: red, green: green, blue: blue)
    }
}

struct Inf6PaperCollectionBodyView: View {
    let onOpenPaperChat: () -> Void

    var body: some View {
        List {
            Section {
                Inf6ArxivPubMedToolsSection(
                    onOpenPaperChat: onOpenPaperChat
                )
            } header: {
                Text(Inf6Lang.text("論文収集", "Paper Collection"))
            } footer: {
                Text(Inf6Lang.text(
                    "資格ツールとは分離して、論文の取得元だけを選びます。",
                    "This screen is independent from qualifications and only selects paper sources."
                ))
            }
        }
    }
}
