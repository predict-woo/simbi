import CodexKit
import Foundation
import Observation
import SimbiKit

/// Owns AI-notes generation for one note (AI Notes spec §3): triggers the
/// NoteSummarizer, writes summary.md (the app is the file's only writer),
/// and exposes tab-strip state. Shared per note like RecordingController
/// so a generation survives view recreation.
@MainActor
@Observable
public final class SummaryController {
    public enum Status: Equatable {
        case idle
        case working
        case failed(String)
    }

    private static var controllers: [URL: SummaryController] = [:]

    public static func shared(noteFolderURL: URL) -> SummaryController {
        if let existing = controllers[noteFolderURL] {
            return existing
        }
        let controller = SummaryController(noteFolderURL: noteFolderURL)
        controllers[noteFolderURL] = controller
        return controller
    }

    private(set) var status: Status = .idle
    /// Bumps after each successful summary.md write; the note view reloads
    /// the AI Notes document when it changes.
    private(set) var generationCount = 0

    let noteFolderURL: URL
    private let summarizer: NoteSummarizer

    init(noteFolderURL: URL) {
        self.noteFolderURL = noteFolderURL
        self.summarizer = NoteSummarizer(
            noteFolderURL: noteFolderURL, client: CodexServices.appServer)
    }

    var summaryFileURL: URL { noteFolderURL.appending(path: "summary.md") }

    var summaryExists: Bool {
        FileManager.default.fileExists(atPath: summaryFileURL.path)
    }

    /// Same two checks as the note view's degraded banner.
    var codexAvailable: Bool {
        CodexInstallation.standard.isBinaryInstalled
            && CodexInstallation.standard.loadAuth() != nil
    }

    /// Degraded or empty recordings never auto-generate (spec §3); a run
    /// already in flight is never doubled.
    nonisolated static func shouldAutoGenerate(
        transcriptHasCues: Bool, codexAvailable: Bool, alreadyWorking: Bool
    ) -> Bool {
        transcriptHasCues && codexAvailable && !alreadyWorking
    }

    /// The recording controller's clean-stop hook.
    func recordingDidStop() {
        let hasCues = transcriptHasCues()
        guard
            Self.shouldAutoGenerate(
                transcriptHasCues: hasCues, codexAvailable: codexAvailable,
                alreadyWorking: status == .working)
        else { return }
        generate()
    }

    /// The tab strip's regenerate button.
    func regenerate() {
        guard status != .working, codexAvailable else { return }
        generate()
    }

    /// A failed attempt keeps the strip (and its retry) alive only while
    /// the note stays open (spec §4).
    func clearFailureOnClose() {
        if case .failed = status {
            status = .idle
        }
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

    private func generate() {
        status = .working
        let myNotes =
            (try? String(
                contentsOf: noteFolderURL.appending(path: FileTreeScanner.noteMarkerName),
                encoding: .utf8)) ?? ""
        let transcript =
            (try? String(
                contentsOf: noteFolderURL.appending(path: "transcript.vtt"),
                encoding: .utf8)) ?? ""
        let current = try? String(contentsOf: summaryFileURL, encoding: .utf8)
        Task {
            do {
                let document = try await summarizer.generate(
                    myNotes: myNotes, transcript: transcript, currentSummary: current)
                try document.write(to: summaryFileURL, atomically: true, encoding: .utf8)
                generationCount += 1
                status = .idle
            } catch {
                status = .failed("AI notes couldn't be updated.")
            }
        }
    }

    // Test seams: status transitions without a live app-server.
    func markFailedForTesting(_ message: String) { status = .failed(message) }
    func markWorkingForTesting() { status = .working }
}
