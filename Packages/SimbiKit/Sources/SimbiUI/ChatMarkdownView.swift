import CodexKit
import SwiftUI

/// Renders one agent message: prose via AttributedString markdown (inline
/// styling, preserved line breaks), fenced code as monospaced blocks.
struct ChatMarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let segments = Array(MarkdownSegmenter.segments(markdown).enumerated())
            ForEach(segments, id: \.offset) { _, segment in
                switch segment {
                case .text(let text):
                    Text(Self.attributed(text))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(_, let body):
                    ScrollView(.horizontal) {
                        Text(body)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
