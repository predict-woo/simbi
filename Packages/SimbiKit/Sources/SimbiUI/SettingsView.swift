import AppKit
import CodexKit
import Observation
import SimbiAudio
import SimbiKit
import SwiftUI

/// The controls view of settings.json. External edits reload while clean;
/// a simultaneous local change must be resolved explicitly before either
/// side can replace the other.
@MainActor
@Observable
final class SettingsDocument {
    private enum DiskSnapshot: Equatable {
        case missing
        case data(Data)

        var settings: SimbiSettings? {
            switch self {
            case .missing: .default
            case .data(let data): try? JSONDecoder().decode(SimbiSettings.self, from: data)
            }
        }
    }

    let fileURL: URL
    var settings: SimbiSettings
    var hasConflict: Bool { conflictingDiskSnapshot != nil }

    private var diskSnapshot: DiskSnapshot
    private var conflictingDiskSnapshot: DiskSnapshot?
    private var watcher: FileTreeWatcher?

    init(home: SimbiHome = SimbiHome()) {
        fileURL = home.settingsFileURL
        let snapshot = Self.readDiskSnapshot(at: fileURL) ?? .missing
        diskSnapshot = snapshot
        settings = snapshot.settings ?? .default
        conflictingDiskSnapshot = snapshot.settings == nil ? snapshot : nil
        watcher = FileTreeWatcher.observing(url: fileURL.deletingLastPathComponent()) {
            [weak self] in
            self?.refreshFromDisk()
        }
    }

    func save() {
        guard conflictingDiskSnapshot == nil, settings != diskSnapshot.settings else { return }
        guard let current = Self.readDiskSnapshot(at: fileURL) else { return }
        guard current == diskSnapshot else {
            if settings == current.settings {
                diskSnapshot = current
                return
            }
            conflictingDiskSnapshot = current
            return
        }
        do {
            let data = try PersistedJSON.encoder().encode(settings)
            try data.write(to: fileURL, options: .atomic)
            diskSnapshot = .data(data)
        } catch {
            Log.files.error("saving settings.json failed: \(error)")
        }
    }

    func refreshFromDisk() {
        guard let latest = Self.readDiskSnapshot(at: fileURL), latest != diskSnapshot else {
            return
        }
        guard let latestSettings = latest.settings else {
            conflictingDiskSnapshot = latest
            return
        }
        if settings == latestSettings {
            diskSnapshot = latest
            conflictingDiskSnapshot = nil
            return
        }
        guard settings == diskSnapshot.settings else {
            conflictingDiskSnapshot = latest
            return
        }
        diskSnapshot = latest
        conflictingDiskSnapshot = nil
        settings = latestSettings
    }

    func reloadFromDisk() {
        guard let latest = Self.readDiskSnapshot(at: fileURL), let latestSettings = latest.settings
        else { return }
        diskSnapshot = latest
        conflictingDiskSnapshot = nil
        settings = latestSettings
    }

    func overwriteDisk() {
        guard conflictingDiskSnapshot != nil,
            let latest = Self.readDiskSnapshot(at: fileURL)
        else { return }
        diskSnapshot = latest
        conflictingDiskSnapshot = nil
        save()
    }

    private static func readDiskSnapshot(at url: URL) -> DiskSnapshot? {
        do {
            return .data(try Data(contentsOf: url))
        } catch {
            guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
            Log.files.error("reading settings.json after a file change failed: \(error)")
            return nil
        }
    }
}

/// App settings (SPEC.md §5.5, §6) as the standard macOS tabbed settings
/// window: a TabView inside the `Settings` scene renders as native toolbar
/// tabs. This parent owns the single settings value (save-on-change) and
/// the app-server model list; the panes are private views over bindings.
public struct SettingsView: View {
    @State private var document = SettingsDocument()
    @State private var models: [CodexModels.Model] = []
    @State private var modelsUnavailable = false

    public init() {}

    public var body: some View {
        @Bindable var document = document
        VStack(spacing: 0) {
            if document.hasConflict {
                FileConflictBanner(
                    fileName: document.fileURL.lastPathComponent,
                    reload: document.reloadFromDisk,
                    overwrite: document.overwriteDisk)
            }
            TabView {
                GeneralSettingsPane(settings: $document.settings)
                    .tabItem { Label("General", systemImage: "gearshape") }
                CodexSettingsPane(
                    settings: $document.settings, models: models,
                    modelsUnavailable: modelsUnavailable
                )
                .tabItem { Label("Codex", systemImage: "sparkles") }
                RecordingSettingsPane(settings: $document.settings)
                    .tabItem { Label("Recording", systemImage: "mic") }
            }
        }
        .frame(width: 460)
        .onChange(of: document.settings) {
            document.save()
        }
        .task {
            models = await CodexModels.availableModels(client: CodexServices.appServer)
            modelsUnavailable = models.isEmpty
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
        guard
            let picked = NotesFolderPicker.choose(
                startingAt: SimbiHome().rootURL.deletingLastPathComponent()),
            picked != SimbiHome.activeRootURL
        else { return }
        proposedRootURL = picked
    }

    /// Quit and start a fresh instance, which latches the new home root.
    private func relaunch() {
        // Quitting without a spawned relauncher would strand the user.
        guard Relaunch.spawnRelauncher(bundlePath: Bundle.main.bundlePath) else { return }
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
            Section("Agent features") {
                Toggle("Transcript fixer", isOn: $settings.transcriptFixerEnabled)
                Toggle("AI notes", isOn: $settings.aiNotesEnabled)
                Toggle("Note title", isOn: $settings.noteTitleEnabled)
            }
            Section("Models") {
                ForEach(AgentRole.allCases) { role in
                    modelRow(role)
                }
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

    /// One role's overrides: its model and, beside it, the reasoning
    /// effort — whose options follow the model chosen in the same row.
    private func modelRow(_ role: AgentRole) -> some View {
        LabeledContent(role.title) {
            ModelEffortPickers(
                choice: Binding(
                    get: { settings[role] },
                    set: { settings[role] = $0 }),
                models: models)
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
