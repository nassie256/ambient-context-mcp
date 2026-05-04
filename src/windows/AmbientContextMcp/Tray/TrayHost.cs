using System.Windows.Forms;
using AmbientContextMcp.Mcp;
using Microsoft.Extensions.Hosting;
using Drawing = System.Drawing;
using WinFormsApp = System.Windows.Forms.Application;

namespace AmbientContextMcp.Tray;

/// <summary>
/// Owns the system tray NotifyIcon, its context menu, and the
/// click-to-open-settings interaction. Constructed on the dedicated tray
/// STA thread (see <see cref="TrayHostedService"/>).
/// </summary>
public sealed class TrayHost : IDisposable
{
    private readonly NotifyIcon _notifyIcon;
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
        _menu.Items.Add("設定...", image: null, OnSettingsClick);
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add("MCP URL をコピー", image: null, OnCopyUrlClick);
        _menu.Items.Add("MCP トークンをコピー", image: null, OnCopyTokenClick);
        _menu.Items.Add("Claude Code 用設定をコピー", image: null, OnCopyClaudeCodeSnippetClick);
        _menu.Items.Add(new ToolStripSeparator());
        _pauseResumeItem = new ToolStripMenuItem("一時停止", image: null, OnPauseResumeClick);
        _menu.Items.Add(_pauseResumeItem);
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add("終了", image: null, OnExitClick);

        _notifyIcon = new NotifyIcon
        {
            Icon = Drawing.SystemIcons.Information,
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
        _menu.Dispose();
    }

    private string GetStatusText()
    {
        var paused = _paused ? " (一時停止中)" : "";
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
        var snippet =
            $"claude mcp add ambient-context " +
            $"--transport http {_mcpHost.McpUrl} " +
            $"--header \"Authorization: Bearer {_mcpHost.Token}\"";
        SafeCopy(snippet);
    }

    private void OnPauseResumeClick(object? sender, EventArgs e)
    {
        _paused = !_paused;
        _pauseResumeItem.Text = _paused ? "再開" : "一時停止";
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
