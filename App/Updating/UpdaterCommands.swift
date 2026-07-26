import SimbiUI
import SwiftUI

/// `Simbi ▸ Check for Updates…`, the one place updates are always reachable
/// no matter what the sidebar pill is (or isn't) showing.
struct CheckForUpdatesCommand: View {
    @Bindable private var updates = UpdateModel.shared

    var body: some View {
        Button("Check for Updates…") {
            updates.checkForUpdates()
        }
        .disabled(!updates.canCheckForUpdates || updates.isChecking)
    }
}
