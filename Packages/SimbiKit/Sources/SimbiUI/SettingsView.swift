import AppKit
import CodexKit
import SimbiAudio
import SimbiKit
import SwiftUI

/// App settings (SPEC.md §5.5, §6): per-feature model selectors populated
/// from the app-server's model list ("Default" = no override), the audio
/// source default, and a home-folder reveal.
public struct SettingsView: View {
    @State private var settings: SimbiSettings =
        (try? SimbiSettings.load(from: SimbiHome().settingsFileURL)) ?? .default
    @State private var models: [String] = []
    @State private var modelsUnavailable = false

    public init() {}

    public var body: some View {
        Form {
            Section("Codex models") {
                modelPicker("Transcript fixer", selection: $settings.fixerModel)
                modelPicker("File converter", selection: $settings.converterModel)
                modelPicker("Chat threads", selection: $settings.chatModel)
                if modelsUnavailable {
                    Text("Model list unavailable — is the ChatGPT app installed?")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
                        !microphones.contains(where: { $0.id == uid }) {
                        Text("Saved microphone (not connected)").tag(MicChoice.device(uid))
                    }
                }
                Toggle("Capture system audio", isOn: $settings.systemAudioEnabled)
                    // The last active source can't be turned off.
                    .disabled(!settings.micEnabled)
            }
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
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
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

    /// `~`-relative home path — friendlier than the absolute `/Users/…`.
    private var abbreviatedHomePath: String {
        (SimbiHome().rootURL.path as NSString).abbreviatingWithTildeInPath
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
