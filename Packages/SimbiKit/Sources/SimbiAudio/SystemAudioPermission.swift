import Foundation

/// Silent one-shot probe of the system-audio-recording TCC permission
/// (docs/superpowers/specs/2026-08-17-onboarding-wizard-design.md).
/// macOS has no request API for this permission: creating a process tap
/// makes the OS show its prompt on first ask, and fails once denied. The
/// tap is torn down immediately; no samples are read, recorded, or played.
public enum SystemAudioPermission {
    /// True when a tap can be created right now.
    public static func probe() -> Bool {
        guard #available(macOS 14.4, *) else { return false }
        let capture = SystemAudioCapture()
        defer { capture.stop() }
        do {
            _ = try capture.start()
            return true
        } catch {
            return false
        }
    }
}
