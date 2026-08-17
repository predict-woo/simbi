import CodexKit

/// One app-server process for the whole app (SPEC.md §5.1), shared by every
/// feature that talks to Codex (fixer, converter, summarizer, titler,
/// thread viewers, settings).
enum CodexServices {
    static let appServer = AppServerClient()
}
