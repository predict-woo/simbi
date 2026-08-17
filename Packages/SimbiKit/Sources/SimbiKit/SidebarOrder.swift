import Foundation

/// Persisted manual ordering of a folder's sidebar children.
///
/// Each organizational folder (and the home root) may hold a hidden
/// `.simbi-order.json` — a JSON array of child names in display order.
/// Children missing from the file keep the default alphabetical sort and
/// follow the listed ones; names that no longer exist are simply ignored
/// and get dropped on the next write. No file → pure default sort, so
/// ordering stays opt-in per folder and travels with the folder on moves.
public enum SidebarOrder {
    public static let fileName = ".simbi-order.json"

    static func fileURL(in folder: URL) -> URL {
        folder.appending(path: fileName)
    }

    public static func read(in folder: URL) -> [String] {
        guard let data = try? Data(contentsOf: fileURL(in: folder)),
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

    /// Reorders `nodes` (already in default order) by the stored order:
    /// listed names first in stored order, unlisted ones after, unchanged.
    public static func apply(to nodes: [FileTreeNode], in folder: URL) -> [FileTreeNode] {
        let order = read(in: folder)
        guard !order.isEmpty else { return nodes }
        var rank: [String: Int] = [:]
        for (index, name) in order.enumerated() where rank[name] == nil {
            rank[name] = index
        }
        var listed = nodes.filter { rank[$0.name] != nil }
        listed.sort { rank[$0.name] ?? 0 < rank[$1.name] ?? 0 }
        return listed + nodes.filter { rank[$0.name] == nil }
    }

    /// Pins `name` to the top of its folder's order, creating the order
    /// file when the folder had none — unlisted siblings keep their
    /// alphabetical order below (`apply`). New notes go through this so
    /// they appear first instead of at their alphabetical slot.
    public static func prepend(_ name: String, in folder: URL) {
        var names = read(in: folder)
        names.removeAll { $0 == name }
        names.insert(name, at: 0)
        write(names, in: folder)
    }

    /// Keeps a renamed item's manual position, if it had one.
    public static func renamed(from oldName: String, to newName: String, in folder: URL) {
        var names = read(in: folder)
        guard let index = names.firstIndex(of: oldName) else { return }
        names[index] = newName
        write(names, in: folder)
    }

    /// Drops a removed item from its folder's stored order, if present.
    public static func removed(_ name: String, in folder: URL) {
        var names = read(in: folder)
        guard names.contains(name) else { return }
        names.removeAll { $0 == name }
        write(names, in: folder)
    }
}
