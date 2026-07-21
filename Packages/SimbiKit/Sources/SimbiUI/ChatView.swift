import CodexKit
import SimbiKit
import SwiftUI

/// The per-note chat window (SPEC.md §5.4): transcript of the note's
/// persistent Codex thread + composer. The app shell declares the matching
/// WindowGroup scene.
public struct ChatWindow: View {
    public static let windowId = "note-chat"

    @State private var model: ChatModel
    private let noteName: String

    public init(noteFolderURL: URL) {
        self._model = State(initialValue: ChatModel.shared(noteFolderURL: noteFolderURL))
        self.noteName = noteFolderURL.lastPathComponent
    }

    public var body: some View {
        ChatView(model: model)
            .navigationTitle("Chat — \(noteName)")
            .frame(minWidth: 380, idealWidth: 480, minHeight: 420, idealHeight: 620)
            .task { model.start() }
    }
}

struct ChatView: View {
    @Bindable var model: ChatModel
    /// True while the transcript is scrolled to (near) the bottom; new
    /// content auto-follows only then, so reading back never fights the
    /// stream.
    @State private var pinnedToBottom = true

    private static let bottomId = "chat-bottom"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if case .unavailable(let message) = model.phase {
                StatusBanner(message: message)
                Divider()
            }
            transcript
            Divider()
            ChatComposer(model: model)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if model.transcript.turnActive {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            Button("New Chat") {
                model.newChat()
            }
            .disabled(model.phase != .ready)
            .help("Archive this conversation and start a fresh one")
        }
        .padding(.horizontal, Design.paneInset)
        .padding(.vertical, 8)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Design.rowGap) {
                    if model.transcript.rows.isEmpty && model.phase == .ready {
                        Text("Ask Codex about this note.")
                            .font(.meta)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(model.transcript.rows) { row in
                        ChatRowView(row: row)
                    }
                    ForEach(model.pendingApprovals) { approval in
                        ChatApprovalCard(approval: approval, model: model)
                    }
                    // Bottom sentinel: measures distance to the viewport
                    // bottom to know whether the user is following along.
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ChatBottomOffsetKey.self,
                            value: geometry.frame(in: .named("chat-scroll")).minY)
                    }
                    .frame(height: 1)
                    .id(Self.bottomId)
                }
                .padding(Design.paneInset)
            }
            .coordinateSpace(name: "chat-scroll")
            .onPreferenceChange(ChatBottomOffsetKey.self) { bottomY in
                // Grace band so tiny bounces don't unpin.
                pinnedToBottom = bottomY < scrollViewportHeight + 80
            }
            .background(alignment: .bottomTrailing) {
                if !pinnedToBottom {
                    jumpToLatest(proxy: proxy)
                }
            }
            .onChange(of: model.transcript.rows) {
                if pinnedToBottom {
                    proxy.scrollTo(Self.bottomId, anchor: .bottom)
                }
            }
            .onChange(of: model.pendingApprovals.count) {
                if pinnedToBottom {
                    proxy.scrollTo(Self.bottomId, anchor: .bottom)
                }
            }
        }
    }

    /// Viewport height for the pin heuristic; a fixed generous estimate
    /// works because the sentinel's minY goes far beyond it when scrolled
    /// up. Refined only if verification shows misbehavior.
    private var scrollViewportHeight: CGFloat { 700 }

    private func jumpToLatest(proxy: ScrollViewProxy) -> some View {
        Button {
            proxy.scrollTo(Self.bottomId, anchor: .bottom)
        } label: {
            Label("Latest", systemImage: "arrow.down")
                .font(.meta)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(12)
    }
}

private struct ChatBottomOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ChatComposer: View {
    @Bindable var model: ChatModel
    @FocusState private var focused: Bool

    private var sendDisabled: Bool {
        model.phase != .ready
            || model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Codex…", text: $model.composerText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit { model.sendCurrentMessage() }
                .onKeyPress(.return, phases: .down) { press in
                    // Shift+Return inserts a newline; plain Return submits
                    // (handled by onSubmit).
                    if press.modifiers.contains(.shift) {
                        model.composerText += "\n"
                        return .handled
                    }
                    return .ignored
                }
                .disabled(model.phase != .ready)
            if model.transcript.turnActive {
                Button {
                    model.interrupt()
                } label: {
                    Image(systemName: "stop.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Stop this turn")
            } else {
                Button {
                    model.sendCurrentMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderless)
                .disabled(sendDisabled)
                .help("Send (Return)")
            }
        }
        .padding(Design.paneInset)
        .onAppear { focused = true }
    }
}

// Task 8 replaces these placeholders with the real row and approval views
// in ChatRows.swift.
struct ChatRowView: View {
    let row: ChatTranscript.Row

    var body: some View {
        switch row {
        case .user(_, let text):
            Text(text)
        case .agent(_, let markdown, _):
            ChatMarkdownView(markdown: markdown)
        default:
            Text(row.id)
                .font(.meta)
                .foregroundStyle(.tertiary)
        }
    }
}

struct ChatApprovalCard: View {
    let approval: ChatApprovalRequest
    let model: ChatModel

    var body: some View {
        EmptyView()
    }
}
