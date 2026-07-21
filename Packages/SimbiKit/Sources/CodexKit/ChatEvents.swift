import Foundation

/// One unit of chat work, translated off the wire (SPEC.md §5.4). Shapes
/// follow the app-server v2 `ThreadItem` union.
public struct ChatItem: Equatable, Sendable, Identifiable {
    public enum Detail: Equatable, Sendable {
        case userMessage(text: String)
        case agentMessage(text: String)
        case reasoning(summary: String)
        case commandExecution(command: String, status: String, output: String?)
        case fileChange(files: [String], status: String)
        /// Item types the chat doesn't render richly (mcpToolCall,
        /// webSearch, …) — shown as a quiet generic row, never dropped.
        case other(type: String)
    }

    public let id: String
    public let detail: Detail

    public init(id: String, detail: Detail) {
        self.id = id
        self.detail = detail
    }
}

/// Chat-relevant app-server traffic, one thread's worth.
public enum ChatEvent: Equatable, Sendable {
    case turnStarted(turnId: String)
    case turnCompleted(status: String)
    case agentMessageDelta(itemId: String, delta: String)
    case itemStarted(ChatItem)
    case itemCompleted(ChatItem)
}

public enum ChatEventParser {
    /// Parses one notification into (threadId, event); nil for methods the
    /// chat doesn't consume. The caller filters by threadId — the shared
    /// client fans every thread's notifications to every handler.
    public static func parse(
        method: String, params: [String: Any]
    ) -> (threadId: String, event: ChatEvent)? {
        guard let threadId = params["threadId"] as? String else { return nil }
        switch method {
        case "turn/started":
            guard let turn = params["turn"] as? [String: Any],
                let turnId = turn["id"] as? String
            else { return nil }
            return (threadId, .turnStarted(turnId: turnId))
        case "turn/completed":
            let turn = params["turn"] as? [String: Any]
            return (threadId, .turnCompleted(status: turn?["status"] as? String ?? "completed"))
        case "item/agentMessage/delta":
            guard let itemId = params["itemId"] as? String,
                let delta = params["delta"] as? String
            else { return nil }
            return (threadId, .agentMessageDelta(itemId: itemId, delta: delta))
        case "item/started", "item/completed":
            guard let dict = params["item"] as? [String: Any],
                let item = item(from: dict)
            else { return nil }
            return (
                threadId,
                method == "item/started" ? .itemStarted(item) : .itemCompleted(item)
            )
        default:
            return nil
        }
    }

    /// Translates one wire item; unknown types become `.other`, a missing
    /// id/type makes it nil (nothing renderable).
    public static func item(from dict: [String: Any]) -> ChatItem? {
        guard let id = dict["id"] as? String, let type = dict["type"] as? String else {
            return nil
        }
        switch type {
        case "userMessage":
            let content = dict["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return ChatItem(id: id, detail: .userMessage(text: text))
        case "agentMessage":
            return ChatItem(id: id, detail: .agentMessage(text: dict["text"] as? String ?? ""))
        case "reasoning":
            let summary = (dict["summary"] as? [String])?.first ?? ""
            return ChatItem(id: id, detail: .reasoning(summary: summary))
        case "commandExecution":
            return ChatItem(
                id: id,
                detail: .commandExecution(
                    command: dict["command"] as? String ?? "",
                    status: dict["status"] as? String ?? "",
                    output: dict["aggregatedOutput"] as? String))
        case "fileChange":
            let changes = dict["changes"] as? [[String: Any]] ?? []
            return ChatItem(
                id: id,
                detail: .fileChange(
                    files: changes.compactMap { $0["path"] as? String },
                    status: dict["status"] as? String ?? ""))
        default:
            return ChatItem(id: id, detail: .other(type: type))
        }
    }
}
