import AVFoundation
import Foundation
import Testing

@testable import SimbiAudio

@Suite("MicCapture")
struct MicCaptureTests {
    @Test("continues streaming after the input device changes")
    func recoversAfterInputDeviceChange() async throws {
        let notifications = NotificationCenter()
        let engine = FakeMicInputEngine()
        let capture = MicCapture(engine: engine, notificationCenter: notifications)
        let stream = try capture.start()
        var iterator = stream.makeAsyncIterator()

        engine.emit([0.1])
        #expect(await iterator.next() == [0.1])

        engine.simulateConfigurationChange(on: notifications)
        for _ in 0..<100 where engine.startCount < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(engine.startCount == 2)
        #expect(engine.isRunning)

        engine.emit([0.2])
        #expect(await iterator.next() == [0.2])
        capture.stop()
    }

    @Test("retries while the replacement input is becoming available")
    func retriesTransientRecoveryFailure() async throws {
        let notifications = NotificationCenter()
        let engine = FakeMicInputEngine()
        let capture = MicCapture(engine: engine, notificationCenter: notifications)
        let stream = try capture.start()
        var iterator = stream.makeAsyncIterator()

        engine.failNextStarts(1)
        engine.simulateConfigurationChange(on: notifications)
        for _ in 0..<150 where engine.startCount < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(engine.startCount == 3)
        #expect(engine.isRunning)

        engine.emit([0.3])
        var receivedReplacementInput = false
        for _ in 0..<4 {
            guard let batch = await iterator.next() else { break }
            if batch == [0.3] {
                receivedReplacementInput = true
                break
            }
        }
        #expect(receivedReplacementInput)
        capture.stop()
    }

    @Test("keeps the recording clock moving while the input reconnects")
    func emitsTimingSilenceDuringRecovery() async throws {
        let notifications = NotificationCenter()
        let engine = FakeMicInputEngine()
        let capture = MicCapture(engine: engine, notificationCenter: notifications)
        let stream = try capture.start()
        let collector = BatchCollector()
        let collectionTask = Task {
            for await batch in stream {
                await collector.append(batch)
            }
        }

        engine.failNextStarts(10)
        engine.simulateConfigurationChange(on: notifications)
        for _ in 0..<100 {
            if await collector.count > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let firstBatch = await collector.first
        #expect(firstBatch?.count == 1_024)
        #expect(firstBatch?.allSatisfy { $0 == 0 } == true)

        capture.stop()
        await collectionTask.value
    }
}

private actor BatchCollector {
    private var batches: [[Float]] = []

    var count: Int { batches.count }
    var first: [Float]? { batches.first }

    func append(_ batch: [Float]) {
        batches.append(batch)
    }
}

private final class FakeMicInputEngine: MicInputEngine, @unchecked Sendable {
    let configurationChangeObject: AnyObject = NSObject()

    private let lock = NSLock()
    private var running = false
    private var starts = 0
    private var failuresRemaining = 0
    private var sampleHandler: (@Sendable ([Float]) -> Void)?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    func start(
        deviceUID: String?, onSamples: @escaping @Sendable ([Float]) -> Void
    ) throws {
        lock.lock()
        starts += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            running = false
            lock.unlock()
            throw FakeError.startFailed
        }
        running = true
        sampleHandler = onSamples
        lock.unlock()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    func emit(_ samples: [Float]) {
        lock.lock()
        let handler = sampleHandler
        lock.unlock()
        handler?(samples)
    }

    func failNextStarts(_ count: Int) {
        lock.lock()
        failuresRemaining = count
        lock.unlock()
    }

    func simulateConfigurationChange(on notifications: NotificationCenter) {
        stop()
        notifications.post(
            name: .AVAudioEngineConfigurationChange,
            object: configurationChangeObject)
    }

    private enum FakeError: Error {
        case startFailed
    }
}
