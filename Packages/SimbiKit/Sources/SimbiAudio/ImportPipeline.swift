import CodexKit
import Foundation
import SimbiKit

/// The media-import pipeline actor (media-import spec): decodes one
/// `files/` media file into the note's `audio.webm` as a new session,
/// analyzes it offline (VAD + Sortformer), builds speaker-attributed
/// blocks, then transcribes them through the same outbox/pending contract
/// as the live pipeline. Crash-safe via a two-phase `state.json` marker:
/// phase 1 (writing audio) rolls back on failure, phase 2 (uploading) has
/// committed audio and resumes by draining pending uploads.
public actor ImportPipeline {
    public struct Progress: Equatable, Sendable {
        public enum Stage: Equatable, Sendable {
            case analyzing(seconds: TimeInterval)
            case transcribing(done: Int, total: Int)
            case finished
            case failed(String)
        }
        public let fileName: String
        public let stage: Stage
    }

    private let noteFolderURL: URL
    private let transcriber: Transcriber
    private let decoder: any MediaDecoding
    private let analyzer: any OfflineAnalyzing
    private let outbox: TranscriptOutbox
    private var running = false
    private var progressContinuation: AsyncStream<Progress>.Continuation?

    private var pendingDirURL: URL { NoteLayout.pendingDirURL(noteFolder: noteFolderURL) }
    private var audioFileURL: URL { NoteLayout.audioURL(noteFolder: noteFolderURL) }

    private static func seconds(_ samples: Int) -> TimeInterval {
        TimeInterval(samples) / TimeInterval(CutConstants.sampleRate)
    }

    public init(
        noteFolderURL: URL, transcriber: Transcriber,
        decoder: any MediaDecoding, analyzer: any OfflineAnalyzing
    ) {
        self.noteFolderURL = noteFolderURL
        self.transcriber = transcriber
        self.decoder = decoder
        self.analyzer = analyzer
        self.outbox = TranscriptOutbox(
            fileURL: VTT.fileURL(noteFolder: noteFolderURL),
            noteName: noteFolderURL.lastPathComponent)
    }

    public var isImporting: Bool { running }

    /// Re-subscribing finishes the previous stream so an old consumer's
    /// `for await` ends instead of suspending forever (same contract as
    /// `RecordingPipeline.liveUpdates`).
    public func progressUpdates() -> AsyncStream<Progress> {
        progressContinuation?.finish()
        return AsyncStream { continuation in
            self.progressContinuation = continuation
        }
    }

    private func emit(_ fileName: String, _ stage: Progress.Stage) {
        progressContinuation?.yield(Progress(fileName: fileName, stage: stage))
    }

    /// Full import of `files/<fileName>`. Throws on failure after rollback.
    public func run(fileName: String) async throws {
        guard !running else { throw ImportPipelineError.importAlreadyRunning }
        running = true
        defer { running = false }
        try await analyzer.prepare()

        var base = 0
        var session = 0
        try NoteRecordingState.update(noteFolder: noteFolderURL) { state in
            base = state.totalSamples
            session = state.sessionCount + 1
            state.activeImport = .init(fileName: fileName, n: session, baseSamples: base, phase: 1)
            state.imports[fileName] = .init(status: .analyzing)
        }
        do {
            let (pcm, entries) = try await runPhase1(fileName: fileName, base: base)
            try NoteRecordingState.update(noteFolder: noteFolderURL) { state in
                state.totalSamples = base + pcm.count
                state.sessionCount = session
                state.lastSessionEnd = .now
                state.activeImport?.phase = 2
                state.imports[fileName]?.status = .transcribing
            }
            try await runPhase2AndDrain(
                fileName: fileName, entries: entries, pcm: pcm, base: base, session: session)
            try NoteRecordingState.update(noteFolder: noteFolderURL) { state in
                state.activeImport = nil
                state.imports[fileName]?.status = .done
            }
            emit(fileName, .finished)
        } catch {
            // Phase-1 failure: undo the audio append and the marker (the
            // rollback both no-op once the marker says phase 2 — committed
            // audio must survive, and a leftover phase-2 marker is exactly
            // what tells the next note open to resume draining pending
            // uploads via resumePhase2).
            try? Self.rollbackStalePhase1(noteFolder: noteFolderURL)
            try? NoteRecordingState.update(noteFolder: noteFolderURL) { state in
                state.imports[fileName]?.status = .failed
            }
            emit(fileName, .failed("\(error)"))
            throw error
        }
    }

    /// Decode → append-encode → analyze → build blocks. Nothing touches the
    /// VTT or the outbox in phase 1.
    private func runPhase1(
        fileName: String, base: Int
    ) async throws -> (pcm: [Float], entries: [ImportTimelineEntry]) {
        let fileURL = NoteLayout.filesDirURL(noteFolder: noteFolderURL).appending(path: fileName)
        let encoder: OpusWebMEncoder
        if base == 0 || !FileManager.default.fileExists(atPath: audioFileURL.path) {
            encoder = try OpusWebMEncoder(fileURL: audioFileURL, mode: .create)
        } else {
            // Same bookkeeping check as RecordingPipeline.start().
            let probe = try OpusWebMDecoder(fileURL: audioFileURL)
            let expectedMs = Int64(base / (CutConstants.sampleRate / 1000))
            guard
                abs(Int64(probe.endMilliseconds) - expectedMs)
                    <= Int64(OpusWebMFormat.clusterMilliseconds) + 20
            else { throw ImportPipelineError.audioFileMismatch }
            encoder = try OpusWebMEncoder(
                fileURL: audioFileURL, mode: .append(baseMilliseconds: UInt64(expectedMs)))
        }
        var pcm: [Float] = []
        for try await batch in decoder.decode(url: fileURL) {
            pcm.append(contentsOf: batch)
            try encoder.append(samples: batch)
            try encoder.flush()
            emit(fileName, .analyzing(seconds: Self.seconds(pcm.count)))
        }
        guard !pcm.isEmpty else { throw ImportPipelineError.noAudio }
        try encoder.finish()
        let records = try await analyzer.analyze(pcm)
        return (pcm, ImportBlockBuilder.build(records: records))
    }

    // MARK: - Phase 2 (reserve → encode → upload at 5 → drain)

    // The upload worker deliberately mirrors RecordingPipeline's §9.2
    // extension — same retry/backoff/auth-pause/failed-dir semantics, kept
    // side-by-side comparable on purpose (see the media-import spec's reuse
    // rationale) — at concurrency `ImportConstants.uploadMaxConcurrent`,
    // plus drain tracking so `run` can block until every cue is rendered.

    private var uploadQueue: [Int] = []
    private var uploadsInFlight = 0
    private var uploadsPaused = false
    private var remainingUploads = 0
    private var uploadsDone = 0
    private var uploadsTotal = 0
    private var activeFileName = ""
    private var drainContinuation: CheckedContinuation<Void, Never>?
    private static let uploadMaxAttempts = 3
    private static let uploadBackoff: [Duration] = [.seconds(1), .seconds(4)]
    private static let authRetryDelay: Duration = .seconds(30)

    /// Reserve session/gap/cue entries in timeline order, encode each block
    /// into `.simbi/pending/`, upload, and block until the queue drains.
    /// With auth degraded the drain never resolves and `run` never returns —
    /// that is correct: the pending queue is disk-safe and a relaunch
    /// resumes via `resumePhase2`.
    private func runPhase2AndDrain(
        fileName: String, entries: [ImportTimelineEntry], pcm: [Float],
        base: Int, session: Int
    ) async throws {
        let baseSec = Self.seconds(base)
        let endSec = baseSec + Self.seconds(pcm.count)
        func noteTime(_ frame: Int) -> TimeInterval {
            baseSec + TimeInterval(frame) * DiarizerPreset.frameDuration
        }
        try FileManager.default.createDirectory(
            at: pendingDirURL, withIntermediateDirectories: true)
        activeFileName = fileName
        uploadsTotal = entries.reduce(0) { if case .block = $1 { $0 + 1 } else { $0 } }
        uploadsDone = 0
        try outbox.append(.sessionStart(n: session, wallClock: .now, offset: baseSec))
        for entry in entries {
            switch entry {
            case .gap(let start, let end):
                try outbox.append(.gap(start: noteTime(start), end: noteTime(end)))
            case .block(let block):
                var cueIndex = 0
                try NoteRecordingState.update(noteFolder: noteFolderURL) { state in
                    cueIndex = state.nextCueIndex
                    state.nextCueIndex += 1
                }
                let sliceStart = block.startFrame * CutConstants.frameSamples
                let sliceEnd = min(block.endFrame * CutConstants.frameSamples, pcm.count)
                let webmURL = pendingDirURL.appending(path: "\(cueIndex).webm")
                let segmentEncoder = try OpusWebMEncoder(fileURL: webmURL, mode: .create)
                try segmentEncoder.append(samples: Array(pcm[sliceStart..<sliceEnd]))
                try segmentEncoder.finish()
                let start = noteTime(block.startFrame)
                let end = min(noteTime(block.endFrame), endSec)
                let sidecar = PendingSegment(
                    cueIndex: cueIndex, startSec: start, endSec: end,
                    speaker: block.speaker, continuation: false)
                try PersistedJSON.encoder().encode(sidecar)
                    .write(to: pendingDirURL.appending(path: "\(cueIndex).json"), options: .atomic)
                outbox.reserveCue(
                    index: cueIndex, start: start, end: end,
                    speaker: SpeakerLabel.name(slot: block.speaker), continuation: false)
                remainingUploads += 1
                enqueueUpload(cueIndex)
            }
        }
        try outbox.append(.sessionEnd(n: session, wallClock: .now, offset: endSec))
        emit(fileName, .transcribing(done: 0, total: uploadsTotal))
        await waitForDrain()
    }

    /// Relaunch recovery for a phase-2 marker: re-enqueue pending segments,
    /// drain, clear the marker. No-op without a phase-2 marker.
    public func resumePhase2() async throws {
        guard !running else { return }
        let state = NoteRecordingState.current(noteFolder: noteFolderURL)
        guard let active = state.activeImport, active.phase == 2 else { return }
        running = true
        defer { running = false }
        activeFileName = active.fileName
        let pendingIndices =
            ((try? FileManager.default.contentsOfDirectory(
                at: pendingDirURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .compactMap { Int($0.deletingPathExtension().lastPathComponent) }
            .sorted()
        if !pendingIndices.isEmpty {
            uploadsTotal = pendingIndices.count
            uploadsDone = 0
            for cueIndex in pendingIndices {
                let jsonURL = pendingDirURL.appending(path: "\(cueIndex).json")
                guard let data = try? Data(contentsOf: jsonURL),
                    let sidecar = try? JSONDecoder().decode(PendingSegment.self, from: data)
                else { continue }
                outbox.reserveCue(
                    index: sidecar.cueIndex, start: sidecar.startSec, end: sidecar.endSec,
                    speaker: SpeakerLabel.name(slot: sidecar.speaker),
                    continuation: sidecar.continuation)
                remainingUploads += 1
                enqueueUpload(sidecar.cueIndex)
            }
            // The in-memory session-end note died with the crashed process;
            // close the session behind the re-enqueued cues (same move as
            // RecordingPipeline.start()'s re-enqueue path).
            try outbox.append(
                .sessionEnd(
                    n: state.sessionCount, wallClock: state.lastSessionEnd ?? .now,
                    offset: Self.seconds(state.totalSamples)))
            await waitForDrain()
        }
        try NoteRecordingState.update(noteFolder: noteFolderURL) { state in
            if let name = state.activeImport?.fileName {
                state.imports[name]?.status = .done
            }
            state.activeImport = nil
        }
        emit(active.fileName, .finished)
    }

    private func waitForDrain() async {
        guard remainingUploads > 0 else { return }
        await withCheckedContinuation { continuation in
            drainContinuation = continuation
        }
    }

    private func enqueueUpload(_ cueIndex: Int) {
        uploadQueue.append(cueIndex)
        kickUploads()
    }

    private func kickUploads() {
        while !uploadsPaused, uploadsInFlight < ImportConstants.uploadMaxConcurrent,
            !uploadQueue.isEmpty
        {
            let cueIndex = uploadQueue.removeFirst()
            uploadsInFlight += 1
            Task { await self.runUpload(cueIndex: cueIndex) }
        }
    }

    private func runUpload(cueIndex: Int) async {
        let webmURL = pendingDirURL.appending(path: "\(cueIndex).webm")
        let jsonURL = pendingDirURL.appending(path: "\(cueIndex).json")
        for attempt in 1...Self.uploadMaxAttempts {
            do {
                let text = try await transcriber.transcribe(webmFile: webmURL)
                for url in [webmURL, jsonURL] {
                    try? FileManager.default.removeItem(at: url)
                }
                uploadFinished(cueIndex: cueIndex, text: text)
                return
            } catch let error as TranscriptionClient.TranscriptionError {
                switch error {
                case .authUnavailable, .authRejected:
                    pauseUploads(requeuing: cueIndex)
                    return
                case .requestFailed, .malformedResponse:
                    break
                }
            } catch {}
            if attempt < Self.uploadMaxAttempts {
                try? await Task.sleep(for: Self.uploadBackoff[attempt - 1])
            }
        }
        Log.recording.error(
            "import cue \(cueIndex) failed after \(Self.uploadMaxAttempts) attempts; [inaudible]")
        let failedDir = NoteLayout.failedDirURL(noteFolder: noteFolderURL)
        try? FileManager.default.createDirectory(at: failedDir, withIntermediateDirectories: true)
        for url in [webmURL, jsonURL] {
            try? FileManager.default.moveItem(
                at: url, to: failedDir.appending(path: url.lastPathComponent))
        }
        uploadFinished(cueIndex: cueIndex, text: "[inaudible]")
    }

    private func uploadFinished(cueIndex: Int, text: String) {
        do {
            try outbox.fulfillCue(index: cueIndex, text: text)
        } catch {
            Log.recording.error("appending import cue \(cueIndex) failed: \(error)")
        }
        uploadsInFlight -= 1
        uploadsDone += 1
        remainingUploads -= 1
        emit(activeFileName, .transcribing(done: uploadsDone, total: uploadsTotal))
        kickUploads()
        if remainingUploads == 0 {
            drainContinuation?.resume()
            drainContinuation = nil
        }
    }

    private func pauseUploads(requeuing cueIndex: Int) {
        uploadQueue.insert(cueIndex, at: 0)
        uploadsInFlight -= 1
        guard !uploadsPaused else { return }
        uploadsPaused = true
        Task {
            try? await Task.sleep(for: Self.authRetryDelay)
            self.resumeUploads()
        }
    }

    private func resumeUploads() {
        uploadsPaused = false
        kickUploads()
    }

    /// Relaunch recovery for a phase-1 marker: truncate audio.webm back to
    /// baseSamples, mark the file failed, clear the marker. No-op otherwise.
    public static func rollbackStalePhase1(noteFolder: URL) throws {
        let state = NoteRecordingState.current(noteFolder: noteFolder)
        guard let active = state.activeImport, active.phase == 1 else { return }
        let audioURL = NoteLayout.audioURL(noteFolder: noteFolder)
        if active.baseSamples == 0 {
            try? FileManager.default.removeItem(at: audioURL)
        } else if FileManager.default.fileExists(atPath: audioURL.path) {
            // The appended session's first cluster starts exactly at the
            // base timeline position; truncating at its byte offset restores
            // the pre-import file (clusters are self-contained).
            let baseMs = Double(active.baseSamples) / Double(CutConstants.sampleRate) * 1000
            let probe = try OpusWebMDecoder(fileURL: audioURL)
            if let cluster = probe.clusterIndex.first(where: { $0.time * 1000 >= baseMs - 1 }) {
                let handle = try FileHandle(forWritingTo: audioURL)
                defer { try? handle.close() }
                try handle.truncate(atOffset: UInt64(cluster.byteOffset))
            }
        }
        try NoteRecordingState.update(noteFolder: noteFolder) { state in
            if let name = state.activeImport?.fileName {
                state.imports[name] = .init(status: .failed)
            }
            state.activeImport = nil
        }
    }
}

public enum ImportPipelineError: Error, Equatable {
    case importAlreadyRunning
    case audioFileMismatch
    case noAudio
}
