import Foundation
import Testing

@testable import CodexKit

@Suite("TurnOverrides")
struct TurnOverridesTests {
    @Test("model and effort land in turn params only when set")
    func applyOverrides() {
        var params: [String: any Sendable] = ["threadId": "t1"]
        TurnOverrides.apply(model: "gpt-5.6-sol", effort: "high", to: &params)
        #expect(params["model"] as? String == "gpt-5.6-sol")
        #expect(params["effort"] as? String == "high")

        var untouched: [String: any Sendable] = ["threadId": "t1"]
        TurnOverrides.apply(model: nil, effort: nil, to: &untouched)
        #expect(untouched["model"] == nil)
        #expect(untouched["effort"] == nil)

        // Effort applies to the thread's default model too.
        var effortOnly: [String: any Sendable] = [:]
        TurnOverrides.apply(model: nil, effort: "low", to: &effortOnly)
        #expect(effortOnly["model"] == nil)
        #expect(effortOnly["effort"] as? String == "low")
    }
}
