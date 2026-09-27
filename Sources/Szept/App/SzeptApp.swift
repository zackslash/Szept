import SwiftUI

@main
struct SzeptApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(appDelegate.appState)
        }
    }
}
