import FluidAudio
import Foundation
import SimbiKit

/// Sidecar metadata persisted next to each pending segment upload
/// (`.simbi/pending/{cueIndex}.json`, guide §6.3 step 7).
public struct PendingSegment: Codable, Equatable, Sendable {
    public var cueIndex: Int
    public var startSec: TimeInterval
    public var endSec: TimeInterval
    public var speaker: Int
    public var continuation: Bool
    public var attempts: Int
}

/// Live-UI snapshot emitted by the pipeline while recording.
public struct RecordingLiveUpdate: Equatable, Sendable {
    /// Note-timeline seconds (base + this session's samples).
    public let elapsed: TimeInterval
    /// Tentative "Speaker N speaking…" indicator slot, nil when silent.
    public let tentativeSpeaker: Int?
}

public enum RecordingPipelineError: Error, Equatable {
    case alreadyRecording
    case audioFileMismatch
    case notRecording
}

/// The single-writer pipeline actor (guide §2, §7, §10): every PCM batch
/// fans out to the ring buffer, the audio.webm writer and the diarizer, and
/// the diarizer's finalized frames drive the cut engine, whose actions
/// become encoded segments, outbox entries and eventually VTT appends.
public actor RecordingPipeline {
    private let noteFolderURL: URL
    private let transcriber: Transcriber
    private let diarizer: DiarizerStream
    private let outbox: TranscriptOutbox

    private var state: NoteRecordingState
    private var encoder: OpusWebMEncoder?
    private var ring = SampleRingBuffer()
    private var engine = CutEngine()
    private var realSamples = 0
    private var sessionBaseSamples = 0
    private var sessionNumber = 0
    private var recording = false

    /// Upload queue (guide §9.2): ≤ 2 concurrent; the stub transcriber
    /// resolves instantly, the M3 uploader will not.
    private var uploadQueue: [Int] = []
    private var uploadsInFlight = 0

    private var liveContinuation: AsyncStream<RecordingLiveUpdate>.Continuation?

    private var audioFileURL: URL { noteFolderURL.appending(path: "audio.webm") }
    private var pendingDirURL: URL { noteFolderURL.appending(path: ".simbi/pending") }
    private var sessionBaseSeconds: TimeInterval { TimeInterval(sessionBaseSamples) / 16000 }

    public init(
        noteFolderURL: URL,
        transcriber: Transcriber = StubTranscriber(),
        diarizer: DiarizerStream
    ) {
        self.noteFolderURL = noteFolderURL
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.outbox = TranscriptOutbox(
            fileURL: noteFolderURL.appending(path: "transcript.vtt"),
            noteName: noteFolderURL.lastPathComponent)
        self.state = (try? NoteRecordingState.load(noteFolder: noteFolderURL)) ?? .init()
    }

    /// Live updates for the record UI (elapsed + tentative speaker).
    public func liveUpdates() -> AsyncStream<RecordingLiveUpdate> {
        AsyncStream { continuation in
            self.liveContinuation = continuation
        }
    }

    public var isRecording: Bool { recording }
    public var canResume: Bool { state.sessionCount > 0 }

    // MARK: - Start / resume (§10.2)

    public func start() async throws {
        guard !recording else { throw RecordingPipelineError.alreadyRecording }
        try await diarizer.prepare()
        state = (try? NoteRecordingState.load(noteFolder: noteFolderURL)) ?? .init()

        if state.activeSession != nil {
            try recoverFromCrash()
        }

        sessionNumber = state.sessionCount + 1
        sessionBaseSamples = state.totalSamples
        realSamples = 0
        ring = SampleRingBuffer()
        engine = CutEngine()
        diarizer.resetSession()

        if sessionNumber == 1 || !FileManager.default.fileExists(atPath: audioFileURL.path) {
            encoder = try OpusWebMEncoder(fileURL: audioFileURL, mode: .create)
        } else {
            // Verify the file matches state.json bookkeeping (±1 cluster).
            let probe = try OpusWebMDecoder(fileURL: audioFileURL)
            let expectedMs = Int64(sessionBaseSamples / 16)
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
        try state.save(noteFolder: noteFolderURL)
        try outbox.append(
            .sessionStart(n: sessionNumber, wallClock: .now, offset: sessionBaseSeconds))
        recording = true
    }

    // MARK: - PCM ingestion (§7)

    /// Delivers one mixed 16 kHz mono batch to the three sinks in order.
    public func ingest(samples: [Float]) throws {
        guard recording else { return }
        ring.append(samples)
        try encoder?.append(samples: samples)
        // Flush the muxer per batch: a crash then loses < 20 ms of tail
        // audio (§11 promises 1–2 s; stdio flush per ~10 ms batch is cheap).
        try encoder?.flush()
        realSamples += samples.count
        diarizer.addAudio(samples)
        while let chunk = try diarizer.process() {
            try consume(chunk, realFrameEnd: Int.max)
        }
    }

    private func consume(_ chunk: DiarizerChunkResult, realFrameEnd: Int) throws {
        for i in 0..<chunk.finalizedFrameCount {
            let frame = chunk.startFrame + i
            let label: FrameLabel
            if frame >= realFrameEnd {
                label = .silence  // stop-pad region (§10.1)
            } else {
                let base = chunk.finalizedPredictions.index(
                    chunk.finalizedPredictions.startIndex, offsetBy: i * 4)
                label = labelFrame(
                    probabilities: chunk.finalizedPredictions[base..<(base + 4)])
            }
            for action in engine.push(label: label) {
                try perform(action)
            }
        }
        liveContinuation?.yield(
            RecordingLiveUpdate(
                elapsed: sessionBaseSeconds + TimeInterval(realSamples) / 16000,
                tentativeSpeaker: chunk.tentativeSpeaker))
    }

    // MARK: - Cut actions

    private var realAudioEndSec: TimeInterval {
        sessionBaseSeconds + TimeInterval(realSamples) / 16000
    }

    private func noteTime(_ frame: Int) -> TimeInterval {
        sessionBaseSeconds + TimeInterval(frame) * DiarizerPreset.frameDuration
    }

    private func perform(_ action: CutAction) throws {
        switch action {
        case .gap(let startFrame, let endFrame):
            try outbox.append(
                .gap(
                    start: noteTime(startFrame),
                    end: min(noteTime(endFrame), realAudioEndSec)))
        case .flush(let command):
            try flushSegment(command)
        }
    }

    private func flushSegment(_ command: FlushCommand) throws {
        let cueIndex = state.nextCueIndex
        let startSec = noteTime(command.startFrame)
        let endSec = min(noteTime(command.endFrame), realAudioEndSec)

        // One contiguous PCM slice (§6.3 step 5); the upper bound clamps to
        // written audio for the stop-time final frame.
        let sliceEnd = min(command.endFrame * 1280, ring.writeHead)
        let pcm = ring.slice((command.startFrame * 1280)..<sliceEnd)

        let webmURL = pendingDirURL.appending(path: "\(cueIndex).webm")
        let segmentEncoder = try OpusWebMEncoder(fileURL: webmURL, mode: .create)
        try segmentEncoder.append(samples: pcm)
        try segmentEncoder.finish()

        let sidecar = PendingSegment(
            cueIndex: cueIndex, startSec: startSec, endSec: endSec,
            speaker: command.speaker, continuation: command.continuation, attempts: 0)
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try jsonEncoder.encode(sidecar)
            .write(to: pendingDirURL.appending(path: "\(cueIndex).json"), options: .atomic)

        // Every fallible step is done: only now consume the cue index
        // (a throw above must not leave a gap in the numbering) and expose
        // the cue to the outbox and upload queue.
        state.nextCueIndex += 1
        try? state.save(noteFolder: noteFolderURL)
        outbox.reserveCue(
            index: cueIndex, start: startSec, end: endSec,
            speaker: "Speaker \(command.speaker + 1)",
            continuation: command.continuation)
        enqueueUpload(cueIndex)

        // Eviction floor (§8): everything before the flushed range's end is
        // no longer referenced (buffer restarts at the cut frame).
        ring.setEvictionFloor(sliceEnd)
    }

    // MARK: - Upload workers (§9.2, stub in M2)

    private func enqueueUpload(_ cueIndex: Int) {
        uploadQueue.append(cueIndex)
        kickUploads()
    }

    private func kickUploads() {
        while uploadsInFlight < 2, !uploadQueue.isEmpty {
            let cueIndex = uploadQueue.removeFirst()
            uploadsInFlight += 1
            let webmURL = pendingDirURL.appending(path: "\(cueIndex).webm")
            let jsonURL = pendingDirURL.appending(path: "\(cueIndex).json")
            Task {
                let text: String
                do {
                    text = try await self.transcriber.transcribe(webmFile: webmURL)
                    try? FileManager.default.removeItem(at: webmURL)
                    try? FileManager.default.removeItem(at: jsonURL)
                } catch {
                    // Terminal failure: keep pending files for retry tooling.
                    text = "[inaudible]"
                }
                self.uploadFinished(cueIndex: cueIndex, text: text)
            }
        }
    }

    private func uploadFinished(cueIndex: Int, text: String) {
        try? outbox.fulfillCue(index: cueIndex, text: text)
        uploadsInFlight -= 1
        kickUploads()
    }

    // MARK: - Stop (§10.1)

    public func stop() async throws {
        guard recording else { throw RecordingPipelineError.notRecording }
        recording = false

        let realFrameEnd = (realSamples + 1279) / 1280
        engine.beginStop(realFrameEnd: realFrameEnd)

        // Stop-pad: zeros to the diarizer ONLY (§0 fact 7 / §10.1 step 3).
        diarizer.addAudio([Float](repeating: 0, count: Int(16000 * CutConstants.stopPadSeconds)))
        while let chunk = try diarizer.process() {
            try consume(chunk, realFrameEnd: realFrameEnd)
        }
        if let chunk = try diarizer.finalizeSession() {
            try consume(chunk, realFrameEnd: realFrameEnd)
        }

        for action in engine.stop(realFrameEnd: realFrameEnd) {
            try perform(action)
        }

        try outbox.append(
            .sessionEnd(n: sessionNumber, wallClock: .now, offset: realAudioEndSec))

        try encoder?.finish()
        encoder = nil

        state.totalSamples = sessionBaseSamples + realSamples
        state.sessionCount = sessionNumber
        state.lastSessionEnd = .now
        state.activeSession = nil
        try state.save(noteFolder: noteFolderURL)
        liveContinuation?.finish()
        liveContinuation = nil
    }

    // MARK: - Crash recovery (§10.3)

    private func recoverFromCrash() throws {
        guard let active = state.activeSession else { return }

        // 1. Scan the surviving clusters (a truncated trailing cluster
        //    simply fails to parse and is excluded).
        var recoveredSamples = 0
        if let probe = try? OpusWebMDecoder(fileURL: audioFileURL) {
            recoveredSamples = Int(probe.endMilliseconds) * 16
        }

        // 2. Clamp to the last cue's end so later sessions never overlap
        //    cues written just before the crash.
        var lastCueEndSec: TimeInterval = 0
        let vttURL = noteFolderURL.appending(path: "transcript.vtt")
        if let text = try? String(contentsOf: vttURL, encoding: .utf8),
            let document = try? VTTParser.parse(text)
        {
            for case .cue(_, _, let end, _, _, _) in document.entries {
                lastCueEndSec = max(lastCueEndSec, end)
            }
        }
        let totalSamples = max(recoveredSamples, Int((lastCueEndSec * 16000).rounded(.up)))

        // 3. Rewrite state; the true wall-clock end is unknowable.
        let estimatedEnd = active.wallStart.addingTimeInterval(
            TimeInterval(totalSamples - active.baseSamples) / 16000)
        state.totalSamples = totalSamples
        state.sessionCount = active.n
        state.lastSessionEnd = estimatedEnd
        state.activeSession = nil
        try state.save(noteFolder: noteFolderURL)

        // 4. Re-enqueue pending uploads in cueIndex order.
        let pendingIndices =
            ((try? FileManager.default.contentsOfDirectory(
                at: pendingDirURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .compactMap { Int($0.deletingPathExtension().lastPathComponent) }
            .sorted()
        for cueIndex in pendingIndices {
            let jsonURL = pendingDirURL.appending(path: "\(cueIndex).json")
            guard let data = try? Data(contentsOf: jsonURL),
                let sidecar = try? JSONDecoder().decode(PendingSegment.self, from: data)
            else { continue }
            outbox.reserveCue(
                index: sidecar.cueIndex, start: sidecar.startSec, end: sidecar.endSec,
                speaker: "Speaker \(sidecar.speaker + 1)",
                continuation: sidecar.continuation)
            enqueueUpload(sidecar.cueIndex)
        }

        // 5. Close the unfinished session in the transcript.
        try outbox.append(
            .sessionEnd(
                n: active.n, wallClock: estimatedEnd,
                offset: TimeInterval(totalSamples) / 16000))
    }
}
