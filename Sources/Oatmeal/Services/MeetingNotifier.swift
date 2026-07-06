import Foundation
import UserNotifications

/// Local "Meeting starting — record it?" notifications for calendar events that
/// carry a video-call link. The notification's Start Recording action begins a
/// recording pre-associated with the event (handled in AppDelegate).
enum MeetingNotifier {
    static let categoryId = "oatmeal.meeting-starting"
    static let startRecordingAction = "oatmeal.start-recording"

    static func setup() {
        let center = UNUserNotificationCenter.current()
        let record = UNNotificationAction(
            identifier: startRecordingAction, title: "Start Recording", options: [.foreground])
        let category = UNNotificationCategory(
            identifier: categoryId, actions: [record], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
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
}
