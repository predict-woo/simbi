import Foundation

/// One local Codex project for every thread Simbi creates. The shared root
/// keeps threads together in Codex, while each task still receives an explicit
/// note directory and a note-scoped sandbox from its caller.
struct SimbiCodexProject: Sendable, Equatable {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    /// App-owned scope placed ahead of user-editable role instructions. This
    /// lets existing templates keep using paths such as `note.md` even though
    /// the thread's Codex project now starts at the shared Simbi root.
    func instructions(for noteFolderURL: URL, taskDirectoryURL: URL, task: String) -> String {
        let notePath = CodexChat.notePath(
            noteFolderURL: noteFolderURL, homeRootURL: rootURL)
        let taskPath = CodexChat.notePath(
            noteFolderURL: taskDirectoryURL, homeRootURL: rootURL)
        return """
            The Codex project working directory is the shared Simbi home. The active Simbi note is \
            `\(notePath)`. The task directory is `\(taskPath)`. Change to that task directory before \
            running commands or editing files. For the task instructions below, resolve every \
            relative file path from there, not from the project root. Work only inside the active \
            note unless the user explicitly asks otherwise.

            \(task)
            """
    }

    /// A consistent user-visible name that remains useful when all Simbi
    /// threads appear together in one Codex project.
    func threadName(
        for noteFolderURL: URL, role: String, detail: String? = nil
    ) -> String {
        let notePath = CodexChat.notePath(
            noteFolderURL: noteFolderURL, homeRootURL: rootURL)
        let base = "[Simbi · \(notePath)] \(role)"
        guard let detail, !detail.isEmpty else { return base }
        return base + " — " + detail
    }
}
