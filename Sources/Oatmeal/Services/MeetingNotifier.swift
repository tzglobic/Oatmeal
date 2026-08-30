import Foundation
import UserNotifications

/// Local notifications around the edges of a meeting: "record it?" when a
/// calendar event with a call link starts, and "has this ended?" when
/// `MeetingEndDetector` infers the call is over. Both carry actions, handled in
/// AppDelegate.
enum MeetingNotifier {
    static let categoryId = "oatmeal.meeting-starting"
    static let startRecordingAction = "oatmeal.start-recording"

    static let endedCategoryId = "oatmeal.meeting-ended"
    static let keepRecordingAction = "oatmeal.keep-recording"
    static let stopNowAction = "oatmeal.stop-now"

    /// Single reused id — there is only ever one recording, so a new question
    /// replaces the old one rather than stacking up in Notification Centre.
    private static let endedNotificationId = "oatmeal.meeting-ended.current"

    static func setup() {
        let center = UNUserNotificationCenter.current()
        let record = UNNotificationAction(
            identifier: startRecordingAction, title: "Start Recording", options: [.foreground])
        let starting = UNNotificationCategory(
            identifier: categoryId, actions: [record], intentIdentifiers: [], options: [])

        // Keep Recording stays in the background — the whole point is that the
        // meeting is still going and shouldn't be interrupted. Stop & Save
        // brings the app forward, where the notes are about to appear.
        let keep = UNNotificationAction(
            identifier: keepRecordingAction, title: "Keep Recording", options: [])
        let stop = UNNotificationAction(
            identifier: stopNowAction, title: "Stop & Save", options: [.foreground, .destructive])
        let ended = UNNotificationCategory(
            identifier: endedCategoryId, actions: [keep, stop], intentIdentifiers: [], options: [])

        center.setNotificationCategories([starting, ended])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Replace all pending notifications with one per future call-link event.
    static func reschedule(for meetings: [UpcomingMeeting]) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        let now = Date()
        for meeting in meetings where meeting.callURL != nil && meeting.start > now {
            let content = UNMutableNotificationContent()
            content.title = "Meeting starting"
            content.body = "\(meeting.title) — record it with Oatmeal?"
            content.sound = .default
            content.categoryIdentifier = categoryId
            content.userInfo = ["meetingId": meeting.id]
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: meeting.start)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            center.add(UNNotificationRequest(identifier: meeting.id, content: content, trigger: trigger))
        }
    }

    // MARK: - Meeting ended

    /// Fired the moment an end is inferred, stating plainly that recording is
    /// still running and when it will stop.
    static func notifyMeetingEnded(trigger: MeetingEndDetector.Trigger, within: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = "Still recording — has this meeting ended?"
        content.body = """
            Oatmeal thinks the call is over — \(trigger.summary). \
            Recording stops in \(Int(within)) seconds unless you keep it going.
            """
        content.sound = .default
        content.categoryIdentifier = endedCategoryId

        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [endedNotificationId])
        center.add(UNNotificationRequest(
            identifier: endedNotificationId, content: content, trigger: nil))
    }

    /// Pull the question once it has been answered — in the notification, in
    /// the app, or by the countdown running out.
    static func withdrawMeetingEnded() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [endedNotificationId])
        center.removePendingNotificationRequests(withIdentifiers: [endedNotificationId])
    }
}
