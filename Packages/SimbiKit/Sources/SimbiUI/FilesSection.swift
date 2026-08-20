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
    @State private var selectedFile: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.rows.isEmpty {
                // Empty state is one quiet row: label, hint, and the same add
                // button — no dedicated shelf height until there are files.
                HStack(spacing: Design.rowGap) {
                    // Deliberately a tier above `SectionLabel` (13pt .body vs
                    // the label's smaller tier) so the row reads as the section
                    // header it replaces; same secondary color.
                    Text("Files")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Add files. Codex turns them into note context.")
                        .font(.meta)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                    addButton
                }
                .padding(.leading, Design.editorInset)
                .padding(.trailing, Design.stripPadding)
            } else {
                HStack {
                    SectionLabel(title: "Files")
                    Spacer()
                    addButton
                }
                // Leading matches the editor's text inset; trailing matches the strip's
                // vertical rhythm so the add button sits square in the corner.
                .padding(.leading, Design.editorInset)
                .padding(.trailing, Design.stripPadding)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Design.rowGap) {
                        ForEach(model.rows) { row in
                            FileTile(model: model, row: row, selection: $selectedFile)
                        }
                    }
                    .padding(.vertical, Design.stripPadding)
                }
                .scrollIndicators(.never)
                .fixedSize(horizontal: false, vertical: true)
                .contentMargins(.horizontal, Design.editorInset, for: .scrollContent)
                .mask {
                    HStack(spacing: 0) {
                        LinearGradient(
                            colors: [.clear, .black],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: Design.editorInset)
                        Color.black
                        LinearGradient(
                            colors: [.black, .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: Design.editorInset)
                    }
                }
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { selectedFile = nil }
                }
            }
            if let error = model.importError {
                Text(error)
                    .font(.meta)
                    .foregroundStyle(Color.statusLive)
                    .lineLimit(2)
                    .padding(.horizontal, Design.editorInset)
            }
        }
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

    private var addButton: some View {
        Button {
            showImporter = true
        } label: {
            Image(systemName: "plus")
                .font(.body)
        }
        .buttonStyle(HoverCircleButtonStyle())
        .help("Add Files…")
        .accessibilityLabel("Add Files")
    }
}

/// One shelf tile: Quick Look thumbnail, name caption, conversion status
/// overlay, and the file's actions in a context menu. Double-click opens
/// the original; the overlay shows converting/failed and nothing when done.
private struct FileTile: View {
    let model: FilesModel
    let row: FilesModel.Row
    @Binding var selection: String?

    private var isSelected: Bool { selection == row.name }

    private var fileURL: URL { model.fileURL(for: row.name) }

    private var thumbnailOpacity: Double {
        if case .converting = row.status { return 0.35 }
        if row.importStatus == .analyzing || row.importStatus == .transcribing { return 0.35 }
        return 1
    }

    /// One busy/failed/done summary across both routes so the overlay and
    /// menu speak one language: conversions from `status`, media imports
    /// from `importStatus`, unsupported media permanently failed.
    private var isBusy: Bool {
        row.status == .converting || row.importStatus == .analyzing
            || row.importStatus == .transcribing
    }

    private var isFailed: Bool {
        row.route == .unsupportedMedia || row.status == .failed || row.importStatus == .failed
    }

    /// Tooltip status word for the busy overlay (media rows distinguish the
    /// two phases; conversions keep their old word).
    private var busyHelp: String {
        switch row.importStatus {
        case .analyzing: "Analyzing"
        case .transcribing: "Transcribing"
        default: "Converting"
        }
    }

    private var failedHelp: String {
        switch row.route {
        case .unsupportedMedia: "Format not supported for transcription"
        case .mediaImport: "Import failed"
        case .documentConversion: "Conversion failed"
        }
    }

    var body: some View {
        VStack(spacing: Design.innerGap) {
            FileThumbnail(
                url: fileURL,
                size: CGSize(width: Design.fileTileWidth, height: Design.fileThumbHeight)
            )
            .opacity(thumbnailOpacity)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: Design.Radius.card)
                        .fill(Color.selectionBackplate)
                }
            }
            .overlay { statusOverlay }
            Text(row.name)
                .font(.meta)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? Color.selectionInk : Color.primary)
                .padding(.horizontal, Design.iconGap)
                .padding(.vertical, 1)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: Design.Radius.row)
                            .fill(Color.accentColor)
                    }
                }
        }
        .frame(width: Design.fileTileWidth)
        .contentShape(Rectangle())
        .help(row.route == .unsupportedMedia ? failedHelp : row.name)
        .onTapGesture(count: 2) {
            NSWorkspace.shared.open(fileURL)
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                selection = row.name
            }
        )
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(fileURL) }
            if case .done = row.status {
                Button("Open Context") {
                    ContextEditorWindowManager.shared.open(
                        fileURL: model.contextURL(for: row.name),
                        title: "Context: \(row.name)")
                }
            }
            if case .failed = row.status {
                Button("Retry Conversion") { model.retry(row.name) }
            }
            if row.importStatus == .failed {
                Button("Retry Import") { model.retry(row.name) }
            }
            // Document rows only: media imports have no Codex thread.
            if row.threadId != nil {
                Button("View Codex Thread") { model.openThreadViewer(row.name) }
            }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
            Divider()
            Button("Move to Trash") {
                if selection == row.name { selection = nil }
                model.delete(row.name)
            }
        }
    }

    // Centered so status reads on any preview; the glass/material circle
    // guarantees contrast. 36/18 are one-off display-glyph values per
    // docs/design-system.md ("One-off display glyphs ... stay inline").
    // Media rows reuse the conversion rows' exact busy/failed treatments;
    // only the tooltip word differs (Analyzing/Transcribing).
    @ViewBuilder private var statusOverlay: some View {
        if isBusy {
            ProgressView()
                .controlSize(.small)
                .frame(width: 36, height: 36)
                .floatingChrome(in: Circle())
                .help(busyHelp)
        } else if isFailed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.statusLive)
                .frame(width: 36, height: 36)
                .floatingChrome(in: Circle())
                .help(failedHelp)
        }
    }
}
