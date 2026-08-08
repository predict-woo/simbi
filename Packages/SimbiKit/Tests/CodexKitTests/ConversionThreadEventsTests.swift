import Foundation
import SimbiKit
import Testing

@testable import CodexKit

@Suite("ConversionThreadEvents")
struct ConversionThreadEventsTests {
    private let conversions: [String: NoteRecordingState.FileConversion] = [
        "deck.pptx": .init(status: .done, threadId: "thread-1"),
        "notes.pdf": .init(status: .converting, threadId: "thread-2"),
    ]

    private func params(threadId: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["threadId": threadId])
    }

    @Test("turn/started on a known idle thread begins an external turn")
    func startedBegins() {
        let effect = ConversionThreadEvents.effect(
            method: "turn/started", params: params(threadId: "thread-1"),
            conversions: conversions, activeJobs: [])
        #expect(effect == .turnBegan(file: "deck.pptx"))
    }

    @Test("turn/completed on a known idle thread ends the external turn")
    func completedEnds() {
        let effect = ConversionThreadEvents.effect(
            method: "turn/completed", params: params(threadId: "thread-1"),
            conversions: conversions, activeJobs: [])
        #expect(effect == .turnEnded(file: "deck.pptx"))
    }

    @Test("threads with an app-owned job in flight are the job's business")
    func activeJobIgnored() {
        let effect = ConversionThreadEvents.effect(
            method: "turn/started", params: params(threadId: "thread-2"),
            conversions: conversions, activeJobs: ["notes.pdf"])
        #expect(effect == nil)
    }

    @Test("unknown threads, other methods, and junk params are ignored")
    func noise() {
        #expect(
            ConversionThreadEvents.effect(
                method: "turn/started", params: params(threadId: "thread-9"),
                conversions: conversions, activeJobs: []) == nil)
        #expect(
            ConversionThreadEvents.effect(
                method: "item/completed", params: params(threadId: "thread-1"),
                conversions: conversions, activeJobs: []) == nil)
        #expect(
            ConversionThreadEvents.effect(
                method: "turn/started", params: Data("not json".utf8),
                conversions: conversions, activeJobs: []) == nil)
    }
}
