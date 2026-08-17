import Foundation
import Testing

@testable import SimbiKit

@Suite("LogSink")
struct LogSinkTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "log-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("writes a timestamped, leveled, categorized line")
    func writesFormattedLine() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "Simbi.log")

        let sink = LogSink(fileURL: url)
        let date = Date(timeIntervalSince1970: 1_755_400_000)
        sink.write(level: .error, category: "recording", message: "saveRecording failed", date: date)

        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        #expect(lines.count == 1)
        let line = String(lines[0])
        #expect(line.hasSuffix("ERROR [recording] saveRecording failed"))
        // Leading field is an ISO 8601 timestamp with fractional seconds.
        let stamp = String(line.split(separator: " ")[0])
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = try #require(parser.date(from: stamp))
        #expect(abs(parsed.timeIntervalSince(date)) < 1)
    }

    @Test("appends across sink instances, like an app relaunch")
    func appendsAcrossInstances() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "Simbi.log")

        LogSink(fileURL: url).write(level: .info, category: "app", message: "first launch")
        LogSink(fileURL: url).write(level: .info, category: "app", message: "second launch")

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("first launch"))
        #expect(contents.contains("second launch"))
    }

    @Test("creates intermediate directories for the log file")
    func createsIntermediateDirectories() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "nested/deeper/Simbi.log")

        LogSink(fileURL: url).write(level: .warning, category: "files", message: "hello")

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("WARN [files] hello"))
    }

    @Test("rotates to a single .1 generation when over the size cap")
    func rotatesWhenOverCap() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "Simbi.log")
        let rotated = dir.appending(path: "Simbi.log.1")

        // ~65-byte lines against a 400-byte cap: exactly one rotation happens,
        // so every line survives across the two generations.
        let sink = LogSink(fileURL: url, maxBytes: 400)
        for n in 1...10 {
            sink.write(level: .info, category: "app", message: "line \(n) padded to some length")
        }

        #expect(FileManager.default.fileExists(atPath: rotated.path))
        let current = try String(contentsOf: url, encoding: .utf8)
        let old = try String(contentsOf: rotated, encoding: .utf8)
        // Every line lands in exactly one of the two generations, in order.
        let all = (old + current).split(separator: "\n")
        #expect(all.count == 10)
        #expect(all.last?.contains("line 10") == true)
        // The live file was reset by rotation, so it holds a strict suffix.
        let currentSize =
            (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        #expect(currentSize < 400)
    }

    @Test("second rotation replaces the previous .1 generation")
    func secondRotationReplacesOldGeneration() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "Simbi.log")
        let rotated = dir.appending(path: "Simbi.log.1")

        let sink = LogSink(fileURL: url, maxBytes: 120)
        for n in 1...30 {
            sink.write(level: .info, category: "app", message: "message number \(n)")
        }

        // Multiple rotations happened: the earliest lines are gone, the .1
        // generation was replaced (never .2, .3, ...), and the newest line is live.
        let old = try String(contentsOf: rotated, encoding: .utf8)
        #expect(!old.contains("message number 1\n"))
        let current = try String(contentsOf: url, encoding: .utf8)
        #expect(current.contains("message number 30"))
        let generations = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("Simbi.log") }
        #expect(generations.sorted() == ["Simbi.log", "Simbi.log.1"])
    }
}

@Suite("Log categories")
struct LogCategoryTests {
    @Test("category loggers route through the shared sink with their names")
    func categoriesRouteToSharedSink() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "log-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "Simbi.log")

        let previous = Log.replaceSinkForTesting(LogSink(fileURL: url))
        defer { _ = Log.replaceSinkForTesting(previous) }

        Log.recording.error("cut failed")
        Log.codex.warning("thread naming failed")

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("ERROR [recording] cut failed"))
        #expect(contents.contains("WARN [codex] thread naming failed"))
    }

    @Test("default log file lives in ~/Library/Logs/Simbi")
    func defaultLocation() {
        #expect(
            LogSink.defaultFileURL.path.hasSuffix("Library/Logs/Simbi/Simbi.log"))
    }
}
