import AppKit
import CodexKit
import GhosttyTerminal
import SimbiKit
import SwiftUI

/// One ghostty app shared by every thread-viewer terminal; per-thread
/// values travel in each surface's env vars (same shape as
/// TerminalChatServices).
@MainActor
enum ThreadViewerServices {
    static let controller = TerminalController(
        configSource: .none,
        terminalConfiguration: TerminalConfiguration { builder in
            builder.withCustom("command", TerminalViewerLaunch.commandLine)
        }
    )
}

/// Owns the per-thread viewer windows (live-view spec §4): plain AppKit
/// windows like ChatWindow (macOS 26 scene machinery is hostile to
/// terminal windows — see ChatWindowManager's doc comment), one window per
/// thread, no tab grouping. Handles the archive dance: unarchive before
/// attach (resume refuses archived threads), archive on close when the
/// thread is idle.
@MainActor
public final class ThreadViewerManager {
    public static let shared = ThreadViewerManager()

    private var windows: [String: ThreadViewerWindow] = [:]
    /// Threads whose window is being created (the unarchive/endpoint awaits
    /// leave a gap a second click could slip through): counted as open so
    /// neither a double-click nor a job-end archive races the attach.
    private var opening: Set<String> = []

    public func isOpen(threadId: String) -> Bool {
        windows[threadId] != nil || opening.contains(threadId)
    }

    func open(
        threadId: String, fileName: String, noteFolderURL: URL,
        isBusy: @escaping @MainActor () -> Bool
    ) {
        if let window = windows[threadId] {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard !opening.contains(threadId) else { return }
        opening.insert(threadId)
        Task { @MainActor in
            defer { self.opening.remove(threadId) }
            // Cosmetic bookkeeping: errors ignored (already unarchived, or
            // degraded server — resume errors then show inside the
            // terminal, which is the error UI).
            _ = try? await CodexServices.appServer.request(
                method: "thread/unarchive", params: ["threadId": threadId])
            guard let endpoint = try? await CodexServices.appServer.endpoint() else { return }
            let window = ThreadViewerWindow(
                threadId: threadId, fileName: fileName, noteFolderURL: noteFolderURL,
                endpoint: endpoint,
                onClose: { [weak self] in
                    self?.viewerClosed(threadId: threadId, isBusy: isBusy)
                })
            self.windows[threadId] = window
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func viewerClosed(threadId: String, isBusy: @MainActor () -> Bool) {
        windows[threadId] = nil
        // A turn is still running: leave the thread unarchived; the next
        // settle point archives it (spec §6).
        guard !isBusy() else { return }
        Task {
            _ = try? await CodexServices.appServer.request(
                method: "thread/archive", params: ["threadId": threadId])
        }
    }
}

/// A single viewer window: the ghostty terminal is the content view,
/// running the codex TUI attached to the app's own app-server. Closes
/// itself when codex exits (double Ctrl-C, /quit, crash).
final class ThreadViewerWindow: NSWindow, NSWindowDelegate {
    private let onClose: () -> Void
    private var terminal: TerminalView?

    init(
        threadId: String, fileName: String, noteFolderURL: URL, endpoint: String,
        onClose: @escaping () -> Void
    ) {
        self.onClose = onClose
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        title = "Conversion: \(fileName)"
        // The manager keeps the strong reference; never restore viewer
        // windows — a restored viewer would attach to a thread nobody asked
        // to watch.
        isReleasedWhenClosed = false
        isRestorable = false
        tabbingMode = .disallowed
        delegate = self
        contentMinSize = NSSize(width: 480, height: 420)

        let launch = TerminalViewerLaunch.forThread(
            threadId: threadId, appServerURL: endpoint)
        let terminal = TerminalView(frame: contentRect(forFrameRect: frame))
        terminal.delegate = self
        terminal.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: noteFolderURL.path,
            envVars: launch.envVars)
        terminal.controller = ThreadViewerServices.controller
        self.terminal = terminal
        contentView = terminal
        makeFirstResponder(terminal)
        center()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

extension ThreadViewerWindow: TerminalSurfaceCloseDelegate, TerminalSurfaceResizeDelegate {
    func terminalDidClose(processAlive: Bool) {
        close()
    }

    func terminalDidResize(columns: Int, rows: Int) {}
}
