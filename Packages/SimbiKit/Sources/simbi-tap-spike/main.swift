// M6 spike: SILENT end-to-end system-audio tap. Plays a wav whose first 4 s
// are pure silence via afplay, and during that lead-in creates a
// process-specific CoreAudio tap with `.mutedWhenTapped` — so the 440 Hz
// tone in the second half is captured through the real tap → aggregate →
// converter path but NEVER reaches the speakers. If the tap isn't running
// before the lead-in ends, afplay is killed (fail-safe: no audible leak).
//
// Requires the system-audio-recording TCC permission (macOS prompts on
// first run, attributed to the hosting terminal).

import AVFoundation
import Foundation
import SimbiAudio

func fail(_ step: String, _ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL \(step): \(message)\n".utf8))
    print("FAIL \(step): \(message)")
    exit(1)
}

if #available(macOS 14.4, *) {
    try await run()
} else {
    fail("os", "needs macOS 14.4+")
}

// (top-level `guard #available` doesn't propagate availability, so the
// spike body lives in an @available function)
@available(macOS 14.4, *)
func run() async throws {

    // 1. Generate the wav: 4 s silence, then 4 s of 440 Hz at 0.5 amplitude.
    let sampleRate = 48000
    let leadInSeconds = 4.0
    let toneSeconds = 4.0
    let toneHz = 440.0
    var samples = [Float](repeating: 0, count: Int(leadInSeconds * Double(sampleRate)))
    for n in 0..<Int(toneSeconds * Double(sampleRate)) {
        samples.append(0.5 * sinf(Float(2.0 * .pi * toneHz * Double(n) / Double(sampleRate))))
    }
    let wavURL = FileManager.default.temporaryDirectory
        .appending(path: "simbi-tap-spike-\(UUID().uuidString).wav")
    do {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
                channels: 1, interleaved: false),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { fail("wav", "could not allocate buffer") }
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let file = try AVAudioFile(
            forWriting: wavURL, settings: format.settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
    defer { try? FileManager.default.removeItem(at: wavURL) }

    // 2. Start afplay (silence begins) and immediately race to get the tap up.
    let player = Process()
    player.executableURL = URL(filePath: "/usr/bin/afplay")
    player.arguments = [wavURL.path]
    try player.run()
    let playbackStart = Date()
    defer { if player.isRunning { player.terminate() } }
    print("afplay pid \(player.processIdentifier) — lead-in \(leadInSeconds)s of silence")

    // 3. Tap ONLY the afplay process, muted-while-tapped. The HAL registers the
    // process once it starts IO, so retry translation briefly.
    let capture = SystemAudioCapture(
        options: .init(pids: [player.processIdentifier], muteWhileTapped: true))
    var stream: AsyncStream<[Float]>?
    while Date().timeIntervalSince(playbackStart) < leadInSeconds - 1.5 {
        do {
            stream = try capture.start()
            break
        } catch {
            try await Task.sleep(for: .milliseconds(150))
        }
    }
    guard let stream else {
        player.terminate()  // fail-safe BEFORE the tone starts
        fail("tap", "tap not running before the silent lead-in ended (TCC denied?)")
    }
    let tapReadyAt = Date().timeIntervalSince(playbackStart)
    print(String(format: "tap running %.2fs into the lead-in — tone will be muted", tapReadyAt))

    // 4. Capture until afplay exits; the stream is 16 kHz mono.
    let captureTask = Task { () -> [Float] in
        var samples: [Float] = []
        for await batch in stream {
            samples.append(contentsOf: batch)
        }
        return samples
    }
    player.waitUntilExit()
    try await Task.sleep(for: .seconds(1))  // drain the tail through the converter
    capture.stop()
    let captured = await captureTask.value

    let seconds = Double(captured.count) / 16000
    print(String(format: "captured %.2fs (%d samples at 16 kHz)", seconds, captured.count))
    guard seconds > 5 else { fail("capture", "too little audio captured") }

    // 5. Verify: lead-in ~silent, tone region has energy at ~440 Hz.
    func rms(_ region: ArraySlice<Float>) -> Float {
        guard !region.isEmpty else { return 0 }
        return sqrtf(region.reduce(0) { $0 + $1 * $1 } / Float(region.count))
    }
    // The capture starts mid-lead-in; use note-timeline: afplay t=0 → capture
    // started at tapReadyAt. Tone spans [4.0, 8.0] in playback time.
    let toneStart = Int((leadInSeconds - tapReadyAt + 0.5) * 16000)
    let toneEnd = Int((leadInSeconds - tapReadyAt + toneSeconds - 0.5) * 16000)
    guard toneEnd <= captured.count else { fail("capture", "tone region not fully captured") }
    let leadRegion = captured[0..<max(1, toneStart - 16000)]
    let toneRegion = captured[toneStart..<toneEnd]
    let leadRMS = rms(leadRegion)
    let toneRMS = rms(toneRegion)
    print(String(format: "lead-in RMS %.5f, tone RMS %.4f", leadRMS, toneRMS))
    guard leadRMS < 0.01 else { fail("verify", "lead-in should be silent") }
    guard toneRMS > 0.05 else { fail("verify", "tone energy missing — tap captured nothing") }

    // Zero-crossing frequency estimate over the tone region.
    var crossings = 0
    var previous = toneRegion.first ?? 0
    for sample in toneRegion.dropFirst() {
        if (previous < 0 && sample >= 0) || (previous >= 0 && sample < 0) { crossings += 1 }
        previous = sample
    }
    let estimatedHz = Double(crossings) / 2.0 / (Double(toneRegion.count) / 16000)
    print(String(format: "estimated tone frequency: %.1f Hz", estimatedHz))
    guard abs(estimatedHz - toneHz) < 20 else {
        fail("verify", "expected ~440 Hz, got \(estimatedHz)")
    }
    print("PASS tap: 440 Hz tone captured through tap → aggregate → 16 kHz mono, zero audible output")
    print("OVERALL: PASS")
}
