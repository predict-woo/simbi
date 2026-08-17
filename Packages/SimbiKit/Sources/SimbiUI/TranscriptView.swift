import AppKit
import CodexKit
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
        self.fileURL = VTT.fileURL(noteFolder: noteFolderURL)
        refresh()
        // Watch the note folder (the file may not exist yet at note-open).
        watcher = FileTreeWatcher.observing(url: noteFolderURL) { [weak self] in
            self?.refresh()
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

/// One externally requested "look here" flash (AI Notes spec §6): a fresh
/// id per request so citing the same cue twice still re-fires.
public struct CueFlash: Equatable {
    let row: Int
    let id: UUID

    public init(row: Int) {
        self.row = row
        self.id = UUID()
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
    /// Externally requested scroll-and-flash of one cue row (nil = none).
    var flash: CueFlash? = nil

    @State private var flashedRow: Int?
    @State private var renameTarget: RenameTarget?
    @State private var renameText = ""
    @FocusState private var renameFieldFocused: Bool

    /// Tail-following (SPEC.md §6): while the user is scrolled to the
    /// bottom, new cues keep the view pinned there; once they scroll up to
    /// read something, growth must not yank them away. Tracked with
    /// `scrollPosition(id:anchor:)` — the row currently at the viewport
    /// bottom. Two prior mechanisms failed here: scroll-geometry
    /// preferences go stale (macOS doesn't re-fire them during user
    /// scrolling → the view yanked), and per-row onAppear/onDisappear
    /// crashes outright (the LazyVStack cache reinserts rows during
    /// NSHostingView.layout, and AppearanceEffect.didReinsert then requests
    /// a constraint update mid-layout-pass — AppKit throws).
    @State private var bottomRow: Int?

    /// Keyed by ROW, not just name — the same speaker appears on many
    /// rows, and a name-keyed binding would anchor the popover on the
    /// last row that matches instead of the one that was clicked.
    private struct RenameTarget: Identifiable {
        let name: String
        let row: Int
        var id: String { "\(row):\(name)" }
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
                        .scrollTargetLayout()
                        .padding(Design.paneInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollPosition(id: $bottomRow, anchor: .bottom)
                    // Tail-follow: only when the PREVIOUS last row was at the
                    // viewport bottom (slack of one row for a partially
                    // visible tail) — a user who scrolled up to read an
                    // earlier segment is never yanked down. `bottomRow` is
                    // nil until the first scroll; that only matters once
                    // content overflows, which is exactly when following
                    // should wait for the user to reach the bottom.
                    .onChange(of: document.entries.count) { oldCount, newCount in
                        guard newCount > oldCount,
                            oldCount <= 1 || (bottomRow ?? -1) >= oldCount - 2
                        else { return }
                        bottomRow = newCount - 1
                    }
                    // Follow playback: keep the highlighted cue in view.
                    .onChange(of: activeRow) { _, row in
                        guard let row else { return }
                        withAnimation(Design.Anim.standard) {
                            proxy.scrollTo(row, anchor: .center)
                        }
                    }
                    // Citation flash: center the cited cue and tint it
                    // briefly. The clear timer is keyed to the flash id via
                    // .task(id:), so a newer flash (fresh CueFlash id even
                    // for the same row) cancels the old timer mid-sleep —
                    // Task.sleep throws on cancellation, so a superseded
                    // timer never reaches the clear line and can't cut the
                    // newer flash short.
                    .onChange(of: flash) { _, flash in
                        guard let flash else { return }
                        withAnimation(Design.Anim.standard) {
                            proxy.scrollTo(flash.row, anchor: .center)
                        }
                        flashedRow = flash.row
                    }
                    .task(id: flash) {
                        guard flash != nil else { return }
                        try? await Task.sleep(for: .seconds(1.5))
                        guard !Task.isCancelled else { return }
                        flashedRow = nil
                    }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if model.isInvalid {
                            StatusBanner(
                                message:
                                    "Transcript is being rewritten. Showing the last good version.")
                        }
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("No Recording", systemImage: "waveform")
                } description: {
                    VStack(spacing: Design.innerGap) {
                        Text("Press Record to capture the room")
                        Text("Simbi transcribes and labels each speaker as they talk.")
                        if CodexSetupModel.shared.state != .connected {
                            Text("Transcription needs the ChatGPT app. See the sidebar footer.")
                                .foregroundStyle(Color.statusWarning)
                        }
                    }
                }
            }
        }
    }

    /// The cue containing the playback position, if any (positions inside
    /// gaps or session markers highlight nothing).
    private func activeRow(in entries: [VTTEntry]) -> Int? {
        guard let position = playbackPosition else { return nil }
        for (index, entry) in entries.enumerated() {
            if case .cue(_, let start, let end, _, _, _) = entry,
                position >= start, position < end
            {
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
                            .font(.metaMono)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(onSeek == nil)
                    .help("Play from here")
                    if continuation {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.micro)
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
            .hoverFill(
                RoundedRectangle(cornerRadius: Design.Radius.row),
                horizontalBleed: 8, verticalBleed: 4,
                enabled: onSeek != nil
            )
            // Playing-now highlight in the cue's speaker color, bleeding
            // slightly past the row bounds without affecting layout.
            .background {
                if isActive || row == flashedRow {
                    RoundedRectangle(cornerRadius: Design.Radius.row)
                        .fill(Design.speakerTint(speaker))
                        .padding(.horizontal, -8)
                        .padding(.vertical, -4)
                }
            }
        case .gap(let start, let end):
            Text("\(Int((end - start).rounded())) s of silence")
                .font(.micro)
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

    /// Deliberately fainter than the shared `Hairline` — a session break
    /// is background texture, not a pane boundary (see the 2026-07-17
    /// redesign README on marker loudness).
    private var hairline: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    private func renamePopover(target: RenameTarget) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename \(target.name) everywhere")
                .font(.body.weight(.semibold))
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
