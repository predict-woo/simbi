import AppKit

/// The "choose your notes folder" open panel shared by Settings and the
/// onboarding folder step. Returns the standardized pick, nil on cancel.
@MainActor
enum NotesFolderPicker {
    static func choose(startingAt directory: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder Simbi keeps its notes in."
        panel.directoryURL = directory
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.standardizedFileURL
    }
}
