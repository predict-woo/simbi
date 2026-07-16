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
        // Fast-moving 0.x — pin exactly; bump deliberately.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
        .package(url: "https://github.com/krzyzanowskim/STTextView.git", from: "2.3.10"),
        // M0 spike choice. Revision-pinned (= tag 0.8.1): its Neon dependency is
        // itself revision-pinned, so SPM refuses to treat the tag as a stable
        // version. Before shipping, vendor the integration against upstream
        // ChimeHQ/Neon (see SPEC.md §1).
        .package(
            url: "https://github.com/krzyzanowskim/STTextView-Plugin-Neon.git",
            revision: "482b73cf442b2262525a0aa4355603b6467b6084"),
    ],
    targets: [
        .target(name: "SimbiKit"),
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
        .target(name: "CodexKit"),
        .target(
            name: "SimbiUI",
            dependencies: [
                "SimbiKit",
                "SimbiAudio",
                "CodexKit",
                .product(name: "STTextView", package: "STTextView"),
                .product(name: "STTextView-Plugin-Neon", package: "STTextView-Plugin-Neon"),
            ]
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
        // M7 spike: chat-in-codex round-trip + model/list.
        .executableTarget(
            name: "simbi-chat-spike",
            dependencies: ["CodexKit", "SimbiKit"]
        ),
        .testTarget(name: "SimbiKitTests", dependencies: ["SimbiKit"]),
        .testTarget(name: "SimbiAudioTests", dependencies: ["SimbiAudio"]),
        .testTarget(name: "CodexKitTests", dependencies: ["CodexKit"]),
    ]
)
