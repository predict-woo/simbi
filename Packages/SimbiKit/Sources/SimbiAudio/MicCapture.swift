import AVFoundation
import Foundation

/// Microphone capture (SPEC.md §3.1): AVAudioEngine input-node tap,
/// converted to the pipeline format (16 kHz mono Float32) and delivered as
/// an AsyncStream of sample batches. System-audio capture and mixing arrive
/// in M6; until then the mic stream IS the mixed stream.
public final class MicCapture: @unchecked Sendable {
    public enum CaptureError: Error {
        case converterUnavailable
    }

    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<[Float]>.Continuation?

    public init() {}

    /// Starts the tap and returns the 16 kHz mono batch stream. The stream
    /// finishes when `stop()` is called.
    public func start() throws -> AsyncStream<[Float]> {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(OpusWebMFormat.sampleRate),
                channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        else {
            throw CaptureError.converterUnavailable
        }

        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
        self.continuation = continuation

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) {
            [weak self] buffer, _ in
            guard let self else { return }
            let ratio = targetFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard
                let converted = AVAudioPCMBuffer(
                    pcmFormat: targetFormat, frameCapacity: capacity)
            else { return }
            var fed = false
            var conversionError: NSError?
            converter.convert(to: converted, error: &conversionError) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard conversionError == nil, converted.frameLength > 0,
                let channel = converted.floatChannelData?[0]
            else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
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
