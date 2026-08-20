import Testing

@testable import SimbiAudio

@Suite("OfflineSpeechAnalyzer record assembly")
struct OfflineSpeechAnalyzerTests {
    @Test("maps chunk verdicts and frame predictions onto the 80 ms grid")
    func assembly() {
        // 3 VAD chunks (256 ms each) for 12800 samples = 10 frames.
        // Frame f's midpoint sample = f*1280 + 640; chunk = midpoint / 4096.
        // Frames 0-2 → chunk 0 (true), 3-5 → chunk 1 (false), 6-8 → chunk 2
        // (true), frame 9 midpoint 12160 → chunk 2 (true).
        let verdicts = [true, false, true]
        // Predictions for only 8 frames: slot 2 active on the first 4,
        // nothing active on the next 4; frames 8-9 have no prediction.
        var predictions = [Float]()
        for _ in 0..<4 { predictions += [0, 0, 0.9, 0] }
        for _ in 0..<4 { predictions += [0, 0, 0, 0] }
        let records = OfflineSpeechAnalyzer.assembleRecords(
            chunkVerdicts: verdicts, predictions: predictions, sampleCount: 12800)
        #expect(records.count == 10)
        #expect(records[0] == ImportFrameRecord(vadActive: true, dominantSlot: 2))
        #expect(records[3] == ImportFrameRecord(vadActive: false, dominantSlot: 2))
        #expect(records[4] == ImportFrameRecord(vadActive: false, dominantSlot: nil))
        #expect(records[7] == ImportFrameRecord(vadActive: true, dominantSlot: nil))
        #expect(records[9] == ImportFrameRecord(vadActive: true, dominantSlot: nil))
    }

    @Test("empty input produces no records")
    func empty() {
        #expect(
            OfflineSpeechAnalyzer.assembleRecords(chunkVerdicts: [], predictions: [], sampleCount: 0)
                .isEmpty)
    }
}
