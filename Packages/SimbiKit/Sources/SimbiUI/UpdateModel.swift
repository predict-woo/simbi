import Foundation
import Observation
import SimbiKit

extension Notification.Name {
    /// Posted when the last live capture stops. The update coordinator uses
    /// it to fire a relaunch it postponed mid-recording.
    public static let simbiRecordingDidEnd = Notification.Name("app.getsimbi.mac.recordingDidEnd")
}

/// "Is any note recording right now?", made observable.
///
/// `RecordingController` keeps one instance per note in a plain static
/// dictionary, which SwiftUI cannot track. This mirrors the aggregate into an
/// observable flag so views (and the updater) react to capture starting and
/// stopping. `RecordingController.status` refreshes it.
@MainActor
@Observable
public final class RecordingActivity {
    public static let shared = RecordingActivity()

    public private(set) var isRecording = false

    private init() {}

    func refresh() {
        let live = RecordingController.isAnyRecording
        guard live != isRecording else { return }
        isRecording = live
        if !live {
            NotificationCenter.default.post(name: .simbiRecordingDidEnd, object: nil)
        }
    }
}

/// What the app shell's Sparkle wiring must be able to do. Declared here so
/// SimbiUI can drive updates without importing Sparkle — the framework is a
/// binary XCFramework and stays in the Xcode target (SPEC.md §1).
@MainActor
public protocol UpdateCoordinating: AnyObject {
    /// User-initiated check; shows Sparkle's own progress and error UI.
    func checkForUpdates()
    /// Install the staged update and relaunch, subject to the recording gate.
    func installUpdate()
    func apply(mode: UpdateMode)
    /// The channel changed in `UpdateModel.shared` — Sparkle reads the
    /// value itself via `allowedChannels(for:)` on its next check; this
    /// just prompts a check so the switch shows something promptly.
    func channelDidChange()
}

/// View-facing update state. The Sparkle coordinator pushes into it; the
/// sidebar pill and Settings read out of it.
///
/// Nothing here decides *policy* — that is `UpdateGate` in SimbiKit, which is
/// unit-tested. This type only holds state and forwards intent.
@MainActor
@Observable
public final class UpdateModel {
    public static let shared = UpdateModel()

    private enum Key {
        static let channel = "SimbiUpdateChannel"
    }

    public private(set) var availability: UpdateAvailability = .none
    /// An install the user already agreed to, held back until capture stops.
    public private(set) var relaunchPending = false
    public private(set) var isChecking = false
    public private(set) var lastCheckDate: Date?
    public private(set) var canCheckForUpdates = true
    /// The running build, for Settings' "Simbi 1.3.0" readout.
    public let currentVersion: String

    /// Mirror of the mode Sparkle's persisted settings currently express.
    /// Sparkle is the single source of truth: the setter forwards intent to
    /// the coordinator (which writes Sparkle's booleans), and the coordinator
    /// observes Sparkle and pushes every change — from the picker, from
    /// Sparkle's own update-alert checkbox — back via `setMode(_:)`.
    private var storedMode: UpdateMode = .default

    public var mode: UpdateMode {
        get { storedMode }
        set {
            guard newValue != storedMode else { return }
            storedMode = newValue
            coordinator?.apply(mode: newValue)
        }
    }

    public var channel: UpdateChannel {
        didSet {
            guard channel != oldValue else { return }
            UserDefaults.standard.set(channel.rawValue, forKey: Key.channel)
            coordinator?.channelDidChange()
        }
    }

    /// Set once by the app shell at launch. Weak: the coordinator owns
    /// Sparkle and outlives this only by the app's lifetime.
    public weak var coordinator: (any UpdateCoordinating)?

    private init() {
        let defaults = UserDefaults.standard
        channel =
            defaults.string(forKey: Key.channel).flatMap(UpdateChannel.init(rawValue:))
            ?? .default
        currentVersion =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
    }

    /// What the sidebar should draw right now.
    public var presentation: UpdatePresentation {
        UpdateGate.presentation(
            availability: availability,
            mode: mode,
            isRecording: RecordingActivity.shared.isRecording,
            relaunchPending: relaunchPending)
    }

    // MARK: - Intent (from the pill and Settings)

    public func checkForUpdates() {
        coordinator?.checkForUpdates()
    }

    public func installUpdate() {
        coordinator?.installUpdate()
    }

    // MARK: - State pushed in by the coordinator

    public func setAvailability(_ availability: UpdateAvailability) {
        self.availability = availability
    }

    public func setRelaunchPending(_ pending: Bool) {
        relaunchPending = pending
    }

    public func setChecking(_ checking: Bool) {
        isChecking = checking
    }

    public func setCanCheckForUpdates(_ canCheck: Bool) {
        canCheckForUpdates = canCheck
    }

    public func setLastCheckDate(_ date: Date?) {
        lastCheckDate = date
    }

    /// Reflect Sparkle's current settings, without echoing back into them.
    /// The coordinator calls this at launch and whenever Sparkle's persisted
    /// booleans change out from under us (e.g. the update alert's checkbox).
    public func setMode(_ mode: UpdateMode) {
        storedMode = mode
    }
}
