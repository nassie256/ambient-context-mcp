using System.IO;
using System.Text.Json;
using AmbientContextMcp.Core.Mcp;
using AmbientContextMcp.Core.Settings;

namespace AmbientContextMcp.Mcp;

/// <summary>
/// Owns the runtime view of the embedded MCP server: settings (port +
/// token + autostart), endpoint URLs, and discovery file lifecycle.
/// </summary>
public sealed class McpServerHost
{
    private readonly ISettingsStore _settingsStore;
    private McpServerSettings _settings;

    public McpServerHost(ISettingsStore settingsStore)
    {
        _settingsStore = settingsStore;
        _settings = settingsStore.LoadMcpServerSettings();
    }

    public McpServerSettings Settings => _settings;

    public string BaseUrl => $"http://127.0.0.1:{_settings.Port}/";

    public string McpUrl => BaseUrl + "mcp";

    public string Token => _settings.Token;

    public void ReloadSettings()
    {
        _settings = _settingsStore.LoadMcpServerSettings();
    }

    public void WriteDiscoveryFile()
    {
        var path = GetDiscoveryPath();
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var payload = new
        {
            schemaVersion = 1,
            baseUrl = BaseUrl,
            mcpUrl = McpUrl,
            token = _settings.Token,
            pid = Environment.ProcessId,
            startedAt = DateTimeOffset.Now,
            endpoints = new
            {
                mcp = "POST/GET /mcp"
            },
            // 実 MCP サーバは Program.cs の WithTools<ContextTools>() で属性スキャン登録するため、
            // この配列は静的に手書きしている。新規 [McpServerTool] を増やしたらここも追加すること
            // (drift 検出の自動化は未実装)。
            tools = new[]
            {
                "ambient_context_get_policy",
                "ambient_context_describe_events",
                "ambient_context_get_states",
                "ambient_context_poll_events"
            }
        };

        var tempPath = path + ".tmp";
        File.WriteAllText(tempPath, JsonSerializer.Serialize(payload, AmbientContextJson.Options));
        File.Move(tempPath, path, overwrite: true);
    }

    public static void TryDeleteDiscoveryFile()
    {
        try
        {
            var path = GetDiscoveryPath();
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
            // Best effort during shutdown.
        }
    }

    public static string GetDiscoveryPath()
    {
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "AmbientContextMcp",
            "mcp-api.json");
    }
}
