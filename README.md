<p align="center">
  <img src="https://raw.githubusercontent.com/predict-woo/simbi-web/main/src/assets/simbi-icon.svg" width="96" alt="Simbi app icon">
</p>

<h1 align="center">Simbi</h1>

<p align="center">
  <strong>Stop paying twice for AI.</strong><br>
  Use your ChatGPT plan for live, speaker-labelled meeting transcripts, saved as plain files.
</p>

<p align="center">
  <a href="https://github.com/predict-woo/simbi/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/predict-woo/simbi?display_name=tag&sort=semver"></a>
  <a href="https://github.com/predict-woo/simbi/actions/workflows/ci.yml"><img alt="CI status" src="https://github.com/predict-woo/simbi/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://getsimbi.app/docs/getting-started/"><img alt="macOS 14 or later" src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple"></a>
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
</p>

<p align="center">
  <a href="https://download.getsimbi.app/darwin-arm64"><strong>Download for Apple silicon</strong></a>
  · <a href="https://getsimbi.app/docs/">Documentation</a>
  · <a href="https://getsimbi.app">Website</a>
</p>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/predict-woo/simbi-web/main/src/assets/app-window-dark.png">
</picture>

Simbi is a free, open-source macOS app that records your microphone and system
audio, identifies speakers locally, and builds a live transcript. When the
recording ends, it turns the conversation into editable AI Notes with citations
that jump back to the original audio.

It pairs a native, local audio engine with the ChatGPT app you already use.
Speaker detection happens on your Mac. Transcription, transcript cleanup,
summaries, file conversion, and chat run through your own ChatGPT account. No
separate Simbi account or API key is needed.

## Why Simbi

- **Your notes stay yours.** There is no database or proprietary format. Notes
  are Markdown, transcripts are WebVTT, recordings are WebM/Opus, and every
  note is an ordinary folder you can open in Finder.
- **Both sides of the conversation.** Simbi captures your microphone and system
  audio into one synchronized timeline, without a bot joining the call.
- **Live speaker-labelled transcripts.** Local voice activity detection and
  diarization divide the conversation into clean per-speaker segments before
  transcription.
- **AI Notes grounded in the recording.** Summaries include clickable timestamp
  citations. Select one to hear the source moment and verify what was said.
- **Context, not copy and paste.** Add PDFs, slide decks, documents, or
  spreadsheets. Simbi preserves the originals and creates Markdown context for
  transcript cleanup, summaries, and chat.
- **Codex you can inspect and steer.** Transcript fixing, conversion, summaries,
  titles, and note chat are real Codex threads. Their Markdown instructions are
  yours to edit.
- **Built to survive the meeting.** Audio streams directly to a valid file, and
  pending transcript segments are queued on disk. A quit, crash, or lost
  connection does not throw away the recording.

## Simbi doesn't reinvent the wheel

The hard parts are already solved, and solved well. Simbi assembles mature
open-source projects and spends its own code on the glue: mixing two audio
sources onto one timeline, deciding where to cut speech, and keeping every note
a plain folder.

- [Codex CLI](https://github.com/openai/codex) for agent threads
- [Ghostty](https://github.com/ghostty-org/ghostty) for the embedded terminal
- [FluidAudio](https://github.com/FluidInference/FluidAudio) for on-device
  speech processing
- [anydoc](https://github.com/firecrawl/anydoc) for file conversion
- [swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine) for
  Markdown editing
- [Sparkle](https://github.com/sparkle-project/Sparkle) for app updates

See [Third-Party Licenses](THIRD-PARTY-LICENSES.md) for the complete list.

## Every note is just a folder

```text
~/Simbi/Work/Weekly Sync/
├── note.md          your notes
├── summary.md       AI Notes with timestamp citations
├── transcript.vtt  timed, speaker-labelled transcript
├── audio.webm       complete recording
├── files/           untouched attachments
└── context/         Markdown copies for Codex
```

Open the same folder in Obsidian, version it with Git, sync it with iCloud, or
search it with `rg`. Changes made outside Simbi appear in the app too. The full
layout, recovery state, and editable agent instructions are documented in
[How Simbi stores notes](https://getsimbi.app/docs/how-simbi-stores-notes/).

## Install

You need:

- An Apple silicon Mac
- macOS 14.0 or later. System-audio capture requires macOS 14.4 or later
- The [ChatGPT desktop app](https://chatgpt.com/download), installed and signed in

Then:

1. [Download the latest notarized DMG](https://download.getsimbi.app/darwin-arm64).
2. Drag Simbi to **Applications** and open it.
3. Choose a notes folder, grant the requested audio permissions, and let Simbi
   download its local speech models once.
4. Create a note and press record.

Simbi checks for signed updates with Sparkle. Update checks can be changed or
disabled in Settings.

## Privacy, without hand-waving

Simbi has no backend, user accounts, analytics, crash reporting, ads, or
tracking. The developer never receives your notes, recordings, or transcripts.

The processing boundary is:

- **On your Mac:** microphone and system-audio capture, the complete recording,
  voice activity detection, speaker diarization, note storage, and recovery
  queues.
- **Sent directly to OpenAI under your ChatGPT account:** short audio segments
  for transcription, plus note, transcript, and attachment content when the
  corresponding Codex features run.
- **Other network access:** one-time public model downloads from Hugging Face
  and optional app updates from GitHub.

Nothing passes through a Simbi-operated server. Read the complete
[privacy policy](PRIVACY.md) before using Simbi with sensitive conversations.
You are responsible for obtaining any consent required to record other people;
see the [terms of use](TERMS.md).

## Learn more

- [Getting started](https://getsimbi.app/docs/getting-started/)
- [How transcription works](https://getsimbi.app/docs/how-transcription-works/)
- [AI Notes, titles, and playback](https://getsimbi.app/docs/after-transcription/)
- [Chat with your notes](https://getsimbi.app/docs/chat-with-notes/)
- [Adding files as context](https://getsimbi.app/docs/adding-context-to-notes/)
- [Settings and agent instructions](https://getsimbi.app/docs/settings/)

## Build from source

The app requires Xcode 26 or later, Swift 6, [XcodeGen](https://github.com/yonaskolb/XcodeGen),
and a [Rust toolchain](https://rustup.rs). Rust is used at build time to vendor
the pinned [anydoc](https://github.com/firecrawl/anydoc) converter CLI.

```bash
git clone https://github.com/predict-woo/simbi.git
cd simbi
brew install xcodegen
xcodegen generate
open Simbi.xcodeproj
```

To launch a local build, select your Apple development team for the **Simbi**
target under **Signing & Capabilities**.

The Swift packages contain the app's real logic and build independently of the
Xcode shell:

```bash
swift build --package-path Packages/SimbiKit
swift test --package-path Packages/SimbiKit
```

For a command-line app build that matches CI:

```bash
xcodebuild -project Simbi.xcodeproj -scheme Simbi \
  -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

The first app build runs `scripts/fetch-anydoc.sh`. It downloads a pinned crate,
verifies its SHA-256 checksum, and builds the helper for every installed macOS
Rust target.

## Architecture

```text
App/                              thin SwiftUI app and Sparkle wiring
Packages/SimbiKit/Sources/
├── SimbiKit/                     plain-file notes, settings, VTT, recovery state
├── SimbiAudio/                   capture, mixing, diarization, encoding, playback
├── CodexKit/                     ChatGPT/Codex integration and worker threads
└── SimbiUI/                      native macOS interface
project.yml                       source of truth for the generated Xcode project
```

The package-first layout keeps almost all work testable with SwiftPM. For the
deeper contracts, start with [the product specification](docs/SPEC.md), the
[recording algorithm](docs/recording-algorithm.md), and the
[design system](docs/design-system.md).

## Contributing

Bug reports, ideas, and focused pull requests are welcome. Please
[open an issue](https://github.com/predict-woo/simbi/issues) before a large
change so the direction can be agreed on first. For code changes, run the Swift
tests and the toolchain formatter before opening a pull request:

```bash
swift test --package-path Packages/SimbiKit
swift format lint --strict --recursive \
  App Packages/SimbiKit/Sources Packages/SimbiKit/Tests Packages/SimbiKit/Package.swift
```

## License

Simbi is released under the [MIT License](LICENSE). Third-party software and
model notices are listed in [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).

Simbi is an independent project and is not affiliated with or endorsed by
OpenAI, Apple, NVIDIA, GitHub, or Hugging Face.
