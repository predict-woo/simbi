// M4 spike: real end-to-end transcript-fixer run. Builds a note folder with
// a transcript containing genuine ASR errors ("Symbi") and speaker
// self-introductions, drives TranscriptFixer against the real codex
// app-server, and verifies the fixes: spelling corrected from note.md
// context, <v> tags renamed consistently across sessions, cue count and
// timestamps untouched, file still valid WebVTT.

import CodexKit
import Foundation
import SimbiKit

func fail(_ step: String, _ message: String) -> Never {
    print("FAIL \(step): \(message)")
    exit(1)
}

let noteFolder = FileManager.default.temporaryDirectory
    .appending(path: "simbi-fixer-spike-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: noteFolder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: noteFolder) }

try """
# Standup notes
This note is about **Simbi** (spelled S-i-m-b-i), our macOS notetaking app.
Attendees: Alice Kim, Bob Park.
""".write(to: noteFolder.appending(path: "note.md"), atomically: true, encoding: .utf8)

let transcript = """
    WEBVTT

    NOTE simbi note="Fixer Spike"

    NOTE session 1 start=2026-07-16T18:00:00+09:00 offset=00:00:00.000

    1
    00:00:00.000 --> 00:00:06.000
    <v Speaker 1>Hi, I'm Alice Kim. Today I want to talk about the Symbi recording pipeline.

    2
    00:00:06.500 --> 00:00:12.000
    <v Speaker 2>This is Bob Park. The simby transcriber worked grate in my tests.

    NOTE session 1 end=2026-07-16T18:00:20+09:00 offset=00:00:12.500

    NOTE session 2 start=2026-07-16T18:05:00+09:00 offset=00:00:12.500

    3
    00:00:12.500 --> 00:00:18.000
    <v Speaker 1>Alice again after the break, sim bee still needs a logo.

    NOTE session 2 end=2026-07-16T18:06:00+09:00 offset=00:00:18.500
    """
try (transcript + "\n").write(
    to: noteFolder.appending(path: "transcript.vtt"), atomically: true, encoding: .utf8)

let originalDocument = try VTTParser.parse(transcript + "\n")

let client = AppServerClient()
let fixer = TranscriptFixer(noteFolderURL: noteFolder, client: client, savedThreadId: nil)

print("starting fixer thread (real app-server)…")
try await fixer.recordingStarted()
guard let threadId = await fixer.threadId else { fail("thread", "no thread id") }
print("fixer thread: \(threadId)")

await fixer.cueAppended(index: 1)
await fixer.cueAppended(index: 2)
await fixer.cueAppended(index: 3)
await fixer.recordingStopped()

// Wait for the fixer's passes: poll until "Simbi" is spelled correctly in
// cue text or timeout (instruction turn + coalesced fix turn).
print("waiting for fixer passes (up to 6 min)…")
var fixed: VTTDocument?
let vttURL = noteFolder.appending(path: "transcript.vtt")
for _ in 0..<120 {
    try await Task.sleep(for: .seconds(3))
    guard let text = try? String(contentsOf: vttURL, encoding: .utf8),
        let document = try? VTTParser.parse(text)
    else { continue }
    let cueTexts = document.entries.compactMap { entry -> String? in
        if case .cue(_, _, _, _, let text, _) = entry { return text }
        return nil
    }
    if cueTexts.allSatisfy({ !$0.localizedCaseInsensitiveContains("symbi") })
        && cueTexts.joined().contains("Simbi")
    {
        fixed = document
        break
    }
}
guard let fixed else {
    let text = (try? String(contentsOf: vttURL, encoding: .utf8)) ?? "<unreadable>"
    fail("fix", "transcript never corrected. Current content:\n\(text)")
}

print("\n--- fixed transcript ---")
print(try String(contentsOf: vttURL, encoding: .utf8))
print("------------------------")

// Validate invariants.
var cues: [(index: Int, start: Double, end: Double, speaker: String, text: String)] = []
for case .cue(let index, let start, let end, let speaker, let text, _) in fixed.entries {
    cues.append((index, start, end, speaker, text))
}
guard cues.count == 3 else { fail("invariants", "cue count changed: \(cues.count)") }
var originalCues: [(Int, Double, Double)] = []
for case .cue(let index, let start, let end, _, _, _) in originalDocument.entries {
    originalCues.append((index, start, end))
}
for (i, cue) in cues.enumerated() {
    guard cue.index == originalCues[i].0, cue.start == originalCues[i].1,
        cue.end == originalCues[i].2
    else {
        fail("invariants", "cue \(cue.index) identity/timestamps changed")
    }
}
print("PASS invariants: 3 cues, indices and timestamps untouched, valid WebVTT")

let allText = cues.map(\.text).joined(separator: " ")
guard !allText.localizedCaseInsensitiveContains("symbi"),
    !allText.localizedCaseInsensitiveContains("simby"),
    !allText.localizedCaseInsensitiveContains("sim bee"),
    allText.contains("Simbi")
else { fail("spelling", "product name not fixed everywhere: \(allText)") }
print("PASS spelling: Simbi corrected in all cues")

// Speaker unification: cue 1 and cue 3 are Alice across the session
// boundary; cue 2 is Bob.
guard cues[0].speaker == cues[2].speaker else {
    fail("speakers", "cross-session unification missed: \(cues.map(\.speaker))")
}
guard cues[0].speaker.localizedCaseInsensitiveContains("alice"),
    cues[1].speaker.localizedCaseInsensitiveContains("bob")
else {
    fail("speakers", "self-introductions not applied: \(cues.map(\.speaker))")
}
print("PASS speakers: \(cues[0].speaker) unified across sessions; \(cues[1].speaker) renamed")
print("OVERALL: PASS")
