import Foundation
import Testing

@testable import SimbiKit

@Suite("SidebarOrder")
struct SidebarOrderTests {
    private func makeTempFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "sidebar-order-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("round-trips through disk and clears on empty write")
    func roundTrip() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        SidebarOrder.write(["b", "a"], in: folder)
        #expect(SidebarOrder.read(in: folder) == ["b", "a"])

        SidebarOrder.write([], in: folder)
        #expect(SidebarOrder.read(in: folder) == [])
        #expect(!FileManager.default.fileExists(atPath: SidebarOrder.fileURL(in: folder).path))
    }

    @Test("apply puts listed names first, unlisted keep default order after")
    func applyOrder() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        func node(_ name: String) -> FileTreeNode {
            FileTreeNode(url: folder.appending(path: name), name: name, kind: .note, children: nil)
        }
        let defaultOrder = [node("a"), node("b"), node("c"), node("d")]

        // No order file: untouched.
        #expect(SidebarOrder.apply(to: defaultOrder, in: folder).map(\.name) == ["a", "b", "c", "d"])

        // "gone" is stale and ignored; c and a lead; b and d trail in default order.
        SidebarOrder.write(["c", "gone", "a"], in: folder)
        #expect(SidebarOrder.apply(to: defaultOrder, in: folder).map(\.name) == ["c", "a", "b", "d"])
    }

    @Test("prepend pins a name first, creating the order file if needed")
    func prepend() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // No order file yet: prepend creates one holding just this name.
        SidebarOrder.prepend("new", in: folder)
        #expect(SidebarOrder.read(in: folder) == ["new"])

        SidebarOrder.write(["a", "b"], in: folder)
        SidebarOrder.prepend("new", in: folder)
        #expect(SidebarOrder.read(in: folder) == ["new", "a", "b"])

        // An already-listed name moves to the front instead of duplicating.
        SidebarOrder.prepend("b", in: folder)
        #expect(SidebarOrder.read(in: folder) == ["b", "new", "a"])
    }

    @Test("rename keeps the manual position, removal drops the name")
    func renameAndRemove() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        SidebarOrder.write(["c", "a", "b"], in: folder)
        SidebarOrder.renamed(from: "a", to: "renamed", in: folder)
        #expect(SidebarOrder.read(in: folder) == ["c", "renamed", "b"])

        // Renaming something with no manual position is a no-op.
        SidebarOrder.renamed(from: "unknown", to: "other", in: folder)
        #expect(SidebarOrder.read(in: folder) == ["c", "renamed", "b"])

        SidebarOrder.removed("c", in: folder)
        #expect(SidebarOrder.read(in: folder) == ["renamed", "b"])
    }

    @Test("scanner applies the stored order over the alphabetical default")
    func scannerUsesOrder() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let fm = FileManager.default
        try fm.createDirectory(at: folder.appending(path: "alpha"), withIntermediateDirectories: false)
        try fm.createDirectory(at: folder.appending(path: "beta"), withIntermediateDirectories: false)
        try Data().write(to: folder.appending(path: "loose.txt"))

        // Default: folders alphabetically, then loose files.
        #expect(FileTreeScanner.scan(root: folder).map(\.name) == ["alpha", "beta", "loose.txt"])

        // Manual order wins, even mixing files ahead of folders.
        SidebarOrder.write(["loose.txt", "beta"], in: folder)
        #expect(FileTreeScanner.scan(root: folder).map(\.name) == ["loose.txt", "beta", "alpha"])

        // The order file itself never shows up as a row.
        #expect(!FileTreeScanner.scan(root: folder).map(\.name).contains(SidebarOrder.fileName))
    }
}
