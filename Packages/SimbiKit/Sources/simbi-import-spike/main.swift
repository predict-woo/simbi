// Media-import spike. `--length-check [minutes...]` probes whether the
// transcribe endpoint accepts long clips: synthesized speech (`say -o`,
// files only — nothing is ever played) is tiled to each requested length,
// encoded to WebM/Opus, and uploaded through the REAL endpoint. The
// default mode (full headless import pipeline) arrives in Task 9.
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
print("default end-to-end mode arrives in a later task; use --length-check")
exit(1)
