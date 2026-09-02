import AmbientContextCore
import Foundation

/// C# `McpServerHost` (src/windows/AmbientContextMcp.Desktop/Mcp/McpServerHost.cs) の移植。
///
/// 埋め込み MCP サーバの実行時ビュー (設定 = port / token / autoStart、エンドポイント URL、
/// discovery ファイルのライフサイクル) を持つ。HTTP の listen 自体は `McpHttpServer` の担当。
public final class McpServerHost: @unchecked Sendable {
    private let lock = NSLock()
    private let settingsStore: any SettingsStore
    private let discoveryPathValue: String
    private var settingsValue: McpServerSettings

    /// - Parameters:
    ///   - settingsStore: 設定の読み出し元。
    ///   - discoveryPath: discovery ファイルのパス。既定では settingsPath と同じディレクトリの
    ///     `mcp-api.json` (= `~/Library/Application Support/AmbientContextMcp/mcp-api.json`)。
    ///     テストから差し替えられるように引数にしている。
    public init(settingsStore: any SettingsStore, discoveryPath: String? = nil) {
        self.settingsStore = settingsStore
        self.discoveryPathValue =
            discoveryPath ?? McpServerHost.resolveDiscoveryPath(settingsPath: settingsStore.settingsPath)
        self.settingsValue = settingsStore.loadMcpServerSettings()
    }

    public var settings: McpServerSettings {
        lock.lock()
        defer { lock.unlock() }
        return settingsValue
    }

    public var baseUrl: String { "http://127.0.0.1:\(settings.port)/" }

    public var mcpUrl: String { baseUrl + "mcp" }

    public var token: String { settings.token }

    public var discoveryPath: String { discoveryPathValue }

    public func reloadSettings() {
        let loaded = settingsStore.loadMcpServerSettings()
        lock.lock()
        settingsValue = loaded
        lock.unlock()
    }

    /// C# の `Environment.GetFolderPath(LocalApplicationData)/AmbientContextMcp/mcp-api.json` に対応する
    /// macOS のパス。Core の `LocalContextEventLog.resolvePath` と同じく settings.json の隣に置く。
    public static func resolveDiscoveryPath(settingsPath: String) -> String {
        let directory = (settingsPath as NSString).deletingLastPathComponent
        return directory.isEmpty
            ? "mcp-api.json"
            : (directory as NSString).appendingPathComponent("mcp-api.json")
    }

    // MARK: - discovery ファイル

    /// StdioBridge との契約ファイル。temp + rename でアトミックに書く。
    public func writeDiscoveryFile(now: Date = Date(), pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
        let current = settings
        let payload = McpDiscoveryPayload(
            schemaVersion: 1,
            baseUrl: "http://127.0.0.1:\(current.port)/",
            mcpUrl: "http://127.0.0.1:\(current.port)/mcp",
            token: current.token,
            pid: Int(pid),
            startedAt: now,
            endpoints: .init(mcp: "POST/GET /mcp"),
            // 実サーバのツール登録は AmbientContextTools.all で行う。C# 版と同じくここは手書きで、
            // 順序も C# の配列リテラルに合わせている。
            tools: AmbientContextTools.discoveryToolNames)

        let directory = (discoveryPathValue as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
        }

        // `Data.write(options: .atomic)` が temp ファイル + rename を行う (C# の
        // WriteAllText + File.Move(overwrite:) と同じ効果)。
        let json = AmbientContextJson.string(payload)
        try Data(json.utf8).write(to: URL(fileURLWithPath: discoveryPathValue), options: .atomic)
    }

    /// 終了時のベストエフォート削除。
    public func tryDeleteDiscoveryFile() {
        try? FileManager.default.removeItem(atPath: discoveryPathValue)
    }
}

/// discovery ファイルの JSON ペイロード。
/// キー名と値は C# の匿名型と同じ。キーの並びは Foundation の JSONEncoder 任せで宣言順にならないが、
/// StdioBridge は名前で読むので契約上の差にはならない (Core の各 Response も同様)。
struct McpDiscoveryPayload: Codable, Sendable {
    struct Endpoints: Codable, Sendable {
        var mcp: String
    }

    var schemaVersion: Int
    var baseUrl: String
    var mcpUrl: String
    var token: String
    var pid: Int
    var startedAt: Date
    var endpoints: Endpoints
    var tools: [String]
}
