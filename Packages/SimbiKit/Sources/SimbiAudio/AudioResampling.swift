// @preconcurrency: the converter input block captures AVAudio types that
// AVFAudio doesn't mark Sendable; each call runs synchronously on its
// caller's tap queue.
@preconcurrency import AVFoundation

/// Conversion to the pipeline format (16 kHz mono Float32) — the
/// per-callback dance the mic tap and the system tap share.
enum AudioResampling {
    /// The pipeline capture format; nil only if AVFoundation refuses the
    /// canonical parameters.
    static var pipelineFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(OpusWebMFormat.sampleRate),
            channels: 1, interleaved: false)
    }

    /// Converts one captured buffer through a persistent AVAudioConverter,
    /// returning the mono samples — nil when the converter errors or
    /// produces nothing.
    static func convert(
        _ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter,
        to targetFormat: AVAudioFormat
    ) -> [Float]? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard
            let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return nil }
        // nonisolated(unsafe): the input block only runs synchronously
        // inside `convert` below, on this thread.
        nonisolated(unsafe) var fed = false
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
        else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
    }
}
