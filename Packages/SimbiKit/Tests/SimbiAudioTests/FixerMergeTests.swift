import Foundation
import SimbiAudio
import SimbiKit
import Testing

@Suite("Fixer merge (snapshot-and-replay)")
struct FixerMergeTests {
    private func vtt(_ cues: [TranscriptOutbox.CueEdit]) -> String {
        var out = VTT.header(noteName: "test")
        for cue in cues {
            out += VTT.render(
                .cue(
                    index: cue.index, start: Double(cue.index), end: Double(cue.index) + 1,
                    speaker: cue.speaker, text: cue.text, continuation: false))
        }
        return out
    }

    @Test("only changed cue payloads survive the diff")
    func diffChangedOnly() {
        let before = vtt([
            .init(index: 1, speaker: "Speaker 1", text: "helo world"),
            .init(index: 2, speaker: "Speaker 2", text: "fine text"),
        ])
        let after = vtt([
            .init(index: 1, speaker: "Speaker 1", text: "hello world"),
            .init(index: 2, speaker: "Speaker 2", text: "fine text"),
        ])
        let edits = TranscriptOutbox.fixerEdits(before: before, after: after)
        #expect(edits == [.init(index: 1, speaker: "Speaker 1", text: "hello world")])
    }

    @Test("deletions, additions, and identical copies contribute nothing")
    func diffIgnoresStructuralChanges() {
        let before = vtt([
            .init(index: 1, speaker: "Speaker 1", text: "a"),
            .init(index: 2, speaker: "Speaker 2", text: "b"),
        ])
        // Fixer deleted cue 2 and invented cue 9 — both ignored.
        let after = vtt([
            .init(index: 1, speaker: "Speaker 1", text: "a"),
            .init(index: 9, speaker: "Speaker 9", text: "made up"),
        ])
        #expect(TranscriptOutbox.fixerEdits(before: before, after: after).isEmpty)
        #expect(TranscriptOutbox.fixerEdits(before: before, after: before).isEmpty)
    }

    @Test("speaker renames are edits too")
    func diffSpeakerRename() {
        let before = vtt([.init(index: 1, speaker: "Speaker 1", text: "hi")])
        let after = vtt([.init(index: 1, speaker: "Linus", text: "hi")])
        #expect(
            TranscriptOutbox.fixerEdits(before: before, after: after)
                == [.init(index: 1, speaker: "Linus", text: "hi")])
    }

    @Test("an unparseable copy yields no edits")
    func diffUnparseable() {
        let before = vtt([.init(index: 1, speaker: "Speaker 1", text: "hi")])
        #expect(TranscriptOutbox.fixerEdits(before: before, after: "garbage").isEmpty)
    }

    @Test("applyEdits rewrites only the edited payload, byte-preserving the rest")
    func applyEditsSurgical() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "fixer-merge-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: "transcript.vtt")

        // Include a session NOTE and an unknown NOTE — both must survive
        // byte-for-byte (the parser drops unknown NOTEs, so a parse→render
        // rewrite would lose them; the surgical rewrite must not).
        let original =
            vtt([
                .init(index: 1, speaker: "Speaker 1", text: "helo wrld"),
                .init(index: 2, speaker: "Speaker 2", text: "keep me"),
            ])
            + "\nNOTE custom marker\n"
            + VTT.render(.sessionEnd(n: 1, wallClock: .init(timeIntervalSince1970: 0), offset: 3))
        try original.write(to: fileURL, atomically: true, encoding: .utf8)

        let outbox = TranscriptOutbox(fileURL: fileURL, noteName: "test")
        try outbox.applyEdits([
            .init(index: 1, speaker: "Speaker 1", text: "hello world"),
            .init(index: 42, speaker: "X", text: "no such cue"),
        ])

        let updated = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(updated.contains("<v Speaker 1>hello world"))
        #expect(!updated.contains("helo wrld"))
        #expect(
            updated.replacingOccurrences(
                of: "<v Speaker 1>hello world", with: "<v Speaker 1>helo wrld") == original)
        _ = try VTTParser.parse(updated)
    }

    @Test("applyEdits sanitizes payloads that would break the VTT")
    func applyEditsSanitizes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "fixer-merge-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appending(path: "transcript.vtt")
        try vtt([.init(index: 1, speaker: "Speaker 1", text: "x")])
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let outbox = TranscriptOutbox(fileURL: fileURL, noteName: "test")
        try outbox.applyEdits([
            .init(index: 1, speaker: "Bad>Name", text: "line one\nline --> two")
        ])

        let document = try VTTParser.parse(try String(contentsOf: fileURL, encoding: .utf8))
        guard case .cue(_, _, _, let speaker, let text, _) = document.entries[0] else {
            Issue.record("expected a cue")
            return
        }
        #expect(speaker == "BadName")
        #expect(text == "line one line → two")
    }
}
