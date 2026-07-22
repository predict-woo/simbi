import Foundation
import Testing

@testable import SimbiKit

@Suite("FileTreeNode.containsNote")
struct FileTreeContainsNoteTests {
    private func node(
        _ name: String, kind: FileTreeNode.Kind, children: [FileTreeNode]? = nil
    ) -> FileTreeNode {
        FileTreeNode(
            url: URL(filePath: "/Simbi/\(name)"), name: name, kind: kind, children: children)
    }

    @Test("empty tree has no notes")
    func emptyTree() {
        #expect(!FileTreeNode.containsNote(in: []))
    }

    @Test("folders and loose files alone don't count")
    func foldersAndFilesOnly() {
        let tree = [
            node("Folder", kind: .folder, children: [node("deep.txt", kind: .file)]),
            node("loose.txt", kind: .file),
        ]
        #expect(!FileTreeNode.containsNote(in: tree))
    }

    @Test("a top-level note counts")
    func topLevelNote() {
        #expect(FileTreeNode.containsNote(in: [node("My Note", kind: .note)]))
    }

    @Test("a note nested in folders counts")
    func nestedNote() {
        let tree = [
            node(
                "Outer", kind: .folder,
                children: [
                    node("Inner", kind: .folder, children: [node("Deep Note", kind: .note)])
                ])
        ]
        #expect(FileTreeNode.containsNote(in: tree))
    }
}
