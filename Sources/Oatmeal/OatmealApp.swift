import SwiftUI

@main
struct OatmealApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = MeetingListModel()
    @StateObject private var recorder = RecordingController.shared

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(recorder)
                .frame(minWidth: 800, minHeight: 500)
        }
        Settings {
            SettingsView()
        }
        MenuBarExtra {
            MenuBarContent(recorder: recorder)
        } label: {
            Image(systemName: recorder.isRecording
                  ? (recorder.isPaused ? "pause.circle.fill" : "record.circle.fill")
                  : "waveform.circle")
        }
    }
}

/// Menu bar content lives in its own view so it can use @Environment(\.openWindow)
/// — plain NSApp.activate can't recreate the main window once it's been closed.
private struct MenuBarContent: View {
    @ObservedObject var recorder: RecordingController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if recorder.isRecording {
            Button("Stop Recording") { recorder.toggle() }
            Button(recorder.isPaused ? "Resume Recording" : "Pause Recording") {
                recorder.togglePause()
            }
        } else {
            Button("Start Recording") { recorder.toggle() }
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
