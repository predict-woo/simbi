import SimbiUI
import SwiftUI

/// Thin shell — all real logic lives in Packages/SimbiKit so that
/// `swift build` / `swift test` work headless (SPEC.md §1).
@main
struct SimbiApp: App {
    var body: some Scene {
        WindowGroup {
            SimbiRootView()
        }
        Settings {
            SettingsView()
        }
    }
}
