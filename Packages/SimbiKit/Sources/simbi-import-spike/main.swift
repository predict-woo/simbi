// Media-import spike, two modes, both completely silent (`say -o` writes
// files; nothing is ever played).
//
// Default: the full headless import pipeline against the REAL offline
// models — synthesize a ~90 s two-voice dialogue, `afconvert` it to
// a temp meeting.m4a, run `ImportPipeline.run(fileURL:)` with the real
// `MediaFileDecoder` + `OfflineSpeechAnalyzer` and a stub transcriber
// (`--real` swaps in `CodexTranscriber`), then validate the transcript,
// audio.webm, state.json, and pending queue. `--note <path>` writes into
// a kept folder instead of temp.
//
// `--length-check [minutes...]` probes whether the transcribe endpoint
// accepts long clips: synthesized speech is tiled to each requested
// length, encoded to WebM/Opus, and uploaded through the REAL endpoint.
//
// Env knobs (both used to expose the >6-minute silent-truncation finding):
//   SIMBI_SPIKE_UNIQUE=1     numbered "Checkpoint N" speech instead of a
//                            repeated tile, so the transcript's last
//                            checkpoint shows how far coverage really got.
//   SIMBI_SPIKE_DUMP=<dir>   write each full transcript to <dir>/clip-N.txt.

import AVFoundation
import Foundation
import SimbiAudio
import SimbiKit

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
    .appending(path: "simbi-import-spike-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDir) }

// --length-check [minutes...]: encode tiled speech at each length to
// webm/opus and upload through the REAL transcribe endpoint. Reports
// duration + result per clip. Needs ChatGPT.app auth (~/.codex/auth.json).
if CommandLine.arguments.contains("--length-check") {
    let minutes = CommandLine.arguments.compactMap { Int($0) }
    let lengths = minutes.isEmpty ? [1, 2, 5, 10] : minutes
    print("synthesizing speech (files only — silent)…")
    let voiceA = try synthesize(
        "First speaker here, talking at length about the Simbi media import pipeline. "
            + "Imported recordings are cut into blocks, encoded to Opus inside WebM, and "
            + "uploaded to the transcribe endpoint one block at a time, so the block size "
            + "we can get away with decides how many round trips a long meeting costs.",
        voice: "Samantha", in: workDir)
    let voiceB = try synthesize(
        "And this is the second speaker replying with a comparable paragraph. If the "
            + "endpoint accepts a full ten minute clip in one request, imports stay simple "
            + "and fast; if it silently truncates or rejects long uploads, we fall back to "
            + "smaller blocks and stitch the transcripts together afterwards.",
        voice: "Daniel", in: workDir)
    let unit =
        voiceA + [Float](repeating: 0, count: 8000) + voiceB
        + [Float](repeating: 0, count: 8000)
    let transcriber = CodexTranscriber()
    for mins in lengths {
        let target = mins * 60 * 16000
        var audio: [Float] = []
        if ProcessInfo.processInfo.environment["SIMBI_SPIKE_UNIQUE"] != nil {
            var counter = 0
            while audio.count < target {
                let batch = (0..<10).map { _ -> String in
                    counter += 1
                    return "Checkpoint \(counter)."
                }.joined(separator: " ")
                audio.append(
                    contentsOf: try synthesize(batch, voice: "Samantha", in: workDir))
            }
            let fullCount = audio.count
            audio = Array(audio.prefix(target))
            print(
                "unique mode: \(counter) checkpoints over \(fullCount) samples, "
                    + "trimmed to \(target); ~last audible checkpoint ≈ "
                    + "\(counter * target / fullCount)")
        } else {
            while audio.count < target {
                audio.append(contentsOf: unit.prefix(target - audio.count))
            }
        }
        let webmURL = workDir.appending(path: "clip-\(mins)min.webm")
        let encoder = try OpusWebMEncoder(fileURL: webmURL, mode: .create)
        try encoder.append(samples: audio)
        try encoder.finish()
        let attributes = try? FileManager.default.attributesOfItem(atPath: webmURL.path)
        let bytes = (attributes?[.size] as? Int) ?? 0
        let start = Date()
        do {
            let text = try await transcriber.transcribe(webmFile: webmURL)
            if let dumpDir = ProcessInfo.processInfo.environment["SIMBI_SPIKE_DUMP"] {
                try? text.write(
                    to: URL(filePath: dumpDir).appending(path: "clip-\(mins)min.txt"),
                    atomically: true, encoding: .utf8)
            }
            print(
                String(
                    format: "PASS %2d min (%5.1f MB): %.1f s, %d chars, tail: …%@",
                    mins, Double(bytes) / 1_048_576, -start.timeIntervalSinceNow,
                    text.count, String(text.suffix(60))))
        } catch {
            print(
                String(
                    format: "FAIL %2d min after %.1f s: %@",
                    mins, -start.timeIntervalSinceNow, "\(error)"))
        }
    }
    exit(0)
}
// --- Default mode: full headless import through ImportPipeline ----------

func fail(_ step: String, _ message: String) -> Never {
    print("FAIL \(step): \(message)")
    exit(1)
}

/// Writes 16 kHz mono Float32 samples to a WAV file.
func writeWAV(_ samples: [Float], to url: URL) throws {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let file = try AVAudioFile(
        forWriting: url,
        settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
        ])
    let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer {
        buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
    }
    try file.write(from: buffer)
}

// --note <path>: import into a real note folder (kept) instead of temp.
let noteFolder: URL
if let flagIndex = CommandLine.arguments.firstIndex(of: "--note"),
    CommandLine.arguments.count > flagIndex + 1
{
    noteFolder = URL(filePath: CommandLine.arguments[flagIndex + 1])
} else {
    noteFolder = workDir.appending(path: "Import Spike Note")
}
try FileManager.default.createDirectory(
    at: noteFolder.appending(path: "files"), withIntermediateDirectories: true)
let noteMarker = noteFolder.appending(path: "note.md")
if !FileManager.default.fileExists(atPath: noteMarker.path) {
    try "# Media import demo\n".write(to: noteMarker, atomically: true, encoding: .utf8)
}

// ~90 s two-voice dialogue: A paragraph, 3 s pause, B paragraph, 3 s
// pause, repeated in whole units until 90 s is reached.
print("synthesizing dialogue (files only — silent)…")
let paragraphA = try synthesize(
    "Hello, this is the first speaker opening the imported meeting. I am going to talk "
        + "for a good while about the Simbi media import pipeline, which decodes a file "
        + "from the files folder, appends it to the note's audio as a brand new session, "
        + "runs voice activity detection and diarization offline, and then uploads each "
        + "speaker block for transcription exactly like a live recording would.",
    voice: "Samantha", in: workDir)
let paragraphB = try synthesize(
    "And this is the second speaker replying in a noticeably different voice. The "
        + "interesting part of the offline path is that the whole file is analyzed in one "
        + "batch, so the diarizer sees the complete conversation at once and can assign "
        + "globally consistent speaker slots before a single upload happens.",
    voice: "Daniel", in: workDir)
let pause = [Float](repeating: 0, count: 3 * 16000)
let unit = paragraphA + pause + paragraphB + pause
// Whole units only (never cut mid-speech); two ~45 s units ≈ 90 s.
var dialogue: [Float] = []
while dialogue.count < 85 * 16000 { dialogue.append(contentsOf: unit) }

let wavURL = workDir.appending(path: "meeting.wav")
let m4aURL = workDir.appending(path: "meeting.m4a")
try writeWAV(dialogue, to: wavURL)
try? FileManager.default.removeItem(at: m4aURL)
try run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", wavURL.path, m4aURL.path])
let m4aFile = try AVAudioFile(forReading: m4aURL)
let m4aSeconds = Double(m4aFile.length) / m4aFile.processingFormat.sampleRate
print(String(format: "meeting.m4a: %.1f s", m4aSeconds))

// --real: upload blocks through the real transcribe endpoint. Default is
// a stub — the end-to-end path under test is decode → analyze → blocks →
// outbox, and Task 1 already proved the real endpoint.
let useRealTranscriber = CommandLine.arguments.contains("--real")
struct SilentTranscriber: Transcriber {
    func transcribe(webmFile: URL) async throws -> String { "[spike]" }
}
let transcriber: any Transcriber =
    useRealTranscriber ? CodexTranscriber() : SilentTranscriber()
print("transcriber: \(useRealTranscriber ? "REAL backend-api/transcribe" : "stub")")

// Warm the models outside the timed run (cached after first download) so
// the realtime multiple measures the import itself.
let analyzer = OfflineSpeechAnalyzer()
print("loading offline models (downloads on first run, then cached)…")
let prepStart = Date()
try await analyzer.prepare()
print(String(format: "models ready (prepare took %.1f s)", -prepStart.timeIntervalSinceNow))

let pipeline = ImportPipeline(
    noteFolderURL: noteFolder, transcriber: transcriber,
    decoder: MediaFileDecoder(), analyzer: analyzer)
let importStart = Date()
do {
    try await pipeline.run(fileURL: m4aURL)
} catch {
    fail("run", "\(error)")
}
let importSeconds = -importStart.timeIntervalSinceNow
print(
    String(
        format: "import: %.1f s of audio in %.1f s (%.1fx realtime)",
        m4aSeconds, importSeconds, m4aSeconds / importSeconds))

// --- Validation ---------------------------------------------------------
let vttURL = VTT.fileURL(noteFolder: noteFolder)
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
        if useRealTranscriber {
            guard text != "[inaudible]" else {
                fail("cue", "cue \(index) has no real transcription: \(text)")
            }
            print("cue \(index) [\(speaker)]: \(text)")
        } else {
            guard text == "[spike]" else { fail("cue", "unexpected stub text: \(text)") }
        }
    case .gap: gaps += 1
    case .sessionStart(let n, _, _): sessionStarts.append(n)
    case .sessionEnd(let n, _, _): sessionEnds.append(n)
    }
}

guard sessionStarts == [1], sessionEnds == [1] else {
    fail("sessions", "starts \(sessionStarts), ends \(sessionEnds)")
}
print("PASS sessions: exactly one session, opened and closed")

guard cues.count >= 2 else { fail("cues", "expected ≥ 2 cues, got \(cues.count)") }
guard cues.map(\.index) == Array(1...cues.count) else {
    fail("cues", "indices not gapless: \(cues.map(\.index))")
}
for (a, b) in zip(cues, cues.dropFirst()) where a.end > b.start {
    fail("cues", "overlap: cue \(a.index) ends \(a.end), cue \(b.index) starts \(b.start)")
}
print("PASS cues: \(cues.count) cues, gapless indices, disjoint and ordered")

// Diarization on synthesized voices can merge speakers or split on the
// pauses; either ≥ 2 distinct labels or ≥ 1 gap proves real model output
// flowed through the block builder.
let speakers = Set(cues.map(\.speaker))
guard speakers.count >= 2 || gaps >= 1 else {
    fail("diarization", "1 speaker and 0 gaps: \(speakers.sorted())")
}
print("PASS diarization: \(speakers.count) speaker(s) \(speakers.sorted()), \(gaps) gap(s)")

let probe = try OpusWebMDecoder(fileURL: noteFolder.appending(path: "audio.webm"))
let deltaMs = abs(Double(probe.endMilliseconds) - m4aSeconds * 1000)
guard deltaMs <= Double(OpusWebMFormat.clusterMilliseconds) + 20 else {
    fail(
        "audio",
        "audio.webm ends at \(probe.endMilliseconds) ms, m4a is \(Int(m4aSeconds * 1000)) ms")
}
print("PASS audio: audio.webm spans \(probe.endMilliseconds) ms (Δ \(Int(deltaMs)) ms)")

let state = try NoteRecordingState.load(noteFolder: noteFolder)
guard state.activeImport == nil else { fail("state", "activeImport still set: \(state)") }
guard state.imports["meeting.m4a"]?.status == .done else {
    fail("state", "imports[meeting.m4a] = \(String(describing: state.imports["meeting.m4a"]))")
}
guard state.sessionCount == 1 else { fail("state", "sessionCount \(state.sessionCount)") }
print("PASS state: import done, marker cleared, sessionCount 1")

let pendingDir = NoteLayout.pendingDirURL(noteFolder: noteFolder)
let leftovers =
    ((try? FileManager.default.contentsOfDirectory(at: pendingDir, includingPropertiesForKeys: nil))
        ?? [])
guard leftovers.isEmpty else {
    fail("pending", "leftover files: \(leftovers.map(\.lastPathComponent))")
}
print("PASS pending: .simbi/pending/ is empty")

print("OVERALL: PASS")
