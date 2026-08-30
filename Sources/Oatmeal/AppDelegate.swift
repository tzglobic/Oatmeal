import AppKit
import UserNotifications

/// Installs diagnostics for the class of macOS 26 crash where an Objective-C
/// exception is thrown and swallowed on the main thread, corrupting the Swift
/// concurrency executor-tracking state — which later detonates as a SIGSEGV in
/// an unrelated MainActor executor check (e.g. a SwiftUI button tap). See
/// docs/crash-macos26-executor.md.
///
/// The uncaught-exception handler records the throwing stack to
/// ~/Library/Application Support/Oatmeal/last-exception.log so a recurrence is
/// diagnosable instead of invisible.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        // Register categories at launch, not just when Calendar access is
        // granted: the meeting-ended question can fire on silence alone.
        MeetingNotifier.setup()
        NSSetUncaughtExceptionHandler { exception in
            let lines = [
                "Uncaught exception: \(exception.name.rawValue)",
                "Reason: \(exception.reason ?? "nil")",
                "Stack:",
                exception.callStackSymbols.joined(separator: "\n"),
            ]
            AppDelegate.writeCrashLog(lines.joined(separator: "\n"))
        }
    }

    // MARK: - Meeting-starting notifications

    /// Show meeting-starting banners even while the app is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Notification actions: "Start Recording" on a meeting-starting banner,
    /// and "Keep Recording" / "Stop & Save" on the meeting-ended question.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        let meetingId = response.notification.request.content.userInfo["meetingId"] as? String

        Task { @MainActor in
            switch (category, action) {
            case (MeetingNotifier.endedCategoryId, MeetingNotifier.keepRecordingAction):
                // Deliberately no activate() — the meeting is still going and
                // pulling the app forward over a shared screen is the last
                // thing anyone wants.
                MeetingEndDetector.shared.keepRecording()

            case (MeetingNotifier.endedCategoryId, MeetingNotifier.stopNowAction):
                NSApp.activate(ignoringOtherApps: true)
                MeetingEndDetector.shared.stopNow()

            case (MeetingNotifier.endedCategoryId, _):
                // Tapping the body just opens the app; the in-app banner is
                // still counting down and asks the same question there.
                NSApp.activate(ignoringOtherApps: true)

            case (_, MeetingNotifier.startRecordingAction):
                NSApp.activate(ignoringOtherApps: true)
                if !RecordingController.shared.isRecording {
                    let event = CalendarService.shared.upcoming.first { $0.id == meetingId }
                    await RecordingController.shared.start(calendarMeeting: event)
                }

            default:
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        // Must be called promptly — start() above can block on permission prompts.
        completionHandler()
    }

    static func writeCrashLog(_ text: String) {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
            .appendingPathComponent("Oatmeal", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("last-exception.log")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
