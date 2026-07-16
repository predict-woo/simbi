import AVFoundation
import Foundation
import Testing

@testable import SimbiAudio

@Suite("AudioPlayback")
struct AudioPlaybackTests {
    /// 3 s of 440 Hz encoded to a live-mode WebM, like a real note's file.
    private func makeToneFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "playback-\(UUID().uuidString).webm")
        let encoder = try OpusWebMEncoder(fileURL: url, mode: .create)
        let rate = Float(OpusWebMFormat.sampleRate)
        let samples = (0..<Int(rate * 3)).map { n in
            0.4 * sinf(2 * .pi * 440 * Float(n) / rate)
        }
        try encoder.append(samples: samples)
        try encoder.finish()
        return url
    }

    @Test("chunked packet iterator equals the one-shot decode")
    func iteratorMatchesDecode() throws {
        let url = try makeToneFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = try OpusWebMDecoder(fileURL: url)
        let full = try decoder.decode(from: 0)

        let iterator = try decoder.packets(from: 0)
        var chunked: [Float] = []
        var first: TimeInterval?
        while let chunk = try iterator.next(maxSamples: 1000) {
            if first == nil { first = chunk.startTime }
            chunked.append(contentsOf: chunk.samples)
        }
        #expect(chunked == full.samples)
        #expect(first == full.startTime)
    }

    @Test("manual-rendering playback delivers the tone from a mid-file seek")
    func offlineRenderedPlayback() async throws {
        let url = try makeToneFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let playback = try AudioPlayback(fileURL: url, manualRenderingForTest: true)
        #expect(abs(playback.duration - 3.0) < 0.1)
        try playback.play(from: 1.0)

        // The feeder thread schedules asynchronously; pull until the tone
        // arrives (deadline-bounded), then check its energy. Nothing is
        // audible — the engine renders offline.
        var toneSeen = false
        for _ in 0..<200 {
            guard let buffer = try playback.renderForTest(frames: 1600),
                buffer.frameLength > 0, let channel = buffer.floatChannelData?[0]
            else {
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
            let rms = sqrtf(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
            if rms > 0.2 {
                toneSeen = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(toneSeen, "rendered audio never carried the tone")
        playback.stop()
        #expect(!playback.isPlaying)
    }
}
