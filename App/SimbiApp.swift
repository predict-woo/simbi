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
        // Per-note fixer activity window, opened from the recording
        // header's sparkles button (one window per note URL).
        WindowGroup("Transcript Fixer", id: FixerActivityWindow.windowId, for: URL.self) { $url in
            if let url {
                FixerActivityWindow(noteFolderURL: url)
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 380, height: 300)
        // Per-note chat window (SPEC.md §5.4): the note's persistent Codex
        // conversation, opened from the note toolbar.
        WindowGroup("Chat", id: ChatWindow.windowId, for: URL.self) { $url in
            if let url {
                ChatWindow(noteFolderURL: url)
            }
        }
        .defaultSize(width: 480, height: 620)
        Settings {
            SettingsView()
        }
    }
}
