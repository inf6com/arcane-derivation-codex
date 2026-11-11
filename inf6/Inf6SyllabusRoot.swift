//
//  Inf6SyllabusRoot.swift
//  inf6
//
//  Created by decopin on 2025/11/30.
//

import SwiftUI

/// Local syllabus roots shown under "シラバス".
enum Inf6SyllabusRoot: String, CaseIterable, Identifiable {
    case localDefault = "localDefault"
    case localOther = "localOther"

    var id: String { rawValue }

    func displayLabel() -> String {
        // ProperNouns を最優先。未設定の場合は、この enum の責務として固定ラベルを返す。
        switch self {
        case .localDefault:
            let pn = Inf6ProperNouns.localDefaultRootDisplayName
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !pn.isEmpty { return pn }
            return Inf6Lang.text("JDLA", "JDLA")

        case .localOther:
            let pn = Inf6ProperNouns.localOtherRootDisplayName
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !pn.isEmpty { return pn }
            return Inf6Lang.text("その他", "Other")
        }
    }
}
