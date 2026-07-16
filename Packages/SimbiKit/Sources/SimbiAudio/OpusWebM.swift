import CLibOpus
import CLibWebM
import Foundation

/// Errors from the Opus/WebM encode and decode paths.
public enum OpusWebMError: Error, Equatable {
    case encoderCreateFailed(Int32)
    case decoderCreateFailed(Int32)
    case encodeFailed(Int32)
    case decodeFailed(Int32)
    case fileCreateFailed
    case fileAppendFailed
    case fileParseFailed
    case muxWriteFailed
}

/// Shared constants of Simbi's single audio format (SPEC.md §3.1/§3.3):
/// 16 kHz mono Float32 in, Opus ~24 kbps VBR in live-mode WebM out.
public enum OpusWebMFormat {
    public static let sampleRate: Int32 = 16000
    public static let channels: Int32 = 1
    public static let bitrate: Int32 = 24000
    /// 20 ms frames: 320 samples at 16 kHz.
    public static let frameSamples = 320
    public static let frameMilliseconds: UInt64 = 20
    /// Start a new cluster every ~5 s (crash-recovery and seek granularity).
    public static let clusterMilliseconds: UInt64 = 5000
    /// WebM/Opus mandates 80 ms SeekPreRoll.
    static let seekPreRollNs: UInt64 = 80_000_000
}

/// Builds the 19-byte OpusHead CodecPrivate for mono
/// (https://datatracker.ietf.org/doc/html/rfc7845#section-5.1).
func opusHead(preSkip48k: UInt16, inputSampleRate: UInt32, channels: UInt8) -> [UInt8] {
    var head: [UInt8] = Array("OpusHead".utf8)
    head.append(1)  // version
    head.append(channels)
    head.append(contentsOf: withUnsafeBytes(of: preSkip48k.littleEndian) { Array($0) })
    head.append(contentsOf: withUnsafeBytes(of: inputSampleRate.littleEndian) { Array($0) })
    head.append(contentsOf: [0, 0])  // output gain, Q7.8
    head.append(0)  // channel mapping family 0
    return head
}

/// Streaming encoder: Float32 PCM in, live-mode WebM/Opus appended to a
/// file. One instance per recording session; a stop/resume creates a new
/// instance in `.append` mode with the resumed timeline offset.
public final class OpusWebMEncoder {
    public enum Mode {
        /// New file: writes EBML/Segment/Info/Tracks headers.
        case create
        /// Existing live-mode file: appends clusters only. `baseMilliseconds`
        /// is the note-timeline offset of the first new sample (= end of the
        /// previous session, from the cluster index).
        case append(baseMilliseconds: UInt64)
    }

    private let encoder: OpaquePointer
    private let writer: OpaquePointer
    private var pending: [Float] = []
    private var framesWritten: UInt64 = 0
    private let baseMs: UInt64
    private var currentClusterStartMs: UInt64?
    private var packetBuffer = [UInt8](repeating: 0, count: 4000)

    /// Timeline position (ms) of the next sample to be appended.
    public var positionMilliseconds: UInt64 {
        baseMs + framesWritten * OpusWebMFormat.frameMilliseconds
    }

    public init(fileURL: URL, mode: Mode) throws {
        var err: Int32 = 0
        guard
            let encoder = opus_encoder_create(
                OpusWebMFormat.sampleRate, OpusWebMFormat.channels,
                OPUS_APPLICATION_AUDIO, &err), err == OPUS_OK
        else {
            throw OpusWebMError.encoderCreateFailed(err)
        }
        opus_encoder_ctl_set(encoder, OPUS_SET_BITRATE_REQUEST, OpusWebMFormat.bitrate)
        opus_encoder_ctl_set(encoder, OPUS_SET_VBR_REQUEST, 1)

        switch mode {
        case .create:
            // Encoder lookahead is reported at the input rate (16 kHz);
            // OpusHead pre-skip is in 48 kHz samples.
            var lookahead: Int32 = 0
            opus_encoder_ctl_get(encoder, OPUS_GET_LOOKAHEAD_REQUEST, &lookahead)
            let preSkip48k = UInt16(clamping: Int(lookahead) * 3)
            let head = opusHead(
                preSkip48k: preSkip48k,
                inputSampleRate: UInt32(OpusWebMFormat.sampleRate),
                channels: UInt8(OpusWebMFormat.channels))
            let codecDelayNs = UInt64(preSkip48k) * 1_000_000_000 / 48000
            guard
                let writer = fileURL.path.withCString({ path in
                    head.withUnsafeBufferPointer { headBuf in
                        swebm_writer_create(
                            path, headBuf.baseAddress, headBuf.count,
                            48000.0,  // Opus output clock, per WebM convention
                            UInt64(OpusWebMFormat.channels),
                            codecDelayNs, OpusWebMFormat.seekPreRollNs)
                    }
                })
            else {
                opus_encoder_destroy(encoder)
                throw OpusWebMError.fileCreateFailed
            }
            self.writer = writer
            self.baseMs = 0
        case .append(let baseMilliseconds):
            guard let writer = fileURL.path.withCString({ swebm_writer_append($0) }) else {
                opus_encoder_destroy(encoder)
                throw OpusWebMError.fileAppendFailed
            }
            self.writer = writer
            self.baseMs = baseMilliseconds
        }
        self.encoder = encoder
    }

    deinit {
        opus_encoder_destroy(encoder)
    }

    /// Appends 16 kHz mono samples; encodes every full 20 ms frame.
    public func append(samples: [Float]) throws {
        pending.append(contentsOf: samples)
        while pending.count >= OpusWebMFormat.frameSamples {
            let frame = Array(pending.prefix(OpusWebMFormat.frameSamples))
            pending.removeFirst(OpusWebMFormat.frameSamples)
            try encode(frame: frame)
        }
    }

    /// Pads any trailing partial frame with silence, closes the cluster and
    /// the file. The encoder is unusable afterwards. Returns the final
    /// timeline position in milliseconds.
    @discardableResult
    public func finish() throws -> UInt64 {
        if !pending.isEmpty {
            var frame = pending
            frame.append(
                contentsOf: [Float](repeating: 0, count: OpusWebMFormat.frameSamples - frame.count))
            pending.removeAll()
            try encode(frame: frame)
        }
        let end = positionMilliseconds
        guard swebm_writer_close(writer) == 0 else { throw OpusWebMError.muxWriteFailed }
        return end
    }

    /// Flushes muxed bytes to disk (call after each cluster for crash
    /// tolerance; the file is valid at every flush point).
    public func flush() throws {
        guard swebm_writer_flush(writer) == 0 else { throw OpusWebMError.muxWriteFailed }
    }

    private func encode(frame: [Float]) throws {
        let timecodeMs = positionMilliseconds
        let written = frame.withUnsafeBufferPointer { pcm in
            packetBuffer.withUnsafeMutableBufferPointer { out in
                opus_encode_float(
                    encoder, pcm.baseAddress!, Int32(OpusWebMFormat.frameSamples),
                    out.baseAddress!, opus_int32(out.count))
            }
        }
        guard written > 0 else { throw OpusWebMError.encodeFailed(written) }

        if let start = currentClusterStartMs,
            timecodeMs - start < OpusWebMFormat.clusterMilliseconds
        {
            // stay in the current cluster
        } else {
            guard swebm_writer_begin_cluster(writer, timecodeMs) == 0 else {
                throw OpusWebMError.muxWriteFailed
            }
            currentClusterStartMs = timecodeMs
            try flush()
        }
        let rc = packetBuffer.withUnsafeBufferPointer { buf in
            swebm_writer_add_frame(writer, buf.baseAddress, Int(written), timecodeMs)
        }
        guard rc == 0 else { throw OpusWebMError.muxWriteFailed }
        framesWritten += 1
    }
}

/// Cluster-indexed reader/decoder for Simbi's live-mode WebM files.
public final class OpusWebMDecoder {
    public struct ClusterEntry: Equatable, Sendable {
        public let time: TimeInterval
        public let byteOffset: Int64
    }

    private let reader: OpaquePointer

    /// The cluster index built at open (SPEC.md §3.1: built once at
    /// note-open, used for seeks and for the resume timeline offset).
    public let clusterIndex: [ClusterEntry]

    /// Start time of the last packet in the file, or nil for an empty file.
    public let lastPacketTime: TimeInterval?

    /// Timeline end (ms) for resuming: last packet start + one frame.
    public var endMilliseconds: UInt64 {
        guard let lastPacketTime else { return 0 }
        return UInt64((lastPacketTime * 1000).rounded()) + OpusWebMFormat.frameMilliseconds
    }

    public init(fileURL: URL) throws {
        guard let reader = fileURL.path.withCString({ swebm_reader_open($0) }) else {
            throw OpusWebMError.fileParseFailed
        }
        self.reader = reader
        var index: [ClusterEntry] = []
        for i in 0..<swebm_reader_cluster_count(reader) {
            var timeNs: Int64 = 0
            var offset: Int64 = 0
            if swebm_reader_cluster_info(reader, i, &timeNs, &offset) == 0 {
                index.append(
                    ClusterEntry(time: TimeInterval(timeNs) / 1e9, byteOffset: offset))
            }
        }
        self.clusterIndex = index
        let lastNs = swebm_reader_last_block_time_ns(reader)
        self.lastPacketTime = lastNs >= 0 ? TimeInterval(lastNs) / 1e9 : nil
    }

    deinit {
        swebm_reader_close(reader)
    }

    /// Decodes from the cluster containing `startTime` to end of file.
    /// Returns 16 kHz mono samples and the timeline time of the first
    /// returned sample.
    public func decode(
        from startTime: TimeInterval = 0
    ) throws -> (
        samples: [Float], startTime: TimeInterval
    ) {
        let iterator = try packets(from: startTime)
        var samples: [Float] = []
        var firstTime: TimeInterval?
        while let chunk = try iterator.next(maxSamples: .max) {
            if firstTime == nil { firstTime = chunk.startTime }
            samples.append(contentsOf: chunk.samples)
        }
        return (samples, firstTime ?? 0)
    }

    /// Incremental decode for playback (SPEC.md §3.1): packets from the
    /// cluster containing `startTime`, decoded in bounded chunks so a long
    /// recording never has to sit in memory whole.
    public func packets(from startTime: TimeInterval = 0) throws -> PacketIterator {
        try PacketIterator(owner: self, reader: reader, startTime: startTime)
    }

    /// Chunked decoder over one seek's packet run. Holds its parent decoder
    /// alive (the libwebm reader must outlive the iterator).
    public final class PacketIterator {
        private let owner: OpusWebMDecoder
        private let iter: OpaquePointer
        private let decoder: OpaquePointer
        private var packet = [UInt8](repeating: 0, count: 8192)
        private var pcm = [Float](repeating: 0, count: OpusWebMFormat.frameSamples * 6)
        private var finished = false

        fileprivate init(
            owner: OpusWebMDecoder, reader: OpaquePointer, startTime: TimeInterval
        )
            throws
        {
            var err: Int32 = 0
            guard
                let decoder = opus_decoder_create(
                    OpusWebMFormat.sampleRate, OpusWebMFormat.channels, &err), err == OPUS_OK
            else {
                throw OpusWebMError.decoderCreateFailed(err)
            }
            guard let iter = swebm_iter_create(reader, Int64(startTime * 1e9)) else {
                opus_decoder_destroy(decoder)
                throw OpusWebMError.fileParseFailed
            }
            self.owner = owner
            self.iter = iter
            self.decoder = decoder
        }

        deinit {
            swebm_iter_free(iter)
            opus_decoder_destroy(decoder)
        }

        /// Decodes whole packets until at least `maxSamples` are gathered
        /// (or EOF). Returns nil once the file is exhausted. `startTime` is
        /// the timeline time of the chunk's first sample.
        public func next(
            maxSamples: Int = OpusWebMFormat.frameSamples * 50
        ) throws -> (
            samples: [Float], startTime: TimeInterval
        )? {
            guard !finished else { return nil }
            var samples: [Float] = []
            var firstTime: TimeInterval?
            while samples.count < maxSamples {
                var timeNs: Int64 = 0
                var len = 0
                let rc = packet.withUnsafeMutableBufferPointer { buf in
                    swebm_iter_next(iter, &timeNs, buf.baseAddress, buf.count, &len)
                }
                if rc == 0 {
                    finished = true
                    break
                }
                if rc == -2 {
                    packet = [UInt8](repeating: 0, count: len)
                    continue
                }
                guard rc == 1 else { throw OpusWebMError.fileParseFailed }
                let decoded = packet.withUnsafeBufferPointer { inBuf in
                    pcm.withUnsafeMutableBufferPointer { outBuf in
                        opus_decode_float(
                            decoder, inBuf.baseAddress!, opus_int32(len),
                            outBuf.baseAddress!, Int32(outBuf.count), 0)
                    }
                }
                guard decoded > 0 else { throw OpusWebMError.decodeFailed(decoded) }
                if firstTime == nil { firstTime = TimeInterval(timeNs) / 1e9 }
                samples.append(contentsOf: pcm.prefix(Int(decoded)))
            }
            guard let firstTime else { return nil }
            return (samples, firstTime)
        }
    }
}
