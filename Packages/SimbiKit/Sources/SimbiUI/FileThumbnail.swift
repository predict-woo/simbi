import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Finder-style file thumbnail: the workspace file-type icon immediately,
/// upgraded to a Quick Look content preview when the file has one.
struct FileThumbnail: View {
    let url: URL
    let size: CGSize

    @State private var preview: NSImage?

    var body: some View {
        Image(nsImage: preview ?? NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .scaledToFit()
            .frame(width: size.width, height: size.height)
            .task(id: url) {
                preview = await FileThumbnailLoader.shared.thumbnail(for: url, size: size)
            }
    }
}

/// Generates and caches Quick Look thumbnails. Files in `files/` are
/// copied once at import and never modified, so the cache is keyed by
/// path with no invalidation; a miss (unsupported type, generation
/// failure) is cached as absent and the workspace icon stands.
@MainActor
private final class FileThumbnailLoader {
    static let shared = FileThumbnailLoader()
    private var cache: [String: NSImage?] = [:]

    func thumbnail(for url: URL, size: CGSize) async -> NSImage? {
        if let cached = cache[url.path] { return cached }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: size, scale: 2, representationTypes: .thumbnail)
        let image = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request).nsImage
        cache[url.path] = image
        return image
    }
}
