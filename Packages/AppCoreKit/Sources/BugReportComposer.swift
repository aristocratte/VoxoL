import Foundation

/// Builds a bug report a user can send without leaking what they dictated.
///
/// A local dictation app carries an implicit promise: the audio and the text
/// never leave the machine. A crash reporter that quietly uploads the last
/// transcript would break that promise more thoroughly than any feature could
/// repair, so this composes a report from counters, timings and machine facts
/// only — never a transcript, never a filename the user dictated into, never
/// audio.
///
/// The report is assembled locally and handed to the user. Nothing is sent
/// automatically; opening the issue is their action.
public enum BugReportComposer {
    /// Where the prefilled issue is opened.
    public static let issueBaseURL = "https://github.com/arhesstide/voxol/issues/new"

    /// GitHub rejects a URL far past this, and browsers truncate earlier.
    private static let maximumBodyCharacters = 6_000

    /// Machine facts a maintainer needs, and nothing that identifies its owner.
    public struct Environment: Sendable {
        /// Marketing version of the running build.
        public var applicationVersion: String
        /// Build number, to distinguish two builds of one version.
        public var buildNumber: String
        /// macOS version string.
        public var systemVersion: String
        /// `hw.model`, e.g. `Mac16,6`; identifies the chip generation.
        public var hardwareModel: String
        /// Logical cores, for a performance report.
        public var processorCount: Int
        /// Installed memory, rounded to whole gigabytes.
        public var physicalMemoryGigabytes: Double
        /// Current locale, which changes text processing behaviour.
        public var locale: String

        /// Reads the running process and machine.
        public static func current() -> Environment {
            let info = Bundle.main.infoDictionary ?? [:]
            let process = ProcessInfo.processInfo
            return Environment(
                applicationVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
                buildNumber: info["CFBundleVersion"] as? String ?? "unknown",
                systemVersion: process.operatingSystemVersionString,
                hardwareModel: hardwareIdentifier(),
                processorCount: process.processorCount,
                physicalMemoryGigabytes: (Double(process.physicalMemory) / 1_073_741_824).rounded(),
                locale: Locale.current.identifier
            )
        }

        /// `sysctl hw.model`, e.g. `Mac16,6`. Identifies the chip generation,
        /// which is what an Apple Silicon performance report needs, and nothing
        /// that identifies the machine's owner.
        private static func hardwareIdentifier() -> String {
            var size = 0
            guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
                return "unknown"
            }
            var bytes = [CChar](repeating: 0, count: size)
            guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else {
                return "unknown"
            }
            return String(cString: bytes)
        }
    }

    /// Renders the Markdown body a maintainer will read.
    ///
    /// `diagnostics` is the JSON from `diagnosticsExportData()`, which carries
    /// timings and counts. It is included verbatim so a performance report is
    /// actionable, and truncated rather than dropped if the issue URL would
    /// overflow — a partial timing trace still beats none.
    public static func body(
        summary: String,
        steps: String,
        environment: Environment,
        diagnostics: String?
    ) -> String {
        var sections = [
            "## What happened",
            summary.isEmpty ? "_(not described)_" : summary,
            "",
            "## Steps to reproduce",
            steps.isEmpty ? "_(not described)_" : steps,
            "",
            "## Environment",
            "| | |",
            "| --- | --- |",
            "| VoxoL | \(environment.applicationVersion) (\(environment.buildNumber)) |",
            "| macOS | \(environment.systemVersion) |",
            "| Hardware | \(environment.hardwareModel) |",
            "| Cores | \(environment.processorCount) |",
            "| Memory | \(Int(environment.physicalMemoryGigabytes)) GB |",
            "| Locale | \(environment.locale) |",
        ]
        if let diagnostics, !diagnostics.isEmpty {
            let budget = maximumBodyCharacters - sections.joined(separator: "\n").count - 200
            let payload =
                diagnostics.count > budget && budget > 0
                ? String(diagnostics.prefix(budget)) + "\n… truncated"
                : diagnostics
            sections.append(contentsOf: [
                "",
                "## Diagnostics",
                "Timings and counters only — no transcript, no audio.",
                "",
                "```json",
                payload,
                "```",
            ])
        }
        return sections.joined(separator: "\n")
    }

    /// The prefilled issue URL, or nil when it cannot be formed.
    public static func issueURL(title: String, body: String) -> URL? {
        var components = URLComponents(string: issueBaseURL)
        components?.queryItems = [
            URLQueryItem(name: "title", value: title.isEmpty ? "VoxoL bug report" : title),
            URLQueryItem(name: "body", value: body),
            URLQueryItem(name: "labels", value: "bug"),
        ]
        return components?.url
    }
}
