import SimbiAudio
import Testing

@Suite("MixedCapture")
struct MixedCaptureTests {
    /// Silent injected system source (no real tap, no audible audio).
    final class FakeSystemCapture: SystemCapturing, @unchecked Sendable {
        private let samples: [Float]
        private var continuation: AsyncStream<[Float]>.Continuation?

        init(samples: [Float]) {
            self.samples = samples
        }

        func start() throws -> AsyncStream<[Float]> {
            let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
            continuation.yield(samples)
            self.continuation = continuation
            return stream
        }

        func stop() {
            continuation?.finish()
            continuation = nil
        }
    }

    @Test("system-only config streams the system source without the mic")
    func systemOnly() async throws {
        let fake = FakeSystemCapture(samples: [0.1, 0.2])
        let capture = MixedCapture(makeSystemCapture: { fake })
        let stream = try capture.start(
            config: .init(micEnabled: false, systemAudioEnabled: true))
        #expect(capture.systemAudioActive)

        var received: [Float] = []
        for await batch in stream {
            received += batch
            break
        }
        capture.stop()
        #expect(received == [0.1, 0.2])
        #expect(!capture.systemAudioActive)
    }

    @Test("all sources disabled is refused")
    func noSources() {
        let capture = MixedCapture()
        #expect(throws: MixedCapture.MixedCaptureError.self) {
            _ = try capture.start(
                config: .init(micEnabled: false, systemAudioEnabled: false))
        }
    }
}
