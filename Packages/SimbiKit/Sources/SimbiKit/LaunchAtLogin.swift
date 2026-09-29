import Foundation
import ServiceManagement

/// Keeps the app's menubar capture control ready before a meeting starts.
public enum LaunchAtLogin {
    /// Applies the user's preference to the app's login item registration.
    /// Registration failures are logged but never prevent Simbi from opening.
    public static func apply(enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.ui.error("updating launch-at-login registration failed: \(error)")
        }
    }
}
