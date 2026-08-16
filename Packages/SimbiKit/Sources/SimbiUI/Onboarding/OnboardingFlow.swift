/// Wizard steps in presentation order
/// (docs/superpowers/specs/2026-08-17-onboarding-wizard-design.md).
enum OnboardingStep: Int, CaseIterable, Equatable {
    case welcome, folder, permissions, codex, agents, download, star
}

/// Pure step machine: ordering, gating, and back/forward. All external
/// facts arrive through `Gates`; no I/O, no UI, so the wizard's rules are
/// testable headless.
struct OnboardingFlow: Equatable {
    /// External conditions the hard gates read.
    struct Gates: Equatable {
        var micGranted = false
        var systemAudioGranted = false
        var codexConnected = false
        var modelsReady = false

        init(
            micGranted: Bool = false, systemAudioGranted: Bool = false,
            codexConnected: Bool = false, modelsReady: Bool = false
        ) {
            self.micGranted = micGranted
            self.systemAudioGranted = systemAudioGranted
            self.codexConnected = codexConnected
            self.modelsReady = modelsReady
        }
    }

    private(set) var step: OnboardingStep = .welcome
    var gates = Gates()

    /// True on the star step, where Finish replaces Continue.
    var isFinal: Bool { step == .star }

    /// Whether Continue is enabled on the current step.
    func canAdvance() -> Bool {
        switch step {
        case .welcome, .folder, .agents: true
        case .permissions: gates.micGranted && gates.systemAudioGranted
        case .codex: gates.codexConnected
        case .download: gates.modelsReady
        case .star: false
        }
    }

    /// Move to the next step if `canAdvance()`. Returns whether it moved.
    @discardableResult
    mutating func advance() -> Bool {
        guard canAdvance(), let next = OnboardingStep(rawValue: step.rawValue + 1) else {
            return false
        }
        step = next
        return true
    }

    /// Move to the previous step; welcome has no back. Returns whether it moved.
    @discardableResult
    mutating func goBack() -> Bool {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return false }
        step = previous
        return true
    }
}
