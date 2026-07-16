// M1 spike (a): vendored libopus + libwebm → backend-api/transcribe.
//
// 1. Synthesizes speech with `say`, converts to 16 kHz mono Float32.
// 2. Encodes it through OpusWebMEncoder in TWO sessions (create + append)
//    — the uploaded file is a live-mode appended file, exactly what a
//    stop/resume recording produces.
// 3. Uploads to https://chatgpt.com/backend-api/transcribe with Codex
//    Desktop credentials/headers (references/codex-transcription/).
// 4. PASS iff the endpoint returns a transcription containing the marker
//    words from the spoken sentence.

import AVFoundation
import CodexKit
import Foundation
import SimbiAudio

let spokenText = "Simbi is a note taking app. It records meetings, and it transcribes them."
let markerWords = ["note", "meetings"]

func fail(_ step: String, _ message: String) -> Never {
    print("FAIL \(step): \(message)")
    exit(1)
}

func run(_ tool: String, _ args: [String]) throws {
    let process = Process()
    process.executableURL = URL(filePath: tool)
    process.arguments = args
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "spike", code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "\(tool) exited \(process.terminationStatus)"])
    }
}

let workDir = FileManager.default.temporaryDirectory
    .appending(path: "simbi-audio-spike-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDir) }

// --- 1. Synthesize speech and load as 16 kHz mono Float32 -------------------
let aiffURL = workDir.appending(path: "speech.aiff")
let wavURL = workDir.appending(path: "speech16k.wav")
do {
    try run("/usr/bin/say", ["-o", aiffURL.path, spokenText])
    try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEF32@16000", "-c", "1", aiffURL.path, wavURL.path])
} catch {
    fail("synthesize", "\(error.localizedDescription)")
}

var samples: [Float] = []
do {
    let file = try AVAudioFile(forReading: wavURL)
    guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1
    else {
        fail("load", "unexpected format \(file.processingFormat)")
    }
    let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    samples = Array(
        UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}
let seconds = Double(samples.count) / 16000
print("PASS synthesize: \(samples.count) samples (\(String(format: "%.2f", seconds)) s)")

// --- 2. Encode in two sessions (create, then append) ------------------------
let webmURL = workDir.appending(path: "audio.webm")
do {
    let half = samples.count / 2
    let encoder1 = try OpusWebMEncoder(fileURL: webmURL, mode: .create)
    try encoder1.append(samples: Array(samples[..<half]))
    let end1 = try encoder1.finish()

    let probe = try OpusWebMDecoder(fileURL: webmURL)
    guard probe.endMilliseconds == end1 else {
        fail("append", "cluster-scan offset \(probe.endMilliseconds) != session end \(end1)")
    }
    let encoder2 = try OpusWebMEncoder(
        fileURL: webmURL, mode: .append(baseMilliseconds: probe.endMilliseconds))
    try encoder2.append(samples: Array(samples[half...]))
    let end2 = try encoder2.finish()

    let decoder = try OpusWebMDecoder(fileURL: webmURL)
    let decoded = try decoder.decode().samples.count
    guard abs(decoded - samples.count) < 16000 else {
        fail("roundtrip", "decoded \(decoded) samples, expected ~\(samples.count)")
    }
    let bytes = try FileManager.default.attributesOfItem(atPath: webmURL.path)[.size] as! Int
    print(
        "PASS encode: 2 sessions, \(end2) ms, \(decoder.clusterIndex.count) clusters, "
            + "\(bytes) bytes (\(String(format: "%.1f", Double(bytes) * 8 / Double(end2))) kbps), "
            + "decode round-trip \(decoded) samples")
} catch {
    fail("encode", "\(error)")
}

// --- 3. Upload to backend-api/transcribe -------------------------------------
let auth: CodexAuth
do {
    auth = try CodexAuth.load(from: CodexInstallation.standard.authFileURL)
} catch {
    fail("auth", "cannot load ~/.codex/auth.json: \(error)")
}

let boundary = "simbi-spike-\(UUID().uuidString)"
var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/transcribe")!)
request.httpMethod = "POST"
request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
request.setValue(auth.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
request.setValue("Codex Desktop/26.707.72221 (Mac OS; arm64)", forHTTPHeaderField: "User-Agent")
request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

var body = Data()
body.append("--\(boundary)\r\n".data(using: .utf8)!)
body.append(
    "Content-Disposition: form-data; name=\"file\"; filename=\"codex.webm\"\r\n".data(using: .utf8)!)
body.append("Content-Type: audio/webm;codecs=opus\r\n\r\n".data(using: .utf8)!)
body.append(try Data(contentsOf: webmURL))
body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
request.httpBody = body

let (data, response): (Data, URLResponse)
do {
    (data, response) = try await URLSession.shared.data(for: request)
} catch {
    fail("upload", "\(error.localizedDescription)")
}
guard let http = response as? HTTPURLResponse else { fail("upload", "no HTTP response") }
guard http.statusCode == 200 else {
    let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
    fail("upload", "HTTP \(http.statusCode) — \(detail)")
}

struct TranscribeResponse: Decodable { let text: String }
guard let result = try? JSONDecoder().decode(TranscribeResponse.self, from: data) else {
    fail("upload", "response had no text field: \(String(data: data.prefix(300), encoding: .utf8) ?? "")")
}
print("PASS upload: HTTP 200")
print("transcription: \(result.text)")

let lowered = result.text.lowercased()
let missing = markerWords.filter { !lowered.contains($0) }
guard missing.isEmpty else {
    fail("verify", "transcription missing marker words \(missing)")
}
print("PASS verify: transcription contains \(markerWords)")
print("OVERALL: PASS")
