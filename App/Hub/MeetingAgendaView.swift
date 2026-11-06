import SpeakerKit
import SwiftUI

/// The meetings coming up in the Mac's calendars, today and the next few days.
struct MeetingUpcomingList: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(MeetingsStore.self) private var meetings

    let french: Bool
    let record: (MeetingCalendarStore.Event) -> Void

    private var events: [MeetingCalendarStore.Event] {
        let now = Date()
        let horizon = Calendar.current.date(byAdding: .day, value: 3, to: now) ?? now
        return meetings.calendar.events
            .filter { $0.end > now && $0.start < horizon }
            .sorted { $0.start < $1.start }
            .prefix(4)
            .map { $0 }
    }

    var body: some View {
        HubSectionHeader(verbatim: tr(french, "À venir", "Coming up")) {
            if meetings.calendar.connected {
                Menu {
                    ForEach(meetings.calendar.calendars) { calendar in
                        Toggle(
                            calendar.title,
                            isOn: Binding(
                                get: { !meetings.calendar.hiddenCalendars.contains(calendar.id) },
                                set: { _ in meetings.calendar.toggleCalendar(calendar.id) }))
                    }
                    Divider()
                    Button(tr(french, "Actualiser", "Refresh")) { meetings.calendar.refresh() }
                } label: {
                    Text(tr(french, "Calendriers", "Calendars"))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(theme.secondaryInk).fixedSize()
            }
        }

        if !meetings.calendar.connected {
            HStack(spacing: 10) {
                Text(
                    meetings.calendar.denied
                        ? (tr(french, "L’accès au calendrier est refusé.", "Calendar access is denied."))
                        : (tr(french, "Tes réunions du calendrier apparaîtront ici.", "Your calendar meetings will appear here."))
                )
                .font(VoxoLTypography.font(size: 13))
                .foregroundStyle(theme.secondaryInk)
                Spacer()
                if meetings.calendar.denied {
                    Button(tr(french, "Ouvrir les Réglages", "Open Settings"), action: meetings.calendar.openSettings)
                        .buttonStyle(HubButtonStyle(kind: .secondary))
                } else {
                    Button(tr(french, "Connecter le calendrier", "Connect calendar")) {
                        Task { await meetings.calendar.connect() }
                    }
                    .buttonStyle(HubButtonStyle(kind: .secondary))
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 40)
        } else if events.isEmpty {
            Text(tr(french, "Rien de prévu dans les trois prochains jours.", "Nothing planned in the next three days."))
                .font(VoxoLTypography.font(size: 13))
                .foregroundStyle(theme.secondaryInk)
                .padding(.horizontal, 10)
        } else {
            VStack(spacing: 2) {
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                    row(event, next: index == 0)
                }
            }
        }
    }

    private func row(_ event: MeetingCalendarStore.Event, next: Bool) -> some View {
        HStack(spacing: 14) {
            Text(verbatim: time(event.start))
                .font(VoxoLTypography.font(size: 13, weight: .medium))
                .foregroundStyle(theme.ink)
                .monospacedDigit()
                .frame(width: 88, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: event.title)
                    .font(VoxoLTypography.font(size: 14, weight: .medium))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Text(verbatim: detail(event))
                    .font(VoxoLTypography.font(size: 12))
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let url = event.joinURL {
                Button(tr(french, "Rejoindre", "Join")) { NSWorkspace.shared.open(url) }
                    .buttonStyle(HubButtonStyle(kind: next ? .onWell : .ghost))
            }
            Button(tr(french, "Enregistrer", "Record")) { record(event) }
                .buttonStyle(HubButtonStyle(kind: next ? .onWell : .ghost))
                .disabled(meetings.busy || meetings.recorder.completedURL != nil)
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(
            next ? theme.well : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func time(_ date: Date) -> String {
        let locale = Locale(identifier: tr(french, "fr", "en"))
        let hour = date.formatted(.dateTime.hour().minute().locale(locale))
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return hour }
        if calendar.isDateInTomorrow(date) { return tr(french, "Demain \(hour)", "Tomorrow \(hour)") }
        return "\(date.formatted(.dateTime.weekday(.abbreviated).locale(locale))) \(hour)"
    }

    private func detail(_ event: MeetingCalendarStore.Event) -> String {
        let minutes = Int(event.end.timeIntervalSince(event.start) / 60)
        var parts = ["\(minutes) min", event.calendar]
        if let host = event.joinURL?.host(percentEncoded: false) {
            parts.insert(host.replacingOccurrences(of: "www.", with: ""), at: 1)
        }
        return parts.joined(separator: " · ")
    }
}
