import Foundation
import EventKit
import AppKit

/// A calendar event surfaced in the sidebar. Outlook/Microsoft 365 calendars are
/// read through EventKit — they appear as soon as the account is added in
/// System Settings → Internet Accounts (Microsoft Exchange).
struct UpcomingMeeting: Identifiable, Equatable {
    let id: String          // eventIdentifier + occurrence start (recurring events share identifiers)
    let eventId: String     // raw EKEvent identifier stored on the Meeting row
    let title: String
    let start: Date
    let end: Date
    let attendees: [String]
    let callURL: URL?
    let provider: String?   // "Teams", "Zoom", "Meet", "Webex"

    /// True from 10 minutes before start until the event ends.
    var isNow: Bool {
        let now = Date()
        return start.addingTimeInterval(-10 * 60) <= now && now <= end
    }
}

@MainActor
final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    @Published var upcoming: [UpcomingMeeting] = []
    @Published var authStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

    private let store = EKEventStore()
    private var refreshTimer: Timer?
    private var changeObserver: NSObjectProtocol?

    var hasAccess: Bool { authStatus == .fullAccess }

    /// Prompts for calendar access on first run, then keeps `upcoming` fresh
    /// (EventKit change notifications + a 5-minute timer).
    func requestAccessAndStart() async {
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            _ = try? await store.requestFullAccessToEvents()
        }
        authStatus = EKEventStore.authorizationStatus(for: .event)
        guard hasAccess else { return }

        MeetingNotifier.setup()
        refresh()

        if changeObserver == nil {
            changeObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
                    Task { @MainActor in CalendarService.shared.refresh() }
                }
        }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in CalendarService.shared.refresh() }
        }
    }

    /// Events from 4h ago through end of tomorrow, minus all-day/cancelled/declined.
    func refresh() {
        guard hasAccess else {
            upcoming = []
            return
        }
        let now = Date()
        let calendar = Calendar.current
        let windowStart = now.addingTimeInterval(-4 * 3600)
        let windowEnd = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now))!

        let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)
        upcoming = store.events(matching: predicate)
            .filter { event in
                guard !event.isAllDay, event.status != .canceled else { return false }
                if let me = event.attendees?.first(where: { $0.isCurrentUser }),
                   me.participantStatus == .declined { return false }
                return event.endDate > now
            }
            .compactMap(Self.meeting(from:))
            .sorted { $0.start < $1.start }

        MeetingNotifier.reschedule(for: upcoming)
    }

    /// The event happening right now (call-link events win), for auto-association
    /// when the user presses the plain Record button.
    func currentMeeting() -> UpcomingMeeting? {
        refresh()
        let candidates = upcoming.filter(\.isNow)
        return candidates.first { $0.callURL != nil } ?? candidates.first
    }

    // MARK: - Mapping

    private static func meeting(from event: EKEvent) -> UpcomingMeeting? {
        guard let eventId = event.eventIdentifier, let start = event.startDate,
              let end = event.endDate else { return nil }

        let (callURL, provider) = detectCall(in: [
            event.url?.absoluteString, event.location, event.notes,
        ])

        let attendees = (event.attendees ?? []).compactMap { participant -> String? in
            guard participant.participantType == .person, !participant.isCurrentUser else { return nil }
            if let name = participant.name, !name.isEmpty { return name }
            let urlString = participant.url.absoluteString
            return urlString.hasPrefix("mailto:") ? String(urlString.dropFirst(7)) : nil
        }

        return UpcomingMeeting(
            id: "\(eventId)#\(Int(start.timeIntervalSince1970))",
            eventId: eventId,
            title: event.title ?? "Untitled meeting",
            start: start,
            end: end,
            attendees: attendees,
            callURL: callURL,
            provider: provider)
    }

    /// Finds the first video-call link. Teams links live in Outlook event bodies
    /// (teams.microsoft.com/l/meetup-join/… or the newer /meet/ form).
    private static func matchesHost(_ host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    static func detectCall(in texts: [String?]) -> (URL?, String?) {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue) else { return (nil, nil) }
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                // Event bodies are attacker-controllable content from whoever
                // sent the invite, and the detected URL is handed straight to
                // NSWorkspace.open. The host allowlist below is the main gate;
                // pinning https keeps a cleartext or odd-scheme link that
                // happens to carry an allowlisted host from ever being opened.
                guard let url = match.url, url.scheme?.lowercased() == "https",
                      let host = url.host?.lowercased() else { continue }
                if matchesHost(host, domain: "teams.microsoft.com") || matchesHost(host, domain: "teams.live.com") {
                    return (url, "Teams")
                }
                if matchesHost(host, domain: "zoom.us"), url.path.contains("/j/") || url.path.contains("/my/") {
                    return (url, "Zoom")
                }
                if host == "meet.google.com" { return (url, "Meet") }
                if matchesHost(host, domain: "webex.com") { return (url, "Webex") }
            }
        }
        return (nil, nil)
    }
}
