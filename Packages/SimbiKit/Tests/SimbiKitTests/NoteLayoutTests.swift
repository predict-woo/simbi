import Foundation
import Testing

@testable import SimbiKit

@Suite("NoteLayout")
struct NoteLayoutTests {
    private let note = URL(filePath: "/tmp/Simbi/Standup")

    @Test("owns every note-folder path the modules used to hardcode")
    func paths() {
        #expect(NoteLayout.audioURL(noteFolder: note).path == "/tmp/Simbi/Standup/audio.webm")
        #expect(NoteLayout.summaryURL(noteFolder: note).path == "/tmp/Simbi/Standup/summary.md")
        #expect(NoteLayout.stateDirURL(noteFolder: note).path == "/tmp/Simbi/Standup/.simbi")
        #expect(
            NoteLayout.pendingDirURL(noteFolder: note).path == "/tmp/Simbi/Standup/.simbi/pending")
        #expect(
            NoteLayout.failedDirURL(noteFolder: note).path == "/tmp/Simbi/Standup/.simbi/failed")
        #expect(
            NoteLayout.fixerWorktreeURL(noteFolder: note).path
                == "/tmp/Simbi/Standup/.simbi/fixer-worktree")
        #expect(NoteLayout.filesDirURL(noteFolder: note).path == "/tmp/Simbi/Standup/files")
        #expect(
            NoteLayout.contextURL(noteFolder: note, fileName: "deck.pdf").path
                == "/tmp/Simbi/Standup/context/deck.pdf.md")
    }

    @Test("transcript path stays owned by VTT and matches the layout")
    func transcriptStaysWithVTT() {
        #expect(VTT.fileURL(noteFolder: note).path == "/tmp/Simbi/Standup/transcript.vtt")
    }
}

@Suite("SpeakerLabel")
struct SpeakerLabelTests {
    @Test("slot 0 renders as Speaker 1")
    func rendersOneBased() {
        #expect(SpeakerLabel.name(slot: 0) == "Speaker 1")
        #expect(SpeakerLabel.name(slot: 3) == "Speaker 4")
    }

    @Test("parses its own output back to the slot")
    func roundTrips() {
        for slot in 0..<8 {
            #expect(SpeakerLabel.slot(name: SpeakerLabel.name(slot: slot)) == slot)
        }
    }

    @Test("renamed speakers do not parse as slots")
    func rejectsCustomNames() {
        #expect(SpeakerLabel.slot(name: "Alice") == nil)
        #expect(SpeakerLabel.slot(name: "Speaker ") == nil)
        #expect(SpeakerLabel.slot(name: "Speaker zero") == nil)
        #expect(SpeakerLabel.slot(name: "Speaker 0") == nil)
        #expect(SpeakerLabel.slot(name: "Speaker -2") == nil)
    }
}

@Suite("VTT voice payload")
struct VTTVoicePayloadTests {
    @Test("voicePayload renders the wire format the parser accepts")
    func voicePayloadRoundTrips() throws {
        let file =
            VTT.header(noteName: "n") + "\n1\n00:00:00.000 --> 00:00:01.000\n"
            + VTT.voicePayload(speaker: "Speaker 2", text: "hello") + "\n"
        let document = try VTTParser.parse(file)
        #expect(
            document.entries == [
                .cue(
                    index: 1, start: 0, end: 1, speaker: "Speaker 2", text: "hello",
                    continuation: false)
            ])
    }

    @Test("voiceTag is the payload prefix rename matching relies on")
    func voiceTagPrefix() {
        #expect(
            VTT.voicePayload(speaker: "Alice", text: "hi")
                == VTT.voiceTag(speaker: "Alice") + "hi")
    }
}
