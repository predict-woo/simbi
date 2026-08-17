import AppKit
import SimbiKit
import SwiftUI

/// Player bar: play/pause, scrubber, position/duration readout. Shown
/// whenever the note has audio and isn't recording (SPEC.md §6).
struct PlaybackBar: View {
    let playback: PlaybackController
    let noteFolderURL: URL
    /// Non-nil while the user drags the scrubber; committed on release.
    @State private var scrubPosition: TimeInterval?
    /// True for a beat after a successful copy (checkmark feedback).
    @State private var copiedTranscript = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                playback.togglePlayPause()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 14)
            }
            .buttonStyle(HoverCircleButtonStyle())
            .help(playback.isPlaying ? "Pause" : "Play")
            Text(Design.time(scrubPosition ?? playback.position))
                .font(.metaMono)
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { scrubPosition ?? min(playback.position, playback.duration) },
                    set: { scrubPosition = $0 }
                ),
                in: 0...max(playback.duration, 0.01)
            ) { editing in
                if !editing, let target = scrubPosition {
                    playback.seek(to: target)
                    scrubPosition = nil
                }
            }
            .controlSize(.small)
            Text(Design.time(playback.duration))
                .font(.metaMono)
                .foregroundStyle(.tertiary)
            Button {
                copyTranscript()
            } label: {
                Image(systemName: copiedTranscript ? "checkmark" : "doc.on.doc")
                    .frame(width: 14)
            }
            .buttonStyle(HoverCircleButtonStyle())
            .help("Copy transcript")
            .disabled(!FileManager.default.fileExists(atPath: transcriptURL.path))
        }
        .padding(.horizontal, Design.paneInset)
        .padding(.vertical, Design.stripPadding)
        .onAppear { playback.refreshDuration() }
    }

    private var transcriptURL: URL {
        VTT.fileURL(noteFolder: noteFolderURL)
    }

    /// Reads transcript.vtt from disk at click time (the file is the
    /// source of truth, so this includes any fixer edits).
    private func copyTranscript() {
        guard let text = try? String(contentsOf: transcriptURL, encoding: .utf8) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copiedTranscript = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copiedTranscript = false
        }
    }
}
