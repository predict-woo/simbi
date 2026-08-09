import Foundation
import Testing

@testable import SimbiKit

@Suite("TimestampLink")
struct TimestampLinkTests {
    @Test("parses m:ss and h:mm:ss")
    func parses() {
        #expect(TimestampLink.parse("12:34") == 754)
        #expect(TimestampLink.parse("0:05") == 5)
        #expect(TimestampLink.parse("1:02:33") == 3753)
        #expect(TimestampLink.parse("00:00") == 0)
    }

    @Test("rejects non-timestamps")
    func rejects() {
        #expect(TimestampLink.parse("12:71") == nil)  // seconds >= 60
        #expect(TimestampLink.parse("1:62:00") == nil)  // minutes >= 60 with hours
        #expect(TimestampLink.parse("::") == nil)
        #expect(TimestampLink.parse("") == nil)
        #expect(TimestampLink.parse("notes") == nil)
        #expect(TimestampLink.parse("1:2:3:4") == nil)
        #expect(TimestampLink.parse("-1:00") == nil)
        #expect(TimestampLink.parse("1:-2") == nil)
    }

    @Test("renders round-trip")
    func renders() {
        #expect(TimestampLink.render(754) == "12:34")
        #expect(TimestampLink.render(5) == "0:05")
        #expect(TimestampLink.render(3753) == "1:02:33")
        #expect(TimestampLink.render(0) == "0:00")
        for value: TimeInterval in [0, 5, 59, 60, 754, 3599, 3600, 3753, 7325] {
            #expect(TimestampLink.parse(TimestampLink.render(value)) == value)
        }
    }

    @Test("cue lookup: containing, nearest below, first, empty")
    func cueLookup() {
        let entries: [VTTEntry] = [
            .sessionStart(n: 1, wallClock: Date(timeIntervalSince1970: 0), offset: 0),
            .cue(index: 1, start: 10, end: 15, speaker: "A", text: "one", continuation: false),
            .gap(start: 15, end: 30),
            .cue(index: 2, start: 30, end: 40, speaker: "B", text: "two", continuation: false),
        ]
        #expect(TimestampLink.cueEntryIndex(for: 12, in: entries) == 1)  // containing
        #expect(TimestampLink.cueEntryIndex(for: 20, in: entries) == 1)  // nearest below
        #expect(TimestampLink.cueEntryIndex(for: 99, in: entries) == 3)  // after all: last
        #expect(TimestampLink.cueEntryIndex(for: 3, in: entries) == 1)  // before all: first cue
        #expect(TimestampLink.cueEntryIndex(for: 5, in: []) == nil)
        #expect(
            TimestampLink.cueEntryIndex(
                for: 5,
                in: [.sessionStart(n: 1, wallClock: Date(timeIntervalSince1970: 0), offset: 0)])
                == nil)  // entries but no cues
    }
}
