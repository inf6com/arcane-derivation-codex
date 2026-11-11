import Foundation
import UIKit

extension InlinePDFPagesView {
    enum Inf6RichTextCommand: Equatable {
        case deleteSelection
        case setHighlight(Inf6Highlight?)
        case toggleUnderline
        case setTextColor(Inf6TextColor?)
    }

    enum Inf6Highlight: String, CaseIterable {
        case yellow, green, pink
    }

    enum Inf6TextColor: String, CaseIterable {
        case red, blue, orange
    }

    static func _inf6UIHighlightColor(_ h: Inf6Highlight) -> Any {
        #if canImport(UIKit)
        switch h {
        case .yellow: return UIColor.systemYellow.withAlphaComponent(0.45)
        case .green:  return UIColor.systemGreen.withAlphaComponent(0.38)
        case .pink:   return UIColor.systemPink.withAlphaComponent(0.30)
        }
        #else
        return 0
        #endif
    }

    static func _inf6UITextColor(_ c: Inf6TextColor) -> Any {
        #if canImport(UIKit)
        switch c {
        case .red:    return UIColor.systemRed
        case .blue:   return UIColor.systemBlue
        case .orange: return UIColor.systemOrange
        }
        #else
        return 0
        #endif
    }
}
