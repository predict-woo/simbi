import CodexKit
import Foundation
import SimbiKit

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

    /// One fixer edit to merge into the live file: a new payload (speaker +
    /// text) for an existing cue. Timestamps and numbering are never
    /// editable — they stay whatever the live file says.
    public struct CueEdit: Equatable, Sendable {
        public let index: Int
        public let speaker: String
        public let text: String

        public init(index: Int, speaker: String, text: String) {
            self.index = index
            self.speaker = speaker
            self.text = text
        }
    }

    /// Rewrites the payload line of each edited cue in place. Runs on the
    /// pipeline actor like every other write, so it is serialized against
    /// appends — the whole point of the fixer merge (the fixer never
    /// touches this file). Everything except the edited payload lines —
    /// numbering, timestamps, NOTE blocks, unknown blocks — is preserved
    /// byte-for-byte, and nothing is written unless the result re-parses.
    public func applyEdits(_ edits: [CueEdit]) throws {
        guard !edits.isEmpty, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let byIndex = Dictionary(edits.map { ($0.index, $0) }) { _, last in last }
        let lines = try String(contentsOf: fileURL, encoding: .utf8)
            .components(separatedBy: "\n")

        var out: [String] = []
        var i = 0
        var changed = false
        while i < lines.count {
            // A cue block: bare integer line, then a timing line.
            if let cueIndex = Int(lines[i]), i + 1 < lines.count,
                lines[i + 1].contains(" --> "), let edit = byIndex[cueIndex]
            {
                out.append(lines[i])
                out.append(lines[i + 1])
                out.append(
                    VTT.voicePayload(
                        speaker: Self.sanitizeSpeaker(edit.speaker),
                        text: Self.sanitizeText(edit.text)))
                i += 2
                while i < lines.count, !lines[i].isEmpty { i += 1 }
                changed = true
            } else {
                out.append(lines[i])
                i += 1
            }
        }
        guard changed else { return }
        let updated = out.joined(separator: "\n")
        guard (try? VTTParser.parse(updated)) != nil else {
            Log.recording.error("fixer merge produced unparseable VTT; edits discarded")
            return
        }
        try updated.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Payload text must stay one line and must not contain the cue-timing
    /// arrow (WebVTT forbids it in cue text).
    static func sanitizeText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "-->", with: "→")
            .trimmingCharacters(in: .whitespaces)
    }

    /// A `>` inside the voice tag would end it early.
    static func sanitizeSpeaker(_ speaker: String) -> String {
        speaker.replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private func drain() throws {
        while let head = queue.first, head.isReady {
            queue.removeFirst()
            let entry: VTTEntry
            switch head {
            case .ready(let readyEntry):
                entry = readyEntry
            case .pendingCue(let index, let start, let end, let speaker, let continuation, let text):
                entry = .cue(
                    index: index, start: start, end: end, speaker: speaker,
                    text: text ?? "[inaudible]", continuation: continuation)
            }
            try appendToFile(VTT.render(entry))
        }
    }

    /// The per-cue diff between the fixer's snapshot ("before" — what the
    /// pipeline copied into the worktree at ping time) and the fixer's
    /// edited copy ("after"). Only changed payloads of cues present in BOTH
    /// survive: deletions, additions, renumbering, and timestamp changes
    /// are ignored by construction, and an unparseable copy yields nothing
    /// — the prompt rules the fixer used to be trusted with are enforced
    /// here instead.
    public static func fixerEdits(before: String, after: String) -> [CueEdit] {
        guard before != after,
            let beforeDocument = try? VTTParser.parse(before),
            let afterDocument = try? VTTParser.parse(after)
        else { return [] }
        var beforeCues: [Int: (speaker: String, text: String)] = [:]
        for case .cue(let index, _, _, let speaker, let text, _) in beforeDocument.entries {
            beforeCues[index] = (speaker, text)
        }
        var edits: [CueEdit] = []
        for case .cue(let index, _, _, let speaker, let text, _) in afterDocument.entries {
            if let old = beforeCues[index], old.speaker != speaker || old.text != text {
                edits.append(CueEdit(index: index, speaker: speaker, text: text))
            }
        }
        return edits
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
