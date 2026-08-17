import Foundation
import Observation
import SimbiAudio
import SimbiKit

/// UI-facing playback state for one note's `audio.webm` (SPEC.md §6:
/// player bar + click-to-seek playback in the transcript pane).
@MainActor
@Observable
final class PlaybackController {
    private(set) var isPlaying = false
    /// Timeline seconds — polled while playing, the resume point while
    /// paused.
    private(set) var position: TimeInterval = 0
    /// Total timeline seconds; refreshed on play and `refreshDuration`
    /// (the file grows while recording).
    private(set) var duration: TimeInterval = 0

    private let audioURL: URL
    private var playback: AudioPlayback?
    private var tickTask: Task<Void, Never>?

    init(noteFolderURL: URL) {
        self.audioURL = NoteLayout.audioURL(noteFolder: noteFolderURL)
    }

    var hasAudio: Bool {
        FileManager.default.fileExists(atPath: audioURL.path)
    }

    func refreshDuration() {
        do {
            duration = try ensurePlayback().duration
        } catch {
            Log.ui.warning("opening audio.webm for playback failed: \(error)")
        }
    }

    /// Player-bar play/pause: resumes at the paused position, restarts
    /// from the top once the file has finished.
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play(from: position)
        }
    }

    func play(from time: TimeInterval) {
        do {
            let playback = try ensurePlayback()
            duration = playback.duration
            let start = min(max(0, time), duration)
            try playback.play(from: start >= duration ? 0 : start)
            isPlaying = true
            position = start >= duration ? 0 : start
            tickTask?.cancel()
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self, self.isPlaying else { break }
                    self.position = self.playback?.position ?? 0
                }
            }
        } catch {
            Log.ui.error("playback failed: \(error)")
            isPlaying = false
        }
    }

    /// Stops the audio but keeps `position` as the resume point.
    func pause() {
        guard isPlaying, let playback else { return }
        position = playback.position
        playback.stop()
        isPlaying = false
        tickTask?.cancel()
        tickTask = nil
    }

    /// Scrubber seek: jumps there mid-play, or just moves the resume
    /// point while paused.
    func seek(to time: TimeInterval) {
        if isPlaying {
            play(from: time)
        } else {
            position = max(0, min(time, duration))
        }
    }

    func stop() {
        playback?.stop()
        isPlaying = false
        tickTask?.cancel()
        tickTask = nil
    }

    private func ensurePlayback() throws -> AudioPlayback {
        if let playback { return playback }
        let playback = try AudioPlayback(fileURL: audioURL)
        self.playback = playback
        playback.onFinished = { [weak self] in
            Task { @MainActor in self?.playbackFinished() }
        }
        return playback
    }

    private func playbackFinished() {
        isPlaying = false
        position = 0
        tickTask?.cancel()
        tickTask = nil
    }
}
