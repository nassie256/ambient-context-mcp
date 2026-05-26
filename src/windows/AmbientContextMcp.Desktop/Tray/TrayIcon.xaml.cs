using System.Windows.Input;
using AmbientContextMcp.Core.Diagnostics;
using AmbientContextMcp.Mcp;
using AmbientContextMcp.Resources;
using Microsoft.UI.Xaml.Controls;

namespace AmbientContextMcp.Tray;

public sealed partial class TrayIcon : UserControl
{
    private readonly McpServerHost _mcpHost;
    private readonly Action _openSettings;
    private readonly Action _requestExit;
    private bool _paused;

    public TrayIcon(McpServerHost mcpHost, Action openSettings, Action requestExit)
    {
        _mcpHost = mcpHost;
        _openSettings = openSettings;
        _requestExit = requestExit;
        OpenSettingsCommand = new RelayCommand(_ => _openSettings());
        InitializeComponent();
        ApplyLabels();
        RefreshStatusText();
    }

    public ICommand OpenSettingsCommand { get; }

    public bool IsPaused => _paused;

    public void RefreshStatusText()
    {
        StatusItem.Text = GetStatusText();
    }

    private void ApplyLabels()
    {
        SettingsItem.Text = Strings.TraySettings;
        CopyUrlItem.Text = Strings.TrayCopyMcpUrl;
        CopyTokenItem.Text = Strings.TrayCopyMcpToken;
        CopySnippetItem.Text = Strings.TrayCopyClaudeCodeSnippet;
        PauseResumeItem.Text = _paused ? Strings.TrayResume : Strings.TrayPause;
        ExitItem.Text = Strings.TrayExit;
    }

    private string GetStatusText()
    {
        var suffix = _paused ? Strings.TrayPausedSuffix : "";
        return $"Ambient Context MCP — :{_mcpHost.Settings.Port}{suffix}";
    }

    private void OnSettingsClick(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        AppDiagnosticLog.Log("tray", "menu_settings_click");
        _openSettings();
    }

    private void OnCopyUrlClick(object sender, Microsoft.UI.Xaml.RoutedEventArgs e) =>
        ClipboardCopy.Safe(_mcpHost.McpUrl);

    private void OnCopyTokenClick(object sender, Microsoft.UI.Xaml.RoutedEventArgs e) =>
        ClipboardCopy.Safe(_mcpHost.Token);

    private void OnCopySnippetClick(object sender, Microsoft.UI.Xaml.RoutedEventArgs e) =>
        ClipboardCopy.Safe(McpClientSnippets.BuildClaudeCodeSnippet(_mcpHost.McpUrl, _mcpHost.Token));

    private void OnPauseResumeClick(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        _paused = !_paused;
        PauseResumeItem.Text = _paused ? Strings.TrayResume : Strings.TrayPause;
        RefreshStatusText();
    }

    private void OnExitClick(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        AppDiagnosticLog.Log("tray", "menu_exit_click");
        _requestExit();
    }

    private sealed class RelayCommand : ICommand
    {
        private readonly Action<object?> _execute;
        public RelayCommand(Action<object?> execute) => _execute = execute;
        public event EventHandler? CanExecuteChanged;
        public bool CanExecute(object? parameter) => true;
        public void Execute(object? parameter) => _execute(parameter);
    }
}

internal static class ClipboardCopy
{
    public static void Safe(string value)
    {
        if (string.IsNullOrWhiteSpace(value)) return;
        try
        {
            var dp = new Windows.ApplicationModel.DataTransfer.DataPackage();
            dp.SetText(value);
            Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(dp);
        }
        catch
        {
            // best-effort
        }
    }
}
