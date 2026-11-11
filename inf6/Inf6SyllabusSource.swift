import SwiftUI

/// Compass sources. Remote API and local YAML.
///
/// IMPORTANT:
/// - `Picker(selection:)` works best when the selection type is `Hashable`.
/// - We keep legacy aliases so older call sites still compile.
public enum Inf6SyllabusSource: String, CaseIterable, Identifiable, Hashable {
    case explorecourses = "explorecourses"
    case localYAML = "local"

    public var id: String { rawValue }

    // Backward-compatibility: older call sites used `.remoteAPI`.
    public static var remoteAPI: Self { .explorecourses }

    public func displayLabel() -> String {
        switch self {
        case .explorecourses:
            // Keep this enum independent from Compass config files.
            return Inf6Lang.text("Stanford explorecourses", "Stanford explorecourses")

        case .localYAML:
            // Keep this enum independent from Compass config files.
            return Inf6Lang.text("資格・団体", "Qualifications")
        }
    }
}
