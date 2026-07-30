import SwiftUI

/// Cross-cutting view recipes (docs/design-system.md § Components).

/// The bordered-card recipe: `cardFill` surface with a `hairline` stroke.
private struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                Color.cardFill,
                in: RoundedRectangle(cornerRadius: Design.Radius.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Design.Radius.card)
                    .stroke(Color.hairline)
            )
    }
}

extension View {
    /// Card chrome: inspector panels, setup card, drop targets.
    func card() -> some View {
        modifier(CardModifier())
    }
}

/// Slow opacity pulse for live indicators — the recording dot and the
/// fixer's working sparkles.
struct PulseEffect: ViewModifier {
    var active = true
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? 0.3 : 1)
            .animation(
                active ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                value: dimmed
            )
            .onAppear { dimmed = active }
            .onChange(of: active) { _, nowActive in
                dimmed = nowActive
            }
    }
}
