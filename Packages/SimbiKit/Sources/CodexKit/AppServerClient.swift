import Foundation

/// Long-lived `codex app-server` JSON-RPC client (SPEC.md §5.1). One child
/// process per app session, JSON-RPC over a loopback websocket
/// (`--listen ws://127.0.0.1:0`); the port also serves viewer terminals
/// (`endpoint()`); responses demuxed by id, notifications fanned out to a
/// handler. Restarts the process on demand if it died (callers re-resume
/// their threads).
///
/// Wire shapes verified in Spikes/AppServerSpike/README.md.
public actor AppServerClient {
    public enum ClientError: Error {
        case binaryMissing
        case notAuthenticated
        case serverError(code: Int, message: String)
        case malformedResponse
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
    /// object) — Data is Sendable; handlers parse what they need.
    private var notificationHandlers: [UUID: @Sendable (String, Data) -> Void] = [:]

    /// Answers server→client requests (approvals). First handler returning
    /// `.result` wins; if none claims it the client answers with a JSON-RPC
    /// error so the server never hangs on us.
    public enum ServerRequestReply: Sendable {
        case notMine
        case result([String: any Sendable])
    }

    private var serverRequestHandlers: [UUID: @Sendable (String, Data) async -> ServerRequestReply] = [:]

    public init(installation: CodexInstallation = .standard) {
        self.installation = installation
    }

    @discardableResult
    public func addNotificationHandler(
        _ handler: @escaping @Sendable (String, Data) -> Void
    ) -> UUID {
        let id = UUID()
        notificationHandlers[id] = handler
        return id
    }

    @discardableResult
    public func addServerRequestHandler(
        _ handler: @escaping @Sendable (String, Data) async -> ServerRequestReply
    ) -> UUID {
        let id = UUID()
        serverRequestHandlers[id] = handler
        return id
    }

    /// True while the child process is alive and the socket is open.
    public var isRunning: Bool { process?.isRunning == true && socket != nil }

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
        process?.terminate()
        process = nil

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
                "clientInfo": ["name": "simbi", "title": "Simbi", "version": "0.1.0"]
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
        case .serverRequest(let id, let method, let params):
            // Approvals: the server is blocked on our answer, so an
            // unclaimed request gets an explicit error, never silence.
            let paramsData =
                (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)
            let handlers = Array(serverRequestHandlers.values)
            Task { [weak self] in
                for handler in handlers {
                    if case .result(let result) = await handler(method, paramsData) {
                        await self?.respond(id: id, result: result)
                        return
                    }
                }
                await self?.respondMethodNotFound(id: id, method: method)
            }
        case .notification(let method, let params):
            let paramsData =
                (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)
            for handler in notificationHandlers.values {
                handler(method, paramsData)
            }
        case .invalid:
            break
        }
    }

    private func respond(id: RPCID, result: [String: any Sendable]) {
        Task { try? await self.write(["jsonrpc": "2.0", "id": id.jsonValue, "result": result]) }
    }

    private func respondMethodNotFound(id: RPCID, method: String) {
        Task {
            try? await self.write([
                "jsonrpc": "2.0", "id": id.jsonValue,
                "error": ["code": -32601, "message": "unhandled server request: \(method)"],
            ])
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
                do { try await self.write(payload) } catch {
                    await self.failPending(id: id, with: error)
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
