# Simbi

An open-source macOS notetaking app that lives symbiotically with the Codex
(ChatGPT desktop) app. Simbi records and diarizes meeting audio locally,
transcribes it through the ChatGPT backend, and delegates all "intelligence"
(transcript fixing, file conversion, chat) to Codex threads.

**Status: feature-complete (M0–M7).** Recording + diarization, real
transcription, fixer/converter/chat Codex threads, system-audio capture,
playback, speaker rename, and per-feature model selectors are all
implemented and verified (see `docs/verification/`). See [docs/SPEC.md](docs/SPEC.md)
for the full design and
[docs/recording-algorithm.md](docs/recording-algorithm.md) for the normative
recording-pipeline algorithm.

## Layout

```
App/                    # thin SwiftUI shell (the only Xcode-target code)
Packages/SimbiKit/      # all real logic, headless-buildable:
  Sources/SimbiKit/     #   notes, file tree, VTT, state, settings
  Sources/SimbiAudio/   #   capture (mic + system), diarization, segmenting,
                        #   Opus/WebM encode/decode, mixing, playback
  Sources/CodexKit/     #   app-server JSON-RPC, transcription, fixer,
                        #   converter, chat, model list
  Sources/SimbiUI/      #   SwiftUI views (sidebar, note view, editor)
project.yml             # XcodeGen spec for the app shell
references/             # read-only research material (verified API notes)
```

## Building

Requires Xcode 26+ (Swift 6). Packages build and test headless:

```bash
swift build --package-path Packages/SimbiKit
swift test  --package-path Packages/SimbiKit
```

The app shell needs a generated project ([XcodeGen](https://github.com/yonaskolb/XcodeGen),
`brew install xcodegen`):

```bash
xcodegen generate
open Simbi.xcodeproj        # or: xcodebuild -scheme Simbi build
```

Formatting is enforced with the toolchain-bundled formatter:

```bash
swift format --in-place --recursive App Packages/SimbiKit/Sources Packages/SimbiKit/Tests
```

## Stack (decided in M0, 2026-07)

| Concern | Choice | Notes |
|---|---|---|
| UI | Swift 6 + SwiftUI, macOS 14+ | system-audio capture path needs 14.4+ |
| Diarization | [FluidAudio](https://github.com/FluidInference/FluidAudio) `0.15.5` (exact pin) | streaming Sortformer `fastV2_1`, CoreML/ANE |
| Markdown editor | [STTextView](https://github.com/krzyzanowskim/STTextView) + Neon (tree-sitter-markdown) | via STTextView-Plugin-Neon for the spike; to be vendored against upstream Neon before release |
| Markdown preview | MarkdownUI 2.4.x (planned, M5+) | successor Textual needs macOS 15 — adopt when the floor rises |
| Audio format | WebM/Opus everywhere, vendored libopus + libwebm (M1) | codex-native; no raw audio on disk |
| Project generation | XcodeGen (`project.yml` in git, no `.xcodeproj`) | thin app shell only |
| CI | GitHub Actions `macos-26`: format lint, `swift test`, unsigned app build | |
| Updates | [Sparkle 2](https://sparkle-project.org) — notarized DMGs on GitHub Releases, appcast on GitHub Pages | see [docs/release-setup.md](docs/release-setup.md) |

## Releasing

Tag and push; the release workflow builds, signs, notarizes, publishes the DMG
and updates the Sparkle feed:

```bash
git tag v1.3.0        && git push origin v1.3.0        # stable channel
git tag v1.4.0-beta.1 && git push origin v1.4.0-beta.1 # beta channel
```

One-time setup (Developer ID, notarization keys, Sparkle signing key) is in
[docs/release-setup.md](docs/release-setup.md).
