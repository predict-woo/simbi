import Foundation

/// Auto-update policy, kept free of Sparkle (and of AppKit) so the rules that
/// decide *when* Simbi may interrupt the user are plain testable values.
/// The Sparkle wiring lives in the app shell (`App/Updating/`); it reads these
/// types and does what they say.

/// How eagerly Simbi adopts new versions. This — not Sparkle's own user
/// defaults — is the source of truth; the coordinator pushes it into Sparkle
/// at launch and on every change, so there is one place to reason about.
public enum UpdateMode: String, CaseIterable, Codable, Sendable {
    /// Download in the background and install on quit, no interaction at all.
    case automatic
    /// Only say that a version exists; download when the user asks for it.
    case notifyOnly
    /// No background checks. "Check for Updates…" still works.
    case never

    /// Placeholder until the coordinator derives the real mode from Sparkle.
    /// Matches the Info.plist defaults a fresh install starts from.
    public static let `default` = UpdateMode.notifyOnly

    /// The mode is a pure projection of Sparkle's two persisted booleans —
    /// Sparkle is the single source of truth, and every control surface
    /// (Settings picker, Sparkle's own update-alert checkbox) converges here.
    public init(checksAutomatically: Bool, downloadsAutomatically: Bool) {
        if !checksAutomatically {
            self = .never
        } else if downloadsAutomatically {
            self = .automatic
        } else {
            self = .notifyOnly
        }
    }

    /// Maps to Sparkle's `SPUUpdater.automaticallyChecksForUpdates`.
    public var checksAutomatically: Bool {
        self != .never
    }

    /// Maps to Sparkle's `SPUUpdater.automaticallyDownloadsUpdates`.
    public var downloadsAutomatically: Bool {
        self == .automatic
    }

    public var title: String {
        switch self {
        case .automatic: "Install automatically"
        case .notifyOnly: "Only notify me"
        case .never: "Never check"
        }
    }
}

/// Release stream the user follows. Beta items are tagged in the appcast, so
/// both streams share one feed.
public enum UpdateChannel: String, CaseIterable, Codable, Sendable {
    case stable
    case beta

    public static let `default` = UpdateChannel.stable

    /// Sparkle's `allowedChannelsForUpdater:` — untagged (stable) items are
    /// always allowed, so only the beta stream needs naming.
    public var allowedChannelIdentifiers: Set<String> {
        switch self {
        case .stable: []
        case .beta: ["beta"]
        }
    }

    public var title: String {
        switch self {
        case .stable: "Stable"
        case .beta: "Beta"
        }
    }
}

/// What Sparkle currently has for us.
public enum UpdateAvailability: Equatable, Sendable {
    case none
    /// Found, not downloaded — clicking opens Sparkle's sheet.
    case available(version: String)
    /// Downloaded and staged — clicking installs and relaunches.
    case readyToInstall(version: String)

    public var version: String? {
        switch self {
        case .none: nil
        case .available(let version), .readyToInstall(let version): version
        }
    }
}

/// What the UI shows for it.
public enum UpdatePresentation: Equatable, Sendable {
    case hidden
    case available(version: String)
    case readyToInstall(version: String)
    /// The user already consented; the relaunch is held until capture stops.
    case waitingForRecordingToEnd(version: String)
}

/// The one rule about interrupting a recording, in one place.
///
/// Losing a meeting to an updater is unforgivable, so while capture is live
/// Simbi shows nothing that invites a restart. The single exception is an
/// update the user *already* agreed to install: that pill is reassurance
/// ("this will happen after your recording"), not a nag.
public enum UpdateGate {
    public static func presentation(
        availability: UpdateAvailability,
        mode: UpdateMode,
        isRecording: Bool,
        relaunchPending: Bool
    ) -> UpdatePresentation {
        if relaunchPending, let version = availability.version {
            return .waitingForRecordingToEnd(version: version)
        }
        guard !isRecording else { return .hidden }
        switch availability {
        case .none:
            return .hidden
        case .available(let version):
            // When downloads are automatic, "found" is a transient state on
            // the way to "staged" — a pill here would invite a click that the
            // download is about to make redundant. Stay quiet until then.
            return mode.downloadsAutomatically ? .hidden : .available(version: version)
        case .readyToInstall(let version):
            return .readyToInstall(version: version)
        }
    }

    /// Whether Sparkle may relaunch the app right now. The postpone hook
    /// (`updater:shouldPostponeRelaunchForUpdate:untilInvoking:`) inverts this.
    public static func mayRelaunch(isRecording: Bool) -> Bool {
        !isRecording
    }
}
