import SimbiAudio
import SwiftUI

// The inspector's section views: front-end model boxes, rule meters, the
// flush lane (segments + transcript text) and the event log. All
// re-evaluate on the model's `summaryTick`, not per PCM batch.

// MARK: - Front end row (§3–§4 boxes)

struct InspectorFrontEndRow: View {
    let state: InspectorTimelineState

    var body: some View {
        let latest = state.latest
        HStack(spacing: 10) {
            box("PCM in", subtitle: "16 kHz mono mix") {
                bigValue((latest?.samplesFed ?? 0).formatted(), unit: "samples fed")
            }
            box("Wrapped VAD", subtitle: "256 ms chunks · ≤ 4 fr lag") {
                let inChunk = (latest?.samplesFed ?? 0) % CutConstants.vadChunkSamples
                fillBar(
                    Double(inChunk) / Double(CutConstants.vadChunkSamples), color: .secondary)
                labelRow("\(inChunk) / 4096", trailing: "\(latest?.vadChunks ?? 0) chunks")
                verdictDots
            }
            box("Wrapped Sortformer", subtitle: "6-frame bursts · ≤ 13 fr lag") {
                let finalized = latest?.sortFramesFinalized ?? 0
                fillBar(burstProgress(latest), color: Design.speakerPalette[0])
                labelRow("next burst", trailing: "finalized: \(finalized) fr")
                slotBars
            }
            box("Release clock", subtitle: "emit f when fed ≥ (f+13)·1280") {
                bigValue("\(latest?.frontier ?? 0)", unit: "frontier frame")
                labelRow(
                    "release lag", trailing: String(format: "%.2f s", releaseLag(latest)))
            }
            box("PCM ring", subtitle: "evicts below flushedUpTo") {
                let retained = retainedSeconds(latest)
                bigValue(String(format: "%.1f s", retained), unit: retainedMB(retained))
                fillBar(retained / 31.0, color: InspectorDesign.accent)
            }
        }
    }

    private var verdictDots: some View {
        // Last 24 chunk verdicts, derived from the frame lane (frames map
        // to chunks by the §3.1 midpoint rule — good enough for a readout).
        HStack(spacing: 2) {
            let verdicts = recentChunkVerdicts(count: 24)
            ForEach(Array(verdicts.enumerated()), id: \.offset) { _, active in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(active ? Color.secondary : Color.primary.opacity(0.07))
                    .frame(width: 7, height: 7)
            }
        }
    }

    private var slotBars: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 2) {
            let probs = latestProbabilities
            ForEach(0..<4, id: \.self) { slot in
                GridRow {
                    Text("S\(slot + 1)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.06))
                            Capsule()
                                .fill(InspectorDesign.speaker(slot))
                                .frame(width: geo.size.width * CGFloat(probs[slot]))
                                .opacity(
                                    probs[slot] >= CutConstants.activeProbability ? 1 : 0.4)
                            // 0.5 activation threshold marker
                            Rectangle()
                                .fill(Color.primary.opacity(0.25))
                                .frame(width: 1)
                                .offset(x: geo.size.width * 0.5)
                        }
                    }
                    .frame(height: 5)
                    Text(String(format: "%.2f", probs[slot]))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
        }
    }

    private var latestProbabilities: [Float] {
        let probs = state.frames.last?.probabilities ?? []
        return probs.count == 4 ? probs : [0, 0, 0, 0]
    }

    private func recentChunkVerdicts(count: Int) -> [Bool] {
        guard let latest = state.latest, latest.vadChunks > 0 else {
            return Array(repeating: false, count: count)
        }
        var byChunk: [Int: Bool] = [:]
        for record in state.frames.suffix(count * 4) {
            let chunk =
                (record.frame * CutConstants.frameSamples + CutConstants.frameSamples / 2)
                / CutConstants.vadChunkSamples
            byChunk[chunk] = record.vadActive
        }
        let lastChunk = latest.vadChunks - 1
        return (max(0, lastChunk - count + 1)...max(0, lastChunk)).map { byChunk[$0] ?? false }
    }

    private func burstProgress(_ latest: InspectorUpdate?) -> Double {
        guard let latest else { return 0 }
        let nextBurstAt =
            (latest.sortFramesFinalized + CutConstants.pipelineLatencyFrames)
            * CutConstants.frameSamples
        let span = Double(6 * CutConstants.frameSamples)
        return max(0, min(1, 1 - Double(nextBurstAt - latest.samplesFed) / span))
    }

    private func releaseLag(_ latest: InspectorUpdate?) -> Double {
        guard let latest else { return 0 }
        return Double(latest.samplesFed - latest.frontier * CutConstants.frameSamples) / 16000
    }

    private func retainedSeconds(_ latest: InspectorUpdate?) -> Double {
        guard let latest else { return 0 }
        return max(
            0,
            Double(latest.samplesFed - latest.flushedUpTo * CutConstants.frameSamples) / 16000)
    }

    private func retainedMB(_ seconds: Double) -> String {
        String(format: "%.2f MB · cap 30 s", seconds * 16000 * 4 / 1_000_000)
    }

    private func box(
        _ title: String, subtitle: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.metaSemibold)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            content()
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .background(InspectorDesign.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(InspectorDesign.line))
    }

    private func bigValue(_ value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 15, weight: .medium))
                .monospacedDigit()
            Text(unit)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func fillBar(_ fraction: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06))
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, fraction))))
            }
        }
        .frame(height: 6)
    }

    private func labelRow(_ leading: String, trailing: String) -> some View {
        HStack {
            Text(leading)
            Spacer()
            Text(trailing)
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .monospacedDigit()
    }
}

// MARK: - Rule meters

struct InspectorMetersRow: View {
    let state: InspectorTimelineState

    private struct Meter {
        let id: String
        let name: String
        let desc: String
        let fraction: Double
        let value: String
        var color: Color = .secondary
    }

    var body: some View {
        let latest = state.latest
        HStack(spacing: 10) {
            meterView(
                Meter(
                    id: "R1", name: "Silence cut",
                    desc: "3 silent records seal the speech tail into staging.",
                    fraction: fraction(latest?.silenceRun, of: CutConstants.silenceCutFrames),
                    value: r1Value(latest)))
            meterView(
                Meter(
                    id: "R3", name: "Long-silence flush",
                    desc: "2 s of silence ships staged speech to the transcript.",
                    fraction: fraction(
                        latest?.silenceRun, of: CutConstants.longSilenceFlushFrames),
                    value: r3Value(latest)))
            meterView(
                Meter(
                    id: "R6", name: "Silence trim",
                    desc: "Past R3, dead air is discarded — only a 0.96 s pre-roll is kept.",
                    fraction: isTrimming(latest) ? 1 : 0,
                    value: isTrimming(latest) ? "trimming — pre-roll 0.96 s" : "idle",
                    color: InspectorDesign.accent))
            meterR4(latest)
            meterView(
                Meter(
                    id: "R2", name: "Size flush",
                    desc: "After any cut, staging over 10 s ships as one upload.",
                    fraction: fraction(staged(latest), of: CutConstants.stagingFlushFrames),
                    value: String(
                        format: "%.1f s / 10 s staged", Double(staged(latest) ?? 0) * 0.08)))
            meterView(
                Meter(
                    id: "R5", name: "Max latency",
                    desc: "30 s unflushed forces a boundary — even mid-word.",
                    fraction: fraction(unflushed(latest), of: CutConstants.maxUnflushedFrames),
                    value: String(
                        format: "%.1f s / 30 s unflushed",
                        Double(unflushed(latest) ?? 0) * 0.08)))
        }
    }

    private func fraction(_ value: Int?, of threshold: Int) -> Double {
        min(1, Double(value ?? 0) / Double(threshold))
    }

    private func staged(_ latest: InspectorUpdate?) -> Int? {
        latest.map { $0.cutUpTo - $0.flushedUpTo }
    }

    private func unflushed(_ latest: InspectorUpdate?) -> Int? {
        latest.map { $0.frontier - $0.flushedUpTo }
    }

    private func isTrimming(_ latest: InspectorUpdate?) -> Bool {
        guard let latest else { return false }
        return latest.silenceRun >= CutConstants.longSilenceFlushFrames
            && latest.cutUpTo == latest.flushedUpTo
    }

    private func r1Value(_ latest: InspectorUpdate?) -> String {
        guard let run = latest?.silenceRun, run > 0 else { return "in speech" }
        return run < CutConstants.silenceCutFrames
            ? "silence \(run * 80) ms / 240 ms" : "fired — waiting for speech"
    }

    private func r3Value(_ latest: InspectorUpdate?) -> String {
        guard let run = latest?.silenceRun, run > 0 else { return "—" }
        return run < CutConstants.longSilenceFlushFrames
            ? String(format: "%.1f s / 2.0 s", Double(run) * 0.08)
            : "fired — R6 owns the pause"
    }

    private func meterR4(_ latest: InspectorUpdate?) -> some View {
        let challenger = latest.flatMap { update in
            update.previousDominant != update.currentSpeaker ? update.previousDominant : nil
        }
        let run = challenger != nil ? (latest?.dominantRun ?? 0) : 0
        return meterCard("R4", "Speaker change") {
            Text("A new speaker holding 0.48 s of dominance flushes the old turn.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(minHeight: 26, alignment: .top)
            meterBar(
                fraction: fraction(run, of: CutConstants.speakerStableFrames), color: .secondary)
            HStack(spacing: 5) {
                speakerChip(latest?.currentSpeaker, empty: "no speaker yet")
                if let challenger {
                    Text("←")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    speakerChip(challenger, empty: "")
                    Text("\(run)/6")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(minHeight: 15)
        }
    }

    @ViewBuilder
    private func speakerChip(_ slot: Int?, empty: String) -> some View {
        if let slot {
            SpeakerChip(name: InspectorDesign.speakerName(slot))
        } else {
            Text(empty)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func meterView(_ meter: Meter) -> some View {
        meterCard(meter.id, meter.name) {
            Text(meter.desc)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(minHeight: 26, alignment: .top)
            meterBar(fraction: meter.fraction, color: meter.color)
            Text(meter.value)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .frame(minHeight: 15)
        }
    }

    private func meterCard(
        _ id: String, _ name: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(id)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(InspectorDesign.accent)
                Text(name)
                    .font(.metaSemibold)
            }
            content()
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(InspectorDesign.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(InspectorDesign.line))
    }

    private func meterBar(fraction: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06))
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, fraction))))
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Flush lane (segments with transcript text)

struct InspectorFlushLane: View {
    let state: InspectorTimelineState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 8) {
                    if state.segments.isEmpty {
                        Text(
                            "No uploads yet — the first flush appears here with its transcript."
                        )
                        .font(.meta)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 24)
                    }
                    ForEach(state.segments) { segment in
                        card(segment).id(segment.id)
                    }
                }
                .padding(.horizontal, Design.paneInset)
            }
            .onChange(of: state.segments.last?.id) { _, lastId in
                if let lastId {
                    withAnimation { proxy.scrollTo(lastId, anchor: .trailing) }
                }
            }
        }
    }

    private func card(_ segment: InspectorTimelineState.Segment) -> some View {
        let color =
            segment.speaker == nil
            ? InspectorDesign.faintInk : InspectorDesign.speaker(segment.speaker)
        let duration =
            Double(segment.endFrame - segment.startFrame) * InspectorDesign.frameSeconds
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Cue \(String(format: "%03d", segment.id))")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                if segment.speaker != nil {
                    SpeakerChip(name: InspectorDesign.speakerName(segment.speaker))
                }
                Spacer()
                Text(String(format: "%.1f s", duration))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 6) {
                Text(InspectorTimelineState.tag(segment.reason))
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(InspectorDesign.line))
                    .foregroundStyle(.secondary)
                Text(spanLabel(segment))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Group {
                switch segment.status {
                case .queued:
                    Text("transcribing…")
                        .foregroundStyle(.tertiary)
                case .done(let text):
                    Text("“\(text)”")
                }
            }
            .font(.system(size: 11))
            .lineLimit(3)
            .frame(minHeight: 40, alignment: .topLeading)
        }
        .padding(9)
        .frame(width: 210, alignment: .topLeading)
        .background(InspectorDesign.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(InspectorDesign.line))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)
                .fill(color)
                .frame(width: 3)
        }
    }

    private func spanLabel(_ segment: InspectorTimelineState.Segment) -> String {
        let start = Design.time(Double(segment.startFrame) * InspectorDesign.frameSeconds)
        let end = Design.time(Double(segment.endFrame) * InspectorDesign.frameSeconds)
        return "\(start)–\(end)"
    }
}

// MARK: - Event log

struct InspectorEventLog: View {
    let state: InspectorTimelineState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                if state.log.isEmpty {
                    Text("— waiting for the first engine decision —")
                        .foregroundStyle(.tertiary)
                }
                ForEach(state.log) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Design.time(entry.time))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                        Text(entry.tag)
                            .font(.metaSemibold)
                            .foregroundStyle(InspectorDesign.accent)
                            .frame(width: 34, alignment: .leading)
                        Text(entry.message)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
            }
            .font(.meta)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .frame(minHeight: 90, maxHeight: 150)
        .background(InspectorDesign.well, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(InspectorDesign.line))
    }
}
