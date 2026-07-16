// M7 spike: real chat-in-codex round-trip (SPEC.md §5.4) + model list
// (§5.5) against the real app-server. Starts the chat thread at the HOME
// root, verifies the name and the context turn, fetches model/list, then
// archives the thread purely as spike hygiene (the app itself NEVER
// archives chat threads).

import CodexKit
import Foundation
import SimbiKit

func fail(_ step: String, _ message: String) -> Never {
    print("FAIL \(step): \(message)")
    exit(1)
}

let home = SimbiHome()
let noteFolder = home.rootURL.appending(path: "M5 Files Demo")
guard FileManager.default.fileExists(atPath: noteFolder.path) else {
    fail("setup", "expected demo note at \(noteFolder.path)")
}

let client = AppServerClient()

print("model/list…")
let models = try await CodexModels.list(client: client)
guard !models.isEmpty else { fail("models", "model/list returned nothing") }
print("PASS models: \(models.count) available — \(models.joined(separator: ", "))")

print("starting chat thread (real app-server)…")
let threadId = try await CodexChat.startChat(
    noteFolderURL: noteFolder, homeRootURL: home.rootURL, client: client)
print("chat thread: \(threadId)")

// The context turn is running; wait for turn/completed.
let completed = AsyncStream.makeStream(of: Void.self)
await client.addNotificationHandler { method, params in
    guard method == "turn/completed",
        let object = (try? JSONSerialization.jsonObject(with: params)) as? [String: Any],
        object["threadId"] as? String == threadId
    else { return }
    completed.continuation.yield()
}
print("waiting for the context turn (up to 4 min)…")
let turnDone = await withTaskGroup(of: Bool.self) { group in
    group.addTask {
        for await _ in completed.stream { return true }
        return false
    }
    group.addTask {
        try? await Task.sleep(for: .seconds(240))
        return false
    }
    let first = await group.next() ?? false
    group.cancelAll()
    return first
}
guard turnDone else { fail("turn", "context turn never completed") }

// Verify the thread persisted under the right name and cwd.
let resumeData = try await client.request(
    method: "thread/resume", params: ["threadId": threadId])
let resume = (try? JSONSerialization.jsonObject(with: resumeData)) as? [String: Any]
let thread = resume?["thread"] as? [String: Any]
guard thread?["name"] as? String == "M5 Files Demo — chat" else {
    fail("name", "thread name wrong: \(thread?["name"] ?? "nil")")
}
guard (thread?["cwd"] as? String) == home.rootURL.path else {
    fail("cwd", "thread cwd wrong: \(thread?["cwd"] ?? "nil")")
}
let turns = (thread?["turns"] as? [[String: Any]]) ?? []
print("PASS chat: named \"M5 Files Demo — chat\", cwd = home root, \(turns.count) turn(s)")
print("deeplink would be: codex://threads/\(threadId)")

// Spike hygiene only — the app never archives chat threads (§5.4).
_ = try? await client.request(method: "thread/archive", params: ["threadId": threadId])
print("OVERALL: PASS")
