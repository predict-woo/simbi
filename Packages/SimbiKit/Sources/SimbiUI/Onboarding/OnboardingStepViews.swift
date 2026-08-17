import AppKit
import CodexKit
import SimbiAudio
import SimbiKit
import SwiftUI

/// The wizard's seven steps
/// (docs/superpowers/specs/2026-08-17-onboarding-wizard-design.md § Steps).
/// Every step shares one scaffold; permission and Codex rows follow the
/// Ice pattern where the button itself is the status.

/// Shared step scaffold: hero symbol + title + subtitle, spacers, content.
private struct StepScaffold<Content: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: Design.rowGap) {
            Spacer()
            HeroHeader(symbol: symbol, title: title, subtitle: subtitle)
            content
                .padding(.top, Design.rowGap)
            Spacer()
        }
    }
}

struct WelcomeStep: View {
    var body: some View {
        StepScaffold(
            symbol: WelcomeCopy.symbol,
            title: WelcomeCopy.title,
            subtitle: WelcomeCopy.tagline
        ) {
            Text("A few quick steps set everything up.")
                .font(.meta)
                .foregroundStyle(.secondary)
        }
    }
}

struct FolderStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        StepScaffold(
            symbol: "folder",
            title: "Notes Folder",
            subtitle: "Your notes are plain files in one folder you own."
        ) {
            VStack(spacing: Design.rowGap) {
                HStack(spacing: Design.rowGap) {
                    Text((model.draft.rootURL.path as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                        .lineLimit(1)
                    Spacer()
                    if !model.isRerun {
                        Button("Change…") { choose() }
                    }
                }
                .padding(Design.paneInset)
                .frame(maxWidth: .infinity)
                .card()
                if model.isRerun {
                    Text("Change the folder in Settings > General.")
                        .font(.meta)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func choose() {
        guard
            let picked = NotesFolderPicker.choose(
                startingAt: model.draft.rootURL.deletingLastPathComponent()),
            FileManager.default.isWritableFile(atPath: picked.path)
        else { return }
        model.draft.rootURL = picked
    }
}

struct PermissionsStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        StepScaffold(
            symbol: "lock.shield",
            title: "Permissions",
            subtitle: "Simbi records your mic and system audio, locally."
        ) {
            VStack(spacing: Design.rowGap) {
                PermissionRow(
                    symbol: "mic.fill", title: "Microphone",
                    detail: "Records your side of every conversation.",
                    status: model.permissions.mic,
                    settingsURL: OnboardingPermissions.micSettingsURL
                ) { Task { await model.permissions.requestMic() } }
                PermissionRow(
                    symbol: "speaker.wave.2.fill", title: "System Audio",
                    detail: "Records the other side: calls, videos, meetings.",
                    status: model.permissions.systemAudio,
                    settingsURL: OnboardingPermissions.systemAudioSettingsURL
                ) { model.permissions.requestSystemAudio() }
            }
        }
        .task { await model.permissions.poll() }
        .onChange(of: model.permissions.bothGranted) { model.syncGates() }
    }
}

/// One permission card. The button is the status (Ice pattern):
/// Grant Access, then Open System Settings on denial, then green Granted.
private struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let status: OnboardingPermissions.Status
    let settingsURL: URL
    let request: () -> Void

    var body: some View {
        HStack(spacing: Design.rowGap) {
            Image(systemName: symbol)
                .frame(width: 24)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Design.innerGap) {
                Text(title)
                Text(detail)
                    .font(.meta)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch status {
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.statusOK)
                    .font(.metaSemibold)
            case .denied:
                Button("Open System Settings") { NSWorkspace.shared.open(settingsURL) }
            case .unknown:
                Button("Grant Access", action: request)
            }
        }
        .padding(Design.paneInset)
        .card()
        .animation(Design.Anim.standard, value: status)
    }
}

struct CodexStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        StepScaffold(
            symbol: "sparkles",
            title: "Connect Codex",
            subtitle: "Transcription and intelligence run through the ChatGPT app."
        ) {
            codexRow
        }
        .onChange(of: model.codexSetup.state) { model.syncGates() }
    }

    @ViewBuilder
    private var codexRow: some View {
        HStack(spacing: Design.rowGap) {
            StatusDot(color: model.codexSetup.state == .connected ? .statusOK : .statusWarning)
            Text(message)
            Spacer()
            if model.codexSetup.state == .connected {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.statusOK)
                    .font(.metaSemibold)
            } else {
                CodexSetupActionButton(state: model.codexSetup.state)
            }
        }
        .padding(Design.paneInset)
        .card()
        .animation(Design.Anim.standard, value: model.codexSetup.state)
    }

    private var message: String {
        switch model.codexSetup.state {
        case .notInstalled: "Install the ChatGPT app to continue."
        case .signedOut: "Sign in to ChatGPT and Simbi connects automatically."
        case .connected: "Codex connected."
        }
    }
}

struct AgentsStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        StepScaffold(
            symbol: "brain",
            title: "Agent Models",
            subtitle: "Pick a model and effort for each agent, or keep the defaults."
        ) {
            VStack(spacing: Design.rowGap) {
                ForEach(AgentRole.allCases) { role in
                    agentRow(role)
                }
            }
            .padding(Design.paneInset)
            .card()
            if model.modelsUnavailable {
                StatusBanner(
                    message: "Model list unavailable. Defaults still work.",
                    actionTitle: "Retry"
                ) { Task { await model.fetchModels() } }
            }
        }
        .task { await model.fetchModels() }
    }

    private func agentRow(_ role: AgentRole) -> some View {
        HStack {
            Text(role.title)
            Spacer()
            ModelEffortPickers(
                choice: Binding(
                    get: { model.draft[role] },
                    set: { model.draft[role] = $0 }),
                models: model.models)
        }
    }
}

struct DownloadStep: View {
    @Bindable var model: OnboardingModel
    /// When this step began being observed; gates the ETA readout so a
    /// garbage estimate never shows (Whisky's 5-second rule).
    @State private var observedSince = Date()
    @State private var firstFraction: Double = 0

    var body: some View {
        StepScaffold(
            symbol: "arrow.down.circle",
            title: "Speech Models",
            subtitle: "Diarization runs on your Mac. The models download once."
        ) {
            content
        }
        .task {
            observedSince = Date()
            if case .downloading(let fraction, _) = warmupPhase { firstFraction = fraction }
            // Preview fakes completion after a beat so the whole wizard
            // stays walkable in design review.
            if Flags.uiPreviewOnboarding {
                try? await Task.sleep(for: .seconds(3))
                model.retryDownload()
            }
            // Poll the gate while visible so Continue enables itself.
            while !Task.isCancelled {
                model.syncGates()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var warmupPhase: ModelWarmupState.Phase {
        if Flags.uiPreviewOnboarding {
            return model.flow.gates.modelsReady
                ? .ready
                : .downloading(fraction: 0.48, detail: "file 3 of 7")
        }
        return SpeechModelPool.warmupState.phase
    }

    @ViewBuilder
    private var content: some View {
        switch warmupPhase {
        case .ready:
            Label("Speech models ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.statusOK)
                .padding(Design.paneInset)
                .frame(maxWidth: .infinity)
                .card()
        case .downloading(let fraction, let detail):
            VStack(spacing: Design.rowGap) {
                MeterBar(fraction: fraction, tint: .primary)
                Text(progressLine(fraction: fraction, detail: detail))
                    .font(.meta)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(Design.paneInset)
            .card()
        case .failed(let message):
            StatusBanner(message: message, actionTitle: "Retry") {
                model.retryDownload()
            }
        case .idle:
            ProgressView()
                .controlSize(.small)
        }
    }

    /// "Downloading: 48% (file 3 of 7), about 40 seconds left". The ETA
    /// projects from progress since this step appeared.
    private func progressLine(fraction: Double, detail: String) -> String {
        var line = "Downloading: \(Int(fraction * 100))% (\(detail))"
        let elapsed = Date().timeIntervalSince(observedSince)
        let progressed = fraction - firstFraction
        if elapsed > 5, progressed > 0.01, fraction < 1 {
            let remaining = elapsed / progressed * (1 - fraction)
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = remaining >= 3600 ? [.hour, .minute] : [.minute, .second]
            formatter.unitsStyle = .full
            if let eta = formatter.string(from: remaining) {
                line += ", about \(eta) left"
            }
        }
        return line
    }
}

struct StarStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        StepScaffold(
            symbol: "star",
            title: "One Last Thing",
            subtitle:
                "Simbi is free and open source. If it becomes useful to you, a star on GitHub helps a lot."
        ) {
            VStack(spacing: Design.rowGap) {
                Button {
                    model.openGitHub()
                } label: {
                    Label("Star on GitHub", systemImage: "star.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                if let error = model.applyError {
                    StatusBanner(message: error)
                }
            }
        }
    }
}
