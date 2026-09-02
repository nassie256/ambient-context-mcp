// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ax-title-poc",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ax-title-poc",
            path: "Sources/ax-title-poc",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics")
            ]
        )
    ]
)
