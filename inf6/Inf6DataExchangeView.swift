//
//  Inf6DataExchangeView.swift
//  inf6
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ObjectiveC

struct Inf6DataExchangeView: View {
    @State private var _importPickerPresented = false
    @State private var _destination: String?
    @State private var _busy: String?
    @State private var _message: String?
    @State private var _failure: String?
    @State private var _history: [Inf6DataExchange.HistoryEntry] = Inf6DataExchange.loadHistory()
    @State private var _task: Task<Void, Never>?

    private func L(_ ja: String, _ en: String) -> String {
        Inf6Lang.isJapanese ? ja : en
    }

    var body: some View {
        Form {
            SwiftUI.Section {
                Button {
                    _export()
                } label: {
                    Label(L("エクスポート", "Export"), systemImage: "square.and.arrow.up")
                }
                .disabled(_busy != nil)

                Button {
                    _importPickerPresented = true
                } label: {
                    Label(L("インポート", "Import"), systemImage: "square.and.arrow.down")
                }
                .disabled(_busy != nil)
            }

            if let _busy {
                SwiftUI.Section {
                    HStack(spacing: 10) {
                        ProgressView().tint(.pink).scaleEffect(1.25)
                        Text(_busy)
                        Spacer()
                        Button(role: .cancel) {
                            _task?.cancel()
                        } label: {
                            Label(L("キャンセル", "Cancel"), systemImage: "xmark.circle")
                        }
                    }
                }
            }
            if _destination != nil || _message != nil {
                SwiftUI.Section {
                    if let _destination {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("書き出し先", "Written to"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(_destination).textSelection(.enabled)
                        }
                    }
                    if let _message {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("できたもの", "Result"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(_message).textSelection(.enabled)
                        }
                    }
                }
            }
            SwiftUI.Section {
                if _history.isEmpty {
                    Text(L("履歴はありません。", "No history yet."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(_history) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(entry.operation == .export
                                     ? L("エクスポート", "Export")
                                     : L("インポート", "Import"))
                                    .font(.system(size: Inf6ApplicationSystemFont.scaledSize(13), weight: .semibold))
                                Spacer()
                                Text(entry.happenedAt)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            if let path = entry.destinationPath, !path.isEmpty {
                                Text(path)
                                    .font(.footnote)
                                    .textSelection(.enabled)
                            }
                            Text(
                                entry.operation == .export
                                ? L("zip \(entry.archiveCount) 個 / \(entry.fileCount) ファイル",
                                    "\(entry.archiveCount) zips / \(entry.fileCount) files")
                                : L("zip \(entry.archiveCount) 個 / 復元 \(entry.fileCount) ファイル",
                                    "\(entry.archiveCount) zips / restored \(entry.fileCount) files")
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            if !entry.archiveNames.isEmpty {
                                Text(entry.archiveNames.joined(separator: "\n"))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text(L("履歴", "History"))
            }
            if let _failure {
                SwiftUI.Section {
                    Text(_failure)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle(L("エクスポート / インポート", "Export / Import"))
        .fileImporter(
            isPresented: $_importPickerPresented,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                guard !urls.isEmpty else { return }
                _import(urls)
            case .failure(let error):
                _failure = error.localizedDescription
            }
        }
    }

    private func _export() {
        _message = nil; _failure = nil
        _destination = nil
        _busy = L("書き出しを作成しています", "Preparing export")

        _task = Task.detached(priority: .userInitiated) {
            let parent = FileManager.default.temporaryDirectory
                .appendingPathComponent("inf6_data_exchange_export_\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: parent) }
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                let summary = try Inf6DataExchange.exportSet(
                    into: parent,
                    sourceFamilies: Inf6DataExchange.knownSourceFamilies(),
                    everything: true,
                    commitImmediately: false
                ) { step in
                    Task { @MainActor in _busy = step }
                } isCancelled: { Task.isCancelled }
                await MainActor.run {
                    _busy = L("保存先を選んでください", "Choose where to save")
                }
                let exportedURLs = try await _exportDataExchangeFilesViaDocumentPicker(summary.exportedFileURLs)
                let destinationPath = exportedURLs.map(\.path).joined(separator: "\n")
                try Inf6DataExchange.commitExport(
                    summary,
                    destinationPath: destinationPath.isEmpty ? nil : destinationPath
                )
                await MainActor.run {
                    _task = nil
                    _busy = nil
                    _destination = destinationPath.isEmpty ? summary.directory.path : destinationPath
                    _message = L("zip \(summary.partCount) 個 / \(summary.fileCount) ファイル",
                                 "\(summary.partCount) zips / \(summary.fileCount) files")
                    _history = Inf6DataExchange.loadHistory()
                }
            } catch {
                await MainActor.run {
                    _task = nil
                    _busy = nil
                    _failure = error is CancellationError
                        ? L("処理をキャンセルしました。", "Operation cancelled.")
                        : error.localizedDescription
                }
            }
        }
    }

    private func _import(_ files: [URL]) {
        _message = nil; _failure = nil
        _busy = L("取り込んでいます", "Importing")

        _task = Task.detached(priority: .userInitiated) {
            do {
                let count = try Inf6DataExchange.importArchives(at: files, progress: { step in
                    Task { @MainActor in _busy = step }
                }, isCancelled: { Task.isCancelled })
                await MainActor.run {
                    _task = nil
                    _busy = nil
                    _message = L("\(count) ファイル", "\(count) files")
                    _history = Inf6DataExchange.loadHistory()
                    NotificationCenter.default.post(name: .inf6DataExchangeDidImport, object: nil)
                }
            } catch {
                await MainActor.run {
                    _task = nil
                    _busy = nil
                    _failure = error is CancellationError
                        ? L("処理をキャンセルしました。", "Operation cancelled.")
                        : error.localizedDescription
                }
            }
        }
    }
}

private enum _Inf6DataExchangePickerError: LocalizedError {
    case noPresenter
    case fileMissing(String)
    case presentFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noPresenter:
            return Inf6Lang.text("保存先選択画面を表示できません。", "Cannot present the save destination picker.")
        case .fileMissing(let name):
            return Inf6Lang.text(
                "書き出し対象ファイルが見つかりません: \(name)",
                "Export file is missing: \(name)"
            )
        case .presentFailed:
            return Inf6Lang.text(
                "保存先選択画面の表示に失敗しました。",
                "Failed to present the save destination picker."
            )
        case .cancelled:
            return Inf6Lang.text("エクスポートをキャンセルしました。", "Export was cancelled.")
        }
    }
}

private var _inf6DataExchangeDocPickerAssocKey: UInt8 = 0

private final class _Inf6DataExchangeDocPickerCoordinator: NSObject, UIDocumentPickerDelegate {
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
        self.onPick = onPick
        self.onCancel = onCancel
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        onPick(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        onCancel()
    }
}

@MainActor
private func _exportDataExchangeFilesViaDocumentPicker(_ fileURLs: [URL]) async throws -> [URL] {
    guard !fileURLs.isEmpty else { return [] }

    for url in fileURLs {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw _Inf6DataExchangePickerError.fileMissing(url.lastPathComponent)
        }
    }

    await Task.yield()
    guard var presenter = _inf6DataExchangeTopMostViewController() else {
        throw _Inf6DataExchangePickerError.noPresenter
    }

    if presenter.viewIfLoaded?.window == nil {
        _ = presenter.view
    }
    if presenter.viewIfLoaded?.window == nil {
        await Task.yield()
        guard let refreshed = _inf6DataExchangeTopMostViewController() else {
            throw _Inf6DataExchangePickerError.noPresenter
        }
        presenter = refreshed
        _ = presenter.view
        if presenter.viewIfLoaded?.window == nil {
            throw _Inf6DataExchangePickerError.presentFailed
        }
    }

    if presenter.presentedViewController != nil {
        await Task.yield()
        guard let refreshed = _inf6DataExchangeTopMostViewController() else {
            throw _Inf6DataExchangePickerError.noPresenter
        }
        presenter = refreshed
    }

    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[URL], Error>) in
        let picker = UIDocumentPickerViewController(forExporting: fileURLs, asCopy: true)
        var resumed = false

        func resumeOnce(_ result: Result<[URL], Error>) {
            guard !resumed else { return }
            resumed = true
            switch result {
            case .success(let urls):
                cont.resume(returning: urls)
            case .failure(let error):
                cont.resume(throwing: error)
            }
        }

        let coordinator = _Inf6DataExchangeDocPickerCoordinator(
            onPick: { urls in resumeOnce(.success(urls)) },
            onCancel: { resumeOnce(.failure(_Inf6DataExchangePickerError.cancelled)) }
        )

        picker.delegate = coordinator
        objc_setAssociatedObject(
            picker,
            &_inf6DataExchangeDocPickerAssocKey,
            coordinator,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        picker.modalPresentationStyle = .automatic

        Task { @MainActor in
            var didCallPresentCompletion = false
            presenter.present(picker, animated: true) {
                didCallPresentCompletion = true
            }

            let deadlineNs = DispatchTime.now().uptimeNanoseconds + 12_000_000_000
            while true {
                if resumed { return }

                let attached = (presenter.presentedViewController === picker)
                    || (picker.presentingViewController != nil)
                    || (picker.viewIfLoaded?.window != nil)
                    || didCallPresentCompletion
                if attached { return }

                if DispatchTime.now().uptimeNanoseconds >= deadlineNs {
                    resumeOnce(.failure(_Inf6DataExchangePickerError.presentFailed))
                    return
                }
                await Task.yield()
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }
}

@MainActor
private func _inf6DataExchangeTopMostViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let orderedScenes: [UIWindowScene]
    if let active = scenes.first(where: { $0.activationState == .foregroundActive }) {
        orderedScenes = [active] + scenes.filter { $0 != active }
    } else if let inactive = scenes.first(where: { $0.activationState == .foregroundInactive }) {
        orderedScenes = [inactive] + scenes.filter { $0 != inactive }
    } else {
        orderedScenes = scenes
    }

    func topPresented(from root: UIViewController) -> UIViewController {
        var viewController = root
        while let presented = viewController.presentedViewController, !presented.isBeingDismissed {
            viewController = presented
        }
        return viewController
    }

    func bestPresenter(from root: UIViewController) -> UIViewController {
        let top = topPresented(from: root)
        if let navigation = top as? UINavigationController, let visible = navigation.visibleViewController {
            return bestPresenter(from: visible)
        }
        if let tab = top as? UITabBarController, let selected = tab.selectedViewController {
            return bestPresenter(from: selected)
        }
        if let split = top as? UISplitViewController, let last = split.viewControllers.last {
            return bestPresenter(from: last)
        }
        return top
    }

    for scene in orderedScenes {
        let visible = scene.windows.filter { !$0.isHidden && $0.alpha > 0.0 && $0.windowLevel == .normal }
        let candidates = visible.isEmpty ? scene.windows : visible
        let orderedWindows = candidates.sorted { lhs, rhs in
            lhs.isKeyWindow && !rhs.isKeyWindow
        }

        for window in orderedWindows {
            guard let root = window.rootViewController else { continue }
            if root.viewIfLoaded?.window == nil {
                _ = root.view
                if root.viewIfLoaded?.window == nil { continue }
            }
            let presenter = bestPresenter(from: root)
            if presenter.viewIfLoaded?.window != nil {
                return presenter
            }
        }
    }
    return nil
}
