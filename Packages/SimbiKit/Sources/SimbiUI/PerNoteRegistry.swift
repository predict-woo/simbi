import Foundation

/// One instance per note folder, kept for the app's lifetime — the
/// registry behind every controller's `shared(noteFolderURL:)`. Instances
/// are deliberately never evicted: they are tiny when idle, and per-note
/// state (a running recording, an in-flight generation) must survive view
/// recreation.
@MainActor
final class PerNoteRegistry<Value> {
    private var values: [URL: Value] = [:]

    /// The note's instance, created on first use.
    func value(for noteFolderURL: URL, make: (URL) -> Value) -> Value {
        if let existing = values[noteFolderURL] { return existing }
        let value = make(noteFolderURL)
        values[noteFolderURL] = value
        return value
    }

    /// The note's instance if one exists — never creates as a side effect.
    subscript(noteFolderURL: URL) -> Value? {
        values[noteFolderURL]
    }

    /// Every live instance (the any-note-recording aggregate).
    var all: Dictionary<URL, Value>.Values { values.values }
}
