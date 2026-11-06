import SwiftUI
import WebKit

struct MathMLView: UIViewRepresentable {
    let source: String

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.isOpaque = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        do {
            try MathMLValidator().validate(source)
        } catch {
            let message = htmlEscaped(error.localizedDescription)
            let html = "<html><body><p style='color:#b00020;font-family:-apple-system'>\(message)</p></body></html>"
            view.loadHTMLString(html, baseURL: nil)
            return
        }
        let escaped = source.replacingOccurrences(of: "&", with: "&amp;")
        let html = "<html><head><meta name='viewport' content='width=device-width, initial-scale=1.0'><style>body{font-size:28px;text-align:center;background:transparent}math{font-size:1.2em}</style></head><body>\(escaped)</body></html>"
        view.loadHTMLString(html, baseURL: nil)
    }

    private func htmlEscaped(_ source: String) -> String {
        source
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
