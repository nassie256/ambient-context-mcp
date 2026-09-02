// swift-tools-version: 6.0
import PackageDescription

// macOS 版 ambient-context-mcp のパッケージ定義。
// Phase 2 までで Core ライブラリ + MCP サーバライブラリ (と開発用 CLI) を定義する。
//
// TODO(Phase 4): executable target "AmbientContextMac" (.app 本体、NSStatusItem / SwiftUI 設定ウィンドウ /
//                Collector 群) を追加する。Resources と ja.lproj / en.lproj もここにぶら下げる。
// TODO(Phase 5): executable target "ambient-mcp-stdio" (StdioBridge の Swift 移植) を追加する。
let package = Package(
    name: "AmbientContextMcp",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AmbientContextCore", targets: ["AmbientContextCore"]),
        .library(name: "AmbientContextMcpServer", targets: ["AmbientContextMcpServer"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        // swift-sdk 0.12.1 が推移的に引くのと同じ版。HTTP/1.1 の受け口としてのみ使う。
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.102.0")
    ],
    targets: [
        .target(
            name: "AmbientContextCore",
            path: "Sources/AmbientContextCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AmbientContextMcpServer",
            dependencies: [
                "AmbientContextCore",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio")
            ],
            path: "Sources/AmbientContextMcpServer",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // 手動疎通 (curl) 用の開発専用 CLI。配布物には含めない。
        .executableTarget(
            name: "ambient-mcp-dev",
            dependencies: ["AmbientContextCore", "AmbientContextMcpServer"],
            path: "Sources/ambient-mcp-dev",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AmbientContextCoreTests",
            dependencies: ["AmbientContextCore"],
            path: "Tests/AmbientContextCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AmbientContextMcpServerTests",
            dependencies: [
                "AmbientContextMcpServer",
                "AmbientContextCore",
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Tests/AmbientContextMcpServerTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
