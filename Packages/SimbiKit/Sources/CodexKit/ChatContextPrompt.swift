import Foundation

/// Builds the attachment block that rides along with the USER'S FIRST
/// message on a chat thread (SPEC.md §5.4): the note's files embedded
/// inline so the agent can answer immediately — Simbi never sends a turn
/// of its own — plus the on-disk paths so edits land in the real files.
/// The block is model-facing only; the UI strips it via ``userVisibleText``.
public enum ChatContextPrompt {
    /// First line of the attachment block. ``userVisibleText`` strips
    /// everything from here through ``endMarker`` before a userMessage is
    /// rendered (the wire echoes the full sent text, which would otherwise
    /// show as a giant "You" row).
    public static let sentinel = "[simbi note context]"
    /// Last line of the attachment block; the user's own text follows it.
    public static let endMarker = "[end simbi note context]"

    /// What the transcript shows for a userMessage: plain messages pass
    /// through; the attachment block is cut; a message that was ONLY
    /// context (the pre-rework auto-sent turn) becomes empty — callers
    /// drop empty user rows.
    public static func userVisibleText(_ text: String) -> String {
        guard text.hasPrefix(sentinel) else { return text }
        guard let marker = text.range(of: endMarker) else { return "" }
        return String(text[marker.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
                Its files are attached below as inline copies — answer from them \
                directly, without reading the files first. The real files live in your \
                working directory at the path shown in each header; when the user asks \
                for changes, edit those files on disk, not the inline copies.
                """
        let header = """
            \(sentinel)
            This conversation is about the note at `\(notePath)`. \(inventory) \
            The user's message follows the attachments.
            """
        return ([header] + sections + [endMarker]).joined(separator: "\n\n")
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
