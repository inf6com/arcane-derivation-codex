import Foundation
import UIKit

extension InlinePDFPagesView {
    static func _inf6RTFData(from attributed: NSAttributedString) -> Data? {
        #if canImport(UIKit)
        let m = NSMutableAttributedString(attributedString: attributed)
        let full = NSRange(location: 0, length: m.length)

        m.enumerateAttribute(.foregroundColor, in: full, options: []) { v, r, _ in
            guard let c = v as? UIColor else { return }
            if Self._inf6IsDefaultForegroundUIColor(c) {
                m.removeAttribute(.foregroundColor, range: r)
            }
        }

        let base: NSAttributedString = m
        #else
        let base: NSAttributedString = attributed
        #endif

        let fullRange = NSRange(location: 0, length: base.length)
        return try? base.data(
            from: fullRange,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    #if canImport(UIKit)
    static func _inf6IsDefaultForegroundUIColor(_ c: UIColor) -> Bool {
        let resolved = c.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))

        guard let comps = resolved.cgColor.components, !comps.isEmpty else {
            return false
        }

        let r: CGFloat
        let g: CGFloat
        let b: CGFloat
        if comps.count >= 3 {
            r = comps[0]
            g = comps[1]
            b = comps[2]
        } else if comps.count == 2 {
            r = comps[0]
            g = comps[0]
            b = comps[0]
        } else {
            return false
        }

        let tol: CGFloat = 0.03
        let isGray = abs(r - g) < tol && abs(g - b) < tol
        guard isGray else { return false }

        return r < 0.25 || r > 0.85
    }
    #endif

    static func _inf6AttributedFromNote(_ note: Inf6ExtraNote, fontSize: CGFloat) -> NSAttributedString {
        #if canImport(UIKit)
        let baseFont = UIFont.systemFont(ofSize: max(10, fontSize))
        let monoFont = UIFont.monospacedSystemFont(ofSize: max(9, fontSize - 1), weight: .regular)
        let sectionFont = UIFont.systemFont(ofSize: max(10, fontSize), weight: .semibold)
        #else
        return NSAttributedString(string: note.text)
        #endif

        if let rtf = note.rtf,
           let ns = try? NSAttributedString(
            data: rtf,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
           ) {
            let m = NSMutableAttributedString(attributedString: ns)
            m.addAttribute(.font, value: baseFont, range: NSRange(location: 0, length: m.length))

            let full = NSRange(location: 0, length: m.length)
            m.enumerateAttribute(.foregroundColor, in: full, options: []) { v, r, _ in
                guard let c = v as? UIColor else { return }
                if Self._inf6IsDefaultForegroundUIColor(c) {
                    m.removeAttribute(.foregroundColor, range: r)
                }
            }

            return m
        }

        if let structured = note.structuredExplain {
            return _inf6AttributedFromStructuredExplain(structured, fontSize: fontSize)
        }

        let sectionHeadings: Set<String> = [
            "再構成表:", "Reconstructed table:",
            "列の意味:", "Column meanings:",
            "行の意味:", "Row meanings:"
        ]

        func isMarkdownTableLine(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.contains("|") else { return false }
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
                return true
            }
            return trimmed.split(separator: "|", omittingEmptySubsequences: false).count >= 3
        }

        let out = NSMutableAttributedString()
        let lines = note.text.split(separator: "\n", omittingEmptySubsequences: false)
        for (idx, rawLine) in lines.enumerated() {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let font: UIFont
            if sectionHeadings.contains(trimmed) {
                font = sectionFont
            } else if isMarkdownTableLine(line) {
                font = monoFont
            } else {
                font = baseFont
            }
            out.append(NSAttributedString(string: line, attributes: [.font: font]))
            if idx != lines.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
            }
        }
        return out
    }

    static func _plainTextFromStructuredWebExplain(_ structured: Inf6StructuredExplain, lang: String) -> String {
        let isEnglish = lang == "en"
        let answerTitle = isEnglish ? "Answer" : "結論"
        let paperTitle = isEnglish ? "Paper evidence" : "論文内根拠"
        let webTitle = isEnglish ? "External web evidence" : "論文外根拠"
        let sourceTitle = isEnglish ? "Web sources" : "Web出典"
        return [
            answerTitle,
            structured.answer,
            "",
            paperTitle,
            structured.paperEvidence,
            "",
            webTitle,
            structured.webEvidence,
            "",
            sourceTitle,
            structured.webSources
        ].joined(separator: "\n")
    }

    static func _makeStructuredWebExplainNote(_ structured: Inf6StructuredExplain, lang: String) -> Inf6ExtraNote {
        let attributed = _inf6AttributedFromStructuredExplain(structured, fontSize: 16)
        return Inf6ExtraNote(
            text: _plainTextFromStructuredWebExplain(structured, lang: lang),
            rtf: _inf6RTFData(from: attributed),
            structuredExplain: structured
        )
    }

    static func _inf6AttributedFromStructuredExplain(_ structured: Inf6StructuredExplain, fontSize: CGFloat) -> NSAttributedString {
        #if canImport(UIKit)
        let titleFont = UIFont.systemFont(ofSize: max(11, fontSize - 1), weight: .semibold)
        let bodyFont = UIFont.systemFont(ofSize: max(10, fontSize))
        let answerColor = UIColor.label
        let paperColor = UIColor.systemBlue
        let webColor = UIColor.systemRed
        #else
        return NSAttributedString(string: structured.answer)
        #endif

        let out = NSMutableAttributedString()
        func appendBlock(_ title: String, _ body: String, color: UIColor) {
            if out.length > 0 {
                out.append(NSAttributedString(string: "\n\n"))
            }
            out.append(NSAttributedString(
                string: title + "\n",
                attributes: [
                    .font: titleFont,
                    .foregroundColor: color
                ]
            ))
            out.append(NSAttributedString(
                string: body,
                attributes: [
                    .font: bodyFont,
                    .foregroundColor: color
                ]
            ))
        }

        appendBlock("結論", structured.answer, color: answerColor)
        appendBlock("論文内根拠", structured.paperEvidence, color: paperColor)
        appendBlock("論文外根拠", structured.webEvidence, color: webColor)
        appendBlock("Web出典", structured.webSources, color: webColor)
        return out
    }
}
