# In-App Codex Chat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the "Chat in Codex" deeplink with an in-app, per-note chat window that streams from `codex app-server`, resumes one persistent chat thread per note, and renders command/file-change approvals inline.

**Architecture:** New `ChatSession` actor in CodexKit wraps the existing `AppServerClient` (JSON-RPC over stdio) for one note's chat thread; a pure `ChatTranscript` reducer turns wire events into UI rows; a thin `@Observable` `ChatModel` bridges to a hand-rolled SwiftUI chat window (transcript + composer + approval cards). `AppServerClient` gains a server→client request path (approvals must be *answered*, not just observed).

**Tech Stack:** Swift 6 SPM package (macOS 14), swift-testing (`@Suite`/`@Test`/`#expect`), SwiftUI `@Observable`, existing `swift-markdown-engine` NOT used for chat rows (see Task 6) — chat markdown renders via `AttributedString(markdown:)` + fenced-code segmentation.

**Spec:** `docs/superpowers/specs/2026-07-21-in-app-codex-chat-design.md`

## Global Constraints

- Platform floor: macOS 14 (`Package.swift` `.macOS(.v14)`). No macOS 15-only API (e.g. no `onScrollGeometryChange`).
- No new external dependencies.
- All logic in `Packages/SimbiKit` (the app target `App/SimbiApp.swift` is a thin shell); `swift build`/`swift test` must pass headless from `Packages/SimbiKit`.
- SwiftLint is configured (`.swiftlint.yml`); run `swiftlint --quiet` at repo root before each commit and fix violations.
- UI style: use `Design` constants (`Design.paneInset`, `Font.meta`, `StatusBanner`) — no hardcoded one-off colors; red is reserved for recording.
- View models: `@Observable @MainActor` classes (NOT ObservableObject); Codex-facing backends are actors; bridge with `Task { @MainActor in ... }`.
- Existing test style: swift-testing (`import Testing`, `@Suite`, `@Test`, `#expect`), NOT XCTest.
- Wire protocol facts (verified against openai/codex `app-server-protocol` v2 and the existing fixer code — do not "correct" these):
  - Requests carry `"jsonrpc":"2.0"`, integer `id`. Notifications: `method` + `params`, no `id`. Server→client requests: `method` + `params` + `id` (id may be Int or String).
  - Notifications used: `turn/started` `{threadId, turn}`, `turn/completed` `{threadId, turn: {status: "completed"|"interrupted"|"failed"|"inProgress", ...}}`, `item/started`/`item/completed` `{item, threadId, turnId, ...}`, `item/agentMessage/delta` `{threadId, turnId, itemId, delta}`.
  - `item` is tagged by `type` (camelCase): `userMessage {id, content: [{type:"text", text}]}`, `agentMessage {id, text}`, `reasoning {id, summary: [String]}`, `commandExecution {id, command, cwd, status, aggregatedOutput?, exitCode?}`, `fileChange {id, changes: [{path, kind}], status}`, plus others (`mcpToolCall`, `webSearch`, …) that must render as a quiet generic row, never crash.
  - Server→client approval requests: `item/commandExecution/requestApproval` `{threadId, turnId, itemId, command?, cwd?, reason?}` and `item/fileChange/requestApproval` `{threadId, turnId, itemId, reason?, grantRoot?}`. The client answers the *request* with result `{"decision": "accept" | "acceptForSession" | "decline" | "cancel"}`.
  - `turn/start` params for chat: `threadId`, `input: [{type:"text", text, text_elements: []}]`, optional `model`, `approvalPolicy: "on-request"`, `sandboxPolicy: {type: "workspaceWrite", networkAccess: false, excludeTmpdirEnvVar: false, excludeSlashTmp: false}` (no `writableRoots` → cwd is the writable root).
  - History hydration: `thread/read` params `{threadId, includeTurns: true}` → `{thread: {turns: [{items: [item...]}]}}`. Parse defensively; missing `turns`/`items` → empty history, not an error.
  - `turn/interrupt` params: `{threadId, turnId}`.

---

### Task 1: JSON-RPC classification + server→client request support in AppServerClient

Approvals arrive as server→client *requests* (`method` + `id`). Today `AppServerClient.receive` treats anything with a `method` as a notification, so approvals would be fanned out and never answered, hanging the turn.

**Files:**
- Create: `Packages/SimbiKit/Sources/CodexKit/JSONRPCMessage.swift`
- Modify: `Packages/SimbiKit/Sources/CodexKit/AppServerClient.swift`
- Test: `Packages/SimbiKit/Tests/CodexKitTests/JSONRPCMessageTests.swift`

**Interfaces:**
- Produces: `JSONRPCMessage.classify(_: [String: Any]) -> JSONRPCMessage` with cases `.response(id: Int, body: [String: Any])`, `.serverRequest(id: RPCID, method: String, params: [String: Any])`, `.notification(method: String, params: [String: Any])`, `.invalid`; `enum RPCID: Equatable, Sendable { case int(Int); case string(String) }` with `var jsonValue: any Sendable`.
- Produces: `AppServerClient.addServerRequestHandler(_ handler: @escaping @Sendable (String, Data) async -> ServerRequestReply) -> UUID` and `public enum ServerRequestReply: Sendable { case notMine; case result([String: any Sendable]) }`.

- [ ] **Step 1: Write the failing classification tests**

`Packages/SimbiKit/Tests/CodexKitTests/JSONRPCMessageTests.swift`:

```swift
import Foundation
import Testing

@testable import CodexKit

@Suite("JSONRPCMessage")
struct JSONRPCMessageTests {
    private func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    @Test("id without method is a response")
    func response() {
        let message = JSONRPCMessage.classify(object(#"{"id": 3, "result": {"ok": true}}"#))
        guard case .response(let id, _) = message else {
            Issue.record("expected response, got \(message)")
            return
        }
        #expect(id == 3)
    }

    @Test("method with id is a server request, int or string id")
    func serverRequest() {
        let intId = JSONRPCMessage.classify(
            object(#"{"id": 7, "method": "item/commandExecution/requestApproval", "params": {"command": "git push"}}"#))
        guard case .serverRequest(let id, let method, let params) = intId else {
            Issue.record("expected serverRequest, got \(intId)")
            return
        }
        #expect(id == .int(7))
        #expect(method == "item/commandExecution/requestApproval")
        #expect(params["command"] as? String == "git push")

        let stringId = JSONRPCMessage.classify(
            object(#"{"id": "req-1", "method": "item/fileChange/requestApproval", "params": {}}"#))
        guard case .serverRequest(let sid, _, _) = stringId else {
            Issue.record("expected serverRequest, got \(stringId)")
            return
        }
        #expect(sid == .string("req-1"))
    }

    @Test("method without id is a notification")
    func notification() {
        let message = JSONRPCMessage.classify(
            object(#"{"method": "item/agentMessage/delta", "params": {"delta": "hi"}}"#))
        guard case .notification(let method, let params) = message else {
            Issue.record("expected notification, got \(message)")
            return
        }
        #expect(method == "item/agentMessage/delta")
        #expect(params["delta"] as? String == "hi")
    }

    @Test("garbage is invalid")
    func invalid() {
        guard case .invalid = JSONRPCMessage.classify(object(#"{"foo": 1}"#)) else {
            Issue.record("expected invalid")
            return
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/SimbiKit && swift test --filter JSONRPCMessage`
Expected: compile FAILURE — `JSONRPCMessage` not defined.

- [ ] **Step 3: Implement JSONRPCMessage**

`Packages/SimbiKit/Sources/CodexKit/JSONRPCMessage.swift`:

```swift
import Foundation

/// JSON-RPC id — the app-server sends Int ids for its own requests, but the
/// spec allows strings; echo back whatever arrived.
public enum RPCID: Equatable, Sendable, Hashable {
    case int(Int)
    case string(String)

    var jsonValue: any Sendable {
        switch self {
        case .int(let value): value
        case .string(let value): value
        }
    }
}

/// Classifies one incoming JSON-RPC message off the app-server stream.
/// Responses have an id and no method; server→client requests (approvals)
/// have BOTH method and id and must be answered; notifications have only a
/// method.
enum JSONRPCMessage {
    case response(id: Int, body: [String: Any])
    case serverRequest(id: RPCID, method: String, params: [String: Any])
    case notification(method: String, params: [String: Any])
    case invalid

    static func classify(_ object: [String: Any]) -> JSONRPCMessage {
        let method = object["method"] as? String
        let rpcId: RPCID? =
            if let intId = object["id"] as? Int {
                .int(intId)
            } else if let stringId = object["id"] as? String {
                .string(stringId)
            } else {
                nil
            }
        switch (method, rpcId) {
        case (nil, .int(let id)):
            return .response(id: id, body: object)
        case (let method?, let id?):
            return .serverRequest(
                id: id, method: method, params: object["params"] as? [String: Any] ?? [:])
        case (let method?, nil):
            return .notification(
                method: method, params: object["params"] as? [String: Any] ?? [:])
        default:
            return .invalid
        }
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `cd Packages/SimbiKit && swift test --filter JSONRPCMessage`
Expected: 4 tests PASS.

- [ ] **Step 5: Rewire AppServerClient.receive through classify and add the server-request path**

In `AppServerClient.swift`, add next to `notificationHandlers`:

```swift
    /// Answers server→client requests (approvals). First handler returning
    /// `.result` wins; if none claims it the client answers with a JSON-RPC
    /// error so the server never hangs on us.
    public enum ServerRequestReply: Sendable {
        case notMine
        case result([String: any Sendable])
    }

    private var serverRequestHandlers:
        [UUID: @Sendable (String, Data) async -> ServerRequestReply] = [:]

    @discardableResult
    public func addServerRequestHandler(
        _ handler: @escaping @Sendable (String, Data) async -> ServerRequestReply
    ) -> UUID {
        let id = UUID()
        serverRequestHandlers[id] = handler
        return id
    }
```

Replace the body of `private func receive(line: Data)` with:

```swift
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
        try? write(["jsonrpc": "2.0", "id": id.jsonValue, "result": result])
    }

    private func respondMethodNotFound(id: RPCID, method: String) {
        try? write([
            "jsonrpc": "2.0", "id": id.jsonValue,
            "error": ["code": -32601, "message": "unhandled server request: \(method)"]
        ])
    }
```

(The old comment about approvals never arriving under `approvalPolicy: never` is now wrong — delete it.)

- [ ] **Step 6: Full package build + tests**

Run: `cd Packages/SimbiKit && swift build && swift test --filter CodexKit`
Expected: build succeeds; all CodexKit tests pass (fixer/converter behavior unchanged — they registered notification handlers only).

- [ ] **Step 7: Lint + commit**

```bash
swiftlint --quiet
git add Packages/SimbiKit/Sources/CodexKit/JSONRPCMessage.swift \
        Packages/SimbiKit/Sources/CodexKit/AppServerClient.swift \
        Packages/SimbiKit/Tests/CodexKitTests/JSONRPCMessageTests.swift
git commit -m "Answer app-server server->client requests in AppServerClient"
```

---

### Task 2: ChatEvent model + notification parser

**Files:**
- Create: `Packages/SimbiKit/Sources/CodexKit/ChatEvents.swift`
- Test: `Packages/SimbiKit/Tests/CodexKitTests/ChatEventsTests.swift`

**Interfaces:**
- Produces:
  - `public struct ChatItem: Equatable, Sendable, Identifiable { public let id: String; public let detail: Detail }` with `public enum Detail: Equatable, Sendable { case userMessage(text: String); case agentMessage(text: String); case reasoning(summary: String); case commandExecution(command: String, status: String, output: String?); case fileChange(files: [String], status: String); case other(type: String) }`.
  - `public enum ChatEvent: Equatable, Sendable { case turnStarted(turnId: String); case turnCompleted(status: String); case agentMessageDelta(itemId: String, delta: String); case itemStarted(ChatItem); case itemCompleted(ChatItem) }`
  - `public enum ChatEventParser { static func parse(method: String, params: [String: Any]) -> (threadId: String, event: ChatEvent)?; static func item(from dict: [String: Any]) -> ChatItem? }`
- Consumes: nothing from other tasks.

- [ ] **Step 1: Write failing parser tests**

`Packages/SimbiKit/Tests/CodexKitTests/ChatEventsTests.swift` — fixtures copied from the confirmed v2 wire shapes:

```swift
import Foundation
import Testing

@testable import CodexKit

@Suite("ChatEventParser")
struct ChatEventsTests {
    private func params(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    @Test("agent message delta")
    func delta() {
        let parsed = ChatEventParser.parse(
            method: "item/agentMessage/delta",
            params: params(
                #"{"threadId": "thr_1", "turnId": "turn_1", "itemId": "item_9", "delta": "Hel"}"#))
        #expect(parsed?.threadId == "thr_1")
        #expect(parsed?.event == .agentMessageDelta(itemId: "item_9", delta: "Hel"))
    }

    @Test("turn lifecycle")
    func turns() {
        let started = ChatEventParser.parse(
            method: "turn/started",
            params: params(#"{"threadId": "thr_1", "turn": {"id": "turn_1", "status": "inProgress"}}"#))
        #expect(started?.event == .turnStarted(turnId: "turn_1"))

        let failed = ChatEventParser.parse(
            method: "turn/completed",
            params: params(#"{"threadId": "thr_1", "turn": {"id": "turn_1", "status": "failed"}}"#))
        #expect(failed?.event == .turnCompleted(status: "failed"))
    }

    @Test("item completed: agentMessage, commandExecution, fileChange")
    func items() {
        let agent = ChatEventParser.parse(
            method: "item/completed",
            params: params(
                #"{"threadId": "thr_1", "turnId": "t", "item": {"type": "agentMessage", "id": "i1", "text": "Done."}}"#))
        #expect(agent?.event == .itemCompleted(ChatItem(id: "i1", detail: .agentMessage(text: "Done."))))

        let command = ChatEventParser.parse(
            method: "item/completed",
            params: params(
                #"""
                {"threadId": "thr_1", "turnId": "t", "item": {"type": "commandExecution",
                 "id": "i2", "command": "ls -la", "cwd": "/tmp", "status": "completed",
                 "aggregatedOutput": "total 0", "exitCode": 0}}
                """#))
        #expect(
            command?.event
                == .itemCompleted(
                    ChatItem(
                        id: "i2",
                        detail: .commandExecution(
                            command: "ls -la", status: "completed", output: "total 0"))))

        let file = ChatEventParser.parse(
            method: "item/started",
            params: params(
                #"""
                {"threadId": "thr_1", "turnId": "t", "item": {"type": "fileChange", "id": "i3",
                 "status": "inProgress", "changes": [{"path": "/Users/u/Simbi/note.md", "kind": "edit"}]}}
                """#))
        #expect(
            file?.event
                == .itemStarted(
                    ChatItem(
                        id: "i3",
                        detail: .fileChange(files: ["/Users/u/Simbi/note.md"], status: "inProgress"))))
    }

    @Test("user message and unknown types survive")
    func userAndUnknown() {
        let user = ChatEventParser.item(from: params(
            #"{"type": "userMessage", "id": "u1", "content": [{"type": "text", "text": "hi"}]}"#))
        #expect(user == ChatItem(id: "u1", detail: .userMessage(text: "hi")))

        let odd = ChatEventParser.item(from: params(
            #"{"type": "mcpToolCall", "id": "m1", "server": "s", "tool": "t"}"#))
        #expect(odd == ChatItem(id: "m1", detail: .other(type: "mcpToolCall")))
    }

    @Test("reasoning summarizes; unrelated methods return nil")
    func reasoningAndNil() {
        let reasoning = ChatEventParser.item(from: params(
            #"{"type": "reasoning", "id": "r1", "summary": ["Weighing options"], "content": []}"#))
        #expect(reasoning == ChatItem(id: "r1", detail: .reasoning(summary: "Weighing options")))
        #expect(ChatEventParser.parse(method: "turn/diff/updated", params: [:]) == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/SimbiKit && swift test --filter ChatEventParser`
Expected: compile FAILURE — types not defined.

- [ ] **Step 3: Implement ChatEvents.swift**

```swift
import Foundation

/// One unit of chat work, translated off the wire (SPEC §5.4 v2 items).
public struct ChatItem: Equatable, Sendable, Identifiable {
    public enum Detail: Equatable, Sendable {
        case userMessage(text: String)
        case agentMessage(text: String)
        case reasoning(summary: String)
        case commandExecution(command: String, status: String, output: String?)
        case fileChange(files: [String], status: String)
        /// Item types the chat doesn't render richly (mcpToolCall,
        /// webSearch, …) — shown as a quiet generic row, never dropped.
        case other(type: String)
    }

    public let id: String
    public let detail: Detail

    public init(id: String, detail: Detail) {
        self.id = id
        self.detail = detail
    }
}

/// Chat-relevant app-server traffic, one thread's worth.
public enum ChatEvent: Equatable, Sendable {
    case turnStarted(turnId: String)
    case turnCompleted(status: String)
    case agentMessageDelta(itemId: String, delta: String)
    case itemStarted(ChatItem)
    case itemCompleted(ChatItem)
}

public enum ChatEventParser {
    /// Parses one notification into (threadId, event); nil for methods the
    /// chat doesn't consume. The caller filters by threadId — the shared
    /// client fans every thread's notifications to every handler.
    public static func parse(
        method: String, params: [String: Any]
    ) -> (threadId: String, event: ChatEvent)? {
        guard let threadId = params["threadId"] as? String else { return nil }
        switch method {
        case "turn/started":
            guard let turn = params["turn"] as? [String: Any],
                let turnId = turn["id"] as? String
            else { return nil }
            return (threadId, .turnStarted(turnId: turnId))
        case "turn/completed":
            let turn = params["turn"] as? [String: Any]
            return (threadId, .turnCompleted(status: turn?["status"] as? String ?? "completed"))
        case "item/agentMessage/delta":
            guard let itemId = params["itemId"] as? String,
                let delta = params["delta"] as? String
            else { return nil }
            return (threadId, .agentMessageDelta(itemId: itemId, delta: delta))
        case "item/started", "item/completed":
            guard let dict = params["item"] as? [String: Any],
                let item = item(from: dict)
            else { return nil }
            return (
                threadId,
                method == "item/started" ? .itemStarted(item) : .itemCompleted(item)
            )
        default:
            return nil
        }
    }

    /// Translates one wire item; unknown types become `.other`, a missing
    /// id/type makes it nil (nothing renderable).
    public static func item(from dict: [String: Any]) -> ChatItem? {
        guard let id = dict["id"] as? String, let type = dict["type"] as? String else {
            return nil
        }
        switch type {
        case "userMessage":
            let content = dict["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return ChatItem(id: id, detail: .userMessage(text: text))
        case "agentMessage":
            return ChatItem(id: id, detail: .agentMessage(text: dict["text"] as? String ?? ""))
        case "reasoning":
            let summary = (dict["summary"] as? [String])?.first ?? ""
            return ChatItem(id: id, detail: .reasoning(summary: summary))
        case "commandExecution":
            return ChatItem(
                id: id,
                detail: .commandExecution(
                    command: dict["command"] as? String ?? "",
                    status: dict["status"] as? String ?? "",
                    output: dict["aggregatedOutput"] as? String))
        case "fileChange":
            let changes = dict["changes"] as? [[String: Any]] ?? []
            return ChatItem(
                id: id,
                detail: .fileChange(
                    files: changes.compactMap { $0["path"] as? String },
                    status: dict["status"] as? String ?? ""))
        default:
            return ChatItem(id: id, detail: .other(type: type))
        }
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `cd Packages/SimbiKit && swift test --filter ChatEventParser`
Expected: 5 tests PASS.

- [ ] **Step 5: Lint + commit**

```bash
swiftlint --quiet
git add Packages/SimbiKit/Sources/CodexKit/ChatEvents.swift \
        Packages/SimbiKit/Tests/CodexKitTests/ChatEventsTests.swift
git commit -m "Add chat event model and app-server notification parser"
```

---

### Task 3: ChatTranscript reducer

Pure state machine: events in, UI rows out. Lives in CodexKit so it's testable headless (SimbiUI has no test target).

**Files:**
- Create: `Packages/SimbiKit/Sources/CodexKit/ChatTranscript.swift`
- Test: `Packages/SimbiKit/Tests/CodexKitTests/ChatTranscriptTests.swift`

**Interfaces:**
- Consumes: `ChatEvent`, `ChatItem` (Task 2).
- Produces:
  - `public struct ChatTranscript: Equatable, Sendable` with `public private(set) var rows: [Row]`, `public private(set) var turnActive: Bool`, `public private(set) var activeTurnId: String?`, `public init(history: [ChatItem] = [])`, `public mutating func apply(_ event: ChatEvent)`, `public mutating func appendLocalUser(text: String)`, `public mutating func appendBanner(_ text: String)`.
  - `public enum Row: Equatable, Sendable, Identifiable { case user(id: String, text: String); case agent(id: String, markdown: String, streaming: Bool); case command(id: String, command: String, status: String, output: String?); case fileChange(id: String, files: [String], status: String); case quiet(id: String, text: String); case banner(id: String, text: String) }` (nested in ChatTranscript; `id` returns the associated id).

Reducer rules (encode exactly):
- `itemStarted`/`itemCompleted` upsert by item id (update in place if a row with that id exists, else append). `itemCompleted` text/status/output is authoritative.
- `agentMessageDelta`: append delta to the `.agent` row with that id, or create `.agent(id:, markdown: delta, streaming: true)` if absent.
- `itemCompleted` with `.agentMessage` sets `streaming: false` and replaces accumulated text.
- `.reasoning` → `.quiet(id, "Thinking — <summary>")` (summary may be empty → "Thinking…"); `.other(type)` → `.quiet(id, type)`.
- `turnStarted` sets `turnActive = true`, `activeTurnId`; `turnCompleted` sets `turnActive = false`, `activeTurnId = nil`, and if status is `failed` or `interrupted` appends `.banner` ("The turn failed." / "Interrupted.").
- `appendLocalUser` appends a `.user` row with a locally generated id (`"local-<count>"`) — the user's message must appear instantly, before any server round-trip.
- `init(history:)` maps hydrated items through the same upsert path.

- [ ] **Step 1: Write failing reducer tests**

`Packages/SimbiKit/Tests/CodexKitTests/ChatTranscriptTests.swift`:

```swift
import Testing

@testable import CodexKit

@Suite("ChatTranscript")
struct ChatTranscriptTests {
    @Test("deltas accumulate then completion is authoritative")
    func streaming() {
        var transcript = ChatTranscript()
        transcript.apply(.turnStarted(turnId: "t1"))
        #expect(transcript.turnActive)
        #expect(transcript.activeTurnId == "t1")
        transcript.apply(.agentMessageDelta(itemId: "a1", delta: "Hel"))
        transcript.apply(.agentMessageDelta(itemId: "a1", delta: "lo"))
        #expect(transcript.rows == [.agent(id: "a1", markdown: "Hello", streaming: true)])
        transcript.apply(.itemCompleted(ChatItem(id: "a1", detail: .agentMessage(text: "Hello!"))))
        #expect(transcript.rows == [.agent(id: "a1", markdown: "Hello!", streaming: false)])
        transcript.apply(.turnCompleted(status: "completed"))
        #expect(!transcript.turnActive)
        #expect(transcript.rows.count == 1)  // no banner on clean completion
    }

    @Test("command rows upsert started -> completed")
    func commandLifecycle() {
        var transcript = ChatTranscript()
        transcript.apply(
            .itemStarted(
                ChatItem(id: "c1", detail: .commandExecution(command: "ls", status: "inProgress", output: nil))))
        transcript.apply(
            .itemCompleted(
                ChatItem(id: "c1", detail: .commandExecution(command: "ls", status: "completed", output: "a.txt"))))
        #expect(transcript.rows == [.command(id: "c1", command: "ls", status: "completed", output: "a.txt")])
    }

    @Test("failed turn appends a banner; local user rows are immediate")
    func failureAndLocalEcho() {
        var transcript = ChatTranscript()
        transcript.appendLocalUser(text: "do the thing")
        #expect(transcript.rows == [.user(id: "local-1", text: "do the thing")])
        transcript.apply(.turnCompleted(status: "failed"))
        #expect(transcript.rows.last == .banner(id: "banner-1", text: "The turn failed."))
    }

    @Test("history hydration maps items to rows; reasoning and unknown are quiet")
    func hydration() {
        let transcript = ChatTranscript(history: [
            ChatItem(id: "u1", detail: .userMessage(text: "hi")),
            ChatItem(id: "a1", detail: .agentMessage(text: "hello")),
            ChatItem(id: "r1", detail: .reasoning(summary: "")),
            ChatItem(id: "m1", detail: .other(type: "mcpToolCall")),
            ChatItem(id: "f1", detail: .fileChange(files: ["/n/note.md"], status: "completed"))
        ])
        #expect(transcript.rows == [
            .user(id: "u1", text: "hi"),
            .agent(id: "a1", markdown: "hello", streaming: false),
            .quiet(id: "r1", text: "Thinking…"),
            .quiet(id: "m1", text: "mcpToolCall"),
            .fileChange(id: "f1", files: ["/n/note.md"], status: "completed")
        ])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/SimbiKit && swift test --filter ChatTranscript`
Expected: compile FAILURE.

- [ ] **Step 3: Implement ChatTranscript.swift**

```swift
import Foundation

/// Pure reducer from chat wire events to renderable rows. All ordering and
/// streaming rules live here so the UI model stays a thin bridge and the
/// behavior is testable headless.
public struct ChatTranscript: Equatable, Sendable {
    public enum Row: Equatable, Sendable, Identifiable {
        case user(id: String, text: String)
        case agent(id: String, markdown: String, streaming: Bool)
        case command(id: String, command: String, status: String, output: String?)
        case fileChange(id: String, files: [String], status: String)
        /// Reasoning + item types without a rich row — visible but muted.
        case quiet(id: String, text: String)
        case banner(id: String, text: String)

        public var id: String {
            switch self {
            case .user(let id, _), .agent(let id, _, _), .command(let id, _, _, _),
                .fileChange(let id, _, _), .quiet(let id, _), .banner(let id, _):
                id
            }
        }
    }

    public private(set) var rows: [Row] = []
    public private(set) var turnActive = false
    public private(set) var activeTurnId: String?
    private var localCounter = 0
    private var bannerCounter = 0

    public init(history: [ChatItem] = []) {
        for item in history {
            upsert(item)
        }
    }

    public mutating func apply(_ event: ChatEvent) {
        switch event {
        case .turnStarted(let turnId):
            turnActive = true
            activeTurnId = turnId
        case .turnCompleted(let status):
            turnActive = false
            activeTurnId = nil
            if status == "failed" {
                appendBanner("The turn failed.")
            } else if status == "interrupted" {
                appendBanner("Interrupted.")
            }
        case .agentMessageDelta(let itemId, let delta):
            if let index = rows.firstIndex(where: { $0.id == itemId }),
                case .agent(_, let markdown, _) = rows[index] {
                rows[index] = .agent(id: itemId, markdown: markdown + delta, streaming: true)
            } else {
                rows.append(.agent(id: itemId, markdown: delta, streaming: true))
            }
        case .itemStarted(let item), .itemCompleted(let item):
            upsert(item)
        }
    }

    /// The user's message must appear the instant they hit send — the wire
    /// echo (userMessage item) upserts under its server id separately, so
    /// suppress those to avoid doubles: hydrated userMessage items only
    /// come from history.
    public mutating func appendLocalUser(text: String) {
        localCounter += 1
        rows.append(.user(id: "local-\(localCounter)", text: text))
    }

    public mutating func appendBanner(_ text: String) {
        bannerCounter += 1
        rows.append(.banner(id: "banner-\(bannerCounter)", text: text))
    }

    private mutating func upsert(_ item: ChatItem) {
        let row = Self.row(for: item)
        guard let row else { return }
        if let index = rows.firstIndex(where: { $0.id == item.id }) {
            rows[index] = row
        } else {
            rows.append(row)
        }
    }

    private static func row(for item: ChatItem) -> Row? {
        switch item.detail {
        case .userMessage(let text):
            .user(id: item.id, text: text)
        case .agentMessage(let text):
            .agent(id: item.id, markdown: text, streaming: false)
        case .reasoning(let summary):
            .quiet(id: item.id, text: summary.isEmpty ? "Thinking…" : "Thinking — \(summary)")
        case .commandExecution(let command, let status, let output):
            .command(id: item.id, command: command, status: status, output: output)
        case .fileChange(let files, let status):
            .fileChange(id: item.id, files: files, status: status)
        case .other(let type):
            .quiet(id: item.id, text: type)
        }
    }
}
```

Caveat discovered in test-writing: a live `userMessage` item WILL arrive over the wire for the message we already echoed locally, producing a duplicate. Handle it: in `apply`, when upserting a `.user` row whose id is new but whose text equals the last local `.user` row's text, replace that local row (swap its id to the server id) instead of appending. Add this test:

```swift
    @Test("wire echo of the sent message replaces the local row, not duplicates")
    func echoDedup() {
        var transcript = ChatTranscript()
        transcript.appendLocalUser(text: "hi")
        transcript.apply(.itemCompleted(ChatItem(id: "u9", detail: .userMessage(text: "hi"))))
        #expect(transcript.rows == [.user(id: "u9", text: "hi")])
    }
```

Implementation: in `upsert`, before the generic path —

```swift
        if case .user(_, let text) = row,
            let last = rows.lastIndex(where: {
                if case .user(let id, let existing) = $0 {
                    return id.hasPrefix("local-") && existing == text
                }
                return false
            }) {
            rows[last] = row
            return
        }
```

- [ ] **Step 4: Run tests to verify pass**

Run: `cd Packages/SimbiKit && swift test --filter ChatTranscript`
Expected: 5 tests PASS.

- [ ] **Step 5: Lint + commit**

```bash
swiftlint --quiet
git add Packages/SimbiKit/Sources/CodexKit/ChatTranscript.swift \
        Packages/SimbiKit/Tests/CodexKitTests/ChatTranscriptTests.swift
git commit -m "Add ChatTranscript reducer from chat events to UI rows"
```

---

### Task 4: Persist chatThreadId in NoteRecordingState

**Files:**
- Modify: `Packages/SimbiKit/Sources/SimbiKit/NoteRecordingState.swift`
- Test: `Packages/SimbiKit/Tests/SimbiKitTests/NoteRecordingStateChatTests.swift` (new file)

**Interfaces:**
- Produces: `NoteRecordingState.chatThreadId: String?` — persisted, forward-compatible, round-trips through `update(noteFolder:_:)`.

- [ ] **Step 1: Write failing test**

```swift
import Foundation
import Testing

@testable import SimbiKit

@Suite("NoteRecordingState chat thread")
struct NoteRecordingStateChatTests {
    @Test("chatThreadId round-trips and old state files still decode")
    func chatThreadId() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "chat-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Old file without the key decodes to nil.
        try Data(#"{"nextCueIndex": 3}"#.utf8)
            .write(to: NoteRecordingState.fileURL(noteFolder: folder).path.isEmpty
                ? folder : NoteRecordingState.fileURL(noteFolder: folder))
        // fileURL is .simbi/state.json — ensure parent exists first:
        // (createDirectory above only made the note folder)
        var loaded = try NoteRecordingState.load(noteFolder: folder)
        #expect(loaded.chatThreadId == nil)

        try NoteRecordingState.update(noteFolder: folder) { $0.chatThreadId = "thr_42" }
        loaded = try NoteRecordingState.load(noteFolder: folder)
        #expect(loaded.chatThreadId == "thr_42")
        #expect(loaded.nextCueIndex == 3)
    }
}
```

Note: writing the "old file" needs `.simbi/` to exist — create it with `FileManager.default.createDirectory(at: folder.appending(path: ".simbi"), withIntermediateDirectories: true)` before the write, and write to `NoteRecordingState.fileURL(noteFolder: folder)` directly (drop the ternary noise above; it's illustrative that the path is `.simbi/state.json`).

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/SimbiKit && swift test --filter "NoteRecordingState chat"`
Expected: compile FAILURE — `chatThreadId` not defined.

- [ ] **Step 3: Add the field**

In `NoteRecordingState.swift`, after `fixerInstructionsVersion`:

```swift
    /// The note's persistent chat thread (SPEC.md §5.4), resumed by the
    /// in-app chat window across app restarts. Never archived by Simbi
    /// except when the user starts a new chat.
    public var chatThreadId: String?
```

Add `chatThreadId: String? = nil` to `init` (after `fixerInstructionsVersion: Int = 0`), assign it, and in `init(from:)` add:

```swift
        chatThreadId = try container.decodeIfPresent(String.self, forKey: .chatThreadId)
```

- [ ] **Step 4: Run tests to verify pass**

Run: `cd Packages/SimbiKit && swift test --filter "NoteRecordingState"`
Expected: PASS (including any existing state tests).

- [ ] **Step 5: Lint + commit**

```bash
swiftlint --quiet
git add Packages/SimbiKit/Sources/SimbiKit/NoteRecordingState.swift \
        Packages/SimbiKit/Tests/SimbiKitTests/NoteRecordingStateChatTests.swift
git commit -m "Persist per-note chat thread id in state.json"
```

---

### Task 5: ChatSession actor

**Files:**
- Create: `Packages/SimbiKit/Sources/CodexKit/ChatSession.swift`
- Test: `Packages/SimbiKit/Tests/CodexKitTests/ChatSessionTests.swift` (hydration parsing only — the full actor is exercised in Task 10 against the real server)

**Interfaces:**
- Consumes: `AppServerClient.request/addNotificationHandler/addServerRequestHandler` (Task 1), `ChatEventParser`, `ChatEvent`, `ChatItem` (Task 2), `CodexChat.notePath` (existing).
- Produces (all used by ChatModel in Task 7/8):

```swift
public struct ChatApprovalRequest: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case commandExecution(command: String, cwd: String?, reason: String?)
        case fileChange(files: [String], reason: String?)
    }
    public let id: UUID          // local token, not a wire id
    public let itemId: String
    public let kind: Kind
}

public enum ChatSessionEvent: Sendable {
    case event(ChatEvent)                        // transcript-relevant
    case approvalRequested(ChatApprovalRequest)  // needs a user decision
    case approvalSettled(UUID)                   // card can collapse
}

public actor ChatSession {
    public init(noteFolderURL: URL, homeRootURL: URL, client: AppServerClient, model: String?)
    /// Single-consumer stream; ChatModel is the only listener.
    public func events() -> AsyncStream<ChatSessionEvent>
    /// Resume-or-create; returns hydrated history (empty for a new thread).
    public func ensureThread() async throws -> [ChatItem]
    public func send(_ text: String) async throws
    public func interrupt() async
    /// Archives the current thread and creates a fresh one.
    public func newChat() async throws
    /// decision: "accept" | "acceptForSession" | "decline" | "cancel"
    public func resolveApproval(id: UUID, decision: String) async
    public static func history(fromThreadReadResult data: Data) -> [ChatItem]
}
```

- [ ] **Step 1: Write failing hydration tests**

`Packages/SimbiKit/Tests/CodexKitTests/ChatSessionTests.swift`:

```swift
import Foundation
import Testing

@testable import CodexKit

@Suite("ChatSession hydration")
struct ChatSessionTests {
    @Test("thread/read result maps turns/items to ChatItems in order")
    func hydration() {
        let data = Data(
            #"""
            {"thread": {"id": "thr_1", "turns": [
              {"id": "t1", "status": "completed", "items": [
                {"type": "userMessage", "id": "u1", "content": [{"type": "text", "text": "hi"}]},
                {"type": "agentMessage", "id": "a1", "text": "hello"}
              ]},
              {"id": "t2", "status": "completed", "items": [
                {"type": "commandExecution", "id": "c1", "command": "ls", "cwd": "/", "status": "completed"}
              ]}
            ]}}
            """#.utf8)
        #expect(ChatSession.history(fromThreadReadResult: data) == [
            ChatItem(id: "u1", detail: .userMessage(text: "hi")),
            ChatItem(id: "a1", detail: .agentMessage(text: "hello")),
            ChatItem(id: "c1", detail: .commandExecution(command: "ls", status: "completed", output: nil))
        ])
    }

    @Test("missing turns or items hydrate to empty, not crash")
    func defensive() {
        #expect(ChatSession.history(fromThreadReadResult: Data(#"{"thread": {"id": "x"}}"#.utf8)).isEmpty)
        #expect(ChatSession.history(fromThreadReadResult: Data("null".utf8)).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/SimbiKit && swift test --filter "ChatSession"`
Expected: compile FAILURE.

- [ ] **Step 3: Implement ChatSession.swift**

```swift
import Foundation
import SimbiKit

/// A pending approval surfaced to the chat UI. `id` is a local token tying
/// the UI's decision back to the suspended server request.
public struct ChatApprovalRequest: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case commandExecution(command: String, cwd: String?, reason: String?)
        case fileChange(files: [String], reason: String?)
    }

    public let id: UUID
    public let itemId: String
    public let kind: Kind
}

public enum ChatSessionEvent: Sendable {
    case event(ChatEvent)
    case approvalRequested(ChatApprovalRequest)
    case approvalSettled(UUID)
}

/// The note's chat thread over the shared app-server (SPEC.md §5.4):
/// resume-or-create with a persisted thread id, workspace-write turns with
/// on-request approvals, and a single event stream for the UI.
public actor ChatSession {
    private let noteFolderURL: URL
    private let homeRootURL: URL
    private let client: AppServerClient
    private let model: String?

    private var threadId: String?
    private var bound = false
    private var continuation: AsyncStream<ChatSessionEvent>.Continuation?
    private var pendingApprovals: [UUID: CheckedContinuation<String, Never>] = [:]

    public init(
        noteFolderURL: URL, homeRootURL: URL, client: AppServerClient, model: String?
    ) {
        self.noteFolderURL = noteFolderURL
        self.homeRootURL = homeRootURL
        self.client = client
        self.model = model
    }

    public func events() -> AsyncStream<ChatSessionEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: ChatSessionEvent.self)
        self.continuation = continuation
        return stream
    }

    /// Resume the persisted thread (fresh-start fallback if it's gone) and
    /// return its history for the transcript.
    public func ensureThread() async throws -> [ChatItem] {
        try await bindHandlers()
        if let saved = try? NoteRecordingState.load(noteFolder: noteFolderURL).chatThreadId {
            do {
                _ = try await client.request(
                    method: "thread/resume", params: ["threadId": saved])
                threadId = saved
                let read = try await client.request(
                    method: "thread/read",
                    params: ["threadId": saved, "includeTurns": true])
                return Self.history(fromThreadReadResult: read)
            } catch {
                // Deleted/corrupt thread: fall through to a fresh one.
            }
        }
        try await startFreshThread()
        return []
    }

    public func send(_ text: String) async throws {
        guard let threadId else { return }
        let input: [[String: any Sendable]] = [
            ["type": "text", "text": text, "text_elements": [String]()]
        ]
        // Workspace-write rooted at the thread's cwd (the home root), with
        // approvals surfaced to the user — unlike the fixer's silent
        // never-ask worktree policy.
        let sandboxPolicy: [String: any Sendable] = [
            "type": "workspaceWrite",
            "networkAccess": false,
            "excludeTmpdirEnvVar": false,
            "excludeSlashTmp": false
        ]
        var params: [String: any Sendable] = [
            "threadId": threadId,
            "input": input,
            "approvalPolicy": "on-request",
            "sandboxPolicy": sandboxPolicy
        ]
        if let model {
            params["model"] = model
        }
        _ = try await client.request(method: "turn/start", params: params)
    }

    public func interrupt(turnId: String?) async {
        guard let threadId, let turnId else { return }
        _ = try? await client.request(
            method: "turn/interrupt", params: ["threadId": threadId, "turnId": turnId])
    }

    public func newChat() async throws {
        if let threadId {
            _ = try? await client.request(
                method: "thread/archive", params: ["threadId": threadId])
        }
        threadId = nil
        try? NoteRecordingState.update(noteFolder: noteFolderURL) { $0.chatThreadId = nil }
        try await startFreshThread()
    }

    public func resolveApproval(id: UUID, decision: String) {
        guard let waiting = pendingApprovals.removeValue(forKey: id) else { return }
        waiting.resume(returning: decision)
        continuation?.yield(.approvalSettled(id))
    }

    // MARK: - wiring

    private func bindHandlers() async throws {
        guard !bound else { return }
        bound = true
        await client.addNotificationHandler { [weak self] method, paramsData in
            guard
                let params = (try? JSONSerialization.jsonObject(with: paramsData))
                    as? [String: Any],
                let parsed = ChatEventParser.parse(method: method, params: params)
            else { return }
            Task { await self?.forward(threadId: parsed.threadId, event: parsed.event) }
        }
        await client.addServerRequestHandler { [weak self] method, paramsData in
            guard let self else { return .notMine }
            return await self.handleServerRequest(method: method, paramsData: paramsData)
        }
    }

    private func forward(threadId: String, event: ChatEvent) {
        guard threadId == self.threadId else { return }
        if case .turnCompleted = event {
            // A turn that ends with approvals still pending (interrupt,
            // failure) must not leave the server request hanging.
            for (id, waiting) in pendingApprovals {
                waiting.resume(returning: "cancel")
                continuation?.yield(.approvalSettled(id))
            }
            pendingApprovals.removeAll()
        }
        continuation?.yield(.event(event))
    }

    private func handleServerRequest(
        method: String, paramsData: Data
    ) async -> AppServerClient.ServerRequestReply {
        guard
            method == "item/commandExecution/requestApproval"
                || method == "item/fileChange/requestApproval",
            let params = (try? JSONSerialization.jsonObject(with: paramsData)) as? [String: Any],
            params["threadId"] as? String == threadId,
            let itemId = params["itemId"] as? String
        else { return .notMine }

        let kind: ChatApprovalRequest.Kind =
            method == "item/commandExecution/requestApproval"
            ? .commandExecution(
                command: params["command"] as? String ?? "",
                cwd: params["cwd"] as? String,
                reason: params["reason"] as? String)
            : .fileChange(
                files: [], reason: params["reason"] as? String)
        let request = ChatApprovalRequest(id: UUID(), itemId: itemId, kind: kind)
        let decision = await withCheckedContinuation { waiting in
            pendingApprovals[request.id] = waiting
            continuation?.yield(.approvalRequested(request))
        }
        return .result(["decision": decision])
    }

    private func startFreshThread() async throws {
        let resultData = try await client.request(
            method: "thread/start", params: ["cwd": homeRootURL.path])
        let result = (try? JSONSerialization.jsonObject(with: resultData)) as? [String: Any]
        guard let thread = result?["thread"] as? [String: Any],
            let id = thread["id"] as? String
        else { throw AppServerClient.ClientError.malformedResponse }
        threadId = id
        // Naming forces rollout persistence (M1 spike gotcha #2) and is the
        // user's handle in the ChatGPT app's history.
        _ = try await client.request(
            method: "thread/name/set",
            params: ["threadId": id, "name": "\(noteFolderURL.lastPathComponent) — chat"])
        try? NoteRecordingState.update(noteFolder: noteFolderURL) { $0.chatThreadId = id }

        let relativePath = CodexChat.notePath(
            noteFolderURL: noteFolderURL, homeRootURL: homeRootURL)
        let prompt = """
            The user wants to discuss the note at `\(relativePath)`. Read its \
            `note.md`, `transcript.vtt`, and `context/*.md` (whatever exists), \
            then answer their next message.
            """
        var params: [String: any Sendable] = [
            "threadId": id,
            "input": [["type": "text", "text": prompt, "text_elements": [String]()]]
                as [[String: any Sendable]]
        ]
        if let model {
            params["model"] = model
        }
        _ = try await client.request(method: "turn/start", params: params)
    }

    /// `thread/read` → ordered ChatItems. Defensive: absent turns/items are
    /// an empty history, never an error.
    public static func history(fromThreadReadResult data: Data) -> [ChatItem] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let thread = object["thread"] as? [String: Any],
            let turns = thread["turns"] as? [[String: Any]]
        else { return [] }
        return turns.flatMap { turn in
            (turn["items"] as? [[String: Any]] ?? []).compactMap(ChatEventParser.item(from:))
        }
    }
}
```

Notes for the implementer:
- The file-change approval `files` list is empty because the wire request doesn't carry `changes`; the matching `fileChange` item row (same `itemId`) shows the files. Keep the card generic: "Codex wants to edit files".
- `interrupt(turnId:)` takes the turnId because the transcript reducer (ChatModel) tracks `activeTurnId`; the session stays stateless about turns.
- The Task 5 interface listed `interrupt()` — the implemented signature is `interrupt(turnId: String?)`; Tasks 7/8 use this signature.

- [ ] **Step 4: Run tests, full build**

Run: `cd Packages/SimbiKit && swift build && swift test --filter "ChatSession"`
Expected: build succeeds, 2 tests PASS.

- [ ] **Step 5: Lint + commit**

```bash
swiftlint --quiet
git add Packages/SimbiKit/Sources/CodexKit/ChatSession.swift \
        Packages/SimbiKit/Tests/CodexKitTests/ChatSessionTests.swift
git commit -m "Add ChatSession actor: resume-or-create, streaming, approvals"
```

---

### Task 6: Markdown fence segmentation + chat markdown view

Agent messages are markdown. `swift-markdown-engine`'s view is an editing NSScrollView (wrong tool for chat rows: nested scroll views, editor chrome). v1 renders: fenced code blocks as monospaced boxes, everything else through `AttributedString(markdown:)` with `.inlineOnlyPreservingWhitespace` (bold/italic/links/inline code render; heading/list markers stay as literal text — acceptable for v1, matches the spec's "no bubbles, agent console" bar).

**Files:**
- Create: `Packages/SimbiKit/Sources/CodexKit/MarkdownSegmenter.swift` (pure, testable)
- Create: `Packages/SimbiKit/Sources/SimbiUI/ChatMarkdownView.swift`
- Test: `Packages/SimbiKit/Tests/CodexKitTests/MarkdownSegmenterTests.swift`

**Interfaces:**
- Produces: `public enum MarkdownSegment: Equatable, Sendable { case text(String); case code(language: String?, body: String) }`, `public enum MarkdownSegmenter { public static func segments(_ markdown: String) -> [MarkdownSegment] }`.
- Produces: `ChatMarkdownView(markdown: String)` (internal SwiftUI view).

- [ ] **Step 1: Write failing segmenter tests**

```swift
import Testing

@testable import CodexKit

@Suite("MarkdownSegmenter")
struct MarkdownSegmenterTests {
    @Test("splits fenced code out of prose")
    func fences() {
        let segments = MarkdownSegmenter.segments(
            "Before\n```swift\nlet x = 1\n```\nAfter")
        #expect(segments == [
            .text("Before"),
            .code(language: "swift", body: "let x = 1"),
            .text("After")
        ])
    }

    @Test("unterminated fence swallows the rest as code")
    func unterminated() {
        #expect(MarkdownSegmenter.segments("hi\n```\nstill code") == [
            .text("hi"), .code(language: nil, body: "still code")
        ])
    }

    @Test("plain text is one segment; empty is none")
    func plain() {
        #expect(MarkdownSegmenter.segments("just words") == [.text("just words")])
        #expect(MarkdownSegmenter.segments("").isEmpty)
        #expect(MarkdownSegmenter.segments("  \n").isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/SimbiKit && swift test --filter MarkdownSegmenter`
Expected: compile FAILURE.

- [ ] **Step 3: Implement MarkdownSegmenter.swift**

```swift
import Foundation

/// A chat message split at ``` fences so code renders monospaced while
/// prose goes through AttributedString markdown.
public enum MarkdownSegment: Equatable, Sendable {
    case text(String)
    case code(language: String?, body: String)
}

public enum MarkdownSegmenter {
    public static func segments(_ markdown: String) -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        var textLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCode = false

        func flushText() {
            let text = textLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { segments.append(.text(text)) }
            textLines = []
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    segments.append(
                        .code(language: codeLanguage, body: codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCode = false
                } else {
                    flushText()
                    let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    codeLanguage = language.isEmpty ? nil : language
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(String(line))
            } else {
                textLines.append(String(line))
            }
        }
        if inCode {
            segments.append(
                .code(language: codeLanguage, body: codeLines.joined(separator: "\n")))
        } else {
            flushText()
        }
        return segments
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `cd Packages/SimbiKit && swift test --filter MarkdownSegmenter`
Expected: 3 tests PASS.

- [ ] **Step 5: Implement ChatMarkdownView.swift (SimbiUI)**

```swift
import CodexKit
import SwiftUI

/// Renders one agent message: prose via AttributedString markdown (inline
/// styling, preserved line breaks), fenced code as monospaced blocks.
struct ChatMarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownSegmenter.segments(markdown).enumerated()), id: \.offset) {
                _, segment in
                switch segment {
                case .text(let text):
                    Text(Self.attributed(text))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(_, let body):
                    ScrollView(.horizontal) {
                        Text(body)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
```

- [ ] **Step 6: Build + lint + commit**

Run: `cd Packages/SimbiKit && swift build`
Expected: builds clean.

```bash
swiftlint --quiet
git add Packages/SimbiKit/Sources/CodexKit/MarkdownSegmenter.swift \
        Packages/SimbiKit/Sources/SimbiUI/ChatMarkdownView.swift \
        Packages/SimbiKit/Tests/CodexKitTests/MarkdownSegmenterTests.swift
git commit -m "Add chat markdown rendering: fence segmentation + view"
```

---

### Task 7: ChatModel, ChatWindow scene, transcript + composer

**Files:**
- Create: `Packages/SimbiKit/Sources/SimbiUI/ChatModel.swift`
- Create: `Packages/SimbiKit/Sources/SimbiUI/ChatView.swift`
- Modify: `App/SimbiApp.swift` (add the WindowGroup)
- Modify: `Packages/SimbiKit/Sources/SimbiUI/NoteView.swift` (toolbar button → openWindow; delete deeplink)

**Interfaces:**
- Consumes: `ChatSession`, `ChatSessionEvent`, `ChatTranscript`, `ChatApprovalRequest` (Tasks 3/5), `ChatMarkdownView` (Task 6), `CodexServices.appServer` (existing, `FilesModel.swift`), `SimbiSettings.chatModel`, `Design`, `StatusBanner`.
- Produces: `public struct ChatWindow: View { public static let windowId = "note-chat"; public init(noteFolderURL: URL) }`; `ChatModel.shared(noteFolderURL:)` with `transcript: ChatTranscript`, `pendingApprovals: [ChatApprovalRequest]`, `phase: Phase` (`.connecting`, `.ready`, `.unavailable(String)`), `composerText: String`, `func start()`, `func sendCurrentMessage()`, `func interrupt()`, `func newChat()`, `func respond(to: ChatApprovalRequest, decision: String)` (used by Task 8's approval card).

- [ ] **Step 1: Implement ChatModel.swift**

```swift
import CodexKit
import Foundation
import Observation
import SimbiKit

/// UI model for one note's chat window. Shared per note (like FilesModel)
/// so the conversation survives window close/reopen within a session.
@MainActor
@Observable
final class ChatModel {
    enum Phase: Equatable {
        case connecting
        case ready
        case unavailable(String)
    }

    private static var models: [URL: ChatModel] = [:]

    static func shared(noteFolderURL: URL) -> ChatModel {
        if let existing = models[noteFolderURL] { return existing }
        let model = ChatModel(noteFolderURL: noteFolderURL)
        models[noteFolderURL] = model
        return model
    }

    private(set) var transcript = ChatTranscript()
    private(set) var pendingApprovals: [ChatApprovalRequest] = []
    private(set) var phase: Phase = .connecting
    var composerText = ""

    let noteFolderURL: URL
    private let session: ChatSession
    private var started = false

    private init(noteFolderURL: URL) {
        self.noteFolderURL = noteFolderURL
        let settings =
            (try? SimbiSettings.load(from: SimbiHome().settingsFileURL)) ?? .default
        self.session = ChatSession(
            noteFolderURL: noteFolderURL,
            homeRootURL: SimbiHome().rootURL,
            client: CodexServices.appServer,
            model: settings.chatModel)
    }

    /// Idempotent; called from the window's .task.
    func start() {
        guard !started else { return }
        started = true
        guard CodexInstallation.standard.isBinaryInstalled else {
            phase = .unavailable(
                "ChatGPT app not found — chat needs the bundled codex app-server.")
            return
        }
        Task {
            let events = await session.events()
            Task { [weak self] in
                for await event in events {
                    self?.handle(event)
                }
            }
            do {
                let history = try await session.ensureThread()
                transcript = ChatTranscript(history: history)
                phase = .ready
            } catch {
                phase = .unavailable("Could not reach the Codex app-server.")
            }
        }
    }

    func sendCurrentMessage() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, phase == .ready, !transcript.turnActive else { return }
        composerText = ""
        transcript.appendLocalUser(text: text)
        Task {
            do {
                try await session.send(text)
            } catch {
                transcript.appendBanner("Sending failed — the app-server may be restarting.")
            }
        }
    }

    func interrupt() {
        let turnId = transcript.activeTurnId
        Task { await session.interrupt(turnId: turnId) }
    }

    func newChat() {
        transcript = ChatTranscript()
        pendingApprovals = []
        phase = .connecting
        Task {
            do {
                try await session.newChat()
                phase = .ready
            } catch {
                phase = .unavailable("Could not start a new chat thread.")
            }
        }
    }

    func respond(to approval: ChatApprovalRequest, decision: String) {
        pendingApprovals.removeAll { $0.id == approval.id }
        Task { await session.resolveApproval(id: approval.id, decision: decision) }
    }

    private func handle(_ event: ChatSessionEvent) {
        switch event {
        case .event(let chatEvent):
            transcript.apply(chatEvent)
        case .approvalRequested(let request):
            pendingApprovals.append(request)
        case .approvalSettled(let id):
            pendingApprovals.removeAll { $0.id == id }
        }
    }
}
```

- [ ] **Step 2: Implement ChatView.swift (window, transcript, composer, autoscroll)**

```swift
import CodexKit
import SimbiKit
import SwiftUI

/// The per-note chat window (SPEC.md §5.4): transcript of the note's
/// persistent Codex thread + composer. The app shell declares the matching
/// WindowGroup scene.
public struct ChatWindow: View {
    public static let windowId = "note-chat"

    @State private var model: ChatModel
    private let noteName: String

    public init(noteFolderURL: URL) {
        self._model = State(initialValue: ChatModel.shared(noteFolderURL: noteFolderURL))
        self.noteName = noteFolderURL.lastPathComponent
    }

    public var body: some View {
        ChatView(model: model)
            .navigationTitle("Chat — \(noteName)")
            .frame(minWidth: 380, idealWidth: 480, minHeight: 420, idealHeight: 620)
            .task { model.start() }
    }
}

struct ChatView: View {
    @Bindable var model: ChatModel
    /// True while the transcript is scrolled to (near) the bottom; new
    /// content auto-follows only then, so reading back never fights the
    /// stream.
    @State private var pinnedToBottom = true

    private static let bottomId = "chat-bottom"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if case .unavailable(let message) = model.phase {
                StatusBanner(message: message)
                Divider()
            }
            transcript
            Divider()
            ChatComposer(model: model)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if model.transcript.turnActive {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            Button("New Chat") {
                model.newChat()
            }
            .disabled(model.phase != .ready)
            .help("Archive this conversation and start a fresh one")
        }
        .padding(.horizontal, Design.paneInset)
        .padding(.vertical, 8)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Design.rowGap) {
                    if model.transcript.rows.isEmpty && model.phase == .ready {
                        Text("Ask Codex about this note.")
                            .font(.meta)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(model.transcript.rows) { row in
                        ChatRowView(row: row)
                    }
                    ForEach(model.pendingApprovals) { approval in
                        ChatApprovalCard(approval: approval, model: model)
                    }
                    // Bottom sentinel: measures distance to the viewport
                    // bottom to know whether the user is following along.
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ChatBottomOffsetKey.self,
                            value: geometry.frame(in: .named("chat-scroll")).minY)
                    }
                    .frame(height: 1)
                    .id(Self.bottomId)
                }
                .padding(Design.paneInset)
            }
            .coordinateSpace(name: "chat-scroll")
            .onPreferenceChange(ChatBottomOffsetKey.self) { bottomY in
                // Grace band so tiny bounces don't unpin.
                pinnedToBottom = bottomY < scrollViewportHeight + 80
            }
            .background(alignment: .bottomTrailing) {
                if !pinnedToBottom {
                    jumpToLatest(proxy: proxy)
                }
            }
            .onChange(of: model.transcript.rows) {
                if pinnedToBottom {
                    proxy.scrollTo(Self.bottomId, anchor: .bottom)
                }
            }
            .onChange(of: model.pendingApprovals.count) {
                if pinnedToBottom {
                    proxy.scrollTo(Self.bottomId, anchor: .bottom)
                }
            }
        }
    }

    /// Viewport height for the pin heuristic; a fixed generous estimate
    /// works because the sentinel's minY goes far beyond it when scrolled
    /// up. Refined only if verification shows misbehavior.
    private var scrollViewportHeight: CGFloat { 700 }

    private func jumpToLatest(proxy: ScrollViewProxy) -> some View {
        Button {
            proxy.scrollTo(Self.bottomId, anchor: .bottom)
        } label: {
            Label("Latest", systemImage: "arrow.down")
                .font(.meta)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(12)
    }
}

private struct ChatBottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ChatComposer: View {
    @Bindable var model: ChatModel
    @FocusState private var focused: Bool

    private var sendDisabled: Bool {
        model.phase != .ready
            || model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Codex…", text: $model.composerText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit { model.sendCurrentMessage() }
                .onKeyPress(.return, phases: .down) { press in
                    // Shift+Return inserts a newline; plain Return submits
                    // (handled by onSubmit).
                    if press.modifiers.contains(.shift) {
                        model.composerText += "\n"
                        return .handled
                    }
                    return .ignored
                }
                .disabled(model.phase != .ready)
            if model.transcript.turnActive {
                Button {
                    model.interrupt()
                } label: {
                    Image(systemName: "stop.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Stop this turn")
            } else {
                Button {
                    model.sendCurrentMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderless)
                .disabled(sendDisabled)
                .help("Send (Return)")
            }
        }
        .padding(Design.paneInset)
        .onAppear { focused = true }
    }
}
```

(`ChatRowView` and `ChatApprovalCard` are Task 8 — to keep this task buildable, add them as minimal placeholders in ChatView.swift now: `ChatRowView` renders `.user`/`.agent` with `Text`/`ChatMarkdownView` and everything else as `Text(row.id)`; `ChatApprovalCard` is `EmptyView()`-bodied. Task 8 replaces both with the real implementations in `ChatRows.swift` and deletes the placeholders.)

- [ ] **Step 3: Add the scene and switch the toolbar button**

`App/SimbiApp.swift` — after the fixer WindowGroup:

```swift
        // Per-note chat window (SPEC.md §5.4): the note's persistent Codex
        // conversation, opened from the note toolbar.
        WindowGroup("Chat", id: ChatWindow.windowId, for: URL.self) { $url in
            if let url {
                ChatWindow(noteFolderURL: url)
            }
        }
        .defaultSize(width: 480, height: 620)
```

`NoteView.swift`: delete the `chatStatus` property, the `ChatStatus` enum, and the entire deeplink `chatButton` body. Replace with:

```swift
    @Environment(\.openWindow) private var openWindow

    /// In-app chat (SPEC.md §5.4): one persistent Codex thread per note,
    /// one window per note; reopening focuses it.
    private var chatButton: some View {
        Button {
            openWindow(id: ChatWindow.windowId, value: document.noteFolderURL)
        } label: {
            Label("Chat", systemImage: "bubble.left.and.bubble.right")
        }
        .help("Chat with Codex about this note")
    }
```

(Keep the `import CodexKit` — `degradedBanner` still uses `CodexInstallation`.)

- [ ] **Step 4: Build package and app**

Run: `cd Packages/SimbiKit && swift build && swift test`
Expected: builds, all tests pass.

Run: `cd /Users/andyye/dev/simbi && xcodebuild -project Simbi.xcodeproj -scheme Simbi -configuration Debug build 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Lint + commit**

```bash
swiftlint --quiet
git add Packages/SimbiKit/Sources/SimbiUI/ChatModel.swift \
        Packages/SimbiKit/Sources/SimbiUI/ChatView.swift \
        Packages/SimbiKit/Sources/SimbiUI/NoteView.swift \
        App/SimbiApp.swift
git commit -m "Add in-app chat window: model, transcript, composer"
```

---

### Task 8: Chat rows + approval cards

**Files:**
- Create: `Packages/SimbiKit/Sources/SimbiUI/ChatRows.swift`
- Modify: `Packages/SimbiKit/Sources/SimbiUI/ChatView.swift` (delete the Task 7 placeholders)

**Interfaces:**
- Consumes: `ChatTranscript.Row`, `ChatApprovalRequest`, `ChatModel.respond(to:decision:)`, `ChatMarkdownView`, `Design`, `Font.meta`.
- Produces: `ChatRowView(row: ChatTranscript.Row)`, `ChatApprovalCard(approval: ChatApprovalRequest, model: ChatModel)`.

- [ ] **Step 1: Implement ChatRows.swift**

```swift
import CodexKit
import SwiftUI

/// One transcript row. Agent-console styling: full-width, quiet tints, no
/// messenger bubbles (SPEC §2).
struct ChatRowView: View {
    let row: ChatTranscript.Row

    var body: some View {
        switch row {
        case .user(_, let text):
            VStack(alignment: .leading, spacing: 3) {
                Text("You")
                    .font(.metaSemibold)
                    .foregroundStyle(.secondary)
                Text(text)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        case .agent(_, let markdown, let streaming):
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text("Codex")
                        .font(.metaSemibold)
                        .foregroundStyle(.secondary)
                    if streaming {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                ChatMarkdownView(markdown: markdown)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .command(_, let command, let status, let output):
            DisclosureGroup {
                if let output, !output.isEmpty {
                    ScrollView(.horizontal) {
                        Text(output)
                            .font(.meta.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                    .frame(maxHeight: 160)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                } else {
                    Text("No output.")
                        .font(.meta)
                        .foregroundStyle(.tertiary)
                }
            } label: {
                HStack(spacing: 6) {
                    statusDot(status)
                    Text(command)
                        .font(.meta.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.meta)
        case .fileChange(_, let files, let status):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                statusDot(status)
                Image(systemName: "doc.badge.gearshape")
                    .font(.meta)
                    .foregroundStyle(.secondary)
                Text(files.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                    .font(.meta)
                    .lineLimit(2)
            }
        case .quiet(_, let text):
            Text(text)
                .font(.meta)
                .foregroundStyle(.tertiary)
        case .banner(_, let text):
            StatusBanner(message: text)
        }
    }

    /// Green = done, orange = failed-ish, secondary = in flight. Red stays
    /// reserved for recording.
    private func statusDot(_ status: String) -> some View {
        Circle()
            .fill(
                status == "completed"
                    ? Color.green
                    : status == "failed" || status == "declined" ? Color.orange : Color.secondary)
            .frame(width: 6, height: 6)
    }
}

/// Inline approval prompt: what Codex wants to do + the three decisions.
/// Rendered at the transcript tail while the server request is suspended.
struct ChatApprovalCard: View {
    let approval: ChatApprovalRequest
    let model: ChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                Text(title)
                    .font(.metaSemibold)
            }
            switch approval.kind {
            case .commandExecution(let command, let cwd, let reason):
                ScrollView(.horizontal) {
                    Text(command)
                        .font(.meta.monospaced())
                        .textSelection(.enabled)
                }
                if let cwd {
                    Text("in \(cwd)")
                        .font(.meta)
                        .foregroundStyle(.tertiary)
                }
                if let reason {
                    Text(reason)
                        .font(.meta)
                        .foregroundStyle(.secondary)
                }
            case .fileChange(_, let reason):
                if let reason {
                    Text(reason)
                        .font(.meta)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Button("Allow") {
                    model.respond(to: approval, decision: "accept")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Allow for Session") {
                    model.respond(to: approval, decision: "acceptForSession")
                }
                .controlSize(.small)
                Button("Deny") {
                    model.respond(to: approval, decision: "decline")
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.orange.opacity(0.35)))
    }

    private var title: String {
        switch approval.kind {
        case .commandExecution: "Codex wants to run a command"
        case .fileChange: "Codex wants to edit files"
        }
    }
}
```

- [ ] **Step 2: Delete the Task 7 placeholders from ChatView.swift**

Remove the placeholder `ChatRowView`/`ChatApprovalCard` structs added at the end of Task 7's ChatView.swift; the real ones now live in ChatRows.swift.

- [ ] **Step 3: Build package and app**

Run: `cd Packages/SimbiKit && swift build && swift test`
Expected: builds, tests pass.

Run: `cd /Users/andyye/dev/simbi && xcodebuild -project Simbi.xcodeproj -scheme Simbi -configuration Debug build 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Lint + commit**

```bash
swiftlint --quiet
git add Packages/SimbiKit/Sources/SimbiUI/ChatRows.swift \
        Packages/SimbiKit/Sources/SimbiUI/ChatView.swift
git commit -m "Add chat row views and inline approval cards"
```

---

### Task 9: Retire the deeplink path + update SPEC.md

**Files:**
- Modify: `Packages/SimbiKit/Sources/CodexKit/CodexChat.swift` (delete `startChat`, keep `notePath` + `CodexModels`)
- Modify: `SPEC.md` (§5.4, and the §6 UI section)

**Interfaces:**
- Consumes: nothing new. `CodexChat.notePath` remains (used by `ChatSession`); `CodexChatTests.relativeNotePath` still covers it.

- [ ] **Step 1: Delete `CodexChat.startChat`**

Remove the `startChat` function and its doc comment from `CodexChat.swift`; update the file's header comment to say the chat thread lifecycle lives in `ChatSession` and this file keeps the shared path helper + model discovery. Keep `notePath` and `CodexModels` unchanged.

- [ ] **Step 2: Verify nothing references it**

Run: `grep -rn "startChat\|codex://threads" /Users/andyye/dev/simbi/App /Users/andyye/dev/simbi/Packages/SimbiKit/Sources`
Expected: no matches. (The `simbi-chat-spike` target references `startChat` — update the spike to use `ChatSession` minimally: `let session = ChatSession(noteFolderURL:..., homeRootURL:..., client: client, model: nil); _ = try await session.ensureThread()`, keep its turn-completed wait and thread/resume verification via the persisted `NoteRecordingState` id, or simply delete the spike's startChat call in favor of `ensureThread()`. The spike must still compile: `swift build` builds all targets.)

- [ ] **Step 3: Update SPEC.md §5.4**

Rewrite the §5.4 block (currently "Chat in Codex", `SPEC.md:398-410`) to describe: in-app per-note chat window; one persistent thread per note stored as `chatThreadId` in `.simbi/state.json`; resume-or-create on open (`thread/resume` + `thread/read includeTurns` hydration, fresh `thread/start` at the HOME root + name + context turn otherwise); turns run `approvalPolicy: on-request` + `sandboxPolicy: workspaceWrite` (cwd-rooted) with approvals answered from inline cards; New Chat archives and recreates; threads remain browsable in the ChatGPT app (same cwd/name conventions, never archived except by New Chat). Update §6's UI inventory to add the chat window row types. Update the v0.6 version header if SPEC convention bumps it (check the file's changelog pattern; bump to v0.7 with a one-line changelog entry if one exists).

- [ ] **Step 4: Full test run + lint + commit**

Run: `cd Packages/SimbiKit && swift build && swift test`
Expected: all pass (spike compiles).

```bash
swiftlint --quiet
git add Packages/SimbiKit/Sources/CodexKit/CodexChat.swift \
        Packages/SimbiKit/Sources/simbi-chat-spike/main.swift SPEC.md
git commit -m "Retire the Chat-in-Codex deeplink; spec the in-app chat"
```

---

### Task 10: End-to-end verification

**Files:**
- Create: `docs/verification/2026-07-21-in-app-chat/` (evidence)

- [ ] **Step 1: Full headless test pass**

Run: `cd Packages/SimbiKit && swift test`
Expected: every suite passes.

- [ ] **Step 2: UI verification via the project's verify flow**

Use the `verify` skill (build, kill any stale app instance first — check process start time — then launch fresh). Verify, with screenshots saved to `docs/verification/2026-07-21-in-app-chat/`:

1. Toolbar "Chat" button opens the chat window titled "Chat — <note>".
2. Sending a message shows the user row instantly, then a streaming Codex reply (markdown rendered, code fenced if the reply has any — ask "reply with a swift code block that prints hi").
3. Close and reopen the window, and relaunch the app: the same conversation is restored (the original bug's fix — verify `.simbi/state.json` now contains `chatThreadId`, and the reopened window shows prior turns).
4. Approval flow: ask "run `git status` in this folder and tell me what you see" — an approval card should appear (on-request policy); Deny it; the turn continues/completes and the card collapses. Then repeat with Allow.
5. New Chat archives and starts clean.
6. The scroll pin: scroll up mid-stream, confirm the "Latest" pill appears and the view does not yank to the bottom.

Constraints from project memory: never play audio in tests; UI evidence lives under `docs/verification/`; kill stale app before checks.

- [ ] **Step 3: Write the verification note**

`docs/verification/2026-07-21-in-app-chat/notes.md` summarizing each check with its screenshot; note any deviations found and fixed.

- [ ] **Step 4: Commit evidence**

```bash
git add docs/verification/2026-07-21-in-app-chat
git commit -m "Verify in-app chat end to end"
```

---

## Self-Review (completed)

- **Spec coverage:** server-request path → T1; events/streaming → T2/T3; persistence → T4; session/resume/approvals/new-chat → T5; markdown → T6; window/model/composer/autoscroll → T7; rows/approval cards → T8; deeplink removal + SPEC → T9; tests/verification → T10. Error handling: turn-failure banners (T3), send-failure banner + unavailable phase (T7), resume-fallback (T5), pending-approval cancellation on turn end (T5).
- **Known simplifications vs spec (accepted):** heading/list markers render literally in v1 prose (T6 notes why); viewport-height heuristic for scroll pinning is a constant with a wide grace band (T7 notes it's refined only if verification shows misbehavior).
- **Type consistency:** `ChatSession.interrupt(turnId:)` (T5 note) matches T7's call; `ServerRequestReply` (T1) matches T5's handler; `ChatTranscript.Row` cases match T8's switch; `ChatApprovalRequest` fields match T8's card.
