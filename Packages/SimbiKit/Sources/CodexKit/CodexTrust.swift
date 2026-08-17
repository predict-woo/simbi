import Foundation
import SimbiKit

/// Pre-trusts a note folder in `~/.codex/config.toml` so the chat TUI
/// skips its "Do you trust the contents of this directory?" gate on every
/// note. Appends the same `[projects."<path>"]` entry codex writes when
/// the user picks "Yes, continue"; trust is per exact path — a parent
/// entry does not cover children (verified against codex 0.147), so each
/// note folder needs its own entry. `-c` overrides on the command line
/// are ignored for the trust decision, hence the config file.
public enum CodexTrust {
    public static func ensureTrusted(
        directory: URL, installation: CodexInstallation = .standard
    ) {
        // No codex home → signed-out/degraded; nothing to pre-trust.
        guard FileManager.default.fileExists(atPath: installation.codexHomeURL.path) else {
            return
        }
        let path = escaped(directory.standardizedFileURL.path)
        let configURL = installation.codexHomeURL.appending(path: "config.toml")
        let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        // Any mention of the quoted path means an entry exists (possibly
        // deliberately untrusted) — appending again would be a duplicate
        // TOML table, which breaks codex's whole config parse, so the
        // check errs toward skipping.
        guard !existing.contains("\"\(path)\"") else { return }
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "\n" : "\n\n"
        let entry = "\(separator)[projects.\"\(path)\"]\ntrust_level = \"trusted\"\n"
        do {
            try (existing + entry).write(to: configURL, atomically: true, encoding: .utf8)
        } catch {
            Log.codex.error(
                "pre-trusting \(directory.lastPathComponent) in config.toml failed"
                    + " (chat will show the trust prompt): \(error)")
        }
    }

    /// TOML basic-string escaping for the quoted key (note names can
    /// legitimately contain quotes).
    private static func escaped(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
