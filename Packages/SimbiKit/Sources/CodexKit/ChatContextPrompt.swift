import Foundation

/// Builds the chat thread's context message (SPEC.md §5.4): the note's
/// files embedded inline so the agent can answer immediately — no
/// read-the-files turn — plus the on-disk paths so edits land in the real
/// files. The message is model-facing only; the UI hides it via
/// ``sentinel``.
public enum ChatContextPrompt {
    /// First line of the context message; the transcript filters rows
    /// carrying this prefix (the wire echoes the message as a userMessage
    /// item, which would otherwise render as a giant "You" row).
    public static let sentinel = "[simbi note context]"

    /// Per-file and whole-message caps keep a long transcript from eating
    /// the thread's context window; truncated files point back to disk.
    static let perFileLimit = 60_000
    static let totalLimit = 180_000

    public static func build(noteFolderURL: URL, homeRootURL: URL) -> String {
        let notePath = CodexChat.notePath(
            noteFolderURL: noteFolderURL, homeRootURL: homeRootURL)
        var sections: [String] = []
        var budget = totalLimit
        for fileURL in attachableFiles(noteFolderURL: noteFolderURL) {
            let relPath = "\(notePath)/\(relativeName(of: fileURL, in: noteFolderURL))"
            guard budget > 0 else {
                sections.append(
                    "[more files omitted — read them under `\(notePath)/` in your working directory]"
                )
                break
            }
            guard var content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            let limit = min(perFileLimit, budget)
            if content.count > limit {
                content = String(content.prefix(limit))
                    + "\n[truncated — the full file is at `\(relPath)`]"
            }
            budget -= content.count
            sections.append("===== BEGIN \(relPath) =====\n\(content)\n===== END \(relPath) =====")
        }

        let inventory =
            sections.isEmpty
            ? "The note has no files yet; its folder is `\(notePath)` in your working directory."
            : """
                The note's files are attached below as inline copies — answer from them \
                directly, without reading the files first. The real files live in your \
                working directory at the path shown in each header; when the user asks \
                for changes, edit those files on disk, not the inline copies.
                """
        let header = """
            \(sentinel)
            The user wants to discuss the note at `\(notePath)`. \(inventory) \
            Reply with one short sentence once you're ready.
            """
        return ([header] + sections).joined(separator: "\n\n")
    }

    /// note.md, transcript.vtt, then context/*.md sorted by name — the same
    /// set the old read-the-files prompt named.
    private static func attachableFiles(noteFolderURL: URL) -> [URL] {
        var files = ["note.md", "transcript.vtt"]
            .map { noteFolderURL.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let contextDir = noteFolderURL.appending(path: "context")
        let contextFiles =
            ((try? FileManager.default.contentsOfDirectory(
                at: contextDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        files.append(contentsOf: contextFiles)
        return files
    }

    private static func relativeName(of fileURL: URL, in noteFolderURL: URL) -> String {
        let note = noteFolderURL.standardizedFileURL.path
        let file = fileURL.standardizedFileURL.path
        if file.hasPrefix(note + "/") {
            return String(file.dropFirst(note.count + 1))
        }
        return fileURL.lastPathComponent
    }
}
