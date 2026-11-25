import SwiftUI

enum DictationCleanupMode: String, CaseIterable, Identifiable {
    case faithful
    case raw
    case rewrite

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .faithful:
            "Faithful"
        case .raw:
            "Raw"
        case .rewrite:
            "Rewrite"
        }
    }
}

enum ActivationMode: String, CaseIterable, Identifiable {
    case hold
    case toggle

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .hold:
            "Hold"
        case .toggle:
            "Toggle"
        }
    }
}
