import Foundation

/// Quit-and-restart support for changes that only take effect on launch
/// (the home-root latch in `SimbiHome.activeRootURL`).
public enum Relaunch {
    /// Spawns a detached `open` of the app bundle after a short delay, so
    /// the current instance can terminate first. The shell is detached so
    /// it outlives this process; the path travels as an argument to
    /// sidestep quoting. Returns false (logged) when the helper can't
    /// start — the caller must then stay open rather than quit into
    /// nothing.
    public static func spawnRelauncher(bundlePath: String) -> Bool {
        let helper = Process()
        helper.executableURL = URL(filePath: "/bin/sh")
        helper.arguments = ["-c", #"sleep 0.5; /usr/bin/open "$0""#, bundlePath]
        do {
            try helper.run()
            return true
        } catch {
            Log.app.error("relaunch helper failed to start: \(error)")
            return false
        }
    }
}
