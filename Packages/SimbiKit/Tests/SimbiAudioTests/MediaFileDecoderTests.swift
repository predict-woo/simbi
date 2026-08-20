import AVFoundation
import Foundation
import Testing

@testable import SimbiAudio

/// Decoder tests synthesize fixtures at test time (say/afconvert, file-only,
/// silent — never played) and decode them back.
@Suite("MediaFileDecoder")
struct MediaFileDecoderTests {
    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(filePath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        try #require(p.terminationStatus == 0)
    }

    /// say → aiff, then afconvert into the requested container.
    private func fixture(format: [String], ext: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "decoder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let aiff = dir.appending(path: "src.aiff")
        let out = dir.appending(path: "src.\(ext)")
        try run("/usr/bin/say", ["-o", aiff.path, "Testing one two three four five"])
        try run("/usr/bin/afconvert", format + [aiff.path, out.path])
        return out
    }

    private func decodeAll(_ url: URL) async throws -> [Float] {
        var samples: [Float] = []
        for try await batch in MediaFileDecoder().decode(url: url) {
            samples.append(contentsOf: batch)
        }
        return samples
    }

    @Test("decodes a wav to 16 kHz mono at the right length")
    func decodesWav() async throws {
        let url = try fixture(format: ["-f", "WAVE", "-d", "LEI16@44100", "-c", "2"], ext: "wav")
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(try await asset.load(.duration))
        let samples = try await decodeAll(url)
        let expected = Int(seconds * 16000)
        #expect(abs(samples.count - expected) < 16000 / 5)  // within 200 ms
        #expect(samples.contains { abs($0) > 0.01 })  // real signal, not zeros
    }

    @Test("decodes an m4a (mp4 container) — the video-container code path")
    func decodesM4a() async throws {
        let url = try fixture(format: ["-f", "m4af", "-d", "aac"], ext: "m4a")
        let samples = try await decodeAll(url)
        #expect(samples.count > 16000)  // the sentence is well over a second
        #expect(samples.contains { abs($0) > 0.01 })
    }

    @Test("a non-media file throws")
    func unreadableThrows() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "decoder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "not-audio.mp4")
        try Data("plain text".utf8).write(to: url)
        await #expect(throws: (any Error).self) {
            _ = try await decodeAll(url)
        }
    }

    @Test("file-kind routing")
    func kinds() {
        #expect(MediaFileDecoder.kind(of: "talk.mp4") == .supported)
        #expect(MediaFileDecoder.kind(of: "voice.m4a") == .supported)
        #expect(MediaFileDecoder.kind(of: "song.wav") == .supported)
        #expect(MediaFileDecoder.kind(of: "clip.mov") == .supported)
        #expect(MediaFileDecoder.kind(of: "audio.mp3") == .supported)
        #expect(MediaFileDecoder.kind(of: "video.webm") == .unsupported)
        #expect(MediaFileDecoder.kind(of: "video.mkv") == .unsupported)
        #expect(MediaFileDecoder.kind(of: "audio.ogg") == .unsupported)
        #expect(MediaFileDecoder.kind(of: "notes.pdf") == .document)
        #expect(MediaFileDecoder.kind(of: "README") == .document)
    }
}
