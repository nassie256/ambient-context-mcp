import AmbientContextCore
import AmbientContextMcpServer
import Foundation

// 手動疎通 (curl / claude CLI) 用の開発専用エントリポイント。配布物には含めない。
//
//   AMBIENT_PORT=37699 AMBIENT_TOKEN=dev-token swift run ambient-mcp-dev
//
// 設定は一時ディレクトリの settings.json に置くので、実ユーザ設定を汚さない。

let environment = ProcessInfo.processInfo.environment
let port = environment["AMBIENT_PORT"].flatMap(Int.init) ?? 37699
let token = environment["AMBIENT_TOKEN"] ?? "dev-token"

let settingsPath = environment["AMBIENT_SETTINGS"]
    ?? (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("ambient-mcp-dev/\(UUID().uuidString)/settings.json")

let store = JsonFileSettingsStore(path: settingsPath)
store.saveMcpServerSettings(McpServerSettings(autoStart: false, port: port, token: token))

let hub = LocalContextHub(settingsStore: store, language: "en")
let host = McpServerHost(settingsStore: store)

let transport = AmbientMcpServer.makeTransport()
_ = try await AmbientMcpServer.makeAndStart(transport: transport, hub: hub)

let httpServer = McpHttpServer(transport: transport, tokenProvider: { host.token })
try await httpServer.start(host: "127.0.0.1", port: port)
try host.writeDiscoveryFile()

FileHandle.standardError.write(Data("""
    ambient-mcp-dev listening on \(host.mcpUrl)
      token:     \(host.token)
      settings:  \(settingsPath)
      discovery: \(host.discoveryPath)

    """.utf8))

// Ctrl-C / kill されるまで動かし続ける。
while true {
    try await Task.sleep(nanoseconds: 3_600_000_000_000)
}
