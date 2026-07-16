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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Files")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showImporter = true
                } label: {
                    Label("Add Files…", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            if model.rows.isEmpty {
                Text("Drop files here — Codex converts them into note context.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.rows) { row in
                            FileRow(model: model, row: row)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
            if let error = model.importError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : .clear,
                    style: StrokeStyle(lineWidth: 1.5, dash: [5])
                )
                .padding(2)
        )
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
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
            Text(row.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            switch row.status {
            case .converting:
                ProgressView()
                    .controlSize(.small)
                Text("converting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .done:
                Button {
                    NSWorkspace.shared.open(model.contextURL(for: row.name))
                } label: {
                    Label("context", systemImage: "doc.text")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Open the converted markdown")
            case .failed:
                Text("failed")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button {
                    model.retry(row.name)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Retry conversion")
            }
        }
        .padding(.vertical, 2)
    }
}
