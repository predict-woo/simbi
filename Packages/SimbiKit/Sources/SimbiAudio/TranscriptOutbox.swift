import Foundation
import SimbiKit

/// Transcription backend. M2 ships the stub; M3 replaces it with the real
/// `backend-api/transcribe` uploader (same protocol, same queueing).
public protocol Transcriber: Sendable {
    /// Returns the transcription text for one encoded WebM/Opus segment.
    func transcribe(webmFile: URL) async throws -> String
}

/// M2 stub transcriber (SPEC.md §8: "stub transcriber"). Always succeeds.
public struct StubTranscriber: Transcriber {
    public init() {}

    public func transcribe(webmFile: URL) async throws -> String {
        "[transcription arrives in M3]"
    }
}

/// The single writer for `transcript.vtt` (guide §9.1): an ordered queue of
/// entries created synchronously by the pipeline in note-timeline order.
/// NOTE entries are ready immediately; cues become ready when their
/// transcription reaches a terminal state. The head is appended as soon as
/// it is ready, so the file is always valid WebVTT and cues appear strictly
/// in timestamp order regardless of completion order.
///
/// Not Sendable: owned by and confined to the pipeline actor, so entry
/// creation is synchronous and order is by construction.
public final class TranscriptOutbox {
    private enum Slot {
        case ready(VTTEntry)
        case pendingCue(
            index: Int, start: TimeInterval, end: TimeInterval, speaker: String,
            continuation: Bool, text: String?)

        var isReady: Bool {
            switch self {
            case .ready: return true
            case .pendingCue(_, _, _, _, _, let text): return text != nil
            }
        }
    }

    private var queue: [Slot] = []
    private let fileURL: URL
    private let noteName: String

    public init(fileURL: URL, noteName: String) {
        self.fileURL = fileURL
        self.noteName = noteName
    }

    /// Enqueues an immediately-ready NOTE entry (session/gap).
    public func append(_ entry: VTTEntry) throws {
        queue.append(.ready(entry))
        try drain()
    }

    /// Reserves the ordering slot for a flushed cue (§6.3 step 8).
    public func reserveCue(
        index: Int, start: TimeInterval, end: TimeInterval, speaker: String,
        continuation: Bool
    ) {
        queue.append(
            .pendingCue(
                index: index, start: start, end: end, speaker: speaker,
                continuation: continuation, text: nil))
    }

    /// Marks a reserved cue terminal (transcription text or `[inaudible]`).
    public func fulfillCue(index: Int, text: String) throws {
        for (i, slot) in queue.enumerated() {
            if case .pendingCue(index, let start, let end, let speaker, let continuation, nil) =
                slot
            {
                queue[i] = .pendingCue(
                    index: index, start: start, end: end, speaker: speaker,
                    continuation: continuation, text: text)
                break
            }
        }
        try drain()
    }

    /// True when no reserved cue is still awaiting its text.
    public var isDrained: Bool { queue.isEmpty }

    private func drain() throws {
        while let head = queue.first, head.isReady {
            queue.removeFirst()
            let entry: VTTEntry
            switch head {
            case .ready(let e):
                entry = e
            case .pendingCue(let index, let start, let end, let speaker, let continuation, let text):
                entry = .cue(
                    index: index, start: start, end: end, speaker: speaker,
                    text: text ?? "[inaudible]", continuation: continuation)
            }
            try appendToFile(VTT.render(entry))
        }
    }

    private func appendToFile(_ block: String) throws {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try VTT.header(noteName: noteName).write(to: fileURL, atomically: true, encoding: .utf8)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        // One write per entry: the file is valid WebVTT after every append.
        try handle.write(contentsOf: Data(block.utf8))
    }
}
