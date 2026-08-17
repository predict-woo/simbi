import Foundation

/// Native tab grouping for chat windows: AppKit only merges windows whose
/// tabbing identifiers match, so giving every chat window of one note the
/// same identifier — and different notes different ones — yields exactly
/// the per-note tab groups the chat UX wants.
public enum ChatWindowTabbing {
    static func identifier(for noteFolderURL: URL) -> String {
        prefix + noteFolderURL.standardizedFileURL.path
    }

    private static let prefix = "app.getsimbi.mac.note-chat:"
}
