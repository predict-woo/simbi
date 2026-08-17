import AVFoundation
import Foundation

/// Microphone capture (SPEC.md §3.1): AVAudioEngine input-node tap,
/// converted to the pipeline format (16 kHz mono Float32) and delivered as
/// an AsyncStream of sample batches. `MixedCapture` mixes this stream with
/// the system-audio tap's.
public final class MicCapture: @unchecked Sendable {
    public enum CaptureError: Error {
        case converterUnavailable
        /// The requested device UID isn't connected (or refused selection).
        case deviceUnavailable
    }

    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<[Float]>.Continuation?

    public init() {}

    /// Starts the tap and returns the 16 kHz mono batch stream. The stream
    /// finishes when `stop()` is called. `deviceUID` selects a specific
    /// input device; nil follows the system default.
    public func start(deviceUID: String? = nil) throws -> AsyncStream<[Float]> {
        let input = engine.inputNode
        if let deviceUID {
            // Must happen before the first format query — selecting the
            // device changes the input node's hardware format.
            guard var deviceID = AudioInputDevices.deviceID(forUID: deviceUID),
                let audioUnit = input.audioUnit,
                AudioUnitSetProperty(
                    audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0, &deviceID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
            else {
                throw CaptureError.deviceUnavailable
            }
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard
            let targetFormat = AudioResampling.pipelineFormat,
            let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        else {
            throw CaptureError.converterUnavailable
        }

        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
        self.continuation = continuation

        input.installTap(
            onBus: 0, bufferSize: 1024, format: inputFormat
        ) { [weak self] buffer, _ in
            guard let self,
                let samples = AudioResampling.convert(buffer, using: converter, to: targetFormat)
            else { return }
            self.continuation?.yield(samples)
        }

        engine.prepare()
        try engine.start()
        return stream
    }

    /// Stops the tap and finishes the stream (delivering everything already
    /// yielded first — the pipeline drains before its stop sequence).
    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }
}
