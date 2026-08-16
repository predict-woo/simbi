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
                .map(\.id) == ["gpt-5.6", "gpt-5.6-mini"])
        #expect(CodexModels.parse(Data(#"{"models":["a","b"]}"#.utf8)).map(\.id) == ["a", "b"])
        #expect(CodexModels.parse(Data(#"["x",{"slug":"y"}]"#.utf8)).map(\.id) == ["x", "y"])
        #expect(CodexModels.parse(Data(#"{"nope":1}"#.utf8)).isEmpty)
    }

    /// The live app-server (codex 0.148) shape: `data`-keyed, with per-model
    /// reasoning efforts.
    @Test("model list parses reasoning efforts and the default marker")
    func modelListEfforts() throws {
        let json = #"""
            {"data":[
              {"id":"gpt-5.6-sol","displayName":"GPT-5.6-Sol","hidden":false,
               "supportedReasoningEfforts":[
                 {"reasoningEffort":"low","description":"Fast"},
                 {"reasoningEffort":"ultra","description":"Maximum"}],
               "defaultReasoningEffort":"low","isDefault":true},
              {"id":"gpt-5.5",
               "supportedReasoningEfforts":[{"reasoningEffort":"medium"}],
               "isDefault":false}
            ]}
            """#
        let models = CodexModels.parse(Data(json.utf8))
        let sol = try #require(models.first)
        #expect(sol.id == "gpt-5.6-sol")
        #expect(sol.supportedEfforts.map(\.id) == ["low", "ultra"])
        #expect(sol.supportedEfforts.first?.description == "Fast")
        #expect(sol.defaultEffort == "low")
        #expect(sol.isDefault)
        // Missing effort metadata degrades to empty, not a parse failure.
        let bare = try #require(models.last)
        #expect(bare.supportedEfforts.map(\.id) == ["medium"])
        #expect(bare.supportedEfforts.first?.description == nil)
        #expect(bare.defaultEffort == nil)
        #expect(!bare.isDefault)
    }

    @Test("efforts follow the selected model; nil selection follows the server default")
    func effortResolution() {
        let low = CodexModels.Effort(id: "low", description: nil)
        let high = CodexModels.Effort(id: "high", description: nil)
        let models = [
            CodexModels.Model(
                id: "a", supportedEfforts: [low, high], defaultEffort: "low", isDefault: false),
            CodexModels.Model(
                id: "b", supportedEfforts: [low], defaultEffort: nil, isDefault: true),
        ]
        #expect(CodexModels.efforts(for: "a", in: models) == [low, high])
        #expect(CodexModels.efforts(for: nil, in: models) == [low])
        #expect(CodexModels.efforts(for: "unknown", in: models).isEmpty)
        #expect(CodexModels.efforts(for: nil, in: []).isEmpty)
    }
}
