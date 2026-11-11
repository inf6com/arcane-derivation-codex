//
//  Inf6TaxonomyCompass.swift
//  inf6
//






import Foundation
import SwiftUI
#if canImport(WebKit)
import WebKit
#endif



// MARK: - Minimal localization helper (shared)
// NOTE: Some views/files call `Inf6Lang.text(ja,en)` for simple JP/EN switching.
// If the dedicated localization module is not included in the build target, we provide
// this minimal, functional implementation here so the app keeps building.
public enum Inf6Lang {
    /// Pick JP/EN string based on app setting (UserDefaults) or system preferred language.
    /// - Preference order:
    ///   1) `inf6_ui_language` ("ja"/"en"/"auto")
    ///   2) `gen_lang` ("ja"/"en"/"auto")
    ///   3) Locale.preferredLanguages
    public static func text(_ ja: String, _ en: String) -> String {
        let raw = (
            UserDefaults.standard.string(forKey: "inf6_ui_language") ??
            UserDefaults.standard.string(forKey: "gen_lang") ??
            "auto"
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

        func preferEN() -> Bool {
            if raw.hasPrefix("en") { return true }
            if raw.hasPrefix("ja") { return false }
            // auto: follow system preferred languages
            let pref = (Locale.preferredLanguages.first ?? "").lowercased()
            return pref.hasPrefix("en")
        }

        if preferEN() {
            return en.isEmpty ? ja : en
        } else {
            return ja.isEmpty ? en : ja
        }
    }
}

/// Convenience for inline UI strings that read nicer at call sites.
@inline(__always)
public func UIJA(_ ja: String, _ en: String) -> String {
    Inf6Lang.text(ja, en)
}

// MARK: - Paper Collection (Fast Search + Download)

/// Collect and manage PDFs discovered from an official site.
/// This is intentionally search-first (no giant Menu) to keep UI responsive.
struct Inf6PaperCollectionPanel: View {

    @State private var officialURLText: String = ""
    @State private var isDiscovering: Bool = false
    @State private var discoveredPDFs: [URL] = []

    @State private var localSearchText: String = ""
    @State private var remoteSearchText: String = ""

    @State private var localPDFs: [URL] = []
    @State private var lastError: String? = nil

    private let builder = Inf6SyllabusPipelineBuilder()

    #if canImport(UIKit)
    @MainActor
    private func _dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    #endif

    private static func collectionDirectoryURL() throws -> URL {
        let dir = Inf6Storage.manifestsDirectory().appendingPathComponent("stanford_papers", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw NSError(
                domain: "Inf6PaperCollectionPanel",
                code: -500,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create collection directory: \(error.localizedDescription)"]
            )
        }
        return dir
    }

    private static func isPDFFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    private static func safeFileName(from url: URL) throws -> String {
        // Prefer lastPathComponent; sanitize to keep file system safe.
        let raw = url.lastPathComponent.isEmpty ? "document.pdf" : url.lastPathComponent
        let lower = raw.lowercased()
        let base = lower.hasSuffix(".pdf") ? String(lower.dropLast(4)) : lower

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_ ")
        let cleanedScalars = base.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let cleaned = String(cleanedScalars)
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")

        let clipped = String(cleaned.prefix(120))
        guard !clipped.isEmpty else {
            throw NSError(
                domain: "Inf6PaperCollectionPanel",
                code: -501,
                userInfo: [NSLocalizedDescriptionKey: "Failed to build a safe filename (empty after sanitization)."]
            )
        }
        return "\(clipped).pdf"
    }

    @MainActor
    private func reloadLocalPDFs() {
        do {
            let dir = try Self.collectionDirectoryURL()
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            localPDFs = files.filter(Self.isPDFFile).sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            lastError = error.localizedDescription
            localPDFs = []
        }
    }

    @MainActor
    private func discover() async {
        lastError = nil
        discoveredPDFs = []

        let trimmed = officialURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = UIJA("公式URLが未入力です。", "Official URL is empty.")
            return
        }
        guard let url = URL(string: trimmed) else {
            lastError = UIJA("公式URLの形式が不正です。", "Official URL is invalid.")
            return
        }
        let scheme = (url.scheme ?? "").lowercased()
        guard scheme == "https" || scheme == "http" else {
            lastError = UIJA("http/https のURLのみ対応しています。", "Only http/https URLs are supported.")
            return
        }

        isDiscovering = true
        defer { isDiscovering = false }

        let urls = await builder.discoverReachablePDFURLsFromOfficialSite(officialURL: url, timeout: 20, maxConcurrency: 6)
        if urls.isEmpty {
            lastError = UIJA("PDFリンクが見つかりませんでした。", "No PDF links were found.")
            return
        }

        // Stable, de-duplicated.
        var seen = Set<String>()
        var out: [URL] = []
        out.reserveCapacity(urls.count)
        for u in urls {
            let key = u.absoluteString
            guard seen.insert(key).inserted else { continue }
            out.append(u)
        }
        discoveredPDFs = out.sorted { $0.absoluteString < $1.absoluteString }
    }

    @MainActor
    private func downloadPDF(_ url: URL) async {
        lastError = nil
        do {
            let dir = try Self.collectionDirectoryURL()
            let filename = try Self.safeFileName(from: url)
            let dest = dir.appendingPathComponent(filename)

            // Fail loudly on duplicates (no silent overwrite).
            if FileManager.default.fileExists(atPath: dest.path) {
                throw NSError(
                    domain: "Inf6PaperCollectionPanel",
                    code: -510,
                    userInfo: [NSLocalizedDescriptionKey: "PDF already exists: \(dest.lastPathComponent)"]
                )
            }

            var req = URLRequest(url: url)
            req.httpMethod = "GET"

            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 60
            let session = URLSession(configuration: config)

            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(status) else {
                let snippet = String(data: data.prefix(400), encoding: .utf8) ?? ""
                throw NSError(
                    domain: "Inf6PaperCollectionPanel",
                    code: status,
                    userInfo: [NSLocalizedDescriptionKey: "Download failed (\(status)): \(snippet)"]
                )
            }

            // Minimal PDF signature validation.
            if data.count < 5 || String(data: data.prefix(5), encoding: .ascii) != "%PDF-" {
                throw NSError(
                    domain: "Inf6PaperCollectionPanel",
                    code: -511,
                    userInfo: [NSLocalizedDescriptionKey: "Downloaded content is not a PDF."]
                )
            }

            try data.write(to: dest, options: [.atomic])
            reloadLocalPDFs()

        } catch {
            lastError = error.localizedDescription
        }
    }

    private var filteredLocal: [URL] {
        let q = localSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return localPDFs }
        return localPDFs.filter { $0.lastPathComponent.lowercased().contains(q) }
    }

    private var filteredRemote: [URL] {
        let q = remoteSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return discoveredPDFs }
        return discoveredPDFs.filter { $0.absoluteString.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(UIJA("公式サイトからPDF探索", "Discover PDFs from official site"))) {
                    TextField(UIJA("公式URLを入力", "Enter official URL"), text: $officialURLText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)

                    HStack {
                        Button {
                            Task { @MainActor in
                                await discover()
                            }
                        } label: {
                            Label(UIJA("探索", "Discover"), systemImage: "magnifyingglass")
                        }
                        .disabled(isDiscovering)

                        if isDiscovering {
                            ProgressView().tint(.pink).scaleEffect(1.25)
                        }
                    }

                    TextField(UIJA("探索結果を高速フィルタ", "Filter discovered results"), text: $remoteSearchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)

                    if !filteredRemote.isEmpty {
                        ForEach(filteredRemote, id: \.absoluteString) { u in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(u.absoluteString)
                                    .font(.footnote)
                                    .textSelection(.enabled)

                                Button {
                                    Task { @MainActor in
                                        await downloadPDF(u)
                                    }
                                } label: {
                                    Label(UIJA("このPDFを保存", "Save this PDF"), systemImage: "square.and.arrow.down")
                                }
                            }
                        }
                    }
                }

                Section(header: Text(UIJA("収集済みPDF（高速サーチ）", "Collected PDFs (fast search)"))) {
                    TextField(UIJA("ファイル名で検索", "Search by filename"), text: $localSearchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)

                    if filteredLocal.isEmpty {
                        Text(UIJA("まだPDFがありません。上の探索から保存してください。", "No PDFs yet. Discover above and save."))
                            .font(.footnote)
                    } else {
                        ForEach(filteredLocal, id: \.path) { u in
                            Text(u.lastPathComponent)
                                .font(.footnote)
                                .textSelection(.enabled)
                        }
                    }

                    Button {
                        reloadLocalPDFs()
                    } label: {
                        Label(UIJA("再スキャン", "Rescan"), systemImage: "arrow.clockwise")
                    }
                }

                if let e = lastError {
                    Section {
                        Text(e)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    } header: {
                        Text(UIJA("エラー", "Error"))
                    }
                }
            }
            .navigationTitle(UIJA("論文PDF収集", "Collect Paper PDFs"))
            .toolbar {
                #if canImport(UIKit)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(UIJA("完了", "Done")) {
                        _dismissKeyboard()
                    }
                }
                #endif
            }
            .onAppear {
                reloadLocalPDFs()
            }
        }
    }
}


// MARK: - Syllabus pipeline (embedded fallback)
// NOTE:
// `Inf6SyllabusPipelineBuilder.swift` がプロジェクトに存在しない/Target に入っていない場合でも
// Inf6Compass.swift 単体でビルドできるように、最低限の型定義をここに同梱する。
// ここで定義する型は「汎用シラバス生成パイプライン」の入力仕様を表す pure-data と、
// それを運ぶビルダー型（型参照の解決用）です。

/// シラバス生成の入力パラメータ（ユースケース側で組み立てる）
public struct Inf6SyllabusBuildSpec: Hashable, Codable {
    /// Web 検索に投げる検索文字列
    public let searchQuery: String

    /// YAML スキーマの骨格（system prompt に埋め込む想定）
    public let yamlSchemaDescription: String

    /// 必要なら次のような追加制約を指定できる（未使用でも OK / `nil` を許容するため）
    public let domainAllowlist: [String]?
    public let domainDenylist: [String]?
    public let createdAfterISO8601: String?
    public let createdBeforeISO8601: String?
    public let note: String?

    public init(
        searchQuery: String,
        yamlSchemaDescription: String,
        domainAllowlist: [String]? = nil,
        domainDenylist: [String]? = nil,
        createdAfterISO8601: String? = nil,
        createdBeforeISO8601: String? = nil,
        note: String? = nil
    ) {
        self.searchQuery = searchQuery
        self.yamlSchemaDescription = yamlSchemaDescription
        self.domainAllowlist = domainAllowlist
        self.domainDenylist = domainDenylist
        self.createdAfterISO8601 = createdAfterISO8601
        self.createdBeforeISO8601 = createdBeforeISO8601
        self.note = note
    }
}

/// 汎用「シラバス取得→構造化→保存」パイプラインのビルダー（型参照の解決用）。
///
/// 実処理は別モジュール/別ファイルで差し替えられる前提だが、
/// このファイルだけでも参照解決できるように最低限の型定義を提供する。
public final class Inf6SyllabusPipelineBuilder {
    public init() {}

    // MARK: - PDF probing helpers (fallback when HEAD is blocked or Content-Type is hidden)


    /// JS 実行後に取得した outerHTML と baseURL から、到達可能な PDF URL を抽出して返す。
    /// - Note: URL の「拡張子」ではなく、Content-Type / Content-Disposition / redirect 後 URL も含めて判定する。
    public func extractReachablePDFURLs(
        outerHTML: String,
        baseURL: URL,
        timeout: TimeInterval = 20,
        maxConcurrency: Int = 6
    ) async -> [URL] {
        print("[Inf6Compass] extractReachablePDFURLs: start baseURL=\(baseURL.absoluteString) outerHTMLChars=\(outerHTML.count)")
        let candidates = Inf6DOMURLInspector.extractCandidates(from: outerHTML, baseURL: baseURL)
        print("[Inf6Compass] extractReachablePDFURLs: candidates=\(candidates.count)")
        if candidates.isEmpty { return [] }

        let results = await Inf6DOMURLInspector.checkAll(
            candidates,
            timeout: timeout,
            maxConcurrency: maxConcurrency
        )
        print("[Inf6Compass] extractReachablePDFURLs: results=\(results.count)")

        // HTTP 2xx/3xx で、PDF と判定できたものだけ
        var out: [URL] = []
        out.reserveCapacity(results.count)
        var seen = Set<String>()

        for r in results {
            let code = r.statusCode ?? 0
            guard (200..<400).contains(code) else { continue }
            guard r.isLikelyPDF else { continue }

            let u = (r.finalURL ?? r.requestedURL)
            let key = u.absoluteString
            guard seen.insert(key).inserted else { continue }
            out.append(u)
        }
        if !out.isEmpty {
            print("[Inf6Compass] extractReachablePDFURLs: done pdfURLs=\(out.count)")
            return out
        }

        return out
    }


// Updated WebKit block for offscreen WKWebView and improved JS DOM fetching.
#if canImport(WebKit)
private final class _Inf6ProbeNav: NSObject, WKNavigationDelegate {
    var didFinish: ((WKWebView) -> Void)?
    var didFail: ((Error) -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish?(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        didFail?(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        didFail?(error)
    }
}

/// Some sites render almost nothing in the initial HTML and populate links via JS.
/// To improve reliability (and avoid GPU idle exits), attach the web view offscreen while loading.
@MainActor
private func _inf6AttachOffscreenWebView(_ webView: WKWebView) throws -> () -> Void {
#if canImport(UIKit)
    let scenes = UIApplication.shared.connectedScenes
    let windowScene = scenes
        .compactMap { $0 as? UIWindowScene }
        .first(where: { $0.activationState == .foregroundActive })
        ?? scenes.compactMap { $0 as? UIWindowScene }.first
    guard let windowScene else {
        throw NSError(
            domain: "Inf6SyllabusPipelineBuilder",
            code: -1004,
            userInfo: [NSLocalizedDescriptionKey: "No foreground window scene for WKWebView DOM fetch"]
        )
    }

    let hostController = UIViewController()
    hostController.view.backgroundColor = .clear
    hostController.view.isUserInteractionEnabled = false

    let hostWindow = UIWindow(windowScene: windowScene)
    hostWindow.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    hostWindow.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
    hostWindow.rootViewController = hostController
    hostWindow.backgroundColor = .clear
    hostWindow.isUserInteractionEnabled = false
    hostWindow.alpha = 0.001
    hostWindow.isHidden = false

    webView.translatesAutoresizingMaskIntoConstraints = false
    webView.isUserInteractionEnabled = false
    webView.alpha = 0.001
    hostController.view.addSubview(webView)
    NSLayoutConstraint.activate([
        webView.widthAnchor.constraint(equalToConstant: 1),
        webView.heightAnchor.constraint(equalToConstant: 1),
        webView.leadingAnchor.constraint(equalTo: hostController.view.leadingAnchor),
        webView.topAnchor.constraint(equalTo: hostController.view.topAnchor)
    ])

    return {
        webView.removeFromSuperview()
        hostWindow.isHidden = true
    }

#else
    return {}
#endif
}

@MainActor
private func _inf6FetchOuterHTMLAfterJS(url: URL, timeout: TimeInterval) async throws -> (outerHTML: String, baseURL: URL) {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    let webView = WKWebView(frame: .zero, configuration: config)
    let detach = try _inf6AttachOffscreenWebView(webView)

    let nav = _Inf6ProbeNav()
    webView.navigationDelegate = nav

    return try await withCheckedThrowingContinuation { cont in
        var didResume = false
        func resumeOnce(_ result: Result<(String, URL), Error>) {
            guard !didResume else { return }
            didResume = true
            detach()
            switch result {
            case .success(let v): cont.resume(returning: v)
            case .failure(let e): cont.resume(throwing: e)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            resumeOnce(.failure(NSError(
                domain: "Inf6SyllabusPipelineBuilder",
                code: -1001,
                userInfo: [NSLocalizedDescriptionKey: "WebView load timed out"]
            )))
        }

        nav.didFail = { error in
            resumeOnce(.failure(error))
        }

        nav.didFinish = { wv in
            // Wait a bit for JS-driven DOM updates (SPA / XHR) before taking outerHTML.
            // Use callAsyncJavaScript when available so we can await promises.
            let js = """
return new Promise(resolve => {
  const deadline = Date.now() + 8000;
  function tick() {
    const ready = (document.readyState === 'complete');
    const linkCount = document.querySelectorAll('a[href], link[href]').length;
    const html = document.documentElement ? document.documentElement.outerHTML : '';
    if (ready || linkCount > 0 || Date.now() > deadline) {
      resolve(html);
    } else {
      setTimeout(tick, 200);
    }
  }
  tick();
});
"""

            if #available(iOS 14.0, macOS 11.0, tvOS 14.0, *) {
                wv.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
                    switch result {
                    case .success(let any):
                        guard let html = any as? String else {
                            resumeOnce(.failure(NSError(
                                domain: "Inf6SyllabusPipelineBuilder",
                                code: -1003,
                                userInfo: [NSLocalizedDescriptionKey: "Unexpected JS result type for outerHTML"]
                            )))
                            return
                        }
                        resumeOnce(.success((html, wv.url ?? url)))
                    case .failure(let error):
                        resumeOnce(.failure(error))
                    }
                }
            } else {
                resumeOnce(.failure(NSError(
                    domain: "Inf6SyllabusPipelineBuilder",
                    code: -1002,
                    userInfo: [NSLocalizedDescriptionKey: "Unsupported OS version for JS DOM fetch (requires iOS 14 / macOS 11 or later)"]
                )))
            }
        }

        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = timeout
        _ = webView.load(req)
    }
}
#endif

/// 学校（団体）の公式URLを WebView で描画(JS実行後)した outerHTML を解析し、到達可能なPDF URLを返す。
/// - Note: watchOS など WebKit が無い環境では空配列を返す。
public func discoverReachablePDFURLsFromOfficialSite(
    officialURL: URL,
    timeout: TimeInterval = 20,
    maxConcurrency: Int = 6
) async -> [URL] {
#if canImport(WebKit)
    do {
        let (outerHTML, baseURL) = try await _inf6FetchOuterHTMLAfterJS(url: officialURL, timeout: timeout)
        print("[Inf6Compass] discoverReachablePDFURLsFromOfficialSite: outerHTMLChars=\(outerHTML.count) baseURL=\(baseURL.absoluteString)")
        guard !outerHTML.isEmpty else { return [] }
        return await extractReachablePDFURLs(
            outerHTML: outerHTML,
            baseURL: baseURL,
            timeout: timeout,
            maxConcurrency: maxConcurrency
        )
    } catch {
        print("[Inf6Compass] discoverReachablePDFURLsFromOfficialSite failed: \(error)")
        return []
    }
#else
    return []
#endif
}

}




// MARK: - Compass unified defaults
// Pure-data defaults (Inf6CompassUIConfig / Inf6CompassLocal* / Inf6CompassDefaultConfig)
// are defined in `compass.default.swift` so they can be swapped per-skin.

// NOTE:
// `compass.default.swift` is the preferred home for Compass pure-data defaults.
// If that file is not included in the build target, symbols such as
// `Inf6CompassUIConfig` / `Inf6CompassDefaultConfig` are missing.
// To keep this view buildable, we use a local, namespaced copy here.

// MARK: - Syllabus Model (shared)

/// リモート API / ローカル YAML などのシラバス情報 1 件を表す共通モデル。
public struct Inf6StanfordSyllabus: Codable, Identifiable, Hashable {
    public let id: String
    public let code: String
    public let title: String
    public let detail: String
    public let department: String
    public let level: String
    /// このシラバスに紐づいた論文セットマニフェストへの内部参照。
    public let manifestRef: String?

    public init(
        id: String,
        code: String,
        title: String,
        detail: String,
        department: String,
        level: String,
        manifestRef: String? = nil
    ) {
        self.id = id
        self.code = code
        self.title = title
        self.detail = detail
        self.department = department
        self.level = level
        self.manifestRef = manifestRef
    }
}


// MARK: - Compass Branding (config-driven UI skin)

/// `compass.default.swift`（branding + local schools を統合した）を差し替えるだけで
/// UI/ログ表記とローカルシラバスをまとめてスキン切り替えできる設定モデル。
/// Bundle 内の YAML を読み込み、無ければ `defaultInf6` を使う。
public struct Inf6CompassBranding: Codable, Hashable {
    public var appKey: String
    public var heroSystemImage: String
    public var heroTitleJa: String
    public var heroTitleEn: String
    public var heroSubtitleJa: String
    public var heroSubtitleEn: String
    public var navigationTitleJa: String
    public var navigationTitleEn: String
    public var logPrefix: String
    // Optional UI labels (may be provided by YAML; menu strings are primarily driven by Inf6CompassUIConfig)
    public var syllabusSourceRemoteLabelJa: String?
    public var syllabusSourceRemoteLabelEn: String?
    public var syllabusSourceLocalLabelJa: String?
    public var syllabusSourceLocalLabelEn: String?

    public init(
        appKey: String,
        heroSystemImage: String,
        heroTitleJa: String,
        heroTitleEn: String,
        heroSubtitleJa: String,
        heroSubtitleEn: String,
        navigationTitleJa: String,
        navigationTitleEn: String,
        logPrefix: String,
        syllabusSourceRemoteLabelJa: String? = nil,
        syllabusSourceRemoteLabelEn: String? = nil,
        syllabusSourceLocalLabelJa: String? = nil,
        syllabusSourceLocalLabelEn: String? = nil
    ) {
        self.appKey = appKey
        self.heroSystemImage = heroSystemImage
        self.heroTitleJa = heroTitleJa
        self.heroTitleEn = heroTitleEn
        self.heroSubtitleJa = heroSubtitleJa
        self.heroSubtitleEn = heroSubtitleEn
        self.navigationTitleJa = navigationTitleJa
        self.navigationTitleEn = navigationTitleEn
        self.logPrefix = logPrefix
        self.syllabusSourceRemoteLabelJa = syllabusSourceRemoteLabelJa
        self.syllabusSourceRemoteLabelEn = syllabusSourceRemoteLabelEn
        self.syllabusSourceLocalLabelJa = syllabusSourceLocalLabelJa
        self.syllabusSourceLocalLabelEn = syllabusSourceLocalLabelEn
    }

    /// 現在の inf6.com デフォルト。
    /// フォールバック禁止のため、ラベル類は空文字列とし、Bundle の compass.default.yaml から必ず上書きされる前提。
    public static let defaultInf6 = Inf6CompassBranding(
        appKey: "inf6.com",
        heroSystemImage: "compass.drawing",
        heroTitleJa: "",
        heroTitleEn: "",
        heroSubtitleJa: "",
        heroSubtitleEn: "",
        navigationTitleJa: "",
        navigationTitleEn: "",
        logPrefix: "[Inf6Compass]"
    )

    private static func _pickText(_ ja: String, _ en: String) -> String {
        // Prefer an explicit app setting if present.
        let raw = (
            UserDefaults.standard.string(forKey: "inf6_ui_language") ??
            UserDefaults.standard.string(forKey: "gen_lang") ??
            "auto"
        ).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        func preferEN() -> Bool {
            if raw.hasPrefix("en") { return true }
            if raw.hasPrefix("ja") { return false }
            // auto: follow system preferred languages
            let pref = (Locale.preferredLanguages.first ?? "").lowercased()
            return pref.hasPrefix("en")
        }

        let useEN = preferEN()
        if useEN {
            return en.isEmpty ? ja : en
        } else {
            return ja.isEmpty ? en : ja
        }
    }

    public var localizedHeroTitle: String {
        Self._pickText(heroTitleJa, heroTitleEn)
    }

    public var localizedHeroSubtitle: String {
        Self._pickText(heroSubtitleJa, heroSubtitleEn)
    }

    public var localizedNavigationTitle: String {
        Self._pickText(navigationTitleJa, navigationTitleEn)
    }
}












//
//  compass.default.swift
//  inf6
//
//  Unified Compass defaults (branding + UI labels + local proper‑noun schools).
//  Swift‑native replacement for compass.default.yaml.
//  Keep this file pure‑data so it can be swapped for skinning.
//

import Foundation

// MARK: - UI labels (menu strings)

public struct Inf6CompassUIConfig: Codable, Hashable {
    public struct SourceLabels: Codable, Hashable {
        public var labelJa: String
        public var labelEn: String
        public init(labelJa: String, labelEn: String) {
            self.labelJa = labelJa
            self.labelEn = labelEn
        }
    }

    public struct RootLabels: Codable, Hashable {
        public var labelJa: String
        public var labelEn: String
        public init(labelJa: String, labelEn: String) {
            self.labelJa = labelJa
            self.labelEn = labelEn
        }
    }

    // Section/header titles
    public var syllabusSourceTitleJa: String
    public var syllabusSourceTitleEn: String

    public var sourcePickerTitleJa: String
    public var sourcePickerTitleEn: String

    public var syllabusRootTitleJa: String
    public var syllabusRootTitleEn: String

    public var categoryPickerTitleJa: String
    public var categoryPickerTitleEn: String

    // Labels for each syllabus “source” option
    public var syllabusSources: [String: SourceLabels]

    // Labels for each “root/category” under the local branch
    public var syllabusRoots: [String: RootLabels]

    public init(
        syllabusSourceTitleJa: String,
        syllabusSourceTitleEn: String,
        syllabusSources: [String: SourceLabels],
        sourcePickerTitleJa: String,
        sourcePickerTitleEn: String,
        syllabusRootTitleJa: String,
        syllabusRootTitleEn: String,
        categoryPickerTitleJa: String,
        categoryPickerTitleEn: String,
        syllabusRoots: [String: RootLabels]
    ) {
        self.syllabusSourceTitleJa = syllabusSourceTitleJa
        self.syllabusSourceTitleEn = syllabusSourceTitleEn
        self.syllabusSources = syllabusSources
        self.sourcePickerTitleJa = sourcePickerTitleJa
        self.sourcePickerTitleEn = sourcePickerTitleEn
        self.syllabusRootTitleJa = syllabusRootTitleJa
        self.syllabusRootTitleEn = syllabusRootTitleEn
        self.categoryPickerTitleJa = categoryPickerTitleJa
        self.categoryPickerTitleEn = categoryPickerTitleEn
        self.syllabusRoots = syllabusRoots
    }
}

// MARK: - Local proper‑noun hierarchy (schools / faculties / departments)

/// ツールバーレベルの分類。AI = JDLA 系、IT = Microsoft Learn など IT 資格系。
public enum Inf6SchoolCategory: String, Codable, Hashable {
    case ai = "ai"
    case it = "it"
}

public struct Inf6CompassLocalSchool: Codable, Hashable {
    public var key: String
    public var labelJa: String
    public var labelEn: String
    public var homeURLString: String?
    public var faculties: [Inf6CompassLocalFaculty]
    /// ツールバーレベルの分類（デフォルト: .ai）
    public var category: Inf6SchoolCategory

    public init(
        key: String,
        labelJa: String,
        labelEn: String,
        homeURLString: String? = nil,
        faculties: [Inf6CompassLocalFaculty],
        category: Inf6SchoolCategory = .ai
    ) {
        self.key = key
        self.labelJa = labelJa
        self.labelEn = labelEn
        self.homeURLString = homeURLString
        self.faculties = faculties
        self.category = category
    }
}

public struct Inf6CompassLocalFaculty: Codable, Hashable {
    public var key: String
    public var labelJa: String
    public var labelEn: String
    public var departments: [Inf6CompassLocalDepartment]

    public init(key: String, labelJa: String, labelEn: String, departments: [Inf6CompassLocalDepartment]) {
        self.key = key
        self.labelJa = labelJa
        self.labelEn = labelEn
        self.departments = departments
    }
}

public struct Inf6CompassLocalDepartment: Codable, Hashable {
    public var key: String
    public var labelJa: String
    public var labelEn: String
    public var homeURLString: String?
    public var familyID: String?
    public var actionPhase: String?
    public var actionLabelJa: String?
    public var actionLabelEn: String?
    public var actionDescriptionJa: String?
    public var actionDescriptionEn: String?

    public init(
        key: String,
        labelJa: String,
        labelEn: String,
        homeURLString: String? = nil,
        familyID: String? = nil,
        actionPhase: String? = nil,
        actionLabelJa: String? = nil,
        actionLabelEn: String? = nil,
        actionDescriptionJa: String? = nil,
        actionDescriptionEn: String? = nil
    ) {
        self.key = key
        self.labelJa = labelJa
        self.labelEn = labelEn
        self.homeURLString = homeURLString
        self.familyID = familyID
        self.actionPhase = actionPhase
        self.actionLabelJa = actionLabelJa
        self.actionLabelEn = actionLabelEn
        self.actionDescriptionJa = actionDescriptionJa
        self.actionDescriptionEn = actionDescriptionEn
    }
}
