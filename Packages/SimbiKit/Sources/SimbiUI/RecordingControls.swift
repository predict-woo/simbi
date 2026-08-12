import SimbiKit
import SwiftUI

/// Recording controls for the transcript pane, split out of `NoteView`
/// in the 2026-08-10 floating-bar redesign: `RecordingBar` floats over
/// the transcript's bottom edge, `RecordingStatusStrip` sits above it
/// only while there is live status to show.

/// Floating capture bar: Record/Stop, elapsed timer, and the source
/// menu in a glass capsule the transcript scrolls under. Reads like a
/// recorder: the red stop glyph carries the live state, monospaced timer.
struct RecordingBar: View {
    @Bindable var recorder: RecordingController

    private var isRecording: Bool { recorder.status == .recording || Flags.uiPreview }

    var body: some View {
        HStack(spacing: Design.rowGap) {
            recordButton
            elapsedTimer
            sourcesMenu
        }
        // Concentric end caps: an end element whose inset from the cap
        // equals its vertical slack has its hover shape centered on the
        // cap's circle center. The record button's hover circle is the
        // tallest child (slack = stripPadding); the sources menu's hover
        // capsule is shorter, its slack lands on rowGap.
        .padding(.leading, Design.stripPadding)
        .padding(.trailing, Design.rowGap)
        .padding(.vertical, Design.stripPadding)
        .floatingChrome(in: Capsule())
        // Outer margin so the capsule keeps daylight from the pane edges
        // even at the transcript's minimum width — flush edges would stop
        // reading as "floating."
        .padding(.horizontal, Design.rowGap)
        .padding(.bottom, Design.rowGap)
    }

    // Idle: red dot (ready). Recording: filled red Stop — red means
    // "live", not "will be live". Icon-only: the capsule already reads
    // as a recorder, so the glyph carries the state and the tooltip
    // keeps the words. 18pt is a one-off display glyph
    // (docs/design-system.md).
    private var recordButton: some View {
        Button {
            recorder.toggle()
        } label: {
            Group {
                if isRecording {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(Color.statusLive)
                } else {
                    switch recorder.status {
                    case .idle, .failed:
                        Image(systemName: "record.circle.fill")
                            .foregroundStyle(Color.statusLive)
                    case .preparing:
                        Image(systemName: "record.circle")
                    case .recording, .stopping:
                        Image(systemName: "stop.circle")
                    }
                }
            }
            .font(.system(size: 18))
        }
        .buttonStyle(HoverCircleButtonStyle())
        .disabled(recorder.status == .preparing || recorder.status == .stopping)
        .help(recordHelp)
        .accessibilityLabel(recordHelp)
    }

    /// The old button labels, demoted to tooltip + accessibility text.
    private var recordHelp: String {
        if isRecording { return "Stop" }
        switch recorder.status {
        case .idle, .failed:
            return recorder.hasRecording ? "Resume" : "Record"
        case .preparing:
            return "Preparing…"
        case .recording, .stopping:
            return "Stopping…"
        }
    }

    private var elapsedTimer: some View {
        Text(Design.time(recorder.elapsed))
            .font(.body.monospacedDigit())
            .foregroundStyle(isRecording ? .primary : .secondary)
    }

    // Source menu (SPEC.md §3.1: mic device and system audio are chosen
    // independently; either can be off, never both). Locked while
    // recording — the mix can't change mid-session. Quiet icons: the
    // symbols carry the state so they don't compete with Record.
    private var sourcesMenu: some View {
        Menu {
            Section("Microphone") {
                micOption("Off", selected: !recorder.micEnabled) {
                    recorder.micEnabled = false
                }
                // Turning the mic off with system audio off would leave
                // nothing to record.
                .disabled(!recorder.systemAudioEnabled)
                micOption(
                    "System default",
                    selected: recorder.micEnabled && recorder.micDeviceUID == nil
                ) {
                    recorder.micEnabled = true
                    recorder.micDeviceUID = nil
                }
                let mics = recorder.availableMicrophones
                ForEach(mics) { mic in
                    micOption(
                        mic.name,
                        selected: recorder.micEnabled && recorder.micDeviceUID == mic.id
                    ) {
                        recorder.micEnabled = true
                        recorder.micDeviceUID = mic.id
                    }
                }
                // Keep a saved-but-unplugged mic visible so the selection
                // isn't silently misrepresented.
                if recorder.micEnabled, let uid = recorder.micDeviceUID,
                    !mics.contains(where: { $0.id == uid })
                {
                    micOption("Saved microphone (not connected)", selected: true) {}
                }
            }
            Section("System audio") {
                Toggle("Capture system audio", isOn: $recorder.systemAudioEnabled)
                    // Same guard from the other side: last source stays on.
                    .disabled(!recorder.micEnabled)
            }
        } label: {
            HStack(spacing: Design.iconGap) {
                Image(systemName: recorder.micEnabled ? "mic.fill" : "mic.slash")
                    .foregroundStyle(
                        recorder.micEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Image(
                    systemName: recorder.systemAudioEnabled ? "speaker.wave.2" : "speaker.slash"
                )
                .foregroundStyle(
                    recorder.systemAudioEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(Design.footerStripPadding)
        .hoverFill(Capsule())
        .disabled(recorder.status != .idle)
        .help(sourcesSummary)
    }

    private func micOption(
        _ title: String, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        // Toggle rows get the native menu checkmark on the active option.
        Toggle(title, isOn: .init(get: { selected }, set: { _ in action() }))
    }

    /// Tooltip summary, e.g. "Recording: MacBook Pro Microphone + system audio".
    private var sourcesSummary: String {
        var parts: [String] = []
        if recorder.micEnabled {
            let name =
                recorder.availableMicrophones
                .first { $0.id == recorder.micDeviceUID }?.name
            parts.append(name ?? "default microphone")
        }
        if recorder.systemAudioEnabled {
            parts.append("system audio")
        }
        return "Recording: " + parts.joined(separator: " + ")
    }
}

/// Live status above the transcript: tentative speaker, failure text,
/// fixer and inspector affordances. Renders nothing at all (no strip,
/// no divider) when idle without a failure — the transcript then gets
/// the full pane height.
struct RecordingStatusStrip: View {
    @Bindable var recorder: RecordingController
    @Environment(\.openWindow) private var openWindow

    private var isRecording: Bool { recorder.status == .recording || Flags.uiPreview }

    /// Live-speaker slot; the preview flag pins one so the chip is visible.
    private var tentativeSpeaker: Int? {
        Flags.uiPreview ? 1 : recorder.tentativeSpeaker
    }

    private var isFailed: Bool {
        if case .failed = recorder.status { return true }
        return false
    }

    private var hasContent: Bool {
        isRecording || isFailed || Flags.uiPreview
    }

    var body: some View {
        if hasContent {
            HStack(spacing: Design.rowGap) {
                statusItems
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, Design.paneInset)
            .padding(.vertical, Design.stripPadding)
            Divider()
        }
    }

    @ViewBuilder private var statusItems: some View {
        if isRecording {
            liveIndicator
        }
        if case .failed(let message) = recorder.status {
            Text(message)
                .font(.meta)
                .foregroundStyle(Color.statusLive)
                .lineLimit(2)
        }

        // Fixer status/activity (SPEC.md §5.2): sparkles pulse while a pass
        // runs; clicking opens the live thread viewer. Recording-only: outside
        // a session the icon was the strip's lone occupant, and keeping the
        // strip up for it wasn't worth the row.
        if (isRecording && (recorder.hasFixerThread || recorder.fixerActivity.status != .off))
            || Flags.uiPreview
        {
            fixerButton
        }

        // Pipeline Inspector: live view of the recording pipeline's
        // internals. Only meaningful mid-session, so recording-only.
        if isRecording {
            inspectorButton
        }
    }

    private var fixerButton: some View {
        Button {
            recorder.openFixerViewer()
        } label: {
            Image(systemName: "sparkles")
                .foregroundStyle(
                    recorder.fixerActivity.status == .working
                        ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
                )
                .modifier(PulseEffect(active: recorder.fixerActivity.status == .working))
        }
        .buttonStyle(HoverCircleButtonStyle())
        .help(fixerHelp)
    }

    private var inspectorButton: some View {
        Button {
            // One inspector window per note; reopening focuses it.
            openWindow(id: PipelineInspectorWindow.windowId, value: recorder.noteFolderURL)
        } label: {
            Image(systemName: "waveform.path.ecg")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(HoverCircleButtonStyle())
        .help("Pipeline Inspector: watch the recording pipeline work")
    }

    private var fixerHelp: String {
        switch recorder.fixerActivity.status {
        case .off: "Transcript fixer"
        case .waiting: "Transcript fixer: waiting for new cues"
        case .working: "Transcript fixer: reviewing"
        case .done: "Transcript fixer: done"
        }
    }

    /// Who the diarizer currently hears, in the same chip language as the
    /// transcript rows — strip and transcript read as one system.
    @ViewBuilder private var liveIndicator: some View {
        if let slot = tentativeSpeaker {
            let name = "Speaker \(slot + 1)"
            HStack(spacing: Design.iconGap) {
                Image(systemName: "waveform")
                    .font(.meta)
                SpeakerChip(name: name)
            }
            .foregroundStyle(Design.speakerColor(name))
            .padding(.horizontal, 8)
            .padding(.vertical, Design.innerGap)
            .background(Design.speakerTint(name), in: Capsule())
        } else {
            Text("Listening…")
                .font(.meta)
                .foregroundStyle(.tertiary)
        }
    }
}

extension View {
    /// Bottom-bar availability fork: `safeAreaBar` (native scroll-edge
    /// blur under the bar) where the OS has it; `safeAreaInset` further
    /// back — identical layout semantics (content scrolls under, the
    /// last cue can always scroll clear), just without the edge blur.
    @ViewBuilder func bottomFloatingBar(
        @ViewBuilder _ bar: () -> some View
    ) -> some View {
        if #available(macOS 26.0, *) {
            self.safeAreaBar(edge: .bottom) { bar() }
        } else {
            self.safeAreaInset(edge: .bottom) { bar() }
        }
    }
}
