import Foundation

/// Speaker rename (SPEC.md §6): rewrites `<v Name>` tags consistently
/// across the whole transcript — the same rename the fixer thread performs,
/// but user-driven. Only the tags change; everything else is preserved
/// byte-for-byte, and the result is re-parsed before it replaces the file.
public enum SpeakerRename {
    public enum RenameError: Error, Equatable {
        case invalidName
        case wouldInvalidate
    }

    /// Replaces `<v from>` with `<v to>` everywhere in `transcript`.
    public static func rename(transcript: String, from: String, to: String) throws -> String {
        let trimmed = to.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(">"), !trimmed.contains("\n") else {
            throw RenameError.invalidName
        }
        let renamed = transcript.replacingOccurrences(of: "<v \(from)>", with: "<v \(trimmed)>")
        guard (try? VTTParser.parse(renamed)) != nil else {
            throw RenameError.wouldInvalidate
        }
        return renamed
    }

    /// Renames in the note's `transcript.vtt`, written atomically so the
    /// live renderer never sees a half-written file.
    public static func renameInFile(noteFolder: URL, from: String, to: String) throws {
        let url = VTT.fileURL(noteFolder: noteFolder)
        let transcript = try String(contentsOf: url, encoding: .utf8)
        let renamed = try rename(transcript: transcript, from: from, to: to)
        try renamed.write(to: url, atomically: true, encoding: .utf8)
    }
}
