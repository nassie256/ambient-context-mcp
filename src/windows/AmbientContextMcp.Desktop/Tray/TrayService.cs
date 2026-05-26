using AmbientContextMcp.Mcp;
using Microsoft.Extensions.Hosting;

namespace AmbientContextMcp.Tray;

public sealed class TrayService
{
    private readonly McpServerHost _mcpHost;
    private readonly IHostApplicationLifetime _lifetime;
    private TrayIcon? _icon;

    public TrayService(McpServerHost mcpHost, IHostApplicationLifetime lifetime)
    {
        _mcpHost = mcpHost;
        _lifetime = lifetime;
    }

    public bool IsPaused => _icon?.IsPaused ?? false;

    public void Show(Action openSettings)
    {
        _icon = new TrayIcon(_mcpHost, openSettings, () => _lifetime.StopApplication());
    }

    public void RefreshStatus() => _icon?.RefreshStatusText();
}
