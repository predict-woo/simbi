import Foundation

/// A chat message split at ``` fences so code renders monospaced while
/// prose goes through AttributedString markdown.
public enum MarkdownSegment: Equatable, Sendable {
    case text(String)
    case code(language: String?, body: String)
}

public enum MarkdownSegmenter {
    public static func segments(_ markdown: String) -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        var textLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCode = false

        func flushText() {
            let text = textLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { segments.append(.text(text)) }
            textLines = []
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    segments.append(
                        .code(language: codeLanguage, body: codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCode = false
                } else {
                    flushText()
                    let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    codeLanguage = language.isEmpty ? nil : language
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(String(line))
            } else {
                textLines.append(String(line))
            }
        }
        if inCode {
            segments.append(
                .code(language: codeLanguage, body: codeLines.joined(separator: "\n")))
        } else {
            flushText()
        }
        return segments
    }
}
