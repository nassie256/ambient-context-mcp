using AmbientContextMcp.Mcp;
using Microsoft.Extensions.Hosting;

namespace AmbientContextMcp.Tray;

public sealed class TrayService : IDisposable
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

    // IHost.DisposeAsync (アプリ終了時) でこの singleton も破棄され、
    // TrayHost.Dispose が Shell_NotifyIcon(NIM_DELETE) でアイコンを除去する。
    public void Dispose() => _host?.Dispose();
}
