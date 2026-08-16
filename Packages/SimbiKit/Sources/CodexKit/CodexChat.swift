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
    /// One reasoning-effort level a model supports, as reported by
    /// `model/list` (`supportedReasoningEfforts` entries).
    public struct Effort: Equatable, Sendable {
        public var id: String
        public var description: String?

        public init(id: String, description: String? = nil) {
            self.id = id
            self.description = description
        }
    }

    /// One selectable model. Effort metadata is optional on the wire —
    /// a bare slug degrades to a model with no known efforts.
    public struct Model: Equatable, Sendable {
        public var id: String
        public var supportedEfforts: [Effort]
        public var defaultEffort: String?
        public var isDefault: Bool

        public init(
            id: String, supportedEfforts: [Effort] = [], defaultEffort: String? = nil,
            isDefault: Bool = false
        ) {
            self.id = id
            self.supportedEfforts = supportedEfforts
            self.defaultEffort = defaultEffort
            self.isDefault = isDefault
        }
    }

    /// Models from the app-server. Parses defensively — accepts
    /// `{"data": [...]}` (live 0.148 shape), `{"models": [...]}`, or a bare
    /// array, of strings or of objects keyed `id`/`model`/`slug`.
    public static func list(client: AppServerClient) async throws -> [Model] {
        let data = try await client.request(method: "model/list", params: [:])
        return parse(data)
    }

    /// The efforts to offer for a selection: the chosen model's, or the
    /// server-default model's when no override is chosen (nil = "Default").
    public static func efforts(for modelId: String?, in models: [Model]) -> [Effort] {
        guard let modelId else {
            return models.first(where: \.isDefault)?.supportedEfforts ?? []
        }
        return models.first(where: { $0.id == modelId })?.supportedEfforts ?? []
    }

    static func parse(_ data: Data) -> [Model] {
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
            if let slug = entry as? String { return Model(id: slug) }
            guard let dict = entry as? [String: Any],
                let id = (dict["id"] ?? dict["model"] ?? dict["slug"]) as? String
            else { return nil }
            let efforts = (dict["supportedReasoningEfforts"] as? [Any] ?? []).compactMap {
                raw -> Effort? in
                guard let effort = raw as? [String: Any],
                    let id = effort["reasoningEffort"] as? String
                else { return nil }
                return Effort(id: id, description: effort["description"] as? String)
            }
            return Model(
                id: id, supportedEfforts: efforts,
                defaultEffort: dict["defaultReasoningEffort"] as? String,
                isDefault: dict["isDefault"] as? Bool ?? false)
        }
    }
}
