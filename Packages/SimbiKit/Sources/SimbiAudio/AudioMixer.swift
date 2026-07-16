import Foundation
import os

/// Mixes the two 16 kHz mono capture streams into ONE (SPEC.md §3.1: simple
/// sum with per-source gain, soft-clip limiter). The mic stream is the
/// clock: each mic batch pulls matching system-audio samples from a bounded
/// FIFO — zeros when the system side runs short, and backlog beyond
/// `maxBacklogSamples` is dropped (oldest first) so drift and memory stay
/// bounded. Pure state machine; the capture facade serializes access.
public struct AudioMixer: Sendable {
    public var micGain: Float
    public var systemGain: Float
    public let maxBacklogSamples: Int

    private var fifo: [Float] = []
    /// Read position into `fifo` (compacted lazily, avoids O(n) removeFirst).
    private var fifoStart = 0

    public init(micGain: Float = 1, systemGain: Float = 1, maxBacklogSamples: Int = 16000) {
        self.micGain = micGain
        self.systemGain = systemGain
        self.maxBacklogSamples = maxBacklogSamples
    }

    public var backlog: Int { fifo.count - fifoStart }

    public mutating func pushSystem(_ samples: [Float]) {
        fifo.append(contentsOf: samples)
        let excess = backlog - maxBacklogSamples
        if excess > 0 {
            fifoStart += excess
        }
        if fifoStart > maxBacklogSamples {
            fifo.removeFirst(fifoStart)
            fifoStart = 0
        }
    }

    public mutating func mix(mic: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: mic.count)
        for i in 0..<mic.count {
            let system: Float = fifoStart < fifo.count ? fifo[fifoStart] : 0
            if fifoStart < fifo.count { fifoStart += 1 }
            out[i] = Self.softClip(micGain * mic[i] + systemGain * system)
        }
        if fifoStart > maxBacklogSamples {
            fifo.removeFirst(fifoStart)
            fifoStart = 0
        }
        return out
    }

    /// tanh soft-clip: bounded to (-1, 1), ~linear for normal speech levels.
    public static func softClip(_ x: Float) -> Float {
        tanhf(x)
    }
}

/// Owns the capture sources for one recording and exposes the single mixed
/// 16 kHz mono stream the pipeline ingests (SPEC.md §3.1). If system-audio
/// capture can't start (permission denied, pre-14.4 macOS), capture
/// proceeds mic-only and the failure is surfaced for the UI banner
/// (SPEC.md §7).
public final class MixedCapture: @unchecked Sendable {
    public enum Source: Sendable, Equatable {
        case mic
        case micAndSystem
    }

    /// Why system audio is off even though `micAndSystem` was requested.
    public private(set) var systemAudioFailure: String?
    /// True when the system tap is actually contributing to the stream.
    public private(set) var systemAudioActive = false

    private let mic = MicCapture()
    private var system: (any SystemCapturing)?
    /// Mixer state shared by the mic and system consumer tasks.
    private let mixer: OSAllocatedUnfairLock<AudioMixer>
    private var systemTask: Task<Void, Never>?

    /// Test seam: the spike/tests inject a fake system source.
    private let makeSystemCapture: @Sendable () throws -> any SystemCapturing

    public init(
        mixer: AudioMixer = AudioMixer(),
        makeSystemCapture: @escaping @Sendable () throws -> any SystemCapturing = {
            guard #available(macOS 14.4, *) else {
                throw MixedCaptureError.systemAudioUnsupported
            }
            return SystemAudioCapture()
        }
    ) {
        self.mixer = OSAllocatedUnfairLock(initialState: mixer)
        self.makeSystemCapture = makeSystemCapture
    }

    public enum MixedCaptureError: Error {
        /// System-audio capture needs macOS 14.4+ (SPEC.md §3.1).
        case systemAudioUnsupported
    }

    /// Starts capture and returns the mixed stream. Mic failure throws;
    /// system-audio failure degrades to mic-only (check
    /// `systemAudioFailure`).
    public func start(source: Source) throws -> AsyncStream<[Float]> {
        let micStream = try mic.start()
        guard source == .micAndSystem else { return micStream }

        let systemStream: AsyncStream<[Float]>
        do {
            let capture = try makeSystemCapture()
            systemStream = try capture.start()
            system = capture
        } catch {
            systemAudioFailure = failureMessage(for: error)
            return micStream
        }
        systemAudioActive = true

        let (mixed, continuation) = AsyncStream.makeStream(of: [Float].self)
        systemTask = Task { [weak self] in
            for await batch in systemStream {
                guard let self else { break }
                self.mixer.withLock { $0.pushSystem(batch) }
            }
        }
        Task { [weak self] in
            for await batch in micStream {
                guard let self else { break }
                continuation.yield(self.mixer.withLock { $0.mix(mic: batch) })
            }
            continuation.finish()
        }
        return mixed
    }

    /// Stops both sources; the mixed stream finishes after delivering
    /// everything already captured (the pipeline drains before stopping).
    public func stop() {
        mic.stop()
        system?.stop()
        system = nil
        systemTask?.cancel()
        systemTask = nil
        systemAudioActive = false
    }

    private func failureMessage(for error: any Error) -> String {
        if case MixedCaptureError.systemAudioUnsupported = error {
            return "System audio needs macOS 14.4 or later — recording mic only."
        }
        return "System audio unavailable (permission denied?) — recording mic only."
    }
}

/// What MixedCapture needs from a system-audio source (lets the silent
/// spike and tests inject fakes; SystemAudioCapture is the real one).
public protocol SystemCapturing: Sendable {
    func start() throws -> AsyncStream<[Float]>
    func stop()
}

@available(macOS 14.4, *)
extension SystemAudioCapture: SystemCapturing {}
