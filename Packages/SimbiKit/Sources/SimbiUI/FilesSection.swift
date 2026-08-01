import AppKit
import SimbiKit
import SwiftUI
import UniformTypeIdentifiers

/// The note view's files section (SPEC.md §6): drag-drop target + file
/// picker, one thumbnail tile per `files/` entry with conversion status
/// and actions in a context menu.
struct FilesSection: View {
    let model: FilesModel
    @State private var showImporter = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(title: "Files")
                Spacer()
                Button {
                    showImporter = true
                } label: {
                    Label("Add Files…", systemImage: "plus")
                        .font(.meta)
                }
                .buttonStyle(.borderless)
            }
            if model.rows.isEmpty {
                Text("Drop files here — Codex turns them into note context.")
                    .font(.meta)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Design.rowGap) {
                        ForEach(model.rows) { row in
                            FileTile(model: model, row: row)
                        }
                    }
                    .padding(.vertical, Design.stripPadding)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.importError {
                Text(error)
                    .font(.meta)
                    .foregroundStyle(Color.statusLive)
                    .lineLimit(2)
            }
        }
        // Matches the editor's text inset so the section shares its left edge.
        .padding(.horizontal, Design.editorInset)
        .padding(.vertical, Design.stripPadding)
        .background(
            Color.accentColor.opacity(isDropTargeted ? 0.08 : 0)
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.accentColor.opacity(isDropTargeted ? 1 : 0))
                .frame(height: 2)
        }
        .animation(Design.Anim.quick, value: isDropTargeted)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                model.importFiles(urls)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.isFileURL }
            guard !files.isEmpty else { return false }
            model.importFiles(files)
            return true
        } isTargeted: {
            isDropTargeted = $0
        }
    }
}

/// One shelf tile: Quick Look thumbnail, name caption, conversion status
/// overlay, and the file's actions in a context menu. Double-click opens
/// the original; the overlay shows converting/failed and nothing when done.
private struct FileTile: View {
    let model: FilesModel
    let row: FilesModel.Row

    private var fileURL: URL { model.fileURL(for: row.name) }

    private var thumbnailOpacity: Double {
        if case .converting = row.status { return 0.35 }
        return 1
    }

    var body: some View {
        VStack(spacing: Design.innerGap) {
            FileThumbnail(
                url: fileURL,
                size: CGSize(width: Design.fileTileWidth, height: Design.fileThumbHeight)
            )
            .opacity(thumbnailOpacity)
            .overlay { statusOverlay }
            Text(row.name)
                .font(.meta)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
        }
        .frame(width: Design.fileTileWidth)
        .contentShape(Rectangle())
        .help(row.name)
        .onTapGesture(count: 2) {
            NSWorkspace.shared.open(fileURL)
        }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(fileURL) }
            if case .done = row.status {
                Button("Open Context") {
                    NSWorkspace.shared.open(model.contextURL(for: row.name))
                }
            }
            if case .failed = row.status {
                Button("Retry Conversion") { model.retry(row.name) }
            }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        }
    }

    // Centered so status reads on any preview; the glass/material circle
    // guarantees contrast. 36/18 are one-off display-glyph values per
    // docs/design-system.md ("One-off display glyphs ... stay inline").
    @ViewBuilder private var statusOverlay: some View {
        switch row.status {
        case .converting:
            ProgressView()
                .controlSize(.small)
                .frame(width: 36, height: 36)
                .statusCircleChrome()
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.statusLive)
                .frame(width: 36, height: 36)
                .statusCircleChrome()
        case .done:
            EmptyView()
        }
    }
}

extension View {
    /// Status-circle chrome: Liquid Glass where the OS has it (macOS 26),
    /// the closest material further back.
    @ViewBuilder fileprivate func statusCircleChrome() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: Circle())
        } else {
            self.background(.regularMaterial, in: Circle())
        }
    }
}
