import SwiftUI

/// Entry is `main.swift`, which handles `--mcp-stdio` before AppKit exists
/// and otherwise calls `VibeBarApp.main()`.
struct VibeBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            CompactSettingsRoot(environment: appDelegate.environment)
                .environmentObject(appDelegate.environment)
                .environmentObject(appDelegate.environment.quotaService)
        }
        .defaultSize(width: 660, height: 650)
    }
}
