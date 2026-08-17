// @preconcurrency: the IO block captures AVAudioConverter, which AVFAudio
// doesn't mark Sendable; access is serialized on the tap's dispatch queue.
@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// System-audio capture (SPEC.md §3.1): a CoreAudio process tap
/// (`CATapDescription` + private aggregate device, macOS 14.4+) capturing
/// system-wide output, converted to the pipeline format (16 kHz mono
/// Float32) and delivered as an AsyncStream of sample batches.
///
/// Requires the system-audio-recording TCC permission; a denial surfaces as
/// `tapCreationFailed` and the caller proceeds mic-only (SPEC.md §7).
@available(macOS 14.4, *)
public final class SystemAudioCapture: @unchecked Sendable {
    public struct Options: Sendable {
        /// Empty = tap the whole system output (production). Non-empty =
        /// tap only these processes (used by the silent M6 spike).
        public var pids: [pid_t]
        /// Mute the tapped processes' output at the device while the tap is
        /// active (`.mutedWhenTapped`) — spike-only; the app never mutes.
        public var muteWhileTapped: Bool

        public init(pids: [pid_t] = [], muteWhileTapped: Bool = false) {
            self.pids = pids
            self.muteWhileTapped = muteWhileTapped
        }
    }

    public enum CaptureError: Error {
        /// Tap creation refused — TCC permission denied is the common cause.
        case tapCreationFailed(OSStatus)
        case tapFormatUnavailable(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case ioSetupFailed(OSStatus)
        case converterUnavailable
        case processNotFound(pid_t)
    }

    private let options: Options
    private let queue = DispatchQueue(label: "app.getsimbi.mac.system-tap")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<[Float]>.Continuation?

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Starts the tap and returns the 16 kHz mono batch stream. The stream
    /// finishes when `stop()` is called.
    public func start() throws -> AsyncStream<[Float]> {
        let description: CATapDescription
        if options.pids.isEmpty {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        } else {
            let objects = try options.pids.map { try Self.processObject(forPID: $0) }
            description = CATapDescription(stereoMixdownOfProcesses: objects)
        }
        description.isPrivate = true
        description.muteBehavior = options.muteWhileTapped ? .mutedWhenTapped : .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr, tap != kAudioObjectUnknown else {
            throw CaptureError.tapCreationFailed(tapStatus)
        }
        tapID = tap

        do {
            var streamDescription = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let formatStatus = AudioObjectGetPropertyData(
                tapID, &address, 0, nil, &size, &streamDescription)
            guard formatStatus == noErr else {
                throw CaptureError.tapFormatUnavailable(formatStatus)
            }
            guard let tapFormat = AVAudioFormat(streamDescription: &streamDescription),
                let targetFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: Double(OpusWebMFormat.sampleRate),
                    channels: 1, interleaved: false),
                let converter = AVAudioConverter(from: tapFormat, to: targetFormat)
            else { throw CaptureError.converterUnavailable }

            // A private aggregate device whose only input is the tap. This
            // never touches the user's default input/output devices.
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Simbi System Audio Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                        kAudioSubTapDriftCompensationKey: true,
                    ]
                ],
            ]
            var aggregate = AudioObjectID(kAudioObjectUnknown)
            let aggregateStatus = AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary, &aggregate)
            guard aggregateStatus == noErr, aggregate != kAudioObjectUnknown else {
                throw CaptureError.aggregateCreationFailed(aggregateStatus)
            }
            aggregateID = aggregate

            let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
            self.continuation = continuation

            var ioProc: AudioDeviceIOProcID?
            let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
                &ioProc, aggregateID, queue
            ) { [weak self] _, inputData, _, _, _ in
                self?.deliver(
                    inputData, tapFormat: tapFormat, converter: converter,
                    targetFormat: targetFormat)
            }
            guard ioStatus == noErr, let ioProc else {
                throw CaptureError.ioSetupFailed(ioStatus)
            }
            ioProcID = ioProc

            let startStatus = AudioDeviceStart(aggregateID, ioProcID)
            guard startStatus == noErr else {
                throw CaptureError.ioSetupFailed(startStatus)
            }
            return stream
        } catch {
            stop()
            throw error
        }
    }

    /// Converts one IO cycle's tap buffers to 16 kHz mono and yields them —
    /// same conversion pattern the mic tap uses (MicCapture).
    private func deliver(
        _ inputData: UnsafePointer<AudioBufferList>, tapFormat: AVAudioFormat,
        converter: AVAudioConverter, targetFormat: AVAudioFormat
    ) {
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: tapFormat, bufferListNoCopy: inputData, deallocator: nil),
            buffer.frameLength > 0
        else { return }
        let ratio = targetFormat.sampleRate / tapFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard
            let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
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
        continuation?.yield(
            Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))))
    }

    /// Stops IO and tears down the aggregate device and tap. Safe to call
    /// on a partially started capture.
    public func stop() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        continuation?.finish()
        continuation = nil
    }

    /// HAL audio-object id for a running process (it registers with the HAL
    /// once it does audio IO — even inaudible IO).
    static func processObject(forPID pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pidValue = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutableBytes(of: &pidValue) { pidBytes in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(pidBytes.count), pidBytes.baseAddress, &size, &object)
        }
        guard status == noErr, object != kAudioObjectUnknown else {
            throw CaptureError.processNotFound(pid)
        }
        return object
    }
}
