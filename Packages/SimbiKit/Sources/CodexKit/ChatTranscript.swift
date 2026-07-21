import Foundation

/// Pure reducer from chat wire events to renderable rows. All ordering and
/// streaming rules live here so the UI model stays a thin bridge and the
/// behavior is testable headless.
public struct ChatTranscript: Equatable, Sendable {
    public enum Row: Equatable, Sendable, Identifiable {
        case user(id: String, text: String)
        case agent(id: String, markdown: String, streaming: Bool)
        case command(id: String, command: String, status: String, output: String?)
        case fileChange(id: String, files: [String], status: String)
        /// Reasoning + item types without a rich row — visible but muted.
        case quiet(id: String, text: String)
        case banner(id: String, text: String)

        public var id: String {
            switch self {
            case .user(let id, _), .agent(let id, _, _), .command(let id, _, _, _),
                .fileChange(let id, _, _), .quiet(let id, _), .banner(let id, _):
                id
            }
        }
    }

    public private(set) var rows: [Row] = []
    public private(set) var turnActive = false
    public private(set) var activeTurnId: String?
    private var localCounter = 0
    private var bannerCounter = 0

    public init(history: [ChatItem] = []) {
        for item in history {
            upsert(item)
        }
    }

    public mutating func apply(_ event: ChatEvent) {
        switch event {
        case .turnStarted(let turnId):
            turnActive = true
            activeTurnId = turnId
        case .turnCompleted(let status):
            turnActive = false
            activeTurnId = nil
            if status == "failed" {
                appendBanner("The turn failed.")
            } else if status == "interrupted" {
                appendBanner("Interrupted.")
            }
        case .agentMessageDelta(let itemId, let delta):
            if let index = rows.firstIndex(where: { $0.id == itemId }),
                case .agent(_, let markdown, _) = rows[index] {
                rows[index] = .agent(id: itemId, markdown: markdown + delta, streaming: true)
            } else {
                rows.append(.agent(id: itemId, markdown: delta, streaming: true))
            }
        case .itemStarted(let item), .itemCompleted(let item):
            upsert(item)
        }
    }

    /// The user's message must appear the instant they hit send; the wire
    /// echo (a userMessage item with a server id) later replaces the local
    /// row instead of duplicating it.
    public mutating func appendLocalUser(text: String) {
        localCounter += 1
        rows.append(.user(id: "local-\(localCounter)", text: text))
    }

    public mutating func appendBanner(_ text: String) {
        bannerCounter += 1
        rows.append(.banner(id: "banner-\(bannerCounter)", text: text))
    }

    private mutating func upsert(_ item: ChatItem) {
        guard let row = Self.row(for: item) else { return }
        if case .user(_, let text) = row,
            let last = rows.lastIndex(where: {
                if case .user(let id, let existing) = $0 {
                    return id.hasPrefix("local-") && existing == text
                }
                return false
            }) {
            rows[last] = row
            return
        }
        if let index = rows.firstIndex(where: { $0.id == item.id }) {
            rows[index] = row
        } else {
            rows.append(row)
        }
    }

    private static func row(for item: ChatItem) -> Row? {
        switch item.detail {
        case .userMessage(let text):
            .user(id: item.id, text: text)
        case .agentMessage(let text):
            .agent(id: item.id, markdown: text, streaming: false)
        case .reasoning(let summary):
            .quiet(id: item.id, text: summary.isEmpty ? "Thinking…" : "Thinking — \(summary)")
        case .commandExecution(let command, let status, let output):
            .command(id: item.id, command: command, status: status, output: output)
        case .fileChange(let files, let status):
            .fileChange(id: item.id, files: files, status: status)
        case .other(let type):
            .quiet(id: item.id, text: type)
        }
    }
}
