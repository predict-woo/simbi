// appserver-spike — M1 spike (b) for Simbi.
//
// Proves the `codex app-server` JSON-RPC round-trip end to end:
//   spawn → initialize/initialized → thread/start → thread/name/set →
//   turn/start → stream notifications to turn/completed →
//   thread/archive → thread/resume → clean exit.
//
// Throwaway code. Plain synchronous line-reader loop, no actor machinery.

import Darwin
import Foundation

struct SpikeError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

@MainActor
final class Spike {
    // MARK: configuration

    let codexBinaryPath = "/Applications/ChatGPT.app/Contents/Resources/codex"
    let codexHome = NSHomeDirectory() + "/.codex"  // MANDATORY — see references/codex-open/README.md gotcha #1
    let overallTimeoutSeconds: Double = 300
    let prompt = "Reply with exactly the word pong and do nothing else."

    // MARK: state

    let process = Process()
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    var stdoutBuffer = Data()
    var nextRequestId = 0
    var stderrLogPath = ""

    var agentMessageDeltas = ""
    var finalAgentMessage = ""
    var completedTurn: [String: Any]?

    var summary: [(step: String, pass: Bool, detail: String)] = []

    // MARK: bookkeeping

    func record(_ step: String, _ pass: Bool, _ detail: String = "") {
        summary.append((step, pass, detail))
        print("[\(pass ? "PASS" : "FAIL")] \(step)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    func finish() -> Never {
        if process.isRunning { process.terminate() }
        print("\n===== SUMMARY =====")
        for s in summary {
            print("\(s.pass ? "PASS" : "FAIL")  \(s.step)\(s.detail.isEmpty ? "" : " — \(s.detail)")")
        }
        let allPass = !summary.isEmpty && summary.allSatisfy { $0.pass }
        print("OVERALL: \(allPass ? "PASS" : "FAIL")")
        exit(allPass ? 0 : 1)
    }

    func truncate(_ s: String, _ max: Int = 800) -> String {
        s.count <= max ? s : String(s.prefix(max)) + " …[\(s.count - max) more chars]"
    }

    // MARK: wire I/O

    func sendRaw(_ obj: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        print("→ \(String(data: data, encoding: .utf8) ?? "<non-utf8>")")
        var line = data
        line.append(0x0A)
        try stdinPipe.fileHandleForWriting.write(contentsOf: line)
    }

    func sendRequest(_ method: String, _ params: [String: Any]?) throws -> Int {
        let id = nextRequestId
        nextRequestId += 1
        var obj: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { obj["params"] = params }
        try sendRaw(obj)
        return id
    }

    func sendNotification(_ method: String, _ params: [String: Any]? = nil) throws {
        var obj: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { obj["params"] = params }
        try sendRaw(obj)
    }

    /// Blocking read of the next newline-delimited JSON object from the server.
    func readMessage() throws -> [String: Any] {
        while true {
            if let nl = stdoutBuffer.firstIndex(of: 0x0A) {
                let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<nl)
                stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
                guard let line = String(data: lineData, encoding: .utf8),
                    !line.trimmingCharacters(in: .whitespaces).isEmpty
                else { continue }
                print("← \(truncate(line))")
                guard
                    let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
                else { continue }
                return obj
            }
            let chunk = stdoutPipe.fileHandleForReading.availableData
            if chunk.isEmpty {
                throw SpikeError("app-server closed stdout (EOF). See stderr log: \(stderrLogPath)")
            }
            stdoutBuffer.append(chunk)
        }
    }

    // MARK: message dispatch

    func handleNotification(_ obj: [String: Any]) {
        guard let method = obj["method"] as? String else { return }
        let params = obj["params"] as? [String: Any] ?? [:]
        switch method {
        case "item/agentMessage/delta":
            agentMessageDeltas += params["delta"] as? String ?? ""
        case "item/completed":
            if let item = params["item"] as? [String: Any],
                item["type"] as? String == "agentMessage"
            {
                finalAgentMessage = item["text"] as? String ?? ""
            }
        case "turn/completed":
            completedTurn = params["turn"] as? [String: Any]
        default:
            break
        }
    }

    /// Reads messages, dispatching notifications and refusing server->client
    /// requests, until the response with `id` arrives. Throws on error response.
    func waitForResponse(_ id: Int) throws -> [String: Any] {
        while true {
            let obj = try readMessage()
            if let method = obj["method"] as? String {
                if let requestId = obj["id"] {
                    // Server -> client request (e.g. an approval). With
                    // approvalPolicy "never" none should arrive; refuse it.
                    print("!! unexpected server request \(method); refusing")
                    try sendRaw([
                        "jsonrpc": "2.0", "id": requestId,
                        "error": ["code": -32601, "message": "spike client refuses \(method)"],
                    ])
                } else {
                    handleNotification(obj)
                }
                continue
            }
            guard let responseId = obj["id"] as? Int, responseId == id else { continue }
            if let error = obj["error"] as? [String: Any] {
                throw SpikeError("error response to request \(id): \(error)")
            }
            return obj["result"] as? [String: Any] ?? [:]
        }
    }

    /// Streams notifications until turn/completed arrives.
    func waitForTurnCompleted() throws -> [String: Any] {
        while completedTurn == nil {
            let obj = try readMessage()
            if let method = obj["method"] as? String {
                if let requestId = obj["id"] {
                    print("!! unexpected server request \(method); refusing")
                    try sendRaw([
                        "jsonrpc": "2.0", "id": requestId,
                        "error": ["code": -32601, "message": "spike client refuses \(method)"],
                    ])
                } else {
                    handleNotification(obj)
                }
            }
        }
        return completedTurn!
    }

    // MARK: the spike

    func run() {
        do { try runSteps() } catch {
            record("aborted", false, "\(error)")
        }
        finish()
    }

    func runSteps() throws {
        let fm = FileManager.default

        // ---- Step 1: spawn `codex app-server` with CODEX_HOME=~/.codex ----
        guard fm.isExecutableFile(atPath: codexBinaryPath) else {
            throw SpikeError("codex binary not found at \(codexBinaryPath)")
        }
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("simbi-appserver-spike-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        stderrLogPath = workDir.appendingPathComponent("app-server-stderr.log").path
        fm.createFile(atPath: stderrLogPath, contents: nil)

        process.executableURL = URL(fileURLWithPath: codexBinaryPath)
        process.arguments = ["app-server"]
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = codexHome
        process.environment = env
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle(forWritingAtPath: stderrLogPath)
        try process.run()

        // Watchdog: kill the child if the whole spike overruns, so blocking
        // reads turn into EOF instead of hanging forever.
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + overallTimeoutSeconds) {
            kill(pid, SIGKILL)
        }
        record(
            "1 spawn app-server", process.isRunning,
            "pid \(pid), CODEX_HOME=\(codexHome), cwd=\(workDir.path), stderr=\(stderrLogPath)")

        // ---- Step 2: initialize -> initialized handshake ----
        let initId = try sendRequest(
            "initialize",
            [
                "clientInfo": ["name": "simbi-spike", "title": "Simbi M1 spike", "version": "0.1.0"]
            ])
        let initResult = try waitForResponse(initId)
        try sendNotification("initialized")
        record(
            "2 initialize handshake", true,
            "server: \(truncate("\(initResult)", 200))")

        // ---- Auth preflight (informational but required for the turn) ----
        let authId = try sendRequest("getAuthStatus", ["includeToken": false, "refreshToken": false])
        let auth = try waitForResponse(authId)
        let authMethod = auth["authMethod"] as? String
        if authMethod == nil {
            record(
                "2b auth preflight", false,
                "no auth in \(codexHome)/auth.json — log in via the ChatGPT app or `codex login`, then re-run")
            throw SpikeError("cannot run a model turn without auth")
        }
        record("2b auth preflight", true, "authMethod=\(authMethod!)")

        // ---- Step 3: thread/start in a fresh temp directory ----
        let startId = try sendRequest(
            "thread/start",
            [
                "cwd": workDir.path,
                "approvalPolicy": "never",
                "sandbox": "read-only",
            ])
        let startResult = try waitForResponse(startId)
        guard let thread = startResult["thread"] as? [String: Any],
            let threadId = thread["id"] as? String, !threadId.isEmpty
        else { throw SpikeError("thread/start returned no thread id: \(startResult)") }
        record("3 thread/start", true, "threadId=\(threadId)")

        // ---- Step 4: thread/name/set (forces rollout persistence, gotcha #2) ----
        let stamp = ISO8601DateFormatter().string(from: Date())
        let threadName = "[simbi] m1 spike \(stamp)"
        let nameId = try sendRequest("thread/name/set", ["threadId": threadId, "name": threadName])
        _ = try waitForResponse(nameId)
        record("4 thread/name/set", true, "name=\(threadName)")

        // ---- Step 5: turn/start with a trivial prompt, most restrictive options ----
        let turnId = try sendRequest(
            "turn/start",
            [
                "threadId": threadId,
                "input": [["type": "text", "text": prompt, "text_elements": [] as [Any]]],
                "approvalPolicy": "never",
                "sandboxPolicy": ["type": "readOnly", "networkAccess": false],
            ])
        let turnResult = try waitForResponse(turnId)
        guard let turn = turnResult["turn"] as? [String: Any], let turnUuid = turn["id"] as? String
        else { throw SpikeError("turn/start returned no turn: \(turnResult)") }
        record("5 turn/start", true, "turnId=\(turnUuid)")

        // ---- Step 6: stream notifications until turn/completed ----
        let completed = try waitForTurnCompleted()
        let status = completed["status"] as? String ?? "?"
        let reply = finalAgentMessage.isEmpty ? agentMessageDeltas : finalAgentMessage
        let gotPong = reply.lowercased().contains("pong")
        record(
            "6 stream to turn/completed", status == "completed" && gotPong,
            "status=\(status), agent reply=\"\(truncate(reply, 120))\"")

        // ---- Step 7: thread/archive ----
        let archiveId = try sendRequest("thread/archive", ["threadId": threadId])
        _ = try waitForResponse(archiveId)
        record("7 thread/archive", true)

        // ---- Step 8: thread/resume the same thread id ----
        var resumeDetail = ""
        var resumedThread: [String: Any]?
        do {
            let resumeId = try sendRequest("thread/resume", ["threadId": threadId])
            let resumeResult = try waitForResponse(resumeId)
            resumedThread = resumeResult["thread"] as? [String: Any]
        } catch {
            // Some server versions may refuse to resume an archived thread
            // directly; document by trying unarchive first.
            resumeDetail = "direct resume failed (\(error)); retrying after thread/unarchive — "
            let unarchiveId = try sendRequest("thread/unarchive", ["threadId": threadId])
            _ = try waitForResponse(unarchiveId)
            let resumeId = try sendRequest("thread/resume", ["threadId": threadId])
            let resumeResult = try waitForResponse(resumeId)
            resumedThread = resumeResult["thread"] as? [String: Any]
        }
        let resumedId = resumedThread?["id"] as? String
        let resumedTurns = (resumedThread?["turns"] as? [[String: Any]])?.count ?? 0
        record(
            "8 thread/resume after archive", resumedId == threadId,
            resumeDetail
                + "resumed id=\(resumedId ?? "nil"), turns=\(resumedTurns), name=\(resumedThread?["name"] as? String ?? "nil")"
        )

        // ---- Step 9: clean exit ----
        try stdinPipe.fileHandleForWriting.close()
        for _ in 0..<50 {
            if !process.isRunning { break }
            usleep(100_000)
        }
        if process.isRunning { process.terminate() }
        record("9 clean exit", true, process.isRunning ? "had to terminate" : "server exited on stdin close")
    }
}

Spike().run()
