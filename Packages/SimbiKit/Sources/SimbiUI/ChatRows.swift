import CodexKit
import SwiftUI

/// One transcript row. Agent-console styling: full-width, quiet tints, no
/// messenger bubbles (SPEC.md §5.4).
struct ChatRowView: View {
    let row: ChatTranscript.Row

    var body: some View {
        switch row {
        case .user(_, let text):
            VStack(alignment: .leading, spacing: 3) {
                Text("You")
                    .font(.metaSemibold)
                    .foregroundStyle(.secondary)
                Text(text)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        case .agent(_, let markdown, let streaming):
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text("Codex")
                        .font(.metaSemibold)
                        .foregroundStyle(.secondary)
                    if streaming {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                ChatMarkdownView(markdown: markdown)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .command(_, let command, let status, let output):
            DisclosureGroup {
                if let output, !output.isEmpty {
                    ScrollView(.horizontal) {
                        Text(output)
                            .font(.meta.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                    .frame(maxHeight: 160)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                } else {
                    Text("No output.")
                        .font(.meta)
                        .foregroundStyle(.tertiary)
                }
            } label: {
                HStack(spacing: 6) {
                    statusDot(status)
                    Text(command)
                        .font(.meta.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.meta)
        case .fileChange(_, let files, let status):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                statusDot(status)
                Image(systemName: "doc.badge.gearshape")
                    .font(.meta)
                    .foregroundStyle(.secondary)
                Text(files.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                    .font(.meta)
                    .lineLimit(2)
            }
        case .quiet(_, let text):
            Text(text)
                .font(.meta)
                .foregroundStyle(.tertiary)
        case .banner(_, let text):
            StatusBanner(message: text)
        }
    }

    /// Green = done, orange = failed-ish, secondary = in flight. Red stays
    /// reserved for recording.
    private func statusDot(_ status: String) -> some View {
        Circle()
            .fill(
                status == "completed"
                    ? Color.green
                    : status == "failed" || status == "declined" ? Color.orange : Color.secondary)
            .frame(width: 6, height: 6)
    }
}

/// Inline approval prompt: what Codex wants to do + the three decisions.
/// Rendered at the transcript tail while the server request is suspended.
struct ChatApprovalCard: View {
    let approval: ChatApprovalRequest
    let model: ChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                Text(title)
                    .font(.metaSemibold)
            }
            switch approval.kind {
            case .commandExecution(let command, let cwd, let reason):
                ScrollView(.horizontal) {
                    Text(command)
                        .font(.meta.monospaced())
                        .textSelection(.enabled)
                }
                if let cwd {
                    Text("in \(cwd)")
                        .font(.meta)
                        .foregroundStyle(.tertiary)
                }
                if let reason {
                    Text(reason)
                        .font(.meta)
                        .foregroundStyle(.secondary)
                }
            case .fileChange(_, let reason):
                if let reason {
                    Text(reason)
                        .font(.meta)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Button("Allow") {
                    model.respond(to: approval, decision: "accept")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Allow for Session") {
                    model.respond(to: approval, decision: "acceptForSession")
                }
                .controlSize(.small)
                Button("Deny") {
                    model.respond(to: approval, decision: "decline")
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.orange.opacity(0.35)))
    }

    private var title: String {
        switch approval.kind {
        case .commandExecution: "Codex wants to run a command"
        case .fileChange: "Codex wants to edit files"
        }
    }
}
