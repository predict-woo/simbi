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

    /// True while any open note is capturing. The auto-updater reads this to
    /// keep an install from ever interrupting a meeting (`UpdateGate`).
    public static var isAnyRecording: Bool {
        controllers.values.contains { $0.status.isCapturing }
    }

    public enum Status: Equatable {
        case idle
        /// Requesting mic permission. Models come preloaded from
        /// `SpeechModelPool` (warmed at app launch); only the very first
        /// run may still download here.
        case preparing
        case recording
        case stopping
        case failed(String)

        /// Audio is (or is about to be) flowing — the window in which an app
        /// relaunch would cost the user their meeting.
        var isCapturing: Bool {
            switch self {
            case .preparing, .recording, .stopping: true
            case .idle, .failed: false
            }
        }
    }

    private(set) var status: Status = .idle {
        didSet { RecordingActivity.shared.refresh() }
    }
    /// Note-timeline seconds, live while recording.
    private(set) var elapsed: TimeInterval = 0
    /// Tentative live indicator slot ("Speaker N speaking…"), display-only.
    private(set) var tentativeSpeaker: Int?
    /// True when the note already has a recording (button says Resume).
    private(set) var hasRecording: Bool
    /// Recording sources (SPEC.md §3.1: mic and system audio are chosen
    /// independently; at least one stays on — the UI disables the last
    /// active option). Defaults come from settings.json and changes persist
    /// back as the new default.
    var micEnabled: Bool {
        didSet { persistSources() }
    }
    /// Specific input device UID; nil follows the system default.
    var micDeviceUID: String? {
        didSet { persistSources() }
    }
    var systemAudioEnabled: Bool {
        didSet { persistSources() }
    }
    /// Set when a requested source degraded at start (system tap couldn't
    /// start, saved mic not connected) — recording proceeds with what's
    /// left under this banner (SPEC.md §7).
    private(set) var systemAudioBanner: String?

    /// Input devices for the source menu, re-read on each open so plugging
    /// in a mic shows up without a restart.
    var availableMicrophones: [AudioInputDevice] {
        AudioInputDevices.list()
    }

    /// Fixer status + activity feed for the header button/popover.
    let fixerActivity = FixerActivityModel()

    /// Exposed so the header's fixer button can open the note's activity
    /// window (keyed by this URL).
    let noteFolderURL: URL
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
        self.micEnabled = settings.micEnabled
        self.micDeviceUID = settings.micDeviceUID
        self.systemAudioEnabled = settings.systemAudioEnabled
    }

    private func persistSources() {
        let home = SimbiHome()
        var settings = (try? SimbiSettings.load(from: home.settingsFileURL)) ?? .default
        settings.micEnabled = micEnabled
        settings.micDeviceUID = micDeviceUID
        settings.systemAudioEnabled = systemAudioEnabled
        try? settings.save(to: home.settingsFileURL)
    }

    /// Pipeline Inspector stream for this note's pipeline (the pipeline
    /// itself is private to the controller).
    public func inspectorUpdates() async -> AsyncStream<InspectorUpdate> {
        await pipeline.inspectorUpdates()
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
        if micEnabled {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                status = .failed("Microphone access denied. Enable it in System Settings.")
                return
            }
        }
        do {
            // Fixer (SPEC.md §5.2): reuses the note's saved thread if any.
            // A thread created under older instructions — a contract
            // version bump or a user edit to FIXER.md — is retired; a
            // fresh thread with the current prompt starts instead.
            let noteState = try? NoteRecordingState.load(noteFolder: noteFolderURL)
            let fixerInstructions = AgentInstructions.fixer.resolve(
                homeRootURL: SimbiHome().rootURL)
            let savedThreadId =
                noteState?.fixerInstructionsVersion == TranscriptFixer.instructionsVersion
                    && noteState?.fixerInstructionsHash
                        == AgentInstructions.fingerprint(fixerInstructions)
                ? noteState?.fixerThreadId : nil
            let settings =
                (try? SimbiSettings.load(from: SimbiHome().settingsFileURL)) ?? .default
            let fixer = TranscriptFixer(
                noteFolderURL: noteFolderURL, client: CodexServices.appServer,
                savedThreadId: savedThreadId, model: settings.fixerModel,
                instructions: fixerInstructions)
            let activity = fixerActivity
            await fixer.setEventSink { event in
                Task { @MainActor in activity.handle(event) }
            }
            await pipeline.attachFixer(fixer)
            try await pipeline.start()
            let capture = MixedCapture()
            self.capture = capture
            // A saved mic that's unplugged degrades to the default device
            // (with a banner) rather than blocking the recording.
            var deviceUID = micDeviceUID
            var micBanner: String?
            if micEnabled, let uid = deviceUID, AudioInputDevices.deviceID(forUID: uid) == nil {
                deviceUID = nil
                micBanner = "Selected microphone isn't connected. Using the system default."
            }
            let stream = try capture.start(
                config: .init(
                    micEnabled: micEnabled,
                    micDeviceUID: deviceUID,
                    systemAudioEnabled: systemAudioEnabled))
            systemAudioBanner = capture.systemAudioFailure ?? micBanner
            status = .recording
            hasRecording = true
            fixerActivity.noteRecordingStarted()

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
            if !micEnabled {
                // System-only has no mic to degrade to; the tap failing is
                // almost always the screen/system-audio TCC permission.
                status = .failed(
                    "System audio capture couldn't start (check the System Audio Recording "
                        + "permission in System Settings, or enable the microphone): \(error)")
            } else {
                status = .failed("Could not start recording: \(error)")
            }
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
