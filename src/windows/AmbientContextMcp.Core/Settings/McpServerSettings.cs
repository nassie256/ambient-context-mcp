namespace AmbientContextMcp.Core.Settings;

public sealed class McpServerSettings
{
    public int SchemaVersion { get; init; } = 1;

    public bool AutoStart { get; init; }

    public int Port { get; init; } = 37690;

    public string Token { get; init; } = "";
}
