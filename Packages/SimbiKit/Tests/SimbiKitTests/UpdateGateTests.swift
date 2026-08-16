import Foundation
import Testing

@testable import SimbiKit

@Suite("UpdateGate")
struct UpdateGateTests {
    @Test("nothing to show when there is no update")
    func noUpdate() {
        #expect(
            UpdateGate.presentation(
                availability: .none, mode: .notifyOnly, isRecording: false, relaunchPending: false) == .hidden)
    }

    @Test("an available update shows while idle")
    func availableWhileIdle() {
        #expect(
            UpdateGate.presentation(
                availability: .available(version: "1.3.0"),
                mode: .notifyOnly,
                isRecording: false,
                relaunchPending: false) == .available(version: "1.3.0"))
    }

    @Test("a staged update shows as ready while idle")
    func readyWhileIdle() {
        #expect(
            UpdateGate.presentation(
                availability: .readyToInstall(version: "1.3.0"),
                mode: .notifyOnly,
                isRecording: false,
                relaunchPending: false) == .readyToInstall(version: "1.3.0"))
    }

    // The core promise: nothing invites a restart mid-meeting.
    @Test(
        "recording hides an available update",
        arguments: [
            UpdateAvailability.available(version: "1.3.0"),
            UpdateAvailability.readyToInstall(version: "1.3.0"),
            UpdateAvailability.none,
        ])
    func recordingHidesUnconsentedUpdates(availability: UpdateAvailability) {
        #expect(
            UpdateGate.presentation(
                availability: availability, mode: .notifyOnly, isRecording: true, relaunchPending: false) == .hidden)
    }

    @Test("an already-consented install shows as deferred while recording")
    func consentedInstallReassuresWhileRecording() {
        #expect(
            UpdateGate.presentation(
                availability: .readyToInstall(version: "1.3.0"),
                mode: .notifyOnly,
                isRecording: true,
                relaunchPending: true) == .waitingForRecordingToEnd(version: "1.3.0"))
    }

    @Test("a pending relaunch still reads as deferred once recording stops")
    func pendingRelaunchOutlivesRecording() {
        // The coordinator fires the stashed invocation on the next idle tick;
        // until it does, the pill must not flip back to a clickable "install".
        #expect(
            UpdateGate.presentation(
                availability: .readyToInstall(version: "1.3.0"),
                mode: .notifyOnly,
                isRecording: false,
                relaunchPending: true) == .waitingForRecordingToEnd(version: "1.3.0"))
    }

    @Test("a pending relaunch with no known version cannot be shown")
    func pendingRelaunchWithoutVersion() {
        #expect(
            UpdateGate.presentation(
                availability: .none, mode: .notifyOnly, isRecording: false, relaunchPending: true) == .hidden)
    }

    // Automatic mode downloads on its own, so a "found it" pill would invite
    // a click the download is about to make redundant.
    @Test("automatic mode hides a merely-available update")
    func automaticHidesAvailable() {
        #expect(
            UpdateGate.presentation(
                availability: .available(version: "1.3.0"),
                mode: .automatic,
                isRecording: false,
                relaunchPending: false) == .hidden)
    }

    @Test("automatic mode still shows a staged update as ready")
    func automaticShowsReady() {
        #expect(
            UpdateGate.presentation(
                availability: .readyToInstall(version: "1.3.0"),
                mode: .automatic,
                isRecording: false,
                relaunchPending: false) == .readyToInstall(version: "1.3.0"))
    }

    @Test("relaunch is blocked exactly while recording")
    func relaunchGate() {
        #expect(UpdateGate.mayRelaunch(isRecording: false))
        #expect(!UpdateGate.mayRelaunch(isRecording: true))
    }
}

@Suite("UpdateMode")
struct UpdateModeTests {
    @Test("default matches a fresh install's Info.plist state")
    func defaultMode() {
        let mode = UpdateMode.default
        #expect(mode == .notifyOnly)
        #expect(mode.checksAutomatically)
        #expect(!mode.downloadsAutomatically)
    }

    @Test("automatic checks and pre-downloads")
    func automaticMode() {
        #expect(UpdateMode.automatic.checksAutomatically)
        #expect(UpdateMode.automatic.downloadsAutomatically)
    }

    @Test("notify-only checks but never pre-downloads")
    func notifyOnlyMode() {
        #expect(UpdateMode.notifyOnly.checksAutomatically)
        #expect(!UpdateMode.notifyOnly.downloadsAutomatically)
    }

    @Test("never disables background checks entirely")
    func neverMode() {
        #expect(!UpdateMode.never.checksAutomatically)
        #expect(!UpdateMode.never.downloadsAutomatically)
    }

    @Test("modes round-trip through their stored raw values")
    func rawValueRoundTrip() {
        for mode in UpdateMode.allCases {
            #expect(UpdateMode(rawValue: mode.rawValue) == mode)
        }
    }

    // The single-source-of-truth contract: Sparkle's two persisted booleans
    // fully determine the mode, and every mode maps back onto them.
    @Test("modes round-trip through Sparkle's two booleans")
    func sparkleBooleansRoundTrip() {
        for mode in UpdateMode.allCases {
            #expect(
                UpdateMode(
                    checksAutomatically: mode.checksAutomatically,
                    downloadsAutomatically: mode.downloadsAutomatically) == mode)
        }
    }

    @Test("downloads-on with checks-off still reads as never")
    func checksOffWinsOverDownloadsOn() {
        // Sparkle can persist this combination, but without background checks
        // nothing is ever downloaded — "Never check" is the honest label.
        #expect(UpdateMode(checksAutomatically: false, downloadsAutomatically: true) == .never)
    }
}

@Suite("UpdateChannel")
struct UpdateChannelTests {
    @Test("stable allows only untagged appcast items")
    func stableAllowsNoChannels() {
        #expect(UpdateChannel.stable.allowedChannelIdentifiers.isEmpty)
    }

    @Test("beta opts into the beta stream")
    func betaAllowsBeta() {
        #expect(UpdateChannel.beta.allowedChannelIdentifiers == ["beta"])
    }
}
