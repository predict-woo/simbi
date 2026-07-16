import CoreServices
import Foundation

/// Recursive FSEvents watcher over the Simbi home directory. Fires `onChange`
/// (coalesced by `latency`) on any file-system change below `url`, so external
/// edits — Finder, Codex threads, git — show up in the tree immediately
/// (SPEC.md §2.1). Callbacks arrive on a private queue; hop to your own actor.
public final class FileTreeWatcher {
    private final class Callback {
        let onChange: @Sendable () -> Void
        init(_ onChange: @escaping @Sendable () -> Void) {
            self.onChange = onChange
        }
    }

    private let stream: FSEventStreamRef
    private let queue = DispatchQueue(label: "ac.clap.simbi.file-tree-watcher")

    public init?(url: URL, latency: TimeInterval = 0.3, onChange: @escaping @Sendable () -> Void) {
        let callback = Callback(onChange)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(callback).toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<Callback>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                { _, info, _, _, _, _ in
                    guard let info else { return }
                    Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue().onChange()
                },
                &context,
                [url.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
            )
        else {
            Unmanaged.passUnretained(callback).release()  // balance passRetained
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)  // context release callback frees Callback
    }
}
