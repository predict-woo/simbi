import Foundation
import os

/// App-wide diagnostic logging. Every message goes to the shared on-disk log
/// (`~/Library/Logs/Simbi/Simbi.log`, rotated at 2 MB with one old generation
/// kept) and is mirrored to the unified logging system for Console.app /
/// `log stream`. Logging never throws and never blocks on failure — a logger
/// that can take the app down defeats its purpose.
///
/// The degraded-mode contract (CLAUDE.md: missing ChatGPT.app or auth keeps
/// recording alive) stays intact; these loggers are how those paths, and every
/// local-I/O failure the app survives, stop being invisible.
public struct Log: Sendable {
    public enum Level: String, Sendable {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    public static let app = Log(category: "app")
    public static let recording = Log(category: "recording")
    public static let codex = Log(category: "codex")
    public static let files = Log(category: "files")
    public static let ui = Log(category: "ui")

    private let category: String
    private let mirror: os.Logger

    private init(category: String) {
        self.category = category
        self.mirror = os.Logger(subsystem: "app.getsimbi.mac", category: category)
    }

    public func debug(_ message: String) { emit(.debug, message) }
    public func info(_ message: String) { emit(.info, message) }
    public func warning(_ message: String) { emit(.warning, message) }
    public func error(_ message: String) { emit(.error, message) }

    private func emit(_ level: Level, _ message: String) {
        Self.sharedSink.withLock { $0 }.write(level: level, category: category, message: message)
        switch level {
        case .debug: mirror.debug("\(message, privacy: .public)")
        case .info: mirror.info("\(message, privacy: .public)")
        case .warning: mirror.warning("\(message, privacy: .public)")
        case .error: mirror.error("\(message, privacy: .public)")
        }
    }

    private static let sharedSink = OSAllocatedUnfairLock(
        initialState: LogSink(fileURL: LogSink.defaultFileURL))

    /// Swaps the process-wide sink and returns the previous one so tests can
    /// capture output in a temporary file and restore the original after.
    public static func replaceSinkForTesting(_ sink: LogSink) -> LogSink {
        sharedSink.withLock { current in
            let previous = current
            current = sink
            return previous
        }
    }
}

/// Serialized append-to-file backend for `Log`. Rotation keeps exactly one
/// old generation: when the live file exceeds `maxBytes` it becomes
/// `<name>.1` (replacing any previous one) and a fresh live file starts.
public final class LogSink: @unchecked Sendable {
    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/Simbi/Simbi.log")
    }

    private let fileURL: URL
    private let rotatedURL: URL
    private let maxBytes: Int
    private let lock = NSLock()
    private var handle: FileHandle?

    private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public init(fileURL: URL, maxBytes: Int = 2_000_000) {
        self.fileURL = fileURL
        self.rotatedURL = fileURL.appendingPathExtension("1")
        self.maxBytes = maxBytes
    }

    deinit {
        try? handle?.close()
    }

    public func write(level: Log.Level, category: String, message: String, date: Date = Date()) {
        let line = "\(date.formatted(Self.timestamp)) \(level.rawValue) [\(category)] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        let data = Data(line.utf8)
        do {
            guard var handle = openedHandle() else { return }
            // Rotate before a write that would exceed the cap, so the newest
            // lines are always in the live file.
            if try handle.offset() + UInt64(data.count) > UInt64(maxBytes) {
                try rotate()
                guard let fresh = openedHandle() else { return }
                handle = fresh
            }
            try handle.write(contentsOf: data)
        } catch {
            // A failing disk is not something the logger can report to itself.
        }
    }

    private func openedHandle() -> FileHandle? {
        if let handle { return handle }
        let fm = FileManager.default
        try? fm.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let opened = try? FileHandle(forWritingTo: fileURL) else { return nil }
        _ = try? opened.seekToEnd()
        handle = opened
        return opened
    }

    private func rotate() throws {
        try handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: rotatedURL)
        try fm.moveItem(at: fileURL, to: rotatedURL)
    }
}
