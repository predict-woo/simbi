// M5 spike: real end-to-end file-converter run. Builds a note folder,
// generates a binary .docx (via textutil) full of exact numbers, drives
// FileConverter against the real codex app-server, and verifies the
// resulting context/<name>.md: exists, carries the numbers and names
// verbatim (no information loss), and the original file is untouched.

import CodexKit
import Foundation
import SimbiKit

func fail(_ step: String, _ message: String) -> Never {
    print("FAIL \(step): \(message)")
    exit(1)
}

let noteFolder = FileManager.default.temporaryDirectory
    .appending(path: "simbi-converter-spike-\(UUID().uuidString)")
let filesDir = noteFolder.appending(path: "files")
try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: noteFolder) }

try """
# Q2 review
This note is about **Simbi**, our macOS notetaking app.
""".write(to: noteFolder.appending(path: "note.md"), atomically: true, encoding: .utf8)

// A binary format the agent must actually convert (not just `cat`):
// plain text → .docx via textutil.
let sourceText = """
    Q2 Review — Simbi

    Revenue for Q2 was 1,234,567.89 USD, up 17.3 percent quarter over quarter.
    The beta shipped to 4,096 users; median session length was 42.195 minutes.
    Prepared by Jae-won Seo (Head of Product) on 2026-07-14.

    Targets by region:
    Region, Target, Actual
    APAC, 500000, 512345
    EMEA, 400000, 398765
    AMER, 300000, 323457
    """
let sourceTxt = noteFolder.appending(path: "source.txt")
try sourceText.write(to: sourceTxt, atomically: true, encoding: .utf8)
let textutil = Process()
textutil.executableURL = URL(filePath: "/usr/bin/textutil")
textutil.arguments = [
    "-convert", "docx", sourceTxt.path, "-output", filesDir.appending(path: "report.docx").path,
]
try textutil.run()
textutil.waitUntilExit()
guard textutil.terminationStatus == 0 else { fail("setup", "textutil -convert docx failed") }
try FileManager.default.removeItem(at: sourceTxt)
let originalBytes = try Data(contentsOf: filesDir.appending(path: "report.docx"))
print("files/report.docx: \(originalBytes.count) bytes")

let client = AppServerClient()
let converter = FileConverter(noteFolderURL: noteFolder, client: client)

print("converting via real app-server (up to 15 min)…")
do {
    try await converter.convert(fileName: "report.docx") { threadId in
        print("converter thread: \(threadId)")
        // Same persistence path the app's FilesModel uses (§5.1: state.json
        // records thread ids).
        try? NoteRecordingState.update(noteFolder: noteFolder) {
            $0.conversions["report.docx"] = .init(status: .converting, threadId: threadId)
        }
    }
    try NoteRecordingState.update(noteFolder: noteFolder) {
        $0.conversions["report.docx"]?.status = .done
    }
} catch {
    let listing =
        (try? FileManager.default.contentsOfDirectory(atPath: noteFolder.path))?
        .joined(separator: ", ") ?? "?"
    fail("convert", "\(error) — note folder contains: \(listing)")
}

let outputURL = noteFolder.appending(path: "context/report.docx.md")
guard let markdown = try? String(contentsOf: outputURL, encoding: .utf8), !markdown.isEmpty
else { fail("output", "context/report.docx.md missing or empty") }

print("\n--- context/report.docx.md ---")
print(markdown)
print("------------------------------")

// No information loss: exact numbers and names must survive verbatim.
let mustContain = [
    "1,234,567.89", "17.3", "4,096", "42.195", "Jae-won Seo", "2026-07-14",
    "512345", "398765", "323457",
]
let normalized = markdown.replacingOccurrences(of: ",", with: "")
for needle in mustContain {
    // The agent may reformat thousands separators; compare with and without.
    let bare = needle.replacingOccurrences(of: ",", with: "")
    guard markdown.contains(needle) || normalized.contains(bare) else {
        fail("fidelity", "output lost \"\(needle)\"")
    }
}
print("PASS fidelity: all \(mustContain.count) exact values present")

guard try Data(contentsOf: filesDir.appending(path: "report.docx")) == originalBytes else {
    fail("original", "files/report.docx was modified")
}
print("PASS original: files/report.docx byte-identical")

let state = try NoteRecordingState.load(noteFolder: noteFolder)
guard state.conversions["report.docx"]?.status == .done,
    state.conversions["report.docx"]?.threadId != nil
else { fail("state", "conversion record not persisted: \(state.conversions)") }
print("PASS state: conversion record persisted with thread id")
print("OVERALL: PASS")
