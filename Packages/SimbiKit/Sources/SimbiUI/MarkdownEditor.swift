import AppKit
import MarkdownEngine
import MarkdownEngineCodeBlocks
import MarkdownEngineLatex
import SimbiKit
import SwiftUI

/// The note editor: MarkdownEngine's TextKit 2 view with live styling
/// (SPEC.md §1). Replaces the M0 STTextView + Neon source editor —
/// markdown renders in place (headings, lists, tables, task checkboxes)
/// while staying editable, with highlighted code blocks and LaTeX.
public struct MarkdownEditor: View {
    /// Which dialect the editor speaks. Notes are pure markdown; agent
    /// instruction files add the `{{ variable }}` token span — a `{{ }}`
    /// in a regular note must stay literal text.
    public enum Flavor {
        case note
        case instructions
    }

    @Binding var text: String
    /// Scopes the undo stack and editor state; pass something stable and
    /// unique per note so switching notes never mixes histories.
    let documentId: String
    let flavor: Flavor
    /// Wiki-link clicks deliver the link's target string (`[[12:34]]` →
    /// "12:34"); nil leaves clicks inert, as before.
    let onLinkClick: ((String) -> Void)?

    public init(
        text: Binding<String>, documentId: String = "default", flavor: Flavor = .note,
        onLinkClick: ((String) -> Void)? = nil
    ) {
        self._text = text
        self.documentId = documentId
        self.flavor = flavor
        self.onLinkClick = onLinkClick
    }

    /// One highlighter/LaTeX bridge pair for the whole app: both cache
    /// rendered output internally, so every editor (both flavors) sharing
    /// them keeps re-renders cheap.
    private static let sharedHighlighter = HighlighterSwiftBridge()
    private static let sharedLatex = SwiftMathBridge()

    private static func makeConfiguration(
        extraExtensions: [any MarkdownExtension] = []
    ) -> MarkdownEditorConfiguration {
        var config = MarkdownEditorConfiguration()
        config.services.syntaxHighlighter = sharedHighlighter
        config.services.latex = sharedLatex
        // Timestamp wiki links must resolve as existing: the styler only
        // attaches the clickable `.link` attribute (routing clicks to
        // `onLinkClick` → seek) when the resolver says so; unresolved names
        // render as dead links. The resolver's one call site is styling —
        // it never rewrites `[[12:34]]` into the `[[Name|<id>]]` storage
        // form (verified against the pinned engine, 2026-08-10).
        config.services.wikiLinks = TimestampWikiLinkResolver()
        config.extensions = [HighlightExtension(), StrikethroughExtension()] + extraExtensions
        config.textInsets = TextInsets(horizontal: Design.editorInset, vertical: 20)
        // The engine auto-pairs [ ( { but has no type-through of the closing
        // char, so typing literal markdown (`- [ ]`, `[text](url)`) leaves a
        // stray bracket behind. Notes are plain markdown — typed syntax must
        // land verbatim. (Found in the 2026-07-17 UI verification.)
        config.lists.autoClosePairsEnabled = false
        return config
    }

    private static let noteConfiguration = makeConfiguration()
    private static let instructionsConfiguration = makeConfiguration(
        extraExtensions: [TemplateVariableExtension()])

    /// Resolves timestamp-shaped wiki-link names ([[12:34]], [[1:02:33]])
    /// as existing so they read and click like real links; anything else
    /// stays unresolved (no note-linking feature yet, so other names render
    /// as dead links). The id is the display name itself: it is what the
    /// click handler receives and feeds to `TimestampLink.parse`.
    private struct TimestampWikiLinkResolver: WikiLinkResolver {
        func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? {
            guard TimestampLink.parse(displayName) != nil else { return nil }
            return WikiLinkResolution(id: displayName, exists: true)
        }
    }

    private var configuration: MarkdownEditorConfiguration {
        switch flavor {
        case .note: Self.noteConfiguration
        case .instructions: Self.instructionsConfiguration
        }
    }

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
            configuration: configuration,
            fontSize: Design.editorFontSize,
            documentId: documentId,
            onLinkClick: onLinkClick,
            placeholder: Self.placeholder
        )
    }
}

/// `{{ variable }}` placeholders in agent instruction files, rendered as
/// accent token chips (design-system § Color: `Design.variableInk`/
/// `variableTint`). The engine's generic marker behavior does the rest:
/// braces shrink away while the caret is outside — the chip reads as a
/// token — and reveal muted for editing when clicked into, like every
/// other live-styled construct. Content is opaque (a variable name is
/// not markdown) and purely syntactic: the span can't tell a real
/// variable from a typo, which is why the instructions editor footer
/// lists the file's supported names.
private struct TemplateVariableExtension: MarkdownExtension {
    var id: String { "simbi-variable" }

    var inline: InlineSyntax? {
        InlineSyntax(open: "{{", close: "}}", parsesContent: false)
    }

    func contentAttributes(theme: MarkdownEditorTheme) -> [NSAttributedString.Key: Any] {
        [
            .foregroundColor: Design.variableInk,
            .backgroundColor: Design.variableTint,
            // Same face inline code gets from the engine: token, not prose.
            .font: NSFont.monospacedSystemFont(ofSize: Design.editorFontSize, weight: .regular),
        ]
    }

    func html(childrenHTML: String) -> String {
        "<code>{{\(childrenHTML)}}</code>"
    }
}
