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
    /// would corrupt the timeline.
    private static let controllers = PerNoteRegistry<RecordingController>()

    public static func shared(noteFolderURL: URL) -> RecordingController {
        controllers.value(for: noteFolderURL, make: RecordingController.init(noteFolderURL:))
    }

    /// True while any open note is capturing. The auto-updater reads this to
    /// keep an install from ever interrupting a meeting (`UpdateGate`).
    public static var isAnyRecording: Bool {
        controllers.all.contains { $0.status.isCapturing }
    }

    /// True while THIS note is capturing. Read-only — never creates a
    /// controller as a side effect. The summary controller uses it to
    /// refuse generation triggers mid-recording (AI Notes spec §3).
    static func isCapturing(noteFolderURL: URL) -> Bool {
        controllers[noteFolderURL]?.status.isCapturing ?? false
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

    /// Coarse fixer status (off/waiting/working/done) for the header button.
    let fixerActivity = FixerActivityModel()

    /// Fired after a clean stop (status back to .idle) so the summary
    /// controller can generate AI notes (AI Notes spec §3). Assigned by
    /// the note view; both controllers are app-lifetime singletons.
    var onRecordingStopped: (() -> Void)?

    /// Whether this note has a fixer thread (saved in state.json, or created
    /// this session). Drives the header button's visibility across relaunches.
    private(set) var hasFixerThread: Bool

    /// Exposed so the header's buttons can open per-note windows keyed by
    /// this URL.
    let noteFolderURL: URL
    private let pipeline: RecordingPipeline
    private var capture: MixedCapture?
    private var ingestTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var watcher: FileTreeWatcher?

    public init(noteFolderURL: URL) {
        self.noteFolderURL = noteFolderURL
        self.pipeline = RecordingPipeline(
            noteFolderURL: noteFolderURL,
            transcriber: CodexTranscriber(),
            diarizer: SortformerStream())
        let state = NoteRecordingState.current(noteFolder: noteFolderURL)
        self.hasRecording = state.sessionCount > 0 || state.activeSession != nil
        self.hasFixerThread = state.fixerThreadId != nil
        self.elapsed = TimeInterval(state.totalSamples) / TimeInterval(CutConstants.sampleRate)
        let settings = SimbiSettings.current()
        self.micEnabled = settings.micEnabled
        self.micDeviceUID = settings.micDeviceUID
        self.systemAudioEnabled = settings.systemAudioEnabled
        watcher = FileTreeWatcher.observing(url: noteFolderURL) { [weak self] in
            self?.refreshFileState()
        }
    }

    /// state.json is also plain-file state. Adopt external bookkeeping while
    /// idle; during capture the live pipeline remains its single writer.
    func refreshFileState() {
        guard status == .idle else { return }
        let state = NoteRecordingState.current(noteFolder: noteFolderURL)
        hasRecording = state.sessionCount > 0 || state.activeSession != nil
        hasFixerThread = state.fixerThreadId != nil
        elapsed = TimeInterval(state.totalSamples) / TimeInterval(CutConstants.sampleRate)
    }

    private func persistSources() {
        let home = SimbiHome()
        var settings = SimbiSettings.current(home: home)
        settings.micEnabled = micEnabled
        settings.micDeviceUID = micDeviceUID
        settings.systemAudioEnabled = systemAudioEnabled
        do {
            try settings.save(to: home.settingsFileURL)
        } catch {
            Log.ui.error("persisting recording sources to settings.json failed: \(error)")
        }
    }

    /// Pipeline Inspector stream for this note's pipeline (the pipeline
    /// itself is private to the controller).
    public func inspectorUpdates() async -> AsyncStream<InspectorUpdate> {
        await pipeline.inspectorUpdates()
    }

    /// The header's sparkles button: open the note's fixer thread in the
    /// live thread viewer. Fixer viewers never archive on close; the thread
    /// stays resumable with full context (spec 2026-08-09).
    func openFixerViewer() {
        guard let threadId = NoteRecordingState.current(noteFolder: noteFolderURL).fixerThreadId
        else { return }
        ThreadViewerManager.shared.open(
            threadId: threadId,
            title: "Fixer: \(noteFolderURL.lastPathComponent)",
            noteFolderURL: noteFolderURL,
            archivesOnClose: false,
            isBusy: { [weak self] in self?.fixerActivity.status == .working })
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
        // An import owns the note's timeline (state.json sessionCount /
        // totalSamples) while it runs; a concurrent recording would clobber
        // it. The other direction holds too: ImportController's worker
        // waits while this note is capturing.
        guard !ImportController.isImporting(noteFolderURL: noteFolderURL) else {
            status = .failed(
                "A file import is transcribing into this note. Wait for it to finish first.")
            return
        }
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
            let settings = SimbiSettings.current()
            if settings.transcriptFixerEnabled {
                let noteState = NoteRecordingState.current(noteFolder: noteFolderURL)
                let fixerInstructions = AgentInstructions.fixer.resolve(
                    homeRootURL: SimbiHome().rootURL)
                let savedThreadId =
                    noteState.fixerInstructionsVersion == TranscriptFixer.instructionsVersion
                        && noteState.fixerInstructionsHash
                            == AgentInstructions.fingerprint(fixerInstructions)
                    ? noteState.fixerThreadId : nil
                let choice = settings[.fixer]
                let fixer = TranscriptFixer(
                    noteFolderURL: noteFolderURL, client: CodexServices.appServer,
                    savedThreadId: savedThreadId, model: choice.model,
                    effort: choice.effort,
                    instructions: fixerInstructions)
                let activity = fixerActivity
                await fixer.setEventSink { event in
                    Task { @MainActor in activity.handle(event) }
                }
                await pipeline.attachFixer(fixer)
            } else {
                await pipeline.attachFixer(nil)
            }
            try await pipeline.start()
            // Refresh right after pipeline.start(): that's where the fixer
            // thread is (or isn't) created. When codex is unavailable no
            // thread exists, the status stays .off, and the sparkles button
            // stays hidden (degraded state, SPEC.md §8).
            if settings.transcriptFixerEnabled {
                hasFixerThread =
                    NoteRecordingState.current(noteFolder: noteFolderURL).fixerThreadId != nil
                if hasFixerThread {
                    fixerActivity.noteRecordingStarted()
                }
            }
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
            notifyStoppedAfterTranscriptDrain()
        } catch {
            status = .failed("Could not stop cleanly: \(error)")
        }
    }

    /// Fires `onRecordingStopped` only after the pending-upload queue has
    /// drained (bounded — AI Notes spec §3): `pipeline.stop()` returns
    /// while the final cues' transcriptions are still in flight, and the
    /// summary must not be generated from a transcript missing its last
    /// utterances. Degraded recordings never drain; when the bound
    /// expires the trigger fires with whatever transcript exists (an
    /// empty one is skipped quietly downstream). A recording restarted
    /// during the wait swallows the trigger: no trigger while recording.
    private func notifyStoppedAfterTranscriptDrain() {
        Task { [pipeline] in
            _ = await TranscriptDrainWait.wait {
                await pipeline.isTranscriptDrained
            }
            guard status == .idle else { return }
            onRecordingStopped?()
        }
    }

}
