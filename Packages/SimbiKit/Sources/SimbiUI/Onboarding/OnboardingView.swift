import SwiftUI

/// The first-run wizard, rendered as the main window's entire content
/// until setup completes
/// (docs/superpowers/specs/2026-08-17-onboarding-wizard-design.md).
/// Layout follows the Whisky/TRex survey: title over subtitle, centered
/// content, fixed footer with progress dots and system-styled buttons.
struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    /// +1 advancing, -1 going back; mirrors the slide direction.
    @State private var direction: Int = 1

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                stepBody
                    .id(model.step)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: direction >= 0 ? .trailing : .leading)
                                .combined(with: .opacity),
                            removal: .move(edge: direction >= 0 ? .leading : .trailing)
                                .combined(with: .opacity)))
            }
            .frame(maxWidth: 560, maxHeight: .infinity)
            .padding(Design.paneInset)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Design.Anim.standard, value: model.step)
    }

    @ViewBuilder
    private var stepBody: some View {
        switch model.step {
        case .welcome: WelcomeStep()
        case .folder: FolderStep(model: model)
        case .permissions: PermissionsStep(model: model)
        case .codex: CodexStep(model: model)
        case .agents: AgentsStep(model: model)
        case .download: DownloadStep(model: model)
        case .star: StarStep(model: model)
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: Design.iconGap) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                    Circle()
                        .fill(step == model.step ? Color.primary : Color.trackFill)
                        .frame(width: Design.dotSize, height: Design.dotSize)
                }
            }
            .animation(Design.Anim.standard, value: model.step)
            Spacer()
            if model.step != .welcome {
                Button("Back") {
                    direction = -1
                    model.goBack()
                }
                .buttonStyle(.bordered)
            }
            if model.isFinal {
                Button("Finish") { model.finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(model.step == .welcome ? "Get Started" : "Continue") {
                    direction = 1
                    model.advance()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canContinue)
            }
        }
        .padding(Design.paneInset)
    }
}
