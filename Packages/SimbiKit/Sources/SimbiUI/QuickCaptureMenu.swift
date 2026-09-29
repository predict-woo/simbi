import AppKit
import Observation
import SimbiKit
import SwiftUI

/// Stable scene identity for the app's single main window.
public enum SimbiWindow {
    public static let mainID = "simbi-main"
}

/// Menubar-first recording: choose any normal Simbi folder, create a
/// timestamped note there, and start the per-note recorder immediately.
@MainActor @Observable
public final class QuickCaptureModel {
    public static let shared = QuickCaptureModel()

    public let home: SimbiHome
    public private(set) var nodes: [FileTreeNode] = []
    public private(set) var lastError: String?

    private var watcher: FileTreeWatcher?
    private static let lastFolderDefaultsKey = "quickCapture.lastFolderURL"

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return formatter
    }()

    private init() {
        home = SimbiHome()
        guard !OnboardingState.isNeeded() else { return }
        refresh()
        watcher = FileTreeWatcher.observing(url: home.rootURL) { [weak self] in
            self?.refresh()
        }
    }

    public var rootFolders: [FileTreeNode] {
        nodes.filter { $0.kind == .folder }
    }

    /// The checked destination in the menubar: keep using the last folder
    /// chosen. A single available folder is an obvious first-run default;
    /// otherwise the Simbi root remains the safe fallback.
    public var quickStartParent: URL {
        if let lastFolderURL { return lastFolderURL }
        if rootFolders.count == 1, let onlyFolder = rootFolders.first {
            return onlyFolder.url
        }
        return home.rootURL
    }

    private var lastFolderURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: Self.lastFolderDefaultsKey) else {
            return nil
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue,
            isValidFolderDestination(url)
        else { return nil }
        return url
    }

    public func refresh() {
        guard !OnboardingState.isNeeded() else {
            nodes = []
            return
        }
        do {
            try home.bootstrap()
        } catch {
            lastError = "Could not open the Simbi folder: \(error.localizedDescription)"
            return
        }
        nodes = FileTreeScanner.scan(root: home.rootURL)
    }

    /// Creates the note before starting capture, so the recording pipeline
    /// owns a real, durable folder from its first byte.
    public func start(in parent: URL) {
        guard !RecordingActivity.shared.isRecording else { return }
        lastError = nil

        let parent = parent.standardizedFileURL
        guard parent == home.rootURL || !NoteOperations.isInsideNoteFolder(parent) else {
            lastError = "Choose a Simbi folder, not an existing note."
            return
        }
        guard isValidFolderDestination(parent) else {
            lastError = "Choose a folder inside Simbi."
            return
        }

        do {
            UserDefaults.standard.set(parent.path, forKey: Self.lastFolderDefaultsKey)
            let timestamp = Self.timestampFormatter.string(from: .now)
            let name = NoteOperations.availableName(timestamp, in: parent)
            let noteURL = try NoteOperations.createNote(named: name, in: parent)
            let controller = RecordingController.shared(noteFolderURL: noteURL)
            let summary = SummaryController.shared(noteFolderURL: noteURL)
            let title = TitleController.shared(noteFolderURL: noteURL)

            // Quick capture has no NoteView yet, so install the same
            // post-recording AI hooks that NoteView normally wires up.
            controller.onRecordingStopped = { [weak summary, weak title] in
                summary?.recordingDidStop()
                title?.recordingDidStop()
            }
            title.noteIsQuiet = { [weak controller, weak summary] in
                TitleController.isQuiet(
                    fixerStatus: controller?.fixerActivity.status ?? .off,
                    summaryWorking: summary?.status == .working)
            }
            title.renameNote = { [weak self] newName in
                do {
                    let renamed = try NoteOperations.rename(noteURL, to: newName)
                    SidebarOrder.renamed(
                        from: noteURL.lastPathComponent,
                        to: renamed.lastPathComponent,
                        in: noteURL.deletingLastPathComponent())
                    self?.refresh()
                } catch {
                    Log.ui.error("quick capture title rename failed: \(error)")
                }
            }
            controller.startRecording()
            refresh()

            // Surface a startup failure in the menubar instead of leaving an
            // empty timestamped note with no explanation.
            Task { @MainActor [weak self, weak controller] in
                try? await Task.sleep(for: .seconds(1))
                guard let controller, case .failed(let message) = controller.status else { return }
                self?.lastError = message
            }
        } catch {
            lastError = "Could not create the recording note: \(error.localizedDescription)"
        }
    }

    public func stop() {
        guard let noteURL = RecordingActivity.shared.activeNoteURL else { return }
        RecordingController.shared(noteFolderURL: noteURL).toggle()
    }

    private func isValidFolderDestination(_ url: URL) -> Bool {
        let root = home.rootURL.standardizedFileURL
        let path = url.standardizedFileURL.path
        guard path == root.path || path.hasPrefix(root.path + "/") else { return false }
        return path == root.path || !NoteOperations.isInsideNoteFolder(url)
    }

}

/// The app-level menubar content. The model is resolved only after onboarding
/// is dismissed, so the menubar never latches SimbiHome to the default folder
/// before the user chooses a notes location.
public struct QuickCaptureMenuContent: View {
    @State private var onboarding = OnboardingPresenter.shared
    @State private var activity = RecordingActivity.shared

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if onboarding.isActive {
                Text("Finish Simbi setup to start recording")
                OpenSimbiButton()
            } else {
                QuickCaptureMenu(model: QuickCaptureModel.shared, activity: activity)
            }
            Divider()
            Button("Quit Simbi") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.borderless)
        .padding(10)
        .frame(width: 280, alignment: .leading)
    }
}

/// The compact label stays visible even when the main window is closed.
public struct QuickCaptureMenuBarLabel: View {
    @State private var activity = RecordingActivity.shared

    public init() {}

    public var body: some View {
        Image(systemName: activity.isRecording ? "record.circle.fill" : "waveform")
            .symbolRenderingMode(.hierarchical)
            .accessibilityLabel(activity.isRecording ? "Recording" : "Start recording")
    }
}

private struct QuickCaptureMenu: View {
    @Bindable private var model: QuickCaptureModel
    @Bindable private var activity: RecordingActivity

    init(model: QuickCaptureModel, activity: RecordingActivity) {
        self.model = model
        self.activity = activity
    }

    var body: some View {
        Group {
            if OnboardingState.isNeeded() {
                Text("Finish Simbi setup to start recording")
                OpenSimbiButton()
            } else if activity.isRecording {
                Section {
                    Label(
                        model.recordingLabel,
                        systemImage: "record.circle.fill"
                    )
                    .foregroundStyle(.red)
                    Button("Stop Recording", systemImage: "stop.circle") {
                        model.stop()
                    }
                }
            } else {
                ForEach(folderDestinations) { destination in
                    Toggle(isOn: destinationBinding(for: destination)) {
                        Text(destination.path)
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("Record in \(destination.path)")
                }
            }

            if let error = model.lastError {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            Divider()
            OpenSimbiButton()
            SettingsLink {
                Text("Settings…")
            }
        }
        .onAppear { model.refresh() }
    }

    private var folderDestinations: [FolderDestination] {
        [FolderDestination(url: model.home.rootURL, path: "Simbi")]
            + model.rootFolders.flatMap { allFolderDestinations(for: $0, prefix: "") }
    }

    private func destinationBinding(for destination: FolderDestination) -> Binding<Bool> {
        Binding(
            get: {
                model.quickStartParent.standardizedFileURL
                    == destination.url.standardizedFileURL
            },
            // A folder row is an action, not a persistent on/off setting:
            // clicking either the checked or unchecked row starts capture.
            set: { _ in model.start(in: destination.url) }
        )
    }

    private func allFolderDestinations(
        for node: FileTreeNode,
        prefix: String
    ) -> [FolderDestination] {
        let path = prefix.isEmpty ? node.name : "\(prefix) / \(node.name)"
        var destinations = [FolderDestination(url: node.url, path: path)]
        for child in (node.children ?? []).filter({ $0.kind == .folder }) {
            destinations.append(contentsOf: allFolderDestinations(for: child, prefix: path))
        }
        return destinations
    }
}

private struct OpenSimbiButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Simbi") {
            openWindow(id: SimbiWindow.mainID)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct FolderDestination: Identifiable {
    let url: URL
    let path: String

    var id: String {
        url.standardizedFileURL.path
    }
}

private extension QuickCaptureModel {
    var recordingLabel: String {
        if let noteURL = RecordingActivity.shared.activeNoteURL {
            return "Recording in \(noteURL.deletingLastPathComponent().lastPathComponent)/\(noteURL.lastPathComponent)…"
        }
        return "Recording…"
    }
}
