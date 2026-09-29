import AppKit
import Foundation

/// The local-project catalog rendered by the Codex desktop Projects screen.
///
/// App-server projects alone are not enough: Codex keeps the UI catalog in
/// `.codex-global-state.json` and only its desktop directory-open flow updates
/// that catalog and broadcasts the change to already-open windows.
enum SimbiCodexDesktopProjectCatalog {
    struct Project: Equatable {
        let desktopID: String
        let serverID: String?
    }

    static func project(
        in data: Data, rootURL: URL, codexHomeURL: URL
    ) -> Project? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let projects = object["local-projects"] as? [String: [String: Any]]
        else { return nil }

        let rootPath = rootURL.standardizedFileURL.path
        guard let (desktopID, _) = projects.first(where: { _, project in
            let roots = project["rootPaths"] as? [String] ?? []
            return roots.contains {
                URL(filePath: $0).standardizedFileURL.path == rootPath
            }
        }) else { return nil }

        let hostKey = "local:\(codexHomeURL.standardizedFileURL.path)"
        let mappings = object["app-server-project-id-by-legacy-project-id-by-host"]
            as? [String: [String: String]]
        return Project(desktopID: desktopID, serverID: mappings?[hostKey]?[desktopID])
    }

    static func project(
        rootURL: URL, installation: CodexInstallation = .standard
    ) -> Project? {
        let stateURL = installation.codexHomeURL.appending(
            path: ".codex-global-state.json")
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return project(
            in: data, rootURL: rootURL, codexHomeURL: installation.codexHomeURL)
    }
}

/// Registers the Simbi root through Codex's own macOS directory-open path.
/// That is the only external entry point that updates both the app-server
/// project store and the live desktop UI catalog without restarting Codex.
public enum SimbiCodexDesktopProjectRegistrar {
    public enum RegistrationError: Error {
        case appMissing
        case timedOut
    }

    @MainActor
    public static func ensureProject(
        rootURL: URL, installation: CodexInstallation = .standard
    ) async throws {
        let rootURL = rootURL.standardizedFileURL
        if SimbiCodexDesktopProjectCatalog.project(
            rootURL: rootURL, installation: installation)?.serverID != nil
        {
            return
        }

        guard FileManager.default.fileExists(atPath: installation.appBundleURL.path) else {
            throw RegistrationError.appMissing
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open(
                [rootURL], withApplicationAt: installation.appBundleURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            if SimbiCodexDesktopProjectCatalog.project(
                rootURL: rootURL, installation: installation)?.serverID != nil
            {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RegistrationError.timedOut
    }
}
