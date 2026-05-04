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
            tools = new[]
            {
                "ambient.context.get_policy",
                "ambient.context.get_states",
                "ambient.context.poll_events"
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
