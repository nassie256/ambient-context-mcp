import AmbientContextCore
import Foundation
import Testing
@testable import AmbientContextMcpServer

/// `McpServerHost` (URL 組み立て / 設定リロード / discovery ファイル) の検証。
@Suite("McpServerHost")
struct McpServerHostTests {
    @Test("urls_follow_the_windows_format")
    func urlsFollowTheWindowsFormat() {
        let directory = TempDirectory()
        let store = FakeSettingsStore(
            settingsPath: directory.file("settings.json"),
            mcpSettings: McpServerSettings(port: 37690, token: "abc"))
        let host = McpServerHost(settingsStore: store)

        #expect(host.baseUrl == "http://127.0.0.1:37690/")
        #expect(host.mcpUrl == "http://127.0.0.1:37690/mcp")
        #expect(host.token == "abc")
    }

    @Test("reload_settings_picks_up_new_port_and_token")
    func reloadSettingsPicksUpNewPortAndToken() {
        let directory = TempDirectory()
        let store = FakeSettingsStore(
            settingsPath: directory.file("settings.json"),
            mcpSettings: McpServerSettings(port: 37690, token: "old"))
        let host = McpServerHost(settingsStore: store)

        store.setMcpSettings(McpServerSettings(port: 40000, token: "new"))
        #expect(host.mcpUrl == "http://127.0.0.1:37690/mcp", "reload 前は古い値のまま")

        host.reloadSettings()
        #expect(host.mcpUrl == "http://127.0.0.1:40000/mcp")
        #expect(host.token == "new")
    }

    /// 既定の discovery パスは settings.json と同じディレクトリ
    /// (= `~/Library/Application Support/AmbientContextMcp/mcp-api.json`)。
    @Test("default_discovery_path_sits_next_to_settings_json")
    func defaultDiscoveryPathSitsNextToSettingsJson() {
        let path = McpServerHost.resolveDiscoveryPath(
            settingsPath: "/Users/x/Library/Application Support/AmbientContextMcp/settings.json")
        #expect(path == "/Users/x/Library/Application Support/AmbientContextMcp/mcp-api.json")
        #expect(JsonFileSettingsStore.defaultPath.hasSuffix(
            "Library/Application Support/AmbientContextMcp/settings.json"))
    }

    @Test("discovery_file_round_trip")
    func discoveryFileRoundTrip() throws {
        let directory = TempDirectory()
        let store = FakeSettingsStore(
            settingsPath: directory.file("settings.json"),
            mcpSettings: McpServerSettings(port: 37691, token: "tok-123"))
        let host = McpServerHost(
            settingsStore: store, discoveryPath: directory.file("nested/mcp-api.json"))

        #expect(!FileManager.default.fileExists(atPath: host.discoveryPath))
        try host.writeDiscoveryFile(now: Date(timeIntervalSince1970: 1_777_000_000), pid: 4242)
        #expect(FileManager.default.fileExists(atPath: host.discoveryPath))

        let data = try Data(contentsOf: URL(fileURLWithPath: host.discoveryPath))
        let payload = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(payload["schemaVersion"] as? Int == 1)
        #expect(payload["baseUrl"] as? String == "http://127.0.0.1:37691/")
        #expect(payload["mcpUrl"] as? String == "http://127.0.0.1:37691/mcp")
        #expect(payload["token"] as? String == "tok-123")
        #expect(payload["pid"] as? Int == 4242)
        #expect(payload["startedAt"] as? String != nil)
        #expect((payload["endpoints"] as? [String: Any])?["mcp"] as? String == "POST/GET /mcp")
        #expect(payload["tools"] as? [String] == [
            "ambient_context_get_policy",
            "ambient_context_describe_events",
            "ambient_context_get_states",
            "ambient_context_poll_events"
        ])

        // 上書きが壊れないこと (2 回目も同じパスに書ける)。
        try host.writeDiscoveryFile()
        #expect(FileManager.default.fileExists(atPath: host.discoveryPath))

        host.tryDeleteDiscoveryFile()
        #expect(!FileManager.default.fileExists(atPath: host.discoveryPath))
        // 存在しないファイルの削除は握りつぶす。
        host.tryDeleteDiscoveryFile()
    }

    /// discovery の tools 配列は実際に登録しているツール名と一致していること (drift 防止)。
    @Test("discovery_tool_names_match_registered_tools")
    func discoveryToolNamesMatchRegisteredTools() {
        #expect(
            Set(AmbientContextTools.discoveryToolNames)
                == Set(AmbientContextTools.all.map(\.name)))
    }

    @Test("claude_code_snippet_matches_windows")
    func claudeCodeSnippetMatchesWindows() {
        let snippet = McpClientSnippets.buildClaudeCodeSnippet(
            mcpUrl: "http://127.0.0.1:37690/mcp", token: "abc")
        #expect(snippet == "claude mcp add ambient-context "
            + "--transport http http://127.0.0.1:37690/mcp "
            + "--header \"Authorization: Bearer abc\"")
    }

    /// ポート使用中の bind 失敗は呼び出し側が扱える throw で出る (Windows は致命ダイアログ表示)。
    @Test("bind_failure_surfaces_as_start_error")
    func bindFailureSurfacesAsStartError() async throws {
        let first = try await TestServer()
        defer { Task { await first.shutdown() } }

        let transport = AmbientMcpServer.makeTransport()
        let second = McpHttpServer(transport: transport, tokenProvider: { "x" })
        await #expect(throws: McpHttpServer.StartError.self) {
            try await second.start(host: "127.0.0.1", port: first.port)
        }
    }
}
