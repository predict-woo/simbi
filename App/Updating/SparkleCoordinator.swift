import AppKit
import SimbiKit
import SimbiUI
import Sparkle

/// The only place Sparkle is imported.
///
/// Everything opinionated lives elsewhere: `UpdateGate` (SimbiKit) decides
/// when Simbi may interrupt, `UpdateModel` (SimbiUI) holds what the sidebar
/// draws. This class translates between those and Sparkle's delegates, and
/// enforces the one hard rule — a recording is never interrupted by an update
/// (see docs/superpowers/specs/2026-07-27-github-auto-update-design.md).
/// Sparkle calls its delegate methods on the main thread and hands back plain
/// Objective-C blocks, which Swift 6 sees as non-`Sendable`. Boxing one lets
/// it cross into `MainActor.assumeIsolated` — safe precisely because the call
/// is already on the main thread.
private struct MainThreadBlock: @unchecked Sendable {
    let run: () -> Void
}

@MainActor
final class SparkleCoordinator: NSObject {
    static let shared = SparkleCoordinator()

    private var updaterController: SPUStandardUpdaterController?
    /// Sparkle wants to relaunch, but a recording is live. Fired once capture
    /// stops.
    private var postponedRelaunch: (() -> Void)?
    /// A downloaded update Sparkle would have installed on quit, held back
    /// for an explicit click in `.downloadAndAsk` mode.
    private var stagedInstall: (() -> Void)?
    private var canCheckObservation: NSKeyValueObservation?

    private var updater: SPUUpdater? { updaterController?.updater }

    /// Grace period between capture stopping and a postponed relaunch, so
    /// stopping a recording never feels like it yanked the app away.
    private static let relaunchSettleDelay = Duration.seconds(3)

    func start() {
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self)
        updaterController = controller

        let model = UpdateModel.shared
        model.coordinator = self
        // Until the user has chosen a mode, leave Sparkle's own settings
        // alone: writing them would answer its second-launch permission
        // prompt on their behalf. Reflect its state into Settings instead.
        if model.hasExplicitMode {
            apply(mode: model.mode)
        } else {
            model.adoptMode(Self.mode(matching: controller.updater))
        }
        model.setLastCheckDate(controller.updater.lastUpdateCheckDate)

        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates, options: [.initial, .new]
        ) { updater, _ in
            MainActor.assumeIsolated {
                UpdateModel.shared.setCanCheckForUpdates(updater.canCheckForUpdates)
            }
        }

        NotificationCenter.default.addObserver(
            forName: .simbiRecordingDidEnd, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                SparkleCoordinator.shared.recordingDidEnd()
            }
        }
    }

    /// Read Sparkle's current settings back as one of our modes, so Settings
    /// shows what is actually happening before the user has chosen anything.
    private static func mode(matching updater: SPUUpdater) -> UpdateMode {
        guard updater.automaticallyChecksForUpdates else { return .never }
        return updater.automaticallyDownloadsUpdates ? .downloadAndAsk : .notifyOnly
    }

    /// Fire a relaunch we held back, once the user has had a moment with
    /// their finished recording.
    private func recordingDidEnd() {
        guard let relaunch = postponedRelaunch else { return }
        Task {
            try? await Task.sleep(for: Self.relaunchSettleDelay)
            guard !RecordingActivity.shared.isRecording else { return }
            self.postponedRelaunch = nil
            relaunch()
        }
    }
}

// MARK: - UpdateCoordinating (what SimbiUI calls)

extension SparkleCoordinator: UpdateCoordinating {
    func checkForUpdates() {
        guard let updater, updater.canCheckForUpdates else { return }
        UpdateModel.shared.setChecking(true)
        updater.checkForUpdates()
    }

    func installUpdate() {
        // Already downloaded and staged: install it now. Otherwise fall back
        // to a normal check, which opens Sparkle's sheet with release notes.
        if let stagedInstall {
            self.stagedInstall = nil
            stagedInstall()
        } else {
            checkForUpdates()
        }
    }

    func apply(mode: UpdateMode) {
        guard let updater else { return }
        updater.automaticallyChecksForUpdates = mode.checksAutomatically
        updater.automaticallyDownloadsUpdates = mode.downloadsAutomatically
    }

    func apply(channel: UpdateChannel) {
        // `allowedChannels(for:)` is read on the next check; run one now so
        // switching to Beta shows something without waiting a day. Sparkle
        // logs an error if asked to check in the background while automatic
        // checks are off, so respect that.
        _ = channel
        guard let updater, updater.automaticallyChecksForUpdates else { return }
        updater.checkForUpdatesInBackground()
    }
}

// MARK: - SPUUpdaterDelegate

extension SparkleCoordinator: SPUUpdaterDelegate {
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated {
            UpdateModel.shared.channel.allowedChannelIdentifiers
        }
    }

    /// The hard guarantee: Sparkle may not relaunch Simbi mid-recording.
    nonisolated func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        let handler = MainThreadBlock(run: installHandler)
        let version = item.displayVersionString
        return MainActor.assumeIsolated {
            guard !UpdateGate.mayRelaunch(isRecording: RecordingActivity.shared.isRecording) else {
                return false
            }
            postponedRelaunch = handler.run
            UpdateModel.shared.setAvailability(.readyToInstall(version: version))
            UpdateModel.shared.setRelaunchPending(true)
            return true
        }
    }

    /// In `.downloadAndAsk` mode, take ownership of the staged update so it
    /// waits for a click instead of landing on the next quit.
    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let handler = MainThreadBlock(run: immediateInstallHandler)
        let version = item.displayVersionString
        return MainActor.assumeIsolated {
            UpdateModel.shared.setAvailability(.readyToInstall(version: version))
            guard UpdateModel.shared.mode.holdsInstallUntilConfirmed else { return false }
            stagedInstall = handler.run
            return true
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            UpdateModel.shared.setAvailability(.available(version: version))
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated {
            UpdateModel.shared.setAvailability(.none)
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            UpdateModel.shared.setChecking(false)
            UpdateModel.shared.setLastCheckDate(updater.lastUpdateCheckDate)
        }
    }
}

// MARK: - SPUStandardUserDriverDelegate (gentle reminders)

extension SparkleCoordinator: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Never let Sparkle's scheduled-update alert steal focus — Simbi shows a
    /// pill in the sidebar instead. User-initiated checks are untouched;
    /// Sparkle only consults this for updates *it* found on a schedule.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            UpdateModel.shared.setChecking(false)
        }
    }
}
