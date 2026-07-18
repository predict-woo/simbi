import Foundation

/// The per-note transcript-fixer thread (SPEC.md §5.2): a Codex worker
/// thread with a workspace-write sandbox scoped to the note folder that
/// fixes ASR errors in newly appended cues and unifies speaker names.
///
/// Ping policy: ping when ≥ 1 new cue has been appended since the last pass
/// AND the thread has no active turn; pings are coalesced. A final ping
/// fires at recording stop, after which the thread is archived.
public actor TranscriptFixer {
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
        working directory is a live WebVTT transcript of an ongoing recording; \
        context/*.md (if present) are markdown versions of the user's reference files.

        On each of my pings, review the cues I name (plus earlier ones if needed for \
        consistency) and fix ASR errors in their text: spelling of names and jargon \
        (use note.md and context files as ground truth), punctuation, and obvious \
        mis-hearings. Rules you must never break:
        - Every edit must leave the file as valid WebVTT — the app renders it live.
        - Never renumber cues, never change cue timestamps, never delete cues or NOTE blocks.
        - Speaker `<v Name>` tags may be renamed ONLY when the transcript makes the \
        identity unambiguous (e.g. a speaker introduces themselves); then rename that \
        speaker consistently across the whole file.
        - `NOTE session` blocks mark stop/resume boundaries. Speaker slot numbering may \
        reshuffle across them ("Speaker 1" in session 2 may be a different person than \
        in session 1) — unify names across sessions only when identity is clear from \
        the content.
        - If the file fails to parse as WebVTT, repair it minimally first.

        Reply with a one-line summary of what you changed (or "no changes").
        """

    /// Creates the fixer thread on first recording start, or unarchives +
    /// resumes the note's existing thread (archive → unarchive → resume).
    private var bound = false

    public func recordingStarted() async throws {
        stopping = false
        if !bound {
            bound = true
            await client.addNotificationHandler { [weak self] method, paramsData in
                guard method == "turn/completed" else { return }
                let params =
                    (try? JSONSerialization.jsonObject(with: paramsData)) as? [String: Any]
                let threadId = params?["threadId"] as? String
                Task { await self?.turnCompleted(threadId: threadId) }
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
                "cwd": noteFolderURL.path,
                "approvalPolicy": "never",
                "sandbox": "workspace-write"
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
        try await startTurn(text: Self.instructions)
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

    private func turnCompleted(threadId: String?) async {
        guard threadId == self.threadId else { return }
        turnActive = false
        if newestCue > lastPingedCue {
            await pingIfIdle()  // coalesced pass over everything new
        } else if stopping {
            await archiveIfDone()
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
        turnActive = true
        do {
            let input: [[String: any Sendable]] = [
                ["type": "text", "text": text, "text_elements": [String]()]
            ]
            // Workspace-write scoped to the note folder (§5.1).
            let sandboxPolicy: [String: any Sendable] = [
                "type": "workspaceWrite",
                "writableRoots": [noteFolderURL.path],
                "networkAccess": false,
                "excludeTmpdirEnvVar": false,
                "excludeSlashTmp": false
            ]
            var params: [String: any Sendable] = [
                "threadId": threadId,
                "input": input,
                "approvalPolicy": "never",
                "sandboxPolicy": sandboxPolicy
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
    }
}
