import AppKit
import CodexKit
import GhosttyTerminal
import SimbiKit
import SwiftUI

/// One ghostty app shared by every chat terminal. The command is one
/// constant string (`TerminalChatLaunch.commandLine`); everything per-note
/// travels in each surface's env vars, so surfaces can share the controller.
@MainActor
enum TerminalChatServices {
    static let controller = TerminalController(
        configSource: .none,
        terminalConfiguration: TerminalConfiguration { builder in
            builder.withCustom("command", TerminalChatLaunch.commandLine)
        }
    )
}

/// Owns every per-note chat window (SPEC.md §5.4). Chat windows are plain
/// AppKit `NSWindow`s hosting the ghostty `TerminalView` directly — the
/// same proven shape as `simbi-terminal-spike` — NOT a SwiftUI WindowGroup,
/// deliberately: on macOS 26 the scene machinery persists chat sessions in
/// a store that survives savedState deletion, restores them as broken
/// value-less windows, and never commits content for windows born into a
/// native tab group. Owning the windows sidesteps all of it: no session
/// persistence, tab-group joins happen after content exists, and closing a
/// window on codex exit is ordinary AppKit.
///
/// One window per codex session. A note's chats group into one window as
/// native macOS tabs; new sessions come from the window's New Chat toolbar
/// button (or the native tab bar's + once two tabs exist). Different notes
/// get different tab groups, so they never merge. Closing a session's tab
/// kills its codex; the codex process exiting closes its tab, and the last
/// tab closing closes the window.
@MainActor
public final class ChatWindowManager {
    public static let shared = ChatWindowManager()

    /// Strong refs — `isReleasedWhenClosed` is off and windows are removed
    /// here from `windowWillClose`.
    private var windows: [ChatWindow] = []

    /// Note-toolbar entry point: focus the note's existing chat window
    /// (and its native tab group) if one is open, else start a first chat.
    public func openOrFocus(noteFolderURL: URL) {
        let identifier = ChatWindowTabbing.identifier(for: noteFolderURL)
        if let window = windows.first(where: { $0.tabbingIdentifier == identifier }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        openNewChat(noteFolderURL: noteFolderURL)
    }

    /// A fresh codex session about the note — first chat, or a + button.
    public func openNewChat(noteFolderURL: URL) {
        let window = ChatWindow(noteFolderURL: noteFolderURL, manager: self)
        windows.append(window)
        if let host = windows.first(where: {
            $0 !== window && $0.tabbingIdentifier == window.tabbingIdentifier
        }) {
            host.addTabbedWindow(window, ordered: .above)
        }
        window.makeKeyAndOrderFront(nil)
        // Deferred: a freshly added tab's `tabGroup` resolves after the
        // current runloop turn.
        DispatchQueue.main.async { self.refreshPlusButtons() }
    }

    fileprivate func windowWillClose(_ window: ChatWindow) {
        windows.removeAll { $0 === window }
        // The closing window still sits in its tab group right now; count
        // again on the next runloop turn once it has actually left.
        DispatchQueue.main.async { self.refreshPlusButtons() }
    }

    /// The New Chat toolbar button is only needed while a window has no
    /// native tab bar (single tab). From two tabs on, the bar's own +
    /// takes over.
    private func refreshPlusButtons() {
        for window in windows {
            window.refreshPlusButton()
        }
    }
}

/// A single codex session's window: the ghostty terminal is the content
/// view, exactly like the spike. Implements `newWindowForTab` so the
/// native tab bar shows its + button, and closes itself when the session's
/// process exits — natively closing just its tab while siblings remain.
final class ChatWindow: NSWindow, NSWindowDelegate {
    private let noteFolderURL: URL
    private weak var manager: ChatWindowManager?
    private var terminal: TerminalView?

    init(noteFolderURL: URL, manager: ChatWindowManager) {
        self.noteFolderURL = noteFolderURL
        self.manager = manager
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        title = "Chat: \(noteFolderURL.lastPathComponent)"
        // The manager keeps the strong reference; never restore chat
        // windows — a restored chat would spawn a codex process on launch
        // with nobody asking.
        isReleasedWhenClosed = false
        isRestorable = false
        tabbingMode = .preferred
        tabbingIdentifier = ChatWindowTabbing.identifier(for: noteFolderURL)
        delegate = self
        contentMinSize = NSSize(width: 480, height: 420)

        if CodexInstallation.standard.isBinaryInstalled {
            let terminal = TerminalView(frame: contentRect(forFrameRect: frame))
            // Pre-trust the note folder so the TUI opens on the composer
            // instead of the per-directory trust prompt.
            CodexTrust.ensureTrusted(directory: noteFolderURL)
            let launch = TerminalChatLaunch.forNote(
                noteFolderURL: noteFolderURL, homeRootURL: SimbiHome().rootURL)
            terminal.delegate = self
            terminal.configuration = TerminalSurfaceOptions(
                backend: .exec,
                workingDirectory: noteFolderURL.path,
                envVars: launch.envVars)
            terminal.controller = TerminalChatServices.controller
            self.terminal = terminal
            contentView = terminal
            makeFirstResponder(terminal)
        } else {
            contentView = NSHostingView(
                rootView: StatusBanner(
                    message: "ChatGPT app not found. Chat needs the bundled codex."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity))
        }

        // New-chat affordance: a real NSToolbar item, so AppKit owns the
        // padding, corner clearance, and bezel — hand-placed titlebar
        // accessories never sit right against the window's rounded corner.
        // The native tab bar (and its own +) only exists once two tabs
        // group, and with automatic window tabbing disabled app-wide,
        // `toggleTabBar` is a no-op — so single-tab windows need this.
        let toolbar = NSToolbar(identifier: "chat-window-toolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        toolbarStyle = .unifiedCompact
        self.toolbar = toolbar

        center()
    }

    static let newChatItemID = NSToolbarItem.Identifier("new-chat")

    /// Show the toolbar's New Chat button only while this window has no
    /// native tab bar; from two tabs on, the bar's own + takes over.
    func refreshPlusButton() {
        guard let toolbar else { return }
        let redundant = (tabGroup?.windows.count ?? 1) >= 2
        let index = toolbar.items.firstIndex { $0.itemIdentifier == Self.newChatItemID }
        if redundant, let index {
            toolbar.removeItem(at: index)
        } else if !redundant, index == nil {
            toolbar.insertItem(withItemIdentifier: Self.newChatItemID, at: toolbar.items.count)
        }
    }

    /// The native tab bar's + button: another chat about the same note.
    override func newWindowForTab(_ sender: Any?) {
        manager?.openNewChat(noteFolderURL: noteFolderURL)
    }

    func windowWillClose(_ notification: Notification) {
        manager?.windowWillClose(self)
    }

    /// Fires on every tab switch (and after tab drag-outs) — a cheap spot
    /// to keep the New Chat button in sync with the tab count.
    func windowDidBecomeKey(_ notification: Notification) {
        refreshPlusButton()
    }
}

extension ChatWindow: NSToolbarDelegate {
    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.newChatItemID else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        // A custom button (native `.toolbar` bezel) instead of the bordered
        // item: the item's standard styling exposes no way to shrink the
        // label and glyph without shrinking the bezel with them.
        let symbol = NSImage(systemSymbolName: "plus", accessibilityDescription: "New chat")!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))!
        let button = NSButton(
            title: "New Chat", image: symbol, target: self,
            action: #selector(newWindowForTab(_:)))
        button.bezelStyle = .toolbar
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 11)
        button.translatesAutoresizingMaskIntoConstraints = false
        // Wider than the content fits, so the small label sits in a
        // comfortable bezel rather than a cramped one.
        button.widthAnchor.constraint(equalToConstant: button.fittingSize.width + 12)
            .isActive = true
        item.view = button
        item.label = "New Chat"
        item.toolTip = "New chat about this note"
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.newChatItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.newChatItemID]
    }
}

extension ChatWindow: TerminalSurfaceCloseDelegate, TerminalSurfaceResizeDelegate {
    /// The codex process ended (double ctrl-c, ctrl-d, `/quit`, crash):
    /// close this session's window — natively just its tab when siblings
    /// remain, the whole window with the last one.
    func terminalDidClose(processAlive: Bool) {
        close()
    }

    func terminalDidResize(columns: Int, rows: Int) {}
}
