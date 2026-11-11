//
//  Inf6PaperGraphView.swift
//  inf6
//
//  論文中心の知識グラフ（WKWebView + D3.js 版）。
//  iOS / Electron で同一の D3 force simulation コードを共有。
//

import Foundation
import SwiftUI
import WebKit

// MARK: - Inf6PaperGraphView

struct Inf6PaperGraphView: View {

    var onSelectPaper: ((Inf6CorePaper) -> Void)?

    var body: some View {
        _PaperGraphWebView(onSelectPaper: onSelectPaper)
            .ignoresSafeArea()
    }
}

// MARK: - WKWebView wrapper

private struct _PaperGraphWebView: UIViewRepresentable {

    var onSelectPaper: ((Inf6CorePaper) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(onSelectPaper: onSelectPaper) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "paperTap")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false

        // Load HTML from bundle
        if let url = Bundle.main.url(forResource: "paper_graph", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView? {
            didSet { webView?.navigationDelegate = self }
        }
        var onSelectPaper: ((Inf6CorePaper) -> Void)?
        private var papers: [Inf6CorePaper] = []

        init(onSelectPaper: ((Inf6CorePaper) -> Void)?) {
            self.onSelectPaper = onSelectPaper
        }

        // Page loaded → inject paper data
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            _injectPapers()
        }

        func userContentController(_ uc: WKUserContentController,
                                     didReceive message: WKScriptMessage) {
            guard message.name == "paperTap",
                  let paperId = message.body as? String,
                  let paper = papers.first(where: { $0.id == paperId }) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onSelectPaper?(paper)
            }
        }

        private func _injectPapers() {
            let store = Inf6CorePaperStore.shared
            var loadedPapers = store.papers

            // Fallback: disk JSON
            if loadedPapers.isEmpty {
                loadedPapers = _loadPapersFromDisk()
            }

            papers = loadedPapers

            // Convert to JSON for JS
            let jsonArray: [[String: Any]] = loadedPapers.map { p in
                var dict: [String: Any] = [
                    "id": p.id,
                    "title": p.title,
                    "tags": p.tags,
                    "provider": p.provider
                ]
                if let aid = p.arxivId { dict["arxiv_id"] = aid }
                if let purl = p.pdfURL { dict["pdf_url"] = purl }
                return dict
            }

            guard let data = try? JSONSerialization.data(withJSONObject: jsonArray),
                  let jsonStr = String(data: data, encoding: .utf8) else { return }

            let escaped = jsonStr
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")

            let js = "loadPapers('\(escaped)');"
            webView?.evaluateJavaScript(js) { _, error in
                if let error { print("[PaperGraph] JS error: \(error)") }
            }
        }

        private func _loadPapersFromDisk() -> [Inf6CorePaper] {
            let papersRoot = Inf6DataRoot.url().appendingPathComponent("papers", isDirectory: true)

            var result: [Inf6CorePaper] = []
            let fm = FileManager.default

            for subdir in ["arxiv", "direct", "pubmed", "acl"] {
                let dir = papersRoot.appendingPathComponent(subdir)
                guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                    .filter({ $0.pathExtension == "json" }) else { continue }
                for file in files {
                    guard let data = try? Data(contentsOf: file),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    let raw = json["raw"] as? [String: Any]
                    let id = (raw?["id"] as? String) ?? file.deletingPathExtension().lastPathComponent
                    let title = (json["title"] as? String) ?? id
                    let provider = (json["provider"] as? String) ?? subdir
                    let arxivId = (raw?["arxiv_id"] as? String) ?? (json["arxiv_id"] as? String)
                    let pdfURL = json["source_url"] as? String
                    let tags: [String] = (json["tags"] as? [String]) ?? []
                    result.append(Inf6CorePaper(
                        id: id, title: title, titleEn: json["title_en"] as? String, provider: provider,
                        arxivId: arxivId, pdfURL: pdfURL, year: json["year"] as? Int, tags: tags
                    ))
                }
            }
            return result
        }
    }
}
