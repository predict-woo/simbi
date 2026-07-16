import Foundation
import Testing

@testable import SimbiKit

@Suite("VTT")
struct VTTTests {
    @Test("timestamp formatting rounds to milliseconds")
    func timestamps() {
        #expect(VTT.timestamp(0) == "00:00:00.000")
        #expect(VTT.timestamp(7.36) == "00:00:07.360")
        #expect(VTT.timestamp(3730.2504) == "01:02:10.250")
        #expect(VTT.timestamp(0.0005) == "00:00:00.001")
    }

    @Test("render/parse round-trip of a full transcript")
    func roundTrip() throws {
        let wall = try #require(VTT.wallClockFormatter.date(from: "2026-07-15T13:40:00+09:00"))
        let entries: [VTTEntry] = [
            .sessionStart(n: 1, wallClock: wall, offset: 0),
            .cue(
                index: 1, start: 0, end: 7.36, speaker: "Speaker 1",
                text: "So the main thing for today is the pipeline refactor.",
                continuation: false),
            .gap(start: 7.36, end: 12.48),
            .cue(
                index: 2, start: 12.48, end: 19.36, speaker: "Speaker 2",
                text: "Right, and I think we should land it before Thursday.",
                continuation: false),
            .cue(
                index: 3, start: 19.5, end: 24.0, speaker: "Speaker 2",
                text: "…and this cue continues mid-sentence.", continuation: true),
            // Whole-second wall clock: ISO8601 rendering has no sub-second
            // precision (offsets keep milliseconds; wall clocks don't).
            .sessionEnd(n: 1, wallClock: wall.addingTimeInterval(730), offset: 730.24),
        ]
        var file = VTT.header(noteName: "2026-07-15 Standup")
        for entry in entries {
            file += VTT.render(entry)
        }

        let document = try VTTParser.parse(file)
        #expect(document.noteName == "2026-07-15 Standup")
        #expect(document.entries == entries)
    }

    @Test("strict parser rejects malformed content")
    func strictness() {
        #expect(throws: VTTParseError.self) {
            try VTTParser.parse("not a vtt file")
        }
        #expect(throws: VTTParseError.self) {
            try VTTParser.parse("WEBVTT\n\n1\n00:00:00.000 --> garbage\n<v A>x\n")
        }
        #expect(throws: VTTParseError.self) {
            try VTTParser.parse("WEBVTT\n\n1\n00:00:05.000 --> 00:00:01.000\n<v A>backwards\n")
        }
        #expect(throws: VTTParseError.self) {
            try VTTParser.parse("WEBVTT\n\nNOTE gap start=xx end=yy\n")
        }
    }

    @Test("unknown NOTE blocks are legal and ignored")
    func unknownNotes() throws {
        let file =
            "WEBVTT\n\nNOTE fixer pass 3 reviewed cues 1..4\n\n1\n00:00:00.000 --> 00:00:01.000\n<v Speaker 1>hi\n"
        let document = try VTTParser.parse(file)
        #expect(document.entries.count == 1)
    }
}

@Suite("NoteRecordingState")
struct NoteRecordingStateTests {
    @Test("defaults, save and load round-trip")
    func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fresh = try NoteRecordingState.load(noteFolder: dir)
        #expect(fresh == NoteRecordingState())
        #expect(fresh.nextCueIndex == 1)

        var state = fresh
        state.nextCueIndex = 8
        state.sessionCount = 2
        state.totalSamples = 1_440_000
        state.activeSession = .init(n: 3, baseSamples: 1_440_000, wallStart: .now)
        try state.save(noteFolder: dir)

        let loaded = try NoteRecordingState.load(noteFolder: dir)
        #expect(loaded.nextCueIndex == 8)
        #expect(loaded.totalSamples == 1_440_000)
        #expect(loaded.activeSession?.n == 3)
    }
}
