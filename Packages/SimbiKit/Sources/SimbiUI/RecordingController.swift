import AVFoundation
import CodexKit
import Foundation
import Observation
import SimbiAudio
import SimbiKit

/// Owns the mic capture and recording pipeline for one open note and
/// exposes UI-facing state (SPEC.md §6: Record/Stop/Resume with live
/// elapsed time and speaker indicator).
@MainActor
@Observable
public final class RecordingController {
    /// One controller (and pipeline) per note folder, however many times
    /// the note view is recreated — two pipelines writing one note's files
    /// would corrupt the timeline. Controllers are kept for the app's
    /// lifetime; they are tiny when idle.
    private static var controllers: [URL: RecordingController] = [:]

    public static func shared(noteFolderURL: URL) -> RecordingController {
        if let existing = controllers[noteFolderURL] {
            return existing
        }
        let controller = RecordingController(noteFolderURL: noteFolderURL)
        controllers[noteFolderURL] = controller
        return controller
    }

    public enum Status: Equatable {
        case idle
        /// Requesting mic permission / loading diarizer models (first run
        /// downloads them).
        case preparing
        case recording
        case stopping
        case failed(String)
    }

    private(set) var status: Status = .idle
    /// Note-timeline seconds, live while recording.
    private(set) var elapsed: TimeInterval = 0
    /// Tentative live indicator slot ("Speaker N speaking…"), display-only.
    private(set) var tentativeSpeaker: Int?
    /// True when the note already has a recording (button says Resume).
    private(set) var hasRecording: Bool
    /// Source toggle (SPEC.md §3.1: mic / mic+system); default from
    /// settings.json, changes persist back as the new default.
    var systemAudioEnabled: Bool {
        didSet { persistAudioSource() }
    }
    /// Set when mic+system was requested but the tap couldn't start —
    /// recording proceeds mic-only with this banner (SPEC.md §7).
    private(set) var systemAudioBanner: String?

    private let noteFolderURL: URL
    private let pipeline: RecordingPipeline
    private var capture: MixedCapture?
    private var ingestTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?

    public init(noteFolderURL: URL) {
        self.noteFolderURL = noteFolderURL
        self.pipeline = RecordingPipeline(
            noteFolderURL: noteFolderURL,
            transcriber: CodexTranscriber(),
            diarizer: SortformerStream())
        let state = (try? NoteRecordingState.load(noteFolder: noteFolderURL)) ?? .init()
        self.hasRecording = state.sessionCount > 0 || state.activeSession != nil
        self.elapsed = TimeInterval(state.totalSamples) / 16000
        let settings =
            (try? SimbiSettings.load(from: SimbiHome().settingsFileURL)) ?? .default
        self.systemAudioEnabled = settings.audioSource == .micAndSystem
    }

    private func persistAudioSource() {
        let home = SimbiHome()
        var settings = (try? SimbiSettings.load(from: home.settingsFileURL)) ?? .default
        settings.audioSource = systemAudioEnabled ? .micAndSystem : .mic
        try? settings.save(to: home.settingsFileURL)
    }

    public func toggle() {
        switch status {
        case .idle, .failed:
            Task { await start() }
        case .recording:
            Task { await stop() }
        case .preparing, .stopping:
            break
        }
    }

    private func start() async {
        status = .preparing
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            status = .failed("Microphone access denied — enable it in System Settings.")
            return
        }
        do {
            // Fixer (SPEC.md §5.2): reuses the note's saved thread if any.
            let savedThreadId = (try? NoteRecordingState.load(noteFolder: noteFolderURL))?
                .fixerThreadId
            await pipeline.attachFixer(
                TranscriptFixer(
                    noteFolderURL: noteFolderURL, client: CodexServices.appServer,
                    savedThreadId: savedThreadId))
            try await pipeline.start()
            let capture = MixedCapture()
            self.capture = capture
            let stream = try capture.start(
                source: systemAudioEnabled ? .micAndSystem : .mic)
            systemAudioBanner = capture.systemAudioFailure
            status = .recording
            hasRecording = true

            liveTask = Task { [pipeline] in
                for await update in await pipeline.liveUpdates() {
                    self.elapsed = update.elapsed
                    self.tentativeSpeaker = update.tentativeSpeaker
                }
            }
            ingestTask = Task { [pipeline] in
                for await batch in stream {
                    do {
                        try await pipeline.ingest(samples: batch)
                    } catch {
                        self.status = .failed("Recording failed: \(error)")
                        break
                    }
                }
            }
        } catch {
            status = .failed("Could not start recording: \(error)")
        }
    }

    private func stop() async {
        status = .stopping
        capture?.stop()  // finishes the stream; ingest drains what's left
        await ingestTask?.value
        ingestTask = nil
        liveTask?.cancel()
        liveTask = nil
        capture = nil
        do {
            try await pipeline.stop()
            status = .idle
            tentativeSpeaker = nil
        } catch {
            status = .failed("Could not stop cleanly: \(error)")
        }
    }

}
