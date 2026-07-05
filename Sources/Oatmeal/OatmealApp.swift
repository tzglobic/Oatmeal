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
    }
}
