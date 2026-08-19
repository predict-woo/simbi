import CodexKit
import FluidAudio
import Foundation
import SimbiKit

/// The single-writer pipeline actor (guide §4/§5): every PCM batch fans out
/// to the ring buffer, the audio.webm writer, the wrapped VAD and the
/// wrapped Sortformer; the aligned record stream drives the cut engine,
/// whose flushes become encoded segments, outbox entries and eventually VTT
/// appends.
public actor RecordingPipeline: TranscriptFixerHost {
    private let noteFolderURL: URL
    private let transcriber: Transcriber
    private let diarizer: DiarizerStream
    private let vad: VadStream
    private let outbox: TranscriptOutbox

    private var state: NoteRecordingState
    private var encoder: OpusWebMEncoder?
    private var ring = SampleRingBuffer()
    private var engine = CutEngine()
    private var realSamples = 0
    private var sessionBaseSamples = 0
    private var sessionNumber = 0
    private var recording = false

    /// Wrapped-model result queues (§3): one verdict per completed 256 ms
    /// VAD chunk, and 4 probabilities per finalized Sortformer frame. The
    /// release loop (§4.1) joins them on the 80 ms grid.
    private var vadVerdicts: [Bool] = []
    private var sortProbabilities: [Float] = []
    private var sortFrames = 0
    private var nextRecordFrame = 0

    /// Upload queue (guide §9.2): ≤ 2 concurrent, 3 attempts each with
    /// 1 s / 4 s backoff; missing/rejected auth pauses the whole queue
    /// (disk-backed — nothing is lost) and retries every 30 s.
    private var uploadQueue: [Int] = []
    private var uploadsInFlight = 0
    private var uploadsPaused = false
    /// Cues reserved in the outbox by THIS process — start-time re-enqueue
    /// is for cross-restart recovery and must skip segments that are merely
    /// still uploading (their pending files are live, not orphaned).
    private var trackedCues: Set<Int> = []
    private static let uploadMaxConcurrent = 2
    private static let uploadMaxAttempts = 3
    private static let uploadBackoff: [Duration] = [.seconds(1), .seconds(4)]
    private static let authRetryDelay: Duration = .seconds(30)

    private var liveContinuation: AsyncStream<RecordingLiveUpdate>.Continuation?
    /// Inspector tap (spec 2026-07-22): with no subscriber every hook is
    /// a nil-check and the engine trace stays disabled.
    private var inspector = InspectorTap()
    /// Optional transcript fixer (SPEC.md §5.2); failures never affect
    /// recording (degraded mode: fixing just doesn't happen).
    private var fixer: TranscriptFixer?
    /// The transcript content copied into the fixer's worktree at pass
    /// start — the "before" side of the merge diff. In-memory only: if the
    /// app dies mid-pass, that pass's edits are simply dropped.
    private var fixerSnapshot: String?

    private var audioFileURL: URL { NoteLayout.audioURL(noteFolder: noteFolderURL) }
    private var pendingDirURL: URL { NoteLayout.pendingDirURL(noteFolder: noteFolderURL) }
    private var sessionBaseSeconds: TimeInterval { Self.seconds(sessionBaseSamples) }

    private static func seconds(_ samples: Int) -> TimeInterval {
        TimeInterval(samples) / TimeInterval(CutConstants.sampleRate)
    }

    public init(
        noteFolderURL: URL,
        transcriber: Transcriber,
        diarizer: DiarizerStream,
        vad: VadStream = SileroVadStream()
    ) {
        self.noteFolderURL = noteFolderURL
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.vad = vad
        self.outbox = TranscriptOutbox(
            fileURL: VTT.fileURL(noteFolder: noteFolderURL),
            noteName: noteFolderURL.lastPathComponent)
        self.state = NoteRecordingState.current(noteFolder: noteFolderURL)
    }

    /// Live updates for the record UI (elapsed + tentative speaker).
    /// Re-subscribing finishes the previous stream so an old consumer's
    /// `for await` ends instead of suspending forever (same contract as
    /// `InspectorTap.subscribe`).
    public func liveUpdates() -> AsyncStream<RecordingLiveUpdate> {
        liveContinuation?.finish()
        return AsyncStream { continuation in
            self.liveContinuation = continuation
        }
    }

    /// Inspector updates (one per PCM batch, plus upload completions).
    /// Subscribing toggles the engine trace on; the stream deliberately
    /// outlives `stop()` — cue transcriptions arrive after the session ends.
    public func inspectorUpdates() -> AsyncStream<InspectorUpdate> {
        engine.traceEnabled = true
        return inspector.subscribe { token in
            Task { await self.inspectorTerminated(token) }
        }
    }

    private func inspectorTerminated(_ token: UUID) {
        if inspector.terminated(token) { engine.traceEnabled = false }
    }

    private func emitInspectorUpdate() {
        inspector.emit(
            counts: .init(
                recording: recording, samplesFed: realSamples,
                sessionBaseSeconds: sessionBaseSeconds, vadChunks: vadVerdicts.count,
                sortFrames: sortFrames, uploadQueueDepth: uploadQueue.count,
                uploadsInFlight: uploadsInFlight), engine: &engine)
    }

    public var isRecording: Bool { recording }
    /// Read-only observation for stop-time consumers (the AI-notes
    /// trigger): true once every reserved transcript entry has been
    /// rendered to transcript.vtt — no cue still awaits its
    /// transcription. Never drains while uploads are paused (degraded
    /// auth), so callers must bound their wait.
    public var isTranscriptDrained: Bool { outbox.isDrained }

    /// Attaches the note's fixer before `start()`.
    public func attachFixer(_ fixer: TranscriptFixer?) async {
        self.fixer = fixer
        await fixer?.setHost(self)
    }

    // MARK: - Start / resume (§10.2)

    public func start() async throws {
        guard !recording else { throw RecordingPipelineError.alreadyRecording }
        try await diarizer.prepare()
        try await vad.prepare()
        state = NoteRecordingState.current(noteFolder: noteFolderURL)

        if state.activeSession != nil {
            try recoverFromCrash()
        } else {
            // Pending segments from a previous run (auth outage, quit before
            // the queue drained): their cues — and the session-end note that
            // was queued behind them — were never rendered. Re-enqueue in
            // cueIndex order, then close the old session in the transcript.
            let reenqueued = reenqueuePendingSegments()
            if reenqueued > 0, state.sessionCount > 0 {
                try outbox.append(
                    .sessionEnd(
                        n: state.sessionCount,
                        wallClock: state.lastSessionEnd ?? .now,
                        offset: Self.seconds(state.totalSamples)))
            }
        }

        sessionNumber = state.sessionCount + 1
        sessionBaseSamples = state.totalSamples
        realSamples = 0
        ring = SampleRingBuffer()
        engine = CutEngine()
        engine.traceEnabled = inspector.isActive
        vadVerdicts = []
        sortProbabilities = []
        sortFrames = 0
        nextRecordFrame = 0
        diarizer.resetSession()
        vad.resetSession()

        if sessionNumber == 1 || !FileManager.default.fileExists(atPath: audioFileURL.path) {
            encoder = try OpusWebMEncoder(fileURL: audioFileURL, mode: .create)
        } else {
            // Verify the file matches state.json bookkeeping (±1 cluster).
            let probe = try OpusWebMDecoder(fileURL: audioFileURL)
            let expectedMs = Int64(sessionBaseSamples / (CutConstants.sampleRate / 1000))
            let actualMs = Int64(probe.endMilliseconds)
            guard abs(actualMs - expectedMs) <= Int64(OpusWebMFormat.clusterMilliseconds) + 20
            else {
                throw RecordingPipelineError.audioFileMismatch
            }
            encoder = try OpusWebMEncoder(
                fileURL: audioFileURL, mode: .append(baseMilliseconds: UInt64(expectedMs)))
        }

        try FileManager.default.createDirectory(
            at: pendingDirURL, withIntermediateDirectories: true)

        state.activeSession = .init(
            n: sessionNumber, baseSamples: sessionBaseSamples, wallStart: .now)
        try state.saveRecording(noteFolder: noteFolderURL)
        try outbox.append(
            .sessionStart(n: sessionNumber, wallClock: .now, offset: sessionBaseSeconds))
        recording = true

        if let fixer {
            do {
                try await fixer.recordingStarted()
            } catch {
                // Degraded mode by contract: recording continues without the fixer.
                Log.recording.warning("fixer thread failed to start: \(error)")
            }
            let fingerprint = await fixer.instructionsFingerprint
            if let threadId = await fixer.threadId,
                threadId != state.fixerThreadId
                    || state.fixerInstructionsVersion != TranscriptFixer.instructionsVersion
                    || state.fixerInstructionsHash != fingerprint
            {
                state.fixerThreadId = threadId
                state.fixerInstructionsVersion = TranscriptFixer.instructionsVersion
                state.fixerInstructionsHash = fingerprint
                do {
                    try state.saveRecording(noteFolder: noteFolderURL)
                } catch {
                    Log.recording.error("saving fixer thread id to state.json failed: \(error)")
                }
            }
        }
    }

    // MARK: - PCM ingestion (§4.2)

    /// Delivers one mixed 16 kHz mono batch to the four sinks in order,
    /// then advances the release loop.
    public func ingest(samples: [Float]) async throws {
        guard recording else { return }
        ring.append(samples)
        try encoder?.append(samples: samples)
        // Flush the muxer per batch: a crash then loses < 20 ms of tail
        // audio (§11 promises 1–2 s; stdio flush per ~10 ms batch is cheap).
        try encoder?.flush()
        realSamples += samples.count
        vadVerdicts.append(contentsOf: try await vad.addAudio(samples))
        diarizer.addAudio(samples)
        while let chunk = try diarizer.process() {
            absorb(chunk)
        }
        try releaseRecords(upTo: Int.max)
        emitInspectorUpdate()
    }

    /// Queues one Sortformer burst's finalized frames (§3.2 holding queue).
    private func absorb(_ chunk: DiarizerChunkResult) {
        assert(chunk.startFrame == sortFrames, "sortformer frames out of order")
        sortProbabilities.append(
            contentsOf: chunk.finalizedPredictions.prefix(chunk.finalizedFrameCount * 4))
        sortFrames += chunk.finalizedFrameCount
        liveContinuation?.yield(
            RecordingLiveUpdate(
                elapsed: sessionBaseSeconds + Self.seconds(realSamples),
                tentativeSpeaker: chunk.tentativeSpeaker))
    }

    /// The release loop (§4.1). Records release when both wrapped models
    /// have their result — availability-driven, which by §3's bounds is at
    /// most `pipelineLatencyFrames` behind the audio and immune to any
    /// off-by-a-few-samples in the models' internal framing. Decisions are
    /// a pure function of the record sequence, so release timing cannot
    /// change them.
    private func releaseRecords(upTo limit: Int) throws {
        while nextRecordFrame < limit, nextRecordFrame < sortFrames {
            let frame = nextRecordFrame
            // §3.1 midpoint rule: the frame's VAD verdict is the chunk
            // containing its midpoint. Always already computed (§3.3) —
            // except with lag-free test fakes, where we just wait.
            let chunkIndex =
                (frame * CutConstants.frameSamples + CutConstants.frameSamples / 2)
                / CutConstants.vadChunkSamples
            guard chunkIndex < vadVerdicts.count else { break }
            let base = frame * 4
            if inspector.isActive {
                let probabilities = Array(sortProbabilities[base..<(base + 4)])
                inspector.records.append(
                    InspectorFrameRecord(
                        frame: frame, vadActive: vadVerdicts[chunkIndex],
                        dominantSlot: labelFrame(probabilities: probabilities[...]).slot,
                        probabilities: probabilities))
            }
            let commands = engine.push(
                vadActive: vadVerdicts[chunkIndex],
                probabilities: sortProbabilities[base..<(base + 4)])
            nextRecordFrame += 1
            for command in commands {
                try flushSegment(command)
            }
        }
        // Eviction floor (§5.1) = flushedUpTo, which advances on flushes AND
        // on R6 discards (which emit no command) — during a long silence
        // this is what keeps ring memory bounded. Set after slicing so a
        // flush can never evict its own span.
        ring.setEvictionFloor(engine.flushedUpTo * CutConstants.frameSamples)
    }

    // MARK: - Flushes (§5)

    private var realAudioEndSec: TimeInterval {
        sessionBaseSeconds + Self.seconds(realSamples)
    }

    private func noteTime(_ frame: Int) -> TimeInterval {
        sessionBaseSeconds + TimeInterval(frame) * DiarizerPreset.frameDuration
    }

    private func flushSegment(_ command: FlushCommand) throws {
        let cueIndex = state.nextCueIndex
        let startSec = noteTime(command.startFrame)
        let endSec = min(noteTime(command.endFrame), realAudioEndSec)

        // One contiguous PCM slice over the staged span — uploads tile the
        // timeline (§5.1), so the slice is exactly the cue extents. The
        // upper bound clamps to written audio for the stop-time final
        // (possibly partial) frame.
        let sliceEnd = min(command.endFrame * CutConstants.frameSamples, ring.writeHead)
        let pcm = ring.slice((command.startFrame * CutConstants.frameSamples)..<sliceEnd)

        let webmURL = pendingDirURL.appending(path: "\(cueIndex).webm")
        let segmentEncoder = try OpusWebMEncoder(fileURL: webmURL, mode: .create)
        try segmentEncoder.append(samples: pcm)
        try segmentEncoder.finish()

        // Uploads before the first stable speaker have no label (§5.3);
        // slot 0 is the display fallback.
        let speakerSlot = command.speaker ?? 0
        let sidecar = PendingSegment(
            cueIndex: cueIndex, startSec: startSec, endSec: endSec,
            speaker: speakerSlot, continuation: false)
        try PersistedJSON.encoder().encode(sidecar)
            .write(to: pendingDirURL.appending(path: "\(cueIndex).json"), options: .atomic)

        // Every fallible step is done: only now consume the cue index
        // (a throw above must not leave a gap in the numbering) and expose
        // the cue to the outbox and upload queue.
        state.nextCueIndex += 1
        do {
            try state.saveRecording(noteFolder: noteFolderURL)
        } catch {
            Log.recording.error(
                "saving nextCueIndex \(state.nextCueIndex) to state.json failed: \(error)")
        }
        trackedCues.insert(cueIndex)
        outbox.reserveCue(
            index: cueIndex, start: startSec, end: endSec,
            speaker: SpeakerLabel.name(slot: speakerSlot),
            continuation: false)
        if inspector.isActive {
            inspector.uploadEvents.append(
                .queued(
                    cue: cueIndex, startFrame: command.startFrame, endFrame: command.endFrame,
                    speaker: command.speaker, reason: command.reason))
        }
        enqueueUpload(cueIndex)
    }

    // MARK: - Stop (§5.4)

    public func stop() async throws {
        guard recording else { throw RecordingPipelineError.notRecording }
        recording = false

        let realFrameEnd =
            (realSamples + CutConstants.frameSamples - 1) / CutConstants.frameSamples

        // Drain: the wrapped models lag the audio (§3), so feed the stop
        // pad — zeros, to the models ONLY, never the ring or audio.webm —
        // until every real frame has both results, then release exactly the
        // real frames. Pad frames past realFrameEnd never reach the engine.
        let pad = [Float](repeating: 0, count: Int(Double(CutConstants.sampleRate) * CutConstants.stopPadSeconds))
        vadVerdicts.append(contentsOf: try await vad.addAudio(pad))
        diarizer.addAudio(pad)
        while let chunk = try diarizer.process() {
            absorb(chunk)
        }
        if let chunk = try diarizer.finalizeSession() {
            absorb(chunk)
        }
        try releaseRecords(upTo: realFrameEnd)

        // Defensive: if a model still fell short of realFrameEnd (it should
        // not — the pad exceeds both latencies), synthesize silence records
        // so the final cut covers all real audio.
        let silence: [Float] = [0, 0, 0, 0]
        while engine.frontier < realFrameEnd {
            for command in engine.push(vadActive: false, probabilities: silence[...]) {
                try flushSegment(command)
            }
        }
        for command in engine.stop() {
            try flushSegment(command)
        }
        // A silent tail is discarded, not flushed — mirror the floor anyway.
        ring.setEvictionFloor(engine.flushedUpTo * CutConstants.frameSamples)

        try outbox.append(
            .sessionEnd(n: sessionNumber, wallClock: .now, offset: realAudioEndSec))

        try encoder?.finish()
        encoder = nil

        state.totalSamples = sessionBaseSamples + realSamples
        state.sessionCount = sessionNumber
        state.lastSessionEnd = .now
        state.activeSession = nil
        try state.saveRecording(noteFolder: noteFolderURL)
        // Final snapshot (recording == false); the stream stays open for
        // the late cue transcriptions.
        emitInspectorUpdate()
        liveContinuation?.finish()
        liveContinuation = nil

        if let fixer {
            await fixer.recordingStopped()
        }
    }

    /// Reserves + enqueues every segment left in `.simbi/pending/`, in
    /// cueIndex order (guide §9.2 / §11: the disk queue survives restarts;
    /// smaller indices re-enter the outbox ahead of any new entries).
    /// Returns the number of re-enqueued segments.
    private func reenqueuePendingSegments() -> Int {
        let pendingIndices =
            ((try? FileManager.default.contentsOfDirectory(
                at: pendingDirURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .compactMap { Int($0.deletingPathExtension().lastPathComponent) }
            .sorted()
        var count = 0
        for cueIndex in pendingIndices where !trackedCues.contains(cueIndex) {
            let jsonURL = pendingDirURL.appending(path: "\(cueIndex).json")
            guard let data = try? Data(contentsOf: jsonURL),
                let sidecar = try? JSONDecoder().decode(PendingSegment.self, from: data)
            else {
                Log.recording.warning(
                    "pending sidecar \(jsonURL.lastPathComponent) unreadable; segment skipped")
                continue
            }
            trackedCues.insert(cueIndex)
            outbox.reserveCue(
                index: sidecar.cueIndex, start: sidecar.startSec, end: sidecar.endSec,
                speaker: SpeakerLabel.name(slot: sidecar.speaker),
                continuation: sidecar.continuation)
            enqueueUpload(sidecar.cueIndex)
            count += 1
        }
        return count
    }

    // MARK: - Fixer merge (SPEC.md §5.2 snapshot-and-replay)

    /// Copies the live transcript into the fixer's worktree and remembers
    /// it as the diff base. The fixer edits the copy (its only writable
    /// root), so the live file keeps this actor as its single writer.
    public func fixerWillStartPass() {
        let worktree = TranscriptFixer.worktreeURL(noteFolder: noteFolderURL)
        let live =
            (try? String(
                contentsOf: VTT.fileURL(noteFolder: noteFolderURL), encoding: .utf8))
            ?? VTT.header(noteName: noteFolderURL.lastPathComponent)
        fixerSnapshot = live
        do {
            try FileManager.default.createDirectory(
                at: worktree, withIntermediateDirectories: true)
            try live.write(
                to: worktree.appending(path: VTT.fileName), atomically: true, encoding: .utf8)
        } catch {
            Log.recording.error("copying transcript into fixer worktree failed: \(error)")
        }
    }

    /// Diffs the fixer's edited copy against the snapshot and replays the
    /// changed cue payloads onto the live file — serialized here between
    /// appends, so the collision that lost cues under direct fixer writes
    /// cannot occur. Returns the number of merged cue edits (for the
    /// activity UI).
    @discardableResult
    public func fixerDidCompletePass() -> Int {
        guard let before = fixerSnapshot else { return 0 }
        fixerSnapshot = nil
        let copyURL = TranscriptFixer.worktreeURL(noteFolder: noteFolderURL)
            .appending(path: VTT.fileName)
        guard let after = try? String(contentsOf: copyURL, encoding: .utf8) else {
            Log.recording.warning("fixer worktree transcript unreadable; merge skipped")
            return 0
        }
        let edits = TranscriptOutbox.fixerEdits(before: before, after: after)
        guard !edits.isEmpty else { return 0 }
        do {
            try outbox.applyEdits(edits)
            return edits.count
        } catch {
            Log.recording.error("applying \(edits.count) fixer edits failed: \(error)")
            return 0
        }
    }

    // MARK: - Crash recovery (§10.3)

    private func recoverFromCrash() throws {
        guard let active = state.activeSession else { return }

        // 1. Scan the surviving clusters (a truncated trailing cluster
        //    simply fails to parse and is excluded).
        var recoveredSamples = 0
        do {
            let probe = try OpusWebMDecoder(fileURL: audioFileURL)
            recoveredSamples = Int(probe.endMilliseconds) * (CutConstants.sampleRate / 1000)
        } catch {
            Log.recording.warning(
                "crash recovery: audio.webm unreadable, timeline recovered from cues only:"
                    + " \(error)")
        }

        // 2. Clamp to the last cue's end so later sessions never overlap
        //    cues written just before the crash.
        var lastCueEndSec: TimeInterval = 0
        let vttURL = VTT.fileURL(noteFolder: noteFolderURL)
        if let text = try? String(contentsOf: vttURL, encoding: .utf8),
            let document = try? VTTParser.parse(text)
        {
            for case .cue(_, _, let end, _, _, _) in document.entries {
                lastCueEndSec = max(lastCueEndSec, end)
            }
        }
        let totalSamples = max(recoveredSamples, Int((lastCueEndSec * Double(CutConstants.sampleRate)).rounded(.up)))

        // 3. Rewrite state; the true wall-clock end is unknowable.
        let estimatedEnd = active.wallStart.addingTimeInterval(
            Self.seconds(totalSamples - active.baseSamples))
        state.totalSamples = totalSamples
        state.sessionCount = active.n
        state.lastSessionEnd = estimatedEnd
        state.activeSession = nil
        try state.saveRecording(noteFolder: noteFolderURL)

        // 4. Re-enqueue pending uploads in cueIndex order.
        _ = reenqueuePendingSegments()

        // 5. Close the unfinished session in the transcript.
        try outbox.append(
            .sessionEnd(
                n: active.n, wallClock: estimatedEnd,
                offset: Self.seconds(totalSamples)))
    }
}

// MARK: - Upload workers (§9.2)

extension RecordingPipeline {
    private func enqueueUpload(_ cueIndex: Int) {
        uploadQueue.append(cueIndex)
        kickUploads()
    }

    private func kickUploads() {
        while !uploadsPaused, uploadsInFlight < Self.uploadMaxConcurrent, !uploadQueue.isEmpty {
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
                    do {
                        try FileManager.default.removeItem(at: url)
                    } catch {
                        Log.recording.warning(
                            "removing uploaded segment \(url.lastPathComponent) failed"
                                + " (will re-upload after relaunch): \(error)")
                    }
                }
                uploadFinished(cueIndex: cueIndex, text: text)
                return
            } catch let error as TranscriptionClient.TranscriptionError {
                switch error {
                case .authUnavailable, .authRejected:
                    // Not this segment's fault: requeue it, pause the whole
                    // queue, retry after a delay (SPEC.md §7 — the queue is
                    // disk-backed and drains on recovery).
                    pauseUploads(requeuing: cueIndex)
                    return
                case .requestFailed, .malformedResponse:
                    break  // retryable
                }
            } catch {
                // Unknown error: treat as retryable transport failure.
            }
            if attempt < Self.uploadMaxAttempts {
                try? await Task.sleep(for: Self.uploadBackoff[attempt - 1])
            }
        }

        // Terminal failure: the timeline stays complete with [inaudible];
        // the encoded segment moves to failed/ for post-hoc retry tooling
        // (pending/ must only hold cues not yet rendered to the VTT).
        Log.recording.error(
            "cue \(cueIndex) upload failed after \(Self.uploadMaxAttempts) attempts;"
                + " rendering [inaudible] and moving segment to failed/")
        let failedDir = NoteLayout.failedDirURL(noteFolder: noteFolderURL)
        do {
            try FileManager.default.createDirectory(
                at: failedDir, withIntermediateDirectories: true)
            for url in [webmURL, jsonURL] {
                try FileManager.default.moveItem(
                    at: url, to: failedDir.appending(path: url.lastPathComponent))
            }
        } catch {
            Log.recording.error("moving cue \(cueIndex) segment to failed/ failed: \(error)")
        }
        uploadFinished(cueIndex: cueIndex, text: "[inaudible]")
    }

    private func uploadFinished(cueIndex: Int, text: String) {
        do {
            try outbox.fulfillCue(index: cueIndex, text: text)
        } catch {
            Log.recording.error(
                "appending cue \(cueIndex) to transcript.vtt failed; text dropped: \(error)")
        }
        uploadsInFlight -= 1
        kickUploads()
        if inspector.isActive {
            inspector.uploadEvents.append(.finished(cue: cueIndex, text: text))
            emitInspectorUpdate()
        }
        if let fixer {
            Task { await fixer.cueAppended(index: cueIndex) }
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
}
