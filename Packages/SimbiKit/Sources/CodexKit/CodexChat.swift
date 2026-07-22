import Foundation

/// Shared helpers for the in-app chat (SPEC.md §5.4): the path helper used
/// by the terminal chat's developer instructions, and model discovery for
/// the settings pickers.
public enum CodexChat {
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
            let models = (dict["models"] ?? dict["items"] ?? dict["data"]) as? [Any] {
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
