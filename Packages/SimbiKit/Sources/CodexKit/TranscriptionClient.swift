import Foundation

/// Placeholder transcription client.
public struct TranscriptionClient: Sendable {
    public enum TranscriptionError: Error, Equatable {
        case authUnavailable
        case authRejected(status: Int)
        case requestFailed(String)
        case malformedResponse
    }

    public init(installation: CodexInstallation = .standard) {}

    public func transcribe(webmData: Data) async throws -> String {
        throw TranscriptionError.authUnavailable
    }
}
