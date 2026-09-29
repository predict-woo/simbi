import Foundation

/// Wire parsing kept separate from the organizer so project membership has
/// deterministic unit coverage without launching the real app-server.
enum SimbiCodexProjectAPI {
    static func projectID(
        in data: Data, rootURL: URL, preferredID: String? = nil
    ) -> String? {
        let rootPath = rootURL.standardizedFileURL.path
        let matches = rows(in: data).filter { row in
            let roots = row["roots"] as? [[String: Any]] ?? []
            return roots.contains { root in
                guard let path = root["path"] as? String else { return false }
                return URL(filePath: path).standardizedFileURL.path == rootPath
            }
        }
        if let preferredID,
            matches.contains(where: { $0["id"] as? String == preferredID })
        {
            return preferredID
        }
        return matches.first?["id"] as? String
    }

    static func importedProjectID(in data: Data) -> String? {
        let object = jsonObject(in: data)
        return (object?["project"] as? [String: Any])?["id"] as? String
    }

    static func threadIDsToAssign(
        in data: Data, projectID: String, rootURL: URL
    ) -> [String] {
        let rootPath = rootURL.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return rows(in: data).compactMap { row in
            guard let id = row["id"] as? String,
                row["projectId"] as? String != projectID
            else { return nil }
            let isOwned = row["originator"] as? String == "simbi"
            let cwdPath = (row["cwd"] as? String).map {
                URL(filePath: $0).standardizedFileURL.path
            }
            let isInsideRoot = cwdPath == rootPath || cwdPath?.hasPrefix(rootPrefix) == true
            return isOwned || isInsideRoot ? id : nil
        }
    }

    static func nextCursor(in data: Data) -> String? {
        jsonObject(in: data)?["nextCursor"] as? String
    }

    private static func rows(in data: Data) -> [[String: Any]] {
        jsonObject(in: data)?["data"] as? [[String: Any]] ?? []
    }

    private static func jsonObject(in data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Creates one local Codex project rooted at the Simbi home and keeps every
/// Simbi-created thread assigned to it. Codex does not infer project
/// membership from `cwd`, even when a matching local project already exists.
public enum SimbiCodexProjectOrganizer {
    private static let registry = Registry()

    public static func ensureProject(
        client: AppServerClient, rootURL: URL
    ) async throws -> String {
        try await registry.ensureProject(client: client, rootURL: rootURL, reconcile: false)
    }

    /// Imports historical threads and catches sessions created by the
    /// embedded Codex CLI, which has no project-id launch option.
    public static func reconcile(
        client: AppServerClient, rootURL: URL
    ) async throws {
        _ = try await registry.ensureProject(client: client, rootURL: rootURL, reconcile: true)
    }

    private actor Registry {
        private var projectIDs: [String: String] = [:]

        func ensureProject(
            client: AppServerClient, rootURL: URL, reconcile: Bool
        ) async throws -> String {
            let rootURL = rootURL.standardizedFileURL
            let rootPath = rootURL.path
            if let projectID = projectIDs[rootPath] {
                if reconcile {
                    try await assignExistingThreads(
                        client: client, rootURL: rootURL, projectID: projectID)
                }
                return projectID
            }

            if let projectID = try await findProject(client: client, rootURL: rootURL) {
                projectIDs[rootPath] = projectID
                if reconcile {
                    try await assignExistingThreads(
                        client: client, rootURL: rootURL, projectID: projectID)
                }
                return projectID
            }

            let threadIDs = try await matchingThreadIDs(
                client: client, rootURL: rootURL, projectID: "")
            let result = try await client.request(
                method: "project/import",
                params: [
                    "name": "Simbi",
                    "roots": [["path": rootPath]],
                    "threads": threadIDs,
                    "idempotencyKey": "simbi:\(rootPath)",
                    "metadata": ["originator": "simbi"],
                ])
            guard let projectID = SimbiCodexProjectAPI.importedProjectID(in: result) else {
                throw AppServerClient.ClientError.serverError(
                    code: -1, message: "project/import returned no project id")
            }
            projectIDs[rootPath] = projectID
            return projectID
        }

        private func findProject(
            client: AppServerClient, rootURL: URL
        ) async throws -> String? {
            let preferredID = SimbiCodexDesktopProjectCatalog.project(
                rootURL: rootURL)?.serverID
            var cursor: String?
            repeat {
                var params: [String: any Sendable] = ["limit": 100]
                if let cursor { params["cursor"] = cursor }
                let result = try await client.request(method: "project/list", params: params)
                if let id = SimbiCodexProjectAPI.projectID(
                    in: result, rootURL: rootURL, preferredID: preferredID)
                {
                    return id
                }
                cursor = SimbiCodexProjectAPI.nextCursor(in: result)
            } while cursor != nil
            return nil
        }

        private func assignExistingThreads(
            client: AppServerClient, rootURL: URL, projectID: String
        ) async throws {
            let threadIDs = try await matchingThreadIDs(
                client: client, rootURL: rootURL, projectID: projectID)
            for threadID in threadIDs {
                _ = try await client.request(
                    method: "thread/metadata/update",
                    params: ["threadId": threadID, "projectId": projectID])
            }
        }

        private func matchingThreadIDs(
            client: AppServerClient, rootURL: URL, projectID: String
        ) async throws -> [String] {
            var ids: [String] = []
            for archived in [false, true] {
                var cursor: String?
                repeat {
                    var params: [String: any Sendable] = [
                        "limit": 100, "archived": archived,
                    ]
                    if let cursor { params["cursor"] = cursor }
                    let result = try await client.request(method: "thread/list", params: params)
                    ids.append(
                        contentsOf: SimbiCodexProjectAPI.threadIDsToAssign(
                            in: result, projectID: projectID, rootURL: rootURL))
                    cursor = SimbiCodexProjectAPI.nextCursor(in: result)
                } while cursor != nil
            }
            return Array(Set(ids)).sorted()
        }
    }
}
