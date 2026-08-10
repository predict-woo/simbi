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

/// Toolbar-like icon button: quiet at rest, circular highlight on
/// hover, a deeper fill while pressed. Stock styles can't produce the
/// toolbar hover treatment in content views, so the hover state is
/// tracked explicitly.
struct HoverCircleButtonStyle: ButtonStyle {
    /// Hover-circle padding around the icon. The default suits toolbar-tier
    /// buttons; compact contexts (the editor tab strip) pass `Design.iconGap`
    /// so the button's height matches neighboring text rows.
    var inset: CGFloat = Design.stripPadding

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(inset)
            .contentShape(Circle())
            .background {
                Circle()
                    .fill(
                        configuration.isPressed
                            ? Color.pressFill
                            : isHovered ? Color.hoverFill : Color.clear)
            }
            .onHover { isHovered = $0 }
            .animation(Design.Anim.quick, value: isHovered)
    }
}

/// Hover fill for non-button interactive surfaces (menus, tap-to-play
/// rows): fills `shape` with `hoverFill` while hovered, optionally
/// bleeding past the bounds like the transcript's active-cue
/// highlight. Suppressed while disabled or when `enabled` is false.
private struct HoverFillModifier<S: Shape>: ViewModifier {
    let shape: S
    var horizontalBleed: CGFloat = 0
    var verticalBleed: CGFloat = 0
    var enabled = true
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background {
                if isHovered && isEnabled && enabled {
                    shape
                        .fill(Color.hoverFill)
                        .padding(.horizontal, -horizontalBleed)
                        .padding(.vertical, -verticalBleed)
                }
            }
            .onHover { isHovered = $0 }
            .animation(Design.Anim.quick, value: isHovered)
    }
}

extension View {
    /// Hover highlight for interactive surfaces that aren't Buttons.
    func hoverFill<S: Shape>(
        _ shape: S,
        horizontalBleed: CGFloat = 0,
        verticalBleed: CGFloat = 0,
        enabled: Bool = true
    ) -> some View {
        modifier(
            HoverFillModifier(
                shape: shape, horizontalBleed: horizontalBleed,
                verticalBleed: verticalBleed, enabled: enabled))
    }
}
