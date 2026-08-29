import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Finder-style file thumbnail: the workspace file-type icon immediately,
/// upgraded to a Quick Look content preview when the file has one.
struct FileThumbnail: View {
    let url: URL
    let size: CGSize
    let revision: FilesModel.FileRevision

    @State private var preview: NSImage?

    var body: some View {
        Image(nsImage: preview ?? NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .scaledToFit()
            .frame(width: size.width, height: size.height)
            .task(id: revision) {
                preview = nil
                preview = await FileThumbnailLoader.thumbnail(for: url, size: size)
            }
    }
}

/// Generates a preview for one observed file revision. The view holds the
/// image until FilesModel reports that the file changed on disk.
private enum FileThumbnailLoader {
    static func thumbnail(for url: URL, size: CGSize) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: size, scale: 2, representationTypes: .thumbnail)
        request.iconMode = true
        let image = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request).nsImage
        guard !Task.isCancelled else { return nil }
        return image
    }
}
