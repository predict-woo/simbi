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
    private var observations: [NSKeyValueObservation] = []

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
        // Sparkle's persisted settings are the single source of truth for the
        // mode. Settings writes them through `apply(mode:)`; these observers
        // reflect every change back — including ones made behind our back by
        // the "Automatically download and install updates" checkbox in
        // Sparkle's own update alert.
        model.setMode(Self.mode(matching: controller.updater))
        model.setLastCheckDate(controller.updater.lastUpdateCheckDate)

        // One check per launch, so a fresh update is noticed without waiting
        // out the scheduled interval. Guarded because Sparkle rejects (and
        // logs) background checks while automatic checks are off ("Never").
        if controller.updater.automaticallyChecksForUpdates {
            controller.updater.checkForUpdatesInBackground()
        }

        let reflectMode: (SPUUpdater, Any) -> Void = { updater, _ in
            MainActor.assumeIsolated {
                UpdateModel.shared.setMode(Self.mode(matching: updater))
            }
        }
        observations = [
            controller.updater.observe(\.automaticallyChecksForUpdates, changeHandler: reflectMode),
            controller.updater.observe(\.automaticallyDownloadsUpdates, changeHandler: reflectMode),
            controller.updater.observe(
                \.canCheckForUpdates, options: [.initial, .new]
            ) { updater, _ in
                MainActor.assumeIsolated {
                    UpdateModel.shared.setCanCheckForUpdates(updater.canCheckForUpdates)
                }
            },
        ]

        NotificationCenter.default.addObserver(
            forName: .simbiRecordingDidEnd, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                SparkleCoordinator.shared.recordingDidEnd()
            }
        }
    }

    /// Project Sparkle's two persisted booleans onto the Settings mode.
    private static func mode(matching updater: SPUUpdater) -> UpdateMode {
        UpdateMode(
            checksAutomatically: updater.automaticallyChecksForUpdates,
            downloadsAutomatically: updater.automaticallyDownloadsUpdates)
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
        // A user-initiated check resumes the staged update through Sparkle's
        // standard sheet ("ready to install" + Install and Relaunch).
        checkForUpdates()
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

    /// An update was downloaded and staged for install-on-quit (automatic
    /// mode). Reflect it in the pill; Sparkle keeps ownership of the install.
    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let version = item.displayVersionString
        return MainActor.assumeIsolated {
            UpdateModel.shared.setAvailability(.readyToInstall(version: version))
            return false
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
