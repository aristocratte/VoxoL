import Foundation

/// The values settings take before anyone opens Settings.
///
/// Every preference used to default to whatever `UserDefaults` returns for a
/// missing key, which for a `Bool` is `false`. That is a fine accident for most
/// flags and a bad one for two of them: history and learning were off until the
/// user found the switch, so a fresh install recorded nothing, the dashboard
/// showed zeroes forever, and the dictionary never learned from a correction.
/// A feature nobody knows to turn on does not exist.
///
/// Registered rather than written: the registration domain is consulted only
/// when the user domain has no value, so someone who deliberately turned
/// history off keeps it off. This changes the default, not anyone's choice.
enum DefaultSettings {
    static func register() {
        UserDefaults.standard.register(defaults: [
            // Local by construction — the transcripts never leave the machine —
            // so the cost of keeping them is a file on disk, and the benefit is
            // that the dashboard means something and a mis-recognised word can
            // still be found and corrected an hour later. Private mode remains
            // one switch away and still overrides this.
            "voxol.historyEnabled": true,
            // Corrections are the only signal that says which words this
            // particular speaker gets wrong. Discarding them by default threw
            // away the app's ability to improve on the person using it.
            "voxol.learningEnabled": true,
        ])
    }
}
