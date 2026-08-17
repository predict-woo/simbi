import Foundation
import Testing

@testable import SimbiKit

@Suite("NoteRecordingState forward compatibility")
struct NoteRecordingStateCompatTests {
    @Test("state files with unknown keys (e.g. retired fields) still decode")
    func unknownKeysAreTolerated() throws {
        // chatThreadId and attempts-style extras stand in for any field a
        // past or future version persisted that this build doesn't know.
        let stored = """
            {
              "nextCueIndex": 7,
              "fixerThreadId": "thr_1",
              "chatThreadId": "thr_42",
              "someFutureField": {"nested": true}
            }
            """
        let state = try JSONDecoder().decode(
            NoteRecordingState.self, from: Data(stored.utf8))
        #expect(state.nextCueIndex == 7)
        #expect(state.fixerThreadId == "thr_1")
        #expect(state.conversions.isEmpty)
    }
}
