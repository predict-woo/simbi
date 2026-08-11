import Foundation
import Testing

@testable import CodexKit

/// Fixtures captured from a live `codex app-server` probe (2026-08-12);
/// see docs/superpowers/specs/2026-08-12-codex-status-window-design.md.
@Suite("CodexAccountStatus")
struct CodexAccountStatusTests {
    private let accountJSON = Data(
        #"""
        {
         "account": {"type": "chatgpt", "email": "me@example.com", "planType": "pro"},
         "requiresOpenaiAuth": true
        }
        """#.utf8)

    private let rateLimitsJSON = Data(
        #"""
        {
         "rateLimits": {
          "limitId": "codex", "limitName": null,
          "primary": {"usedPercent": 2, "windowDurationMins": 10080, "resetsAt": 1787024413}
         },
         "rateLimitsByLimitId": {
          "codex": {
           "limitId": "codex", "limitName": null,
           "primary": {"usedPercent": 2, "windowDurationMins": 10080, "resetsAt": 1787024413}
          },
          "codex_bengalfox": {
           "limitId": "codex_bengalfox", "limitName": "GPT-5.3-Codex-Spark",
           "primary": {"usedPercent": 37.5, "windowDurationMins": 300, "resetsAt": 1787076173}
          }
         },
         "rateLimitResetCredits": {"availableCount": 1, "credits": []}
        }
        """#.utf8)

    @Test("parses account email and plan")
    func parsesAccount() throws {
        let account = CodexAccountStatus.parseAccount(accountJSON)
        #expect(account?.email == "me@example.com")
        #expect(account?.planType == "pro")
    }

    @Test("parses limits from rateLimitsByLimitId, codex first")
    func parsesLimits() throws {
        let parsed = CodexAccountStatus.parseRateLimits(rateLimitsJSON)
        #expect(parsed.limits.count == 2)
        #expect(parsed.limits[0].id == "codex")
        #expect(parsed.limits[0].displayName == "Codex")
        #expect(parsed.limits[0].usedPercent == 2)
        #expect(parsed.limits[0].windowDurationMins == 10080)
        #expect(parsed.limits[0].resetsAt == Date(timeIntervalSince1970: 1_787_024_413))
        #expect(parsed.limits[1].displayName == "GPT-5.3-Codex-Spark")
        #expect(parsed.limits[1].usedPercent == 37.5)
    }

    @Test("counts available reset credits")
    func resetCredits() throws {
        #expect(CodexAccountStatus.parseRateLimits(rateLimitsJSON).resetCreditsAvailable == 1)
    }

    @Test("falls back to the top-level rateLimits when the by-id map is absent")
    func fallbackToTopLevel() throws {
        let data = Data(
            #"""
            {"rateLimits": {"limitId": "codex", "limitName": null,
              "primary": {"usedPercent": 80, "windowDurationMins": 10080, "resetsAt": 1}}}
            """#.utf8)
        let parsed = CodexAccountStatus.parseRateLimits(data)
        #expect(parsed.limits.count == 1)
        #expect(parsed.limits[0].usedPercent == 80)
        #expect(parsed.resetCreditsAvailable == 0)
    }

    @Test("missing fields degrade to nil or empty, never crash")
    func missingFields() throws {
        #expect(CodexAccountStatus.parseAccount(Data("{}".utf8)) == nil)
        let parsed = CodexAccountStatus.parseRateLimits(Data("{}".utf8))
        #expect(parsed.limits.isEmpty)
        #expect(parsed.resetCreditsAvailable == 0)
    }

    @Test("window duration labels: weekly, 5-hour, fallback hours")
    func windowLabels() throws {
        func window(_ mins: Int?) -> CodexAccountStatus.RateLimitWindow {
            CodexAccountStatus.RateLimitWindow(
                id: "x", displayName: "X", usedPercent: 0,
                windowDurationMins: mins, resetsAt: nil)
        }
        #expect(window(10080).windowLabel == "weekly")
        #expect(window(300).windowLabel == "5-hour")
        #expect(window(120).windowLabel == "2-hour")
        #expect(window(nil).windowLabel == nil)
    }
}
