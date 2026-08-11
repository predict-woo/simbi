import AppKit
import CodexKit
import SimbiAudio
import SimbiKit
import SwiftUI

/// App settings (SPEC.md §5.5, §6) as the standard macOS tabbed settings
/// window: a TabView inside the `Settings` scene renders as native toolbar
/// tabs. This parent owns the single settings value (save-on-change) and
/// the app-server model list; the panes are private views over bindings.
public struct SettingsView: View {
    @State private var settings: SimbiSettings =
        (try? SimbiSettings.load(from: SimbiHome().settingsFileURL)) ?? .default
    @State private var models: [String] = []
    @State private var modelsUnavailable = false

    public init() {}

    public var body: some View {
        TabView {
            GeneralSettingsPane(settings: $settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            CodexSettingsPane(
                settings: $settings, models: models, modelsUnavailable: modelsUnavailable
            )
            .tabItem { Label("Codex", systemImage: "sparkles") }
            RecordingSettingsPane(settings: $settings)
                .tabItem { Label("Recording", systemImage: "mic") }
        }
        .frame(width: 460)
        .onChange(of: settings) {
            try? settings.save(to: SimbiHome().settingsFileURL)
        }
        .task {
            do {
                models = try await CodexModels.list(client: CodexServices.appServer)
                modelsUnavailable = models.isEmpty
            } catch {
                modelsUnavailable = true
            }
        }
    }
}

/// Notes folder location and Sparkle update preferences.
private struct GeneralSettingsPane: View {
    @Binding var settings: SimbiSettings
    @Bindable private var updates = UpdateModel.shared

    var body: some View {
        Form {
            Section("Notes folder") {
                LabeledContent("Location") {
                    HStack(spacing: 8) {
                        Text(abbreviatedHomePath)
                            .foregroundStyle(.secondary)
                            .truncationMode(.middle)
                            .lineLimit(1)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([SimbiHome().rootURL])
                        }
                    }
                }
            }
            Section("Updates") {
                Picker("Updates", selection: $updates.mode) {
                    ForEach(UpdateMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("Channel", selection: $updates.channel) {
                    ForEach(UpdateChannel.allCases, id: \.self) { channel in
                        Text(channel.title).tag(channel)
                    }
                }
                LabeledContent("Version") {
                    HStack(spacing: 8) {
                        Text(updateStatusText)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("Check Now") { updates.checkForUpdates() }
                            .disabled(!updates.canCheckForUpdates || updates.isChecking)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "1.3.0 (up to date)" / "…(checking…)" / "…(1.4.0 available)".
    private var updateStatusText: String {
        let version = updates.currentVersion
        if updates.isChecking { return "\(version) (checking…)" }
        if let available = updates.availability.version {
            return "\(version) (\(available) available)"
        }
        guard updates.mode.checksAutomatically || updates.lastCheckDate != nil else {
            return version
        }
        return "\(version) (up to date)"
    }

    /// `~`-relative home path — friendlier than the absolute `/Users/…`.
    private var abbreviatedHomePath: String {
        (SimbiHome().rootURL.path as NSString).abbreviatingWithTildeInPath
    }
}

/// Per-feature model overrides and the editable agent instruction files.
private struct CodexSettingsPane: View {
    @Binding var settings: SimbiSettings
    let models: [String]
    let modelsUnavailable: Bool
    /// Instruction file awaiting reset confirmation (nil = no dialog).
    @State private var resetTarget: AgentInstructions?

    var body: some View {
        Form {
            Section("Models") {
                modelPicker("Transcript fixer", selection: $settings.fixerModel)
                modelPicker("File converter", selection: $settings.converterModel)
                modelPicker("AI notes", selection: $settings.summaryModel)
                if modelsUnavailable {
                    Text("Model list unavailable. Is the ChatGPT app installed?")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Agent instructions") {
                ForEach(AgentInstructions.allCases) { file in
                    instructionsRow(file)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .alert(
            "Reset to default?",
            isPresented: Binding(
                get: { resetTarget != nil },
                set: { if !$0 { resetTarget = nil } }
            ),
            presenting: resetTarget
        ) { file in
            Button("Reset", role: .destructive) {
                InstructionsEditorWindowManager.shared.reset(file)
            }
            Button("Cancel", role: .cancel) {}
        } message: { file in
            Text("This replaces \(file.fileName) with the default instructions. Your edits will be lost.")
        }
    }

    /// One editable instruction file (SPEC.md §2.1): its role, a "…" menu
    /// with the file actions, and the editor button.
    private func instructionsRow(_ file: AgentInstructions) -> some View {
        LabeledContent(file.title) {
            HStack(spacing: 8) {
                Menu {
                    Button("Reveal in Finder") {
                        InstructionsEditorWindowManager.shared.revealInFinder(file)
                    }
                    Button("Reset to Default…", role: .destructive) {
                        resetTarget = file
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Button("Edit") {
                    InstructionsEditorWindowManager.shared.open(file)
                }
            }
        }
    }

    private func modelPicker(_ title: String, selection: Binding<String?>) -> some View {
        Picker(title, selection: selection) {
            Text("Default").tag(String?.none)
            // Keep a saved override selectable even if the list is stale.
            let options =
                models.contains(selection.wrappedValue ?? "") || selection.wrappedValue == nil
                ? models
                : [selection.wrappedValue!] + models
            ForEach(options, id: \.self) { model in
                Text(model).tag(String?.some(model))
            }
        }
    }
}

/// Default recording sources (SPEC.md §3.1).
private struct RecordingSettingsPane: View {
    @Binding var settings: SimbiSettings

    var body: some View {
        Form {
            Section("Recording") {
                Picker("Microphone", selection: micSelection) {
                    Text("Off").tag(MicChoice.off)
                    Text("System default").tag(MicChoice.systemDefault)
                    ForEach(microphones) { mic in
                        Text(mic.name).tag(MicChoice.device(mic.id))
                    }
                    // A saved-but-unplugged mic stays selectable rather
                    // than silently snapping to another option.
                    if case .device(let uid) = micSelection.wrappedValue,
                        !microphones.contains(where: { $0.id == uid })
                    {
                        Text("Saved microphone (not connected)").tag(MicChoice.device(uid))
                    }
                }
                Toggle("Capture system audio", isOn: $settings.systemAudioEnabled)
                    // The last active source can't be turned off.
                    .disabled(!settings.micEnabled)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private enum MicChoice: Hashable {
        case off
        case systemDefault
        case device(String)
    }

    /// Re-read per render so a newly plugged-in mic appears without
    /// reopening Settings.
    private var microphones: [AudioInputDevice] {
        AudioInputDevices.list()
    }

    private var micSelection: Binding<MicChoice> {
        Binding {
            guard settings.micEnabled else { return .off }
            return settings.micDeviceUID.map(MicChoice.device) ?? .systemDefault
        } set: { choice in
            switch choice {
            case .off:
                settings.micEnabled = false
                // Something must still record (SPEC.md §3.1).
                settings.systemAudioEnabled = true
            case .systemDefault:
                settings.micEnabled = true
                settings.micDeviceUID = nil
            case .device(let uid):
                settings.micEnabled = true
                settings.micDeviceUID = uid
            }
        }
    }
}
