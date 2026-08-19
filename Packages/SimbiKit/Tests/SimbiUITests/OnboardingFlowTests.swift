import Testing

@testable import SimbiUI

@Suite struct OnboardingFlowTests {
    @Test func stepsRunInPresentationOrder() {
        var flow = OnboardingFlow()
        flow.gates = .init(
            micGranted: true, systemAudioGranted: true,
            codexConnected: true, modelsReady: true)
        var visited: [OnboardingStep] = [flow.step]
        while flow.advance() { visited.append(flow.step) }
        #expect(visited == OnboardingStep.allCases)
    }

    @Test func permissionsGateBlocksUntilBothGranted() {
        var flow = OnboardingFlow()
        flow.advance()  // welcome -> folder
        flow.advance()  // folder -> permissions
        #expect(flow.step == .permissions)
        #expect(!flow.canAdvance())
        flow.gates.micGranted = true
        #expect(!flow.canAdvance())
        flow.gates.systemAudioGranted = true
        #expect(flow.canAdvance())
    }

    @Test func codexAndDownloadGate() {
        var flow = OnboardingFlow()
        flow.gates = .init(micGranted: true, systemAudioGranted: true)
        flow.advance()
        flow.advance()
        flow.advance()  // -> codex
        #expect(flow.step == .codex && !flow.canAdvance())
        flow.gates.codexConnected = true
        flow.advance()  // -> agents
        flow.advance()  // -> download
        #expect(flow.step == .download && !flow.canAdvance())
        flow.gates.modelsReady = true
        #expect(flow.canAdvance())
    }

    @Test func backStopsAtWelcomeAndFinalHasNoAdvance() {
        var flow = OnboardingFlow()
        let backFromWelcome = flow.goBack()
        #expect(!backFromWelcome)
        flow.gates = .init(
            micGranted: true, systemAudioGranted: true,
            codexConnected: true, modelsReady: true)
        while flow.advance() {}
        #expect(flow.step == .star && flow.isFinal)
        let advanceFromStar = flow.advance()
        #expect(!advanceFromStar)
        let backFromStar = flow.goBack()
        #expect(backFromStar)
        #expect(flow.step == .download)
    }

    @Test func agentDefaultsFollowAccountUsageTier() {
        let goOrLower: [String?] = [nil, "unknown", "free", "go"]
        for plan in goOrLower {
            let choice = OnboardingModel.defaultChoice(for: plan)
            #expect(choice.model == "gpt-5.6-luna" && choice.effort == "medium")
        }

        for plan in ["plus", "team", "self_serve_business_prolite", "business", "enterprise", "edu"] {
            let choice = OnboardingModel.defaultChoice(for: plan)
            #expect(choice.model == "gpt-5.6-luna" && choice.effort == "high")
        }

        for plan in [
            "prolite", "pro", "self_serve_business_usage_based", "ent26",
            "enterprise_cbp_automation", "enterprise_cbp_usage_based",
        ] {
            let choice = OnboardingModel.defaultChoice(for: plan)
            #expect(choice.model == "gpt-5.6-sol" && choice.effort == "high")
        }
    }
}
