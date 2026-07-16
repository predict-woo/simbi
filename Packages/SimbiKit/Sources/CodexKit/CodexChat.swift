import Foundation

/// "Chat in Codex" (SPEC.md §5.4): a normal, user-facing Codex thread at
/// the HOME root (never the note folder, so the ChatGPT app's history stays
/// browsable), primed with a context turn that points the agent at the
/// note. Chat threads are never archived by Simbi.
public enum CodexChat {
    /// Starts the chat thread and its context turn; returns the thread id
    /// for the `codex://threads/<id>` deeplink (the composer can't be
    /// pre-filled — the context turn runs while the user types).
    public static func startChat(
        noteFolderURL: URL, homeRootURL: URL, client: AppServerClient, model: String? = nil
    ) async throws -> String {
        let resultData = try await client.request(
            method: "thread/start", params: ["cwd": homeRootURL.path])
        let result = (try? JSONSerialization.jsonObject(with: resultData)) as? [String: Any]
        guard let thread = result?["thread"] as? [String: Any],
            let threadId = thread["id"] as? String
        else { throw AppServerClient.ClientError.malformedResponse }

        // Naming forces rollout persistence (M1 spike gotcha #2) and is the
        // user's handle on the thread in the ChatGPT app.
        _ = try await client.request(
            method: "thread/name/set",
            params: [
                "threadId": threadId,
                "name": "\(noteFolderURL.lastPathComponent) — chat",
            ])

        let relativePath = notePath(noteFolderURL: noteFolderURL, homeRootURL: homeRootURL)
        let prompt = """
            The user wants to discuss the note at `\(relativePath)`. Read its \
            `note.md`, `transcript.vtt`, and `context/*.md` (whatever exists), \
            then answer their next message.
            """
        var params: [String: any Sendable] = [
            "threadId": threadId,
            "input": [["type": "text", "text": prompt, "text_elements": [String]()]]
                as [[String: any Sendable]],
        ]
        if let model {
            params["model"] = model
        }
        _ = try await client.request(method: "turn/start", params: params)
        return threadId
    }

    /// The note's path relative to the home root, as shown to the agent.
    static func notePath(noteFolderURL: URL, homeRootURL: URL) -> String {
        let home = homeRootURL.standardizedFileURL.path
        let note = noteFolderURL.standardizedFileURL.path
        if note.hasPrefix(home + "/") {
            return String(note.dropFirst(home.count + 1))
        }
        return note
    }
}

/// Model discovery for the per-feature selectors (SPEC.md §5.5).
public enum CodexModels {
    /// Model slugs from the app-server. Parses defensively — accepts
    /// `{"models": [...]}` or a bare array, of strings or of objects keyed
    /// `id`/`model`/`slug`.
    public static func list(client: AppServerClient) async throws -> [String] {
        let data = try await client.request(method: "model/list", params: [:])
        return parse(data)
    }

    static func parse(_ data: Data) -> [String] {
        let object = try? JSONSerialization.jsonObject(with: data)
        let array: [Any]
        if let dict = object as? [String: Any],
            let models = (dict["models"] ?? dict["items"] ?? dict["data"]) as? [Any]
        {
            array = models
        } else if let bare = object as? [Any] {
            array = bare
        } else {
            return []
        }
        return array.compactMap { entry in
            if let slug = entry as? String { return slug }
            if let dict = entry as? [String: Any] {
                return (dict["id"] ?? dict["model"] ?? dict["slug"]) as? String
            }
            return nil
        }
    }
}
