//
//  inf6SyllabnusDetailView.swift
//  inf6
//
//  Created by decopin on 2026/02/23.
//

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

#if canImport(WebKit)
import WebKit
#endif

import Foundation
import SwiftUI
import CoreText
import UniformTypeIdentifiers

import Security
import Dispatch

private struct _Inf6OutlineDashboardSection: Identifiable {
    let root: Inf6SyllabusOutlineItem
    let items: [Inf6SyllabusOutlineItem]

    var id: String { root.key }
    var title: String { root.displayTitle }
    var summary: String? { root.displaySummary }
    var selectableCount: Int { items.count }
}

struct Inf6KnowledgeStructureTreeView: View {
    let structure: Inf6KnowledgeDomainStructure
    let accentColor: Color
    let selectableNodeIDs: Set<String>
    let selectedNodeIDs: Set<String>
    @Binding var expandedNodeIDs: Set<String>
    let onToggleSelection: (String) -> Void

    private var nodeByID: [String: Inf6KnowledgeNode] {
        Dictionary(uniqueKeysWithValues: structure.nodes.map { ($0.nodeID, $0) })
    }

    private var paperByID: [String: Inf6KnowledgePaperLink] {
        Dictionary(uniqueKeysWithValues: structure.papers.map { ($0.paperID, $0) })
    }

    private var domainNode: Inf6KnowledgeNode? {
        structure.nodes.first(where: { $0.kind == .domain })
    }

    private var versionNode: Inf6KnowledgeNode? {
        structure.nodes.first(where: { $0.kind == .syllabusVersion })
    }

    private var topNodes: [Inf6KnowledgeNode] {
        let parentID = versionNode?.nodeID ?? domainNode?.nodeID
        return _children(of: parentID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            _summaryCard
            ForEach(topNodes) { node in
                _nodeCard(node)
            }
        }
        .padding(.vertical, 10)
    }

    private var _summaryCard: some View {
        let fraction = _fraction(for: versionNode ?? domainNode)
        return HStack(alignment: .center, spacing: 18) {
            ZStack {
                Circle()
                    .stroke(accentColor.opacity(0.16), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(accentColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(fraction * 100))%")
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(accentColor)
            }
            .frame(width: 84, height: 84)

            VStack(alignment: .leading, spacing: 10) {
                Text(versionNode?.titleJa ?? structure.syllabusVersionID)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                if let summaryJa = domainNode?.summaryJa.trimmingCharacters(in: .whitespacesAndNewlines),
                   !summaryJa.isEmpty {
                    Text(summaryJa)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    _metricChip(title: Inf6Lang.text("大項目", "Sections"), value: "\(topNodes.count)", color: accentColor)
                    _metricChip(title: Inf6Lang.text("論文", "Papers"), value: "\(structure.papers.count)", color: .orange)
                    _metricChip(title: Inf6Lang.text("選択中", "Selected"), value: "\(selectedNodeIDs.count)", color: .blue)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(accentColor.opacity(0.14), lineWidth: 1)
        )
    }

    private func _nodeCard(_ node: Inf6KnowledgeNode) -> AnyView {
        let isExpandable = !_children(of: node.nodeID).isEmpty
        let isExpanded = expandedNodeIDs.contains(node.nodeID)
        let isSelectable = selectableNodeIDs.contains(node.nodeID)
        let isSelected = selectedNodeIDs.contains(node.nodeID)
        let fraction = _fraction(for: node)

        return AnyView(
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(node.titleJa)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    let summary = node.summaryJa.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !summary.isEmpty {
                        Text(summary)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 10) {
                    _badge(text: _achievementLabel(node.achievement), color: _achievementColor(node.achievement))
                    if isSelectable {
                        Button {
                            onToggleSelection(node.nodeID)
                        } label: {
                            Label(
                                isSelected ? Inf6Lang.text("選択解除", "Deselect") : Inf6Lang.text("論点として選ぶ", "Select"),
                                systemImage: isSelected ? "checkmark.circle.fill" : "circle"
                            )
                            .font(.body.weight(.semibold))
                            .foregroundStyle(isSelected ? accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 12) {
                _metricChip(title: Inf6Lang.text("論文数", "Papers"), value: "\(node.paperCount)", color: .orange)
                _metricChip(title: Inf6Lang.text("重要度", "Importance"), value: _importanceLabel(node.importance), color: _importanceColor(node.importance))
                _metricChip(title: Inf6Lang.text("次の行動", "Next"), value: _actionLabel(node.nextAction), color: accentColor)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.12))
                    Capsule()
                        .fill(_achievementColor(node.achievement))
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 10)

            if isExpandable {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if isExpanded {
                            expandedNodeIDs.remove(node.nodeID)
                        } else {
                            expandedNodeIDs.insert(node.nodeID)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(isExpanded ? Inf6Lang.text("詳細を閉じる", "Hide details") : Inf6Lang.text("詳細を開く", "Show details"))
                            .font(.body.weight(.semibold))
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.body.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(_children(of: node.nodeID)) { child in
                            _childRow(child)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(_importanceColor(node.importance).opacity(0.16), lineWidth: 1)
        )
        )
    }

    private func _childRow(_ node: Inf6KnowledgeNode) -> AnyView {
        if node.kind == .paper, let paperID = node.linkedPaperIDs.first, let paper = paperByID[paperID] {
            return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(_achievementColor(paper.achievement))
                        .frame(width: 12, height: 12)
                        .padding(.top, 6)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(node.titleJa)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(node.summaryJa)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    VStack(alignment: .trailing, spacing: 8) {
                        _badge(text: _achievementLabel(paper.achievement), color: _achievementColor(paper.achievement))
                        Text(Inf6Lang.text("知識 \(paper.knowledgeCount)", "Knowledge \(paper.knowledgeCount)"))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
            )
            )
        } else {
            let isSelectable = selectableNodeIDs.contains(node.nodeID)
            let isSelected = selectedNodeIDs.contains(node.nodeID)

            return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Rectangle()
                        .fill(_achievementColor(node.achievement))
                        .frame(width: 4)
                        .clipShape(Capsule())

                    VStack(alignment: .leading, spacing: 6) {
                        Text(node.titleJa)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        let summary = node.summaryJa.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !summary.isEmpty {
                            Text(summary)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 0)

                    if isSelectable {
                        Button {
                            onToggleSelection(node.nodeID)
                        } label: {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(isSelected ? accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !_children(of: node.nodeID).isEmpty {
                    ForEach(_children(of: node.nodeID)) { child in
                        _childRow(child)
                            .padding(.leading, 18)
                    }
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
            )
            )
        }
    }

    private func _children(of parentID: String?) -> [Inf6KnowledgeNode] {
        structure.nodes
            .filter { $0.parentNodeID == parentID }
            .sorted {
                if $0.kind == .paper && $1.kind != .paper { return false }
                if $0.kind != .paper && $1.kind == .paper { return true }
                if $0.depth != $1.depth { return $0.depth < $1.depth }
                return $0.titleJa.localizedCaseInsensitiveCompare($1.titleJa) == .orderedAscending
            }
    }

    private func _fraction(for node: Inf6KnowledgeNode?) -> Double {
        guard let node else { return 0 }
        if !node.linkedPaperIDs.isEmpty {
            let fractions = node.linkedPaperIDs.compactMap { paperByID[$0] }.map { _achievementFraction($0.achievement) }
            guard !fractions.isEmpty else { return _achievementFraction(node.achievement) }
            return fractions.reduce(0, +) / Double(fractions.count)
        }
        let children = _children(of: node.nodeID)
        if !children.isEmpty {
            let fractions = children.map { _fraction(for: $0) }
            return fractions.reduce(0, +) / Double(fractions.count)
        }
        return _achievementFraction(node.achievement)
    }

    private func _achievementFraction(_ achievement: Inf6KnowledgeAchievementState) -> Double {
        switch achievement {
        case .notStarted:
            return 0.0
        case .collecting:
            return 0.16
        case .reading:
            return 0.42
        case .annotating:
            return 0.58
        case .explained:
            return 0.72
        case .questioned:
            return 0.88
        case .measured:
            return 1.0
        }
    }

    private func _achievementLabel(_ achievement: Inf6KnowledgeAchievementState) -> String {
        switch achievement {
        case .notStarted:
            return Inf6Lang.text("未着手", "Not started")
        case .collecting:
            return Inf6Lang.text("収集中", "Collecting")
        case .reading:
            return Inf6Lang.text("読書中", "Reading")
        case .annotating:
            return Inf6Lang.text("注釈済み", "Annotated")
        case .explained:
            return Inf6Lang.text("解説済み", "Explained")
        case .questioned:
            return Inf6Lang.text("問題化済み", "Questioned")
        case .measured:
            return Inf6Lang.text("測定済み", "Measured")
        }
    }

    private func _achievementColor(_ achievement: Inf6KnowledgeAchievementState) -> Color {
        switch achievement {
        case .notStarted:
            return .gray
        case .collecting:
            return .teal
        case .reading:
            return .blue
        case .annotating:
            return .purple
        case .explained:
            return .indigo
        case .questioned:
            return .orange
        case .measured:
            return .green
        }
    }

    private func _importanceLabel(_ raw: String) -> String {
        switch raw {
        case "high":
            return Inf6Lang.text("高", "High")
        case "medium":
            return Inf6Lang.text("中", "Medium")
        case "normal":
            return Inf6Lang.text("標準", "Normal")
        default:
            return raw
        }
    }

    private func _importanceColor(_ raw: String) -> Color {
        switch raw {
        case "high":
            return .red
        case "medium":
            return .orange
        default:
            return .blue
        }
    }

    private func _actionLabel(_ phase: Inf6LearningFamilyActionPhase) -> String {
        switch phase {
        case .collect:
            return Inf6Lang.text("収集", "Collect")
        case .organize:
            return Inf6Lang.text("整理", "Organize")
        case .compose:
            return Inf6Lang.text("問題化", "Compose")
        case .measure:
            return Inf6Lang.text("測定", "Measure")
        }
    }

    @ViewBuilder
    private func _metricChip(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.weight(.bold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func _badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.body.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// ============================================================================
// MARK: - Split 1/2 (UI)
// 目的: View本体（body / View fragments / 表示系の計算プロパティ）を extension にまとめ、
//      後で別ファイルへ移し替えやすくする。
// ============================================================================
extension Inf6SyllabusDetailView {

    // MARK: - User-facing error presentation (Explanation PDF)

    private func _userFacingExplanationPDFErrorMessage(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else {
            return Inf6Lang.text(
                "解説PDFの処理に失敗しました。\n\n『詳細をコピー』で内容を共有してください。",
                "Explanation PDF failed.\n\nUse “Copy details” to share the error."
            )
        }

        // If the message already looks user-actionable, keep it.
        if s.contains("未指定") || s.contains("選択") || s.contains("アクセス権") || s.contains("タイムアウト") || s.contains("不足") {
            return s
        }

        // Generic fallback: show a short, actionable message without dumping internal domains/codes.
        return Inf6Lang.text(
            "解説PDFの処理に失敗しました。\n\n『詳細をコピー』で内容を共有してください。",
            "Explanation PDF failed.\n\nUse “Copy details” to share the error."
        )
    }

    @MainActor
    private func _copyTextToPasteboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }


    // MARK: - iOS security-scope policy

    #if os(iOS)
    @inline(__always)
    private func _shouldUseSecurityScope() -> Bool {
        // iOS の Files / フォルダピッカー（bookmark含む）で取得したURLは、
        // iPad/iPhone 実機でも iOS App on Mac でも security-scope が必要になり得ます。
        // ここでは「ピッカー由来URLを扱う」前提で常に有効化します。
        return true
    }
    #endif

    // MARK: - Existing explanation PDF handling (open / overwrite)

    private enum _Inf6ExistingExplanationPDFDecision {
        case openExisting
        case overwrite
        case cancel
    }

    @MainActor
    private func _inf6TopMostViewControllerOrNil() -> UIViewController? {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let orderedScenes: [UIWindowScene] = {
            if let s = scenes.first(where: { $0.activationState == .foregroundActive }) {
                return [s] + scenes.filter { $0 != s }
            }
            if let s = scenes.first(where: { $0.activationState == .foregroundInactive }) {
                return [s] + scenes.filter { $0 != s }
            }
            return scenes
        }()

        func topPresented(from root: UIViewController) -> UIViewController {
            var vc: UIViewController = root
            while let p = vc.presentedViewController, !p.isBeingDismissed {
                vc = p
            }
            return vc
        }

        func bestPresenter(from root: UIViewController) -> UIViewController {
            let top = topPresented(from: root)
            if let nav = top as? UINavigationController {
                if let vis = nav.visibleViewController { return bestPresenter(from: vis) }
                return nav
            }
            if let tab = top as? UITabBarController {
                if let sel = tab.selectedViewController { return bestPresenter(from: sel) }
                return tab
            }
            if let split = top as? UISplitViewController {
                if let last = split.viewControllers.last { return bestPresenter(from: last) }
                return split
            }
            return top
        }

        for scene in orderedScenes {
            let windows = scene.windows
            guard !windows.isEmpty else { continue }

            let visible = windows.filter { !$0.isHidden && $0.alpha > 0.0 && $0.windowLevel == .normal }
            let candidates = visible.isEmpty ? windows : visible

            var orderedWindows: [UIWindow] = []
            if let key = candidates.first(where: { $0.isKeyWindow }) {
                orderedWindows.append(key)
            }
            orderedWindows.append(contentsOf: candidates.filter { !$0.isKeyWindow })

            for win in orderedWindows {
                guard let root = win.rootViewController else { continue }
                if root.viewIfLoaded?.window == nil {
                    _ = root.view
                    if root.viewIfLoaded?.window == nil { continue }
                }
                let presenter = bestPresenter(from: root)
                if presenter.viewIfLoaded?.window == nil {
                    _ = presenter.view
                    if presenter.viewIfLoaded?.window == nil { continue }
                }
                return presenter
            }
        }

        return nil
        #else
        return nil
        #endif
    }

    @MainActor
    private func _presentExistingExplanationPDFConflictDialogOrThrow(destURL: URL) async throws -> _Inf6ExistingExplanationPDFDecision {
        #if os(iOS)
        guard let presenter = _inf6TopMostViewControllerOrNil() else {
            throw NSError(domain: "Inf6PDF", code: 2010, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "確認ダイアログを表示できません（画面提示元が取得できません）。",
                    "Cannot present confirmation dialog (failed to resolve presenter)."
                )
            ])
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<_Inf6ExistingExplanationPDFDecision, Never>) in
            let title = Inf6Lang.text("同名ファイルが存在します", "File already exists")
            let message = Inf6Lang.text(
                "同名の解説PDFが既に存在します。\n\n『既存を開く』または『上書き』を選択してください。\n\n保存先: \(destURL.path)",
                "An explanation PDF with the same name already exists.\n\nChoose either Open existing or Overwrite.\n\nPath: \(destURL.path)"
            )

            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)

            alert.addAction(UIAlertAction(title: Inf6Lang.text("既存を開く", "Open existing"), style: .default) { _ in
                cont.resume(returning: .openExisting)
            })

            alert.addAction(UIAlertAction(title: Inf6Lang.text("上書き", "Overwrite"), style: .destructive) { _ in
                cont.resume(returning: .overwrite)
            })

            alert.addAction(UIAlertAction(title: Inf6Lang.text("キャンセル", "Cancel"), style: .cancel) { _ in
                cont.resume(returning: .cancel)
            })

            presenter.present(alert, animated: true)
        }
        #else
        return .cancel
        #endif
    }

    @MainActor
    private func _openExistingExplanationPDFOrThrow(_ url: URL) async throws {
        #if os(iOS)
        guard url.isFileURL else {
            throw NSError(domain: "Inf6PDF", code: 2011, userInfo: [
                NSLocalizedDescriptionKey: "Expected a file URL: \(url.absoluteString)"
            ])
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "Inf6PDF", code: 2012, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "既存ファイルが見つかりません（存在しません）。",
                    "Existing file was not found (missing)."
                )
            ])
        }

        let ok: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            UIApplication.shared.open(url, options: [:]) { success in
                cont.resume(returning: success)
            }
        }
        if !ok {
            throw NSError(domain: "Inf6PDF", code: 2013, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "既存の解説PDFを開けませんでした（システムが拒否しました）。",
                    "Failed to open the existing explanation PDF (system denied the request)."
                )
            ])
        }
        #else
        throw NSError(domain: "Inf6PDF", code: 2014, userInfo: [
            NSLocalizedDescriptionKey: "Open existing PDF is supported on iOS only in this path."
        ])
        #endif
    }

    private func _atomicOverwriteFileOrThrow(destURL: URL, data: Data) throws {
        guard destURL.isFileURL else {
            throw NSError(domain: "Inf6PDF", code: 2015, userInfo: [
                NSLocalizedDescriptionKey: "Expected a file URL: \(destURL.absoluteString)"
            ])
        }

        let dir = destURL.deletingLastPathComponent()
        let tmpName = ".inf6_tmp_\(UUID().uuidString).pdf"
        let tmpURL = dir.appendingPathComponent(tmpName, isDirectory: false)

        try data.write(to: tmpURL, options: [.atomic])

        do {
            _ = try FileManager.default.replaceItemAt(destURL, withItemAt: tmpURL, backupItemName: nil, options: [])
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw error
        }

        if FileManager.default.fileExists(atPath: tmpURL.path) {
            try? FileManager.default.removeItem(at: tmpURL)
        }
    }

    // MARK: - Export (SwiftUI fileExporter) security-scope bookkeeping
    // fileExporter completion handler must always stopAccessingSecurityScopedResource
    // when we started it for the export source folder.

    @ViewBuilder
    var _mainContentWithExplanationPDFExporter: some View {
        mainContent
            .fileExporter(
                isPresented: $isExportingExplanationPDF,
                document: exportExplanationDocument,
                contentType: .pdf,
                defaultFilename: _explanationPDFFilenameBaseFromSelection()
            ) { result in
                switch result {
                case .success:
                    self.explanationPDFStatus = Inf6Lang.text("書き出しが完了しました。", "Export completed.")
                case .failure(let error):
                    let msg = Inf6Lang.text(
                        "書き出しに失敗しました: \(error)",
                        "Export failed: \(error)"
                    )
                    self.explanationPDFStatus = msg
                    self.explanationPDFErrorAlertMessage = msg
                    self.showExplanationPDFErrorAlert = true
                }

                // 次回に備えて必ずクリア
                self.exportExplanationDocument = nil

                // Export 中だけ保持していた security-scope を必ず解放（成功/失敗どちらでも）
                if self._didStartExportingExplanationPDFScope,
                   let f = self._exportingExplanationPDFScopeFolderURL {
                    f.stopAccessingSecurityScopedResource()
                }
                self._exportingExplanationPDFScopeFolderURL = nil
                self._didStartExportingExplanationPDFScope = false
            }
    }

    // MARK: - G検定: 解説PDF 保存先（ユーザー指定フォルダ / bookmark）

    private func gkenteiExplanationPDFFolderBookmarkFileURL() throws -> URL {
        let url = try Inf6UserSettingRootPaths.userDataFileURL("gkentei_explanation_pdf_destination", ext: "bookmark")
        if !FileManager.default.fileExists(atPath: url.path),
           let old = try? Inf6UserSettingRootPaths.cacheFileURL("gkentei_explanation_pdf_destination", ext: "bookmark"),
           FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: url)
        }
        return url
    }

    func loadPersistedGkenteiExplanationPDFFolder() throws -> URL? {
        let fileURL = try gkenteiExplanationPDFFolderBookmarkFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let data = try Inf6DiskData.load(from: fileURL)

        var isStale = false
        let opts: URL.BookmarkResolutionOptions = {
#if os(iOS)
            // iOS では `.withSecurityScope` は利用できないため、bookmark は通常解決します。
            // 実アクセスは `startAccessingSecurityScopedResource()` で取得します。
            return [.withoutUI]
#elseif os(macOS)
            return [.withoutUI, .withSecurityScope]
#else
            return [.withoutUI]
#endif
        }()

        let resolved: URL
        do {
            resolved = try URL(
                resolvingBookmarkData: data,
                options: opts,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            // Persisted bookmark payload is invalid/corrupted.
            // Remove it so the next launch does not fail in a loop.
            try? FileManager.default.removeItem(at: fileURL)
            throw NSError(
                domain: "Inf6Bookmark",
                code: 259,
                userInfo: [
                    NSLocalizedDescriptionKey: Inf6Lang.text(
                        "保存済みの解説PDF保存先フォルダ情報が壊れていたため無効化しました。保存先を再選択してください。",
                        "The saved explanation PDF destination folder data was invalid and has been reset. Please choose the destination folder again."
                    ),
                    NSUnderlyingErrorKey: error
                ]
            )
        }

        if isStale {
            let updated = try resolved.bookmarkData(
                options: {
#if os(iOS)
                    // iOS では `.withSecurityScope` は利用できません。
                    return [.minimalBookmark]
#elseif os(macOS)
                    return [.withSecurityScope]
#else
                    return [.minimalBookmark]
#endif
                }(),
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            try Inf6DiskData.save(updated, to: fileURL)
        }

        return resolved
    }

    private func persistGkenteiExplanationPDFFolder(_ url: URL) throws {
        let fileURL = try gkenteiExplanationPDFFolderBookmarkFileURL()
        let data = try url.bookmarkData(
            options: {
#if os(iOS)
                // iOS では `.withSecurityScope` は利用できません。
                return [.minimalBookmark]
#elseif os(macOS)
                return [.withSecurityScope]
#else
                return [.minimalBookmark]
#endif
            }(),
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try Inf6DiskData.save(data, to: fileURL)
    }

    // MARK: - Microsoft: 知識PDF 保存先（shared root / fixed path）

    private func _microsoftKnowledgePDFDirectoryURLOrThrow() throws -> URL {
        try Inf6LibraryView._microsoftKnowledgePDFDirectory(qualificationID: syllabus.id)
    }

    // MARK: - G検定: 解説PDF 保存先フォルダ UI

    private var gkenteiExplanationPDFFolderRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(Inf6Lang.text("解説PDF保存先", "Explanation PDF destination"))
                    .font(.headline)
                Spacer()
                Button {
                    isPickingGkenteiExplanationPDFFolder = true
                } label: {
                    Text(Inf6Lang.text("選択…", "Choose…"))
                }
                .buttonStyle(.bordered)
            }

            if let u = gkenteiFolderURL {
                Text(u.path)
                    .font(.caption)
                    .foregroundStyle(Color.blue)
                    .lineLimit(2)
                    .truncationMode(.middle)
            } else {
                Text(Inf6Lang.text(
                    "解説PDF保存先が未指定です。「選択…」でフォルダを指定してください。",
                    "Explanation PDF destination is not set. Choose a folder with “Choose…”."
                ))
                .font(.caption)
                .foregroundStyle(Color.blue)
            }

            if !gkenteiFolderStatus.isEmpty {
                Text(gkenteiFolderStatus)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - E資格: 解説PDF 保存先フォルダ UI（G検定と同じ行）

    private var eshikakuExplanationPDFFolderRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(Inf6Lang.text("解説PDF保存先", "Explanation PDF destination"))
                    .font(.headline)
                Spacer()
                Button {
                    Task { @MainActor in
                        do {
                            try await _chooseEshikakuExportFolderOrThrow()
                            eshikakuPaperSearchStatus = Inf6Lang.text(
                                "保存先フォルダを設定しました。",
                                "Destination folder has been set."
                            )
                        } catch {
                            let msg = Inf6Lang.text(
                                "保存先フォルダの選択に失敗: \(error.localizedDescription)",
                                "Failed to choose destination folder: \(error.localizedDescription)"
                            )
                            eshikakuPaperSearchStatus = msg
                            explanationPDFErrorAlertMessage = msg
                            showExplanationPDFErrorAlert = true
                        }
                    }
                } label: {
                    Text(Inf6Lang.text("選択…", "Choose…"))
                }
                .buttonStyle(.bordered)
            }

            if let u = try? _eshikakuExportFolderURLOrThrow() {
                Text(u.path)
                    .font(.caption)
                    .foregroundStyle(Color.blue)
                    .lineLimit(2)
                    .truncationMode(.middle)
            } else {
                Text(Inf6Lang.text(
                    "解説PDF保存先が未指定です。「選択…」でフォルダを指定してください。",
                    "Explanation PDF destination is not set. Choose a folder with “Choose…”."
                ))
                .font(.caption)
                .foregroundStyle(Color.blue)
            }

            if !eshikakuPaperSearchStatus.isEmpty {
                Text(eshikakuPaperSearchStatus)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var microsoftKnowledgePDFFolderRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(Inf6Lang.text("知識PDF保存先", "Knowledge PDF destination"))
                    .font(.headline)
                Spacer()
            }

            if let u = microsoftKnowledgePDFFolderURL ?? (try? _microsoftKnowledgePDFDirectoryURLOrThrow()) {
                Text(u.path)
                    .font(.caption)
                    .foregroundStyle(Color.blue)
                    .lineLimit(2)
                    .truncationMode(.middle)
            } else {
                Text(Inf6Lang.text(
                    "shared root が未設定です。ライブラリ画面で共有保存先を設定してください。",
                    "The shared root is not configured. Set the shared storage location from the library screen."
                ))
                .font(.caption)
                .foregroundStyle(Color.blue)
            }

            if !microsoftKnowledgePDFFolderStatus.isEmpty {
                Text(microsoftKnowledgePDFFolderStatus)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var eshikakuExplanationBlock: some View {
        if isEshikakuCourse {
            // 保存先フォルダ行（UIとして見える場所に出す）
            eshikakuExplanationPDFFolderRow
        }
    }

    @ViewBuilder
    private var microsoftKnowledgeBlock: some View {
        if isMicrosoftLearnKnowledgeCourse {
            if isGeneratingMicrosoftKnowledgePDF {
                HStack {
                    ProgressView().tint(.pink).scaleEffect(1.25)
                    Text(Inf6Lang.text("知識PDFを生成中…", "Generating knowledge PDF…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            if !microsoftKnowledgePDFStatus.isEmpty {
                Text(microsoftKnowledgePDFStatus)
                    .font(.caption)
                    .foregroundStyle(Color.blue)

                if let u = generatedMicrosoftKnowledgePDFURL {
                    Text(u.path)
                        .font(.caption2)
                        .foregroundStyle(Color.blue)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            } else if let r = _microsoftKnowledgePDFDisabledReason {
                Text(r)
                    .font(.caption)
                    .foregroundStyle(Color.blue)
            }

            microsoftKnowledgePDFFolderRow
        }
    }
    
    // MARK: - Display title (local)

    /// Local display title used by UI sections.
    var displayTitle: String {
        syllabus.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }


    private func applyGkenteiExplanationPDFFolderPicker<Content: View>(_ content: Content) -> some View {
        content.fileImporter(
            isPresented: $isPickingGkenteiExplanationPDFFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) {
            let urls = try? $0.get()
            guard let picked = urls?.first else {
                gkenteiFolderStatus = Inf6Lang.text("フォルダが選択されませんでした。", "No folder was selected.")
                return
            }

            #if os(iOS)
            let started: Bool
            if _shouldUseSecurityScope() {
                started = picked.startAccessingSecurityScopedResource()
            } else {
                started = false
            }
            defer { if started { picked.stopAccessingSecurityScopedResource() } }
            #endif

            do {
                try persistGkenteiExplanationPDFFolder(picked)
                gkenteiFolderURL = picked
                gkenteiFolderStatus = Inf6Lang.text("解説PDF保存先を設定しました。", "Explanation PDF destination folder set.")

                if showGkenteiGeneratedPDFListSheet {
                    try _reloadGkenteiGeneratedPDFListOrThrow()
                }
            } catch {
                gkenteiFolderURL = nil
                let msg = Inf6Lang.text(
                    "解説PDF保存先フォルダの保存に失敗しました: \(error)",
                    "Failed to persist the explanation PDF destination folder: \(error)"
                )
                gkenteiFolderStatus = msg
                explanationPDFErrorAlertMessage = msg
                showExplanationPDFErrorAlert = true
            }
        }
    }

    @ViewBuilder
    var body: some View {
        let base = Group {
            #if os(iOS)
            if #available(iOS 16.0, *) {
                if isIOSAppOnMac {
                    _mainContentWithExplanationPDFExporter
                } else {
                    _mainContentWithExplanationPDFExporter
                        .quickLookPreview($quickLookExplanationPDFURL)
                }
            } else {
                _mainContentWithExplanationPDFExporter
            }
            #else
            _mainContentWithExplanationPDFExporter
            #endif
        }
        .alert(Inf6Lang.text("解説PDFエラー", "Explanation PDF Error"), isPresented: $showExplanationPDFErrorAlert) {
            Button(Inf6Lang.text("詳細をコピー", "Copy details")) {
                Task { @MainActor in
                    _copyTextToPasteboard(explanationPDFErrorAlertMessage)
                    explanationPDFStatus = Inf6Lang.text(
                        "エラー詳細をコピーしました。必要なら貼り付けて共有してください。",
                        "Copied error details. Paste and share if needed."
                    )
                }
            }
            Button("OK") {}
        } message: {
            Text(_userFacingExplanationPDFErrorMessage(explanationPDFErrorAlertMessage))
        }
        .sheet(isPresented: $showMMAQuizPlayerSheet) {
            Inf6MMAQuizPlayerView(
                qualificationId: syllabus.id,
                qualificationTitle: displayTitle
            )
        }
        .sheet(isPresented: $showGkenteiGeneratedPDFListSheet) {
            #if os(iOS)
            if #available(iOS 16.0, *) {
                NavigationStack { gkenteiGeneratedPDFListPanel }
            } else {
                NavigationView { gkenteiGeneratedPDFListPanel }
            }
            #else
            NavigationView { gkenteiGeneratedPDFListPanel }
            #endif
        }
        .onChange(of: generatedExplanationPDFURL) { _, newURL in
            guard isGkenteiCourse else { return }
            guard let newURL else { return }

            if FileManager.default.fileExists(atPath: newURL.path) {
                self.explanationPDFStatus = Inf6Lang.text(
                    "解説PDFを生成しました。\n\n右上のボタンから書き出してください。",
                    "Explanation PDF generated.\n\nExport it from the top-right button."
                )
            } else {
                let msg = Inf6Lang.text(
                    "解説PDFの生成に失敗しました（生成ファイルが存在しません）。\n\n生成先: \(newURL.path)",
                    "Failed to generate the explanation PDF (the generated file does not exist).\n\nPath: \(newURL.path)"
                )
                self.explanationPDFStatus = msg
                self.explanationPDFErrorAlertMessage = msg
                self.showExplanationPDFErrorAlert = true
            }
        }

        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            base
                .fullScreenCover(isPresented: $showEshikakuPaperSearchFullScreen) {
                    eshikakuPaperSearchSheet
                }
        } else {
            base
                .sheet(isPresented: $showEshikakuPaperSearchSheet) {
                    eshikakuPaperSearchSheet
                }
        }
        #else
        base
        #endif
    }

    var _gkenteiExplanationPDFDisabledReason: String? {
        if selectedOutlineKeys.isEmpty {
            return Inf6Lang.text("シラバス項目を1つ以上選択してください。", "Please select at least one syllabus item.")
        }
        if isGeneratingExplanationPDF {
            return Inf6Lang.text("現在、解説PDFを生成中です。", "An explanation PDF is being generated.")
        }
        return nil
    }

    var _microsoftKnowledgePDFDisabledReason: String? {
        if isGeneratingMicrosoftKnowledgePDF {
            return Inf6Lang.text("現在、知識PDFを生成中です。", "A knowledge PDF is being generated.")
        }
        do {
            _ = try _microsoftKnowledgePDFDirectoryURLOrThrow()
        } catch {
            return Inf6Lang.text(
                "shared root が未設定です。ライブラリ画面で共有保存先を設定してください。",
                "The shared root is not configured. Set the shared storage location from the library screen."
            )
        }
        return nil
    }

    var _eshikakuPaperSearchDisabledReason: String? {
        if selectedOutlineKeys.isEmpty {
            return Inf6Lang.text(
                "論文サーチの前に、シラバス項目を1つ以上選択してください。",
                "Select at least one syllabus item before opening paper search."
            )
        }
        return nil
    }

    @MainActor
    private func _requestEshikakuPDFImport() {
        showEshikakuPaperSearchSheet = false
        showEshikakuPaperSearchFullScreen = false

        let targetFolder: URL? = {
            if let u = folderURL { return u }
            if let restored = try? loadPersistedEshikakuPDFFolder() {
                folderURL = restored
                return restored
            }
            return nil
        }()

        NotificationCenter.default.post(
            name: .inf6RequestLibraryImportPicker,
            object: targetFolder
        )

        eshikakuPaperSearchStatus = Inf6Lang.text(
            "ライブラリで PDF を追加するよう要求しました。",
            "Requested the Library to add PDFs."
        )
    }

    @MainActor
    private func _openEshikakuPaperSearch() {
        if selectedOutlineKeys.isEmpty {
            let msg = Inf6Lang.text(
                "シラバス項目を1つ以上選択してください。",
                "Please select at least one syllabus item."
            )
            eshikakuPaperSearchStatus = msg
            explanationPDFErrorAlertMessage = msg
            showExplanationPDFErrorAlert = true
            return
        }

        let titles: [String] = syllabusOutlineItems
            .filter { selectedOutlineKeys.contains($0.key) }
            .map { $0.displayTitle.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        var uniq: [String] = []
        uniq.reserveCapacity(titles.count)
        for t in titles {
            if seen.contains(t) { continue }
            seen.insert(t)
            uniq.append(t)
        }

        let q = uniq.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            let msg = Inf6Lang.text(
                "検索語を生成できませんでした（選択項目のタイトルが空です）。",
                "Failed to build a query (selected item titles are empty)."
            )
            eshikakuPaperSearchStatus = msg
            explanationPDFErrorAlertMessage = msg
            showExplanationPDFErrorAlert = true
            return
        }

        eshikakuPaperQuery = q

        Task { @MainActor in
            await Task.yield()

            if UIDevice.current.userInterfaceIdiom == .pad {
                showEshikakuPaperSearchSheet = true
                showEshikakuPaperSearchFullScreen = false
            } else {
                showEshikakuPaperSearchFullScreen = true
                showEshikakuPaperSearchSheet = false
            }

            await Task.yield()
            startEshikakuPaperSearchUI()
        }
    }

    @ViewBuilder
    var primaryActionsSection: some View {
        Section {

            if isMicrosoftLearnKnowledgeCourse {
                Button {
                    generateMicrosoftLearnKnowledgePDF()
                } label: {
                    Label(
                        Inf6Lang.text("公式知識を整理する", "Organize current knowledge"),
                        systemImage: "wand.and.stars"
                    )
                }
                .disabled(_microsoftKnowledgePDFDisabledReason != nil)

                Button {
                    generateMMAQuizMicrosoftLearn()
                } label: {
                    Label(
                        Inf6Lang.text("MMA 演習を生成する", "Generate MMA exercise"),
                        systemImage: "checklist"
                    )
                }
                .disabled(_microsoftKnowledgePDFDisabledReason != nil)
            } else if isGkenteiCourse {
                Button {
                    generateGkenteiExplanationPDF()
                } label: {
                    Label(
                        Inf6Lang.text("解説 PDF を生成する", "Generate explanation PDF"),
                        systemImage: "wand.and.stars"
                    )
                }
                .disabled(_gkenteiExplanationPDFDisabledReason != nil)

                Button {
                    generateMMAQuizJDLA()
                } label: {
                    Label(
                        Inf6Lang.text("MMA 演習を生成する", "Generate MMA exercise"),
                        systemImage: "checklist"
                    )
                }
                .disabled(_gkenteiExplanationPDFDisabledReason != nil)
            } else if isEshikakuCourse {
                Button {
                    _requestEshikakuPDFImport()
                } label: {
                    Label(
                        Inf6Lang.text("PDF をライブラリに追加する", "Add PDFs to library"),
                        systemImage: "tray.and.arrow.down"
                    )
                }

                NavigationLink {
                    Inf6LibraryView()
                } label: {
                    Label(
                        Inf6Lang.text("収集済み PDF を開く", "Open collected PDFs"),
                        systemImage: "books.vertical"
                    )
                }

                Button {
                    _openEshikakuPaperSearch()
                } label: {
                    Label(
                        Inf6Lang.text("論文サーチを開く", "Open paper search"),
                        systemImage: "doc.text.magnifyingglass"
                    )
                }
                .disabled(_eshikakuPaperSearchDisabledReason != nil)

            }

            if isEshikakuCourse, let reason = _eshikakuPaperSearchDisabledReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(Color.blue)
            }
        }
    }

    @ViewBuilder
    var coreListContent: some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            _coreListBase
                .scrollContentBackground(.hidden)
        } else {
            _coreListBase
        }
        #else
        _coreListBase
        #endif
    }

    var _coreListBase: some View {
        List {
            knowledgeStructureSection
            primaryActionsSection
            if let officialHomeURL = resolvedOfficialHomeURL {
                officialSiteSection(officialHomeURL: officialHomeURL)
            }
            if isMicrosoftLearnKnowledgeCourse {
                microsoftLearnSourcesSection
            }

            // Watch sync on appear
            EmptyView()
                .onAppear {
                    if isEshikakuCourse {
                        #if os(iOS)
                        Inf6CorePaperWatchSender.shared.sendLearningGuide(store: Inf6CorePaperStore.shared)
                        #endif
                    }
                }
                .task(id: _knowledgeStructureReloadKey) {
                    _loadKnowledgeDomainStructureIfPossible()
                }
        }
        .navigationTitle(Inf6Lang.text("シラバス詳細", "Syllabus Detail"))
        .navigationBarTitleDisplayMode(.inline)
        .foregroundStyle(Color.blue)
        #if os(iOS)
        .background(Color(uiColor: .systemBackground))
        #endif
        .toolbar {

            // E資格: add paper search button to the title bar (right side)
            if isEshikakuCourse {
                #if os(iOS)
                // iOS/iPadOS: navigation bar trailing
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Text(Inf6Lang.text("PDF取り込みは 1 件のみ対応です。", "PDF import supports 1 item only."))
                        Button {
                            // Ensure any overlay does not stay on top of this view.
                            showEshikakuPaperSearchSheet = false
                            showEshikakuPaperSearchFullScreen = false

                            let targetFolder: URL? = {
                                if let u = folderURL { return u }
                                if let restored = try? loadPersistedEshikakuPDFFolder() {
                                    folderURL = restored
                                    return restored
                                }
                                return nil
                            }()

                            NotificationCenter.default.post(
                                name: .inf6RequestLibraryImportPicker,
                                object: targetFolder
                            )

                            eshikakuPaperSearchStatus = Inf6Lang.text(
                                "ライブラリのPDF取り込みを開くよう要求しました。",
                                "Requested the Library to open the PDF import picker."
                            )
                        } label: {
                            Label(
                                Inf6Lang.text("PDFを取り込む…", "Import PDF…"),
                                systemImage: "tray.and.arrow.down"
                            )
                        }
                    } label: {
                        Label(
                            Inf6Lang.text("PDFを取り込む…", "Import PDF…"),
                            systemImage: "tray.and.arrow.down"
                        )
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Color.blue)
                    }
                    .tint(Color.blue)
                    .help(Inf6Lang.text("PDFを取り込むメニューを開きます", "Open the PDF import menu"))
                    Menu {
                        if selectedOutlineKeys.isEmpty {
                            Text(Inf6Lang.text(
                                "シラバス項目を1つ以上選択してください。",
                                "Please select at least one syllabus item."
                            ))
                        } else {
                            Button {
                                // Hard failures must surface.
                                if selectedOutlineKeys.isEmpty {
                                    let msg = Inf6Lang.text(
                                        "シラバス項目を1つ以上選択してください。",
                                        "Please select at least one syllabus item."
                                    )
                                    eshikakuPaperSearchStatus = msg
                                    explanationPDFErrorAlertMessage = msg
                                    showExplanationPDFErrorAlert = true
                                    return
                                }

                                // Regenerate query from current selection only (no fixed prefix)
                                let titles: [String] = syllabusOutlineItems
                                    .filter { selectedOutlineKeys.contains($0.key) }
                                    .map { $0.displayTitle.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
                                    .filter { !$0.isEmpty }

                                // Deterministic order: preserve syllabusOutlineItems order and de-duplicate
                                var seen = Set<String>()
                                var uniq: [String] = []
                                uniq.reserveCapacity(titles.count)
                                for t in titles {
                                    if seen.contains(t) { continue }
                                    seen.insert(t)
                                    uniq.append(t)
                                }

                                let q = uniq.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !q.isEmpty else {
                                    let msg = Inf6Lang.text(
                                        "検索語を生成できませんでした（選択項目のタイトルが空です）。",
                                        "Failed to build a query (selected item titles are empty)."
                                    )
                                    eshikakuPaperSearchStatus = msg
                                    explanationPDFErrorAlertMessage = msg
                                    showExplanationPDFErrorAlert = true
                                    return
                                }

                                eshikakuPaperQuery = q

                                // Present the paper search UI after the Menu closes.
                                Task { @MainActor in
                                    await Task.yield()

                                    if UIDevice.current.userInterfaceIdiom == .pad {
                                        showEshikakuPaperSearchSheet = true
                                        showEshikakuPaperSearchFullScreen = false
                                    } else {
                                        showEshikakuPaperSearchFullScreen = true
                                        showEshikakuPaperSearchSheet = false
                                    }

                                    // Start search after presentation state is committed.
                                    await Task.yield()
                                    startEshikakuPaperSearchUI()
                                }
                            } label: {
                                Label(
                                    Inf6Lang.text("論文サーチを開く…", "Open paper search…"),
                                    systemImage: "doc.text.magnifyingglass"
                                )
                            }
                        }
                    } label: {
                        Label(
                            Inf6Lang.text("論文サーチ…", "Paper search…"),
                            systemImage: "doc.text.magnifyingglass"
                        )
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Color.blue)
                    }
                    .tint(Color.blue)
                    .help(Inf6Lang.text("論文サーチのメニューを開きます", "Open the paper search menu"))
                }
                #else
                #endif
            }

            if isMicrosoftLearnKnowledgeCourse {
                #if os(iOS)
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        if let r = _microsoftKnowledgePDFDisabledReason {
                            Text(r)
                        }

                        Button {
                            generateMicrosoftLearnKnowledgePDF()
                        } label: {
                            Label(
                                Inf6Lang.text("現行知識PDFを生成…", "Generate current knowledge PDF…"),
                                systemImage: "wand.and.stars"
                            )
                        }
                        .disabled(_microsoftKnowledgePDFDisabledReason != nil)

                        Divider()

                        Button {
                            generateMMAQuizMicrosoftLearn()
                        } label: {
                            Label(
                                Inf6Lang.text("MMA 演習を生成…", "Generate MMA exercise…"),
                                systemImage: "checklist"
                            )
                        }
                        .disabled(_microsoftKnowledgePDFDisabledReason != nil)
                    } label: {
                        Label(
                            Inf6Lang.text("知識PDF…", "Knowledge PDF…"),
                            systemImage: "wand.and.stars"
                        )
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Color.accentColor)
                    }
                    .tint(Color.accentColor)
                    .help(Inf6Lang.text(
                        "Microsoft Learn を基に現行知識PDFを生成します",
                        "Generate a current knowledge PDF from Microsoft Learn"
                    ))
                }
                #endif
            }

            // G検定: toolbar aligned with E資格 (icon-only menus)
            if isGkenteiCourse {
                #if os(iOS)
                ToolbarItemGroup(placement: .topBarTrailing) {

                    // Import / List (icon-only menu)
                    Menu {
                        Text(Inf6Lang.text("PDF取り込みは 1 件のみ対応です。", "PDF import supports 1 item only."))
                        Button {
                            if isGeneratingExplanationPDF {
                                let msg = Inf6Lang.text(
                                    "生成中は取り込めません。処理が完了してから再度実行してください。",
                                    "You can't import while generation is running. Please wait until it finishes, then try again."
                                )
                                explanationPDFStatus = msg
                                explanationPDFErrorAlertMessage = msg
                                showExplanationPDFErrorAlert = true
                                return
                            }

                            // Ensure any overlay does not stay on top of this view.
                            showEshikakuPaperSearchSheet = false
                            showEshikakuPaperSearchFullScreen = false

                            let targetFolder: URL? = {
                                if let u = gkenteiFolderURL { return u }
                                if let restored = try? loadPersistedGkenteiExplanationPDFFolder() { return restored }
                                return nil
                            }()

                            NotificationCenter.default.post(
                                name: .inf6RequestLibraryImportPicker,
                                object: targetFolder
                            )

                            explanationPDFStatus = Inf6Lang.text(
                                "ライブラリのPDF取り込みを開くよう要求しました。",
                                "Requested the Library to open the PDF import picker."
                            )
                        } label: {
                            Label(
                                Inf6Lang.text("保存先から取り込む…", "Import from destination…"),
                                systemImage: "tray.and.arrow.down"
                            )
                        }
                    } label: {
                        Label(
                            Inf6Lang.text("開く…", "Open…"),
                            systemImage: "tray.and.arrow.down"
                        )
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Color.blue)
                    }
                    .tint(Color.blue)
                    .help(Inf6Lang.text("保存先フォルダを初期位置にしてPDF取り込みを開きます", "Open PDF import starting from the destination folder"))
                    .disabled(isGeneratingExplanationPDF)

                    if isGeneratingExplanationPDF {
                        ProgressView().tint(.pink).scaleEffect(1.25)
                    } else {
                        // Generate (icon-only menu)
                        Menu {
                            if let r = _gkenteiExplanationPDFDisabledReason {
                                Text(r)
                            }

                            Button {
                                generateGkenteiExplanationPDF()
                            } label: {
                                Label(
                                    Inf6Lang.text("G検定解説PDFを生成…", "Generate…"),
                                    systemImage: "wand.and.stars"
                                )
                            }
                            .disabled(_gkenteiExplanationPDFDisabledReason != nil)

                            Divider()

                            Button {
                                generateMMAQuizJDLA()
                            } label: {
                                Label(
                                    Inf6Lang.text("MMA 演習を生成…", "Generate MMA exercise…"),
                                    systemImage: "checklist"
                                )
                            }
                            .disabled(_gkenteiExplanationPDFDisabledReason != nil)
                        } label: {
                            Label(
                                Inf6Lang.text("解説PDF…", "Explanation…"),
                                systemImage: "wand.and.stars"
                            )
                            .labelStyle(.iconOnly)
                            .foregroundStyle(Color.accentColor)
                        }
                        .tint(Color.accentColor)
                        .help(Inf6Lang.text(
                            "解説PDFを生成します",
                            "Generate the explanation PDF"
                        ))
                    }
                }
                #else
                #endif
            }
        }
    }

    @ViewBuilder
    var mainContent: some View {
        if isMicrosoftLearnKnowledgeCourse {
            coreListContent
                .onAppear {
                    do {
                        microsoftKnowledgePDFFolderURL = try _microsoftKnowledgePDFDirectoryURLOrThrow()
                        microsoftKnowledgePDFFolderStatus = ""
                    } catch {
                        let msg = Inf6Lang.text(
                            "shared root の解決に失敗しました: \(error.localizedDescription)",
                            "Failed to resolve the shared root: \(error.localizedDescription)"
                        )
                        microsoftKnowledgePDFFolderURL = nil
                        microsoftKnowledgePDFFolderStatus = msg
                        explanationPDFErrorAlertMessage = msg
                        showExplanationPDFErrorAlert = true
                    }
                }
        } else if isGkenteiCourse {
            applyGkenteiExplanationPDFFolderPicker(
                applyGkenteiPDFImporter(coreListContent)
                    .onAppear {
                        do {
                            if let restored = try loadPersistedGkenteiExplanationPDFFolder() {
                                gkenteiFolderURL = restored
                            }
                        } catch {
                            let msg = Inf6Lang.text(
                                "保存済み解説PDF保存先フォルダの復元に失敗しました: \(error.localizedDescription)",
                                "Failed to restore the persisted explanation PDF destination folder: \(error.localizedDescription)"
                            )
                            gkenteiFolderStatus = msg
                            explanationPDFErrorAlertMessage = msg
                            showExplanationPDFErrorAlert = true
                        }
                    }
            )
        } else {
            coreListContent
        }
    }

    @ViewBuilder
    var arxivPubMedToolsSection: some View {
        Section {
            microsoftKnowledgeBlock
            gkenteiExplanationBlock
            eshikakuExplanationBlock
        } header: {
            if isMicrosoftLearnKnowledgeCourse {
                Text(Inf6Lang.text("Microsoft", "Microsoft"))
            } else if isGkenteiCourse {
                Text(Inf6Lang.text("G検定", "G Test"))
            } else if isEshikakuCourse {
                Text(Inf6Lang.text("E資格", "E Qualification"))
            } else {
                EmptyView()
            }
        }
    }

    @ViewBuilder
    var courseOverviewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(displayTitle)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
            }
        } header: {
            Text(Inf6Lang.text("コース概要", "Course Overview"))
        }
    }

    @ViewBuilder
    var microsoftLearnSourcesSection: some View {
        Section {
            let defs = (try? microsoftLearnSourceDefinitionsOrThrow()) ?? []
            if defs.isEmpty {
                Text(Inf6Lang.text("Microsoft Learn のソース定義がありません。", "No Microsoft Learn source definitions are available."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(defs, id: \.id) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.headline)
                        Text(item.roleHint.labelJa)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item.urlString)
                            .font(.caption2)
                            .foregroundStyle(.blue)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text(Inf6Lang.text("Microsoft Learn ソース", "Microsoft Learn sources"))
        } footer: {
            Text(Inf6Lang.text(
                "AI-102 では wrapper / current / legacy_detail を分けて収集し、sources JSON に判定根拠を残します。",
                "AI-102 collects wrapper, current, and legacy_detail sources separately and records the evidence in sources JSON."
            ))
        }
    }

    @ViewBuilder
    func officialSiteSection(officialHomeURL: URL) -> some View {
        let checker = Inf6SyllabusUpdateChecker.shared
        let examName = _resolvedExamScheduleName()

        Group {
            // ① 試験日程カード (LLM 解析)
            if let examName {
                examScheduleSection(checker: checker, examName: examName)
            }

            // ② 公式 PDF / シラバス選択
            Section {
                officialSiteUpdateCheckerRow(officialHomeURL: officialHomeURL, checker: checker)
                officialSiteSectionContent
            } header: {
                Text(Inf6Lang.text("公式サイト", "Official site"))
            }
        }
        .onAppear {
            if !didAutoStartSyllabusPDFPipeline,
               syllabus.code.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                didAutoStartSyllabusPDFPipeline = true
                discoverOfficialPDFs(from: officialHomeURL)
            }
            // PDF 更新チェック（最終確認から一定期間経過していれば）
            checker.checkForUpdatesIfNeeded(officialURL: officialHomeURL)
            // 試験日程 LLM チェック（同様に期間経過時のみ）
            if let examName {
                checker.fetchExamScheduleIfNeeded(examName: examName)
            }
        }
    }

    func _resolvedExamScheduleName() -> String? {
        let dept = syllabus.department.trimmingCharacters(in: .whitespacesAndNewlines)
        if dept == "E資格" || dept == "G検定" {
            return dept
        }
        let title = syllabus.title.lowercased()
        if title.contains("e資格") || title.contains("e-cert") {
            return "E資格"
        }
        if title.contains("g検定") || title.contains("g-test") {
            return "G検定"
        }
        return nil
    }

    func _preferredSyllabusPDFItem(
        in items: [Inf6SyllabusPDFItem],
        scheduleInfo: Inf6ExamScheduleInfo
    ) -> Inf6SyllabusPDFItem? {
        guard !items.isEmpty else { return nil }
        let idToken = scheduleInfo.applicableSyllabusId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let versionToken = scheduleInfo.applicableSyllabusVersion
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        func haystack(for item: Inf6SyllabusPDFItem) -> String {
            [
                item.title,
                item.sourceURL.lastPathComponent,
                item.localURL.lastPathComponent
            ]
            .joined(separator: " ")
            .lowercased()
        }

        if !idToken.isEmpty,
           let match = items.first(where: { haystack(for: $0).contains(idToken) }) {
            return match
        }
        if !versionToken.isEmpty,
           let match = items.first(where: { haystack(for: $0).contains(versionToken) }) {
            return match
        }
        return nil
    }

    @MainActor
    private func _applyApplicableSyllabusSelectionIfPossible(_ info: Inf6ExamScheduleInfo) {
        guard let preferred = _preferredSyllabusPDFItem(in: syllabusPDFItems, scheduleInfo: info) else { return }
        guard selectedSyllabusPDFID != preferred.id else { return }
        selectSyllabusPDFItem(preferred)
    }

    /// 次回試験日程・適用シラバスカード
    @ViewBuilder
    func examScheduleSection(checker: Inf6SyllabusUpdateChecker, examName: String) -> some View {
        Section {
            if checker.isCheckingExamSchedule(for: examName) {
                HStack(spacing: 10) {
                    ProgressView().tint(.pink).scaleEffect(1.25)
                    Text(Inf6Lang.text("AI が調査中…", "AI checking…"))
                        .font(.body)
                        .foregroundStyle(Color.secondary)
                }
                .padding(.vertical, 6)
            } else if let info = checker.examScheduleInfo(for: examName) {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(info.nextExamId)
                            .font(.title2.bold())
                        Text(info.nextExamDate)
                            .font(.title3)
                            .foregroundStyle(Color.secondary)
                        if let days = info.daysUntilStart() {
                            Text(
                                days >= 0
                                ? Inf6Lang.text("あと\(days)日", "\(days) days left")
                                : Inf6Lang.text("\(abs(days))日前に開始", "started \(abs(days)) days ago")
                            )
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(days >= 30 ? .green : (days >= 7 ? .orange : .red))
                        }
                        Text(Inf6Lang.text("シラバス \(info.applicableSyllabusVersion)版", "Syllabus \(info.applicableSyllabusVersion)"))
                            .font(.body)
                            .foregroundStyle(Color.accentColor)
                        if info.publishedSyllabusId.localizedCaseInsensitiveCompare(info.applicableSyllabusId) != .orderedSame {
                            Text(
                                Inf6Lang.text(
                                    "公開最新版: \(info.publishedSyllabusVersion) / 次回適用: \(info.applicableSyllabusVersion)",
                                    "Published latest: \(info.publishedSyllabusVersion) / next exam: \(info.applicableSyllabusVersion)"
                                )
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                        if !info.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(info.notes)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !info.sourceURLs.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Inf6Lang.text("根拠", "Evidence"))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(info.sourceURLs, id: \.self) { urlString in
                                    Button {
                                        guard let url = URL(string: urlString) else { return }
                                        UIApplication.shared.open(url)
                                    } label: {
                                        Text(urlString)
                                            .font(.caption)
                                            .foregroundStyle(.blue)
                                            .multilineTextAlignment(.leading)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    Spacer()
                    Button {
                        checker.forceFetchExamSchedule(examName: examName)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.title3)
                            .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 6)
                .task(id: "\(info.applicableSyllabusId)|\(info.applicableSyllabusVersion)|\(syllabusPDFItems.count)") {
                    _applyApplicableSyllabusSelectionIfPossible(info)
                }
            } else {
                HStack {
                    Text(Inf6Lang.text("未取得", "Not fetched"))
                        .font(.body)
                        .foregroundStyle(Color.secondary)
                    Spacer()
                    Button {
                        checker.forceFetchExamSchedule(examName: examName)
                    } label: {
                        Label(Inf6Lang.text("AI で調査", "Check via AI"), systemImage: "sparkle")
                            .font(.body)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 6)

                if let err = checker.examScheduleError(for: examName) {
                    Text(err)
                        .font(.subheadline)
                        .foregroundStyle(Color.red)
                }
            }
        } header: {
            Text(Inf6Lang.text("次回試験日程", "Next Exam"))
        }
    }


    /// シラバス更新チェックのステータス行
    @ViewBuilder
    func officialSiteUpdateCheckerRow(officialHomeURL: URL, checker: Inf6SyllabusUpdateChecker) -> some View {
        let isChecking = checker.isChecking(for: officialHomeURL)
        let hasUpdate  = checker.hasUpdate(for: officialHomeURL)
        let lastDate   = checker.lastChecked(for: officialHomeURL)

        HStack(spacing: 10) {
            if isChecking {
                ProgressView().tint(.pink).scaleEffect(1.25).scaleEffect(0.9)
            } else if hasUpdate {
                Image(systemName: "sparkles").foregroundStyle(Color.orange)
            }

            if hasUpdate {
                Button {
                    checker.dismissUpdate(for: officialHomeURL)
                    bypassDiscoveryCache = true
                    didAutoStartSyllabusPDFPipeline = false
                    discoverOfficialPDFs(from: officialHomeURL)
                } label: {
                    Text(Inf6Lang.text("新しいシラバスに更新", "Update syllabus"))
                        .font(.body.bold())
                        .foregroundStyle(Color.orange)
                }
                .buttonStyle(.plain)
            } else if let d = lastDate {
                Text(Inf6Lang.text(
                    "確認済: \(Inf6SyllabusUpdateChecker.relativeString(from: d))",
                    "Checked: \(Inf6SyllabusUpdateChecker.relativeString(from: d))"
                ))
                .font(.body)
                .foregroundStyle(Color.secondary)
            }

            Spacer()

            if !isChecking {
                Button {
                    checker.forceCheck(officialURL: officialHomeURL)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.body)
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    var officialSiteSectionContent: some View {
        if isDiscoveringOfficialPDFs {
            HStack {
                Spacer()
                ProgressView().tint(.pink).scaleEffect(1.25)
                Spacer()
            }
            .padding(.vertical, 4)
        }

        if !officialPDFStatus.isEmpty {
            Text(officialPDFStatus)
                .font(.caption)
                .foregroundStyle(Color.blue)
        }

        if !syllabusPDFItems.isEmpty {
            let examName = _resolvedExamScheduleName()
            let scheduleInfo = examName.flatMap { Inf6SyllabusUpdateChecker.shared.examScheduleInfo(for: $0) }
            let preferredID = scheduleInfo.flatMap { _preferredSyllabusPDFItem(in: syllabusPDFItems, scheduleInfo: $0)?.id }
            // 適用シラバスが判明している場合、それだけ表示。旧版は非表示。
            let visibleItems: [Inf6SyllabusPDFItem] = {
                if let pid = preferredID {
                    return syllabusPDFItems.filter { $0.id == pid }
                }
                return syllabusPDFItems
            }()
            VStack(alignment: .leading, spacing: 6) {
                ForEach(visibleItems) { item in
                    Button {
                        selectSyllabusPDFItem(item)
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.body)
                                    .lineLimit(6)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(Inf6Lang.text("\(item.pageCount)ページ", "\(item.pageCount) pages"))
                                    .font(.caption)
                                    .foregroundStyle(Color.blue)
                            }
                            Spacer()
                            Image(systemName: (selectedSyllabusPDFID == item.id) ? "checkmark.circle.fill" : "circle")
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)
        }

        if isPreparingSyllabusPDFs || isExtractingSyllabusText {
            ProgressView().tint(.pink).scaleEffect(1.25)
                .padding(.top, 2)
        }

        if isGeneratingSyllabusOutline {
            HStack {
                ProgressView().tint(.pink).scaleEffect(1.25)
                Text(Inf6Lang.text("シラバス一覧を生成中…", "Generating syllabus outline…"))
                    .font(.caption)
                    .foregroundStyle(Color.blue)
            }
            .padding(.top, 2)
        }

        if !syllabusOutlineStatus.isEmpty {
            Text(syllabusOutlineStatus)
                .font(.caption)
                .foregroundStyle(Color.blue)
        }

        EmptyView()
    }

    var _knowledgeStructureManifest: Inf6LearningFamilyManifest? {
        resolvedLearningFamilyManifest
    }

    private var _selectedSyllabusPDFItem: Inf6SyllabusPDFItem? {
        guard let sid = selectedSyllabusPDFID else { return nil }
        return syllabusPDFItems.first(where: { $0.id == sid })
    }

    private var _currentKnowledgeStructureVersionID: String {
        if let examName = _resolvedExamScheduleName(),
           let info = Inf6SyllabusUpdateChecker.shared.examScheduleInfo(for: examName) {
            let versionID = info.preferredKnowledgeStructureID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !versionID.isEmpty { return versionID }
        }

        if let selected = _selectedSyllabusPDFItem {
            let title = selected.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                return title
            }
        }

        let title = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }
        return syllabus.id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var _knowledgeStructureReloadKey: String {
        let manifestID = _knowledgeStructureManifest?.sourceFamily ?? "no-domain"
        let versionID = _currentKnowledgeStructureVersionID
        let outlineCount = syllabusOutlineItems.count
        let selectedPDF = selectedSyllabusPDFID?.uuidString ?? "no-pdf"
        let livePaperState = "\(Inf6CorePaperStore.shared.totalCount)|\(Inf6CorePaperStore.shared.doneCount)|\(Inf6CorePaperStore.shared.readingCount)"
        return [manifestID, versionID, String(outlineCount), selectedPDF, livePaperState].joined(separator: "|")
    }

    @MainActor
    private func _loadKnowledgeDomainStructureIfPossible() {
        guard let manifest = _knowledgeStructureManifest else {
            knowledgeDomainStructure = nil
            knowledgeDomainStructureError = ""
            return
        }

        let outlineItems = syllabusOutlineItems
        let paperStore: Inf6CorePaperStore? = Inf6CorePaperStore.shared

        if paperStore == nil && outlineItems.isEmpty {
            knowledgeDomainStructure = nil
            knowledgeDomainStructureError = ""
            return
        }

        do {
            let loaded = try Inf6KnowledgeDomainStructureStore.loadOrSeed(
                manifest: manifest,
                syllabusVersionID: _currentKnowledgeStructureVersionID,
                domainTitleJa: displayTitle,
                outlineItems: outlineItems,
                paperStore: paperStore
            )
            knowledgeDomainStructure = _hydratedKnowledgeDomainStructure(loaded, manifest: manifest)
            knowledgeDomainStructureError = ""
        } catch {
            knowledgeDomainStructure = nil
            knowledgeDomainStructureError = error.localizedDescription
        }
    }

    private func _hydratedKnowledgeDomainStructure(
        _ structure: Inf6KnowledgeDomainStructure,
        manifest: Inf6LearningFamilyManifest
    ) -> Inf6KnowledgeDomainStructure {
        guard manifest.supportsPaperSearchProviders else {
            return structure
        }

        let store = Inf6CorePaperStore.shared
        let liveAchievementsByPaperID = store.achievementByPaperID
        let liveAchievements: [String: Inf6KnowledgeAchievementState] = Dictionary(
            uniqueKeysWithValues: store.papers.map { paper in
                let achievement = liveAchievementsByPaperID[paper.id] ?? .notStarted
                return (paper.id, achievement)
            }
        )

        let liveKnowledgeCounts: [String: Int] = Dictionary(
            uniqueKeysWithValues: store.papers.map { paper in
                (paper.id, store.progress[paper.id]?.masteryScore ?? 0)
            }
        )

        let hydratedPapers = structure.papers.map { paper -> Inf6KnowledgePaperLink in
            var copy = paper
            if let achievement = liveAchievements[paper.paperID] {
                copy.achievement = achievement
            }
            if let knowledgeCount = liveKnowledgeCounts[paper.paperID] {
                copy.knowledgeCount = knowledgeCount
            }
            return copy
        }

        let achievementByPaperID = Dictionary(uniqueKeysWithValues: hydratedPapers.map { ($0.paperID, $0.achievement) })

        let hydratedNodes = structure.nodes.map { node -> Inf6KnowledgeNode in
            guard !node.linkedPaperIDs.isEmpty else { return node }
            var copy = node
            copy.paperCount = node.linkedPaperIDs.count
            copy.achievement = _aggregateAchievement(for: node.linkedPaperIDs, achievements: achievementByPaperID)
            return copy
        }

        return Inf6KnowledgeDomainStructure(
            domainID: structure.domainID,
            syllabusVersionID: structure.syllabusVersionID,
            nodes: hydratedNodes,
            papers: hydratedPapers,
            edges: structure.edges
        )
    }

    private func _achievementState(from status: Inf6CorePaperStatus) -> Inf6KnowledgeAchievementState {
        switch status {
        case .notStarted:
            return .notStarted
        case .reading:
            return .reading
        case .done:
            return .measured
        }
    }

    private func _aggregateAchievement(
        for paperIDs: [String],
        achievements: [String: Inf6KnowledgeAchievementState]
    ) -> Inf6KnowledgeAchievementState {
        guard !paperIDs.isEmpty else { return .notStarted }
        let states = paperIDs.compactMap { achievements[$0] }
        guard !states.isEmpty else { return .notStarted }
        let avg = states.map { _hydratedAchievementFraction($0) }.reduce(0, +) / Double(states.count)
        if avg >= 0.95 { return .measured }
        if avg >= 0.74 { return .questioned }
        if avg >= 0.58 { return .explained }
        if avg >= 0.42 { return .annotating }
        if avg >= 0.24 { return .reading }
        if avg > 0 { return .collecting }
        return .notStarted
    }

    private func _hydratedAchievementFraction(_ achievement: Inf6KnowledgeAchievementState) -> Double {
        switch achievement {
        case .notStarted: return 0
        case .collecting: return 0.16
        case .reading: return 0.34
        case .annotating: return 0.50
        case .explained: return 0.66
        case .questioned: return 0.82
        case .measured: return 1.0
        }
    }

    private var _knowledgeSelectableNodeIDs: Set<String> {
        Set(syllabusOutlineItems.map(\.key))
    }

    private var _knowledgeSelectedNodeIDs: Set<String> {
        selectedOutlineKeys
    }

    @ViewBuilder
    var knowledgeStructureSection: some View {
        Section {
            if !knowledgeDomainStructureError.isEmpty {
                Text(knowledgeDomainStructureError)
                    .font(.body)
                    .foregroundStyle(Color.red)
            } else if let structure = knowledgeDomainStructure,
                      let manifest = _knowledgeStructureManifest {
                Inf6KnowledgeStructureTreeView(
                    structure: structure,
                    accentColor: _knowledgeStructureAccentColor(manifest),
                    selectableNodeIDs: _knowledgeSelectableNodeIDs,
                    selectedNodeIDs: _knowledgeSelectedNodeIDs,
                    expandedNodeIDs: $expandedKnowledgeNodeIDs,
                    onToggleSelection: { nodeID in
                        toggleOutlineSelection(nodeID)
                    }
                )
            }
        }
    }

    private func _knowledgeStructureAccentColor(_ manifest: Inf6LearningFamilyManifest) -> Color {
        let trimmed = manifest.accentColorHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return .accentColor }
        let raw = String(trimmed.dropFirst())
        guard raw.count == 6, let value = UInt64(raw, radix: 16) else { return .accentColor }
        let red = Double((value & 0xFF0000) >> 16) / 255.0
        let green = Double((value & 0x00FF00) >> 8) / 255.0
        let blue = Double(value & 0x0000FF) / 255.0
        return Color(red: red, green: green, blue: blue)
    }

    @ViewBuilder
    var syllabusOutlineBlock: some View {
        if !syllabusOutlineItems.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(Inf6Lang.text("シラバス大項目", "Syllabus sections"))
                    .font(.headline)
                    .padding(.top, 6)

                _syllabusOutlineOverallProgressCard

                ForEach(_outlineDashboardSections) { section in
                    _syllabusOutlineSectionCard(section)
                }

                Text(Inf6Lang.text(
                    "選択進捗は、この画面で整理対象として選んだ論点数です。構造重要度は階層と論点数から算出します。論文接続が無い資格では、論文数は表示しません。",
                    "Selection progress counts the topics selected on this screen. Structural importance is derived from hierarchy and topic count. Paper counts are shown only when the family is connected to papers."
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
            .padding(.top, 4)
        }
    }

    private var _outlineDashboardSections: [_Inf6OutlineDashboardSection] {
        let items = syllabusOutlineItems
        guard !items.isEmpty else { return [] }

        let topLevelIndices = items.enumerated().compactMap { idx, item in
            item.effectiveDepth == 0 ? idx : nil
        }

        if topLevelIndices.isEmpty {
            return items.map { item in
                _Inf6OutlineDashboardSection(root: item, items: [item])
            }
        }

        var sections: [_Inf6OutlineDashboardSection] = []
        for (offset, startIndex) in topLevelIndices.enumerated() {
            let endIndex = (offset + 1 < topLevelIndices.count) ? topLevelIndices[offset + 1] : items.count
            let sectionItems = Array(items[startIndex..<endIndex])
            guard let root = sectionItems.first else { continue }
            sections.append(_Inf6OutlineDashboardSection(root: root, items: sectionItems))
        }
        return sections
    }

    private var _outlineSelectedCount: Int {
        syllabusOutlineItems.filter { selectedOutlineKeys.contains($0.key) }.count
    }

    private var _outlineSelectionFraction: Double {
        let total = syllabusOutlineItems.count
        guard total > 0 else { return 0 }
        return Double(_outlineSelectedCount) / Double(total)
    }

    private var _supportsPaperLinkedSyllabusMetrics: Bool {
        isEshikakuCourse
    }

    @ViewBuilder
    private var _syllabusOutlineOverallProgressCard: some View {
        HStack(alignment: .center, spacing: 14) {
            _outlineRingGauge(
                fraction: _outlineSelectionFraction,
                size: 58,
                lineWidth: 7,
                color: _outlineProgressColor(_outlineSelectionFraction)
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(Inf6Lang.text("全体の選択進捗", "Overall selection progress"))
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    Text("\(_outlineSelectedCount) / \(syllabusOutlineItems.count)")
                        .font(.subheadline.monospacedDigit())
                    Text(Inf6Lang.text("論点", "topics"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.12))
                        Capsule()
                            .fill(_outlineProgressColor(_outlineSelectionFraction))
                            .frame(width: geo.size.width * _outlineSelectionFraction)
                    }
                }
                .frame(height: 7)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(Int(_outlineSelectionFraction * 100))%")
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(_outlineProgressColor(_outlineSelectionFraction))
                Text(Inf6Lang.text("整理済み", "selected"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.accentColor.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func _syllabusOutlineSectionCard(_ section: _Inf6OutlineDashboardSection) -> some View {
        let isExpanded = expandedOutlineSectionKeys.contains(section.id)
        let selectedCount = section.items.filter { selectedOutlineKeys.contains($0.key) }.count
        let fraction = section.selectableCount > 0 ? Double(selectedCount) / Double(section.selectableCount) : 0
        let importance = _outlineImportance(for: section)
        let allSelected = selectedCount == section.selectableCount && section.selectableCount > 0

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)

                    if let summary = section.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        _toggleOutlineSectionSelection(section)
                    }
                } label: {
                    Text(allSelected
                         ? Inf6Lang.text("選択解除", "Clear")
                         : Inf6Lang.text("まとめて選択", "Select all"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(allSelected ? Color.orange : Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background((allSelected ? Color.orange : Color.accentColor).opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                _outlineMetricChip(
                    title: Inf6Lang.text("論点数", "Topics"),
                    value: "\(section.selectableCount)",
                    color: .blue
                )
                _outlineMetricChip(
                    title: Inf6Lang.text("選択進捗", "Progress"),
                    value: "\(selectedCount)/\(section.selectableCount)",
                    color: _outlineProgressColor(fraction)
                )
                _outlineMetricChip(
                    title: Inf6Lang.text("構造重要度", "Structural importance"),
                    value: importance.label,
                    color: importance.color
                )
                if _supportsPaperLinkedSyllabusMetrics {
                    _outlineMetricChip(
                        title: Inf6Lang.text("関連論文", "Papers"),
                        value: Inf6Lang.text("未接続", "Unlinked"),
                        color: .secondary
                    )
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.12))
                    Capsule()
                        .fill(_outlineProgressColor(fraction))
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 8)

            Button {
                withAnimation(.spring(duration: 0.22)) {
                    if isExpanded {
                        expandedOutlineSectionKeys.remove(section.id)
                    } else {
                        expandedOutlineSectionKeys.insert(section.id)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(isExpanded
                         ? Inf6Lang.text("論点を閉じる", "Hide topics")
                         : Inf6Lang.text("論点を開く", "Show topics"))
                        .font(.caption.weight(.semibold))
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(section.items) { item in
                        _outlineSelectableRow(item)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(importance.color.opacity(0.18), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func _outlineSelectableRow(_ item: Inf6SyllabusOutlineItem) -> some View {
        let isSelected = selectedOutlineKeys.contains(item.key)

        Button {
            toggleOutlineSelection(item.key)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(18), weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 22, height: 22, alignment: .top)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayTitle)
                        .font(item.effectiveDepth == 0 ? .subheadline.weight(.semibold) : .subheadline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if let summary = item.displaySummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, CGFloat(item.effectiveDepth) * 12)

                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func _toggleOutlineSectionSelection(_ section: _Inf6OutlineDashboardSection) {
        let keys = Set(section.items.map(\.key))
        let selectedCount = keys.intersection(selectedOutlineKeys).count
        if selectedCount == keys.count {
            selectedOutlineKeys.subtract(keys)
        } else {
            selectedOutlineKeys.formUnion(keys)
        }
    }

    private func _outlineImportance(for section: _Inf6OutlineDashboardSection) -> (label: String, color: Color) {
        let count = section.selectableCount
        if count >= 6 {
            return (Inf6Lang.text("高", "High"), .red)
        }
        if count >= 3 {
            return (Inf6Lang.text("中", "Medium"), .orange)
        }
        return (Inf6Lang.text("低", "Low"), .blue)
    }

    @ViewBuilder
    private func _outlineMetricChip(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func _outlineRingGauge(fraction: Double, size: CGFloat, lineWidth: CGFloat, color: Color) -> some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(fraction * 100))%")
                .font(.system(size: size * 0.22, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }

    private func _outlineProgressColor(_ fraction: Double) -> Color {
        if fraction >= 0.8 { return .green }
        if fraction >= 0.4 { return .orange }
        return .blue
    }

    // MARK: - Microsoft: generate knowledge PDF

    @MainActor
    func generateMicrosoftLearnKnowledgePDF() {
        Task { @MainActor in
            do {
                try await _generateMicrosoftLearnKnowledgePDFOrThrow()
            } catch {
                let msg = Inf6Lang.text(
                    "Microsoft 知識PDFの生成に失敗しました: \(error)",
                    "Failed to generate the Microsoft knowledge PDF: \(error)"
                )
                microsoftKnowledgePDFStatus = msg
                explanationPDFErrorAlertMessage = msg
                showExplanationPDFErrorAlert = true
                isGeneratingMicrosoftKnowledgePDF = false
            }
        }
    }

    @MainActor
    private func _generateMicrosoftLearnKnowledgePDFOrThrow() async throws {
        if isGeneratingMicrosoftKnowledgePDF {
            throw NSError(domain: "Inf6MicrosoftLearn", code: 20, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "現在、知識PDFを生成中です。完了後に再度実行してください。",
                    "A knowledge PDF is being generated. Please try again after it finishes."
                )
            ])
        }

        let definitions = try microsoftLearnSourceDefinitionsOrThrow()
        let destFolder = try _microsoftKnowledgePDFDirectoryURLOrThrow()
        microsoftKnowledgePDFFolderURL = destFolder

        let apiKey = try loadOpenAIAPIKeyOrThrowForRequests()

        isGeneratingMicrosoftKnowledgePDF = true
        microsoftKnowledgePDFStatus = Inf6Lang.text("Microsoft Learn を収集中…", "Collecting Microsoft Learn sources…")
        defer { isGeneratingMicrosoftKnowledgePDF = false }

        let sources = try await fetchMicrosoftLearnSourcesOrThrow(definitions: definitions)
        microsoftKnowledgePDFStatus = Inf6Lang.text("Microsoft Learn から知識本文を再構成中…", "Rebuilding knowledge content from Microsoft Learn…")

        let htmlFragment = try await generateMicrosoftLearnKnowledgeHTMLFragmentViaGPT(
            apiKey: apiKey,
            qualificationTitle: displayTitle,
            sources: sources
        )

        let docTitle = "\(displayTitle) 現行知識集"
        let pdfData = try await renderMicrosoftLearnKnowledgePDFDataViaWebKit(
            title: docTitle,
            bodyHTMLFragment: htmlFragment
        )

        let baseName = _microsoftKnowledgePDFFilenameBase()
        let destPDFURL = destFolder.appendingPathComponent(baseName).appendingPathExtension("pdf")
        let destSourcesURL = destFolder.appendingPathComponent(baseName).appendingPathExtension("sources.json")

        try pdfData.write(to: destPDFURL, options: [.atomic])

        let sidecar = Inf6MicrosoftLearnSourcesSidecar(
            qualificationID: syllabus.id,
            qualificationTitle: displayTitle,
            checkedAt: ISO8601DateFormatter().string(from: Date()),
            sources: sources
        )
        let sidecarData = try JSONEncoder().encode(sidecar)
        try sidecarData.write(to: destSourcesURL, options: [.atomic])

        generatedMicrosoftKnowledgePDFURL = destPDFURL
        microsoftKnowledgePDFStatus = Inf6Lang.text(
            "知識PDFを生成しました。sources JSON も保存しました。",
            "Generated the knowledge PDF and saved the sources JSON."
        )
    }

    private func _microsoftKnowledgePDFFilenameBase() -> String {
        let base = _sanitizePathComponent(displayTitle.isEmpty ? syllabus.id : displayTitle)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = formatter.string(from: Date())
        return "\(base)_microsoftlearn_current_\(stamp)"
    }

    // MARK: - MMA: 経脈マスタリー作問（Microsoft Learn）

    @MainActor
    func generateMMAQuizMicrosoftLearn() {
        Task { @MainActor in
            do {
                try await _generateMMAQuizMicrosoftLearnOrThrow()
            } catch {
                let msg = Inf6Lang.text(
                    "MMA 演習生成に失敗しました: \(error)",
                    "MMA quiz generation failed: \(error)"
                )
                microsoftKnowledgePDFStatus = msg
                explanationPDFErrorAlertMessage = msg
                showExplanationPDFErrorAlert = true
                isGeneratingMicrosoftKnowledgePDF = false
            }
        }
    }

    @MainActor
    private func _generateMMAQuizMicrosoftLearnOrThrow() async throws {
        if isGeneratingMicrosoftKnowledgePDF {
            throw NSError(domain: "Inf6MMA", code: 30, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "現在、生成処理中です。完了後に再度実行してください。",
                    "Generation is in progress. Please try again after it finishes."
                )
            ])
        }

        let definitions = try microsoftLearnSourceDefinitionsOrThrow()
        let apiKey = try loadOpenAIAPIKeyOrThrowForRequests()
        let model  = Inf6Lang.text("gpt-4o", "gpt-4o")
        let client = OpenAIClient(
            apiKey: apiKey,
            config: try OpenAIClient.Config.default(model: model)
        )

        isGeneratingMicrosoftKnowledgePDF = true
        microsoftKnowledgePDFStatus = Inf6Lang.text(
            "Microsoft Learn を収集中 (MMA)…",
            "Collecting Microsoft Learn sources (MMA)…"
        )
        defer { isGeneratingMicrosoftKnowledgePDF = false }

        let sources = try await fetchMicrosoftLearnSourcesOrThrow(definitions: definitions)

        let moduleTexts: [(url: String, text: String)] = sources.map {
            (url: $0.finalURL, text: $0.excerpt)
        }

        microsoftKnowledgePDFStatus = Inf6Lang.text(
            "シラバス骨格化 + コアナレッジ判定中…",
            "Skeletonizing syllabus + resolving core knowledge…"
        )

        let result = try await Inf6MMAFullPipeline.runMicrosoftLearn(
            moduleTexts: moduleTexts,
            qualificationId: syllabus.id,
            qualificationTitle: displayTitle,
            goal: "\(displayTitle) 合格",
            questionCount: 30,
            lang: Inf6Lang.isJapanese ? "ja" : "en",
            client: client
        )

        microsoftKnowledgePDFStatus = Inf6Lang.text(
            "MMA 演習生成完了: \(result.questions.count) 問（sharedRoot/mma/\(syllabus.id)/quiz.json に保存）",
            "MMA quiz generated: \(result.questions.count) questions saved to sharedRoot/mma/\(syllabus.id)/quiz.json"
        )
        showMMAQuizPlayerSheet = true
    }

    // MARK: - MMA: 経脈マスタリー作問（JDLA G検定）

    @MainActor
    func generateMMAQuizJDLA() {
        Task { @MainActor in
            do {
                try await _generateMMAQuizJDLAOrThrow()
            } catch {
                let msg = Inf6Lang.text(
                    "MMA 演習生成（JDLA）に失敗しました: \(error)",
                    "MMA quiz generation (JDLA) failed: \(error)"
                )
                explanationPDFStatus = msg
                explanationPDFErrorAlertMessage = msg
                showExplanationPDFErrorAlert = true
                isGeneratingExplanationPDF = false
            }
        }
    }

    @MainActor
    private func _generateMMAQuizJDLAOrThrow() async throws {
        if isGeneratingExplanationPDF {
            throw NSError(domain: "Inf6MMA", code: 31, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "生成処理中です。完了後に再度実行してください。",
                    "Generation is in progress. Please try again after it finishes."
                )
            ])
        }

        let text = syllabusExtractedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw NSError(domain: "Inf6MMA", code: 32, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "シラバステキストが抽出されていません。シラバス PDF を先に取り込んでください。",
                    "Syllabus text is not extracted. Please import a syllabus PDF first."
                )
            ])
        }

        let apiKey = try loadOpenAIAPIKeyOrThrowForRequests()
        let model  = "gpt-4o"
        let client = OpenAIClient(
            apiKey: apiKey,
            config: try OpenAIClient.Config.default(model: model)
        )

        isGeneratingExplanationPDF = true
        explanationPDFStatus = Inf6Lang.text(
            "シラバス骨格化 + コアナレッジ判定中 (MMA)…",
            "Skeletonizing syllabus + resolving core knowledge (MMA)…"
        )
        defer { isGeneratingExplanationPDF = false }

        // ページ単位のテキストが取れないため全文を 1 ページとして渡す
        let pageTexts: [Int: String] = [0: text]

        let result = try await Inf6MMAFullPipeline.runJdla(
            pageTexts: pageTexts,
            pdfRelPath: "jdla/syllabus_pdfs/\(syllabus.id).pdf",
            qualificationId: syllabus.id,
            qualificationTitle: displayTitle,
            goal: "\(displayTitle) 合格",
            questionCount: 30,
            lang: Inf6Lang.isJapanese ? "ja" : "en",
            client: client
        )

        explanationPDFStatus = Inf6Lang.text(
            "MMA 演習生成完了: \(result.questions.count) 問（sharedRoot/mma/\(syllabus.id)/quiz.json に保存）",
            "MMA quiz generated: \(result.questions.count) questions saved to sharedRoot/mma/\(syllabus.id)/quiz.json"
        )
        showMMAQuizPlayerSheet = true
    }

    // MARK: - G検定: generate entry point (local)

    /// Entry point invoked by toolbar. If the generation pipeline is not linked into this target,
    /// we must surface a hard failure (no silent ignore).
    @MainActor
    func generateGkenteiExplanationPDF() {
        Task { @MainActor in
            do {
                try await _generateGkenteiExplanationPDFOrThrow()
            } catch {
                let msg = Inf6Lang.text(
                    "解説PDFの生成に失敗しました: \(error)",
                    "Failed to generate the explanation PDF: \(error)"
                )
                explanationPDFStatus = msg
                explanationPDFErrorAlertMessage = msg
                showExplanationPDFErrorAlert = true
                isGeneratingExplanationPDF = false
            }
        }
    }

    @MainActor
    private func _generateGkenteiExplanationPDFOrThrow() async throws {
        if isGeneratingExplanationPDF {
            throw NSError(domain: "Inf6PDF", code: 2001, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "現在、解説PDFを生成中です。完了後に再度実行してください。",
                    "An explanation PDF is being generated. Please try again after it finishes."
                )
            ])
        }

        // Hard requirements: selection must exist.
        guard !selectedOutlineKeys.isEmpty else {
            throw NSError(domain: "Inf6PDF", code: 2002, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "シラバス項目を1つ以上選択してください。",
                    "Please select at least one syllabus item."
                )
            ])
        }

        // Destination folder must be configured.
        let destFolder: URL = {
            if let u = gkenteiFolderURL { return u }
            if let restored = try? loadPersistedGkenteiExplanationPDFFolder() { return restored }
            return URL(fileURLWithPath: "")
        }()

        guard destFolder.isFileURL, !destFolder.path.isEmpty else {
            throw NSError(domain: "Inf6PDF", code: 2003, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "解説PDF保存先が未指定です。『解説PDF保存先』でフォルダを指定してください。",
                    "Explanation PDF destination is not set. Choose a folder in 'Explanation PDF destination'."
                )
            ])
        }

        #if os(iOS)
        let startedScope: Bool
        if _shouldUseSecurityScope() {
            startedScope = destFolder.startAccessingSecurityScopedResource()
            if !startedScope {
                throw NSError(domain: "Inf6PDF", code: 2016, userInfo: [
                    NSLocalizedDescriptionKey: Inf6Lang.text(
                        "解説PDF保存先フォルダへのアクセス権を取得できませんでした（セキュリティスコープ）。\n\n『解説PDF保存先』でフォルダを選び直してください。",
                        "Failed to obtain access to the destination folder (security-scoped resource).\n\nPlease re-choose the destination folder."
                    )
                ])
            }
        } else {
            startedScope = false
        }
        defer { if startedScope { destFolder.stopAccessingSecurityScopedResource() } }
        #endif

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destFolder.path, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(domain: "Inf6PDF", code: 2004, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "解説PDF保存先フォルダが見つかりません（存在しないか、フォルダではありません）。",
                    "Explanation PDF destination folder was not found (missing or not a directory)."
                )
            ])
        }

        // Extract selected items in deterministic order.
        let selectedKeySet = Set(selectedOutlineKeys)
        let itemsToExplain = syllabusOutlineItems.filter { selectedKeySet.contains($0.key) }
        guard !itemsToExplain.isEmpty else {
            throw NSError(domain: "Inf6PDF", code: 2005, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "選択されたシラバス項目が見つかりませんでした。",
                    "Failed to resolve selected syllabus items."
                )
            ])
        }

        // Resolve PDF title for traceability.
        let pdfTitle: String = {
            let sid = selectedSyllabusPDFID
            if let sid, let hit = syllabusPDFItems.first(where: { $0.id == sid }) {
                let t = hit.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
            return syllabus.title.trimmingCharacters(in: .whitespacesAndNewlines)
        }()

        let courseTitle = syllabus.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !courseTitle.isEmpty else {
            throw NSError(domain: "Inf6PDF", code: 2006, userInfo: [
                NSLocalizedDescriptionKey: "Course title is empty"
            ])
        }

        // Full text must be available.
        let fullText = syllabusExtractedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullText.isEmpty else {
            throw NSError(domain: "Inf6PDF", code: 2007, userInfo: [
                NSLocalizedDescriptionKey: Inf6Lang.text(
                    "PDF本文がまだ抽出されていません。先に本文抽出を完了してください。",
                    "PDF full-text has not been extracted yet. Complete text extraction first."
                )
            ])
        }

        isGeneratingExplanationPDF = true
        explanationPDFStatus = Inf6Lang.text("解説PDFを生成しています…", "Generating explanation PDF…")

        defer {
            isGeneratingExplanationPDF = false
        }

        // 1) Load API key
        let apiKey = try loadOpenAIAPIKeyOrThrowForRequests()

        // 2) Generate HTML fragment
        let htmlFragment = try await generateExplanationHTMLFragmentViaGPT(
            apiKey: apiKey,
            courseTitle: courseTitle,
            pdfTitle: pdfTitle,
            selectedItems: itemsToExplain,
            fullText: fullText
        )


        // 4) Render PDF via WebKit
        let docTitle = "\(pdfTitle)"
        let pdfData = try await renderExplanationPDFDataViaWebKit(
            title: docTitle,
            bodyHTMLFragment: htmlFragment
        )

        // 5) Write file (no silent overwrite)
        let nameBase = _explanationPDFFilenameBaseFromSelection().trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName0 = nameBase.isEmpty ? "gkentei_explanation" : nameBase
        let destURL = destFolder.appendingPathComponent(fileName0 + ".pdf", isDirectory: false)

        if FileManager.default.fileExists(atPath: destURL.path) {
            let decision = try await _presentExistingExplanationPDFConflictDialogOrThrow(destURL: destURL)
            switch decision {
            case .openExisting:
                try await _openExistingExplanationPDFOrThrow(destURL)
                generatedExplanationPDFURL = destURL
                explanationPDFStatus = Inf6Lang.text(
                    "既存の解説PDFを開きました。",
                    "Opened the existing explanation PDF."
                )
                return

            case .overwrite:
                try _atomicOverwriteFileOrThrow(destURL: destURL, data: pdfData)
                generatedExplanationPDFURL = destURL
                explanationPDFStatus = Inf6Lang.text(
                    "解説PDFを上書きしました。\n\n右上のボタンから書き出してください。",
                    "Overwrote the explanation PDF.\n\nExport it from the top-right button."
                )
                return

            case .cancel:
                throw NSError(domain: "Inf6PDF", code: 2009, userInfo: [
                    NSLocalizedDescriptionKey: Inf6Lang.text(
                        "ユーザーが操作をキャンセルしました。",
                        "User cancelled the operation."
                    )
                ])
            }
        }

        try pdfData.write(to: destURL, options: [.atomic])

        generatedExplanationPDFURL = destURL
        explanationPDFStatus = Inf6Lang.text(
            "解説PDFを生成しました。\n\n右上のボタンから書き出してください。",
            "Explanation PDF generated.\n\nExport it from the top-right button."
        )
    }

    @ViewBuilder
    var gkenteiExplanationBlock: some View {
        if isGkenteiCourse {
            if isGeneratingExplanationPDF {
                HStack {
                    ProgressView().tint(.pink).scaleEffect(1.25)
                    Text(Inf6Lang.text("解説PDFを生成中…", "Generating explanation PDF…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            if !explanationPDFStatus.isEmpty {
                    Text(explanationPDFStatus)
                        .font(.caption)
                        .foregroundStyle(Color.blue)

                if let u = generatedExplanationPDFURL {
                    Text(u.path)
                        .font(.caption2)
                        .foregroundStyle(Color.blue)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            } else if let r = _gkenteiExplanationPDFDisabledReason {
                Text(r)
                    .font(.caption)
                    .foregroundStyle(Color.blue)
            }

            // 保存先フォルダ行（UIとして見える場所に出す）
            gkenteiExplanationPDFFolderRow
        }
    }

}


//
//  Inf6SyllabusDetailView+ExplanationPDFRenderer.swift
//  inf6
//
//  Created by decopin on 2025/12/03.
//

//
//  Inf6SyllabusDetailView+ExplanationPDFRenderer.swift
//  inf6
//
//  “テキスト抽出に強いPDF”を生成するためのレンダラ。
//  CoreText-直描き(CTFrameDraw)は ToUnicode が欠けるPDFになり得て、PDFKitがメモリ爆発しやすい。
//  そこで WebKit の createPDF を優先して、検索/選択に強いPDFを作る。
//


extension Inf6SyllabusDetailView {

    // MARK: - Preferred renderer: WebKit createPDF

    /// WebKit でHTMLをPDF化する（検索/選択に強いPDFになりやすい）。
    /// - Note: WKWebView は main thread 必須のため @MainActor。
    @MainActor
    func renderExplanationPDFDataViaWebKit(
        title: String,
        bodyHTMLFragment: String
    ) async throws -> Data {
        #if canImport(WebKit)
        if #available(iOS 14.0, macOS 11.0, *) {
            let html = _buildExplanationHTML(title: title, bodyHTMLFragment: bodyHTMLFragment)

            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 612, height: 792)) // Letter pt
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.isScrollEnabled = false

            // 1) Wait page load
            let nav = _Inf6PDFNavDelegate()
            webView.navigationDelegate = nav
            webView.loadHTMLString(html, baseURL: nil)
            try await nav.waitFinished()

            // 2) Render PDF
            // IMPORTANT:
            // WKWebView.createPDF のデフォルトは「webView の bounds（= 1ページ相当）」のみを対象にし得ます。
            // そのため、全文を対象にするために contentSize を rect に明示します。
            webView.layoutIfNeeded()

            // IMPORTANT:
            // `scrollView.contentSize` can remain zero for offscreen WKWebView instances.
            // Measure the document size via JavaScript after `didFinish` to avoid generating a 1-page/empty PDF.
            let docSize = try await _measureWKWebViewDocumentSize(webView)
            guard webView.bounds.width > 0, docSize.width > 0, docSize.height > 0 else {
                throw NSError(domain: "Inf6PDF", code: 11, userInfo: [
                    NSLocalizedDescriptionKey: "WKWebView document size is empty (failed to determine full document size)"
                ])
            }

            // `scrollWidth/scrollHeight` returned from JS are in document (CSS pixel) space.
            // `WKPDFConfiguration.rect` is in the webView's coordinate space. Convert by scaling to the webView width.
            let scaleToViewWidth = webView.bounds.width / docSize.width
            let fullHeightInViewSpace = ceil(docSize.height * scaleToViewWidth)
            guard fullHeightInViewSpace > 0 else {
                throw NSError(domain: "Inf6PDF", code: 11, userInfo: [
                    NSLocalizedDescriptionKey: "WKWebView document size is empty (failed to determine full document size)"
                ])
            }

            let cfg = WKPDFConfiguration()
            cfg.rect = CGRect(origin: .zero, size: CGSize(width: webView.bounds.width, height: fullHeightInViewSpace))

            let data: Data = try await withCheckedThrowingContinuation { cont in
                webView.createPDF(configuration: cfg) { result in
                    switch result {
                    case .success(let data):
                        cont.resume(returning: data)
                    case .failure(let err):
                        cont.resume(throwing: err)
                    }
                }
            }
            if data.isEmpty {
                throw NSError(domain: "Inf6PDF", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "WebKit PDF data was empty"
                ])
            }
            return data
        } else {
            throw NSError(domain: "Inf6PDF", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "WKWebView.createPDF is not available on this OS version"
            ])
        }
        #else
        throw NSError(domain: "Inf6PDF", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "WebKit is not available on this platform"
        ])
        #endif
    }

    /// Microsoft Learn 向けの単一カラム知識 PDF を WebKit で生成する。
    /// 読みやすさを優先し、G検定版より行間と見出し余白を広く取る。
    @MainActor
    func renderMicrosoftLearnKnowledgePDFDataViaWebKit(
        title: String,
        bodyHTMLFragment: String
    ) async throws -> Data {
        #if canImport(WebKit)
        if #available(iOS 14.0, macOS 11.0, *) {
            let html = _buildMicrosoftLearnKnowledgeHTML(title: title, bodyHTMLFragment: bodyHTMLFragment)

            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 612, height: 792)) // Letter pt
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.isScrollEnabled = false

            let nav = _Inf6PDFNavDelegate()
            webView.navigationDelegate = nav
            webView.loadHTMLString(html, baseURL: nil)
            try await nav.waitFinished()

            webView.layoutIfNeeded()

            let docSize = try await _measureWKWebViewDocumentSize(webView)
            guard webView.bounds.width > 0, docSize.width > 0, docSize.height > 0 else {
                throw NSError(domain: "Inf6PDF", code: 31, userInfo: [
                    NSLocalizedDescriptionKey: "WKWebView document size is empty (failed to determine full Microsoft Learn document size)"
                ])
            }

            let scaleToViewWidth = webView.bounds.width / docSize.width
            let fullHeightInViewSpace = ceil(docSize.height * scaleToViewWidth)
            guard fullHeightInViewSpace > 0 else {
                throw NSError(domain: "Inf6PDF", code: 31, userInfo: [
                    NSLocalizedDescriptionKey: "WKWebView document size is empty (failed to determine full Microsoft Learn document size)"
                ])
            }

            let cfg = WKPDFConfiguration()
            cfg.rect = CGRect(origin: .zero, size: CGSize(width: webView.bounds.width, height: fullHeightInViewSpace))

            let data: Data = try await withCheckedThrowingContinuation { cont in
                webView.createPDF(configuration: cfg) { result in
                    switch result {
                    case .success(let data):
                        cont.resume(returning: data)
                    case .failure(let err):
                        cont.resume(throwing: err)
                    }
                }
            }
            if data.isEmpty {
                throw NSError(domain: "Inf6PDF", code: 32, userInfo: [
                    NSLocalizedDescriptionKey: "WebKit Microsoft Learn PDF data was empty"
                ])
            }
            return data
        } else {
            throw NSError(domain: "Inf6PDF", code: 33, userInfo: [
                NSLocalizedDescriptionKey: "WKWebView.createPDF is not available on this OS version"
            ])
        }
        #else
        throw NSError(domain: "Inf6PDF", code: 34, userInfo: [
            NSLocalizedDescriptionKey: "WebKit is not available on this platform"
        ])
        #endif
    }

    // MARK: - Document size measurement (WKWebView)

    /// Measure the full document size reliably.
    /// `scrollView.contentSize` may stay zero for offscreen WKWebView, so we query the DOM instead.
    @MainActor
    func _measureWKWebViewDocumentSize(_ webView: WKWebView) async throws -> CGSize {
        #if canImport(WebKit)
        let js = "({w: document.documentElement.scrollWidth, h: document.documentElement.scrollHeight})"

        let value: Any = try await withCheckedThrowingContinuation { cont in
            webView.evaluateJavaScript(js) { v, err in
                if let err {
                    cont.resume(throwing: err)
                    return
                }
                guard let v else {
                    cont.resume(throwing: NSError(domain: "Inf6PDF", code: 12, userInfo: [
                        NSLocalizedDescriptionKey: "WKWebView evaluateJavaScript returned nil (failed to measure document size)"
                    ]))
                    return
                }
                cont.resume(returning: v)
            }
        }

        guard let dict = value as? [String: Any] else {
            throw NSError(domain: "Inf6PDF", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "WKWebView evaluateJavaScript returned an unexpected value (failed to measure document size)"
            ])
        }

        func toDouble(_ any: Any?) -> Double? {
            if let d = any as? Double { return d }
            if let n = any as? NSNumber { return n.doubleValue }
            if let i = any as? Int { return Double(i) }
            return nil
        }

        guard let w = toDouble(dict["w"]), let h = toDouble(dict["h"]) else {
            throw NSError(domain: "Inf6PDF", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "WKWebView document size fields are missing (failed to measure document size)"
            ])
        }

        let cw = max(0, ceil(w))
        let ch = max(0, ceil(h))
        guard cw > 0, ch > 0 else {
            throw NSError(domain: "Inf6PDF", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "WKWebView measured document size was zero (w=\(w), h=\(h))"
            ])
        }

        return CGSize(width: cw, height: ch)
        #else
        throw NSError(domain: "Inf6PDF", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "WebKit is not available on this platform"
        ])
        #endif
    }

    // MARK: - HTML builder

    func _buildExplanationHTML(title: String, bodyHTMLFragment: String) -> String {
        let t = _escapeHTML_ExplanationPDFRenderer(title)

        // NOTE:
        // - `bodyHTMLFragment` は厳格バリデータで許可タグのみになっている前提で、そのまま埋め込みます。
        // - ここでエスケープすると図・表・数式（MathML）が壊れるため、断片は非エスケープ。
        return """
        <!doctype html>
        <html lang="ja">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            @page { size: letter; margin: 36pt; }
            html, body {
              margin: 0;
              padding: 0;
              font-family: -apple-system, BlinkMacSystemFont, "Hiragino Sans", "Hiragino Kaku Gothic ProN", "Noto Sans CJK JP", "Segoe UI", sans-serif;
              font-size: 8pt;
              line-height: 1.18;
              color: #111;
              background: #fff;
            }
            h1 {
              font-size: 11pt;
              margin: 0 0 6pt 0;
              padding: 0;
              font-weight: 700;
              color: #0b3d91;
            }
            .meta {
              font-size: 7pt;
              color: #444;
              margin-bottom: 6pt;
            }
            .content {
              border: 1px solid #ddd;
              border-radius: 4pt;
              padding: 4pt;
            }
            h2 {
              font-size: 9.5pt;
              margin: 8pt 0 4pt 0;
              color: #0b3d91;
              border-bottom: 1px solid #cfd8e3;
              padding-bottom: 1.5pt;
            }
            h3 {
              font-size: 9pt;
              margin: 6pt 0 3pt 0;
              color: #1f4b99;
            }
            p { margin: 3pt 0; }
            ul, ol { margin: 6pt 0 6pt 18pt; padding: 0; }
            li { margin: 2pt 0; }
            hr { border: 0; border-top: 1px solid #ddd; margin: 6pt 0; }

            table {
              width: 100%;
              border-collapse: collapse;
              margin: 5pt 0;
              font-size: 7.5pt;
            }
            th, td {
              border: 1px solid #ddd;
              padding: 3pt 4pt;
              vertical-align: top;
            }
            th {
              background: #eef3ff;
              color: #0b3d91;
              font-weight: 700;
            }

            pre, code {
              font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;
              font-size: 7.5pt;
              line-height: 1.18;
            }
            pre {
              white-space: pre-wrap;
              word-break: break-word;
              margin: 4pt 0;
              padding: 4pt;
              border: 1px solid #e5e5e5;
              border-radius: 6pt;
              background: #fafafa;
            }
            .formula {
              margin: 4pt 0;
              padding: 4pt;
              border: 1px solid #cfd8e3;
              border-radius: 6pt;
              background: #f7f9ff;
            }
            math { font-size: 8pt; }
          </style>
        </head>
        <body>
          <h1>\(t)</h1>
          <div class="meta">Generated by inf6</div>
          <div class="content">\(bodyHTMLFragment)</div>
        </body>
        </html>
        """
    }

    func _buildMicrosoftLearnKnowledgeHTML(title: String, bodyHTMLFragment: String) -> String {
        let t = _escapeHTML_ExplanationPDFRenderer(title)

        return """
        <!doctype html>
        <html lang="ja">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            :root { color-scheme: light; }
            @page { size: letter; margin: 42pt; }
            @media print {
              * { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
              body { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
            }

            html, body {
              margin: 0;
              padding: 0;
              font-family: -apple-system, BlinkMacSystemFont, "Hiragino Sans", "Hiragino Kaku Gothic ProN", "Noto Sans CJK JP", "Segoe UI", sans-serif;
              font-size: 10.8pt;
              line-height: 1.48;
              color: #111827;
              background: #ffffff;
            }

            body {
              padding: 0;
            }

            .page {
              padding: 0;
            }

            h1 {
              font-size: 18pt;
              line-height: 1.25;
              margin: 0 0 8pt 0;
              color: #0f3b82;
              font-weight: 700;
              letter-spacing: 0.1pt;
            }

            .meta {
              font-size: 8.8pt;
              color: #5b6472;
              margin-bottom: 14pt;
              padding-bottom: 10pt;
              border-bottom: 1px solid #d9e2f0;
            }

            .content {
              padding: 0;
            }

            h2 {
              font-size: 13.4pt;
              line-height: 1.28;
              margin: 18pt 0 8pt 0;
              padding-bottom: 3pt;
              color: #0f3b82;
              border-bottom: 1px solid #d9e2f0;
              page-break-after: avoid;
            }

            h3 {
              font-size: 11.2pt;
              line-height: 1.3;
              margin: 12pt 0 5pt 0;
              color: #1b4d9b;
              font-weight: 700;
              page-break-after: avoid;
            }

            p {
              margin: 5pt 0;
              orphans: 3;
              widows: 3;
            }

            ul, ol {
              margin: 6pt 0 10pt 20pt;
              padding: 0;
            }

            li {
              margin: 3pt 0;
            }

            strong {
              font-weight: 700;
              color: #0f172a;
            }

            hr {
              border: 0;
              border-top: 1px solid #d9e2f0;
              margin: 14pt 0;
            }

            table {
              width: 100%;
              border-collapse: collapse;
              margin: 8pt 0 12pt 0;
              table-layout: fixed;
              word-break: break-word;
              font-size: 9.6pt;
            }

            th, td {
              border: 1px solid #d6deea;
              padding: 6pt 7pt;
              vertical-align: top;
              text-align: left;
            }

            th {
              background: #eef4ff;
              color: #0f3b82;
              font-weight: 700;
            }

            pre, code {
              font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;
            }

            code {
              font-size: 8.8pt;
              background: #f3f5f8;
              padding: 1pt 3pt;
              border-radius: 3pt;
            }

            pre {
              font-size: 8.8pt;
              line-height: 1.4;
              white-space: pre-wrap;
              word-break: break-word;
              margin: 7pt 0 10pt 0;
              padding: 8pt 9pt;
              border: 1px solid #dce4ef;
              border-radius: 6pt;
              background: #f7f9fc;
            }

            div {
              page-break-inside: avoid;
            }
          </style>
        </head>
        <body>
          <div class="page">
            <h1>\(t)</h1>
            <div class="meta">Generated by inf6</div>
            <div class="content">\(bodyHTMLFragment)</div>
          </div>
        </body>
        </html>
        """
    }

    func _escapeHTML_ExplanationPDFRenderer(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "&", with: "&amp;")
        t = t.replacingOccurrences(of: "<", with: "&lt;")
        t = t.replacingOccurrences(of: ">", with: "&gt;")
        t = t.replacingOccurrences(of: "\"", with: "&quot;")
        t = t.replacingOccurrences(of: "'", with: "&#39;")
        return t
    }

    // MARK: - G検定: PDF取り込み（Files → Library）

    func applyGkenteiPDFImporter<Content: View>(_ content: Content) -> some View {
        content.fileImporter(
            isPresented: $isPickingGkenteiImportPDF,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) {
            let picked: URL
            do {
                let urls = try $0.get()
                guard let u = urls.first else {
                    throw CocoaError(.userCancelled)
                }
                picked = u
            } catch {
                let msg = Inf6Lang.text(
                    "PDFの選択に失敗しました: \(error)",
                    "Failed to pick a PDF: \(error)"
                )
                explanationPDFStatus = msg
                explanationPDFErrorAlertMessage = msg
                showExplanationPDFErrorAlert = true
                return
            }

            // 失敗は握り潰し禁止。
            guard picked.isFileURL else {
                let msg = Inf6Lang.text(
                    "選択されたPDFのURLが不正です（ファイルURLではありません）。",
                    "The selected PDF URL is invalid (not a file URL)."
                )
                explanationPDFStatus = msg
                explanationPDFErrorAlertMessage = msg
                showExplanationPDFErrorAlert = true
                return
            }

            #if os(iOS)
            let started = picked.startAccessingSecurityScopedResource()
            guard started else {
                let msg = Inf6Lang.text(
                    "PDFへのアクセス権を取得できませんでした（セキュリティスコープ）。",
                    "Failed to obtain access to the PDF (security-scoped resource)."
                )
                explanationPDFStatus = msg
                explanationPDFErrorAlertMessage = msg
                showExplanationPDFErrorAlert = true
                return
            }
            defer { picked.stopAccessingSecurityScopedResource() }
            #endif

            // Library に「このPDFを取り込め」と要求する
            NotificationCenter.default.post(
                name: .inf6OpenSavedPaperPDFInLibrary,
                object: picked
            )

            explanationPDFStatus = Inf6Lang.text(
                "PDFをライブラリに取り込むよう要求しました: \(picked.lastPathComponent)",
                "Requested the Library to import the PDF: \(picked.lastPathComponent)"
            )
        }
    }
}
