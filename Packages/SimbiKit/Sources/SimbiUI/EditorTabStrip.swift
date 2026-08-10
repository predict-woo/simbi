import SwiftUI

/// Which document the editor pane shows (AI Notes spec §4).
enum EditorTab: Hashable {
    case aiNotes
    case myNotes
}

/// Editorial text tabs: quiet labels, an accent underline that slides to
/// the active one. Deliberately not a segmented control (spec §4).
struct EditorTabStrip: View {
    @Binding var selected: EditorTab
    let showRegenerate: Bool
    let regenerateEnabled: Bool
    let isWorking: Bool
    let regenerateHelp: String
    let onRegenerate: () -> Void

    @Namespace private var underline

    var body: some View {
        HStack(spacing: Design.paneInset) {
            tab("AI Notes", .aiNotes)
            tab("My Notes", .myNotes)
            Spacer()
            // Always in the layout, hidden when not applicable: an appearing
            // button would grow the row and visibly shift the tabs. Meta-tier
            // icon + compact inset keep its height at the labels' height.
            Button(action: onRegenerate) {
                Image(systemName: "arrow.clockwise")
                    .font(.meta)
                    .foregroundStyle(
                        isWorking ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
                    )
                    .modifier(PulseEffect(active: isWorking))
            }
            .buttonStyle(HoverCircleButtonStyle(inset: Design.iconGap))
            .disabled(!showRegenerate || !regenerateEnabled || isWorking)
            .opacity(showRegenerate ? 1 : 0)
            .accessibilityHidden(!showRegenerate)
            .help(showRegenerate ? regenerateHelp : "")
        }
        .padding(.horizontal, Design.paneInset)
        .padding(.vertical, Design.stripPadding)
    }

    private func tab(_ title: String, _ value: EditorTab) -> some View {
        Button {
            withAnimation(Design.Anim.standard) { selected = value }
        } label: {
            Text(title)
                .font(selected == value ? .body.weight(.semibold) : .body)
                .foregroundStyle(selected == value ? .primary : .secondary)
                .padding(.vertical, Design.innerGap)
                .overlay(alignment: .bottom) {
                    if selected == value {
                        Capsule()
                            .fill(.tint)
                            .frame(height: Design.tabUnderlineHeight)
                            .matchedGeometryEffect(id: "underline", in: underline)
                    }
                }
        }
        .buttonStyle(.plain)
        .hoverFill(
            RoundedRectangle(cornerRadius: Design.Radius.badge), enabled: selected != value)
    }
}
