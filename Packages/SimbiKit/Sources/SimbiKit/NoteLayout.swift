import Foundation

/// The note folder's on-disk contract (SPEC.md §3): every file and
/// directory name a note is made of, in one place. `transcript.vtt` stays
/// with `VTT.fileURL` (the VTT module owns its own file); everything else
/// resolves here so no module hardcodes a layout name.
public enum NoteLayout {
    /// One continuous WebM/Opus recording across all sessions.
    public static let audioFileName = "audio.webm"
    /// AI-notes output; its mere existence makes the notes tab appear.
    public static let summaryFileName = "summary.md"
    /// Hidden per-note state: state.json, upload queue, fixer worktree.
    public static let stateDirName = ".simbi"
    /// Imported originals, untouched.
    public static let filesDirName = "files"
    /// Codex-converted markdown twins of `files/`.
    public static let contextDirName = "context"

    public static func audioURL(noteFolder: URL) -> URL {
        noteFolder.appending(path: audioFileName)
    }

    public static func summaryURL(noteFolder: URL) -> URL {
        noteFolder.appending(path: summaryFileName)
    }

    public static func stateDirURL(noteFolder: URL) -> URL {
        noteFolder.appending(path: stateDirName, directoryHint: .isDirectory)
    }

    /// Disk-backed upload queue (`{cueIndex}.webm` + `{cueIndex}.json`).
    public static func pendingDirURL(noteFolder: URL) -> URL {
        stateDirURL(noteFolder: noteFolder).appending(path: "pending", directoryHint: .isDirectory)
    }

    /// Segments that exhausted their upload retries, kept for post-hoc tooling.
    public static func failedDirURL(noteFolder: URL) -> URL {
        stateDirURL(noteFolder: noteFolder).appending(path: "failed", directoryHint: .isDirectory)
    }

    /// The fixer thread's writable copy of the transcript (snapshot-and-replay).
    public static func fixerWorktreeURL(noteFolder: URL) -> URL {
        stateDirURL(noteFolder: noteFolder)
            .appending(path: "fixer-worktree", directoryHint: .isDirectory)
    }

    public static func filesDirURL(noteFolder: URL) -> URL {
        noteFolder.appending(path: filesDirName, directoryHint: .isDirectory)
    }

    public static func contextDirURL(noteFolder: URL) -> URL {
        noteFolder.appending(path: contextDirName, directoryHint: .isDirectory)
    }

    /// `context/<original file name>.md` — the converted twin of an import.
    public static func contextURL(noteFolder: URL, fileName: String) -> URL {
        contextDirURL(noteFolder: noteFolder).appending(path: fileName + ".md")
    }
}

/// The on-disk JSON house style — pretty-printed, key-sorted (stable
/// diffs), ISO 8601 dates. Every persisted JSON file (state.json,
/// settings.json, pending-segment sidecars) encodes through it.
public enum PersistedJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

/// The `"Speaker N"` display convention (SPEC.md §5.3): written into cue
/// voice tags by the pipeline, parsed back for stable speaker colors.
/// Slots are 0-based internally; display numbers are 1-based.
public enum SpeakerLabel {
    private static let prefix = "Speaker "

    public static func name(slot: Int) -> String {
        "\(prefix)\(slot + 1)"
    }

    /// The 0-based slot a default label refers to; nil for renamed speakers.
    public static func slot(name: String) -> Int? {
        guard name.hasPrefix(prefix), let number = Int(name.dropFirst(prefix.count)),
            number >= 1
        else { return nil }
        return number - 1
    }
}
