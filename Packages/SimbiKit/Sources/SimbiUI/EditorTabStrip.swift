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
            if showRegenerate {
                Button(action: onRegenerate) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(
                            isWorking ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
                        )
                        .modifier(PulseEffect(active: isWorking))
                }
                .buttonStyle(HoverCircleButtonStyle())
                .disabled(!regenerateEnabled || isWorking)
                .help(regenerateHelp)
            }
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
