import Foundation
import Testing

@testable import SimbiKit

@Suite("NoteOperations")
struct NoteOperationsTests {
    private func withTempRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "simbi-ops-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test("createNote writes the note.md marker")
    func createNoteWritesMarker() throws {
        try withTempRoot { root in
            let note = try NoteOperations.createNote(named: "Standup", in: root)
            #expect(FileTreeScanner.isNoteFolder(note))
        }
    }

    @Test("note folders cannot nest — directly or transitively")
    func noNestedNotes() throws {
        try withTempRoot { root in
            let note = try NoteOperations.createNote(named: "Standup", in: root)
            #expect(throws: NoteOperationError.insideNoteFolder) {
                try NoteOperations.createNote(named: "Inner", in: note)
            }
            // Even inside a plain subdirectory of a note folder.
            let filesDir = note.appending(path: "files", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
            #expect(throws: NoteOperationError.insideNoteFolder) {
                try NoteOperations.createFolder(named: "Nope", in: filesDir)
            }
        }
    }

    @Test("creating over an existing name throws")
    func duplicateNamesThrow() throws {
        try withTempRoot { root in
            try NoteOperations.createNote(named: "Standup", in: root)
            #expect(throws: NoteOperationError.self) {
                try NoteOperations.createNote(named: "Standup", in: root)
            }
        }
    }

    @Test("rename moves the folder and returns the new URL")
    func renameMoves() throws {
        try withTempRoot { root in
            let note = try NoteOperations.createNote(named: "Old", in: root)
            let renamed = try NoteOperations.rename(note, to: "New")
            #expect(renamed.lastPathComponent == "New")
            #expect(!FileManager.default.fileExists(atPath: note.path))
            #expect(FileTreeScanner.isNoteFolder(renamed))
        }
    }

    @Test("availableNoteName dedupes with a counter")
    func noteNameDedup() throws {
        try withTempRoot { root in
            let date = Date(timeIntervalSince1970: 1_784_000_000)  // fixed for determinism
            let first = NoteOperations.availableNoteName(in: root, date: date)
            try NoteOperations.createNote(named: first, in: root)
            let second = NoteOperations.availableNoteName(in: root, date: date)
            #expect(second == "\(first) 2")
        }
    }
}
