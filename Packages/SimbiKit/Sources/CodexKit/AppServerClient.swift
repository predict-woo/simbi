import Foundation

/// Long-lived `codex app-server` JSON-RPC client (SPEC.md §5.1). One child
/// process per app session, newline-delimited JSON over stdio; responses
/// demuxed by id, notifications fanned out to a handler. Restarts the
/// process on demand if it died (callers re-resume their threads).
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
    private var stdinPipe: FileHandle?
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var readerTask: Task<Void, Never>?
    /// Notification fan-out: method + params (raw JSON of the params
    /// object) — Data is Sendable; handlers parse what they need.
    private var notificationHandlers: [UUID: @Sendable (String, Data) -> Void] = [:]

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

    /// True while the child process is alive and initialized.
    public var isRunning: Bool { process?.isRunning == true }

    private func ensureRunning() async throws {
        if process?.isRunning == true { return }
        guard installation.isBinaryInstalled else { throw ClientError.binaryMissing }

        // A dead process fails all in-flight requests.
        for (_, continuation) in pending {
            continuation.resume(throwing: ClientError.serverError(code: -1, message: "restarted"))
        }
        pending.removeAll()
        readerTask?.cancel()

        let child = Process()
        child.executableURL = installation.binaryURL
        child.arguments = ["app-server"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = installation.codexHomeURL.path  // mandatory
        child.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        let stderrLog = FileManager.default.temporaryDirectory
            .appending(path: "simbi-app-server-\(ProcessInfo.processInfo.processIdentifier).log")
        FileManager.default.createFile(atPath: stderrLog.path, contents: nil)
        child.standardError = try? FileHandle(forWritingTo: stderrLog)
        try child.run()
        process = child
        stdinPipe = stdin.fileHandleForWriting

        // Blocking availableData loop on the pipe (same transport the M1
        // spike validated), bridged into the actor line by line.
        let readHandle = stdout.fileHandleForReading
        let (lines, continuation) = AsyncStream.makeStream(of: Data.self)
        Thread.detachNewThread {
            var buffer = Data()
            while true {
                let chunk = readHandle.availableData
                if chunk.isEmpty { break }  // EOF
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    continuation.yield(Data(buffer.prefix(upTo: newline)))
                    buffer.removeSubrange(...newline)
                }
            }
            continuation.finish()
        }
        readerTask = Task { [weak self] in
            for await line in lines {
                await self?.receive(line: line)
            }
        }

        _ = try await send(
            method: "initialize",
            params: [
                "clientInfo": ["name": "simbi", "title": "Simbi", "version": "0.1.0"]
            ])
        try write(["jsonrpc": "2.0", "method": "initialized"])

        let auth = try await send(
            method: "getAuthStatus", params: ["includeToken": false, "refreshToken": false])
        guard
            (try? JSONSerialization.jsonObject(with: auth) as? [String: Any])?["authMethod"]
                is String
        else { throw ClientError.notAuthenticated }
    }

    private func receive(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return
        }
        if let id = object["id"] as? Int, object["method"] == nil {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = object["error"] as? [String: Any] {
                continuation.resume(
                    throwing: ClientError.serverError(
                        code: error["code"] as? Int ?? 0,
                        message: error["message"] as? String ?? "unknown"))
            } else {
                let result = object["result"] ?? [String: Any]()
                continuation.resume(
                    returning: (try? JSONSerialization.data(
                        withJSONObject: result, options: [.fragmentsAllowed])) ?? Data("{}".utf8))
            }
            return
        }
        if let method = object["method"] as? String {
            // Server→client requests (approvals) never arrive with
            // approvalPolicy "never"; notifications fan out.
            let params =
                (try? JSONSerialization.data(
                    withJSONObject: object["params"] ?? [String: Any]())) ?? Data("{}".utf8)
            for handler in notificationHandlers.values {
                handler(method, params)
            }
        }
    }

    private func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try stdinPipe?.write(contentsOf: data)
    }

    private func send(method: String, params: [String: Any]) async throws -> Data {
        let id = nextId
        nextId += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try write(["id": id, "jsonrpc": "2.0", "method": method, "params": params])
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    /// Public request entry: starts/restarts the server as needed. Returns
    /// the raw JSON of the response's `result`.
    @discardableResult
    public func request(method: String, params: [String: any Sendable]) async throws -> Data {
        try await ensureRunning()
        return try await send(method: method, params: params)
    }
}
