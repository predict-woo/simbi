import AppKit
import CodexKit
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
                Picker("Audio source", selection: $settings.audioSource) {
                    Text("Mic + system audio").tag(SimbiSettings.AudioSource.micAndSystem)
                    Text("Mic only").tag(SimbiSettings.AudioSource.mic)
                }
                .pickerStyle(.radioGroup)
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
