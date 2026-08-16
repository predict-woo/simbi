import Foundation
import Observation
import SimbiKit

/// App-wide switch for the onboarding takeover: latched from persistence
/// at init (before anything reads `SimbiHome.activeRootURL`), re-armed
/// any time by Help > Welcome to Simbi.
@MainActor @Observable
public final class OnboardingPresenter {
    public static let shared = OnboardingPresenter()

    public private(set) var isActive: Bool
    /// True when the wizard was reopened over a running app: the folder
    /// step is then read-only (a change needs a relaunch, which Settings
    /// owns) and Finish must not re-bootstrap into a new root.
    public private(set) var isRerun = false

    private init() {
        isActive = OnboardingState.isNeeded() || Flags.uiPreviewOnboarding
    }

    /// Help > Welcome to Simbi. Re-runs the wizard over the live app.
    public func present() {
        isRerun = true
        isActive = true
    }

    func dismiss() {
        isActive = false
    }
}
