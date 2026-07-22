import AppKit
import Testing

@testable import OutlineViewKit

/// Regression tests for the stale-snapshot crash (see VENDORED.md):
/// `NSOutlineView` keeps the item wrappers it was first handed (matched by
/// id-based equality) and never swaps them for fresh ones, so the data
/// source must answer tree-shape questions from its *current* `items`,
/// not from the stale wrapper AppKit passes back.
@MainActor
@Suite("OutlineViewDataSource stale items")
struct OutlineViewDataSourceTests {
    struct Node: Identifiable, Equatable {
        let id: String
        var children: [Node]?
    }

    private typealias DataSource = OutlineViewDataSource<[Node], NoDropReceiver<Node>>

    private func makeDataSource(_ nodes: [Node]) -> DataSource {
        DataSource(
            items: nodes.map { OutlineViewItem(value: $0, children: .keyPath(\.children)) },
            childSource: .keyPath(\.children))
    }

    private func item(_ node: Node) -> OutlineViewItem<[Node]> {
        OutlineViewItem(value: node, children: .keyPath(\.children))
    }

    @Test("a stale folder wrapper resolves children from the current items")
    func staleWrapperSeesNewChild() {
        let outlineView = NSOutlineView()
        let oldFolder = Node(id: "folder", children: [Node(id: "a", children: nil)])
        let dataSource = makeDataSource([oldFolder])

        // The wrapper NSOutlineView stored at insert time — its value
        // snapshot predates the update below.
        let staleWrapper = item(oldFolder)

        // A note lands in the folder; SwiftUI pushes the new state.
        let newFolder = Node(
            id: "folder",
            children: [Node(id: "a", children: nil), Node(id: "b", children: nil)])
        dataSource.items = [item(newFolder)]

        // Crash case before the fix: index 1 is past the stale snapshot's
        // single-element children array.
        #expect(
            dataSource.outlineView(outlineView, numberOfChildrenOfItem: staleWrapper) == 2)
        let child = dataSource.outlineView(outlineView, child: 1, ofItem: staleWrapper)
        #expect((child as? OutlineViewItem<[Node]>)?.id == "b")
    }

    @Test("a stale nested wrapper resolves through the current tree")
    func staleNestedWrapperResolves() {
        let outlineView = NSOutlineView()
        let oldInner = Node(id: "inner", children: [])
        let root = Node(id: "outer", children: [oldInner])
        let dataSource = makeDataSource([root])
        let staleWrapper = item(oldInner)

        let newInner = Node(id: "inner", children: [Node(id: "note", children: nil)])
        dataSource.items = [item(Node(id: "outer", children: [newInner]))]

        #expect(dataSource.outlineView(outlineView, numberOfChildrenOfItem: staleWrapper) == 1)
        let child = dataSource.outlineView(outlineView, child: 0, ofItem: staleWrapper)
        #expect((child as? OutlineViewItem<[Node]>)?.id == "note")
    }

    @Test("a wrapper for an item no longer in the tree falls back to its snapshot")
    func removedItemFallsBackToSnapshot() {
        let outlineView = NSOutlineView()
        let folder = Node(id: "folder", children: [Node(id: "a", children: nil)])
        let dataSource = makeDataSource([folder])
        let staleWrapper = item(folder)

        // The folder is deleted; AppKit may still ask about the rows it is
        // tearing down, which must stay consistent with the old snapshot.
        dataSource.items = []

        #expect(dataSource.outlineView(outlineView, numberOfChildrenOfItem: staleWrapper) == 1)
        let child = dataSource.outlineView(outlineView, child: 0, ofItem: staleWrapper)
        #expect((child as? OutlineViewItem<[Node]>)?.id == "a")
    }

    @Test("expandability follows the current items")
    func expandabilityFollowsCurrentItems() {
        let outlineView = NSOutlineView()
        let leaf = Node(id: "x", children: nil)
        let dataSource = makeDataSource([leaf])
        let staleWrapper = item(leaf)

        dataSource.items = [item(Node(id: "x", children: []))]

        #expect(dataSource.outlineView(outlineView, isItemExpandable: staleWrapper))
    }
}
