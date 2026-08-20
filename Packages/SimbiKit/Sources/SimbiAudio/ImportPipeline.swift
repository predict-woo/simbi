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

    // Task 7 replaces this placeholder with cue reservation + uploads.
    private func runPhase2AndDrain(
        fileName: String, entries: [ImportTimelineEntry], pcm: [Float],
        base: Int, session: Int
    ) async throws {}

    /// Relaunch recovery for a phase-2 marker: re-enqueue pending segments,
    /// drain, clear the marker. No-op without a phase-2 marker.
    public func resumePhase2() async throws {
        // Filled in Task 7.
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
