import SwiftUI

@main
struct OatmealApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = MeetingListModel()
    @StateObject private var recorder = RecordingController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(recorder)
                .frame(minWidth: 800, minHeight: 500)
        }
        Settings {
            SettingsView()
        }
        MenuBarExtra {
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
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.canBecomeKey })?.makeKeyAndOrderFront(nil)
            }
            Divider()
            Button("Quit Oatmeal") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: recorder.isRecording
                  ? (recorder.isPaused ? "pause.circle.fill" : "record.circle.fill")
                  : "waveform.circle")
        }
    }
}
