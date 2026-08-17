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

    /// One file-import conversion job (SPEC.md §5.3), keyed by the file's
    /// name inside `files/`.
    public struct FileConversion: Codable, Equatable, Sendable {
        public enum Status: String, Codable, Sendable {
            case converting
            case done
            case failed
        }

        public var status: Status
        /// The converter Codex thread (archived when the job ends).
        public var threadId: String?

        public init(status: Status, threadId: String? = nil) {
            self.status = status
            self.threadId = threadId
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
    /// The note's transcript-fixer Codex thread (SPEC.md §5.2), reused
    /// across sessions and app restarts.
    public var fixerThreadId: String?
    /// The fixer-instructions version the saved thread was created with
    /// (SPEC.md §5.2). A thread from an older version — including 0, the
    /// pre-worktree era whose instructions wrote the live file — is
    /// retired rather than resumed.
    public var fixerInstructionsVersion: Int
    /// Fingerprint of the exact instruction text the saved fixer thread
    /// was created with (`AgentInstructions.fingerprint`). FIXER.md is
    /// user-editable, so version alone can't tell an outdated thread —
    /// any text change retires the thread the same way a version bump does.
    public var fixerInstructionsHash: String?
    /// File-import conversion jobs by `files/` file name (SPEC.md §5.3).
    public var conversions: [String: FileConversion]

    public init(
        nextCueIndex: Int = 1, sessionCount: Int = 0, totalSamples: Int = 0,
        lastSessionEnd: Date? = nil, activeSession: ActiveSession? = nil,
        fixerThreadId: String? = nil, fixerInstructionsVersion: Int = 0,
        fixerInstructionsHash: String? = nil,
        conversions: [String: FileConversion] = [:]
    ) {
        self.nextCueIndex = nextCueIndex
        self.sessionCount = sessionCount
        self.totalSamples = totalSamples
        self.lastSessionEnd = lastSessionEnd
        self.activeSession = activeSession
        self.fixerThreadId = fixerThreadId
        self.fixerInstructionsVersion = fixerInstructionsVersion
        self.fixerInstructionsHash = fixerInstructionsHash
        self.conversions = conversions
    }

    // Forward-compatible decoding, same pattern as SimbiSettings.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nextCueIndex = try container.decodeIfPresent(Int.self, forKey: .nextCueIndex) ?? 1
        sessionCount = try container.decodeIfPresent(Int.self, forKey: .sessionCount) ?? 0
        totalSamples = try container.decodeIfPresent(Int.self, forKey: .totalSamples) ?? 0
        lastSessionEnd = try container.decodeIfPresent(Date.self, forKey: .lastSessionEnd)
        activeSession = try container.decodeIfPresent(ActiveSession.self, forKey: .activeSession)
        fixerThreadId = try container.decodeIfPresent(String.self, forKey: .fixerThreadId)
        fixerInstructionsVersion =
            try container.decodeIfPresent(Int.self, forKey: .fixerInstructionsVersion) ?? 0
        fixerInstructionsHash =
            try container.decodeIfPresent(String.self, forKey: .fixerInstructionsHash)
        conversions =
            try container.decodeIfPresent([String: FileConversion].self, forKey: .conversions)
            ?? [:]
    }

    public static func fileURL(noteFolder: URL) -> URL {
        NoteLayout.stateDirURL(noteFolder: noteFolder).appending(path: "state.json")
    }

    /// The note's state as stored right now; a missing or corrupt file
    /// reads as a fresh state.
    public static func current(noteFolder: URL) -> NoteRecordingState {
        (try? load(noteFolder: noteFolder)) ?? NoteRecordingState()
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
        try PersistedJSON.encoder().encode(self).write(to: url, options: .atomic)
    }

    // Two writers share state.json: the recording pipeline (which holds its
    // copy in memory for a whole session) and the file-import path (which
    // owns only `conversions`). Both go through this lock so neither
    // clobbers the other's fields.
    private static let ioLock = NSLock()

    /// Locked load → mutate → save, for writers that own only part of the
    /// state (the file-import path's `conversions`, SPEC.md §5.3).
    public static func update(
        noteFolder: URL, _ mutate: (inout NoteRecordingState) -> Void
    )
        throws
    {
        ioLock.lock()
        defer { ioLock.unlock() }
        var state = current(noteFolder: noteFolder)
        mutate(&state)
        try state.save(noteFolder: noteFolder)
    }

    /// Saves the recording pipeline's bookkeeping, adopting whatever
    /// conversion records are on disk — the file-import path may have
    /// written since this copy was loaded.
    public mutating func saveRecording(noteFolder: URL) throws {
        Self.ioLock.lock()
        defer { Self.ioLock.unlock() }
        if let disk = try? Self.load(noteFolder: noteFolder) {
            conversions = disk.conversions
        }
        try save(noteFolder: noteFolder)
    }
}
