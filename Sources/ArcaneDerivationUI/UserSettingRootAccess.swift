import Foundation
import SwiftUI

@MainActor
final class UserSettingRootAccess: ObservableObject {
    @Published private(set) var url: URL?
    @Published private(set) var accessError: String?
    private var isAccessing = false
    private let bookmarkKey = "userSettingRoot.bookmark"

    var isAvailable: Bool { url != nil }

    init() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        do {
            var stale = false
            let resolved = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard resolved.startAccessingSecurityScopedResource() else { throw WorkspaceError.rootUnavailable }
            url = resolved
            isAccessing = true
            if stale {
                do { try persist(resolved) }
                catch { accessError = "保存先の再認証情報を保存できません: \(error.localizedDescription)" }
            }
        } catch {
            accessError = "保存先を復元できません: \(error.localizedDescription)"
        }
    }

    func set(url newURL: URL) throws {
        guard newURL.startAccessingSecurityScopedResource() else { throw WorkspaceError.rootUnavailable }
        let bookmark: Data
        do {
            bookmark = try newURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            newURL.stopAccessingSecurityScopedResource()
            throw error
        }
        if isAccessing { url?.stopAccessingSecurityScopedResource() }
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        url = newURL
        isAccessing = true
        accessError = nil
    }

    private func persist(_ resolved: URL) throws {
        let data = try resolved.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

}
