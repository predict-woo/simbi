import Foundation

/// `.simbi/state.json` inside a note folder: cue numbering, session
/// bookkeeping and the timeline base (SPEC.md §2.2, guide §3/§10).
///
/// An `activeSession` still present when the note is opened means the app
/// died mid-recording — the crash-recovery path (§10.3) closes it.
public struct NoteRecordingState: Codable, Equatable, Sendable {
    public struct ActiveSession: Codable, Equatable, Sendable {
        /// 1-based session number.
        public var n: Int
        /// Note-timeline base of this session in samples.
        public var baseSamples: Int
        public var wallStart: Date

        public init(n: Int, baseSamples: Int, wallStart: Date) {
            self.n = n
            self.baseSamples = baseSamples
            self.wallStart = wallStart
        }
    }

    /// Next cue index to assign (monotonic across sessions, starts at 1).
    public var nextCueIndex: Int
    /// Number of completed sessions.
    public var sessionCount: Int
    /// Total samples written to audio.webm by all completed sessions.
    public var totalSamples: Int
    public var lastSessionEnd: Date?
    public var activeSession: ActiveSession?

    public init(
        nextCueIndex: Int = 1, sessionCount: Int = 0, totalSamples: Int = 0,
        lastSessionEnd: Date? = nil, activeSession: ActiveSession? = nil
    ) {
        self.nextCueIndex = nextCueIndex
        self.sessionCount = sessionCount
        self.totalSamples = totalSamples
        self.lastSessionEnd = lastSessionEnd
        self.activeSession = activeSession
    }

    // Forward-compatible decoding, same pattern as SimbiSettings.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nextCueIndex = try container.decodeIfPresent(Int.self, forKey: .nextCueIndex) ?? 1
        sessionCount = try container.decodeIfPresent(Int.self, forKey: .sessionCount) ?? 0
        totalSamples = try container.decodeIfPresent(Int.self, forKey: .totalSamples) ?? 0
        lastSessionEnd = try container.decodeIfPresent(Date.self, forKey: .lastSessionEnd)
        activeSession = try container.decodeIfPresent(ActiveSession.self, forKey: .activeSession)
    }

    public static func fileURL(noteFolder: URL) -> URL {
        noteFolder.appending(path: ".simbi/state.json")
    }

    public static func load(noteFolder: URL) throws -> NoteRecordingState {
        let url = fileURL(noteFolder: noteFolder)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return NoteRecordingState()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(NoteRecordingState.self, from: Data(contentsOf: url))
    }

    public func save(noteFolder: URL) throws {
        let url = Self.fileURL(noteFolder: noteFolder)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
