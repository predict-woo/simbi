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
        .target(
            name: "SimbiAudio",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ]
        ),
        .target(name: "CodexKit"),
        .target(
            name: "SimbiUI",
            dependencies: [
                "SimbiKit",
                "CodexKit",
                .product(name: "STTextView", package: "STTextView"),
                .product(name: "STTextView-Plugin-Neon", package: "STTextView-Plugin-Neon"),
            ]
        ),
        .testTarget(name: "SimbiKitTests", dependencies: ["SimbiKit"]),
        .testTarget(name: "SimbiAudioTests", dependencies: ["SimbiAudio"]),
        .testTarget(name: "CodexKitTests", dependencies: ["CodexKit"]),
    ]
)
