import AppKit
import CodexKit
import Foundation
import Observation
import SimbiAudio
import SimbiKit

/// Coordinator for the first-run wizard
/// (docs/superpowers/specs/2026-08-17-onboarding-wizard-design.md): owns
/// the pure flow, the draft, and the live gate sources; the views only
/// render and call intents. Nothing persists until `finish()`.
@MainActor @Observable
final class OnboardingModel {
    private(set) var flow = OnboardingFlow()
    var draft = OnboardingState.Draft()
    let permissions = OnboardingPermissions()
    let codexSetup = CodexSetupModel.shared
    private(set) var models: [CodexModels.Model] = []
    private(set) var modelsUnavailable = false
    /// Non-nil while the Finish apply has failed; shown as a StatusBanner.
    private(set) var applyError: String?
    /// True once Finish succeeded; SimbiRootView flips to the main UI.
    private(set) var completed = false

    static let repoURL = URL(string: "https://github.com/predict-woo/simbi")!

    /// Reopened over a running app (Help > Welcome to Simbi): the root is
    /// already latched, so the folder step is read-only and Finish only
    /// saves settings.
    let isRerun: Bool

    var step: OnboardingStep { flow.step }
    var canContinue: Bool { flow.canAdvance() }
    var isFinal: Bool { flow.isFinal }

    init() {
        isRerun = OnboardingPresenter.shared.isRerun
        if isRerun {
            draft.rootURL = SimbiHome.activeRootURL
        } else {
            // A version-bump re-onboard on an existing install must show
            // the folder actually in use, not the factory default.
            // `resolvedRootURL()` reads the stored override without
            // touching the `activeRootURL` latch.
            draft.rootURL = SimbiHome.resolvedRootURL()
        }
        // Seed the draft from existing settings when a home already
        // exists (re-run, or a first run over a previous install), so
        // Finish never clobbers configured models with empty defaults.
        // NOTE: reads the draft root directly, never `SimbiHome()` — the
        // first-run path must not latch `activeRootURL` before apply.
        if let settings = try? SimbiSettings.load(
            from: SimbiHome(rootURL: draft.rootURL).settingsFileURL)
        {
            for role in AgentRole.allCases {
                draft[role] = settings[role]
            }
        }
        // The big download starts the moment the wizard exists, so the
        // download step near the end is usually already green. Preview
        // mode fakes readiness instead of touching the network.
        if !Flags.uiPreviewOnboarding {
            SpeechModelPool.shared.warmUp()
        }
        syncGates()
    }

    func advance() {
        syncGates()
        flow.advance()
    }

    func goBack() {
        applyError = nil
        flow.goBack()
    }

    /// Re-reads every gate from its live source. Cheap; called by the
    /// steps' pollers and before any advance.
    func syncGates() {
        flow.gates.micGranted = permissions.mic == .granted
        flow.gates.systemAudioGranted = permissions.systemAudio == .granted
        flow.gates.codexConnected = codexSetup.state == .connected
        if !Flags.uiPreviewOnboarding {
            flow.gates.modelsReady = SpeechModelPool.warmupState.phase == .ready
        }
    }

    /// Model list for the agents step; Codex is connected by the time
    /// this step shows, but failure still degrades to Default-only.
    func fetchModels() async {
        guard models.isEmpty else { return }
        do {
            models = try await CodexModels.list(client: CodexServices.appServer)
            modelsUnavailable = models.isEmpty
        } catch {
            modelsUnavailable = true
        }
    }

    func retryDownload() {
        if Flags.uiPreviewOnboarding {
            flow.gates.modelsReady = true
            return
        }
        SpeechModelPool.shared.warmUp()
    }

    func finish() {
        if Flags.uiPreviewOnboarding {
            // Design review must never persist anything.
            completed = true
            OnboardingPresenter.shared.dismiss()
            return
        }
        if isRerun {
            // The root is latched for this process; only settings changes
            // apply live. A folder change follows the Settings relaunch
            // path instead of the first-run bootstrap.
            let home = SimbiHome()
            var settings = SimbiSettings.current(home: home)
            for role in AgentRole.allCases {
                settings[role] = draft[role]
            }
            do {
                try settings.save(to: home.settingsFileURL)
            } catch {
                Log.ui.error("saving onboarding model choices failed: \(error)")
            }
            completed = true
            OnboardingPresenter.shared.dismiss()
            return
        }
        do {
            try OnboardingState.apply(draft)
            OnboardingState.markCompleted()
            applyError = nil
            completed = true
            OnboardingPresenter.shared.dismiss()
        } catch {
            applyError = "Could not set up the notes folder: \(error.localizedDescription)"
        }
    }

    func openGitHub() {
        NSWorkspace.shared.open(Self.repoURL)
    }
}
