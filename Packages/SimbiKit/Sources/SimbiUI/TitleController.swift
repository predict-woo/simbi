import CodexKit
import Foundation
import Observation
import SimbiKit

/// Auto-titles one note: when a recording stops (transcript drained) and
/// the note still carries the default "New Note" name, a one-shot
/// NoteTitler thread proposes a title and the folder is renamed through
/// the sidebar's rename path. Failures are silent by design — the note
/// simply keeps its default name (degraded Codex is never a failure).
/// Shared per note like SummaryController so a run survives view
/// recreation.
@MainActor
@Observable
public final class TitleController {
    private static var controllers: [URL: TitleController] = [:]

    public static func shared(noteFolderURL: URL) -> TitleController {
        if let existing = controllers[noteFolderURL] {
            return existing
        }
        let controller = TitleController(noteFolderURL: noteFolderURL)
        controllers[noteFolderURL] = controller
        return controller
    }

    private(set) var working = false

    let noteFolderURL: URL
    private let titler: NoteTitler

    /// Renames the note folder — assigned by the note view, routed
    /// through FileTreeModel so sidebar order and selection follow.
    var renameNote: ((String) -> Void)?

    init(noteFolderURL: URL) {
        self.noteFolderURL = noteFolderURL
        let settings =
            (try? SimbiSettings.load(from: SimbiHome().settingsFileURL)) ?? .default
        self.titler = NoteTitler(
            noteFolderURL: noteFolderURL, client: CodexServices.appServer,
            model: settings.titleModel)
    }

    /// Same two checks as the note view's degraded banner.
    var codexAvailable: Bool {
        CodexInstallation.standard.isBinaryInstalled
            && CodexInstallation.standard.loadAuth() != nil
    }

    /// A note the user (or a previous run) has renamed is never touched;
    /// otherwise the same gates as AI notes: cues exist, Codex works, no
    /// run in flight, no active recording.
    nonisolated static func shouldAutoGenerate(
        titleIsDefault: Bool, transcriptHasCues: Bool, codexAvailable: Bool,
        alreadyWorking: Bool, recordingActive: Bool
    ) -> Bool {
        titleIsDefault && transcriptHasCues && codexAvailable && !alreadyWorking
            && !recordingActive
    }

    /// The recording controller's clean-stop hook.
    func recordingDidStop() {
        guard
            Self.shouldAutoGenerate(
                titleIsDefault: NoteOperations.isDefaultNoteName(noteFolderURL.lastPathComponent),
                transcriptHasCues: transcriptHasCues(), codexAvailable: codexAvailable,
                alreadyWorking: working,
                recordingActive: RecordingController.isCapturing(noteFolderURL: noteFolderURL))
        else { return }
        working = true
        Task {
            defer { working = false }
            do {
                let title = try await titler.generateTitle()
                applyGeneratedTitle(title, currentFolderName: noteFolderURL.lastPathComponent)
            } catch {
                print("TitleController: titling failed for \(noteFolderURL.path): \(error)")
            }
        }
    }

    /// Applies a generated title, re-checking that the note is still on
    /// its default name — a rename by the user (or anything else) during
    /// the run wins, and a restarted recording defers to its own stop.
    /// Collisions dedupe to "Title 2" style rather than failing.
    func applyGeneratedTitle(_ title: String, currentFolderName: String) {
        guard NoteOperations.isDefaultNoteName(currentFolderName),
            !RecordingController.isCapturing(noteFolderURL: noteFolderURL),
            let renameNote
        else { return }
        let unique = NoteOperations.availableName(
            title, in: noteFolderURL.deletingLastPathComponent())
        renameNote(unique)
    }

    private func transcriptHasCues() -> Bool {
        guard
            let text = try? String(
                contentsOf: noteFolderURL.appending(path: "transcript.vtt"), encoding: .utf8),
            let document = try? VTTParser.parse(text)
        else { return false }
        return document.entries.contains {
            if case .cue = $0 { return true }
            return false
        }
    }
}
