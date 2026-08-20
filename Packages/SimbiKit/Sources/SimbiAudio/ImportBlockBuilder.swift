import Foundation

/// The offline sibling of `CutEngine` (media-import spec): turns the
/// per-frame records of a whole imported file — one `{vadActive,
/// dominantSlot}` per 80 ms frame — into a timeline of speaker-attributed
/// blocks and gap entries. Pure and deterministic: records in, timeline out
/// — no IO, no clocks. Downstream tasks slice PCM by the block boundaries
/// and upload each block for transcription, so blocks are hard-bounded at
/// `ImportConstants.maxBlockFrames`.
///
/// All indices are file-relative frames (80 ms, 1280 samples).

/// Constants of the media-import pipeline (frame counts normative).
public enum ImportConstants {
    /// Hard bound on a block, 5 min: the transcribe endpoint silently
    /// truncates transcripts of clips much past 6 minutes (measured
    /// 2026-08-21 by simbi-import-spike --length-check).
    public static let maxBlockFrames = 3750
    /// A silence run at least this long (2 s) separates speech regions and
    /// becomes a gap entry.
    public static let gapThresholdFrames = 25
    /// Frames of the neighboring long silence retained on each region edge.
    public static let edgePadFrames = 12
    /// Primary split tier: minimum silence length for a split candidate.
    public static let splitMinSilenceFrames = 4
    /// Relaxed split tier: minimum silence length when the primary tier is
    /// empty.
    public static let splitRelaxedSilenceFrames = 2
    /// Concurrency cap for the import upload queue (Tasks 5–7).
    public static let uploadMaxConcurrent = 5
}

/// One aligned offline record: the VAD verdict and the dominant Sortformer
/// slot (nil when no slot is active) for one 80 ms frame.
public struct ImportFrameRecord: Equatable, Sendable {
    public let vadActive: Bool
    public let dominantSlot: Int?

    public init(vadActive: Bool, dominantSlot: Int?) {
        self.vadActive = vadActive
        self.dominantSlot = dominantSlot
    }
}

/// One speaker-attributed span `[startFrame, endFrame)` to slice and upload.
public struct ImportBlock: Equatable, Sendable {
    public let startFrame: Int
    /// Exclusive.
    public let endFrame: Int
    /// Sortformer slot; 0 is the display fallback when no slot ever won.
    public let speaker: Int

    public init(startFrame: Int, endFrame: Int, speaker: Int) {
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.speaker = speaker
    }
}

/// Timeline element: a block to upload, or a gap (long silence between
/// regions, minus the retained edge pads) that uploads nothing.
public enum ImportTimelineEntry: Equatable, Sendable {
    case block(ImportBlock)
    case gap(startFrame: Int, endFrame: Int)
}

public enum ImportBlockBuilder {
    /// Records in (one per 80 ms frame, file-relative), timeline out.
    /// Entries are ordered, non-overlapping; blocks and gaps tile the
    /// speech-bearing part of the file; leading/trailing silence produces
    /// no entry at all.
    public static func build(records: [ImportFrameRecord]) -> [ImportTimelineEntry] {
        guard !records.isEmpty else { return [] }
        let silences = silenceRuns(records)

        // 1. Speech regions between long silences.
        var regions: [Range<Int>] = []
        var cursor = 0
        for run in silences where run.count >= ImportConstants.gapThresholdFrames {
            if run.lowerBound > cursor {
                regions.append(cursor..<run.lowerBound)
            }
            cursor = run.upperBound
        }
        if cursor < records.count { regions.append(cursor..<records.count) }
        // Drop regions with no VAD speech at all (short-silence artifacts).
        regions = regions.filter { r in records[r].contains(where: \.vadActive) }
        guard !regions.isEmpty else { return [] }
        // Pad each region into its neighboring long silence.
        let padded = regions.map { r -> Range<Int> in
            let leftSilence = silences.first { $0.upperBound == r.lowerBound }
            let rightSilence = silences.first { $0.lowerBound == r.upperBound }
            let lo = r.lowerBound - min(ImportConstants.edgePadFrames, leftSilence?.count ?? 0)
            let hi = r.upperBound + min(ImportConstants.edgePadFrames, rightSilence?.count ?? 0)
            return lo..<hi
        }

        // 2. Blocks per region (speaker spans + oversize split), gaps
        // between regions when at least one frame survives the pads.
        var entries: [ImportTimelineEntry] = []
        for (i, region) in padded.enumerated() {
            if i > 0, padded[i - 1].upperBound < region.lowerBound {
                entries.append(
                    .gap(startFrame: padded[i - 1].upperBound, endFrame: region.lowerBound))
            }
            for span in speakerSpans(region: region, records: records) {
                entries.append(contentsOf: split(span, records: records).map { .block($0) })
            }
        }
        return entries
    }

    /// Maximal `!vadActive` runs, ascending.
    static func silenceRuns(_ records: [ImportFrameRecord]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for (i, r) in records.enumerated() {
            if !r.vadActive {
                start = start ?? i
            } else if let s = start {
                runs.append(s..<i)
                start = nil
            }
        }
        if let s = start { runs.append(s..<records.count) }
        return runs
    }

    /// One block per stable speaker within the region. A new slot must hold
    /// `CutConstants.speakerStableFrames` (6) frames to take over — same
    /// debounce as the live engine; nil dominants extend the current span.
    static func speakerSpans(region: Range<Int>, records: [ImportFrameRecord]) -> [ImportBlock] {
        var spans: [ImportBlock] = []
        var current: (start: Int, speaker: Int)?
        var candidate: (slot: Int, since: Int)?
        for f in region {
            guard let slot = records[f].dominantSlot else {
                candidate = nil
                continue
            }
            if current == nil {
                current = (region.lowerBound, slot)
                candidate = nil
            } else if slot != current!.speaker {
                if candidate?.slot != slot { candidate = (slot, f) }
                if f - candidate!.since + 1 >= CutConstants.speakerStableFrames {
                    let cut = candidate!.since
                    spans.append(
                        ImportBlock(
                            startFrame: current!.start, endFrame: cut, speaker: current!.speaker))
                    current = (cut, slot)
                    candidate = nil
                }
            } else {
                candidate = nil
            }
        }
        spans.append(
            ImportBlock(
                startFrame: current?.start ?? region.lowerBound,
                endFrame: region.upperBound,
                speaker: current?.speaker ?? 0))
        return spans
    }

    /// Oversize split: cut at the midpoint of the longest silence run near
    /// the center (primary tier: ≥ 4 frames, middle 50%; relaxed tier: ≥ 2
    /// frames, middle 80%), recursing on both halves; with no candidate at
    /// all, hard-chop into equal pieces. Ties break toward the run closest
    /// to the center, then the earliest run, for determinism.
    static func split(_ block: ImportBlock, records: [ImportFrameRecord]) -> [ImportBlock] {
        let len = block.endFrame - block.startFrame
        guard len > ImportConstants.maxBlockFrames else { return [block] }
        let inner = silenceRuns(records).filter {
            $0.lowerBound >= block.startFrame && $0.upperBound <= block.endFrame
        }
        func pool(minFrames: Int, band: Double) -> [Range<Int>] {
            let lo = block.startFrame + Int((Double(len) * (0.5 - band / 2)).rounded(.up))
            let hi = block.startFrame + Int(Double(len) * (0.5 + band / 2))
            return inner.filter {
                $0.count >= minFrames && (lo...hi).contains(($0.lowerBound + $0.upperBound) / 2)
            }
        }
        var candidates = pool(minFrames: ImportConstants.splitMinSilenceFrames, band: 0.5)
        if candidates.isEmpty {
            candidates = pool(minFrames: ImportConstants.splitRelaxedSilenceFrames, band: 0.8)
        }
        let center = block.startFrame + len / 2
        guard
            let best = candidates.max(by: { a, b in
                (a.count, -abs((a.lowerBound + a.upperBound) / 2 - center), -a.lowerBound)
                    < (b.count, -abs((b.lowerBound + b.upperBound) / 2 - center), -b.lowerBound)
            })
        else {
            let pieces = (len + ImportConstants.maxBlockFrames - 1) / ImportConstants.maxBlockFrames
            let pieceLen = (len + pieces - 1) / pieces
            return (0..<pieces).map { i in
                ImportBlock(
                    startFrame: block.startFrame + i * pieceLen,
                    endFrame: min(block.startFrame + (i + 1) * pieceLen, block.endFrame),
                    speaker: block.speaker)
            }
        }
        let cut = (best.lowerBound + best.upperBound) / 2
        return split(
            ImportBlock(startFrame: block.startFrame, endFrame: cut, speaker: block.speaker),
            records: records)
            + split(
                ImportBlock(startFrame: cut, endFrame: block.endFrame, speaker: block.speaker),
                records: records)
    }
}
