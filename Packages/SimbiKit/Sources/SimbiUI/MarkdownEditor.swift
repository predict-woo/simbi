import AppKit
import STPluginNeon
import STTextView
import SwiftUI

/// The markdown source editor: STTextView with tree-sitter highlighting via
/// the Neon plugin (SPEC.md §1, validated in M0).
///
/// This is our own `NSViewRepresentable` rather than the stock
/// `STTextViewSwiftUI.TextView`: the stock wrapper re-applies the bound text
/// on every keystroke's binding round-trip, which resets the insertion point
/// and interleaves fast input (observed in M0 verification). Here the view
/// is the source of truth while editing — `updateNSView` only pushes the
/// binding into the view when it genuinely diverges (external load/reset),
/// never in response to the view's own edit events.
public struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String

    public init(text: Binding<String>) {
        self._text = text
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = STTextView.scrollableTextView()
        let textView = scrollView.documentView as! STTextView
        textView.text = text
        textView.isHorizontallyResizable = false  // wrap lines
        textView.highlightSelectedLine = true
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize + 1, weight: .regular)
        textView.textDelegate = context.coordinator
        textView.addPlugin(NeonPlugin(theme: .default, language: .markdown))
        context.coordinator.textView = textView
        return scrollView
    }

    /// Accept whatever size SwiftUI proposes. Without this, SwiftUI derives
    /// min/max sizes from the scroll view during the AppKit constraint pass,
    /// which (inside a split view) re-invalidates layout mid-pass and crashes
    /// with an NSInternalInconsistencyException.
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(
            width: proposal.width ?? nsView.frame.width,
            height: proposal.height ?? nsView.frame.height
        )
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? STTextView else { return }
        // Only external changes reach the view; edits made in the view are
        // already there (coordinator forwarded them to the binding).
        if !context.coordinator.isForwardingEdit, textView.text != text {
            textView.text = text
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    public final class Coordinator: NSObject, @preconcurrency STTextViewDelegate {
        var parent: MarkdownEditor
        weak var textView: STTextView?
        /// True while the binding update we trigger is being processed, so
        /// `updateNSView` never writes the text back mid-edit.
        private(set) var isForwardingEdit = false

        init(parent: MarkdownEditor) {
            self.parent = parent
        }

        public func textViewDidChangeText(_ notification: Notification) {
            guard let textView else { return }
            isForwardingEdit = true
            parent.text = textView.text ?? ""
            isForwardingEdit = false
        }
    }
}
