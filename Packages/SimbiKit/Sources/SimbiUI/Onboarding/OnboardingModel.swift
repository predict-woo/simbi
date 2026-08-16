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
    let codexSetup = CodexSetupModel()
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
            // Seed the draft from live state so the wizard shows what is
            // actually configured.
            draft.rootURL = SimbiHome.activeRootURL
            if let settings = try? SimbiSettings.load(from: SimbiHome().settingsFileURL) {
                draft.fixerModel = settings.fixerModel
                draft.fixerEffort = settings.fixerEffort
                draft.converterModel = settings.converterModel
                draft.converterEffort = settings.converterEffort
                draft.summaryModel = settings.summaryModel
                draft.summaryEffort = settings.summaryEffort
                draft.titleModel = settings.titleModel
                draft.titleEffort = settings.titleEffort
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
        if isRerun {
            // The root is latched for this process; only settings changes
            // apply live. A folder change follows the Settings relaunch
            // path instead of the first-run bootstrap.
            let home = SimbiHome()
            var settings = (try? SimbiSettings.load(from: home.settingsFileURL)) ?? .default
            settings.fixerModel = draft.fixerModel
            settings.fixerEffort = draft.fixerEffort
            settings.converterModel = draft.converterModel
            settings.converterEffort = draft.converterEffort
            settings.summaryModel = draft.summaryModel
            settings.summaryEffort = draft.summaryEffort
            settings.titleModel = draft.titleModel
            settings.titleEffort = draft.titleEffort
            try? settings.save(to: home.settingsFileURL)
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
