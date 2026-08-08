import Foundation
import Testing

@testable import SimbiKit

@Suite("FileTreeScanner")
struct FileTreeScannerTests {
    /// Creates a unique temp root, runs `body`, and cleans up.
    private func withTempRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "simbi-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func makeNoteFolder(named name: String, in parent: URL) throws {
        let url = parent.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data().write(to: url.appending(path: "note.md"))
    }

    @Test("note folders are leaves; internals never appear as children")
    func noteFoldersAreLeaves() throws {
        try withTempRoot { root in
            try makeNoteFolder(named: "Standup", in: root)
            let noteURL = root.appending(path: "Standup")
            for internalDir in ["files", "context", ".simbi"] {
                try FileManager.default.createDirectory(
                    at: noteURL.appending(path: internalDir), withIntermediateDirectories: true)
            }

            let nodes = FileTreeScanner.scan(root: root)
            #expect(nodes.count == 1)
            #expect(nodes[0].kind == .note)
            #expect(nodes[0].children == nil)
        }
    }

    @Test("organizational folders recurse; hidden entries are skipped")
    func organizationalFoldersRecurse() throws {
        try withTempRoot { root in
            let work = root.appending(path: "Work", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try makeNoteFolder(named: "ProjectX Kickoff", in: work)
            try FileManager.default.createDirectory(
                at: root.appending(path: ".simbi"), withIntermediateDirectories: true)
            try Data().write(to: root.appending(path: ".hidden-file"))

            let nodes = FileTreeScanner.scan(root: root)
            #expect(nodes.count == 1)
            #expect(nodes[0].kind == .folder)
            #expect(nodes[0].children?.count == 1)
            #expect(nodes[0].children?[0].kind == .note)
        }
    }

    @Test("reserved app-managed files (the instruction files) never appear")
    func reservedNamesAreHidden() throws {
        try withTempRoot { root in
            for file in AgentInstructions.allCases {
                try Data().write(to: root.appending(path: file.fileName))
            }
            try Data().write(to: root.appending(path: "notes.md"))

            let names = FileTreeScanner.scan(root: root).map(\.name)
            #expect(names == ["notes.md"])
        }
    }

    @Test("folders sort before loose files, each alphabetically")
    func sortingIsFoldersFirst() throws {
        try withTempRoot { root in
            try Data().write(to: root.appending(path: "a-loose-file.md"))
            try makeNoteFolder(named: "Zebra", in: root)
            try FileTreeScannerTests.createFolder(named: "Alpha", in: root)

            let nodes = FileTreeScanner.scan(root: root)
            #expect(nodes.map(\.name) == ["Alpha", "Zebra", "a-loose-file.md"])
        }
    }

    @Test("find locates nested nodes by URL")
    func findLocatesNestedNodes() throws {
        try withTempRoot { root in
            let work = root.appending(path: "Work", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try makeNoteFolder(named: "Note", in: work)

            let nodes = FileTreeScanner.scan(root: root)
            let target = work.appending(path: "Note").standardizedFileURL
            #expect(FileTreeNode.find(target, in: nodes)?.kind == .note)
            #expect(FileTreeNode.find(root.appending(path: "nope"), in: nodes) == nil)
        }
    }

    private static func createFolder(named name: String, in parent: URL) throws {
        try FileManager.default.createDirectory(
            at: parent.appending(path: name, directoryHint: .isDirectory),
            withIntermediateDirectories: true)
    }
}

@Suite("FileTreeWatcher")
struct FileTreeWatcherTests {
    @Test("fires on file creation under the watched root")
    func firesOnChange() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "simbi-watcher-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let (fired, continuation) = AsyncStream.makeStream(of: Void.self)
        let watcher = FileTreeWatcher(url: root, latency: 0.05) {
            continuation.yield()
        }
        #expect(watcher != nil)

        // FSEvents needs a beat to arm before events are captured.
        try await Task.sleep(for: .milliseconds(300))
        try Data().write(to: root.appending(path: "new-file"))

        let firstEvent = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in fired { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        #expect(firstEvent, "watcher should report the change within 10 s")
        _ = watcher  // keep alive until here
    }
}
