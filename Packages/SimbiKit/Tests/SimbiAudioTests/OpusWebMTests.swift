import Foundation
import Testing

@testable import SimbiAudio

@Suite("OpusWebM")
struct OpusWebMTests {
    private func makeTempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "opuswebm-\(UUID().uuidString).webm")
    }

    /// 440 Hz sine at 16 kHz, amplitude 0.5.
    private func tone(seconds: Double) -> [Float] {
        let count = Int(seconds * Double(OpusWebMFormat.sampleRate))
        return (0..<count).map { i in
            0.5 * sin(2 * .pi * 440 * Float(i) / Float(OpusWebMFormat.sampleRate))
        }
    }

    @Test("create, append session, and decode round-trip")
    func roundTrip() throws {
        let url = makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        // Session 1: 3 s.
        let encoder1 = try OpusWebMEncoder(fileURL: url, mode: .create)
        try encoder1.append(samples: tone(seconds: 3))
        let end1 = try encoder1.finish()
        #expect(end1 == 3000)

        // Resume offset comes from the cluster scan, like a real resume.
        let probe = try OpusWebMDecoder(fileURL: url)
        #expect(probe.endMilliseconds == 3000)

        // Session 2: 2 s appended to the same file.
        let encoder2 = try OpusWebMEncoder(
            fileURL: url, mode: .append(baseMilliseconds: probe.endMilliseconds))
        try encoder2.append(samples: tone(seconds: 2))
        let end2 = try encoder2.finish()
        #expect(end2 == 5000)

        // Decode everything back.
        let decoder = try OpusWebMDecoder(fileURL: url)
        #expect(decoder.lastPacketTime != nil)
        #expect(abs((decoder.lastPacketTime ?? 0) - 4.98) < 0.001)

        let (samples, startTime) = try decoder.decode()
        #expect(startTime == 0)
        // 5 s at 16 kHz; opus pre-skip may shift a frame's worth of samples.
        #expect(abs(samples.count - 5 * 16000) <= OpusWebMFormat.frameSamples)

        // The decoded tail must be actual signal, not silence: RMS of a
        // 0.5-amplitude sine is ~0.35.
        let tail = samples.suffix(16000)
        let rms = sqrt(tail.map { $0 * $0 }.reduce(0, +) / Float(tail.count))
        #expect(rms > 0.2)
    }

    @Test("cluster index spans sessions and supports seeking")
    func clusterIndexAndSeek() throws {
        let url = makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        // 12 s in one session: clusters at 0, 5, 10 s.
        let encoder = try OpusWebMEncoder(fileURL: url, mode: .create)
        try encoder.append(samples: tone(seconds: 12))
        try encoder.finish()

        let decoder = try OpusWebMDecoder(fileURL: url)
        #expect(decoder.clusterIndex.count == 3)
        #expect(decoder.clusterIndex.map(\.time) == [0, 5, 10])
        #expect(decoder.clusterIndex[1].byteOffset > decoder.clusterIndex[0].byteOffset)

        // Seek to 7 s: decoding starts at that cluster (5 s), not at 0.
        let (samples, startTime) = try decoder.decode(from: 7)
        #expect(startTime == 5.0)
        #expect(abs(samples.count - 7 * 16000) <= OpusWebMFormat.frameSamples)
    }

    @Test("file is parseable mid-recording after a flush (crash tolerance)")
    func validWithoutFinish() throws {
        let url = makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = try OpusWebMEncoder(fileURL: url, mode: .create)
        try encoder.append(samples: tone(seconds: 2))
        try encoder.flush()

        // Parse while the encoder still has the file open and was never
        // finished — simulating a crash after the last flush.
        let decoder = try OpusWebMDecoder(fileURL: url)
        #expect(decoder.clusterIndex.count == 1)
        let (samples, _) = try decoder.decode()
        #expect(samples.count > 16000)

        try encoder.finish()
    }

    @Test("OpusHead layout")
    func opusHeadBytes() {
        let head = opusHead(preSkip48k: 312, inputSampleRate: 16000, channels: 1)
        #expect(head.count == 19)
        #expect(Array(head.prefix(8)) == Array("OpusHead".utf8))
        #expect(head[8] == 1)  // version
        #expect(head[9] == 1)  // channels
        #expect(UInt16(head[10]) | (UInt16(head[11]) << 8) == 312)
        let rate =
            UInt32(head[12]) | (UInt32(head[13]) << 8)
            | (UInt32(head[14]) << 16) | (UInt32(head[15]) << 24)
        #expect(rate == 16000)
        #expect(head[18] == 0)  // mapping family
    }
}
