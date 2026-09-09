import SwiftUI

@main
struct OatmealApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = MeetingListModel()
    @StateObject private var recorder = RecordingController.shared
    @ObservedObject private var endDetector = MeetingEndDetector.shared

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(recorder)
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1120, height: 760)
        Settings {
            SettingsView()
                .tint(OatmealStyle.accent)
        }
        MenuBarExtra {
            MenuBarContent(recorder: recorder)
        } label: {
            Image(systemName: menuBarIcon)
        }
    }

    /// The menu bar is often the only Oatmeal on screen during a call, so an
    /// inferred end has to be visible there too.
    private var menuBarIcon: String {
        if endDetector.pending != nil { return "exclamationmark.circle.fill" }
        if recorder.isRecording { return recorder.isPaused ? "pause.circle.fill" : "record.circle.fill" }
        return "waveform.circle"
    }
}

/// Menu bar content lives in its own view so it can use @Environment(\.openWindow)
/// — plain NSApp.activate can't recreate the main window once it's been closed.
private struct MenuBarContent: View {
    @ObservedObject var recorder: RecordingController
    @ObservedObject private var endDetector = MeetingEndDetector.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if endDetector.pending != nil {
            Text("Oatmeal thinks this meeting has ended")
            Button("Keep Recording") { endDetector.keepRecording() }
            Button("Stop & Save Now") { endDetector.stopNow() }
            Divider()
        }
        if recorder.isRecording {
            Button("Stop Recording") { recorder.toggle() }
                .disabled(recorder.isTransitioning)
            Button(recorder.isPaused ? "Resume Recording" : "Pause Recording") {
                recorder.togglePause()
            }
        } else {
            Button(recorder.state == .starting ? "Starting…" : "Start Recording") { recorder.toggle() }
                .disabled(recorder.isTransitioning)
        }
        Divider()
        Button("Open Oatmeal") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit Oatmeal") { NSApp.terminate(nil) }
    }
}
