import AppKit

/// Installs diagnostics for the class of macOS 26 crash where an Objective-C
/// exception is thrown and swallowed on the main thread, corrupting the Swift
/// concurrency executor-tracking state — which later detonates as a SIGSEGV in
/// an unrelated MainActor executor check (e.g. a SwiftUI button tap). See
/// docs/crash-macos26-executor.md.
///
/// The uncaught-exception handler records the throwing stack to
/// ~/Library/Application Support/Oatmeal/last-exception.log so a recurrence is
/// diagnosable instead of invisible.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
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
