import AppKit
@preconcurrency import EventKit
import Observation

/// EventKit stays on the main actor; views receive small value snapshots only.
@MainActor @Observable
final class MeetingCalendarStore {
    struct Event: Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let calendar: String
        let location: String?
        let joinURL: URL?
    }

    private(set) var events: [Event] = []
    private(set) var connected = false
    private(set) var loading = false
    private(set) var denied = false
    var failure: String?
    @ObservationIgnored private let store = EKEventStore()

    func connect() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            _ = try await store.requestFullAccessToEvents()
            refresh()
        } catch { failure = error.localizedDescription }
    }

    func refresh() {
        let status = EKEventStore.authorizationStatus(for: .event)
        connected = status == .fullAccess
        denied = status == .denied || status == .restricted || status == .writeOnly
        events = []
        guard connected else { return }
        failure = nil
        let now = Date()
        let until = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
        let predicate = store.predicateForEvents(withStart: now, end: until, calendars: nil)
        events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .prefix(12)
            .map { event in
                Event(
                    id: "\(event.calendarItemIdentifier)-\(event.startDate.timeIntervalSince1970)",
                    title: event.title ?? String(localized: "Meeting"),
                    start: event.startDate, end: event.endDate, calendar: event.calendar.title,
                    location: event.location,
                    joinURL: Self.conferenceURL(
                        event.url, location: event.location, notes: event.notes))
            }
    }

    // Only present recognizable conference links, never arbitrary URLs from notes.
    private static func conferenceURL(_ url: URL?, location: String?, notes: String?) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let text = [location, notes].compactMap { $0 }.joined(separator: "\n")
        let candidates =
            [url].compactMap { $0 }
            + (detector?.matches(
                in: text, range: NSRange(text.startIndex..., in: text)
            ).compactMap(\.url) ?? [])
        let hosts = [
            "zoom.us", "teams.microsoft.com", "teams.live.com", "meet.google.com", "webex.com",
        ]
        return candidates.first { candidate in
            guard candidate.scheme == "https", let host = candidate.host?.lowercased() else {
                return false
            }
            return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }

    func openSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        {
            NSWorkspace.shared.open(url)
        }
    }
}
