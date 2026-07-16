import Foundation
import Observation
import SimbiAudio

/// UI-facing playback state for one note's `audio.webm` (SPEC.md §6:
/// click-to-seek playback in the transcript pane).
@MainActor
@Observable
final class PlaybackController {
    private(set) var isPlaying = false
    /// Timeline seconds, polled while playing.
    private(set) var position: TimeInterval = 0

    private let audioURL: URL
    private var playback: AudioPlayback?
    private var tickTask: Task<Void, Never>?

    init(noteFolderURL: URL) {
        self.audioURL = noteFolderURL.appending(path: "audio.webm")
    }

    var hasAudio: Bool {
        FileManager.default.fileExists(atPath: audioURL.path)
    }

    func play(from time: TimeInterval) {
        do {
            let playback = try self.playback ?? AudioPlayback(fileURL: audioURL)
            self.playback = playback
            playback.onFinished = { [weak self] in
                Task { @MainActor in self?.playbackFinished() }
            }
            try playback.play(from: time)
            isPlaying = true
            position = time
            tickTask?.cancel()
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, self.isPlaying else { break }
                    self.position = self.playback?.position ?? 0
                }
            }
        } catch {
            isPlaying = false
        }
    }

    func stop() {
        playback?.stop()
        isPlaying = false
        tickTask?.cancel()
        tickTask = nil
    }

    private func playbackFinished() {
        isPlaying = false
        tickTask?.cancel()
        tickTask = nil
    }
}
