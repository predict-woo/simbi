import Foundation
import Testing

@testable import SimbiKit

@Suite("SpeakerRename")
struct SpeakerRenameTests {
    private let transcript = """
        WEBVTT

        NOTE simbi note="Rename Test"

        NOTE session 1 start=2026-07-16T10:00:00+09:00 offset=00:00:00.000

        1
        00:00:00.000 --> 00:00:02.000
        <v Speaker 1>Hello there.

        2
        00:00:02.500 --> 00:00:04.000
        <v Speaker 2>Hi!

        NOTE session 1 end=2026-07-16T10:01:00+09:00 offset=00:00:04.500

        NOTE session 2 start=2026-07-16T10:05:00+09:00 offset=00:00:04.500

        3
        00:00:05.000 --> 00:00:07.000
        <v Speaker 1>Back again.

        """

    @Test("renames consistently across sessions, everything else untouched")
    func renamesEverywhere() throws {
        let renamed = try SpeakerRename.rename(
            transcript: transcript, from: "Speaker 1", to: "Alice Kim")
        #expect(!renamed.contains("<v Speaker 1>"))
        #expect(renamed.components(separatedBy: "<v Alice Kim>").count == 3)  // 2 occurrences
        #expect(renamed.contains("<v Speaker 2>Hi!"))
        // Only the tags changed.
        #expect(
            renamed.replacingOccurrences(of: "<v Alice Kim>", with: "<v Speaker 1>")
                == transcript)
        let document = try VTTParser.parse(renamed)
        var speakers: [String] = []
        for case .cue(_, _, _, let speaker, _, _) in document.entries {
            speakers.append(speaker)
        }
        #expect(speakers == ["Alice Kim", "Speaker 2", "Alice Kim"])
    }

    @Test("rejects names that would break the tag or the file")
    func rejectsInvalidNames() {
        #expect(throws: SpeakerRename.RenameError.invalidName) {
            _ = try SpeakerRename.rename(transcript: transcript, from: "Speaker 1", to: "  ")
        }
        #expect(throws: SpeakerRename.RenameError.invalidName) {
            _ = try SpeakerRename.rename(transcript: transcript, from: "Speaker 1", to: "a>b")
        }
        #expect(throws: SpeakerRename.RenameError.invalidName) {
            _ = try SpeakerRename.rename(transcript: transcript, from: "Speaker 1", to: "a\nb")
        }
    }

    @Test("unknown speaker is a byte-for-byte no-op")
    func unknownSpeakerNoop() throws {
        let renamed = try SpeakerRename.rename(
            transcript: transcript, from: "Speaker 9", to: "Nobody")
        #expect(renamed == transcript)
    }

    @Test("file rename writes atomically and stays valid")
    func fileRename() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try transcript.write(
            to: dir.appending(path: "transcript.vtt"), atomically: true, encoding: .utf8)
        try SpeakerRename.renameInFile(noteFolder: dir, from: "Speaker 2", to: "Bob Park")
        let text = try String(
            contentsOf: dir.appending(path: "transcript.vtt"), encoding: .utf8)
        #expect(text.contains("<v Bob Park>Hi!"))
        _ = try VTTParser.parse(text)
    }
}
