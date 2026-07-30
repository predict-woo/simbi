import AppKit
import SimbiKit
import SwiftUI
import UniformTypeIdentifiers

/// The note view's files section (SPEC.md §6): drag-drop target + file
/// picker, one row per `files/` entry with conversion status and a link to
/// its `context/` markdown.
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.rows) { row in
                            FileRow(model: model, row: row)
                        }
                    }
                }
                .frame(maxHeight: 140)
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

private struct FileRow: View {
    let model: FilesModel
    let row: FilesModel.Row

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(row.name)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            switch row.status {
            case .converting:
                ProgressView()
                    .controlSize(.mini)
                Text("Converting…")
                    .font(.meta)
                    .foregroundStyle(.secondary)
            case .done:
                Button {
                    NSWorkspace.shared.open(model.contextURL(for: row.name))
                } label: {
                    Text("Open Context")
                        .font(.meta)
                }
                .buttonStyle(.link)
                .help("Open the converted markdown")
            case .failed:
                Text("Failed")
                    .font(.meta)
                    .foregroundStyle(Color.statusLive)
                Button {
                    model.retry(row.name)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.meta)
                }
                .buttonStyle(.borderless)
                .help("Retry conversion")
            }
        }
        .padding(.vertical, 1)
    }

    /// File-type icon by extension, so the row hints at what was dropped.
    private var icon: String {
        switch (row.name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp": "photo"
        case "pdf": "doc.richtext"
        case "doc", "docx", "pages": "doc.text"
        case "xls", "xlsx", "numbers", "csv": "tablecells"
        case "ppt", "pptx", "key": "rectangle.on.rectangle"
        case "mp3", "m4a", "wav", "opus": "waveform"
        case "mp4", "mov": "film"
        case "zip", "tar", "gz": "archivebox"
        default: "doc"
        }
    }
}
