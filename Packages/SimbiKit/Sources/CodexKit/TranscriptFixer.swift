import Foundation
import SimbiKit

/// Host hooks around each fixer pass. The pipeline implements these: it
/// refreshes the fixer's worktree copy of the transcript before a turn and
/// merges the per-cue diff back into the live file after — so the live
/// transcript.vtt keeps exactly ONE writer and fixer passes can never race
/// (or corrupt) the pipeline's appends.
public protocol TranscriptFixerHost: AnyObject, Sendable {
    func fixerWillStartPass() async
    /// Returns the number of cue edits merged into the live transcript.
    @discardableResult
    func fixerDidCompletePass() async -> Int
}

/// Coarse fixer activity for the UI (the header button's status):
/// one event per pass milestone, no payloads.
public enum FixerEvent: Equatable, Sendable {
    /// A pass began.
    case passStarted
    /// A pass ended; any edits were merged into the live transcript.
    case passCompleted
    /// Recording stopped and every cue has been reviewed.
    case done
}

/// The per-note transcript-fixer thread (SPEC.md §5.2): a Codex worker
/// thread that fixes ASR errors in newly appended cues and unifies speaker
/// names. It works on a snapshot COPY of the transcript in
/// `.simbi/fixer-worktree/` (its cwd and sole writable root) with plain
/// apply_patch edits; the host diffs and merges each pass into the live
/// file (see `TranscriptFixerHost`).
///
/// Ping policy: ping when ≥ 1 new cue has been appended since the last pass
/// AND the thread has no active turn; pings are coalesced. A final ping
/// fires at recording stop.
public actor TranscriptFixer {
    /// The fixer's working directory: holds its refreshed working copy of
    /// transcript.vtt, and nothing else.
    public static func worktreeURL(noteFolder: URL) -> URL {
        noteFolder.appending(path: ".simbi/fixer-worktree", directoryHint: .isDirectory)
    }

    /// Bumped whenever the thread's *contract* (worktree cwd, merge
    /// behavior, ping protocol) changes incompatibly. A note's saved
    /// thread carries the instructions it was created with, so threads
    /// from an older version are retired and recreated instead of
    /// resumed; the instruction *text* (user-editable FIXER.md) is
    /// tracked separately via `instructionsFingerprint`. History: 1 =
    /// snapshot-and-replay worktree, 2 = per-cue speaker-attribution fixes.
    public static let instructionsVersion = 2

    private let noteFolderURL: URL
    private let client: AppServerClient
    /// Model override for fixer turns (SPEC.md §5.5); nil = thread default.
    private let model: String?
    /// Reasoning-effort override; nil = the model's own default.
    private let effort: String?
    /// The thread's opening instructions — FIXER.md's resolved text,
    /// injected by the caller; defaults to the built-in prompt.
    private let instructions: String
    /// Persisted by the caller in .simbi/state.json across app restarts.
    public private(set) var threadId: String?
    private let savedThreadId: String?

    private var turnActive = false
    private var lastPingedCue = 0
    private var newestCue = 0
    private var stopping = false
    /// Weak: the pipeline owns the fixer; the back-reference must not keep
    /// either alive.
    private weak var host: (any TranscriptFixerHost)?
    /// Coarse status events for the header button; nil = nobody watching.
    private var eventSink: (@Sendable (FixerEvent) -> Void)?

    public init(
        noteFolderURL: URL, client: AppServerClient, savedThreadId: String?,
        model: String? = nil, effort: String? = nil,
        instructions: String = AgentInstructions.fixer.defaultContents
    ) {
        self.noteFolderURL = noteFolderURL
        self.client = client
        self.savedThreadId = savedThreadId
        self.threadId = savedThreadId
        self.model = model
        self.effort = effort
        self.instructions = instructions
    }

    /// Persisted next to the thread id so a FIXER.md edit retires the
    /// saved thread (see `NoteRecordingState.fixerInstructionsHash`).
    public var instructionsFingerprint: String {
        AgentInstructions.fingerprint(instructions)
    }

    /// The pipeline registers itself as host before recording starts.
    public func setHost(_ host: any TranscriptFixerHost) {
        self.host = host
    }

    /// The UI registers a coarse activity feed before recording starts.
    public func setEventSink(_ sink: @escaping @Sendable (FixerEvent) -> Void) {
        self.eventSink = sink
    }

    /// Creates the fixer thread on first recording start, or unarchives +
    /// resumes the note's existing thread (archive → unarchive → resume).
    private var bound = false

    public func recordingStarted() async throws {
        stopping = false
        // The thread's cwd; must exist before thread/start.
        try? FileManager.default.createDirectory(
            at: Self.worktreeURL(noteFolder: noteFolderURL), withIntermediateDirectories: true)
        if !bound {
            bound = true
            await client.addNotificationHandler { [weak self] method, paramsData in
                let params =
                    (try? JSONSerialization.jsonObject(with: paramsData)) as? [String: Any]
                let threadId = params?["threadId"] as? String
                switch method {
                case "turn/completed":
                    Task { await self?.turnCompleted(threadId: threadId) }
                default:
                    break
                }
            }
        }
        if let threadId {
            do {
                _ = try await client.request(
                    method: "thread/resume", params: ["threadId": threadId])
            } catch {
                _ = try? await client.request(
                    method: "thread/unarchive", params: ["threadId": threadId])
                _ = try await client.request(
                    method: "thread/resume", params: ["threadId": threadId])
            }
            return
        }

        let resultData = try await client.request(
            method: "thread/start",
            params: [
                "cwd": Self.worktreeURL(noteFolder: noteFolderURL).path,
                "approvalPolicy": "never",
                "sandbox": "workspace-write",
            ])
        let result = (try? JSONSerialization.jsonObject(with: resultData)) as? [String: Any]
        guard let thread = result?["thread"] as? [String: Any],
            let id = thread["id"] as? String
        else { throw AppServerClient.ClientError.malformedResponse }
        threadId = id
        // Naming forces rollout persistence (M1 spike gotcha #2).
        _ = try await client.request(
            method: "thread/name/set",
            params: ["threadId": id, "name": "[simbi] fixer: \(noteFolderURL.lastPathComponent)"])
        try await startTurn(text: instructions)
    }

    /// Called when a cue lands in transcript.vtt.
    public func cueAppended(index: Int) async {
        newestCue = max(newestCue, index)
        await pingIfIdle()
    }

    /// Final ping at stop; emits `.done` once everything is fixed.
    public func recordingStopped() async {
        stopping = true
        await pingIfIdle()
        if !turnActive {
            doneIfDrained()
        }
    }

    private func turnCompleted(threadId: String?) async {
        guard threadId == self.threadId else { return }
        turnActive = false
        // Merge this pass's edits into the live file BEFORE the next pass
        // snapshots it — the next working copy must include them.
        await host?.fixerDidCompletePass()
        eventSink?(.passCompleted)
        if newestCue > lastPingedCue {
            await pingIfIdle()  // coalesced pass over everything new
        } else if stopping {
            doneIfDrained()
        }
    }

    private func pingIfIdle() async {
        guard !turnActive, threadId != nil, newestCue > lastPingedCue else { return }
        let from = lastPingedCue + 1
        let to = newestCue
        lastPingedCue = to
        let text =
            from == to
            ? "Cue \(to) is new — review and fix."
            : "Cues \(from)..\(to) are new — review and fix."
        try? await startTurn(text: text)
    }

    private func startTurn(text: String) async throws {
        guard let threadId else { return }
        // Refresh the working copy from the live file before the model
        // looks at it.
        await host?.fixerWillStartPass()
        turnActive = true
        eventSink?(.passStarted)
        do {
            // Workspace-write scoped to the fixer's worktree — the live
            // note folder (transcript.vtt included) is read-only to it.
            var params: [String: any Sendable] = [
                "threadId": threadId,
                "input": CodexTurn.textInput(text),
                "approvalPolicy": "never",
                "sandboxPolicy": CodexTurn.workspaceWritePolicy(
                    writableRoot: Self.worktreeURL(noteFolder: noteFolderURL)),
            ]
            TurnOverrides.apply(model: model, effort: effort, to: &params)
            _ = try await client.request(method: "turn/start", params: params)
        } catch {
            turnActive = false
            throw error
        }
    }

    private func doneIfDrained() {
        guard stopping, threadId != nil, newestCue <= lastPingedCue else { return }
        eventSink?(.done)
    }
}
