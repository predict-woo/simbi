import Foundation
import Testing

@testable import CodexKit

@Suite("Simbi Codex project")
struct SimbiCodexProjectTests {
    @Test("finds the Codex project registered for the exact Simbi root")
    func findsRegisteredProject() {
        let result = Data(
            #"{"data":[{"id":"other","roots":[{"path":"/tmp/Other"}]},{"id":"simbi","roots":[{"path":"/Users/test/Simbi"}]}],"nextCursor":null}"#
                .utf8)

        #expect(
            SimbiCodexProjectAPI.projectID(
                in: result, rootURL: URL(filePath: "/Users/test/Simbi")) == "simbi")
    }

    @Test("prefers the app-server project linked to the visible desktop project")
    func prefersVisibleDesktopProject() {
        let result = Data(
            #"{"data":[{"id":"hidden","roots":[{"path":"/Users/test/Simbi"}]},{"id":"visible","roots":[{"path":"/Users/test/Simbi"}]}],"nextCursor":null}"#
                .utf8)

        #expect(
            SimbiCodexProjectAPI.projectID(
                in: result, rootURL: URL(filePath: "/Users/test/Simbi"),
                preferredID: "visible") == "visible")
    }

    @Test("reads the visible project and server mapping from Codex desktop state")
    func readsDesktopProjectCatalog() {
        let state = Data(
            #"{"local-projects":{"desktop-simbi":{"id":"desktop-simbi","name":"Simbi","rootPaths":["/Users/test/Simbi"],"createdAt":1,"updatedAt":1}},"app-server-project-id-by-legacy-project-id-by-host":{"local:/Users/test/.codex":{"desktop-simbi":"server-simbi"}}}"#
                .utf8)

        let project = SimbiCodexDesktopProjectCatalog.project(
            in: state, rootURL: URL(filePath: "/Users/test/Simbi"),
            codexHomeURL: URL(filePath: "/Users/test/.codex"))

        #expect(project?.desktopID == "desktop-simbi")
        #expect(project?.serverID == "server-simbi")
    }

    @Test("selects only Simbi threads not already assigned to the project")
    func selectsThreadsForMigration() {
        let result = Data(
            #"{"data":[{"id":"move","originator":"simbi","cwd":"/tmp","projectId":null},{"id":"chat","originator":"codex_cli_rs","cwd":"/Users/test/Simbi/Work/Standup","projectId":null},{"id":"done","originator":"simbi","cwd":"/Users/test/Simbi","projectId":"simbi"},{"id":"foreign","originator":"other","cwd":"/tmp/Other","projectId":null}],"nextCursor":null}"#
                .utf8)

        #expect(
            SimbiCodexProjectAPI.threadIDsToAssign(
                in: result, projectID: "simbi",
                rootURL: URL(filePath: "/Users/test/Simbi")) == ["move", "chat"])
    }

    @Test("task instructions keep the project root shared and scope relative paths to one note")
    func scopesTaskToNote() {
        let root = URL(filePath: "/Users/test/Simbi")
        let note = root.appending(path: "Work/Standup")
        let project = SimbiCodexProject(rootURL: root)

        let text = project.instructions(
            for: note, taskDirectoryURL: note,
            task: "Read note.md and write summary.md.")

        #expect(project.rootURL == root.standardizedFileURL)
        #expect(text.contains("active Simbi note is `Work/Standup`"))
        #expect(text.contains("task directory is `Work/Standup`"))
        #expect(text.contains("Change to that task directory before running commands"))
        #expect(text.hasSuffix("Read note.md and write summary.md."))
    }

    @Test("thread names identify Simbi, the note path, role, and optional detail")
    func namesThread() {
        let root = URL(filePath: "/Users/test/Simbi")
        let note = root.appending(path: "Work/Standup")
        let project = SimbiCodexProject(rootURL: root)

        #expect(project.threadName(for: note, role: "AI Notes") == "[Simbi · Work/Standup] AI Notes")
        #expect(
            project.threadName(for: note, role: "Convert", detail: "agenda.pdf")
                == "[Simbi · Work/Standup] Convert — agenda.pdf")
    }
}
