import Foundation

/// WebVTT emission and strict parsing for `transcript.vtt`
/// (SPEC.md §3.4, algorithm guide §9.3).
///
/// The file is append-only: the header is written once, then each entry is
/// one atomic append. NOTE payloads never contain `-->` (WebVTT forbids it
/// inside comment blocks), hence the `key=value` forms.

public enum VTTEntry: Equatable, Sendable {
    case cue(
        index: Int, start: TimeInterval, end: TimeInterval, speaker: String,
        text: String, continuation: Bool)
    case gap(start: TimeInterval, end: TimeInterval)
    case sessionStart(n: Int, wallClock: Date, offset: TimeInterval)
    case sessionEnd(n: Int, wallClock: Date, offset: TimeInterval)
}

public enum VTT {
    /// A note's transcript file name — also used for the fixer worktree's
    /// copy, which mirrors the live file's name.
    public static let fileName = "transcript.vtt"

    /// A note's transcript file (SPEC.md §2.2 note-folder layout).
    public static func fileURL(noteFolder: URL) -> URL {
        noteFolder.appending(path: fileName)
    }

    /// True when the note's transcript parses and contains at least one
    /// cue — the "recording produced content" gate the auto-summary and
    /// auto-title triggers share.
    public static func transcriptHasCues(noteFolder: URL) -> Bool {
        guard
            let text = try? String(contentsOf: fileURL(noteFolder: noteFolder), encoding: .utf8),
            let document = try? VTTParser.parse(text)
        else { return false }
        return document.entries.contains {
            if case .cue = $0 { return true }
            return false
        }
    }

    /// `HH:MM:SS.mmm`, milliseconds rounded (guide §1).
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let totalMs = Int((seconds * 1000).rounded())
        let ms = totalMs % 1000
        let secs = (totalMs / 1000) % 60
        let mins = (totalMs / 60000) % 60
        let hours = totalMs / 3_600_000
        return String(format: "%02d:%02d:%02d.%03d", hours, mins, secs, ms)
    }

    static func parseTimestamp(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":")
        guard parts.count == 3, let hours = Int(parts[0]), let mins = Int(parts[1]) else { return nil }
        let secParts = parts[2].split(separator: ".")
        guard secParts.count == 2, let secs = Int(secParts[0]), let ms = Int(secParts[1]),
            secParts[1].count == 3
        else { return nil }
        return TimeInterval(hours * 3600 + mins * 60 + secs) + TimeInterval(ms) / 1000
    }

    /// Wall clocks render with the local UTC offset (SPEC.md §3.4:
    /// `2026-07-15T13:40:00+09:00`). ISO8601DateFormatter is documented
    /// thread-safe.
    nonisolated(unsafe) static let wallClockFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()

    /// The file header, written once at note creation.
    public static func header(noteName: String) -> String {
        "WEBVTT\n\nNOTE simbi note=\"\(noteName)\"\n"
    }

    /// The `<v Name>` opening tag — the one wire shape speaker renames
    /// string-replace on.
    public static func voiceTag(speaker: String) -> String {
        "<v \(speaker)>"
    }

    /// A cue's payload line: voice tag + text, exactly as the parser and
    /// the fixer merge expect it.
    public static func voicePayload(speaker: String, text: String) -> String {
        voiceTag(speaker: speaker) + text
    }

    /// Renders one entry as an appendable block (leading blank line).
    public static func render(_ entry: VTTEntry) -> String {
        switch entry {
        case .cue(let index, let start, let end, let speaker, let text, let continuation):
            let marker = continuation ? "\nNOTE continuation\n" : ""
            return marker
                + "\n\(index)\n\(timestamp(start)) --> \(timestamp(end))\n"
                + voicePayload(speaker: speaker, text: text) + "\n"
        case .gap(let start, let end):
            return "\nNOTE gap start=\(timestamp(start)) end=\(timestamp(end))\n"
        case .sessionStart(let n, let wall, let offset):
            return
                "\nNOTE session \(n) start=\(wallClockFormatter.string(from: wall)) offset=\(timestamp(offset))\n"
        case .sessionEnd(let n, let wall, let offset):
            return
                "\nNOTE session \(n) end=\(wallClockFormatter.string(from: wall)) offset=\(timestamp(offset))\n"
        }
    }
}

/// A parsed transcript document.
public struct VTTDocument: Equatable, Sendable {
    public var entries: [VTTEntry]

    public init(entries: [VTTEntry] = []) {
        self.entries = entries
    }
}

/// Strict parser (SPEC.md §4): any malformed block throws, so the renderer
/// keeps its last good state and shows the "temporarily invalid" badge.
public enum VTTParseError: Error, Equatable {
    case missingHeader
    case malformedBlock(String)
}

public enum VTTParser {
    public static func parse(_ text: String) throws -> VTTDocument {
        var document = VTTDocument()
        let blocks = text.split(separator: "\n\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.isEmpty }
        guard blocks.first == "WEBVTT" else { throw VTTParseError.missingHeader }

        var pendingContinuation = false
        for block in blocks.dropFirst() {
            let lines = block.split(separator: "\n").map(String.init)
            if lines[0] == "NOTE continuation" {
                pendingContinuation = true
                continue
            }
            if lines[0].hasPrefix("NOTE ") || lines[0] == "NOTE" {
                if let entry = try parseNote(block: block, lines: lines) {
                    document.entries.append(entry)
                }
                continue
            }
            document.entries.append(
                try parseCue(lines: lines, continuation: pendingContinuation))
            pendingContinuation = false
        }
        return document
    }

    private static func parseCue(lines: [String], continuation: Bool) throws -> VTTEntry {
        guard lines.count >= 3, let index = Int(lines[0]) else {
            throw VTTParseError.malformedBlock(lines.joined(separator: "\n"))
        }
        let timing = lines[1].components(separatedBy: " --> ")
        guard timing.count == 2,
            let start = VTT.parseTimestamp(timing[0]),
            let end = VTT.parseTimestamp(timing[1]),
            end >= start
        else {
            throw VTTParseError.malformedBlock(lines.joined(separator: "\n"))
        }
        let payload = lines[2...].joined(separator: "\n")
        guard payload.hasPrefix("<v "), let close = payload.firstIndex(of: ">") else {
            throw VTTParseError.malformedBlock(payload)
        }
        let speaker = String(payload[payload.index(payload.startIndex, offsetBy: 3)..<close])
        let text = String(payload[payload.index(after: close)...])
        return .cue(
            index: index, start: start, end: end, speaker: speaker, text: text,
            continuation: continuation)
    }

    private static func parseNote(
        block: String, lines: [String]
    ) throws -> VTTEntry? {
        let head = lines[0]
        if head.hasPrefix("NOTE simbi") {
            // The note=… header identifies the file; nothing consumes it
            // when parsing (writers emit it via VTT.header).
            return nil
        }
        if head.hasPrefix("NOTE gap ") {
            let fields = keyValues(of: head.dropFirst("NOTE gap ".count))
            guard let start = fields["start"].flatMap(VTT.parseTimestamp),
                let end = fields["end"].flatMap(VTT.parseTimestamp)
            else { throw VTTParseError.malformedBlock(block) }
            return .gap(start: start, end: end)
        }
        if head.hasPrefix("NOTE session ") {
            let rest = head.dropFirst("NOTE session ".count)
            let parts = rest.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let n = Int(parts[0]) else {
                throw VTTParseError.malformedBlock(block)
            }
            let fields = keyValues(of: parts[1])
            guard let offset = fields["offset"].flatMap(VTT.parseTimestamp) else {
                throw VTTParseError.malformedBlock(block)
            }
            if let startText = fields["start"] {
                guard let wall = VTT.wallClockFormatter.date(from: startText) else {
                    throw VTTParseError.malformedBlock(block)
                }
                return .sessionStart(n: n, wallClock: wall, offset: offset)
            }
            if let endText = fields["end"] {
                guard let wall = VTT.wallClockFormatter.date(from: endText) else {
                    throw VTTParseError.malformedBlock(block)
                }
                return .sessionEnd(n: n, wallClock: wall, offset: offset)
            }
            throw VTTParseError.malformedBlock(block)
        }
        // Unknown NOTE (e.g. fixer commentary): legal WebVTT, ignored.
        return nil
    }

    private static func keyValues(of text: Substring) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: " ") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                result[String(kv[0])] = String(kv[1])
            }
        }
        return result
    }
}
