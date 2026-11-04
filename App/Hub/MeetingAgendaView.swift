import EventKit
import SpeakerKit
import SwiftUI

struct MeetingAgendaView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(MeetingsStore.self) private var meetings
    let french: Bool
    let record: (MeetingCalendarStore.Event) -> Void
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())

    private var days: [Date] {
        let today = Calendar.current.startOfDay(for: Date())
        return (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
    }
    private var events: [MeetingCalendarStore.Event] {
        meetings.calendar.events.filter {
            Calendar.current.isDate($0.start, inSameDayAs: selectedDay)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "calendar").font(.system(size: 18)).foregroundStyle(theme.cobalt)
                VStack(alignment: .leading, spacing: 4) {
                    Text(french ? "À venir" : "Coming up").font(
                        VoxoLTypography.font(size: 20, weight: .semibold))
                    Text(french ? "Votre semaine de conversations" : "Your week of conversations")
                        .font(.system(size: 12)).foregroundStyle(theme.secondaryInk)
                }
                Spacer()
                if meetings.calendar.connected {
                    Menu {
                        ForEach(meetings.calendar.calendars) { calendar in
                            Toggle(
                                calendar.title,
                                isOn: Binding(
                                    get: {
                                        !meetings.calendar.hiddenCalendars.contains(calendar.id)
                                    },
                                    set: { _ in meetings.calendar.toggleCalendar(calendar.id) }))
                        }
                    } label: {
                        Label(
                            french ? "Calendriers" : "Calendars",
                            systemImage: "line.3.horizontal.decrease")
                    }
                    .menuStyle(.borderlessButton).fixedSize().font(.system(size: 12))
                    Button {
                        meetings.calendar.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(MeetingQuietButtonStyle()).help(french ? "Actualiser" : "Refresh")
                } else if meetings.calendar.denied {
                    Button(
                        french ? "Autoriser dans Réglages" : "Allow in Settings",
                        action: meetings.calendar.openSettings
                    )
                    .buttonStyle(MeetingQuietButtonStyle())
                } else {
                    Button(french ? "Connecter le calendrier" : "Connect calendar") {
                        Task { await meetings.calendar.connect() }
                    }.buttonStyle(MeetingQuietButtonStyle()).disabled(meetings.calendar.loading)
                }
                if meetings.calendar.loading { ProgressView().controlSize(.small) }
            }
            if meetings.calendar.connected {
                HStack(spacing: 8) {
                    ForEach(days, id: \.self) { day in
                        dayButton(day)
                    }
                }
                if events.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "sun.max").foregroundStyle(theme.secondaryInk)
                        Text(
                            french
                                ? "Aucune réunion prévue ce jour-là."
                                : "No meetings scheduled for this day."
                        )
                        .font(.system(size: 13)).foregroundStyle(theme.secondaryInk)
                    }.padding(.vertical, 10)
                } else {
                    ForEach(events) { event in
                        MeetingAgendaEventRow(
                            event: event, french: french,
                            disabled: meetings.busy || meetings.recorder.completedURL != nil,
                            record: { record(event) })
                        if event.id != events.last?.id { Divider().overlay(theme.line) }
                    }
                }
            } else {
                Text(
                    french
                        ? "Retrouvez les événements des comptes iCloud, Google ou Exchange configurés dans Calendrier sur ce Mac. Vous pouvez aussi enregistrer une réunion spontanée."
                        : "See events from iCloud, Google or Exchange accounts set up in Calendar on this Mac. You can also record a spontaneous meeting."
                )
                .font(.system(size: 13)).foregroundStyle(theme.secondaryInk).lineSpacing(4)
            }
            if let error = meetings.calendar.failure {
                Text(error).font(.system(size: 12)).foregroundStyle(theme.warning)
            }
        }
        .padding(24).background(theme.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(theme.line))
        .padding(.bottom, 30)
        .task { meetings.calendar.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            meetings.calendar.refresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            meetings.calendar.refresh()
        }
    }

    private func dayButton(_ day: Date) -> some View {
        let selected = Calendar.current.isDate(day, inSameDayAs: selectedDay)
        let count = meetings.calendar.events.filter {
            Calendar.current.isDate($0.start, inSameDayAs: day)
        }.count
        return Button {
            selectedDay = day
        } label: {
            VStack(spacing: 7) {
                Text(day, format: .dateTime.weekday(.abbreviated)).font(
                    .system(size: 10, weight: .medium))
                Text(day, format: .dateTime.day()).font(.system(size: 18, weight: .semibold))
                Circle().fill(count > 0 ? (selected ? theme.cobalt : theme.secondaryInk) : .clear)
                    .frame(width: 4, height: 4)
            }
            .foregroundStyle(selected ? theme.cobalt : theme.secondaryInk)
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(
                selected ? theme.cobaltSoft.opacity(0.65) : theme.canvas.opacity(0.5),
                in: RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(.plain)
            .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct MeetingAgendaEventRow: View {
    @Environment(VoxoLTheme.self) private var theme
    let event: MeetingCalendarStore.Event
    let french: Bool
    let disabled: Bool
    let record: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Text(event.start, format: .dateTime.hour().minute())
                .font(.system(size: 14, weight: .medium)).monospacedDigit().frame(
                    width: 58, alignment: .leading)
            RoundedRectangle(cornerRadius: 2).fill(theme.cobalt.opacity(0.4)).frame(
                width: 3, height: 32)
            VStack(alignment: .leading, spacing: 5) {
                Text(event.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(
                    "\(event.calendar) · \(max(1, Int(event.end.timeIntervalSince(event.start) / 60))) min"
                )
                .font(.system(size: 11)).foregroundStyle(theme.secondaryInk)
            }
            Spacer()
            if let url = event.joinURL {
                Link(destination: url) { Image(systemName: "video") }
                    .buttonStyle(MeetingQuietButtonStyle()).help(french ? "Rejoindre" : "Join")
            }
            Button(action: record) {
                Label(french ? "Enregistrer" : "Record", systemImage: "record.circle")
            }
            .buttonStyle(MeetingQuietButtonStyle()).disabled(disabled)
        }
    }
}
