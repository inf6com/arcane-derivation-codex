import Foundation
import SwiftUI
import UIKit

extension InlinePDFPagesView {
    // MARK: - Assets pipeline status persistence

    func _assetsPipelineStatusURL() -> URL? {
        guard let base = _paperBaseDir() else {
            return nil
        }
        return base.appendingPathComponent("assets.pipeline.status.json")
    }

    @MainActor
    func _restoreAssetsPipelineIndicatorFromDisk() {
        guard let u = _assetsPipelineStatusURL() else {
            _assetsPipelineDidFinish = false
            return
        }

        #if os(iOS)
        let didAccess = u.startAccessingSecurityScopedResource()
        defer { if didAccess { u.stopAccessingSecurityScopedResource() } }
        #endif

        let fm = FileManager.default
        let existsOnDisk = fm.fileExists(atPath: u.path)

        guard let data = _readFileDataCoordinated(u), !data.isEmpty else {
            if existsOnDisk {
                let msg = "[AssetsPipelineStatus] read failed: \(u)"
                print(msg)
                _ioLastError = msg
            }
            _assetsPipelineDidFinish = false
            return
        }

        do {
            let status = try JSONDecoder().decode(Inf6AssetsPipelineStatus.self, from: data)
            _assetsPipelineDidFinish = status.resolvedState == .finished
        } catch {
            let msg = "[AssetsPipelineStatus] decode failed: \(error) url=\(u)"
            print(msg)
            _ioLastError = msg
            _assetsPipelineDidFinish = false
        }
    }

    @MainActor
    func _persistAssetsPipelineAttempt(succeeded: Bool) {
        guard let u = _assetsPipelineStatusURL() else {
            let msg = L(
                "⚠︎ 保存先rootを解決できないため、図表パイプラインの完了状態（緑ドット）を保存できません。",
                "⚠︎ The storage root is unavailable, so the assets pipeline status (green dot) cannot be saved."
            )
            _assetsPipelineFinishedMessage = msg
            _assetsPipelineDidFinish = false
            return
        }

        #if os(iOS)
        let didAccess = u.startAccessingSecurityScopedResource()
        defer { if didAccess { u.stopAccessingSecurityScopedResource() } }
        #endif

        var lastSuccessAt: TimeInterval? = nil
        if let existing = _readFileDataCoordinated(u), !existing.isEmpty,
           let decoded = try? JSONDecoder().decode(Inf6AssetsPipelineStatus.self, from: existing) {
            lastSuccessAt = decoded.lastSuccessAt
        }

        let now = Date().timeIntervalSince1970
        let payload = Inf6AssetsPipelineStatus(
            lastAttemptAt: now,
            lastAttemptSucceeded: succeeded,
            lastSuccessAt: succeeded ? now : lastSuccessAt,
            state: succeeded ? .finished : .failed
        )

        guard let data = try? JSONEncoder().encode(payload) else {
            let msg = "[AssetsPipelineStatus] encode failed"
            print(msg)
            _ioLastError = msg
            _assetsPipelineDidFinish = false
            return
        }

        var coordError: NSError? = nil
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: u, options: .forReplacing, error: &coordError) { writeURL in
            do {
                try data.write(to: writeURL, options: [.atomic])
            } catch {
                let msg = "[AssetsPipelineStatus] write failed: \(error) url=\(u)"
                print(msg)
                _ioLastError = msg
                _assetsPipelineDidFinish = false
                _assetsPipelineFinishedMessage = L(
                    "⚠︎ 図表パイプライン状態の保存に失敗しました: \(error.localizedDescription)",
                    "⚠︎ Failed to save assets pipeline status: \(error.localizedDescription)"
                )
            }
        }

        if let coordError {
            let msg = "[AssetsPipelineStatus] coordination failed: \(coordError) url=\(u)"
            print(msg)
            _ioLastError = msg
            _assetsPipelineDidFinish = false
            _assetsPipelineFinishedMessage = L(
                "⚠︎ 図表パイプライン状態の保存（協調書き込み）に失敗しました: \(coordError.localizedDescription)",
                "⚠︎ Failed to coordinate saving assets pipeline status: \(coordError.localizedDescription)"
            )
        }
    }

    // MARK: - Assets pipeline finished popup

    @ViewBuilder
    var _assetsPipelineFinishedPopup: some View {
        if _isRunningAssetsPipeline {
            ZStack {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()

                VStack(spacing: 12) {
                    Text(L("図表パイプライン", "Assets pipeline"))
                        .font(.headline)

                    ProgressView().tint(.pink).scaleEffect(1.25)

                    Text(L("処理中…", "Running…"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: 420)
                .background(Color(UIColor.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(radius: 10)
                .padding(24)
            }
        } else if let msg = _assetsPipelineFinishedMessage,
                  !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ZStack {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .onTapGesture {
                        _assetsPipelineFinishedMessage = nil
                    }

                VStack(spacing: 12) {
                    Text(L("図表パイプライン", "Assets pipeline"))
                        .font(.headline)

                    Text(msg)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(_assetsPipelineDidFinish ? Color.blue : Color.red)

                    Button(L("OK", "OK")) {
                        _assetsPipelineFinishedMessage = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(16)
                .frame(maxWidth: 420)
                .background(Color(UIColor.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(radius: 10)
                .padding(24)
            }
        } else {
            EmptyView()
        }
    }
}
