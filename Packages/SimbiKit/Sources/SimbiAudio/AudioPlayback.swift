// @preconcurrency: scheduling closures capture AVAudio types that AVFAudio
// doesn't mark Sendable; access is serialized by the playback lock.
@preconcurrency import AVFoundation
import Foundation
import os

public enum AudioPlaybackError: Error, Equatable {
    /// The 16 kHz mono pipeline format failed to construct — an
    /// environment problem, not a file problem (mirrors the capture
    /// classes' `converterUnavailable`).
    case pipelineFormatUnavailable
}

/// Plays a note's `audio.webm` (SPEC.md §3.1). AVFoundation can't read
/// WebM, so this is our own small path: cluster-index seek + libopus decode
/// → PCM buffers scheduled on an `AVAudioPlayerNode` with bounded
/// lookahead (a long recording never sits in memory whole).
public final class AudioPlayback: @unchecked Sendable {
    private let fileURL: URL
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat
    /// ~1 s of audio per scheduled buffer, at most 4 in flight.
    private let chunkSamples = Int(OpusWebMFormat.sampleRate)
    private let lookahead = 4

    private struct State {
        var isPlaying = false
        var startOffset: TimeInterval = 0
        var generation = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    // Lookahead gate. NSCondition (not DispatchSemaphore): node.stop()
    // destroys pending completion blocks WITHOUT calling them, and a
    // dispatch semaphore deallocated below its initial value traps.
    private let bufferGate = NSCondition()
    private var inFlight = 0
    private var feederDone = false

    /// Fires on the playback queue when the file end is reached (not on
    /// explicit `stop()`).
    public var onFinished: (@Sendable () -> Void)?

    public init(fileURL: URL, manualRenderingForTest: Bool = false) throws {
        self.fileURL = fileURL
        guard let format = AudioResampling.pipelineFormat
        else { throw AudioPlaybackError.pipelineFormatUnavailable }
        self.format = format
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        if manualRenderingForTest {
            try engine.enableManualRenderingMode(
                .offline, format: format, maximumFrameCount: 4096)
        }
    }

    public var isPlaying: Bool {
        state.withLock { $0.isPlaying }
    }

    /// Timeline duration of the file right now (the file grows while
    /// recording; recompute per call).
    public var duration: TimeInterval {
        guard let decoder = try? OpusWebMDecoder(fileURL: fileURL) else { return 0 }
        return TimeInterval(decoder.endMilliseconds) / 1000
    }

    /// Current timeline position, derived from the player's render clock.
    public var position: TimeInterval {
        let (playing, offset) = state.withLock { ($0.isPlaying, $0.startOffset) }
        guard playing, let nodeTime = node.lastRenderTime,
            let playerTime = node.playerTime(forNodeTime: nodeTime)
        else { return offset }
        return offset + Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    /// Starts (or restarts) playback at `time`. Decode runs on a dedicated
    /// feeder thread with bounded lookahead; buffers land on the player
    /// node. Cluster granularity is 5 s, so leading samples up to `time`
    /// are skipped for a precise seek.
    public func play(from time: TimeInterval) throws {
        stop()
        let decoder = try OpusWebMDecoder(fileURL: fileURL)
        let iterator = try decoder.packets(from: time)

        let generation = state.withLock { state -> Int in
            state.generation += 1
            state.isPlaying = true
            state.startOffset = time
            return state.generation
        }
        bufferGate.lock()
        inFlight = 0
        feederDone = false
        bufferGate.unlock()

        try engine.start()
        node.play()

        Thread.detachNewThread { [weak self] in
            var skipRemaining: Int?
            while true {
                guard let self, self.state.withLock({ $0.generation == generation }) else {
                    return
                }
                guard let chunk = try? iterator.next(maxSamples: self.chunkSamples) else {
                    break
                }
                if skipRemaining == nil {
                    skipRemaining = max(
                        0, Int((time - chunk.startTime) * Double(OpusWebMFormat.sampleRate)))
                }
                var samples = chunk.samples
                if let skip = skipRemaining, skip > 0 {
                    let dropped = min(skip, samples.count)
                    samples.removeFirst(dropped)
                    skipRemaining = skip - dropped
                    if samples.isEmpty { continue }
                }
                self.bufferGate.lock()
                while self.inFlight >= self.lookahead,
                    self.state.withLock({ $0.generation == generation })
                {
                    self.bufferGate.wait()
                }
                self.bufferGate.unlock()
                guard self.state.withLock({ $0.generation == generation }) else { return }
                self.schedule(samples: samples, generation: generation)
            }
            guard let self else { return }
            self.bufferGate.lock()
            self.feederDone = true
            let finished = self.inFlight == 0
            self.bufferGate.unlock()
            if finished { self.finish(generation: generation) }
        }
    }

    private func schedule(samples: [Float], generation: Int) {
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        bufferGate.lock()
        inFlight += 1
        bufferGate.unlock()
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.bufferGate.lock()
            self.inFlight -= 1
            let finished = self.feederDone && self.inFlight == 0
            self.bufferGate.signal()
            self.bufferGate.unlock()
            if finished, self.state.withLock({ $0.generation == generation }) {
                self.finish(generation: generation)
            }
        }
    }

    private func finish(generation: Int) {
        let endPosition = position  // read before the lock — position locks too
        let wasCurrent = state.withLock { state -> Bool in
            guard state.generation == generation, state.isPlaying else { return false }
            state.startOffset = endPosition
            state.isPlaying = false
            return true
        }
        guard wasCurrent else { return }
        node.stop()
        engine.stop()
        onFinished?()
    }

    /// Stops playback immediately (no `onFinished`). Safe when idle.
    public func stop() {
        let wasPlaying = state.withLock { state -> Bool in
            let was = state.isPlaying
            state.generation += 1  // orphans the feeder and its callbacks
            state.isPlaying = false
            return was
        }
        // Wake a feeder blocked on the lookahead gate so it can exit.
        bufferGate.lock()
        bufferGate.broadcast()
        bufferGate.unlock()
        guard wasPlaying else { return }
        node.stop()
        engine.stop()
    }

    /// Test hook: pulls rendered audio in manual-rendering mode.
    public func renderForTest(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: engine.manualRenderingFormat, frameCapacity: frames)
        else { return nil }
        let status = try engine.renderOffline(frames, to: buffer)
        return status == .success ? buffer : nil
    }
}
