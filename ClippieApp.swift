import SwiftUI

@main
struct ClippieApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // Empty scene - we're a menu bar only app
        Settings {
            SettingsView(clipboardStore: appDelegate.clipboardStore)
        }
    }
}
