import SwiftUI

@main
struct OatmealApp: App {
    @StateObject private var store = MeetingListModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 800, minHeight: 500)
        }
        Settings {
            SettingsView()
        }
    }
}
