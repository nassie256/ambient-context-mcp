using AmbientContextMcp.Mcp;
using Microsoft.Extensions.Hosting;

namespace AmbientContextMcp.Tray;

public sealed class TrayService
{
    private readonly McpServerHost _mcpHost;
    private readonly IHostApplicationLifetime _lifetime;
    private TrayHost? _host;

    public TrayService(McpServerHost mcpHost, IHostApplicationLifetime lifetime)
    {
        _mcpHost = mcpHost;
        _lifetime = lifetime;
    }

    public bool IsPaused => _host?.IsPaused ?? false;

    public void Show(Action openSettings)
    {
        _host = new TrayHost(_mcpHost, _lifetime, openSettings);
    }

    public void RefreshStatus() => _host?.RefreshStatus();
}
