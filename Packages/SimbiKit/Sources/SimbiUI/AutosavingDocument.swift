import Foundation
import Observation
import SimbiKit

/// Keeps one text editor synchronized with its file: clean external changes
/// reload immediately, edits autosave, and concurrent changes require an
/// explicit choice. Shared by every markdown editor in the app.
@MainActor
@Observable
final class AutosavingDocument {
    private enum DiskSnapshot: Equatable {
        case missing
        case contents(String)

        var text: String {
            switch self {
            case .missing: ""
            case .contents(let text): text
            }
        }
    }

    let fileURL: URL
    var text: String
    var hasConflict: Bool { conflictingDiskSnapshot != nil }

    private var saveTask: Task<Void, Never>?
    private var watcher: FileTreeWatcher?
    private var diskSnapshot: DiskSnapshot
    private var conflictingDiskSnapshot: DiskSnapshot?

    /// `initialText` overrides the plain file read — the instructions
    /// editor starts from the built-in default when its file is missing
    /// or blank.
    init(fileURL: URL, initialText: String? = nil) {
        self.fileURL = fileURL
        let snapshot = Self.readDiskSnapshot(at: fileURL) ?? .missing
        self.diskSnapshot = snapshot
        self.text = initialText ?? snapshot.text
        watcher = FileTreeWatcher.observing(url: fileURL.deletingLastPathComponent()) {
            [weak self] in
            self?.refreshFromDisk()
        }
    }

    /// Debounced autosave; a pending save is superseded by the next edit.
    func scheduleAutosave() {
        saveTask?.cancel()
        guard text != diskSnapshot.text, conflictingDiskSnapshot == nil else {
            saveTask = nil
            return
        }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Never materializes a missing file for empty content: summary.md's
    /// mere existence is state (it makes the tab strip appear), so a note
    /// that never had AI notes must not gain an empty file.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard conflictingDiskSnapshot == nil, text != diskSnapshot.text else { return }
        guard let currentDiskSnapshot = Self.readDiskSnapshot(at: fileURL) else { return }
        guard currentDiskSnapshot == diskSnapshot else {
            if text == currentDiskSnapshot.text {
                diskSnapshot = currentDiskSnapshot
                return
            }
            conflictingDiskSnapshot = currentDiskSnapshot
            return
        }
        if text.isEmpty && currentDiskSnapshot == .missing { return }
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            diskSnapshot = .contents(text)
        } catch {
            Log.files.error("autosaving \(fileURL.lastPathComponent) failed: \(error)")
        }
    }

    /// Reconciles a watcher event. Content comparison filters both unrelated
    /// folder events and our own atomic saves; a dirty buffer is never replaced
    /// or written over a newer disk version without an explicit choice.
    func refreshFromDisk() {
        guard let latest = Self.readDiskSnapshot(at: fileURL), latest != diskSnapshot else {
            return
        }
        saveTask?.cancel()
        saveTask = nil
        if text == latest.text {
            diskSnapshot = latest
            conflictingDiskSnapshot = nil
            return
        }
        guard text == diskSnapshot.text else {
            conflictingDiskSnapshot = latest
            return
        }
        diskSnapshot = latest
        conflictingDiskSnapshot = nil
        text = latest.text
    }

    /// Explicit conflict resolution: discard the editor buffer and show the
    /// file's current contents.
    func reloadFromDisk() {
        guard let latest = Self.readDiskSnapshot(at: fileURL) else { return }
        saveTask?.cancel()
        saveTask = nil
        diskSnapshot = latest
        conflictingDiskSnapshot = nil
        text = latest.text
    }

    /// Explicit conflict resolution: keep the editor buffer and replace the
    /// newer disk contents. saveNow() performs one more comparison so another
    /// intervening external write produces a fresh conflict instead.
    func overwriteDisk() {
        guard conflictingDiskSnapshot != nil,
            let latest = Self.readDiskSnapshot(at: fileURL)
        else { return }
        diskSnapshot = latest
        conflictingDiskSnapshot = nil
        saveNow()
    }

    private static func readDiskSnapshot(at url: URL) -> DiskSnapshot? {
        do {
            return .contents(try String(contentsOf: url, encoding: .utf8))
        } catch {
            // A file can disappear between an existence check and a read.
            guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
            Log.files.error("reading \(url.lastPathComponent) after a file change failed: \(error)")
            return nil
        }
    }
}
