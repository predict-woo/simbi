import Foundation
import Observation
import SimbiAudio
import SimbiKit

/// UI-facing playback state for one note's `audio.webm` (SPEC.md §6:
/// player bar + click-to-seek playback in the transcript pane).
@MainActor
@Observable
final class PlaybackController {
    private struct AudioRevision: Equatable {
        let modifiedAt: Date?
        let size: UInt64?
        let fileIdentifier: UInt64?
    }

    private(set) var isPlaying = false
    /// Timeline seconds — polled while playing, the resume point while
    /// paused.
    private(set) var position: TimeInterval = 0
    /// Total timeline seconds; refreshed on play and `refreshDuration`
    /// (the file grows while recording).
    private(set) var duration: TimeInterval = 0
    private(set) var hasAudio: Bool

    private let audioURL: URL
    private var playback: AudioPlayback?
    private var tickTask: Task<Void, Never>?
    private var audioRevision: AudioRevision?
    private var watcher: FileTreeWatcher?

    init(noteFolderURL: URL) {
        self.audioURL = NoteLayout.audioURL(noteFolder: noteFolderURL)
        let revision = Self.revision(at: audioURL)
        self.audioRevision = revision
        self.hasAudio = revision != nil
        watcher = FileTreeWatcher.observing(url: noteFolderURL) { [weak self] in
            self?.refreshFileState()
        }
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

    /// Audio can be created, replaced, or removed outside Simbi. A loaded
    /// decoder belongs to one exact file revision and must never outlive it.
    func refreshFileState() {
        let latest = Self.revision(at: audioURL)
        guard latest != audioRevision else { return }
        let hadPlayback = playback != nil
        stop()
        playback = nil
        position = 0
        duration = 0
        audioRevision = latest
        hasAudio = latest != nil
        if hadPlayback && hasAudio { refreshDuration() }
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

    private static func revision(at url: URL) -> AudioRevision? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return AudioRevision(
            modifiedAt: values[.modificationDate] as? Date,
            size: (values[.size] as? NSNumber)?.uint64Value,
            fileIdentifier: (values[.systemFileNumber] as? NSNumber)?.uint64Value)
    }
}
