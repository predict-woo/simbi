// M8 spike: embed a Ghostty terminal surface and run the ChatGPT app's
// packaged codex TUI in it directly — no app-server, no custom chat UI.
// Codex draws its own interface (composer, approvals, streaming) inside
// the surface; Simbi only hosts the terminal.
//
// Run by hand: swift run simbi-terminal-spike
// Success = codex TUI renders, accepts typed input, and completes a turn.

import AppKit
import CodexKit
import GhosttyTerminal

@MainActor
final class SpikeDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var terminalView: TerminalView?

    // command= runs through the user's shell; the ChatGPT.app path has no
    // spaces, so no quoting gymnastics are needed.
    private let installation = CodexInstallation.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard installation.isBinaryInstalled else {
            fputs("codex binary not found at \(installation.binaryURL.path); install the ChatGPT app first\n", stderr)
            NSApp.terminate(nil)
            return
        }

        let controller = TerminalController(
            configSource: .none,
            terminalConfiguration: TerminalConfiguration { builder in
                builder.withCustom("command", installation.binaryURL.path)
            }
        )

        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 620))
        terminal.delegate = self
        terminal.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            // Without CODEX_HOME the standalone binary uses a private home
            // invisible to the ChatGPT app (CodexInstallation gotcha #1).
            envVars: ["CODEX_HOME": installation.codexHomeURL.path]
        )
        terminal.controller = controller
        terminalView = terminal

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "simbi-terminal-spike"
        window.contentView = terminal
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminal)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

extension SpikeDelegate: TerminalSurfaceTitleDelegate, TerminalSurfaceResizeDelegate,
    TerminalSurfaceCloseDelegate
{
    func terminalDidChangeTitle(_ title: String) {
        window?.title = title
    }

    func terminalDidResize(columns: Int, rows: Int) {}

    func terminalDidClose(processAlive: Bool) {
        window?.close()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = SpikeDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
