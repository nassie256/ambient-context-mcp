// swift-tools-version: 6.0
import PackageDescription

// macOS 版 ambient-context-mcp のパッケージ定義。
// Phase 1b では Core ライブラリとそのテストのみを定義する。
//
// TODO(Phase 2): target "AmbientContextMcpServer" (MCP Server 組立 / SwiftNIO HTTP /
//                認証ミドルウェア / discovery ファイル) と "AmbientContextMcpServerTests" を追加する。
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
        .library(name: "AmbientContextCore", targets: ["AmbientContextCore"])
    ],
    targets: [
        .target(
            name: "AmbientContextCore",
            path: "Sources/AmbientContextCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AmbientContextCoreTests",
            dependencies: ["AmbientContextCore"],
            path: "Tests/AmbientContextCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
