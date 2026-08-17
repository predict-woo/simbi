import Foundation
import Testing

@testable import CodexKit

@Suite("CodexTurn helpers")
struct CodexTurnTests {
    @Test("startParams builds the shared turn/start shape")
    func startParamsShape() {
        let params = CodexTurn.startParams(
            threadId: "thr_1", text: "fix cues",
            writableRoot: URL(filePath: "/tmp/note/.simbi/fixer-worktree"),
            model: "gpt-5.4", effort: "high")
        #expect(params["threadId"] as? String == "thr_1")
        #expect(params["approvalPolicy"] as? String == "never")
        let input = params["input"] as? [[String: any Sendable]]
        #expect(input?.first?["text"] as? String == "fix cues")
        let sandbox = params["sandboxPolicy"] as? [String: any Sendable]
        #expect(sandbox?["type"] as? String == "workspaceWrite")
        #expect(
            sandbox?["writableRoots"] as? [String] == ["/tmp/note/.simbi/fixer-worktree"])
        #expect(params["model"] as? String == "gpt-5.4")
    }

    @Test("startParams without a writable root inherits the thread sandbox")
    func startParamsNoRoot() {
        let params = CodexTurn.startParams(
            threadId: "thr_1", text: "title it", writableRoot: nil, model: nil, effort: nil)
        #expect(!params.keys.contains("sandboxPolicy"))
        #expect(!params.keys.contains("model"))
    }

    @Test("thread/start result parses to the thread id")
    func threadIdParse() throws {
        let good = Data(#"{"thread": {"id": "thr_9"}}"#.utf8)
        #expect(try CodexTurn.threadId(fromStartResult: good) == "thr_9")

        let bad = Data(#"{"thread": {}}"#.utf8)
        #expect(throws: CodexWorkerError.self) {
            try CodexTurn.threadId(fromStartResult: bad)
        }
    }
}

@Suite("WorkerOutput")
struct WorkerOutputTests {
    @Test("exists means present and non-empty")
    func existsCheck() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "worker-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let missing = dir.appending(path: "missing.md")
        #expect(!WorkerOutput.exists(at: missing))

        let empty = dir.appending(path: "empty.md")
        try Data().write(to: empty)
        #expect(!WorkerOutput.exists(at: empty))

        let real = dir.appending(path: "real.md")
        try Data("content".utf8).write(to: real)
        #expect(WorkerOutput.exists(at: real))
    }
}
