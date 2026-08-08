import SimbiUI
import SwiftUI

/// Thin shell — all real logic lives in Packages/SimbiKit so that
/// `swift build` / `swift test` work headless (docs/SPEC.md §1).
@main
struct SimbiApp: App {
    init() {
        // The system "prefer tabs: always" setting auto-tabs a new window
        // into an existing group DURING creation, and SwiftUI (macOS 26)
        // never commits window content for windows born that way — they
        // stay permanently blank. Chat windows join their note's tab group
        // explicitly instead (ChatWindowManager), after content exists.
        NSWindow.allowsAutomaticWindowTabbing = false

        // Starts Sparkle. It checks in the background and shows nothing until
        // the second launch, so this costs the first run nothing.
        // SIMBI_NO_SPARKLE skips it for headless verification runs: its
        // failed-check alert is app-modal and stalls the whole scene layer.
        if ProcessInfo.processInfo.environment["SIMBI_NO_SPARKLE"] == nil {
            SparkleCoordinator.shared.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            SimbiRootView()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand()
            }
        }
        // The per-note chat windows (docs/SPEC.md §5.4) are NOT here on
        // purpose: they are AppKit windows owned by ChatWindowManager
        // (SimbiUI). See its doc comment for why they must not be a
        // SwiftUI WindowGroup.
        // Per-note pipeline inspector (recording debug HUD), opened from
        // the recording header while a session is live.
        WindowGroup(
            "Pipeline Inspector", id: PipelineInspectorWindow.windowId, for: URL.self
        ) { $url in
            if let url {
                PipelineInspectorWindow(noteFolderURL: url)
            }
        }
        .defaultSize(width: 1100, height: 900)
        Settings {
            SettingsView()
        }
    }
}
