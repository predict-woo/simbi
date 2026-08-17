import Foundation
import SimbiKit

/// Ties the websocket server child's lifetime to the app's. The old stdio
/// transport got this for free (the child exited on stdin EOF); `--listen`
/// mode ignores stdin EOF (verified against codex-cli 0.147.0-alpha.6.5),
/// so a killed or crashed Simbi leaves the server running. An orphaned
/// server keeps every loaded thread's rollout open as its writer, and the
/// next app session's `thread/resume` on those threads fails with
/// "already has an active writer". Two nets, neither perfect alone: an
/// `atexit` hook on normal quits SIGTERMs this session's children and
/// sweeps orphans, and `reapOrphans` kills servers whose Simbi is already
/// gone (crashes, SIGKILL) before a new one spawns.
final class AppServerJanitor: @unchecked Sendable {
    static let shared = AppServerJanitor()

    private let lock = NSLock()
    private var pids: [pid_t] = []
    private var binaryPath: String?

    /// Called at client init: remembers the server binary and arms the
    /// exit hook, so a quit kills every running server — this session's
    /// children and older sessions' orphans — even when this session
    /// never spawned one. (The hook runs on normal exits only; a
    /// SIGKILLed Simbi still leaks its child until the next reap.)
    func prepare(binaryPath: String) {
        lock.lock()
        defer { lock.unlock() }
        if self.binaryPath == nil {
            atexit { AppServerJanitor.shared.terminateAll() }
        }
        self.binaryPath = binaryPath
    }

    func register(_ pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        pids.append(pid)
    }

    /// Forget a child that was terminated deliberately — a stale pid could
    /// be reused by an unrelated process before the exit hook fires.
    func unregister(_ pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        pids.removeAll { $0 == pid }
    }

    fileprivate func terminateAll() {
        lock.lock()
        let doomed = pids
        let path = binaryPath
        pids.removeAll()
        lock.unlock()
        for pid in doomed { kill(pid, SIGTERM) }
        // Quit leaves no server running anywhere: sweep older sessions'
        // orphans too, not just this session's children.
        if let path { sweepOrphans(binaryPath: path) }
    }

    /// Kills leftover servers from dead Simbi sessions: processes running
    /// exactly our spawn command whose parent is launchd (a live session's
    /// child has that session as its parent and never matches).
    func reapOrphans(binaryPath: String) {
        lock.lock()
        self.binaryPath = binaryPath
        lock.unlock()
        sweepOrphans(binaryPath: binaryPath)
    }

    private func sweepOrphans(binaryPath: String) {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,args="]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        do {
            try ps.run()
        } catch {
            Log.codex.warning("orphan app-server sweep skipped, ps failed to run: \(error)")
            return
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        guard let listing = String(data: data, encoding: .utf8) else { return }
        for pid in Self.orphanPIDs(inPSListing: listing, binaryPath: binaryPath) {
            kill(pid, SIGTERM)
        }
    }

    /// `ps -axo pid=,ppid=,args=` lines → pids of orphaned servers.
    static func orphanPIDs(inPSListing listing: String, binaryPath: String) -> [pid_t] {
        let signature = "\(binaryPath) app-server --listen ws://127.0.0.1:0"
        var pids: [pid_t] = []
        for line in listing.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3,
                let pid = pid_t(fields[0]), let ppid = pid_t(fields[1]),
                ppid == 1,
                fields[2].trimmingCharacters(in: .whitespaces) == signature
            else { continue }
            pids.append(pid)
        }
        return pids
    }
}

/// Long-lived `codex app-server` JSON-RPC client (SPEC.md §5.1). One child
/// process per app session, JSON-RPC over a loopback websocket
/// (`--listen ws://127.0.0.1:0`); the port also serves viewer terminals
/// (`endpoint()`); responses demuxed by id, notifications fanned out to a
/// handler. Restarts the process on demand if it died (callers re-resume
/// their threads).
///
/// Wire shapes verified in Sources/simbi-appserver-spike/README.md.
public actor AppServerClient {
    public enum ClientError: Error {
        case binaryMissing
        case notAuthenticated
        case serverError(code: Int, message: String)
    }

    private let installation: CodexInstallation
    private var process: Process?
    private var socket: URLSessionWebSocketTask?
    private var boundEndpoint: String?
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var readerTask: Task<Void, Never>?
    private var startupTask: Task<Void, Error>?
    /// Notification fan-out: method + params (raw JSON of the params
    /// object) — Data is Sendable; handlers parse what they need. Handlers
    /// live for the client's lifetime (each guards itself with weak self).
    private var notificationHandlers: [@Sendable (String, Data) -> Void] = []

    public init(installation: CodexInstallation = .standard) {
        self.installation = installation
        AppServerJanitor.shared.prepare(binaryPath: installation.binaryURL.path)
    }

    public func addNotificationHandler(
        _ handler: @escaping @Sendable (String, Data) -> Void
    ) {
        notificationHandlers.append(handler)
    }

    /// The server's loopback websocket endpoint (e.g. "ws://127.0.0.1:51859"),
    /// starting the server if needed. Viewer terminals attach here
    /// (`codex --remote <endpoint> resume <threadId>`).
    public func endpoint() async throws -> String {
        try await ensureRunning()
        guard let boundEndpoint else {
            throw ClientError.serverError(code: -1, message: "no endpoint")
        }
        return boundEndpoint
    }

    /// Extracts the websocket endpoint from the server's
    /// "listening on: ws://127.0.0.1:<port>" startup line.
    nonisolated static func listenEndpoint(fromLine line: String) -> String? {
        guard
            let range = line.range(
                of: #"ws://127\.0\.0\.1:\d+"#, options: .regularExpression),
            line.contains("listening on:")
        else { return nil }
        return String(line[range])
    }

    private func ensureRunning() async throws {
        // Join an in-flight startup FIRST: the socket is connected before
        // the initialize handshake finishes, so the healthy fast path
        // alone would let a concurrent caller fire at an un-initialized
        // server (converter + fixer + settings share one client).
        if let startupTask {
            return try await startupTask.value
        }
        if process?.isRunning == true, socket != nil { return }
        let task = Task { try await self.startServer() }
        startupTask = task
        defer { startupTask = nil }
        try await task.value
    }

    private func startServer() async throws {
        guard installation.isBinaryInstalled else { throw ClientError.binaryMissing }

        // A dead process fails all in-flight requests.
        for (_, continuation) in pending {
            continuation.resume(throwing: ClientError.serverError(code: -1, message: "restarted"))
        }
        pending.removeAll()
        readerTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        boundEndpoint = nil
        if let old = process {
            AppServerJanitor.shared.unregister(old.processIdentifier)
            old.terminate()
        }
        process = nil

        // A previous session's server may still hold rollout writers for
        // this note's threads — resume would fail against a live orphan.
        AppServerJanitor.shared.reapOrphans(binaryPath: installation.binaryURL.path)

        let child = Process()
        child.executableURL = installation.binaryURL
        // Loopback websocket instead of stdio so viewer TUIs can attach as
        // additional clients of the same server (live-view spec §3).
        child.arguments = ["app-server", "--listen", "ws://127.0.0.1:0"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = installation.codexHomeURL.path  // mandatory
        child.environment = environment
        child.standardInput = Pipe()  // unused; don't inherit ours
        child.standardOutput = FileHandle.nullDevice  // prints nothing
        let stderr = Pipe()
        child.standardError = stderr
        let stderrLog = FileManager.default.temporaryDirectory
            .appending(path: "simbi-app-server-\(ProcessInfo.processInfo.processIdentifier).log")
        FileManager.default.createFile(atPath: stderrLog.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: stderrLog)
        try child.run()
        process = child
        AppServerJanitor.shared.register(child.processIdentifier)

        // The startup banner ("listening on: ws://127.0.0.1:<port>") goes
        // to STDERR (verified against codex-cli 0.147.0-alpha.6.5; stdout
        // prints nothing). Tee every stderr chunk into the diagnostic log
        // while scanning lines for the bound port.
        let readHandle = stderr.fileHandleForReading
        let (lines, continuation) = AsyncStream.makeStream(of: String.self)
        Thread.detachNewThread {
            var buffer = Data()
            while true {
                let chunk = readHandle.availableData
                if chunk.isEmpty { break }  // EOF
                logHandle?.write(chunk)
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    if let line = String(
                        data: Data(buffer.prefix(upTo: newline)), encoding: .utf8)
                    {
                        continuation.yield(line)
                    }
                    buffer.removeSubrange(...newline)
                }
            }
            continuation.finish()
        }
        let scan = Task {
            var found: String?
            for await line in lines {
                if found == nil, let endpoint = Self.listenEndpoint(fromLine: line) {
                    found = endpoint
                    break
                }
            }
            return found
        }
        // 10 s cap (live-view spec §3): same degraded state as a failed
        // stdio spawn today.
        let timeout = Task {
            try? await Task.sleep(for: .seconds(10))
            scan.cancel()
        }
        guard let endpoint = await scan.value else {
            timeout.cancel()
            AppServerJanitor.shared.unregister(child.processIdentifier)
            child.terminate()
            process = nil
            throw ClientError.serverError(code: -1, message: "server printed no endpoint")
        }
        timeout.cancel()
        // No further stream consumer: dropping scan's iterator terminated
        // the stream, and the reader thread keeps teeing stderr to the log.

        let socketTask = URLSession.shared.webSocketTask(
            with: URLRequest(url: URL(string: endpoint)!))
        // The server sends multi-MB frames (world state on resume);
        // URLSession's 1 MB default kills the connection.
        socketTask.maximumMessageSize = 64 * 1024 * 1024
        socketTask.resume()
        socket = socketTask
        boundEndpoint = endpoint
        readerTask = Task { [weak self] in
            await self?.readLoop(socketTask)
        }

        _ = try await send(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "simbi", "title": "Simbi",
                    "version": Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                ]
            ])
        try await write(["jsonrpc": "2.0", "method": "initialized"])

        let auth = try await send(
            method: "getAuthStatus", params: ["includeToken": false, "refreshToken": false])
        guard
            (try? JSONSerialization.jsonObject(with: auth) as? [String: Any])?["authMethod"]
                is String
        else { throw ClientError.notAuthenticated }
    }

    private func readLoop(_ socketTask: URLSessionWebSocketTask) async {
        while socket === socketTask {
            do {
                switch try await socketTask.receive() {
                case .string(let text): receive(line: Data(text.utf8))
                case .data(let data): receive(line: data)
                @unknown default: break
                }
            } catch {
                if socket === socketTask { disconnected() }
                return
            }
        }
    }

    private func disconnected() {
        socket = nil
        for (_, continuation) in pending {
            continuation.resume(
                throwing: ClientError.serverError(code: -1, message: "disconnected"))
        }
        pending.removeAll()
    }

    private func receive(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return
        }
        switch JSONRPCMessage.classify(object) {
        case .response(let id, let body):
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = body["error"] as? [String: Any] {
                continuation.resume(
                    throwing: ClientError.serverError(
                        code: error["code"] as? Int ?? 0,
                        message: error["message"] as? String ?? "unknown"))
            } else {
                let result = body["result"] ?? [String: Any]()
                continuation.resume(
                    returning: (try? JSONSerialization.data(
                        withJSONObject: result, options: [.fragmentsAllowed])) ?? Data("{}".utf8))
            }
        case .serverRequest(let id, let method, _):
            // Approvals: the server is blocked on our answer. Every thread
            // runs approvalPolicy "never", so no server request is ever
            // expected — answer with an explicit error, never silence.
            respondMethodNotFound(id: id, method: method)
        case .notification(let method, let params):
            let paramsData =
                (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)
            for handler in notificationHandlers {
                handler(method, paramsData)
            }
        case .invalid:
            break
        }
    }

    private func respondMethodNotFound(id: RPCID, method: String) {
        Task {
            do {
                try await self.write([
                    "jsonrpc": "2.0", "id": id.jsonValue,
                    "error": ["code": -32601, "message": "unhandled server request: \(method)"],
                ])
            } catch {
                Log.codex.error(
                    "rejecting server request \(method) failed (server may hang on it):"
                        + " \(error)")
            }
        }
    }

    private func write(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let socket, let text = String(data: data, encoding: .utf8) else {
            throw ClientError.serverError(code: -1, message: "not connected")
        }
        try await socket.send(.string(text))
    }

    private func send(method: String, params: [String: Any]) async throws -> Data {
        let id = nextId
        nextId += 1
        let payload: [String: Any] = [
            "id": id, "jsonrpc": "2.0", "method": method, "params": params,
        ]
        // Register before writing so a fast response can't race the
        // continuation; a failed write unwinds it.
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                // Inherits actor isolation, so failPending needs no await.
                do { try await self.write(payload) } catch {
                    self.failPending(id: id, with: error)
                }
            }
        }
    }

    private func failPending(id: Int, with error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    /// Public request entry: starts/restarts the server as needed. Returns
    /// the raw JSON of the response's `result`.
    @discardableResult
    public func request(method: String, params: [String: any Sendable]) async throws -> Data {
        try await ensureRunning()
        return try await send(method: method, params: params)
    }
}
