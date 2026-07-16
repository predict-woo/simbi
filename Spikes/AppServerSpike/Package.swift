// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppServerSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "appserver-spike",
            path: "Sources"
        )
    ]
)
