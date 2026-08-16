import AVFoundation
import Foundation
import Observation
import SimbiAudio
import SimbiKit

/// Live mic + system-audio permission state for the wizard's permissions
/// step. Mic status reads TCC without prompting; system audio has no
/// status API, so its state is only learned by probing (which prompts on
/// first ask) and is polled afterward so a System Settings toggle flips
/// the row live.
@MainActor @Observable
final class OnboardingPermissions {
    enum Status: Equatable { case unknown, granted, denied }

    private(set) var mic: Status = .unknown
    private(set) var systemAudio: Status = .unknown

    /// Once the user has asked at least once, polling may re-probe
    /// silently (a re-probe never prompts again after a denial).
    private var systemAudioRequested = false

    static let micSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    static let systemAudioSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!

    var bothGranted: Bool { mic == .granted && systemAudio == .granted }

    init() {
        if Flags.uiPreviewOnboarding {
            mic = .denied
            systemAudio = .unknown
            return
        }
        refresh()
    }

    /// Re-checks both permissions; never prompts.
    func refresh() {
        guard !Flags.uiPreviewOnboarding else { return }
        mic =
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .granted
            case .denied, .restricted: .denied
            case .notDetermined: .unknown
            @unknown default: .unknown
            }
        if systemAudioRequested {
            systemAudio = SystemAudioPermission.probe() ? .granted : .denied
        }
    }

    func requestMic() async {
        if Flags.uiPreviewOnboarding {
            mic = .granted
            return
        }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        mic = granted ? .granted : .denied
    }

    /// Runs the tap probe, which shows the OS prompt on the first ask.
    func requestSystemAudio() {
        if Flags.uiPreviewOnboarding {
            systemAudio = .granted
            return
        }
        systemAudioRequested = true
        systemAudio = SystemAudioPermission.probe() ? .granted : .denied
    }

    /// Poll from the permissions step's `.task`; cancellation on
    /// disappear stops it.
    func poll() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
