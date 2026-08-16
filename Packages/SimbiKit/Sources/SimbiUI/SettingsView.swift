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
    @State private var models: [CodexModels.Model] = []
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
    /// A freshly picked home root awaiting the relaunch confirmation
    /// (nil = no dialog). Nothing is persisted until the user confirms.
    @State private var proposedRootURL: URL?

    var body: some View {
        Form {
            Section("Notes folder") {
                LabeledContent("Location") {
                    HStack(spacing: 8) {
                        Text(abbreviatedPath(SimbiHome().rootURL))
                            .foregroundStyle(.secondary)
                            .truncationMode(.middle)
                            .lineLimit(1)
                        Menu {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([
                                    SimbiHome().rootURL
                                ])
                            }
                            if SimbiHome.overrideRootURL() != nil {
                                Button("Reset to Default…") {
                                    proposedRootURL = SimbiHome.defaultRootURL
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        Button("Change…") { chooseHomeFolder() }
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
        .alert(
            "Relaunch Simbi to switch the notes folder?",
            isPresented: Binding(
                get: { proposedRootURL != nil },
                set: { if !$0 { proposedRootURL = nil } }
            ),
            presenting: proposedRootURL
        ) { url in
            Button("Relaunch") {
                SimbiHome.setOverrideRootURL(url == SimbiHome.defaultRootURL ? nil : url)
                relaunch()
            }
            Button("Cancel", role: .cancel) {}
        } message: { url in
            Text("Simbi will relaunch using \(abbreviatedPath(url)). Your notes stay where they are.")
        }
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

    /// `~`-relative path — friendlier than the absolute `/Users/…`.
    private func abbreviatedPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// Directory picker for the next home folder. The choice is only
    /// proposed here; the relaunch alert persists or discards it.
    private func chooseHomeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder Simbi keeps its notes in."
        panel.directoryURL = SimbiHome().rootURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let picked = url.standardizedFileURL
        guard picked != SimbiHome.activeRootURL else { return }
        proposedRootURL = picked
    }

    /// Quit and start a fresh instance, which latches the new home root.
    /// The `open` runs from a detached shell so it outlives this process;
    /// the path travels as an argument to sidestep quoting.
    private func relaunch() {
        let helper = Process()
        helper.executableURL = URL(filePath: "/bin/sh")
        helper.arguments = ["-c", #"sleep 0.5; /usr/bin/open "$0""#, Bundle.main.bundlePath]
        try? helper.run()
        NSApp.terminate(nil)
    }
}

/// Per-feature model overrides and the editable agent instruction files.
private struct CodexSettingsPane: View {
    @Binding var settings: SimbiSettings
    let models: [CodexModels.Model]
    let modelsUnavailable: Bool
    /// Instruction file awaiting reset confirmation (nil = no dialog).
    @State private var resetTarget: AgentInstructions?

    var body: some View {
        Form {
            Section("Models") {
                modelRow(
                    "Transcript fixer", model: $settings.fixerModel,
                    effort: $settings.fixerEffort)
                modelRow(
                    "File converter", model: $settings.converterModel,
                    effort: $settings.converterEffort)
                modelRow(
                    "AI notes", model: $settings.summaryModel,
                    effort: $settings.summaryEffort)
                modelRow(
                    "Note title", model: $settings.titleModel,
                    effort: $settings.titleEffort)
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

    /// One feature's overrides: its model and, beside it, the reasoning
    /// effort — whose options follow the model chosen in the same row.
    private func modelRow(
        _ title: String, model: Binding<String?>, effort: Binding<String?>
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                modelPicker(selection: model)
                effortPicker(modelId: model.wrappedValue, selection: effort)
            }
        }
    }

    private func modelPicker(selection: Binding<String?>) -> some View {
        Picker("Model", selection: selection) {
            Text("Default").tag(String?.none)
            ForEach(stalePreserving(selection.wrappedValue, in: models.map(\.id)), id: \.self) {
                model in
                Text(model).tag(String?.some(model))
            }
        }
        .labelsHidden()
    }

    /// Efforts of the row's model ("Default" model = the server's default
    /// model), so the options track the picker beside this one.
    private func effortPicker(modelId: String?, selection: Binding<String?>) -> some View {
        let efforts = CodexModels.efforts(for: modelId, in: models)
        return Picker("Effort", selection: selection) {
            Text("Default").tag(String?.none)
            ForEach(stalePreserving(selection.wrappedValue, in: efforts.map(\.id)), id: \.self) {
                effort in
                Text(effort).tag(String?.some(effort))
            }
        }
        .labelsHidden()
        .fixedSize()
        .help(
            efforts.first(where: { $0.id == selection.wrappedValue })?.description
                ?? "Reasoning effort. Default uses the model's own default.")
    }

    /// Keep a saved override selectable even if the list is stale.
    private func stalePreserving(_ saved: String?, in options: [String]) -> [String] {
        guard let saved, !options.contains(saved) else { return options }
        return [saved] + options
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
