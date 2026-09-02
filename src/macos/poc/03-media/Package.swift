// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "media-poc",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "media-poc",
            path: "Sources/media-poc"
        )
    ]
)
