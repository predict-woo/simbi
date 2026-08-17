import CodexKit
import Foundation

/// Transcription backend. The real implementation uploads to
/// `backend-api/transcribe`; tests script their own fakes.
public protocol Transcriber: Sendable {
    /// Returns the transcription text for one encoded WebM/Opus segment.
    /// Single attempt; the pipeline owns retry/backoff (guide §9.2).
    func transcribe(webmFile: URL) async throws -> String
}

/// The production transcriber: Codex-credentialed uploads.
public struct CodexTranscriber: Transcriber {
    private let client = TranscriptionClient()

    public init() {}

    public func transcribe(webmFile: URL) async throws -> String {
        try await client.transcribe(webmData: Data(contentsOf: webmFile))
    }
}
