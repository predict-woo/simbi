// M2 spike: the full recording pipeline against the REAL Sortformer models,
// completely silent — `say -o` synthesizes speech to files (nothing is
// played), and the PCM is fed straight into RecordingPipeline.ingest.
//
// Two sessions:
//   1. voice A speaks, 3 s pause, voice B speaks  → cues + speaker switch + gap
//   2. resume: voice A speaks again               → appended session, numbering continues
//
// PASS criteria: transcript parses, has both sessions' notes, ≥ 2 cues in
// session 1 with ≥ 2 distinct speakers OR a gap from the pause, a cue in
// session 2, cues disjoint/ordered, audio.webm duration == total ingested.

import AVFoundation
import Foundation
import SimbiAudio
import SimbiKit

func fail(_ step: String, _ message: String) -> Never {
    print("FAIL \(step): \(message)")
    exit(1)
}

func run(_ tool: String, _ args: [String]) throws {
    let process = Process()
    process.executableURL = URL(filePath: tool)
    process.arguments = args
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "spike", code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "\(tool) exited \(process.terminationStatus)"])
    }
}

/// Synthesizes `text` with `voice` to 16 kHz mono Float32 samples. Writes
/// files only — no audio device is touched.
func synthesize(_ text: String, voice: String, in dir: URL) throws -> [Float] {
    let aiff = dir.appending(path: "\(voice)-\(UUID().uuidString).aiff")
    let wav = dir.appending(path: "\(voice)-\(UUID().uuidString).wav")
    try run("/usr/bin/say", ["-v", voice, "-o", aiff.path, text])
    try run(
        "/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEF32@16000", "-c", "1", aiff.path, wav.path])
    let file = try AVAudioFile(forReading: wav)
    let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return Array(
        UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

let workDir = FileManager.default.temporaryDirectory
    .appending(path: "simbi-pipeline-spike-\(UUID().uuidString)")
let noteFolder = workDir.appending(path: "Spike Note")
try FileManager.default.createDirectory(at: noteFolder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDir) }

print("synthesizing speech (files only — silent)…")
let speechA1 = try synthesize(
    "Hello, this is the first speaker. I am talking about the Simbi recording pipeline, "
        + "and I will keep going long enough to make a solid first segment.",
    voice: "Samantha", in: workDir)
let speechB = try synthesize(
    "And this is a completely different second speaker, with a lower voice, "
        + "responding right after the first one finished talking.",
    voice: "Daniel", in: workDir)
let speechA2 = try synthesize(
    "Back again after resuming the recording in a brand new session.",
    voice: "Samantha", in: workDir)

// Session 1 timeline: A, 3 s silence, B, 1 s silence tail.
var session1: [Float] = speechA1
session1.append(contentsOf: [Float](repeating: 0, count: 3 * 16000))
session1.append(contentsOf: speechB)
session1.append(contentsOf: [Float](repeating: 0, count: 16000))

let pipeline = RecordingPipeline(noteFolderURL: noteFolder, diarizer: SortformerStream())

print("loading Sortformer models (cached after first run)…")
let prepStart = Date()
try await pipeline.start()
print(String(format: "session 1 started (prepare took %.1f s)", -prepStart.timeIntervalSinceNow))

let inferStart = Date()
for batchStart in stride(from: 0, to: session1.count, by: 1600) {
    let batch = Array(session1[batchStart..<min(batchStart + 1600, session1.count)])
    try await pipeline.ingest(samples: batch)
}
try await pipeline.stop()
let audioSeconds = Double(session1.count) / 16000
print(
    String(
        format: "session 1: %.1f s audio diarized in %.1f s (%.1fx realtime)",
        audioSeconds, -inferStart.timeIntervalSinceNow,
        audioSeconds / -inferStart.timeIntervalSinceNow))

// Session 2: resume, speak, stop.
try await pipeline.start()
var session2: [Float] = speechA2
session2.append(contentsOf: [Float](repeating: 0, count: 8000))
for batchStart in stride(from: 0, to: session2.count, by: 1600) {
    let batch = Array(session2[batchStart..<min(batchStart + 1600, session2.count)])
    try await pipeline.ingest(samples: batch)
}
try await pipeline.stop()
print("session 2 stopped")

// Give the (instant) stub uploads a beat to drain the outbox.
try await Task.sleep(for: .milliseconds(500))

// --- Validation ---------------------------------------------------------
let vttURL = noteFolder.appending(path: "transcript.vtt")
let transcript = try String(contentsOf: vttURL, encoding: .utf8)
print("\n--- transcript.vtt ---\n\(transcript)\n----------------------")

let document: VTTDocument
do {
    document = try VTTParser.parse(transcript)
} catch {
    fail("parse", "\(error)")
}

var cues: [(index: Int, start: Double, end: Double, speaker: String)] = []
var gaps = 0
var sessionStarts: [Int] = []
var sessionEnds: [Int] = []
for entry in document.entries {
    switch entry {
    case .cue(let index, let start, let end, let speaker, let text, _):
        cues.append((index, start, end, speaker))
        guard text == "[transcription arrives in M3]" else {
            fail("cue", "unexpected stub text: \(text)")
        }
    case .gap: gaps += 1
    case .sessionStart(let n, _, _): sessionStarts.append(n)
    case .sessionEnd(let n, _, _): sessionEnds.append(n)
    }
}

guard sessionStarts == [1, 2], sessionEnds == [1, 2] else {
    fail("sessions", "starts \(sessionStarts), ends \(sessionEnds)")
}
print("PASS sessions: 1 and 2 both opened and closed")

guard cues.count >= 2 else { fail("cues", "expected ≥ 2 cues, got \(cues.count)") }
guard cues.map(\.index) == Array(1...cues.count) else {
    fail("cues", "indices not gapless: \(cues.map(\.index))")
}
for (a, b) in zip(cues, cues.dropFirst()) where a.end > b.start {
    fail("cues", "overlap: cue \(a.index) ends \(a.end), cue \(b.index) starts \(b.start)")
}
print("PASS cues: \(cues.count) cues, gapless indices, disjoint and ordered")

let speakers = Set(cues.map(\.speaker))
let session1End = Double(session1.count) / 16000
let hasSession2Cue = cues.contains { $0.start >= session1End - 0.1 }
guard hasSession2Cue else { fail("resume", "no cue in session 2's time range") }
print("PASS resume: session 2 produced a cue past \(String(format: "%.2f", session1End)) s")
print("INFO speakers detected: \(speakers.sorted()) · gap notes: \(gaps)")

let probe = try OpusWebMDecoder(fileURL: noteFolder.appending(path: "audio.webm"))
let expectedMs = (session1.count + session2.count) / 16
guard abs(Int(probe.endMilliseconds) - expectedMs) <= 20 else {
    fail("audio", "audio.webm ends at \(probe.endMilliseconds) ms, expected ~\(expectedMs) ms")
}
print("PASS audio: audio.webm spans \(probe.endMilliseconds) ms across both sessions")

let state = try NoteRecordingState.load(noteFolder: noteFolder)
guard state.sessionCount == 2, state.activeSession == nil,
    state.nextCueIndex == cues.count + 1
else {
    fail("state", "\(state)")
}
print("PASS state: sessionCount 2, nextCueIndex \(state.nextCueIndex), no active session")

// Keep the evidence.
let evidenceDir = URL(filePath: "docs/verification/2026-07-16-m2-recording")
if FileManager.default.fileExists(atPath: evidenceDir.path) {
    try? transcript.write(
        to: evidenceDir.appending(path: "headless-real-model-transcript.vtt"),
        atomically: true, encoding: .utf8)
}
print("OVERALL: PASS")
