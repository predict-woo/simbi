import Foundation

public enum NoteOperationError: Error, Equatable {
    /// Note folders never nest inside other note folders (SPEC.md §2.2).
    case insideNoteFolder
    case alreadyExists(URL)
}

/// Plain file-system operations behind the sidebar's context menu (SPEC.md §6).
public enum NoteOperations {
    /// Creates a note folder (a folder containing an empty `note.md`).
    @discardableResult
    public static func createNote(named name: String, in parent: URL) throws -> URL {
        guard !isInsideNoteFolder(parent) else { throw NoteOperationError.insideNoteFolder }
        let url = parent.appending(path: name, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw NoteOperationError.alreadyExists(url)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data().write(to: url.appending(path: FileTreeScanner.noteMarkerName))
        return url
    }

    @discardableResult
    public static func createFolder(named name: String, in parent: URL) throws -> URL {
        guard !isInsideNoteFolder(parent) else { throw NoteOperationError.insideNoteFolder }
        let url = parent.appending(path: name, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw NoteOperationError.alreadyExists(url)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    public static func rename(_ url: URL, to newName: String) throws -> URL {
        let destination = url.deletingLastPathComponent().appending(path: newName)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw NoteOperationError.alreadyExists(destination)
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination.standardizedFileURL
    }

    public static func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// True if `url` or any ancestor is itself a note folder.
    public static func isInsideNoteFolder(_ url: URL) -> Bool {
        var current = url.standardizedFileURL
        while current.pathComponents.count > 1 {
            if FileTreeScanner.isNoteFolder(current) { return true }
            current = current.deletingLastPathComponent()
        }
        return false
    }

    /// "report.pdf", "report 2.pdf", … — first file name not taken in
    /// `directory`. Imports never overwrite (SPEC.md §5.3: originals are
    /// copied, untouched).
    public static func availableFileName(_ proposed: String, in directory: URL) -> String {
        let stem = (proposed as NSString).deletingPathExtension
        let ext = (proposed as NSString).pathExtension
        var candidate = proposed
        var counter = 2
        while FileManager.default.fileExists(atPath: directory.appending(path: candidate).path) {
            candidate = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    /// "2026-07-15 Note", "2026-07-15 Note 2", … — first name not taken in `parent`.
    public static func availableNoteName(in parent: URL, date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let base = "\(formatter.string(from: date)) Note"
        var candidate = base
        var counter = 2
        while FileManager.default.fileExists(atPath: parent.appending(path: candidate).path) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        return candidate
    }
}
