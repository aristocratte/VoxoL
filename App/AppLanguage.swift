import SwiftUI
import TextProcessingKit

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case french = "fr"

    var id: String { rawValue }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    var displayName: String {
        switch self {
        case .english:
            "English"
        case .french:
            "Français"
        }
    }

    static var preferred: AppLanguage {
        guard let preferredIdentifier = Locale.preferredLanguages.first else {
            return .english
        }
        return preferredIdentifier.hasPrefix("fr") ? .french : .english
    }
}

enum DictationLanguagePreference: String, CaseIterable, Identifiable {
    case automatic
    case french
    case english

    var id: String { rawValue }

    /// BCP-47 prefix for ASR decoding, or nil when the user has not chosen.
    ///
    /// Automatic returns nil on purpose: the French decoding bias suppresses
    /// English function words, so guessing a language would strip an English
    /// dictation rather than merely mis-tune it.
    var decodingLanguageCode: String? {
        switch self {
        case .automatic: nil
        case .french: "fr"
        case .english: "en"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .automatic:
            "Auto"
        case .french:
            "Français"
        case .english:
            "English"
        }
    }

    var localeIdentifier: String? {
        switch self {
        case .automatic:
            nil
        case .french:
            "fr_FR"
        case .english:
            "en_US"
        }
    }

    var textLanguage: TextLanguage? {
        switch self {
        case .automatic:
            nil
        case .french:
            .french
        case .english:
            .english
        }
    }

    static var preferred: DictationLanguagePreference {
        AppLanguage.preferred == .french ? .french : .english
    }
}
