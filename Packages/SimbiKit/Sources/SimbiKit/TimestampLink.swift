import Foundation

/// The `[[m:ss]]` / `[[h:mm:ss]]` note-timeline timestamps AI notes cite
/// (AI Notes spec §6). The wiki-link TARGET (text between the brackets) is
/// what parse/render speak; the editor supplies it via its link callback.
public enum TimestampLink {
    /// Strict: 2 or 3 numeric components, seconds < 60, minutes < 60 when
    /// hours are present. Anything else is a page-name wiki link, not a
    /// timestamp, and must not seek.
    public static func parse(_ target: String) -> TimeInterval? {
        let parts = target.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let values = parts.map { part -> Int? in
            guard !part.isEmpty, part.allSatisfy(\.isNumber) else { return nil }
            return Int(part)
        }
        guard let numbers = values as? [Int] else { return nil }
        let seconds = numbers[numbers.count - 1]
        let minutes = numbers[numbers.count - 2]
        guard seconds < 60 else { return nil }
        if numbers.count == 3 {
            guard minutes < 60 else { return nil }
            return TimeInterval(numbers[0] * 3600 + minutes * 60 + seconds)
        }
        return TimeInterval(minutes * 60 + seconds)
    }

    /// Inverse of `parse`: "12:34" below an hour, "1:02:33" above.
    public static func render(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// The transcript row a citation lands on: the cue containing the
    /// time, else the last cue starting before it, else the first cue.
    /// Indices are positions in `entries` (what the transcript renders),
    /// not VTT cue numbers.
    public static func cueEntryIndex(
        for seconds: TimeInterval, in entries: [VTTEntry]
    ) -> Int? {
        var lastBefore: Int?
        var firstCue: Int?
        for (index, entry) in entries.enumerated() {
            guard case .cue(_, let start, let end, _, _, _) = entry else { continue }
            if firstCue == nil { firstCue = index }
            if seconds >= start, seconds < end { return index }
            if start <= seconds { lastBefore = index }
        }
        return lastBefore ?? firstCue
    }
}
