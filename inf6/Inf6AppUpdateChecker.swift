import Foundation
import Observation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct Inf6AppUpdate: Equatable {
    let currentVersion: String
    let latestVersion: String
    let appStoreURL: URL
}

@MainActor
@Observable
final class Inf6AppUpdateChecker {
    static let shared = Inf6AppUpdateChecker()

    private(set) var availableUpdate: Inf6AppUpdate?
    private(set) var isChecking = false
    private(set) var lastError: String?

    private let bundleID = "com.inf6.inf6"
    private var hasCheckedThisLaunch = false

    func checkIfNeeded() async {
        guard !hasCheckedThisLaunch else { return }
        hasCheckedThisLaunch = true
        await check()
    }

    func check() async {
        guard !isChecking else { return }
        guard let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !currentVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "アプリの現在バージョンを取得できません。"
            return
        }

        guard let lookupURL = URL(string: "https://itunes.apple.com/lookup?bundleId=\(bundleID)&country=JP") else {
            lastError = "App Store照会URLを作成できません。"
            return
        }

        isChecking = true
        lastError = nil
        defer { isChecking = false }

        do {
            var request = URLRequest(url: lookupURL)
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }

            let payload = try JSONDecoder().decode(AppStoreLookupResponse.self, from: data)
            guard let result = payload.results.first,
                  let latest = result.version,
                  let storeURL = URL(string: result.trackViewUrl ?? "") else {
                throw NSError(domain: "Inf6AppUpdateChecker", code: 1, userInfo: [NSLocalizedDescriptionKey: "App Storeに公開版情報がありません。"])
            }

            if Self.compareVersion(latest, currentVersion) == .orderedDescending {
                availableUpdate = Inf6AppUpdate(currentVersion: currentVersion, latestVersion: latest, appStoreURL: storeURL)
            } else {
                availableUpdate = nil
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func dismiss() {
        availableUpdate = nil
    }

    private static func compareVersion(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private struct AppStoreLookupResponse: Decodable {
        let results: [Result]

        struct Result: Decodable {
            let version: String?
            let trackViewUrl: String?
        }
    }
}

struct Inf6AppUpdateBanner: View {
    let update: Inf6AppUpdate
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text("新しいinf6があります")
                    .font(.headline)
                Text("v\(update.currentVersion) → v\(update.latestVersion)")
                    .font(.subheadline)
            }
            Spacer(minLength: 8)
            Button("App Store") {
#if canImport(UIKit)
                UIApplication.shared.open(update.appStoreURL)
#endif
            }
            .buttonStyle(.borderedProminent)
            Button("閉じる", action: onDismiss)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .foregroundStyle(.white)
        .background(.blue, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("新しいinf6があります。App Storeでv\(update.latestVersion)へ更新できます。")
    }
}
