import AmbientContextCore
import Foundation
import MCP
@testable import AmbientContextMcpServer

// MARK: - フィクスチャ

enum Fixtures {
    /// #filePath から上に辿って `mcpb/manifest.json` を持つリポジトリルートを探し、
    /// `src/macos/Fixtures/contract` を返す (Core テストと同じ方式)。
    static var contractDirectory: URL? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let marker = directory.appendingPathComponent("mcpb/manifest.json")
            if FileManager.default.fileExists(atPath: marker.path) {
                return directory.appendingPathComponent("src/macos/Fixtures/contract")
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }
}

// MARK: - 設定ストア

/// MCP サーバテスト用のインメモリ設定ストア。settingsPath だけは実在の一時ディレクトリを指す。
final class FakeSettingsStore: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var mcpSettings: McpServerSettings

    let settingsPath: String

    init(settingsPath: String, mcpSettings: McpServerSettings = McpServerSettings()) {
        self.settingsPath = settingsPath
        self.mcpSettings = mcpSettings
    }

    func setMcpSettings(_ settings: McpServerSettings) {
        lock.lock()
        mcpSettings = settings
        lock.unlock()
    }

    func loadAmbientTransmissionSettings() -> AmbientTransmissionSettings { .init() }
    func saveAmbientTransmissionSettings(_ settings: AmbientTransmissionSettings) {}

    func loadLocalContextSettings() -> LocalContextSettings {
        LocalContextSettings(persistEventLog: false)
    }
    func saveLocalContextSettings(_ settings: LocalContextSettings) {}

    func loadMcpServerSettings() -> McpServerSettings {
        lock.lock()
        defer { lock.unlock() }
        return mcpSettings
    }
    func saveMcpServerSettings(_ settings: McpServerSettings) { setMcpSettings(settings) }

    func loadSettingsWindowStatus() -> SettingsWindowStatus? { nil }
    func saveSettingsWindowStatus(_ status: SettingsWindowStatus) {}

    func loadUiSettings() -> UiSettings { .init() }
    func saveUiSettings(_ settings: UiSettings) {}

    func loadTransientStateSettings() -> TransientStateSettings { .init() }
    func saveTransientStateSettings(_ settings: TransientStateSettings) {}
}

/// テストごとに固有の一時ディレクトリを作り、破棄時に消す。
final class TempDirectory {
    let path: String

    init() {
        path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ambient-context-mcp-server-test/\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }

    func file(_ name: String) -> String {
        (path as NSString).appendingPathComponent(name)
    }
}

// MARK: - テスト用サーバ

/// ランダムな空きポートに bind した MCP サーバ一式。
actor TestServer {
    let token: String
    let port: Int
    private let httpServer: McpHttpServer

    /// let のみから導けるので nonisolated (await 不要)。
    nonisolated var mcpUrl: URL { URL(string: "http://127.0.0.1:\(port)/mcp")! }

    init(token: String = "test-token", hub: LocalContextHub? = nil) async throws {
        self.token = token
        let directory = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ambient-context-mcp-server-test/\(UUID().uuidString)")
        let store = FakeSettingsStore(
            settingsPath: (directory as NSString).appendingPathComponent("settings.json"))
        let sharedHub = hub ?? LocalContextHub(settingsStore: store, language: "en")
        let server = McpHttpServer(
            pipelineFactory: { try await AmbientMcpServer.makePipeline(hub: sharedHub) },
            tokenProvider: { token })
        // port 0 = カーネルに空きポートを選ばせる。
        try await server.start(host: "127.0.0.1", port: 0)
        self.httpServer = server
        self.port = await server.boundPort
    }

    func shutdown() async {
        await httpServer.stop()
    }
}

// MARK: - HTTP クライアント

struct HTTPResult {
    var status: Int
    var headers: [String: String]
    var body: Data

    var text: String { String(decoding: body, as: UTF8.self) }

    func json() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
    }
}

enum TestHTTP {
    /// `session` 省略時は毎回 ephemeral な URLSession を作る (接続を共有しない)。
    /// 同一クライアントの連続呼び出しを表現したいときだけ session を渡す。
    static func request(
        _ url: URL,
        method: String = "POST",
        headers: [String: String] = [:],
        body: Data? = nil,
        session: URLSession? = nil
    ) async throws -> HTTPResult {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let session = session ?? URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        var normalized: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                normalized[name.lowercased()] = value
            }
        }
        return HTTPResult(status: http.statusCode, headers: normalized, body: data)
    }

    /// JSON-RPC 1 件を `/mcp` に投げる。MCP の spec 上 Accept は json + event-stream の両方が要る。
    static func rpc(
        _ url: URL,
        payload: [String: Any],
        token: String?,
        tokenHeader: String = "Authorization",
        extraHeaders: [String: String] = [:],
        session: URLSession? = nil
    ) async throws -> HTTPResult {
        var headers = [
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream"
        ]
        if let token {
            headers[tokenHeader] =
                tokenHeader == "Authorization" ? "Bearer \(token)" : token
        }
        for (name, value) in extraHeaders { headers[name] = value }
        return try await request(
            url,
            method: "POST",
            headers: headers,
            body: try JSONSerialization.data(withJSONObject: payload),
            session: session)
    }

    static func initializePayload(id: Int = 1) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "initialize",
            "params": [
                "protocolVersion": Version.latest,
                "capabilities": [:],
                "clientInfo": ["name": "test-client", "version": "1.0.0"]
            ]
        ]
    }

    static func toolsListPayload(id: Int = 2) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": "tools/list", "params": [:]]
    }

    static func toolsCallPayload(
        id: Int = 3, name: String, arguments: [String: Any] = [:]
    ) -> [String: Any] {
        [
            "jsonrpc": "2.0", "id": id, "method": "tools/call",
            "params": ["name": name, "arguments": arguments]
        ]
    }
}
