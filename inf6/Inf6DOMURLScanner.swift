//
//  Inf6DOMURLScanner.swift
//  inf6
//
//  JS後に取得した DOM(outerHTML) から URL を総当り抽出し、実際に到達できるか / PDFか を検査する汎用ユーティリティ。
//  NOTE: Swiftではファイル名と型名は一致している必要はありません。
//  もし Xcode 上でファイル名も揃えたい場合は、このファイルを手動で
//  `Inf6DOMURLInspector.swift` にリネームしてください（型名はこのままでOK）。
//


import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(WebKit)
import WebKit
#endif

public enum Inf6DOMURLInspector {

    // MARK: - JS-executed DOM fetch (WKWebView)

    public enum DOMFetchError: Error, LocalizedError, Sendable {
        case webKitUnavailable
        case timeout
        case navigationFailed(String)
        case javaScriptFailed(String)

        public var errorDescription: String? {
            switch self {
            case .webKitUnavailable:
                return "WebKit is unavailable on this platform."
            case .timeout:
                return "Timed out waiting for JS-mutated DOM."
            case .navigationFailed(let s):
                return "Navigation failed: \(s)"
            case .javaScriptFailed(let s):
                return "JavaScript evaluation failed: \(s)"
            }
        }
    }

    /// WKWebViewでページを読み込み、JS実行後の `document.documentElement.outerHTML`（= DevTools寄りのDOM）を取得する。
    /// - Note: WebKitが無いプラットフォームでは `.webKitUnavailable` を投げる。
    /// - Parameters:
    ///   - pageURL: 対象ページ
    ///   - timeout: 最大待ち時間（秒）
    ///   - stablePolls: outerHTMLの長さが連続で安定した回数（安定判定）
    ///   - pollInterval: ポーリング間隔（秒）
    ///   - waitForSelectors: これらのCSSセレクタが揃ったら早期に確定（空なら安定判定のみ）
    @MainActor
    public static func fetchOuterHTMLAfterJS(
        from pageURL: URL,
        timeout: TimeInterval = 12,
        stablePolls: Int = 3,
        pollInterval: TimeInterval = 0.25,
        waitForSelectors: [String] = []
    ) async throws -> String {
        #if canImport(WebKit)
        let loader = _DOMLoader(
            pageURL: pageURL,
            timeout: timeout,
            stablePolls: max(1, stablePolls),
            pollInterval: max(0.05, pollInterval),
            waitForSelectors: waitForSelectors
        )
        return try await loader.run()
        #else
        throw DOMFetchError.webKitUnavailable
        #endif
    }

    /// 「JS後DOMを取得 → URL候補抽出 → 到達性/PDF判定」を一気通貫で実行する。
    /// これにより「ブラウザで見るDOM(B)」と同等の入力に対して、既存の総当りURL検査を適用できる。
    @MainActor
    public static func scanJSExecutedDOM(
        pageURL: URL,
        domTimeout: TimeInterval = 12,
        probeTimeout: TimeInterval = 20,
        maxConcurrency: Int = 6,
        waitForSelectors: [String] = [],
        allowedPathPrefixes: [String]? = nil,
        keywordHints: [String] = [],
        keywordMaxSections: Int = 6
    ) async throws -> (outerHTML: String, candidates: [Candidate], results: [Result]) {
        let outer = try await fetchOuterHTMLAfterJS(
            from: pageURL,
            timeout: domTimeout,
            stablePolls: 3,
            pollInterval: 0.25,
            waitForSelectors: waitForSelectors
        )
        let allCandidates: [Candidate] = {
            // If caller provides keyword hints (e.g., "シラバス" / "syllabus"),
            // prefer candidates extracted from the DOM section(s) around matching headings.
            if keywordHints.isEmpty {
                return extractCandidates(from: outer, baseURL: pageURL)
            }
            let focused = extractCandidatesNearKeywords(
                from: outer,
                baseURL: pageURL,
                keywordHints: keywordHints,
                maxSections: keywordMaxSections
            )
            let broad = extractCandidates(from: outer, baseURL: pageURL)
            if focused.isEmpty {
                return broad
            }
            return mergeCandidates(preferred: focused, fallback: broad)
        }()

        // Default filter: keep same-site (eTLD+1-ish) links to avoid probing the whole internet.
        var candidates = filterCandidatesForSameSite(allCandidates, baseURL: pageURL)

        // Scope filter:
        // - If caller provided `allowedPathPrefixes`, use them.
        // - Otherwise, infer a sensible default from `pageURL` (e.g. /certificate/general or /certificate/engineer)
        //   so broad DOM scans don't wander into /topic, /events, /news, ...
        let effectivePrefixes: [String] = {
            if let prefixes = allowedPathPrefixes, prefixes.isEmpty == false {
                return prefixes
            }
            return inferAllowedPathPrefixes(from: pageURL)
        }()

        if effectivePrefixes.isEmpty == false {
            let before = candidates.count
            candidates = filterCandidatesForAllowedPaths(candidates, allowedPathPrefixes: effectivePrefixes)
            log("scanJSExecutedDOM: scope prefixes=\(effectivePrefixes) kept=\(candidates.count)/\(before)")
        } else {
            log("scanJSExecutedDOM: scope prefixes=(none) kept=\(candidates.count)")
        }

        let results = await checkAll(candidates, timeout: probeTimeout, maxConcurrency: maxConcurrency)
        return (outer, candidates, results)
    }

    #if canImport(WebKit)
    @MainActor
    private final class _DOMLoader: NSObject, WKNavigationDelegate {
        private let pageURL: URL
        private let timeout: TimeInterval
        private let stablePolls: Int
        private let pollInterval: TimeInterval
        private let waitForSelectors: [String]

        init(
            pageURL: URL,
            timeout: TimeInterval,
            stablePolls: Int,
            pollInterval: TimeInterval,
            waitForSelectors: [String]
        ) {
            self.pageURL = pageURL
            self.timeout = timeout
            self.stablePolls = stablePolls
            self.pollInterval = pollInterval
            self.waitForSelectors = waitForSelectors
            super.init()
        }

        private var webView: WKWebView?
        private var continuation: CheckedContinuation<String, Error>?
        private var pollTimer: Timer?
        private var deadline: Date = .distantPast
        private var lastOuterLen: Int = -1
        private var stableCount: Int = 0

#if canImport(UIKit)
        private var hostingWindow: UIWindow?
#endif

        func run() async throws -> String {
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                self.continuation = cont
                self.deadline = Date().addingTimeInterval(self.timeout)

                let config = WKWebViewConfiguration()
                config.websiteDataStore = .nonPersistent()

                let wv = WKWebView(frame: .zero, configuration: config)
                wv.navigationDelegate = self
                wv.isOpaque = false
                wv.backgroundColor = .clear
                self.webView = wv

                // IMPORTANT: On iOS, WKWebView network/content processes may be suspended/terminated
                // if the web view is not attached to a view hierarchy. Attach it invisibly.
                #if canImport(UIKit)
                guard self.attachToViewHierarchyIfNeeded(wv) else {
                    self.finish(.failure(DOMFetchError.navigationFailed("No foreground window scene for WKWebView DOM fetch")))
                    return
                }
                #endif

                let req = URLRequest(url: self.pageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: self.timeout)
                Inf6DOMURLInspector.log("fetchOuterHTMLAfterJS: load start url=\(self.pageURL.absoluteString)")
                _ = wv.load(req)

                // Hard-timeout safety
                DispatchQueue.main.asyncAfter(deadline: .now() + self.timeout) { [weak self] in
                    guard let self else { return }
                    if self.continuation != nil {
                        Inf6DOMURLInspector.log("fetchOuterHTMLAfterJS: hard timeout url=\(self.pageURL.absoluteString)")
                        self.finish(.failure(DOMFetchError.timeout))
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Inf6DOMURLInspector.log("fetchOuterHTMLAfterJS: didFinish; start polling JS DOM")
            startPolling()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finish(.failure(DOMFetchError.navigationFailed(error.localizedDescription)))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finish(.failure(DOMFetchError.navigationFailed(error.localizedDescription)))
        }

        private func startPolling() {
            pollTimer?.invalidate()
            stableCount = 0
            lastOuterLen = -1

            pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
                // Hop back to the main actor before touching any @MainActor state.
                Task { @MainActor in
                    guard let self else { return }
                    guard let wv = self.webView else {
                        self.finish(.failure(DOMFetchError.navigationFailed("WKWebView deallocated")))
                        return
                    }

                    if Date() > self.deadline {
                        Inf6DOMURLInspector.log("fetchOuterHTMLAfterJS: poll deadline reached")
                        self.finish(.failure(DOMFetchError.timeout))
                        return
                    }

                    // 1) Check readyState + outerHTML length + (optional) selectors presence
                    let selectorsJSON: String
                    if self.waitForSelectors.isEmpty {
                        selectorsJSON = "[]"
                    } else {
                        // naive JSON escaping for quotes/backslashes
                        let escaped = self.waitForSelectors.map {
                            $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                        }
                        selectorsJSON = "[\"" + escaped.joined(separator: "\",\"") + "\"]"
                    }

                    let jsCheck = """
                    (() => {
                      const rs = document.readyState || "";
                      const len = (document.documentElement && document.documentElement.outerHTML) ? document.documentElement.outerHTML.length : 0;
                      const sels = \(selectorsJSON);
                      let ok = true;
                      if (sels && sels.length) {
                        ok = sels.every(s => { try { return !!document.querySelector(s); } catch(e) { return false; } });
                      }
                      return { readyState: rs, outerLen: len, selectorsOK: ok };
                    })()
                    """

                    do {
                        let any = try await wv.callAsyncJavaScript(jsCheck, arguments: [:], in: nil, contentWorld: .page)
                        let dict = any as? [String: Any]
                        let rs = dict?["readyState"] as? String ?? ""
                        let len = dict?["outerLen"] as? Int ?? 0
                        let selectorsOK = dict?["selectorsOK"] as? Bool ?? true

                        // stability check (length stabilization)
                        if len == self.lastOuterLen {
                            self.stableCount += 1
                        } else {
                            self.stableCount = 0
                            self.lastOuterLen = len
                        }

                        Inf6DOMURLInspector.log("fetchOuterHTMLAfterJS: poll readyState=\(rs) outerLen=\(len) stable=\(self.stableCount)/\(self.stablePolls) selectorsOK=\(selectorsOK)")

                        let ready = (rs == "complete" || rs == "interactive")
                        let stableEnough = (self.stableCount >= self.stablePolls)
                        let selectorsEnough = self.waitForSelectors.isEmpty ? false : selectorsOK

                        if ready && (stableEnough || selectorsEnough) {
                            // 2) Fetch the full outerHTML once
                            let jsOuter = "document.documentElement ? document.documentElement.outerHTML : ''"
                            let htmlAny = try await wv.callAsyncJavaScript(jsOuter, arguments: [:], in: nil, contentWorld: .page)
                            let html = (htmlAny as? String) ?? ""
                            if html.isEmpty {
                                // If empty, keep polling until deadline
                                Inf6DOMURLInspector.log("fetchOuterHTMLAfterJS: outerHTML empty; continue polling")
                                return
                            }
                            Inf6DOMURLInspector.log("fetchOuterHTMLAfterJS: outerHTML acquired chars=\(html.count)")
                            self.finish(.success(html))
                        }
                    } catch {
                        Inf6DOMURLInspector.log("fetchOuterHTMLAfterJS: js error=\(error.localizedDescription)")
                        // keep polling on transient script errors
                    }
                }
            }
        }

        private func finish(_ result: Swift.Result<String, Error>) {
            pollTimer?.invalidate()
            pollTimer = nil

            let cont = continuation
            continuation = nil

            #if canImport(UIKit)
            detachFromViewHierarchyIfNeeded()
            #endif
            // Break retain cycles
            webView?.navigationDelegate = nil
            webView = nil

            switch result {
            case .success(let html):
                cont?.resume(returning: html)
            case .failure(let err):
                cont?.resume(throwing: err)
            }
        }

        deinit {
            pollTimer?.invalidate()
            pollTimer = nil
        }

    #if canImport(UIKit)
        private func attachToViewHierarchyIfNeeded(_ wv: WKWebView) -> Bool {
            // If already attached, do nothing.
            if wv.superview != nil { return true }

            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
            guard let scene else {
                Inf6DOMURLInspector.log("fetchOuterHTMLAfterJS: no foreground window scene")
                return false
            }

            let hostController = UIViewController()
            hostController.view.backgroundColor = .clear
            hostController.view.isUserInteractionEnabled = false

            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
            window.rootViewController = hostController
            window.backgroundColor = .clear
            window.isUserInteractionEnabled = false
            window.alpha = 0.001
            window.isHidden = false

            wv.translatesAutoresizingMaskIntoConstraints = false
            wv.isUserInteractionEnabled = false
            wv.alpha = 0.001

            hostController.view.addSubview(wv)
            self.hostingWindow = window

            NSLayoutConstraint.activate([
                wv.widthAnchor.constraint(equalToConstant: 1),
                wv.heightAnchor.constraint(equalToConstant: 1),
                wv.leadingAnchor.constraint(equalTo: hostController.view.leadingAnchor),
                wv.topAnchor.constraint(equalTo: hostController.view.topAnchor)
            ])

            Inf6DOMURLInspector.log("fetchOuterHTMLAfterJS: hosted WKWebView in dedicated window")
            return true
        }

        private func detachFromViewHierarchyIfNeeded() {
            guard let wv = self.webView else { return }
            if wv.superview != nil {
                wv.removeFromSuperview()
                Inf6DOMURLInspector.log("fetchOuterHTMLAfterJS: detached WKWebView from hierarchy")
            }
            self.hostingWindow?.isHidden = true
            self.hostingWindow = nil
        }
#endif
    }
    #endif

    // MARK: - Logging

    /// Enable very verbose logs for debugging DOM URL extraction/probing.
    /// Default: enabled in DEBUG builds.
    public static var verboseLogEnabled: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// When enabled, suppress verbose per-URL logs unless the URL strongly hints a PDF/download.
    /// This prevents noisy logs like /news/ or unrelated content pages during broad DOM scans.
    /// Default: true in DEBUG builds.
    public static var verboseLogPDFHintOnly: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    @inline(__always)
    private static func shouldVerboseLog(for url: URL) -> Bool {
        guard verboseLogEnabled else { return false }
        guard verboseLogPDFHintOnly else { return true }
        let u = canonicalURLForProbe(url)
        if u.pathExtension.lowercased() == "pdf" { return true }
        return isPDFHintURL(u)
    }

    @inline(__always)
    private static func shouldVerboseLogCandidateURL(_ url: URL?) -> Bool {
        guard verboseLogEnabled else { return false }
        if verboseLogPDFHintOnly {
            guard let url else { return false }
            return shouldVerboseLog(for: url)
        }
        return true
    }

    @inline(__always)
    private static func vlogCandidate(_ url: URL?, _ message: @autoclosure () -> String) {
        guard shouldVerboseLogCandidateURL(url) else { return }
        log(message())
    }

    @inline(__always)
    private static func log(_ message: String) {
        guard verboseLogEnabled else { return }
        print("[Inf6DOMURLInspector] \(message)")
    }

    @inline(__always)
    private static func oneLine(_ s: String, limit: Int = 200) -> String {
        let x = s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        if x.count <= limit { return x }
        let i = x.index(x.startIndex, offsetBy: limit)
        return String(x[..<i]) + "…"
    }

    public struct Candidate: Hashable, Sendable {
        public let raw: String          // DOM中の生文字列
        public let url: URL             // baseURL で解決済み
        public let source: String       // "a[href]" / "img[src]" / "a[data-downloadurl]" / "inline(http)" など
    }

    public struct Result: Hashable, Sendable {
        public let requestedURL: URL
        public let finalURL: URL?
        public let statusCode: Int?
        public let contentType: String?
        public let contentDisposition: String?
        public let isLikelyPDF: Bool
        public let errorDescription: String?
    }

    // MARK: - Public API

    /// DOM(outerHTML)から URL 候補を総抽出（href/src/data-* / srcset / inline http(s) / CSS url(...)）
    public static func extractCandidates(from html: String, baseURL: URL) -> [Candidate] {
        var out: [Candidate] = []
        var uniq = Set<String>() // resolved absolute string

        log("extractCandidates: start baseURL=\(baseURL.absoluteString) htmlChars=\(html.count)")

        func looksLikeSrcsetList(_ s: String) -> Bool {
            // Typical srcset: "a.png 2000w, b.png 300w" or "a.png 2x, b.png 1x"
            guard s.contains(",") else { return false }
            return !matches(s, pattern: #"(?i)\s\d+(?:\.\d+)?[wx]\b"#).isEmpty
        }

        func addOne(raw: String, source: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            guard let resolved = resolveURL(trimmed, baseURL: baseURL) else {
                vlogCandidate(nil, "extractCandidates: skip unresolved source=\(source) raw=\(oneLine(trimmed))")
                return
            }
            if shouldSkipCandidateURL(resolved) {
                vlogCandidate(resolved, "extractCandidates: skip noise source=\(source) url=\(resolved.absoluteString)")
                return
            }
            let abs = resolved.absoluteString
            guard uniq.insert(abs).inserted else {
                vlogCandidate(resolved, "extractCandidates: skip duplicate source=\(source) url=\(abs)")
                return
            }

            out.append(Candidate(raw: trimmed, url: resolved, source: source))
            vlogCandidate(resolved, "extractCandidates: + source=\(source) url=\(abs) raw=\(oneLine(trimmed))")
        }

        func add(raw: String, source: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            // Some sites put srcset-like lists into data-* attributes (e.g. data-srcset).
            // If we treat the whole list as one URL, it becomes an invalid percent-encoded monster.
            if looksLikeSrcsetList(trimmed) {
                for item in parseSrcsetURLs(trimmed) {
                    addOne(raw: item, source: "\(source):srcset")
                }
                return
            }

            addOne(raw: trimmed, source: source)
        }

        // 1) HTMLタグを走査して、href/src/action/poster/srcset + 任意の data-* を総抽出
        //    ※ 属性名はサイトごとにバラバラなので、data-downloadurl 等の「特定名」には依存しない。
        let tagPattern =
        #"(?is)<([a-z0-9:_-]+)\b([^>]*)>"#
        let attrAnyPattern =
        #"(?is)\s([a-z0-9:_-]+)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#

        for t in matches(html, pattern: tagPattern) {
            let tag = (t.group(1)?.lowercased() ?? "node")
            let attrs = (t.group(2) ?? "")

            for a in matches(attrs, pattern: attrAnyPattern) {
                let name = (a.group(1)?.lowercased() ?? "")
                let value = (a.group(2) ?? a.group(3) ?? a.group(4) ?? "")
                if value.isEmpty { continue }

                // srcset は複数URLを含む
                if name == "srcset" {
                    for item in parseSrcsetURLs(value) { add(raw: item, source: "\(tag)[srcset]") }
                    continue
                }

                // style 属性にも url(...) が埋まることがある（保険）
                if name == "style" {
                    for m in matches(value, pattern: #"(?is)\burl\(\s*(?:\"([^\"]*)\"|'([^']*)'|([^\)\s]+))\s*\)"#) {
                        let v = (m.group(1) ?? m.group(2) ?? m.group(3) ?? "")
                        add(raw: stripQuotes(v), source: "\(tag)[style:url()]")
                    }
                    continue
                }

                // 主要属性 + 任意の data-* を採用
                if name == "href" || name == "src" || name == "action" || name == "poster" || name.hasPrefix("data-") {
                    add(raw: value, source: "\(tag)[\(name)]")
                }
            }
        }

        // 2) srcset 単独（上の正規表現に乗りにくい場合の保険）
        let srcsetPattern =
        #"(?is)\bsrcset\s*=\s*(?:\"([^\"]*)\"|'([^']*)')"#
        for m in matches(html, pattern: srcsetPattern) {
            let v = (m.group(1) ?? m.group(2) ?? "")
            for item in parseSrcsetURLs(v) { add(raw: item, source: "node[srcset]") }
        }

        // 3) CSS url(...)
        let cssURLPattern = #"(?is)\burl\(\s*(?:\"([^\"]*)\"|'([^']*)'|([^\)\s]+))\s*\)"#
        for m in matches(html, pattern: cssURLPattern) {
            let v = (m.group(1) ?? m.group(2) ?? m.group(3) ?? "")
            add(raw: stripQuotes(v), source: "css:url()")
        }

        // 4) inline http(s)（onclick の gtag event_label 等も拾える）
        let inlineHTTPPattern = #"(?i)\bhttps?://[^\s\"'<>]+(?!=\"|\')"#
        for m in matches(html, pattern: inlineHTTPPattern) {
            add(raw: m.group(0) ?? "", source: "inline(http)")
        }

        log("extractCandidates: done candidates=\(out.count)")
        return out
    }

    /// 抽出したURLをHEAD/GETで検査して、到達性・リダイレクト後URL・Content-Type等を返す
    public static func checkAll(
        _ candidates: [Candidate],
        timeout: TimeInterval = 20,
        maxConcurrency: Int = 6
    ) async -> [Result] {
        if candidates.isEmpty { return [] }

        log("checkAll: start candidates=\(candidates.count) timeout=\(timeout)s maxConcurrency=\(maxConcurrency)")
        if verboseLogEnabled {
            let list = candidates.filter { shouldVerboseLogCandidateURL($0.url) }
            let suppressed = candidates.count - list.count
            if verboseLogPDFHintOnly && suppressed > 0 {
                log("checkAll: verbose candidate logs filtered by PDF-hints; suppressed=\(suppressed)")
            }
            for (i, c) in list.enumerated() {
                log("checkAll: candidate[\(i)] source=\(c.source) url=\(c.url.absoluteString)")
            }
        }

        let urls: [URL] = {
            var out: [URL] = []
            out.reserveCapacity(candidates.count)
            var seen = Set<String>()
            for c in candidates {
                let u = canonicalURLForProbe(c.url)
                let abs = u.absoluteString
                guard seen.insert(abs).inserted else { continue }
                out.append(u)
            }
            return out
        }()
        let session = URLSession(configuration: {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = timeout
            c.timeoutIntervalForResource = timeout
            c.waitsForConnectivity = false
            return c
        }())

        var results: [Result] = []
        results.reserveCapacity(urls.count)

        await withTaskGroup(of: Result?.self) { group in
            var iterator = urls.makeIterator()

            func enqueueNext() {
                guard let u = iterator.next() else { return }
                group.addTask {
                    return await probe(url: u, session: session)
                }
            }

            for _ in 0..<max(1, maxConcurrency) { enqueueNext() }

            while let r = await group.next() {
                if let r { results.append(r) }
                enqueueNext()
            }
        }

        log("checkAll: done results=\(results.count)")
        return results
    }

    /// キーワード（例: "シラバス" / "syllabus"）を含む見出し（h1..h6）を起点に、
    /// その見出しから次の「同レベル以上の見出し」までを1セクションとしてDOM断片を切り出し、
    /// その範囲内のURL候補だけを優先抽出する。
    ///
    /// - Note: HTMLを厳密DOMとして解析するのではなく、見出しタグ境界での「軽量セクション抽出」です。
    ///         WordPress等の「h2見出し + その直後にカード/ダウンロードリンク」という典型構造に強い。
    public static func extractCandidatesNearKeywords(
        from html: String,
        baseURL: URL,
        keywordHints: [String],
        maxSections: Int = 6
    ) -> [Candidate] {
        let kws = keywordHints
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !kws.isEmpty else { return [] }
        guard html.isEmpty == false else { return [] }

        // Match heading blocks: <h2 ...>...</h2> (including inner tags)
        let headingPattern = #"(?is)<(h[1-6])\b([^>]*)>(.*?)</\1>"#
        let ms = matches(html, pattern: headingPattern)
        if ms.isEmpty { return [] }

        struct H {
            let start: Int
            let tag: String
            let level: Int
            let attrs: String
            let textLower: String
        }

        func stripTagsToLower(_ s: String) -> String {
            // remove nested tags
            let stripped = s.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
            let x = stripped
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
            return x.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        var hs: [H] = []
        hs.reserveCapacity(ms.count)
        for m in ms {
            let tag = (m.group(1)?.lowercased() ?? "")
            let attrs = (m.group(2) ?? "")
            let inner = (m.group(3) ?? "")
            let level = Int(tag.dropFirst()) ?? 6
            let start = m.ns.range.location
            let textLower = stripTagsToLower(inner)
            hs.append(H(start: start, tag: tag, level: level, attrs: attrs.lowercased(), textLower: textLower))
        }

        // Determine section bounds: from heading start until next heading with level <= current level
        func sectionEndStartIndex(forHeadingAt i: Int) -> Int {
            let cur = hs[i]
            var j = i + 1
            while j < hs.count {
                if hs[j].level <= cur.level {
                    return hs[j].start
                }
                j += 1
            }
            return html.utf16.count
        }

        func matchesKeyword(_ h: H) -> String? {
            for kw in kws {
                if h.textLower.contains(kw) { return kw }
                if h.attrs.contains(kw) { return kw }
            }
            return nil
        }

        var out: [Candidate] = []
        var seen = Set<String>()
        var usedSections = 0

        for i in 0..<hs.count {
            guard usedSections < max(1, maxSections) else { break }
            let h = hs[i]
            guard let kw = matchesKeyword(h) else { continue }

            let endStart = sectionEndStartIndex(forHeadingAt: i)
            let startUTF16 = h.start
            let endUTF16 = max(startUTF16, endStart)

            // Slice by UTF-16 offsets because NSRegularExpression ranges are UTF-16 based.
            let ns = html as NSString
            let len = min(ns.length, endUTF16) - min(ns.length, startUTF16)
            if len <= 0 { continue }
            let frag = ns.substring(with: NSRange(location: min(ns.length, startUTF16), length: len))

            let fragCandidates = extractCandidates(from: frag, baseURL: baseURL)
            if fragCandidates.isEmpty {
                usedSections += 1
                continue
            }

            log("extractCandidatesNearKeywords: matched kw=\(kw) tag=\(h.tag) sectionChars=\(frag.count) candidates=\(fragCandidates.count)")

            for c in fragCandidates {
                let key = c.url.absoluteString
                guard seen.insert(key).inserted else { continue }
                out.append(Candidate(raw: c.raw, url: c.url, source: "kw(\(kw))|\(c.source)"))
            }
            usedSections += 1
        }

        log("extractCandidatesNearKeywords: done keywordHints=\(keywordHints) candidates=\(out.count)")
        return out
    }

    @inline(__always)
    private static func mergeCandidates(preferred: [Candidate], fallback: [Candidate]) -> [Candidate] {
        var out: [Candidate] = []
        out.reserveCapacity(preferred.count + fallback.count)
        var seen = Set<String>()
        for c in preferred {
            let k = c.url.absoluteString
            guard seen.insert(k).inserted else { continue }
            out.append(c)
        }
        for c in fallback {
            let k = c.url.absoluteString
            guard seen.insert(k).inserted else { continue }
            out.append(c)
        }
        return out
    }

    // MARK: - Internals

    // --- Helper functions for canonicalization, site filtering, and PDF hint detection ---
    private static func canonicalURLForProbe(_ url: URL) -> URL {
        // URL fragments are never sent over HTTP; probing them creates duplicate work.
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.fragment = nil
        return comps.url ?? url
    }

    private static func guessSiteSuffix(_ host: String) -> String {
        // Best-effort eTLD+1; good enough for jdla.org and similar.
        let parts = host.lowercased().split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return host.lowercased() }
        return parts.suffix(2).joined(separator: ".")
    }

    private static func inferAllowedPathPrefixes(from pageURL: URL) -> [String] {
        // Best-effort default scoping to reduce noisy internal links.
        // Example targets:
        // - https://www.jdla.org/certificate/engineer/
        // - https://www.jdla.org/certificate/general/
        let path = pageURL.path

        if path.hasPrefix("/certificate/engineer") {
            return ["/certificate/engineer"]
        }
        if path.hasPrefix("/certificate/general") {
            return ["/certificate/general"]
        }
        return []
    }

    private static func filterCandidatesForSameSite(_ candidates: [Candidate], baseURL: URL) -> [Candidate] {
        guard let baseHostRaw = baseURL.host?.lowercased(), !baseHostRaw.isEmpty else { return candidates }
        let baseHost = baseHostRaw.hasPrefix("www.") ? String(baseHostRaw.dropFirst(4)) : baseHostRaw
        let suffix = guessSiteSuffix(baseHost)

        return candidates.filter { c in
            guard let h0 = c.url.host?.lowercased(), !h0.isEmpty else { return true }
            let h = h0.hasPrefix("www.") ? String(h0.dropFirst(4)) : h0
            if h == baseHost { return true }
            if h == suffix { return true }
            if h.hasSuffix("." + suffix) { return true }
            return false
        }
    }

    private static func filterCandidatesForAllowedPaths(_ candidates: [Candidate], allowedPathPrefixes: [String]) -> [Candidate] {
        let normalizedPrefixes: [String] = allowedPathPrefixes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { p -> String? in
                // Allow callers to pass either:
                // - "/certificate/general"
                // - "https://www.jdla.org/certificate/general/"
                if let u = URL(string: p), let scheme = u.scheme?.lowercased(), (scheme == "http" || scheme == "https") {
                    let path = u.path.isEmpty ? "/" : u.path
                    return path.hasPrefix("/") ? path : ("/" + path)
                }
                var x = p
                if x.hasPrefix("/") == false { x = "/" + x }
                return x
            }

        if normalizedPrefixes.isEmpty { return candidates }

        return candidates.filter { c in
            let u = canonicalURLForProbe(c.url)

            // Always allow obvious PDF/download targets anywhere (they may live outside /certificate/...)
            if u.pathExtension.lowercased() == "pdf" { return true }
            if isPDFHintURL(u) { return true }

            let path = u.path
            return normalizedPrefixes.contains(where: { path.hasPrefix($0) })
        }
    }

    private static func isPDFHintURL(_ url: URL) -> Bool {
        // Only used to decide whether it's worth doing a small Range GET sniff.
        // Keep this intentionally conservative to avoid crawling unrelated HTML pages.
        let s = url.absoluteString.lowercased()
        if s.contains(".pdf") { return true }

        // Common query patterns for file delivery.
        if s.contains("pdf=") || s.contains("file=") || s.contains("filename=") { return true }

        // WordPress uploads are a frequent PDF location (even if linked from scoped pages).
        let path = url.path.lowercased()
        if path.contains("/wp-content/") || path.contains("/uploads/") {
            if s.contains(".pdf") || path.hasSuffix(".pdf") { return true }
        }

        // Avoid treating generic "download" pages as hints unless they also look file-like.
        if s.contains("download") {
            if s.contains(".pdf") || s.contains("file=") || s.contains("filename=") { return true }
        }

        return false
    }

    private static func probe(url: URL, session: URLSession) async -> Result {
        if shouldVerboseLog(for: url) {
            log("probe: start url=\(url.absoluteString)")
        }
        // 1) HEAD
        if let head = await request(url: url, method: "HEAD", session: session) {
            if shouldVerboseLog(for: url) {
                log("probe: HEAD status=\(head.statusCode ?? -1) url=\(head.finalURL?.absoluteString ?? url.absoluteString) ct=\(head.contentType ?? "") cd=\(head.contentDisposition ?? "") isPDF=\(head.isLikelyPDF)")
            }

            // HEAD が 405/403/400 などで情報が取れない場合は GET にフォールバック
            if head.statusCode == 405 || head.statusCode == 403 || head.statusCode == 400 {
                if shouldVerboseLog(for: url) {
                    log("probe: fallback GET after HEAD status=\(head.statusCode ?? -1) url=\(url.absoluteString)")
                }
                if let get = await request(url: url, method: "GET", session: session, rangeFirstByteOnly: true) {
                    return get
                }
                return head
            }

            // HEAD は通るが判定できない場合は、Range GET で先頭マジックバイト(%PDF-)を嗅ぐ。
            // NOTE: 一般の HTML ページに対して無差別に GET すると重いので、「ヒントがあるURL」だけ行う。
            if !head.isLikelyPDF {
                let status = head.statusCode ?? 0
                let ctLower = (head.contentType ?? "").lowercased()
                let headersMissing = (head.contentType == nil && head.contentDisposition == nil)
                let ambiguousType = ctLower.isEmpty || ctLower.contains("application/octet-stream")
                let effectiveURL = canonicalURLForProbe(head.finalURL ?? url)
                let noUsefulExt = effectiveURL.pathExtension.isEmpty

                // 1) headers missing/ambiguous & no extension => sniff
                if (200...299).contains(status) && (headersMissing || ambiguousType) && noUsefulExt {
                    if shouldVerboseLog(for: url) {
                        log("probe: fallback GET range sniff (HEAD headers missing/ambiguous) url=\(url.absoluteString)")
                    }
                    if let get = await request(url: url, method: "GET", session: session, rangeFirstByteOnly: true) {
                        return get
                    }
                }

                // 2) Some servers return text/html on HEAD even though GET returns a PDF/redirect-to-PDF.
                //    Only do this when the URL strongly hints a PDF/download to avoid heavy probing.
                if (200...299).contains(status) && ctLower.contains("text/html") && noUsefulExt && isPDFHintURL(effectiveURL) {
                    if shouldVerboseLog(for: url) {
                        log("probe: fallback GET range sniff (HEAD says text/html but URL hints PDF) url=\(url.absoluteString)")
                    }
                    if let get = await request(url: url, method: "GET", session: session, rangeFirstByteOnly: true) {
                        return get
                    }
                }
            }

            return head
        }

        // 2) GET fallback
        if shouldVerboseLog(for: url) {
            log("probe: HEAD failed; trying GET url=\(url.absoluteString)")
        }
        if let get = await request(url: url, method: "GET", session: session, rangeFirstByteOnly: true) {
            return get
        }

        if shouldVerboseLog(for: url) {
            log("probe: failed url=\(url.absoluteString)")
        }
        return Result(
            requestedURL: url,
            finalURL: nil,
            statusCode: nil,
            contentType: nil,
            contentDisposition: nil,
            isLikelyPDF: false,
            errorDescription: "request failed"
        )
    }

    private static func request(
        url: URL,
        method: String,
        session: URLSession,
        rangeFirstByteOnly: Bool = false
    ) async -> Result? {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("inf6/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("application/pdf,application/octet-stream;q=0.9,text/html;q=0.8,*/*;q=0.7", forHTTPHeaderField: "Accept")
        if rangeFirstByteOnly {
            // Fetch a small prefix so we can sniff magic bytes (e.g., "%PDF-") when headers are unhelpful.
            req.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
        }

        if shouldVerboseLog(for: url) {
            log("request: \(method) url=\(url.absoluteString) rangeFirstByteOnly=\(rangeFirstByteOnly)")
        }

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                if shouldVerboseLog(for: url) {
                    log("request: non-http response method=\(method) url=\(url.absoluteString) final=\(resp.url?.absoluteString ?? "")")
                }
                return Result(
                    requestedURL: url,
                    finalURL: resp.url,
                    statusCode: nil,
                    contentType: nil,
                    contentDisposition: nil,
                    isLikelyPDF: false,
                    errorDescription: "non-http response"
                )
            }

            let ct = http.value(forHTTPHeaderField: "Content-Type")
            let cd = http.value(forHTTPHeaderField: "Content-Disposition")
            let finalURL = http.url

            let sniffedPDF = (method == "GET") ? dataLooksLikePDF(data) : false
            let isPDF = looksLikePDF(url: finalURL ?? url, contentType: ct, contentDisposition: cd) || sniffedPDF

            if shouldVerboseLog(for: finalURL ?? url) {
                log("request: response method=\(method) requested=\(url.absoluteString) status=\(http.statusCode) final=\(finalURL?.absoluteString ?? "") ct=\(ct ?? "") cd=\(cd ?? "") sniffedPDF=\(sniffedPDF) isPDF=\(isPDF)")
            }

            return Result(
                requestedURL: url,
                finalURL: finalURL,
                statusCode: http.statusCode,
                contentType: ct,
                contentDisposition: cd,
                isLikelyPDF: isPDF,
                errorDescription: nil
            )
        } catch {
            if shouldVerboseLog(for: url) {
                log("request: error method=\(method) url=\(url.absoluteString) error=\(error.localizedDescription)")
            }
            return Result(
                requestedURL: url,
                finalURL: nil,
                statusCode: nil,
                contentType: nil,
                contentDisposition: nil,
                isLikelyPDF: false,
                errorDescription: error.localizedDescription
            )
        }
    }

    private static func looksLikePDF(url: URL, contentType: String?, contentDisposition: String?) -> Bool {
        // URL拡張子
        if url.pathExtension.lowercased() == "pdf" { return true }
        // Content-Type
        if let ct = contentType?.lowercased(), ct.contains("application/pdf") { return true }
        // Content-Disposition filename
        if let cd = contentDisposition?.lowercased(), cd.contains(".pdf") { return true }
        return false
    }

    private static func dataLooksLikePDF(_ data: Data) -> Bool {
        // PDF files typically start with "%PDF-".
        guard data.count >= 5 else { return false }
        let prefix = data.prefix(5)
        return prefix.elementsEqual([0x25, 0x50, 0x44, 0x46, 0x2D])
    }

    private static func resolveURL(_ raw: String, baseURL: URL) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // Remove wrapping quotes early.
        s = stripQuotes(s)

        // Trim common junk that leaks from inline(http) / css url(...) / attributes.
        s = sanitizeRawURLString(s)
        guard !s.isEmpty else { return nil }

        // Fast rejects
        if s.hasPrefix("#") { return nil }
        let lower = s.lowercased()
        if lower.hasPrefix("javascript:") { return nil }
        if lower.hasPrefix("mailto:") { return nil }
        if lower.hasPrefix("tel:") { return nil }
        if lower.hasPrefix("data:") { return nil } // 画像のdata URI等はURL検査対象外
        if lower.hasPrefix("css:") { return nil }  // css:fb.css... などの擬似スキームはURLではない
        if lower.hasPrefix("about:") { return nil }
        if lower.hasPrefix("blob:") { return nil }

        // Decode common escapes seen in DOM/inline JS.
        var normalized = decodeCommonEscapes(s)

        // Handle scheme-relative URLs like "//example.com/file".
        if normalized.hasPrefix("//") {
            let baseScheme = (baseURL.scheme?.isEmpty == false) ? (baseURL.scheme!) : "https"
            normalized = baseScheme + ":" + normalized
        }

        if let u = URL(string: normalized) {
            if let scheme = u.scheme?.lowercased(), !scheme.isEmpty {
                // Only allow HTTP(S) for probing.
                guard scheme == "http" || scheme == "https" else { return nil }
                return u
            }
            return URL(string: normalized, relativeTo: baseURL)?.absoluteURL // relative
        }
        return nil
    }

    private static func parseSrcsetURLs(_ srcset: String) -> [String] {
        // "a.jpg 320w, b.jpg 640w" の左側だけ取る
        return srcset
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { part -> String? in
                let comps = part.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                return comps.first.map(String.init)
            }
    }

    private static func stripQuotes(_ s: String) -> String {
        var x = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if x.hasPrefix("\"") && x.hasSuffix("\"") && x.count >= 2 { x = String(x.dropFirst().dropLast()) }
        if x.hasPrefix("'") && x.hasSuffix("'") && x.count >= 2 { x = String(x.dropFirst().dropLast()) }
        return x
    }

    private static func decodeCommonEscapes(_ s: String) -> String {
        var x = s

        // HTML entities commonly observed on WordPress/JDLA
        x = x.replacingOccurrences(of: "&amp;", with: "&")
        x = x.replacingOccurrences(of: "&#038;", with: "&")
        x = x.replacingOccurrences(of: "&#38;", with: "&")

        // JSON / JS escapes
        x = x.replacingOccurrences(of: "\\/", with: "/")
        x = x.replacingOccurrences(of: "\\u0026", with: "&")
        x = x.replacingOccurrences(of: "\\u003d", with: "=")
        x = x.replacingOccurrences(of: "\\u003D", with: "=")
        x = x.replacingOccurrences(of: "\\x26", with: "&")
        x = x.replacingOccurrences(of: "\\x3d", with: "=")
        x = x.replacingOccurrences(of: "\\x3D", with: "=")

        // Percent-encoded backslash sequences (e.g. %5Cx3d)
        x = x.replacingOccurrences(of: "%5Cx26", with: "&")
        x = x.replacingOccurrences(of: "%5cx26", with: "&")
        x = x.replacingOccurrences(of: "%5Cx3d", with: "=")
        x = x.replacingOccurrences(of: "%5cx3d", with: "=")
        x = x.replacingOccurrences(of: "%5Cx3D", with: "=")
        x = x.replacingOccurrences(of: "%5cx3D", with: "=")

        return x
    }

    private static func sanitizeRawURLString(_ s: String) -> String {
        var x = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !x.isEmpty else { return "" }

        // If a CSS/url() leak like ".png);background-position:...", cut at the first ')'
        if let r = x.range(of: ")") {
            let after = x[r.upperBound...]
            if after.lowercased().contains("background") || after.contains(";") {
                x = String(x[..<r.lowerBound])
            }
        }

        // Drop trailing punctuation that often appears in inline/http and CSS contexts.
        while let last = x.last {
            if last == ")" || last == "]" || last == "}" || last == "," || last == ";" {
                x.removeLast()
                continue
            }
            break
        }

        // Trim again after edits
        x = x.trimmingCharacters(in: .whitespacesAndNewlines)
        x = stripQuotes(x)
        return x
    }

    private static func shouldSkipCandidateURL(_ url: URL) -> Bool {
        // Only probe http(s). Anything else (css:, data:, blob:, file:, etc.) is noise for network probing.
        if let scheme = url.scheme?.lowercased(), scheme != "http" && scheme != "https" {
            return true
        }
        // Never skip obvious PDFs
        if url.pathExtension.lowercased() == "pdf" { return false }

        // Reject common static assets
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty {
            switch ext {
            case "png", "jpg", "jpeg", "gif", "webp", "svg", "ico",
                 "js", "css", "map",
                 "woff", "woff2", "ttf", "otf", "eot",
                 "mp3", "mp4", "m4a", "mov",
                 "json", "xml"
                :
                return true
            default:
                break
            }
        }

        // Reject obvious namespace/metadata URLs and tracker hosts that are never PDFs.
        if let host = url.host?.lowercased() {
            if host == "schema.org" || host == "www.schema.org" { return true }
            if host == "ogp.me" || host == "www.ogp.me" { return true }
            if host.hasSuffix("scheme.org") || host.hasSuffix("schema.org") { return true }
            if host.hasSuffix("docodoco.jp") || host.hasSuffix("surfpoint.jp") { return true }
            if host.hasSuffix("facebook.com") || host.hasSuffix("connect.facebook.net") { return true }
            if host.hasSuffix("instagram.com") { return true }
            if host.hasSuffix("linkedin.com") { return true }
            if host.hasSuffix("youtube.com") { return true }
            if host.hasSuffix("x.com") || host.hasSuffix("twitter.com") || host.hasSuffix("t.co") { return true }
            if host.hasSuffix("google.com") || host.hasSuffix("googleapis.com") { return true }
            if host.hasSuffix("gstatic.com") { return true }
            if host.hasSuffix("googletagmanager.com") { return true }
            if host.hasSuffix("google-analytics.com") { return true }
            if host.hasSuffix("unpkg.com") { return true }
        }

        // Clip weird namespace fragments like ".../ns#" which are not navigations.
        if url.absoluteString.hasSuffix("#") { return true }

        // Reject date-only paths like /2025-11-26 which are often calendar widgets, not documents.
        // Keep anything that looks like a PDF/download.
        if !isPDFHintURL(url) {
            let p = url.path
            if matches(p, pattern: #"^/20\d{2}-\d{2}-\d{2}/?$"#).isEmpty == false {
                return true
            }
        }

        return false
    }

    // MARK: - Regex helpers

    private struct RegexMatch {
        let ns: NSTextCheckingResult
        let text: NSString
        func group(_ i: Int) -> String? {
            guard i <= ns.numberOfRanges - 1 else { return nil }
            let r = ns.range(at: i)
            if r.location == NSNotFound { return nil }
            return text.substring(with: r)
        }
    }

    private static func matches(_ text: String, pattern: String) -> [RegexMatch] {
        let ns = text as NSString
        do {
            let re = try NSRegularExpression(pattern: pattern, options: [])
            return re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
                .map { RegexMatch(ns: $0, text: ns) }
        } catch {
            return []
        }
    }
}
