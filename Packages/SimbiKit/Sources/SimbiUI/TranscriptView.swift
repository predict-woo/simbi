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
/// session markers (SPEC.md §6; playback/seek arrives in M7).
struct TranscriptView: View {
    let model: TranscriptModel

    static let speakerColors: [Color] = [.blue, .green, .orange, .purple]

    static func color(forSpeaker name: String) -> Color {
        // "Speaker N" gets slot N-1's color; renamed speakers hash.
        if name.hasPrefix("Speaker "), let n = Int(name.dropFirst(8)), (1...4).contains(n) {
            return speakerColors[n - 1]
        }
        return speakerColors[abs(name.hashValue) % speakerColors.count]
    }

    var body: some View {
        Group {
            if let document = model.document, !document.entries.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.isInvalid {
                            Label("Transcript temporarily invalid", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        ForEach(Array(document.entries.enumerated()), id: \.offset) { _, entry in
                            entryView(entry)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    "No Recording",
                    systemImage: "waveform",
                    description: Text("Press Record to start; the transcript appears here live.")
                )
            }
        }
    }

    @ViewBuilder
    private func entryView(_ entry: VTTEntry) -> some View {
        switch entry {
        case .cue(_, let start, _, let speaker, let text, let continuation):
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(speaker)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Self.color(forSpeaker: speaker))
                    Text(VTT.timestamp(start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if continuation {
                        Text("cont.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
            }
        case .gap(let start, let end):
            Label(
                "silence · \(String(format: "%.1f", end - start)) s",
                systemImage: "zzz"
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
        case .sessionStart(let n, let wallClock, _):
            HStack {
                VStack { Divider() }
                Text("Session \(n) · \(wallClock.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                VStack { Divider() }
            }
        case .sessionEnd:
            EmptyView()
        }
    }
}
