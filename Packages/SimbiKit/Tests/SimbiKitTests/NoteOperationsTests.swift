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

    @Test("availableName counts up without treating dots as extensions")
    func availableNameCountsUp() throws {
        try withTempRoot { root in
            #expect(NoteOperations.availableName("Meeting 7.18", in: root) == "Meeting 7.18")
            try NoteOperations.createNote(named: "Meeting 7.18", in: root)
            #expect(NoteOperations.availableName("Meeting 7.18", in: root) == "Meeting 7.18 2")
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

    @Test("availableFileName dedupes before the extension")
    func fileNameDedup() throws {
        try withTempRoot { root in
            #expect(NoteOperations.availableFileName("report.pdf", in: root) == "report.pdf")
            try Data().write(to: root.appending(path: "report.pdf"))
            #expect(NoteOperations.availableFileName("report.pdf", in: root) == "report 2.pdf")
            try Data().write(to: root.appending(path: "report 2.pdf"))
            #expect(NoteOperations.availableFileName("report.pdf", in: root) == "report 3.pdf")
            try Data().write(to: root.appending(path: "README"))
            #expect(NoteOperations.availableFileName("README", in: root) == "README 2")
        }
    }

    @Test("availableNoteName is \"New Note\" with a counter for collisions")
    func noteNameDedup() throws {
        try withTempRoot { root in
            #expect(NoteOperations.availableNoteName(in: root) == "New Note")
            try NoteOperations.createNote(named: "New Note", in: root)
            #expect(NoteOperations.availableNoteName(in: root) == "New Note 2")
        }
    }

    @Test("isDefaultNoteName matches exactly the names availableNoteName produces")
    func defaultNoteNamePredicate() {
        #expect(NoteOperations.isDefaultNoteName("New Note"))
        #expect(NoteOperations.isDefaultNoteName("New Note 2"))
        #expect(NoteOperations.isDefaultNoteName("New Note 41"))
        #expect(!NoteOperations.isDefaultNoteName("New Note "))
        #expect(!NoteOperations.isDefaultNoteName("new note"))
        #expect(!NoteOperations.isDefaultNoteName("New Notes"))
        #expect(!NoteOperations.isDefaultNoteName("Design sync"))
        #expect(!NoteOperations.isDefaultNoteName("New Note 2b"))
        #expect(!NoteOperations.isDefaultNoteName("2026-08-15 Note"))
    }
}
