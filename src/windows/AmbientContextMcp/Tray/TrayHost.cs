using System.Windows.Forms;
using AmbientContextMcp.Mcp;
using AmbientContextMcp.Resources;
using Microsoft.Extensions.Hosting;
using Drawing = System.Drawing;
using WinFormsApp = System.Windows.Forms.Application;
using WpfApp = System.Windows.Application;

namespace AmbientContextMcp.Tray;

/// <summary>
/// Owns the system tray NotifyIcon, its context menu, and the
/// click-to-open-settings interaction. Constructed on the dedicated tray
/// STA thread (see <see cref="TrayHostedService"/>).
/// </summary>
public sealed class TrayHost : IDisposable
{
    private readonly NotifyIcon _notifyIcon;
    private readonly Drawing.Icon _icon;
    private readonly ContextMenuStrip _menu;
    private readonly McpServerHost _mcpHost;
    private readonly IHostApplicationLifetime _lifetime;
    private readonly Action _openSettings;
    private readonly ToolStripMenuItem _statusItem;
    private readonly ToolStripMenuItem _pauseResumeItem;
    private bool _paused;
    private bool _disposed;

    public TrayHost(
        McpServerHost mcpHost,
        IHostApplicationLifetime lifetime,
        Action openSettings)
    {
        _mcpHost = mcpHost;
        _lifetime = lifetime;
        _openSettings = openSettings;

        _menu = new ContextMenuStrip();
        _statusItem = new ToolStripMenuItem(GetStatusText())
        {
            Enabled = false
        };
        _menu.Items.Add(_statusItem);
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(Strings.TraySettings, image: null, OnSettingsClick);
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(Strings.TrayCopyMcpUrl, image: null, OnCopyUrlClick);
        _menu.Items.Add(Strings.TrayCopyMcpToken, image: null, OnCopyTokenClick);
        _menu.Items.Add(Strings.TrayCopyClaudeCodeSnippet, image: null, OnCopyClaudeCodeSnippetClick);
        _menu.Items.Add(new ToolStripSeparator());
        _pauseResumeItem = new ToolStripMenuItem(Strings.TrayPause, image: null, OnPauseResumeClick);
        _menu.Items.Add(_pauseResumeItem);
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(Strings.TrayExit, image: null, OnExitClick);

        _icon = LoadAppIcon();
        _notifyIcon = new NotifyIcon
        {
            Icon = _icon,
            Text = "Ambient Context MCP",
            ContextMenuStrip = _menu,
            Visible = true
        };
        _notifyIcon.MouseClick += OnTrayMouseClick;
    }

    /// <summary>
    /// True while ingestion to LocalContextHub is suppressed by the user.
    /// </summary>
    public bool IsPaused => _paused;

    public void RefreshStatus()
    {
        _statusItem.Text = GetStatusText();
    }

    public void RequestExit()
    {
        WinFormsApp.ExitThread();
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
        _icon.Dispose();
        _menu.Dispose();
    }

    private static Drawing.Icon LoadAppIcon()
    {
        var uri = new Uri("pack://application:,,,/Resources/AppIcon.ico", UriKind.Absolute);
        using var stream = WpfApp.GetResourceStream(uri).Stream;
        return new Drawing.Icon(stream, SystemInformation.SmallIconSize);
    }

    private string GetStatusText()
    {
        var paused = _paused ? Strings.TrayPausedSuffix : "";
        return $"Ambient Context MCP — :{_mcpHost.Settings.Port}{paused}";
    }

    private void OnTrayMouseClick(object? sender, MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Left)
        {
            _openSettings();
        }
    }

    private void OnSettingsClick(object? sender, EventArgs e)
    {
        _openSettings();
    }

    private void OnCopyUrlClick(object? sender, EventArgs e)
    {
        SafeCopy(_mcpHost.McpUrl);
    }

    private void OnCopyTokenClick(object? sender, EventArgs e)
    {
        SafeCopy(_mcpHost.Token);
    }

    private void OnCopyClaudeCodeSnippetClick(object? sender, EventArgs e)
    {
        SafeCopy(McpClientSnippets.BuildClaudeCodeSnippet(_mcpHost.McpUrl, _mcpHost.Token));
    }

    private void OnPauseResumeClick(object? sender, EventArgs e)
    {
        _paused = !_paused;
        _pauseResumeItem.Text = _paused ? Strings.TrayResume : Strings.TrayPause;
        RefreshStatus();
    }

    private void OnExitClick(object? sender, EventArgs e)
    {
        _lifetime.StopApplication();
    }

    private static void SafeCopy(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return;
        }

        try
        {
            Clipboard.SetText(value);
        }
        catch
        {
            // Clipboard.SetText throws if another process holds the clipboard.
            // Best effort for a tray menu copy.
        }
    }
}
