import AppKit
import SwiftUI

/// Zero-size background view that fires `onClick` when the window's
/// toolbar title view is clicked. AppKit-level because SwiftUI offers no
/// working affordance here on macOS: the binding form of navigationTitle
/// renders a plain label, and `.toolbar(removing: .title)` plus a custom
/// title item collapses the toolbar's flexible region so the trailing
/// action buttons slide against the title. The recognizer lives on the
/// window's private `NSToolbarTitleView`; lookup is by class name only
/// and fails soft (no title view found → no click affordance).
struct ToolbarTitleClickCatcher: NSViewRepresentable {
    let onClick: () -> Void

    @MainActor
    final class Coordinator: NSObject {
        var onClick: () -> Void = {}
        private weak var recognizer: NSClickGestureRecognizer?
        private weak var titleView: NSView?

        @objc private func clicked(_ sender: Any?) {
            // Only the title text counts, not the toolbar's whole flexible
            // region. Fail-soft: with no text field found (AppKit internals
            // moved), fire anywhere — rename must stay reachable.
            if let recognizer = sender as? NSClickGestureRecognizer,
                let titleView,
                let text = titleView.firstDescendant(where: { $0 is NSTextField }),
                let textSuperview = text.superview
            {
                let point = recognizer.location(in: titleView)
                let textFrame = titleView.convert(text.frame, from: textSuperview)
                guard textFrame.contains(point) else { return }
            }
            onClick()
        }

        /// Idempotent: re-resolves the title view only when the current
        /// recognizer's host left the window (e.g. toolbar rebuilt).
        func install(in window: NSWindow?) {
            if let titleView, titleView.window != nil, recognizer != nil { return }
            guard let root = window?.contentView?.superview,
                let title = root.firstDescendant(where: {
                    String(describing: type(of: $0)) == "NSToolbarTitleView"
                })
            else { return }
            // Sweep recognizers a previous NoteView left behind — SwiftUI
            // does not dismantle representables when an ancestor `.id`
            // changes (as every rename does), and the orphaned recognizer
            // (its target zeroed) sits first in line and eats the click.
            for existing in title.gestureRecognizers {
                if let click = existing as? NSClickGestureRecognizer,
                    click.target == nil || click.target is Coordinator
                {
                    title.removeGestureRecognizer(click)
                }
            }
            let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
            title.addGestureRecognizer(click)
            recognizer = click
            titleView = title
        }

        func uninstall() {
            if let recognizer, let titleView {
                titleView.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            titleView = nil
        }
    }

    /// Installs on `viewDidMoveToWindow` — the one deterministic moment
    /// the view has its window. A deferred install from updateNSView is
    /// not enough: after a rename recreates NoteView, the single update
    /// runs before the window is attached and never fires again.
    private final class AttachAwareView: NSView {
        var onAttach: (NSWindow) -> Void = { _ in }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                onAttach(window)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = AttachAwareView()
        view.onAttach = { [coordinator = context.coordinator] window in
            coordinator.install(in: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onClick = onClick
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }
}
