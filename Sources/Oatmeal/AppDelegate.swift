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

    /// "Start Recording" on the notification begins a recording pre-associated
    /// with that calendar event.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let meetingId = response.notification.request.content.userInfo["meetingId"] as? String
        let wantsRecording = response.actionIdentifier == MeetingNotifier.startRecordingAction
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if wantsRecording, !RecordingController.shared.isRecording {
                let event = CalendarService.shared.upcoming.first { $0.id == meetingId }
                await RecordingController.shared.start(calendarMeeting: event)
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
