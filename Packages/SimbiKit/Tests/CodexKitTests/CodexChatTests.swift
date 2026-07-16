import Foundation
import Testing

@testable import CodexKit

@Suite("CodexChat")
struct CodexChatTests {
    @Test("note path is relative to the home root")
    func relativeNotePath() {
        let home = URL(filePath: "/Users/u/Simbi")
        #expect(
            CodexChat.notePath(
                noteFolderURL: URL(filePath: "/Users/u/Simbi/Work/ProjectX/Standup"),
                homeRootURL: home) == "Work/ProjectX/Standup")
        // Outside the home root: absolute path passthrough (still correct
        // for the agent, whose cwd is the home root).
        #expect(
            CodexChat.notePath(
                noteFolderURL: URL(filePath: "/tmp/Elsewhere"), homeRootURL: home)
                == "/tmp/Elsewhere")
    }

    @Test("model list parses the shapes the server might send")
    func modelListShapes() {
        #expect(
            CodexModels.parse(Data(#"{"models":[{"id":"gpt-5.6"},{"id":"gpt-5.6-mini"}]}"#.utf8))
                == ["gpt-5.6", "gpt-5.6-mini"])
        #expect(CodexModels.parse(Data(#"{"models":["a","b"]}"#.utf8)) == ["a", "b"])
        #expect(CodexModels.parse(Data(#"["x",{"slug":"y"}]"#.utf8)) == ["x", "y"])
        #expect(CodexModels.parse(Data(#"{"nope":1}"#.utf8)).isEmpty)
    }
}
