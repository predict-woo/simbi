// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SimbiKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SimbiKit", targets: ["SimbiKit"]),
        .library(name: "SimbiAudio", targets: ["SimbiAudio"]),
        .library(name: "CodexKit", targets: ["CodexKit"]),
        .library(name: "SimbiUI", targets: ["SimbiUI"]),
    ],
    dependencies: [
        // Fast-moving 0.x — pin exactly; bump deliberately. Pinned to the
        // upstream merge of our streaming mel timeline-drift fix (#807);
        // move to the next tagged release when one is cut.
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "baa11f65daa3003daf4401308786b1dcdeddd84e"),
        // TextKit 2 live-styled markdown editor (replaces the M0
        // STTextView + Neon source editor). Pre-1.0 — pin exactly.
        .package(url: "https://github.com/nodes-app/swift-markdown-engine", exact: "0.10.0"),
        // Ghostty terminal emulator wrapped as a Swift package (prebuilt
        // XCFramework, MIT). Fork of Lakr233/libghostty-spm 1.3.2 with the
        // xcframework headers namespaced (Headers/GhosttyKitHeaders/) so the
        // modulemap doesn't collide with FluidAudio's NemoTextProcessing in
        // Xcode's include/ copy step ("Multiple commands produce"). Tracks a
        // pinned Ghostty commit — pin exactly.
        .package(
            url: "https://github.com/predict-woo/libghostty-spm.git",
            exact: "1.3.2-simbi.3"),
    ],
    targets: [
        .target(name: "SimbiKit"),
        // Vendored Sameesunkaria/OutlineView (MIT) — SwiftUI wrapper around
        // NSOutlineView with drag & drop. See Sources/OutlineViewKit/VENDORED.md.
        // Pre-concurrency AppKit code, so it stays in Swift 5 language mode.
        .target(
            name: "OutlineViewKit",
            exclude: ["LICENSE.txt", "VENDORED.md"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Vendored stevengharris/SplitView 3.5.3 (MIT) — pure-SwiftUI split
        // panes; replaces HSplitView, whose macOS 26 NSSplitView bridge is
        // broken three ways. See Sources/SplitViewKit/VENDORED.md.
        .target(
            name: "SplitViewKit",
            exclude: ["LICENSE.txt", "VENDORED.md"]
        ),
        // Vendored xiph/opus 1.5.2 (float, portable C — no arch-specific
        // intrinsics, no dnn/). See SPEC.md §3.3 [decided: vendored].
        .target(
            name: "CLibOpus",
            exclude: ["opus/COPYING"],
            publicHeadersPath: "opus/include",
            cSettings: [
                .headerSearchPath("opus/include"),
                .headerSearchPath("opus/src"),
                .headerSearchPath("opus/celt"),
                .headerSearchPath("opus/silk"),
                .headerSearchPath("opus/silk/float"),
                .define("OPUS_BUILD"),
                .define("VAR_ARRAYS", to: "1"),
                .define("HAVE_LRINT", to: "1"),
                .define("HAVE_LRINTF", to: "1"),
            ]
        ),
        // Vendored google/libwebm 1.0.0.31 (mkvmuxer + mkvparser) behind a
        // plain-C shim (webm_shim.h) so Swift needs no C++ interop.
        .target(
            name: "CLibWebM",
            exclude: ["libwebm/LICENSE.TXT", "libwebm/PATENTS.TXT"],
            cxxSettings: [
                .headerSearchPath("libwebm"),
                .headerSearchPath("include"),
            ],
            linkerSettings: [
                .linkedLibrary("c++")
            ]
        ),
        .target(
            name: "SimbiAudio",
            dependencies: [
                "SimbiKit",
                "CodexKit",
                "CLibOpus",
                "CLibWebM",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        // ChatSession persists its thread id in the note's state.json.
        .target(name: "CodexKit", dependencies: ["SimbiKit"]),
        .target(
            name: "SimbiUI",
            dependencies: [
                "SimbiKit",
                "OutlineViewKit",
                "SplitViewKit",
                "SimbiAudio",
                "CodexKit",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "MarkdownEngine", package: "swift-markdown-engine"),
                .product(name: "MarkdownEngineCodeBlocks", package: "swift-markdown-engine"),
                .product(name: "MarkdownEngineLatex", package: "swift-markdown-engine"),
            ]
        ),
        // M1 spike (b): proves the full `codex app-server` JSON-RPC lifecycle
        // end-to-end against the real ChatGPT.app binary. The reference
        // AppServerClient was built from; see its README for the wire shapes.
        // Burns real tokens — run by hand, never in CI. Not shipped in the app.
        .executableTarget(
            name: "simbi-appserver-spike"
        ),
        // M1 spike (SPEC.md §8): proves the vendored encoder's output is
        // accepted by backend-api/transcribe. Not shipped in the app.
        .executableTarget(
            name: "simbi-audio-spike",
            dependencies: ["SimbiAudio", "CodexKit"]
        ),
        // M2 spike: silent headless run of the full recording pipeline with
        // the REAL Sortformer models — synthesized speech is fed straight in
        // as PCM (no mic, no speakers). Not shipped in the app.
        .executableTarget(
            name: "simbi-pipeline-spike",
            dependencies: ["SimbiAudio"]
        ),
        // M4 spike: real fixer thread repairs a transcript end-to-end.
        .executableTarget(
            name: "simbi-fixer-spike",
            dependencies: ["CodexKit", "SimbiKit"]
        ),
        // M5 spike: real converter thread turns files/<name> into
        // context/<name>.md with no information loss.
        .executableTarget(
            name: "simbi-converter-spike",
            dependencies: ["CodexKit", "SimbiKit"]
        ),
        // M6 spike: SILENT system-audio tap E2E — process-specific tap with
        // muteBehavior=mutedWhenTapped, tone never audible.
        .executableTarget(
            name: "simbi-tap-spike",
            dependencies: ["SimbiAudio"]
        ),
        // M8 spike: embedded Ghostty terminal running the ChatGPT app's
        // packaged codex TUI directly — the terminal-instead-of-chat-UI
        // direction. Opens a real window; run by hand, not in CI.
        .executableTarget(
            name: "simbi-terminal-spike",
            dependencies: [
                "CodexKit",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ]
        ),
        .testTarget(name: "SimbiKitTests", dependencies: ["SimbiKit"]),
        .testTarget(name: "SimbiUITests", dependencies: ["SimbiUI", "CodexKit"]),
        .testTarget(
            name: "OutlineViewKitTests",
            dependencies: ["OutlineViewKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "SimbiAudioTests", dependencies: ["SimbiAudio"]),
        .testTarget(name: "CodexKitTests", dependencies: ["CodexKit"]),
    ]
)
