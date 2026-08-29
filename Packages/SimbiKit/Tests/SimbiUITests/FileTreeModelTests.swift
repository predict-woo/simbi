import Foundation
import SimbiKit
import Testing

@testable import SimbiUI

@Suite("FileTreeModel live filesystem")
struct FileTreeModelTests {
    @Test("an externally moved parent keeps the selected note open")
    @MainActor
    func followsExternalMove() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "simbi-tree-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let group = root.appending(path: "Group")
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        let note = try NoteOperations.createNote(named: "Meeting", in: group)
        let model = FileTreeModel(home: SimbiHome(rootURL: root))
        model.refresh()
        model.selection = note

        let movedGroup = root.appending(path: "Renamed Group")
        try FileManager.default.moveItem(at: group, to: movedGroup)
        model.refresh()

        #expect(model.selection?.path == movedGroup.appending(path: "Meeting").path)
        #expect(model.selectedNode?.name == "Meeting")
    }
}
