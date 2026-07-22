import SimbiAudio
import SwiftUI

/// The per-note Pipeline Inspector window (spec
/// docs/superpowers/specs/2026-07-22-pipeline-inspector-design.md):
/// a live view over the recording pipeline's internals. Styled like the
/// rest of the app — system appearance, `Design` type scale, shared
/// section labels and speaker chips. The app shell declares the matching
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
            .onAppear { model.attach(recorder) }
            .onDisappear { model.detach() }
    }
}

/// Window-local styling helpers. Chrome and ink come from the system so
/// the window follows the app's appearance; only what the Canvas needs as
/// concrete `Color`s lives here, plus the slot→speaker mapping shared
/// with the transcript.
enum InspectorDesign {
    /// Recessed content wells (timeline, event log) — the text-view
    /// surface, so lane colors read on it in both appearances.
    static let well = Color(nsColor: .textBackgroundColor)
    static let line = Color(nsColor: .separatorColor)
    /// Card surface for the model boxes, rule meters and flush cards.
    static let card = Color.primary.opacity(0.045)
    /// Tertiary ink as a concrete color — Canvas text can't take the
    /// hierarchical `.tertiary` style.
    static let faintInk = Color(nsColor: .tertiaryLabelColor)
    /// Staging + rule accent: the app's one warning hue (`StatusBanner`).
    static let accent = Color.orange

    /// Seconds per 80 ms grid frame.
    static let frameSeconds = Double(CutConstants.frameSamples) / 16000

    static func speaker(_ slot: Int?) -> Color {
        guard let slot else { return Color.primary.opacity(0.12) }
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
    }

    private var waitingView: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("Start recording to inspect the pipeline")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("The inspector attaches the moment audio starts flowing.")
                .font(.meta)
                .foregroundStyle(.tertiary)
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
                    StatusBanner(
                        message:
                            "Session ended — showing the last pipeline state; "
                            + "cue text may still arrive.",
                        icon: "stop.circle")
                }
                statusRow(latest: state.latest)
                sectionDivider
                InspectorFrontEndRow(state: state)
                    .padding(.horizontal, Design.paneInset)
                    .padding(.vertical, 10)
                sectionDivider
                sectionHeader(
                    "Record stream",
                    hint: "buffers & pointers — released 1.04 s behind live (§4.1)")
                InspectorTimeline(model: model)
                    .frame(height: 175)
                    .padding(.horizontal, Design.paneInset)
                    .padding(.bottom, 10)
                sectionDivider
                sectionHeader(
                    "Cut engine",
                    hint: "order per record: R1 → R3 → R6 → R4 → R5, R2 inside every cut")
                InspectorMetersRow(state: state)
                    .padding(.horizontal, Design.paneInset)
                    .padding(.bottom, 10)
                sectionDivider
                sectionHeader("Flushes → transcription", hint: "≤ 2 concurrent uploads")
                InspectorFlushLane(state: state)
                    .padding(.bottom, 8)
                sectionDivider
                sectionHeader("Event log", hint: nil)
                InspectorEventLog(state: state)
                    .padding(.horizontal, Design.paneInset)
                    .padding(.bottom, 12)
            }
        }
    }

    private var sectionDivider: some View {
        Rectangle().fill(InspectorDesign.line).frame(height: 1)
    }

    private func statusRow(latest: InspectorUpdate?) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.phase == .live ? Color.red : InspectorDesign.faintInk)
                    .frame(width: 8, height: 8)
                Text(Design.time(model.elapsed))
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
            }
            if let latest {
                Text("\(latest.samplesFed.formatted()) samples fed · frame grid 80 ms")
                    .font(.meta)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Spacer()
            Text("live view of the real engine — nothing here is sampled or simulated")
                .font(.meta)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Design.paneInset)
        .padding(.vertical, 8)
    }

    private func sectionHeader(_ title: String, hint: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            SectionLabel(title: title)
            if let hint {
                Text(hint)
                    .font(.meta)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, Design.paneInset)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}
