import Foundation
import Testing

@testable import SimbiUI

@Suite("TranscriptDrainWait")
struct TranscriptDrainWaitTests {
    @Test("already-drained outbox returns true without waiting out the bound")
    func alreadyDrained() async {
        let clock = ContinuousClock()
        let start = clock.now
        let drained = await TranscriptDrainWait.wait(
            timeout: .seconds(10), pollInterval: .milliseconds(1)
        ) { true }
        #expect(drained)
        #expect(clock.now - start < .seconds(5))
    }

    @Test("returns true as soon as a later poll sees the drain")
    func drainsDuringTheWait() async {
        let drain = SecondPollDrain()
        let drained = await TranscriptDrainWait.wait(
            timeout: .seconds(10), pollInterval: .zero
        ) { await drain.isDrained }
        #expect(drained)
    }

    @Test("a queue that never drains hits the bound and still completes")
    func boundExpires() async {
        let clock = ContinuousClock()
        let start = clock.now
        let drained = await TranscriptDrainWait.wait(
            timeout: .milliseconds(60), pollInterval: .milliseconds(10)
        ) { false }
        #expect(!drained)
        #expect(clock.now - start >= .milliseconds(60))
    }

    @Test("a zero bound with an undrained queue returns immediately")
    func zeroBound() async {
        let drained = await TranscriptDrainWait.wait(
            timeout: .zero, pollInterval: .milliseconds(10)
        ) { false }
        #expect(!drained)
    }
}

private actor SecondPollDrain {
    private var polls = 0

    var isDrained: Bool {
        polls += 1
        return polls == 2
    }
}
