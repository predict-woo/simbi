import AVFoundation
import Foundation
import UniformTypeIdentifiers

public enum MediaFileDecoderError: Error, Equatable {
    case unreadable
    case noAudioTrack
}

public protocol MediaDecoding: Sendable {
    /// 16 kHz mono Float32 batches in file order. Throws on unreadable
    /// files or files without an audio track.
    func decode(url: URL) -> AsyncThrowingStream<[Float], Error>
}

/// What a files/ entry is, for routing (import vs anydoc vs neither).
public enum MediaKind: Equatable, Sendable {
    /// AVFoundation-decodable audio/video: route to the import pipeline.
    case supported
    /// Recognized media AVFoundation can't read (webm/mkv/ogg): failed row.
    case unsupported
    /// Not media: the existing document-converter path.
    case document
}

/// Decodes any AVFoundation-readable audio or video file into the recording
/// pipeline's sample format through a single AVAssetReader path.
public struct MediaFileDecoder: MediaDecoding, Sendable {
    public init() {}

    public static func kind(of fileName: String) -> MediaKind {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if ["webm", "mkv", "ogg", "oga", "opus"].contains(ext) { return .unsupported }
        guard let type = UTType(filenameExtension: ext) else { return .document }
        return type.conforms(to: .audiovisualContent) ? .supported : .document
    }

    public func decode(url: URL) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let asset = AVURLAsset(url: url)
                    let tracks = try await asset.loadTracks(withMediaType: .audio)
                    guard !tracks.isEmpty else { throw MediaFileDecoderError.noAudioTrack }
                    let reader = try AVAssetReader(asset: asset)
                    // The mix output resamples + downmixes for us: all audio
                    // tracks to 16 kHz mono Float32 (the pipeline format).
                    let output = AVAssetReaderAudioMixOutput(
                        audioTracks: tracks,
                        audioSettings: [
                            AVFormatIDKey: kAudioFormatLinearPCM,
                            AVSampleRateKey: OpusWebMFormat.sampleRate,
                            AVNumberOfChannelsKey: 1,
                            AVLinearPCMBitDepthKey: 32,
                            AVLinearPCMIsFloatKey: true,
                            AVLinearPCMIsNonInterleaved: false,
                            AVLinearPCMIsBigEndianKey: false,
                        ] as [String: Any])
                    guard reader.canAdd(output) else { throw MediaFileDecoderError.unreadable }
                    reader.add(output)
                    guard reader.startReading() else { throw MediaFileDecoderError.unreadable }
                    while let sampleBuffer = output.copyNextSampleBuffer() {
                        if Task.isCancelled {
                            reader.cancelReading()
                            break
                        }
                        if let samples = Self.floats(from: sampleBuffer), !samples.isEmpty {
                            continuation.yield(samples)
                        }
                    }
                    if reader.status == .failed {
                        throw reader.error ?? MediaFileDecoderError.unreadable
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func floats(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return [] }
        var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        let status = data.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(
                blockBuffer, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
        }
        return status == kCMBlockBufferNoErr ? data : nil
    }
}
