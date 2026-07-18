import AppKit
import MarkdownEngine
import MarkdownEngineCodeBlocks
import MarkdownEngineLatex
import SwiftUI

/// The note editor: MarkdownEngine's TextKit 2 view with live styling
/// (SPEC.md §1). Replaces the M0 STTextView + Neon source editor —
/// markdown renders in place (headings, lists, tables, task checkboxes)
/// while staying editable, with highlighted code blocks and LaTeX.
public struct MarkdownEditor: View {
    @Binding var text: String
    /// Scopes the undo stack and editor state; pass something stable and
    /// unique per note so switching notes never mixes histories.
    let documentId: String

    public init(text: Binding<String>, documentId: String = "default") {
        self._text = text
        self.documentId = documentId
    }

    /// One engine configuration for the whole app. Built once: the
    /// highlighter and LaTeX bridges cache rendered output internally,
    /// so sharing them across notes keeps re-renders cheap.
    private static let configuration: MarkdownEditorConfiguration = {
        var config = MarkdownEditorConfiguration()
        config.services.syntaxHighlighter = HighlighterSwiftBridge()
        config.services.latex = SwiftMathBridge()
        config.extensions = [HighlightExtension(), StrikethroughExtension()]
        config.textInsets = TextInsets(horizontal: 24, vertical: 20)
        // The engine auto-pairs [ ( { but has no type-through of the closing
        // char, so typing literal markdown (`- [ ]`, `[text](url)`) leaves a
        // stray bracket behind. Notes are plain markdown — typed syntax must
        // land verbatim. (Found in the 2026-07-17 UI verification.)
        config.lists.autoClosePairsEnabled = false
        return config
    }()

    private static let placeholder = NSAttributedString(
        string: "Write your note…",
        attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor,
            .font: NSFont.systemFont(ofSize: Design.editorFontSize),
        ]
    )

    public var body: some View {
        NativeTextViewWrapper(
            text: $text,
            configuration: Self.configuration,
            fontSize: Design.editorFontSize,
            documentId: documentId,
            placeholder: Self.placeholder
        )
    }
}
