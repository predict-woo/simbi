import SimbiAudio
import SwiftUI

/// The per-note Pipeline Inspector window (spec
/// docs/superpowers/specs/2026-07-22-pipeline-inspector-design.md):
/// a live instrument panel over the recording pipeline's internals.
/// Deliberately dark in both app themes — it is a meter bridge, and it
/// matches the approved mockup. The app shell declares the matching
/// `WindowGroup(id: windowId, for: URL.self)` scene.
///
/// Companions: `PipelineInspectorTimeline.swift` (the canvas),
/// `PipelineInspectorPanels.swift` (front-end row, meters, flush lane, log).
public struct PipelineInspectorWindow: View {
    public static let windowId = "pipeline-inspector"

    private let recorder: RecordingController
    private let noteName: String
    @State private var model = PipelineInspectorModel()

    public init(noteFolderURL: URL) {
        self.recorder = RecordingController.shared(noteFolderURL: noteFolderURL)
        self.noteName = noteFolderURL.lastPathComponent
    }

    public var body: some View {
        PipelineInspectorView(model: model)
            .navigationTitle("Pipeline Inspector — \(noteName)")
            .preferredColorScheme(.dark)
            .onAppear { model.attach(recorder) }
            .onDisappear { model.detach() }
    }
}

/// Window-local HUD palette (not part of `Design` — this is instrument
/// chrome, used nowhere else in the app). Speaker colors do come from
/// `Design.speakerPalette` so identities match the transcript.
enum HUD {
    static let bg = Color(red: 0.043, green: 0.059, blue: 0.082)
    static let panel = Color(red: 0.071, green: 0.086, blue: 0.114)
    static let raised = Color(red: 0.098, green: 0.118, blue: 0.153)
    static let line = Color.white.opacity(0.08)
    static let ink = Color(red: 0.91, green: 0.93, blue: 0.96)
    static let ink2 = Color(red: 0.59, green: 0.64, blue: 0.69)
    static let ink3 = Color(red: 0.37, green: 0.42, blue: 0.47)
    static let amber = Color(red: 0.98, green: 0.70, blue: 0.10)
    static let live = Color(red: 0.88, green: 0.28, blue: 0.28)
    static let vadTick = Color(red: 0.73, green: 0.82, blue: 0.93)
    static let processingWash = Color(red: 0.59, green: 0.73, blue: 0.88).opacity(0.09)

    /// Seconds per 80 ms grid frame.
    static let frameSeconds = Double(CutConstants.frameSamples) / 16000

    static func speaker(_ slot: Int?) -> Color {
        guard let slot else { return Color.white.opacity(0.18) }
        return Design.speakerPalette[slot % Design.speakerPalette.count]
    }

    static func speakerName(_ slot: Int?) -> String {
        guard let slot else { return "—" }
        return "Speaker \(slot + 1)"
    }
}

struct PipelineInspectorView: View {
    let model: PipelineInspectorModel

    var body: some View {
        Group {
            if model.phase == .waiting {
                waitingView
            } else {
                liveView
            }
        }
        .frame(minWidth: 940, minHeight: 520)
        .background(HUD.bg)
    }

    private var waitingView: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 34))
                .foregroundStyle(HUD.ink3)
            Text("Start recording to inspect the pipeline")
                .font(.body)
                .foregroundStyle(HUD.ink2)
            Text("The inspector attaches the moment audio starts flowing.")
                .font(.meta)
                .foregroundStyle(HUD.ink3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var liveView: some View {
        // Anchor: sections below re-evaluate per structural update
        // (records/events/uploads), never per raw PCM batch.
        _ = model.summaryTick
        let state = model.state

        // Scrolls when the window is shorter than the panel — the sections
        // must never clip silently.
        return ScrollView {
            VStack(spacing: 0) {
                if model.phase == .ended {
                    sessionEndedBanner
                }
                statusRow(latest: state.latest)
                hudDivider
                InspectorFrontEndRow(state: state)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                hudDivider
                sectionHeader(
                    "ALIGNED RECORD STREAM — BUFFERS & POINTERS",
                    hint: "released 1.04 s behind live (§4.1)")
                InspectorTimeline(model: model)
                    .frame(height: 175)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                hudDivider
                sectionHeader(
                    "CUT ENGINE — WHAT EACH RULE IS WAITING FOR",
                    hint: "order per record: R1 → R3 → R6 → R4 → R5, R2 inside every cut")
                InspectorMetersRow(state: state)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                hudDivider
                sectionHeader("FLUSHES → TRANSCRIPTION", hint: "≤ 2 concurrent uploads")
                InspectorFlushLane(state: state)
                    .padding(.bottom, 8)
                hudDivider
                sectionHeader("EVENT LOG", hint: nil)
                InspectorEventLog(state: state)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
    }

    private var hudDivider: some View {
        Rectangle().fill(HUD.line).frame(height: 1)
    }

    private var sessionEndedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "stop.circle")
            Text("Session ended — last pipeline state shown; cue text may still arrive.")
        }
        .font(.meta)
        .foregroundStyle(HUD.amber)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(HUD.amber.opacity(0.1))
    }

    private func statusRow(latest: InspectorUpdate?) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.phase == .live ? HUD.live : HUD.ink3)
                    .frame(width: 8, height: 8)
                Text(Design.time(model.elapsed))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(HUD.ink)
            }
            if let latest {
                Text("\(latest.samplesFed.formatted()) samples fed · frame grid 80 ms")
                    .font(.meta)
                    .foregroundStyle(HUD.ink3)
            }
            Spacer()
            Text("live view of the real engine — nothing here is sampled or simulated")
                .font(.meta)
                .foregroundStyle(HUD.ink3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func sectionHeader(_ title: String, hint: String?) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .kerning(1.1)
                .foregroundStyle(HUD.ink3)
            if let hint {
                Text(hint)
                    .font(.meta)
                    .foregroundStyle(HUD.ink3.opacity(0.8))
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}
