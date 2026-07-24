import Foundation

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

/// Coarse fixer activity for the UI (SPEC.md §6 fixer button/popover):
/// one event per pass milestone, no streaming detail.
public enum FixerEvent: Equatable, Sendable {
    /// A pass began ("Reviewing cues 20–36").
    case passStarted(summary: String)
    /// The fixer's own one-line progress/summary message.
    case message(String)
    /// A pass ended; `merged` cue edits landed in the live transcript.
    case passCompleted(merged: Int, failed: Bool)
    /// The thread was archived (recording stopped, all passes drained).
    case archived
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
/// fires at recording stop, after which the thread is archived.
public actor TranscriptFixer {
    /// The fixer's working directory: holds its refreshed working copy of
    /// transcript.vtt, and nothing else.
    public static func worktreeURL(noteFolder: URL) -> URL {
        noteFolder.appending(path: ".simbi/fixer-worktree", directoryHint: .isDirectory)
    }

    /// Bumped whenever `instructions` (or the thread's cwd contract)
    /// changes incompatibly. A note's saved thread carries the
    /// instructions it was created with, so threads from an older version
    /// are retired and recreated instead of resumed. History: 1 =
    /// snapshot-and-replay worktree, 2 = per-cue speaker-attribution fixes.
    public static let instructionsVersion = 2

    private let noteFolderURL: URL
    private let client: AppServerClient
    /// Model override for fixer turns (SPEC.md §5.5); nil = thread default.
    private let model: String?
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
    /// UI activity feed (fixer button/popover); nil = nobody watching.
    private var eventSink: (@Sendable (FixerEvent) -> Void)?

    public init(
        noteFolderURL: URL, client: AppServerClient, savedThreadId: String?,
        model: String? = nil
    ) {
        self.noteFolderURL = noteFolderURL
        self.client = client
        self.savedThreadId = savedThreadId
        self.threadId = savedThreadId
        self.model = model
    }

    private static let instructions = """
        You are the transcript fixer for this note. The file transcript.vtt in your \
        working directory is YOUR WORKING COPY of the note's live WebVTT transcript — \
        it is refreshed from the live file before every ping, and after each of your \
        turns I diff your copy against what you were given and merge the changed cue \
        payloads into the live transcript myself. Never write outside your working \
        directory. The note's own files are read-only ground truth for names and \
        jargon: ../../note.md, and ../../context/*.md if present.

        On each of my pings, review the cues I name (plus earlier ones if needed for \
        consistency) and fix ASR errors in their text: spelling of names and jargon, \
        punctuation, and obvious mis-hearings. Rules you must never break:
        - Edit ONLY cue text and `<v Name>` speaker tags. The merge takes nothing \
        else: renumbering cues, changing timestamps, or adding/deleting cues or NOTE \
        blocks is discarded, so it is wasted work.
        - Speaker diarization is imperfect: when the conversation makes it pretty \
        certain a cue is attributed to the wrong speaker (e.g. a reply credited to \
        the person who just asked the question, or a sentence obviously continuing \
        the other speaker's thought), fix that cue's `<v>` tag — copy the correct \
        speaker's tag exactly as it appears on their other cues. When in doubt, \
        leave the attribution alone.
        - Renaming a speaker's identity is different from fixing attribution: rename \
        ONLY when the transcript makes the identity unambiguous (e.g. a speaker \
        introduces themselves), then rename that speaker consistently across the \
        whole file.
        - `NOTE session` blocks mark stop/resume boundaries. Speaker slot numbering may \
        reshuffle across them ("Speaker 1" in session 2 may be a different person than \
        in session 1) — unify names across sessions only when identity is clear from \
        the content.
        - Keep your copy valid WebVTT — a copy that fails to parse contributes nothing.

        Reply with a one-line summary of what you changed (or "no changes").
        """

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
                    let turn = params?["turn"] as? [String: Any]
                    let failed = (turn?["status"] as? String) == "failed"
                    Task { await self?.turnCompleted(threadId: threadId, failed: failed) }
                case "item/completed":
                    // The fixer's own one-line progress messages feed the
                    // activity popover; threadId is required so other
                    // threads' (converter/chat) messages never leak in.
                    guard let item = params?["item"] as? [String: Any],
                        (item["type"] as? String) == "agentMessage",
                        let text = item["text"] as? String, threadId != nil
                    else { return }
                    Task { await self?.agentMessaged(threadId: threadId, text: text) }
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
        try await startTurn(text: Self.instructions, summary: "Reading the note and transcript")
    }

    /// Called when a cue lands in transcript.vtt.
    public func cueAppended(index: Int) async {
        newestCue = max(newestCue, index)
        await pingIfIdle()
    }

    /// Final ping at stop; archives once everything is fixed (§5.2).
    public func recordingStopped() async {
        stopping = true
        await pingIfIdle()
        if !turnActive {
            await archiveIfDone()
        }
    }

    private func turnCompleted(threadId: String?, failed: Bool = false) async {
        guard threadId == self.threadId else { return }
        turnActive = false
        // Merge this pass's edits into the live file BEFORE the next pass
        // snapshots it — the next working copy must include them.
        let merged = await host?.fixerDidCompletePass() ?? 0
        eventSink?(.passCompleted(merged: merged, failed: failed))
        if newestCue > lastPingedCue {
            await pingIfIdle()  // coalesced pass over everything new
        } else if stopping {
            await archiveIfDone()
        }
    }

    private func agentMessaged(threadId: String?, text: String) {
        guard threadId == self.threadId else { return }
        // One line, popover-sized.
        let line = text.split(separator: "\n", maxSplits: 1)[0].prefix(200)
        eventSink?(.message(String(line)))
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
        let summary = from == to ? "Reviewing cue \(to)" : "Reviewing cues \(from)–\(to)"
        try? await startTurn(text: text, summary: summary)
    }

    private func startTurn(text: String, summary: String) async throws {
        guard let threadId else { return }
        // Refresh the working copy from the live file before the model
        // looks at it.
        await host?.fixerWillStartPass()
        turnActive = true
        eventSink?(.passStarted(summary: summary))
        do {
            let input: [[String: any Sendable]] = [
                ["type": "text", "text": text, "text_elements": [String]()]
            ]
            // Workspace-write scoped to the fixer's worktree — the live
            // note folder (transcript.vtt included) is read-only to it.
            let sandboxPolicy: [String: any Sendable] = [
                "type": "workspaceWrite",
                "writableRoots": [Self.worktreeURL(noteFolder: noteFolderURL).path],
                "networkAccess": false,
                "excludeTmpdirEnvVar": false,
                "excludeSlashTmp": false,
            ]
            var params: [String: any Sendable] = [
                "threadId": threadId,
                "input": input,
                "approvalPolicy": "never",
                "sandboxPolicy": sandboxPolicy,
            ]
            if let model {
                params["model"] = model
            }
            _ = try await client.request(method: "turn/start", params: params)
        } catch {
            turnActive = false
            throw error
        }
    }

    private func archiveIfDone() async {
        guard stopping, let threadId, newestCue <= lastPingedCue else { return }
        _ = try? await client.request(method: "thread/archive", params: ["threadId": threadId])
        eventSink?(.archived)
    }
}
