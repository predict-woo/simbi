import Foundation

/// Client for `POST https://chatgpt.com/backend-api/transcribe` (SPEC.md
/// §3.3): uploads WebM/Opus segments byte-identical in form to Codex
/// Desktop's own traffic, with credentials from `~/.codex/auth.json`.
/// Validated end-to-end in the M1 spike.
public struct TranscriptionClient: Sendable {
    public enum TranscriptionError: Error, Equatable {
        /// No usable ChatGPT login — recording continues, uploads queue
        /// (SPEC.md §7). Retrying later may succeed (user logs in).
        case authUnavailable
        /// The server rejected the credentials (401/403) — same recovery.
        case authRejected(status: Int)
        /// Transport or server failure; retryable.
        case requestFailed(String)
        /// 2xx but no usable text in the response body.
        case malformedResponse
    }

    public static let endpoint = URL(string: "https://chatgpt.com/backend-api/transcribe")!
    public static let userAgent = "Codex Desktop/26.707.72221 (Mac OS; arm64)"
    public static let requestTimeout: TimeInterval = 60

    private let installation: CodexInstallation

    public init(installation: CodexInstallation = .standard) {
        self.installation = installation
    }

    /// Uploads one encoded segment and returns its transcription text.
    /// Single attempt — the caller owns retry/backoff policy (guide §9.2).
    public func transcribe(webmData: Data) async throws -> String {
        guard let auth = try? CodexAuth.load(from: installation.authFileURL) else {
            throw TranscriptionError.authUnavailable
        }

        let boundary = "simbi-\(UUID().uuidString)"
        var request = URLRequest(url: Self.endpoint, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(auth.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(
            Data("Content-Disposition: form-data; name=\"file\"; filename=\"codex.webm\"\r\n".utf8))
        body.append(Data("Content-Type: audio/webm;codecs=opus\r\n\r\n".utf8))
        body.append(webmData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TranscriptionError.requestFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.requestFailed("no HTTP response")
        }
        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw TranscriptionError.authRejected(status: http.statusCode)
        default:
            let detail = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw TranscriptionError.requestFailed("HTTP \(http.statusCode) \(detail)")
        }

        struct TranscribeResponse: Decodable { let text: String }
        guard let result = try? JSONDecoder().decode(TranscribeResponse.self, from: data) else {
            throw TranscriptionError.malformedResponse
        }
        return result.text
    }
}
