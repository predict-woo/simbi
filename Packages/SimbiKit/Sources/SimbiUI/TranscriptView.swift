import AppKit
import Foundation
import Observation
import SimbiKit
import SwiftUI

/// Watches and re-parses `transcript.vtt` on every file change (SPEC.md §4).
/// The parser is strict: on a malformed file the last good render is kept
/// and a "temporarily invalid" badge shows.
@MainActor
@Observable
final class TranscriptModel {
    private(set) var document: VTTDocument?
    private(set) var isInvalid = false

    private let fileURL: URL
    private var watcher: FileTreeWatcher?

    init(noteFolderURL: URL) {
        self.fileURL = noteFolderURL.appending(path: "transcript.vtt")
        refresh()
        // Watch the note folder (the file may not exist yet at note-open).
        // When the model deallocs, the watcher releases the continuation,
        // the stream finishes, and the task ends — same pattern as
        // FileTreeModel.
        let (events, continuation) = AsyncStream.makeStream(of: Void.self)
        watcher = FileTreeWatcher(url: noteFolderURL) {
            continuation.yield()
        }
        Task { [weak self] in
            for await _ in events {
                self?.refresh()
            }
        }
    }

    func refresh() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            document = nil
            isInvalid = false
            return
        }
        do {
            document = try VTTParser.parse(text)
            isInvalid = false
        } catch {
            // Keep the last good render (a mid-append read can be partial).
            isInvalid = document != nil
        }
    }
}

/// Renders the live transcript: cues with per-speaker colors, gap and
/// session markers, click-to-seek playback and speaker rename (SPEC.md §6).
struct TranscriptView: View {
    let model: TranscriptModel
    /// Current playback position: the cue containing it is highlighted
    /// and kept scrolled into view (nil = not playing).
    var playbackPosition: TimeInterval?
    /// Click on a cue (timestamp or text) seeks playback there (nil =
    /// disabled, e.g. while recording).
    var onSeek: ((TimeInterval) -> Void)?
    /// Rename a speaker across the whole file (old name, new name).
    var onRenameSpeaker: ((String, String) -> Void)?

    @State private var renameTarget: RenameTarget?
    @State private var renameText = ""
    @FocusState private var renameFieldFocused: Bool

    /// Keyed by ROW, not just name — the same speaker appears on many
    /// rows, and a name-keyed binding would anchor the popover on the
    /// last row that matches instead of the one that was clicked.
    private struct RenameTarget: Identifiable {
        let name: String
        let row: Int
        var id: String { "\(row):\(name)" }
    }

    /// Kept as the public color entry point (RecordingHeader uses it);
    /// routed through the shared design-system palette.
    static func color(forSpeaker name: String) -> Color {
        Design.speakerColor(name)
    }

    var body: some View {
        Group {
            if let document = model.document, !document.entries.isEmpty {
                let activeRow = activeRow(in: document.entries)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Design.rowGap) {
                            ForEach(Array(document.entries.enumerated()), id: \.offset) { index, entry in
                                entryView(entry, row: index, isActive: index == activeRow)
                                    .id(index)
                            }
                        }
                        .padding(Design.paneInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Follow playback: keep the highlighted cue in view.
                    .onChange(of: activeRow) { _, row in
                        guard let row else { return }
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(row, anchor: .center)
                        }
                    }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if model.isInvalid {
                            StatusBanner(
                                message:
                                    "Transcript is being rewritten — showing the last good version.")
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Recording",
                    systemImage: "waveform",
                    description: Text("Press Record to start. The transcript appears here live.")
                )
            }
        }
    }

    /// The cue containing the playback position, if any (positions inside
    /// gaps or session markers highlight nothing).
    private func activeRow(in entries: [VTTEntry]) -> Int? {
        guard let position = playbackPosition else { return nil }
        for (index, entry) in entries.enumerated() {
            if case .cue(_, let start, let end, _, _, _) = entry,
                position >= start, position < end {
                return index
            }
        }
        return nil
    }

    @ViewBuilder
    private func entryView(_ entry: VTTEntry, row: Int, isActive: Bool) -> some View {
        switch entry {
        case .cue(_, let start, _, let speaker, let text, let continuation):
            VStack(alignment: .leading, spacing: Design.innerGap) {
                HStack(spacing: 8) {
                    Button {
                        renameText = speaker
                        renameTarget = RenameTarget(name: speaker, row: row)
                    } label: {
                        SpeakerChip(name: speaker)
                    }
                    .buttonStyle(.plain)
                    .disabled(onRenameSpeaker == nil)
                    .help("Rename this speaker across the transcript")
                    .popover(
                        item: Binding(
                            get: { renameTarget?.row == row ? renameTarget : nil },
                            set: { if $0 == nil { renameTarget = nil } })
                    ) { target in
                        renamePopover(target: target)
                    }
                    Button {
                        onSeek?(start)
                    } label: {
                        Text(Design.time(start))
                            .font(.meta.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(onSeek == nil)
                    .help("Play from here")
                    if continuation {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.quaternary)
                            .help("Continues across a session break")
                    }
                }
                // Click a sentence to play from it. Not selectable text:
                // on macOS the selection view consumes every click, so
                // tap-to-play and drag-to-select can't coexist — the
                // context menu keeps the text copyable instead.
                Text(text)
                    .font(.body)
                    .lineSpacing(2.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { onSeek?(start) }
                    .help(onSeek != nil ? "Play from this line" : "")
                    .contextMenu {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                    }
            }
            // Playing-now highlight in the cue's speaker color, bleeding
            // slightly past the row bounds without affecting layout.
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Design.speakerColor(speaker).opacity(0.12))
                        .padding(.horizontal, -8)
                        .padding(.vertical, -4)
                }
            }
        case .gap(let start, let end):
            Text("\(Int((end - start).rounded())) s of silence")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        case .sessionStart(let n, let wallClock, _):
            HStack(spacing: 10) {
                hairline
                Text("Session \(n) · \(wallClock.formatted(date: .omitted, time: .shortened))")
                    .font(.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                hairline
            }
            .padding(.vertical, 4)
        case .sessionEnd:
            EmptyView()
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    private func renamePopover(target: RenameTarget) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename \(target.name) everywhere")
                .font(.system(size: 12, weight: .semibold))
            TextField("Name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .focused($renameFieldFocused)
                .onSubmit { submitRename(target: target) }
                .onAppear { renameFieldFocused = true }
                // Reset on close: a stale `true` would make the next
                // presentation's `= true` a no-op and leave focus outside
                // the popover (found by the M7 UI verification worker).
                .onDisappear { renameFieldFocused = false }
            HStack {
                Spacer()
                Button("Cancel") { renameTarget = nil }
                Button("Rename") { submitRename(target: target) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        renameText.trimmingCharacters(in: .whitespaces).isEmpty
                            || renameText == target.name)
            }
        }
        .padding(12)
        // The popover is its own focus scope; make the field its default
        // focus in addition to the onAppear set (initial-focus timing on
        // popover child windows is racy otherwise).
        .defaultFocus($renameFieldFocused, true)
    }

    private func submitRename(target: RenameTarget) {
        let name = renameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != target.name else { return }
        onRenameSpeaker?(target.name, name)
        renameTarget = nil
    }
}
