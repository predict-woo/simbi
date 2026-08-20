import Testing

@testable import SimbiAudio

/// Offline block builder (media-import spec): speech regions between long
/// silences, speaker spans within regions, recursive silence-split for
/// oversize blocks. Pure — records are synthesized directly.
@Suite("ImportBlockBuilder")
struct ImportBlockBuilderTests {
    /// records(...) DSL: each element is (count, vadActive, slot).
    private func records(_ runs: [(Int, Bool, Int?)]) -> [ImportFrameRecord] {
        runs.flatMap { count, vad, slot in
            Array(repeating: ImportFrameRecord(vadActive: vad, dominantSlot: slot), count: count)
        }
    }

    private func blocks(_ entries: [ImportTimelineEntry]) -> [ImportBlock] {
        entries.compactMap { if case .block(let b) = $0 { b } else { nil } }
    }

    @Test("speaker change cuts a region into per-speaker blocks")
    func speakerChangeCuts() {
        // 100 frames slot 0, 100 frames slot 1, all VAD-active.
        let entries = ImportBlockBuilder.build(
            records: records([(100, true, 0), (100, true, 1)]))
        #expect(
            blocks(entries) == [
                ImportBlock(startFrame: 0, endFrame: 100, speaker: 0),
                ImportBlock(startFrame: 100, endFrame: 200, speaker: 1),
            ])
    }

    @Test("a silence over the gap threshold becomes a gap entry, pads retained")
    func longSilenceGap() {
        // speech(50, s0) silence(50) speech(50, s0): regions keep 12 pad
        // frames on each side of the silence; the gap covers the rest.
        let entries = ImportBlockBuilder.build(
            records: records([(50, true, 0), (50, false, nil), (50, true, 0)]))
        #expect(
            entries == [
                .block(ImportBlock(startFrame: 0, endFrame: 62, speaker: 0)),
                .gap(startFrame: 62, endFrame: 88),
                .block(ImportBlock(startFrame: 88, endFrame: 150, speaker: 0)),
            ])
    }

    @Test("leading and trailing silence produce no entries")
    func leadingTrailingSilenceDropped() {
        let entries = ImportBlockBuilder.build(
            records: records([(100, false, nil), (50, true, 0), (100, false, nil)]))
        // Block keeps up to 12 pad frames on each side, nothing else.
        #expect(
            entries == [.block(ImportBlock(startFrame: 88, endFrame: 162, speaker: 0))])
    }

    @Test("short silences stay inside a block")
    func shortSilenceInline() {
        let entries = ImportBlockBuilder.build(
            records: records([(50, true, 0), (10, false, nil), (50, true, 0)]))
        #expect(entries == [.block(ImportBlock(startFrame: 0, endFrame: 110, speaker: 0))])
    }

    @Test("a speaker flicker shorter than the stability window is absorbed")
    func flickerAbsorbed() {
        let entries = ImportBlockBuilder.build(
            records: records([(100, true, 0), (3, true, 1), (100, true, 0)]))
        #expect(entries == [.block(ImportBlock(startFrame: 0, endFrame: 203, speaker: 0))])
    }

    @Test("nil-dominant frames inherit the surrounding speaker")
    func nilDominantInherits() {
        let entries = ImportBlockBuilder.build(
            records: records([(100, true, 0), (20, true, nil), (100, true, 1)]))
        // The nil stretch merges into the preceding slot-0 span.
        #expect(
            blocks(entries) == [
                ImportBlock(startFrame: 0, endFrame: 120, speaker: 0),
                ImportBlock(startFrame: 120, endFrame: 220, speaker: 1),
            ])
    }

    @Test("an all-nil region falls back to slot 0")
    func allNilFallsBack() {
        let entries = ImportBlockBuilder.build(records: records([(50, true, nil)]))
        #expect(entries == [.block(ImportBlock(startFrame: 0, endFrame: 50, speaker: 0))])
    }

    @Test("an oversize monologue splits at the longest central silence")
    func oversizeSplitsAtSilence() {
        // 4500 frames of slot 0 with one 6-frame silence at frame 2000
        // (midpoint 2003, 44.5% — inside the middle 50% band [1125, 3375]).
        let entries = ImportBlockBuilder.build(
            records: records([(2000, true, 0), (6, false, nil), (2494, true, 0)]))
        let result = blocks(entries)
        #expect(result.count == 2)
        #expect(result[0] == ImportBlock(startFrame: 0, endFrame: 2003, speaker: 0))
        #expect(result[1] == ImportBlock(startFrame: 2003, endFrame: 4500, speaker: 0))
        #expect(result.allSatisfy { $0.endFrame - $0.startFrame <= ImportConstants.maxBlockFrames })
    }

    @Test("the relaxed tier finds a short silence when no primary candidate exists")
    func relaxedTierUsed() {
        // One 2-frame silence at 60% of a 4500-frame block: too short for
        // the primary tier, valid for the relaxed one (middle 80%,
        // [450, 4050]).
        let entries = ImportBlockBuilder.build(
            records: records([(2700, true, 0), (2, false, nil), (1798, true, 0)]))
        let result = blocks(entries)
        #expect(result.count == 2)
        #expect(result[0].endFrame == 2701)
    }

    @Test("continuous speech with no silences hard-chops into equal pieces")
    func hardChop() {
        let entries = ImportBlockBuilder.build(records: records([(16000, true, 0)]))
        let result = blocks(entries)
        #expect(result.count == 5)  // ceil(16000 / 3750)
        #expect(result.map { $0.endFrame - $0.startFrame }.allSatisfy { $0 <= ImportConstants.maxBlockFrames })
        #expect(result.first?.startFrame == 0)
        #expect(result.last?.endFrame == 16000)
        // Pieces tile with no overlap: [0,3200) [3200,6400) [6400,9600)
        // [9600,12800) [12800,16000).
        for (a, b) in zip(result, result.dropFirst()) { #expect(a.endFrame == b.startFrame) }
    }

    @Test("recursion bounds every block even with many silences")
    func deepSplitTerminates() {
        // 39000 frames with a 5-frame silence every 3000 frames.
        var runs: [(Int, Bool, Int?)] = []
        for _ in 0..<13 {
            runs.append((2995, true, 0))
            runs.append((5, false, nil))
        }
        let entries = ImportBlockBuilder.build(records: records(runs))
        let result = blocks(entries)
        #expect(result.allSatisfy { $0.endFrame - $0.startFrame <= ImportConstants.maxBlockFrames })
        for (a, b) in zip(result, result.dropFirst()) { #expect(a.endFrame <= b.startFrame) }
    }

    @Test("determinism: same records, identical output")
    func deterministic() {
        let input = records([
            (4000, true, 0), (30, false, nil), (4000, true, 1), (6, false, nil), (2000, true, 1),
        ])
        #expect(ImportBlockBuilder.build(records: input) == ImportBlockBuilder.build(records: input))
    }

    @Test("empty and all-silent inputs produce nothing")
    func degenerateInputs() {
        #expect(ImportBlockBuilder.build(records: []).isEmpty)
        #expect(ImportBlockBuilder.build(records: records([(500, false, nil)])).isEmpty)
    }
}
