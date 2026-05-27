using AmbientContextMcp.Mcp;
using Microsoft.Extensions.Hosting;
using Microsoft.UI.Xaml;

namespace AmbientContextMcp.Tray;

public sealed class TrayService
{
    private readonly McpServerHost _mcpHost;
    private readonly IHostApplicationLifetime _lifetime;
    private Window? _hostWindow;
    private TrayIcon? _icon;

    public TrayService(McpServerHost mcpHost, IHostApplicationLifetime lifetime)
    {
        _mcpHost = mcpHost;
        _lifetime = lifetime;
    }

    public bool IsPaused => _icon?.IsPaused ?? false;

    public void Show(Action openSettings)
    {
        // H.NotifyIcon.WinUI の TaskbarIcon は visual tree に attach されないと
        // Loaded イベントが発火せず、OS の通知領域に登録されない。
        // 表示しない裏ホスト Window を 1 つ作って Content として保持する。
        _icon = new TrayIcon(_mcpHost, openSettings, () => _lifetime.StopApplication());
        _hostWindow = new Window
        {
            Title = "AmbientContextMcp.Tray (hidden host)",
            Content = _icon
        };
        _hostWindow.Activate();
        // Activate 直後に隠す。これでメッセージ pump は走るが visible window はない。
        _hostWindow.AppWindow.Hide();
    }

    public void RefreshStatus() => _icon?.RefreshStatusText();
}
