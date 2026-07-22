import SimbiAudio
import SwiftUI

/// The inspector's hero: the last ~45 s of the aligned record stream —
/// VAD lane, speaker lane, the buffer band with its three pointers,
/// uploaded segments, hatched discards, cut marks and rule badges.
/// Reads the model's hot state on a 30 Hz TimelineView clock (bypassing
/// observation) so drawing cost is bounded and the pipeline never waits.
struct InspectorTimeline: View {
    let model: PipelineInspectorModel

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                // Capturing the tick's date gives the canvas closure a new
                // identity every frame — without it SwiftUI reuses the
                // first render and the timeline freezes at t≈0.
                _ = timeline.date
                let state = model.state
                if let latest = state.latest {
                    var drawer = TimelineDrawer(
                        context: context, size: size, state: state, latest: latest)
                    drawer.draw()
                }
            }
        }
        .background(InspectorDesign.well, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(InspectorDesign.line))
    }
}

/// One frame of timeline drawing; holds the shared geometry so the lane
/// painters stay small. All ink is semantic (`.primary`-derived) so the
/// canvas reads on the light and dark well alike.
private struct TimelineDrawer {
    let context: GraphicsContext
    let size: CGSize
    let state: InspectorTimelineState
    let latest: InspectorUpdate

    static let windowSeconds = 45.0
    private let padL = 8.0
    private let padR = 62.0

    private let yRuler = 12.0
    private let yVad = 22.0, hVad = 10.0
    private let ySpk = 36.0, hSpk = 12.0
    private let yBand = 54.0, hBand = 56.0
    private let yBadge = 116.0
    private var yPtrEnd: CGFloat { size.height - 32 }

    /// Session-local seconds of the live head.
    private var liveT: Double { Double(latest.samplesFed) / 16000 }
    private var pxPerSec: CGFloat { (size.width - padL - padR) / Self.windowSeconds }
    private var windowStart: Double { liveT - Self.windowSeconds }
    private var frameW: CGFloat { max(0.6, pxPerSec * InspectorDesign.frameSeconds - 0.4) }

    /// Occupied label intervals per pointer-label row (collision layout).
    private var labelRows: [[ClosedRange<CGFloat>]] = [[], []]

    init(
        context: GraphicsContext, size: CGSize, state: InspectorTimelineState,
        latest: InspectorUpdate
    ) {
        self.context = context
        self.size = size
        self.state = state
        self.latest = latest
    }

    private func xOfT(_ time: Double) -> CGFloat {
        size.width - padR - (liveT - time) * pxPerSec
    }

    private func xOfF(_ frame: Int) -> CGFloat {
        xOfT(Double(frame) * InspectorDesign.frameSeconds)
    }

    mutating func draw() {
        drawRuler()
        drawFrameLanes()
        drawBufferBand()
        drawSegments()
        drawDiscards()
        drawCutMarks()
        drawBadges()
        drawPointers()
        drawLeftFade()
    }

    private func drawRuler() {
        var tickTime = max(0, (windowStart / 5).rounded(.up) * 5)
        while tickTime <= liveT + 0.001 {
            let x = xOfT(tickTime)
            context.stroke(
                vertical(x: x, from: yRuler, to: size.height - 28),
                with: .color(.primary.opacity(0.05)), lineWidth: 1)
            context.draw(
                Text(Design.time(latest.sessionBaseSeconds + tickTime))
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(InspectorDesign.faintInk),
                at: CGPoint(x: x, y: yRuler - 5))
            tickTime += 5
        }
    }

    private func drawFrameLanes() {
        guard !state.frames.isEmpty else { return }
        let firstVisible = max(
            state.firstBufferedFrame,
            Int(max(0, windowStart) / InspectorDesign.frameSeconds))
        for frame in firstVisible..<(state.firstBufferedFrame + state.frames.count) {
            let record = state.frames[frame - state.firstBufferedFrame]
            let x = xOfF(frame)
            if record.vadActive {
                context.fill(
                    Path(CGRect(x: x, y: yVad, width: frameW, height: hVad)),
                    with: .color(.secondary))
            } else {
                context.fill(
                    Path(CGRect(x: x, y: yVad + 3, width: frameW, height: hVad - 6)),
                    with: .color(.primary.opacity(0.06)))
            }
            context.fill(
                Path(CGRect(x: x, y: ySpk, width: frameW, height: hSpk)),
                with: .color(InspectorDesign.speaker(record.dominantSlot)))
        }
    }

    private func drawBufferBand() {
        let xFlushed = xOfF(latest.flushedUpTo)
        let xCut = xOfF(latest.cutUpTo)
        let xFrontier = xOfF(latest.frontier)
        let xLive = xOfT(liveT)
        context.fill(
            Path(CGRect(x: xFrontier, y: yBand, width: xLive - xFrontier, height: hBand)),
            with: .color(.primary.opacity(0.08)))
        context.fill(
            Path(CGRect(x: xFlushed, y: yBand, width: max(0, xCut - xFlushed), height: hBand)),
            with: .color(InspectorDesign.accent.opacity(0.13)))
        context.fill(
            Path(CGRect(x: xCut, y: yBand, width: max(0, xFrontier - xCut), height: hBand)),
            with: .color(.primary.opacity(0.03)))
        if xCut - xFlushed > 60 {
            regionLabel("STAGING", x: xFlushed + 5, y: yBand + 8)
        }
        if xFrontier - xCut > 80 {
            regionLabel("PROCESSING", x: xCut + 5, y: yBand + 8)
        }
        if xLive - xFrontier > 74 {
            regionLabel("FINALIZING", x: xFrontier + 5, y: yBand + 8)
        }
    }

    private func drawSegments() {
        for segment in state.segments {
            let x1 = xOfF(segment.startFrame), x2 = xOfF(segment.endFrame)
            guard x2 > padL - 20 else { continue }
            let rect = CGRect(
                x: x1 + 1, y: yBand + 18, width: max(2, x2 - x1 - 2), height: hBand - 24)
            let color =
                segment.speaker == nil
                ? InspectorDesign.faintInk : InspectorDesign.speaker(segment.speaker)
            let path = Path(roundedRect: rect, cornerRadius: 3)
            var isDone = false
            if case .done = segment.status { isDone = true }
            context.fill(path, with: .color(color.opacity(isDone ? 0.35 : 0.15)))
            context.stroke(path, with: .color(color), lineWidth: 1)
            if x2 - x1 > 36 {
                context.draw(
                    Text(InspectorTimelineState.tag(segment.reason))
                        .font(.system(size: 9))
                        .foregroundStyle(.primary.opacity(0.7)),
                    at: CGPoint(x: x1 + 14, y: yBand + hBand - 13))
            }
        }
    }

    private func drawDiscards() {
        for span in state.discards {
            let x1 = xOfF(span.start), x2 = xOfF(span.end)
            guard x2 > padL - 20 else { continue }
            let rect = CGRect(x: x1, y: yBand + 18, width: x2 - x1, height: hBand - 24)
            context.drawLayer { layer in
                layer.clip(to: Path(rect))
                var hatch = Path()
                var x = rect.minX - rect.height
                while x < rect.maxX {
                    hatch.move(to: CGPoint(x: x, y: rect.maxY))
                    hatch.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                    x += 6
                }
                layer.stroke(hatch, with: .color(.primary.opacity(0.18)), lineWidth: 1)
            }
            let label = String(
                format: "%.1f s trimmed",
                Double(span.end - span.start) * InspectorDesign.frameSeconds)
            let labelX = max(x1, 50) + 5
            if x2 - labelX > 74 {
                regionLabel(label, x: labelX, y: yBand + hBand - 16)
            }
        }
    }

    private func drawCutMarks() {
        for mark in state.cutMarks {
            let x = xOfF(mark.frame)
            guard x > padL - 5 else { continue }
            context.stroke(
                vertical(x: x, from: yBand + 16, to: yBand + hBand - 2),
                with: .color(.primary.opacity(0.4)),
                style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
    }

    /// Recent decisions get a fading badge above the band: ✂ cuts, ⇧ flushes.
    private func drawBadges() {
        var badges: [(x: CGFloat, label: String)] = []
        for mark in state.cutMarks.suffix(24)
        where liveT - Double(mark.frame) * InspectorDesign.frameSeconds < 14 {
            badges.append((xOfF(mark.frame), "✂ " + InspectorTimelineState.tag(mark.rule)))
        }
        for segment in state.segments.suffix(12)
        where liveT - Double(segment.endFrame) * InspectorDesign.frameSeconds < 14 {
            badges.append(
                (xOfF(segment.endFrame), "⇧ " + InspectorTimelineState.tag(segment.reason)))
        }
        for (index, badge) in badges.enumerated() where badge.x > padL {
            let resolved = context.resolve(
                Text(badge.label)
                    .font(.system(size: 9))
                    .foregroundStyle(.primary))
            let textSize = resolved.measure(in: CGSize(width: 100, height: 20))
            let y = yBadge + (index.isMultiple(of: 2) ? 0.0 : 15.0)
            let rect = CGRect(
                x: badge.x - textSize.width / 2 - 4, y: y,
                width: textSize.width + 8, height: 13)
            let path = Path(roundedRect: rect, cornerRadius: 3)
            context.fill(path, with: .color(Color(nsColor: .windowBackgroundColor)))
            context.stroke(path, with: .color(InspectorDesign.line), lineWidth: 1)
            context.draw(resolved, at: CGPoint(x: rect.midX, y: rect.midY))
        }
    }

    private mutating func drawPointers() {
        pointer(
            x: xOfT(liveT), color: .red,
            label: "live " + Design.time(latest.sessionBaseSeconds + liveT), preferredRow: 0)
        pointer(
            x: xOfF(latest.flushedUpTo), color: InspectorDesign.accent,
            label: latest.flushedUpTo == latest.cutUpTo ? "flushed · cut" : "flushed",
            preferredRow: 0)
        if latest.cutUpTo != latest.flushedUpTo {
            pointer(x: xOfF(latest.cutUpTo), color: .primary, label: "cut", preferredRow: 1)
        }
        pointer(
            x: xOfF(latest.frontier), color: .secondary, label: "frontier −1.04 s",
            preferredRow: 1)
    }

    /// Vertical marker line + triangle + label, laid out over two label
    /// rows: preferred row, else the other row, else shifted right.
    private mutating func pointer(x: CGFloat, color: Color, label: String, preferredRow: Int) {
        context.stroke(vertical(x: x, from: 14, to: yPtrEnd), with: .color(color), lineWidth: 1.4)
        var triangle = Path()
        triangle.move(to: CGPoint(x: x - 4, y: yPtrEnd + 5))
        triangle.addLine(to: CGPoint(x: x + 4, y: yPtrEnd + 5))
        triangle.addLine(to: CGPoint(x: x, y: yPtrEnd))
        triangle.closeSubpath()
        context.fill(triangle, with: .color(color))

        let resolved = context.resolve(
            Text(label)
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(color))
        let textSize = resolved.measure(in: CGSize(width: 200, height: 20))
        var labelX = min(max(x - textSize.width / 2, 4), size.width - textSize.width - 4)
        var row = preferredRow
        func fits(_ candidateRow: Int, _ candidateX: CGFloat) -> Bool {
            !labelRows[candidateRow].contains {
                candidateX < $0.upperBound + 8 && candidateX + textSize.width > $0.lowerBound - 8
            }
        }
        if !fits(row, labelX) {
            if fits(1 - row, labelX) {
                row = 1 - row
            } else {
                for interval in labelRows[row].sorted(by: { $0.lowerBound < $1.lowerBound })
                where labelX < interval.upperBound + 8
                    && labelX + textSize.width > interval.lowerBound - 8 {
                    labelX = interval.upperBound + 8
                }
                labelX = min(labelX, size.width - textSize.width - 2)
            }
        }
        labelRows[row].append(labelX...(labelX + textSize.width))
        context.draw(
            resolved,
            at: CGPoint(x: labelX + textSize.width / 2, y: yPtrEnd + 14 + CGFloat(row) * 11))
    }

    private func drawLeftFade() {
        context.fill(
            Path(CGRect(x: 0, y: 0, width: 46, height: size.height)),
            with: .linearGradient(
                Gradient(colors: [InspectorDesign.well, InspectorDesign.well.opacity(0)]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 46, y: 0)))
    }

    private func regionLabel(_ text: String, x: CGFloat, y: CGFloat) {
        let resolved = context.resolve(
            Text(text)
                .font(.system(size: 9))
                .foregroundStyle(InspectorDesign.faintInk))
        let measured = resolved.measure(in: CGSize(width: 200, height: 20))
        context.draw(resolved, at: CGPoint(x: x + measured.width / 2, y: y))
    }

    private func vertical(x: CGFloat, from y1: CGFloat, to y2: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: x, y: y1))
            path.addLine(to: CGPoint(x: x, y: y2))
        }
    }
}
