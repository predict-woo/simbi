import Foundation

/// Persisted manual ordering and pin state for a folder's sidebar children.
///
/// Each organizational folder (and the home root) may hold a hidden
/// `.simbi-order.json` — a JSON array of child names in display order.
/// Children missing from the file keep the default alphabetical sort and
/// follow the listed ones; names that no longer exist are simply ignored
/// and get dropped on the next write. No file → pure default sort, so
/// ordering stays opt-in per folder and travels with the folder on moves.
/// Pin state is kept separately in `.simbi-pins.json`, so pinning an item
/// never overwrites its manual position.
public enum SidebarOrder {
    public static let fileName = ".simbi-order.json"
    public static let pinsFileName = ".simbi-pins.json"

    static func fileURL(in folder: URL) -> URL {
        folder.appending(path: fileName)
    }

    static func pinsFileURL(in folder: URL) -> URL {
        folder.appending(path: pinsFileName)
    }

    public static func read(in folder: URL) -> [String] {
        guard let data = try? Data(contentsOf: fileURL(in: folder)),
            let names = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return names
    }

    static func readPinned(in folder: URL) -> [String] {
        guard let data = try? Data(contentsOf: pinsFileURL(in: folder)),
            let names = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return names
    }

    public static func write(_ names: [String], in folder: URL) {
        let url = fileURL(in: folder)
        guard !names.isEmpty else {
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    Log.files.error("SidebarOrder: removing \(url.path) failed: \(error)")
                }
            }
            return
        }
        do {
            let data = try JSONEncoder().encode(names)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.files.error("SidebarOrder: writing \(url.path) failed: \(error)")
        }
    }

    private static func writePinned(_ names: [String], in folder: URL) {
        let url = pinsFileURL(in: folder)
        guard !names.isEmpty else {
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    Log.files.error("SidebarOrder: removing \(url.path) failed: \(error)")
                }
            }
            return
        }
        do {
            let data = try JSONEncoder().encode(names)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.files.error("SidebarOrder: writing \(url.path) failed: \(error)")
        }
    }

    /// Reorders `nodes` (already in default order) by manual order, then
    /// overlays pinned names at the top. Unlisted and unpinned items keep
    /// their current relative order.
    public static func apply(to nodes: [FileTreeNode], in folder: URL) -> [FileTreeNode] {
        let order = read(in: folder)
        let ordered: [FileTreeNode]
        if order.isEmpty {
            ordered = nodes
        } else {
            var rank: [String: Int] = [:]
            for (index, name) in order.enumerated() where rank[name] == nil {
                rank[name] = index
            }
            var listed = nodes.filter { rank[$0.name] != nil }
            listed.sort { rank[$0.name] ?? 0 < rank[$1.name] ?? 0 }
            ordered = listed + nodes.filter { rank[$0.name] == nil }
        }

        let pinned = readPinned(in: folder)
        guard !pinned.isEmpty else { return ordered }
        var pinnedRank: [String: Int] = [:]
        for (index, name) in pinned.enumerated() where pinnedRank[name] == nil {
            pinnedRank[name] = index
        }
        var pinnedNodes = ordered.filter { pinnedRank[$0.name] != nil }
        pinnedNodes.sort { pinnedRank[$0.name] ?? 0 < pinnedRank[$1.name] ?? 0 }
        let pinnedNames = Set(pinned)
        return pinnedNodes + ordered.filter { !pinnedNames.contains($0.name) }
    }

    /// Prepends `name` to its folder's manual order, creating the order file
    /// when the folder had none. New notes use this so they appear first
    /// instead of at their alphabetical slot.
    public static func prepend(_ name: String, in folder: URL) {
        var names = read(in: folder)
        names.removeAll { $0 == name }
        names.insert(name, at: 0)
        write(names, in: folder)
    }

    /// Returns whether `name` is pinned within its immediate parent folder.
    public static func isPinned(_ name: String, in folder: URL) -> Bool {
        readPinned(in: folder).contains(name)
    }

    /// Pins `name` to the top of its immediate parent folder. Pin order is
    /// independent from manual drag order and newest pins appear first.
    public static func pin(_ name: String, in folder: URL) {
        var names = readPinned(in: folder)
        names.removeAll { $0 == name }
        names.insert(name, at: 0)
        writePinned(names, in: folder)
    }

    /// Removes a pin without changing the item's manual order.
    public static func unpin(_ name: String, in folder: URL) {
        var names = readPinned(in: folder)
        guard names.contains(name) else { return }
        names.removeAll { $0 == name }
        writePinned(names, in: folder)
    }

    /// Keeps a renamed item's manual position, if it had one.
    public static func renamed(from oldName: String, to newName: String, in folder: URL) {
        var names = read(in: folder)
        if let index = names.firstIndex(of: oldName) {
            names[index] = newName
            write(names, in: folder)
        }

        var pinned = readPinned(in: folder)
        if let index = pinned.firstIndex(of: oldName) {
            pinned[index] = newName
            writePinned(pinned, in: folder)
        }
    }

    /// Drops a removed item from its folder's stored order, if present.
    public static func removed(_ name: String, in folder: URL) {
        var names = read(in: folder)
        if names.contains(name) {
            names.removeAll { $0 == name }
            write(names, in: folder)
        }

        var pinned = readPinned(in: folder)
        if pinned.contains(name) {
            pinned.removeAll { $0 == name }
            writePinned(pinned, in: folder)
        }
    }
}
