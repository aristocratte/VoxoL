// Appended to MeetingCalendarStore.swift: no access to real calendar data.
extension MeetingCalendarStore {
    static func checkConferenceLinks() {
        precondition(
            conferenceURL(
                URL(string: "https://meet.google.com/abc-defg-hij"), location: nil, notes: nil)?
                .host == "meet.google.com")
        precondition(
            conferenceURL(nil, location: "https://us02web.zoom.us/j/123", notes: nil)?.host
                == "us02web.zoom.us")
        precondition(
            conferenceURL(
                nil, location: nil, notes: "Join: https://teams.microsoft.com/l/meetup-join/123")?
                .host == "teams.microsoft.com")
        precondition(
            conferenceURL(
                URL(string: "https://zoom.us.example.com/j/123"), location: nil, notes: nil) == nil)
        precondition(
            conferenceURL(URL(string: "http://meet.google.com/abc"), location: nil, notes: nil)
                == nil)
        precondition(
            conferenceURL(URL(string: "file:///tmp/meeting"), location: nil, notes: nil) == nil)
        precondition(conferenceURL(nil, location: "Office", notes: nil) == nil)
    }
}
@main struct MeetingCalendarProbe {
    @MainActor static func main() {
        MeetingCalendarStore.checkConferenceLinks()
        print(
            "PASS: Google Meet, Zoom and Teams links; unrelated, deceptive and non-HTTPS URLs excluded"
        )
    }
}
